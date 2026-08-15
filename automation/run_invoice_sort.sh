#!/bin/zsh
set -uo pipefail

PROJECT_DIR="$HOME/Claude/invoice-scanner/automation"
LOG_DIR="$PROJECT_DIR/logs"
CLAUDE_BIN="$HOME/.local/bin/claude"
ONEDRIVE_ROOT="$HOME/Library/CloudStorage/OneDrive-個人用"
INBOX_DIR="$ONEDRIVE_ROOT/納品書写真/受信箱"
PROCESSED_FILE="$PROJECT_DIR/invoice_sort_processed.txt"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/invoice_sort_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
mkdir -p "$PROJECT_DIR/見本"
cd "$PROJECT_DIR"
touch "$PROCESSED_FILE"

# 受信箱直下の新着画像のうち、まだ処理済みリストに載っていないものだけを対象にする
FIND_ERR_FILE="$LOG_DIR/.sort_find_stderr"
ALL_FILES=("${(@f)$(find "$INBOX_DIR" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \) 2>"$FIND_ERR_FILE")}")

if [ -s "$FIND_ERR_FILE" ]; then
  echo "エラー: $(date) - $INBOX_DIR の検索に失敗（アクセス権限不足の可能性）: $(cat "$FIND_ERR_FILE")" >> "$LOG_DIR/last_run_invoice_sort.log"
  exit 1
fi

TARGET_FILES=()
for f in "${ALL_FILES[@]}"; do
  [ -z "$f" ] && continue
  if ! grep -Fxq "$f" "$PROCESSED_FILE"; then
    TARGET_FILES+=("$f")
  fi
done

if [ ${#TARGET_FILES[@]} -eq 0 ]; then
  echo "対象ファイルなし（新規なし）: $(date)" >> "$LOG_DIR/last_run_invoice_sort.log"
  exit 0
fi

FILE_LIST=$(printf '%s\n' "${TARGET_FILES[@]}")

MOVE_SCRIPT="$PROJECT_DIR/move_sorted.py"
SUPPLIER_MAP_FILE="$PROJECT_DIR/仕入先_店舗マップ.txt"
MIHON_DIR="$PROJECT_DIR/見本"
ALLOWED_TOOLS="Read,Bash(python3 ${MOVE_SCRIPT}:*)"

SUPPLIER_MAP_RULES=$(cat "$SUPPLIER_MAP_FILE")
STORE_LIST_TEXT="本店、KADODE店、空港店、静岡紺屋町店、セントラル、冷凍事業部、製麺事業部"

PROMPT="【実行環境について】
これは深夜バッチによる完全無人の自動実行です。あなたへの応答者は存在しません。
python3 ${MOVE_SCRIPT} の実行はこの呼び出しで事前に許可済み（--allowedTools）です。
『実行してよいですか？』のような確認・質問は一切せず、判定が終わり次第そのまま実行してください（確認質問を出すと、誰も答えられないため処理がそこで停止してしまいます）。

以下の納品書写真を、店舗ごとのフォルダへ仕分けてください。1枚ごとに次の手順で判定します。

【対象ファイル（絶対パス）】
${FILE_LIST}

【手順1：仕入先の判定】
画像を読み、発行元・ロゴ・書式から仕入先名を判定する。
${MIHON_DIR}/<仕入先名>/ に見本画像が置かれていることがある。置かれていれば、その書式（ロゴ・レイアウト）と見比べて判定の参考にしてよい。フォルダが空、または見本が無い場合は無視してよい。
仕入先が全く読み取れない場合は空欄のまま次の手順に進んでよい。

【手順2：店舗の判定】
次の優先順位で判定する。
1. 画像内に届け先の店舗名・住所が明記されていれば、それを読んで店舗を決める（信頼度：高）
2. 明記が無い場合、以下の仕入先→店舗の対応関係に一致すれば、それで店舗を決める（信頼度：低）
   ${SUPPLIER_MAP_RULES}
3. 上記のどちらでも決められない場合は『不明』とする

対象店舗（7つ）：${STORE_LIST_TEXT}
店舗名の表記ゆれ（『空港店』『静岡空港店』など）は上記7つのいずれかに正規化すること。

【手順3：移動】
判定した店舗（または『不明』）と、信頼度が『低』だったかどうかを使い、以下のコマンドで移動する（このスクリプトが移動先フォルダの作成・ファイル名重複対策・低信頼時の目印付けを行う。元ファイルの中身は一切変更しない）：

   python3 ${MOVE_SCRIPT} <元画像の絶対パス> <店舗名 or 不明> <yes(信頼度が低い場合) または no>

『不明』の場合、low_confidence引数は no でよい（不明フォルダ自体が『要確認』の目印になるため）。

【重要】
店舗が確信を持てない場合は、無理に決めず『不明』に入れること。
最後に、何をどこに仕分けたか（元ファイル名→店舗→信頼度→保存ファイル名）を簡潔に一覧で報告してください。"

# 何らかの理由でclaudeの呼び出しが極端に長引いた場合に備え、60分で強制終了する保険をかける
TIMEOUT_SECONDS=3600
"$CLAUDE_BIN" -p \
  --allowedTools "$ALLOWED_TOOLS" \
  --add-dir "$ONEDRIVE_ROOT" \
  --no-session-persistence \
  "$PROMPT" \
  > "$LOG_FILE" 2>&1 &
CLAUDE_PID=$!
( sleep "$TIMEOUT_SECONDS"
  if kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill -9 "$CLAUDE_PID" 2>/dev/null
    echo "タイムアウト: ${TIMEOUT_SECONDS}秒経っても完了しなかったため強制終了しました ($(date))" >> "$LOG_FILE"
  fi
) &
WATCHER_PID=$!
wait "$CLAUDE_PID" 2>/dev/null
CLAUDE_EXIT=$?
kill "$WATCHER_PID" 2>/dev/null
wait "$WATCHER_PID" 2>/dev/null

if [ "$CLAUDE_EXIT" -eq 0 ]; then
  # 正常終了した分だけ「処理済み」として記録する（移動済みで受信箱には既に無いはずだが、
  # 途中失敗時に同じファイルを重複して判定し直さないための保険）
  printf '%s\n' "${TARGET_FILES[@]}" >> "$PROCESSED_FILE"
else
  echo "警告: claude呼び出しが異常終了（exit ${CLAUDE_EXIT}、タイムアウトの可能性）のため、今回の対象ファイルは処理済みにせず次回また対象にします ($(date))" >> "$LOG_FILE"
fi

echo "done: $(date)" >> "$LOG_DIR/last_run_invoice_sort.log"

# 古いログを30日で自動整理
find "$LOG_DIR" -name "invoice_sort_*.log" -mtime +30 -delete
