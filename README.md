# Perceptor Platform

Multi-tenant observability for 10–50 projects with hard isolation between
them, running on Docker Compose and backed by S3-compatible object storage.

```
apps / VM agents ──▶ Caddy (edge auth + TLS) ──▶ OTel Collector ──▶ Mimir · Loki · Tempo ──▶ S3
                                                                     ▲ read: Grafana, one org per project
```

| Doc | What it covers |
|---|---|
| [docs/architecture.md](docs/architecture.md) | End-to-end data flow, protocol on every hop, design rationale, known limits |
| [docs/identity-model.md](docs/identity-model.md) | How tenant / token / service_name / vm relate; what to create when adding a service, VM, or project |
| [docs/instrumenting-apps.md](docs/instrumenting-apps.md) | Wiring an app's OTel SDK: required attributes, cardinality rules |
| [docs/querying-and-retention.md](docs/querying-and-retention.md) | The query cost model; what each limit governs; read before tuning |
| [docs/data-lifecycle.md](docs/data-lifecycle.md) | When data is in memory vs local WAL vs S3, and what "durable" means |

## Core concept

**A project is a tenant. Its id is the `X-Scope-OrgID` header.** Caddy
authenticates each project's token and stamps that header; the collector
forwards it; Mimir/Loki/Tempo store data under it; each project's Grafana org
has datasources pinned to it. A project can neither write as, nor read,
another project's data.

The single source of truth is `tenants.yaml` — this deployment's project
list. It is gitignored (per-instance, like `.env`); copy
[tenants.example.yaml](tenants.example.yaml) to create it. Everything
per-tenant — edge tokens, retention and rate limits, Grafana orgs and
datasources — is rendered from it by `make render`.

New to the platform? Read [docs/identity-model.md](docs/identity-model.md)
first.

## Quick start

```bash
cp .env.example .env                    # storage (S3) + Grafana secrets
cp tenants.example.yaml tenants.yaml    # your project list (gitignored, per-instance)
make render                             # per-tenant config + tokens (tenants.secrets.yaml)
make up                                 # start the stack
make bootstrap-orgs                     # one Grafana org per project (first run only)
```

| What | Where |
|---|---|
| Grafana | http://localhost:3001 (admin / `$GRAFANA_ADMIN_PASSWORD`) |
| Ingest (OTLP/HTTP) | http://localhost:4318 — requires the project's bearer token |

