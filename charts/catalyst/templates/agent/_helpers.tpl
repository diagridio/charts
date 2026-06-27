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
agent.defaultAffinity: a soft pod anti-affinity that spreads agent replicas
across nodes so a single node failure can't take out the whole fleet. It is a
preference (preferredDuringScheduling), so it never blocks scheduling — at a
single replica it is a no-op. Applied by agent/deployment.yaml only when no
affinity is configured via values; any user-supplied affinity replaces it.
*/}}
{{- define "agent.defaultAffinity" -}}
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            {{- /* full selector labels (name+instance+component) so this only
                   spreads replicas of THIS agent Deployment, not every agent
                   pod in the namespace from other releases/hosts */}}
            {{- include "agent.selectorLabels" . | nindent 12 }}
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
    {{- if and (not .Values.join_token) (not .Values.agent.existingJoinTokenSecret.name) -}}
        {{- fail "Either join_token or agent.existingJoinTokenSecret.name is required to deploy this chart!" -}}
    {{- end -}}
    {{- if not .Values.global.control_plane_url -}}
        {{- fail "global.control_plane_url is required!" -}}
    {{- end -}}
    {{- if not .Values.global.control_plane_http_url -}}
        {{- fail "global.control_plane_http_url is required when join_token is provided!" -}}
    {{- end -}}
    {{- include "catalyst.validateGlobalValues" . -}}
    {{- if not .Values.agent.config.project.default_managed_state_store_type -}}
        {{- fail "agent.config.project.default_managed_state_store_type is required!" -}}
    {{- end -}}
    {{- if not .Values.agent.config.project.default_managed_pubsub_type -}}
        {{- fail "agent.config.project.default_managed_pubsub_type is required!" -}}
    {{- end -}}
    {{- if not .Values.agent.config.placement -}}
        {{- fail "agent.config.placement is required!" -}}
    {{- end -}}
    {{- if le (int .Values.agent.config.placement.max_project_count) 0 -}}
        {{- fail "agent.config.placement.max_project_count must be greater than 0!" -}}
    {{- end -}}
    {{- if le (int .Values.agent.config.placement.max_appid_count) 0 -}}
        {{- fail "agent.config.placement.max_appid_count must be greater than 0!" -}}
    {{- end -}}
    {{- if .Values.agent.config.internal_dapr -}}
        {{- if .Values.agent.config.internal_dapr.ca -}}
            {{- if not .Values.agent.config.internal_dapr.ca.trust_anchors_config_map_name -}}
                {{- fail "agent.config.internal_dapr.ca.trust_anchors_config_map_name is required when internal_dapr.ca is configured!" -}}
            {{- end -}}
        {{- end -}}
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