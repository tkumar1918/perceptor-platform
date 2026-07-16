#!/usr/bin/env bash
# ============================================================================
# Delete a tenant (project) from the platform — the inverse of onboarding.
#
# "Remove from tenants.yaml + make render" is only a SOFT stop: it cuts ingest
# but leaves the Grafana org, the stored S3 data, and a couple of stale files
# behind. This does the full teardown that render doesn't:
#
#   - removes the tenant block from tenants.yaml        (stops it being rendered)
#   - drops its ingest token from tenants.secrets.yaml
#   - re-renders (Caddy token gone -> ingest stops; overrides/.orgs updated)
#   - deletes the orphaned docker/grafana/bootstrap/<id>.ndjson
#   - deletes its Grafana org (resolved by name) + its datasources
#   - restarts caddy so ingest actually stops now
#
# Its org_id stays in tenants.lock.yaml as a reserved TOMBSTONE (never reused;
# re-adding the same id later gets the same number back).
#
# STORED DATA: by default the tenant's S3 data is left to age out under the 30d
# default retention. Pass PURGE_DATA=1 to also irreversibly wipe its S3 prefixes
# (mimir/loki/tempo) now — you'll be asked to type the tenant id to confirm.
#
# Usage (env must be loaded, like bootstrap-orgs — `make` does this for you):
#   make delete-tenant TENANT=project-beta
#   make delete-tenant TENANT=project-beta PURGE_DATA=1
#   YES=1 skips the prompts (automation).
# ============================================================================
set -euo pipefail

TENANT="${1:?usage: delete-tenant.sh <tenant-id>  (or: make delete-tenant TENANT=<id>)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PURGE_DATA="${PURGE_DATA:-}"
YES="${YES:-}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3001}"
ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
ADMIN_PASS="${GRAFANA_ADMIN_PASSWORD:-}"
# --env-file matches the Makefile: the compose file's ${VAR:?} guards reject
# any invocation that doesn't load .env, so this array must carry it too.
COMPOSE=(docker compose -f "${ROOT}/docker/docker-compose.yml" --env-file "${ROOT}/.env")
PYBIN="${ROOT}/.venv/bin/python"; [ -x "$PYBIN" ] || PYBIN=python3

cd "$ROOT"
[ -f tenants.yaml ] || { echo "tenants.yaml not found (per-instance; cp tenants.example.yaml tenants.yaml)"; exit 1; }

confirm() {  # $1 = prompt
  [ -n "$YES" ] && return 0
  local ans; read -r -p "$1 [y/N] " ans </dev/tty || true
  [[ "$ans" == [yY] || "$ans" == [yY][eE][sS] ]]
}

# --- 1. Validate + capture display_name / org_id (refuse reserved / unknown) ---
meta=$("$PYBIN" - "$TENANT" <<'PY'
import sys, os, yaml
tid = sys.argv[1]
if tid.startswith("_"):
    sys.exit(f"'{tid}' is a reserved platform tenant — refusing to delete.")
cfg = yaml.safe_load(open("tenants.yaml")) or {}
tenants = cfg.get("tenants") or []
t = next((x for x in tenants if x.get("id") == tid), None)
if not t:
    ids = ", ".join(x.get("id", "?") for x in tenants) or "(none)"
    sys.exit(f"tenant '{tid}' not found in tenants.yaml. Known project tenants: {ids}")
org_id = ""
if os.path.exists("tenants.lock.yaml"):
    lk = yaml.safe_load(open("tenants.lock.yaml")) or {}
    org_id = (lk.get("allocations") or {}).get(tid, "")
print(f"{t.get('display_name', tid)}\t{org_id}")
PY
) || exit 1
DISPLAY="${meta%%$'\t'*}"; ORG_ID="${meta##*$'\t'}"

