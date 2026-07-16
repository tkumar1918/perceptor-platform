# Perceptor Platform - Operator entrypoints.
# --env-file is part of COMPOSE itself so EVERY target interpolates the S3_*
# vars — the compose file's ${VAR:?} guards fail any invocation that skips it
# (that mistake once recreated mimir/loki with empty storage config).
COMPOSE := docker compose -f docker/docker-compose.yml --env-file .env
PY      := .venv/bin/python
PIP     := .venv/bin/pip

.DEFAULT_GOAL := help
.PHONY: help venv render up down reload bootstrap-orgs delete-tenant logs ps fmt-check fix-perms

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

venv: ## Create local venv with PyYAML (for the renderer)
	@test -x $(PIP) || { rm -rf .venv && python3 -m venv .venv; }  # self-heal a missing/broken venv (e.g. one copied without pip)
	@$(PIP) install -q --upgrade pip pyyaml

render: venv ## Regenerate all per-tenant config from tenants.yaml
	@set -a; [ -f .env ] && . ./.env; set +a; $(PY) scripts/render.py   # .env feeds EDGE_HOST/GRAFANA_HOST/ACME_EMAIL into the Caddyfile

# .env and the rendered Caddyfile both hold secrets (Grafana admin password;
# every tenant's ingest token). Self-heal their modes on every apply so a
# loose copy/edit can't leave them world-readable.
fix-perms:
	@chmod 600 .env 2>/dev/null || true
	@chmod 600 docker/caddy/Caddyfile 2>/dev/null || true
	@chmod 600 tenants.secrets.yaml 2>/dev/null || true

up: fix-perms ## Start the whole stack (after `make render`)
	@test -f .env || { echo "Create .env from .env.example first"; exit 1; }
	@$(COMPOSE) up -d

down: ## Stop the stack (keeps volumes/data)
	@$(COMPOSE) down

reload: render fix-perms ## Re-render config, apply compose changes, restart, and re-import dashboards into every project org
	@$(COMPOSE) up -d                        # create/recreate any new or changed services (e.g. alloy)
	@$(COMPOSE) restart caddy otel-collector mimir loki tempo grafana alloy  # re-read rendered/provisioned config
	@$(MAKE) --no-print-directory bootstrap-orgs             # dashboards are config too — see why this is NOT optional, below

# Why reload must end in bootstrap-orgs: only the ADMIN org (1) is file-provisioned
# from docker/grafana/dashboards (Grafana rescans it every 30s). Project orgs are
# created at runtime, so file provisioning cannot reach them — they hold copies
# API-imported by grafana-bootstrap.sh. Without this line a dashboard fix goes live
# in the admin org and stays SILENTLY STALE in every project org, which is where
# people actually look. The import is overwrite=true and the whole script is
# idempotent (existing orgs/datasources just 409), so re-running it is safe and
# cheap. It waits for Grafana's /api/health, so running it right after the restart
# above is fine.

bootstrap-orgs: ## Create each project's Grafana org + tenant-pinned datasources, and import dashboards (idempotent)
	@set -a; . ./.env; set +a; bash scripts/grafana-bootstrap.sh

delete-tenant: venv ## Fully remove a tenant: config + Grafana org + stale files (TENANT=<id>; PURGE_DATA=1 also wipes its S3 data)
	@test -n "$(TENANT)" || { echo "usage: make delete-tenant TENANT=<id> [PURGE_DATA=1] [YES=1]"; exit 1; }
	@set -a; . ./.env; set +a; PURGE_DATA="$(PURGE_DATA)" YES="$(YES)" bash scripts/delete-tenant.sh "$(TENANT)"

logs: ## Tail logs for all services
	@$(COMPOSE) logs -f --tail=100

ps: ## Show service status
	@$(COMPOSE) ps
