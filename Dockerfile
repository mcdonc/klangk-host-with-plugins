# Custom klangk-host image with plugins and optional CA certs.
#
# This cannot be built standalone — use ./build.sh which clones klangk,
# fetches plugins, rebuilds Flutter web and the workspace image, then
# builds this Dockerfile.
#
# Usage:
#   ./build.sh
#
FROM ghcr.io/mcdonc/klangk/klangk-host:latest

# Add custom CA certificate (if provided)
COPY ssl/ /tmp/ssl/
USER root
RUN if ls /tmp/ssl/*.pem 1>/dev/null 2>&1; then \
      cp /tmp/ssl/*.pem /usr/local/share/ca-certificates/ && \
      # ca-certificates expects .crt extension
      for f in /usr/local/share/ca-certificates/*.pem; do \
        mv "$f" "${f%.pem}.crt"; \
      done && \
      update-ca-certificates; \
    fi && \
    rm -rf /tmp/ssl
USER klangk

# Replace Flutter web build (rebuilt with Dart plugins)
COPY --chown=klangk:klangk web /home/klangk/src/frontend/build/web

# Replace workspace tarball (rebuilt with plugin extensions/tools)
COPY --from=workspace-tar --chown=klangk:klangk workspace.tar /home/klangk/workspace.tar
