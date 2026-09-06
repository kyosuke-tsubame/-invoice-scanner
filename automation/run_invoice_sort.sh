#!/bin/zsh
set -uo pipefail

PROJECT_DIR="$HOME/Claude/invoice-scanner/automation"
LOG_DIR="$PROJECT_DIR/logs"
# 2026-09-07変更：Claude本体はバージョンごとにファイル名が変わるため、更新のたびに
# macOSの「OneDriveで管理されているファイルにアクセスしようとしています」確認が復活し、
# 応答者のいない夜間バッチが固まってタイムアウトしていた。名前が変わらない固定パスのコピーを使う。
"$HOME/Claude/scripts/sync_claude_bin.sh" >/dev/null 2>&1
CLAUDE_BIN="$HOME/Claude/bin/claude"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$HOME/.local/bin/claude"
ONEDRIVE_ROOT="$HOME/Library/CloudStorage/OneDrive-個人用"
INBOX_DIR="$ONEDRIVE_ROOT/納品書写真/受信箱"
PROCESSED_FILE="$PROJECT_DIR/invoice_sort_processed.txt"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/invoice_sort_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
mkdir -p "$PROJECT_DIR/見本"
cd "$PROJECT_DIR"
touch "$PROCESSED_FILE"

# 2026-09-06追加：OneDrive側の見本投入フォルダに置かれた写真を、アプリ内の見本フォルダへ自動で移す。
# アプリ内フォルダ（invoice-scanner/automation/見本/）は普段OneDriveしか触らないユーザーからは
# 見えにくい場所のため、OneDrive「納品書写真/_見本投入/<仕入先名>/」に置くだけで済むようにした。
# AIを介さず単純なファイル移動のみなので、この処理自体がフリーズすることはない。
MIHON_INBOX_DIR="$ONEDRIVE_ROOT/納品書写真/_見本投入"
mkdir -p "$MIHON_INBOX_DIR"
find "$MIHON_INBOX_DIR" -mindepth 2 -maxdepth 2 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \) -print0 2>/dev/null |
while IFS= read -r -d '' f; do
  supplier=$(basename "$(dirname "$f")")
  dest_dir="$PROJECT_DIR/見本/$supplier"
  mkdir -p "$dest_dir"
  dest="$dest_dir/$(basename "$f")"
  # 同名ファイルが既にあれば上書きせずタイムスタンプを付けて退避
  [ -e "$dest" ] && dest="$dest_dir/$(date +%Y%m%d%H%M%S)_$(basename "$f")"
  mv "$f" "$dest" && echo "見本を移動: $f -> $dest ($(date))" >> "$LOG_DIR/last_run_invoice_sort.log"
done

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
見本フォルダと一致した場合は、表記ゆれを避けるため必ずその見本フォルダ名（${MIHON_DIR}/直下のフォルダ名）をそのまま仕入先名として使うこと（例：見本フォルダが『木村商事』なら『木村商事株式会社』のように書かず『木村商事』を使う）。
仕入先が全く読み取れない場合は『不明』として次の手順に進んでよい。

【手順2：店舗の判定】
次の優先順位で判定する。
1. 画像内に届け先として対象店舗7つのうちどれか一つの店舗名・住所が具体的に明記されていれば、それを読んで店舗を決める（信頼度：高）
2. 届け先の記載が『燕』『麺屋燕』『TUBAMEカンパニー』『株式会社TUBAMEカンパニー』のように会社全体を指すだけで、
   店舗が特定できない場合は、本店とみなす（信頼度：低）
3. 上記1・2のどちらでもない場合、以下の仕入先→店舗の対応関係に一致すれば、それで店舗を決める（信頼度：低）
   ${SUPPLIER_MAP_RULES}
4. 上記のいずれでも決められない場合は『不明』とする

対象店舗（7つ）：${STORE_LIST_TEXT}
店舗名の表記ゆれ（『空港店』『静岡空港店』など）は上記7つのいずれかに正規化すること。
既知の別名：『燕食堂』＝セントラル

【手順3：伝票日付（年月）の判定】
画像内の伝票日付・納品日を読み、『YYYY-MM』形式（例：2026-08）に変換する。西暦への変換（令和・令和年号表記など）が必要な場合はここで行う。日付が読めない場合は『不明』とする。

【手順4：移動】
判定した店舗（または『不明』）・仕入先（または『不明』）・年月（または『不明』）・信頼度が『低』だったかどうかを使い、以下のコマンドで移動する（このスクリプトが移動先フォルダの作成・ファイル名重複対策・低信頼時の目印付けを行う。元ファイルの中身は一切変更しない）：

   python3 ${MOVE_SCRIPT} <元画像の絶対パス> <店舗名 or 不明> <仕入先名 or 不明> <年月 YYYY-MM or 不明> <yes(信頼度が低い場合) または no>

『不明』店舗の場合、仕入先・年月は『不明』を渡し、low_confidence引数は no でよい（不明フォルダ自体が『要確認』の目印になるため）。
店舗は分かったが仕入先や年月が読み取れない場合は、読み取れた項目まで渡し、読み取れない項目には『不明』を渡すこと（move_sorted.pyが分かる階層までのフォルダに保存する）。

【重要】
店舗が確信を持てない場合は、無理に決めず『不明』に入れること。
最後に、何をどこに仕分けたか（元ファイル名→店舗→仕入先→年月→信頼度→保存ファイル名）を簡潔に一覧で報告してください。"

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

# ログイン切れ等で失敗していたら、Claudeを介さず直接Slackへ警告する
"$HOME/Claude/scripts/notify_claude_login_issue.sh" "納品書写真仕分け" "$LOG_FILE" "$CLAUDE_EXIT"

echo "done: $(date)" >> "$LOG_DIR/last_run_invoice_sort.log"

# 古いログを30日で自動整理
find "$LOG_DIR" -name "invoice_sort_*.log" -mtime +30 -delete
