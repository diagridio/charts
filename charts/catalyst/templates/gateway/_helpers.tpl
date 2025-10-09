{{/*
Common labels for gateway controlplane
*/}}
{{- define "gateway.controlplane.labels" -}}
{{- include "common.labels" . }}
app.kubernetes.io/component: gateway-controlplane
{{- end }}

{{/*
Common labels for gateway envoy
*/}}
{{- define "gateway.envoy.labels" -}}
{{- include "common.labels" . }}
app.kubernetes.io/component: gateway-envoy
{{- end }}

{{/*
Selector Labels
*/}}
{{- define "common.selectorLabels" -}}
app.kubernetes.io/name: {{ include "common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "gateway.controlplane.selectorLabels" -}}
{{- include "common.selectorLabels" . }}
app.kubernetes.io/component: gateway-controlplane
{{- end }}

{{/*
Selector labels
*/}}
{{- define "gateway.envoy.selectorLabels" -}}
{{- include "common.selectorLabels" . }}
app.kubernetes.io/component: gateway-envoy
{{- end }}



{{/*
Create the name of the service account to use for the gateway controlplane.
*/}}
{{- define "gateway.controlplane.serviceAccountName" -}}
  {{- if .Values.gateway.controlplane.serviceAccount.name }}
    {{- .Values.gateway.controlplane.serviceAccount.name | trunc 63 | trimSuffix "-" }}
  {{- else }}
    {{- printf "%s-sa" (include "gateway.controlplane.fullname" .) | trunc 63 | trimSuffix "-" }}
  {{- end }}
{{- end }}

{{/*
Create the name of the service account to use for the gateway controlplane.
*/}}
{{- define "gateway.envoy.serviceAccountName" -}}
  {{- if .Values.gateway.envoy.serviceAccount.name }}
    {{- .Values.gateway.envoy.serviceAccount.name | trunc 63 | trimSuffix "-" }}
  {{- else }}
    {{- printf "%s-sa" (include "gateway.envoy.fullname" .) | trunc 63 | trimSuffix "-" }}
  {{- end }}
{{- end }}

{{/*
Get the name of the TLS secret to use
*/}}
{{- define "gateway.tlsSecretName" -}}
{{- if .Values.gateway.tls.existingSecret }}
  {{- .Values.gateway.tls.existingSecret }}
{{- else }}
  {{- .Values.gateway.tls.secretName | default (printf "%s-gateway-tls" .Release.Name) }}
{{- end }}
{{- end }}
