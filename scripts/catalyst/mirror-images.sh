#!/usr/bin/env bash

#
# Mirror Catalyst Helm Chart Images
#
# This script copies every image a Catalyst install pulls to a target registry,
# at the path the chart asks for once global.image.registry names that
# registry. It finds them by rendering the chart you install with the
# values files you install it with: the images its templates render, and the
# ones the agent deploys after installation, which the chart names in the
# agent's config. An image or tag your values override is the one copied.
# Subchart images (metrics-server, the OpenTelemetry add-ons) do not follow
# global.image.registry: the script lists them instead of copying them.
#
# Released Catalyst charts pin every Diagrid image by digest, so the mirror has
# to hold the same manifests as the source registry. ORAS is preferred when it
# is installed: `oras cp --recursive` preserves digests and also copies each
# image's signature, build provenance and SBOMs, so the mirror can be verified
# (see
# https://docs.diagrid.io/operate/hosting/enterprise-self-hosted/verify-artifacts).
# ORAS also needs jq, to find the
# per-architecture images whose legacy attestation tags it copies. crane also
# preserves digests but copies the image alone. docker and podman re-push
# through the local daemon, which can re-encode layers and change digests, and
# a digest-pinned chart then fails to pull from the mirror.
#
# Usage:
#   ./mirror-images.sh <target-registry> [OPTIONS]
#
# Arguments:
#   target-registry: The destination registry (e.g., my-registry.example.com)
#
# Options:
#   --chart CHART                 The chart to read the image list from: a directory,
#                                 a .tgz, or oci://public.ecr.aws/diagrid/catalyst
#                                 (default: the chart in this repository, ../../charts/catalyst)
#   --chart-version VERSION       The chart version, with an oci:// --chart
#   --values FILE                 A values file you install the chart with. Repeat it for
#                                 each file, in the order you pass them to helm
#                                 (default: the chart's own defaults)
#   --charts-registry REGISTRY    Also copy the Dapr Helm chart the agent installs to this
#                                 oci:// path, the value you give global.charts.registry
#   --dry-run                     Print what would be done without executing
#   --skip-pull                   Skip pulling images, only tag and push
#
# Examples:
#   ./mirror-images.sh my-registry.example.com \
#     --chart oci://public.ecr.aws/diagrid/catalyst --chart-version 1.137.0
#   ./mirror-images.sh my-registry.example.com \
#     --chart oci://public.ecr.aws/diagrid/catalyst --chart-version 1.137.0 \
#     --values catalyst-values.yaml \
#     --charts-registry oci://my-registry.example.com/diagrid/catalyst
#   ./mirror-images.sh my-registry.example.com --dry-run
#
# Requires helm, to render the chart. A chart directory needs its dependencies
# built first (helm dependency build).
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default options
DRY_RUN=false
SKIP_PULL=false
TARGET_REGISTRY=""
CHART="${SCRIPT_DIR}/../../charts/catalyst"
CHART_VERSION=""
CHARTS_REGISTRY=""
VALUES_ARGS=()
DAPR_CHART_SOURCE="oci://public.ecr.aws/diagrid/dapr"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --chart)
      CHART="${2:?--chart needs a value}"
      shift 2
      ;;
    --chart-version)
      CHART_VERSION="${2:?--chart-version needs a value}"
      shift 2
      ;;
    --values)
      [[ -f "${2:?--values needs a file}" ]] || { echo -e "${RED}Error: no such values file: $2${NC}" >&2; exit 1; }
      VALUES_ARGS+=(--values "$2")
      shift 2
      ;;
    --charts-registry)
      CHARTS_REGISTRY="${2:?--charts-registry needs a value}"; CHARTS_REGISTRY="${CHARTS_REGISTRY%/}"
      shift 2
      ;;
    --catalyst-version|--dapr-version|--internal-dapr-version|--envoy-version|--piko-version|--otel-version)
      echo -e "${RED}Error: $1 was removed. The image list now comes from the chart itself:${NC}" >&2
      echo "  $0 <target-registry> --chart oci://public.ecr.aws/diagrid/catalyst --chart-version <version>" >&2
      exit 1
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --skip-pull)
      SKIP_PULL=true
      shift
      ;;
    -h|--help)
      grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# //g; s/^#//g'
      exit 0
      ;;
    *)
      if [[ -z "$TARGET_REGISTRY" ]]; then
        TARGET_REGISTRY="$1"
      else
        echo -e "${RED}Error: Unknown argument '$1'${NC}" >&2
        echo "Use --help for usage information" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# Validate target registry
