SHELL := /bin/bash
.DEFAUL_GOAL := help

.PHONY: help lint build kind-up kind-down deploy-local

help: ## Display this help message
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## lint code