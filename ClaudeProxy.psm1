# ClaudeProxy.psm1 — PowerShell module for Claude Code proxy management

$script:ProxyDir = "$HOME\.claude-proxy"
$script:ProxyScript = "$script:ProxyDir\proxy.py"
$script:ProxyPort = 8787
$script:ProxyJobName = "ClaudeProxy"

function Get-ProxyConfig {
    $configPath = "$script:ProxyDir\config.json"
    if (Test-Path $configPath) {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        $script:ProxyPort = $cfg.proxy_port
        return $cfg
    }
    return $null
}

function Test-ProxyRunning {
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$script:ProxyPort/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

function Start-ClaudeProxy {
    [CmdletBinding()]
    param(
        [string]$Provider
    )

    if ($Provider) {
        $env:CLAUDE_PROVIDERS = $Provider
    } else {
        $env:CLAUDE_PROVIDERS = $null
    }

    Get-ProxyConfig | Out-Null

    if (Test-ProxyRunning) {
        Write-Host "Proxy already running on port $script:ProxyPort"
        return $true
    }

    # Start proxy as a background job, passing .env vars so Python inherits them
    $envFile = "$script:ProxyDir\.env"
    $envVars = @{}
    if (Test-Path $envFile) {
        Get-Content $envFile | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
                $parts = $line.Split('=', 2)
                $envVars[$parts[0].Trim()] = $parts[1].Trim()
            }
        }
    }
    if ($Provider) {
        $envVars['CLAUDE_PROVIDERS'] = $Provider
    }

    $job = Start-Job -Name $script:ProxyJobName -ScriptBlock {
        param($script_path, $extraEnv)
        foreach ($kv in $extraEnv.GetEnumerator()) {
            [System.Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'Process')
        }
        & python $script_path 2>&1
    } -ArgumentList $script:ProxyScript, $envVars

    # Wait for proxy to become ready
    $retries = 20
    for ($i = 0; $i -lt $retries; $i++) {
        Start-Sleep -Milliseconds 300
        if (Test-ProxyRunning) {
            Write-Host "Proxy started on port $script:ProxyPort (job $($job.Id))"
            return $true
        }
    }

    # If we get here, proxy didn't start — show error output
    $output = Receive-Job -Job $job -ErrorAction SilentlyContinue
    if ($output) {
        Write-Warning "Proxy failed to start. Output:`n$output"
    } else {
        Write-Warning "Proxy failed to start within timeout"
    }
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    return $false
}

function Stop-ClaudeProxy {
    [CmdletBinding()]
    param()

    # Stop background job
    $jobs = Get-Job -Name $script:ProxyJobName -ErrorAction SilentlyContinue
    foreach ($job in $jobs) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    # Also kill any orphaned python proxy processes
    Get-Process -Name python* -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
                $cmdline -and $cmdline -match [regex]::Escape("proxy.py")
            } catch { $false }
        } |
        ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }

    Write-Host "Proxy stopped"
}

function claude-fb {
    <#
    .SYNOPSIS
    Start fallback mode with all configured providers.
    #>
    [CmdletBinding()]
    param()

    $started = Start-ClaudeProxy
    if (-not $started) {
        Write-Warning "Could not start proxy."
        return
    }

    $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:$script:ProxyPort"
    $env:ANTHROPIC_AUTH_TOKEN = "proxy-managed"

    Write-Host "Fallback mode active (all providers)"
}

function claude-switch {
    <#
    .SYNOPSIS
    Switch current terminal to a specific provider.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Provider
    )

    $started = Start-ClaudeProxy -Provider $Provider
    if (-not $started) {
        Write-Warning "Could not start proxy."
        return
    }

    $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:$script:ProxyPort"
    $env:ANTHROPIC_AUTH_TOKEN = "proxy-managed"

    Write-Host "Switched to fallback mode"
}

function claude-reset {
    <#
    .SYNOPSIS
    Switch back to normal Anthropic mode.
    #>
    [CmdletBinding()]
    param()

    Remove-Item Env:\ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_PROVIDERS -ErrorAction SilentlyContinue
    Stop-ClaudeProxy

    Write-Host "Switched to normal mode (Anthropic Pro)"
}

function claude-status {
    <#
    .SYNOPSIS
    Show current Claude Code mode and proxy status.
    #>
    [CmdletBinding()]
    param()

    $baseUrl = $env:ANTHROPIC_BASE_URL
    $proxyRunning = Test-ProxyRunning

    if ($baseUrl -and $baseUrl -match "127\.0\.0\.1|localhost") {
        Write-Host "Mode:  FALLBACK (proxy)"
        Write-Host "URL:   $baseUrl"
    } else {
        Write-Host "Mode:  NORMAL (Anthropic Pro)"
    }

    if ($proxyRunning) {
        try {
            $health = Invoke-WebRequest -Uri "http://127.0.0.1:$script:ProxyPort/health" -UseBasicParsing -TimeoutSec 2 | ConvertFrom-Json
            $providers = $health.providers -join ", "
            Write-Host "Proxy: RUNNING on port $script:ProxyPort (providers: $providers)"
        } catch {
            Write-Host "Proxy: RUNNING on port $script:ProxyPort"
        }
    } else {
        Write-Host "Proxy: STOPPED"
    }

    # Show recent log entries
    $logPath = "$script:ProxyDir\proxy.log"
    if (Test-Path $logPath) {
        $lastLines = Get-Content $logPath -Tail 3
        if ($lastLines) {
            Write-Host "`nRecent log:"
            $lastLines | ForEach-Object { Write-Host "  $_" }
        }
    }
}

Export-ModuleMember -Function claude-fb, claude-switch, claude-reset, claude-status, Stop-ClaudeProxy, Start-ClaudeProxy, Test-ProxyRunning