echo "About to delete tenant:"
echo "    id           : $TENANT"
echo "    display_name : $DISPLAY   (Grafana org)"
echo "    org_id       : ${ORG_ID:-<none>}   (kept as reserved tombstone)"
echo "    S3 data      : $([ -n "$PURGE_DATA" ] && echo 'PURGE now (irreversible)' || echo 'left to expire (~30d default retention)')"
confirm "Proceed?" || { echo "aborted."; exit 1; }

# --- 2. Back up the hand-edited files; restore if render rejects the result ----
cp tenants.yaml "tenants.yaml.bak.$$"
[ -f tenants.secrets.yaml ] && cp tenants.secrets.yaml "tenants.secrets.yaml.bak.$$"
restore() {
  mv -f "tenants.yaml.bak.$$" tenants.yaml
  [ -f "tenants.secrets.yaml.bak.$$" ] && mv -f "tenants.secrets.yaml.bak.$$" tenants.secrets.yaml || true
}

# --- 3. Remove the tenant block from tenants.yaml + its secret line -------------
"$PYBIN" - "$TENANT" <<'PY'
import sys, re, os
tid = sys.argv[1]
lines = open("tenants.yaml").read().splitlines(keepends=True)
start = next((i for i, l in enumerate(lines)
              if re.match(rf'^  - id:\s*{re.escape(tid)}(\s|#|$)', l)), None)
if start is None:
    sys.exit("block not found (unexpected)")
end = len(lines)
for i in range(start + 1, len(lines)):          # block runs to next list item or col-0 line
    if re.match(r'^  - id:', lines[i]) or re.match(r'^\S', lines[i]):
        end = i
        break
del lines[start:end]
open("tenants.yaml", "w").writelines(lines)

sec = "tenants.secrets.yaml"
if os.path.exists(sec):
    kept = [l for l in open(sec).read().splitlines(keepends=True)
            if not re.match(rf'^{re.escape(tid)}:\s', l)]
    open(sec, "w").writelines(kept)
PY

# --- 4. Re-render (restore + abort if the edit produced invalid config) ---------
if ! "$PYBIN" scripts/render.py; then
  echo "render failed on the edited tenants.yaml — restoring originals."; restore; exit 1
fi
rm -f "tenants.yaml.bak.$$" "tenants.secrets.yaml.bak.$$"

# --- 5. Remove the orphaned per-org datasource payload -------------------------
rm -f "docker/grafana/bootstrap/${TENANT}.ndjson" && echo "removed stale bootstrap/${TENANT}.ndjson"

# --- 6. Apply: restart caddy so the ingest token is actually revoked -----------
if command -v docker >/dev/null 2>&1 && "${COMPOSE[@]}" ps caddy >/dev/null 2>&1; then
  "${COMPOSE[@]}" restart caddy >/dev/null 2>&1 && echo "restarted caddy (ingest token revoked)"
  echo "note: retention/limit changes hot-reload in mimir/loki/tempo — no restart needed."
else
  echo "note: docker not reachable from here — run 'make reload' to apply the config."
fi

# --- 7. Delete the Grafana org (resolved by name; idempotent) ------------------
if [ -z "$ADMIN_PASS" ]; then
  echo "GRAFANA_ADMIN_PASSWORD not set — skipping Grafana org delete (use 'make delete-tenant' so .env loads)."
else
  U="${ADMIN_USER}:${ADMIN_PASS}"
  enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$DISPLAY")
  resp=$(curl -sS -u "$U" -w $'\n%{http_code}' "${GRAFANA_URL}/api/orgs/name/${enc}" 2>/dev/null || printf '\n000')
  code=${resp##*$'\n'}; body=${resp%$'\n'*}
  if [ "$code" = "200" ]; then
    oid=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
    dc=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -u "$U" "${GRAFANA_URL}/api/orgs/${oid}")
    [ "$dc" = "200" ] && echo "deleted Grafana org '${DISPLAY}' (id ${oid})" \
                      || echo "WARN: Grafana org delete returned HTTP ${dc} — remove it manually if needed."
  elif [ "$code" = "404" ]; then
    echo "Grafana org '${DISPLAY}' already absent."
  else
    echo "WARN: couldn't reach Grafana at ${GRAFANA_URL} (http ${code}) — delete org '${DISPLAY}' manually if needed."
  fi
