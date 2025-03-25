-include .env

VERSION ?= "0.0.0-$(shell git rev-parse --short HEAD)"
CHART_DIR ?= ./charts/catalyst
CHART_NAME ?= catalyst

.PHONY: helm-lint
helm-lint: helm-prereqs
	cd $(CHART_DIR) && \
	helm lint $(TARGET_PATH) \
	--set agent.config.host.join_token="fake_token"

.PHONY: helm-add-repos
helm-add-repos:
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ > /dev/null 2>&1 || true

.PHONY: helm-dependency-build
helm-dependency-build:
	cd $(CHART_DIR) && \
	helm dependency build

.PHONY: helm-dependency-update
helm-depedency-update:
	cd $(CHART_DIR) && \
	helm dependency update ./

.PHONY: helm-prereqs
helm-prereqs: helm-add-repos helm-dependency-build helm-depedency-update

.PHONY: helm-template
helm-template: helm-prereqs
	cd $(CHART_DIR) && \
	helm template my-release ./ \
		--namespace test \
		--debug \
		--set agent.config.host.join_token="fake_token" > rendered.yaml

.PHONY: helm-package
helm-package: 
	cd $(CHART_DIR) && \
	helm package . --version $(VERSION) --destination ./dist

.PHONY: helm-install
helm-install: helm-upgrade

.PHONY: helm-upgrade
helm-upgrade: helm-prereqs
	cd $(CHART_DIR) && \
	helm upgrade --install my-release ./ \
		--namespace test \
		--create-namespace \
		--dry-run \
		--skip-crds \
		--debug \
		--set agent.config.host.join_token="fake_token" \
		--set agent.config.host.control_plane_url="fake_url" \
		--set agent.config.host.control_plane_http_url="fake_http_url"

.PHONY: helm-push
helm-push:
	cd $(CHART_DIR) && \
	helm push ./dist/$(CHART_NAME)-$(VERSION).tgz oci://$(REGISTRY)/$(REPO)