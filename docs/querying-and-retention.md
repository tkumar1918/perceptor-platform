# Querying and retention

How Loki's query model and limits actually work — read before tuning. The
recurring confusion this answers: *"I have a year of data, why can't I query
it?"* Loki is not a content-indexed database, and its limits gate the
**width** of a query, not the **age** of the data.

The examples use Loki, but the same shape applies to Mimir and Tempo: a small
index + object storage + per-tenant limits. Companion:
[data-lifecycle.md](./data-lifecycle.md) covers the write side — when
telemetry moves from memory to WAL to S3.

## Mental model

- **Labels are the index; line filters are a scan.** `{service="checkout"}`
  picks which chunks to read; `|= "error"` is grep over those chunks.
- **Scan cost ≈ time-window width × label selectivity.** Filters reduce what
  is *returned*; labels reduce what is *read*.
- **Grafana does not filter.** It sends the query to Loki; Loki returns only
  matching lines. Grafana never downloads "all the logs".
- **The limits gate width, not age.** A 1-day query is equally cheap from
  yesterday or a year ago, if the data is retained.
- **Long retention is for retrieving a specific slice on demand** (forensics,
  compliance) — not for sweeping a year of raw logs. Long-range trends come
  from metrics, not log scans.

## 1. Loki is indexed grep, not a database

A content-indexed store (Elasticsearch, a SQL DB with the right indexes)
indexes the content of every log; `WHERE message CONTAINS 'error'` jumps
straight to matches. The price is a large index, often 5–10× the storage.
Loki makes the opposite trade-off:

| | Loki | Content-indexed DB |
|---|---|---|
| Indexes log content? | no | yes |
| Indexes labels (stream metadata)? | yes — a small index | yes |
| Content search | scans the selected chunks (grep) | index lookup |
| Storage cost | cheap (compressed blobs) | expensive (big index) |
| Broad / wildcard search | reads all matching bytes | bounded by the index |

Loki is grep over compressed files in object storage, with labels as a coarse
index that picks which files to grep.

## 2. The cost model: width × selectivity

Two parts of a LogQL query do two different jobs:

1. **Label selector** `{service="checkout", env="prod"}` — consulted against
   the index to decide which chunks are read from object storage.
2. **Filter expression** `|= "order-123"`, `| json | level="error"` — applied
   by scanning the lines in those chunks. Not indexed.

So `{service="checkout"} |= "order-123"` over 60 days reads only checkout's
chunks — bounded. `{} |= "order-123"` over 60 days reads every chunk in the
tenant for the same result count. **The filter changes what is returned; the
label selector changes what is read.**

## 3. The three limits

Independent knobs that get confused constantly:

| Limit | Governs | Default (this stack) |
|---|---|---|
| `max_query_length` | max **width** of one query window (`end − start`) | `30d1h` (721h) |
| `max_query_lookback` | how far **back** `start` may reach | `0` = unlimited |
| `retention_period` | how long data is **kept** | per-tenant in `tenants.yaml` → `docker/loki/overrides.yaml` (default 30d) |

`max_query_length` gates width, not age: a 1-day window from a year ago has
width = 1 day and passes untouched. Raise it only when a single query must
span more than ~30 days.

### Decoding the classic error

```
the query time range exceeds the limit (query length: 743h59m59.999s, limit: 30d1h)
```

`743h59m` ≈ 31 days — the width of the requested window (usually "last month"
in the Grafana time picker) — against a `30d1h` ceiling. Loki rejects it
before running anything; even a query that would return zero results is
rejected on width alone. The `+1h` of slack is why a normal "last 30 days"
doesn't trip it. Fix: narrow the window, split it into sub-30-day chunks, or
deliberately raise `max_query_length`.

## 4. Querying old data

"Show me logs from Jan 1 last year, 00:00–23:59":

| Concern | Limit | This 1-day, year-old query |
|---|---|---|
| window is 1 day wide | `max_query_length` | passes — 1d ≪ 30d1h |
| start is ~365 days back | `max_query_lookback` | passes — unlimited by default |
| the data must still exist | `retention_period` | **the only real requirement** — retention must cover that age |

A narrow window on old data is cheap and needs no limit changes. Age is free;
width is what's gated. The expensive query is the opposite one — "all of last
year in one sweep" — and it's usually the wrong tool anyway (below).

## 5. What long retention is for

| Need | Query | Cost |
|---|---|---|
| "logs for order-12345 from last March" (forensics) | narrow window + good labels | cheap |
| "was there an incident in Q2?" (audit) | bounded window, on demand | cheap, occasional |
| "error rate / p99 over the last year" (trend) | **metrics**, not logs | trivial |

For long-range questions, use rollups: Loki recording rules ("errors per
service per minute" into Mimir) and Tempo span-metrics (already enabled —
request rate/latency into Mimir). Then a year-long trend is a tiny metric
query instead of a year-long log scan. Raw logs answer *"what exactly
happened here, then"* (narrow); metrics answer *"what's the trend"* (wide).

If the real requirement is analytical queries over a year of raw logs (group
by arbitrary fields across 12 months), that isn't what any operational log
store is built for — export to a columnar store (ClickHouse, BigQuery, a data
lake) and query there.

## 6. Tuning in this stack

- **Retention** is per-tenant in `tenants.yaml` (`logs_retention`,
  `metrics_retention`, `traces_retention`) → `make render`.
- **`max_query_length`** is not exposed per-tenant; it uses Loki's `30d1h`
  default. To allow wider single queries, add it to Loki's `limits_config`
  (global) or per-tenant overrides — raise it deliberately and modestly
  (e.g. `60d`), not to `0`/unlimited, which reopens the wildcard-scan
  footgun.
- **The real lever is labels.** A well-scoped `{service=...}` query is cheap
  at any age; spend effort on consistent labels before raising limits.
