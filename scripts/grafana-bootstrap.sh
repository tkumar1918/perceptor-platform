#!/usr/bin/env bash
# ============================================================================
# Create one Grafana Org per project AND its tenant-pinned datasources, via the
# Grafana HTTP API. Idempotent — safe to re-run.
#
# Why API and not file provisioning: Grafana hard-fails at boot if a datasource
# or dashboard provider names an org that doesn't exist, and orgs can only be
# created once Grafana is running. So orgs + their datasources are created here,
# after Grafana is up. Org IDs are positional, so orgs are created in the same
# order as tenants.yaml on a fresh Grafana.
#
# Run after `make up`:  make bootstrap-orgs
# ============================================================================
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3001}"
ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
ADMIN_PASS="${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ORGS_FILE="$HERE/.orgs"
BOOTSTRAP_DIR="$HERE/../docker/grafana/bootstrap"
DASH_FILE="$HERE/../docker/grafana/dashboards/infra.json"

[[ -f "$ORGS_FILE" ]] || { echo "Run 'make render' first (missing scripts/.orgs)"; exit 1; }
auth=(-fsS -u "${ADMIN_USER}:${ADMIN_PASS}")

# The shared infra dashboard is FILE-provisioned into the admin org (org 1)
# automatically. Project orgs are created here at runtime, so file provisioning
# can't reach them — we import the same dashboard into each via the API below.
# It's portable: datasource template variables bind to each org's own Mimir/Loki,
# so one JSON serves every tenant. (No-op if the file is absent.)
DASH_PAYLOAD=""
if [[ -f "$DASH_FILE" ]]; then
  DASH_PAYLOAD="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["id"]=None; print(json.dumps({"dashboard":m,"overwrite":True,"folderId":0}))' "$DASH_FILE")"
fi

# Wait for Grafana to be reachable.
until curl -fsS -o /dev/null "${GRAFANA_URL}/api/health" 2>/dev/null; do
  echo "waiting for Grafana at ${GRAFANA_URL} ..."; sleep 2
done

while IFS='|' read -r org_id id display_name; do
  [[ -z "$org_id" ]] && continue

  # 1) Create the org (idempotent).
  if curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" "${GRAFANA_URL}/api/orgs/${org_id}" | grep -q '"id"'; then
    echo "org ${org_id} (${id}) exists"
  else
    new_id=$(curl "${auth[@]}" -H 'Content-Type: application/json' \
      -d "{\"name\":\"${display_name}\"}" "${GRAFANA_URL}/api/orgs" \
      | grep -o '"orgId":[0-9]*' | grep -o '[0-9]*' || true)
    if [[ "$new_id" != "$org_id" ]]; then
      echo "ERROR: created '${display_name}' got org id ${new_id}, expected ${org_id}."
      echo "       Orgs must be created in tenants.yaml order on a fresh Grafana."
      exit 1
    fi
    echo "created org ${org_id} (${id})"
  fi

  # 2) Add admin to the org (creating an org doesn't auto-add the creator),
  #    then point the admin's active org at it, then create its datasources.
  curl -s -o /dev/null -u "${ADMIN_USER}:${ADMIN_PASS}" -H 'Content-Type: application/json' \
    -d "{\"loginOrEmail\":\"${ADMIN_USER}\",\"role\":\"Admin\"}" \
    "${GRAFANA_URL}/api/orgs/${org_id}/users" || true   # 409 if already a member
  curl "${auth[@]}" -o /dev/null -X POST "${GRAFANA_URL}/api/user/using/${org_id}"
  while IFS= read -r ds; do
    [[ -z "$ds" ]] && continue
    name=$(echo "$ds" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "${ADMIN_USER}:${ADMIN_PASS}" \
      -H 'Content-Type: application/json' -d "$ds" "${GRAFANA_URL}/api/datasources")
    case "$code" in
      200|409) echo "  org ${org_id}: datasource ${name} ok (${code})" ;;
      *)       echo "  org ${org_id}: datasource ${name} FAILED (${code})"; exit 1 ;;
    esac
  done < "${BOOTSTRAP_DIR}/${id}.ndjson"

  # 3) Import the shared infra dashboard into THIS org (active org is set above).
  #    Non-fatal: a dashboard hiccup shouldn't abort org/datasource provisioning.
  if [[ -n "$DASH_PAYLOAD" ]]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "${ADMIN_USER}:${ADMIN_PASS}" \
      -H 'Content-Type: application/json' -d "$DASH_PAYLOAD" "${GRAFANA_URL}/api/dashboards/db")
    case "$code" in
      200) echo "  org ${org_id}: infra dashboard imported" ;;
      *)   echo "  org ${org_id}: infra dashboard import WARN (${code})" ;;
    esac
  fi
done < "$ORGS_FILE"

# Restore the admin session to org 1.
curl "${auth[@]}" -o /dev/null -X POST "${GRAFANA_URL}/api/user/using/1" || true
echo "Done. Each project now has an isolated org with tenant-pinned datasources."
