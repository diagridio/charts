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
{{- $tag := include "catalyst.imageTag" (dict "image" .image) -}}
{{- if and .consolidated .consolidated.enabled -}}
  {{- $repository = .consolidated.repository -}}
  {{- $registry = .consolidated.registry -}}
{{- end -}}
{{- if .global.registry -}}
  {{- $registry = .global.registry -}}
{{- end -}}
{{- if kindIs "string" $repository -}}
  {{- $repository = tpl $repository .context -}}
{{- end -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry $repository $tag -}}
{{- else -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the image tag for a component. This is the single source of truth for
"which tag was this component deployed with", so a component can be told its own
version at runtime (e.g. via an env var) and have it match the image it actually
runs from — "catalyst.image" resolves its tag the same way. The consolidated-image
path does not change the tag (only the registry and repository differ), so the
component's own image tag is always correct.
Usage: include "catalyst.imageTag" (dict "image" .Values.component.image)
*/}}
{{- define "catalyst.imageTag" -}}
{{- .image.tag -}}
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

{{/*
Init container that blocks until the named Dapr Configuration CR exists in
the pod's namespace. Used by management/gateway/gateway-controlplane pods to
avoid crash-looping during the window between pod start and the cra-agent
creating their Configuration CR (the agent installs root-dapr-system and
joins the region before it can compute the trust domain and create the CRs).

Usage:
  {{- include "catalyst.waitForDaprConfigInitContainer" (dict "configName" "management" "context" .) | nindent 6 }}
*/}}
{{- define "catalyst.waitForDaprConfigInitContainer" -}}
{{- $w := .context.Values.global.waitForDaprConfig -}}
{{- if $w.enabled -}}
{{- $wRegistry := or $w.image.registry .context.Values.global.registry -}}
- name: wait-for-dapr-config
  image: "{{ $wRegistry }}/{{ $w.image.repository }}:{{ $w.image.tag }}"
  imagePullPolicy: {{ $w.image.pullPolicy }}
  command:
    - sh
    - -c
    - |
      set -eu
      cfg="{{ .configName }}"
      deadline=$(( $(date +%s) + ${TIMEOUT_SECONDS} ))
      echo "waiting for Configuration.dapr.io/${cfg} in namespace ${NAMESPACE} (timeout ${TIMEOUT_SECONDS}s)"
      while ! kubectl get configurations.dapr.io "${cfg}" -n "${NAMESPACE}" -o name >/dev/null 2>&1; do
        if [ "$(date +%s)" -ge "${deadline}" ]; then
          echo "timed out waiting for Configuration.dapr.io/${cfg} in namespace ${NAMESPACE}"
          exit 1
        fi
        sleep "${POLL_INTERVAL_SECONDS}"
      done
      echo "Configuration.dapr.io/${cfg} present, continuing"
  env:
    - name: NAMESPACE
      valueFrom:
        fieldRef:
          fieldPath: metadata.namespace
    - name: TIMEOUT_SECONDS
      value: {{ $w.timeoutSeconds | quote }}
    - name: POLL_INTERVAL_SECONDS
      value: {{ $w.pollIntervalSeconds | quote }}
  resources:
    {{- toYaml $w.resources | nindent 4 }}
  securityContext:
    {{- toYaml $w.securityContext | nindent 4 }}
{{- end -}}
{{- end -}}

{{/*
catalyst.nodeSelectorAsList: converts a map[string]string (nodeSelector/matchLabels)
into a list of { key, value } pairs. This form is safe to write into the agent's
configmap because viper's default "." key delimiter would otherwise split well-
known label keys like "kubernetes.io/arch" into nested paths during Unmarshal.
Returns an empty list if the input is empty or missing.

Input dict: { m: <map to convert> }
*/}}
{{- define "catalyst.nodeSelectorAsList" -}}
{{- $out := list -}}
{{- range $k, $v := .m -}}
{{- $out = append $out (dict "key" $k "value" $v) -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end }}

{{/*
catalyst.nodeSelector: render a merged nodeSelector map.

Applies in order (later wins on key collision):
  1. shared.scheduling.nodeSelector         (chart-wide default — typically .Values.shared.scheduling)
  2. component.nodeSelector      (per-component value)
  3. componentMerge.nodeSelector (per-component merge patch, if any)

Input dict: { shared, component, componentMerge }
Caller is responsible for indenting the output (use | nindent N).
*/}}
{{- define "catalyst.nodeSelector" -}}
{{- $out := dict -}}
{{- if and .shared .shared.nodeSelector }}{{- $out = mergeOverwrite $out .shared.nodeSelector }}{{- end -}}
{{- if and .component .component.nodeSelector }}{{- $out = mergeOverwrite $out .component.nodeSelector }}{{- end -}}
{{- if and .componentMerge .componentMerge.nodeSelector }}{{- $out = mergeOverwrite $out .componentMerge.nodeSelector }}{{- end -}}
{{- $out | toYaml -}}
{{- end }}

