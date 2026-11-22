#!/usr/bin/env python3
"""Local UI demo, not an AI provider. Reads only the supplied prepared JSON."""
import json
import sys

request = json.load(sys.stdin)
buffer = request['buffer']
comments = [
    {'file': buffer['file'], 'line': index, 'text': 'UIデモ（AI未接続）：この行に解説が表示されます。\n全文ポップアップの表示確認です。'}
    for index, line in enumerate(buffer['content'].splitlines(), 1)
    if line.strip()
][:20]
json.dump({'version': buffer['version'], 'message': 'ローカルUIデモです。AIへは送信していません。',
           'comments': comments}, sys.stdout, ensure_ascii=False)
