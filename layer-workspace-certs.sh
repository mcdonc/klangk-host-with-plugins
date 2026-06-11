#!/usr/bin/env bash
# Layer custom CA certs onto the workspace image.
# Called from build.sh inside the devenv shell.
#
# Usage: layer-workspace-certs.sh <ssl-cert-dir>
set -euo pipefail

SSL_CERT_DIR="$1"
WORKSPACE_IMAGE="${KLANGK_IMAGE_NAME:-klangk-workspace}"
PODMAN="${KLANGK_PODMAN_BIN:-podman}"
POLICY_ARGS=()
if [ -n "${KLANGK_SIGNATURE_POLICY:-}" ]; then
  POLICY_ARGS+=(--signature-policy "${KLANGK_SIGNATURE_POLICY}")
fi

WS_CERT_DIR=$(mktemp -d)
trap 'rm -rf "$WS_CERT_DIR"' EXIT

cp "$SSL_CERT_DIR"/*.pem "$WS_CERT_DIR/" 2>/dev/null || true
cp "$SSL_CERT_DIR"/*.crt "$WS_CERT_DIR/" 2>/dev/null || true

cat > "$WS_CERT_DIR/Dockerfile" <<'CERTDF'
ARG BASE
FROM $BASE
COPY *.pem *.crt /tmp/ssl/
USER root
RUN cp /tmp/ssl/*.pem /usr/local/share/ca-certificates/ 2>/dev/null; \
    cp /tmp/ssl/*.crt /usr/local/share/ca-certificates/ 2>/dev/null; \
    for f in /usr/local/share/ca-certificates/*.pem; do \
      [ -f "$f" ] && mv "$f" "${f%.pem}.crt"; \
    done; \
    update-ca-certificates && \
    rm -rf /tmp/ssl
USER klangk
CERTDF

"$PODMAN" build "${POLICY_ARGS[@]}" \
  --build-arg BASE="$WORKSPACE_IMAGE" \
  -t "$WORKSPACE_IMAGE:latest" \
  "$WS_CERT_DIR"