{{/*
catalyst.affinity: same merge semantics as catalyst.nodeSelector, for affinity.
Input dict: { shared, component, componentMerge }
*/}}
{{- define "catalyst.affinity" -}}
{{- $out := dict -}}
{{- if and .shared .shared.affinity }}{{- $out = mergeOverwrite $out .shared.affinity }}{{- end -}}
{{- if and .component .component.affinity }}{{- $out = mergeOverwrite $out .component.affinity }}{{- end -}}
{{- if and .componentMerge .componentMerge.affinity }}{{- $out = mergeOverwrite $out .componentMerge.affinity }}{{- end -}}
{{- $out | toYaml -}}
{{- end }}

{{/*
catalyst.tolerations: concatenated tolerations list.
Order: shared + component + componentMerge (duplicates are the user's
responsibility; Kubernetes accepts duplicate toleration entries).
Input dict: { shared, component, componentMerge }
*/}}
{{- define "catalyst.tolerations" -}}
{{- $out := list -}}
{{- if and .shared .shared.tolerations }}{{- $out = concat $out .shared.tolerations -}}{{- end -}}
{{- if and .component .component.tolerations }}{{- $out = concat $out .component.tolerations -}}{{- end -}}
{{- if and .componentMerge .componentMerge.tolerations }}{{- $out = concat $out .componentMerge.tolerations -}}{{- end -}}
{{- $out | toYaml -}}
{{- end }}

{{/*
Validate global values shared by agent and management.
Both services require sentry and correct secrets provider configuration.
*/}}
{{- define "catalyst.validateGlobalValues" -}}
    {{- if not .Values.global.sentry.endpoint -}}
        {{- fail "global.sentry.endpoint is required!" -}}
    {{- end -}}
    {{- if not .Values.global.sentry.trust_domain -}}
        {{- fail "global.sentry.trust_domain is required!" -}}
    {{- end -}}
    {{- if not .Values.global.sentry.namespace -}}
        {{- fail "global.sentry.namespace is required!" -}}
    {{- end -}}
    {{- if eq .Values.global.secrets.provider "redis" -}}
        {{- if not .Values.global.secrets.redis -}}
            {{- fail "global.secrets.redis must be configured when global.secrets.provider is redis!" -}}
        {{- end -}}
        {{- if not .Values.global.secrets.redis.host -}}
            {{- fail "global.secrets.redis.host is required when global.secrets.provider is redis!" -}}
        {{- end -}}
    {{- end -}}
    {{- if eq .Values.global.secrets.provider "aws.secretmanager" -}}
        {{- if not .Values.global.secrets.aws -}}
            {{- fail "global.secrets.aws must be configured when global.secrets.provider is aws.secretmanager!" -}}
        {{- end -}}
        {{- if not .Values.global.secrets.aws.region -}}
            {{- fail "global.secrets.aws.region is required when global.secrets.provider is aws.secretmanager!" -}}
        {{- end -}}
    {{- end -}}
    {{- include "catalyst.validateInfraValues" . -}}
{{- end -}}

