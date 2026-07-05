# Where your data lives — memory, disk, and S3 (read this before asking "is it in S3 yet?")

This doc exists to kill a recurring confusion:

> "I sent telemetry a minute ago — why isn't it in the S3 bucket?"
> "If it's not in S3 yet, is it lost?"
> "How am I able to *query* it in Grafana when it's not in S3?"

All three have the same root: **data does not go straight to S3, and "in S3" is
not the same event as "queryable."** Once you internalize the three-tier model
below, none of it is mysterious.

> Companion to [querying-and-retention.md](./querying-and-retention.md), which
> covers the *read* side (why a narrow query on old data is cheap). This doc
> covers the *write* side (how data moves from an app to durable storage).

---

## TL;DR mental model

- Telemetry lands in three tiers, in order: **ingester memory → local WAL (the
  instance's disk) → object storage (S3)**. It is promoted between tiers on a
  **flush cadence**, not instantly.
- **The flush cadence differs per signal.** Traces reach S3 in ~minutes; logs in
  minutes-to-hours; **metrics can take up to ~2 hours.**
- **Flush is triggered by time OR size — whichever comes first** — not a fixed
  "N minutes after ingest" timer.
- **"In S3" = durability. "Queryable" = the ingesters.** They are different
  events. **Querying does not wait for S3** — the ingesters serve recent data
  from memory the moment it arrives. ← the single most important sentence here.
- **Unflushed data lives only in memory + local WAL.** It survives a container
  *restart* (WAL replay) but **not** loss of the instance/volume. With
  single-node `replication_factor: 1`, that local WAL is the only copy until the
  flush lands in S3.

---

## 1. The three tiers

```
  app ──OTLP──▶ Caddy ──▶ OTel gateway ──▶ [ INGESTER ]
                                             │  1. MEMORY (head)   ── most recent data, RAM
                                             │  2. WAL on LOCAL DISK ── crash-recovery copy
                                             │        (docker volume on the instance)
                                             ▼  3. flush ──▶ [ S3 ] block/chunk ── durable, long-term
                                                              └▶ compactor merges small → large
```

| Tier | What it is | Where (this stack) | Survives… |
|---|---|---|---|
| **Memory** | the ingester's in-RAM head — newest samples/spans/lines | container RAM | nothing (lost on stop) |
| **Local WAL** | write-ahead log: an on-disk mirror of the head for crash recovery | docker volumes on the instance (`mimir-data`, `loki-data`, `tempo-data`) | container **restart** (WAL replay), **not** volume/instance loss |
| **S3** | flushed, immutable blocks/chunks + index | `lgtm-*` buckets (AWS S3) | container **and** instance loss |

Data is **only durable once it's in S3.** Memory and WAL are staging.

---

## 2. The flush cadence — per signal, from *this stack's* config

Each backend promotes memory → S3 on **whichever fires first: a time threshold or
a size threshold.** The values below are from your actual configs.

| Signal | Backend | Reaches S3 after… | Config |
|---|---|---|---|
| **Traces** | Tempo | **~minutes** — a block is cut every `5m` **or** at `1 MB`, after a trace is idle `10s` | `max_block_duration: 5m`, `max_block_bytes: 1_000_000`, `trace_idle_period: 10s` |
| **Logs** | Loki | **minutes → ~2h** — a chunk flushes at `30m` idle **or** `2h` max age **or** ~`1.5 MB` target | Loki defaults (not overridden) |
| **Metrics** | Mimir | **up to ~2h** — the TSDB head is compacted into a **2-hour block**, then shipped | `blocks_storage.tsdb` default `2h` block range |

So the order data shows up in S3 is: **traces first, then logs, then metrics.**
Low-volume streams take the *longest* (they hit the time trigger, never the size
trigger) — which is why a quiet tenant's logs can sit in the ingester for up to
2h before a single chunk appears in the bucket.

**This is normal and healthy.** An empty-looking bucket 5 minutes after you send
metrics is not a bug — the 2-hour block hasn't been cut yet.

---

## 3. Why you can query data that isn't in S3 yet

The read path reads from **both** tiers and stitches them:

- **Ingesters** answer for **recent** data straight from memory/WAL — before it is
  ever flushed.
- **Store-gateway / queriers** answer for **older** data by reading blocks from S3.
- The query-frontend merges the two; Grafana just sees one seamless result.

```
Grafana query ─▶ query-frontend ─┬─▶ ingester   (recent: memory/WAL)
                                 └─▶ store/S3    (older: flushed blocks)
                                     └── merged ──▶ result
```

So **"is it queryable?" and "is it in S3?" are answered by different components.**
Freshly-ingested data is queryable in seconds; it becomes *durable* minutes-to-
hours later. Don't validate ingestion by staring at the bucket — **query it in
Grafana.**

---

## 4. How to check each thing (they need different tools)

| Question | Check | How |
|---|---|---|
| "Is my data **retrievable**?" | the read path | Grafana → the project's org → query Loki/Mimir/Tempo |
| "Is my data **durable** (in S3)?" | object storage | `aws s3 ls s3://<bucket>/<tenant>/ --recursive` |
| "Is it still only in memory/WAL?" | the gap between the two | queryable **but** not in the bucket yet = staged, not durable |

Worked example (project-tutor, verified against the live buckets):

```
metrics  s3://lgtm-mimir-blocks-2026/project-tutor/…   55 objects  (2h blocks)
logs     s3://lgtm-loki-data-2026/project-tutor/…        2 objects  (low volume → slow flush)
traces   s3://lgtm-tempo-data-2026/project-tutor/…      14 objects  (~5m blocks)
```

The lopsided counts are exactly the cadence in §2, not a problem: traces flush
fast and often, metrics come in 2h chunks, and low log volume means most lines
are still in the ingester.

---

## 5. Durability — what's actually at risk, and when

Because promotion to S3 lags, at any moment some data is **only in memory + local
WAL**:

- **Metrics:** up to ~2h of the most recent samples (the un-shipped TSDB head).
- **Logs:** any chunk not yet flushed (idle < 30m, age < 2h, under size).
- **Traces:** the last few minutes (open block + idle window).

What that means:

- **Container restart** → fine. On boot the ingester **replays the WAL** from its
  local volume; nothing is lost.
- **Loss of the instance / the docker volume** → the un-flushed window is **gone**.
  Anything already in S3 is safe.
- This stack runs **`replication_factor: 1`** (single node), so the local WAL is
  the *only* copy of un-flushed data — there is no second ingester holding it.

Mitigations if that window matters: shorten flush intervals (more S3 writes, more
cost), back up the WAL volumes, or move to a replicated/multi-node setup. For most
uses the default cadence is the right trade-off — just **know the window exists.**

---

## 6. Common confusions, answered

- **"I sent metrics, the bucket is empty — broken?"** No. Metrics ship as 2-hour
  blocks. Check again after the block cuts, or just **query Grafana** (served from
  the ingester immediately).
- **"Traces are in S3 but metrics aren't — inconsistent?"** Expected. Different
  cadence (§2): traces ~5m, metrics ~2h.
- **"A quiet project's logs never reach S3."** They will — on the `2h` max-age
  timer. Low volume never hits the size trigger, so it waits for the time trigger.
- **"It's queryable, so it's safe, right?"** Not necessarily. Queryable ≠ durable.
  Until it's in S3 it lives only in memory + local WAL (§5).
- **"Do I need S3 to query recent data?"** No. Recent data is served from the
  ingester. S3 is for durability and older data.

---

## 7. Related knobs in this project

- **Flush cadence:** Tempo in [`docker/tempo/tempo.yaml`](../docker/tempo/tempo.yaml)
  (`max_block_duration`, `max_block_bytes`, `trace_idle_period`); Mimir's 2h block
  range is the default; Loki uses defaults (add `ingester.chunk_idle_period` /
  `max_chunk_age` to [`docker/loki/loki.yaml`](../docker/loki/loki.yaml) to change).
- **Retention** (how long S3 keeps it) is per-tenant in
  [`tenants.yaml`](../tenants.yaml) → `make render`. See
  [querying-and-retention.md](./querying-and-retention.md).
- **WAL/volume locations:** `mimir-data` (`/data/mimir`), `loki-data`
  (`/var/loki`), `tempo-data` (`/var/tempo`) in
  [`docker/docker-compose.yml`](../docker/docker-compose.yml) — these hold the
  un-flushed window; back them up if that data is precious.
```
