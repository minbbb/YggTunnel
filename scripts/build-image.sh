#!/bin/sh
#
# Builds the pinned Yggdrasil image.
#
#   ./scripts/build-image.sh                # host architecture only, fast
#   PLATFORMS=linux/amd64,linux/arm64 ./scripts/build-image.sh
#
# The multi-platform build needs a builder that supports it and either a
# registry to push to or the containerd image store enabled in the Docker
# daemon (Docker Desktop has it on by default). A single-platform build is
# loaded into the local image store, which is what the compose files use.
#
#   YGG_VERSION=0.5.13 ./scripts/build-image.sh

set -eu

cd "$(dirname "$0")/.."

YGG_VERSION="${YGG_VERSION:-0.5.14}"

if [ -z "${PLATFORMS:-}" ]; then
    case "$(uname -m)" in
        x86_64|amd64) PLATFORMS="linux/amd64" ;;
        aarch64|arm64) PLATFORMS="linux/arm64" ;;
        *)
            echo "build-image.sh: unsupported host architecture '$(uname -m)'." >&2
            echo "               Set PLATFORMS=linux/amd64 or PLATFORMS=linux/arm64 explicitly." >&2
            exit 1
            ;;
    esac
fi

set -- buildx build
set -- "$@" --platform "${PLATFORMS}"
set -- "$@" --build-arg "YGG_VERSION=${YGG_VERSION}"
set -- "$@" --tag "yggtunnel/yggdrasil:${YGG_VERSION}"
set -- "$@" --file docker/yggdrasil/Dockerfile

# --load only understands a single platform.
case "${PLATFORMS}" in
    *,*) ;;
    *) set -- "$@" --load ;;
esac

set -- "$@" docker/yggdrasil

echo "build-image.sh: yggtunnel/yggdrasil:${YGG_VERSION} for ${PLATFORMS}"
docker "$@"
echo "build-image.sh: done"
