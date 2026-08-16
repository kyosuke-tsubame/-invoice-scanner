#!/bin/zsh
set -uo pipefail

PROJECT_DIR="$HOME/Claude/invoice-scanner/automation"
LOG_DIR="$PROJECT_DIR/logs"
CLAUDE_BIN="$HOME/.local/bin/claude"
ONEDRIVE_ROOT="$HOME/Library/CloudStorage/OneDrive-個人用"
PHOTOS_ROOT="$ONEDRIVE_ROOT/納品書写真"
STATE_FILE="$PROJECT_DIR/invoice_ocr_state.json"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/invoice_ocr_$TIMESTAMP.log"
LEDGER_SCRIPT="$PROJECT_DIR/invoice_ledger.py"
LEDGER_XLSX="$ONEDRIVE_ROOT/納品書集計/納品書集計.xlsx"

mkdir -p "$LOG_DIR"
cd "$PROJECT_DIR"

if [ ! -f "$STATE_FILE" ]; then
  echo "{}" > "$STATE_FILE"
fi

# 受信箱の新着写真を店舗フォルダへ仕分けてから読み取りに進む
"$PROJECT_DIR/run_invoice_sort.sh"

STORES=("本店" "KADODE店" "空港店" "静岡紺屋町店" "セントラル" "冷凍事業部" "製麺事業部")
STORE_LIST_TEXT="本店、KADODE店、空港店、静岡紺屋町店、セントラル、冷凍事業部、製麺事業部"

