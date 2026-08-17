{{/*
Catalyst MCP Helpers

catalyst-mcp is the regional MCP bridge: it exposes the Catalyst Management
REST API as MCP tools, generated at runtime from the Management OpenAPI
specification that ships inside its container image.
*/}}
{{/*
Create the name of the mcp resource
*/}}
{{- define "mcp.name" -}}
  {{- include "common.name" (dict
      "nameOverride" .Values.mcp.nameOverride
      "defaultName" "catalyst-mcp"
      "Chart.Name" .Chart.Name
      "global" .Values.global
  ) }}
{{- end }}


{{/*
Create a fully qualified app name for mcp
*/}}
{{- define "mcp.fullname" -}}
  {{- include "common.fullname" (dict
      "fullnameOverride" .Values.mcp.fullnameOverride
      "Release" .Release
      "name" (include "mcp.name" .)
      "global" .Values.global
  ) }}
{{- end }}


{{/*
Common labels for mcp
*/}}
{{- define "mcp.labels" -}}
{{- include "common.labels" . }}
app.kubernetes.io/component: mcp
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mcp.selectorLabels" -}}
{{- include "common.selectorLabels" . }}
app.kubernetes.io/component: mcp
{{- end }}

{{/*
Create the name of the service account to use for mcp
*/}}
{{- define "mcp.serviceAccountName" -}}
  {{- if .Values.mcp.serviceAccount.name }}
    {{- .Values.mcp.serviceAccount.name | trunc 63 | trimSuffix "-" }}
  {{- else }}
    {{- printf "%s-sa" (include "mcp.fullname" .) | trunc 63 | trimSuffix "-" }}
  {{- end }}
{{- end }}

{{/*
Upstream Management API base URL that catalyst-mcp proxies tool calls to.

Derived from the in-cluster management Service by default so it can never drift
from the Service this chart renders: same release namespace, the management
HTTP Service port, and plain http:// because management's REST server is
started without a TLS config (pkg/restservice.NewHTTPRestServer is passed a nil
*tls.Config from services/catalyst/management/internal/management/management.go,
and http_server.tls defaults to disabled). The upstream must stay in-cluster —
never a public endpoint — so tool calls do not leave the region.

mcp.baseUrl overrides it verbatim when set.
*/}}
{{- define "mcp.baseURL" -}}
{{- if .Values.mcp.baseUrl -}}
{{- .Values.mcp.baseUrl -}}
{{- else -}}
{{- printf "http://%s.%s.svc.cluster.local:%v" (include "management.name" .) .Release.Namespace (.Values.management.http_service.port | int) -}}
{{- end -}}
{{- end -}}

{{/*
Validate mcp values
*/}}
{{- define "mcp.validateValues" -}}
    {{- if not (has .Values.mcp.httpAuthMode (list "passthrough" "server")) -}}
        {{- fail (printf "mcp.httpAuthMode must be \"passthrough\" or \"server\", got %q!" .Values.mcp.httpAuthMode) -}}
    {{- end -}}
    {{- if eq .Values.mcp.httpAuthMode "server" -}}
        {{- /* "server" mode makes catalyst-mcp hold a single shared upstream
               credential (DIAGRID_TOKEN / DIAGRID_ORG_ID), so every tool call
               would run as that identity instead of the calling end user, and
               the Management API would apply the wrong RBAC. This chart
               deliberately plumbs no such credential, and the binary exits 2
               when it is missing, so fail at render time with the reason
               rather than in a CrashLoopBackOff. */ -}}
        {{- fail "mcp.httpAuthMode: \"server\" is not supported by this chart — it would make every MCP tool call run under one shared service identity instead of the calling user's, bypassing per-user RBAC in the Management API. Use \"passthrough\"." -}}
    {{- end -}}
{{- end -}}
