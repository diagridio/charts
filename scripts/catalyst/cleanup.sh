helm uninstall catalyst-otel-logs-collector -n cra-agent || true
helm uninstall catalyst-otel-metrics-collector -n cra-agent || true
helm uninstall dapr -n root-dapr-system || true
helm uninstall dapr-ext -n root-dapr-system || true
kubectl delete pvc -n root-dapr-system --all || true
kubectl delete configmap region-details -n cra-agent || true
kubectl delete configmap ca-certificates-bundle -n cra-agent || true
kubectl delete namespace root-dapr-system || true
kubectl delete namespace cra-agent || true