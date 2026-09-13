#!/usr/bin/env python3
"""見本フォルダへ写真を1枚コピーする（AIから呼ばれる唯一の書き込み口）。

使い方:
    python3 pick_mihon.py <元画像の絶対パス> <仕入先名> <店舗名>

作られる場所: 見本/<仕入先名>/<店舗名>/<元のファイル名>

move_sorted.py と同じ考え方で、AIには「どれを見本にするか」の判断だけさせ、
実際のファイル操作（フォルダ作成・重複回避・元ファイルを動かさないこと）は
このスクリプトが受け持つ。元の写真は必ずコピー（移動ではない）。
"""
import shutil
import sys
from pathlib import Path

MIHON_ROOT = Path(__file__).resolve().parent / "見本"
# 仕分け先と同じ7店舗。ここに無い店舗名は受け付けない（打ち間違い・表記ゆれ対策）
STORES = {"本店", "KADODE店", "空港店", "静岡紺屋町店", "セントラル", "冷凍事業部", "製麺事業部"}


def main():
    if len(sys.argv) != 4:
        print("使い方: python3 pick_mihon.py <元画像の絶対パス> <仕入先名> <店舗名>")
        return 1

    src = Path(sys.argv[1])
    supplier = sys.argv[2].strip()
    store = sys.argv[3].strip()

    if not src.is_file():
        print(f"エラー: 元画像が見つかりません: {src}")
        return 1
    if not supplier or "/" in supplier:
        print(f"エラー: 仕入先名が不正です: {supplier}")
        return 1
    if store not in STORES:
        print(f"エラー: 店舗名が7店舗のいずれでもありません: {store}")
        return 1

    dest_dir = MIHON_ROOT / supplier / store
    dest_dir.mkdir(parents=True, exist_ok=True)

    # 既に見本がある組み合わせは上書きしない（先に入れた1枚を正とする）
    existing = [p for p in dest_dir.iterdir() if p.is_file() and not p.name.startswith(".")]
    if existing:
        print(f"スキップ: {supplier}/{store} には既に見本があります（{existing[0].name}）")
        return 0

    dest = dest_dir / src.name
    shutil.copy2(src, dest)
    print(f"登録: {supplier}/{store}/{dest.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
