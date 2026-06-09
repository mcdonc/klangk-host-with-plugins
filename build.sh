#!/usr/bin/env bash
# Build a custom klangk-host image with plugins baked in.
#
# Prerequisites:
#   - Nix with devenv installed (or run klangk's ./bootstrap)
#   - Docker
#   - SSH key with access to git repos in plugins.yaml
#
# Usage:
#   ./build.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

KLANGK_REF="${KLANGK_REF:-main}"
KLANGK_REPO="${KLANGK_REPO:-https://github.com/mcdonc/klangk.git}"
KLANGK_DIR="$SCRIPT_DIR/.klangk"
WORKSPACE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/klangk-ws-XXXXXX")
trap 'rm -rf "$WORKSPACE_DIR"' EXIT

# 1. Clone or update klangk repo
echo "=== Cloning klangk ($KLANGK_REF) ==="
if [ -d "$KLANGK_DIR/.git" ]; then
  git -C "$KLANGK_DIR" fetch origin --tags
  git -C "$KLANGK_DIR" checkout "$KLANGK_REF"
  # Pull only if on a branch (not a detached tag/SHA)
  if git -C "$KLANGK_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
    git -C "$KLANGK_DIR" pull --ff-only || true
  fi
else
  git clone "$KLANGK_REPO" "$KLANGK_DIR"
  git -C "$KLANGK_DIR" checkout "$KLANGK_REF"
fi

# 2. Install plugins into a staging directory
PLUGINS_DIR="$SCRIPT_DIR/.plugins"
echo "=== Fetching plugins ==="
rm -rf "$PLUGINS_DIR"
mkdir -p "$PLUGINS_DIR"
cp "$SCRIPT_DIR/plugins.yaml" "$PLUGINS_DIR/plugins.yaml"

cd "$KLANGK_DIR"

# Run everything inside devenv shell for access to flutter, podman, python, etc.
devenv shell -- bash -c "
  set -euo pipefail
  export KLANGK_PLUGINS_DIR='$PLUGINS_DIR'

  # Fetch plugins
  echo '--- Fetching plugins ---'
  python3 scripts/update_plugins.py

  # Build Flutter web (imports Dart plugins, rebuilds frontend)
  echo '--- Building Flutter web ---'
  bash scripts/flutterbuildweb.sh

  # Build workspace image (stages extensions/tools, builds image)
  echo '--- Building workspace image ---'
  bash scripts/build-workspace-image.sh

  # Export workspace image as tarball
  WORKSPACE_IMAGE=\"\${KLANGK_IMAGE_NAME:-klangk-workspace}\"
  PODMAN=\"\${KLANGK_PODMAN_BIN:-podman}\"
  POLICY_ARGS=()
  if [ -n \"\${KLANGK_SIGNATURE_POLICY:-}\" ]; then
    POLICY_ARGS+=(--signature-policy \"\${KLANGK_SIGNATURE_POLICY}\")
  fi
  echo '--- Exporting workspace image ---'
  \"\$PODMAN\" save \"\${POLICY_ARGS[@]}\" -o '$WORKSPACE_DIR/workspace.tar' \"\$WORKSPACE_IMAGE\"
"

# 3. Copy Flutter web build output to this directory for Docker context
echo "=== Preparing Docker build context ==="
rm -rf "$SCRIPT_DIR/web"
cp -r "$KLANGK_DIR/src/frontend/build/web" "$SCRIPT_DIR/web"

# 4. Build the custom host image
echo "=== Building custom host image ==="
IMAGE="${KLANGK_HOST_IMAGE:-ghcr.io/mcdonc/klangk/klangk-host-custom}"

cd "$SCRIPT_DIR"
docker build \
  --platform "${KLANGK_PLATFORM:-linux/amd64}" \
  -f Dockerfile \
  --build-context "workspace-tar=$WORKSPACE_DIR" \
  -t "$IMAGE:latest" \
  .

# Cleanup build artifacts
rm -rf "$SCRIPT_DIR/web"

echo "=== Done. Image: $IMAGE ==="
docker images "$IMAGE" --format "  {{.Tag}}\t{{.Size}}"
