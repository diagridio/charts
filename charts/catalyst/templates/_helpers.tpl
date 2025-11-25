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
Merge two maps, with the second map overriding the first
*/}}
{{- define "merge.maps" -}}
  {{- $base := .base | default dict }}
  {{- $overrides := .overrides | default dict }}
  {{- $merged := merge $base $overrides }}
  {{- $merged | toYaml | nindent 2 }}
{{- end }}

{{/*
Inject additional YAML into a resource
*/}}
{{- define "inject.patch" -}}
  {{- if .patch }}
    {{- if kindIs "string" .patch }}
      {{- tpl .patch . | nindent .indent }}
    {{- else if kindIs "slice" .patch }}
      {{- toYaml .patch | nindent .indent }}
    {{- else }}
      {{- fail (printf "inject.patch: unsupported type for patch: %s" (typeOf .patch)) }}
    {{- end }}
  {{- end }}
{{- end }}

{{/*
Generate the image reference for a component.
Usage: include "catalyst.image" (dict "image" .Values.component.image "consolidated" .Values.global.consolidated_image "global" .Values.global.image "context" .)
This helper:
1. Uses global.image.registry if set, otherwise uses the component's registry (or consolidated registry if using consolidated image)
2. Uses consolidated_image.repository if consolidated_image.enabled is true
3. Properly constructs the full image reference as registry/repository:tag
*/}}
{{- define "catalyst.image" -}}
{{- $registry := .image.registry -}}
{{- $repository := .image.repository -}}
{{- $tag := .image.tag -}}
{{- if and .consolidated .consolidated.enabled -}}
  {{- $repository = .consolidated.repository -}}
  {{- $registry = .consolidated.registry -}}
  {{- $tag = .image.tag -}}
{{- end -}}
{{- if and .global .global.registry -}}
  {{- $registry = .global.registry -}}
{{- end -}}
{{- if kindIs "string" $repository -}}
  {{- $repository = tpl $repository .context -}}
{{- end -}}
{{- printf "%s/%s:%s" $registry $repository $tag -}}
{{- end -}}

{{/*
Generate the image pull policy for a component.
Usage: include "catalyst.imagePullPolicy" (dict "image" .Values.component.image "consolidated" .Values.global.consolidated_image "global" .Values.global.image)
This helper:
1. Uses component's pullPolicy if set
2. Falls back to consolidated_image.pullPolicy if using consolidated image and it's set
3. Falls back to global.image.pullPolicy as final default
*/}}
{{- define "catalyst.imagePullPolicy" -}}
{{- if .image.pullPolicy -}}
  {{- .image.pullPolicy -}}
{{- else if and .consolidated .consolidated.enabled .consolidated.pullPolicy -}}
  {{- .consolidated.pullPolicy -}}
{{- else -}}
  {{- .global.pullPolicy -}}
{{- end -}}
{{- end -}}

{{/*
Replace registry in a full image reference.
Usage: include "catalyst.replaceRegistry" (dict "image" "old-registry.com/path/to/image:tag" "registry" "new-registry.com")
This helper extracts the repository:tag portion and prepends the new registry.
*/}}
{{- define "catalyst.replaceRegistry" -}}
{{- if .registry -}}
  {{- $parts := regexSplit "/" .image -1 -}}
  {{- $repoAndTag := slice $parts 1 | join "/" -}}
  {{- printf "%s/%s" .registry $repoAndTag -}}
{{- else -}}
  {{- .image -}}
{{- end -}}
{{- end -}}


