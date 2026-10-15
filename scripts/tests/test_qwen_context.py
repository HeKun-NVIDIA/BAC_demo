#!/usr/bin/env python3
"""CPU-only tests; no model download or GPU is required."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import shutil
import os
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/qwen-context.py"
MODEL = "nvidia/Qwen3.6-35B-A3B-NVFP4"


class QwenContextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("qwen_context", HELPER)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_server_limit_not_model_card_or_first_model(self):
        models = {"data": [
            {"id": "other-model", "max_model_len": 131072},
            {"id": MODEL, "max_model_len": 49152},
        ]}
        self.assertEqual(self.module.resolve_context(models, MODEL), 49152)

    def test_default_spark_limit(self):
        self.assertEqual(self.module.resolve_context(
            {"data": [{"id": MODEL, "max_model_len": 131072}]}, MODEL
        ), 131072)

    def test_missing_model_fails_instead_of_using_another_limit(self):
        with self.assertRaises(ValueError):
            self.module.resolve_context({"data": [{"id": "other", "max_model_len": 49152}]}, MODEL)

    def test_invalid_or_missing_limits_fail(self):
        for value in (None, 0, -1, True, "49152", 49152.5):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.module.resolve_context({"data": [{"id": MODEL, "max_model_len": value}]}, MODEL)

    def test_stdin_cli_reports_only_limit(self):
        result = subprocess.run(
            [sys.executable, str(HELPER), MODEL],
            input=json.dumps({"data": [{"id": MODEL, "max_model_len": 49152}]}),
            capture_output=True, text=True, check=True,
        )
        self.assertEqual(result.stdout, "49152\n")

    def test_bad_response_cli_is_actionable(self):
        result = subprocess.run([sys.executable, str(HELPER), MODEL],
                                input="not JSON", capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("model-ctl.sh", result.stderr)
        self.assertEqual(result.stdout, "")


class ResetContextTests(unittest.TestCase):
    def setUp(self):
        # Exercise the real reset entry point with only external services stubbed.
        self.temp = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("reset-openclaw.sh", "qwen-context.py"):
            source = ROOT / "scripts" / name
            if source.exists():
                shutil.copy(source, scripts / name)
        for relative in ("openclaw/workspace-template", "openclaw/config", "outputs", "runtime"):
            (self.root / relative).mkdir(parents=True)
        shutil.copy(ROOT / "openclaw/config/openclaw.template.json",
                    self.root / "openclaw/config/openclaw.template.json")
        (scripts / "lib.sh").write_text(
            'DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"\n'
            'DEMO_RUNTIME="$DEMO_ROOT/runtime"\nDEMO_WORKSPACE="$DEMO_ROOT/workspace"\n'
            'DEMO_OUTPUTS="$DEMO_ROOT/outputs"\nOPENCLAW_HOME="$DEMO_ROOT/state"\n'
            'OPENCLAW_BIN="$DEMO_ROOT/scripts/openclaw-ctl.sh"\nCHROMIUM_BIN=/unused/chromium\n'
            'OPENCLAW_PORT=13001\nQWEN_PORT=18000\nTTS_PORT=18002\nSHOWCASE_PORT=18088\nNEMOTRON_PORT=18001\n'
            f'QWEN_MODEL_ID="{MODEL}"\nQWEN_BASE_URL=http://127.0.0.1:18000/v1\n'
            'lan_ip() { echo 127.0.0.1; }\nkill_participant_processes() { :; }\n'
            'ok() { :; }\ninfo() { :; }\ndie() { echo "$*" >&2; exit 1; }\n'
        )
        for name in ("openclaw-ctl.sh", "curl"):
            path = scripts / name
            path.write_text("#!/bin/bash\n" + ('cat "$MODEL_RESPONSE"\n' if name == "curl" else "exit 0\n"))
            path.chmod(0o755)
        self.response = self.root / "models.json"
        self.env = dict(os.environ, PATH=f"{scripts}:/usr/bin:/bin", MODEL_RESPONSE=str(self.response))
        self.config = self.root / "state/.openclaw/openclaw.json"

    def reset(self, limit):
        self.response.write_text(json.dumps({"data": [{"id": MODEL, "max_model_len": limit}]}))
        return subprocess.run(["bash", str(self.root / "scripts/reset-openclaw.sh")],
                              capture_output=True, text=True, env=self.env)

    def test_reset_uses_running_server_limit(self):
        for limit in (131072, 65536, 49152):
            with self.subTest(limit=limit):
                result = self.reset(limit)
                self.assertEqual(result.returncode, 0, result.stderr)
                config = json.loads(self.config.read_text())
                model = config["models"]["providers"]["qwen-local"]["models"][0]
                self.assertEqual(model["contextWindow"], limit)
                self.assertEqual(model["maxTokens"], 8192)
                compaction = config["agents"]["defaults"]["compaction"]
                self.assertTrue(compaction["midTurnPrecheck"]["enabled"])
                self.assertEqual(compaction["thinkingLevel"], "off")
                self.assertEqual(model["compat"]["thinkingFormat"], "qwen-chat-template")

    def test_invalid_server_limit_does_not_erase_existing_state(self):
        self.config.parent.mkdir(parents=True)
        self.config.write_text("existing-state")
        result = self.reset(None)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.config.read_text(), "existing-state")


if __name__ == "__main__":
    unittest.main()
