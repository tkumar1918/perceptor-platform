# Perceptor Platform

Multi-tenant observability for **10–50 projects** with **hard isolation**, on
**Docker Compose**, backed by **object storage**.

Stack: **Caddy** (edge auth) → **OpenTelemetry Collector** → **Mimir** (metrics)
· **Loki** (logs) · **Tempo** (traces) → **SeaweedFS** (S3, swappable for AWS S3)
· **Grafana** (one org per project). See [REDESIGN.md](REDESIGN.md) for the why,
and [docs/architecture.md](docs/architecture.md) for the end-to-end data flow
(diagram + protocol on every hop).

> This is the redesign that replaces the original `../perceptor/` prototype.
> The two can run side by side; nothing here touches the old folder.

---

## One concept to understand

**A project is a tenant. Its id is the `X-Scope-OrgID` header.** Caddy
authenticates each project's token and stamps that header; the collector
forwards it; Mimir/Loki/Tempo store data under it; and each project's Grafana
**org** has datasources pinned to it. A project can neither write as, nor read,
another project's data.

The single source of truth is `tenants.yaml` — your deployment's project list.
It's **gitignored** (per-instance, like `.env`); the repo ships
[tenants.example.yaml](tenants.example.yaml) as the template to copy. Everything
per-tenant (Caddy tokens, backend retention/limits, Grafana datasources/orgs) is
**rendered** from it by `make render`.

New to the platform? Read **[docs/identity-model.md](docs/identity-model.md)**
first — how tenant / token / service_name / vm relate, what's a security
boundary vs. just a label, and "I'm adding X — what do I create?".

---

## Quick start

