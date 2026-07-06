# Perceptor Platform

Multi-tenant observability for **10–50 projects** with **hard isolation**, on
**Docker Compose**, backed by **object storage**.

Stack: **Caddy** (edge auth) → **OpenTelemetry Collector** → **Mimir** (metrics)
· **Loki** (logs) · **Tempo** (traces) → **SeaweedFS** (S3, swappable for AWS S3)
· **Grafana** (one org per project). See [REDESIGN.md](REDESIGN.md) for the why.

> This is the redesign that replaces the original `../perceptor/` prototype.
> The two can run side by side; nothing here touches the old folder.

---

## One concept to understand

**A project is a tenant. Its id is the `X-Scope-OrgID` header.** Caddy
authenticates each project's token and stamps that header; the collector
forwards it; Mimir/Loki/Tempo store data under it; and each project's Grafana
**org** has datasources pinned to it. A project can neither write as, nor read,
another project's data.

The single source of truth is [tenants.yaml](tenants.yaml). Everything per-tenant
(Caddy tokens, backend retention/limits, Grafana datasources/orgs) is **rendered**
from it by `make render`.

---

## Quick start

```bash
cp .env.example .env          # set storage (S3) + Grafana secrets
make render                   # generate per-tenant config + ingest tokens (tenants.secrets.yaml)
make up                       # start the stack
make bootstrap-orgs           # create one Grafana org per project (first run only)
```

Then:

| What | Where |
|---|---|
| Grafana | http://localhost:3001 (admin / `$GRAFANA_ADMIN_PASSWORD`) |
| Ingest (OTLP/HTTP) | http://localhost:4318 — **requires** the project's bearer token |

Point an app's OTLP exporter at the edge with its project token:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <project token from tenants.secrets.yaml>
```

A request with no/invalid token gets `401` at Caddy and never reaches the stack.

---

## Onboarding a new project

1. Add an entry to [tenants.yaml](tenants.yaml) (unique `id`, next free `org_id`,
   optional retention/limits). No token needed — `make render` generates one into
   `tenants.secrets.yaml` and prints it once.
2. `make reload` — re-renders and restarts the edge + backends.
3. `make bootstrap-orgs` — creates its Grafana org **and** its three
   tenant-pinned datasources via the API (idempotent; no-op for existing ones).

> Grafana orgs/datasources are created via the API, not file provisioning:
> Grafana hard-fails at boot if provisioning names an org that doesn't exist yet,
> and orgs can only be created after it's running. `bootstrap-orgs` resolves that
> ordering. Org IDs are positional, so create them in `tenants.yaml` order.

That's the whole flow. No hand-editing of six config files.

> **`org_id` is forever.** It must be unique, sequential from 2, and never
> reused or renumbered once a project is live — Grafana org IDs are positional.

---

## Monitoring the infrastructure

App telemetry is what projects send *in*. Infra telemetry (host CPU/RAM/disk,
container stats, system + container logs) is collected by **Grafana Alloy
agents**. There are two, deliberately separate:

- **Platform self-monitoring** — a central agent ([docker/alloy/](docker/alloy/))
  watches the platform host itself and writes to the reserved **`_infra`** tenant
  (admin-only). It ships with the stack; disk/CPU/mem alerts are pre-provisioned.
- **Per-project VM monitoring** — an agent deployed on a **project's own VM**
  ships that machine's infra into the **project's** tenant, tagged
  `telemetry_source=infra` so it correlates with the project's apps without
  mixing in. **Setup guide: [agent/README.md](agent/README.md).**

Both push outbound only; neither opens inbound ports.

---

## Verifying it works

```bash
# 1) no/invalid token is rejected at the edge
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:4318/v1/metrics \
  -H 'Content-Type: application/json' --data '{}'                       # -> 401

# 2) push as a project (its token), then confirm the data is tenant-scoped
curl -s -X POST http://localhost:4318/v1/metrics \
  -H 'Authorization: Bearer <project-alpha-token>' \
  -H 'Content-Type: application/json' --data-binary @your-otlp.json     # -> 200
```
Then in Grafana, log into the project's org — it sees only its own data; other
orgs query the same metric name and get an empty result. This isolation has been
verified end-to-end (auth gate → write routing → storage → Grafana read path).

## Security note on tokens

Project ingest tokens are auto-generated (one per tenant) into
`tenants.secrets.yaml` and rendered into the Caddyfile. **That file is the secret —
it's gitignored;** `tenants.yaml` itself is now safe to commit. Generation is
idempotent (an existing token is never silently rotated). Back up
`tenants.secrets.yaml` or source it from a secrets manager / SOPS-age — losing it
means re-issuing every project's token. To rotate one, delete its line and re-render.

## Managing old data

- **Retention is per project** — `metrics_retention` / `logs_retention` /
  `traces_retention` in `tenants.yaml` render into each backend's `overrides.yaml`.
- **Bucket lifecycle** — set S3 lifecycle rules to expire/transition old objects
  so storage can't silently fill. (On AWS S3 this is native bucket lifecycle.)
- **Rate & series caps per project** (`ingestion_rate`, `max_series`) stop one
  noisy project from degrading the others.

> **Before you change query limits**, read
> [docs/querying-and-retention.md](docs/querying-and-retention.md) — it explains
> why Loki gates query *width* (`max_query_length`) not *age*, why a narrow query
> on year-old data is cheap, and why long-range trends should come from metrics,
> not raw-log scans. It clears up the usual "I have a year of data, why can't I
> query it?" confusion.

---

## Operational notes & known limits

- **Only the edge is exposed.** Mimir/Loki/Tempo/Collector are on an internal
  Docker network with no host ports — there is no unauthenticated read/write path.
- **gRPC ingest (4317)** is intentionally not exposed yet (Caddy h2c needs more
  setup); use OTLP/HTTP. The collector's gRPC stays internal.
- **Single-node object storage is a shared failure domain.** For hard isolation,
  replicate SeaweedFS + take offsite backups, or point `.env` at **AWS S3 / R2 /
  B2** to offload durability. This is the main ceiling of a one-box deployment.
- **Grafana OSS orgs** have no SSO auto-mapping and no datasource-level RBAC
  (Enterprise). File provisioning keeps many orgs manageable.

---

## Layout

```
tenants.yaml                source of truth (the only file you normally edit)
tenants.secrets.yaml        (generated, gitignored) one ingest token per tenant
scripts/render.py           renders everything below from tenants.yaml
scripts/grafana-bootstrap.sh creates Grafana orgs via API
docker/
  docker-compose.yml
  caddy/Caddyfile           (generated) token -> tenant
  otel/collector-config.yaml
  mimir/{mimir,overrides}.yaml
  loki/{loki,overrides}.yaml
  tempo/{tempo,overrides}.yaml
  grafana/bootstrap/         (generated) per-org datasource payloads, API-applied
  grafana/provisioning/...   dashboards provider (admin org 1)
  grafana/dashboards/        drop shared dashboard JSON here
```
