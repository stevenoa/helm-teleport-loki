# Teleport → Grafana Loki (Helm / Kubernetes)

This is a NON-production example for connecting the Teleport event-handler
to a Grafana Loki instance running on the same Kubernetes cluster via Helm.

Streams Teleport audit events to Grafana Loki using the Teleport event handler
and Fluentd, deployed as a Helm chart.

```mermaid
flowchart LR
    subgraph teleport["Teleport Cluster"]
        auth["Auth Service"]
        nodes["Nodes / Apps /\nDatabases / K8s"]
        nodes -- "audit events" --> auth
    end

    subgraph k8s["Kubernetes (Helm chart)"]
        tbot["tbot sidecar\n(auto-renews identity\nevery 20 min)"]
        handler["StatefulSet\nteleport-event-handler:18\n(cursor on PVC)"]
        svc["ClusterIP Service\nport 24224"]
        fluentd["Deployment\nFluentd v1.17\n+ grafana-loki plugin"]
        tbot -- "writes identity\n(PVC)" --> handler
        handler -- "HTTPS POST JSON\n(mTLS)" --> svc
        svc --> fluentd
    end

    subgraph grafana["Grafana Stack"]
        loki["Loki\n(SingleBinary)"]
        gateway["loki-gateway\n(nginx)"]
        grafanaui["Grafana\nExplore & Dashboards"]
        fluentd -- "HTTP POST\n/loki/api/v1/push" --> gateway
        gateway --> loki
        loki --> grafanaui
    end

    auth -- "gRPC stream\n(identity file auth)" --> handler
    auth -- "kubernetes SA JWT\n(secretless join)" --> tbot

    style teleport fill:#6366f1,color:#fff,stroke:#4f46e5
    style k8s fill:#0ea5e9,color:#fff,stroke:#0284c7
    style grafana fill:#f97316,color:#fff,stroke:#ea580c
```

```
Teleport Cluster → teleport-event-handler (StatefulSet) → Fluentd (Deployment) → Loki gateway → Loki
```

## Why Kubernetes instead of Docker Compose?

| Concern | Docker Compose | Helm / Kubernetes |
|---|---|---|
| Cursor persistence | Volume mount | PVC on StatefulSet — survives pod restarts and rescheduling |
| Secret management | `.env` file | Kubernetes Secrets (or ESO / Vault / Sealed Secrets) |
| Restarts & health | `restart: always` | Liveness & readiness probes with backoff |
| Scaling | Manual | Declarative replicas (Fluentd can scale; handler stays at 1) |
| Config rollouts | `docker compose up` | `helm upgrade` with automatic pod rollout on ConfigMap change |

## Identity modes

| Mode | How it works | When to use |
|---|---|---|
| **tbot** (default) | `tbot` sidecar joins Teleport using the pod's Kubernetes ServiceAccount JWT — no static secret required. The provision token uses `type: static_jwks`, validating the JWT signature offline against your cluster's public JWKS. The pod mounts a custom projected SA token with a 20-minute TTL and `audience: <teleport-proxy-addr>` (both required by `static_jwks`). Renews a 1-hour identity certificate every 20 minutes and persists it on the PVC. | Recommended for all deployments |
| **Static** (`tbot.enabled: false`) | A 1-year identity file is signed with `tctl auth sign` and stored in a Kubernetes Secret. Requires the `teleport-event-handler-impersonator` role during setup. | Fallback / air-gapped environments |

## Prerequisites

