#!/usr/bin/env bash

#
# Mirror Catalyst Helm Chart Images
#
# This script pulls all images used by the Catalyst Helm chart from their default
# registries and pushes them to a target registry with the same repository paths
# and tags preserved.
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
#   --piko-version VERSION        Piko version (default: v0.8.1)
#   --k0s-version VERSION         k0s version (default: v1.26.0-k0s.0)
#   --coredns-version VERSION     CoreDNS version (default: 1.10.1)
#   --dry-run                     Print what would be done without executing
#   --skip-pull                   Skip pulling images, only tag and push
#
# Examples:
#   ./mirror-images.sh my-registry.example.com
#   ./mirror-images.sh my-registry.example.com --catalyst-version 0.470.0
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
DAPR_VERSION="1.16.1"
INTERNAL_DAPR_VERSION="1.16.2-rc.1-catalyst.2"
ENVOY_VERSION="distroless-v1.33.0"
PIKO_VERSION="v0.8.1"
K0S_VERSION="v1.26.0-k0s.0"
COREDNS_VERSION="1.10.1"

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
    --k0s-version)
      K0S_VERSION="$2"
      shift 2
      ;;
    --coredns-version)
      COREDNS_VERSION="$2"
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

# Detect container runtime
if command -v docker &> /dev/null; then
  RUNTIME="docker"
elif command -v podman &> /dev/null; then
  RUNTIME="podman"
elif command -v crane &> /dev/null; then
  RUNTIME="crane"
else
  echo -e "${RED}Error: No container runtime found. Please install docker, podman, or crane.${NC}" >&2
  exit 1
fi

echo -e "${BLUE}Using container runtime: ${RUNTIME}${NC}"
echo -e "${BLUE}Target registry: ${TARGET_REGISTRY}${NC}"
echo -e "${BLUE}Catalyst version: ${CATALYST_VERSION}${NC}"
echo -e "${BLUE}Dapr version: ${DAPR_VERSION}${NC}"
echo -e "${BLUE}Internal Dapr version: ${INTERNAL_DAPR_VERSION}${NC}"

# Define all images from the Catalyst Helm chart
# Format: "SOURCE_IMAGE"
declare -a IMAGES=(
  # Primary Component Images (Default Mode)
  "us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/cra-agent:${CATALYST_VERSION}"
  "us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/catalyst-management:${CATALYST_VERSION}"
  "us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/catalyst-gateway:${CATALYST_VERSION}"
  "us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/identity-injector:${CATALYST_VERSION}"
  "us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-hub-proxy/k0sproject/k0s:${K0S_VERSION}"
  "us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-hub-proxy/coredns/coredns:${COREDNS_VERSION}"

  # Consolidated Image (Alternative Mode)
  "us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/catalyst-all:${CATALYST_VERSION}"
  
  # External Component Images
  "us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-hub-proxy/envoyproxy/envoy:${ENVOY_VERSION}"
  "ghcr.io/andydunstall/piko:${PIKO_VERSION}"
  
  # Agent Nested Images
  "us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/sidecar:${CATALYST_VERSION}"
  "us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/diagrid-otel-collector:${CATALYST_VERSION}"
  
  # Upstream Dapr Images
  "us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-hub-proxy/daprio/dapr:${DAPR_VERSION}"
  
  # Internal Dapr Images
  "us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/dapr:${INTERNAL_DAPR_VERSION}"
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
      crane)
        crane pull "$source_image" - | crane push - "$target_image"
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
  
  # Tag image (not needed for crane)
  if [[ "$RUNTIME" != "crane" ]]; then
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
