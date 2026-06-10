# klangk-host-with-plugins

Builds a custom [Klangk](https://github.com/mcdonc/klangk) host container image with plugins baked in.

## Plugins

Edit `plugins.yaml` to add or remove plugins. The default set includes:

- celebrate, beep, pig-latin, word-count, browser-fetch, bobdobbs (built-in)
- soliplex (external)

## Prerequisites

- [Nix](https://nixos.org/download/) with [devenv](https://devenv.sh/)
- Docker
- SSH key with access to the git repos listed in `plugins.yaml`

## Build

```bash
./build.sh

# Or pin to a specific release:
KLANGK_REF=v2026.06.09.1 ./build.sh
```

This will:

1. Clone the klangk repo (into `.klangk/`)
2. Fetch plugins listed in `plugins.yaml`
3. Rebuild the Flutter web frontend (with Dart plugin UI)
4. Rebuild the workspace container image (with plugin extensions and tools)
5. Build a Docker image extending `ghcr.io/mcdonc/klangk/klangk-host:latest`

The resulting image is tagged `ghcr.io/mcdonc/klangk/klangk-host-custom:latest` by default. Override with `KLANGK_HOST_IMAGE`.

## Options

| Variable | Default | Description |
|---|---|---|
| `KLANGK_REF` | `main` | Klangk branch, tag, or commit SHA to build against |
| `KLANGK_REPO` | `https://github.com/mcdonc/klangk.git` | Klangk repo URL |
| `KLANGK_HOST_IMAGE` | `ghcr.io/mcdonc/klangk/klangk-host-custom` | Output image name |
| `KLANGK_PLATFORM` | `linux/amd64` | Target platform |
| `KLANGK_SSL_CERT_DIR` | `./ssl` | Directory containing `.pem` CA certs to inject into both images |

## Custom CA Certificates

Place `.pem` or `.crt` files in the `ssl/` directory (or set `KLANGK_SSL_CERT_DIR`). They will be installed into the system CA store of both the host and workspace images. This is needed when services like Logfire use certificates signed by a private CA. The `ssl/` directory is gitignored — certs must be provided at build time.

## Running

```bash
docker run -d \
  -p 8995:8995 \
  -v /your/data/path:/home/klangk/data \
  --cap-add SYS_ADMIN \
  --device /dev/fuse \
  --device /dev/net/tun \
  --security-opt seccomp=unconfined \
  --security-opt systempaths=unconfined \
  -e KLANGK_DEFAULT_USER=admin@example.com \
  -e KLANGK_DEFAULT_PASSWORD=admin \
  -e KLANGK_JWT_SECRET=change-me \
  ghcr.io/mcdonc/klangk/klangk-host-custom
```

### OIDC Authentication

To enable OIDC login, place your OIDC config at `oidc.yaml` in this repo (gitignored), then mount it at runtime:

```bash
docker run -d \
  ...
  -v /path/to/oidc.yaml:/home/klangk/oidc.yaml:ro \
  -e KLANGK_OIDC_CONFIG=/home/klangk/oidc.yaml \
  ghcr.io/mcdonc/klangk/klangk-host-custom
```

If your OIDC provider requires a custom CA certificate (e.g. `ca_cert: cacert.pem` in `oidc.yaml`), place the PEM file at `cacert.pem` in this repo (gitignored). Both `docker-compose.yml` and `run.sh` mount it into the container at `/home/klangk/cacert.pem`.

See the [OIDC section in HACKING.md](https://github.com/mcdonc/klangk/blob/main/HACKING.md#oidc-openid-connect) for the config file format.
