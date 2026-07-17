# Instrumenting your app

How to wire an application's OpenTelemetry SDK for this platform so the
telemetry is cheap (no cardinality blow-ups), easy to query, and correlated
across metrics, logs, and traces.

> **The one rule:** identify your service with a few stable, low-cardinality
> resource attributes. Put every high-cardinality detail (IDs, emails, raw
> URLs) in span/log attributes — never in metric labels or log stream labels.

Everything below is that rule, applied.

## The 2-minute version

**1. Get two values from your platform admin:**

| You need | Looks like | What it is |
|---|---|---|
| Edge URL | `https://lgtm.runtheday.com` | where telemetry is sent |
| Project token | `ptk_a1b2c3…` | your project's credential — keep it secret |

**2. Set these environment variables on your app** (no code changes; every
OTel SDK reads them):

```bash
OTEL_SERVICE_NAME=checkout-api                       # name THIS app (stable, human)
OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=production
OTEL_EXPORTER_OTLP_ENDPOINT=https://<edge-host>:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <your project token>
```

**3. Restart the app.** Within ~30s it shows up in your project's Grafana.

The two fields that matter most are `OTEL_SERVICE_NAME` (name it well) and
the token (keep it secret). The rest of this page is how to go from
"working" to "fast, cheap, and correlated".

> **You never set your tenant.** Which project the data belongs to is decided
> by your token at the edge — not by any attribute you send. There is no
> `tenant=` field to set, and setting `service.namespace` to another
> project's name does nothing across the boundary.

## 1. Identify your service (resource attributes)

Resource attributes describe who is sending and are attached to every signal.
Set them once at SDK startup.

| Attribute | Example | Why it matters on this platform |
|---|---|---|
| `service.name` **(required)** | `checkout-api` | The anchor: becomes the Loki `service_name` stream label, the Tempo service, and the primary grouping for metrics. One stable, human name per deployable — not per replica |
| `service.namespace` | `shop` | Groups related services (a team, a bounded context) |
| `service.version` | `1.4.2` | Correlate a latency/error change to a deploy |
| `deployment.environment.name` | `production` | Promoted to a `deployment_environment` label on metrics and spans, and a span-metrics dimension (§7). Keep it to a tiny set: `production`, `staging`, `dev` |
| `service.instance.id` | `checkout-api-7f9c` (pod name) | Distinguishes replicas. Must be bounded — a pod/host name, never a random per-process UUID |

Set them with standard env vars:

```bash
OTEL_SERVICE_NAME=checkout-api
OTEL_RESOURCE_ATTRIBUTES=service.namespace=shop,service.version=1.4.2,deployment.environment.name=production
```

A missing `service.name` lands everything under `unknown_service` — an
unsearchable pool shared with every other unlabelled sender.

## 2. The cardinality rule — what becomes an indexed label

Cardinality is how many distinct values a label can take. Each distinct
combination of label values is a separate stored series/stream; a label
holding user IDs means millions of series, slow queries, and eventually
rejected writes. This is the most common way a tenant gets wrecked.

What gets indexed, per signal:

| Signal | What becomes an indexed label | What stays cheap |
|---|---|---|
| Metrics (Mimir) | **every attribute on the datapoint** becomes a Prometheus label | keep the attribute set small and bounded |
| Logs (Loki) | only `service_name` (+ platform infra labels); other attributes become structured metadata — queryable with `\| key="value"`, not indexed | attach attributes freely; they don't cost a stream |
| Traces (Tempo) | nothing — all span attributes are searchable with no per-series cost | rich, high-cardinality detail belongs here |

Never put these in a metric label or log stream label: `user_id`,
`request_id`, `trace_id`, `session_id`, `order_id`, `email`, a full URL with
an ID in it, a raw timestamp, or any random UUID. Put them instead in:

- **Span attributes** (traces) — searchable, no cardinality cost. First choice.
- **Log attributes / the log body** — becomes structured metadata.
- **Metric exemplars** — attach a `trace_id` to a histogram sample to jump
  from a latency spike to an example trace without making it a label.

Rule of thumb: a label value should come from a set you could write down — a
few hundred values at most. If you can't enumerate it, it isn't a label.

## 3. Metrics — keep labels bounded

- Label with templated routes, not raw paths: `http.route="/users/{id}"`,
  never `http.target="/users/48213"` (one series per user).