if [[ -z "$TARGET_REGISTRY" ]]; then
  echo -e "${RED}Error: Target registry is required${NC}" >&2
  echo "Usage: $0 <target-registry> [--chart <chart>] [--chart-version <version>] [--values <file>]... [--dry-run] [--skip-pull]" >&2
  exit 1
fi
if [[ -n "$CHARTS_REGISTRY" && "$CHARTS_REGISTRY" != oci://* ]]; then
  echo -e "${RED}Error: --charts-registry takes an oci:// reference, e.g. oci://my-registry.example.com/diagrid/catalyst${NC}" >&2
  exit 1
fi
if [[ -n "$CHARTS_REGISTRY" && "${CHARTS_REGISTRY#oci://}" == "${TARGET_REGISTRY%/}" ]]; then
  # The Dapr chart and the Dapr image share a name and a tag.
  echo -e "${RED}Error: give --charts-registry a path of its own, e.g. oci://${TARGET_REGISTRY%/}/charts: the Dapr chart would replace the dapr image${NC}" >&2
  exit 1
fi
command -v helm > /dev/null || { echo -e "${RED}Error: helm is required to render the chart${NC}" >&2; exit 1; }

# Remove trailing slash from registry if present
TARGET_REGISTRY="${TARGET_REGISTRY%/}"

# The repository part of an image reference: no tag, no digest.
image_repository() {
  local ref="${1%@*}"
  local last="${ref##*/}"
  if [[ "$last" == *:* ]]; then
    ref="${ref%:*}"
  fi
  echo "$ref"
}

# `oras cp --recursive` follows the artifacts that refer to an image. The SLSA
# Build L3 provenance and the VEX statements are instead stored the older way,
# under a tag named after the digest (sha256-<hex>.att), for the index and for
# each per-architecture image. Copy those tags as well, where they exist.
copy_legacy_attestations() {
  local source_repo target_repo digest
  source_repo=$(image_repository "$1")
  target_repo=$(image_repository "$2")
  local digests
  digests=$(oras resolve "$1") || return 1
  digests+=" $(oras manifest fetch "$1" | jq -r '.manifests[]?.digest')" || return 1
  for digest in ${digests}; do
    local tag="sha256-${digest#sha256:}.att" err
    # Only a missing tag means there is nothing to copy. Any other error, a
    # missing login or a timeout, would leave the mirror without them.
    if err=$(oras manifest fetch --descriptor "${source_repo}:${tag}" 2>&1 > /dev/null); then
      oras cp "${source_repo}:${tag}" "${target_repo}:${tag}" > /dev/null || return 1
    elif ! grep -qiE 'not found|manifest unknown' <<< "${err}"; then
      echo -e "${RED}Could not check ${source_repo}:${tag}: ${err}${NC}" >&2
      return 1
    fi
  done
}

# Detect container runtime. ORAS, then crane: both copy manifests as they are,
# so the digests a released chart pins exist in the mirror, and ORAS also brings
# the signatures and attestations that refer to them.
if command -v oras &> /dev/null && command -v jq &> /dev/null; then
  RUNTIME="oras"
elif command -v crane &> /dev/null; then
  RUNTIME="crane"
elif command -v docker &> /dev/null; then
  RUNTIME="docker"
elif command -v podman &> /dev/null; then
  RUNTIME="podman"
else
  echo -e "${RED}Error: No container runtime found. Please install oras, crane, docker, or podman.${NC}" >&2
  exit 1
fi

# oras and crane copy registry to registry, so there is no locally pulled image
# for --skip-pull to reuse. The combination used to skip the copy and the push
# alike and still count every image as mirrored, reporting a complete mirror
# that holds nothing.
if [[ ( "$RUNTIME" == "oras" || "$RUNTIME" == "crane" ) && "$SKIP_PULL" == "true" ]]; then
  echo -e "${RED}Error: --skip-pull cannot be used with ${RUNTIME}, which copies directly between registries.${NC}" >&2
  echo -e "${RED}Drop the flag, or install docker or podman if you meant to push images you already pulled.${NC}" >&2
  exit 1
fi

echo -e "${BLUE}Using container runtime: ${RUNTIME}${NC}"
if [[ "$RUNTIME" == "crane" ]]; then
  echo -e "${YELLOW}Warning: crane copies each image without its signature, provenance or SBOMs, so the mirror cannot be verified.${NC}"
  echo -e "${YELLOW}Install oras to copy them too.${NC}"
elif [[ "$RUNTIME" != "oras" ]]; then
  echo -e "${YELLOW}Warning: ${RUNTIME} re-pushes images through the local daemon, which can change their digests.${NC}"
  echo -e "${YELLOW}Released Catalyst charts pin Diagrid images by digest; install oras (or crane) for a digest-preserving mirror.${NC}"
fi
echo -e "${BLUE}Target registry: ${TARGET_REGISTRY}${NC}"
echo -e "${BLUE}Chart: ${CHART}${CHART_VERSION:+ ${CHART_VERSION}}${NC}"

# The images a data plane render names outside any pod spec: the ones the agent
# deploys after installation, which the chart writes into the agent's
# config.yaml. agent_config flattens the config.yaml of every ConfigMap in a
# render read on stdin to "<path>\t<value>" lines; agent_images turns those
# into "<section> <image>" lines. They read the same fields as
# deploy/tools/pkg/catalystimages in the Catalyst repository and
# deploy/selfhosted/work/mirror-to-registry.sh in the self-hosted package (AgentComposedImages,
# AgentPinnedImages); keep them in step.
agent_config() {
  awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    /^---/ { inblock = 0; next }
    inblock && /^[[:space:]]*$/ { next }
    inblock && indent($0) < base { inblock = 0 }
    inblock {
      ind = indent($0) - base
      line = substr($0, base + 1)
      # The lines of a multi-line scalar (a PEM bundle) are not keys.
      if (skip >= 0 && ind > skip) next
      skip = -1
      if (line ~ /^ *- /) next
      if (line !~ /^ *[^ :][^:]*:( |$)/) next
      key = line; sub(/^ */, "", key); sub(/:( .*)?$/, "", key); gsub(/^["\047]|["\047]$/, "", key)
      val = line; sub(/^ *[^ :][^:]*:/, "", val); sub(/^ */, "", val); sub(/ *$/, "", val)
      while (n > 0 && depth[n] >= ind) n--
      path = ""
      for (i = 1; i <= n; i++) path = path keys[i] "."
      if (val == "") { n++; depth[n] = ind; keys[n] = key; next }
      if (val ~ /^[|>]/) { skip = ind; next }
      gsub(/^["\047]|["\047]$/, "", val)
      print path key "\t" val
      next
    }
    /^ *"?config\.yaml"?: *[|]/ { inblock = 1; base = indent($0) + 2; n = 0; skip = -1 }
  '
}

# agent_images FILE DAPR_VERSION ROTATION_IMAGE: the last two are the chart's
# catalyst.diagrid.io/dapr-version and catalyst.diagrid.io/jwt-rotation-image
# annotations, what the agent deploys where the values leave the Dapr image tag
# or the rotation image empty. A value the render sets wins.
agent_images() {
  awk -F'\t' -v dapr_default="$2" -v rotation_default="$3" '
    { v[$1] = $2 }
    function img(section, reg, name, tag, digest,   ref) {
      if (name == "" || (tag == "" && digest == "")) return
      ref = (reg != "" ? reg "/" : "") name
      if (tag != "") ref = ref ":" tag
      if (digest != "") ref = ref "@" digest
      print section, ref
    }
    function either(a, b) { return a != "" ? a : b }
    END {
      img("sidecar", v["sidecar.image_registry"], v["sidecar.image_name"], v["sidecar.image_tag"], v["sidecar.image_digest"])
      img("otel", v["otel.image_registry"], v["otel.image_name"], v["otel.image_tag"], v["otel.image_digest"])
      img("internal_dapr.sentry", v["internal_dapr.sentry.image.registry"], v["internal_dapr.sentry.image.name"], v["internal_dapr.sentry.image.tag"], v["internal_dapr.sentry.image.digest"])
      if (v["internal_dapr.container_registry"] != "")
        img("internal_dapr", v["internal_dapr.container_registry"], either(v["internal_dapr.image_name"], "dapr"), either(v["internal_dapr.image_tag"], dapr_default), "")
      # The rotation default, split into registry, name and tag.
      d_reg = ""; d_name = rotation_default; d_tag = ""
      if (match(d_name, /:[^:\/]+$/)) { d_tag = substr(d_name, RSTART + 1); d_name = substr(d_name, 1, RSTART - 1) }
      if (match(d_name, /.*\//)) { d_reg = substr(d_name, 1, RLENGTH - 1); d_name = substr(d_name, RLENGTH + 1) }
      p = "internal_dapr.sentry.jwt."
      reg = either(v[p "rotation_image_registry"], either(v[p "rotation_image.registry"], d_reg))
      if (reg != "")
        img("internal_dapr.sentry.jwt", reg, either(v[p "rotation_image.name"], d_name), either(v[p "rotation_image.tag"], d_tag), "")
    }
  ' "$1"
}

# chart_annotation KEY: one annotation's value from `helm show chart` on stdin.
chart_annotation() {
  awk -v key="$1" '$1 == key ":" { v = $2; gsub(/^["\047]|["\047]$/, "", v); print v }'
}

images_in() {
  { grep -oE 'image: *"?[^" ]+' || true; } | sed -E 's/image: *"?//'
}

# A reference with both a tag and a digest is pushed under its tag; the copy
# keeps the digest. One with only a digest is pushed by digest.
by_tag() {
  local ref="$1" name="${1%@*}"
  if [[ "$ref" == *@* && "${name##*/}" == *:* ]]; then echo "$name"; else echo "$ref"; fi
}

# The chart rendered as you install it twice: against Diagrid's registries,
# with global.image.registry cleared since a values file written for the
# mirror names the mirror, to find each image; and against the target, to find
# where the install will pull that image from.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
render() {
  helm template catalyst "$CHART" ${CHART_VERSION:+--version "$CHART_VERSION"} \
    ${VALUES_ARGS[@]+"${VALUES_ARGS[@]}"} --set join_token=mirror "$@"
}
if ! render --set global.image.registry= > "$WORK/render.yaml" \
  || ! render --set global.image.registry="$TARGET_REGISTRY" > "$WORK/render-mirror.yaml"; then
  echo -e "${RED}Error: could not render ${CHART}. A chart directory needs \`helm dependency build\` first, or pass --chart oci://public.ecr.aws/diagrid/catalyst --chart-version <version>${NC}" >&2
  exit 1
fi
agent_config < "$WORK/render.yaml" > "$WORK/agent-config.txt"
agent_config < "$WORK/render-mirror.yaml" > "$WORK/agent-config-mirror.txt"
# Where your values leave the Dapr control plane or the JWT key rotation job to
# the agent, the chart's annotations name what the agent deploys. A chart
# released before them lists those two under Runtime Images in its README.
helm show chart "$CHART" ${CHART_VERSION:+--version "$CHART_VERSION"} > "$WORK/chart.yaml"
DAPR_DEFAULT=$(chart_annotation catalyst.diagrid.io/dapr-version < "$WORK/chart.yaml")
ROTATION_DEFAULT=$(chart_annotation catalyst.diagrid.io/jwt-rotation-image < "$WORK/chart.yaml")
agent_images "$WORK/agent-config.txt" "$DAPR_DEFAULT" "$ROTATION_DEFAULT" > "$WORK/agent-images.txt"
agent_images "$WORK/agent-config-mirror.txt" "$DAPR_DEFAULT" "$ROTATION_DEFAULT" > "$WORK/agent-images-mirror.txt"

for section in internal_dapr internal_dapr.sentry.jwt; do
  grep -q "^${section} " "$WORK/agent-images.txt" && continue
  case "$section" in
    internal_dapr) name=dapr ;;
    internal_dapr.sentry.jwt) name=k8s-tools ;;
  esac
  helm show readme "$CHART" ${CHART_VERSION:+--version "$CHART_VERSION"} \
    | awk '/^#+ Runtime Images/ {f = 1; next} /^#+ / {f = 0} f' \
    | { grep -oE '`[^`]+/'"${name}"'[:@][^`]+`' || true; } | tr -d '`' | head -n1 \
    | sed "s|^|${section} |" >> "$WORK/agent-images.txt"
done

# Where an image goes in the target registry: its path on its source registry,
# with Diagrid's registry prefixes dropped. Used only for the images an older
# chart lists in its README, which no render names.
destination() {
  local ref="$1" path first
  case "$ref" in
    # reg-[dp]-common-docker, -docker-public and -docker-hub-proxy
    */reg-[dp]-common-docker*/*) path="${ref#*/reg-[dp]-common-docker*/}" ;;
    */*)
      first="${ref%%/*}"
      if [[ "$first" == *.* || "$first" == *:* || "$first" == localhost ]]; then
        path="${ref#*/}"
      else
        path="$ref"
      fi
      ;;
    *) path="$ref" ;;
  esac
  echo "${TARGET_REGISTRY}/${path#library/}"
}

