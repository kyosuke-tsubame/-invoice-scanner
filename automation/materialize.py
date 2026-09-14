#!/usr/bin/env python3
"""OneDriveの「クラウドのみ（未ダウンロード）」の写真を、読み込んで手元に実体化させる。

2026-09-14新設。毎晩の自動起動（launchd）から動く処理は、macOSの設定で
「クラウドにしか無いファイルを開いてもダウンロードしない」扱いになっていて、
cat や mv が「Resource deadlock avoided」で失敗していた（待っても読めない）。
この部品は自分の中でその設定を「ダウンロードする」に切り替えてから読むので、夜間でも実体化できる。
一度実体化したファイルは、そのあと普通の cat / mv / AI の読み取りで扱える。

  標準入力にファイルパスを1行ずつ渡す。読めなかったパスだけを標準出力に1行ずつ返す。
  printf '%s\n' "${FILES[@]}" | python3 materialize.py
"""
import ctypes
import sys
import time

IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES = 3
IOPOL_SCOPE_PROCESS = 0
IOPOL_MATERIALIZE_DATALESS_FILES_ON = 2


def allow_download():
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    libc.setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                        IOPOL_MATERIALIZE_DATALESS_FILES_ON)


def readable(path):
    try:
        with open(path, "rb") as f:
            while f.read(1 << 20):
                pass
        return True
    except OSError:
        return False


def main():
    allow_download()
    pending = [l.rstrip("\n") for l in sys.stdin if l.strip()]
    # ダウンロードに一時的に失敗することもあるので、少し待って2回まで読み直す
    for wait in (0, 30, 60):
        if not pending:
            break
        time.sleep(wait)
        pending = [p for p in pending if not readable(p)]
    for p in pending:
        print(p)


if __name__ == "__main__":
    main()
