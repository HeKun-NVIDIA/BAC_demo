#!/usr/bin/env bash
# Builds a relocatable tar.zst of the workshop bundle for other DGX Sparks.
# The target machine only needs Docker + NVIDIA Container Toolkit; running
# ./install.sh there loads everything offline.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

OUT_DIR="${OUT_DIR:-$DEMO_ROOT/artifacts/packages}"
ARCHIVE_NAME="${ARCHIVE_NAME:-dgx_spark_openclaw_workshop.tar.zst}"
SPLIT_SIZE=""
WITH_NEMOTRON=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_DIR="$2"; shift 2 ;;
    --split) SPLIT_SIZE="$2"; shift 2 ;;
    --with-nemotron) WITH_NEMOTRON=1; shift ;;
    -h|--help)
      echo "用法: $0 [--out DIR] [--split 20G] [--with-nemotron]"
      exit 0
      ;;
    *) die "未知参数: $1" ;;
  esac
done

require_command rsync
require_command zstd
python3 "$HERE/verify-models.py" qwen qwen3-tts
[[ -f "$DEMO_ROOT/artifacts/containers/dgx-spark-vllm-0.28.0-nvfp4.tar" ]] || die "缺少离线 vLLM 镜像归档"
[[ -x "$CHROMIUM_BIN" ]] || die "缺少 Chromium，请先运行 install.sh"
[[ -x "$DEMO_RUNTIME/tts-venv/bin/python" ]] || die "缺少 TTS 运行环境，请先运行 install.sh"

stage="$DEMO_RUNTIME/package-stage/dgx_spark_openclaw_demo"
rm -rf "$DEMO_RUNTIME/package-stage"
mkdir -p "$stage" "$OUT_DIR"

excludes=(
  --exclude '/archive/'
  --exclude '/artifacts/packages/'
  --exclude '/logs/*'
  --exclude '/runtime/*'
  --exclude '/openclaw/state/'
  --exclude '/openclaw/.secrets/'
  --exclude '/workspace/'
  --exclude '/showcase/outputs/'
  --exclude '/showcase/sandbox-data/'
  --exclude '/models/hf-cache/'
  --exclude '*.partial'
  --exclude '__pycache__/'
)
(( WITH_NEMOTRON )) || excludes+=(--exclude '/models/nemotron/')

section "创建脱敏 staging 目录"
# --include rules must precede the broad /runtime/* exclude.
rsync -a --delete \
  --exclude '**/__pycache__/***' --exclude '*.pyc' \
  --include '/runtime/ms-playwright/***' --include '/runtime/tts-venv/***' --include '/runtime/node/***' \
  "${excludes[@]}" "$DEMO_ROOT/" "$stage/"
mkdir -p "$stage/logs" "$stage/openclaw/state" "$stage/workspace" "$stage/runtime/cache/vllm" \
  "$stage/runtime/cache/flashinfer" "$stage/runtime/cache/triton"

if find "$stage" -type f \
  \( -name 'gateway-token' -o -name 'device-auth.json' -o -name 'paired.json' -o -name 'exec-approvals.json' \) |
  read -r _; then
  die "staging 中检测到运行凭据/配对状态，拒绝打包"
fi

section "生成资产校验清单"
(
  cd "$stage"
  find models artifacts runtime/node runtime/ms-playwright runtime/tts-venv \
    openclaw/node_modules showcase/vendor -type f -print0 |
    sort -z | xargs -0 sha256sum > manifests.sha256
)

archive="$OUT_DIR/$ARCHIVE_NAME"
rm -f "$archive" "$archive".part-*
section "压缩为 tar.zst"
tar -C "$(dirname "$stage")" -cf - "$(basename "$stage")" | zstd -T0 -6 -o "$archive"
(cd "$OUT_DIR" && sha256sum "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")

if [[ -n "$SPLIT_SIZE" ]]; then
  section "分卷"
  split -b "$SPLIT_SIZE" -d -a 3 "$archive" "$archive.part-"
  (cd "$OUT_DIR" && sha256sum "$ARCHIVE_NAME".part-* > "$ARCHIVE_NAME.parts.sha256")
fi

du -sh "$stage" "$archive"
rm -rf "$DEMO_RUNTIME/package-stage"
ok "打包完成: $archive"
