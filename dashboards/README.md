# Grafana Dashboards

Pre-built Grafana dashboards for Teleport audit events stored in Grafana Loki.

## Dashboards

| File | Title | Description |
|---|---|---|
| `teleport-audit-events.json` | Teleport Audit Events | General overview — event volume, auth, sessions, access requests, full log stream |
| `teleport-kubernetes-access.json` | Teleport — Kubernetes Access | K8s session starts/ends, exec commands, port forwards — broken down by cluster and user |
| `teleport-access-requests.json` | Teleport — Access Requests | JIT access request lifecycle — created, approved, denied — by requester and reviewer |
| `teleport-identity-changes.json` | Teleport — Identity Changes | Role, user, lock, connector, and trusted cluster changes — all turns red on any activity |
| `teleport-nginx-k8s-demo.json` | Teleport — Nginx K8s Access Demo | `kube.request` events for the `gitlab-nginx-ci` bot only — restart-only traffic to `nginx-prod1` vs. full-access traffic to `demo-nginx` |

## Importing dashboards

### Using Make (recommended)

From the repo root:

```bash
make import-dashboards
```

This automatically fetches the Grafana admin password from the `grafana` Kubernetes Secret,
copies each dashboard JSON into the Grafana pod, and imports it via the API. Output shows
the status and URL for each dashboard on success.

Override defaults via `.env` or environment variables if needed:

```bash
GRAFANA_NS=my-grafana-namespace make import-dashboards   # different namespace
GRAFANA_PASS=mypassword make import-dashboards           # skip secret lookup
```

### Manual import (single dashboard)

If you prefer to import one dashboard at a time:

```bash
GRAFANA_POD=$(KUBECONFIG="${HOME}/teleport-kubeconfig.yaml" kubectl get pod -n grafana \
  -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[0].metadata.name}')

kubectl cp dashboards/<filename>.json grafana/${GRAFANA_POD}:/tmp/<filename>.json

kubectl exec -n grafana ${GRAFANA_POD} -- curl -s -X POST \
  'http://admin:YOUR_PASSWORD@localhost:3000/api/dashboards/db' \
  -H 'Content-Type: application/json' \
  -d @/tmp/<filename>.json
```

---

## Dashboard details

### Teleport Audit Events (`teleport-audit-events.json`)

General-purpose overview dashboard. Good starting point.

**Panels:**

| Panel | Type | Query |
|---|---|---|
| Total Events (24h) | Stat | `sum(count_over_time({job="teleport-audit"}[$__range]))` |
| Failed Logins (24h) | Stat | `... \| event="user.login" \| success="false"` — turns red if > 0 |
| Session Starts (24h) | Stat | `... \| event="session.start"` |
| Access Requests (24h) | Stat | `... \| event=~"access_request.*"` |
| Event Rate by Type | Timeseries | `sum by (event) (rate(...\| json [2m]))` |
| Authentication Events | Timeseries | Login success/fail + cert.create rates |
| Sessions & Access Requests | Timeseries | session.start/end + access_request.* rates |
| Failed Logins | Logs | Live stream of failed login events |
| Access Requests | Logs | Live stream of access request events |
| All Audit Events | Logs | Full audit log stream |

---

### Teleport — Kubernetes Access (`teleport-kubernetes-access.json`)

Focused on kubectl/Kubernetes activity. Useful for spotting unusual exec into production pods,
cross-namespace access, or unexpected port forwards.

**Panels:**

| Panel | Type | Query |
|---|---|---|
| K8s Sessions Started (24h) | Stat | `... \| event="session.start" \| proto="kube"` |
| Exec Commands (24h) | Stat | `... \| event="exec"` |
| Port Forwards (24h) | Stat | `... \| event="port"` |
| Session Ends (24h) | Stat | `... \| event="session.end" \| proto="kube"` |
| K8s Event Rate by Type | Timeseries | session.start, session.end, exec, port rates |
| Sessions by Cluster | Timeseries | `sum by (kubernetes_cluster) (rate(...))` |
| Sessions by User | Timeseries | `sum by (user) (rate(...))` |
| Recent Exec Commands | Logs | Live stream of exec events |
| Recent Session Starts | Logs | Live stream of K8s session starts |
| All Kubernetes Events | Logs | Full stream of all K8s-related events |

**Useful ad-hoc queries for Explore:**

```logql
# Exec commands with context
{job="teleport-audit"} | json | event="exec"
  | line_format `{{.user}} ran '{{.command}}' in {{.kubernetes_pod_namespace}}/{{.kubernetes_pod_name}}`

# All activity in a specific namespace
{job="teleport-audit"} | json | kubernetes_pod_namespace="production"

# Exec commands to a specific pod
{job="teleport-audit"} | json | event="exec" | kubernetes_pod_name=~"api-.*"

# Sessions to a specific cluster
{job="teleport-audit"} | json | event="session.start" | kubernetes_cluster="prod-us-east-1"
```

---

### Teleport — Access Requests (`teleport-access-requests.json`)

Tracks the full JIT access request lifecycle. Useful for compliance reviews and
demonstrating Teleport's just-in-time access workflow.

**Panels:**

| Panel | Type | Query |
|---|---|---|
| Requests Created (24h) | Stat | `... \| event="access_request.create"` |
| Approved (24h) | Stat | `... \| event="access_request.review" \| state="APPROVED"` |
| Denied (24h) | Stat | `... \| event="access_request.review" \| state="DENIED"` — turns red if > 0 |
| Total Reviews (24h) | Stat | `... \| event="access_request.review"` |
| Request Activity Over Time | Timeseries | created, approved, denied rates |
| Requests by Requester | Timeseries | `sum by (user) (rate(...))` |
| Reviews by Reviewer | Timeseries | `sum by (reviewer) (rate(...))` |
| Recent Requests Created | Logs | Live stream of new requests |
| Recent Reviews | Logs | Live stream of approvals and denials |
| All Access Request Events | Logs | Full stream of all access_request.* events |

