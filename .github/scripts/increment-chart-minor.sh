#!/bin/bash
set -e

# Ensure required tools are available
command -v yq >/dev/null 2>&1 || { echo "Error: yq is required but not installed."; exit 1; }

CURRENT_VERSION=$(yq -r '.version' ./charts/catalyst/Chart.yaml)
MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
NEW_MINOR=$((MINOR + 1))
NEW_VERSION="$MAJOR.$NEW_MINOR.0"

yq -i ".version = \"$NEW_VERSION\"" ./charts/catalyst/Chart.yaml

echo "Chart version updated to $NEW_VERSION"
