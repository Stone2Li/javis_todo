#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image=$(cat "$repo_root/tools/swift-image.txt")
if [ "$#" -eq 0 ]; then
    echo 'Usage: tools/swift.sh --version | build | test | run [SwiftPM arguments]' >&2
    exit 2
fi
subcommand=$1
shift
case "$subcommand" in
    build|test|run|package)
        set -- "$subcommand" --cache-path /tmp/jarvis-cache --config-path /tmp/jarvis-config --security-path /tmp/jarvis-security "$@"
        ;;
    *) set -- "$subcommand" "$@" ;;
esac
exec env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    docker --host=unix:///var/run/docker.sock run --rm --network none \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=$repo_root,dst=/repo" \
    --workdir /repo/apps/ios/Packages/JarvisDomain \
    --env XDG_CACHE_HOME=/tmp/jarvis-cache \
    --env SWIFTPM_MODULECACHE_OVERRIDE=/tmp/jarvis-modules \
    --env CLANG_MODULE_CACHE_PATH=/tmp/jarvis-clang \
    "$image" swift "$@"
