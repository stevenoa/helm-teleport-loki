NAMESPACE    ?= teleport-loki
RELEASE      ?= teleport-loki
CHART        := ./helm/teleport-loki
KUBECONFIG   ?= $(HOME)/teleport-kubeconfig.yaml

# Override these via env or a local .env file
TELEPORT_ADDR  ?=
LOKI_URL       ?= http://loki-gateway.grafana.svc.cluster.local
GRAFANA_NS     ?= grafana
GRAFANA_PASS   ?=

-include .env

.PHONY: help setup-certs setup-identity setup-role setup-bot \
        create-tls-secret create-identity-secret install upgrade uninstall \
        import-dashboards \
        logs logs-fluentd logs-handler status clean

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ------------------------------------------------------------------------------
# One-time setup
# ------------------------------------------------------------------------------

setup-certs: ## Generate mTLS certs via teleport-event-handler configure
	@echo "==> Generating TLS certificates in ./certs/ ..."
	rm -rf certs && mkdir -p certs
	teleport-event-handler configure certs $(TELEPORT_ADDR) \
	  --dns-names=localhost,$(RELEASE)-fluentd.$(NAMESPACE).svc.cluster.local

setup-identity: ## Sign an identity file for the event-handler plugin user
	@echo "==> Signing identity file ..."
	mkdir -p identity
	tctl auth sign \
	  --user teleport-event-handler \
	  --out identity/identity \
	  --ttl 8760h

setup-role: ## Apply teleport-event-handler RBAC roles to the cluster
	@echo "==> Applying Teleport RBAC roles ..."
	tctl create -f teleport-event-handler-role.yaml

create-tls-secret: ## Create the Kubernetes TLS secret from ./certs/
	@echo "==> Creating TLS secret in namespace $(NAMESPACE) ..."
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic teleport-loki-tls \
	  --namespace $(NAMESPACE) \
	  --from-file=ca.crt=certs/ca.crt \
	  --from-file=client.crt=certs/client.crt \
	  --from-file=client.key=certs/client.key \
	  --from-file=server.crt=certs/server.crt \
	  --from-file=server.key=certs/server.key \
	  --from-literal=server.key.passphrase=$$(grep private_key_passphrase certs/fluent.conf | awk '{print $$2}' | tr -d '"') \
	  --dry-run=client -o yaml | kubectl apply -f -

create-identity-secret: ## Create the Kubernetes identity secret from ./identity/
	@echo "==> Creating identity secret in namespace $(NAMESPACE) ..."
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic teleport-loki-identity \
	  --namespace $(NAMESPACE) \
	  --from-file=identity=identity/identity \
	  --dry-run=client -o yaml | kubectl apply -f -

setup-bot: ## Create Teleport bot and kubernetes join token (tbot mode — no secret created)
	@echo "==> Creating Teleport bot ..."
	tctl bots add event-handler-bot --roles=teleport-event-handler 2>/dev/null || \
	  echo "    Bot already exists, skipping"
	@echo "==> Fetching cluster JWKS for static_jwks token type ..."
	$(eval JWKS := $(shell kubectl get --raw /openid/v1/jwks))
	@echo "==> Creating kubernetes join token in Teleport (static_jwks) ..."
	@printf 'kind: token\nversion: v2\nmetadata:\n  name: event-handler-bot-join\nspec:\n  roles:\n  - Bot\n  bot_name: event-handler-bot\n  join_method: kubernetes\n  kubernetes:\n    type: static_jwks\n    static_jwks:\n      jwks: '"'"'$(JWKS)'"'"'\n    allow:\n    - service_account: "$(NAMESPACE):$(RELEASE)-event-handler"\n' | tctl create -f - 2>/dev/null || \
	  echo "    Token already exists, skipping (run 'tctl tokens rm event-handler-bot-join' to recreate)"

setup: setup-certs setup-role setup-bot create-tls-secret ## Full first-time setup (tbot mode — no identity secret needed)

