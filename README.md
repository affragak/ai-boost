# ai-boost

A self-contained AI workstation in a single rootless Podman container.

Bundles a local LLM inference server ([Ollama](https://ollama.com)), a web chat UI ([Open WebUI](https://github.com/open-webui/open-webui)), a public tunnel ([Cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)), and a developer toolchain ([mise](https://mise.jdx.dev), [uv](https://github.com/astral-sh/uv), [Claude Code](https://docs.anthropic.com/en/docs/claude-code)) — all managed by supervisord.

---

## Getting Started

> **Prefer a faster start?** A pre-built image is published to the GitHub Container Registry on every relevant push to `main`. Skip the 20–30 min local build with:
> ```bash
> make pull   # ~2 GB download
> make up
> ```
> Then jump straight to Step 3 (you still need the data directories and `.env`).

---

### Step 1 — Install host prerequisites

**Podman and podman-compose** (Ubuntu/Debian):
```bash
sudo apt install podman podman-compose
```

**NVIDIA Container Toolkit** (for GPU passthrough):

Follow the [official install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html), then generate the CDI device spec that Podman uses:
```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

Verify with:
```bash
nvidia-ctk cdi list        # should list nvidia.com/gpu=0 etc.
podman run --rm --device nvidia.com/gpu=all ubuntu nvidia-smi
```

---

### Step 2 — Set up a Cloudflare Tunnel

> Skip this step if you don't need a public URL — Cloudflared will simply fail to connect but everything else still works.

```bash
# Authenticate with your Cloudflare account
cloudflared tunnel login

# Create the tunnel (pick any name)
cloudflared tunnel create ai-boost

# Note the tunnel UUID printed — you'll need it in Step 4
cloudflared tunnel list

# Create a DNS route so your domain points to the tunnel
cloudflared tunnel route dns ai-boost chat.yourdomain.com
```

The credentials JSON file is saved automatically to `~/.cloudflared/`. You also need a `~/.cloudflared/config.yml`:
```yaml
tunnel: <your-tunnel-uuid>
credentials-file: /home/ubuntu/.cloudflared/<your-tunnel-uuid>.json

ingress:
  - hostname: chat.yourdomain.com
    service: http://localhost:8080
  - service: http_status:404
```

---

### Step 3 — Create host data directories

All persistent data lives on the host via bind mounts. Create the directories before first run:

```bash
mkdir -p ~/.ollama ~/.cloudflared ~/.local/share/open-webui
```

Fix ownership on the Open WebUI directory so it's writable by the container user:
```bash
podman unshare chown -R 1000:1000 ~/.local/share/open-webui
```

> This uses `podman unshare` — a rootless Podman command that enters the user namespace and applies the correct UID mapping. You only need to run it once (or after manually copying data in).

---

### Step 4 — Configure environment variables

Copy the example file and fill in your values:

```bash
cp .env.example .env
```

Then edit `.env` in your favourite editor:

```bash
# Required
WEBUI_SECRET_KEY=$(openssl rand -hex 32)   # generate once, keep stable
CLOUDFLARED_TUNNEL_ID=<uuid>               # from: cloudflared tunnel list

# Optional but recommended
ANTHROPIC_API_KEY=sk-...     # Claude API key (for Claude Code inside the container)
MISE_GITHUB_TOKEN=ghp_...    # GitHub token (avoids rate-limiting for mise)
```

`podman-compose` and `make` both read `.env` automatically — no `export` needed before running any `make` target. The file is git-ignored so your secrets stay off GitHub.

> **Keep `WEBUI_SECRET_KEY` consistent across restarts.** Changing it signs out all users. See [`notes/rotating-webui-secret-key.md`](notes/rotating-webui-secret-key.md) for rotation guidance.

---

### Step 5 — Build and start

**Option A — use the pre-built image from GHCR (recommended, no clone needed):**
```bash
make pull && make up
# or, without cloning the repo at all:
podman build --format docker -t ghcr.io/affragak/ai-boost:latest \
  https://github.com/affragak/ai-boost.git
```

**Option B — build locally** (20–30 min on first run — downloads CUDA base, open-webui, mise toolchain):
```bash
make rebuild
```

Check everything came up:
```bash
make status       # supervisord service list
make healthcheck  # full API + disk check
```

---

### Step 6 — Create your admin account

Open **http://localhost:8080** in your browser. The first user to sign up becomes the administrator — fill in your name, email and password.

> Open WebUI does **not** create a default admin account. The first sign-up on a fresh instance is always admin.

---

### Step 7 — Pull models

```bash
# Pull all configured models (downloads ~40 GB total)
make pull-models

# If you want other users to see the models immediately:
OPENWEBUI_ADMIN_EMAIL=you@example.com \
OPENWEBUI_ADMIN_PASSWORD=yourpassword \
make fix-model-access
```

You're ready. Open WebUI is at **http://localhost:8080**, Ollama API at **http://localhost:11434**.

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

---

## Pulling Models

```bash
podman exec -it ai-boost pull-models
```

The `pull-models` script pulls any models listed in it, skipping ones already downloaded. If `OPENWEBUI_ADMIN_EMAIL` and `OPENWEBUI_ADMIN_PASSWORD` are set, it automatically syncs model access grants so all users can see newly pulled models.

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

---

## Scripts

All scripts live in `scripts/` and are installed to `/usr/local/bin` inside the container.

### `pull-models`
Pulls the curated model set from Ollama, skipping any already present. If the `OPENWEBUI_ADMIN_EMAIL` and `OPENWEBUI_ADMIN_PASSWORD` environment variables are set, it calls `fix-model-access` afterwards so newly pulled models are immediately visible to all users.

```bash
# Basic usage
podman exec -it ai-boost pull-models

# With automatic access grant sync
podman exec -e OPENWEBUI_ADMIN_EMAIL=admin@example.com \
            -e OPENWEBUI_ADMIN_PASSWORD=yourpassword \
            ai-boost pull-models
```

### `create-user`
Creates a new Open WebUI user account with the `user` role and grants them read access to all currently available models. Credentials are passed via CLI flags; internally they are forwarded as environment variables to Python to avoid shell quoting issues with special characters.

```bash
podman exec -it ai-boost create-user \
  --admin-email admin@example.com \
  --admin-password yourpassword \
  --name "Alice" \
  --email alice@example.com \
  --password alicepassword
```

### `fix-model-access`
Grants a wildcard read access grant (`principal_id: *`) to every model registered in Open WebUI. This makes all models visible to every authenticated user. Run this whenever new models are pulled without using `pull-models` + admin env vars, or to repair broken model visibility.

> **Why this is needed:** Open WebUI 0.8 requires explicit access grants in its database — raw Ollama models with no DB entry are visible to admins only. See [`notes/open-webui-model-access.md`](notes/open-webui-model-access.md) for the full explanation.

```bash
podman exec -e OPENWEBUI_ADMIN_EMAIL=admin@example.com \
            -e OPENWEBUI_ADMIN_PASSWORD=yourpassword \
            ai-boost fix-model-access
```

### `healthcheck`
Checks the health of all services and APIs in one command. Reports the status of each supervisord service, verifies the Ollama and Open WebUI HTTP APIs are reachable, confirms the Cloudflared tunnel process is running, and warns if disk usage on the Ollama volume exceeds 90%. Exits `0` if everything is healthy, `1` otherwise (useful in scripts).

```bash
podman exec -it ai-boost healthcheck
```

Example output:
```
=== ai-boost health check ===

Services:
  ✅  cloudflared  (RUNNING)
  ✅  ollama  (RUNNING)
  ✅  open-webui  (RUNNING)

APIs:
  ✅  Ollama  (http://localhost:11434)  10 model(s) loaded
  ✅  Open WebUI  (http://localhost:8080)

Tunnel:
  ✅  Cloudflared tunnel

Disk:
  ✅  Ollama volume  (1.5T free, 14% used)

All checks passed.
```

### `backup`
Archives Open WebUI user data and Cloudflare tunnel credentials into a timestamped `.tar.gz`. Ollama model weights are intentionally excluded — they are large and can be re-pulled with `pull-models`. The archive is saved to `~/backups/` inside the container (which is on the bind-mounted home directory, so it persists on the host).

```bash
# Default output: ~/backups/ai-boost-backup-<timestamp>.tar.gz
podman exec -it ai-boost backup

# Custom output directory
podman exec -it ai-boost backup /path/to/dir
```

To restore from a backup:
```bash
podman cp ~/backups/ai-boost-backup-<timestamp>.tar.gz ai-boost:/tmp/
podman exec -it ai-boost tar -xzf /tmp/ai-boost-backup-<timestamp>.tar.gz -C /
```

### `list-users`
Lists every Open WebUI user with their name, email, role, and sign-up date. Admins are shown first and marked with ★; pending accounts are flagged with ⚠.

```bash
podman exec \
  -e OPENWEBUI_ADMIN_EMAIL=admin@example.com \
  -e OPENWEBUI_ADMIN_PASSWORD=yourpassword \
  ai-boost list-users

# or via make:
OPENWEBUI_ADMIN_EMAIL=admin@example.com \
OPENWEBUI_ADMIN_PASSWORD=yourpassword \
make list-users
```

Example output:
```
  3 user(s)

  Name       Email                     Role      Created
  ─────────  ────────────────────────  ────────  ──────────
  Antonis    antonis@example.com       admin ★   2025-01-01
  Alice      alice@example.com         user      2025-03-15
  Bob        bob@example.com           pending ⚠ 2025-04-01
```

### `update`
Checks the pinned versions in the `Containerfile` against the latest releases on PyPI and GitHub and prints a comparison table. Run this from the **host** (not inside the container) whenever you want to know if anything needs bumping.

```bash
make update
# or directly:
./scripts/update
```

Example output:
```
  Component           Pinned        Latest        Status
  ──────────────────  ────────────  ────────────  ──────────────────
  open-webui          0.8.12        0.8.12        ✅  up to date
  ollama              0.20.3        0.20.4        ⬆️   UPDATE AVAILABLE
  uv                  0.11.4        0.11.4        ✅  up to date
  cuda base           12.8.0-...    (manual)      check Docker Hub
```

When an update is available, edit the pinned version in `Containerfile` then run `make rebuild`. The CUDA base image is not checked automatically — check [Docker Hub](https://hub.docker.com/r/nvidia/cuda/tags) manually.

### `entrypoint.sh`
The container entrypoint (PID 1 before supervisord takes over). Chowns all three bind-mounted directories to `ubuntu:ubuntu` on every start, then hands off to supervisord via `exec sudo` with secrets forwarded explicitly as `VAR=value` arguments to bypass sudo's `env_reset`.

---

## Auto-start on Boot

A systemd user service is included so the container starts automatically when your machine boots — no need to run `make up` manually.

### Install

Make sure your `.env` is populated (or env vars are exported), then:

```bash
make install-systemd
```

This will:
1. Write `~/.config/ai-boost/env` with your current env vars (mode `600` — readable only by you)
2. Install three unit files to `~/.config/systemd/user/`:
   - `ai-boost.service` — starts/stops the container
   - `ai-boost-backup.service` — runs the backup script
   - `ai-boost-backup.timer` — triggers the backup daily at 03:00
3. Enable and start both units immediately
4. Run `loginctl enable-linger` so user services survive logout

### Verify

```bash
systemctl --user status ai-boost
systemctl --user status ai-boost-backup.timer
systemctl --user list-timers
```

### Uninstall

```bash
make uninstall-systemd
```

> **Updating secrets:** if you rotate `WEBUI_SECRET_KEY` or any other env var, re-run `make install-systemd` to update `~/.config/ai-boost/env`, then `systemctl --user restart ai-boost`.

---

## Common Operations

```bash
make up              # Start the container (detached)
make down            # Stop and remove it
make pull            # Pull latest pre-built image from GHCR
make rebuild         # Stop → build locally → start
make shell           # Open a bash shell inside the container
make status          # Show supervisord service status
make logs            # Tail all service logs combined (Ctrl+C to stop)
make logs-webui      # Tail Open WebUI logs
make logs-ollama     # Tail Ollama logs
make healthcheck     # Full health check (services, APIs, disk)
make pull-models     # Pull configured Ollama models
make pull-model MODEL=llama3:8b  # Pull a single model by name
make model-remove MODEL=llava:7b # Remove an installed model
make models          # List installed Ollama models
make backup          # Archive Open WebUI data + Cloudflare credentials
make help            # List all available targets
```

Direct `podman exec` equivalents are in the scripts section below for cases where you need raw access.

---

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `WEBUI_SECRET_KEY` | JWT signing key for Open WebUI sessions — generate with `openssl rand -hex 32` |
| `CLOUDFLARED_TUNNEL_ID` | UUID of your Cloudflare Tunnel (from `cloudflared tunnel list`) |
| `ANTHROPIC_API_KEY` | Claude API access for Claude Code |
| `MISE_GITHUB_TOKEN` | GitHub token for mise tool downloads |
| `OPENWEBUI_ADMIN_EMAIL` | Admin email for `list-users`, `fix-model-access`, `create-user` |
| `OPENWEBUI_ADMIN_PASSWORD` | Admin password for the same scripts |

Set these in `.env` (copy from `.env.example`) — `podman-compose` reads it automatically. Shell exports also work and take precedence.

---

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for a detailed breakdown of the image build, user namespace mapping, startup sequence, and more.

---

## Notes

| File | Contents |
|------|----------|
| [`notes/reliability.md`](notes/reliability.md) | Log rotation, systemd auto-start, and daily backup timer — what was done and why |
| [`notes/troubleshooting.md`](notes/troubleshooting.md) | Common failure modes and fixes |
| [`notes/rotating-webui-secret-key.md`](notes/rotating-webui-secret-key.md) | How to rotate `WEBUI_SECRET_KEY` without data loss |
| [`notes/open-webui-model-access.md`](notes/open-webui-model-access.md) | Open WebUI 0.8 model access control explained |
