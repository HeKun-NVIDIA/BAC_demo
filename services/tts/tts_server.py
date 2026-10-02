#!/usr/bin/env python3
"""OpenAI-compatible speech endpoint backed by a local Qwen3-TTS CustomVoice model.

POST /v1/audio/speech  {"input": "...", "voice": "vivian", "response_format": "wav"}
GET  /v1/audio/voices, /v1/models, /health
"""

from __future__ import annotations

import io
import json
import os
import re
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import torch
from qwen_tts import Qwen3TTSModel

MODEL_DIR = os.environ.get("TTS_MODEL_DIR", "/models/qwen3-tts")
PORT = int(os.environ.get("TTS_PORT", "18002"))
DEFAULT_SPEAKER = os.environ.get("TTS_DEFAULT_SPEAKER", "vivian")
MODEL_ID = "qwen3-tts"
MAX_INPUT_CHARS = 3000
CHUNK_CHARS = 150

# OpenAI clients send their own voice names; map them onto Qwen speakers.
OPENAI_VOICE_ALIASES = {
    "alloy": "vivian", "nova": "vivian", "sage": "vivian", "shimmer": "serena",
    "coral": "serena", "ballad": "serena", "echo": "dylan", "verse": "aiden",
    "onyx": "uncle_fu", "fable": "eric", "ash": "ryan",
}
CJK = re.compile(r"[\u3400-\u9fff]")
SENTENCE_END = re.compile(r"(?<=[。！？!?；;\n])")

torch.backends.cuda.matmul.allow_tf32 = True
MODEL = Qwen3TTSModel.from_pretrained(
    MODEL_DIR, device_map="cuda:0", dtype=torch.bfloat16, attn_implementation="sdpa"
)
SPEAKERS = sorted(MODEL.get_supported_speakers() or [])
LOCK = threading.Lock()


def resolve_speaker(requested: str | None) -> str:
    name = (requested or DEFAULT_SPEAKER).strip().lower()
    name = OPENAI_VOICE_ALIASES.get(name, name)
    return name if name in SPEAKERS else DEFAULT_SPEAKER


def split_text(text: str) -> list[str]:
    chunks: list[str] = []
    current = ""
    for sentence in (s.strip() for s in SENTENCE_END.split(text)):
        if not sentence:
            continue
        if current and len(current) + len(sentence) > CHUNK_CHARS:
            chunks.append(current)
            current = sentence
        else:
            current += sentence
    if current:
        chunks.append(current)
    return chunks or [text]


def synthesize(text: str, speaker: str, language: str | None, instruct: str | None,
               speed: float) -> tuple[np.ndarray, int]:
    chunks = split_text(text)
    if not language:
        language = "Chinese" if CJK.search(text) else "English"
    with LOCK:
        wavs, rate = MODEL.generate_custom_voice(
            text=chunks,
            speaker=[speaker] * len(chunks),
            language=[language] * len(chunks),
            instruct=[instruct or ""] * len(chunks),
        )
    gap = np.zeros(int(rate * 0.12), dtype=np.float32)
    pieces: list[np.ndarray] = []
    for index, piece in enumerate(wavs):
        pieces.append(np.asarray(piece, dtype=np.float32).reshape(-1))
        if index < len(wavs) - 1:
            pieces.append(gap)
    audio = np.concatenate(pieces)
    if abs(speed - 1.0) > 0.01:
        import librosa

        audio = librosa.effects.time_stretch(audio, rate=max(0.5, min(speed, 2.0)))
    return audio, rate


def to_pcm16(audio: np.ndarray) -> bytes:
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    if peak > 1.0:
        audio = audio / peak
    return (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()


def to_wav(audio: np.ndarray, rate: int) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(to_pcm16(audio))
    return buffer.getvalue()


class Handler(BaseHTTPRequestHandler):
    server_version = "QwenTTS/1.0"

    def log_message(self, fmt: str, *args) -> None:  # noqa: D401
        print(f"[tts] {self.address_string()} {fmt % args}", flush=True)

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/health"):
            self._json(200, {"ok": True, "model": MODEL_ID, "speakers": SPEAKERS})
        elif self.path.startswith("/v1/models"):
            self._json(200, {"object": "list", "data": [{"id": MODEL_ID, "object": "model"}]})
        elif self.path.startswith("/v1/audio/voices"):
            self._json(200, {"voices": SPEAKERS, "default": DEFAULT_SPEAKER})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if not self.path.startswith("/v1/audio/speech"):
            self._json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            request = json.loads(self.rfile.read(length) or b"{}")
            text = str(request.get("input") or "").strip()
            if not text:
                raise ValueError("input is required")
            if len(text) > MAX_INPUT_CHARS:
                raise ValueError(f"input longer than {MAX_INPUT_CHARS} characters")
            started = time.time()
            audio, rate = synthesize(
                text,
                resolve_speaker(request.get("voice")),
                request.get("language"),
                request.get("instructions"),
                float(request.get("speed") or 1.0),
            )
        except (ValueError, json.JSONDecodeError) as exc:
            self._json(400, {"error": str(exc)})
            return
        except Exception as exc:  # noqa: BLE001
            self._json(500, {"error": f"synthesis failed: {exc}"})
            return

        if request.get("response_format") == "pcm":
            body, content_type = to_pcm16(audio), "audio/pcm"
        else:
            # No MP3 encoder in the runtime image; WAV is returned for every other format.
            body, content_type = to_wav(audio, rate), "audio/wav"
        print(f"[tts] {len(text)} chars -> {audio.size / rate:.1f}s audio "
              f"in {time.time() - started:.1f}s", flush=True)
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    synthesize("你好。", DEFAULT_SPEAKER, "Chinese", None, 1.0)
    print(f"[tts] ready on 127.0.0.1:{PORT}, speakers={SPEAKERS}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
