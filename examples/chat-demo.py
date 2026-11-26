#!/usr/bin/env python3
"""Local JSON session demo, not an AI provider. Never opens project files."""
import json
import sys

request = json.load(sys.stdin)
message = "HodoCodeセッションデモ（AI未接続・変更なし）\n"
message += f"会話履歴: {len(request.get('history', []))}件\n"
message += "デモ: " + request["prompt"]
print(json.dumps({"message": message}, ensure_ascii=False))