# Each image paired with where the install pulls it from: a pod-spec image with
# the one in the same place in the render against the target, an agent image
# with the one in the same agent config section. global.image.registry
# replaces an image's whole registry, path included, so the destination cannot
# be worked out from the source alone.
images_in < "$WORK/render.yaml" > "$WORK/pod-images.txt"
images_in < "$WORK/render-mirror.yaml" > "$WORK/pod-images-mirror.txt"
if [[ $(wc -l < "$WORK/pod-images.txt") -ne $(wc -l < "$WORK/pod-images-mirror.txt") ]]; then
  echo -e "${RED}Error: ${CHART} renders a different set of images once global.image.registry is ${TARGET_REGISTRY}, so they cannot be paired${NC}" >&2
  exit 1
fi
{
  paste -d' ' "$WORK/pod-images.txt" "$WORK/pod-images-mirror.txt"
  while read -r section src; do
    dst=$(awk -v s="$section" '$1 == s {print $2; exit}' "$WORK/agent-images-mirror.txt")
    echo "$src ${dst:-$(destination "$src")}"
  done < "$WORK/agent-images.txt"
} > "$WORK/pairs.txt"

# One copy per destination. An image the target render still pulls from
# elsewhere is a subchart's (metrics-server, the OpenTelemetry add-ons), which
# global.image.registry does not reach; one your values already pull from the
# target needs no copy.
SOURCES=()
DESTINATIONS=()
NOT_RELOCATED=()
ALREADY_THERE=()
while read -r src dst; do
  if [[ "$src" == "${TARGET_REGISTRY}/"* ]]; then
    ALREADY_THERE+=("$src")
  elif [[ "$dst" != "${TARGET_REGISTRY}/"* ]]; then
    NOT_RELOCATED+=("$src")
  else
    SOURCES+=("$src")
    DESTINATIONS+=("$(by_tag "$dst")")
  fi
