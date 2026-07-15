#!/usr/bin/env bash
# ============================================================================
# Create one Grafana Org per project AND its tenant-pinned datasources, via the
# Grafana HTTP API. Idempotent — safe to re-run.
#
# Why API and not file provisioning: Grafana hard-fails at boot if a datasource
# or dashboard provider names an org that doesn't exist, and orgs can only be
# created once Grafana is running. So orgs + their datasources are created here,
# after Grafana is up.
#
# Orgs are resolved BY NAME (display_name), not by the org_id in tenants.lock.yaml.
# Grafana auto-increments org ids and won't let us pick one, so we look up (or
# create) each org by name and use whatever real id Grafana assigns. That makes
# provisioning robust to a gap or drift in the allocated org_id — nothing here
# asserts that Grafana's number matches ours.
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
#
# GROUPED tenants (group set in tenants.yaml) get a VARIANT instead: on a shared
# VM the agent pushes infra to the group's _infra-<group> tenant, NOT the
# project's own — so the normal dashboard, which defaults to the org's default
# (app) datasources, would render empty. The variant is derived from the same
# infra.json (single source of truth, nothing to drift): the mimir/loki
# datasource picker variables are dropped and every reference is pinned to the
# uids of the org's group-infra pair (mimir-infra / loki-infra — fixed per org,
# see render.py). Same dashboard uid, so the URL is identical either way.

DASH_PAYLOAD=""
DASH_PAYLOAD_GROUPED=""
if [[ -f "$DASH_FILE" ]]; then
  DASH_PAYLOAD="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["id"]=None; print(json.dumps({"dashboard":m,"overwrite":True,"folderId":0}))' "$DASH_FILE")"
  DASH_PAYLOAD_GROUPED="$(python3 - "$DASH_FILE" <<'PYEOF'
import json, sys

m = json.load(open(sys.argv[1]))
m["id"] = None

# Drop the datasource pickers; pin every ${mimir}/${loki} reference instead.
tpl = m.get("templating", {}).get("list")
if tpl is not None:
    m["templating"]["list"] = [
        v for v in tpl
        if not (v.get("type") == "datasource" and v.get("name") in ("mimir", "loki"))
    ]

PIN = {"${mimir}": "mimir-infra", "${loki}": "loki-infra"}

def walk(o):
    if isinstance(o, dict):
        return {k: walk(v) for k, v in o.items()}
    if isinstance(o, list):
        return [walk(v) for v in o]
    return PIN.get(o, o) if isinstance(o, str) else o

print(json.dumps({"dashboard": walk(m), "overwrite": True, "folderId": 0}))
PYEOF
)"
fi

# Wait for Grafana to be reachable.
until curl -fsS -o /dev/null "${GRAFANA_URL}/api/health" 2>/dev/null; do
  echo "waiting for Grafana at ${GRAFANA_URL} ..."; sleep 2
done

# .orgs fields: org_id|id|group|display_name — display_name LAST because it may
# itself contain '|' (read folds the remainder of the line into the final var).
while IFS='|' read -r org_id id group display_name; do
  [[ -z "$id" ]] && continue

  # 1) Resolve the org BY NAME, capturing the real id Grafana assigned (create on
  #    404). We never assume Grafana's number matches org_id from the lock — so a
  #    gap or drift in the allocated id can't break provisioning. Exact single
  #    lookup (GET /api/orgs/name/:name), so no listing / 1000-org pagination cap.
  #    Name is URL-encoded for the path; the create body is built with json.dumps
  #    so quotes/backslashes in a display_name can't corrupt the JSON.
  enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$display_name")
  resp=$(curl -sS -u "${ADMIN_USER}:${ADMIN_PASS}" -w $'\n%{http_code}' \
    "${GRAFANA_URL}/api/orgs/name/${enc}")
  code=${resp##*$'\n'}; body=${resp%$'\n'*}
  if [[ "$code" == 200 ]]; then
    real_id=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
    echo "org '${display_name}' exists -> grafana id ${real_id} (${id})"
  elif [[ "$code" == 404 ]]; then
    payload=$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1]}))' "$display_name")
    real_id=$(curl "${auth[@]}" -H 'Content-Type: application/json' -d "$payload" \
      "${GRAFANA_URL}/api/orgs" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("orgId",""))')
    [[ -z "$real_id" ]] && { echo "ERROR: could not create org '${display_name}'"; exit 1; }
    echo "created org '${display_name}' -> grafana id ${real_id} (${id}, lock org_id ${org_id})"
  else
    echo "ERROR: unexpected HTTP ${code} resolving org '${display_name}'"; exit 1
  fi

  # 2) Add admin to the org (creating an org doesn't auto-add the creator),
  #    then point the admin's active org at it, then create its datasources.
  curl -s -o /dev/null -u "${ADMIN_USER}:${ADMIN_PASS}" -H 'Content-Type: application/json' \
    -d "{\"loginOrEmail\":\"${ADMIN_USER}\",\"role\":\"Admin\"}" \
    "${GRAFANA_URL}/api/orgs/${real_id}/users" || true   # 409 if already a member
  curl "${auth[@]}" -o /dev/null -X POST "${GRAFANA_URL}/api/user/using/${real_id}"
  while IFS= read -r ds; do
    [[ -z "$ds" ]] && continue
    name=$(echo "$ds" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "${ADMIN_USER}:${ADMIN_PASS}" \
      -H 'Content-Type: application/json' -d "$ds" "${GRAFANA_URL}/api/datasources")
    case "$code" in
      200|409) echo "  org ${real_id}: datasource ${name} ok (${code})" ;;
      *)       echo "  org ${real_id}: datasource ${name} FAILED (${code})"; exit 1 ;;
    esac
  done < "${BOOTSTRAP_DIR}/${id}.ndjson"

  # 3) Import the infra dashboard into THIS org (active org is set above) —
  #    the group-pinned variant for grouped tenants, the normal one otherwise.
  #    Non-fatal: a dashboard hiccup shouldn't abort org/datasource provisioning.
  dash_payload="$DASH_PAYLOAD" dash_kind="infra dashboard"
  [[ -n "$group" ]] && { dash_payload="$DASH_PAYLOAD_GROUPED"; dash_kind="infra dashboard (group: ${group})"; }
  if [[ -n "$dash_payload" ]]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "${ADMIN_USER}:${ADMIN_PASS}" \
      -H 'Content-Type: application/json' -d "$dash_payload" "${GRAFANA_URL}/api/dashboards/db")
    case "$code" in
      200) echo "  org ${real_id}: ${dash_kind} imported" ;;
      *)   echo "  org ${real_id}: ${dash_kind} import WARN (${code})" ;;
    esac
  fi
done < "$ORGS_FILE"

# Restore the admin session to org 1.
curl "${auth[@]}" -o /dev/null -X POST "${GRAFANA_URL}/api/user/using/1" || true
echo "Done. Each project now has an isolated org with tenant-pinned datasources."
