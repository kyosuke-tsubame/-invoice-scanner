#!/usr/bin/env python3
"""要確認の納品書を、写真を見ながらその場で直す画面。

2026-09-13新設。Excelの確認シート（review_sheet.py）だと写真を別ウィンドウで開く必要があり
行き来が面倒だったため、写真を大きく出しながら店舗・金額を指定できる画面を用意した。

使い方:
    python3 review_server.py          # ブラウザが自動で開く
    python3 review_server.py --port 8800

このMacの中だけで動く（localhost）。外からは見えない。
押した瞬間に台帳へ記帳し、要確認を解除する。
"""
import argparse
import io
import json
import os
import secrets
import shutil
import socket
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from PIL import Image, ImageOps

sys.path.insert(0, str(Path(__file__).resolve().parent))
import invoice_ledger as L  # noqa: E402
import review_sheet as RS  # noqa: E402
import validate_entry as V  # noqa: E402

BASE = Path(__file__).resolve().parent
STATE_FILE = BASE / "invoice_ocr_state.json"
MAX_SIDE = 1600  # 画面に出すときの最大の辺。原本は変更しない

# 同じWi-Fi内の他の端末（iPhone等）からも開けるようにしたため、4桁の暗証番号で入口を守る。
# 番号は .review_pin に平文で置く（このMacの中だけのファイル。変えたいときは書き換える）。
NAME_DOC = Path.home() / "Claude/Obsidian/kyosuke-brain/AI/reference/仕入先の正式名称_対応表.md"
PIN_FILE = BASE / ".review_pin"
# ログイン済みの合言葉はファイルに残す。15分アクセスが無いとサーバーが終了する作りのため、
# メモリに置いていると毎回入力し直しになってしまっていた（2026-09-13に判明）。
SESSION_FILE = BASE / ".review_sessions"
SESSION_DAYS = 30


def load_sessions():
    """期限切れを捨てながら、有効な合言葉を読む。"""
    if not SESSION_FILE.is_file():
        return {}
    out = {}
    now = time.time()
    try:
        for line in SESSION_FILE.read_text(encoding="utf-8").splitlines():
            tok, _, exp = line.partition(" ")
            if tok and exp and float(exp) > now:
                out[tok] = float(exp)
    except Exception:
        return {}
    return out


def add_session(token):
    sess = load_sessions()
    sess[token] = time.time() + SESSION_DAYS * 86400
    SESSION_FILE.write_text(
        "\n".join(f"{t} {e}" for t, e in sess.items()) + "\n", encoding="utf-8")
    SESSION_FILE.chmod(0o600)


FAILED = {"count": 0, "until": 0.0}   # 連続失敗したらしばらく受け付けない
IDLE_EXIT_SECONDS = 900   # 15分アクセスが無ければ自分で終了する（常駐させないため）
LAST_ACCESS = {"t": 0.0}


def load_pin():
    if PIN_FILE.is_file():
        pin = PIN_FILE.read_text(encoding="utf-8").strip()
        if pin:
            return pin
    pin = f"{secrets.randbelow(9000) + 1000}"
    PIN_FILE.write_text(pin + "\n", encoding="utf-8")
    PIN_FILE.chmod(0o600)
    return pin


LOGIN_PAGE = """<!doctype html><html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>納品書の確認</title>
<style>
 body{margin:0;height:100vh;display:grid;place-items:center;background:#f4f4f6;color:#1c2340;
      font:16px/1.6 -apple-system,BlinkMacSystemFont,"Hiragino Sans","Yu Gothic",sans-serif}
 form{background:#fff;border:1px solid #d8d8de;border-radius:12px;padding:28px;width:300px;text-align:center}
 h1{font-size:17px;margin:0 0 18px}
 input{width:100%;padding:14px;font-size:28px;text-align:center;letter-spacing:.4em;
       border:1px solid #d8d8de;border-radius:8px;background:#fff;color:#1c2340}
 button{width:100%;margin-top:14px;padding:12px;font-size:16px;font-weight:600;border:none;
        border-radius:8px;background:#1c2340;color:#fff;cursor:pointer}
 .err{color:#b3261e;font-size:14px;margin-top:12px;min-height:1.4em}
</style></head><body>
<form method="POST" action="/login">
  <h1>暗証番号を入れてください</h1>
  <input name="pin" type="tel" inputmode="numeric" maxlength="4" autofocus autocomplete="off">
  <button type="submit">開く</button>
  <div class="err">__ERR__</div>
</form></body></html>"""


def lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def load_state():
    with open(STATE_FILE, encoding="utf-8") as f:
        return json.load(f)


def save_state(state):
    tmp = STATE_FILE.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
    tmp.replace(STATE_FILE)


def items_payload():
    state = load_state()
    out = []
    for path, v in RS.held_items(state):
        out.append({
            "path": path,
            "name": Path(path).name,
            "folder": path.split("納品書写真/")[-1].rsplit("/", 1)[0] if "納品書写真/" in path else "",
            "store": v.get("store") or "",
            "supplier": v.get("supplier") or "",
            "date": (v.get("date") or "")[:10],
            "total": v.get("total") if isinstance(v.get("total"), int) else "",
            "note": v.get("note") or "",
            "memo": v.get("humanMemo") or "",
        })
    return out


PAGE = """<!doctype html><html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>納品書の確認</title>
<style>
  :root{--bg:#f4f4f6;--card:#fff;--line:#d8d8de;--ink:#1c2340;--accent:#1c2340;--warn:#8a6d1f;--warnbg:#fff6d9}
  *{box-sizing:border-box}
  body{margin:0;font:15px/1.6 -apple-system,BlinkMacSystemFont,"Hiragino Sans","Yu Gothic",sans-serif;
       background:var(--bg);color:var(--ink)}
  header{background:var(--accent);color:#fff;padding:10px 18px;display:flex;gap:18px;align-items:center;
         position:sticky;top:0;z-index:5}
  header b{font-size:17px}
  #prog{margin-left:auto;font-variant-numeric:tabular-nums}
  main{display:grid;grid-template-columns:1fr 400px;gap:18px;padding:18px;align-items:start}
  @media (max-width:900px){main{grid-template-columns:1fr}}
  .card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px}
  #photo{width:100%;border-radius:6px;display:block;cursor:zoom-in;background:#eee}
  #photowrap{position:relative}
  .hint{font-size:13px;color:#666;margin:8px 0 0}
  label{display:block;font-size:13px;font-weight:600;margin:14px 0 4px}
  textarea{width:100%;padding:9px 10px;border:1px solid var(--line);border-radius:6px;
           font-size:14px;font-family:inherit;background:#fff;color:var(--ink);resize:vertical}
  input,select{width:100%;padding:9px 10px;border:1px solid var(--line);border-radius:6px;font-size:15px;
               background:#fff;color:var(--ink)}
  input[type=number]{text-align:right}
  .why{background:var(--warnbg);border:1px solid #e5d089;color:var(--warn);border-radius:8px;
       padding:10px 12px;font-size:13px;margin-bottom:6px;white-space:pre-wrap}
  .meta{font-size:12px;color:#777;word-break:break-all;margin-top:10px}
  .btns{display:grid;gap:8px;margin-top:18px}
  button{padding:11px 14px;border-radius:8px;border:1px solid var(--line);background:#fff;
         font-size:15px;font-weight:600;cursor:pointer;color:var(--ink)}
  button:hover{background:#f0f0f4}
  .primary{background:var(--accent);color:#fff;border-color:var(--accent)}
  .primary:hover{background:#2b3556}
  .chk{display:flex;gap:8px;align-items:center;margin-top:12px;font-size:14px}
  .chk input{width:auto}
  #msg{padding:10px 14px;border-radius:8px;margin:0 18px;display:none;font-size:14px}
  .ok{background:#e8f5e9;border:1px solid #a5d6a7}
  .ng{background:#fdecea;border:1px solid #f5aca6}
  #done{padding:40px;text-align:center;font-size:18px;display:none}
  dialog{border:none;border-radius:10px;padding:0;max-width:96vw;max-height:96vh}
  dialog img{display:block;max-width:96vw;max-height:92vh}
  dialog::backdrop{background:rgba(0,0,0,.75)}
  .nav{display:flex;gap:8px;margin-top:8px}
  .nav button{flex:1}
</style></head><body>
<header><b>納品書の確認</b><span id="cur"></span><span id="prog"></span></header>
<div id="msg"></div>
<div id="done">すべて確認が終わりました。おつかれさまでした。</div>
<main id="app">
  <div class="card" id="photowrap">
    <img id="photo" alt="納品書の写真">
    <p class="hint">写真をクリックすると拡大します。</p>
    <p class="meta" id="meta"></p>
  </div>
  <div class="card">
    <div class="why" id="why"></div>
    <label>店舗</label><select id="store"></select>
    <label>仕入先</label><input id="supplier" list="suppliers"><datalist id="suppliers"></datalist>
    <label>日付</label><input id="date" type="date">
    <label>金額（税抜）</label><input id="total" type="number" step="1">
    <label>メモ（読み間違いの原因や、次回の読み方のコツ）</label>
    <textarea id="memo" rows="3" placeholder="例：数量欄の45を35と読み違えた。単価×数量で検算すること"></textarea>
    <div class="chk"><input type="checkbox" id="memolearn">
      <label for="memolearn" style="margin:0;font-weight:400">このメモを今後この仕入先の読み取りに使う</label></div>
    <div class="chk"><input type="checkbox" id="learn">
      <label for="learn" style="margin:0;font-weight:400">この仕入先は今後もこの店舗にする</label></div>
    <div class="btns">
      <button class="primary" id="save">この内容で記帳する</button>
      <button id="skip">記帳しない（対象外にする）</button>
      <button id="later">あとで（そのまま次へ）</button>
    </div>
    <div class="nav"><button id="prev">← 前</button><button id="next">次 →</button></div>
  </div>
</main>
<dialog id="zoom"><img id="zoomimg"></dialog>
<script>
let items=[],i=0;
const $=id=>document.getElementById(id);
const STORES=__STORES__;
function msg(t,cls){const m=$('msg');m.textContent=t;m.className=cls;m.style.display=t?'block':'none';
  if(t)setTimeout(()=>{m.style.display='none'},4000);}
function render(){
  if(!items.length){$('app').style.display='none';$('done').style.display='block';$('prog').textContent='';return;}
  if(i>=items.length)i=0; if(i<0)i=items.length-1;
  const it=items[i];
  $('prog').textContent=(i+1)+' / '+items.length+' 件';
  $('cur').textContent=it.folder;
  $('photo').src='/photo?p='+encodeURIComponent(it.path)+'&t='+Date.now();
  $('why').textContent=it.note||'（理由の記録なし）';
  $('store').innerHTML=STORES.map(s=>`<option ${s===it.store?'selected':''}>${s}</option>`).join('');
  $('supplier').value=it.supplier; $('date').value=it.date; $('total').value=it.total;
  $('learn').checked=false;$('memo').value=it.memo||'';$('memolearn').checked=false;
  $('meta').textContent=it.name;
}
async function send(action){
  const it=items[i];
  const body={path:it.path,action,store:$('store').value,supplier:$('supplier').value,
              date:$('date').value,total:$('total').value,learn:$('learn').checked,
              memo:$('memo').value,memolearn:$('memolearn').checked};
  const r=await fetch('/api/save',{method:'POST',headers:{'Content-Type':'application/json'},
                                   body:JSON.stringify(body)});
  const d=await r.json();
  if(!d.ok){msg(d.error,'ng');return;}
  msg(d.message,'ok');
  if(action==='later'){
    // 一覧からは消さず、直した内容を手元にも反映して次の1枚へ
    Object.assign(items[i],{store:body.store,supplier:body.supplier,
                            date:body.date,total:body.total});
    i++; render(); return;
  }
  items.splice(i,1); render();
}
$('save').onclick=()=>send('record');
$('skip').onclick=()=>send('skip');
$('later').onclick=()=>send('later');
$('next').onclick=()=>{i++;render();};
$('prev').onclick=()=>{i--;render();};
$('photo').onclick=()=>{$('zoomimg').src=$('photo').src;$('zoom').showModal();};
$('zoom').onclick=()=>$('zoom').close();
document.addEventListener('keydown',e=>{
  if(e.target.tagName==='INPUT'||e.target.tagName==='SELECT')return;
  if(e.key==='ArrowRight')$('next').click();
  if(e.key==='ArrowLeft')$('prev').click();
});
fetch('/api/items').then(r=>r.json()).then(d=>{items=d.items;
  $('suppliers').innerHTML=d.suppliers.map(s=>`<option value="${s}">`).join('');render();});
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_one_request(self):
        LAST_ACCESS["t"] = time.time()
        return super().handle_one_request()

    def _authed(self):
        # このMac自身のブラウザからは暗証番号なしで通す。
        # Macを操作できている時点で本人なので、そこで改めて聞く意味がない。
        if self.client_address[0] in ("127.0.0.1", "::1"):
            return True
        cookie = self.headers.get("Cookie", "")
        sess = load_sessions()
        for part in cookie.split(";"):
            k, _, val = part.strip().partition("=")
            if k == "nouhin" and val in sess:
                return True
        return False

    def _login_page(self, err=""):
        self._send(200, LOGIN_PAGE.replace("__ERR__", err), "text/html; charset=utf-8")

    def do_GET(self):
        u = urlparse(self.path)
        if not self._authed():
            if u.path in ("/", "/login"):
                return self._login_page()
            return self._send(401, {"error": "暗証番号を入れてください"})
        if u.path == "/":
            html = PAGE.replace("__STORES__", json.dumps(V.STORES, ensure_ascii=False))
            return self._send(200, html, "text/html; charset=utf-8")
        if u.path == "/api/items":
            names = sorted(V.load_official_names())
            return self._send(200, {"items": items_payload(), "suppliers": names})
        if u.path == "/photo":
            p = parse_qs(u.query).get("p", [""])[0]
            # 状態ファイルに載っている写真しか出さない（勝手なパスを読ませない）
            if p not in load_state():
                return self._send(404, {"error": "not found"})
            try:
                im = ImageOps.exif_transpose(Image.open(p))
                im.thumbnail((MAX_SIDE, MAX_SIDE))
                buf = io.BytesIO()
                im.convert("RGB").save(buf, "JPEG", quality=88)
                return self._send(200, buf.getvalue(), "image/jpeg")
            except Exception as e:
                return self._send(500, {"error": str(e)})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        if urlparse(self.path).path == "/login":
            n = int(self.headers.get("Content-Length", 0))
            pin = parse_qs(self.rfile.read(n).decode()).get("pin", [""])[0].strip()
            now = time.time()
            if now < FAILED["until"]:
                wait = int(FAILED["until"] - now)
                return self._login_page(f"何度も間違えたため、あと{wait}秒お待ちください")
            if secrets.compare_digest(pin, load_pin()):
                FAILED.update(count=0, until=0.0)
                token = secrets.token_urlsafe(32)
                add_session(token)
                self.send_response(303)
                self.send_header("Location", "/")
                self.send_header(
                    "Set-Cookie",
                    f"nouhin={token}; Path=/; HttpOnly; SameSite=Lax; "
                    f"Max-Age={SESSION_DAYS * 86400}")
                self.end_headers()
                return
            FAILED["count"] += 1
            if FAILED["count"] >= 5:
                FAILED.update(count=0, until=now + 60)
                return self._login_page("何度も間違えたため、60秒お待ちください")
            return self._login_page("番号が違います")
        if not self._authed():
            return self._send(401, {"error": "暗証番号を入れてください"})
        if urlparse(self.path).path != "/api/save":
            return self._send(404, {"error": "not found"})
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")
        try:
            return self._send(200, handle_save(req))
        except Exception as e:
            return self._send(200, {"ok": False, "error": f"保存できませんでした: {e}"})


SAVE_LOCK = threading.Lock()


def handle_save(req):
    path = req.get("path")
    action = req.get("action")
    with SAVE_LOCK:
        state = load_state()
        v = state.get(path)
        if not isinstance(v, dict):
            return {"ok": False, "error": "この写真の記録が見つかりません"}
        now = time.strftime("%Y-%m-%dT%H:%M:%S+09:00")

        if action == "skip":
            v.update({"status": "skipped", "resolvedAt": now,
                      "resolvedNote": "確認画面で『記帳しない』と指定された"})
            save_state(state)
            return {"ok": True, "message": "対象外にしました"}

        if action not in ("record", "later"):
            return {"ok": False, "error": "不明な操作です"}

        entry = {
            "date": (req.get("date") or "").strip(),
            "store": (req.get("store") or "").strip(),
            "supplier": (req.get("supplier") or "").strip(),
            "total": req.get("total"),
        }
        try:
            entry["total"] = int(str(entry["total"]).replace(",", "").strip())
        except (TypeError, ValueError):
            entry["total"] = None

        memo_now = (req.get("memo") or "").strip()
        if action == "later":
            # 記帳はせず、書いたメモと直した内容だけ残して次へ。
            # 「あとで」で何も保存されないと、せっかく書いたメモが消えてしまう。
            if entry["store"] in V.STORES:
                v["store"] = entry["store"]
            if entry["supplier"]:
                v["supplier"] = normalize_supplier(entry["supplier"])
            if entry["date"] and V.parse_date(entry["date"]):
                v["date"] = entry["date"]
            if entry["total"] and entry["total"] > 0:
                v["total"] = entry["total"]
            saved = []
            if memo_now:
                v["humanMemo"] = memo_now
                v["humanMemoAt"] = now
                saved.append("メモ")
            v["heldNote"] = "確認画面で『あとで』を選択（記帳はまだ）"
            save_state(state)
            extra = ""
            if memo_now and req.get("memolearn"):
                extra = save_reading_hint(v["supplier"], memo_now)
            saved.append("直した内容")
            return {"ok": True,
                    "message": f"{'と'.join(saved)}を保存しました（記帳はまだです）{extra}"}

        missing = []
        if not entry["date"] or V.parse_date(entry["date"]) is None:
            missing.append("日付")
        if entry["store"] not in V.STORES:
            missing.append("店舗")
        if not entry["supplier"]:
            missing.append("仕入先")
        if not entry["total"] or entry["total"] <= 0:
            missing.append("金額")
        if missing:
            return {"ok": False, "error": "／".join(missing) + " を入れてください"}

        # 仕入先名は、押した時点で名寄せ表の正式名に自動で揃える。
        # 画面には読み取ったままの名前（例：株式会社クリチク）が出るので、
        # そのまま押すと台帳に旧表記が入ってしまっていた（2026-09-13に実際に発生）。
        entry["supplier"] = normalize_supplier(entry["supplier"])

        level, reasons = V.check(entry)
        L.cmd_add({**entry, "category": "仕入れ"})
        v.update({"status": "auto_saved", **entry, "resolvedAt": now,
                  "resolvedNote": "確認画面で人が確認して記帳した"
                  + (f"（検算の指摘: {'／'.join(reasons)}）" if reasons else "")})
        save_state(state)

        memo = (req.get("memo") or "").strip()
        if memo:
            v["humanMemo"] = memo
            v["humanMemoAt"] = now
            save_state(state)

        extra = ""
        if memo and req.get("memolearn"):
            extra += save_reading_hint(entry["supplier"], memo)
        if req.get("learn"):
            extra += learn_rule(entry["supplier"], entry["store"])
        warn = f"（検算の指摘: {reasons[0]}）" if reasons else ""
        return {"ok": True,
                "message": f"記帳しました：{entry['store']} / {entry['supplier']} / "
                           f"{entry['date']} / {entry['total']:,}円{warn}{extra}"}


def normalize_supplier(name):
    """納品書の表記を、名寄せ表の正式名称に直す。表に無ければそのまま返す。"""
    import re as _re
    if not NAME_DOC.is_file():
        return name
    doc = NAME_DOC.read_text(encoding="utf-8")
    for n, al in _re.findall(r"^\|\s*([^|\s][^|]*?)\s*\|\s*([^|]*?)\s*\|\s*$", doc, _re.M):
        if n == "正式名称" or set(n) <= set("-― "):
            continue
        if name == n:
            return n
        for a in _re.split(r"[、,]", al):
            if a.strip() and a.strip() != "－" and name == a.strip():
                return n
    return name


def stores_seen(supplier):
    """その仕入先の写真が、どの店舗フォルダに入っているか。"""
    root = Path.home() / "Library/CloudStorage/OneDrive-個人用/納品書写真"
    found = set()
    for st in V.STORES:
        d = root / st / supplier
        if d.is_dir() and any(
            not f.name.startswith(".") for f in d.rglob("*") if f.is_file()
        ):
            found.add(st)
    return found


def save_reading_hint(supplier, memo):
    """『今後この仕入先の読み取りに使う』メモを、読み取りメモの表に書き足す。

    このファイルは毎晩 run_invoice_ocr.sh が読み込んでAIに渡すので、
    次の晩から同じ読み間違いをしにくくなる。
    """
    f = BASE / "仕入先_読み取りメモ.txt"
    if not f.is_file():
        f.write_text(
            "# 仕入先ごとの「読み取りのコツ・注意点」。\n"
            "# 確認画面でメモを書いて『今後この仕入先の読み取りに使う』にチェックすると、ここに溜まる。\n"
            "# 毎晩の読み取りでAIに渡されるので、同じ読み間違いを繰り返しにくくなる。\n"
            "# 形式は「仕入先名: メモ」。手で書き足しても消してもよい。\n\n",
            encoding="utf-8")
    one_line = " ".join(memo.split())
    existing = f.read_text(encoding="utf-8")
    if f"{supplier}: {one_line}" in existing:
        return ""
    with open(f, "a", encoding="utf-8") as fh:
        fh.write(f"{supplier}: {one_line}\n")
    return f"／読み取りメモに登録しました（次の晩から{supplier}の読み取りに使われます）"


def learn_rule(supplier, store):
    """『今後もこの店舗』が押されたら、仕入先→店舗の対応表に書き足す。"""
    f = BASE / "仕入先_店舗マップ.txt"
    fixed, no_auto, rebill = V.load_supplier_store_map()
    if supplier in no_auto or supplier in rebill:
        return "（この仕入先は特別ルールがあるため、対応表は変えませんでした）"
    if fixed.get(supplier) == store:
        return ""
    if supplier in fixed:
        return f"（対応表では『{supplier}＝{fixed[supplier]}』です。変える場合は言ってください）"
    # 複数の店舗に納品がある仕入先を「いつもこの店舗」と登録すると、
    # 他の店舗ぶんが全部その店舗と誤判定される（2026-09-13に石橋青果・濱村屋で実際に発生）。
    seen = stores_seen(supplier)
    if len(seen) > 1:
        return (f"（{supplier}は{len(seen)}店舗（{'・'.join(sorted(seen))}）に納品があるため、"
                "『いつもこの店舗』にはしませんでした）")
    shutil.copy2(f, str(f) + ".bak." + time.strftime("%Y%m%d_%H%M%S"))
    with open(f, "a", encoding="utf-8") as fh:
        fh.write(f"{supplier}: {store}\n")
    return f"／対応表に『{supplier}＝{store}』を追加しました"


def launchd_socket():
    """macOSのlaunchdが用意したポートを受け取る（アクセスがあった時だけ起動する仕組み）。

    launchdが先にポートを握っておき、誰かが接続してきた瞬間にこのプログラムを起動して
    そのポートを渡してくれる。使っていない間はプログラムが存在しないのでメモリを使わない。
    渡されなかった場合（手動起動）は None を返し、いつもどおり自分でポートを開く。
    """
    import ctypes
    import ctypes.util

    name = os.environ.get("LAUNCH_SOCKET_NAME")
    if not name:
        return None
    try:
        libc = ctypes.CDLL(ctypes.util.find_library("System"), use_errno=True)
        fds = ctypes.POINTER(ctypes.c_int)()
        cnt = ctypes.c_size_t(0)
        rc = libc.launch_activate_socket(name.encode(), ctypes.byref(fds), ctypes.byref(cnt))
        if rc != 0 or cnt.value < 1:
            return None
        return socket.socket(fileno=fds[0])
    except Exception:
        return None


class ActivatedServer(ThreadingHTTPServer):
    """launchdから受け取ったポートをそのまま使うサーバー。"""

    def __init__(self, sock, handler):
        # 中身を自前で組み立てると、標準ライブラリが内部で使う変数が揃わず起動直後に落ちる。
        # いつもどおり初期化させたうえで（bind_and_activate=False で自分ではポートを開かせない）、
        # 使い捨てのポートを閉じて、launchdからもらったポートに差し替える。
        super().__init__(sock.getsockname()[:2], handler, bind_and_activate=False)
        self.socket.close()
        self.socket = sock
        self.server_name, self.server_port = sock.getsockname()[:2]


def start_idle_watch(srv):
    """しばらく誰も使わなければ自分で終了する見張り。"""
    def watch():
        while True:
            time.sleep(30)
            if time.time() - LAST_ACCESS["t"] > IDLE_EXIT_SECONDS:
                print(f"{IDLE_EXIT_SECONDS // 60}分アクセスが無かったので終了します。")
                threading.Thread(target=srv.shutdown, daemon=True).start()
                return
    threading.Thread(target=watch, daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--no-open", action="store_true")
    ap.add_argument("--local-only", action="store_true",
                    help="このMacからだけ開けるようにする（他の端末からは開けない）")
    args = ap.parse_args()
    n = len(items_payload())
    pin = load_pin()
    LAST_ACCESS["t"] = time.time()

    sock = launchd_socket()
    if sock is not None:
        # アクセスがあって macOS に起こされた場合
        srv = ActivatedServer(sock, Handler)
        port = srv.server_address[1]
        start_idle_watch(srv)
        print(f"アクセスを受けて起動しました（ポート{port}）。要確認 {n}件。")
        srv.serve_forever()
        print("終了しました。")
        return

    host = "127.0.0.1" if args.local_only else "0.0.0.0"
    srv = ThreadingHTTPServer((host, args.port), Handler)
    url = f"http://127.0.0.1:{args.port}/"
    print(f"要確認 {n}件。ブラウザで開きます: {url}")
    if not args.local_only:
        print(f"iPhoneなど同じWi-Fiの端末からは: http://{lan_ip()}:{args.port}/")
    print(f"暗証番号: {pin}    （変えるときは {PIN_FILE} の数字を書き換えてください）")
    print("終わったらこのウィンドウを閉じるか、control+C を押してください。")
    if not args.no_open:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n終了しました。")


if __name__ == "__main__":
    main()
