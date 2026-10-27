# AutoDeployX — entry points.
#
# Every target here is a thin wrapper over a script or a terraform invocation
# that already existed. The point is discoverability: `make help` is a shorter
# path to "how do I run this" than reading eight shell scripts, and the
# environment switch below is what stops `-var-file` and `-backend-config`
# drifting apart by hand.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

ENV     ?= production
SERVICE ?= all
REGION  ?= ap-south-1

TF        := terraform -chdir=terraform
TFVARS    := envs/$(ENV).tfvars
BACKEND   := backend.$(ENV).hcl

.PHONY: help
help: ## Show this help
	@echo "AutoDeployX — make targets"
	@echo ""
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables: ENV=$(ENV)  SERVICE=$(SERVICE)  REGION=$(REGION)"
	@echo "Example:   make plan ENV=dev"

# --- Local development ----------------------------------------------------

.PHONY: up
up: ## Run a service locally with docker compose (SERVICE=finsight)
	@test "$(SERVICE)" != "all" || { echo "Pick one: make up SERVICE=finsight"; exit 1; }
	./scripts/local-up.sh $(SERVICE)

.PHONY: down
down: ## Stop the local compose stack
	docker compose -f docker/docker-compose.yml down --remove-orphans

.PHONY: sizes
sizes: ## Measure image sizes against the repo's own Dockerfiles
	./scripts/measure-image-size.sh $(SERVICE)

# --- Quality gates (§7) ---------------------------------------------------

.PHONY: lint
lint: ## Gate G2 — actionlint, shellcheck, hadolint, manifest validation
	actionlint
	shellcheck -x scripts/*.sh
	hadolint --failure-threshold warning docker/Dockerfile.api
	hadolint --failure-threshold warning docker/Dockerfile.frontend
	AUTOSCALING_MAX=2 ./scripts/validate-manifest.sh

.PHONY: tf-lint
tf-lint: ## Gate G3 — terraform fmt, validate, tflint
	$(TF) fmt -check -recursive -diff .
	$(TF) init -backend=false -input=false >/dev/null
	$(TF) validate -no-color
	terraform -chdir=terraform/bootstrap init -backend=false -input=false >/dev/null
	terraform -chdir=terraform/bootstrap validate -no-color
	cd terraform && tflint --recursive

.PHONY: policy
policy: ## Policy-as-code — checkov plus this project's own rules
	./scripts/policy-check.sh

.PHONY: cost
cost: ## Price the stack ENV's tfvars describes, before applying it
	./scripts/cost-estimate.sh $(ENV)

.PHONY: check
check: lint tf-lint ## Everything runnable without an AWS account

# --- Infrastructure -------------------------------------------------------

.PHONY: state
state: ## One-time: create the S3/DynamoDB state backend for ENV
	./scripts/bootstrap-state.sh $(ENV)

.PHONY: init
init: ## terraform init against ENV's state key
	@test -f terraform/$(BACKEND) || { echo "terraform/$(BACKEND) missing — run: make state ENV=$(ENV)"; exit 1; }
	$(TF) init -reconfigure -input=false -backend-config=$(BACKEND)

.PHONY: plan
plan: ## terraform plan for ENV
	@test -f terraform/$(TFVARS) || { echo "terraform/$(TFVARS) missing — copy $(TFVARS).example"; exit 1; }
	$(TF) plan -input=false -var-file=$(TFVARS)

.PHONY: apply
apply: ## terraform apply for ENV (prompts)
	@test -f terraform/$(TFVARS) || { echo "terraform/$(TFVARS) missing — copy $(TFVARS).example"; exit 1; }
	$(TF) apply -input=false -var-file=$(TFVARS)

.PHONY: budgets
budgets: ## Apply ONLY the budget alarms — do this before anything billable
	$(TF) apply -input=false -var-file=$(TFVARS) -target=module.budgets

.PHONY: destroy
destroy: ## terraform destroy for ENV, with a typed confirmation
	ENVIRONMENT=$(ENV) ./scripts/teardown.sh

.PHONY: outputs
outputs: ## Show the stack outputs, including the live URLs
	$(TF) output

# --- Deployment -----------------------------------------------------------

.PHONY: seed
seed: ## Build and push the first images, closing the bootstrap gap
	./scripts/seed-images.sh $(SERVICE)

.PHONY: databases
databases: ## One-time: create a database and least-privilege role per service
	./scripts/init-databases.sh

.PHONY: deploy
deploy: ## Deploy SERVICE at TAG (TAG=<git sha>)
	@test "$(SERVICE)" != "all" || { echo "Pick one: make deploy SERVICE=finsight TAG=a3f9c21b"; exit 1; }
	@test -n "$(TAG)" || { echo "TAG is required: make deploy SERVICE=$(SERVICE) TAG=<git sha>"; exit 1; }
	SERVICE_KEY=$(SERVICE) IMAGE_TAG=$(TAG) CLUSTER=autodeployx-$(ENV) AWS_REGION=$(REGION) ./scripts/deploy.sh

.PHONY: migrate
migrate: ## Run SERVICE's schema migration at TAG, before a deploy
	@test "$(SERVICE)" != "all" || { echo "Pick one: make migrate SERVICE=strategysphere TAG=a3f9c21b"; exit 1; }
	@test -n "$(TAG)" || { echo "TAG is required: make migrate SERVICE=$(SERVICE) TAG=<git sha>"; exit 1; }
	SERVICE_KEY=$(SERVICE) IMAGE_TAG=$(TAG) CLUSTER=autodeployx-$(ENV) AWS_REGION=$(REGION) ./scripts/migrate.sh

.PHONY: db
db: ## psql against the deployed database via ECS Exec (SERVICE=finsight [SQL="..."])
	@test "$(SERVICE)" != "all" || { echo "Pick one: make db SERVICE=finsight"; exit 1; }
	CLUSTER=autodeployx-$(ENV) AWS_REGION=$(REGION) ./scripts/db-console.sh $(SERVICE) $(SQL)

.PHONY: snapshot
snapshot: ## Take a manual RDS snapshot before a risky migration
	CLUSTER=autodeployx-$(ENV) AWS_REGION=$(REGION) ./scripts/db-snapshot.sh create

.PHONY: restore-drill
restore-drill: ## Prove the snapshot restores — to a NEW instance, not production
	CLUSTER=autodeployx-$(ENV) AWS_REGION=$(REGION) ./scripts/db-snapshot.sh restore-drill

.PHONY: smoke
smoke: ## Smoke-test a live URL (URL=http://... [SHA=<git sha>])
	@test -n "$(URL)" || { echo "URL is required: make smoke URL=http://..."; exit 1; }
	SERVICE_URL=$(URL) EXPECTED_SHA=$(SHA) ./scripts/smoke-test.sh

.PHONY: load
load: ## Run the k6 load test against URL
	@test -n "$(URL)" || { echo "URL is required: make load URL=http://..."; exit 1; }
	./scripts/load-test.sh $(URL)

.PHONY: metrics
metrics: ## Export the stack's CloudWatch metrics as NDJSON
	CLUSTER=autodeployx-$(ENV) AWS_REGION=$(REGION) ./scripts/export-metrics.sh
