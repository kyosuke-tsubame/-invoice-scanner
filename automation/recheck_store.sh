#!/bin/zsh
# すでに仕分け済みの写真について、店舗の入れ間違いがないか見直す。
#
# 2026-09-12新設。仕分けの判定ルールに誤りが見つかったため（「会社名だけなら本店」が
# 仕入先→店舗の対応表より先に効いていた／会社住所8770を本店の証拠にしていた）、
# 過去に仕分け済みの写真を、直したルールでもう一度判定し直すために作った。
#
# 使い方:  ./recheck_store.sh <見直す店舗名>      例: ./recheck_store.sh 本店
#
# 判定が変わった写真だけを move_sorted.py で移動する。中身は一切変更しない。
set -uo pipefail

TARGET_STORE="${1:-}"
if [ -z "$TARGET_STORE" ]; then
  echo "使い方: ./recheck_store.sh <見直す店舗名>（例: 本店）"
  exit 1
fi

PROJECT_DIR="$HOME/Claude/invoice-scanner/automation"
LOG_DIR="$PROJECT_DIR/logs"
"$HOME/Claude/scripts/sync_claude_bin.sh" >/dev/null 2>&1
CLAUDE_BIN="$HOME/Claude/bin/claude"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$HOME/.local/bin/claude"
ONEDRIVE_ROOT="$HOME/Library/CloudStorage/OneDrive-個人用"
PHOTOS_ROOT="$ONEDRIVE_ROOT/納品書写真"
MOVE_SCRIPT="$PROJECT_DIR/move_sorted.py"
MIHON_DIR="$PROJECT_DIR/見本"
SUPPLIER_MAP_FILE="$PROJECT_DIR/仕入先_店舗マップ.txt"
STORE_ADDR_FILE="$PROJECT_DIR/店舗_住所マップ.txt"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/recheck_${TARGET_STORE}_$TIMESTAMP.log"
GROUP_SIZE=8
TIMEOUT_SECONDS=2400

mkdir -p "$LOG_DIR"
cd "$PROJECT_DIR"

TARGET_DIR="$PHOTOS_ROOT/$TARGET_STORE"
if [ ! -d "$TARGET_DIR" ]; then
  echo "エラー: $TARGET_DIR がありません"
  exit 1
fi

# 対象写真を洗い出す（OneDriveの実体化も先に済ませる）
ALL_FILES=("${(@f)$(find "$TARGET_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) ! -name '.*')}")
TARGET_FILES=()
for f in "${ALL_FILES[@]}"; do
  [ -z "$f" ] && continue
  TARGET_FILES+=("$f")
done

