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
#   # build based on v2026.06.10 Klangk release, otherwise build based on main
#   KLANGK_REF=v2026.06.10 ./build.sh
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

# 2. Apply branding overlay (replaces the upstream logo widget + ships logo asset).
# Runs after the git reset/clean so our changes are re-applied on every build.
echo "=== Applying branding overlay ==="
BRANDING_ASSET_DIR="$KLANGK_DIR/src/frontend/assets/branding"
mkdir -p "$BRANDING_ASSET_DIR"
cp "$SCRIPT_DIR/logo.png" "$BRANDING_ASSET_DIR/logo.png"
cp "$SCRIPT_DIR/klangk_logo.dart" \
   "$KLANGK_DIR/src/frontend/lib/widgets/klangk_logo.dart"
# Upstream test asserts the old procedurally-drawn widget; drop it.
rm -f "$KLANGK_DIR/src/frontend/test/klangk_logo_test.dart"
# Register the branding asset dir in pubspec.yaml if not already declared.
PUBSPEC="$KLANGK_DIR/src/frontend/pubspec.yaml"
if ! grep -q "assets/branding/" "$PUBSPEC"; then
  sed -i '/^    - assets\/fonts\//a\    - assets/branding/' "$PUBSPEC"
fi

# 3. Install plugins into a staging directory
PLUGINS_DIR="$SCRIPT_DIR/.plugins"
echo "=== Fetching plugins ==="
rm -rf "$PLUGINS_DIR"
mkdir -p "$PLUGINS_DIR"
cp "$SCRIPT_DIR/plugins.yaml" "$PLUGINS_DIR/plugins.yaml"

cd "$KLANGK_DIR"

DEVENV_CMD=(devenv --quiet -O dotenv.enable:bool false shell --no-tui --)

# Run everything inside devenv shell for access to flutter, podman, python, etc.
"${DEVENV_CMD[@]}" bash "$SCRIPT_DIR/build-inner.sh" \
  "$PLUGINS_DIR" "$WORKSPACE_DIR" "$SSL_CERT_DIR"

# 4. Build host image from source (needs devenv for venv build context).
# build-host-image.sh re-runs flutterbuildweb.sh, which re-runs
# import_dart_plugins.py — so KLANGK_PLUGINS_DIR must be forwarded into
# this devenv shell too, otherwise it falls back to devenv.nix's default
# (.devenv/state/klangk/plugins), scans an empty dir, overwrites the
# frontend's pubspec_overrides symlink to point at an empty .dart/
# package, and `pub get` drops all the plugin deps.
"${DEVENV_CMD[@]}" env KLANGK_PLUGINS_DIR="$PLUGINS_DIR" bash scripts/build-host-image.sh

# 5. Copy Flutter web build output to this directory for Docker context
echo "=== Preparing Docker build context ==="
rm -rf "$SCRIPT_DIR/web"
cp -r "$KLANGK_DIR/src/frontend/build/web" "$SCRIPT_DIR/web"

# 6. Build the custom host image
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
