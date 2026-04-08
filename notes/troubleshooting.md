# Troubleshooting ai-boost

Common failure modes and how to resolve them.

---

## 1. Open WebUI fails to start — `WEBUI_SECRET_KEY` missing

**Symptom**

```
podman exec -it ai-boost sudo supervisorctl status
open-webui    FATAL   Exited too quickly (process log may have details)
```

```
tail -20 /var/log/open-webui.err
ValueError: Required environment variable not found. Terminating now.
```

**Cause**

Open WebUI 0.8+ hard-requires `WEBUI_SECRET_KEY` when authentication is enabled
(`WEBUI_AUTH=true`). If the variable is empty or not exported on the host before
`podman-compose up`, the process crashes immediately.

**Fix**

```bash
# On the host, generate a key (only needed once — save it permanently)
export WEBUI_SECRET_KEY=$(openssl rand -hex 32)

# Restart the stack so the new value is picked up
podman-compose up -d
```

> **Important:** use the same key on every restart. Changing it invalidates all
> existing user sessions and forces everyone to log in again. Save it in your shell
> profile (e.g. `~/.bashrc` or `~/.zshrc`) or a secrets manager.

---

## 2. Container name conflict — `ai_ai_1` vs `ai-boost`

**Symptom**

```
podman-compose down
# or
podman-compose up -d
Error: no container with name or id "ai-boost" found
```

Or you find two containers running: the old `ai_ai_1` and the new `ai-boost`.

**Cause**

podman-compose names containers `{project}_{service}_{index}` by default. Before
`container_name: ai-boost` was added to `podman-compose.yml`, the container was
named `ai_ai_1`. If the old container is still present, the new one cannot start.

**Fix**

```bash
# Stop and remove the old container by its actual name
podman stop ai_ai_1
podman rm ai_ai_1

# Now start fresh
podman-compose up -d
```

---

## 3. Bind mount permission errors — Open WebUI data not writable

**Symptom**

Open WebUI starts but immediately logs permission errors, or the database cannot
be created:

```
PermissionError: [Errno 13] Permission denied: '/home/ubuntu/.local/share/open-webui/...'
```

**Cause**

Rootless Podman maps UIDs differently from Docker:

| Inside container | On host |
|-----------------|---------|
| `root` (UID 0) | host user (e.g. `antonis`, UID 1000) |
| `ubuntu` (UID 1000) | subordinate UID (~100999) |

Files created on the host by `antonis` (UID 1000) appear as `root` inside the
container — not as `ubuntu`. The `ubuntu` process running Open WebUI cannot write
to them.

**Fix**

Use `podman unshare` to apply the correct UID mapping from the host side:

```bash
podman unshare chown -R 1000:1000 ~/.local/share/open-webui
```

This is a one-time step after first creating or copying the data directory.
The `entrypoint.sh` also runs `chown ubuntu:ubuntu` on every container start,
which covers the common case of the directory already existing with correct
subordinate UIDs.

**Verify**

```bash
# Inside the container, the directory should be owned by ubuntu
podman exec -it ai-boost ls -la /home/ubuntu/.local/share/ | grep open-webui
# Expected: drwxr-xr-x ... ubuntu ubuntu ... open-webui
```

---

## 4. Cloudflared tunnel not connecting

**Symptom**

`supervisorctl status` shows `cloudflared RUNNING` but the public URL returns
an error or times out.

**Cause — missing tunnel ID**

`CLOUDFLARED_TUNNEL_ID` was not exported before `podman-compose up`.

**Fix**

```bash
export CLOUDFLARED_TUNNEL_ID=<your-tunnel-uuid>
podman-compose up -d
```

Find your tunnel UUID:
```bash
# On the host (requires cloudflared installed)
cloudflared tunnel list

# Or check ~/.cloudflared/config.yml
```

**Cause — missing credentials**

The `~/.cloudflared` directory on the host is empty or does not contain the
tunnel credentials JSON file.

**Fix**

Follow Cloudflare's [tunnel setup guide](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/)
to create a tunnel and download its credentials. The resulting files go in
`~/.cloudflared/` on the host, which is bind-mounted into the container.

---

## 5. Models visible to admin but not to regular users

**Symptom**

A user with the `user` role logs in to Open WebUI but sees no models in the
selector.

**Cause**

Open WebUI 0.8 requires explicit access grants in its database. Ollama models
with no DB entry are visible to admins only. An empty grant list also hides
models from regular users.

**Fix**

```bash
podman exec -e OPENWEBUI_ADMIN_EMAIL=admin@example.com \
            -e OPENWEBUI_ADMIN_PASSWORD=yourpassword \
            ai-boost fix-model-access
```

Run this after every `pull-models` call (or use admin env vars with `pull-models`
so it runs automatically). See
[`notes/open-webui-model-access.md`](open-webui-model-access.md) for the full
technical explanation.

---

## 6. Rebuild uses cached layers despite code changes

**Symptom**

`podman-compose up --build -d` reports `Using cache` for every step and the
running container does not pick up your script changes.

**Cause**

Podman caches each `RUN`/`COPY` layer. If the files being copied have not changed
on disk, the cache hit is correct. If the running container was started from the
old image before the build, it also needs to be replaced.

**Fix**

```bash
# Stop and remove the current container, then rebuild
podman-compose down
podman-compose up --build -d
```

If you need to force a full rebuild (e.g. to pick up a new OS package version):

```bash
podman-compose build --no-cache
podman-compose up -d
```
