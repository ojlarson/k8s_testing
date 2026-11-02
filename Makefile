SHELL := /bin/bash
.DEFAULT_GOAL := help

VENV := .venv
PY := $(VENV)/bin/python
IMAGE := hello-api
TAG := $(shell git rev-parse --short HEAD)

.PHONY: help venv lint test build

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

ci: lint test build