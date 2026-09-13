#!/usr/bin/env python3
"""
納品書の記帳をExcelファイル（OneDrive）で管理する。
Googleスプレッドシート連携（curlがGoogle側にブロックされる問題があった）を廃止し、
FAX仕分けの売上集計.xlsxと同じ考え方（openpyxlでローカルのExcelファイルを直接読み書き）に統一した。

使い方:
  python3 invoice_ledger.py check '{"date":"2026-08-15","store":"本店","total":3950}'
    -> 同じ日付・店舗・金額の行が既にあれば {"duplicate": true} を返す

  python3 invoice_ledger.py add '{"date":"2026-08-15","store":"本店","supplier":"株式会社マルフク","total":3950,"category":"仕入れ"}'
    -> 「データ」シートに1行追記し、「店舗別集計」シートを最新の内容で作り直す

  python3 invoice_ledger.py edit '{"match":{"date":"2026-08-15","store":"本店"},"set":{"total":3200}}'
    -> matchの条件に一致する行が1件だけなら、setで指定した項目を書き換えて「店舗別集計」シートも作り直す
       （Slackの返信でOCR結果の修正指示を受けた時に使う。保存前に元ファイルを.bak.<timestamp>としてバックアップする）
       一致が0件・複数件の場合は書き換えず、{"error":..., "candidates":[...]}を返す（呼び出し側は当て推量で決めず、原田さんに確認すること）

シート構成:
  データ     … 生ログ（追記のみ、日付/店舗/仕入先/金額/年月/区分）
  店舗別集計 … 店舗ごとに区切られた、仕入先×月の金額一覧（add/editのたびに全体を作り直す）
"""
import re
import shutil
import sys
import json
import time
from pathlib import Path
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font, PatternFill, Alignment
from openpyxl.utils import get_column_letter

XLSX_PATH = Path.home() / "Library/CloudStorage/OneDrive-個人用/納品書集計/納品書集計.xlsx"
DATA_SHEET = "データ"
SUMMARY_SHEET = "店舗別集計"
HEADER = ["日付", "店舗", "仕入先", "金額", "年月", "区分"]

STORE_ORDER = ["本店", "KADODE店", "空港店", "静岡紺屋町店", "セントラル", "冷凍事業部", "製麺事業部"]

HEADER_FONT = Font(bold=True, color="FFFFFF")
HEADER_FILL = PatternFill(start_color="1C2340", end_color="1C2340", fill_type="solid")
STORE_FONT = Font(bold=True, size=13)
SUBTOTAL_FONT = Font(bold=True)
MONEY_FORMAT = "#,##0"

# 2026-09-13追加：仕入先名は、台帳に書く直前にここで必ず名寄せ表の正式名称に揃える。
# 揃える処理が呼び出し側（夜間AIへの指示・確認画面・確認シート）任せだったため、
# 確認画面の修正前に記帳した22行が「株式会社クリチク」などの旧表記で台帳に入ってしまった。
NAME_DOC = Path.home() / "Claude/Obsidian/kyosuke-brain/AI/reference/仕入先の正式名称_対応表.md"


def normalize_supplier(name):
    """名寄せ表に当てはまれば正式名称を、当てはまらなければ元の表記をそのまま返す。"""
    name = (name or "").strip()
    if not name or not NAME_DOC.is_file():
        return name
    aliases = {}
    for official, al in re.findall(r"^\|\s*([^|\s][^|]*?)\s*\|\s*([^|]*?)\s*\|\s*$",
                                   NAME_DOC.read_text(encoding="utf-8"), re.M):
        if official == "正式名称" or set(official) <= set("-― "):
            continue
        aliases[official] = official
        for a in re.split(r"[、,]", al):
            if a.strip() and a.strip() != "－":
                aliases[a.strip()] = official
    # 表にそのまま載っていなければ、株式会社などを外した形・括弧の外と中の名前でも探す
    # （例：「新村商店（株式会社シンムラCOMPANY）」→ 新村商店）
    bare = re.sub(r"株式会社|有限会社|（株）|\(株\)|㈱|㈲", "", name).strip()
    candidates = [name, bare]
    m = re.match(r"^(.*?)[（(](.*?)[）)]$", bare)
    if m:
        candidates += [m.group(1).strip(), m.group(2).strip()]
    for c in candidates:
        if c in aliases:
            return aliases[c]
    return name


