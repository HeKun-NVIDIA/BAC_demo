#!/usr/bin/env bash
# Root-only: simulate a new DGX Spark account installing the workshop.
#   默认：只把 install.sh 交给新账号。
#   REPO_URL=<GitHub 地址或 git bundle 路径>：新账号用 git clone 获取项目后运行 ./install.sh。
#   REUSE_LOCAL_ASSETS=1：模拟模式，用硬链接复用本机已下载的模型并保留现有 vLLM 镜像，
#     跳过约 38GB 下载和镜像构建；其余步骤（依赖安装、启动、重置、自检）照常执行。
set -euo pipefail

SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
TEST_USER="${TEST_USER:-openclawtest}"
REPO_URL="${REPO_URL:-}"
REUSE_LOCAL_ASSETS="${REUSE_LOCAL_ASSETS:-0}"
TEST_HOME="/home/$TEST_USER"
DEST="$TEST_HOME/dgx_spark_openclaw_demo"
ACCOUNT_MARKER="$TEST_HOME/.dgx-openclaw-test-user"
IMAGE_MARKER="$TEST_HOME/.dgx-openclaw-public-image-tested"
TARGET_IMAGE="dgx-spark-vllm:0.28.0-nvfp4"

info() { printf '\n[新用户测试] %s\n' "$*"; }
die() { printf '[新用户测试][错误] %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] ||
  die "需要 root：sudo $SOURCE/scripts/create-test-user.sh"
[[ "$TEST_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] ||
  die "非法用户名: $TEST_USER"
[[ "$TEST_USER" != "root" && "$TEST_USER" != "nvidia" ]] ||
  die "拒绝使用保留账号: $TEST_USER"
command -v useradd >/dev/null || die "缺少 useradd"
command -v runuser >/dev/null || die "缺少 runuser"
getent group docker >/dev/null || die "缺少 docker 用户组"
getent group video >/dev/null || die "缺少 video 用户组"

available_kib="$(df -Pk /home | awk 'NR == 2 {print $4}')"
(( available_kib >= 120 * 1024 * 1024 )) ||
  die "/home 可用空间不足 120 GiB"

if id "$TEST_USER" >/dev/null 2>&1; then
  [[ -f "$ACCOUNT_MARKER" ]] ||
    die "账号 $TEST_USER 已存在但不是本脚本创建的，拒绝复用"
  info "复用先前创建的测试账号 $TEST_USER（下载可断点续传）"
else
  info "创建系统账号 $TEST_USER，并加入 docker/video 组"
  useradd --create-home --shell /bin/bash --groups docker,video "$TEST_USER"
  touch "$ACCOUNT_MARKER"
  chown "$TEST_USER:$TEST_USER" "$ACCOUNT_MARKER"
fi

run_as_test_user() {
  runuser -u "$TEST_USER" -- env \
    HOME="$TEST_HOME" USER="$TEST_USER" LOGNAME="$TEST_USER" SHELL=/bin/bash \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    "$@"
}

info "停止本机所有账号的 workshop 副本（它们占用相同的固定端口；不操作其他 demo）"
if [[ -x "$DEST/stop.sh" ]]; then
  run_as_test_user "$DEST/stop.sh" || true
fi
for other in /home/*/dgx_spark_openclaw_demo; do
  [[ "$other" == "$DEST" || "$other" == "$SOURCE" || ! -x "$other/stop.sh" ]] && continue
  owner="$(stat -c %U "$other")"
  info "停止 $owner 的 workshop：$other"
  runuser -u "$owner" -- "$other/stop.sh" || true
done
"$SOURCE/stop.sh" || true

if [[ -n "$REPO_URL" ]]; then
  delivery="git clone $REPO_URL"
  if [[ -d "$DEST/.git" ]]; then
    info "测试目录已有仓库，更新到 $REPO_URL 的最新提交（已下载的模型等不受影响）"
    run_as_test_user git -C "$DEST" fetch "$REPO_URL" HEAD
    run_as_test_user git -C "$DEST" reset --hard FETCH_HEAD
  else
    [[ ! -e "$DEST" || -z "$(find "$DEST" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
      die "$DEST 已存在且不是 git 仓库；请换一个 TEST_USER"
    info "以 $TEST_USER 身份克隆仓库：$REPO_URL"
    rmdir "$DEST" 2>/dev/null || true
    run_as_test_user git clone "$REPO_URL" "$DEST"
  fi
else
  delivery="install.sh only"
  install -d -o "$TEST_USER" -g "$TEST_USER" "$DEST"
  install -m 0755 -o "$TEST_USER" -g "$TEST_USER" \
    "$SOURCE/install.sh" "$DEST/install.sh"

  file_count="$(find "$DEST" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | wc -l)"
  [[ "$file_count" == "1" && -f "$DEST/install.sh" ]] ||
    info "测试目录是断点续传状态；install.sh 会更新内置骨架并复用已下载资产"
fi

if [[ "$REUSE_LOCAL_ASSETS" == "1" ]]; then
  docker image inspect "$TARGET_IMAGE" >/dev/null 2>&1 ||
    die "模拟模式需要本机已有镜像 $TARGET_IMAGE"
  install -d -o "$TEST_USER" -g "$TEST_USER" "$DEST/models"
  for model in qwen qwen3-tts; do
    [[ -s "$SOURCE/models/$model/config.json" ]] || die "本机缺少模型 $SOURCE/models/$model"
    if [[ ! -e "$DEST/models/$model" ]]; then
      info "硬链接复用本机模型 $model（不额外占用磁盘，原文件对新账号只读）"
      cp -al "$SOURCE/models/$model" "$DEST/models/$model"
    fi
  done
  find "$DEST/models" -type d -exec chown "$TEST_USER:$TEST_USER" {} +
  info "保留现有镜像 $TARGET_IMAGE，跳过镜像构建"
elif [[ ! -f "$IMAGE_MARKER" ]]; then
  info "移除本机旧的目标镜像标签，强制执行单脚本公开镜像构建路径"
  docker image rm "$TARGET_IMAGE" >/dev/null 2>&1 || true
fi

info "以 $TEST_USER 身份运行 install.sh（交付方式：$delivery）"
run_as_test_user bash -c "cd '$DEST' && ./install.sh"
if [[ "$REUSE_LOCAL_ASSETS" != "1" ]]; then
  touch "$IMAGE_MARKER"
  chown "$TEST_USER:$TEST_USER" "$IMAGE_MARKER"
fi

info "运行 OpenClaw 新用户冒烟任务"
cat > "$DEST/runtime/tmp/new-user-smoke-prompt.txt" <<'EOF'
在 demos/new-user-smoke/index.html 创建一个完全离线的简单网页，页面必须清晰显示
NEW_USER_ENV_OK。完成后检查文件并回复访问链接。
EOF
chown "$TEST_USER:$TEST_USER" "$DEST/runtime/tmp/new-user-smoke-prompt.txt"
run_as_test_user bash -c "
  cd '$DEST'
  source env.sh
  openclaw agent \
    --session-key agent:main:new-user-smoke \
    --message-file runtime/tmp/new-user-smoke-prompt.txt \
    --timeout 300 --json > logs/new-user-smoke.json
"

smoke_page="$DEST/workspace/demos/new-user-smoke/index.html"
[[ -f "$smoke_page" ]] || die "OpenClaw 没有创建冒烟网页"
grep -q "NEW_USER_ENV_OK" "$smoke_page" ||
  die "冒烟网页缺少 NEW_USER_ENV_OK"
curl -fsS --max-time 10 \
  "http://127.0.0.1:18088/workspace/demos/new-user-smoke/" |
  grep -q "NEW_USER_ENV_OK" ||
  die "冒烟网页无法通过 workshop 服务器访问"
[[ "$(stat -c %U "$smoke_page")" == "$TEST_USER" ]] ||
  die "冒烟文件所有者不是 $TEST_USER"

asset_result=PASS
[[ "$REUSE_LOCAL_ASSETS" == "1" ]] && asset_result="SKIPPED (reused local assets)"
cat > "$DEST/NEW_USER_TEST_RESULT.txt" <<EOF
PASS
user=$TEST_USER
home=$TEST_HOME
delivery=$delivery
standalone_extract=PASS
models_download=$asset_result
public_vllm_build=$asset_result
openclaw_install=PASS
qwen_text_and_vision=PASS
qwen3_tts=PASS
camera_permission=PASS
openclaw_file_creation=PASS
web_access=PASS
completed_at=$(date --iso-8601=seconds)
EOF
chown "$TEST_USER:$TEST_USER" "$DEST/NEW_USER_TEST_RESULT.txt"

info "新用户全流程测试通过"
id "$TEST_USER"
du -sh "$DEST"
run_as_test_user "$DEST/scripts/openclaw-ctl.sh" urls
echo "报告: $DEST/NEW_USER_TEST_RESULT.txt"
echo "环境保持运行，便于继续检查。"
