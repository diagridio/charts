-include .env

VERSION ?= $(if $(CHART_VERSION),$(CHART_VERSION),0.0.0-edge)
REPO ?= $(GCP_PROJECT_ID)/$(GCP_DOCKER_REPOSITORY)
REGISTRY ?= $(GCP_CONTAINER_REGISTRY_HOST)

.PHONY: helm-lint
helm-lint:
	helm lint $(TARGET_PATH)

.PHONY: helm-dependency-update
helm-depedency-update:
	helm dependency update ./

.PHONY: helm-template
helm-template:	
	helm template my-release ./ \
		--namespace test \
		--debug \
		--set global.image.imagePullSecrets[0].name=cra-pull-secret \
		--set agent.config.host.join_token="fake_token" \
		--set agent.config.host.control_plane_url="fake_url" \
		--set agent.config.host.control_plane_http_url="fake_http_url" > rendered.yaml

.PHONY: helm-package
helm-package:
	helm package --version ${VERSION} --destination ./dist

.PHONY: helm-upgrade
helm-upgrade:
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
	helm push ./dist/diagrid-catalyst-$(VERSION).tgz oci://$(REGISTRY)/$(REPO)