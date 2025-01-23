{{/*
Common Helpers
*/}}

{{/*
Create a default name for the chart
Priority:
1. Resource-specific nameOverride
2. Global nameOverride
3. Default Name (e.g., "agent")
4. Chart name
*/}}
{{- define "common.name" -}}
{{- if and .nameOverride (ne .nameOverride "") }}
  {{- .nameOverride | trunc 63 | trimSuffix "-" }}
{{- else if and (hasKey . "global") (hasKey .global "nameOverride") (ne .global.nameOverride "") }}
  {{- .global.nameOverride | trunc 63 | trimSuffix "-" }}
{{- else if and .defaultName (ne .defaultName "") }}
  {{- .defaultName | trunc 63 | trimSuffix "-" }}
{{- else }}
  {{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}


{{/*
Create a default fully qualified app name
Priority:
1. Resource-specific fullnameOverride
2. Global fullnameOverride
3. Release name + resource name, with special handling if release name contains resource name
*/}}
{{- define "common.fullname" -}}
{{- if and .fullnameOverride (ne .fullnameOverride "") }}
  {{- .fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else if and (hasKey . "global") (hasKey .global "fullnameOverride") (ne .global.fullnameOverride "") }}
  {{- .global.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
  {{- $name := .name }}
  {{- if and (hasKey . "Release") (hasKey .Release "Name") }}
    {{- if contains $name .Release.Name }}
      {{- .Release.Name | trunc 63 | trimSuffix "-" }}
    {{- else }}
      {{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
    {{- end }}
  {{- else }}
    {{- $name }}
  {{- end }}
{{- end }}
{{- end }}


{{/*
Create chart name and version as used by the chart label
*/}}
{{- define "common.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common Labels
*/}}
{{- define "common.labels" -}}
helm.sh/chart: {{ include "common.chart" . }}
{{ include "common.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector Labels
*/}}
{{- define "common.selectorLabels" -}}
app.kubernetes.io/name: {{ include "common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}





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

