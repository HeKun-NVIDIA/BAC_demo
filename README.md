# DGX Spark × OpenClaw Workshop（单文件安装、本地 AI）

体验流程：**运行安装脚本 → 打开 OpenClaw 网页 → 按 `PROMPTS.txt` 逐条复制粘贴 → OpenClaw 完成任务并给出结果**。

代码生成、模型推理、图片理解和语音合成都在 DGX Spark 本机运行。仅 Demo 7
按用户要求访问真实 NVIDIA/CUDA 公开网页：

| 能力 | 本地组件 |
| --- | --- |
| 写代码、看图、调用工具 | Qwen 3.6 35B-A3B NVFP4（vLLM，端口 18000） |
| 语音合成 | Qwen3-TTS 1.7B CustomVoice（端口 18002，魔搭下载） |
| Agent | OpenClaw 2026.9.4（端口 13001），浏览器工具使用包内 Chromium |
| 作品托管 | workshop 服务器（端口 18088）：`/workspace/demos/`、本地 Three.js、同源模型接口 |

## 给全新 DGX Spark 安装

任选一种方式，任何用户名、任何目录都可以：

```bash
# 方式一：从 GitHub 克隆
git clone https://github.com/HeKun-NVIDIA/BAC_demo.git ~/dgx_spark_openclaw_demo
cd ~/dgx_spark_openclaw_demo
./install.sh

# 方式二：只拿到根目录的 install.sh（约 7MB，内嵌项目骨架）
mkdir -p ~/dgx_spark_openclaw_demo
cp install.sh ~/dgx_spark_openclaw_demo/
cd ~/dgx_spark_openclaw_demo
./install.sh
```

仓库只包含源码（`.gitignore` 为白名单）；模型、运行环境、工作区、日志和登录令牌都由
`install.sh` 在每台 Spark 上生成，不会提交。修改源码后请运行
`python3 scripts/build-standalone-installer.py` 重新生成 `install.sh` 再提交，
否则 `install.sh` 解包时会用旧内容覆盖新改动。

- **第一次**：解包内置骨架；下载模型（Qwen 走 hf-mirror 国内镜像、Qwen3-TTS
  走魔搭）；通过国内 Docker 代理拉取固定 digest 的 ARM64 vLLM 基础镜像并构建
  vLLM 0.28；从 npmmirror/阿里云安装其余依赖。
- 首次联网安装约下载 38GB，至少预留 120GiB 磁盘。实测模型与依赖冷下载约
  65 分钟；完全无 Docker 缓存的机器还需约 10–20 分钟构建镜像，具体取决于网络。
- **之后每位体验者再运行一次**：已下载的模型、已安装的库都会跳过（约 30 秒），**OpenClaw 总是被重置**（会话、设备配对、记忆、浏览器资料、工作区全部恢复初始）。
- 服务已在运行时，也可以用更快的 `./reset.sh` 只重置 OpenClaw。

脚本最后会打印登录链接（带令牌），复制到浏览器地址栏打开即可。局域网内的电脑打开后会自动完成设备配对。

然后打开 `PROMPTS.txt`，每个 demo 前先发送 `/new`，再把整段提示词粘贴进去。
7 个本地 Demo 在 `openclaw/demo-templates/` 里有调好的完整工程，所有可调项集中在文件顶部的
`DESIGN`（作品设计）。OpenClaw 收到提示词后把工程放进 `demos/`，按提示词里的主题、配色、速度、数量等要求
修改 `DESIGN`（Pong 升级即打开菜单、音效、粒子等开关），再自动检查并给出链接。实测每个 Demo
约 30 秒到 2 分钟。只有 Ping-Pong 分“构建 → 升级”两轮。Demo 7 是真实浏览器操作，耗时取决于网络。

| Demo | 内容 |
| --- | --- |
| 1（必做） | Ping-Pong 游戏：构建 + 升级 |
| 2 | 物理平台跳跃游戏 |
| 3 | Three.js 3D 交互场景 |
| 4 | 生成式视觉应用（呼吸冥想，内含本地 LLM + TTS 调用） |
| 5 | USB 摄像头实时人脸检测（OpenCV）+ Qwen 描述画面 |
| 6 | Playbook 风格 3D 卡丁车游戏（原创几何体素材） |
| 7 | Playbook 浏览器控制：通过 Bing 搜索 NVIDIA CUDA 13.4 并访问官方来源（需要联网） |
| 8 | 离线语音：tts 工具朗读 + 语音播报器网页 |

生成的作品都在 `http://<Spark IP>:18088/workspace/demos/`。

## 其他命令

```bash
./status.sh             # 查看各服务状态和登录链接
./stop.sh               # 停止本 workshop 的全部服务（不影响其他 demo）
./install.sh --local    # OpenClaw 只允许本机浏览器访问
./install.sh --rotate-token   # 给这位体验者换一个新令牌
scripts/pack.sh --split 20G   # 打包迁移到其他 DGX Spark
```

## 前提与注意事项

- 全新 DGX Spark（aarch64、GB10），已安装 Docker 与 NVIDIA Container
  Toolkit，当前用户在 `docker` 组。
- 摄像头 demo 需要当前用户在 `video` 组，执行一次即可：`sudo usermod -aG video $USER`（无需重启，脚本会用 `sg video` 生效）。
- 与其他 demo 隔离：所有文件、缓存、HOME 都在本目录内；端口固定（13001/18000/18002/18088，体验者作品用 18090–18099）；停止/重置只会结束本目录启动的进程和 `dgx-demo-*` 容器。
- OpenClaw 写出的 Python 服务通过受限的本地 `workshop-service` 托管，回合结束后仍可访问；下一次重置会自动停止它们。
- 单轮任务硬超时为 10 分钟，并启用工具循环检测，避免小模型反复调用浏览器而长期不结束。
- Qwen 的 KV 缓存为固定大小，别的 demo 占用内存时只会等待，不会被挤崩，也不会去停止别人的服务。
- 除 Demo 7 的真实 NVIDIA 网页研究需要互联网外，其余 demo 运行时均为本地离线。
- `scripts/pack.sh` 默认不包含可选 Nemotron（约 21 GB）；需要时加 `--with-nemotron`。

## 目录

```
install.sh reset.sh stop.sh status.sh   入口
PROMPTS.txt                             8 个 demo 的提示词
scripts/                                安装、服务控制、重置、自检、打包
openclaw/config/openclaw.template.json  OpenClaw 配置模板
openclaw/workspace-template/            每次重置恢复的规则和示例图片
openclaw/demo-templates/                7 个本地 Demo 的完整工程（顶部 DESIGN 可调）
services/tts/                           Qwen3-TTS OpenAI 兼容服务
showcase/                               workshop 服务器、本地 Three.js、离线靶站
models/ artifacts/ runtime/             模型、离线安装包、运行环境
archive/                                旧版本与历史产物（不参与打包）
```
