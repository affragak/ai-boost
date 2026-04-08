# ai-boost

A self-contained AI workstation in a single rootless Podman container.

Bundles a local LLM inference server ([Ollama](https://ollama.com)), a web chat UI ([Open WebUI](https://github.com/open-webui/open-webui)), a public tunnel ([Cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)), and a developer toolchain ([mise](https://mise.jdx.dev), [uv](https://github.com/astral-sh/uv), [Claude Code](https://docs.anthropic.com/en/docs/claude-code)) — all managed by supervisord.

---

## Requirements

- [Podman](https://podman.io/) + [podman-compose](https://github.com/containers/podman-compose)
- [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) (for GPU passthrough via CDI)
- A [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/) configured in `~/.cloudflared`

---

## Quick Start

```bash
# 1. Set required environment variables
export ANTHROPIC_API_KEY=sk-...
export MISE_GITHUB_TOKEN=ghp_...
export WEBUI_SECRET_KEY=$(openssl rand -hex 32)
export CLOUDFLARED_TUNNEL_ID=<your-tunnel-uuid>

# 2. Build the image
podman-compose build

# 3. Start (detached)
podman-compose up -d
```

Open WebUI will be available at **http://localhost:8080**.

---

## Services

| Service | Description | Port |
|---------|-------------|------|
| Ollama | GPU-accelerated local LLM inference | 11434 |
| Open WebUI | Chat interface, RAG, embeddings | 8080 |
| Cloudflared | Public HTTPS tunnel to Open WebUI | — |

Services start in priority order (Ollama → Open WebUI → Cloudflared) so Open WebUI can connect to Ollama on startup.

---

## Persistent Data

All state lives on the host via bind mounts — rebuilding the image never loses data.

| Host path | Contents |
|-----------|----------|
| `~/.ollama` | Downloaded LLM model files |
| `~/.cloudflared` | Tunnel credentials and config |
| `~/.local/share/open-webui` | User accounts, chat history, vector DB, uploads |

> **One-time setup:** if you create or copy the Open WebUI data directory, fix ownership so it's writable inside the container:
> ```bash
> podman unshare chown -R 1000:1000 ~/.local/share/open-webui/
> ```

---

## Pulling Models

```bash
podman exec -it ai-boost pull-models
```

The `pull-models` script pulls any models listed in it, skipping ones already downloaded.

---

## Common Operations

```bash
# Check service health
podman exec -it ai-boost sudo supervisorctl status

# Shell access
podman exec -it ai-boost bash

# Tail logs
podman exec -it ai-boost tail -f /var/log/open-webui.log
podman exec -it ai-boost tail -f /var/log/ollama.err

# Stop
podman-compose down

# Rebuild and restart
podman-compose up --build -d
```

---

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_API_KEY` | Claude API access for Claude Code |
| `MISE_GITHUB_TOKEN` | GitHub token for mise tool downloads |
| `WEBUI_SECRET_KEY` | JWT signing key for Open WebUI sessions — generate with `openssl rand -hex 32` |
| `CLOUDFLARED_TUNNEL_ID` | UUID of your Cloudflare Tunnel (from `cloudflared tunnel list`) |

Set these in your shell before running `podman-compose up`.

---

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for a detailed breakdown of the image build, user namespace mapping, startup sequence, and more.
