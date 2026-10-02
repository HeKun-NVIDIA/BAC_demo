#!/usr/bin/env bash
# Python environment OpenClaw uses for the apps it writes (OpenCV camera
# servers, Flask, image processing). Built offline from bundled wheels.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

SYSTEM_PYTHON="${SYSTEM_PYTHON:-/usr/bin/python3}"
WHEELS="$DEMO_ROOT/artifacts/wheels/pyenv"
# OpenCV 5 dropped CascadeClassifier/Haar data and HOG, which generated
# face-detection code relies on; stay on 4.x.
PACKAGES=("opencv-python-headless>=4.10,<5" numpy flask pillow requests)
IMPORT_CHECK='import cv2, flask, numpy, PIL, requests; cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")'

if [[ -x "$DEMO_PYENV/bin/python" ]] && "$DEMO_PYENV/bin/python" -c "$IMPORT_CHECK" 2>/dev/null; then
  skip "Python 应用环境已就绪（OpenCV $("$DEMO_PYENV/bin/python" -c 'import cv2; print(cv2.__version__)')）"
  exit 0
fi

[[ -x "$SYSTEM_PYTHON" ]] || die "缺少 $SYSTEM_PYTHON"
info "创建 Python 应用环境: $DEMO_PYENV"
rm -rf "$DEMO_PYENV"
if ! "$SYSTEM_PYTHON" -m venv "$DEMO_PYENV" 2>/dev/null; then
  # Hosts without python3-venv's ensurepip: bootstrap pip from its own wheel.
  rm -rf "$DEMO_PYENV"
  "$SYSTEM_PYTHON" -m venv --without-pip "$DEMO_PYENV"
  pip_wheel="$(compgen -G "$WHEELS/pip-*.whl" | head -1 || true)"
  [[ -n "$pip_wheel" ]] || die "系统缺少 python3-venv，且 bundle 中没有 pip wheel"
  "$DEMO_PYENV/bin/python" "$pip_wheel/pip" install --no-index --find-links "$WHEELS" pip
fi

pip_run() {
  "$DEMO_PYENV/bin/python" -m pip --disable-pip-version-check "$@"
}
if ! compgen -G "$WHEELS/opencv_python_headless-4.*.whl" >/dev/null; then
  info "离线 wheels 缺失，从阿里云 PyPI 镜像下载"
  mkdir -p "$WHEELS"
  pip_run download --index-url "$PIP_INDEX_URL" --dest "$WHEELS" \
    pip setuptools wheel "${PACKAGES[@]}"
fi
pip_run install --no-index --find-links "$WHEELS" "${PACKAGES[@]}"
"$DEMO_PYENV/bin/python" -c "$IMPORT_CHECK" || die "Python 应用环境校验失败"
ok "Python 应用环境就绪（OpenCV $("$DEMO_PYENV/bin/python" -c 'import cv2; print(cv2.__version__)')）"
