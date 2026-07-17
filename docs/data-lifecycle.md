# Data lifecycle — memory, local WAL, S3

Where telemetry lives at each moment between an app emitting it and it being
durable. The recurring confusions this answers:

> "I sent telemetry a minute ago — why isn't it in the S3 bucket?"
> "If it's not in S3 yet, is it lost?"
> "How can I query it in Grafana when it's not in S3?"

All three have one root: **data does not go straight to S3, and "in S3" is
not the same event as "queryable".** Companion:
[querying-and-retention.md](./querying-and-retention.md) covers the read
side.

## Mental model

- Telemetry lands in three tiers, in order: **ingester memory → local WAL →
  object storage (S3)**, promoted on a flush cadence, not instantly.
- The cadence differs per signal: traces reach S3 in minutes, logs in
  minutes-to-hours, metrics in up to ~2 hours.
- Flush triggers on **time or size, whichever comes first** — not a fixed
  timer after ingest.
- **"In S3" means durable. "Queryable" means the ingesters.** Querying does
  not wait for S3 — ingesters serve recent data from memory the moment it
  arrives.
- Unflushed data lives only in memory + local WAL. It survives a container
  restart (WAL replay) but not loss of the instance or volume.

## 1. The three tiers

```
  app ──OTLP──▶ Caddy ──▶ OTel gateway ──▶ [ INGESTER ]
                                             │  1. MEMORY (head)    — newest data, RAM
                                             │  2. WAL on LOCAL DISK — crash-recovery copy
                                             ▼  3. flush ──▶ [ S3 ]  — durable blocks/chunks
                                                              └▶ compactor merges small → large
```

| Tier | What it is | Where (this stack) | Survives |
|---|---|---|---|
| Memory | the ingester's in-RAM head — newest samples/spans/lines | container RAM | nothing |
| Local WAL | write-ahead log mirroring the head, for crash recovery | docker volumes (`mimir-data`, `loki-data`, `tempo-data`) | container restart (WAL replay); **not** volume/instance loss |
| S3 | flushed, immutable blocks/chunks + index | the configured buckets | container and instance loss |

Data is durable only once it is in S3; memory and WAL are staging.

## 2. Flush cadence per signal (this stack's config)

| Signal | Backend | Reaches S3 after | Config |
|---|---|---|---|
| Traces | Tempo | **~minutes** — a block cuts every 5m or at 1 MB, after a trace is idle 10s | `max_block_duration: 5m`, `max_block_bytes: 1_000_000`, `trace_idle_period: 10s` in `docker/tempo/tempo.yaml` |
| Logs | Loki | **minutes → ~2h** — a chunk flushes at 30m idle, 2h max age, or ~1.5 MB | Loki defaults (not overridden) |
| Metrics | Mimir | **up to ~2h** — the TSDB head compacts into a 2-hour block, then ships | `blocks_storage.tsdb` default 2h block range |

So S3 fills in order: traces first, then logs, then metrics. Low-volume
streams take the longest — they never hit the size trigger, so they wait for
the time trigger. An empty-looking bucket five minutes after sending metrics
is normal, not a bug.

## 3. Why data is queryable before it reaches S3

The read path reads both tiers and merges:

```
Grafana query ─▶ query-frontend ─┬─▶ ingester    (recent: memory/WAL)
                                 └─▶ store / S3  (older: flushed blocks)
                                      └── merged ──▶ one result
```

Ingesters answer for recent data straight from memory; store-gateways and
queriers answer for older data from S3 blocks. Freshly ingested data is
queryable in seconds and becomes durable minutes-to-hours later. Don't
validate ingestion by watching the bucket — query Grafana.

## 4. Checking each property

| Question | Check | How |
|---|---|---|
| Is my data retrievable? | the read path | Grafana → the project's org → query it |
| Is my data durable (in S3)? | object storage | `aws s3 ls s3://<bucket>/<tenant>/ --recursive` |
| Is it still only in memory/WAL? | the gap between the two | queryable but not in the bucket = staged, not yet durable |

A worked example (verified against live buckets) of the lopsided counts the
cadence produces — not a problem:

```
metrics  s3://…mimir…/project-tutor/   55 objects  (2h blocks)
logs     s3://…loki…/project-tutor/     2 objects  (low volume → slow flush)
traces   s3://…tempo…/project-tutor/   14 objects  (~5m blocks)
```

## 5. Durability — what is at risk, and when

At any moment, some data is only in memory + local WAL:

- **Metrics:** up to ~2h of the newest samples (the unshipped TSDB head).
- **Logs:** any chunk not yet flushed (idle < 30m, age < 2h, under size).
- **Traces:** the last few minutes (open block + idle window).

Consequences:

- **Container restart** — fine; the ingester replays its WAL on boot.
- **Loss of the instance or the docker volume** — the unflushed window is
  gone. Everything already in S3 is safe.
- This stack runs `replication_factor: 1` (single node), so the local WAL is
  the only copy of unflushed data.

If that window matters: shorten flush intervals (more S3 writes), back up the
WAL volumes, or move to a replicated multi-node setup. For most uses the
default cadence is the right trade-off — just know the window exists.

## 6. Common confusions

- **"I sent metrics, the bucket is empty — broken?"** No; metrics ship as
  2-hour blocks. Query Grafana instead — it's served from the ingester
  immediately.
- **"Traces are in S3 but metrics aren't — inconsistent?"** Expected;
  different cadence (§2).
- **"A quiet project's logs never reach S3."** They will, on the 2h max-age
  timer; low volume never hits the size trigger.
- **"It's queryable, so it's safe?"** Not necessarily — queryable ≠ durable
  (§5).
- **"Do I need S3 to query recent data?"** No; recent data comes from the
  ingester. S3 is durability and history.

## 7. Related knobs

- **Flush cadence:** Tempo in `docker/tempo/tempo.yaml`; Mimir's 2h block
  range is the default; Loki uses defaults (set
  `ingester.chunk_idle_period` / `max_chunk_age` in `docker/loki/loki.yaml`
  to change).
- **Retention** (how long S3 keeps data) is per-tenant in `tenants.yaml` →
  `make render`; see [querying-and-retention.md](./querying-and-retention.md).
- **WAL volumes:** `mimir-data`, `loki-data`, `tempo-data` in
  `docker/docker-compose.yml` hold the unflushed window — back them up if
  that data is precious.
