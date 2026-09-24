#!/usr/bin/env python3
"""夜の納品書読み取りの結果（invoice_ocr_state.json）を、写真つきで経理アプリ（keiri-app）の「納品書仕分け」へ送る。

run_invoice_ocr.sh の最後に呼ぶ（Excel台帳への記帳はこれまでどおり続ける＝しばらく並行）。
まだ送っていない写真を1枚ずつ、長辺1600pxのJPEGに縮めて POST /api/invoice-scans へ送る。
経理アプリ側で改めてチェックし、自信のあるものは取引登録まで自動、引っかかるものは「要確認」になる。
送り終わったら、保管期間（90日）を過ぎた写真を経理アプリから消す（POST /api/invoice-scans/cleanup）。

状態の対応：
  auto_saved         → そのまま送る（経理アプリがチェックして登録 or 要確認）
  held_for_review    → 要確認（理由＝保留のメモ）
  skipped            → 記帳しない
  resolved_duplicate → 記帳しない（重複）
送った写真は keiri_sent.txt に受信箱のファイル名で記録する（仕分けの記録・状態ファイルとは別）。
送った後に Mac mini 側（8766番の画面・Slack返信）で直しても経理アプリには反映されない。直すのは経理アプリの画面で。

手動テスト：
  python3 push_scans_to_keiri.py --dry-run          送らずに、送る予定の件数と内訳を表示
  python3 push_scans_to_keiri.py --limit 3          3枚だけ送る
  KEIRI_API_BASE=http://localhost:3000 で送り先を差し替えられる
2026-09-24 作成。
"""
import base64
import collections
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from materialize import allow_download  # noqa: E402  夜の自動起動でもOneDriveの写真を読めるようにする
from invoice_ledger import normalize_supplier  # noqa: E402  Excel台帳と同じ名寄せ（正式名称にそろえる）

HOME = os.path.expanduser("~")
STATE_FILE = os.path.join(HERE, "invoice_ocr_state.json")
SENT_FILE = os.path.join(HERE, "keiri_sent.txt")
ENV_FILE = os.path.join(HOME, "Claude", "keiri-app", ".env.local")
API_BASE = os.environ.get("KEIRI_API_BASE", "https://keiri-app-one.vercel.app")
NOTIFY = os.path.join(HOME, "Claude", "scripts", "notify_slack.sh")
SLACK_CHANNEL = "C0BRBFZ2N6R"  # #納品書通知


def read_env():
    env = {}
    with open(ENV_FILE, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'^\s*([A-Z_]+)\s*=\s*"?([^"\n]*)"?\s*$', line)
            if m:
                env[m.group(1)] = m.group(2)
    return env


def source_key(path):
    # 受信箱に届いたときのファイル名。仕分けで付いた「要確認_」は外す（何度付いても）
    name = os.path.basename(path)
    while name.startswith("要確認_"):
        name = name[len("要確認_"):]
    return name


def shrink(path):
    # 長辺1600px・JPEG（品質80）に縮めたバイト列を返す。読めなければ None
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as t:
        out = t.name
    try:
        r = subprocess.run(
            ["sips", "-Z", "1600", "-s", "format", "jpeg", "-s", "formatOptions", "80", path, "--out", out],
            capture_output=True, timeout=60,
        )
        if r.returncode != 0 or not os.path.getsize(out):
            return None
        with open(out, "rb") as f:
            return f.read()
    finally:
        try:
            os.unlink(out)
        except OSError:
            pass


