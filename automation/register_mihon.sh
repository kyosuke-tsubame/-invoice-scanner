#!/bin/zsh
# 見本（仕入先ごと・店舗ごとの手本写真）を、仕分け済みの写真の中から選んで登録する。
#
# 2026-09-12新設。狙いは2つ。
#   1. 「この仕入先のこの形の伝票は、この店舗」という手本を作り、店舗の判定精度を上げる
#   2. 選ぶ過程で「写真の中身と入っているフォルダが食い違うもの」を洗い出す（誤仕分けの発見）
#
# 元の写真は動かさない（コピーのみ）。何度流しても、既に見本がある組み合わせは飛ばす。
set -uo pipefail

PROJECT_DIR="$HOME/Claude/invoice-scanner/automation"
LOG_DIR="$PROJECT_DIR/logs"
"$HOME/Claude/scripts/sync_claude_bin.sh" >/dev/null 2>&1
CLAUDE_BIN="$HOME/Claude/bin/claude"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$HOME/.local/bin/claude"
ONEDRIVE_ROOT="$HOME/Library/CloudStorage/OneDrive-個人用"
PHOTOS_ROOT="$ONEDRIVE_ROOT/納品書写真"
MIHON_DIR="$PROJECT_DIR/見本"
PICK_SCRIPT="$PROJECT_DIR/pick_mihon.py"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/register_mihon_$TIMESTAMP.log"
# 1グループあたり何組（仕入先×店舗）を見るか。多すぎると夜間に固まるため小さく分ける
GROUP_SIZE=5
SUPPLIER_MAP_FILE="$PROJECT_DIR/仕入先_店舗マップ.txt"
# 1組あたり最大何枚の候補を見せるか
CANDIDATES=3

mkdir -p "$LOG_DIR" "$MIHON_DIR"
cd "$PROJECT_DIR"

# まだ見本が無い「仕入先×店舗」の組み合わせと、その候補写真を洗い出す
WORK_FILE="$LOG_DIR/.mihon_work_$TIMESTAMP.txt"
python3 - "$PHOTOS_ROOT" "$MIHON_DIR" "$CANDIDATES" > "$WORK_FILE" <<'PY'
import os, sys

photos_root, mihon_dir, n_cand = sys.argv[1], sys.argv[2], int(sys.argv[3])
STORES = ["本店", "KADODE店", "空港店", "静岡紺屋町店", "セントラル", "冷凍事業部", "製麺事業部"]
EXT = (".jpg", ".jpeg", ".png")

for store in STORES:
    sdir = os.path.join(photos_root, store)
    if not os.path.isdir(sdir):
        continue
    for supplier in sorted(os.listdir(sdir)):
        pdir = os.path.join(sdir, supplier)
        if not os.path.isdir(pdir) or supplier.startswith("."):
            continue
        # 既に見本があればこの組み合わせは飛ばす
        done = os.path.join(mihon_dir, supplier, store)
        if os.path.isdir(done) and any(
            not f.startswith(".") for f in os.listdir(done)
        ):
            continue
        files = []
        for dp, _, fs in os.walk(pdir):
            for f in fs:
                if f.startswith(".") or not f.lower().endswith(EXT):
                    continue
                files.append(os.path.join(dp, f))
        if not files:
            continue
        # 「要確認_」が付いていない＝判定に自信があった写真を優先して候補にする
        files.sort(key=lambda p: (os.path.basename(p).startswith("要確認_"), p))
        for p in files[:n_cand]:
            print(f"{supplier}\t{store}\t{p}")
        print("---")
PY

if [ ! -s "$WORK_FILE" ]; then
  echo "見本が必要な組み合わせはありません: $(date)" >> "$LOG_DIR/last_run_register_mihon.log"
  rm -f "$WORK_FILE"
  exit 0
fi

# 組み合わせ単位のブロック（--- 区切り）に分けて、GROUP_SIZE 組ずつ処理する
TOTAL_COMBOS=$(grep -c '^---$' "$WORK_FILE")
echo "=== 開始: $(date) （見本が必要な組み合わせ ${TOTAL_COMBOS}件を${GROUP_SIZE}件ずつ処理） ===" > "$LOG_FILE"

# 「届け先と仕入れの計上先が違う」仕入先（例：まっちゃん餃子はセントラル宛だが本店の仕入れ）は、
# そのままだと「食い違い」と誤判定されるので、例外としてAIに伝えておく
REBILL_RULES=$(grep '^>' "$SUPPLIER_MAP_FILE" 2>/dev/null | sed 's/^>//')
if [ -n "$REBILL_RULES" ]; then
  REBILL_BLOCK="
【例外：届け先と仕入れの計上先が違う仕入先】
次の仕入先は、納品書の届け先が矢印の左の店舗でも、仕入れは右の店舗として扱う。
この場合はフォルダの店舗が右の店舗であれば正しいので、『食い違い』にはせず見本として登録すること。
${REBILL_RULES}
"
else
  REBILL_BLOCK=""
fi

