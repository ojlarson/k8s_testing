SHELL := /bin/bash
.DEFAULT_GOAL := help

APP := azimuth

VENV := .venv
PY := $(VENV)/bin/python
IMAGE := azimuth
TAG := $(shell git rev-parse --short HEAD)

KIND_CLUSTER := azimuth
KIND_CONFIG := kind/kind_config.yaml

KUBECTL := kubectl --context kind-$(KIND_CLUSTER)

NGF_VERSION := 2.8.1
NGF_VALUES := kind/ngf-values.yaml
NGF_NAMESPACE := nginx-gateway

API_KEY ?= fake-local-key
ENV ?= test

.PHONY: help venv lint test build run smoke ci kind-up kind-down gateway-install helm-deploy smoke-kind helm-check show-tag

help: ## Display this help message
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

$(VENV)/.installed: requirements.txt requirements-dev.txt
	python -m venv $(VENV)
	$(PY) -m pip install --upgrade pip
	$(PY) -m pip install -r requirements-dev.txt
	touch $@

venv: $(VENV)/.installed ## create .venv and install dependencies

lint: venv ## lint code with ruff
	$(PY) -m ruff format .
	$(PY) -m ruff check .

test: venv ## run the test suite
	$(PY) -m pytest

show-tag: ## print the image tag this run would use
	@echo $(IMAGE):$(TAG)

build: ## build the docker image tagged with the git SHA
	docker build -t $(IMAGE):$(TAG) .

run: ## run docker locally
	docker run --rm -p 8000:8000 $(IMAGE):$(TAG)

smoke-image: build ## run the image and hit /healthz
	-docker rm -f smoke >/dev/null 2>&1
	docker run -d --name smoke -p 8000:8000 $(IMAGE):$(TAG)
	curl -fsS --retry 15 --retry-delay 2 --retry-connrefused --retry-all-errors localhost:8000/healthz; \
	status=$$?; \
	if [ $$status -ne 0 ]; then echo "--- container logs ---"; docker logs smoke; fi; \
	docker rm -f smoke >/dev/null; \
	exit $$status

ci: lint test build

kind-up: ## create the kind cluster if it doesn't exist
	@if kind get clusters | grep -qx "$(KIND_CLUSTER)"; then \
		echo "kind cluster '$(KIND_CLUSTER)' already exists"; \
	else \
		kind create cluster --name $(KIND_CLUSTER) --config $(KIND_CONFIG) --wait 60s; \
	fi

kind-down: ## delete kind cluster
	kind delete cluster --name $(KIND_CLUSTER)

gateway-install: kind-up ## install Gateway API CRDs + NGF
	@if helm status ngf -n $(NGF_NAMESPACE) --kube-context kind-$(KIND_CLUSTER) >/dev/null 2>&1 && [ -z "$(FORCE)" ]; then \
		echo "NGF already installed (use FORCE=1 to reinstall/upgrade)"; \
	else \
		$(KUBECTL) kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v$(NGF_VERSION)" | $(KUBECTL) apply -f - && \
		helm upgrade --install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
			--kube-context kind-$(KIND_CLUSTER) --version $(NGF_VERSION) \
			--create-namespace -n $(NGF_NAMESPACE) \
			-f $(NGF_VALUES); \
	fi
	$(KUBECTL) wait --for=condition=available deployment --all -n $(NGF_NAMESPACE) --timeout=120s
	kubectl apply -f gateway/gateway.yaml
	$(KUBECTL) wait --for=condition=Programmed gateway/gateway --timeout=60s


helm-deploy: gateway-install build ## deploy into kind: make helm-deploy ENV=dev
	kind load docker-image $(IMAGE):$(TAG) --name $(KIND_CLUSTER)
	helm upgrade --install $(APP) chart/$(APP) \
		--wait --timeout 120s \
		--kube-context kind-$(KIND_CLUSTER) \
		-n $(ENV) --create-namespace \
		-f chart/$(APP)/values-kind.yaml \
		-f chart/$(APP)/values-$(ENV).yaml \
		--set image.tag=$(TAG) \
		--set apiKey=$(API_KEY)

helm-check: ## helm lint and use kubeconform on helm templates
	helm lint chart/$(APP) --set apiKey=$(API_KEY)
	helm template $(APP) -n $(ENV) chart/$(APP) \
	-f chart/$(APP)/values-kind.yaml \
	-f chart/$(APP)/values-$(ENV).yaml \
	--set apiKey=test123 \
	| kubeconform -strict -summary \
		-schema-location default \
		-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
		-


smoke-helm: ## run helm tests against the kind release
	helm test $(APP) -n $(ENV) --kube-context kind-$(KIND_CLUSTER) --logs

smoke-gateway: ## curl through the Gateway: make smoke-gateway ENV=dev
	$(KUBECTL) wait --for=condition=available deployment/gateway-nginx -n default --timeout=120s
	$(KUBECTL) wait httproute/$(APP) -n $(ENV) --timeout=60s \
		--for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True
	$(KUBECTL) wait httproute/$(APP) -n $(ENV) --timeout=60s \
		--for=jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}'=True
	curl -fsS --retry 10 --retry-delay 3 --retry-connrefused --retry-all-errors \
		-H "Host: $(ENV).localhost" http://localhost/healthz