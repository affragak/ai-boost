CONTAINER := ai-boost

# Load .env automatically if present — no need to source it manually.
# Shell-exported vars take precedence over .env values.
# Note: values containing $ must be escaped as $$ in .env for Make compatibility.
ifneq (,$(wildcard .env))
  -include .env
  export
endif

.DEFAULT_GOAL := help

.PHONY: help up down build rebuild pull logs logs-webui logs-ollama logs-cloudflared shell status \
        pull-models pull-model model-remove models healthcheck backup \
        fix-model-access create-user list-users update \
        install-systemd uninstall-systemd

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Container lifecycle ────────────────────────────────────────────────────────

up: ## Start the container (detached)
	podman-compose up -d

down: ## Stop and remove the container
	podman-compose down

build: ## Build the image without starting
	podman-compose build

pull: ## Pull the latest pre-built image from GHCR (faster than building locally)
	podman pull ghcr.io/affragak/ai-boost:latest

rebuild: ## Stop, rebuild image locally, and start (full cycle)
	podman-compose down
	podman-compose up --build -d

# ── Observability ──────────────────────────────────────────────────────────────

status: ## Show supervisord service status inside the container
	podman exec -it $(CONTAINER) sudo supervisorctl status

logs: ## Tail all service logs combined (Ctrl+C to stop)
	podman exec -it $(CONTAINER) tail -f \
		/var/log/ollama.err \
		/var/log/open-webui.log \
		/var/log/cloudflared.log

logs-webui: ## Tail Open WebUI logs
	podman exec -it $(CONTAINER) tail -f /var/log/open-webui.log

logs-ollama: ## Tail Ollama logs
	podman exec -it $(CONTAINER) tail -f /var/log/ollama.err

logs-cloudflared: ## Tail Cloudflared logs
	podman exec -it $(CONTAINER) tail -f /var/log/cloudflared.log

shell: ## Open a bash shell inside the container
	podman exec -it $(CONTAINER) bash

healthcheck: ## Run the full health check script
	podman exec -it $(CONTAINER) healthcheck

# ── Model management ──────────────────────────────────────────────────────────

pull-models: ## Pull configured Ollama models
	podman exec -it $(CONTAINER) pull-models

# Usage: make pull-model MODEL=llama3:8b
pull-model: ## Pull a single Ollama model (MODEL=name:tag required)
	@test -n "$(MODEL)" || (echo "ERROR: MODEL is not set  e.g. make pull-model MODEL=llama3:8b" && exit 1)
	podman exec -it $(CONTAINER) ollama pull $(MODEL)

# Usage: make model-remove MODEL=llava:7b
model-remove: ## Remove an installed Ollama model (MODEL=name:tag required)
	@test -n "$(MODEL)" || (echo "ERROR: MODEL is not set  e.g. make model-remove MODEL=llava:7b" && exit 1)
	podman exec -it $(CONTAINER) ollama rm $(MODEL)

models: ## List installed Ollama models
	podman exec -it $(CONTAINER) ollama list

fix-model-access: ## Grant all users read access to all models
	@test -n "$(OPENWEBUI_ADMIN_EMAIL)"    || (echo "ERROR: OPENWEBUI_ADMIN_EMAIL is not set"    && exit 1)
	@test -n "$(OPENWEBUI_ADMIN_PASSWORD)" || (echo "ERROR: OPENWEBUI_ADMIN_PASSWORD is not set" && exit 1)
	podman exec \
		-e OPENWEBUI_ADMIN_EMAIL="$(OPENWEBUI_ADMIN_EMAIL)" \
		-e OPENWEBUI_ADMIN_PASSWORD="$(OPENWEBUI_ADMIN_PASSWORD)" \
		$(CONTAINER) fix-model-access

# ── User management ───────────────────────────────────────────────────────────

# Usage: make create-user NAME="Alice" EMAIL="alice@example.com" PASSWORD="secret"
#        Optionally: ADMIN_EMAIL=... ADMIN_PASSWORD=... (defaults to env vars)
create-user: ## Create a new Open WebUI user (NAME, EMAIL, PASSWORD required)
	@test -n "$(NAME)"     || (echo "ERROR: NAME is not set"     && exit 1)
	@test -n "$(EMAIL)"    || (echo "ERROR: EMAIL is not set"    && exit 1)
	@test -n "$(PASSWORD)" || (echo "ERROR: PASSWORD is not set" && exit 1)
	@test -n "$(ADMIN_EMAIL)"    || (echo "ERROR: ADMIN_EMAIL is not set (or OPENWEBUI_ADMIN_EMAIL)"    && exit 1)
	@test -n "$(ADMIN_PASSWORD)" || (echo "ERROR: ADMIN_PASSWORD is not set (or OPENWEBUI_ADMIN_PASSWORD)" && exit 1)
	podman exec \
		-e OPENWEBUI_ADMIN_EMAIL="$(or $(ADMIN_EMAIL),$(OPENWEBUI_ADMIN_EMAIL))" \
		-e OPENWEBUI_ADMIN_PASSWORD="$(or $(ADMIN_PASSWORD),$(OPENWEBUI_ADMIN_PASSWORD))" \
		-e NEW_USER_NAME="$(NAME)" \
		-e NEW_USER_EMAIL="$(EMAIL)" \
		-e NEW_USER_PASSWORD="$(PASSWORD)" \
		$(CONTAINER) create-user