if [ ${#TARGET_FILES[@]} -eq 0 ]; then
  echo "対象なし: $TARGET_DIR"
  exit 0
fi

# クラウドのみ状態の写真を先にダウンロードさせる（読めないまま判定させない）
NOT_READY=("${TARGET_FILES[@]}")
for wait_sec in 0 30 60; do
  [ ${#NOT_READY[@]} -eq 0 ] && break
  [ "$wait_sec" -gt 0 ] && sleep "$wait_sec"
  STILL=()
  for f in "${NOT_READY[@]}"; do
    cat "$f" > /dev/null 2>&1 || STILL+=("$f")
  done
  NOT_READY=("${STILL[@]}")
done
if [ ${#NOT_READY[@]} -gt 0 ]; then
  READY=()
  for f in "${TARGET_FILES[@]}"; do
    skip=0
    for n in "${NOT_READY[@]}"; do [ "$f" = "$n" ] && skip=1 && break; done
    [ "$skip" -eq 0 ] && READY+=("$f")
  done
  TARGET_FILES=("${READY[@]}")
fi

SUPPLIER_MAP_RULES=$(grep -v '^!' "$SUPPLIER_MAP_FILE" | grep -v '^>')
NO_AUTO_STORE=$(grep '^!' "$SUPPLIER_MAP_FILE" | sed 's/^!//' | paste -sd '、' -)
REBILL_RULES=$(grep '^>' "$SUPPLIER_MAP_FILE" | sed 's/^>//')
STORE_ADDR=$(cat "$STORE_ADDR_FILE" 2>/dev/null)
STORE_LIST_TEXT="本店、KADODE店、空港店、静岡紺屋町店、セントラル、冷凍事業部、製麺事業部"
ALLOWED_TOOLS="Read,Bash(python3 ${MOVE_SCRIPT}:*),Bash(python3 move_sorted.py:*)"

TOTAL=${#TARGET_FILES[@]}
BATCH_COUNT=$(( (TOTAL + GROUP_SIZE - 1) / GROUP_SIZE ))
echo "=== 開始: $(date) （${TARGET_STORE} の${TOTAL}枚を${GROUP_SIZE}枚ずつ${BATCH_COUNT}グループで見直し） ===" > "$LOG_FILE"

i=1
BATCH_NUM=0
while [ "$i" -le "$TOTAL" ]; do
  BATCH_NUM=$((BATCH_NUM + 1))
  END=$((i + GROUP_SIZE - 1))
  [ "$END" -gt "$TOTAL" ] && END=$TOTAL
  BATCH=()
  for ((j = i; j <= END; j++)); do BATCH+=("${TARGET_FILES[$j]}"); done
  FILE_LIST=$(printf '%s\n' "${BATCH[@]}")

  PROMPT="【実行環境について】
これは自動実行です。応答者はいません。python3 ${MOVE_SCRIPT} の実行は事前に許可済みです。
確認の質問はせず、判断がついた時点でそのまま実行してください。

【やってほしいこと】
下の写真は現在すべて『${TARGET_STORE}』のフォルダに入っています。
しかし過去の判定ルールに誤りがあったため、別の店舗のものが混ざっている可能性があります。
1枚ずつ中身を読んで、本当に『${TARGET_STORE}』で正しいかを判定し直してください。

【対象ファイル（絶対パス）】
${FILE_LIST}

【手順1：仕入先を読む】
発行元・ロゴ・書式から仕入先名を判定する。
${MIHON_DIR}/<仕入先名>/<店舗名>/ に見本（店舗が確定済みの手本）がある。書式・得意先コードの位置を見比べる参考にしてよい。

【手順2：店舗を判定する】
上から順に見て、当てはまったところで決める。前の番号で決まらないときだけ次へ進む。

1. 届け先として具体的な店舗名が書いてある（例：燕セントラルキッチン、麺屋燕 本店、富士山静岡空港店、紺屋町店、燕食堂）
   → その店舗（信頼度：高）
   ※伝票の上部だけでなく、摘要欄・備考欄・店名欄・手書きメモまで必ず全部見ること。
2. 届け先住所や得意先コードが、下の【店舗ごとの住所・目印】か見本の写真と一致する
   → その店舗（信頼度：高）
3. 下の仕入先→店舗の対応関係に載っている
   → その店舗（信頼度：低）
   ${SUPPLIER_MAP_RULES}
4. ここまでで決まらず、宛名が『燕』『麺屋燕』『TUBAMEカンパニー』など会社全体を指すだけ
   → 本店とみなす（信頼度：低）
5. それでも決まらない → 『不明』

【店舗ごとの住所・目印】
${STORE_ADDR}

【店舗を自動判定しない仕入先】
次の仕入先は複数店舗に納品があるため、手順1で店舗名が読めなかった場合は手順4を使わず必ず『不明』にする。
対象：${NO_AUTO_STORE}

【届け先と仕入れの計上先が違う仕入先】
次の仕入先は、届け先が矢印の左の店舗でも、仕入れは右の店舗として扱う。
${REBILL_RULES}

【手順3：移動が必要かどうか】
判定した店舗が『${TARGET_STORE}』と同じなら、何もしない（移動しない）。
違う店舗、または『不明』になった場合だけ、次のコマンドで移動する。

   python3 ${MOVE_SCRIPT} <元画像の絶対パス> <判定した店舗 or 不明> <仕入先名 or 不明> <年月 YYYY-MM or 不明> <yes(信頼度が低い場合) または no>

年月は伝票日付から YYYY-MM 形式で読む。読めなければ『不明』を渡す。

対象店舗（7つ）：${STORE_LIST_TEXT}

【重要】
・確信が持てないときは動かさない。今のフォルダのままにして、報告に『判断できず』と書く。
  誤って動かすと、どこに何があるか分からなくなるため、動かさない方が安全。
・上のコマンド以外でファイルを触らないこと。

最後に、次の3つに分けて簡潔に報告してください。
1. 移動したもの（元ファイル名／判定した店舗／根拠）
2. ${TARGET_STORE}のままで正しかったもの（ファイル名と根拠を1行ずつ）
3. 判断できず動かさなかったもの（ファイル名と理由）"

  echo "--- グループ${BATCH_NUM}/${BATCH_COUNT} 開始: $(date) ---" >> "$LOG_FILE"
  "$CLAUDE_BIN" -p \
    --allowedTools "$ALLOWED_TOOLS" \
    --add-dir "$ONEDRIVE_ROOT" \
    --no-session-persistence \
    "$PROMPT" >> "$LOG_FILE" 2>&1 &
  CPID=$!
  ( sleep "$TIMEOUT_SECONDS"
    kill -0 "$CPID" 2>/dev/null && kill -9 "$CPID" 2>/dev/null && \
      echo "タイムアウト: グループ${BATCH_NUM} ($(date))" >> "$LOG_FILE"
  ) &
  WPID=$!
  wait "$CPID" 2>/dev/null
  RC=$?
  kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
  echo "--- グループ${BATCH_NUM}/${BATCH_COUNT} 終了(exit ${RC}): $(date) ---" >> "$LOG_FILE"

  i=$((END + 1))
done

echo "=== 終了: $(date) ===" >> "$LOG_FILE"
echo "done: $(date) ${TARGET_STORE} ${TOTAL}枚を見直し" >> "$LOG_DIR/last_run_recheck.log"
