# Instrumenting your app — what to send for the best telemetry

This is for a developer wiring an app's OpenTelemetry SDK at the platform. Follow
it and you get telemetry that's **cheap** (won't blow up cardinality), **easy to
query**, and **correlated** across metrics, logs, and traces. Ignore it and you
get a slow, expensive tenant where nothing links up.

> **The one rule:** *Identify your service with a few **stable, low-cardinality**
> resource attributes. Put every high-cardinality detail (IDs, emails, raw URLs)
> in **span/log attributes** — never in metric labels or log stream labels.*

Everything below is that rule, applied.

---

## Start here — the 2-minute version

New to this? Don't read the whole page yet. Do these three things and you'll have
working telemetry; come back for §2 onward when you want it *good*.

**1. Get two values from your platform admin:**

| You need | Looks like | What it is |
|---|---|---|
| **Edge URL** | `https://lgtm.runtheday.com` | where telemetry is sent |
| **Project token** | `ptk_a1b2c3…` | your project's password — **keep it secret** |

**2. Set these environment variables on your app** (no code changes — every OTel SDK reads them):

```bash
OTEL_SERVICE_NAME=checkout-api                       # name THIS app (pick a stable, human name)
OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=production   # prod / staging / dev
OTEL_EXPORTER_OTLP_ENDPOINT=https://<edge-host>:4318 # the Edge URL above
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <your project token>
```

**3. Restart your app.** Within ~30s it shows up in your project's Grafana. Done.

That's the whole minimum. The two fields that matter most — and the only ones you
*must* think about — are `OTEL_SERVICE_NAME` (name it well) and the token (keep it
secret). Everything below this line is how to go from "working" to "fast, cheap,
and correlated."

> **You never set your tenant.** Which project's data this becomes is decided by
> your **token** at the edge — not by any attribute you send. So there's no
> `tenant=` or `project=` field to set, and setting `service.namespace` to another
> project's name does **nothing** (it can't cross the boundary; see §1). One less
> thing to get wrong.

---

## 1. Identify your service (resource attributes)

Resource attributes describe *who is sending* and are attached to every signal.
Set them **once** at SDK startup. These are the backbone of querying and
correlation — get them right and the rest falls into place.

| Attribute | Example | Why it matters **on this platform** |
|---|---|---|
| `service.name` **(required)** | `checkout-api` | The anchor. Becomes the Loki **`service_name`** stream label, the Tempo **service**, and the primary grouping for metrics. Pick one **stable, human** name per deployable — *not* per replica/pod. |
| `service.namespace` | `shop` | Groups related services (a team, a bounded context). Lets you query "all of shop". |
| `service.version` | `1.4.2` | Correlate a latency/error change to a deploy. |
| `deployment.environment.name` | `production` | The platform **promotes** this to a `deployment_environment` label on metrics + spans, and it's a **span-metrics dimension** (see §7). Keep it to a tiny set: `production`, `staging`, `dev`. |
| `service.instance.id` | `checkout-api-7f9c` (pod name) | Distinguishes replicas. Must be **bounded** — a pod/host name, *never* a random per-process/per-request UUID. |

Set them with standard env vars — no code needed:

```bash
OTEL_SERVICE_NAME=checkout-api
OTEL_RESOURCE_ATTRIBUTES=service.namespace=shop,service.version=1.4.2,deployment.environment.name=production
```

> `service.name` is the single most important field. A missing one lands
> everything under `unknown_service` — your logs and traces become an
> unsearchable soup shared with every other unlabelled sender.

---

## 2. The cardinality rule — what becomes an indexed label

"Cardinality" = how many distinct values a label can take. Each distinct
combination of label values is a **separate stored series/stream**. A label that
can take a user's ID has *millions* of values → millions of series → slow queries,
huge storage, and eventually rejected writes. This is the #1 way teams wreck a
tenant.

**What gets indexed, per signal:**

