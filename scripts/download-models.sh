#!/usr/bin/env bash
# Download pinned model snapshots into ordinary, relocatable folders.
# Files that are already complete are skipped, so re-running is cheap.
# Sources: ModelScope first; the NVIDIA NVFP4 repos are not on ModelScope yet,
# so they come from the domestic Hugging Face mirror (hf-mirror.com).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

HF_BASE_URL="${HF_BASE_URL:-https://hf-mirror.com}"
MODELSCOPE_BASE_URL="${MODELSCOPE_BASE_URL:-https://www.modelscope.cn}"
DOWNLOAD_JOBS="${DOWNLOAD_JOBS:-2}"

QWEN_REVISION="1355db6a052410cfd62085d94b58866fd0f2c3c5"
NEMOTRON_REVISION="16993199e436da4ba75ddc410855f87e0d996ee6"
TTS_MODELSCOPE_REPO="${TTS_MODELSCOPE_REPO:-Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice}"
TTS_REVISION="${TTS_REVISION:-master}"

_download_snapshot_file() {
  local record="$1" name size target partial url actual
  name="${record%%$'\t'*}"
  size="${record#*$'\t'}"
  target="$DL_DESTINATION/$name"
  partial="$target.partial"
  mkdir -p "$(dirname "$target")"

  if [[ -f "$target" ]] && { [[ "$size" -eq 0 ]] || [[ "$(stat -c%s "$target")" == "$size" ]]; }; then
    printf '  [已存在] %s\n' "$name"
    return 0
  fi

  url="$DL_URL_PREFIX/$name"
  printf '  [下载] %s\n' "$name"
  curl -fL --continue-at - --retry 8 --retry-all-errors \
    --connect-timeout 30 --speed-time 120 --speed-limit 1024 \
    "$url" -o "$partial"
  if [[ "$size" -gt 0 ]]; then
    actual="$(stat -c%s "$partial")"
    [[ "$actual" == "$size" ]] || { echo "$name 大小错误：期望 $size，实际 $actual" >&2; return 1; }
  fi
  mv "$partial" "$target"
}
export -f _download_snapshot_file

download_listing() {
  local destination="$1" url_prefix="$2" expected="$destination/.expected-files.tsv"
  export DL_DESTINATION="$destination" DL_URL_PREFIX="$url_prefix"
  # Low parallelism: several 10 GB shards at once can flood the page cache
  # on a unified-memory Spark.
  while IFS= read -r record; do
    printf '%s\0' "$record"
  done < "$expected" |
    xargs -0 -n1 -P "$DOWNLOAD_JOBS" bash -c '_download_snapshot_file "$1"' _
}

download_from_modelscope() {
  local repo="$1" revision="$2" destination="$3" listing
  mkdir -p "$destination"
  info "魔搭社区: $repo@$revision"
  listing="$destination/.modelscope-files.json"
  curl -fsSL --retry 5 --retry-all-errors \
    "$MODELSCOPE_BASE_URL/api/v1/models/$repo/repo/files?Revision=$revision&Recursive=true" \
    -o "$listing"
  python3 - "$listing" "$destination/.expected-files.tsv" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
files = [f for f in (data.get("Data") or {}).get("Files", []) if f.get("Type") == "blob"]
if not files:
    sys.exit(f"ModelScope 返回空文件列表: {data.get('Message')}")
with open(sys.argv[2], "w", encoding="utf-8") as out:
    for item in files:
        out.write(f"{item['Path']}\t{item.get('Size') or 0}\n")
PY
  download_listing "$destination" "$MODELSCOPE_BASE_URL/models/$repo/resolve/$revision"
  printf '%s\n' "$revision" > "$destination/REVISION"
  printf 'modelscope:%s\n' "$repo" > "$destination/SOURCE"
  ok "$repo 下载完成: $destination"
}

download_from_hf_mirror() {
  local repo="$1" revision="$2" destination="$3" metadata
  mkdir -p "$destination"
  metadata="$destination/.snapshot-api.json"
  info "HF 国内镜像: $repo@$revision"
  curl -fsSL --retry 5 --retry-all-errors \
    "$HF_BASE_URL/api/models/$repo/revision/$revision?blobs=true" \
    -o "$metadata"
  python3 - "$metadata" "$destination/.expected-files.tsv" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
with open(sys.argv[2], "w", encoding="utf-8") as out:
    for item in data.get("siblings", []):
        size = (item.get("lfs") or {}).get("size") or item.get("size") or 0
        out.write(f"{item['rfilename']}\t{size}\n")
PY
  download_listing "$destination" "$HF_BASE_URL/$repo/resolve/$revision"
  printf '%s\n' "$revision" > "$destination/REVISION"
  printf 'hf-mirror:%s\n' "$HF_BASE_URL" > "$destination/SOURCE"
  ok "$repo 下载完成: $destination"
}

# Prefer ModelScope whenever it hosts the exact repo; never substitute a
# different quantization.
download_repo() {
  local hf_repo="$1" revision="$2" destination="$3" modelscope_repo="$4"
  if [[ -n "$modelscope_repo" ]] &&
     curl -fsS --max-time 20 \
       "$MODELSCOPE_BASE_URL/api/v1/models/$modelscope_repo/repo/files?Revision=master" 2>/dev/null |
       python3 -c 'import json,sys; sys.exit(json.load(sys.stdin).get("Code") != 200)' 2>/dev/null; then
    download_from_modelscope "$modelscope_repo" master "$destination"
    return
  fi
  info "魔搭社区暂无 $hf_repo 的原版 NVFP4 仓库，改用 HF 国内镜像"
  download_from_hf_mirror "$hf_repo" "$revision" "$destination"
}

model_complete() {
  python3 "$HERE/verify-models.py" "$1" >/dev/null 2>&1
}

fetch() {
  local key="$1"
  if model_complete "$key"; then
    skip "模型 $key 已完整，无需下载"
    return
  fi
  case "$key" in
    qwen)
      download_repo "$QWEN_MODEL_ID" "$QWEN_REVISION" "$QWEN_MODEL_DIR" \
        "${MODELSCOPE_QWEN_REPO:-nvidia/Qwen3.6-35B-A3B-NVFP4}"
      ;;
    nemotron)
      download_repo "$NEMOTRON_MODEL_ID" "$NEMOTRON_REVISION" "$NEMOTRON_MODEL_DIR" \
        "${MODELSCOPE_NEMOTRON_REPO:-nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-NVFP4}"
      ;;
    qwen3-tts)
      download_from_modelscope "$TTS_MODELSCOPE_REPO" "$TTS_REVISION" "$TTS_MODEL_DIR"
      ;;
  esac
  model_complete "$key" || die "模型 $key 校验失败，请重新运行以续传"
}

case "${1:-workshop}" in
  qwen|nemotron|qwen3-tts) fetch "$1" ;;
  workshop) fetch qwen; fetch qwen3-tts ;;
  all) fetch qwen; fetch qwen3-tts; fetch nemotron ;;
  *)
    echo "用法: $0 [workshop|all|qwen|qwen3-tts|nemotron]" >&2
    exit 2
    ;;
esac