{{/*
catalyst.resolvedInfra — single source of truth translating the user-facing
global.postgresql / global.kafka / scheduler value surface into the canonical
agent config vocabulary (project.default_managed_*_type, external/selfhosted
sub-configs, internal_dapr.scheduler.backend_type + backend sub-configs).

Both the agent and management ConfigMaps consume this so they can never drift:
Helm renders each template independently, so a `set` mutation in one is invisible
to the other — the shared, side-effect-free helper is the only safe way to share
derived state.

Precedence (see charts/charts/catalyst/README.md and the branch handoff):
  Rule A — legacy passthrough wins. If the user explicitly set an underlying
  canonical field (a non-empty default_managed_*_type, external_*.enabled, or a
  *legacy* scheduler backend_type of managed-postgresql/external-postgresql), it
  is honored verbatim and the global.* derivation is skipped.
  Rule B — otherwise derive from the friendlier global.* surface. This depends on
  the shipped legacy defaults being blanked in values.yaml so "non-empty" reliably
  means "user set it".

Output (rendered as YAML; callers do `include ... | fromYaml`):
  stateStore: { type, selfhosted{}, external{} }
  scheduler:  { backend_type, managed_postgresql{}, external_postgresql{} }
  pubsub:     { type, selfhosted{}, external{} }
Empty sub-config dicts are falsy in Helm, so callers gate on them with `if`.
*/}}
{{- define "catalyst.resolvedInfra" -}}
{{- /* Read via nested-value accessors (not dig on .Values): the root .Values is
       chartutil.Values, which dig cannot type-assert; nested values are plain maps. */ -}}
{{- $global := .Values.global | default dict -}}
{{- $agent := .Values.agent | default dict -}}
{{- $ac := $agent.config | default dict -}}
{{- $project := $ac.project | default dict -}}
{{- $sched := dig "internal_dapr" "scheduler" dict $ac -}}
{{- $gpg := dig "postgresql" dict $global -}}
{{- $gkafka := dig "kafka" dict $global -}}
{{- /* ---------- State store ---------- */ -}}
{{- $ssType := "" -}}
{{- $ssSelfhosted := dict -}}
{{- $ssExternal := dict -}}
{{- $legacySSType := $project.default_managed_state_store_type | default "" -}}
{{- $legacyExtPg := dig "external_postgresql" dict $project -}}
{{- if or (ne $legacySSType "") (dig "enabled" false $legacyExtPg) -}}
  {{- $ssType = $legacySSType -}}
  {{- $ssSelfhosted = dig "selfhosted_postgresql" dict $project -}}
  {{- $ssExternal = $legacyExtPg -}}
{{- else if dig "disabled" false $gpg -}}
  {{- $ssType = "postgresql-shared-disabled" -}}
{{- else if dig "create" true $gpg -}}
  {{- $ssType = "postgresql-shared-selfhosted" -}}
  {{- $ssSelfhosted = dig "selfhosted" dict $gpg -}}
{{- else -}}
  {{- $ssType = "postgresql-shared-external" -}}
  {{- $ssExternal = deepCopy (dig "external" dict $gpg) -}}
  {{- $_ := set $ssExternal "enabled" true -}}
{{- end -}}
{{- /* ---------- Scheduler ---------- */ -}}
{{- $schedBackend := $sched.backend_type | default "" -}}
{{- $outBackend := "" -}}
{{- $outManaged := dict -}}
{{- $outExternal := dict -}}
{{- if eq $schedBackend "postgresql" -}}
  {{- $pgsched := dig "postgresql" dict $sched -}}
  {{- if dig "use_global" true $pgsched -}}
    {{- $outBackend = "managed-postgresql" -}}
    {{- $outManaged = dict "max_conns_per_instance" (dig "max_conns_per_instance" 5 $pgsched) -}}
  {{- else -}}
    {{- $outBackend = "external-postgresql" -}}
    {{- $outExternal = dict "max_conns_per_instance" (dig "max_conns_per_instance" 5 $pgsched) "connections" (dig "connections" list $pgsched) -}}
  {{- end -}}
{{- else -}}
  {{- /* etcd, legacy managed-/external-postgresql, or empty (disabled): passthrough */ -}}
  {{- $outBackend = $schedBackend -}}
  {{- $outManaged = dig "managed_postgresql" dict $sched -}}
  {{- $outExternal = dig "external_postgresql" dict $sched -}}
{{- end -}}
{{- /* ---------- Pubsub / Kafka ---------- */ -}}
{{- $psType := "" -}}
{{- $psSelfhosted := dict -}}
{{- $psExternal := dict -}}
{{- $legacyPsType := $project.default_managed_pubsub_type | default "" -}}
{{- $legacyExtKafka := dig "external_kafka" dict $project -}}
{{- if or (ne $legacyPsType "") (dig "enabled" false $legacyExtKafka) -}}
  {{- $psType = $legacyPsType -}}
  {{- $psSelfhosted = dig "selfhosted_kafka" dict $project -}}
  {{- $psExternal = $legacyExtKafka -}}
{{- else if dig "disabled" true $gkafka -}}
  {{- $psType = "kafka-shared-disabled" -}}
{{- else if dig "create" false $gkafka -}}
  {{- $psType = "kafka-shared-selfhosted" -}}
  {{- $psSelfhosted = dig "selfhosted" dict $gkafka -}}
{{- else -}}
  {{- $psType = "kafka-shared-external" -}}
  {{- $psExternal = deepCopy (dig "external" dict $gkafka) -}}
  {{- $_ := set $psExternal "enabled" true -}}
{{- end -}}
{{- /* ---------- Redis (managed shared backing service) ---------- */ -}}
{{- /* Defaults to disabled (opt-in),
       so existing overlays without global.redis resolve to redis-shared-disabled
       and the agent ConfigMap emits nothing (see agent/configmap.yaml). */ -}}
{{- $gredis := dig "redis" dict $global -}}
{{- $rType := "redis-shared-disabled" -}}
{{- $rSelfhosted := dict -}}
{{- $rExternal := dict -}}
{{- if dig "disabled" true $gredis -}}
  {{- $rType = "redis-shared-disabled" -}}
{{- else if dig "create" false $gredis -}}
  {{- $rType = "redis-shared-selfhosted" -}}
  {{- $rSelfhosted = dig "selfhosted" dict $gredis -}}
{{- else -}}
  {{- $rType = "redis-shared-external" -}}
  {{- $rExternal = deepCopy (dig "external" dict $gredis) -}}
  {{- $_ := set $rExternal "enabled" true -}}
{{- end -}}
{{- $out := dict
    "stateStore" (dict "type" $ssType "selfhosted" $ssSelfhosted "external" $ssExternal)
    "scheduler" (dict "backend_type" $outBackend "managed_postgresql" $outManaged "external_postgresql" $outExternal)
    "pubsub" (dict "type" $psType "selfhosted" $psSelfhosted "external" $psExternal)
    "redis" (dict "type" $rType "selfhosted" $rSelfhosted "external" $rExternal)
-}}
{{- $out | toYaml -}}
{{- end -}}

