# Architecture — data flow

The complete path telemetry takes through the stack, with the exact protocol on
every hop. Ingest is **HTTP end-to-end**; the only gRPC in the default path is
the internal collector → Tempo leg for traces.

```mermaid
flowchart TB
    subgraph remote["🌐 Remote (internet)"]
        app["Project app<br/>OTLP/HTTP<br/>(gRPC optional)"]
        vmagent["VM agent · Alloy<br/>OTLP/HTTP"]
        user["Operator<br/>browser"]
    end

    subgraph host["Platform host — internal 'obs' bridge network"]
        subgraph edge["Public edge — ONLY :80 / :443 exposed"]
            caddy["Caddy<br/>TLS termination + auto-HTTPS<br/>Bearer token → X-Scope-OrgID"]
        end
        collector["OTel Collector<br/>:4318 HTTP · :4317 gRPC<br/>per-tenant batching"]
        calloy["Central Alloy<br/>platform self-monitoring"]
        mimir[("Mimir<br/>metrics")]
        loki[("Loki<br/>logs")]
        tempo[("Tempo<br/>traces")]
        s3[("SeaweedFS<br/>S3 object storage")]
        grafana["Grafana<br/>one org per tenant<br/>(:3001 localhost only)"]
    end

    %% ---- Ingest ----
    app -->|"OTLP/HTTP over TLS :443"| caddy
    app -.->|"OTLP/gRPC over TLS :443 (optional)"| caddy
    vmagent -->|"OTLP/HTTP over TLS :443"| caddy

    caddy -->|"OTLP/HTTP → :4318"| collector
    caddy -.->|"OTLP/gRPC h2c → :4317"| collector

    collector -->|"remote-write (HTTP)"| mimir
    collector -->|"OTLP/HTTP"| loki
    collector -->|"OTLP/gRPC"| tempo

    %% ---- Storage ----
    mimir --> s3
    loki --> s3
    tempo --> s3

    %% ---- Self-monitoring (bypasses the edge) ----
    caddy -.->|"stdout access logs<br/>scraped"| calloy
    calloy -->|"direct write · _infra"| mimir
    calloy -->|"direct write · _infra"| loki

    %% ---- Read / query ----
    user -->|"HTTPS :443<br/>monitoring.&lt;domain&gt;"| caddy
    caddy -->|"reverse_proxy grafana:3000"| grafana
    grafana -->|"PromQL / LogQL / TraceQL<br/>X-Scope-OrgID per org"| mimir
    grafana --> loki
    grafana --> tempo
```

## How to read it

- **Solid** = the default/live path; **dotted** = optional (client gRPC) or the
  self-monitoring side-channel.
- **Caddy is the only public door** — `:80/:443` face the internet; the
  collector, backends, and S3 have **no host ports**; Grafana's `:3001` is
  localhost-only (reached publicly via Caddy's `monitoring.<domain>` vhost). See
  the port model (`EDGE_BIND` / `SERVICE_BIND`) in `.env.example`.
- **Two agent routes:** remote VM agents go *through* the authenticated edge; the
  central Alloy writes *directly* to Mimir/Loki (the `_infra` tenant), since it's
  already inside the trust boundary.
- **Tenant isolation rides one header the whole way:** Caddy stamps
  `X-Scope-OrgID` from the project token → the collector preserves it
  (`headers_setter`) → the backends store under it → Grafana's per-org
  datasources query with it. A project can neither write as, nor read, another's
  data.

## Protocol per hop

| Hop | Protocol | Notes |
|---|---|---|
| app / agent → Caddy `:443` | OTLP/**HTTP** over TLS | gRPC also accepted (rides 443, matched by `Content-Type: application/grpc`) |
| Caddy → collector `:4318` | OTLP/**HTTP** | Caddy forwards the *same* protocol the client used — it never transcodes |
| Caddy → collector `:4317` | OTLP/**gRPC** (h2c) | only for clients that chose gRPC |
| collector → **Mimir** | Prometheus **remote-write** (HTTP) | metrics |
| collector → **Loki** | OTLP/**HTTP** | logs |
| collector → **Tempo** | OTLP/**gRPC** | traces — the one internal gRPC hop |
| Mimir / Loki / Tempo → **SeaweedFS** | S3 | swappable for AWS S3 / R2 / B2 |
| Grafana → backends | PromQL / LogQL / TraceQL | `X-Scope-OrgID` pinned per org datasource |

See [REDESIGN.md](../REDESIGN.md) for the design rationale, and
[instrumenting-apps.md](instrumenting-apps.md) for what to send in.
