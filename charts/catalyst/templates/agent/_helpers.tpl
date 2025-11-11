{{/*
Agent Helpers
*/}}
{{/*
Create the name of the agent resource
*/}}
{{- define "agent.name" -}}
  {{- include "common.name" (dict 
      "nameOverride" .Values.agent.nameOverride 
      "defaultName" "agent" 
      "Chart.Name" .Chart.Name
      "global" .Values.global
  ) }}
{{- end }}


{{/*
Create a fully qualified app name for agent
*/}}
{{- define "agent.fullname" -}}
  {{- include "common.fullname" (dict 
      "fullnameOverride" .Values.agent.fullnameOverride 
      "Release" .Release 
      "name" (include "agent.name" .) 
      "global" .Values.global
  ) }}
{{- end }}


{{/*
Common labels for agent
*/}}
{{- define "agent.labels" -}}
{{- include "common.labels" . }}
app.kubernetes.io/component: agent
{{- end }}

{{/*
Selector labels
*/}}
{{- define "agent.selectorLabels" -}}
{{- include "common.selectorLabels" . }}
app.kubernetes.io/component: agent
{{- end }}

{{/*
Create the name of the service account to use for agent
*/}}
{{- define "agent.serviceAccountName" -}}
  {{- if .Values.agent.serviceAccount.name }}
    {{- .Values.agent.serviceAccount.name | trunc 63 | trimSuffix "-" }}
  {{- else }}
    {{- printf "%s-sa" (include "agent.fullname" .) | trunc 63 | trimSuffix "-" }}
  {{- end }}
{{- end }}

{{/*
Validate values
*/}}
{{- define "agent.validateValues" -}}
    {{- if not .Values.join_token -}}
        {{- fail "A valid join_token value is required to deploy this chart!" -}}
    {{- end -}}
{{- end -}}

{{/*
Get the name of the charts secret to use
*/}}
{{- define "agent.chartsSecretName" -}}
{{- if .Values.global.charts.existingSecret }}
  {{- .Values.global.charts.existingSecret }}
{{- else }}
  {{- .Values.global.charts.secretName | default (printf "%s-charts" .Release.Name) }}
{{- end }}
{{- end }}