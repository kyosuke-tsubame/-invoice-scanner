#!/usr/bin/env python3
"""記帳しようとしている内容を、AIとは別に機械だけで検算する。

2026-09-13新設。背景：これまで「自信あり」とAIが判断したものはそのまま台帳に書かれ、
誤読が混ざっても誰も気づけなかった（例：手書き伝票の18,250円を0円と読んでいた、
税込25,116円を税抜として記帳しようとしていた）。AIの判断の外側に、
過去データと突き合わせる機械的な関所を置く。

使い方:
  # 1件を検算する（記帳の直前に使う。run_invoice_ocr.sh から呼ぶ）
  python3 validate_entry.py check '{"date":"2026-08-15","store":"本店","supplier":"マルフク","total":3950}'
      → {"ok": true}  または  {"ok": false, "reasons": ["..."], "level": "要確認"}

  # 台帳全体を検査して、怪しい行を一覧にする
  python3 validate_entry.py audit

判定は3段階。
  OK     … 問題なし。そのまま記帳してよい
  要確認 … 記帳せず人の確認にまわす
  注意   … 記帳はしてよいが、報告に残す（後から見直せるように）
"""
import json
import os
import re
import statistics
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import invoice_ledger as L  # noqa: E402

BASE = Path(__file__).resolve().parent
NAME_DOC = Path.home() / "Claude/Obsidian/kyosuke-brain/AI/reference/仕入先の正式名称_対応表.md"
SUPPLIER_MAP = BASE / "仕入先_店舗マップ.txt"
STORES = ["本店", "KADODE店", "空港店", "静岡紺屋町店", "セントラル", "冷凍事業部", "製麺事業部"]

# --- しきい値（2026-09-13時点の実データで決めた。263行・中央値7,900円・最大210,905円）---
MAX_REASONABLE = 500_000     # 1枚でこれを超えたら桁の読み違いを疑う
MIN_REASONABLE = 100         # これ未満は0円・読み落としを疑う
OUTLIER_RATIO = 8            # その仕入先のいつもの金額（中央値）の何倍で疑うか
OUTLIER_MIN_SAMPLES = 5      # 過去データがこの件数以上あるときだけ外れ値判定する
STALE_DAYS = 100             # 伝票日付がこれより古いと読み違いを疑う


def load_official_names():
    """名寄せ表から正式名称の一覧を読む。"""
    if not NAME_DOC.is_file():
        return set()
    names = set()
    for n, _al in re.findall(
        r"^\|\s*([^|\s][^|]*?)\s*\|\s*([^|]*?)\s*\|\s*$", NAME_DOC.read_text(encoding="utf-8"), re.M
    ):
        if n == "正式名称" or set(n) <= set("-― "):
            continue
        names.add(n)
    return names


def load_supplier_store_map():
    """仕入先→店舗の対応表を読む。「!」「>」行は別扱い。"""
    fixed, no_auto, rebill = {}, set(), {}
    if not SUPPLIER_MAP.is_file():
        return fixed, no_auto, rebill
    for line in SUPPLIER_MAP.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("!"):
            no_auto.add(line[1:].strip())
        elif line.startswith(">"):
            m = re.match(r"(.+?):\s*(.+?)\s*->\s*(.+)", line[1:])
            if m:
                rebill[m.group(1).strip()] = (m.group(2).strip(), m.group(3).strip())
        elif ":" in line:
            k, v = line.split(":", 1)
            fixed[k.strip()] = v.strip()
    return fixed, no_auto, rebill


def ledger_rows():
    wb = L._load_workbook()
    return L._read_rows(wb[L.DATA_SHEET])


def supplier_stats(rows):
    """金額の相場（中央値と件数）を「仕入先×店舗」と「仕入先」の2段階で持つ。

    同じ仕入先でも店舗によって相場がまるで違う（空港店の石橋青果は245〜405円が普通だが、
    全店まとめた中央値は3,500円）。店舗込みの相場を優先し、データが足りないときだけ
    仕入先だけの相場にさがる。
    """
    per_pair, per_sup = defaultdict(list), defaultdict(list)
    for r in rows:
        if r["total"] and r["total"] > 0:
            per_pair[(r["supplier"], r["store"])].append(r["total"])
            per_sup[r["supplier"]].append(r["total"])
    return (
        {k: (statistics.median(v), len(v)) for k, v in per_pair.items()},
        {k: (statistics.median(v), len(v)) for k, v in per_sup.items()},
    )


def parse_date(s):
    for fmt in ("%Y-%m-%d", "%Y/%m/%d"):
        try:
            return datetime.strptime(str(s)[:10], fmt).date()
        except ValueError:
            continue
    return None


