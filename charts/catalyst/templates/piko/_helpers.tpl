{{/*
Selector labels, matching the StatefulSet's matchLabels.
*/}}
{{- define "piko.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.piko.pikoName }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
piko.jwksURL is where piko fetches the keys that sign tunnel tokens: the
region's Sentry OIDC endpoint. piko.publicToken.url left empty or at its old
default, root-dapr-system's Sentry, follows global.namespaces.dapr; any other
value is used as given. That old default must match values.yaml and
agent.RootDaprNamespace (services/catalyst/pkg/agent/defaults.go).
*/}}
{{- define "piko.jwksURL" -}}
{{- $url := .Values.piko.publicToken.url -}}
{{- if or (not $url) (eq $url "http://dapr-sentry.root-dapr-system.svc.cluster.local:9080/jwks.json") -}}
{{- printf "http://dapr-sentry.%s.svc.cluster.local:9080/jwks.json" (include "catalyst.daprNamespace" .) -}}
{{- else -}}
{{- $url -}}
{{- end -}}
{{- end -}}
