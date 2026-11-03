SHELL := /bin/bash
.DEFAULT_GOAL := help

VENV := .venv
PY := $(VENV)/bin/python
IMAGE := hello-api
TAG := $(shell git rev-parse --short HEAD)

KIND_CLUSTER := hello
KIND_CONFIG := k8s/kind_config.yaml

.PHONY: help venv lint test build run smoke ci

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