def build_body(path, v, image):
    status = v.get("status")
    note = v.get("note") or None
    body = {
        "sourceKey": source_key(path),
        "store": "" if v.get("store") in (None, "不明") else v.get("store"),
        "supplier": normalize_supplier(v.get("supplier") or ""),
        "date": v.get("date") or None,
        "total": v.get("total"),
        "taxType": v.get("taxType") or "unknown",
        "aiNote": note,
        "humanMemo": v.get("humanMemo") or v.get("resolvedNote") or None,
        "processedAt": v.get("processedAt"),
        "holdReasons": [],
    }
    if status == "auto_saved" and body["taxType"] != "excluded":
        # Mac mini側で記帳済み（Excel台帳には税抜として記入済み）なのに税区分が「読めない/税込」のまま残っている過去分。
        # 台帳と同じく税抜として送り、元の税区分はメモに残す（夜の新しい分は読めなければMac mini側で要確認になる）
        memo = f"Mac mini側で税抜として記帳済み（読み取り時の税区分：{body['taxType']}）"
        body["humanMemo"] = memo + (f"／{body['humanMemo']}" if body["humanMemo"] else "")
        body["taxType"] = "excluded"
    if status == "held_for_review":
        body["holdReasons"] = [v.get("heldNote") or note or "Mac miniの読み取りで要確認"]
    elif status in ("skipped", "resolved_duplicate"):
        body["initialStatus"] = "discarded"
        if status == "resolved_duplicate":
            body["humanMemo"] = "重複（Mac mini側で処理済み）" + (f"／{body['humanMemo']}" if body["humanMemo"] else "")
    if image is not None:
        body["image"] = {"contentType": "image/jpeg", "data": base64.b64encode(image).decode()}
    return body


def api(path, auth, body):
    req = urllib.request.Request(
        f"{API_BASE}{path}",
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        method="POST",
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": "Basic " + base64.b64encode(auth.encode()).decode(),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as res:
            return json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}", "body": e.read().decode("utf-8", "replace")[:500]}
    except Exception as e:  # 通信の失敗は次の晩にやり直す
        return {"error": str(e)}


def notify(text):
    if os.path.exists(NOTIFY):
        subprocess.run([NOTIFY, SLACK_CHANNEL, text], check=False)


def main():
    dry = "--dry-run" in sys.argv
    limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None
    allow_download()

    with open(STATE_FILE, encoding="utf-8") as f:
        state = json.load(f)
    sent = set()
    if os.path.exists(SENT_FILE):
        with open(SENT_FILE, encoding="utf-8") as f:
            sent = {line.strip() for line in f if line.strip()}

    todo = [(p, v) for p, v in sorted(state.items()) if source_key(p) not in sent]
    print(f"状態ファイル {len(state)}件のうち、まだ送っていない分 {len(todo)}件")
    print("  内訳:", dict(collections.Counter(v.get("status") for _, v in todo)))
    if dry:
        missing = [p for p, _ in todo if not os.path.exists(p)]
        print(f"  写真が見つからないもの: {len(missing)}件", *missing[:5], sep="\n    ")
        return
    if limit is not None:
        todo = todo[:limit]

    auth = "{BASIC_AUTH_USER}:{BASIC_AUTH_PASS}".format(**read_env())
    result = collections.Counter()
    failures = []
    with open(SENT_FILE, "a", encoding="utf-8") as sent_f:
        for path, v in todo:
            image = shrink(path) if os.path.exists(path) else None
            if image is None and os.path.exists(path):
                failures.append(f"{os.path.basename(path)}：写真を読めなかった（次の晩にやり直す）")
                continue
            res = api("/api/invoice-scans", auth, build_body(path, v, image))
            if "error" in res:
                failures.append(f"{os.path.basename(path)}：{res.get('error')} {res.get('body', '')}")
                continue
            key = "duplicate" if res.get("duplicate") else res.get("status", "?")
            result[key] += 1
            if image is None:
                result["写真なし"] += 1
            sent_f.write(source_key(path) + "\n")
            sent_f.flush()

    cleanup = api("/api/invoice-scans/cleanup", auth, {})
    labels = {"posted": "登録", "review": "要確認", "discarded": "記帳しない", "duplicate": "送信済みだった"}
    summary = "、".join(f"{labels.get(k, k)} {n}件" for k, n in result.items())
    print(f"送信結果：{summary or 'なし'}／写真の削除：{cleanup.get('deleted', cleanup.get('error'))}件")
    for x in failures:
        print("  失敗:", x)

    if result.get("review") or failures:
        msg = []
        if result.get("review"):
            msg.append(f"📥 経理アプリの「納品書仕分け」に要確認が {result['review']}件 増えました。\n{API_BASE}/invoice-scans")
        if failures:
            msg.append(f"⚠️ 経理アプリへの送信に失敗した写真が {len(failures)}件あります（次の晩にやり直します）。\n" + "\n".join(failures[:10]))
        notify("\n\n".join(msg))


if __name__ == "__main__":
    main()
