# Claude Proxy - Cheatsheet

## Quick Start

```powershell
Import-Module ~/.claude-proxy/ClaudeProxy.psm1
```

---

## Scenarios

### Use Claude with a specific provider (e.g., Moonshot)

```powershell
claude-switch -Provider moonshot
claude "your prompt"
```

Starts the proxy with only Moonshot enabled. No failover — if Moonshot fails, the request fails.
To use MiniMax instead: `claude-switch -Provider minimax`.

---

### Use Claude with auto-failover (all providers)

```powershell
claude-fb
claude "your prompt"
```

Starts the proxy with all configured providers. Tries MiniMax first; on 429/5xx, falls over to Moonshot automatically.

---

### Go back to normal Anthropic Pro

```powershell
claude-reset
```

Removes `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and `CLAUDE_PROVIDERS` env vars. Stops the proxy process.

---

### Check what mode you're in

```powershell
claude-status
```

Example output:

```
Mode:  FALLBACK (proxy)
URL:   http://127.0.0.1:8787
Proxy: RUNNING on port 8787 (providers: minimax, moonshot)

Recent log:
  2025-02-03 04:12:01,123 [INFO] minimax responded 200 — streaming to client
```

---

### Something is broken / proxy stuck

```powershell
# 1. Check current state
claude-status

# 2. Reset everything
claude-reset

# 3. If proxy is still stuck, kill it manually
Stop-ClaudeProxy

# 4. Nuclear option — kill any python proxy.py process
Get-Process python* -ErrorAction SilentlyContinue |
    Where-Object {
        try {
            $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
            $cmdline -and $cmdline -match "proxy.py"
        } catch { $false }
    } |
    ForEach-Object { Stop-Process -Id $_.Id -Force }
```

---

### Just updated the module files

```powershell
Import-Module ~/.claude-proxy/ClaudeProxy.psm1 -Force
```

`-Force` re-imports even if already loaded, picking up your changes.

---

## Manual Proxy Management

These are the lower-level functions used internally by `claude-switch` and `claude-fb`:

```powershell
Start-ClaudeProxy                    # start proxy in background
Test-ProxyRunning                    # returns $true / $false
Stop-ClaudeProxy                     # stop proxy and kill orphaned processes
```

To set env vars manually (what `claude-switch` does for you):

```powershell
$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:8787"
$env:ANTHROPIC_AUTH_TOKEN = "proxy-managed"
```

To clear them (what `claude-reset` does for you):

```powershell
Remove-Item Env:\ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:\CLAUDE_PROVIDERS -ErrorAction SilentlyContinue
```

---

## Health Check

```powershell
Invoke-WebRequest -Uri http://127.0.0.1:8787/health
```

Response:

```json
{"status": "ok", "providers": ["minimax", "moonshot"]}
```

---

## Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `ANTHROPIC_BASE_URL` | `http://127.0.0.1:8787` | Tells Claude to use proxy |
| `ANTHROPIC_AUTH_TOKEN` | `proxy-managed` | Placeholder (proxy replaces it with provider key) |
| `CLAUDE_PROVIDERS` | `minimax,moonshot` | Limits which providers the proxy uses |

---

## Troubleshooting

### Proxy won't start

```powershell
python --version                   # Python 3.14+ required
netstat -ano | findstr :8787       # check if port is in use
Get-Content ~/.claude-proxy/config.json | ConvertFrom-Json  # validate config
```

### Check logs

```powershell
Get-Content ~/.claude-proxy/proxy.log -Tail 20 -Wait
```

### API key issues

```powershell
$env:MOONSHOT_API_KEY     # should show your key
$env:MINIMAX_API_KEY      # should show your key
```

If empty, the `.env` file wasn't loaded. Restart the proxy with `claude-reset` then `claude-fb`.

---

## Add New Provider

1. Edit `config.json`:

```json
{
  "providers": [
    {"name": "newone", "base_url": "https://api.newone.com/anthropic", "api_key_env": "NEWONE_API_KEY"}
  ]
}
```

2. Add to `.env`:

```bash
NEWONE_API_KEY=sk-...
```

3. Restart proxy: `claude-reset && claude-fb`

---

## Common Errors

| Error | Solution |
|-------|----------|
| `connection refused` | Run `claude-fb` or `Start-ClaudeProxy` |
| `401 unauthorized` | Check API keys in `.env` |
| `429 rate limited` | Proxy should auto-failover; check `claude-status` |
| `413 request_too_large` | Request body exceeds 10MB limit |
| `all providers failed` | Check API keys and network |
| `port in use` | Run `Stop-ClaudeProxy` or change `proxy_port` in config.json |

---

## Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    User Terminal                             │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  claude-fb or claude-switch                                  │
│  Sets: ANTHROPIC_BASE_URL=http://127.0.0.1:8787             │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  proxy.py (:8787)                                            │
│  • Health endpoint /health                                   │
│  • Tries providers in order                                  │
│  • Auto-failover on 429/5xx                                  │
└─────────────────────────────────────────────────────────────┘
          │                           │
          ▼                           ▼
┌─────────────────┐         ┌─────────────────┐
│  MiniMax API    │         │  Moonshot API   │
│  (primary)      │         │  (fallback)     │
└─────────────────┘         └─────────────────┘
```
