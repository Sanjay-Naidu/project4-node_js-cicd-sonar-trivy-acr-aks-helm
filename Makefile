# Developer entry points. Everything here runs the SAME commands CI runs, so
# "works on my machine" and "passes the pipeline" cannot diverge.

SHELL := /bin/bash
.DEFAULT_GOAL := help

APP_DIR   := app
CHART     := deploy/helm/orders-api
TF_DIR    := infra/terraform
ENV       ?= dev
IMAGE     ?= orders-api
TAG       ?= $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo dev)
NAMESPACE ?= orders-api

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

.PHONY: install
install: ## Install dependencies and create the lockfile
	cd $(APP_DIR) && npm install

.PHONY: dev
dev: ## Run with auto-reload
	cd $(APP_DIR) && npm run dev

.PHONY: lint
lint: ## ESLint
	cd $(APP_DIR) && npm run lint

.PHONY: test
test: ## Jest
	cd $(APP_DIR) && npm test

.PHONY: coverage
coverage: ## Jest with coverage (produces the lcov Sonar consumes)
	cd $(APP_DIR) && npm run test:coverage

.PHONY: audit
audit: ## npm audit at CI severity
	cd $(APP_DIR) && npm run audit:ci

.PHONY: verify
verify: ## Full Maven build - exactly what CI runs
	cd $(APP_DIR) && mvn --batch-mode verify

.PHONY: sonar
sonar: ## Maven build + SonarQube analysis (needs SONAR_TOKEN)
	cd $(APP_DIR) && mvn --batch-mode verify sonar:sonar \
		-Dsonar.host.url=$${SONAR_HOST_URL:-https://sonarcloud.io} \
		-Dsonar.organization=$${SONAR_ORGANIZATION} \
		-Dsonar.projectKey=$${SONAR_PROJECT_KEY:-orders-api}

# ---------------------------------------------------------------------------
# Container
# ---------------------------------------------------------------------------

.PHONY: docker-build
docker-build: ## Build the image
	docker build -t $(IMAGE):$(TAG) \
		--build-arg APP_VERSION=$(TAG) \
		--build-arg GIT_SHA=$(TAG) \
		--build-arg BUILD_DATE=$$(date -u +'%Y-%m-%dT%H:%M:%SZ') \
		$(APP_DIR)

.PHONY: docker-run
docker-run: docker-build ## Run the image locally on :3000
	docker run --rm -p 3000:3000 \
		-e LOG_LEVEL=debug \
		--read-only --tmpfs /tmp \
		--cap-drop ALL \
		$(IMAGE):$(TAG)

.PHONY: docker-scan
docker-scan: docker-build ## Trivy image scan at the CI gate severity
	trivy image --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 $(IMAGE):$(TAG)

# ---------------------------------------------------------------------------
# Helm
# ---------------------------------------------------------------------------

.PHONY: helm-lint
helm-lint: ## Lint both value overlays
	helm lint $(CHART) --values $(CHART)/values-dev.yaml --set image.tag=$(TAG) --strict
	helm lint $(CHART) --values $(CHART)/values-prod.yaml --set image.tag=$(TAG) --strict

.PHONY: helm-template
helm-template: ## Render manifests for the current ENV
	helm template orders-api $(CHART) \
		--namespace $(NAMESPACE) \
		--values $(CHART)/values-$(ENV).yaml \
		--set image.tag=$(TAG)

.PHONY: helm-diff
helm-diff: ## Show what an upgrade would change (needs helm-diff plugin)
	helm diff upgrade orders-api $(CHART) \
		--namespace $(NAMESPACE) \
		--values $(CHART)/values-$(ENV).yaml \
		--set image.tag=$(TAG)

# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------

.PHONY: tf-init
tf-init: ## terraform init (requires infra/terraform/backend.hcl)
	cd $(TF_DIR) && terraform init -backend-config=backend.hcl

.PHONY: tf-fmt
tf-fmt: ## Format HCL
	cd $(TF_DIR) && terraform fmt -recursive

.PHONY: tf-validate
tf-validate: ## Validate without a backend
	cd $(TF_DIR) && terraform init -backend=false && terraform validate

.PHONY: tf-plan
tf-plan: ## Plan for ENV
	cd $(TF_DIR) && terraform plan -var-file=environments/$(ENV).tfvars

.PHONY: tf-apply
tf-apply: ## Apply for ENV
	cd $(TF_DIR) && terraform apply -var-file=environments/$(ENV).tfvars

.PHONY: tf-destroy
tf-destroy: ## Destroy ENV - stops the billing
	cd $(TF_DIR) && terraform destroy -var-file=environments/$(ENV).tfvars

# ---------------------------------------------------------------------------
# Cluster operations
# ---------------------------------------------------------------------------

.PHONY: creds
creds: ## Fetch kubeconfig for the cluster
	az aks get-credentials -g $(AZURE_RESOURCE_GROUP) -n $(AKS_CLUSTER_NAME) --overwrite-existing
	kubelogin convert-kubeconfig -l azurecli

.PHONY: status
status: ## Show what is running
	kubectl -n $(NAMESPACE) get deploy,rs,pods,svc,ingress,hpa,pdb -o wide

.PHONY: logs
logs: ## Tail application logs
	kubectl -n $(NAMESPACE) logs -l app.kubernetes.io/name=orders-api -f --tail=100 --prefix

.PHONY: rollback
rollback: ## Roll back to the previous Helm revision
	helm -n $(NAMESPACE) rollback orders-api

.PHONY: zero-downtime-check
zero-downtime-check: ## Hammer the endpoint during a rollout to prove no requests drop
	@./scripts/zero-downtime-check.sh

# ---------------------------------------------------------------------------

.PHONY: ci-local
ci-local: lint test helm-lint tf-validate ## Run every gate that does not need Azure
	@echo "All local gates passed."
