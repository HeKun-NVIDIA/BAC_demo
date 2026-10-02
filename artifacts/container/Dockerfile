ARG BASE_IMAGE=vllm-node:latest
FROM ${BASE_IMAGE}

ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple
ARG PIP_EXTRA_INDEX_URL=https://pypi.org/simple

ENV PIP_INDEX_URL=${PIP_INDEX_URL} \
    PIP_EXTRA_INDEX_URL=${PIP_EXTRA_INDEX_URL} \
    UV_INDEX_URL=${PIP_INDEX_URL} \
    UV_EXTRA_INDEX_URL=${PIP_EXTRA_INDEX_URL} \
    MAX_JOBS=8 \
    CUTE_DSL_ARCH=sm_121a \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1

# Aliyun is the primary package source for mainland-China preparation.
# The official index is a fallback only for architecture-specific wheels not
# mirrored there yet.
RUN if command -v uv >/dev/null 2>&1; then \
      uv pip install --system --upgrade \
        "vllm==0.28.0" \
        "flashinfer-python==0.6.16.post3" \
        "nvidia-cutlass-dsl>=4.6.2"; \
    else \
      python3 -m pip install --upgrade \
        "vllm==0.28.0" \
        "flashinfer-python==0.6.16.post3" \
        "nvidia-cutlass-dsl>=4.6.2"; \
    fi

# Public nightlies carry AOT cubins and architecture-specific JIT cache
# namespace packages. vLLM 0.28 + FlashInfer 0.6.16 must not import those 0.7
# leftovers. pip uninstall leaves namespace directories behind, so remove both
# metadata and modules explicitly and let 0.6.16 JIT into the mounted cache.
RUN python3 -m pip uninstall -y flashinfer-cubin flashinfer-jit-cache || true && \
    rm -rf \
      /usr/local/lib/python3.12/dist-packages/flashinfer_cubin* \
      /usr/local/lib/python3.12/dist-packages/flashinfer_jit_cache*

RUN python3 - <<'PY'
from importlib.metadata import version
assert version("vllm") == "0.28.0"
assert version("flashinfer-python") == "0.6.16.post3"
print("vllm", version("vllm"))
print("flashinfer-python", version("flashinfer-python"))
print("nvidia-cutlass-dsl", version("nvidia-cutlass-dsl"))
PY

ENTRYPOINT []
CMD ["bash"]

