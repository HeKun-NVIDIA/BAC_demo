"""USB 摄像头实时人脸检测 + 本地 Qwen 看图描述。"""

import base64
import os
import threading
import time

import cv2
import numpy as np
import requests
from flask import Flask, Response, jsonify

# ==================== 作品设计 开始 ====================
DESIGN = {
    "title": "Spark 视觉实验室",
    "subtitle": "USB 摄像头 · OpenCV 实时人脸检测 · 本地 Qwen 看图",
    # 主题色（按钮、标题装饰）
    "accent": "#76b900",
    # 页面背景
    "background": "#0d1117",
    # 文字颜色（浅色背景时改成深色）
    "text": "#e6edf3",
    # 卡片和按钮底色
    "panel": "#161b22",
    # 人脸框颜色
    "box_color": "#76b900",
    "box_thickness": 3,
    # 人脸框上方显示编号
    "show_label": True,
    # 检测缩放步长，越小越精细但越慢
    "scale_factor": 1.1,
    # 越大越严格，误检越少
    "min_neighbors": 4,
    # 最小人脸尺寸（像素）
    "min_face": 60,
    # 镜像画面
    "mirror": True,
    "width": 640,
    "height": 480,
    "describe_prompt": "请用两三句中文描述这张摄像头画面：画面里有几个人、他们在做什么、周围环境是什么样的。",
}
# ==================== 作品设计 结束 ====================

PORT = int(os.environ.get("PORT", "18090"))
QWEN_URL = "http://127.0.0.1:18000/v1/chat/completions"
QWEN_MODEL = "nvidia/Qwen3.6-35B-A3B-NVFP4"


def bgr(hex_color):
    value = hex_color.lstrip("#")
    r, g, b = (int(value[i:i + 2], 16) for i in (0, 2, 4))
    return (b, g, r)


