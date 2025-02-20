-include .env

VERSION ?= "0.0.0-$(shell git rev-parse --short HEAD)"
CHART_DIR ?= ./charts/catalyst

.PHONY: helm-lint
helm-lint: helm-dependency-build helm-depedency-update
	cd $(CHART_DIR) && \
	helm lint $(TARGET_PATH) \
	--set agent.config.host.join_token="fake_token"

.PHONY: helm-dependency-build
helm-dependency-build:
	cd $(CHART_DIR) && \
	helm dependency build

.PHONY: helm-dependency-update
helm-depedency-update:
	cd $(CHART_DIR) && \
	helm dependency update ./

.PHONY: helm-template
helm-template: helm-dependency-build helm-depedency-update
	cd $(CHART_DIR) && \
	helm template my-release ./ \
		--namespace test \
		--debug \
		--set global.image.imagePullSecrets[0].name=cra-pull-secret \
		--set agent.config.host.join_token="fake_token" \
		--set agent.config.host.control_plane_url="fake_url" \
		--set agent.config.host.control_plane_http_url="fake_http_url" > rendered.yaml

.PHONY: helm-package
helm-package:
	cd $(CHART_DIR) && \
	helm package --version ${VERSION} --destination ./dist

.PHONY: helm-upgrade
helm-upgrade:
	cd $(CHART_DIR) && \
	helm upgrade --install my-release ./ \
		--namespace test \
		--create-namespace \
		--dry-run \
		--skip-crds \
		--debug \
		--set global.image.imagePullSecrets[0].name=cra-pull-secret \
		--set agent.config.host.join_token="fake_token" \
		--set agent.config.host.control_plane_url="fake_url" \
		--set agent.config.host.control_plane_http_url="fake_http_url"

.PHONY: helm-push
helm-push:
	cd $(CHART_DIR) && \
	helm push ./dist/diagrid-catalyst-$(VERSION).tgz oci://$(REGISTRY)/$(REPO)