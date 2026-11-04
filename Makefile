SHELL := /bin/bash
.DEFAULT_GOAL := help

VENV := .venv
PY := $(VENV)/bin/python
IMAGE := hello-api
TAG := $(shell git rev-parse --short HEAD)

KIND_CLUSTER := hello
KIND_CONFIG := k8s/kind_config.yaml

KUBECTL := kubectl --context kind-$(KIND_CLUSTER)
NGF_VERSION := 2.8.1

.PHONY: help venv lint test build run smoke ci kubeconform

help: ## Display this help message
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

$(VENV)/.installed: requirements.txt requirements-dev.txt
	python -m venv $(VENV)
	$(PY) -m pip install --upgrade pip
	$(PY) -m pip install -r requirements-dev.txt
	touch $@

venv: $(VENV)/.installed ## create .venv and install dependencies

lint: venv ## lint code with ruff
	$(PY) -m ruff check .

test: venv ## run the test suite
	$(PY) -m pytest

show-tag: ## print the image tag this run would use
	@echo $(IMAGE):$(TAG)

build: ## build the docker image tagged with the git SHA
	docker build -t $(IMAGE):$(TAG) .

run: ## run docker locally
	docker run --rm -p 8000:8000 $(IMAGE):$(TAG)

smoke: build ## run the image and hit /healthz
	docker run -d --rm --name smoke -p 8000:8000 $(IMAGE):$(TAG)
	sleep 3
	curl -fsS localhost:8000/healthz; status=$$?; docker stop smoke; exit $$status

ci: lint test build

kind-up: ## create the kind cluster if it doesn't exist
	@if kind get clusters | grep -qx "$(KIND_CLUSTER)"; then \
		echo "kind cluster '$(KIND_CLUSTER)' already exists"; \
	else \
		kind create cluster --name $(KIND_CLUSTER) --config $(KIND_CONFIG) --wait 30s; \
	fi

kind-down: ## delete kind cluster
	kind delete cluster --name $(KIND_CLUSTER)

kube-deploy: gateway-install build ## build, load, and deploy everything into kind
	kind load docker-image $(IMAGE):$(TAG) --name $(KIND_CLUSTER)
	$(KUBECTL) apply -f k8s/gateway.yaml
	$(KUBECTL) apply -f k8s/config_map.yaml
	sed 's|image: $(IMAGE):.*|image: $(IMAGE):$(TAG)|' k8s/deployment.yaml | $(KUBECTL) apply -f -
	$(KUBECTL) rollout status deployment/hello-api
	$(KUBECTL) apply -f k8s/routes.yaml

kubeconform: ## validate k8s manifests against schemas
	kubeconform -strict -summary \
		-kubernetes-version 1.37.0 \
		-skip Cluster \
		-schema-location default \
		-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
		k8s/*.yaml

gateway-install: kind-up ## install Gateway API CRDs + NGINX Gateway Fabric (idempotent)
	$(KUBECTL) kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v$(NGF_VERSION)" \
		| $(KUBECTL) apply -f -
	helm upgrade --install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
		--kube-context kind-$(KIND_CLUSTER) \
		--version $(NGF_VERSION) \
		--create-namespace -n nginx-gateway \
		--set nginx.service.type=NodePort \
		--set-json 'nginx.service.nodePorts=[{"port":31437,"listenerPort":80}]'
	$(KUBECTL) wait --for=condition=available deployment --all -n nginx-gateway --timeout=120s

smoke-kind: 
	curl -fsS --retry 10 --retry-delay 3 --retry-connrefused --retry-all-errors \
	-H "Host: hello.localhost" http://localhost/healthz | grep -q '"status":"ok"'