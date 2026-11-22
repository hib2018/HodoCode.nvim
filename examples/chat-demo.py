#!/usr/bin/env python3
"""Local terminal demo, not an AI provider. Never opens project files."""
import json
import sys

with open(sys.argv[1], encoding='utf-8') as stream:
    context = json.load(stream)
buffer = context['buffer']
print('HodoCodeチャットUIデモ（AI未接続・読み取り専用）', flush=True)
print(f"対象: {buffer['file']} / 固定スナップショット: {buffer['version'][:12]}", flush=True)
print('入力は復唱だけします。/quit または Ctrl-D で終了。', flush=True)
for line in sys.stdin:
    if line.strip() == '/quit':
        break
    print('デモ: ' + line.rstrip(), flush=True)
