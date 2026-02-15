{{/*
Trust Anchors Helpers
*/}}

{{/*
Create the name of the trust anchors resource
*/}}
{{- define "trustanchors.name" -}}
  {{- include "common.name" (dict
      "nameOverride" .Values.trustAnchors.nameOverride
      "defaultName" "trust-anchors"
      "Chart.Name" .Chart.Name
      "global" .Values.global
  ) }}
{{- end }}

{{/*
Create a fully qualified app name for trust anchors
*/}}
{{- define "trustanchors.fullname" -}}
  {{- include "common.fullname" (dict
      "fullnameOverride" .Values.trustAnchors.fullnameOverride
      "Release" .Release
      "name" (include "trustanchors.name" .)
      "global" .Values.global
  ) }}
{{- end }}

{{/*
Common labels for trust anchors
*/}}
{{- define "trustanchors.labels" -}}
{{- include "common.labels" . }}
app.kubernetes.io/component: agent
app.kubernetes.io/subcomponent: trust-anchor
{{- end }}

{{/*
Selector labels for trust anchors
*/}}
{{- define "trustanchors.selectorLabels" -}}
{{- include "common.selectorLabels" . }}
app.kubernetes.io/component: agent
app.kubernetes.io/subcomponent: trust-anchor
{{- end }}

{{/*
Create the name of the service account to use for trust anchors
Uses the agent service account since it's deployed in the agent namespace
*/}}
{{- define "trustanchors.serviceAccountName" -}}
  {{- include "agent.serviceAccountName" . }}
{{- end }}
