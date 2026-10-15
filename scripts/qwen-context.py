#!/usr/bin/env python3
"""Read the effective context limit advertised by the running vLLM server."""

import json
import sys


def resolve_context(models, model_id):
    if not isinstance(models, dict) or not isinstance(models.get("data"), list):
        raise ValueError("invalid /v1/models response")
    matches = [row for row in models["data"]
               if isinstance(row, dict) and row.get("id") == model_id]
    if len(matches) != 1:
        raise ValueError("configured Qwen model is missing or ambiguous")
    limit = matches[0].get("max_model_len")
    if type(limit) is not int or limit <= 0:
        raise ValueError("Qwen max_model_len must be a positive integer")
    return limit


def main():
    try:
        if len(sys.argv) != 2:
            raise ValueError("expected the served Qwen model ID")
        print(resolve_context(json.load(sys.stdin), sys.argv[1]))
    except (ValueError, TypeError) as error:
        print(f"Cannot determine Qwen context: {error}. "
              "Check scripts/model-ctl.sh status and logs qwen before resetting OpenClaw.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
