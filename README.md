# Diagrid Helm Charts Repository

This repository contains official Helm charts published by Diagrid for deploying Diagrid products on Kubernetes.

> ⚠️ This repository is under active development. Documentation may be updated frequently.


## Available Charts

### Catalyst ⚡️

https://catalyst.diagrid.io

Diagrid Catalyst is a collection of API-based programming patterns for messaging, data, and workflow that is fully compliant with the Dapr open source project. It provides managed components and runtime that streamline cloud-native application development.

Please see the [Catalyst Chart README](./charts/catalyst/README.md).

## Docs

For more information about Diagrid Catalyst, including detailed usage instructions and examples, please visit:

- [Catalyst Documentation](https://docs.diagrid.io/catalyst)
- [Catalyst Support](https://docs.diagrid.io/catalyst/support)
- [Diagrid Website](https://www.diagrid.io/)
- [Diagrid Support](https://diagrid.io/support)

## Contributing

We welcome contributions to our Helm charts. Please feel free to submit issues or pull requests.

### Development

If you're developing or testing the Catalyst Helm chart locally, you'll need to manage dependencies:

#### Prerequisites

- [Helm](https://helm.sh/) v3.12.0+
- [helm-unittest](https://github.com/helm-unittest/helm-unittest) plugin for testing

#### Chart Dependencies

The `Chart.lock` file in the repository tracks exact dependency versions. This ensures consistent builds across all environments. When adding or updating dependencies:

1. Update `Chart.yaml` with the new dependency
2. Run `helm dependency update` to generate a new `Chart.lock`
3. Commit both `Chart.yaml` and `Chart.lock` to version control

To install dependencies locally, run:

```bash
# Install Helm dependencies
make helm-prereqs
```

#### Testing

```bash
# Run unit tests
make helm-test

# Run linting
make helm-lint

# Template the chart to verify output
make helm-template

# Run all validation
make helm-validate

# Run integration tests (requires Docker)
make helm-test-integration
```

## License

Copyright © Diagrid, Inc.
