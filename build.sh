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
  git -C "$KLANGK_DIR" reset --hard HEAD
  git -C "$KLANGK_DIR" clean -fd
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

# 2. Detect whether we need to layer CA certs onto the workspace image later
HAVE_CUSTOM_CERTS=false
if ls "$SSL_CERT_DIR"/*.pem 2>/dev/null || ls "$SSL_CERT_DIR"/*.crt 2>/dev/null; then
  HAVE_CUSTOM_CERTS=true
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

  # Layer custom CA certs onto the workspace image if present
  WORKSPACE_IMAGE=\"\${KLANGK_IMAGE_NAME:-klangk-workspace}\"
  PODMAN=\"\${KLANGK_PODMAN_BIN:-podman}\"
  POLICY_ARGS=()
  if [ -n \"\${KLANGK_SIGNATURE_POLICY:-}\" ]; then
    POLICY_ARGS+=(--signature-policy \"\${KLANGK_SIGNATURE_POLICY}\")
  fi
  if [ '$HAVE_CUSTOM_CERTS' = true ]; then
    echo '--- Layering custom CA certs onto workspace image ---'
    WS_CERT_DIR=\$(mktemp -d)
    trap 'rm -rf \"\$WS_CERT_DIR\"' EXIT
    cp '$SSL_CERT_DIR'/*.pem \"\$WS_CERT_DIR/\" 2>/dev/null || true
    cp '$SSL_CERT_DIR'/*.crt \"\$WS_CERT_DIR/\" 2>/dev/null || true
    cat > \"\$WS_CERT_DIR/Dockerfile\" <<'CERTDF'
ARG BASE
FROM \$BASE
COPY *.pem *.crt /tmp/ssl/
USER root
RUN cp /tmp/ssl/*.pem /usr/local/share/ca-certificates/ 2>/dev/null; \
    cp /tmp/ssl/*.crt /usr/local/share/ca-certificates/ 2>/dev/null; \
    for f in /usr/local/share/ca-certificates/*.pem; do \
      [ -f \"\$f\" ] && mv \"\$f\" \"\${f%.pem}.crt\"; \
    done; \
    update-ca-certificates && \
    rm -rf /tmp/ssl
USER klangk
CERTDF
    \"\$PODMAN\" build \"\${POLICY_ARGS[@]}\" \
      --build-arg BASE=\"\$WORKSPACE_IMAGE\" \
      -t \"\$WORKSPACE_IMAGE:latest\" \
      \"\$WS_CERT_DIR\"
  fi

  # Export workspace image as tarball
  echo '--- Exporting workspace image ---'
  \"\$PODMAN\" save \"\${POLICY_ARGS[@]}\" -o '$WORKSPACE_DIR/workspace.tar' \"\$WORKSPACE_IMAGE\"

  # Build host image from source (provides up-to-date backend code)
  echo '--- Building host image from source ---'
  bash scripts/build-host-image.sh
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
