# 全新用户手动验收

## 0. 一键自动验收（推荐）

在已有项目的管理员账号里执行（`<新用户名>` 用一个从未存在过的名字）：

```bash
# 从 GitHub 克隆（公开仓库或带令牌的地址）
sudo TEST_USER=<新用户名> REPO_URL=https://github.com/HeKun-NVIDIA/BAC_demo.git \
  ./scripts/create-test-user.sh

# 或者用本机生成的 git bundle（内容与将要推送的提交完全一致）
sudo TEST_USER=<新用户名> REPO_URL=/tmp/dgx_spark_openclaw_demo.bundle \
  ./scripts/create-test-user.sh
```

只想模拟流程、不重新下载时，再加 `REUSE_LOCAL_ASSETS=1`：用硬链接复用本机已下载的模型并保留
现有 vLLM 镜像，跳过约 38GB 下载和镜像构建，其余步骤照常执行。

脚本会创建账号（加入 docker、video 组），停止本机其他账号的 workshop 副本
（它们占用相同端口），以新账号身份克隆并运行 `./install.sh`（首次约下载 38GB），
再做一次 OpenClaw 冒烟测试，结果写入新账号目录下的 `NEW_USER_TEST_RESULT.txt`。
之后按第 6 节在浏览器里完成八个 demo。

下面是逐步手动验收的方法。

本文以全新账号 `openclawmanual` 为例验证单文件
`install.sh`。所有 sudo 命令都在前台执行，不要在等待密码时加 `&`。

## 1. 在管理员账号准备

```bash
sudo -v

sudo -u openclawtest -H bash -c \
  'cd /home/openclawtest/dgx_spark_openclaw_demo && ./stop.sh'

sudo useradd -m -s /bin/bash -G docker,video openclawmanual

sudo install -d -m 0755 -o openclawmanual -g openclawmanual \
  /home/openclawmanual/dgx_spark_openclaw_demo

sudo install -m 0755 -o openclawmanual -g openclawmanual \
  /home/nvidia/dgx_spark_openclaw_demo/install.sh \
  /home/openclawmanual/dgx_spark_openclaw_demo/install.sh

sudo -iu openclawmanual
```

如果账号已经存在，不要重复 `useradd`；确认它属于 `docker` 和 `video` 组。

## 2. 确认初始环境

以下命令均在 `openclawmanual` shell 执行：

```bash
id
pwd
docker info >/dev/null && echo DOCKER_OK
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader

cd ~/dgx_spark_openclaw_demo
find . -mindepth 1 -maxdepth 1 -printf '%f\n'
```

最后一条命令此时应只显示 `install.sh`。

为了在同机测试中强制走独立镜像构建路径，使用唯一镜像名：

```bash
echo 'export VLLM_IMAGE=dgx-spark-vllm-openclawmanual:0.28.0' >> ~/.bashrc
export VLLM_IMAGE=dgx-spark-vllm-openclawmanual:0.28.0
```

## 3. 首次安装

```bash
set -o pipefail
./install.sh 2>&1 | tee ~/openclaw-manual-first-install.log
echo "INSTALL_EXIT=${PIPESTATUS[0]}"
```

期望 `INSTALL_EXIT=0`。首次运行约下载 38GB；同机可能复用 Docker 层缓存，
但模型、Node、OpenClaw、Chromium 和 Python 环境均在新用户目录独立安装。

## 4. 服务与权限检查

```bash
./status.sh

curl -fsS http://127.0.0.1:18000/v1/models
curl -fsS http://127.0.0.1:18002/health
curl -fsS http://127.0.0.1:18088/api/health
curl -fsS http://127.0.0.1:13001/ >/dev/null && echo OPENCLAW_HTTP_OK

docker inspect dgx-demo-qwen --format \
  'image={{.Config.Image}} mounts={{range .Mounts}}{{.Source}};{{end}}'
```

镜像应为 `dgx-spark-vllm-openclawmanual:0.28.0`，挂载路径应全部位于
`/home/openclawmanual/dgx_spark_openclaw_demo/`。

摄像头权限：

```bash
runtime/pyenv/bin/python3 - <<'PY'
import cv2
cap = cv2.VideoCapture(0)
ok, frame = cap.read()
cap.release()
print("CAMERA_OK", ok, None if frame is None else frame.shape)
assert ok and frame is not None
PY
```

TTS：

```bash
curl -fsS http://127.0.0.1:18002/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"input":"新用户语音测试成功","voice":"vivian","speed":1.0}' \
  -o /tmp/openclawmanual-test.wav
file /tmp/openclawmanual-test.wav
```

## 5. OpenClaw 冒烟测试

```bash
source env.sh
openclaw agent \
  --session-key agent:main:manual-smoke \
  --message '在 demos/manual-smoke/index.html 创建完全离线网页，页面清晰显示 MANUAL_USER_OK；完成后检查文件并给出链接。' \
  --timeout 300 --json | tee logs/manual-smoke.json

grep -q MANUAL_USER_OK workspace/demos/manual-smoke/index.html &&
  echo FILE_CREATION_OK

curl -fsS http://127.0.0.1:18088/workspace/demos/manual-smoke/ |
  grep -q MANUAL_USER_OK && echo WEB_ACCESS_OK

stat -c '%U:%G %n' workspace/demos/manual-smoke/index.html
```

文件所有者必须是 `openclawmanual:openclawmanual`。

## 6. 浏览器内完成八个 demo

运行：

```bash
scripts/openclaw-ctl.sh urls
```

用输出的局域网 URL 打开 OpenClaw。打开 `PROMPTS.txt`，每项开始前发送 `/new`
（Ping-Pong 升级步骤在同一会话继续）。
本地作品应按提示词完成定制（标题、配色、数量等与提示词一致），每轮约 30 秒到 2 分钟；不应启动 subagent。

验收重点：

1. Ping-Pong：球移动，W/S 控制，升级后可选难度、粒子和音效。
2. 平台跳跃：左右、二段跳、金币、小怪、生命与终点正常。
3. 3D：主机与粒子可见，拖动/缩放/点击卡片正常。
4. 呼吸冥想：倒计时变化，今日寄语和语音正常。
5. 摄像头：实时画面、FPS、人脸框、AI 描述正常。
6. 3D 卡丁车：方向键驾驶、赛道/护栏/电脑车、检查点和圈数正常。
7. 真实浏览器：工具记录显示使用 Bing（不能是 Google），实际打开 NVIDIA 官方页面，
   回复包含 CUDA 13.4 特性、官方 URL 和日期。
8. TTS：欢迎词可播放，网页的 0.7x 与 1.5x 音频时长不同。

## 7. 重置和幂等性

```bash
time ./reset.sh
test -z "$(find workspace/demos -mindepth 1 -maxdepth 1 -print -quit)" &&
  echo RESET_CLEAN_OK

./install.sh 2>&1 | tee ~/openclaw-manual-second-install.log
```

第二次安装应显示模型、镜像、Node、OpenClaw、Chromium、Python、Three.js 和
TTS 环境均“跳过”或“已就绪”，不得再次下载模型。

## 8. 结束

保留环境继续体验即可。需要停止：

```bash
./stop.sh
exit
```

恢复原 `nvidia` 环境：

```bash
cd /home/nvidia/dgx_spark_openclaw_demo
./install.sh
```
