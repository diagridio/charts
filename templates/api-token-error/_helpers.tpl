{{/*
API Token Error Helpers
*/}}

{{/*
Create the name of the api-token-error resource
*/}}
{{- define "api-token-error.name" -}}
  {{- include "common.name" (dict 
      "nameOverride" .Values.apiTokenError.nameOverride 
      "defaultName" "api-token-error" 
      "Chart.Name" .Chart.Name
      "global" .Values.global
  ) }}
{{- end }}


{{/*
Create a fully qualified app name for api-token-error
*/}}
{{- define "api-token-error.fullname" -}}
  {{- include "common.fullname" (dict 
      "fullnameOverride" .Values.apiTokenError.fullnameOverride 
      "Release" .Release 
      "name" (include "api-token-error.name" .) 
      "global" .Values.global
  ) }}
{{- end }}

{{- define "api-token-error.labels" -}}
{{- include "common.labels" . }}
app.kubernetes.io/component: api-token-error
{{- end }}

{{- define "api-token-error.selectorLabels" -}}
{{- include "common.selectorLabels" . }}
app.kubernetes.io/component: api-token-error
{{- end }}
