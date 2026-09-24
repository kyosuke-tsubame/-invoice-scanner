#!/usr/bin/env python3
"""経理アプリ（keiri-app）の「納品書仕分け → 送る」で本部が送った写真を、OneDriveの受信箱へ入れる。

run_invoice_ocr.sh の最初（仕分けの前）に呼ぶ。受信箱に入れてしまえば、あとは upload.html から届いた写真と
まったく同じ仕分け・読み取りが動く。ファイル名は経理アプリが upload.html と同じ形
（YYYYMMDD_HHMMSS_乱数6桁_元の名前）で付けているので、読み取り後に push_scans_to_keiri.py が
同じファイル名で結果を送ると、経理アプリの「読み取り待ち」の行がそのまま「登録済み／要確認」になる。

入れ終わった写真は経理アプリに知らせる（以後、経理アプリ側で「送信の取り消し」ができなくなる）。
失敗した写真は知らせないので、次の晩にやり直す。

手動テスト：
  python3 pull_app_uploads.py --dry-run     受信箱へ入れずに、届いている枚数だけ表示
  KEIRI_API_BASE=http://localhost:3000 で相手先を、INVOICE_INBOX_DIR=<作業用フォルダ> で入れ先を差し替えられる
2026-09-25 作成。
"""
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
# 試験時だけ INVOICE_INBOX_DIR で入れ先を差し替えられる（本物の受信箱に入れると今夜の仕分けに混ざるため）
INBOX_DIR = os.environ.get("INVOICE_INBOX_DIR") or os.path.join(HOME, "Library", "CloudStorage", "OneDrive-個人用", "納品書写真", "受信箱")
ENV_FILE = os.path.join(HOME, "Claude", "keiri-app", ".env.local")
API_BASE = os.environ.get("KEIRI_API_BASE", "https://keiri-app-one.vercel.app")
SAFE_NAME = re.compile(r"^\d{8}_\d{6}_[a-z0-9]{6}_[A-Za-z0-9_-]{1,40}\.(jpg|png)$")


def read_env():
    env = {}
    with open(ENV_FILE, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'^\s*([A-Z_]+)\s*=\s*"?([^"\n]*)"?\s*$', line)
            if m:
                env[m.group(1)] = m.group(2)
    return env


def request(method, path, auth, raw=False):
    req = urllib.request.Request(
        f"{API_BASE}{path}",
        method=method,
        data=b"{}" if method == "POST" else None,
        headers={"Authorization": "Basic " + base64.b64encode(auth.encode()).decode(), "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as res:
        body = res.read()
        return body if raw else json.loads(body.decode("utf-8"))


def main():
    dry = "--dry-run" in sys.argv
    auth = "{BASIC_AUTH_USER}:{BASIC_AUTH_PASS}".format(**read_env())
    items = request("GET", "/api/invoice-scans/queued", auth)
    print(f"経理アプリから届いている写真：{len(items)}枚")
    if dry or not items:
        return
    os.makedirs(INBOX_DIR, exist_ok=True)
    ok, failed = 0, []
    for it in items:
        name = it.get("sourceKey", "")
        if not SAFE_NAME.match(name):
            failed.append(f"{name}：ファイル名の形が想定外")
            continue
        dest = os.path.join(INBOX_DIR, name)
        try:
            if not os.path.exists(dest):
                data = request("GET", f"/api/invoice-scans/{it['id']}/image", auth, raw=True)
                tmp = dest + ".part"
                with open(tmp, "wb") as f:
                    f.write(data)
                os.replace(tmp, dest)  # 書き終わってから名前を付ける（仕分けが書きかけを拾わないように）
            request("POST", f"/api/invoice-scans/{it['id']}/handed", auth)
            ok += 1
        except (urllib.error.URLError, OSError) as e:
            failed.append(f"{name}：{e}")
    print(f"受信箱へ入れた：{ok}枚")
    for x in failed:
        print("  失敗（次の晩にやり直す）:", x)


if __name__ == "__main__":
    main()