```bash
cp .env.example .env                    # set storage (S3) + Grafana secrets
cp tenants.example.yaml tenants.yaml    # your project list (gitignored, per-instance)
make render                             # generate per-tenant config + tokens (tenants.secrets.yaml)
make up                                 # start the stack
make bootstrap-orgs                     # create one Grafana org per project (first run only)
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

> **Instrument it well — read [docs/instrumenting-apps.md](docs/instrumenting-apps.md) first.**
> What resource attributes to set (`service.name`, `deployment.environment.name`) and
> the one rule that keeps a tenant fast and cheap: identify a service with a few
> **stable, low-cardinality** labels, and keep high-cardinality detail (user / request /
> order IDs) out of metric labels and log stream labels — put it on span attributes
> instead. Getting this right is the difference between a snappy tenant and an
> expensive, unqueryable one.

---

## Onboarding a new project

1. Add an entry to [tenants.yaml](tenants.yaml) — just a unique `id` and
   `display_name` (plus optional retention/limits). No token, **no `org_id`** —
   `make render` generates the token into `tenants.secrets.yaml` and allocates a
   stable `org_id` into `tenants.lock.yaml`, both reused forever.
2. `make reload` — re-renders and restarts the edge + backends.
3. `make bootstrap-orgs` — creates its Grafana org **and** its three
   tenant-pinned datasources via the API (idempotent; no-op for existing ones).

> Grafana orgs/datasources are created via the API, not file provisioning:
> Grafana hard-fails at boot if provisioning names an org that doesn't exist yet,
> and orgs can only be created after it's running. `bootstrap-orgs` resolves that
> ordering. It looks each org up **by name** and uses whatever id Grafana assigns,
> so a gap or drift in the allocated `org_id` never breaks it.

That's the whole flow. No hand-editing of six config files.

> **`org_id` is auto-managed, per-instance.** `make render` allocates one per
> tenant into `tenants.lock.yaml` — **gitignored**, because each deployment has its
> own Grafana with its own org ids (orgs are bound by *name* at bootstrap, so the
> number is just a local label). Two fresh instances with the same `tenants.yaml`
> allocate the same numbers deterministically; you don't set it, and anything
> invalid/taken is healed to the next free number. `display_name` must be unique.

## Removing a project

`make delete-tenant TENANT=<id>` — the inverse of onboarding, and a **full**
teardown. (Just deleting the entry from `tenants.yaml` is only a *soft stop*: it
cuts ingest but orphans the Grafana org, the stored data, and stale files.) It:

- removes the block from `tenants.yaml` + its token from `tenants.secrets.yaml`,
  re-renders, and drops the orphaned `bootstrap/<id>.ndjson`;
- **deletes the tenant's Grafana org** (resolved by name) and its datasources;
- restarts caddy so ingest stops immediately.

The `org_id` stays in `tenants.lock.yaml` as a reserved **tombstone** (never
reused; re-adding the same id later gets the same number back). By default the
tenant's **stored data is left to age out** under its retention (30d default).

```bash
make delete-tenant TENANT=project-beta               # teardown; data expires via retention
make delete-tenant TENANT=project-beta PURGE_DATA=1  # + irreversibly purge its S3 data now
```

`PURGE_DATA=1` also deletes the tenant's objects from all three buckets (Mimir/
Tempo prefixes, Loki chunks **and** its `index/*/<id>/`), and asks you to type the
tenant id to confirm. `YES=1` skips prompts (automation). Reserved tenants
(`_infra`) are refused.

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
  mixing in. It's a standalone, pullable bundle in its **own repo**:
  **[github.com/tkumar1918/perceptor-agent](https://github.com/tkumar1918/perceptor-agent)**.

Both push outbound only; neither opens inbound ports.

**One VM, several projects?** A host's single agent carries one token, so it
can't file into several project tenants at once. Give it a **group** instead: add
a reserved `_infra-<group>` tenant and set `group: <group>` on each project that
shares the box (see [tenants.example.yaml](tenants.example.yaml)). The agent
reports to `_infra-<group>` — a tenant no one project owns — and every one of
those projects sees the shared box from its **own** Grafana org, without any
project's tenant being polluted by another's data. Which token the agent uses is
the agent repo's one real deploy decision — see *Which token does this VM use?*
there.

Three infra dashboards ship with the stack
([docker/grafana/dashboards/](docker/grafana/dashboards/)), split by concern
instead of one monolith:

| Dashboard | Covers |
|---|---|
| **Infrastructure — Host & running services** | Fleet CPU/mem/disk/net, systemd unit health (needs the agent's `systemd` collector), host/journald logs |
| **Infrastructure — Docker containers** | Per-container CPU/mem (cadvisor) and per-container logs, both filterable down to one `container` |
| **Infrastructure — Nginx (host service)** | nginx.service unit state + tailed access/error logs, for nginx running as a host service (not containerized) |

Because infra telemetry is identical everywhere, **the same three dashboards work
for every tenant**: each is auto-provisioned into the admin org (reading
`_infra`) and imported into every project org by `make bootstrap-orgs`, where its
datasource variables bind to that project's own Mimir/Loki. Pick your `vm` from
the dropdown. (Projects in a `group` get a variant pinned to the shared infra
datasources instead, so they show the shared box rather than their own —
otherwise empty — infra namespace.) A dashboard's panels are simply empty on a
tenant whose agent doesn't collect that signal (e.g. no nginx host service, or an
older agent without the systemd collector) — nothing to configure per-tenant.

A fourth dashboard, **Application — RED (rate, errors, duration)**
([docker/grafana/dashboards-app/app-red.json](docker/grafana/dashboards-app/app-red.json)),
is different in kind: it's app data, not infra, so it's imported into every
**project** org only (never the admin org, never group-pinned — app traces stay
in the project's own tenant regardless of infra grouping). It needs **no extra
app-side work**: Tempo's metrics-generator auto-derives request rate, error rate,
and latency from any project's traces the moment spans carry proper
`span.kind`/`status` (see [docs/instrumenting-apps.md](docs/instrumenting-apps.md) §7)
— the same semantic-convention discipline the platform already asks for.

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
`tenants.secrets.yaml` and rendered into the Caddyfile — **both gitignored**, as is
`tenants.yaml` itself (all per-instance, not shared — see [Layout](#layout)).
Generation is idempotent (an existing token is never silently rotated). Back up
`tenants.secrets.yaml` or source it from a secrets manager / SOPS-age — losing it
means re-issuing every project's token. To rotate one, delete its line and re-render.

## Security note on Grafana roles — project users are Editor, NEVER org Admin

Tenant **read** isolation rests entirely on the `X-Scope-OrgID` header pinned
inside each org's provisioned datasources. The backends themselves accept any
org id from anything on the internal network — the header IS the boundary.

A Grafana **org Admin can create datasources**. So a project user holding org
Admin in *their own* org can add one pointing at `http://mimir:9009/prometheus`
with any other tenant's id in the header — and read that tenant's data. Nothing
logs it, nothing blocks it.

The invariant, therefore:

| Who | Role |
|---|---|
| platform operator (the `admin` account) | org Admin everywhere |
| project users | **Editor at most**, in their own org only |

`make bootstrap-orgs` audits this on every run and prints a `⚠ SECURITY`
warning naming any project-org Admin that isn't the platform account. Treat
that warning as an incident, not a nag: demote the user (org →
Administration → Users), then assume the tenant list is known to them.

## Managing old data

- **Retention is per project, and it's *backend* retention — not an S3 rule.**
  `metrics_retention` / `logs_retention` / `traces_retention` in `tenants.yaml`
  render into each backend's `overrides.yaml` (Mimir `compactor_blocks_retention_period`,
  Loki `retention_period`, Tempo `compaction.block_retention`). Your data lives in
  S3 the whole time; these tell each backend's **compactor** to delete the aged S3
  objects **and** their index references together, so queries stay consistent. This
  is the **primary** retention knob.
- **S3 lifecycle is a *backstop*, not the retention control.** Set bucket lifecycle
  rules (native on AWS S3) to sweep truly orphaned objects — failed compactions,
  aborted multipart uploads — so storage can't silently fill. **Set the lifecycle
  window *longer* than the backend retention above**, and never rely on it as the
  primary expiry: if S3 deletes an object a backend still references, queries fail
  with "block not found." Backend retention deletes cleanly; lifecycle only mops up.
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
- **gRPC ingest** works over the TLS edge (`EDGE_HOST` set): OTLP/gRPC rides the
  same `:443` as HTTP — Caddy matches `Content-Type: application/grpc` and proxies
  it to the collector's gRPC listener over h2c, with the same bearer-token auth.
  Point a gRPC exporter at `https://<EDGE_HOST>` (no extra port). Without a TLS
  edge (plain `:4318`), use OTLP/HTTP — h2c gRPC on the bare port isn't enabled.
- **Single-node object storage is a shared failure domain.** For hard isolation,
  replicate SeaweedFS + take offsite backups, or point `.env` at **AWS S3 / R2 /
  B2** to offload durability. This is the main ceiling of a one-box deployment.
- **Grafana OSS orgs** have no SSO auto-mapping and no datasource-level RBAC
  (Enterprise). File provisioning keeps many orgs manageable.

---

## Layout

```
tenants.example.yaml        committed template — copy to tenants.yaml on a new instance
tenants.yaml                your project list, the file you edit (gitignored, per-instance)
tenants.secrets.yaml        (generated, gitignored) one ingest token per tenant
tenants.lock.yaml           (generated, gitignored) one stable Grafana org_id per tenant
scripts/render.py           renders everything below from tenants.yaml
scripts/grafana-bootstrap.sh creates Grafana orgs via API (resolved by name)
scripts/delete-tenant.sh    full tenant teardown (make delete-tenant)
docker/
  docker-compose.yml
  caddy/Caddyfile           (generated) token -> tenant
  otel/collector-config.yaml
  mimir/{mimir,overrides}.yaml
  loki/{loki,overrides}.yaml
  tempo/{tempo,overrides}.yaml
  grafana/bootstrap/         (generated) per-org datasource payloads, API-applied
  grafana/provisioning/...   dashboards provider (admin org 1)
  grafana/dashboards/        infra dashboards — file-provisioned into admin org 1,
                              API-imported into every project org (bootstrap-orgs)
  grafana/dashboards-app/    app dashboards — API-imported into project orgs only,
                              never admin org (not infra, not group-pinned)
```