| Signal | What becomes an indexed label | What stays cheap |
|---|---|---|
| **Metrics (Mimir)** | **Every attribute on the datapoint** becomes a Prometheus label. High-card attribute = series explosion. | Keep the attribute set small + bounded. |
| **Logs (Loki)** | Only **`service_name`** (+ platform infra labels). Your other attributes become **structured metadata** — still queryable with `\| key="value"`, but *not* an indexed stream label. | Attach freely; they don't cost a stream. |
| **Traces (Tempo)** | Nothing is a "label" — **all** span attributes are searchable, with no per-series tax. | This is where rich, high-card detail belongs. |

**Never put these in a metric label or a log stream label** — `user_id`,
`request_id`, `trace_id`, `session_id`, `order_id`, `email`, a full URL with an
ID in it, a raw timestamp, or any random UUID.

**Put them instead in:**
- **Span attributes** (traces) — searchable, no cardinality cost. First choice.
- **Log attributes / the log body** (logs) — becomes structured metadata.
- **Metric exemplars** — attach a `trace_id` to a histogram sample to jump from a
  latency spike straight to an example trace, *without* it being a label.

> **Rule of thumb:** a label value should come from a set you could **write down**
> — a few hundred values at most. If you can't enumerate it, it isn't a label.

---

## 3. Metrics — keep labels bounded

