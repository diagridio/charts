#!/bin/bash
set -e

# Default values
CHART_DIR="${CHART_DIR:-charts/catalyst}"
CHART_NAME=$(yq '.name' "$CHART_DIR/Chart.yaml" -r)
DRY_RUN="${DRY_RUN:-false}"

# Ensure required tools are available
command -v yq >/dev/null 2>&1 || { echo "Error: yq is required but not installed."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "Error: helm is required but not installed."; exit 1; }
command -v git >/dev/null 2>&1 || { echo "Error: git is required but not installed."; exit 1; }

# Check required environment variables
[ -z "$BRANCH" ] && { echo "Error: BRANCH environment variable is required."; exit 1; }
[ -z "$CHART_NAME" ] && { echo "Error: CHART_NAME environment variable is required."; exit 1; }
[ -z "$CHART_REGISTRY" ] && { echo "Error: CHART_REGISTRY environment variable is required."; exit 1; }
[ -z "$CHART_ALIAS" ] && { echo "Error: CHART_ALIAS environment variable is required."; exit 1; }

# Set up variables
OCI_URI="oci://${CHART_REGISTRY}/${CHART_ALIAS}/"

# Temporary file for Chart.yaml diff
TEMP_CHART_YAML=$(mktemp)

# Cleanup function
cleanup() {
  rm -f "$TEMP_CHART_YAML"
  [ "$DRY_RUN" = "true" ] || rm -rf ./packaged
}
trap cleanup EXIT

# Copy original Chart.yaml for diff
cp "$CHART_DIR/Chart.yaml" "$TEMP_CHART_YAML"

# Determine version based on branch
if [ "$BRANCH" = "main" ]; then
  echo "Packaging edge version from main"
  VERSION="0.0.0-edge"
  yq -i ".version = \"$VERSION\"" "$TEMP_CHART_YAML"
else
  if [[ "$BRANCH" =~ ^release-([0-9]+)\.([0-9]+)$ ]]; then
    MAJOR="${BASH_REMATCH[1]}"
    MINOR="${BASH_REMATCH[2]}"
    echo "Packaging release version for $BRANCH"

    # Find the latest patch version for this major.minor from git tags
    LATEST_TAG=$(git tag -l "${MAJOR}.${MINOR}.*" | sort -V | tail -n1)
    if [ -z "$LATEST_TAG" ]; then
      PATCH=0 # Start at 0 if no prior tags exist
    else
      PATCH=$(echo "$LATEST_TAG" | cut -d'.' -f3)
      PATCH=$((PATCH + 1)) # Increment patch
    fi

    VERSION="${MAJOR}.${MINOR}.${PATCH}"
    echo "New version: $VERSION"
    yq -i ".version = \"$VERSION\"" "$TEMP_CHART_YAML"
  else
    [ -z "$CHART_VERSION" ] && { echo "Error: CHART_VERSION environment variable is required."; exit 1; }
    VERSION="$CHART_VERSION"
  fi
fi

# Show diff if DRY_RUN is true
if [ "$DRY_RUN" = "true" ]; then
  echo "Dry run: Showing diff for Chart.yaml"
  diff "$CHART_DIR/Chart.yaml" "$TEMP_CHART_YAML" || true
  echo "Dry run: Would package $CHART_NAME-$VERSION and push to $OCI_URI"
  exit 0
fi

# Apply changes to Chart.yaml
mv "$TEMP_CHART_YAML" "$CHART_DIR/Chart.yaml"

# Package the Helm chart
export VERSION=$VERSION
export CHART_NAME=$CHART_NAME
export CHART_DIR=$CHART_DIR

make helm-prereqs
make helm-package

# Push the chart to OCI
CHART_FILE="./${CHART_DIR}/dist/${CHART_NAME}-${VERSION}.tgz"
echo "Pushing $CHART_FILE to $OCI_URI"
helm push "$CHART_FILE" "$OCI_URI"

# If it's a release branch, set an output variable for the version
if [ "$BRANCH" != "main" ]; then
  echo "Setting VERSION=$VERSION for downstream steps"
  echo "VERSION=$VERSION" >> "$GITHUB_ENV" # For GitHub Actions
fi