# ── Data management ───────────────────────────────────────────────────────────

backup: ## Backup Open WebUI data and Cloudflare credentials
	podman exec -it $(CONTAINER) backup

list-users: ## List all Open WebUI users and their roles
	@test -n "$(OPENWEBUI_ADMIN_EMAIL)"    || (echo "ERROR: OPENWEBUI_ADMIN_EMAIL is not set"    && exit 1)
	@test -n "$(OPENWEBUI_ADMIN_PASSWORD)" || (echo "ERROR: OPENWEBUI_ADMIN_PASSWORD is not set" && exit 1)
	podman exec \
		-e OPENWEBUI_ADMIN_EMAIL="$(OPENWEBUI_ADMIN_EMAIL)" \
		-e OPENWEBUI_ADMIN_PASSWORD="$(OPENWEBUI_ADMIN_PASSWORD)" \
		$(CONTAINER) list-users

update: ## Check pinned versions against latest upstream releases
	@bash scripts/update

# ── Systemd integration ───────────────────────────────────────────────────────

install-systemd: ## Install systemd user service + daily backup timer (run with env vars set)
	@# Source .env if present and vars not already set in environment
	@if [ -f .env ]; then \
		export $$(grep -v '^\s*#' .env | grep -v '^\s*$$' | xargs) 2>/dev/null; \
	fi; \
	test -n "$$WEBUI_SECRET_KEY"      || (echo "ERROR: WEBUI_SECRET_KEY is not set (set in .env or export it)"      && exit 1); \
	test -n "$$CLOUDFLARED_TUNNEL_ID" || (echo "ERROR: CLOUDFLARED_TUNNEL_ID is not set (set in .env or export it)" && exit 1); \
	echo "Writing environment file to ~/.config/ai-boost/env ..."; \
	mkdir -p $(HOME)/.config/ai-boost; \
	printf 'WEBUI_SECRET_KEY=%s\nCLOUDFLARED_TUNNEL_ID=%s\nANTHROPIC_API_KEY=%s\nMISE_GITHUB_TOKEN=%s\n' \
		"$$WEBUI_SECRET_KEY" \
		"$$CLOUDFLARED_TUNNEL_ID" \
		"$$ANTHROPIC_API_KEY" \
		"$$MISE_GITHUB_TOKEN" \
		> $(HOME)/.config/ai-boost/env; \
	chmod 600 $(HOME)/.config/ai-boost/env; \
	echo "Installing systemd unit files ..."; \
	mkdir -p $(HOME)/.config/systemd/user; \
	sed 's|REPO_PATH|$(CURDIR)|g' systemd/ai-boost.service \
		> $(HOME)/.config/systemd/user/ai-boost.service; \
	sed 's|REPO_PATH|$(CURDIR)|g' systemd/ai-boost-backup.service \
		> $(HOME)/.config/systemd/user/ai-boost-backup.service; \
	cp systemd/ai-boost-backup.timer $(HOME)/.config/systemd/user/ai-boost-backup.timer; \
	systemctl --user daemon-reload; \
	systemctl --user enable --now ai-boost.service; \
	systemctl --user enable --now ai-boost-backup.timer; \
	loginctl enable-linger $(USER); \
	echo ""; \
	echo "Done. Container will now start automatically on boot."; \
	echo "Run 'systemctl --user status ai-boost' to verify."

uninstall-systemd: ## Remove systemd user service and backup timer
	@systemctl --user disable --now ai-boost.service       2>/dev/null || true
	@systemctl --user disable --now ai-boost-backup.timer  2>/dev/null || true
	@rm -f $(HOME)/.config/systemd/user/ai-boost.service
	@rm -f $(HOME)/.config/systemd/user/ai-boost-backup.service
	@rm -f $(HOME)/.config/systemd/user/ai-boost-backup.timer
	@systemctl --user daemon-reload
	@echo "Systemd units removed."
