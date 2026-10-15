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

## Qwen 上下文与 vLLM 排查

重置前会读取运行中 vLLM `/v1/models` 中当前 Qwen 模型的 `max_model_len`，
并写入 OpenClaw 的 `contextWindow`。因此修改 `QWEN_CONTEXT` 或复用较小上下文的服务时，
不会继续按模板中的 131072 估算。若模型 ID 或上下文无效，重置会在停止 Gateway、
清理旧会话之前退出；请先检查 `scripts/model-ctl.sh status` 和 `scripts/model-ctl.sh logs qwen`。
仅修改环境变量不会改变已在运行的 vLLM，请在没有进行中的任务时手动重启本 demo 的模型服务。

默认最大输出由 16384 降为 8192，给工具调用留出更保守的输出空间。OpenClaw 2026.9.4
支持的 `compaction.midTurnPrecheck.enabled` 已开启：工具结果返回后、下一次模型请求之前
检查上下文压力。压缩使用 `thinkingLevel: "off"`，避免本地总结额外的推理开销。
这不会扩大模型真实窗口，也不保证视觉 token 的估算完全等同于 Qwen tokenizer。

界面中的 **Prompt budget (last run)** 是扣除压缩预留后的提示词预算，不一定等于
vLLM 的窗口；例如 65536 的窗口可以显示约 49.2k。**Latest run input** 是多次模型
请求的累计用量，不代表同一请求装入了全部 token。仅凭高百分比或“Compacting context”
不能断定窗口配置错误。

vLLM/PyTorch 的 `TCPStore` / `should dump` 警告和 `deep_gemm` 导入问题应分别检查
原始启动日志、实际选中的 NVFP4 backend 和真实生成/工具调用结果。HTTP 200 或一份
AI 总结不能单独证明完全正常，也不要通过关闭 NCCL watchdog 或过滤日志来掩盖问题。
本仓库的启动器仍是 **GB10 / DGX Spark** 路径；Jetson Thor 的本地修改需要单独审查，
不要把 Spark 的 `sm_121a`、`flashinfer_b12x` 配置直接用于 Thor。

CPU-only 回归测试（无需模型或 GPU）：

```bash
python3 -m unittest discover -s scripts/tests -v
```

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
