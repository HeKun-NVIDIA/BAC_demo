#!/usr/bin/env bash
# Internal workshop installer. Root install.sh extracts the project skeleton
# when it is the only delivered file, then delegates here.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

access=lan
reset_args=()
with_nemotron=0
for arg in "$@"; do
  case "$arg" in
    --local) access=local ;;
    --rotate-token) reset_args+=(--rotate-token) ;;
    --with-nemotron) with_nemotron=1 ;;
    -h|--help)
      cat <<'EOF'
用法: ./install.sh [--local] [--rotate-token] [--with-nemotron]
  --local          OpenClaw 只允许本机浏览器访问（默认允许局域网）
  --rotate-token   为这位体验者生成新的访问令牌
  --with-nemotron  额外下载 Nemotron 模型（workshop 不需要）

第一次运行会下载约 28 GB 模型，并在缺少镜像时从固定的公开 ARM64
vLLM 基础镜像构建本地推理镜像。后续运行跳过已有内容，只重置 OpenClaw。
EOF
      exit 0
      ;;
    *) die "未知参数: $arg（--help 查看用法）" ;;
  esac
done

section "0/6 环境检查"
info "Workshop 版本: $(cat "$DEMO_ROOT/VERSION" 2>/dev/null || echo unknown)"
[[ "$(uname -m)" == "aarch64" ]] ||
  die "需要 DGX Spark（aarch64），当前为 $(uname -m)"
require_command docker
require_command curl
require_command python3
docker info >/dev/null 2>&1 ||
  die "无法访问 Docker；请确认 Docker/NVIDIA Container Toolkit 已安装，且当前用户在 docker 组"
command -v nvidia-smi >/dev/null 2>&1 || die "找不到 nvidia-smi"
free_gb="$(df -Pk "$DEMO_ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')"
if [[ ! -s "$QWEN_MODEL_DIR/config.json" ]] ||
   ! docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1; then
  (( free_gb >= 120 )) ||
    die "首次在线安装至少需要 120 GiB 可用磁盘，当前仅 ${free_gb} GiB"
fi
ok "aarch64 / Docker / GPU 正常，磁盘剩余 ${free_gb} GiB"

section "1/6 模型（仅首次下载）"
if (( with_nemotron )); then
  "$HERE/download-models.sh" all
else
  "$HERE/download-models.sh" workshop
fi

section "2/6 推理镜像"
if docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1; then
  skip "vLLM 镜像已存在: $VLLM_IMAGE"
elif [[ -f "$DEMO_ROOT/artifacts/containers/dgx-spark-vllm-0.28.0-nvfp4.tar" ]]; then
  "$HERE/model-ctl.sh" image
else
  info "未携带离线镜像；从固定公开 ARM64 基础镜像构建（首次约 10–30 分钟）"
  "$HERE/build-vllm-image.sh" --no-export
fi

section "3/6 程序与依赖（已安装的会跳过）"
"$HERE/install-openclaw.sh"
"$HERE/install-browser.sh"
"$HERE/install-pyenv.sh"
"$HERE/install-assets.sh"
"$HERE/install-tts.sh"

section "4/6 模型与语音服务（已运行的会跳过）"
"$HERE/model-ctl.sh" start qwen
"$HERE/tts-ctl.sh" start

section "5/6 重置 OpenClaw 并启动"
"$HERE/reset-openclaw.sh" "${reset_args[@]}"
"$HERE/showcase-ctl.sh" restart
"$HERE/openclaw-ctl.sh" start "$access"

section "6/6 快速自检"
"$HERE/selftest.sh"

ip="$(lan_ip)"
section "准备就绪"
echo "打开 OpenClaw（复制整行到浏览器地址栏）："
"$HERE/openclaw-ctl.sh" urls
echo
echo "提示词：$DEMO_ROOT/PROMPTS.txt（按顺序复制粘贴到 OpenClaw 对话框）"
echo "作品列表：http://${ip:-127.0.0.1}:$SHOWCASE_PORT/workspace/demos/"
echo
echo "下一位体验者：再次运行 ./install.sh（或更快的 ./reset.sh）即可得到全新的 OpenClaw。"