- Prefer standard instruments and semconv metric names
  (`http.server.request.duration`, `db.client.operation.duration`) so
  dashboards and alerts understand them.
- Use histograms for latency (they unlock p95/p99); default bucket boundaries
  are fine to start.
- Don't emit a counter per entity: `orders_total{customer="…"}` is a trap;
  `orders_total{status="paid|failed"}` is right.

## 4. Logs — structured, and linked to traces

- Emit structured logs (JSON or the OTel logs SDK), not printf strings.
- Include `trace_id` and `span_id` on every log line emitted inside a
  request. The platform's Loki datasource has a derived field on `trace_id` —
  one click jumps from a log to its trace. Most SDK log bridges inject these
  automatically once tracing is on.
- Keep the stream identity to `service.name`. Everything else (`user_id`,
  `route`, `status`) goes in as attributes, filterable with
  `{service_name="checkout-api"} | user_id="…"` without creating a new
  stream.
- Log at sensible levels; a debug-per-request firehose is expensive even when
  cheap to label.

## 5. Traces — the home for rich detail

- Name spans by low-cardinality operation, not by value: `GET /users/{id}`,
  not `GET /users/48213`. The span name is a span-metrics dimension (§7).
- Set `span.kind` (server/client/producer/consumer) and status (ok/error) —
  these drive the platform's auto-generated RED metrics.
- Follow semantic conventions (`http.*`, `db.*`, `messaging.*`, `rpc.*`) so
  the service graph and span views render properly.
- User IDs, order IDs, SQL statements, and full URLs belong here as span
  attributes: high cardinality is free in Tempo and invaluable when
  debugging.

## 6. Correlation — the payoff for consistency

With the same conventions on all three signals:

- Same `service.name` everywhere → metrics, logs, and traces line up per service.
- `trace_id` in logs → log ↔ trace navigation (Loki derived field → Tempo).
- Exemplars on metrics → metric spike ↔ example trace.
- `deployment_environment` on everything → filter an entire environment in
  one expression, on any signal.
- Traces → logs is pre-wired (Tempo's *Trace to logs* jumps to the matching
  `service_name` in Loki).

## 7. What this platform does with your data

- **Endpoint and auth** — send OTLP/HTTP to the edge with your project token;
  the edge stamps your tenant. No or invalid token → `401`; the data never
  enters the stack.
- **`deployment.environment[.name]` → `deployment_environment`** — the
  collector promotes either spelling to one consistent key on metrics and
  spans.
- **Span metrics (RED) are auto-generated** from traces with dimensions
  `service, span_name, span_kind, status_code, deployment_environment`.
  Every one must be low-cardinality — this is why span names must be
  templated.
- **`service.name` → `service_name`** Loki label; all other log attributes →
  structured metadata (queryable, not indexed).
- **`trace_id`** in a log becomes a clickable link to the trace.

## 8. Cardinality offenders — find and fix

The checklist for what quietly blows up a tenant, and the value to set
instead. Many of these come from auto-instrumentation defaults — you didn't
type them, the agent did.

### A. Resource attributes (identity)

| Attribute | Default danger | Set it to |
|---|---|---|
| `service.instance.id` | OTel agents default this to a random UUID per process start, and it becomes the metric `instance` label in Mimir → a fresh series-set every restart. (Logs are safe: the platform keeps it out of the Loki index as structured metadata) | A stable per-replica id via `OTEL_RESOURCE_ATTRIBUTES` (there is no dedicated env var): `…,service.instance.id=checkout-api-1`. Use the pod name or host — not one constant shared by all replicas |
| `service.version` | A new value every deploy keeps many series alive under a busy cadence | Keep it — deploy correlation is worth it — but use a clean version (`1.4.2`), never a build timestamp or SHA+time |
| `deployment.environment.name` | Templated with a hostname/branch/build id, it stops being a 3-value enum | A tiny enum: `production` / `staging` / `dev` |
| `service.namespace` | A per-instance or per-region value turns a grouping key into cardinality | A few stable group names |
| `host.name`, `container.id`, `k8s.pod.uid` | Auto-added and high-cardinality | Leave them — on this platform they land in structured metadata / `target_info`, not indexed labels, so they're safe as long as you don't copy them onto metric datapoints |

### B. Metric datapoint attributes (every one becomes a Prometheus label)

