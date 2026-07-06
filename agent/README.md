# Perceptor VM agent — setup guide

Deploy this on a **project's VM** to ship that machine's **host + container**
infra (metrics *and* logs) into the **project's own tenant**, so it sits next to
the project's app telemetry and correlates with it — without being mistaken for
it (everything is tagged `telemetry_source=infra`).

- **One agent per VM.** If a project runs on several VMs, deploy it on each and
  give each a unique `VM_NAME`. It does **not** matter how many Docker Compose
  stacks run on the box — one agent sees every container on the host.
- **Push, outbound only.** The agent dials *out* to the platform edge over
  HTTPS. It opens **no inbound ports**; nothing needs to reach the VM.
- **No central config change.** Onboarding a VM (or a new container on it) needs
  nothing edited on the central server.

---

## Prerequisites

On the VM:

- **Docker Engine + Compose plugin** (`docker compose version` works).
- **Outbound HTTPS** to the platform edge (e.g. `https://lgtm.runtheday.com`).
- Root/sudo (the agent mounts host paths read-only to read host + container stats).

From the platform operator, you need two things:

| Value | What it is | Where it comes from |
|---|---|---|
| `EDGE_ENDPOINT` | The OTLP/HTTP ingest URL — the **same** URL the project's apps already push telemetry to. | The platform's public edge, e.g. `https://lgtm.runtheday.com` |
| `PROJECT_TOKEN` | **This project's** ingest token. Caddy maps it to the tenant; the VM never names its own tenant. | The central server's `tenants.secrets.yaml`, the line for this project. **Treat it like a password.** |

---

## Setup (3 steps)

### 1. Get the files onto the VM

Copy this `agent/` directory to the VM — clone the repo, or just `scp` the four
files (`config.alloy`, `docker-compose.agent.yaml`, `.env.example`, `README.md`):

```bash
scp -r agent/ user@project-vm:/opt/perceptor-agent
ssh user@project-vm
cd /opt/perceptor-agent
```

### 2. Configure `.env`

```bash
cp .env.example .env
```

Edit `.env` and set the three values:

```ini
EDGE_ENDPOINT=https://lgtm.runtheday.com   # the project's ingest URL
PROJECT_TOKEN=ptk_xxxxxxxxxxxxxxxxxxxxxxxx  # this project's token (keep secret)
VM_NAME=project-alpha-web-1                 # a name for THIS machine
```

`VM_NAME` becomes the `vm` label on everything this agent sends — pick something
that identifies the box (its role + an index, not a random hostname).

### 3. Start it

```bash
docker compose -f docker-compose.agent.yaml up -d
```

That's it. It begins collecting immediately and picks up new containers on the
host automatically.

---

## Verify it's working

**On the VM** — the logs should show it collecting and exporting, with **no**
`Exporting failed` lines:

```bash
docker compose -f docker-compose.agent.yaml logs -f agent
```

**In the project's Grafana** (or via the API) — after ~30s the data should
appear in the project tenant. In Explore, on the project's datasources:

- **Loki:** `{telemetry_source="infra", vm="<your VM_NAME>"}` → host + container logs
- **Mimir:** `node_uname_info{vm="<your VM_NAME>"}` → host metrics are flowing
- **Mimir (containers):** `container_last_seen{vm="<your VM_NAME>"}` → per-container metrics

If those return data, the round-trip works: VM → edge → project tenant, labelled.

---

## Per-container control (optional)

Every container is collected by default (opt-out model) — you never edit this
agent to onboard a container. Containers self-describe from **their own** compose,
Traefik-style:

```yaml
# in the application's docker-compose, on its service:
labels:
  perceptor.enable: "false"           # exclude this container entirely
  perceptor.service_name: "checkout"  # set its service_name (else the container name is used)
```

---

## What lands where, and how to query it

Everything goes to the **project's tenant**, tagged `telemetry_source=infra` and
`vm=<VM_NAME>` as real labels. That means:

- Isolate all infra from app telemetry: `{telemetry_source="infra"}`
- One VM's logs: `{telemetry_source="infra", vm="project-alpha-web-1"}`
- A container's infra logs **and** metrics share the same `container` label, so a
  single Grafana dashboard variable filters both together.

App telemetry (the project's own SDK metrics/logs/traces) is untouched and does
**not** carry `telemetry_source`, so the two never mix. See
[../docs/querying-and-retention.md](../docs/querying-and-retention.md).

---

## Operating it

```bash
# update config (edit config.alloy or .env), then:
docker compose -f docker-compose.agent.yaml up -d

# stop
docker compose -f docker-compose.agent.yaml down

# view resource use
docker stats perceptor-agent
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Exporting failed ... 401` | Wrong or missing `PROJECT_TOKEN`. Check the value against `tenants.secrets.yaml` on the central server. |
| `Exporting failed ... connection refused / no such host` | `EDGE_ENDPOINT` unreachable — check the URL and that the VM has outbound HTTPS to it. |
| No **container** metrics/logs (host ones fine) | The container-stats mounts didn't attach. Ensure the VM has `/run/containerd/containerd.sock` and `/sys/fs/cgroup` (both mounted by the compose); on non-containerd runtimes adjust `docker_host`/socket paths in `config.alloy`. |
| Nothing at all in Grafana | Confirm you're looking at the **project's** org/datasources, and that `vm=` matches your `VM_NAME` exactly. |

---

## How it differs from the central agent

There are two agents in this platform; don't confuse them.

| | Central agent (`docker/alloy/`) | **VM agent (this)** |
|---|---|---|
| Runs on | the **platform** host | each **project** VM |
| Writes to | internal Mimir/Loki **directly** (trusted, co-located) | the **edge** (Caddy) via OTLP + token |
| Tenant | `_infra` (platform self-monitoring, admin-only) | the **project's** tenant |
| Trust model | internal network | remote — tenant is stamped at the edge from the token, never claimed by the VM |
