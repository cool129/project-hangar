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

##@ Quality

.PHONY: hooks
hooks: ## Install git pre-commit hooks
	pre-commit install

.PHONY: lint
lint: ## Run every pre-commit hook against all files
	pre-commit run --all-files
