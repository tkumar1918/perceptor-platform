# Perceptor VM agent

One Alloy agent per project VM. Collects the VM's **host** and **container**
metrics + logs and ships them to the **project's tenant**, tagged
`telemetry_source=infra`, through the platform edge.

## Deploy

```bash
cp .env.example .env      # set EDGE_ENDPOINT, PROJECT_TOKEN (from the central
                          # server's tenants.secrets.yaml), and VM_NAME
docker compose -f docker-compose.agent.yaml up -d
```

That's it — no inbound ports, no central config change. New containers on the VM
are picked up automatically.

## How it differs from the central agent

| | Central agent | VM agent (this) |
|---|---|---|
| Writes to | internal Mimir/Loki directly (trusted) | the **edge** (Caddy) via OTLP + token |
| Tenant | `_infra` (platform) | the **project's** tenant |
| Trust | co-located, internal | remote — tenant stamped at the edge from the token |

## Per-container control (optional, Traefik-style labels)

Containers self-describe from their **own** compose — nothing to edit here:

```yaml
labels:
  perceptor.enable: "false"          # exclude this container from collection
  perceptor.service_name: "checkout" # override its service_name label
```

By default **every** container is collected (opt-out model).

## What lands where

All of it goes to the project's tenant, tagged `telemetry_source=infra`, so a
Grafana dashboard variable `$container` filters the container's app logs and its
infra metrics together. Query infra with `{telemetry_source="infra"}`.
