# Rotating WEBUI_SECRET_KEY

How to replace the Open WebUI JWT signing key without losing user accounts,
chat history, or any stored data.

---

## What `WEBUI_SECRET_KEY` does

Open WebUI uses `WEBUI_SECRET_KEY` to sign and verify JWT session tokens. It is
**not** used to encrypt data at rest — the database and uploaded files are stored
in plain form in `~/.local/share/open-webui`.

**Consequence of rotation:** all currently logged-in users will be signed out and
must log in again. No accounts, chats, settings, or files are deleted.

---

## When to rotate

- The key was accidentally committed to version control or logged
- A team member who knew the key has left
- As a routine security practice (e.g. annually)
- After restoring a backup to a new host (generate a fresh key for the new
  environment)

---

## Procedure

### 1. Generate a new key

```bash
openssl rand -hex 32
```

Copy the output — you will need it in the next step.

### 2. Update the key in your environment

Update wherever you persist the key (shell profile, secrets manager, `.env` file
outside the repo):

```bash
# Example: update ~/.bashrc or ~/.zshrc
# Replace the old export line with:
export WEBUI_SECRET_KEY=<new-key>
```

### 3. Restart the container

```bash
# Source your updated profile so the new value is in the shell
source ~/.bashrc  # or ~/.zshrc

# Restart the stack — no rebuild needed, this is runtime config only
podman-compose down
podman-compose up -d
```

The new key is picked up via the `podman-compose.yml` environment passthrough →
`entrypoint.sh` → `exec sudo WEBUI_SECRET_KEY=... supervisord` →
`%(ENV_WEBUI_SECRET_KEY)s` in `supervisord/open-webui.conf`.

### 4. Verify

```bash
podman exec -it ai-boost healthcheck
# open-webui should be RUNNING
```

Open WebUI at http://localhost:8080 — all users will need to log in again.

---

## What is NOT affected

| Data | Affected by rotation? |
|------|-----------------------|
| User accounts | ❌ No |
| Passwords | ❌ No (hashed independently) |
| Chat history | ❌ No |
| Uploaded files | ❌ No |
| RAG vector DB | ❌ No |
| Model settings | ❌ No |
| Active sessions / tokens | ✅ Yes — all sessions invalidated |

---

## Key persistence across restarts

The key **must be the same on every restart** of the container. If the variable
is not set or changes unexpectedly, all sessions are invalidated and users must
log in again. If the variable is empty, Open WebUI refuses to start entirely
(see [troubleshooting.md](troubleshooting.md) — failure mode #1).

Recommended storage options (in order of preference):

1. **Shell profile** (`~/.bashrc` / `~/.zshrc`) — simple, survives reboots
2. **systemd environment file** — cleaner for server setups
3. **A password manager** — copy-paste when needed

Never store it in any file tracked by git.
