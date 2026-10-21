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

##@ Phase 2 - Application

APP_DIR   := app
APP_VENV  := $(APP_DIR)/.venv
APP_IMAGE ?= sortie-tracker
GIT_SHA   ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo local)
COMPOSE   := docker compose -f $(APP_DIR)/docker-compose.yml
# 127.0.0.1, not localhost: on Windows/WSL localhost may resolve to ::1 first,
# which Docker does not publish on, and the connection stalls.
TEST_DATABASE_URL ?= postgresql+psycopg://sortie:local-dev-only@127.0.0.1:55432/sortie_tracker_it?connect_timeout=5

.PHONY: app-venv
app-venv: ## Create app/.venv with runtime (pinned) + dev dependencies
	python3 -m venv $(APP_VENV)
	$(APP_VENV)/bin/pip install -c $(APP_DIR)/constraints.txt -e '$(APP_DIR)[dev]'

.PHONY: app-lint
app-lint: ## Ruff lint + format check
	cd $(APP_DIR) && .venv/bin/ruff check . && .venv/bin/ruff format --check .

.PHONY: app-test
app-test: ## Unit tests with coverage (in-memory SQLite, no Docker needed)
	cd $(APP_DIR) && .venv/bin/pytest -m "not integration" --cov --cov-report=term-missing:skip-covered

.PHONY: app-test-integration
app-test-integration: ## Migrations, schema drift and API tests against PostgreSQL in Docker
	$(COMPOSE) up -d --wait db
	@# Throwaway database: the tests downgrade the schema, so never use the dev one.
	$(COMPOSE) exec -T db psql -U sortie -d sortie_tracker -q \
		-c "DROP DATABASE IF EXISTS sortie_tracker_it" -c "CREATE DATABASE sortie_tracker_it"
	cd $(APP_DIR) && TEST_DATABASE_URL='$(TEST_DATABASE_URL)' .venv/bin/pytest -m integration -v

.PHONY: app-lock
app-lock: ## Regenerate constraints.txt by resolving dependencies inside the runtime base image
	docker run --rm -v "$(CURDIR)/$(APP_DIR):/src:ro" python:3.13-slim sh -c \
		'cp -r /src /tmp/app && pip install -q --root-user-action=ignore /tmp/app >/dev/null && pip freeze --exclude sortie-tracker' \
		| { echo "# Pinned runtime dependency versions for reproducible image builds."; echo "# Regenerate: make app-lock"; cat; } \
		> $(APP_DIR)/constraints.txt

.PHONY: app-build
app-build: ## Build the container image tagged with the git SHA
	docker build --build-arg GIT_SHA=$(GIT_SHA) -t $(APP_IMAGE):$(GIT_SHA) -t $(APP_IMAGE):local $(APP_DIR)

.PHONY: app-scan
app-scan: ## Trivy scan: fail on fixable HIGH/CRITICAL vulnerabilities
	trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 $(APP_IMAGE):local

.PHONY: app-up
app-up: ## Run db + migrations + API locally on http://localhost:18080 (API_PORT)
	GIT_SHA=$(GIT_SHA) $(COMPOSE) up -d --build --wait api

.PHONY: app-seed
app-seed: ## Load deterministic squadron data (skipped if data exists)
	$(COMPOSE) run --rm api sortie-tracker-seed --if-empty

.PHONY: app-logs
app-logs: ## Follow API logs (JSON)
	$(COMPOSE) logs -f api

.PHONY: app-down
app-down: ## Stop the local stack and delete its database volume
	$(COMPOSE) down -v

##@ Quality

.PHONY: hooks
hooks: ## Install git pre-commit hooks
	pre-commit install

.PHONY: lint
lint: ## Run every pre-commit hook against all files
	pre-commit run --all-files