| Offender | Why it explodes | Set it to |
|---|---|---|
| `http.target`, `url.path`, `http.url`, `url.full` | one series per distinct URL | `http.route` — the templated route; drop the raw ones from metrics |
| `db.statement` / `db.query.text` | one series per query shape × values | never a metric label; span attribute only, parameterized |
| `user_agent.original` | thousands of UA strings | off metrics; span/log attribute if needed |
| `client.address`, `server.address`, `net.peer.*` | per-client IP/host | off metrics |
| `messaging.destination.name` | per-entity queue/topic names | templated destination, or off metrics |
| any `*.id` — `user_id`, `order_id`, `session_id`, `enduser.id` | unbounded | span attribute, never a label |
| `exception.message`, `exception.stacktrace` | unique per error | off labels; `exception.type` is bounded and fine |
| label **combinations** | even bounded labels multiply: env(3) × route(50) × method(5) × status(8) × instance(20) ≈ 120k series for one metric | keep the label set small; question every added dimension |

### C. Metric names and instruments

| Offender | Why | Set it to |
|---|---|---|
| a counter per entity (`orders_total{customer="…"}`) | one series per customer | bounded dimensions: `orders_total{status="paid\|failed"}`; customer goes on a span |
| a metric name with an embedded id (`queue_depth_orders_48213`) | one metric per id | one metric, id as a bounded label or not at all |
| hand-rolled histograms with many custom buckets | buckets × every label combo | SDK default buckets; tune only with a reason |

### D. Logs (Loki)

The platform curates what Loki indexes down to a low-cardinality allow-list —
`service_name`, `service_namespace`, `deployment_environment[_name]`, and
bounded `cloud.*` / `k8s.*` names — and pushes everything else to structured
metadata. High-churn attributes (`service_instance_id`, `k8s_pod_name`,
`k8s_replicaset_name`, `k8s_job_name`) are deliberately kept out of the index
so a random instance id or a rolling deploy can't explode your streams. The
rule for you: don't try to promote high-cardinality fields to stream labels —
attach them as attributes and they cost nothing.

### Find your offenders

```bash
# 1) Loki — how many stream labels are indexed? Expect a short list (~4-6).
curl -s -H "X-Scope-OrgID: <your-tenant>" \
  "$EDGE/loki/api/v1/labels" | jq '.data'

# 2) Loki — cardinality of a suspect label:
curl -s -H "X-Scope-OrgID: <your-tenant>" \
  "$EDGE/loki/api/v1/label/service_instance_id/values" | jq '.data | length'

# 3) Mimir — your 10 highest-series metrics (run in Grafana Explore):
topk(10, count by (__name__)({__name__=~".+"}))

# 4) Mimir — is `instance` churning?
count(count by (instance) (up{service_name="<your-service>"}))
```

If (1) shows more than the expected labels, or (4) climbs every deploy,
you've found a churn source — map it to the tables above.

## 9. Copy-paste starter

```bash
# --- identity (resource attributes) ---
OTEL_SERVICE_NAME=checkout-api
# Pin service.instance.id to a STABLE per-replica value (no dedicated env var
# exists). Otherwise the agent mints a random UUID -> a new metric `instance`
# series-set every restart. On k8s use the pod name.
OTEL_RESOURCE_ATTRIBUTES=service.namespace=shop,service.version=1.4.2,deployment.environment.name=production,service.instance.id=checkout-api-1

# --- where to send it ---
OTEL_EXPORTER_OTLP_ENDPOINT=https://<edge-host>:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <your project token>

# --- optional: sample high-volume traces ---
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1        # keep 10% of traces; metrics/logs stay 100%
```

### Checklist

- [ ] `service.name` set, stable, one per deployable (not per replica).
- [ ] `service.instance.id` pinned to a stable value (not the default random UUID).
- [ ] `deployment.environment.name` from a tiny enumerated set.
- [ ] No user/request/order IDs in metric labels or log stream labels.
- [ ] `http.route` (templated) on metrics, not raw paths.
- [ ] Span names are operations (`GET /users/{id}`), not values.
- [ ] Logs are structured and carry `trace_id`.
- [ ] Rich, high-cardinality detail lives on span attributes.
- [ ] Latency uses histograms; traces are sampled if high-volume.

See also [querying-and-retention.md](querying-and-retention.md) (the query
cost model) and [data-lifecycle.md](data-lifecycle.md) (when data is in
memory vs on disk vs in S3).
