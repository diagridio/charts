#!/bin/bash
set -e

# Default values
PATCH_CATALYST_CHART="${PATCH_CATALYST_CHART:-false}"
BASE_RELEASE_VERSION="${BASE_RELEASE_VERSION:-}"
# Ensure required tools are available
command -v git >/dev/null 2>&1 || { echo "Error: git is required but not installed."; exit 1; }

# get latest release branch
BASE_RELEASE_BRANCH=$(git branch -l "release-*" | sort -V | tail -n1)

if [ -z "$BASE_RELEASE_VERSION" ]; then
    echo "No base release version provided, using latest release branch"
else
    echo "Using base release version: $BASE_RELEASE_VERSION"
    if [[ "$BASE_RELEASE_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        MAJOR="${BASH_REMATCH[1]}"
        MINOR="${BASH_REMATCH[2]}"
        BASE_RELEASE_BRANCH="release-${MAJOR}.${MINOR}"
    else
        echo "Error: BASE_RELEASE_VERSION does not match expected pattern e.g. 0.3.0"
        exit 1
    fi
fi

# Determine version based on branch
if [[ "$BASE_RELEASE_BRANCH" =~ ^release-([0-9]+)\.([0-9]+)$ ]]; then
  MAJOR="${BASH_REMATCH[1]}"
  MINOR="${BASH_REMATCH[2]}"
  echo "Latest release branch: $BASE_RELEASE_BRANCH"

  if [ "$PATCH_CATALYST_CHART" = "false" ]; then
    echo "Patching existing release"
    # increment minor version
    MINOR=$((MINOR + 1))
  fi

  # Find the latest patch version for this major.minor from git tags
  LATEST_TAG=$(git tag -l "${MAJOR}.${MINOR}.*" | sort -V | tail -n1)
  if [ -z "$LATEST_TAG" ]; then
      PATCH=0 # Start at 0 if no prior tags exist
  else
      PATCH=$(echo "$LATEST_TAG" | cut -d'.' -f3)
      PATCH=$((PATCH + 1)) # Increment patch
  fi

  VERSION="${MAJOR}.${MINOR}.${PATCH}"
  echo "Setting VERSION=$VERSION for downstream steps"
  echo "VERSION=$VERSION" >> "$GITHUB_ENV" # For GitHub Actions

  RELEASE_BRANCH="release-${MAJOR}.${MINOR}"
  echo "Setting RELEASE_BRANCH=$RELEASE_BRANCH for downstream steps"
  echo "RELEASE_BRANCH=$RELEASE_BRANCH" >> "$GITHUB_ENV" # For GitHub Actions
else
  echo "Error: Branch $BRANCH does not match expected pattern"
  exit 1
fi