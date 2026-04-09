# How ai-boost Works — A Beginner's Guide

This document explains every moving part of the ai-boost project from first principles. No prior knowledge of containers, Linux services, or CI/CD is assumed. By the end you should understand not just *what* each piece does, but *why* it exists and how they all connect.

---

## The Big Picture

ai-boost runs three services inside a single container:

| Service | What it does |
|---------|--------------|
| **Ollama** | Downloads and runs AI language models on your GPU |
| **Open WebUI** | A browser-based chat interface that talks to Ollama |
| **Cloudflared** | Creates a secure public URL so you can access the WebUI from anywhere |

Everything lives inside one container, started with a single command (`make up`), managed automatically on boot, and rebuilt and published via GitHub Actions whenever you push changes.

Here is the request flow for a chat message:

```
Your browser
    │
    ▼
Open WebUI (port 8080)
    │  sends the message as an API request
    ▼
Ollama (port 11434)
    │  loads the model, runs it on the GPU
    ▼
GPU (CUDA cores do the math)
    │
    ▼  streams tokens back
Open WebUI
    │  formats and displays them
    ▼
Your browser
```

If you are connecting remotely, your browser hits the Cloudflare tunnel URL instead of `localhost:8080`, but from that point onwards the flow is identical.

---

## 1. Containers — The Foundation

### What is a container?

A container is an isolated process (or group of processes) that has its own view of the filesystem, network, and users. It looks like a mini Linux system but shares the host kernel. Think of it as a very lightweight virtual machine — fast to start, small to store, and completely self-contained.

**Why not just install Ollama and Open WebUI directly on the host?**

- Installing multiple Python packages, system libraries, and GPU drivers alongside each other causes version conflicts.
- Removing them cleanly later is painful.
- Moving the whole setup to another machine means re-doing all the installation steps.

With a container you package *everything* — the exact versions of every dependency — into a single image. To move to a new machine you just pull the image.

### Images vs Containers

| Concept | Analogy | What it is |
|---------|---------|-----------|
| **Image** | A recipe / template | A read-only snapshot of a filesystem with all software pre-installed |
| **Container** | A meal cooked from the recipe | A running instance created from an image |

You can run many containers from the same image. Stopping a container doesn't delete the image. Deleting a container doesn't lose your data if that data is stored in a *volume* (more on this later).

---

## 2. Podman — Our Container Engine

### Podman vs Docker

Podman and Docker serve the same purpose: build and run containers. The key difference is security.

Docker runs a long-lived background daemon as **root**. If anything goes wrong (a bug, a misconfiguration, a compromised container), the attacker has root access to your machine.

Podman is **daemonless and rootless** by default:
- No persistent background daemon.
- Containers run as your own user account, not root.
- A process escaping the container can only do what *your user* can do.

This is why we use Podman.

### Rootless Podman and UID mapping

Here is something that surprises most beginners. When you run Podman without root:

- Your host user (`antonis`, UID 1000) is *mapped* to `root` (UID 0) **inside** the container.
- The `ubuntu` user (UID 1000) **inside** the container maps to a *subordinate* UID on the host — a high number like `165536` that has no real privileges.

This means when the container writes files as `ubuntu`, those files on the host are owned by `165536`, not by `antonis`. That is why `entrypoint.sh` runs `sudo chown` at startup — it fixes the ownership of bind-mounted directories so the running processes can write to them.

---

## 3. The Containerfile — Building the Image

The `Containerfile` is the recipe for building the image. Docker calls this a `Dockerfile`; the format is identical, just renamed for Podman. We pass `--format docker` when building because we use BuildKit cache mount features that Podman's OCI format doesn't support.

### Layers

Every instruction (`RUN`, `COPY`, `FROM`) in the Containerfile creates a *layer*. Layers are cached. If you change line 50 of the Containerfile, Docker/Buildx only re-runs from line 50 onwards — everything before it is reused from cache. This makes rebuilds fast.

**This is why order matters:** put things that change rarely (system packages, Ollama install) early, and things that change often (scripts, config files) late.