Point an app's OTLP exporter at the edge with its project token:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <token from tenants.secrets.yaml>
```

A request with a missing or invalid token gets `401` at Caddy and never
reaches the stack.

Before instrumenting a real app, read
[docs/instrumenting-apps.md](docs/instrumenting-apps.md). The short version:
identify a service with a few stable, low-cardinality resource attributes,
and keep high-cardinality detail (user/request/order IDs) out of metric
labels and log stream labels. That discipline is the difference between a
fast, cheap tenant and an expensive, unqueryable one.

## Onboarding a project

1. Add an entry to `tenants.yaml` — a unique `id` and `display_name`, plus
   optional retention/limits. No token, no `org_id`: `make render` generates
   the token into `tenants.secrets.yaml` and allocates a stable `org_id` into
   `tenants.lock.yaml`, both reused forever.
2. `make reload` — re-renders and restarts the edge and backends.
3. `make bootstrap-orgs` — creates the Grafana org and its tenant-pinned
   datasources via the API (idempotent).

Two implementation notes:

- **Orgs are created via the API, not file provisioning.** Grafana hard-fails
  at boot if provisioning names an org that doesn't exist, and orgs can only
  be created once it's running. `bootstrap-orgs` resolves that ordering, looks
  each org up by name, and uses whatever id Grafana assigns — drift in the
  allocated `org_id` never breaks it.
- **`org_id` is auto-managed and per-instance.** `tenants.lock.yaml` is
  gitignored because each deployment has its own Grafana with its own org ids
  (orgs are bound by name at bootstrap; the number is a local label). Two
  fresh instances with the same `tenants.yaml` allocate identical numbers
  deterministically. `display_name` must be unique.

## Removing a project

`make delete-tenant TENANT=<id>` — the inverse of onboarding, and a full
teardown. Deleting the entry from `tenants.yaml` alone is only a soft stop:
it cuts ingest but orphans the Grafana org, the stored data, and stale files.
The target:

- removes the entry from `tenants.yaml` and its token from
  `tenants.secrets.yaml`, re-renders, and drops the orphaned bootstrap file;
- deletes the tenant's Grafana org (resolved by name) and its datasources;
- restarts Caddy so ingest stops immediately.

The `org_id` stays in `tenants.lock.yaml` as a tombstone — never reused, and
re-adding the same id later gets the same number back. Stored data is left to
age out under the tenant's retention (30d default) unless purged:

```bash
make delete-tenant TENANT=project-beta               # data expires via retention
make delete-tenant TENANT=project-beta PURGE_DATA=1  # also purge its S3 data now (irreversible)
```

`PURGE_DATA=1` deletes the tenant's objects from all three buckets (including
Loki's `index/*/<id>/`) and asks you to type the tenant id to confirm;
`YES=1` skips prompts for automation. Reserved tenants (`_infra*`) are
refused.

## Infrastructure monitoring

App telemetry is what projects send in. Infra telemetry — host CPU/RAM/disk,
container stats, system and container logs — is collected by Grafana Alloy
agents. There are two, deliberately separate:

- **Platform self-monitoring** — a central agent
  ([docker/alloy/](docker/alloy/)) watches the platform host itself and
  writes to the reserved `_infra` tenant (admin-only). It ships with the
  stack; disk/CPU/memory alerts are pre-provisioned.
- **Per-project VM monitoring** — an agent deployed on a project's own VM
  ships that machine's infra into the project's tenant, tagged
  `telemetry_source=infra` so it correlates with the project's apps without
  mixing in. It lives in its own repo:
  [github.com/tkumar1918/perceptor-agent](https://github.com/tkumar1918/perceptor-agent).

Both push outbound only; neither opens inbound ports.

**One VM shared by several projects:** a host's single agent carries one
token, so it can't file into several tenants at once. Define a group instead:
add a reserved `_infra-<group>` tenant and set `group: <group>` on each
project sharing the box (see
[tenants.example.yaml](tenants.example.yaml)). The agent reports to
`_infra-<group>` — a tenant no project owns — and every project in the group
sees the shared box from its own Grafana org via read-only datasources.
Which token the agent uses is the agent repo's one real deploy decision; see
*Which token does this VM use?* there.

### Dashboards

Committed in [docker/grafana/dashboards/](docker/grafana/dashboards/) (infra)
and [docker/grafana/dashboards-app/](docker/grafana/dashboards-app/) (app):

| Dashboard | Covers |
|---|---|
| Infrastructure — Host & running services | Fleet CPU/mem/disk/net, systemd unit health, filtered running-services and disk-space tables, host logs |
| Infrastructure — Host at a glance (htop-style) | Single-host live view: per-core CPU/mem bars, task stats, per-container table, periodic process snapshot (top-20 by CPU) |
| Infrastructure — Docker containers | Per-container CPU/mem (cadvisor) and logs, filterable to one container |
| Infrastructure — Nginx (host service) | nginx unit state + tailed access/error logs, for nginx running directly on the host |
| Application — RED (rate, errors, duration) | Auto-derived from traces by Tempo's metrics-generator; needs correct `span.kind`/`status` ([instrumenting-apps.md](docs/instrumenting-apps.md) §7), no extra app work |
| Application — Logs | The project's own app logs (`telemetry_source != infra`) |

Infra telemetry is identical everywhere, so the same infra dashboards work
for every tenant: file-provisioned into the admin org (reading `_infra`) and
API-imported into every project org by `make bootstrap-orgs`, where the
datasource variables bind to that project's own datasources. Projects in a
`group` get a variant pinned to the shared infra datasources. App dashboards
are imported into project orgs only — never the admin org, never
group-pinned. A panel is simply empty on a tenant whose agent doesn't collect
that signal; nothing is configured per-tenant.

## Verifying it works

```bash
# 1) no/invalid token is rejected at the edge
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:4318/v1/metrics \
  -H 'Content-Type: application/json' --data '{}'                       # -> 401

# 2) push as a project, then confirm the data is tenant-scoped
curl -s -X POST http://localhost:4318/v1/metrics \
  -H 'Authorization: Bearer <project-alpha-token>' \
  -H 'Content-Type: application/json' --data-binary @your-otlp.json     # -> 200
```

In Grafana, the project's org sees only its own data; another org querying
the same metric name gets an empty result. This isolation is verified
end-to-end: auth gate → write routing → storage → Grafana read path.

## Security

**Tokens.** One ingest token per tenant, auto-generated into
`tenants.secrets.yaml` and rendered into the Caddyfile — both gitignored,
as is `tenants.yaml` itself (all per-instance). Generation is idempotent; an
existing token is never silently rotated. Back up `tenants.secrets.yaml` (or
source it from a secrets manager) — losing it means re-issuing every
project's token. To rotate one, delete its line and re-render.

**Grafana roles — project users are Editor, never org Admin.** Read isolation
rests entirely on the `X-Scope-OrgID` header pinned inside each org's
provisioned datasources; the backends accept any org id from the internal
network. An org Admin can create datasources — so a project user with org
Admin in their own org could point a new datasource at another tenant's id
and read its data. The invariant:

| Who | Role |
|---|---|
| Platform operator (the `admin` account) | org Admin everywhere |
| Project users | Editor at most, in their own org only |

`make bootstrap-orgs` audits this on every run and prints a `SECURITY`
warning naming any project-org Admin that isn't the platform account. Treat
that warning as an incident: demote the user, then assume the tenant list is
known to them.

## Retention and limits

- **Retention is per project, and it is backend retention — not an S3 rule.**
  `metrics_retention` / `logs_retention` / `traces_retention` in
  `tenants.yaml` render into each backend's `overrides.yaml`. The data lives
  in S3 the whole time; these tell each backend's compactor to delete aged
  objects and their index references together, so queries stay consistent.
  This is the primary retention knob.
- **S3 lifecycle rules are a backstop only** — for sweeping truly orphaned
  objects (failed compactions, aborted multipart uploads). Set the lifecycle
  window longer than the backend retention: if S3 deletes an object a backend
  still references, queries fail with "block not found".
- **Per-project rate and series caps** (`ingestion_rate`, `max_series`) stop
  one noisy project from degrading the others.

Before changing query limits, read
[docs/querying-and-retention.md](docs/querying-and-retention.md): Loki's
limits gate query width, not data age — a narrow query on year-old data is
cheap, and long-range trends belong in metrics, not raw-log scans.

## Operational notes

- **Only the edge is exposed.** Mimir/Loki/Tempo/collector sit on an internal
  Docker network with no host ports; there is no unauthenticated read or
  write path. Grafana's `:3001` binding is controlled by `SERVICE_BIND` (see
  `.env.example`).
- **gRPC ingest** works over the TLS edge (`EDGE_HOST` set): OTLP/gRPC rides
  the same `:443` — Caddy matches `Content-Type: application/grpc` and
  proxies to the collector's gRPC listener over h2c, with the same bearer
  auth. Without a TLS edge, use OTLP/HTTP; h2c gRPC on the bare `:4318` isn't
  enabled.
- **Single-node object storage is a shared failure domain.** Replicate
  SeaweedFS and take offsite backups, or point `.env` at AWS S3 / R2 / B2 to
  offload durability. This is the main ceiling of a one-box deployment.
- **Grafana OSS orgs** have no SSO auto-mapping and no datasource-level RBAC
  (Enterprise features). Provisioning + `bootstrap-orgs` keeps many orgs
  manageable.

## Layout

```
tenants.example.yaml         committed template — copy to tenants.yaml on a new instance
tenants.yaml                 your project list, the file you edit (gitignored, per-instance)
tenants.secrets.yaml         (generated, gitignored) one ingest token per tenant
tenants.lock.yaml            (generated, gitignored) one stable Grafana org_id per tenant
scripts/render.py            renders everything below from tenants.yaml
scripts/grafana-bootstrap.sh creates Grafana orgs + datasources via API, audits org Admins
scripts/delete-tenant.sh     full tenant teardown (make delete-tenant)
docker/
  docker-compose.yml
  caddy/Caddyfile            (generated) token -> tenant
  otel/collector-config.yaml
  mimir/{mimir,overrides}.yaml
  loki/{loki,overrides}.yaml
  tempo/{tempo,overrides}.yaml
  alloy/                     platform self-monitoring agent (-> _infra)
  grafana/bootstrap/         (generated) per-org datasource payloads, API-applied
  grafana/provisioning/      dashboards provider + alerting (admin org 1)
  grafana/dashboards/        infra dashboards — provisioned to admin org, imported to all project orgs
  grafana/dashboards-app/    app dashboards — imported to project orgs only
```