ALLOWED_TOOLS="Read,Bash(python3 ${PICK_SCRIPT}:*),Bash(python3 pick_mihon.py:*)"
TIMEOUT_SECONDS=2400

BLOCK_NUM=0
GROUP_NUM=0
BUF=""
BUF_COUNT=0

run_group() {
  local body="$1"
  local num="$2"
  [ -z "$body" ] && return 0
  local prompt="【実行環境について】
これは自動実行です。応答者はいません。python3 ${PICK_SCRIPT} の実行は事前に許可済みです。
確認の質問はせず、判断がついた時点でそのまま実行してください。

【やってほしいこと】
納品書の写真から「見本」を選びます。見本とは、あとで別の納品書を見たときに
『この形の伝票は、この仕入先の、この店舗ぶんだ』と見比べるための手本の1枚です。

下に『仕入先／入っているフォルダの店舗／候補写真』の組が並んでいます。
組ごとに、候補写真を上から順に読んで、次の手順で判断してください。

手順1：その写真に、どの店舗宛かが「はっきり」分かる手がかりが写っているか確認する。
  はっきりした手がかりとは、次のいずれか。
    ・届け先として具体的な店舗名が書いてある（例：燕セントラルキッチン、麺屋燕豚中華そば紺屋町店、富士山静岡空港店、麺屋燕 本店）
    ・店舗ごとに違う得意先コード・お客様コードが印字されている
    ・店舗ごとに違う届け先住所が印字されている
  『麺屋燕』『TUBAMEカンパニー』のような会社名だけ、ブランド名だけの場合は、手がかりとして認めない。

手順2：手がかりがあった場合、それが示す店舗と、その写真が入っているフォルダの店舗が一致するか確認する。
  一致する → その写真を見本として登録する（手順3へ）。
  一致しない → 登録せず、最後の報告に『食い違い』として必ず書く（どの写真が、フォルダは何店舗なのに中身は何店舗か）。

手順3：登録は次のコマンドで行う。1つの組につき1枚だけでよい。
  python3 ${PICK_SCRIPT} <元画像の絶対パス> <仕入先名> <店舗名>
  仕入先名・店舗名は、下に書かれているものをそのまま使うこと（勝手に言い換えない）。

手順4：候補をすべて見ても、はっきりした手がかりのある写真が1枚も無かった組は、登録せずに飛ばす。
  最後の報告に『手がかりなし』として、仕入先と店舗を書く。

${REBILL_BLOCK}
【重要】元の写真は絶対に移動・変更しないこと。上のコマンド以外でファイルを触らない。

【対象】
${body}

最後に、次の3つに分けて簡潔に報告してください。
1. 登録できた見本（仕入先／店舗／ファイル名）
2. 食い違い（フォルダの店舗と中身の店舗が違ったもの）
3. 手がかりなしで飛ばした組"

  echo "--- グループ${num} 開始: $(date) ---" >> "$LOG_FILE"
  "$CLAUDE_BIN" -p \
    --allowedTools "$ALLOWED_TOOLS" \
    --add-dir "$ONEDRIVE_ROOT" \
    --no-session-persistence \
    "$prompt" >> "$LOG_FILE" 2>&1 &
  local pid=$!
  ( sleep "$TIMEOUT_SECONDS"
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null && \
      echo "タイムアウト: グループ${num} ($(date))" >> "$LOG_FILE"
  ) &
  local watcher=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  echo "--- グループ${num} 終了(exit ${rc}): $(date) ---" >> "$LOG_FILE"
}

while IFS= read -r line; do
  if [ "$line" = "---" ]; then
    BLOCK_NUM=$((BLOCK_NUM + 1))
    BUF_COUNT=$((BUF_COUNT + 1))
    if [ "$BUF_COUNT" -ge "$GROUP_SIZE" ]; then
      GROUP_NUM=$((GROUP_NUM + 1))
      run_group "$BUF" "$GROUP_NUM"
      BUF=""
      BUF_COUNT=0
    fi
    continue
  fi
  supplier="${line%%	*}"
  rest="${line#*	}"
  store="${rest%%	*}"
  # 変数名に path は使えない。zshでは path が PATH と連動しており、
  # 代入するとコマンドが見つからなくなる（2026-09-12にこれで全グループが即死した）
  imgpath="${rest#*	}"
  BUF="${BUF}仕入先: ${supplier} ／ フォルダの店舗: ${store} ／ 候補: ${imgpath}
"
done < "$WORK_FILE"

if [ -n "$BUF" ]; then
  GROUP_NUM=$((GROUP_NUM + 1))
  run_group "$BUF" "$GROUP_NUM"
fi

rm -f "$WORK_FILE"
REGISTERED=$(find "$MIHON_DIR" -type f ! -name '.*' | wc -l | tr -d ' ')
echo "=== 終了: $(date) （見本フォルダの写真は合計 ${REGISTERED}枚） ===" >> "$LOG_FILE"
echo "done: $(date) 見本合計${REGISTERED}枚" >> "$LOG_DIR/last_run_register_mihon.log"
