################################################################################
# Target: Help                                                                 #
################################################################################
help: ## Show this help message.
	@echo "\nDiagrd Helm Chart Makefile"
	@echo "--------------------------"
	@echo "The following parameters are available:"
	@echo ""
	@echo "CHART_DIR:  The directory of the helm chart (default: ./charts/catalyst)"
	@echo "CHART_NAME: The name of the helm chart (default: catalyst)"
	@echo "VERSION:    The version of the helm chart (default: 0.0.0-<git sha>)"
	@echo "REGISTRY:   The OCI registry to push the helm chart to"
	@echo "REPO:       The repository to push the helm chart to"
	@echo ""
	@echo "The following targets are available:"
	@awk 'BEGIN {FS = ":.*##"; printf "\n  make \033[36m\033[0m\n"} \
		/^[a-zA-Z0-9\-_]+:.*?##/ { if ($$1 != "help") printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
		/##\@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.DEFAULT_GOAL := help

-include .env

VERSION ?= 0.0.0-edge
CHART_DIR ?= ./charts/catalyst
CHART_NAME ?= catalyst

.PHONY: helm-lint
helm-lint: helm-prereqs ## Lint the helm chart
	cd $(CHART_DIR) && \
	helm lint $(TARGET_PATH) \
	--set join_token="fake_token"

.PHONY: helm-test
helm-test: ## Run helm unit tests
	@command -v helm >/dev/null 2>&1 || { echo "helm is not installed. Please install helm first."; exit 1; }
	@helm plugin list | grep -q unittest || { echo "Installing helm-unittest plugin..."; helm plugin install https://github.com/helm-unittest/helm-unittest; }
	cd $(CHART_DIR) && \
	helm unittest --color .

.PHONY: helm-test-verbose
helm-test-verbose: ## Run helm unit tests with verbose output
	@command -v helm >/dev/null 2>&1 || { echo "helm is not installed. Please install helm first."; exit 1; }
	@helm plugin list | grep -q unittest || { echo "Installing helm-unittest plugin..."; helm plugin install https://github.com/helm-unittest/helm-unittest; }
	cd $(CHART_DIR) && \
	helm unittest --color -d .

.PHONY: helm-add-repos
helm-add-repos: ## Add helm repos
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ > /dev/null 2>&1 || true
	helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts > /dev/null 2>&1 || true
	helm repo update > /dev/null 2>&1 || true

.PHONY: helm-dependency-build
helm-dependency-build: ## Build helm dependencies
	cd $(CHART_DIR) && \
	helm dependency build

.PHONY: helm-dependency-update
helm-dependency-update: ## Update helm dependencies
	cd $(CHART_DIR) && \
	helm dependency update ./

.PHONY: helm-prereqs
helm-prereqs: helm-add-repos helm-dependency-build helm-dependency-update ## Install helm dependencies

.PHONY: helm-template
helm-template: helm-prereqs ## Render helm chart
	cd $(CHART_DIR) && \
	helm template my-release ./ \
		--namespace test \
		--debug \
		--set join_token="fake_token" > rendered.yaml

.PHONY: helm-validate
helm-validate: helm-lint helm-test ## Run lint and tests on the helm chart

.PHONY: helm-test-integration
helm-test-integration: ## Run integration tests (requires Docker)
	@command -v docker >/dev/null 2>&1 || { echo "Docker is not installed or not running. Please install Docker first."; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "Docker daemon is not running. Please start Docker."; exit 1; }
	cd tests/integration && \
	go test -v -timeout 10m .

.PHONE: helm-clean
helm-clean: ## Clean up generated files
	rm -rf $(CHART_DIR)/dist

.PHONY: helm-package
helm-package: helm-clean ## Package helm chart
	cd $(CHART_DIR) && \
	helm package . --version $(VERSION) --destination ./dist

.PHONY: helm-push
helm-push: helm-package ## Push the Helm chart to the OCI registry
	cd $(CHART_DIR) && \
	helm push ./dist/$(CHART_NAME)-$(VERSION).tgz oci://$(REGISTRY)/$(REPO)

.PHONY: helm-install
helm-install: helm-upgrade ## Install the Helm chart

.PHONY: helm-upgrade
helm-upgrade: helm-prereqs ## Upgrade the Helm chart
	cd $(CHART_DIR) && \
	helm upgrade --install my-release ./ \
		--namespace test \
		--create-namespace \
		--dry-run \
		--skip-crds \
		--debug \
		--set join_token="fake_token" \
		--set agent.config.host.control_plane_url="fake_url" \
		--set agent.config.host.control_plane_http_url="fake_http_url"

# NOTICE: we need to update this function every time we use a new diagrid image
update-catalyst-tags:
	@if [ -z "$(IMAGES_TAG)" ]; then \
		echo "IMAGES_TAG is not set"; \
		exit 1; \
	fi
	yq -i '.agent.config.sidecar.image_tag="$(IMAGES_TAG)"' $(CHART_DIR)/values.yaml
	yq -i '.agent.config.otel.image_tag="$(IMAGES_TAG)"' $(CHART_DIR)/values.yaml
	yq -i '.agent.image.tag="$(IMAGES_TAG)"' $(CHART_DIR)/values.yaml
	yq -i '.gateway.identityInjector.image.tag="$(IMAGES_TAG)"' $(CHART_DIR)/values.yaml
	yq -i '.gateway.controlplane.image.tag="$(IMAGES_TAG)"' $(CHART_DIR)/values.yaml
	yq -i '.management.image.tag="$(IMAGES_TAG)"' $(CHART_DIR)/values.yaml

update-catalyst-chart-version:
	yq -i '.version="$(VERSION)"' ./charts/catalyst/Chart.yaml

update-catalyst-registry:
	@if [ -z "$(REGISTRY)" ]; then \
		echo "REGISTRY is not set"; \
		exit 1; \
	fi
	yq -i '.agent.config.sidecar.image_registry="$(REGISTRY)"' $(CHART_DIR)/values.yaml
	yq -i '.agent.image.registry="$(REGISTRY)"' $(CHART_DIR)/values.yaml
	yq -i '.gateway.identityInjector.image.registry="$(REGISTRY)"' $(CHART_DIR)/values.yaml
	yq -i '.gateway.controlplane.image.registry="$(REGISTRY)"' $(CHART_DIR)/values.yaml
	yq -i '.management.image.registry="$(REGISTRY)"' $(CHART_DIR)/values.yaml
	yq -i '.agent.config.internal_dapr.container_registry="$(REGISTRY)"' $(CHART_DIR)/values.yaml
