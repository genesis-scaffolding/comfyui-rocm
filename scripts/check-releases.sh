#!/bin/bash
#
# Compare the upstream ComfyUI latest release against our local git tag
# list. Prints whether the CI will trigger a new build on its next run.
#
# Usage: scripts/check-releases.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo -e "${GREEN}comfyui-rocm release checker${NC}"
echo "=============================="
echo

echo "Checking Comfy-Org/ComfyUI for the latest release..."
LATEST_JSON=$(curl -sSf https://api.github.com/repos/Comfy-Org/ComfyUI/releases/latest)
UPSTREAM_TAG=$(echo "$LATEST_JSON" | jq -r '.tag_name')
UPSTREAM_DATE=$(echo "$LATEST_JSON" | jq -r '.published_at')

echo -e "  Latest upstream: ${GREEN}${UPSTREAM_TAG}${NC}"
echo "  Published at:    ${UPSTREAM_DATE}"
echo

# The CI uses the upstream tag as the local git tag, so the most
# recent vX.Y.Z tag in this repo is what we've already built.
OUR_TAG=$(git tag --list 'v*' 2>/dev/null | sort -V | tail -1 || true)

if [ -z "${OUR_TAG:-}" ]; then
    echo -e "${YELLOW}No prior build tags found in this repo.${NC}"
    echo "The next scheduled CI run will build ${UPSTREAM_TAG}."
    exit 0
fi

echo -e "  Latest local:   ${GREEN}${OUR_TAG}${NC}"
echo

if [ "$UPSTREAM_TAG" = "$OUR_TAG" ]; then
    echo -e "${GREEN}✓ Up to date!${NC} The latest upstream release has already been built."
    echo
    echo "To force a rebuild anyway, trigger the workflow manually:"
    echo "  https://github.com/genesis-scaffolding/comfyui-rocm/actions/workflows/build.yml"
else
    echo -e "${YELLOW}⚠ Update available.${NC}"
    echo "  Upstream is at ${UPSTREAM_TAG}, we're at ${OUR_TAG}."
    echo "  The next scheduled CI run (within 24h) will pick this up,"
    echo "  or trigger manually to build now."
fi

echo
echo "Links:"
echo "  Upstream: https://github.com/Comfy-Org/ComfyUI/releases/tag/${UPSTREAM_TAG}"
if [ -n "${OUR_TAG:-}" ]; then
    echo "  Ours:     https://github.com/genesis-scaffolding/comfyui-rocm/releases/tag/${OUR_TAG}"
fi
