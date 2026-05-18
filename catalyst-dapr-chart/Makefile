# Makefile — catalyst-dapr-chart publish tooling
# Self-contained; does not inherit from parent charts/Makefile.

.PHONY: help test lint install-test-deps

help: ## List available targets.
	@echo "catalyst-dapr-chart Makefile"
	@echo "----------------------------"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

install-test-deps: ## Install Python test dependencies.
	python3 -m pip install -r tests/requirements.txt

test: ## Run pytest suite.
	python3 -m pytest tests/ -v

lint: ## Run ruff linter on publish.py and tests/.
	python3 -m ruff check publish.py tests/ || python3 -m flake8 publish.py tests/
