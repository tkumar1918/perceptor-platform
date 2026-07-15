# Perceptor Platform - Operator entrypoints.
COMPOSE := docker compose -f docker/docker-compose.yml
PY      := .venv/bin/python
PIP     := .venv/bin/pip

.DEFAULT_GOAL := help
.PHONY: help venv render up down reload bootstrap-orgs delete-tenant logs ps fmt-check

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

venv: ## Create local venv with PyYAML (for the renderer)
	@test -x $(PIP) || { rm -rf .venv && python3 -m venv .venv; }  # self-heal a missing/broken venv (e.g. one copied without pip)
	@$(PIP) install -q --upgrade pip pyyaml

render: venv ## Regenerate all per-tenant config from tenants.yaml
	@set -a; [ -f .env ] && . ./.env; set +a; $(PY) scripts/render.py   # .env feeds EDGE_HOST/GRAFANA_HOST/ACME_EMAIL into the Caddyfile

up: ## Start the whole stack (after `make render`)
	@test -f .env || { echo "Create .env from .env.example first"; exit 1; }
	@$(COMPOSE) --env-file .env up -d

down: ## Stop the stack (keeps volumes/data)
	@$(COMPOSE) down

reload: render ## Re-render config, apply compose changes (new services), and restart to pick it up
	@$(COMPOSE) --env-file .env up -d                        # create/recreate any new or changed services (e.g. alloy)
	@$(COMPOSE) --env-file .env restart caddy otel-collector mimir loki tempo grafana alloy  # re-read rendered/provisioned config

bootstrap-orgs: ## Create each project's Grafana org + tenant-pinned datasources (idempotent)
	@set -a; . ./.env; set +a; bash scripts/grafana-bootstrap.sh

delete-tenant: venv ## Fully remove a tenant: config + Grafana org + stale files (TENANT=<id>; PURGE_DATA=1 also wipes its S3 data)
	@test -n "$(TENANT)" || { echo "usage: make delete-tenant TENANT=<id> [PURGE_DATA=1] [YES=1]"; exit 1; }
	@set -a; . ./.env; set +a; PURGE_DATA="$(PURGE_DATA)" YES="$(YES)" bash scripts/delete-tenant.sh "$(TENANT)"

logs: ## Tail logs for all services
	@$(COMPOSE) logs -f --tail=100

ps: ## Show service status
	@$(COMPOSE) ps
