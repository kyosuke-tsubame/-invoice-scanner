#!/usr/bin/env python3
"""
納品書スキャナーのApps Script（スプレッドシート連携）を呼び出す。
curlだと（原因不明だが）Google側にブロックされ「ファイルを開けません」という
Googleドライブのエラーページが返ってくることが判明したため、代わりにこのスクリプトを使う。

使い方:
  python3 call_gas.py <action> '<JSON文字列のペイロード>'

  例:
  python3 call_gas.py checkDuplicate '{"rows":[{"date":"2026-08-15","store":"本店","total":3950}]}'
  python3 call_gas.py save '{"rows":[{"date":"2026-08-15","store":"本店","supplier":"株式会社マルフク","total":3950,"category":"仕入れ"}]}'

  レスポンス本文をそのまま標準出力に印字する。
"""
import sys
import json
import urllib.request

APPS_SCRIPT_URL = "https://script.google.com/macros/s/AKfycbxl4ks1XumINgG0HrQqIOxc6j-97DTITwgRiD64-qUywfBag5q_-zyEa7ywWe5UqDt_/exec"


def main():
    if len(sys.argv) != 3:
        print("usage: call_gas.py <action> '<JSON payload>'", file=sys.stderr)
        sys.exit(1)

    action = sys.argv[1]
    try:
        payload = json.loads(sys.argv[2])
    except json.JSONDecodeError as e:
        print(f"ペイロードのJSON解析に失敗しました: {e}", file=sys.stderr)
        sys.exit(1)

    payload["action"] = action
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")

    req = urllib.request.Request(APPS_SCRIPT_URL, data=body, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            print(res.read().decode("utf-8", errors="replace"))
    except urllib.error.URLError as e:
        print(f"通信エラー: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
