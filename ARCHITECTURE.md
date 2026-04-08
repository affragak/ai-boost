# ai-boost Architecture

A self-contained AI workstation running inside a single rootless Podman container. It bundles a local LLM inference server (Ollama), a web UI (Open WebUI), a public tunnel (Cloudflared), and a developer toolchain (mise, uv, Claude Code) — all managed by supervisord.

---

## Project Structure

```
ai-boost/
├── Containerfile               # Image definition
├── podman-compose.yml          # Container runtime configuration
├── mise.toml                   # Developer toolchain versions (node, python, gh, uv)
├── notes/                      # Operational notes and technical deep-dives
├── scripts/
│   ├── entrypoint.sh           # Container startup: chown volumes, exec supervisord
│   ├── pull-models             # Pull curated Ollama model set; syncs access grants
│   ├── create-user             # Create an Open WebUI user via REST API
│   ├── fix-model-access        # Grant wildcard read access to all models
│   ├── healthcheck             # Check services, APIs, and disk in one command
│   └── backup                  # Archive Open WebUI data + Cloudflare credentials
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

**Default models** (defined in `scripts/pull-models`):

| Model | Size | Purpose |
|-------|------|---------|
| `qwen2.5:7b` | ~5 GB | General-purpose chat |
| `mistral-nemo` | ~7 GB | General-purpose chat |
| `gemma2:9b-instruct-q4_K_M` | ~5.5 GB | Reasoning / analysis |
| `phi4:14b-q4_K_M` | ~8 GB | Heavy reasoning |
| `qwen2.5-coder:7b` | ~5 GB | Code generation / assistance |
| `llava:7b` | ~4.5 GB | Multimodal — image understanding |
| `nomic-embed-text` | ~274 MB | RAG embeddings (Open WebUI) |
| `mxbai-embed-large` | ~670 MB | Higher-quality RAG embeddings |

All models are sized for 8 GB VRAM. Only one model is loaded at a time (`OLLAMA_MAX_LOADED_MODELS=1`).

### Open WebUI
- Full-featured chat interface at `http://localhost:8080`
- Connects to Ollama at `http://127.0.0.1:11434` (loopback, both in same container)
- Persistent data (users, settings, chat history, vector DB) in `~/.local/share/open-webui` (bind-mounted from host)
- RAG web search via DuckDuckGo, embedding via `nomic-embed-text` on Ollama

### Cloudflared
- Exposes Open WebUI publicly via a Cloudflare Tunnel
- Tunnel identity stored in `~/.cloudflared` (bind-mounted from host)
- Tunnel UUID supplied at runtime via `CLOUDFLARED_TUNNEL_ID` env var

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

## Scripts

All scripts are installed to `/usr/local/bin` inside the container and are callable via `podman exec`.

### `entrypoint.sh`
The container entry point. Runs as `ubuntu`, uses `sudo` to chown the three bind-mounted directories (`~/.ollama`, `~/.cloudflared`, `~/.local/share/open-webui`) on every start, then hands off to supervisord via `exec sudo VAR=val …` — the explicit variable assignment bypasses sudo's `env_reset` so secrets reach supervisord.

### `pull-models`
Iterates over a curated list of Ollama models and pulls any that are not already present. If `OPENWEBUI_ADMIN_EMAIL` and `OPENWEBUI_ADMIN_PASSWORD` are set in the environment, it calls `fix-model-access` at the end so newly pulled models are immediately visible to all Open WebUI users. To customise the model set, edit the `MODELS` array at the top of the script.

### `create-user`
Creates a new Open WebUI user account (role: `user`) via the REST API and grants them read access to all currently registered models. Uses Python's `os.environ` to read all values — credentials are passed via `podman exec -e` flags, never as shell arguments, to safely handle passwords with special characters.

### `fix-model-access`
Sets a wildcard read grant (`principal_type: user`, `principal_id: *`) on every model in Open WebUI's database. This makes all models selectable by every authenticated user. Idempotent — safe to run repeatedly.

