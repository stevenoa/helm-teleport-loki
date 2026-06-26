# Grafana Dashboards

Pre-built Grafana dashboards for Teleport audit events stored in Grafana Loki.

## Dashboards

| File | Title | Description |
|---|---|---|
| `teleport-audit-events.json` | Teleport Audit Events | General overview — event volume, auth, sessions, access requests, full log stream |
| `teleport-kubernetes-access.json` | Teleport — Kubernetes Access | K8s session starts/ends, exec commands, port forwards — broken down by cluster and user |
| `teleport-access-requests.json` | Teleport — Access Requests | JIT access request lifecycle — created, approved, denied — by requester and reviewer |

## Importing dashboards

All dashboards are imported the same way via the Grafana HTTP API.
Run these commands from the repo root.

### Prerequisites

Get your Grafana admin password:

```bash
kubectl get secret -n grafana grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

Set a variable for the Grafana pod:

```bash
GRAFANA_POD=$(kubectl get pod -n grafana \
  -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[0].metadata.name}')
```

### Import a single dashboard

```bash
kubectl cp dashboards/<filename>.json grafana/${GRAFANA_POD}:/tmp/<filename>.json

kubectl exec -n grafana ${GRAFANA_POD} -- curl -s -X POST \
  'http://admin:YOUR_PASSWORD@localhost:3000/api/dashboards/db' \
  -H 'Content-Type: application/json' \
  -d @/tmp/<filename>.json
```

### Import all dashboards at once

```bash
GRAFANA_POD=$(kubectl get pod -n grafana \
  -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[0].metadata.name}')

for f in dashboards/*.json; do
  name=$(basename "$f")
  kubectl cp "$f" "grafana/${GRAFANA_POD}:/tmp/${name}"
  kubectl exec -n grafana "${GRAFANA_POD}" -- curl -s -X POST \
    'http://admin:YOUR_PASSWORD@localhost:3000/api/dashboards/db' \
    -H 'Content-Type: application/json' \
    -d "@/tmp/${name}" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('status','?'), r.get('url',''))"
done
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