done < <(awk 'NF && !seen[$0]++' "$WORK/pairs.txt")
IMAGES=()
TARGETS=()
for i in "${!SOURCES[@]}"; do
  dup=false
  for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
    [[ "$t" == "${DESTINATIONS[$i]}" ]] && { dup=true; break; }
  done
  $dup && continue
  IMAGES+=("${SOURCES[$i]}")
  TARGETS+=("${DESTINATIONS[$i]}")
done
if [[ ${#IMAGES[@]} -eq 0 && ${#ALREADY_THERE[@]} -eq 0 ]]; then
  echo -e "${RED}Error: the render of ${CHART} names no images${NC}" >&2
  exit 1
fi
# The Dapr chart the agent installs: the version your values pin, else the one
# the chart records, else, in a release that records none, the Dapr image's tag.
DAPR_CHART_VERSION=$(awk -F'\t' '$1 == "internal_dapr.chart_version" {print $2}' "$WORK/agent-config.txt" | tail -n1)
[[ -n "$DAPR_CHART_VERSION" ]] || DAPR_CHART_VERSION="$DAPR_DEFAULT"
[[ -n "$DAPR_CHART_VERSION" ]] || DAPR_CHART_VERSION=$(sed -nE 's|^internal_dapr .*/dapr:([^@]+).*|\1|p' "$WORK/agent-images.txt" | head -n1)

# Function to pull, tag, and push an image
mirror_image() {
  local source_image="$1"
  local target_image="$2"

  echo ""
  echo -e "${YELLOW}=== Processing: ${source_image} ===${NC}"
  
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${BLUE}[DRY RUN] Would pull:  ${source_image}${NC}"
    echo -e "${BLUE}[DRY RUN] Would tag:   ${target_image}${NC}"
    echo -e "${BLUE}[DRY RUN] Would push:  ${target_image}${NC}"
    return 0
  fi
  
  # Pull image
  if [[ "$SKIP_PULL" == "false" ]]; then
    echo -e "${GREEN}Pulling: ${source_image}${NC}"
    case $RUNTIME in
      oras)
        # Checked explicitly: mirror_image runs as an if condition, where
        # set -e does not apply.
        if ! oras cp --recursive "$source_image" "$target_image" \
          || ! copy_legacy_attestations "$source_image" "$target_image"; then
          echo -e "${RED}✗ Failed to copy image${NC}" >&2
          return 1
        fi
        echo -e "${GREEN}✓ Mirrored successfully, with signatures and attestations${NC}"
        return 0
        ;;
      crane)
        if ! crane copy "$source_image" "$target_image"; then
          echo -e "${RED}✗ Failed to copy image${NC}" >&2
          return 1
        fi
        echo -e "${GREEN}✓ Mirrored successfully${NC}"
        return 0
        ;;
      *)
        if ! $RUNTIME pull "$source_image"; then
          echo -e "${RED}✗ Failed to pull image${NC}" >&2
          return 1
        fi
        ;;
    esac
  fi
  
  # Tag image (not needed for oras or crane)
  if [[ "$RUNTIME" != "oras" && "$RUNTIME" != "crane" ]]; then
    echo -e "${GREEN}Tagging: ${target_image}${NC}"
    if ! $RUNTIME tag "$source_image" "$target_image"; then
      echo -e "${RED}✗ Failed to tag image${NC}" >&2
      return 1
    fi
    
    # Push image
    echo -e "${GREEN}Pushing: ${target_image}${NC}"
    if ! $RUNTIME push "$target_image"; then
      echo -e "${RED}✗ Failed to push image${NC}" >&2
      return 1
    fi
    
    echo -e "${GREEN}✓ Mirrored successfully${NC}"
  fi
}

