# Reliability: What We Did and Why

A walkthrough of the three reliability improvements added to ai-boost, written for someone new to Linux service management.

---

## 1. Log Rotation (supervisord)

### The problem

Every service in this container — Ollama, Open WebUI, Cloudflared — writes output to log files at `/var/log/`. Without any limit, these files grow indefinitely. On a machine running 24/7 with a chatty service like Open WebUI, you can easily fill a disk over weeks or months.

### How supervisord handles it

supervisord (the process manager inside the container) has built-in log rotation. Two settings control it per service:

| Setting | Meaning |
|---------|---------|
| `stdout_logfile_maxbytes` | Rotate the log file once it reaches this size |
| `stdout_logfile_backups` | How many rotated copies to keep before deleting the oldest |

We already had `maxbytes=5MB` set. What was missing was an explicit `backups` value — supervisord defaults to **10 backups**, meaning it could silently accumulate up to 50 MB per log stream.

### What we changed

Added `stdout_logfile_backups=3` and `stderr_logfile_backups=3` to all three supervisord configs (`ollama.conf`, `open-webui.conf`, `cloudflared.conf`).

**Result:** each log stream is now capped at 3 × 5 MB = **15 MB**. With 2 streams (stdout + stderr) per service and 3 services, the maximum total log footprint is **~90 MB** — predictable and bounded.

### Files changed

- `supervisord/ollama.conf`
- `supervisord/open-webui.conf`
- `supervisord/cloudflared.conf`

---

## 2. Auto-start on Boot (systemd user service)

### The problem

Without this, every time you reboot your machine you have to manually `cd` into the repo and run `make up`. If you forget, the AI workstation is silently down.

### What systemd is

systemd is the init system on most modern Linux distributions — it's PID 1, the first process that starts when the OS boots. It manages all services: starting them in the right order, restarting them if they crash, and running them automatically at boot.

There are two kinds of systemd services:
- **System services** — run as root, managed in `/etc/systemd/system/`
- **User services** — run as your own user, managed in `~/.config/systemd/user/`

Since we use rootless Podman (no root required), a **user service** is the right fit.

### The `enable-linger` requirement

By default, user systemd services only run while you're logged in. When you log out, they stop. For a server that should keep running after you close your SSH session, you need:

```bash
loginctl enable-linger <username>
```

This tells systemd to keep your user's service manager running even when you're not logged in — effectively making your user services behave like system services.

### How the service works

`systemd/ai-boost.service` uses `Type=oneshot` with `RemainAfterExit=yes`. This is the standard pattern for services that launch a background process and then exit:

```
ExecStart  →  runs `podman-compose up -d`  →  exits immediately (container stays up)
RemainAfterExit=yes  →  systemd considers the service "active" even after ExecStart exits
ExecStop   →  runs `podman-compose down`   →  stops the container on `systemctl stop`
```

Without `RemainAfterExit=yes`, systemd would see ExecStart exit and mark the service as "failed".

### The environment file

The service needs your secrets (WEBUI_SECRET_KEY, CLOUDFLARED_TUNNEL_ID, etc.) but systemd doesn't inherit your shell environment. The solution is an `EnvironmentFile`:

```ini
EnvironmentFile=%h/.config/ai-boost/env
```

`%h` is systemd's shorthand for your home directory. The file format is one `KEY=VALUE` per line, and the file is created by `make install-systemd` from the env vars currently set in your shell. It's stored with `chmod 600` so only you can read it.

### The WorkingDirectory substitution

`podman-compose` needs to run from the repo directory (to find `podman-compose.yml`). But the repo could be cloned anywhere, so the unit file contains a placeholder:

```ini
WorkingDirectory=REPO_PATH
```

`make install-systemd` substitutes `REPO_PATH` with the actual current directory (`$(CURDIR)` in make) using `sed`, then writes the result to `~/.config/systemd/user/ai-boost.service`.

### Installing

```bash
# With all env vars set in your shell:
make install-systemd
```

### Verifying

```bash
systemctl --user status ai-boost          # should show "active (exited)"
systemctl --user is-enabled ai-boost      # should print "enabled"
loginctl show-user $USER | grep Linger    # should print "Linger=yes"
```

### Files added

- `systemd/ai-boost.service` — the unit template
- `Makefile` — `install-systemd` and `uninstall-systemd` targets

---

## 3. Daily Automated Backups (systemd timer)

### The problem

`make backup` exists but requires you to remember to run it. Important data (Open WebUI accounts, chat history, Cloudflare credentials) should be backed up automatically without relying on human memory.

### Why a systemd timer instead of cron

Both cron and systemd timers can schedule jobs. systemd timers have two advantages here:

1. **Catchup on missed runs** — if the machine was off at 03:00, cron silently skips the job. With `Persistent=true`, the timer runs the job on the next boot instead.
2. **Consistency** — since we're already using systemd for the service, using a timer keeps everything in one place. You can inspect it with standard `systemctl` and `journalctl` commands.

### How a systemd timer works

A timer is a pair of two unit files:

| File | Role |
|------|------|
| `ai-boost-backup.timer` | Defines *when* to run (schedule) |
| `ai-boost-backup.service` | Defines *what* to run (the command) |

The timer activates the `.service` file on schedule. The `.service` is a `Type=oneshot` unit — it runs once, exits, and systemd records whether it succeeded or failed.

### The schedule

```ini
OnCalendar=*-*-* 03:00:00
Persistent=true
RandomizedDelaySec=30min
```

- `OnCalendar=*-*-* 03:00:00` — every day at 03:00 local time
- `Persistent=true` — if a run was missed (machine was off), run on next boot
- `RandomizedDelaySec=30min` — adds a random 0–30 min delay; harmless here but good practice on shared infrastructure to avoid all machines hitting the same service simultaneously

### What gets backed up

`make backup` runs the `backup` script inside the container, which archives:
- `~/.local/share/open-webui` — user accounts, chat history, vector DB, uploaded files
- `~/.cloudflared` — Cloudflare tunnel credentials

Ollama model weights (`~/.ollama`) are **not** backed up — they're large (~40 GB) and can be re-downloaded with `make pull-models`.

Backups land in `~/backups/` on the host as timestamped `.tar.gz` files.

### Viewing backup history

```bash
# List backup files
ls -lh ~/backups/

# Check timer status and next run time
systemctl --user status ai-boost-backup.timer

# See logs from past backup runs
journalctl --user -u ai-boost-backup.service
```

### Files added

- `systemd/ai-boost-backup.service` — the backup job unit
- `systemd/ai-boost-backup.timer` — the daily schedule

---

## Summary

| Area | What changed | Max impact |
|------|-------------|------------|
| Log rotation | `backups=3` in all supervisord confs | Logs capped at ~90 MB total |
| Auto-start | User systemd service + linger | Container survives reboots without intervention |
| Backup scheduling | Systemd timer at 03:00 daily | Data protected automatically; missed runs caught on next boot |

All three are installed in one step:

```bash
make install-systemd
```