def check(entry, rows=None, today=None):
    """1件を検算し、(level, reasons) を返す。level は OK / 注意 / 要確認。"""
    if rows is None:
        rows = ledger_rows()
    today = today or date.today()
    official = load_official_names()
    fixed, no_auto, rebill = load_supplier_store_map()
    pair_stats, sup_stats = supplier_stats(rows)

    store = (entry.get("store") or "").strip()
    supplier = (entry.get("supplier") or "").strip()
    total = entry.get("total")
    d = parse_date(entry.get("date"))

    hard, soft = [], []

    # --- 金額 ---
    if total is None or not isinstance(total, (int, float)):
        hard.append("金額が数字として読めていない")
    else:
        total = int(total)
        if total <= 0:
            hard.append(f"金額が0円以下（{total}）。読み取り失敗の可能性が高い")
        elif total < MIN_REASONABLE:
            soft.append(f"金額が{total:,}円と極端に小さい。桁の読み落としかもしれない")
        elif total > MAX_REASONABLE:
            hard.append(f"金額が{total:,}円と極端に大きい（1枚{MAX_REASONABLE:,}円超）。桁の読み違いの可能性")
        # 店舗込みの相場を優先し、足りなければ仕入先だけの相場を使う
        med, n = pair_stats.get((supplier, store), (None, 0))
        basis = f"{supplier}／{store}"
        if n < OUTLIER_MIN_SAMPLES:
            med, n = sup_stats.get(supplier, (None, 0))
            basis = supplier
        if med and n >= OUTLIER_MIN_SAMPLES and total > 0:
            ratio = total / med
            if ratio >= OUTLIER_RATIO:
                hard.append(
                    f"{basis}のいつもの金額（中央値{med:,.0f}円・{n}件）の{ratio:.1f}倍。桁違いを疑う"
                )
            # 「いつもより小さい」判定は入れない。少額納品（葱1袋245円など）が普通にあり、
            # 2026-09-13の実データでは9件すべてが誤検知だった。通知が多すぎると見なくなるため、
            # 金額の下振れは絶対値（MIN_REASONABLE未満）だけで見る。

    # --- 日付 ---
    if d is None:
        hard.append("日付が読めていない")
    else:
        if d > today:
            hard.append(f"伝票日付が未来（{d}）。読み違いの可能性")
        elif d < today - timedelta(days=STALE_DAYS):
            soft.append(f"伝票日付が{ (today - d).days }日前（{d}）と古い。年の読み違いかもしれない")

    # --- 店舗 ---
    if not store:
        hard.append("店舗が空")
    elif store not in STORES:
        hard.append(f"店舗『{store}』が7店舗のいずれでもない")
    else:
        if supplier in no_auto:
            soft.append(f"{supplier}は複数店舗に納品があり自動判定しない設定。店舗が正しいか要確認")
        elif supplier in rebill:
            _to_store = rebill[supplier][1]
            if store != _to_store:
                hard.append(f"{supplier}は仕入れを『{_to_store}』に計上する決まりだが『{store}』になっている")
        elif supplier in fixed and fixed[supplier] != store:
            hard.append(f"対応表では『{supplier}＝{fixed[supplier]}』だが『{store}』になっている")

    # --- 仕入先 ---
    if not supplier:
        hard.append("仕入先が空")
    elif official and supplier not in official:
        hard.append(f"仕入先『{supplier}』が名寄せ表（正式名称）に無い。表記ゆれか新規取引先")

    # --- 重複 ---
    if store and supplier and d and total:
        same = [
            r for r in rows
            if r["store"] == store and r["supplier"] == supplier
            and str(r["date"])[:10] == str(d) and r["total"] == total
        ]
        if same:
            hard.append(f"同じ内容（{store}／{supplier}／{d}／{total:,}円）が台帳に既に{len(same)}件ある")

    level = "要確認" if hard else ("注意" if soft else "OK")
    return level, hard + soft


def cmd_check(payload):
    rows = ledger_rows()
    level, reasons = check(payload, rows=rows)
    print(json.dumps({"ok": level == "OK", "level": level, "reasons": reasons}, ensure_ascii=False))
    return 0


def cmd_audit():
    """台帳全体を検査する。自分自身との重複は数えない。"""
    rows = ledger_rows()
    results = []
    for i, r in enumerate(rows):
        others = rows[:i] + rows[i + 1:]
        level, reasons = check(
            {"date": r["date"], "store": r["store"], "supplier": r["supplier"], "total": r["total"]},
            rows=others,
        )
        if level != "OK":
            results.append((level, i + 2, r, reasons))

    hard = [x for x in results if x[0] == "要確認"]
    soft = [x for x in results if x[0] == "注意"]
    print(f"台帳 {len(rows)}行を検査しました。")
    print(f"  要確認: {len(hard)}行 ／ 注意: {len(soft)}行 ／ 問題なし: {len(rows)-len(results)}行")
    for label, group in (("要確認", hard), ("注意", soft)):
        if not group:
            continue
        print(f"\n=== {label} ===")
        for _lv, rowno, r, reasons in group:
            print(f"  データ{rowno}行目  {r['store']} / {r['supplier']} / {r['date']} / {r['total']:,}円")
            for x in reasons:
                print(f"      - {x}")
    return 0


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("check", "audit"):
        print(__doc__)
        return 1
    if sys.argv[1] == "audit":
        return cmd_audit()
    if len(sys.argv) != 3:
        print("使い方: python3 validate_entry.py check '<JSON>'")
        return 1
    return cmd_check(json.loads(sys.argv[2]))


if __name__ == "__main__":
    sys.exit(main())
