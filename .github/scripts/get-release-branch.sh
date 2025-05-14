#!/bin/bash
set -e

# Ensure required tools are available
command -v yq >/dev/null 2>&1 || { echo "Error: yq is required but not installed."; exit 1; }

# Get current version from Chart.yaml
CURRENT_VERSION=$(yq -r '.version' ./charts/catalyst/Chart.yaml)
MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
RELEASE_BRANCH="release-${MAJOR}.${MINOR}"

echo "Setting RELEASE_BRANCH=$RELEASE_BRANCH for downstream steps"
echo "RELEASE_BRANCH=$RELEASE_BRANCH" >> "$GITHUB_ENV" # For GitHub Actions