**When to run:** after pulling new models without admin env vars set, or to repair a broken model-visibility state. See [`notes/open-webui-model-access.md`](notes/open-webui-model-access.md) for why this is required.

### `healthcheck`
Checks four things and reports pass/fail for each:
1. **Supervisor services** — `ollama`, `open-webui`, `cloudflared` all `RUNNING`
2. **Ollama API** — `GET /api/tags` reachable, reports model count
3. **Open WebUI API** — `GET /health` reachable
4. **Disk usage** — warns if the Ollama volume exceeds 90% capacity

Exits `0` on full pass, `1` if any check fails.

### `backup`
Creates a timestamped `.tar.gz` of the two irreplaceable data directories:
- `~/.local/share/open-webui` — user accounts, chat history, vector DB, uploaded files
- `~/.cloudflared` — Cloudflare tunnel credentials

Ollama model weights (`~/.ollama`) are excluded — they are large and fully recoverable via `pull-models`. Output lands in `~/backups/` by default (on the host, via bind mount).

---

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
| `WEBUI_SECRET_KEY` | JWT signing key for Open WebUI sessions |
| `CLOUDFLARED_TUNNEL_ID` | UUID of the Cloudflare Tunnel to run |

Set these before running:
```bash
export ANTHROPIC_API_KEY=sk-...
export MISE_GITHUB_TOKEN=ghp_...
export WEBUI_SECRET_KEY=$(openssl rand -hex 32)
export CLOUDFLARED_TUNNEL_ID=<your-tunnel-uuid>
```

`WEBUI_SECRET_KEY` and `CLOUDFLARED_TUNNEL_ID` are passed through `sudo` using explicit `VAR=val` assignment in `entrypoint.sh` (bypassing `sudo`'s env_reset), then injected into the respective supervisord program environments via `%(ENV_...)s` interpolation.

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

This is a one-time step after creating or copying the data directory. The `.ollama`, `.cloudflared`, and `.local/share/open-webui` directories are all chowned by the entrypoint on every start.

---

## Startup Sequence

```
podman-compose up
    └── entrypoint.sh
            ├── sudo chown -R ubuntu:ubuntu ~/.cloudflared ~/.ollama ~/.local/share/open-webui
            └── exec sudo WEBUI_SECRET_KEY=... CLOUDFLARED_TUNNEL_ID=... supervisord
                    ├── [priority 1] ollama serve
                    ├── [priority 2] open-webui serve --host 0.0.0.0 --port 8080
                    └── [priority 3] cloudflared tunnel run <CLOUDFLARED_TUNNEL_ID>
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

## Notes & References

Operational notes and technical deep-dives live in the `notes/` directory:

| File | Contents |
|------|----------|
| [`notes/troubleshooting.md`](notes/troubleshooting.md) | Common failure modes: missing `WEBUI_SECRET_KEY`, container name conflicts, bind mount permissions, Cloudflared not connecting, models invisible to users, cache issues |
| [`notes/rotating-webui-secret-key.md`](notes/rotating-webui-secret-key.md) | How to rotate the JWT signing key without losing user data |
| [`notes/open-webui-model-access.md`](notes/open-webui-model-access.md) | Deep-dive into Open WebUI 0.8 model access control and why explicit grants are required |

---

## Common Operations

```bash
# Build image
podman-compose build

# Start (detached)
podman-compose up -d

# Full health check
podman exec -it ai-boost healthcheck

# Check individual service states
podman exec -it ai-boost sudo supervisorctl status

# Pull LLM models (+ auto-sync access grants if admin vars set)
podman exec -it ai-boost pull-models

# Create a new Open WebUI user
podman exec -it ai-boost create-user \
  --admin-email admin@example.com --admin-password yourpassword \
  --name "Alice" --email alice@example.com --password alicepassword

# Re-grant model access after pulling new models
podman exec -e OPENWEBUI_ADMIN_EMAIL=admin@example.com \
            -e OPENWEBUI_ADMIN_PASSWORD=yourpassword \
            ai-boost fix-model-access

# Backup Open WebUI data and Cloudflare credentials
podman exec -it ai-boost backup

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
