#!/bin/bash
set -e

# Default values
DRY_RUN="${DRY_RUN:-false}"

# Ensure required tools are available
command -v yq >/dev/null 2>&1 || { echo "Error: yq is required but not installed."; exit 1; }
command -v git >/dev/null 2>&1 || { echo "Error: git is required but not installed."; exit 1; }

# Get current version from Chart.yaml
CURRENT_VERSION=$(yq -r '.version' ./charts/catalyst/Chart.yaml)
MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)

if [ "$DRY_RUN" = "true" ]; then
  echo "Dry run: Would create release branch release-${MAJOR}.${MINOR}"
  exit 0
fi

git checkout -b release-${MAJOR}.${MINOR}
git push origin release-${MAJOR}.${MINOR}

echo "Release branch created: release-${MAJOR}.${MINOR}"