fi

# --- 8. Optional: irreversibly purge the tenant's S3 data ----------------------
if [ -n "$PURGE_DATA" ]; then
  # Only the buckets are required. The CREDENTIALS may legitimately be empty:
  # on AWS the stack authenticates via the EC2 instance role (Profile C in
  # .env.example), and the CLI below inherits the same default-chain fallback.
  # Requiring S3_ACCESS_KEY_ID here silently broke purge on every role-auth
  # deployment.
  : "${BUCKET_MIMIR:?}"; : "${BUCKET_LOKI:?}"; : "${BUCKET_TEMPO:?}"
  echo
  echo "!!! PURGE_DATA: about to IRREVERSIBLY delete all S3 objects for '${TENANT}':"
  echo "      s3://${BUCKET_MIMIR}/${TENANT}/"
  echo "      s3://${BUCKET_LOKI}/${TENANT}/   and   s3://${BUCKET_LOKI}/index/*/${TENANT}/"
  echo "      s3://${BUCKET_TEMPO}/${TENANT}/"
  if [ -z "$YES" ]; then
    read -r -p "Type the tenant id '${TENANT}' to confirm: " typed </dev/tty || true
    [ "$typed" = "$TENANT" ] || { echo "confirmation mismatch — S3 purge SKIPPED."; typed=""; }
    [ -z "$typed" ] && exit 0
  fi
  ep=(); [ -n "${S3_ENDPOINT_URL:-}" ] && ep=(--endpoint-url "$S3_ENDPOINT_URL")
  ssl=(); [ "${S3_INSECURE:-false}" = "true" ] && ssl=(--no-verify-ssl)   # MinIO/http endpoints
  # Export creds ONLY when non-empty: an empty-but-set AWS_ACCESS_KEY_ID makes
  # some SDK versions abort instead of falling through to the instance role.
  awsenv=(AWS_REGION="${S3_REGION:-us-east-1}")
  if [ -n "${S3_ACCESS_KEY_ID:-}" ]; then
    awsenv+=(AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-}")
  fi
  if command -v aws >/dev/null 2>&1; then
    aws_run() { env "${awsenv[@]}" aws "$@"; }
  else
    # No aws CLI on this host — run the pinned image instead (same one s3-init
    # uses). With no creds passed, the container reaches the EC2 instance role
    # via IMDS exactly like the mimir/loki containers already do.
    denv=(); for kv in "${awsenv[@]}"; do denv+=(-e "$kv"); done
    aws_run() { docker run --rm "${denv[@]}" amazon/aws-cli:2.31.18 "$@"; }
    echo "  (aws CLI not installed — using dockerized amazon/aws-cli)"
  fi
  rm_prefix() { aws_run s3 rm "$1" --recursive "${ep[@]}" "${ssl[@]}"; }
  echo "  mimir…";       rm_prefix "s3://${BUCKET_MIMIR}/${TENANT}/" || true
  echo "  tempo…";       rm_prefix "s3://${BUCKET_TEMPO}/${TENANT}/" || true
  echo "  loki chunks…"; rm_prefix "s3://${BUCKET_LOKI}/${TENANT}/"  || true
  echo "  loki index…";  aws_run s3 rm "s3://${BUCKET_LOKI}/index/" \
       --recursive --exclude "*" --include "*/${TENANT}/*" "${ep[@]}" "${ssl[@]}" || true
  echo "S3 purge complete."
else
  echo
  echo "S3 data for '${TENANT}' left in place — it ages out within ~30d (default retention)."
  echo "To wipe it now:  make delete-tenant TENANT=${TENANT} PURGE_DATA=1"
fi

echo
echo "Done. '${TENANT}' removed. org_id ${ORG_ID:-n/a} retained as a reserved tombstone in tenants.lock.yaml."
