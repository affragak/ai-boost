# ai-boost

A self-contained AI workstation in a single rootless Podman container.

Bundles a local LLM inference server ([Ollama](https://ollama.com)), a web chat UI ([Open WebUI](https://github.com/open-webui/open-webui)), a public tunnel ([Cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)), and a developer toolchain ([mise](https://mise.jdx.dev), [uv](https://github.com/astral-sh/uv), [Claude Code](https://docs.anthropic.com/en/docs/claude-code)) — all managed by supervisord.

---

## Getting Started

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

Set these in your shell (add to `~/.bashrc` or `~/.zshrc` to persist across sessions):

```bash
export ANTHROPIC_API_KEY=sk-...           # Claude API key (for Claude Code)
export MISE_GITHUB_TOKEN=ghp_...          # GitHub token (for mise tool downloads)
export WEBUI_SECRET_KEY=$(openssl rand -hex 32)  # JWT signing key — generate once, keep it
export CLOUDFLARED_TUNNEL_ID=<uuid>       # from: cloudflared tunnel list
```

> **Keep `WEBUI_SECRET_KEY` consistent across restarts.** Changing it signs out all users. See [`notes/rotating-webui-secret-key.md`](notes/rotating-webui-secret-key.md) for rotation guidance.

---

### Step 5 — Build and start

```bash
make rebuild
```

This stops any existing container, rebuilds the image, and starts it detached. First build takes several minutes (downloading CUDA base image, installing Open WebUI, pulling toolchains).

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

### `entrypoint.sh`
The container entrypoint (PID 1 before supervisord takes over). Chowns all three bind-mounted directories to `ubuntu:ubuntu` on every start, then hands off to supervisord via `exec sudo` with secrets forwarded explicitly as `VAR=value` arguments to bypass sudo's `env_reset`.

---

## Common Operations

```bash
make up              # Start the container (detached)
make down            # Stop and remove it
make rebuild         # Full stop → rebuild → start cycle
make shell           # Open a bash shell inside the container
make status          # Show supervisord service status
make logs-webui      # Tail Open WebUI logs
make logs-ollama     # Tail Ollama logs
make healthcheck     # Full health check (services, APIs, disk)
make pull-models     # Pull configured Ollama models
make backup          # Archive Open WebUI data + Cloudflare credentials
make help            # List all available targets
```

Direct `podman exec` equivalents are in the scripts section below for cases where you need raw access.

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

---

## Notes

| File | Contents |
|------|----------|
| [`notes/troubleshooting.md`](notes/troubleshooting.md) | Common failure modes and fixes |
| [`notes/rotating-webui-secret-key.md`](notes/rotating-webui-secret-key.md) | How to rotate `WEBUI_SECRET_KEY` without data loss |
| [`notes/open-webui-model-access.md`](notes/open-webui-model-access.md) | Open WebUI 0.8 model access control explained |