def _load_workbook():
    XLSX_PATH.parent.mkdir(parents=True, exist_ok=True)
    if XLSX_PATH.is_file():
        wb = load_workbook(XLSX_PATH)
    else:
        wb = Workbook()
        wb.remove(wb.active)
    if DATA_SHEET not in wb.sheetnames:
        ws = wb.create_sheet(DATA_SHEET, 0)
        ws.append(HEADER)
        for col, _ in enumerate(HEADER, start=1):
            ws.cell(row=1, column=col).font = HEADER_FONT
            ws.cell(row=1, column=col).fill = HEADER_FILL
        ws.freeze_panes = "A2"
        ws.column_dimensions["A"].width = 12
        ws.column_dimensions["B"].width = 14
        ws.column_dimensions["C"].width = 26
        ws.column_dimensions["D"].width = 12
        ws.column_dimensions["E"].width = 10
        ws.column_dimensions["F"].width = 10
    return wb


def _read_rows(ws):
    rows = []
    for row in ws.iter_rows(min_row=2, values_only=True):
        if row[0] is None:
            continue
        rows.append({
            "date": str(row[0]),
            "store": row[1],
            "supplier": row[2],
            "total": int(row[3] or 0),
            "year_month": row[4],
            "category": row[5],
        })
    return rows


def cmd_check(payload):
    wb = _load_workbook()
    ws = wb[DATA_SHEET]
    date, store, total = payload["date"], payload["store"], int(payload["total"])
    dup = any(r["date"] == date and r["store"] == store and r["total"] == total for r in _read_rows(ws))
    print(json.dumps({"duplicate": dup}, ensure_ascii=False))


def cmd_add(payload):
    wb = _load_workbook()
    ws = wb[DATA_SHEET]
    date = payload["date"]
    store = payload["store"]
    supplier = normalize_supplier(payload.get("supplier", ""))
    total = int(payload["total"])
    category = payload.get("category", "")
    year_month = date[:7] if date else ""

    ws.append([date, store, supplier, total, year_month, category])
    ws.cell(row=ws.max_row, column=4).number_format = MONEY_FORMAT

    _rebuild_summary(wb, _read_rows(ws))
    wb.save(XLSX_PATH)
    print(f"追加: {date} {store} {supplier} {total}円")


def cmd_edit(payload):
    """
    Slackの返信などで届いた「記帳済みの内容が違う」という修正指示に対応する。
    match（date/store/supplierの組み合わせ）に一致する行が1件だけ見つかった場合のみ、
    setで指定した項目（date/store/supplier/total/category）を書き換える。
    0件・複数件ヒットした場合は書き換えず、候補をそのまま返す（呼び出し側で当て推量せず人に確認させるため）。
    """
    match = payload.get("match") or {}
    set_fields = payload.get("set") or {}
    if not match:
        print(json.dumps({"error": "matchを指定してください"}, ensure_ascii=False))
        return
    if not set_fields:
        print(json.dumps({"error": "setを指定してください"}, ensure_ascii=False))
        return

    wb = _load_workbook()
    ws = wb[DATA_SHEET]

    def row_summary(row_cells):
        return {
            "date": str(row_cells[0].value),
            "store": row_cells[1].value,
            "supplier": row_cells[2].value,
            "total": int(row_cells[3].value or 0),
        }

    matched = []
    for row_cells in ws.iter_rows(min_row=2):
        if row_cells[0].value is None:
            continue
        summary = row_summary(row_cells)
        if all(summary.get(k) == v for k, v in match.items()):
            matched.append(row_cells)

    if len(matched) == 0:
        print(json.dumps({"error": "matchに一致する行が見つかりませんでした", "match": match}, ensure_ascii=False))
        return
    if len(matched) > 1:
        print(json.dumps({
            "error": "matchに一致する行が複数あります。当て推量で決めず、どの行か確認してください",
            "candidates": [row_summary(r) for r in matched],
        }, ensure_ascii=False))
        return

    row_cells = matched[0]
    before = row_summary(row_cells)

    col_by_key = {"date": 0, "store": 1, "supplier": 2, "total": 3, "category": 5}
    for key, value in set_fields.items():
        if key not in col_by_key:
            continue
        if key == "supplier":
            value = normalize_supplier(value)
        row_cells[col_by_key[key]].value = int(value) if key == "total" else value
    if "total" in set_fields:
        row_cells[3].number_format = MONEY_FORMAT
    if "date" in set_fields:
        row_cells[4].value = set_fields["date"][:7] if set_fields["date"] else ""

    # 上書き保存する前に、直前の状態をバックアップとして残しておく
    if XLSX_PATH.is_file():
        backup_path = XLSX_PATH.with_name(f"{XLSX_PATH.name}.bak.{time.strftime('%Y%m%d%H%M%S')}")
        shutil.copy2(XLSX_PATH, backup_path)

    _rebuild_summary(wb, _read_rows(ws))
    wb.save(XLSX_PATH)

    print(json.dumps({"result": "修正しました", "before": before, "after": row_summary(row_cells)}, ensure_ascii=False))