class Camera:
    """One thread owns the device; requests only read the latest locked copy."""

    def __init__(self):
        self.lock = threading.Lock()
        self.raw = None
        self.jpeg = None
        self.faces = 0
        self.fps = 0.0
        self.detect = True
        self.error = ""
        self.cascade = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
        threading.Thread(target=self.run, daemon=True).start()

    def open(self):
        cap = cv2.VideoCapture(0, cv2.CAP_V4L2)
        cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, DESIGN["width"])
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, DESIGN["height"])
        for _ in range(20):
            ok, frame = cap.read()
            if ok and frame is not None:
                return cap
            time.sleep(0.05)
        cap.release()
        return None

    def show_message(self, text):
        frame = np.zeros((DESIGN["height"], DESIGN["width"], 3), dtype=np.uint8)
        cv2.putText(frame, text, (40, DESIGN["height"] // 2), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (200, 200, 200), 2)
        ok, buffer = cv2.imencode(".jpg", frame)
        if ok:
            with self.lock:
                self.jpeg = buffer.tobytes()

    def run(self):
        cap = None
        last = time.time()
        color = bgr(DESIGN["box_color"])
        while True:
            if cap is None:
                cap = self.open()
                if cap is None:
                    self.error = "无法打开摄像头 /dev/video0"
                    self.show_message("Camera not available")
                    time.sleep(1)
                    continue
                self.error = ""
            ok, frame = cap.read()
            if not ok or frame is None:
                cap.release()
                cap = None
                continue
            if DESIGN["mirror"]:
                frame = cv2.flip(frame, 1)
            raw = frame.copy()
            count = 0
            if self.detect:
                gray = cv2.equalizeHist(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY))
                size = DESIGN["min_face"]
                faces = self.cascade.detectMultiScale(
                    gray, scaleFactor=DESIGN["scale_factor"], minNeighbors=DESIGN["min_neighbors"], minSize=(size, size)
                )
                for index, (x, y, w, h) in enumerate(faces, 1):
                    cv2.rectangle(frame, (x, y), (x + w, y + h), color, DESIGN["box_thickness"])
                    if DESIGN["show_label"]:
                        cv2.putText(frame, f"Face {index}", (x, max(20, y - 10)), cv2.FONT_HERSHEY_SIMPLEX, 0.7, color, 2)
                count = len(faces)
            now = time.time()
            if now > last:
                self.fps = 0.9 * self.fps + 0.1 * (1.0 / (now - last))
            last = now
            ok, buffer = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
            if ok:
                with self.lock:
                    self.raw = raw
                    self.jpeg = buffer.tobytes()
                    self.faces = count

    def latest(self):
        with self.lock:
            return (None if self.raw is None else self.raw.copy()), self.jpeg


camera = Camera()
app = Flask(__name__)

PAGE = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="icon" href="data:,">
<title>__TITLE__</title>
<style>
  body { margin: 0; background: __BG__; color: __TEXT__; font-family: system-ui, "PingFang SC", "Noto Sans CJK SC", sans-serif; }
  header { padding: 22px 32px 8px; }
  h1 { margin: 0; font-size: 28px; } h1 span { color: __ACCENT__; }
  .sub { opacity: 0.7; margin-top: 6px; }
  main { display: flex; gap: 24px; padding: 16px 32px 32px; flex-wrap: wrap; }
  .video { flex: 1 1 640px; max-width: 900px; border-radius: 14px; overflow: hidden; border: 2px solid __ACCENT__55; background: #000; }
  .video img { width: 100%; display: block; }
  aside { flex: 0 1 340px; display: flex; flex-direction: column; gap: 14px; }
  .stats { display: flex; gap: 12px; }
  .stat { flex: 1; background: __PANEL__; border-radius: 12px; padding: 14px; text-align: center; }
  .stat b { display: block; font-size: 30px; color: __ACCENT__; }
  button { border: none; border-radius: 10px; padding: 14px; font-size: 17px; font-weight: 700; cursor: pointer; font-family: inherit; }
  #btnDescribe { background: __ACCENT__; color: #0b0f14; }
  #btnToggle { background: __PANEL__; color: __TEXT__; }
  button:disabled { opacity: 0.6; cursor: wait; }
  #describeArea { background: __PANEL__; border-radius: 12px; padding: 16px; line-height: 1.7; min-height: 120px; white-space: pre-wrap; }
  #error { color: #ff7b72; }
</style></head><body>
<header><h1><span>●</span> __TITLE__</h1><div class="sub">__SUBTITLE__</div></header>
<main>
  <div class="video"><img src="/video_feed" alt="摄像头画面"></div>
  <aside>
    <div class="stats"><div class="stat"><b id="fps">0</b>FPS</div><div class="stat"><b id="faces">0</b>检测到的人脸</div></div>
    <button id="btnDescribe">✨ AI 描述画面</button>
    <button id="btnToggle">人脸检测：开</button>
    <div id="describeArea">点击“AI 描述画面”，本地 Qwen 会描述当前画面。</div>
    <div id="error"></div>
  </aside>
</main>
<script>
const $ = (id) => document.getElementById(id);
async function poll() {
  try {
    const s = await fetch("/status").then((r) => r.json());
    $("fps").textContent = s.fps.toFixed(1);
    $("faces").textContent = s.faces;
    $("btnToggle").textContent = "人脸检测：" + (s.detect ? "开" : "关");
    $("error").textContent = s.error;
  } catch (e) {}
}
setInterval(poll, 700);
poll();
$("btnToggle").onclick = () => fetch("/toggle-detection", { method: "POST" }).then(poll);
$("btnDescribe").onclick = async () => {
  $("btnDescribe").disabled = true;
  $("describeArea").textContent = "正在分析画面…";
  try {
    const r = await fetch("/describe", { method: "POST" }).then((x) => x.json());
    $("describeArea").textContent = r.text || r.error;
  } catch (e) {
    $("describeArea").textContent = "描述失败：" + e.message;
  } finally {
    $("btnDescribe").disabled = false;
  }
};
</script></body></html>"""


@app.route("/")
def index():
    html = (PAGE.replace("__TITLE__", DESIGN["title"]).replace("__SUBTITLE__", DESIGN["subtitle"])
            .replace("__ACCENT__", DESIGN["accent"]).replace("__BG__", DESIGN["background"])
            .replace("__TEXT__", DESIGN["text"]).replace("__PANEL__", DESIGN["panel"]))
    return html


@app.route("/video_feed")
def video_feed():
    def frames():
        while True:
            _, jpeg = camera.latest()
            if jpeg:
                yield b"--frame\r\nContent-Type: image/jpeg\r\n\r\n" + jpeg + b"\r\n"
            time.sleep(1 / 25)
    return Response(frames(), mimetype="multipart/x-mixed-replace; boundary=frame")


@app.route("/status")
def status():
    return jsonify(fps=round(camera.fps, 1), faces=camera.faces, detect=camera.detect, error=camera.error)


@app.route("/snapshot")
def snapshot():
    raw, _ = camera.latest()
    if raw is None:
        return jsonify(error="摄像头尚未就绪"), 503
    ok, buffer = cv2.imencode(".jpg", raw)
    return jsonify(image="data:image/jpeg;base64," + base64.b64encode(buffer.tobytes()).decode(),
                   fps=round(camera.fps, 1), faces=camera.faces)


@app.route("/toggle-detection", methods=["POST"])
def toggle_detection():
    camera.detect = not camera.detect
    return jsonify(detect=camera.detect)


@app.route("/describe", methods=["POST"])
def describe():
    raw, _ = camera.latest()
    if raw is None:
        return jsonify(error="摄像头尚未就绪"), 503
    scale = 640 / max(raw.shape[1], 1)
    small = cv2.resize(raw, None, fx=scale, fy=scale) if scale < 1 else raw
    ok, buffer = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 85])
    image = "data:image/jpeg;base64," + base64.b64encode(buffer.tobytes()).decode()
    payload = {
        "model": QWEN_MODEL,
        "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": image}},
            {"type": "text", "text": DESIGN["describe_prompt"]},
        ]}],
        "max_tokens": 300,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    try:
        reply = requests.post(QWEN_URL, json=payload, timeout=120).json()
        return jsonify(text=reply["choices"][0]["message"]["content"].strip())
    except Exception as error:
        return jsonify(error=f"AI 描述失败：{error}"), 502


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT, threaded=True)
