# Perceptor Platform - Operator entrypoints.
COMPOSE := docker compose -f docker/docker-compose.yml
PY      := .venv/bin/python
PIP     := .venv/bin/pip

.DEFAULT_GOAL := help
.PHONY: help venv render up down reload bootstrap-orgs logs ps fmt-check

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

venv: ## Create local venv with PyYAML (for the renderer)
	@test -x $(PIP) || { rm -rf .venv && python3 -m venv .venv; }  # self-heal a missing/broken venv (e.g. one copied without pip)
	@$(PIP) install -q --upgrade pip pyyaml

render: venv ## Regenerate all per-tenant config from tenants.yaml
	@$(PY) scripts/render.py

up: ## Start the whole stack (after `make render`)
	@test -f .env || { echo "Create .env from .env.example first"; exit 1; }
	@$(COMPOSE) --env-file .env up -d

down: ## Stop the stack (keeps volumes/data)
	@$(COMPOSE) down

reload: render ## Re-render config and restart edge + backends to pick it up
	@$(COMPOSE) --env-file .env restart caddy otel-collector mimir loki tempo grafana

bootstrap-orgs: ## Create each project's Grafana org + tenant-pinned datasources (idempotent)
	@set -a; . ./.env; set +a; bash scripts/grafana-bootstrap.sh

logs: ## Tail logs for all services
	@$(COMPOSE) logs -f --tail=100

ps: ## Show service status
	@$(COMPOSE) ps