def _rebuild_summary(wb, rows):
    if SUMMARY_SHEET in wb.sheetnames:
        wb.remove(wb[SUMMARY_SHEET])
    ws = wb.create_sheet(SUMMARY_SHEET)

    # 店舗 -> 仕入先 -> 年月 -> 金額合計
    agg = {}
    months = set()
    for r in rows:
        store_agg = agg.setdefault(r["store"], {})
        supplier_agg = store_agg.setdefault(r["supplier"] or "（仕入先不明）", {})
        supplier_agg[r["year_month"]] = supplier_agg.get(r["year_month"], 0) + r["total"]
        if r["year_month"]:
            months.add(r["year_month"])
    month_cols = sorted(months)

    # データに登場する順（STORE_ORDERに無い店舗名にも対応）
    stores_in_data = [s for s in STORE_ORDER if s in agg] + [s for s in agg if s not in STORE_ORDER]

    r_idx = 1
    max_col = max(2 + len(month_cols), 3)
    for store in stores_in_data:
        ws.cell(row=r_idx, column=1, value=store).font = STORE_FONT
        r_idx += 1

        header = ["仕入先"] + month_cols + ["合計"]
        for c_idx, label in enumerate(header, start=1):
            cell = ws.cell(row=r_idx, column=c_idx, value=label)
            cell.font = HEADER_FONT
            cell.fill = HEADER_FILL
        r_idx += 1

        supplier_totals = agg[store]
        store_total = 0
        month_totals = {m: 0 for m in month_cols}
        for supplier, by_month in sorted(supplier_totals.items(), key=lambda kv: -sum(kv[1].values())):
            row_total = sum(by_month.values())
            store_total += row_total
            ws.cell(row=r_idx, column=1, value=supplier)
            for c_idx, m in enumerate(month_cols, start=2):
                v = by_month.get(m, 0)
                month_totals[m] += v
                cell = ws.cell(row=r_idx, column=c_idx, value=v if v else None)
                cell.number_format = MONEY_FORMAT
            total_cell = ws.cell(row=r_idx, column=2 + len(month_cols), value=row_total)
            total_cell.number_format = MONEY_FORMAT
            r_idx += 1

        # 店舗の小計行
        ws.cell(row=r_idx, column=1, value="小計").font = SUBTOTAL_FONT
        for c_idx, m in enumerate(month_cols, start=2):
            cell = ws.cell(row=r_idx, column=c_idx, value=month_totals[m] if month_totals[m] else None)
            cell.number_format = MONEY_FORMAT
            cell.font = SUBTOTAL_FONT
        total_cell = ws.cell(row=r_idx, column=2 + len(month_cols), value=store_total)
        total_cell.number_format = MONEY_FORMAT
        total_cell.font = SUBTOTAL_FONT
        r_idx += 2  # 空行を挟んで次の店舗へ

    ws.column_dimensions["A"].width = 26
    for c in range(2, max_col + 1):
        ws.column_dimensions[get_column_letter(c)].width = 12


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("check", "add", "edit"):
        print("usage: invoice_ledger.py <check|add|edit> '<JSON payload>'", file=sys.stderr)
        sys.exit(1)
    payload = json.loads(sys.argv[2])
    if sys.argv[1] == "check":
        cmd_check(payload)
    elif sys.argv[1] == "edit":
        cmd_edit(payload)
    else:
        cmd_add(payload)


if __name__ == "__main__":
    main()
