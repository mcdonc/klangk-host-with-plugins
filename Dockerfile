# Custom klangk-host image with plugins.
#
# This cannot be built standalone — use ./build.sh which clones klangk,
# fetches plugins, rebuilds Flutter web and the workspace image, then
# builds this Dockerfile.
#
# Usage:
#   ./build.sh
#
FROM ghcr.io/mcdonc/klangk/klangk-host:latest

# Replace Flutter web build (rebuilt with Dart plugins)
COPY --chown=klangk:klangk web /home/klangk/src/frontend/build/web

# Replace workspace tarball (rebuilt with plugin extensions/tools)
COPY --from=workspace-tar --chown=klangk:klangk workspace.tar /home/klangk/workspace.tar
