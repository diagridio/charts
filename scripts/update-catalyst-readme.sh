#!/usr/bin/env bash
#
# Update image tags in the Catalyst chart README from authoritative sources.
#
# Tags are read from charts/catalyst/values.yaml (already mutated for the
# release by `make update-catalyst-tags`, `update-catalyst-chart-version`,
# and `update-catalyst-registry`) and the internal Dapr fork tag from
# services/catalyst/agent/pkg/config/dapr.go. The registry/repository portions
# of each image reference are preserved as-is — only the tag (after the last
# `:` in each backticked cell) is rewritten.
#
# Covered tables:
#   - "Installation Images"             (7 rows)
#   - "Alternatively, separate images"  (4 rows)
#   - "Dependencies"                    (3 rows; labels reused from Installation)
#   - "Runtime Images"                  (3 rows; labels reused from Installation)
#
# Labels that appear in multiple tables (Alpine k8s, Envoy Proxy, Piko,
# Dapr Control Plane (Catalyst), Dapr Server, OpenTelemetry Collector) all
# share the same tag value across their rows, so one substitution per label
# updates every occurrence consistently.
#
# The OpenTelemetry Collector (OSS) row in "Optional Images" is intentionally
# left as `<tag>`: the tag is set by the upstream open-telemetry helm subchart
# pinned via `~X.Y.Z` in Chart.yaml, and resolves only after `helm dependency
# update` against the live chart repo.
#
# Fails loudly if any expected row pattern is not found, so README layout drift
# is caught at CI time instead of silently producing a no-op diff.
#
# Usage:
#   charts/scripts/update-catalyst-readme.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${CHARTS_DIR}/.." && pwd)"

VALUES="${CHARTS_DIR}/charts/catalyst/values.yaml"
README="${CHARTS_DIR}/charts/catalyst/README.md"
DAPR_GO="${REPO_ROOT}/services/catalyst/agent/pkg/config/dapr.go"

for f in "${VALUES}" "${README}" "${DAPR_GO}"; do
    if [[ ! -f "${f}" ]]; then
        echo "ERROR: required file not found: ${f}" >&2
        exit 1
    fi
done

command -v yq >/dev/null 2>&1 || { echo "ERROR: yq is required" >&2; exit 1; }

# ----- Resolve tags -----------------------------------------------------------

yq_get() {
    local path="$1"
    local out
    out="$(yq -r "${path}" "${VALUES}")"
    if [[ -z "${out}" || "${out}" == "null" ]]; then
        echo "ERROR: empty/missing value at ${path} in ${VALUES}" >&2
        exit 1
    fi
    printf '%s' "${out}"
}

# Internal Dapr fork tag — match parser in services/catalyst/scripts/check-dapr-version-sync.sh.
read_dapr_default_image_tag() {
    awk '
        /DefaultInternalDaprConfig[[:space:]]*=/ { in_block = 1 }
        in_block && /DefaultImageTag:/ {
            match($0, /"[^"]+"/)
            if (RSTART > 0) {
                print substr($0, RSTART + 1, RLENGTH - 2)
                exit
            }
        }
        in_block && /^}/ { exit }
    ' "${DAPR_GO}"
}

ALPINE_TAG="$(yq_get '.cleanup.image.tag')"
ENVOY_TAG="$(yq_get '.gateway.envoy.image.tag')"
PIKO_TAG="$(yq_get '.piko.image.tag')"
AGENT_TAG="$(yq_get '.agent.image.tag')"
MANAGEMENT_TAG="$(yq_get '.management.image.tag')"
GATEWAY_CP_TAG="$(yq_get '.gateway.controlplane.image.tag')"
IDENTITY_INJECTOR_TAG="$(yq_get '.gateway.identityInjector.image.tag')"
SIDECAR_TAG="$(yq_get '.agent.config.sidecar.image_tag')"
OTEL_TAG="$(yq_get '.agent.config.otel.image_tag')"

DAPR_TAG="$(read_dapr_default_image_tag)"
if [[ -z "${DAPR_TAG}" ]]; then
    echo "ERROR: failed to read DefaultInternalDaprConfig.DefaultImageTag from ${DAPR_GO}" >&2
    exit 1
fi

# ----- Apply replacements -----------------------------------------------------

# Replace the tag portion (after the last `:` and before the closing backtick)
# on every row whose first cell is `| **<label>** |`. Fails if no row matches.
# The delimiter is `#` to avoid escape collisions with the `\|` literals inside
# the regex (both BSD and GNU sed mishandle that combination with a `|` delim).
replace_tag() {
    local label="$1" new_tag="$2"
    local label_re
    label_re="$(printf '%s' "${label}" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
    if ! grep -qE "^\| \*\*${label_re}\*\* \|" "${README}"; then
        echo "ERROR: row not found for label: ${label}" >&2
        exit 1
    fi
    sed -E -i.bak "s#(\\| \\*\\*${label_re}\\*\\* \\| \`[^\`]*:)[^\`]*(\`.*)#\\1${new_tag}\\2#" "${README}"
    rm -f "${README}.bak"
}

# Installation + Dependencies (shared labels are kept in sync by a single call
# because every occurrence carries the same tag value at release time).
replace_tag "Alpine k8s"                    "${ALPINE_TAG}"
replace_tag "Envoy Proxy"                   "${ENVOY_TAG}"
replace_tag "Catalyst"                      "${AGENT_TAG}"
replace_tag "Piko"                          "${PIKO_TAG}"
replace_tag "Dapr Control Plane (Catalyst)" "${DAPR_TAG}"

# "Dapr Server" / "OpenTelemetry Collector" appear in both the Installation
# table (pointing at the consolidated catalyst-all image, tag = REL_VERSION)
# and the Runtime table (pointing at the per-component sidecar /
# catalyst-otel-collector images, tag = REL_VERSION). Same tag, one call.
replace_tag "Dapr Server"                   "${SIDECAR_TAG}"
replace_tag "OpenTelemetry Collector"       "${OTEL_TAG}"

# Alternatively, separate images.
replace_tag "Catalyst Agent"                "${AGENT_TAG}"
replace_tag "Catalyst Management"           "${MANAGEMENT_TAG}"
replace_tag "Gateway Control Plane"         "${GATEWAY_CP_TAG}"
replace_tag "Gateway Identity Injector"     "${IDENTITY_INJECTOR_TAG}"

echo "Updated ${README#${REPO_ROOT}/} from ${VALUES#${REPO_ROOT}/} and ${DAPR_GO#${REPO_ROOT}/}"
echo "  Alpine k8s                    ${ALPINE_TAG}"
echo "  Envoy Proxy                   ${ENVOY_TAG}"
echo "  Catalyst                      ${AGENT_TAG}"
echo "  Piko                          ${PIKO_TAG}"
echo "  Dapr Control Plane (Catalyst) ${DAPR_TAG}"
echo "  Dapr Server                   ${SIDECAR_TAG}"
echo "  OpenTelemetry Collector       ${OTEL_TAG}"
echo "  Catalyst Agent                ${AGENT_TAG}"
echo "  Catalyst Management           ${MANAGEMENT_TAG}"
echo "  Gateway Control Plane         ${GATEWAY_CP_TAG}"
echo "  Gateway Identity Injector     ${IDENTITY_INJECTOR_TAG}"
