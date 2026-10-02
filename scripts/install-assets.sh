#!/usr/bin/env bash
# Offline front-end libraries served at http://<spark>:18088/vendor/ so the
# pages OpenClaw writes never need a CDN.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

# vendor_npm <package> <version> <label> <sentinel-file> <tar paths...>
vendor_npm() {
  local package="$1" version="$2" label="$3" sentinel="$4"
  shift 4
  local tgz="$DEMO_ROOT/artifacts/npm/${package}-${version}.tgz"
  local dir="$DEMO_ROOT/showcase/vendor/$package"

  if [[ -f "$dir/VERSION" && "$(cat "$dir/VERSION")" == "$version" && -s "$dir/$sentinel" ]]; then
    skip "$label $version 已本地化"
    return
  fi

  if [[ ! -f "$tgz" ]]; then
    info "从 npmmirror 下载 ${package}@${version}"
    mkdir -p "$(dirname "$tgz")"
    local pack_dir="$DEMO_RUNTIME/tmp/${package}-pack"
    rm -rf "$pack_dir"
    mkdir -p "$pack_dir"
    (cd "$pack_dir" && "$NODE_HOME/bin/npm" pack "${package}@${version}" --registry="$NPM_REGISTRY" --silent)
    mv "$pack_dir"/"${package}"-*.tgz "$tgz"
    rm -rf "$pack_dir"
  fi

  info "解压 $label"
  rm -rf "$dir"
  mkdir -p "$dir"
  tar -xzf "$tgz" -C "$dir" --strip-components=1 "$@"
  printf '%s\n' "$version" > "$dir/VERSION"
  ok "$label $version: /vendor/$package/$sentinel"
}

vendor_npm three 0.180.0 "Three.js" build/three.module.js \
  package/build package/examples/jsm package/LICENSE
rm -f "$DEMO_ROOT/showcase/vendor/three.module.js"

vendor_npm phaser 3.90.0 "Phaser" dist/phaser.min.js \
  package/dist/phaser.min.js package/dist/phaser.js package/LICENSE.md
