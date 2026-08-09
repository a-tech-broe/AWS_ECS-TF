SHELL := /bin/bash
ENV ?= dev
ENV_DIR := envs/$(ENV)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Override the target environment with ENV=<dev|staging|prod>."

.PHONY: fmt
fmt: ## Rewrite all Terraform files to canonical format
	terraform fmt -recursive .

.PHONY: fmt-check
fmt-check: ## Fail if any Terraform file is unformatted
	terraform fmt -recursive -check -diff .

.PHONY: init
init: ## terraform init for $(ENV) using its backend.hcl
	terraform -chdir=$(ENV_DIR) init -backend-config=backend.hcl -reconfigure

.PHONY: validate
validate: ## Validate every module and environment root
	@set -euo pipefail; \
	for d in modules/*/ envs/*/ bootstrap/; do \
		echo "==> validating $$d"; \
		terraform -chdir=$$d init -backend=false -input=false >/dev/null; \
		terraform -chdir=$$d validate; \
	done

.PHONY: lint
lint: ## Run tflint across the repository
	tflint --init
	tflint --recursive --config="$(CURDIR)/.tflint.hcl"

.PHONY: sec
sec: ## Run Checkov static security analysis
	checkov --config-file .checkov.yaml

.PHONY: plan
plan: ## terraform plan for $(ENV)
	terraform -chdir=$(ENV_DIR) plan -input=false -out=tfplan

.PHONY: apply
apply: ## Apply the saved plan for $(ENV)
	terraform -chdir=$(ENV_DIR) apply -input=false tfplan

.PHONY: destroy
destroy: ## Destroy $(ENV) (blocked for prod)
	@if [ "$(ENV)" = "prod" ]; then echo "Refusing to destroy prod via make."; exit 1; fi
	terraform -chdir=$(ENV_DIR) destroy -input=false

.PHONY: check
check: fmt-check validate lint sec ## Run the full local gate (mirrors CI)