{{/*
catalyst.validateInfraValues — fail rendering with a clear message for illegal
Postgres/Kafka/scheduler combinations, mirroring the agent's own runtime
validation (services/catalyst/agent/pkg/config/config.go and project/config.go)
so operators get the error at `helm template` time rather than a CrashLoop later.
*/}}
{{- define "catalyst.validateInfraValues" -}}
{{- $r := include "catalyst.resolvedInfra" . | fromYaml -}}
{{- /* A managed-postgresql scheduler reuses the managed state store; it cannot
       run when the state store is disabled (mirrors config.go). */ -}}
{{- if and (eq $r.scheduler.backend_type "managed-postgresql") (eq $r.stateStore.type "postgresql-shared-disabled") -}}
  {{- fail "A Postgres scheduler that reuses the managed state store (scheduler.backend_type: postgresql, postgresql.use_global: true) is incompatible with global.postgresql.disabled: true. Either enable Postgres (global.postgresql.disabled: false), use a dedicated external scheduler DB (postgresql.use_global: false), or switch to scheduler.backend_type: etcd." -}}
{{- end -}}
{{- /* External state store must be enabled (mirrors config.go:279). The deeper
       connection validation (host/secret/aws_auth) stays with the agent, as it
       does today. When derived from global.postgresql.create: false the resolver
       always sets enabled: true; this only trips a legacy passthrough that set
       default_managed_state_store_type: postgresql-shared-external without
       external_postgresql.enabled. */ -}}
{{- if eq $r.stateStore.type "postgresql-shared-external" -}}
  {{- if not (dig "enabled" false $r.stateStore.external) -}}
    {{- fail "An external Postgres state store (global.postgresql.create: false, or default_managed_state_store_type: postgresql-shared-external) requires external_postgresql.enabled: true with a connection. Set global.postgresql.external.existing_secret_name (preferred) or the inline connection_string_* fields." -}}
  {{- end -}}
{{- end -}}
{{- /* A dedicated external scheduler DB needs at least one connection. */ -}}
{{- if eq $r.scheduler.backend_type "external-postgresql" -}}
  {{- if not (dig "connections" list $r.scheduler.external_postgresql) -}}
    {{- fail "scheduler.backend_type: postgresql with postgresql.use_global: false needs at least one entry in scheduler.postgresql.connections." -}}
  {{- end -}}
{{- end -}}
{{- /* External Kafka must be enabled (mirrors config.go:275). Broker-level
       validation stays with the agent. */ -}}
{{- if eq $r.pubsub.type "kafka-shared-external" -}}
  {{- if not (dig "enabled" false $r.pubsub.external) -}}
    {{- fail "An external Kafka (global.kafka.create: false, or default_managed_pubsub_type: kafka-shared-external) requires external_kafka.enabled: true with brokers configured under global.kafka.external." -}}
  {{- end -}}
{{- end -}}
{{- /* External Redis must have a connection host. Deeper validation stays with
       the agent. Only trips when global.redis.create: false, disabled: false. */ -}}
{{- if eq $r.redis.type "redis-shared-external" -}}
  {{- if not (dig "host" "" $r.redis.external) -}}
    {{- fail "An external Redis (global.redis.create: false, disabled: false) requires a connection host. Set global.redis.external.host (and port), or global.redis.external.existing_secret_name." -}}
  {{- end -}}
{{- end -}}
{{- end -}}