setup-static: setup-certs setup-role setup-identity create-tls-secret create-identity-secret ## Full setup using a static 1-year identity secret (no tbot)

# ------------------------------------------------------------------------------
# Helm
# ------------------------------------------------------------------------------

install: ## Install the Helm chart
	helm install $(RELEASE) $(CHART) \
	  --namespace $(NAMESPACE) \
	  --create-namespace \
	  --set teleport.addr=$(TELEPORT_ADDR) \
	  --set loki.url=$(LOKI_URL)

upgrade: ## Upgrade the Helm release
	helm upgrade $(RELEASE) $(CHART) \
	  --namespace $(NAMESPACE) \
	  --set teleport.addr=$(TELEPORT_ADDR) \
	  --set loki.url=$(LOKI_URL)

uninstall: ## Uninstall the Helm release
	helm uninstall $(RELEASE) --namespace $(NAMESPACE)

# ------------------------------------------------------------------------------
# Grafana dashboards
# ------------------------------------------------------------------------------

import-dashboards: ## Import all dashboards from dashboards/ into Grafana
	@if [ -z "$(GRAFANA_PASS)" ]; then \
	  echo "==> Fetching Grafana admin password from secret ..."; \
	  GRAFANA_PASS=$$(KUBECONFIG=$(KUBECONFIG) kubectl get secret -n $(GRAFANA_NS) grafana \
	    -o jsonpath='{.data.admin-password}' | base64 -d); \
	else \
	  GRAFANA_PASS="$(GRAFANA_PASS)"; \
	fi; \
	GRAFANA_POD=$$(KUBECONFIG=$(KUBECONFIG) kubectl get pod -n $(GRAFANA_NS) \
	  -l app.kubernetes.io/name=grafana \
	  -o jsonpath='{.items[0].metadata.name}'); \
	echo "==> Grafana pod: $$GRAFANA_POD"; \
	for f in dashboards/*.json; do \
	  name=$$(basename "$$f"); \
	  echo "==> Importing $$name ..."; \
	  KUBECONFIG=$(KUBECONFIG) kubectl cp "$$f" "$(GRAFANA_NS)/$$GRAFANA_POD:/tmp/$$name"; \
	  result=$$(KUBECONFIG=$(KUBECONFIG) kubectl exec -n $(GRAFANA_NS) "$$GRAFANA_POD" -- \
	    curl -s -X POST "http://admin:$$GRAFANA_PASS@localhost:3000/api/dashboards/db" \
	    -H 'Content-Type: application/json' \
	    -d "@/tmp/$$name"); \
	  echo "$$result" | python3 -c \
	    "import sys,json; r=json.load(sys.stdin); print('   ', r.get('status','?'), r.get('url',''))"; \
	done

# ------------------------------------------------------------------------------
# Observability
# ------------------------------------------------------------------------------

logs: ## Tail all pod logs in the namespace
	kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE) --all-containers -f

logs-fluentd: ## Tail Fluentd logs
	kubectl logs -n $(NAMESPACE) \
	  deployment/$(RELEASE)-teleport-loki-fluentd -f

logs-handler: ## Tail event-handler logs
	kubectl logs -n $(NAMESPACE) \
	  statefulset/$(RELEASE)-teleport-loki-event-handler -f

status: ## Show pod and deployment status
	@echo "\n==> Pods"
	kubectl get pods -n $(NAMESPACE)
	@echo "\n==> Deployments"
	kubectl get deployments -n $(NAMESPACE)
	@echo "\n==> StatefulSets"
	kubectl get statefulsets -n $(NAMESPACE)
	@echo "\n==> Services"
	kubectl get services -n $(NAMESPACE)
	@echo "\n==> PVCs"
	kubectl get pvc -n $(NAMESPACE)

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------

clean: uninstall ## Uninstall chart and delete secrets
	kubectl delete secret teleport-loki-tls teleport-loki-identity \
	  -n $(NAMESPACE) --ignore-not-found
	tctl tokens rm event-handler-bot-join 2>/dev/null || true
	rm -rf certs/ identity/
