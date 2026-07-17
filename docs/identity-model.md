# Identity model — tenant, token, service, VM

Read this once and the whole platform makes sense. Every piece of telemetry
carries a handful of identities, and each answers a different question.

There are **two streams** producing telemetry, and each identity belongs to one
or both:

- **APP** — your application's OTel SDK, pushing traces/logs/metrics with the
  project token.
- **INFRA** — the VM agent (Alloy), pushing the machine's host + container
  telemetry with its own token. Everything on this path is stamped
  `telemetry_source=infra`, which is how the two streams share a tenant without
  being confused for each other (app dashboards filter it out with
  `telemetry_source!="infra"`).

| Identity | Question it answers | Stream | Who sets it | Security boundary? |
|---|---|---|---|---|
| **tenant** (`X-Scope-OrgID`) | *whose data is this?* | both | the **edge** (Caddy), from the token — never the sender | **YES — the only one** |
| **service_name** | *which app / which unit?* | both | APP: `OTEL_SERVICE_NAME` · INFRA: derived (see below) | no — just a label |
| **deployment_environment** / **environment** | *dev / test / prod?* | both | APP: `OTEL_RESOURCE_ATTRIBUTES` · INFRA: `perceptor.environment` container label | no |
| **vm** | *which machine?* | **infra only** | the agent (`VM_NAME` in its `.env`) | no |
| **telemetry_source** | *app stream or infra stream?* | infra only (`=infra`) | the agent, hardcoded | no |
| **job** | *which infra source?* (`docker` / `systemd-journal` / `nginx`) | infra only | the agent config | no |
| **container** | *which container?* | infra only | the agent (from the Docker name) | no |

App telemetry never carries `vm`, `job`, or `container` — if you see those, you
are looking at the infra stream. Infra telemetry never carries an app's
`OTEL_SERVICE_NAME` — its `service_name` is derived per source:

| Infra source | Its `service_name` becomes |
|---|---|
| container logs (opted-in) | `perceptor.service_name` compose label, else the container name |
| host/system logs (journald) | the systemd unit (`cron.service`, `sshd.service`, …) |
| host nginx logs | `nginx` |

The one-sentence version: **the tenant is a wall; everything else is a filter.**
Walls are enforced by the platform. Filters are self-declared by apps and agents
and exist so dashboards can slice data — nothing stops an app from lying about
its own `service_name`, and that's fine, because it can only ever lie *inside
its own tenant*.

---

## Tokens are TENANT-scoped. Full stop.

One token per tenant, generated into `tenants.secrets.yaml` by `make render`.
Not per service. Not per VM. Not per environment.

```
tenant  test-proj-b   ──►  ptk_sU95…   (exactly one)
```

What a token does: Caddy matches it and stamps `X-Scope-OrgID: test-proj-b` on
the request. That's all. Which means:

- **Every service of a project shares the project's one token.** Ten
  microservices, one token — they differ by `OTEL_SERVICE_NAME`, not by
  credential.
- **A token is write-only.** It can push telemetry into its tenant; it can never
  read anything. Reading happens in Grafana, through org-pinned datasources.
- **A leaked token pollutes one tenant** — it can't read data, and can't write
  anywhere else. Rotate it by deleting its line in `tenants.secrets.yaml` and
  running `make render` + `make reload` (every exporter using it then needs the
  new value).
- **Apps never send `X-Scope-OrgID` themselves.** The edge would ignore it
  anyway: tenant comes from the token, and only from the token. A VM is never
  trusted to name its own tenant.

If you're ever unsure what a token "belongs to", the file *is* the answer —
`tenants.secrets.yaml` is a flat `tenant-id: token` map.

## How the identities nest

```
tenant: test-proj-b                      ← the wall (one token, one Grafana org)
├── service_name: test-proj-b-app       ← an app       (set by OTEL_SERVICE_NAME)
│   ├── deployment_environment: test    ← its env      (set by the app)
│   └── deployment_environment: prod
├── service_name: test-proj-b-worker    ← another app, SAME token
└── (infra, if dedicated VM): vm=proj-b-vm-1   ← host metrics/logs, SAME tenant
```

A concrete line of telemetry from each stream, as stored:

