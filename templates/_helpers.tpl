{{/*
Agent Helpers
*/}}
{{/*
Expand the name of the chart.
*/}}
{{- define "agent.name" -}}
{{- default "agent" .Values.agent.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}


{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "agent.fullname" -}}
{{- if .Values.agent.fullnameOverride }}
{{- .Values.agent.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{-     $name := default (include "agent.name" .) .Values.agent.nameOverride }}
{{-     if contains $name .Release.Name }}
{{-         .Release.Name | trunc 63 | trimSuffix "-" }}
{{-     else }}
{{-         printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{-     end }}
{{- end }}
{{- end }}


{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "agent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "agent.labels" -}}
helm.sh/chart: {{ include "agent.chart" . }}
{{ include "agent.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: agent
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "agent.serviceAccountName" -}}
{{- default (include "agent.fullname" .) .Values.agent.serviceAccount.name }}
{{- end }}

{{/*
Convert A suffixed (kMGTP or kiMiGiTiPi) memory values to bytes
*/}}
{{- define "catalyst.convertToBinaryPrefixFromK8S" -}}
{{-     $suffixLength := 0 }}
{{-     if kindIs "string" .memory }}
{{-         if regexMatch "^[0-9]+[kMGTP]$" .memory }}{{- $suffixLength = 1 }}{{- end }}
{{-         if regexMatch "^[0-9]+[KMGTP]i$" .memory }}{{- $suffixLength = 2 }}{{- end }}
{{-     end }}
{{-     if $suffixLength }}
{{-         $kilo := 1000 }}
{{-         $kibi := 1024 }}
{{-         $mega := 1000000 }}
{{-         $mebi := 1048576 }}
{{-         $giga := 1000000000 }}
{{-         $gibi := 1073741824 }}
{{-         $tebi := 1099511627776 }}
{{-         $pebi := 1125899906842624 }}
{{-         $suffixIdx := sub (len .memory ) $suffixLength | int }}
{{-         $suffixOriginal := substr $suffixIdx -1 .memory }}
{{-         $value := substr 0 $suffixIdx .memory | int64 }}
{{-         if lt $value 11 }}{{- /* special change to avoid bad calculations like setting to 0 */}}
{{-             if eq $suffixLength 1 }}
{{-                 $value = mul $value $kilo }}
{{-                 $suffixOriginal = index (dict "k" "" "M" "k" "G" "M" "T" "G" "P" "T") $suffixOriginal }}
{{-             else  }}
{{-                 $value = mul $value $kibi }}
{{-                 $suffixOriginal = index (dict "Ki" "" "Mi" "Ki" "Gi" "Mi" "Ti" "Gi" "Pi" "Ti") $suffixOriginal }}
{{-             end }}
{{-         end }}
{{-         $suffix := printf "%sB" $suffixOriginal }}
{{-         if eq $suffixOriginal "k" }}{{- $value = div (mul $value $kilo) $kibi }}{{- $suffix = "KiB" }}{{- end }}
{{-         if eq $suffixOriginal "M" }}{{- $value = div (mul $value $mega) $mebi }}{{- $suffix = "MiB" }}{{- end }}
{{-         if eq $suffixOriginal "G" }}{{- $value = div (mul $value $giga) $gibi }}{{- $suffix = "GiB" }}{{- end }}
{{-         if eq $suffixOriginal "T" }}{{- $value = div (mul $value $kilo $giga) $tebi  }}{{- $suffix = "TiB" }}{{- end }}
{{-         if eq $suffixOriginal "P" }}{{- $value = div (mul $value $mega $giga) $tebi }}{{- $suffix = "TiB" }}{{- end }}
{{-         if eq $suffixOriginal "Pi" }}{{- $value = div (mul $value $pebi) $tebi }}{{- $suffix = "TiB" }}{{- end }}
{{-         printf "%d%s" (div ($value | mul .percentage) 100) $suffix }}
{{-     else }}
{{-         if kindIs "string" .memory }}
{{-             div (atoi .memory | mul .percentage) 100 }}
{{-         else }}
{{-             div (.memory | int64 | mul .percentage) 100 }}
{{-         end }}
{{-     end }}
{{- end }}

{{/*
Calculate GoLang GOMEMLIMIT From .Values.Resources.Limit.Memory provided as argument
*/}}
{{- define "catalyst.GetGoLangGOMEMLIMITFromResourceLimits" -}}
{{-     if .golimit.override }}
{{-         .golimit.override }}
{{-     else }}
{{-         $golangMemPerc := default .golimit.percent 90 | int64 }}
{{-         with .limits }}
{{-             if .memory }}
{{-                 include "catalyst.convertToBinaryPrefixFromK8S" (dict "memory" .memory "percentage" $golangMemPerc)}}
{{-             end }}
{{-         end }}
{{-     end }}
{{- end }}

{{/*
API Token Error Helpers
*/}}
{{- define "api-token-error.name" -}}
{{- default "api-token-error" .Values.apiTokenError.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "api-token-error.fullname" -}}
{{- if .Values.apiTokenError.fullnameOverride }}
  {{- .Values.apiTokenError.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
  {{- $name := default (include "api-token-error.name" .) .Values.apiTokenError.nameOverride }}
  {{- if contains $name .Release.Name }}
    {{- .Release.Name | trunc 63 | trimSuffix "-" }}
  {{- else }}
    {{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
  {{- end }}
{{- end }}
{{- end }}

{{- define "api-token-error.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "api-token-error.labels" -}}
helm.sh/chart: {{ include "api-token-error.chart" . }}
{{ include "api-token-error.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "api-token-error.selectorLabels" -}}
app.kubernetes.io/name: {{ include "api-token-error.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: api-token-error
{{- end }}


