# Enabling Tracing for Catalyst Apps

Catalyst supports sending tracing data to various backends through [Dapr configuration](https://docs.dapr.io/operations/observability/tracing/setup-tracing/). Tracing is configured per App ID after the chart is installed, via the Diagrid CLI — there are no Helm values to set.

## 1. Create a Dapr tracing configuration

The example below uses Jaeger running in the same Kubernetes cluster as the backend:

```bash
cat <<EOF > tracing-config.yaml
apiVersion: dapr.io/v1alpha1
kind: Configuration
metadata:
  name: tracing-config
spec:
  tracing:
    samplingRate: "1"
    stdout: true
    otel:
      endpointAddress: "jaeger.jaeger.svc.cluster.local:4317"
      isSecure: false
      protocol: grpc
EOF
```

## 2. Apply the configuration

```bash
diagrid apply -f tracing-config.yaml
```

## 3. Attach the configuration to an App ID

```bash
diagrid appid update <app-id> --app-config tracing-config
```

Tracing is now enabled for the selected App ID. Repeat step 3 for each App ID that should emit traces.