### Walkthrough

```dockerfile
FROM nvidia/cuda:12.8.0-runtime-ubuntu24.04
```
Start from NVIDIA's official Ubuntu 24.04 image that already has the CUDA runtime libraries. We inherit everything in that image.

```dockerfile
COPY --from=jdxcode/mise ...
COPY --from=ghcr.io/astral-sh/uv:0.11.4 /uv ...
```
"Multi-stage copy" — grab just the binary from another image without inheriting its entire filesystem. This is how we install `mise` and `uv` without adding their full build environments.

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    sudo zstd libatomic1 supervisor nvtop git curl vim zsh
```
Install system packages. `--no-install-recommends` keeps the image smaller by skipping optional packages apt would otherwise pull in. The `&& rm -rf /var/lib/apt/lists/*` at the end of install commands deletes apt's package index cache — it's not needed at runtime and would bloat the image.

```dockerfile
ARG OLLAMA_VERSION=0.20.3
RUN ... curl ... ollama-linux-${OLLAMA_ARCH}.tar.zst ...
```
Download Ollama from GitHub Releases and extract it. The `ARG` makes the version easy to change in one place. The architecture detection (`uname -m`) makes the same Containerfile work on both x86_64 and ARM machines.

```dockerfile
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --system --break-system-packages open-webui==0.8.12
```
`--mount=type=cache` is a BuildKit feature: it mounts a persistent cache directory that survives across builds. `uv` (a very fast Python package installer) caches downloaded packages here so re-running this line after a version bump only re-downloads what changed.

`--break-system-packages` is needed because Ubuntu 24.04 marks its Python as "externally managed" to protect the system Python. Since we're inside a container where that protection doesn't make sense, we override it.

```dockerfile
USER ubuntu
WORKDIR /home/ubuntu
```
**Critical placement.** Everything before this line runs as root. Everything after runs as `ubuntu`. Never move this earlier — root-level operations (system installs, sudoers config, log file creation) must happen before the user switch, or they would fail with permission errors.

```dockerfile
RUN --mount=type=cache,uid=1000,gid=1000,target=/home/ubuntu/.cache/mise \
    mise install
```
`mise` reads `mise.toml` (copied as `~/.config/mise/config.toml`) and installs the toolchain: Node.js LTS, Python 3.13, and the `gh` CLI. The `uid=1000,gid=1000` on the cache mount ensures the cache is owned by `ubuntu`, not root.

```dockerfile
VOLUME /home/ubuntu/.ollama
VOLUME /home/ubuntu/.cloudflared
```
Declares that these directories are mount points. They are where Ollama stores downloaded models and Cloudflared stores its tunnel credentials. Because we use *bind mounts* (host directories mounted into the container), data written here persists even after the container is deleted.

---

## 4. GPU Acceleration — CUDA

Ollama uses the GPU to run models. Without GPU, inference would be 10–100× slower on CPU.

### CUDA

CUDA is NVIDIA's platform for running general-purpose code on GPUs. The CUDA runtime provides the libraries that programs call to schedule work on the GPU. The `FROM nvidia/cuda:12.8.0-runtime-ubuntu24.04` base image includes these libraries.

### nvidia-container-toolkit

To pass a GPU into a container, the host must have `nvidia-container-toolkit` installed. This toolkit registers the GPU as a CDI (Container Device Interface) device, which Podman can then pass through.

In `podman-compose.yml`:
```yaml
devices:
  - nvidia.com/gpu=all
```
This line says "give the container access to all GPUs via CDI." Without it, the container has no GPU access and Ollama falls back to CPU.

### Environment variables

```yaml
NVIDIA_VISIBLE_DEVICES=all
NVIDIA_DRIVER_CAPABILITIES=all
```
These are read by the NVIDIA container runtime hooks to configure exactly which GPU capabilities are available inside the container.

---

## 5. Ollama — The LLM Server

Ollama is a program that runs AI language models locally. It:
1. Downloads models from the Ollama registry (like Docker Hub, but for AI models).
2. Manages GPU memory — loads models into VRAM, unloads them when not in use.
3. Exposes an HTTP API on port 11434 that other programs (like Open WebUI) call to generate text.

When you send a message through Open WebUI, it POST-requests `http://127.0.0.1:11434/api/chat` with your conversation. Ollama runs the model and streams tokens back.

### Key settings in `supervisord/ollama.conf`

```ini
OLLAMA_KEEP_ALIVE="10m"
```
How long to keep a model loaded in VRAM after the last request. After 10 minutes of inactivity, Ollama unloads the model to free GPU memory.

```ini
OLLAMA_MAX_LOADED_MODELS="1"
```
Maximum number of models loaded simultaneously. Keeping this at 1 prevents VRAM exhaustion when you switch between models.

```ini
OLLAMA_NUM_PARALLEL="1"
```
Maximum simultaneous inference requests. 1 means requests are queued, which is fine for personal use and prevents thrashing.

---

## 6. Open WebUI — The Interface

Open WebUI is a full-featured, self-hosted chat UI inspired by ChatGPT. It is written in Python (FastAPI backend) and Svelte (frontend). Key features:

- **User accounts** with roles (admin, user) and per-user model permissions.
- **Conversation history** stored locally — nothing sent to external servers.
- **RAG (Retrieval-Augmented Generation)** — upload documents and chat with them.
- **Web search** — uses DuckDuckGo (no API key required) to supplement answers with live results.
- **Memory** — can remember facts about you across conversations.

Open WebUI communicates with Ollama via `OLLAMA_BASE_URL=http://127.0.0.1:11434`. Because both processes run inside the same container, they can reach each other over localhost.

### Why a secret key?

```ini
WEBUI_SECRET_KEY="%(ENV_WEBUI_SECRET_KEY)s"
```
Open WebUI uses this key to sign session cookies and JWT tokens. Without it (or with an empty string), anyone could forge a session token and log in as any user. It must be a random secret, generated once and stored safely in `.env`.

The `%(ENV_WEBUI_SECRET_KEY)s` syntax is supervisord's way of reading an environment variable — more on this in the supervisord section.

---

## 7. Cloudflared — The Tunnel

By default, Open WebUI is only accessible on `localhost:8080`. If you want to reach it from your phone, another device, or the internet, you have two options:
- Open a firewall port and expose it directly to the internet (risky without TLS + auth).
- Use a **tunnel**: a secure, outbound-only connection from inside your network to Cloudflare's edge servers.

Cloudflared creates the tunnel. Here is how it works:

```
Your phone
    │  HTTPS request to https://ai.yourdomain.com
    ▼
Cloudflare's edge servers
    │  forwards the request over an encrypted tunnel
    ▼
cloudflared (running inside your container)
    │  proxies to localhost:8080
    ▼
Open WebUI
```

The tunnel is **outbound-only** — the container initiates the connection to Cloudflare. No inbound ports need to be opened on your router or firewall.

The tunnel configuration (credentials, hostname routing) is stored in `~/.cloudflared/` on the host, bind-mounted into the container. The tunnel is identified by its UUID, stored in `CLOUDFLARED_TUNNEL_ID`.

---

## 8. Supervisord — Managing Multiple Processes

### The problem

Containers are designed around a single process. The `CMD` in a Containerfile starts one process, and when that process exits the container stops.

We need to run *three* services: Ollama, Open WebUI, and Cloudflared. We also need:
- Automatic restarts if a service crashes.
- Startup ordering (Ollama must be ready before Open WebUI starts).
- Log management for each service.

### Supervisord as PID 1

Supervisord is a process manager. We make it PID 1 (the first process in the container, i.e., what `CMD` starts). Supervisord then starts and supervises all child processes.

```
Container PID 1: supervisord
    ├── PID 2: ollama serve         (priority 1)
    ├── PID 3: open-webui serve     (priority 2)
    └── PID 4: cloudflared tunnel   (priority 3)
```

### Configuration explained

Each service has a `.conf` file in `supervisord/`. Key fields:

```ini
autostart=true      # Start this service when supervisord starts
autorestart=true    # Restart this service if it exits unexpectedly
startretries=5      # Try to restart up to 5 times before giving up
startsecs=5         # Wait 5 seconds after start; if still running, consider it "up"
priority=1          # Lower number = started earlier
user=ubuntu         # Run as this user (not root)
```

```ini
stdout_logfile=/var/log/ollama.log
stderr_logfile=/var/log/ollama.err
stdout_logfile_maxbytes=5MB
stderr_logfile_backups=3
```
Supervisord handles log rotation for each service: when a log file reaches 5 MB, it is rotated, and up to 3 backups are kept. This prevents logs from filling the disk.

### Passing secrets to supervisord

Supervisord's config files cannot read shell environment variables directly — they have their own interpolation syntax: `%(ENV_VARNAME)s`. This is why in `open-webui.conf`:

```ini
WEBUI_SECRET_KEY="%(ENV_WEBUI_SECRET_KEY)s"
```

But supervisord itself needs to *receive* those variables first. That happens in `entrypoint.sh`:

```bash
exec sudo \
    WEBUI_SECRET_KEY="${WEBUI_SECRET_KEY}" \
    CLOUDFLARED_TUNNEL_ID="${CLOUDFLARED_TUNNEL_ID}" \
    /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
```

`sudo VAR=value command` is a standard Unix way to set environment variables for a process launched via sudo. Supervisord receives those variables in its environment, and the `%(ENV_...)s` references in conf files read from there.

---

## 9. entrypoint.sh — The Container Startup Script

When the container starts, `CMD ["/usr/local/bin/entrypoint.sh"]` runs this script as PID 1's launcher.

```bash
#!/bin/bash
set -e
sudo chown -R ubuntu:ubuntu \
    /home/ubuntu/.cloudflared \
    /home/ubuntu/.ollama \
    /home/ubuntu/.local/share/open-webui
```

`set -e` means "exit immediately if any command fails." The `chown` fixes ownership of the bind-mounted directories (see the rootless Podman UID mapping section above). On first run these directories may be owned by a host-side UID that doesn't match `ubuntu` inside the container.

```bash
exec sudo \
    PYTHONWARNINGS=ignore::UserWarning \
    WEBUI_SECRET_KEY="${WEBUI_SECRET_KEY}" \
    CLOUDFLARED_TUNNEL_ID="${CLOUDFLARED_TUNNEL_ID}" \
    /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
```

`exec` replaces the current shell process with supervisord — so supervisord becomes PID 1. This matters because PID 1 receives OS signals (like SIGTERM for graceful shutdown); if `exec` wasn't used, the shell would be PID 1 and might not forward signals correctly.

`PYTHONWARNINGS=ignore::UserWarning` suppresses a harmless deprecation warning from supervisord's own Python code.

---

## 10. podman-compose.yml — Wiring It All Together

`podman-compose.yml` (a YAML file) describes how to run the container: which image to use, what ports to expose, what volumes to mount, and what environment variables to pass. It is the runtime configuration.

### Volumes (bind mounts)

```yaml
volumes:
  - type: bind
    source: ${HOME}/.ollama
    target: /home/ubuntu/.ollama
    bind:
      selinux: z
```

A **bind mount** links a directory on the host to a path inside the container. Anything written to `/home/ubuntu/.ollama` inside the container lands on `~/.ollama` on the host, and survives container deletion.

We bind-mount three directories:
- `~/.ollama` — Ollama models (can be many GB; you don't want to re-download after every rebuild).
- `~/.cloudflared` — Cloudflare tunnel credentials (generated once, reused forever).
- `~/.local/share/open-webui` — Open WebUI database: chat history, users, settings.

**SELinux label:** `selinux: z` sets the correct SELinux context on the bind-mounted directory so the container process (running as a different UID) can read and write it. On systems without SELinux, this is a no-op.

### Ports

```yaml
ports:
  - "8080:8080"
  - "11434:11434"
```

Format is `HOST_PORT:CONTAINER_PORT`. This maps port 8080 on your host to port 8080 inside the container, so `http://localhost:8080` reaches Open WebUI.

### Environment variables

```yaml
environment:
  OLLAMA_KEEP_ALIVE: 10m
  ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}
```

Static values are written directly. Values like `${ANTHROPIC_API_KEY}` are read from the shell environment at `podman-compose up` time — which is where `.env` comes in.

---

## 11. The .env File — Secrets Management

### What it is

`.env` is a plain text file with `KEY=value` pairs. It is listed in `.gitignore` so it is never committed to git. It holds secrets and machine-specific configuration.

```
WEBUI_SECRET_KEY=abc123...
CLOUDFLARED_TUNNEL_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
OPENWEBUI_ADMIN_EMAIL=admin@example.com
OPENWEBUI_ADMIN_PASSWORD=my-password
```

### How it flows

1. `podman-compose` reads `.env` automatically and makes each key available as an environment variable when evaluating `podman-compose.yml`.
2. The `Makefile` loads `.env` at the top with `-include .env` + `export`, so `make` targets also have access.
3. `make install-systemd` writes an env file to `~/.config/ai-boost/env` which systemd reads at boot — so the container starts with secrets even without a running shell session.

### .env.example

`env.example` is a template committed to git. It shows every variable name with placeholder values and comments. The workflow is:
1. Copy `cp .env.example .env`
2. Fill in real values
3. Never commit `.env`

---

## 12. The Makefile — Developer Experience

A `Makefile` is a file that defines named commands (called *targets*) that you run with `make target-name`. It is the single source of truth for all project operations — you don't need to remember long `podman` commands.

### Self-documenting help

```makefile
help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
```

Every target with a `## comment` after the colon appears in `make help`. The `awk` command formats them into a neat table. This means the Makefile documents itself.

### Auto-loading .env

```makefile
ifneq (,$(wildcard .env))
  -include .env
  export
endif
```

If `.env` exists, include it. The `-` prefix means "don't error if the file doesn't exist." `export` makes every loaded variable available as an environment variable to child processes (like `podman exec`). This is why you don't need to manually `source .env` before running `make` commands.

### A target with validation

```makefile
pull-model: ## Pull a single Ollama model (MODEL=name:tag required)
	@test -n "$(MODEL)" || (echo "ERROR: MODEL is not set" && exit 1)
	podman exec -it $(CONTAINER) ollama pull $(MODEL)
```

`test -n "$(MODEL)"` checks that the `MODEL` variable is non-empty. If it's empty, print an error and exit before running the `podman exec`. This pattern gives helpful error messages instead of confusing `podman` errors.

---

## 13. Scripts — Utility Programs

All scripts live in `scripts/` and are copied into the image at `/usr/local/bin/`, making them runnable from anywhere inside the container.

| Script | What it does |
|--------|-------------|
| `entrypoint.sh` | Container startup: fix permissions, launch supervisord |
| `pull-models` | Download a curated set of Ollama models and grant access |
| `create-user` | Create a new Open WebUI account via API |
| `list-users` | List all Open WebUI users with their roles |
| `fix-model-access` | Grant all users wildcard read access to all models |
| `healthcheck` | Check all services are up, APIs respond, and disk is healthy |
| `backup` | Archive Open WebUI data and Cloudflare credentials to a tarball |
| `update` | Check current pinned versions against latest upstream releases |

Scripts that need admin credentials (`create-user`, `list-users`, `fix-model-access`) read them from environment variables, which are passed in by `make` via `podman exec -e`.

### Why scripts instead of Makefile targets?

Scripts that run *inside* the container (like `healthcheck`, `backup`) need to be part of the *image* so they are available in the container's filesystem. Makefile targets run on the *host* and use `podman exec` to call these scripts.

---

## 14. mise.toml — Toolchain Management

`mise` (formerly `rtx`) is a universal version manager — like `nvm` for Node, `pyenv` for Python, and `rbenv` for Ruby, but all in one tool.

`mise.toml` pins the versions of developer tools used in this project:

```toml
[tools]
node = "lts"
python = "3.13"
gh = "latest"
uv = "latest"
```

Inside the container, `mise` installs Node LTS (needed for Claude Code) and Python 3.13 into `~/.local/share/mise/shims/`, a directory added to `$PATH`. This keeps these tools completely separate from the system Python and Node, avoiding version conflicts.

The `eval "$(mise activate bash)"` line in `.bashrc` makes mise's shims work when you open a shell inside the container.

---

## 15. GitHub Actions — CI/CD

CI/CD stands for Continuous Integration / Continuous Deployment. In this project:
- **CI** = "every push runs a lint check."
- **CD** = "every push that changes the image automatically builds and publishes it."

### How a push triggers a build

```
git push origin main
    │
    ▼
GitHub detects a push to main
    │  checks: did any image-affecting files change?
    ▼
.github/workflows/build.yml triggers
    │
    ▼
GitHub spins up an ubuntu-latest runner (a temporary VM)
    │
    ├── Checkout code
    ├── Set up Docker Buildx (the build engine)
    ├── Log in to GHCR (GitHub Container Registry)
    ├── Build the image  ◄── uses registry cache for speed
    └── Push :latest + :sha tags to GHCR
```

### GHCR (GitHub Container Registry)

GHCR is GitHub's built-in container registry — like Docker Hub but integrated with your GitHub account. The image is stored at `ghcr.io/affragak/ai-boost:latest`. Anyone (or any CI runner) can pull it with `podman pull ghcr.io/affragak/ai-boost:latest`.

### Registry cache

Building a fresh image from scratch takes 30+ minutes (downloading the CUDA base image, installing Python packages). To avoid this on every push, the build is cached. We use **registry cache** stored in GHCR as `:buildcache` tag:

```yaml
cache-from: type=registry,ref=ghcr.io/affragak/ai-boost:buildcache
cache-to:   type=registry,ref=ghcr.io/affragak/ai-boost:buildcache,mode=min
```

On the second build, unchanged layers are pulled from cache instead of rebuilt. A typical rebuild of just one changed script takes 2–3 minutes instead of 30+.

### Concurrency control

```yaml
concurrency:
  group: build-${{ github.ref }}
  cancel-in-progress: true
```

If you push twice in quick succession, the first build is automatically cancelled when the second starts. This prevents an older build from overwriting `:latest` after a newer one already finished.

### Dependabot

`.github/dependabot.yml` auto-creates pull requests every week if any GitHub Action version is outdated. This keeps the CI pipeline itself updated without manual effort.

---

## 16. Systemd — Running on Boot

`systemd` is the Linux init system — the first process started by the kernel, responsible for booting the system and managing services. "User services" are systemd units that run as a regular user (not root) and start when that user's session is active.

### Why systemd instead of `@reboot` cron?

Systemd gives you:
- Dependency ordering (`After=network-online.target` — don't start until network is up).
- Automatic restarts, logging, and status queries.
- Clean stop on shutdown.

### The unit files

**`ai-boost.service`** — runs `podman-compose up -d` on start and `podman-compose down` on stop.
```ini
Type=oneshot
RemainAfterExit=yes
```
`oneshot` means systemd runs the command and waits for it to exit (unlike `simple` which expects a long-running foreground process). `RemainAfterExit=yes` means systemd considers the service "active" even after `podman-compose up -d` exits (the container is running in background).

**`ai-boost-backup.service`** — runs `make backup` (a one-shot job, not a daemon).

**`ai-boost-backup.timer`** — triggers the backup service daily at 03:00.

### Linger

`loginctl enable-linger $USER` is set by `make install-systemd`. Without linger, user systemd services only run while you are logged in. With linger enabled, they run from boot even when no one is logged in — making the container truly always-on.

---

## 17. The .github Folder

```
.github/
├── workflows/
│   ├── build.yml        # Build & push image to GHCR
│   └── lint.yml         # Run hadolint on every push
└── dependabot.yml       # Weekly Action version checks
```

**`lint.yml`** runs `hadolint` — a linter for Containerfiles. It checks for common mistakes: using `apt-get` without `--no-install-recommends`, pinning versions, etc. A failing lint check blocks the PR, catching issues before they get into the image.

---

## 18. Putting It All Together — The Startup Sequence

Here is exactly what happens when you run `make up` from scratch on a new machine:

```
make up
  └── podman-compose up -d
        │
        ├── Reads podman-compose.yml
        ├── Pulls ghcr.io/affragak/ai-boost:latest (if not already present)
        ├── Creates container "ai-boost"
        │    ├── Maps host ports 8080, 11434
        │    ├── Bind-mounts ~/.ollama, ~/.cloudflared, ~/.local/share/open-webui
        │    ├── Passes environment variables from .env
        │    └── Grants GPU access via CDI
        │
        └── Runs CMD: /usr/local/bin/entrypoint.sh
              │
              ├── chown bind-mounted directories → ubuntu:ubuntu
              │
              └── exec supervisord (becomes PID 1)
                    │
                    ├── priority 1 → start ollama serve
                    │       │  waits 5 seconds, checks it's still running
                    │       │  writes logs to /var/log/ollama.*
                    │
                    ├── priority 2 → start open-webui serve --port 8080
                    │       │  waits 10 seconds
                    │       │  reads WEBUI_SECRET_KEY from environment
                    │       │  connects to Ollama at 127.0.0.1:11434
                    │
                    └── priority 3 → start cloudflared tunnel run <TUNNEL_ID>
                            │  reads tunnel credentials from ~/.cloudflared/
                            │  establishes outbound tunnel to Cloudflare edge
```

At this point:
- `http://localhost:8080` serves the Open WebUI login page.
- `http://localhost:11434` serves the Ollama API.
- `https://your-tunnel-url.cloudflareaccess.com` reaches Open WebUI from anywhere.

---

## 19. Data Flow for "Where does my data live?"

| Data | Location on host | Location in container | Persists? |
|------|-----------------|----------------------|-----------|
| AI models | `~/.ollama/` | `/home/ubuntu/.ollama/` | ✅ Yes |
| Chat history, users | `~/.local/share/open-webui/` | `/home/ubuntu/.local/share/open-webui/` | ✅ Yes |
| Cloudflare tunnel credentials | `~/.cloudflared/` | `/home/ubuntu/.cloudflared/` | ✅ Yes |
| Logs | Inside container | `/var/log/*.log` | ❌ Lost on container delete |
| Secrets | `~/.env` / `~/.config/ai-boost/env` | passed as env vars | ✅ Yes |

---

## 20. Common Mental Models

**"Why is nothing working after I delete the container?"**
If your data directories (`~/.ollama`, `~/.local/share/open-webui`) still exist on the host, `make up` restores everything. The *container* is ephemeral; the *data* is not, because it lives on the host via bind mounts.

**"Why is there a separate .env and podman-compose.yml?"**
`podman-compose.yml` describes the *structure* (what ports, what volumes, what image) — it's safe to commit to git. `.env` holds *secrets* (passwords, keys) — it never goes to git. `podman-compose` merges them at runtime.

**"Why not just use one big process instead of supervisord?"**
Ollama, Open WebUI, and Cloudflared are independent programs written in Go and Python. They don't know about each other. Supervisord gives them a common lifecycle manager: start, stop, restart, log, and order them.

**"Why is Ollama priority 1?"**
Open WebUI tries to connect to Ollama at startup. If Ollama isn't ready yet, Open WebUI logs a warning and may not show models. Starting Ollama first (and waiting 5 seconds before starting Open WebUI) eliminates this race condition.

**"Why use GitHub Actions to build instead of building locally?"**
The CUDA base image is large and the pip install takes 20+ minutes on the first run. GitHub's runners have fast internet and can cache layers in GHCR. Once built, you pull a 2 GB image instead of building from scratch. You can also build on your phone, a server without Docker/Podman, or any machine with just `podman pull`.
