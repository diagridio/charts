#!/usr/bin/env bash

#
# Mirror Catalyst Helm Chart Images
#
# This script pulls all images used by the Catalyst Helm chart from their default
# registries and pushes them to a target registry with the same repository paths
# and tags preserved.
#
# Released Catalyst charts pin every Diagrid image by digest, resolved from
# the production registry below, so the mirror has to hold the same manifests
# as that registry. ORAS is preferred when it is installed: `oras cp
# --recursive` preserves digests and also copies each image's signature, build
# provenance and SBOMs, so the mirror can be verified (see
# guides/image-verification). ORAS also needs jq, to find the per-architecture
# images whose legacy attestation tags it copies. crane also preserves digests but copies the image
# alone. docker and podman re-push through the local daemon, which can
# re-encode layers and change digests, and a digest-pinned chart then fails to
# pull from the mirror.
#
# Usage:
#   ./mirror-images.sh <target-registry> [OPTIONS]
#
# Arguments:
#   target-registry: The destination registry (e.g., my-registry.example.com)
#
# Options:
#   --catalyst-version VERSION    Catalyst image version (default: 0.469.0)
#   --dapr-version VERSION        Dapr version (default: 1.16.2)
#   --internal-dapr-version VERSION  Internal Dapr version (default: 1.16.2-rc.1-catalyst.2)
#   --envoy-version VERSION       Envoy version (default: distroless-v1.33.0)
#   --piko-version VERSION        Piko version (default: v0.8.2)
#   --otel-version VERSION        OpenTelemetry Collector version (default: 0.112.0)
#   --dry-run                     Print what would be done without executing
#   --skip-pull                   Skip pulling images, only tag and push
#
# Examples:
#   ./mirror-images.sh my-registry.example.com
#   ./mirror-images.sh my-registry.example.com --catalyst-version 0.470.0
#   ./mirror-images.sh my-registry.example.com --otel-version 0.112.0
#   ./mirror-images.sh my-registry.example.com --dry-run
#   ./mirror-images.sh my-registry.example.com --skip-pull
#
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default options
DRY_RUN=false
SKIP_PULL=false
TARGET_REGISTRY=""

# Default versions(these won't be updated frequently and should be passed explicitly)
CATALYST_VERSION="0.469.0"
DAPR_VERSION="1.16.2"
INTERNAL_DAPR_VERSION="1.16.2-catalyst.3"
ENVOY_VERSION="distroless-v1.33.0"
PIKO_VERSION="v0.8.2"
OTEL_VERSION="0.112.0"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --catalyst-version)
      CATALYST_VERSION="$2"
      shift 2
      ;;
    --dapr-version)
      DAPR_VERSION="$2"
      shift 2
      ;;
    --internal-dapr-version)
      INTERNAL_DAPR_VERSION="$2"
      shift 2
      ;;
    --envoy-version)
      ENVOY_VERSION="$2"
      shift 2
      ;;
    --piko-version)
      PIKO_VERSION="$2"
      shift 2
      ;;
    --otel-version)
      OTEL_VERSION="$2"
      shift 2
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
  echo "Usage: $0 <target-registry> [--dry-run] [--skip-pull]" >&2
  exit 1
fi

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
echo -e "${BLUE}Catalyst version: ${CATALYST_VERSION}${NC}"
echo -e "${BLUE}Dapr version: ${DAPR_VERSION}${NC}"
echo -e "${BLUE}Internal Dapr version: ${INTERNAL_DAPR_VERSION}${NC}"
echo -e "${BLUE}OpenTelemetry Collector version: ${OTEL_VERSION}${NC}"

# The registries the released chart's defaults name: Diagrid's production
# public registry, whose digests the release pipeline pins and signs, and
# Diagrid's production Docker Hub proxy for third-party images.
DIAGRID_REGISTRY="us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public"
DOCKER_HUB_PROXY="us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-hub-proxy"

# Define all images from the Catalyst Helm chart
# Format: "SOURCE_IMAGE"
#
# The Diagrid-built entries must stay aligned with the release image table in
# deploy/tools/pkg/catalystimages, which is what the release pipeline pins by
# digest. An image in that table and missing here mirrors to nothing, and the
# released chart then fails against the mirror with "manifest unknown".
declare -a IMAGES=(
  # Primary Component Images (Default Mode)
  "${DIAGRID_REGISTRY}/cra-agent:${CATALYST_VERSION}"
  "${DIAGRID_REGISTRY}/catalyst-management:${CATALYST_VERSION}"
  "${DIAGRID_REGISTRY}/catalyst-gateway:${CATALYST_VERSION}"
  "${DIAGRID_REGISTRY}/identity-injector:${CATALYST_VERSION}"
  "${DIAGRID_REGISTRY}/catalyst-mcp:${CATALYST_VERSION}"

  # Consolidated Image (Alternative Mode)
  "${DIAGRID_REGISTRY}/catalyst-all:${CATALYST_VERSION}"
  
  # External Component Images
  "${DOCKER_HUB_PROXY}/envoyproxy/envoy:${ENVOY_VERSION}"
  "${DIAGRID_REGISTRY}/diagrid-piko:${PIKO_VERSION}"
  
  # OpenTelemetry Collector Images (Optional)
  "ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-k8s:${OTEL_VERSION}"
  
  # Agent Nested Images
  "${DIAGRID_REGISTRY}/sidecar:${CATALYST_VERSION}"
  "${DIAGRID_REGISTRY}/catalyst-otel-collector:${CATALYST_VERSION}"
  "${DIAGRID_REGISTRY}/private-sentry:${CATALYST_VERSION}"
  
  # Upstream Dapr Images
  "${DOCKER_HUB_PROXY}/daprio/dapr:${DAPR_VERSION}"
  
  # Internal Dapr Images
  "${DIAGRID_REGISTRY}/dapr:${INTERNAL_DAPR_VERSION}"
)

# Function to extract repository path and tag from full image reference
extract_repo_and_tag() {
  local image="$1"
  local image_name_tag="${image##*/}"
  echo "$image_name_tag"
}

# Function to pull, tag, and push an image
mirror_image() {
  local source_image="$1"
  local repo_and_tag
  repo_and_tag=$(extract_repo_and_tag "$source_image")
  local target_image="${TARGET_REGISTRY}/${repo_and_tag}"
  
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

# Process each image
for image in "${IMAGES[@]}"; do
  if mirror_image "$image"; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    FAILED_IMAGES+=("$image")
  fi
done

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
  echo ""
  echo -e "  2. Install the Helm chart:"
  echo -e "     ${YELLOW}helm install catalyst ./charts/catalyst -f values.yaml${NC}"
fi

echo ""
