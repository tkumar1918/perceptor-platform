# Identity model — tenant, token, service, VM

Every piece of telemetry carries a handful of identities, each answering a
different question. Two streams produce telemetry, and each identity belongs
to one or both:

- **APP** — the application's OTel SDK, pushing traces/logs/metrics with the
  project token.
- **INFRA** — the VM agent (Alloy), pushing the machine's host and container
  telemetry with its own token. Everything on this path is stamped
  `telemetry_source=infra`, which is how the two streams share a tenant
  without being confused for each other (app dashboards filter it out with
  `telemetry_source!="infra"`).

| Identity | Question it answers | Stream | Who sets it | Security boundary? |
|---|---|---|---|---|
| **tenant** (`X-Scope-OrgID`) | whose data is this? | both | the edge (Caddy), from the token — never the sender | **yes — the only one** |
| **service_name** | which app / which unit? | both | APP: `OTEL_SERVICE_NAME` · INFRA: derived (below) | no — a label |
| **deployment_environment** | dev / test / prod? | both | APP: `OTEL_RESOURCE_ATTRIBUTES` · INFRA: `perceptor.environment` container label | no |
| **vm** | which machine? | infra only | the agent (`VM_NAME` in its `.env`) | no |
| **telemetry_source** | app stream or infra stream? | infra only (`=infra`) | the agent, hardcoded | no |
| **job** | which infra source? (`docker` / `systemd-journal` / `nginx`) | infra only | the agent config | no |
| **container** | which container? | infra only | the agent, from the Docker name | no |

App telemetry never carries `vm`, `job`, or `container` — if you see those,
you are looking at the infra stream. Infra telemetry never carries an app's
`OTEL_SERVICE_NAME`; its `service_name` is derived per source:

| Infra source | `service_name` becomes |
|---|---|
| container logs (opted in) | the `perceptor.service_name` compose label, else the container name |
| host/system logs (journald) | the systemd unit (`cron.service`, `sshd.service`, …) |
| host nginx logs | `nginx` |

The one-sentence version: **the tenant is a wall; everything else is a
filter.** Walls are enforced by the platform. Filters are self-declared by
apps and agents so dashboards can slice data — nothing stops an app from
lying about its own `service_name`, and that's acceptable, because it can
only lie inside its own tenant.

## Tokens are tenant-scoped

One token per tenant, generated into `tenants.secrets.yaml` by `make render`.
Not per service, not per VM, not per environment. A token does exactly one
thing: Caddy matches it and stamps `X-Scope-OrgID: <tenant>` on the request.
Consequences:

- **Every service of a project shares the project's one token.** Ten
  microservices, one token — they differ by `OTEL_SERVICE_NAME`, not by
  credential.
- **A token is write-only.** It pushes telemetry into its tenant; it can
  never read anything. Reading happens in Grafana, through org-pinned
  datasources.
- **A leaked token pollutes one tenant.** It can't read data or write
  anywhere else. Rotate it by deleting its line in `tenants.secrets.yaml`
  and running `make render` + `make reload`; every exporter using it then
  needs the new value.
- **Apps never send `X-Scope-OrgID` themselves.** The edge derives the tenant
  from the token, and only from the token; a header the client sets never
  survives.

If a token's owner is ever unclear, `tenants.secrets.yaml` is the answer —
it is a flat `tenant-id: token` map.

## How the identities nest

```
tenant: test-proj-b                      ← the wall (one token, one Grafana org)
├── service_name: test-proj-b-app       ← an app       (set by OTEL_SERVICE_NAME)
│   ├── deployment_environment: test    ← its env      (set by the app)
│   └── deployment_environment: prod
├── service_name: test-proj-b-worker    ← another app, same token
└── (infra, if dedicated VM): vm=proj-b-vm-1   ← host metrics/logs, same tenant
```

One line of telemetry from each stream, as stored:

```
APP:    tenant=test-proj-b  service_name=test-proj-b-app  deployment_environment=test   → one trace
INFRA:  tenant=_infra-test-shared-vm  telemetry_source=infra  vm=tushar-test-shared-vm
        job=docker  container=proj-b-otel-test-1  service_name=test-proj-b-app          → one container log line
```

Note the same app appears in both streams under the same `service_name`: its
SDK pushes app telemetry to `test-proj-b`, while the VM agent independently
ships that container's stdout to the group's infra tenant. Two paths, two
tenants, one name — `perceptor.service_name` keeps the identities aligned.

## VMs — where tokens get subtle

A VM runs one agent carrying one token, and that token decides where the
whole machine's infra (host metrics, container metrics, opted-in container
logs) lands:

| The VM is used by… | Agent's token | Infra lands in |
|---|---|---|
| one project (dedicated VM) | that project's token | the project's own tenant, next to its app data |
| several projects (shared VM) | the group's `_infra-<group>` token | the shared `_infra-<group>` tenant |

The shared case can't use a project token: the agent is per-host, not
per-project. Give it project A's token and project B's containers get filed
under A — B cannot see its own machine. So a shared box gets a **group**: a
reserved tenant `_infra-<group>` holds the machine's infra, and every project
in the group gets a read-only extra datasource pair pointed at it. Everyone
on the box can see the box; nobody's app tenant is polluted.

