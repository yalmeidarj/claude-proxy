# Claude Proxy Documentation

A lightweight HTTP proxy that routes Claude Code requests through alternative LLM providers, with automatic failover when a provider is unavailable (rate limits, outages, etc.).

## Overview

- **Location**: `~/.claude-proxy/`
- **Default Port**: `8787`
- **Python Version**: 3.14+

## How It Works

1. Starts a local HTTP proxy server
2. When Claude Code makes API requests, they go through this proxy
3. On 429 (rate limit) or 5xx errors, automatically tries the next provider
4. Streams SSE responses transparently from providers back to Claude

## Supported Providers

| Provider | Base URL | Environment Variable |
|----------|----------|---------------------|
| MiniMax | `https://api.minimax.io/anthropic` | `MINIMAX_API_KEY` |
| Moonshot | `https://api.moonshot.ai/anthropic` | `MOONSHOT_API_KEY` |

## Configuration

### config.json

```json
{
  "proxy_port": 8787,
  "providers": [
    {
      "name": "minimax",
      "base_url": "https://api.minimax.io/anthropic",
      "api_key_env": "MINIMAX_API_KEY"
    },
    {
      "name": "moonshot",
      "base_url": "https://api.moonshot.ai/anthropic",
      "api_key_env": "MOONSHOT_API_KEY"
    }
  ],
  "cooldown_minutes": 30
}
```

### Environment Variables (.env)

```bash
MOONSHOT_API_KEY=sk-...
MINIMAX_API_KEY=sk-...
```

## Architecture

```
Claude Code → :8787 (proxy.py) → Provider APIs
                   ↓
            MiniMax (primary)
                   ↓ (on 429/5xx)
            Moonshot (fallback)
```

## Usage

### Commands

| Command | Behavior |
|---------|----------|
| `claude-fb` | Start fallback mode — all providers, auto-failover |
| `claude-switch -Provider <name>` | Switch to a specific provider for this session |
| `claude-reset` | Stop proxy, remove env vars, return to normal |
| `claude-status` | Show current mode and proxy status |

### Provider Selection

```powershell
claude-switch -Provider moonshot    # moonshot only, no failover
claude-switch -Provider minimax     # minimax only
claude-fb                           # all providers, auto-failover
```

When a single provider is specified via `claude-switch`, no failover occurs. If that provider fails, the request fails.

## Common Scenarios

### Fallback mode (all providers)

```powershell
claude-fb                    # starts proxy with all configured providers
claude "do something"        # MiniMax first, Moonshot if MiniMax fails
claude-reset                 # back to normal when done
```

### Specific provider

```powershell
claude-switch -Provider moonshot
claude "do something"        # goes through Moonshot only
claude-reset                 # back to normal when done
```

### Back to normal

```powershell
claude-reset                 # stop proxy, remove env vars
```

### Troubleshooting

```powershell
claude-status                # see what mode you're in and if proxy is running
claude-reset                 # stop everything, return to normal
```

### Module reload

```powershell
Import-Module ~/.claude-proxy/ClaudeProxy.psm1 -Force
```

## Files

| File | Purpose |
|------|---------|
| `proxy.py` | Main proxy server implementation |
| `ClaudeProxy.psm1` | PowerShell module for management |
| `config.json` | Provider configuration |
| `.env` | API keys (not committed to version control) |
| `.gitignore` | Git ignore rules |
| `proxy.log` | Runtime logs |

## Requirements

- Python 3.14+
- `urllib.request` (standard library)
- Anthropic-compatible API access to MiniMax/Moonshot

## Setup

### 1. Clone and copy templates
```bash
git clone <repo-url>
cd claude-proxy
cp config.example.json config.json
cp .env.example .env
```

### 2. Configure API keys
Edit `.env` with your provider API keys:
```bash
MINIMAX_API_KEY=sk-...
MOONSHOT_API_KEY=sk-...
```

### 3. Windows: Secure .env file
```powershell
icacls "$HOME/.claude-proxy/.env" /inheritance:r /grant "YOUR_USERNAME:(F)"
```

### 4. Import PowerShell module
```powershell
Import-Module ~/.claude-proxy/ClaudeProxy.psm1
```

## Security

- `.env` contains API keys - never commit this file
- On Windows, restrict .env file permissions to prevent accidental access
- The proxy runs locally and only forwards requests to configured providers

## Retry Logic

The proxy retries on these HTTP status codes:
- `429` - Rate limited
- `500` - Internal server error
- `502` - Bad gateway
- `503` - Service unavailable
- `504` - Gateway timeout

All other errors are forwarded directly to the client.

## Adding New Providers

Edit `config.json`:

```json
{
  "providers": [
    {
      "name": "new-provider",
      "base_url": "https://api.newprovider.com/anthropic",
      "api_key_env": "NEWPROVIDER_API_KEY"
    }
  ]
}
```

Add the API key to `.env`:

```bash
NEWPROVIDER_API_KEY=sk-...
```

## Request Limits
- Maximum request body size: 10MB
- Requests exceeding this limit receive HTTP 413 with error type `request_too_large`

## Internals

- API keys are loaded from `.env` into the proxy's environment
- Original `Authorization` header is replaced with the provider's API key
- `Host` header is adjusted to match the provider
