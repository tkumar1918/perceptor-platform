# Querying & Retention — how Loki actually works (read this before tuning limits)

This doc exists to prevent a recurring confusion: **"I have a year of data, why
can't I query it?"** The short answer is that Loki is *not* a content-indexed
database, and its limits gate the **width** of a query, not the **age** of the
data. Once you internalize the model below, the limits stop being mysterious.

> The examples use Loki (logs), but the same shape applies to Mimir (metrics)
> and Tempo (traces): a small index + object storage + per-tenant limits.

---

## TL;DR mental model

- **Labels are the index. Line filters are a scan.** `{service="checkout"}`
  picks *which chunks to read*; `|= "error"` is grep over those chunks.
- **Scan cost ≈ (time-window width) × (label selectivity).** Filters reduce what
  is *returned*; labels reduce what is *read*.
- **Grafana does not filter.** It sends your query to Loki; Loki returns only the
  matching lines. Grafana never downloads "all the logs."
- **The limits gate WIDTH, not AGE.** A 1-day query is cheap whether it's from
  yesterday or a year ago. Reaching far back is free *if the data is retained*.
- **Long retention / S3 is for on-demand retrieval of a specific slice**
  (forensics, compliance) — **not** for sweeping a year of raw logs. Long-range
  *trends* come from metrics/rollups, not from scanning raw logs.

---

## 1. Loki is indexed `grep`, not a database

A content-indexed store (Elasticsearch, a SQL DB with the right indexes) indexes
the **content** of every log. `WHERE message CONTAINS 'error'` consults an index
and jumps straight to matches — it never reads non-matching data. Price: large,
expensive indexes (often 5–10× the storage).

Loki made the **opposite trade-off on purpose**:

| | Loki | Content-indexed DB (e.g. Elasticsearch) |
|---|---|---|
| Indexes log **content**? | ❌ no | ✅ yes |
| Indexes **labels** (stream metadata)? | ✅ small index | ✅ |
| Content search = | **scan** selected chunks (grep) | index lookup |
| Storage cost | cheap (compressed blobs) | expensive (big index) |
| Broad / wildcard search | reads all matching bytes | bounded by index |

So Loki ≈ *"grep over compressed files in object storage, with labels as a coarse
index that picks which files to grep."* **Labels are the only real index.**

---

## 2. The cost model: width × selectivity

Two different parts of a LogQL query do two different jobs:

1. **Label selector** `{service="checkout", env="prod"}` → consulted against the
   index to decide **which chunks get read** from object storage.
2. **Filter expression** `|= "order-123"`, `| json | level="error"` → applied by
   the queriers by **scanning the lines** in those chunks. Not indexed.

Therefore:

```
bytes scanned  ≈  (how wide your time window is)  ×  (how much your labels select)
```

- `{service="checkout"} |= "order-123"` over 60 days → reads only checkout's
  chunks for 60 days. Bounded.
- `{} |= "order-123"` over 60 days → reads **every** chunk in the tenant for 60
  days. Same result count, enormous scan.

**The line filter changes what is returned, not what is read. The label selector
changes what is read.** This is the single most important sentence in this doc.

---

## 3. Grafana does not filter — Loki does

Grafana sends the full LogQL (selector **and** filters) to Loki's `query_range`
endpoint. Loki does all the work and returns **only the matching lines** (capped
by a result `limit`, ~1000 by default). Grafana renders those.

So a filter that matches 3 lines out of 60 days returns **3 lines** to Grafana.
Grafana never loads 60 days of logs into the browser. How much *Loki* had to read
to find those 3 depends on your **labels** (see §2), not on the filter.

---

## 4. The three limits — what each one actually governs

These get confused constantly. They are independent:

| Limit | Governs | Default (this stack) | Analogy |
|---|---|---|---|
| **`max_query_length`** | max **WIDTH** of a single query window (`end − start`) | `30d1h` (721h) | "widest window you may ask for" |
| **`max_query_lookback`** | how far **BACK** `start` may reach at all | `0` = unlimited | "how old a query may begin" |
| **`retention_period`** | how long data is **kept** before deletion | per-tenant¹ | "is the data even still there" |

