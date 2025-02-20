{{/*
Management Helpers
*/}}
{{/*
Create the name of the management resource
*/}}
{{- define "management.name" -}}
  {{- include "common.name" (dict 
      "nameOverride" .Values.management.nameOverride 
      "defaultName" "management" 
      "Chart.Name" .Chart.Name
      "global" .Values.global
  ) }}
{{- end }}


{{/*
Create a fully qualified app name for management
*/}}
{{- define "management.fullname" -}}
  {{- include "common.fullname" (dict 
      "fullnameOverride" .Values.management.fullnameOverride 
      "Release" .Release 
      "name" (include "management.name" .) 
      "global" .Values.global
  ) }}
{{- end }}


{{/*
Common labels for management
*/}}
{{- define "management.labels" -}}
{{- include "common.labels" . }}
app.kubernetes.io/component: management
{{- end }}

{{/*
Selector labels
*/}}
{{- define "management.selectorLabels" -}}
{{- include "common.selectorLabels" . }}
app.kubernetes.io/component: management
{{- end }}

{{/*
Create the name of the service account to use for management
*/}}
{{- define "management.serviceAccountName" -}}
  {{- if .Values.management.serviceAccount.name }}
    {{- .Values.management.serviceAccount.name | trunc 63 | trimSuffix "-" }}
  {{- else }}
    {{- printf "%s-sa" (include "management.fullname" .) | trunc 63 | trimSuffix "-" }}
  {{- end }}
{{- end }}

{{/*
Calculate GoLang GOMEMLIMIT From .Values.Resources.Limit.Memory
*/}}
{{- define "cra.GetGoLangGOMEMLIMITFromResourceLimits" -}}
{{-     if .Values.management.goSoftLimit.override }}
{{-         .Values.management.goSoftLimit.override }}
{{-     else }}
{{-         $golangMemPerc := default .Values.management.goSoftLimit.percent 90 | int64 }}
{{-         with .Values.management.resources.limits }}
{{-             if .memory }}
{{-                 include "cra.convertToBinaryPrefixFromK8S" (dict "memory" .memory "percentage" $golangMemPerc)}}
{{-             end }}
{{-         end }}
{{-     end }}
{{- end }}
