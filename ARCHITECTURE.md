# ai-boost Architecture

A self-contained AI workstation running inside a single rootless Podman container. It bundles a local LLM inference server (Ollama), a web UI (Open WebUI), a public tunnel (Cloudflared), and a developer toolchain (mise, uv, Claude Code) — all managed by supervisord.

---

## Project Structure

```
ai-boost/
├── Containerfile               # Image definition
├── podman-compose.yml          # Container runtime configuration
├── mise.toml                   # Developer toolchain versions (node, python, gh, uv)
├── scripts/
│   ├── entrypoint.sh           # Container startup: chown volumes, exec supervisord
│   └── pull-models             # Helper to pull Ollama models (skips existing)
└── supervisord/
    ├── ollama.conf             # Ollama service definition
    ├── open-webui.conf         # Open WebUI service definition
    └── cloudflared.conf        # Cloudflared tunnel service definition
```

---

## Services

Three processes run concurrently inside the container, managed by supervisord:

```
supervisord (root, PID 1)
├── ollama        priority 1 — LLM inference, listens on 0.0.0.0:11434
├── open-webui    priority 2 — Web interface, listens on 0.0.0.0:8080
└── cloudflared   priority 3 — Tunnel to expose open-webui publicly
```

Priority ordering ensures Ollama is ready before Open WebUI starts (Open WebUI connects to Ollama on startup).

### Ollama
- Serves local LLM inference via HTTP at `http://127.0.0.1:11434`
- GPU access via NVIDIA CUDA (CDI passthrough from host)
- Model files stored in `~/.ollama` (bind-mounted from host)
- Use `pull-models` script inside the container to pre-pull models

### Open WebUI
- Full-featured chat interface at `http://localhost:8080`
- Connects to Ollama at `http://127.0.0.1:11434` (loopback, both in same container)
- Persistent data (users, settings, chat history, vector DB) in `~/.local/share/open-webui` (bind-mounted from host)
- RAG web search via DuckDuckGo, embedding via `nomic-embed-text` on Ollama

### Cloudflared
- Exposes Open WebUI publicly via a Cloudflare Tunnel
- Tunnel identity stored in `~/.cloudflared` (bind-mounted from host)
- Tunnel ID hardcoded in `supervisord/cloudflared.conf`

---

## Image Build

**Base image:** `nvidia/cuda:12.8.0-runtime-ubuntu24.04`

Provides CUDA runtime libraries for GPU-accelerated inference. The `runtime` variant is used (not `devel`) to keep the image size down.

**Build stages (all in one image, ordered by cache stability):**

| Step | What | Why here |
|------|------|----------|
| Binary copy | `mise`, `uv` from upstream images | Pinned versions, no apt |
| apt install | `sudo`, `supervisor`, `zstd`, `nvtop`, `git`, `curl`, `vim`, `zsh` | System dependencies |
| Ollama | Download `.tar.zst` from GitHub releases | Pinned version, no install script |
| Cloudflared | Via Cloudflare apt repo | Signed repo, kept separate from main apt step |
| open-webui | `uv pip install open-webui==x.y.z` | Pinned, fast installs via uv cache mount |
| Config | supervisord confs, scripts, sudoers, log files | Rarely changes |
| User switch | `USER ubuntu` | All subsequent layers run unprivileged |
| mise toolchain | node (LTS), python 3.13, gh, uv — via `mise install` | User-scoped, cache-mounted |
| Claude Code | `npm install -g @anthropic-ai/claude-code` | Installed into mise-managed node |

**Build cache:** `--mount=type=cache` is used for both uv (root) and mise (uid=1000) to avoid re-downloading packages on rebuild.

---

## Runtime (podman-compose)

### GPU Passthrough
```yaml
devices:
  - nvidia.com/gpu=all
```
Uses CDI (Container Device Interface) — requires `nvidia-container-toolkit` on the host. This is the modern Podman approach vs the legacy `--gpus all` Docker flag.

### Ports
| Host | Container | Service |
|------|-----------|---------|
| 8080 | 8080 | Open WebUI |
| 11434 | 11434 | Ollama API |

### Bind Mounts

All persistent state lives on the host, not inside the container. Rebuilding the image never loses data.

| Host path | Container path | Contains |
|-----------|---------------|----------|
| `~/.ollama` | `/home/ubuntu/.ollama` | Downloaded LLM model files |
| `~/.cloudflared` | `/home/ubuntu/.cloudflared` | Tunnel credentials & config |
| `~/.local/share/open-webui` | `/home/ubuntu/.local/share/open-webui` | User accounts, chat history, vector DB, uploads |

All mounts use `selinux: z` for SELinux label relabelling (required on SELinux-enabled hosts with Podman).

### Environment Variables

Variables passed from the host shell at runtime:

| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_API_KEY` | Claude API access for Claude Code |
| `MISE_GITHUB_TOKEN` | GitHub token for mise tool downloads |

Set these before running:
```bash
export ANTHROPIC_API_KEY=sk-...
export MISE_GITHUB_TOKEN=ghp_...
```

Ollama tuning variables (`OLLAMA_KEEP_ALIVE`, `OLLAMA_MAX_LOADED_MODELS`, `OLLAMA_NUM_PARALLEL`) are set in `podman-compose.yml` and override the supervisord-level defaults.

---

## User Namespace (Rootless Podman)

The container runs rootless. Podman maps UIDs as follows:

| Inside container | On host |
|-----------------|---------|
| `root` (UID 0) | host user (e.g. `antonis`, UID 1000) |
| `ubuntu` (UID 1000) | a subordinate UID from `/etc/subuid` |

**Consequence for bind mounts:** files owned by the host user appear as `root` inside the container. For open-webui's data directory to be writable by the `ubuntu` process, ownership must be set using `podman unshare` so the UID mapping is applied correctly:

```bash
podman unshare chown -R 1000:1000 ~/.local/share/open-webui/
```

This is a one-time step after creating or copying the data directory. The `.ollama` and `.cloudflared` directories are handled by the entrypoint at every start.

---

## Startup Sequence

```
podman-compose up
    └── entrypoint.sh
            ├── sudo chown -R ubuntu:ubuntu ~/.cloudflared ~/.ollama
            └── exec sudo supervisord -n -c /etc/supervisor/supervisord.conf
                    ├── [priority 1] ollama serve
                    ├── [priority 2] open-webui serve --host 0.0.0.0 --port 8080
                    └── [priority 3] cloudflared tunnel run <tunnel-id>
```

---

## Developer Toolchain (mise)

`mise.toml` defines the toolchain installed for the `ubuntu` user:

```toml
[tools]
gh      = "latest"
node    = "lts"
python  = "3.13"
uv      = "latest"
```

mise shims are prepended to `PATH` so `node`, `python`, `uv`, `gh` resolve to the mise-managed versions. Claude Code is installed globally into the mise-managed Node via `npm install -g @anthropic-ai/claude-code`.

---

## Common Operations

```bash
# Build image
podman-compose build

# Start (detached)
podman-compose up -d

# Check service health
podman exec -it ai-boost sudo supervisorctl status

# Pull LLM models
podman exec -it ai-boost pull-models

# Shell access
podman exec -it ai-boost zsh

# Tail logs
podman exec -it ai-boost tail -f /var/log/open-webui.log
podman exec -it ai-boost tail -f /var/log/ollama.err

# Stop
podman-compose down

# Rebuild and restart
podman-compose up --build -d
```