```
APP:    tenant=test-proj-b  service_name=test-proj-b-app  deployment_environment=test   → one trace
INFRA:  tenant=_infra-test-shared-vm  telemetry_source=infra  vm=tushar-test-shared-vm
        job=docker  container=proj-b-otel-test-1  service_name=test-proj-b-app          → one container log line
```

Note the last one: the *same app* appears in both streams under the same
`service_name` — its SDK pushes app telemetry to `test-proj-b`, while the VM
agent independently ships that container's stdout to the group's infra tenant.
Two paths, two tenants, one name — that's `perceptor.service_name` doing its
job of keeping the identities aligned.

## VMs — the one place tokens get subtle

A VM runs **one agent** carrying **one token**, and that token decides where the
*whole machine's* infra (host metrics, container metrics, opted-in container
logs) lands. Two cases:

| The VM is used by… | Agent's token | Infra lands in |
|---|---|---|
| **one project** (dedicated VM) | that project's token | the project's own tenant, next to its app data |
| **several projects** (shared VM) | the **group's** `_infra-<group>` token | the shared `_infra-<group>` tenant |

Why the shared case can't use a project token: the agent is per-*host*, not
per-project. Give it project A's token and project B's containers get filed
under A — B literally cannot see its own machine. So a shared box gets a
**group**: a reserved tenant `_infra-<group>` holds the machine's infra, and
every project in the group gets a **read-only** extra datasource pair pointed at
it. Everyone on the box can see the box; nobody's app tenant is polluted.

`vm` (from `VM_NAME` in the agent's `.env`) is what tells machines apart *inside*
that tenant — a group with three hosts has three `vm` values in one tenant.

Reserved tenants (ids starting `_`) are platform namespaces: they get a token
and storage like any tenant, but **no Grafana org** — they're read from the
admin org, or via those read-only group datasources.

## Naming conventions

- **tenant id** — lowercase slug `[a-z0-9-]`, enforced by `make render`. It ends
  up in the Caddyfile, S3 prefixes, and Grafana datasource uids. Name it after
  the *project*, not a person or a machine: `rtd-backend`, `visual-scoring`.
- **service_name** — `<project>-<app>`: `test-proj-b-app`, `rtd-backend-api`.
  Never leave a library default (`node-test-service`, `unknown_service`) — the
  name is how you find your app in every dashboard, and old data keeps the old
  name forever (renames don't rewrite history, they just start a new series).
- **vm** — role + index: `project-alpha-web-1`, `tushar-test-shared-vm`. Stable
  for the machine's life; the agent also pins metric `instance` to it so series
  don't churn when containers recreate.
- **deployment_environment** — one of a small fixed set (`dev`, `test`,
  `staging`, `prod`). It's an indexed label; don't invent per-branch values.

## "I'm adding X — what do I create?"

| Adding… | Tenant? | Token? | What you actually do |
|---|---|---|---|
| a new **microservice** to an existing project | no | no — reuse the project's | set a new `OTEL_SERVICE_NAME`, same `OTEL_EXPORTER_OTLP_HEADERS` |
| a new **environment** of an existing app | no | no | set `deployment.environment` in `OTEL_RESOURCE_ATTRIBUTES` |
| a new **dedicated VM** for a project | no | no — reuse the project's | install the agent with the project token + a new `VM_NAME` |
| a new **project** | **yes** | auto-generated | add it to `tenants.yaml`, `make reload` |
| a new **shared VM** for several projects | yes — reserved `_infra-<group>` | auto-generated | add the reserved tenant + `group:` on each project, `make reload`; agent gets the **group** token |
| a new **team member who should see dashboards** | no | no | add them to the project's Grafana org as **Editor** (never org Admin — see the README security note) |

## Mistakes this model prevents (all observed in the wild)

- **"Data arrives as `node-test-service`"** — the app never set
  `OTEL_SERVICE_NAME`, so a library default leaked through. Tenant was right
  (token did its job); the *filter* was wrong.
- **"Project B can't see its own machine"** — a shared VM's agent was given
  project A's token. Machine-level identity is the group's, not any project's.
- **"Two apps, do I need a second token?"** — no. Tokens are tenant-scoped;
  apps are told apart by `service_name`.
- **"Can I just set X-Scope-OrgID from my app?"** — you can send it; the edge
  derives the real one from your token. The header you set never survives.
