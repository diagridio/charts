#!/bin/bash

set -e

export NEW_VERSION=$VERSION

if [[ -z "$NEW_VERSION" ]]; then
    echo "Error: VERSION environment variable is not set."
    usage
fi

if [[ ! "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$ ]]; then
    echo "Error: Version must be in semantic version format (e.g., 1.0.0, 1.0.0-beta, 1.0.0-edge)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUIDES_DIR="$PROJECT_ROOT/guides"

echo "Updating version to: $NEW_VERSION"
echo "Searching for README.md files in: $GUIDES_DIR"

if [[ ! -d "$GUIDES_DIR" ]]; then
    echo "Error: Guides directory not found at $GUIDES_DIR"
    exit 1
fi

# Find all README.md files under the direct subdirectories of guides (not in nested terraform modules)
README_FILES=$(find "$GUIDES_DIR" -maxdepth 2 -name "README.md" -type f)

if [[ -z "$README_FILES" ]]; then
    echo "No README.md files found in the guides directory"
    exit 0
fi

UPDATED_COUNT=0

# Process each README.md file
while IFS= read -r file; do
    echo "Processing: $file"
    
    # Check if the file contains --version pattern (including edge versions)
    if grep -q "\-\-version [0-9]" "$file"; then
        cp "$file" "${file}.bak"
        
        sed -i.tmp "s/--version [0-9.a-zA-Z-]*/--version $NEW_VERSION/g" "$file"
        
        rm -f "${file}.tmp"
        
        if ! cmp -s "$file" "${file}.bak"; then
            echo "  ✓ Updated version in $file"
            UPDATED_COUNT=$((UPDATED_COUNT + 1))
        else
            echo "  - No changes needed in $file"
        fi
        
        rm -f "${file}.bak"
    else
        echo "  - No --version pattern found in $file"
    fi
done <<< "$README_FILES"

echo ""
echo "Summary:"
echo "- Total README.md files found: $(echo "$README_FILES" | wc -l | tr -d ' ')"
echo "- Files updated: $UPDATED_COUNT"
echo "- New version: $NEW_VERSION"

if [[ $UPDATED_COUNT -gt 0 ]]; then
    echo ""
    echo "Version update completed successfully!"
else
    echo ""
    echo "No files were updated. This might be because:"
    echo "  - The files already have the target version"
    echo "  - No --version patterns were found in the README files"
fi