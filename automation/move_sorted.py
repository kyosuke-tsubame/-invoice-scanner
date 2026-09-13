#!/usr/bin/env python3
"""
受信箱の納品書写真を、判定済みの店舗（/取引先/年月）フォルダへ移動する。
仕分け先フォルダの作成・ファイル名の重複対策・低信頼判定時の目印付けをここに一本化し、
呼び出し側（run_invoice_sort.sh）が直接mvを組み立てないようにするための安全弁。

使い方:
  python3 move_sorted.py <元画像の絶対パス> <店舗名 or 不明> <仕入先名 or 不明> <年月 YYYY-MM or 不明> <low_confidence: yes/no>

  store には「納品書写真/」直下に作る/使うフォルダ名をそのまま渡す（例: 本店、KADODE店、不明）。
  storeが「不明」の場合、supplier・year_monthは無視してフラットな「不明」フォルダに入れる。
  supplierまたはyear_monthが「不明」（判定できなかった）場合は、分かる階層までで止める
  （例: supplierだけ分かればstore/supplier/まで、両方分かればstore/supplier/年月/まで）。
  low_confidence が yes の場合、保存ファイル名の先頭に「要確認_」を付ける
  （届け先の記載が無く、仕入先からの推測だけで店舗を決めたことを示す目印。
    後段のrun_invoice_ocr.shはこの目印を見て、必ず要確認扱いにする）。
"""
import sys
import shutil
from pathlib import Path

PHOTOS_ROOT = Path.home() / "Library/CloudStorage/OneDrive-個人用/納品書写真"


def main():
    if len(sys.argv) != 6:
        print("usage: move_sorted.py <元画像の絶対パス> <店舗名 or 不明> <仕入先名 or 不明> <年月 YYYY-MM or 不明> <low_confidence: yes/no>", file=sys.stderr)
        sys.exit(1)

    src_path = Path(sys.argv[1])
    store = sys.argv[2]
    supplier = sys.argv[3]
    year_month = sys.argv[4]
    low_confidence = sys.argv[5].strip().lower() == "yes"

    if not src_path.is_file():
        print(f"元ファイルが見つかりません: {src_path}", file=sys.stderr)
        sys.exit(1)

    dest_dir = PHOTOS_ROOT / store
    if store != "不明":
        if supplier and supplier != "不明":
            dest_dir = dest_dir / supplier
            if year_month and year_month != "不明":
                dest_dir = dest_dir / year_month
    dest_dir.mkdir(parents=True, exist_ok=True)

    filename = src_path.name
    if low_confidence and not filename.startswith("要確認_"):
        filename = f"要確認_{filename}"

    dest_path = dest_dir / filename
    if dest_path.exists():
        stem = Path(filename).stem
        suffix = Path(filename).suffix
        n = 2
        while dest_path.exists():
            dest_path = dest_dir / f"{stem}_{n}{suffix}"
            n += 1

    shutil.move(str(src_path), str(dest_path))
    print(f"移動完了: {src_path.name} -> {dest_path}")


if __name__ == "__main__":
    main()