**Useful ad-hoc queries for Explore:**

```logql
# All requests and their outcome
{job="teleport-audit"} | json | event=~"access_request.*"

# Only denied requests
{job="teleport-audit"} | json | event="access_request.review" | state="DENIED"

# Requests for a specific role
{job="teleport-audit"} | json | event="access_request.create" | roles=~".*production.*"

# All reviews by a specific reviewer
{job="teleport-audit"} | json | event="access_request.review" | reviewer="alice@example.com"

# Requests from a specific user
{job="teleport-audit"} | json | event="access_request.create" | user="bob@example.com"
```

---

### Teleport — Identity Changes (`teleport-identity-changes.json`)

Tracks all privileged configuration changes in Teleport. Every stat panel turns red on
any activity — useful as a security monitoring view where the expected state is zero changes.

**Panels:**

| Panel | Type | Query |
|---|---|---|
| Role Changes (24h) | Stat | `... \| event=~"role\.(create\|update\|delete)"` — red if > 0 |
| User Changes (24h) | Stat | `... \| event=~"user\.(create\|update\|delete)"` — red if > 0 |
| Locks Created (24h) | Stat | `... \| event="lock.create"` — orange if > 0 |
| Connector Changes (24h) | Stat | `... \| event=~"(github\|oidc\|saml)\.connector\.(create\|delete)"` — red if > 0 |
| Identity Change Activity | Timeseries | All change types as separate series over time |
| Role Changes by Actor | Timeseries | `sum by (user) (rate(...))` — who made role changes |
| User Changes by Actor | Timeseries | `sum by (user) (rate(...))` — who made user changes |
| Role Changes | Logs | Live stream of role create/update/delete events |
| User Changes | Logs | Live stream of user create/update/delete events |
| Locks | Logs | Live stream of lock create/delete events |
| Connector & Trusted Cluster Changes | Logs | Live stream of connector and trusted cluster events |
| All Identity Change Events | Logs | Full stream of all identity-related changes |

**Useful ad-hoc queries for Explore:**

```logql
# All identity changes
{job="teleport-audit"} | json | event=~"(role|user)\\.(create|update|delete)|lock\\.(create|delete)|(github|oidc|saml)\\.connector\\.(create|delete)"

# Who edited which role
{job="teleport-audit"} | json | event=~"role\\.(create|update|delete)"
  | line_format `{{.user}} → {{.event}} on role "{{.name}}"`

# All changes made by a specific user
{job="teleport-audit"} | json | event=~"(role|user)\\.(create|update|delete)" | user="alice@example.com"

# Locks only
{job="teleport-audit"} | json | event=~"lock\\.(create|delete)"
```

---

### Teleport — Nginx K8s Access Demo (`teleport-nginx-k8s-demo.json`)

Scoped to a single identity — the `gitlab-nginx-ci` bot from
[project_nginx_k8s_access_demo](https://gitlab.steveno-enterprise-cloud.teleport.sh/steven.oakley/ansible/-/blob/main/docs/nginx-k8s-access-runbook.md).
Every panel filters on `user="bot-gitlab-nginx-ci"`, so this dashboard shows
nothing for any other identity even though `kube.request` is a
cluster-wide, high-volume event type.

**Panels:**

| Panel | Type | Query |
|---|---|---|
| Total Requests (24h) | Stat | `... \| event="kube.request" \| user="bot-gitlab-nginx-ci"` |
| nginx-prod1 Requests (24h) | Stat | `... \| resource_namespace="nginx-prod1"` |
| demo-nginx Requests (24h) | Stat | `... \| resource_namespace="demo-nginx"` |
| Non-200 Responses (24h) | Stat | `... \| response_code!="200"` — turns red if > 0 |
| Request Rate by Namespace | Timeseries | `sum by (resource_namespace) (rate(...))` |
| Request Rate by Verb | Timeseries | `sum by (verb) (rate(...))` |
| Requests to nginx-prod1 | Logs | Live stream, restart-only scope |
| Requests to demo-nginx | Logs | Live stream, full-access scope |
| All gitlab-nginx-ci Kubernetes Requests | Logs | Full stream for this identity only |

**Known gap:** Teleport's own RBAC denials (the `kubernetes_resources` field
rejecting e.g. a `delete` in `nginx-prod1`) happen *before* the request
reaches the Kubernetes API server, so they never generate a non-200
`kube.request` event — only a denial message returned directly to
`kubectl`. The "Non-200 Responses" panel only catches denials from the
Kubernetes API server's own RBAC, not Teleport's. To see Teleport-level
denials, check the CI job log directly (`nginx-k8s-access-demo` in
`machine-id-demo`) rather than this dashboard.

`kube.request` fires on every single Kubernetes API call — it's excluded
from the default event-handler `types` allow-list as noise (see the
comment in `values.yaml`). It was deliberately re-added specifically to
support this dashboard; watch Loki ingest volume if that becomes a
problem at scale.

---

## Loki datasource UID

The dashboards are pre-configured for datasource UID `afqc1lplux9fka`. If your Loki
datasource has a different UID, update it in each JSON file:

```bash
# Check your Loki datasource UID
kubectl exec -n grafana deployment/grafana -- \
  curl -s 'http://admin:YOUR_PASSWORD@localhost:3000/api/datasources' \
  | python3 -c "import sys,json; [print(d['uid'], d['name']) for d in json.load(sys.stdin)]"

# Replace the UID in all dashboard files
sed -i '' 's/afqc1lplux9fka/YOUR_NEW_UID/g' dashboards/*.json
```
