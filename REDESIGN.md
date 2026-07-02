# Perceptor Platform — Design

A multi-tenant observability platform for **10–50 projects** with **hard isolation**
between them, running on **Docker Compose**, backed by **object storage**.

This is a ground-up redesign of the original `perceptor/` prototype. It keeps the
Grafana LGTM core but fixes the three things the prototype only gestured at:
real per-project scoping, durable storage, and resilience.

---

## Principle

> **Tenant identity is the project. It is established by a credential at the edge,
> and it is never something the client gets to claim.**

Every signal (metrics/logs/traces) carries one tenant id — the `X-Scope-OrgID`
header — and that id is stamped by the edge gateway after it authenticates the
project's token. A client cannot send data as another project, because it never
chooses its own tenant.

---

## Topology

```
 App SDKs ──TLS──▶  Caddy  (edge gateway)
(one token each)   • authenticates project token
                   • maps token → tenant
                   • injects X-Scope-OrgID
                   • strips client Authorization
                          │
                          ▼
                  OpenTelemetry Collector  (gateway pipeline)
                   • memory_limiter (OOM guard)
                   • per-tenant batching (metadata_keys)
                   • persistent queue (file_storage — survives restarts)
                   • retry_on_failure
                   • fan-out, preserving X-Scope-OrgID
                     │           │            │
                     ▼           ▼            ▼
                  Mimir        Loki         Tempo      ◀ multitenancy ON
                 (metrics)    (logs)      (traces)       tenant = project
                     └───────────┼────────────┘
                                 ▼
                          SeaweedFS  (S3 object storage)
                          • one bucket per signal
                          • lifecycle rules manage old data
                          • env-driven → swap to AWS S3 with no config change

  Grafana (OSS)  ── ONE ORG PER PROJECT ──
                    each org has datasources pinned to its own X-Scope-OrgID;
                    a project's users see only their org → hard read isolation.
```

---

## Why each choice

| Concern | Choice | Why |
|---|---|---|
| Edge / auth / TLS | **Caddy** | Automatic HTTPS for external clients (no cert toil), declarative token→tenant `map`, easy to template per project. |
| Pipeline | **OTel Collector (contrib)** | Vendor-neutral, persistent queue, per-tenant batching, tail-sampling/redaction hooks. (Grafana Alloy is a fine alternative.) |
| Metrics | **Mimir** | Multi-tenant via `X-Scope-OrgID` — *same* mechanism as Loki/Tempo, so tenancy is uniform across all three signals. (VictoriaMetrics is lighter but scopes by URL path, breaking the uniform model.) |
| Logs | **Loki** | LGTM-native multi-tenant logs on object storage. |
| Traces | **Tempo** | Multi-tenant traces on object storage. |
| Storage | **SeaweedFS (S3)** | Apache-2.0, actively maintained, S3-compatible. (MinIO's OSS was archived in early 2026 — avoided.) Durable, lifecycle-managed; data survives a restart. All storage settings are env-driven, so moving to **AWS S3 / R2 / B2 is a `.env` change**, not a config rewrite. |
| Read isolation | **Grafana Organizations** | The only *real* read boundary in OSS. One org per project. |
| Onboarding | **`tenants.yaml` + renderer** | Adding a project = one entry + `make render`. |

---

## How "dedicated scope per project" actually works

1. **Write path** — Caddy authenticates the project's token and stamps
   `X-Scope-OrgID: <project>`. The collector forwards it unchanged to all three
   backends, which store the data under that tenant. Backends have multitenancy
   **enabled**, so tenants are physically separated in storage.

2. **Read path** — Each project gets a Grafana **Org**. That org's datasources
   are pinned (`httpHeaderName1: X-Scope-OrgID`, value = the project). A user in
   project-alpha's org literally cannot construct a query against project-beta's
   data — the only datasources they can see carry alpha's tenant header.

3. **Lifecycle** — Retention and rate/series limits are **per-tenant** via each
   backend's runtime overrides, so each project gets its own retention and a
   noisy project can't starve the others.

---

## Managing old data

- **Per-tenant retention** — `*/overrides.yaml` for Mimir/Loki/Tempo.
- **Bucket lifecycle rules** — expire/transition objects at the storage layer so
  a full disk can never cascade into total loss.
- **Consistent labels** — standardize `service.namespace`, `service.name`,
  `deployment.environment`, `project.id` so historical queries stay navigable.

---

## Honest limits of this design (single box, OSS)

1. **Single-node object storage is a shared failure domain.** With hard isolation
   that is a real risk. Mitigate with a multi-node/replicated SeaweedFS, offsite
   backups, or simply point `.env` at **AWS S3 / R2 / B2** to offload durability
   entirely. Revisit Kubernetes + distributed storage when you outgrow one box.
2. **Grafana OSS org management is manual-ish** — no SSO org auto-mapping, no
   datasource-level RBAC (those are Enterprise). File-based provisioning keeps
   30+ orgs sane, but self-serve client SSO is where OSS stops being enough.
3. **Noisy neighbor** — per-tenant query/ingest limits are mandatory, not optional.

These are deliberate trade-offs for "Compose, medium scale," not oversights.
