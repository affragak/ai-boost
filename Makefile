CONTAINER := ai-boost

.DEFAULT_GOAL := help

.PHONY: help up down build rebuild logs shell status \
        pull-models healthcheck backup \
        fix-model-access create-user

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Container lifecycle ────────────────────────────────────────────────────────

up: ## Start the container (detached)
	podman-compose up -d

down: ## Stop and remove the container
	podman-compose down

build: ## Build the image without starting
	podman-compose build

rebuild: ## Stop, rebuild image, and start (full cycle)
	podman-compose down
	podman-compose up --build -d

# ── Observability ──────────────────────────────────────────────────────────────

status: ## Show supervisord service status inside the container
	podman exec -it $(CONTAINER) sudo supervisorctl status

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