¹ Per-tenant in [`tenants.yaml`](../tenants.yaml) → rendered into
[`docker/loki/overrides.yaml`](../docker/loki/overrides.yaml). Current values:
`project-alpha` = 90d, `project-beta` = 7d, default = 30d.

Key point: **`max_query_length` gates WIDTH, not AGE.** A 1-day window from a year
ago has width = 1 day → passes the gate untouched. You only raise
`max_query_length` when a *single query* needs to span more than ~30 days.

---

## 5. Decoding the classic error

```
the query time range exceeds the limit (query length: 743h59m59.999s, limit: 30d1h)
```

- `743h59m59.999s` ≈ **31 days** — the **width** of the window you asked for
  (almost certainly "last 31 days" / "last month" in the Grafana time picker).
- `30d1h` = `721h` = the `max_query_length` ceiling.

So: your query window was 31 days wide; the max allowed width is ~30 days; Loki
**rejected it before running anything.** This check is purely on width — a query
returning *zero* results is still rejected if the window is too wide. The `+1h`
of slack means a normal "last 30 days" doesn't trip it; 31 days does.

Fixes: (a) raise `max_query_length`, or (b) split into sub-30-day windows.

---

## 6. Querying old data — the part everyone gets wrong

**Scenario:** "Show me logs from Jan 1 of *last year*, 00:00–23:59."

| Concern | Limit | Your 1-day, year-old query |
|---|---|---|
| Window is 1 day wide | `max_query_length` | ✅ 1d ≪ 30d1h — **no change needed** |
| Start is ~365 days ago | `max_query_lookback` | ✅ unlimited by default — **no change needed** |
| Data must still exist | `retention_period` | ⚠️ tenant retention must cover ~1 year |

So a **narrow window on old data is cheap and needs no limit changes** — it reads
only ~1 day of the matched streams. The *only* thing that has to be true is that
**retention still covers that age.** Age is free; width is what's gated.

You'd only touch `max_query_length` for the opposite query — "all of last year in
one sweep" (width = 365d) — which is the expensive, usually-wrong query anyway
(see §7).

---

## 7. What long retention / S3 is actually for

Pushing a year of data to object storage is **not** so you can scan a year of raw
logs. It's for **different access patterns**:

| Need | What you query | Cost |
|---|---|---|
| "Pull logs for order-12345 from last March" (forensics) | narrow window + good labels | cheap |
| "Was there an incident in Q2?" (compliance/audit) | bounded window, on demand | cheap, occasional |
| "Error rate / p99 over the last year" (trend) | **metrics**, not logs | trivial, instant |

Long retention means the **specific slice exists and is retrievable** when an
investigation or audit demands it — not that you dashboard a year of raw logs.
S3 (here, SeaweedFS) makes keeping that slice cheap and durable.

**For long-range questions, use rollups, not log scans.** Derive metrics from
logs/traces and let *those* carry the long retention:

- Loki **recording rules** → "errors per service per minute" into Mimir.
- Tempo **span-metrics** (already enabled) → request rate / latency into Mimir.

Then "error rate over the last year" is a tiny, instant **metric** query instead
of a year-long log scan. Raw logs answer *"what exactly happened here, then"*
(narrow). Metrics answer *"what's the trend"* (wide). Use each for its strength.

---

## 8. When Loki is the wrong tool

If your real requirement is **analytical queries over a year of raw logs**
("group all lines by field X across 12 months"), that is **not** what Loki — or
any operational log store — is built for. Export to a columnar analytics store
(data lake / ClickHouse / BigQuery) and query it there. Don't fight Loki into
being a warehouse.

---

## 9. Tuning in this project

- **Retention** is per-tenant in [`tenants.yaml`](../tenants.yaml)
  (`logs_retention`, `metrics_retention`, `traces_retention`) → `make render`.
- **`max_query_length`** is *not* currently exposed per-tenant; it uses Loki's
  `30d1h` default. To allow wider single queries, add it to Loki's
  `limits_config` (global) or per-tenant overrides. Prefer raising it
  deliberately and modestly (e.g. `60d`) rather than `0` (unlimited), which
  re-opens the wildcard-scan footgun.
- **The real lever is labels.** A well-scoped `{service=...}` query is cheap at
  any age. Spend effort on consistent labels before raising limits.