- Label with **templated routes, not raw paths**: `http.route="/users/{id}"` ✅ —
  never `http.target="/users/48213"` ❌ (that's one series per user).
- Prefer **standard instruments and semconv metric names** (`http.server.request.duration`,
  `db.client.operation.duration`) so dashboards and alerts understand them.
- Use **histograms** for latency (they unlock p95/p99), but don't hand-roll dozens
  of custom buckets — the default boundaries are fine to start.
- Don't emit a counter per entity. `orders_total{customer="…"}` is a trap;
  `orders_total{status="paid|failed"}` is right.

---

## 4. Logs — structured, and linked to traces

- Emit **structured logs** (JSON or the OTel logs SDK), not printf strings.
- **Include `trace_id` and `span_id`** on every log line emitted inside a request.
  The platform's Loki datasource has a **derived field on `trace_id`** — one click
  jumps from a log to its full trace. Most SDK log bridges (OTel appender, or a
  logging instrumentation) inject these automatically once tracing is on.
- Keep the **stream identity to `service.name`**. Everything else — `user_id`,
  `route`, `status` — goes in as attributes (structured metadata), filterable with
  `{service_name="checkout-api"} | user_id="…"` without ever creating a new stream.
- Log at sensible levels; a debug-per-request firehose is expensive even when cheap
  to label.

---

## 5. Traces — the home for rich detail

- Name spans by **low-cardinality operation**, not by value: `GET /users/{id}` ✅,
  not `GET /users/48213` ❌. The span **name** is a span-metrics dimension (§7).
- Set **`span.kind`** (server/client/producer/consumer) and the **status**
  (ok/error) — these drive the platform's auto-generated RED metrics.
- Follow **semantic conventions** (`http.*`, `db.*`, `messaging.*`, `rpc.*`) so the
  service graph and span views render properly.
- This is where user IDs, order IDs, SQL statements, and full URLs belong — as span
  attributes. High cardinality is *free* here and priceless when debugging.

---

## 6. Correlation — the payoff for consistency

When the same conventions run through all three signals, you get one pane of glass:

- **Same `service.name` everywhere** → metrics, logs, and traces line up per service.
- **`trace_id` in logs** → log ↔ trace navigation (Loki derived field → Tempo).
- **Exemplars on metrics** → metric spike ↔ example trace.
- **`deployment_environment` on everything** → filter or split an entire env in one
  expression, on any signal.
- **Traces → logs** is pre-wired too (Tempo's *Trace to logs* jumps to the matching
  `service_name` in Loki).

---

## 7. What THIS platform does with your data

Grounding the advice above in the actual stack config, so you know why it matters:

- **Endpoint & auth** — send OTLP/HTTP to the edge with your project token; the edge
  stamps your tenant (you never set it):
  ```bash
  OTEL_EXPORTER_OTLP_ENDPOINT=https://<edge-host>:4318      # or http://localhost:4318 locally
  OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
  OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <your project token>
  ```
  No/invalid token → `401` at the edge; the data never enters the stack.
- **`deployment.environment[.name]` → `deployment_environment`** — the collector
  promotes either spelling to a `deployment_environment` attribute on metrics and
  spans, so dashboards filter on one consistent key.
- **Span-metrics (RED) are auto-generated** from your traces with dimensions
  `service, span_name, span_kind, status_code, deployment_environment`. Every one of
  those must be **low-cardinality** — this is exactly why span names must be templated.
- **`service.name` → `service_name`** Loki label; all other log attributes →
  structured metadata (queryable, not indexed).
- **`trace_id`** in a log is turned into a **clickable link to the trace**.

---

## 8. Cardinality offenders — find them, fix them, or set the right value

This is the checklist for *"what could quietly blow up my tenant, and what should
it be instead."* Every row is something that either explodes series/streams or
churns them on each deploy/restart. The **Set it to** column is the fix.

> Many of these come from **auto-instrumentation defaults** — you didn't type them,
> the agent did. The first table is the one that bites people who "just attached the
> agent and it worked" (it did — until the series count crept up).

### A. Resource attributes (identity — indexed as Loki labels, and metric identity)

| Attribute | Default danger | Set it to |
|---|---|---|
| `service.instance.id` | **The OTel agents default this to a random UUID per process start**, and it becomes the metric **`instance`** label in Mimir → a **fresh series-set every restart**. (Logs are safe — the platform keeps this out of the Loki index as structured metadata — so this is now a **metrics** concern, not logs.) | A **stable, per-replica** id: pod name (k8s downward API), host, or `service-1`. `OTEL_SERVICE_INSTANCE_ID=checkout-api-1`. **Not** a single constant shared by all replicas (they'd collide and you couldn't tell them apart). |
| `service.version` | New value every deploy → a fresh set of series each release (they age out, but a busy deploy cadence keeps many alive). | Keep it — deploy-correlation is worth it — but use a **clean version** (`1.4.2`), never a build timestamp or full git SHA+time. |
| `deployment.environment.name` | If templated with a hostname, branch, or build id it stops being a 3-value enum. | A tiny enum: `production` / `staging` / `dev`. Nothing else. |
| `service.namespace` | A per-instance or per-region value turns a grouping key into cardinality. | A few stable group names (team / bounded context). |
| `host.name`, `container.id`, `k8s.pod.uid` | Auto-added and **high-cardinality** (new per container/pod). | Leave them — on this platform they land in **structured metadata / `target_info`, not indexed labels or metric labels**, so they're safe *as long as you don't manually copy them onto metric datapoints*. Don't. |

### B. Metric datapoint attributes (⚠ **every attribute becomes a Prometheus label** — a series multiplier)

| Offender | Why it explodes | Set it to |
|---|---|---|
| `http.target`, `url.path`, `http.url`, `url.full` | Raw path/URL = **one series per distinct URL** (with the id in it). | `http.route` — the **templated** route (`/users/{id}`). Drop the raw ones from metrics. |
| `db.statement` / `db.query.text` | Raw SQL with literals = one series per query shape × values. | Never a metric label. Span attribute only, **parameterized** (agents sanitize by default — keep it). |
| `user_agent.original` | Thousands of UA strings. | Off metrics. Span/log attribute if needed. |
| `client.address`, `server.address`, `net.peer.*` | Per-client IP/host. | Off metrics. |
| `messaging.destination.name` | Per-entity queue/topic names (e.g. `orders.user.48213`). | Templated destination, or off metrics. |
| any `*.id` — `user_id`, `order_id`, `session_id`, `enduser.id` | Unbounded. | Never a metric label or log stream label → **span attribute**. |
| `exception.message`, `exception.stacktrace` | Unique per error. | Off labels. `exception.type` (the class) is bounded and fine. |
| **Label _combinations_** | Even bounded labels **multiply**: env(3) × route(50) × method(5) × status(8) × instance(20) ≈ 120k series for **one** metric. | Keep the label set small; question every added dimension. |

### C. Metric names & instruments

| Offender | Why | Set it to |
|---|---|---|
| A counter **per entity** (`orders_total{customer="…"}`) | One series per customer. | Bounded dimensions: `orders_total{status="paid\|failed"}`. Put the customer on a span. |
| Metric **name** with an embedded id (`queue_depth_orders_48213`) | One metric per id — worse than a label. | One metric, id as a bounded label or not at all. |
| Hand-rolled histograms with many custom buckets | buckets × every label combo. | Start with SDK default buckets; only tune when you have a reason. |

### D. Logs (Loki)

The platform curates what Loki indexes down to a **low-cardinality allow-list** and
pushes everything else to **structured metadata** (queryable with `| key="value"`,
*not* an indexed stream label). Indexed: `service_name`, `service_namespace`,
`deployment_environment[_name]`, and bounded `cloud.*` / `k8s.*` names. Deliberately
kept **OUT** of the index (as structured metadata) are the high-churn attributes —
`service_instance_id`, `k8s_pod_name`, `k8s_replicaset_name`, `k8s_job_name` — so a
random instance id or a rolling deploy's pod names can't explode your log streams.
Everything else (`trace_id`, `thread`, `level`, your `user_id`) is structured
metadata too. The log rule for you is simple: **don't try to promote high-card fields
to stream labels** — attach them as attributes and they cost nothing.

### Find your offenders (run against your own tenant)

```bash
# 1) Loki — how many stream labels are indexed? Expect a short list (~4-6).
#    If you see trace_id / thread / an *_id here, something is over-promoting it.
curl -s -H "X-Scope-OrgID: <your-tenant>" \
  "$EDGE/loki/api/v1/labels" | jq '.data'

# 2) Loki — cardinality of a suspect label (how many distinct values):
curl -s -H "X-Scope-OrgID: <your-tenant>" \
  "$EDGE/loki/api/v1/label/service_instance_id/values" | jq '.data | length'

# 3) Mimir — your 10 highest-series metrics (the usual explosion suspects):
#    (run in Grafana Explore on your Mimir datasource)
topk(10, count by (__name__)({__name__=~".+"}))

# 4) Mimir — is `instance` churning? distinct instances for your service:
count(count by (instance) (up{service_name="<your-service>"}))
```

If (1) shows more than the expected labels, or (4) climbs every deploy, you've found
a churn source — map it back to the tables above and set the proper value.

---

## 9. Copy-paste starter

```bash
# --- identity (resource attributes) ---
OTEL_SERVICE_NAME=checkout-api
OTEL_RESOURCE_ATTRIBUTES=service.namespace=shop,service.version=1.4.2,deployment.environment.name=production
# pin the instance id to a STABLE per-replica value — the agent otherwise defaults
# it to a random UUID that mints a new metric `instance` series-set every restart
# (see §8.A; logs are unaffected — the platform keeps it out of the Loki index).
OTEL_SERVICE_INSTANCE_ID=checkout-api-1        # k8s: use the pod name

# --- where to send it ---
OTEL_EXPORTER_OTLP_ENDPOINT=https://<edge-host>:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <your project token>

# --- optional: sample high-volume traces (keep cost sane) ---
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1        # keep 10% of traces; metrics/logs stay 100%
```

### Checklist

- [ ] `service.name` set, stable, one per deployable (not per replica).
- [ ] `service.instance.id` pinned to a **stable** value (not the default random UUID).
- [ ] `deployment.environment.name` set to a tiny enumerated set.
- [ ] No user/request/order IDs in **metric labels** or **log stream labels**.
- [ ] `http.route` (templated) on metrics, **not** raw paths.
- [ ] Span names are operations (`GET /users/{id}`), not values.
- [ ] Logs are structured and carry `trace_id`.
- [ ] Rich, high-card detail lives on **span attributes**.
- [ ] Latency uses **histograms**; traces are **sampled** if high-volume.

---

See also [querying-and-retention.md](querying-and-retention.md) (how to query what
you sent, and why retention works the way it does) and
[data-lifecycle.md](data-lifecycle.md) (when data is in memory vs on disk vs in S3).
