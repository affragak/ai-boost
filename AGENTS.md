# AGENTS.md

Guidance for AI agents (Copilot, Claude Code, etc.) working in this repository.

---

## Project Overview

**ai-boost** is a self-contained AI workstation that runs inside a single rootless Podman container. It bundles:

| Service | Role | Port |
|---------|------|------|
| **Ollama** | Local LLM inference (GPU-accelerated) | 11434 |
| **Open WebUI** | Chat interface | 8080 |
| **Cloudflared** | Public tunnel to Open WebUI | — |

All three services are managed by **supervisord** (PID 1 via entrypoint). The container runs as user `ubuntu` (UID 1000) inside a rootless Podman environment.

---

## Repository Layout

```
ai-boost/
├── Containerfile               # Single-stage image build
├── podman-compose.yml          # Container runtime config (GPU, ports, bind mounts)
├── mise.toml                   # Toolchain versions (node LTS, python 3.13, gh, uv)
├── ARCHITECTURE.md             # Detailed architecture reference
├── scripts/
│   ├── entrypoint.sh           # Container startup script
│   └── pull-models             # Helper to pull Ollama models
└── supervisord/
    ├── ollama.conf
    ├── open-webui.conf
    └── cloudflared.conf
```

---

## Preferences

- Keep responses concise and direct.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for all commit messages (e.g. `feat:`, `fix:`, `docs:`, `chore:`).
- Never mention or refer to any AI agent in issues, PRs, or commit messages.

---

## Key Conventions

### Build tool
- Use **podman** / **podman-compose**, not Docker. Build command: `podman-compose build`.
- The `Containerfile` uses Docker-format syntax (`--format docker` flag on build).
- Build cache mounts are used for `uv` (root) and `mise` (uid=1000) — preserve these when editing the `Containerfile`.

### Pinned versions — always update together
| Component | Current version | Where pinned |
|-----------|----------------|--------------|
| CUDA base image | `12.8.0-runtime-ubuntu24.04` | `Containerfile` `FROM` |
| uv | `0.11.4` | `Containerfile` `COPY --from=ghcr.io/astral-sh/uv:...` |
| Ollama | `0.20.3` | `Containerfile` `ARG OLLAMA_VERSION` |
| open-webui | `0.8.12` | `Containerfile` `uv pip install open-webui==...` |
| node | `lts` | `mise.toml` |
| python | `3.13` | `mise.toml` |

When bumping a version, update only that one pin — do not touch unrelated components.

### Python packaging
- Use **uv** for all Python installs (not pip directly). The `--system --break-system-packages` flags are required when installing system-wide inside the container as root.

### Toolchain (mise)
- `mise.toml` is copied into the image at `/home/ubuntu/.config/mise/config.toml`.
- Claude Code is installed into the mise-managed Node via `npm install -g @anthropic-ai/claude-code` (not system npm).

### User model
- The container is **rootless Podman**: host UID (`antonis`, 1000) maps to container `root`; container `ubuntu` (1000) maps to a subordinate UID on the host.
- All application code runs as `ubuntu`. The `entrypoint.sh` uses `sudo` only to `chown` bind-mounted directories, then `exec sudo supervisord`.
- Never change the `USER ubuntu` placement in the `Containerfile` — it must come after all root-level setup and before user-level toolchain installation.

### SELinux
- All bind mounts use `selinux: z` in `podman-compose.yml`. Keep this on every new mount added.

### Supervisor service ordering
- Ollama is **priority 1**, Open WebUI **priority 2**, Cloudflared **priority 3**. This ensures Ollama is listening before Open WebUI tries to connect. Respect this ordering when adding new services.

### Environment variables
- `ANTHROPIC_API_KEY` and `MISE_GITHUB_TOKEN` are injected from the host shell at runtime — they must **never** be hardcoded in any file.
- `WEBUI_SECRET_KEY` is injected the same way — generate with `openssl rand -hex 32`. It is passed through `entrypoint.sh` into supervisord via explicit `sudo VAR=val` assignment and then into open-webui via `%(ENV_WEBUI_SECRET_KEY)s` in `supervisord/open-webui.conf`.
- `CLOUDFLARED_TUNNEL_ID` is injected the same way and referenced in `supervisord/cloudflared.conf` via `%(ENV_CLOUDFLARED_TUNNEL_ID)s`.
- Ollama tuning vars (`OLLAMA_KEEP_ALIVE`, `OLLAMA_MAX_LOADED_MODELS`, `OLLAMA_NUM_PARALLEL`) live in `podman-compose.yml`, not in supervisord confs.

---

## Common Operations (reference)

```bash
# Build image
podman-compose build

# Start (detached)
podman-compose up -d

# Check service health inside container
podman exec -it ai-boost sudo supervisorctl status

# Pull LLM models
podman exec -it ai-boost pull-models

# Shell access
podman exec -it ai-boost bash

# Tail logs
podman exec -it ai-boost tail -f /var/log/open-webui.log
podman exec -it ai-boost tail -f /var/log/ollama.err

# Rebuild and restart
podman-compose up --build -d
```

---

## What NOT to do

- Do not add a `docker-compose.yml` — this project is Podman-only.
- Do not install Python packages with bare `pip` — use `uv`.
- Do not store secrets or credentials in any tracked file.
- Do not change bind-mount paths without also running `podman unshare chown` on the host.
- Do not remove `selinux: z` from bind mounts.