# Main execution
echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          Catalyst Helm Chart Image Mirroring Tool             ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Total images to process: ${#IMAGES[@]}${NC}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo -e "${YELLOW}Running in DRY RUN mode - no changes will be made${NC}"
fi

if [[ "$SKIP_PULL" == "true" ]]; then
  echo -e "${YELLOW}Skipping pull - will only tag and push existing images${NC}"
fi

# Track success/failure
FAILED_IMAGES=()
SUCCESS_COUNT=0

if [[ ${#ALREADY_THERE[@]} -gt 0 ]]; then
  echo ""
  echo -e "${YELLOW}Your values already pull these from ${TARGET_REGISTRY}, so they are not copied; make sure they are there:${NC}"
  printf '  %s\n' "${ALREADY_THERE[@]}"
fi
if [[ ${#NOT_RELOCATED[@]} -gt 0 ]]; then
  echo ""
  echo -e "${YELLOW}global.image.registry does not reach these subchart images, so they are not copied.${NC}"
  echo -e "${YELLOW}Copy them yourself and point the subchart's own image values at ${TARGET_REGISTRY}:${NC}"
  printf '  %s\n' "${NOT_RELOCATED[@]}"
fi

# Process each image
for i in ${IMAGES[@]+"${!IMAGES[@]}"}; do
  if mirror_image "${IMAGES[$i]}" "${TARGETS[$i]}"; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    FAILED_IMAGES+=("${IMAGES[$i]}")
  fi
done

# The agent installs Diagrid's Dapr chart from global.charts.registry, at the
# version found above. It is a chart, not an image, so it is copied with helm.
if [[ -n "$CHARTS_REGISTRY" ]]; then
  echo ""
  if [[ -z "$DAPR_CHART_VERSION" ]]; then
    echo -e "${RED}✗ The chart names no Dapr chart version or dapr image${NC}" >&2
    FAILED_IMAGES+=("${DAPR_CHART_SOURCE} (chart)")
  elif [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${BLUE}[DRY RUN] Would copy chart: ${DAPR_CHART_SOURCE}:${DAPR_CHART_VERSION} -> ${CHARTS_REGISTRY}/dapr${NC}"
  else
    echo -e "${YELLOW}=== Processing chart: ${DAPR_CHART_SOURCE}:${DAPR_CHART_VERSION} ===${NC}"
    CHART_TMP=$(mktemp -d)
    if helm pull "$DAPR_CHART_SOURCE" --version "$DAPR_CHART_VERSION" -d "$CHART_TMP" \
      && helm push "$CHART_TMP/dapr-${DAPR_CHART_VERSION}.tgz" "$CHARTS_REGISTRY"; then
      echo -e "${GREEN}✓ Mirrored chart successfully${NC}"
    else
      echo -e "${RED}✗ Failed to copy the Dapr chart${NC}" >&2
      FAILED_IMAGES+=("${DAPR_CHART_SOURCE}:${DAPR_CHART_VERSION} (chart)")
    fi
    rm -rf "$CHART_TMP"
  fi
fi

# Print summary
echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                          Summary                          ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Successful: ${SUCCESS_COUNT}/${#IMAGES[@]}${NC}"

if [[ ${#FAILED_IMAGES[@]} -gt 0 ]]; then
  echo -e "${RED}Failed: ${#FAILED_IMAGES[@]}${NC}"
  echo ""
  echo -e "${RED}Failed images:${NC}"
  for image in "${FAILED_IMAGES[@]}"; do
    echo -e "  ${RED}- ${image}${NC}"
  done
  exit 1
fi

if [[ "$DRY_RUN" == "false" ]]; then
  echo ""
  echo -e "${GREEN}✓ All images mirrored successfully!${NC}"
  echo ""
  echo -e "${BLUE}Next steps:${NC}"
  echo -e "  1. Update your values.yaml with:"
  echo -e "     ${YELLOW}global:${NC}"
  echo -e "       ${YELLOW}image:${NC}"
  echo -e "         ${YELLOW}registry: ${TARGET_REGISTRY}${NC}"
  if [[ -n "$CHARTS_REGISTRY" ]]; then
    echo -e "       ${YELLOW}charts:${NC}"
    echo -e "         ${YELLOW}registry: ${CHARTS_REGISTRY}${NC}"
  fi
  echo ""
  echo -e "  2. Install the Helm chart:"
  echo -e "     ${YELLOW}helm install catalyst ./charts/catalyst -f values.yaml${NC}"
fi

echo ""
