# Project HANGAR - single entry point for every phase.
# Run `make` (or `make help`) to list targets. Designed for WSL2/Linux/macOS.

SHELL := /bin/bash
.SHELLFLAGS := -Eeuo pipefail -c
.DEFAULT_GOAL := help

# Machine-local settings written by the bootstrap scripts (gitignored).
-include .env.hangar
export

##@ General

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } \
		/^[a-zA-Z0-9_-]+:.*## / { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: prereqs
prereqs: ## Check the local toolchain
	@bash scripts/check-prereqs.sh

##@ Phase 0 - Bootstrap

.PHONY: bootstrap
bootstrap: bootstrap-state bootstrap-oidc ## Create remote state backend and GitHub OIDC identity

.PHONY: bootstrap-state
bootstrap-state: ## Create the Terraform remote-state storage account
	@bash bootstrap/bootstrap-tfstate.sh

.PHONY: bootstrap-oidc
bootstrap-oidc: ## Create the GitHub Actions OIDC app registration and roles
	@bash bootstrap/setup-oidc.sh

##@ Phase 1 - Infrastructure (ENV=dev|prod, default dev)

ENV  ?= dev
UNIT ?=
CMD  ?= plan
TG   := terragrunt
TG_LIVE := infra/live

.PHONY: infra-fmt
infra-fmt: ## Format Terraform modules and Terragrunt HCL
	terraform fmt -recursive infra/modules
	cd $(TG_LIVE) && $(TG) hcl fmt

.PHONY: infra-validate
infra-validate: ## Validate every module (no backend) and all Terragrunt HCL
	@for m in infra/modules/*/; do \
		echo "== $$m"; \
		(cd "$$m" && terraform init -backend=false -input=false >/dev/null && terraform validate -no-color); \
	done
	cd $(TG_LIVE) && $(TG) hcl validate

.PHONY: infra-scan
infra-scan: ## Policy-as-code scan of the modules with Checkov
	checkov -d infra/modules --framework terraform --compact

.PHONY: infra-graph
infra-graph: ## Print the unit dependency graph for ENV
	cd $(TG_LIVE)/$(ENV) && $(TG) dag graph

.PHONY: infra-plan
infra-plan: ## Plan every unit in ENV (dependency order)
	cd $(TG_LIVE)/$(ENV) && $(TG) run --all plan

.PHONY: infra-apply
infra-apply: ## Apply every unit in ENV (asks for confirmation)
	cd $(TG_LIVE)/$(ENV) && $(TG) run --all apply

.PHONY: infra-destroy
infra-destroy: ## Destroy every unit in ENV, reverse dependency order (asks for confirmation)
	cd $(TG_LIVE)/$(ENV) && $(TG) run --all destroy

.PHONY: infra-unit
infra-unit: ## Run one unit: make infra-unit UNIT=aks CMD=plan
	@test -n "$(UNIT)" || { echo "UNIT is required, e.g. UNIT=aks"; exit 1; }
	cd $(TG_LIVE)/$(ENV)/$(UNIT) && $(TG) $(CMD)

.PHONY: infra-output
infra-output: ## Show outputs for every unit in ENV
	cd $(TG_LIVE)/$(ENV) && $(TG) run --all output

.PHONY: aks-credentials
aks-credentials: ## Merge kubeconfig for ENV's cluster (Entra ID auth via kubelogin)
	az aks get-credentials -g rg-hangar-$(ENV) -n aks-hangar-$(ENV) --overwrite-existing
	kubelogin convert-kubeconfig -l azurecli

##@ Quality

.PHONY: hooks
hooks: ## Install git pre-commit hooks
	pre-commit install

.PHONY: lint
lint: ## Run every pre-commit hook against all files
	pre-commit run --all-files