- Kubernetes cluster (1.24+)
- `helm` v3
- `kubectl` configured for your cluster
- `tctl` access to your Teleport cluster
- `teleport-event-handler` v18 binary installed locally ([download](https://goteleport.com/download/))
- Grafana Loki deployed to your cluster (see [Deploy Loki](#deploy-loki) below)

### Installing teleport-event-handler on macOS (arm64)

```bash
curl -Lo /tmp/teleport-event-handler.tar.gz \
  https://cdn.teleport.dev/teleport-event-handler-v18.7.6-darwin-arm64-bin.tar.gz
tar -xzf /tmp/teleport-event-handler.tar.gz -C /tmp
sudo mv /tmp/teleport-event-handler/teleport-event-handler /usr/local/bin/teleport-event-handler
```

> Replace `v18.7.6` and `arm64` with your Teleport version and architecture (`amd64` for Intel Macs).

## Repository layout

```
.
├── helm/
│   └── teleport-loki/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── _helpers.tpl
│           ├── namespace.yaml
│           ├── tbot-configmap.yaml
│           ├── fluentd-configmap.yaml
│           ├── fluentd-deployment.yaml
│           ├── fluentd-service.yaml
│           ├── fluentd-buffer-pvc.yaml
│           ├── event-handler-configmap.yaml
│           ├── event-handler-statefulset.yaml
│           ├── serviceaccount.yaml
│           └── NOTES.txt
├── dashboards/
│   ├── README.md                        # import instructions + LogQL query reference
│   ├── teleport-audit-events.json       # general overview dashboard
│   ├── teleport-kubernetes-access.json  # K8s sessions, exec, port forwards
│   ├── teleport-access-requests.json    # JIT access request lifecycle
│   └── teleport-identity-changes.json  # role, user, lock, connector changes
├── alerts/
│   ├── alert-rules.json                 # Grafana alert rules (identity changes, failed logins)
│   ├── contact-points.json              # Slack contact point (webhook URL placeholder)
│   └── notification-policy.json         # routing policy: team=security → Slack
├── teleport-event-handler-role.yaml
├── Makefile
└── README.md
```

## Deploy Loki

If Loki is not already running in your cluster, deploy it with the official Helm chart
into the `grafana` namespace:

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install loki grafana/loki \
  --namespace grafana \
  --create-namespace \
  --set deploymentMode=SingleBinary \
  --set singleBinary.replicas=1 \
  --set singleBinary.persistence.storageClass=<your-storage-class> \
  --set loki.auth_enabled=false
```

Once running, the gateway service will be available at
`http://loki-gateway.grafana.svc.cluster.local` — this is the default `loki.url`
in `values.yaml`.

### Add the Loki data source to Grafana

```bash
GRAFANA_POD=$(kubectl get pod -n grafana -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n grafana "$GRAFANA_POD" -- curl -s -X POST \
  http://admin:YOUR_GRAFANA_PASSWORD@localhost:3000/api/datasources \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "Loki",
    "type": "loki",
    "url": "http://loki-gateway.grafana.svc.cluster.local",
    "access": "proxy",
    "isDefault": false
  }'
```

## Setup

### 1. Configure your environment

Copy the example env file and populate it:

```bash
cp .env.example .env
```

```bash
# .env
TELEPORT_ADDR=your-cluster.example.com:443
```

The `Makefile` sources `.env` automatically.

### 2. Grant your Teleport user kube-admin for setup (temporary)

The `create-tls-secret` target creates a Kubernetes namespace and secrets. If your
existing kube role already has unrestricted namespace permissions you can skip this.
Otherwise create and assign a `kube-admin` role:

```bash
cat <<'EOF' | tctl create -f -
kind: role
version: v8
metadata:
  name: kube-admin
spec:
  allow:
    kubernetes_groups:
      - system:masters
    kubernetes_labels:
      '*': '*'
    kubernetes_resources:
      - kind: '*'
        name: '*'
        namespace: '*'
        api_group: '*'
        verbs: ['*']
    kubernetes_users:
      - '{{internal.kubernetes_users}}'
EOF

tctl users update YOUR_USER --set-roles YOUR_EXISTING_ROLES,kube-admin
```

Then re-login to pick up the new role:

```bash
tsh logout && tsh login --proxy=YOUR_CLUSTER && tsh kube login YOUR_KUBE_CLUSTER
```

> **After setup is complete**, remove this role from your account:
> ```bash
> tctl users update YOUR_USER --set-roles YOUR_ORIGINAL_ROLES
> ```

### 3. Run setup

```bash
make setup
```

This runs:

1. **`setup-certs`** — generates mTLS certs in `./certs/` with the Fluentd service
   hostname in the SAN (`--dns-names=localhost,<release>-fluentd.<namespace>.svc.cluster.local`)
2. **`setup-role`** — applies the `teleport-event-handler` RBAC role and user to your cluster
3. **`setup-bot`** — creates the Teleport Machine ID bot (`event-handler-bot`) and registers
   a Kubernetes-method provision token (`event-handler-bot-join`) in Teleport using
   `type: static_jwks`. It fetches your cluster's public JWKS from `/openid/v1/jwks` and
   embeds it in the token resource so Teleport can verify SA JWTs offline. The token is
   scoped to the `teleport-loki:teleport-loki-event-handler` ServiceAccount.
4. **`create-tls-secret`** — creates the `teleport-loki-tls` Kubernetes Secret containing
   CA, client, and server certs plus the server key passphrase

> **Why no identity secret?** With tbot enabled (the default), the long-lived identity
> file is replaced by the `tbot` sidecar. On first start, tbot presents the pod's
> Kubernetes ServiceAccount JWT to Teleport to obtain its bot identity — no static secret
> required. It saves that identity to the PVC (`/var/lib/teleport-event-handler/tbot/`).
> On every subsequent restart it loads the saved identity directly; the SA JWT is only
> used again if the stored cert has expired. tbot renews the identity certificate every
> 20 minutes, keeping it fresh without any manual rotation.

> **Why `--dns-names` matters:** The Fluentd service is only reachable inside the cluster
> by its DNS name (`<release>-fluentd.<namespace>.svc.cluster.local`). The mTLS server
> certificate must include this name as a Subject Alternative Name or the event-handler
> will refuse the connection with an x509 hostname mismatch error.

> **Why both server and client certs go in the TLS secret:** Fluentd acts as the TLS
> server (`server.crt` / `server.key`) and requires the event-handler to present its
> client certificate for mutual authentication. Both sides read from the same Kubernetes
> Secret, mounted at `/certs` in each pod.

### 4. Install the Helm chart

```bash
make install
```

Or manually:

```bash
helm install teleport-loki ./helm/teleport-loki \
  --namespace teleport-loki \
  --create-namespace \
  --set teleport.addr=your-cluster.example.com:443 \
  --set loki.url=http://loki-gateway.grafana.svc.cluster.local
```

This deploys:
- **tbot sidecar** — on first start, joins Teleport using the pod's Kubernetes
  ServiceAccount JWT (no static secret), writes a 1-hour identity to the state PVC,
  then renews it every 20 minutes; on restarts it loads the saved identity directly
- **event-handler StatefulSet** — reads the identity from the PVC, streams audit events
  to Fluentd; cursor also persisted on the same PVC
- **Fluentd Deployment** — receives events on port 24224 over mTLS, forwards to Loki
  via `fluent-plugin-grafana-loki`
- **ClusterIP Service** — routes traffic from the event-handler to Fluentd

### 5. Verify

```bash
make status          # check pod / deployment / PVC health
make logs-handler    # tail the event-handler
make logs-fluentd    # tail Fluentd
```

In Grafana → **Explore**, select the Loki data source and run:

```logql
{job="teleport-audit"}
```

You should see event types like `cert.create`, `session.start`, `session.end`, `bot.join`, etc.

### 6. Remove kube-admin from your account

```bash
tctl users update YOUR_USER --set-roles YOUR_ORIGINAL_ROLES
```

## Using the static identity mode (no tbot)

Set `tbot.enabled: false` in `values.yaml`, then run the full static setup instead:

```bash
make setup-static
```

This adds two extra steps:
- Signs a 1-year identity file with `tctl auth sign` (requires the
  `teleport-event-handler-impersonator` role on your Teleport account)
- Stores it in the `teleport-loki-identity` Kubernetes Secret

See the `teleport-event-handler-role.yaml` comments for the impersonator role definition.

## Configuration reference

All tunables live in `values.yaml`. The most commonly changed values:

| Path | Default | Description |
|---|---|---|
| `teleport.addr` | `""` | **Required.** Teleport cluster address |
| `loki.url` | `http://loki-gateway.grafana.svc.cluster.local` | Loki push URL |
| `loki.labels` | `{job: "teleport-audit"}` | Loki stream labels attached to every log line |
| `teleport.startTime` | `""` | RFC3339 cursor start time (blank = latest) |
| `tbot.enabled` | `true` | Use tbot sidecar for ephemeral identity (recommended) |
| `tbot.image.repository` | `public.ecr.aws/gravitational/teleport-distroless` | tbot image |
| `tbot.joinTokenName` | `event-handler-bot-join` | Name of the Teleport provision token |
| `tbot.renewalInterval` | `20m` | How often tbot renews the certificate |
| `tbot.certificateTTL` | `1h` | TTL of each issued certificate |
| `persistence.enabled` | `true` | Persist event-handler cursor on a PVC |
| `persistence.size` | `1Gi` | PVC size |
| `fluentd.persistence.enabled` | `true` | Persist Fluentd file buffer on a PVC |
| `fluentd.persistence.size` | `2Gi` | Fluentd buffer PVC size |
| `fluentd.port` | `24224` | Port Fluentd listens on inside the cluster |
| `fluentd.buffer.flushInterval` | `10s` | How often Fluentd flushes the buffer to Loki |
| `fluentd.buffer.chunkLimitSize` | `256m` | Maximum size of a single buffer chunk |
| `fluentd.buffer.retryWait` | `1m` | Initial wait between retries on flush failure |
| `fluentd.buffer.retryMaxTimes` | `72` | Maximum retry attempts before dropping a chunk |
| `fluentd.buffer.retryMaxInterval` | `1h` | Maximum wait between retries (exponential backoff cap) |
| `fluentd.buffer.totalLimitSize` | `512m` | Hard cap on total buffer disk usage |
| `fluentd.buffer.queuedChunksLimitSize` | `64` | Maximum number of queued buffer chunks |
| `eventHandler.types` | *(allowlist — see values.yaml)* | Audit event types to forward. Empty = all types (not recommended). Defaults to 42 security-relevant types; `kube.request` and other high-volume events are excluded. |
| `eventHandler.image.tag` | `18` | Teleport event-handler image tag |
| `fluentd.image.tag` | `v1.17` | Fluentd image tag |

## Upgrading

After changing `values.yaml` or the chart templates:

```bash
make upgrade
```

ConfigMap checksums are embedded as pod annotations, so pods roll automatically
when the Fluentd config, event-handler config, or tbot config changes.

## Grafana dashboards

Four pre-built dashboards are in the `dashboards/` directory:

| Dashboard | Focus |
|---|---|
| `teleport-audit-events.json` | General overview — event volume, auth, sessions, full log stream |
| `teleport-kubernetes-access.json` | K8s sessions, exec commands, port forwards by cluster and user |
| `teleport-access-requests.json` | JIT access request lifecycle — created, approved, denied |
| `teleport-identity-changes.json` | Role, user, lock, and connector changes — stat panels turn red on any activity |

```bash
make import-dashboards
```

See **[dashboards/README.md](dashboards/README.md)** for import instructions, panel descriptions,
and LogQL query examples for each dashboard.

## Grafana alerting

Two alert rules are in the `alerts/` directory and route to a Slack contact point:

| Alert | Condition |
|---|---|
| Teleport Identity Changes | Any role, user, lock, connector, or trusted cluster change in a 5-minute window |
| Teleport Failed Logins | More than 3 failed `user.login` events in a 5-minute window |

Both alerts use the `team=security` label, which the included notification policy routes to
the `teleport-slack` contact point.

To import after a fresh Grafana deploy:

```bash
make import-alerts SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
```

Or add `SLACK_WEBHOOK_URL=...` to your `.env` file and run `make import-alerts`.

> The Slack webhook URL is substituted at import time and is never written to the repo.

## Makefile reference

```bash
# First-time setup
make setup               # tbot mode: certs, RBAC, bot, tls secret
make setup-static        # static mode: certs, RBAC, identity, all secrets
make setup-certs         # generate mTLS certs only (clears ./certs/ first)
make setup-role          # apply Teleport RBAC roles only
make setup-bot           # create Teleport bot + bootstrap token (tbot mode)
make setup-identity      # sign 1-year identity file (static mode only)
make create-tls-secret   # load ./certs/ into k8s secret (CA + client + server certs)
make create-identity-secret  # load ./identity/ into k8s secret (static mode only)

# Helm
make install             # helm install
make upgrade             # helm upgrade
make uninstall           # helm uninstall

# Grafana dashboards & alerts
make import-dashboards   # import all dashboards from dashboards/ into Grafana
make import-alerts       # import alert rules, contact point, and notification policy

# Observability
make logs                # tail all pods
make logs-fluentd        # tail Fluentd only
make logs-handler        # tail event-handler only
make status              # show pods / deployments / pvcs

# Cleanup
make clean               # uninstall + delete secrets + remove certs/identity
```

## Known issues and fixes applied

The following bugs were found and fixed during initial deployment. They are already
corrected in the chart — this section exists to explain why the chart differs from
naive Fluentd / event-handler documentation.

### tbot kubernetes join requires static_jwks for Teleport Enterprise Cloud

The original `setup-bot` created a provision token with `type: in_cluster`, which requires
Teleport's auth server to verify the SA JWT by calling your cluster's Kubernetes TokenReview
API. For self-hosted Teleport running inside the cluster this works, but Teleport Enterprise
Cloud's auth server does not run in your cluster — it fails at rejoin time with:

```
failed to initialize in-cluster Kubernetes config:
    open /var/run/secrets/kubernetes.io/serviceaccount/token: no such file or directory
```

The fix: `setup-bot` creates the token with `type: static_jwks`. Teleport fetches your
cluster's public JWKS once (from `/openid/v1/jwks`) and stores it in the provision token
resource. At join time it validates the SA JWT signature offline — no call to your Kubernetes
API needed.

Two additional constraints of `static_jwks` required changes to the StatefulSet:

- **Wrong audience:** the default automounted SA token has `aud: kubernetes`. `static_jwks`
  requires the audience to match the Teleport proxy address. The StatefulSet now sets
  `automountServiceAccountToken: false` and mounts a custom projected SA token with
  `audience: <teleport-proxy-addr>` at the standard path.
- **TTL too long:** `static_jwks` requires the SA token TTL to be under 30 minutes. The
  custom projected token uses `expirationSeconds: 1200` (20 minutes).

### Fluentd timestamp extraction causes Loki 400 rejections

Fluentd's `@type json` parser in the HTTP source automatically extracts the `time` field
from the incoming JSON body and uses it as the Fluentd record timestamp. Teleport events
carry a `time` field in RFC3339 format (`2026-06-26T21:17:05.395Z`). Without an explicit
`time_format`, Fluentd fails to parse this string and falls back to epoch
(`1970-01-01T00:00:00Z`). Loki rejects any entry older than its configured reject window
(default: 7 days), returning HTTP 400.

The fix: set `time_key ""` in the JSON parser so Fluentd uses wall-clock time (the moment
the event arrives at Fluentd) instead of trying to extract the Teleport `time` field. This
always produces a current timestamp that Loki accepts. The actual event time remains
available in the JSON body of the log line.

### Fluentd internal SSL log events forwarded to Loki

With `<match **>` as the only output block, Fluentd's own internal log events (tagged
`fluent.**`) are forwarded to Loki alongside the Teleport audit events. These include SSL
connection warnings from Kubernetes health checks that open a TCP connection and immediately
close it without completing the TLS handshake.

The fix: add `<match fluent.**> @type null </match>` **before** the main output block.
Fluentd matches rules top-to-bottom, so internal events are silently dropped before
reaching the Loki output.

### kube.request audit events produce very high event volume

In clusters with ArgoCD or frequent `kubectl` usage, `kube.request` events (one per
Kubernetes API call) dominate the audit stream. With an unfiltered stream this can
produce thousands of events per minute, most of which have low security value.

The fix: the event-handler TOML config uses the `types` top-level allowlist to forward only
security-relevant events. `kube.request`, `resize`, `app.session.request`, `app.session.chunk`
and other high-volume, low-value types are implicitly excluded. The full list is in
`values.yaml` under `eventHandler.types` and can be extended or trimmed as needed.

Note: the `types` field must be at the top level of the TOML config (before `[teleport]`).
When placed inside the `[teleport]` section it is silently ignored.

### event-handler v18 TOML format change

The `[fluentd]` TOML section was renamed to `[forward.fluentd]` in v18, and
`session_url` became `session-url`. The `event-handler-configmap.yaml` template
reflects the correct v18 format.

### fluent-plugin-grafana-loki extra_labels format

The Loki Fluentd plugin uses `extra_labels` (not `<label>` or `<labels>` blocks) to
attach stream labels. The value must be a raw JSON hash — wrapping it in quotes produces
an invalid string instead of a hash object. The configmap template uses `| toJson` without
`| quote` to render `extra_labels {"job":"teleport-audit"}` correctly.

### Fluentd gem install permissions

The `fluent/fluentd` image does not have write access to the system gem path. The
init container and main container both set `GEM_HOME=/usr/local/bundle` (backed by
an emptyDir volume) so gems install and load from a writable location.

### Fluentd TLS uses server cert, not client cert

The Fluentd `<source>` acts as the TLS **server**. It must be configured with
`server.crt` / `server.key` (not `client.crt` / `client.key`), and
`client_cert_auth true` to require the event-handler to present its client
certificate. The server key passphrase is stored in the TLS Kubernetes Secret
and injected via the `FLUENTD_TLS_PASSPHRASE` environment variable.

### Server cert must include the Fluentd service DNS name

`teleport-event-handler configure` defaults the server cert SAN to `localhost`
only. The `make setup-certs` target passes
`--dns-names=localhost,<release>-fluentd.<namespace>.svc.cluster.local`
so the event-handler can verify the server certificate when connecting inside
the cluster. If the release name or namespace changes, certs must be regenerated
and the TLS secret updated.

### Kubernetes readiness probes must use tcpSocket

When Fluentd's HTTP source has TLS enabled, plain HTTP health checks fail the
TLS handshake and the pod never becomes Ready. The liveness and readiness probes
use `tcpSocket` instead of `httpGet`.

### Helm namespace adoption

If the namespace is created by `kubectl` before `helm install`, Helm refuses to
manage it. The `make create-tls-secret` target annotates and labels the namespace
with the required Helm ownership metadata so `helm install` can adopt it cleanly.

### tbot identity output must be on the PVC, not an emptyDir

The original chart wrote tbot's identity output to an emptyDir mounted at `/identity`.
emptyDir is wiped on every pod restart, so on restart the event-handler would race
with tbot at startup — if the event-handler started first it would exit immediately
with `no such file or directory` and enter CrashLoopBackOff.

The fix: tbot writes its identity output to `/var/lib/teleport-event-handler/tbot-output`
on the state PVC, and the event-handler reads it from the same path. The file survives
restarts, so there is no race on startup and reconnects always use a fresh cert from disk.

### StatefulSet requires a ServiceAccount to exist

The StatefulSet spec references `serviceAccountName: <release>-event-handler`. Without
a matching ServiceAccount in the namespace the pod fails with a `forbidden` error before
it even starts. A minimal ServiceAccount template (`serviceaccount.yaml`) is included
in the chart.

### Fluentd file buffer exhausts file descriptors under backlog bursts

The Fluentd file buffer had no cap on the number of queued chunks. When the event-handler
delivers a large backlog of events all at once, Fluentd creates a buffer file per chunk
and can exhaust the process's file descriptor limit, returning HTTP 500 to the event-handler
and stalling ingestion. Three buffer settings cap this:

- `queued_chunks_limit_size 64` — maximum queued buffer files at any one time
- `total_limit_size 512m` — hard cap on total buffer disk usage
- `overflow_action block` — back-pressures the event-handler (HTTP 503) instead of
  crashing; the event-handler retries, so no events are lost

### Fluentd buffer must be on a PVC to survive restarts

The original chart used an emptyDir for the Fluentd file buffer. On any pod restart
(rolling deploy, eviction, node drain), in-flight buffer chunks were silently dropped.
Because the event-handler marks events as sent once Fluentd returns HTTP 200 (accepted
into buffer), those events are never retried and are permanently lost.

The fix: a dedicated 2Gi PVC (`fluentd.persistence`, enabled by default) replaces the
emptyDir. Buffer chunks survive pod restarts and keep retrying across transient Loki
outages.

## Files

| File | Purpose |
|---|---|
| `helm/teleport-loki/values.yaml` | All chart configuration |
| `helm/teleport-loki/templates/tbot-configmap.yaml` | tbot config: kubernetes join method, 1h cert TTL, PVC storage path |
| `helm/teleport-loki/templates/event-handler-configmap.yaml` | Event handler TOML config (v18 `[forward.fluentd]` format) |
| `helm/teleport-loki/templates/event-handler-statefulset.yaml` | Event handler + tbot sidecar; both share the state PVC |
| `helm/teleport-loki/templates/serviceaccount.yaml` | ServiceAccount for the event-handler StatefulSet pod |
| `helm/teleport-loki/templates/fluentd-configmap.yaml` | Fluentd config (mTLS HTTP input → Loki output, `time_key ""` fix) |
| `helm/teleport-loki/templates/fluentd-deployment.yaml` | Fluentd workload (GEM_HOME fix, tcpSocket probes, PVC buffer) |
| `helm/teleport-loki/templates/fluentd-buffer-pvc.yaml` | PVC for the Fluentd file buffer (survives restarts) |
| `helm/teleport-loki/templates/fluentd-service.yaml` | ClusterIP service for Fluentd |
| `dashboards/README.md` | Dashboard import instructions and LogQL query reference |
| `dashboards/teleport-audit-events.json` | Grafana dashboard — general audit event overview |
| `dashboards/teleport-kubernetes-access.json` | Grafana dashboard — Kubernetes access and exec activity |
| `dashboards/teleport-access-requests.json` | Grafana dashboard — JIT access request lifecycle |
| `dashboards/teleport-identity-changes.json` | Grafana dashboard — role, user, lock, and connector changes |
| `alerts/alert-rules.json` | Grafana alert rules — identity changes and failed logins |
| `alerts/contact-points.json` | Slack contact point (webhook URL stored as placeholder) |
| `alerts/notification-policy.json` | Notification routing — `team=security` → Slack |
| `teleport-event-handler-role.yaml` | Teleport RBAC role + user applied with `tctl` |
| `Makefile` | Helper commands |
