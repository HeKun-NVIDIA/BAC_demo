# 中国大陆模型制备与迁移

## 当前策略

`scripts/download-models.sh` 按以下顺序执行：

1. 检查魔搭社区是否存在**完全相同**的 NVFP4 仓库。
2. 若存在，直接通过 ModelScope REST API 读取文件清单并用 `curl` 下载，不要求目标机预装 `modelscope`。
3. 若不存在，通过 `hf-mirror.com` 的固定 revision 下载。
4. Qwen3-TTS 从魔搭 `Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice` 下载。
5. 下载后模型是 `models/qwen/`、`models/qwen3-tts/`（以及可选的
   `models/nemotron/`）中的普通实体文件；
   目标 DGX Spark 不再访问任何模型社区。

单文件 `install.sh` 还会通过 `docker.1ms.run` 国内代理拉取 NVIDIA 模型卡推荐的
`vllm/vllm-openai:nightly` ARM64 镜像，并固定到平台 manifest digest
`sha256:6a8b606d...d51368`；代理失败时回退到 Docker Hub 的相同 digest。
派生镜像固定安装 vLLM 0.28.0、FlashInfer 0.6.16.post3，并在启动后校验
FLASHINFER_B12X NVFP4 backend。

不能把魔搭现有的 Qwen FP8 或 Nemotron GGUF 静默替换成计划中的 NVFP4：
量化格式、vLLM 参数、内存和工具调用行为都不同。

## 使用团队自己的魔搭镜像仓库

若后续把精确 snapshot 同步到组织的魔搭仓库，设置：

```bash
export MODELSCOPE_QWEN_REPO="your-org/Qwen3.6-35B-A3B-NVFP4"
export MODELSCOPE_NEMOTRON_REPO="your-org/Nemotron-3-Nano-Omni-NVFP4"
bash scripts/download-models.sh all
```

脚本会在下载前调用 ModelScope API 验证仓库存在；找不到精确仓库时才改用
HF 国内镜像，不会静默替换成其他量化模型。

## 断点续传

默认下载器把未完成文件保留为 `*.partial`，重跑相同命令会从已有字节继续。
完成后 `scripts/verify-models.py` 会根据 safetensors index 与远程文件大小检查
每个分片。

## 分发

推荐一次下载、多次 U 盘/局域网分发：

```bash
scripts/pack.sh --split 20G
```

接收端先校验 `*.parts.sha256`，合并分卷，再解压并执行 `./install.sh`。