`vm` (from `VM_NAME` in the agent's `.env`) tells machines apart inside that
tenant — a group with three hosts has three `vm` values in one tenant.

Reserved tenants (ids starting `_`) are platform namespaces: they get a token
and storage like any tenant, but no Grafana org — they're read from the admin
org, or via the read-only group datasources.

## One tenant per environment, or one for all?

A project with several environments (prod, dev, staging) has two correct
shapes, and the choice follows from the wall/filter rule.

**Default: one tenant, environments as labels.** Each app sets
`deployment.environment` (a tiny enum — see naming below); the platform
indexes it on all three signals, so one org shows every environment and any
dashboard filters by it. One token, one org, and if the envs share a
dedicated VM, no group is needed. This is the row "an environment of an
existing app → no new tenant" in the table below, and it should be your
starting point.

**Split into per-env tenants when an environment needs its own wall.**
Everything the platform *enforces* is per-tenant; a label can slice data but
can never protect one environment from another:

| Property | Merged (one tenant + labels) | Split (tenant per env) |
|---|---|---|
| Ingestion limits (`ingestion_rate`, `max_series`, trace/log rates) | one shared pool — a dev flood or load test spends prod's quota | independent — the noisy env throttles alone |
| Retention (`*_retention`) | one policy for all envs | per env — trim the noisy env, keep prod's history |
| Write rejections when a limit trips | hit every env in the tenant | stay inside the offending env |
| Grafana visibility | one org sees all envs | one org per env — contractors can get dev without prod |
| Query cost | equal — `deployment_environment` is indexed, so a prod-scoped query never reads dev's chunks | equal |
| Moving parts | 1 token, 1 org | 2 tokens, 2 orgs — plus a group if the envs share a VM |

The decision rule: **symmetric, well-behaved environments → merge and filter
by label. A known-asymmetric environment — log-heavy dev, frequent load
tests, experimental instrumentation — or an audience split → give it its own
tenant**, because limits and retention are walls only at the tenant level.
Note what splitting does *not* buy: query speed (the label already bounds
reads) and cross-tenant correlation (one org can no longer graph prod and dev
side by side).

The shared-box corollary: split envs that share one machine are two tenants
on one VM — a shared box like any other, so the agent needs a group
(`group: <project>` on both tenants + a reserved `_infra-<project>`), exactly
as if they were unrelated projects. Merged envs on a dedicated box skip that
entirely.

```yaml
# Split example: dev is log-heavy — protect prod's quota, trim dev's logs.
tenants:
  - id: visual-scoring-prod
    display_name: Visual Scoring (production)
    group: visual-scoring        # both envs share one VM
    metrics_retention: 90d
  - id: visual-scoring-dev
    display_name: Visual Scoring (development)
    group: visual-scoring
    logs_retention: 168h         # 7d — the noisy env keeps a short tail
reserved:
  - id: _infra-visual-scoring    # required by the group
```

A misconfigured app is the residual risk of merging: `deployment_environment`
is self-declared, so a dev deploy claiming `production` pollutes prod
*dashboards* (never another tenant). If that must be impossible rather than
unlikely, that's an audience/wall requirement — split.

## Naming conventions

- **tenant id** — lowercase slug `[a-z0-9-]`, enforced by `make render`. It
  ends up in the Caddyfile, S3 prefixes, and Grafana datasource uids. Name it
  after the project, not a person or machine: `rtd-backend`,
  `visual-scoring`.
- **service_name** — `<project>-<app>`: `test-proj-b-app`, `rtd-backend-api`.
  Never leave a library default (`node-test-service`, `unknown_service`) —
  the name is how you find the app in every dashboard, and old data keeps the
  old name forever (a rename starts a new series, it doesn't rewrite
  history).
- **vm** — role + index: `project-alpha-web-1`. Stable for the machine's
  life; the agent also pins the metric `instance` label to it so series don't
  churn when containers recreate.
- **deployment_environment** — one of a small fixed set (`dev`, `test`,
  `staging`, `prod`). It's an indexed label; don't invent per-branch values.

## "I'm adding X — what do I create?"

| Adding… | Tenant? | Token? | What you actually do |
|---|---|---|---|
| a microservice to an existing project | no | no — reuse the project's | new `OTEL_SERVICE_NAME`, same `OTEL_EXPORTER_OTLP_HEADERS` |
| an environment of an existing app | usually no | no | set `deployment.environment` in `OTEL_RESOURCE_ATTRIBUTES`; split it into its own tenant only when it needs its own limits/retention — see [One tenant per environment, or one for all?](#one-tenant-per-environment-or-one-for-all) |
| a dedicated VM for a project | no | no — reuse the project's | install the agent with the project token + a new `VM_NAME` |
| a new project | **yes** | auto-generated | add it to `tenants.yaml`, `make reload` |
| a shared VM for several projects | yes — reserved `_infra-<group>` | auto-generated | add the reserved tenant + `group:` on each project, `make reload`; the agent gets the group token |
| a team member who should see dashboards | no | no | add them to the project's Grafana org as **Editor** (never org Admin — see the README security note) |

## Mistakes this model prevents (all observed)

- **"Data arrives as `node-test-service`"** — the app never set
  `OTEL_SERVICE_NAME`, so a library default leaked through. The tenant was
  right (the token did its job); the filter was wrong.
- **"Project B can't see its own machine"** — a shared VM's agent was given
  project A's token. Machine-level identity belongs to the group, not to any
  project.
- **"Two apps — do I need a second token?"** — no. Tokens are tenant-scoped;
  apps are told apart by `service_name`.
- **"Can I set X-Scope-OrgID from my app?"** — you can send it; the edge
  replaces it with the one derived from your token.