# iPhoneのHEIC画像をJPEGに変換しておく（読み取りエンジンが確実に読めるように）
setopt nullglob
for store in "${STORES[@]}"; do
  dir="$PHOTOS_ROOT/$store"
  [ -d "$dir" ] || continue
  for heic in "$dir"/*.heic "$dir"/*.HEIC; do
    jpg="${heic%.*}.jpg"
    [ -f "$jpg" ] && continue
    sips -s format jpeg "$heic" --out "$jpg" >/dev/null 2>&1
  done
done
unsetopt nullglob

ALLOWED_TOOLS="Read,Write,Edit,Bash(python3 ${LEDGER_SCRIPT}:*),mcp__mail-secretary__notify_slack"

PROMPT="【実行環境について】
これは夜間バッチによる完全無人の自動実行です。あなたへの応答者は存在しません。
『実行してよいですか？』のような確認・質問は一切せず、判定が終わり次第そのまま実行してください（確認質問を出すと、誰も答えられないため処理がそこで停止してしまいます）。

【目的】
ラーメン店7店舗が共有フォルダ（OneDrive）にアップロードした納品書の写真を読み取り、内容に自信がある分だけExcel台帳（${LEDGER_XLSX}）に自動記帳する。自信が持てない分は記帳せず、Slackで1通にまとめて報告する。報告を見た人が、OneDrive上の元写真を直接確認し、同じExcelファイルに手入力で追記する運用にする（専用の修正アプリは使わない）。

【対象フォルダ】
${PHOTOS_ROOT}/<店舗名>/ ＝ 店舗名は次の7つ：${STORE_LIST_TEXT}
各店舗フォルダ直下の画像ファイル（jpg/jpeg/png）が対象。

【状態ファイル】
${STATE_FILE}
このJSONファイルで処理状況を管理する。キーは画像ファイルの絶対パス、値は以下の形のオブジェクト（statusはExcelへの記帳状況を表す）：
{
  \"status\": \"auto_saved\" | \"held_for_review\",
  \"store\": \"<店舗フォルダ名>\",
  \"date\": \"YYYY-MM-DD or 空文字\",
  \"supplier\": \"<仕入先。読み取れなければ空文字>\",
  \"total\": 0,
  \"taxType\": \"excluded\" | \"included\" | \"unknown\",
  \"note\": \"<保留にした理由。自動保存なら空欄>\",
  \"processedAt\": \"<処理日時>\"
}
このファイルはRead/Writeで読み書きすること。壊さないよう、更新時は全体を読み直してから書き戻すこと。

【手順1：新着写真のスキャンと読み取り】
上記の対象フォルダを確認し、状態ファイルにまだ記録されていない（＝初めて見る）画像ファイルを探す。
各画像について、Readで直接開いて日本語の納品書として次を読み取る：
- date：納品日（YYYY-MM-DD形式。読めなければ空文字）
- supplier：仕入先の会社名（読めなければ空文字）
- total と taxType：税抜金額（税抜金額）が明記されていればそれをtotalとし、taxTypeを\"excluded\"とする。税込金額（税込金額）しか無ければそれをtotalとし、taxTypeを\"included\"とする。判断できなければtaxTypeを\"unknown\"とする。
- store：画像が入っていたフォルダ名をそのまま使う

【手順2：自動保存か要確認かの判定】
次のいずれかに該当する画像は\"held_for_review\"（要確認）とし、スプレッドシートには書き込まない：
- date または supplier が空文字
- total が0以下
- taxType が \"included\" または \"unknown\"（税率は品目により8%/10%が分かれ、思い込みで決め打ちすると記帳ミスになるため、税抜が明記されている物だけを自動対象にする）
- 手順3で重複の疑いありと判定された
- ファイル名が「要確認_」で始まる（届け先の記載が無く、仕入先からの推測だけで店舗フォルダを決めた印。内容の自信度に関わらず必ず要確認とし、noteに「店舗を仕入先からの推測のみで判定（届け先記載なし）」と記録する）

上記のどれにも該当しなければ、手順3の重複チェックに進む。

【手順3：重複チェック】
自動保存候補になった画像について、以下のコマンドで重複を確認する：
python3 ${LEDGER_SCRIPT} check '{\"date\":\"<date>\",\"store\":\"<store>\",\"total\":<total>}'
返ってきたJSONの duplicate が true なら、この画像は\"held_for_review\"に変更し、note に「重複の可能性」と記録する。重複が無ければ手順4に進む。

【手順4：記帳】
以下のコマンドでExcel台帳に追記する（データシートへの追記と、店舗別集計シートの作り直しを両方このスクリプトが行う）：
python3 ${LEDGER_SCRIPT} add '{\"date\":\"<date>\",\"store\":\"<store>\",\"supplier\":\"<supplier>\",\"total\":<total>,\"category\":\"仕入れ\"}'
成功したら状態ファイルにこの画像を status \"auto_saved\" として記録する（note は空欄）。

【手順5：Slack報告】
${PHOTOS_ROOT}/不明/ に入っている画像の件数を数える（店舗が自動判定できず仕分けの時点で保留になったもの）。
今回処理した画像が1件以上、または不明フォルダに1件以上あれば、mcp__mail-secretary__notify_slackで1通だけ報告する。
見出しは『【納品書OCR】』とする。
自動記帳した分：店舗・日付・仕入先・金額を一覧で。
要確認になった分：店舗・ファイル名・読み取れた範囲の内容（分かる範囲でよい）・保留理由を一覧で、『OneDriveの元写真を確認のうえ、Excel台帳（納品書写真と同じOneDrive内、「納品書集計/納品書集計.xlsx」）に直接1行追記してください』と添える。
不明フォルダに画像がある場合：件数を伝え、『店舗が自動判定できませんでした。OneDriveの「納品書写真/不明」フォルダを開いて、正しい店舗フォルダへ手動で移動するか、Excel台帳に直接記帳してください』と添える。
返信は不要な旨（『返信不要です。読み取りが違う場合だけ教えてください』程度）を添える。
今回処理した画像が0件、かつ不明フォルダも0件なら、手順5は何もしない（新規0件の日は通知しない）。

【手順6：ログ】
最後に、今回何をしたか（新規検出件数／自動記帳件数／要確認件数とその内訳）を簡潔に報告してください。"

# 何らかの理由でclaudeの呼び出しが極端に長引いた場合に備え、90分で強制終了する保険をかける
TIMEOUT_SECONDS=5400
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
kill "$WATCHER_PID" 2>/dev/null
wait "$WATCHER_PID" 2>/dev/null

echo "done: $(date)" >> "$LOG_DIR/last_run_invoice_ocr.log"

# 古いログを30日で自動整理
find "$LOG_DIR" -name "invoice_ocr_*.log" -mtime +30 -delete
