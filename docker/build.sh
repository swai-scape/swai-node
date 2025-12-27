#!/bin/bash
# Build script for SwaiNode Docker image
#
# Prerequisites:
#   1. Create a GitHub Personal Access Token (classic) at:
#      https://github.com/settings/tokens
#
#   2. Required scopes:
#      - repo (Full control of private repositories)
#
#   3. Export the token in ~/.zshrc or ~/.bashrc:
#      export MACULA_BUILD_GIT_TOKEN=ghp_your_token_here
#
# Usage:
#   ./build.sh   # Build with MACULA_BUILD_GIT_TOKEN from environment

set -e

cd "$(dirname "$0")/.."

# Check for MACULA_BUILD_GIT_TOKEN
if [ -z "$MACULA_BUILD_GIT_TOKEN" ]; then
    echo "Error: MACULA_BUILD_GIT_TOKEN environment variable is not set"
    echo ""
    echo "To create a token:"
    echo "  1. Go to https://github.com/settings/tokens"
    echo "  2. Click 'Generate new token (classic)'"
    echo "  3. Select 'repo' scope"
    echo "  4. Add to ~/.zshrc:"
    echo "     export MACULA_BUILD_GIT_TOKEN=ghp_your_token_here"
    echo ""
    exit 1
fi

# Export as GITHUB_TOKEN for Docker secret
export GITHUB_TOKEN="$MACULA_BUILD_GIT_TOKEN"

echo "Building SwaiNode Docker image..."
echo "Using hex.pm packages:"
echo "  - macula ~> 0.16.0"
echo "  - macula_neuroevolution ~> 0.25.0"
echo "  - macula_tweann ~> 0.18.0"
echo "  - erl_esdb ~> 0.4.6"
echo "  - erl_evoq ~> 0.3.0"
echo "Using git dependencies:"
echo "  - macula-nn-nifs v0.2.0 (private, via GITHUB_TOKEN)"
echo "  - erl-esdb-nifs (private, via GITHUB_TOKEN)"
echo ""

DOCKER_BUILDKIT=1 docker build \
    --secret id=github_token,env=GITHUB_TOKEN \
    --build-arg CACHE_BUST=$(date +%s) \
    --build-arg BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
    --build-arg VCS_REF=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown") \
    -t swai-node:latest \
    -f docker/Dockerfile \
    .

echo ""
echo "Build complete!"
echo "Image: swai-node:latest"
echo ""
echo "To run locally:"
echo "  docker run -p 4000:4000 swai-node:latest"
