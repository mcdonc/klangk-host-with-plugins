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
#
# Optional:
#   KLANGK_SSL_CERT_DIR=./ssl  ./build.sh   # inject custom CA certs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

KLANGK_REF="${KLANGK_REF:-main}"
KLANGK_REPO="${KLANGK_REPO:-https://github.com/mcdonc/klangk.git}"
KLANGK_DIR="$SCRIPT_DIR/.klangk"
SSL_CERT_DIR="${KLANGK_SSL_CERT_DIR:-$SCRIPT_DIR/ssl}"
WORKSPACE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/klangk-ws-XXXXXX")
trap 'rm -rf "$WORKSPACE_DIR"' EXIT

# Ensure ssl/ dir exists for COPY (even if empty)
mkdir -p "$SCRIPT_DIR/ssl"

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

# 2. If custom CA certs are provided, patch the workspace Dockerfile to include them
if ls "$SSL_CERT_DIR"/*.pem 1>/dev/null 2>&1; then
  echo "=== Injecting custom CA certs into workspace image ==="
  WORKSPACE_SSL_DIR="$KLANGK_DIR/src/containers/workspace/ssl"
  mkdir -p "$WORKSPACE_SSL_DIR"
  cp "$SSL_CERT_DIR"/*.pem "$WORKSPACE_SSL_DIR/"

  # Append cert installation to the workspace Dockerfile if not already patched
  WS_DOCKERFILE="$KLANGK_DIR/src/containers/workspace/Dockerfile"
  if ! grep -q 'custom CA certs' "$WS_DOCKERFILE"; then
    cat >> "$WS_DOCKERFILE" <<'PATCH'

# Inject custom CA certs
COPY ssl/ /tmp/ssl/
USER root
RUN cp /tmp/ssl/*.pem /usr/local/share/ca-certificates/ && \
    for f in /usr/local/share/ca-certificates/*.pem; do \
      mv "$f" "${f%.pem}.crt"; \
    done && \
    update-ca-certificates && \
    rm -rf /tmp/ssl
USER clanker
PATCH
  fi
fi

# 3. Install plugins into a staging directory
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

# 4. Copy Flutter web build output to this directory for Docker context
echo "=== Preparing Docker build context ==="
rm -rf "$SCRIPT_DIR/web"
cp -r "$KLANGK_DIR/src/frontend/build/web" "$SCRIPT_DIR/web"

# 5. Build the custom host image
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
