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

.PHONY: cost
cost: ## Report billable resources this platform owns, with a monthly estimate
	@./scripts/cost-inventory.sh

.PHONY: teardown
teardown: ## Tear down $(ENV), clearing whatever blocks destroy first
	@./scripts/teardown.sh $(ENV)

.PHONY: teardown-plan
teardown-plan: ## Show what teardown would remove from $(ENV), changing nothing
	@./scripts/teardown.sh $(ENV) --dry-run

.PHONY: teardown-all
teardown-all: ## Tear down every environment in dependency order
	@./scripts/teardown.sh --all

.PHONY: destroy
destroy: ## Raw terraform destroy for $(ENV). Prefer `teardown`, which unblocks first.
	@if [ "$(ENV)" = "prod" ]; then echo "Refusing to destroy prod via make; use scripts/teardown.sh prod."; exit 1; fi
	@echo "Note: this fails on deletion protection, non-empty log buckets and ECR images."
	@echo "      \`make teardown ENV=$(ENV)\` handles those. Continuing in 3s..."
	@sleep 3
	terraform -chdir=$(ENV_DIR) destroy -input=false

.PHONY: check
check: fmt-check validate lint sec ## Run the full local gate (mirrors CI)
