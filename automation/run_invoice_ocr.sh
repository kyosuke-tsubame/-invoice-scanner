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
BATCH_SIZE=5
RUN_STARTED_AT=$(date "+%Y-%m-%d %H:%M:%S")

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
# 店舗フォルダの直下だけでなく、仕分けで作られる「仕入先/年月」の奥のフォルダも対象にする
for store in "${STORES[@]}"; do
  dir="$PHOTOS_ROOT/$store"
  [ -d "$dir" ] || continue
  find "$dir" -type f \( -iname "*.heic" \) -print0 | while IFS= read -r -d '' heic; do
    jpg="${heic%.*}.jpg"
    [ -f "$jpg" ] && continue
    sips -s format jpeg "$heic" --out "$jpg" >/dev/null 2>&1
  done
done

# 状態ファイルにまだ記録されていない画像ファイルを、シェル側で先に洗い出す
# （1回のフォルダ探索・一括処理だと、対象が多い夜に処理が固まって
#   1件も進まない事態が起きたため、少人数のグループに分けて1つずつ処理する）
# 店舗フォルダの直下だけでなく、仕分けで作られる「仕入先/年月」の奥のフォルダも対象にする
ALL_IMAGES_FILE="$LOG_DIR/.all_images_$TIMESTAMP.txt"
: > "$ALL_IMAGES_FILE"
for store in "${STORES[@]}"; do
  dir="$PHOTOS_ROOT/$store"
  [ -d "$dir" ] || continue
  find "$dir" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -print >> "$ALL_IMAGES_FILE"
done

UNPROCESSED_FILE="$LOG_DIR/.unprocessed_$TIMESTAMP.txt"
python3 -c "
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
with open('$ALL_IMAGES_FILE') as f:
    all_images = [l.strip() for l in f if l.strip()]
unprocessed = [p for p in all_images if p not in state]
with open('$UNPROCESSED_FILE', 'w') as f:
    f.write('\n'.join(unprocessed))
"
if [ -s "$UNPROCESSED_FILE" ]; then
  TARGET_FILES=("${(@f)$(cat "$UNPROCESSED_FILE")}")
else
  TARGET_FILES=()
fi
rm -f "$ALL_IMAGES_FILE" "$UNPROCESSED_FILE"

# 不明フォルダ（店舗が自動判定できなかった画像）の件数もシェル側で先に数えておく
UNKNOWN_DIR="$PHOTOS_ROOT/不明"
UNKNOWN_COUNT=0
if [ -d "$UNKNOWN_DIR" ]; then
  setopt nullglob
  UNKNOWN_FILES=("$UNKNOWN_DIR"/*.jpg "$UNKNOWN_DIR"/*.jpeg "$UNKNOWN_DIR"/*.JPG "$UNKNOWN_DIR"/*.JPEG "$UNKNOWN_DIR"/*.png "$UNKNOWN_DIR"/*.PNG)
  UNKNOWN_COUNT=${#UNKNOWN_FILES[@]}
  unsetopt nullglob
fi

TOTAL=${#TARGET_FILES[@]}
# 対象が無くても、Slack返信対応と不明フォルダの報告だけは毎回1グループとして走らせる
BATCH_COUNT=$(( TOTAL == 0 ? 1 : (TOTAL + BATCH_SIZE - 1) / BATCH_SIZE ))

# 「python3 invoice_ledger.py ...」（絶対パス省略の短い書き方）でAIが実行しても許可リストに一致するよう、
# 絶対パス・ファイル名のみの両方のパターンを許可しておく（2026-09-01：絶対パスのみだと夜間実行で毎回承認待ちになる不具合の対策）
ALLOWED_TOOLS="Read,Write,Edit,Bash(python3 ${LEDGER_SCRIPT}:*),Bash(python3 invoice_ledger.py:*),Bash(python3 ./invoice_ledger.py:*),mcp__mail-secretary__notify_slack,mcp__mail-secretary__list_slack_replies"

echo "=== 開始: $(date) （対象${TOTAL}件を${BATCH_SIZE}件ずつ${BATCH_COUNT}グループに分けて処理） ===" > "$LOG_FILE"

OVERALL_EXIT=0
BATCH_NUM=0
i=1
while [ "$BATCH_NUM" -lt "$BATCH_COUNT" ] || [ "$i" -le "$TOTAL" ]; do
  BATCH_NUM=$((BATCH_NUM + 1))
  END=$((i + BATCH_SIZE - 1))
  [ "$END" -gt "$TOTAL" ] && END=$TOTAL

  BATCH=()
  if [ "$TOTAL" -gt 0 ]; then
    for ((j = i; j <= END; j++)); do
      BATCH+=("${TARGET_FILES[$j]}")
    done
  fi

  if [ "$TOTAL" -gt 0 ]; then
    FILE_LIST=$(printf '%s\n' "${BATCH[@]}")
    STEP1_INTRO="以下の画像ファイルだけを対象に処理してください（フォルダ全体を探索する必要はありません）：

${FILE_LIST}"
  else
    STEP1_INTRO="今回、新規の対象ファイルはありません。この手順は何もせず手順5に進んでください。"
  fi

  if [ "$BATCH_NUM" -eq 1 ]; then
    STEP0_TEXT="まず、mcp__mail-secretary__list_slack_repliesをchannel=\"C0BRBFZ2N6R\"で呼び出し、前回のSlack報告以降に届いた返信を確認する。
返信が無ければ、この手順は何もせず手順1に進む。
返信があれば1件ずつ内容を確認する（単なる相槌・お礼など対応不要なものは無視してよい）：
- 「◯◯店の△△の写真、もう一度読んで」のような再確認の指示：該当する画像ファイルを${PHOTOS_ROOT}配下から探してReadで読み直し、内容に自信が持てればpython3 ${LEDGER_SCRIPT} addで記帳する（まだ記帳されていない＝held_for_reviewだった画像が対象）。状態ファイルの該当エントリのstatusも\"auto_saved\"に更新する。
- 「8/15の空港店、金額は3,200円が正しい」のような、既に記帳済みの内容への修正指示：python3 ${LEDGER_SCRIPT} edit '{\"match\":{...},\"set\":{...}}' で直す。matchには返信文から読み取れる範囲の情報（date/store/supplierの組み合わせ）を指定する。結果のJSONにerrorが含まれていたら（該当0件・複数件など）、絶対に当て推量で決めず、notify_slack（channel引数は必ず\"C0BRBFZ2N6R\"）で候補を示して確認を求める。
- 上記のどちらにも当てはまらない、対応方法が分からない指示：無理に何かをせず、notify_slackで『この内容は自動では対応できないため、Excel台帳を直接確認・修正してください』のように伝える。
返信に対して何かしら行動した場合、または対応できず確認を求めた場合は、その内容をnotify_slack（channel引数は必ず\"C0BRBFZ2N6R\"）で簡潔に報告する。単なる相槌で何もしなかった場合は通知しない。"
  else
    STEP0_TEXT="このグループでは手順0は実行しません（1グループ目で対応済みのため）。そのまま手順1に進んでください。"
  fi

  if [ "$BATCH_NUM" -eq "$BATCH_COUNT" ]; then
    STEP5_TEXT="これが最終グループです。今回のバッチ実行全体（今回の起動時刻 ${RUN_STARTED_AT} 以降に処理した分すべて。前のグループで処理した分も含む）をまとめて対象に、1回だけSlack報告してください。
不明フォルダ（${PHOTOS_ROOT}/不明）には現在${UNKNOWN_COUNT}件の画像があります。
今回処理した画像が1件以上、または不明フォルダに1件以上あれば、mcp__mail-secretary__notify_slackで1通だけ報告する（channel引数には必ず \"C0BRBFZ2N6R\"＝#納品書通知 を指定すること）。
見出しは『【納品書OCR】』とする。
自動記帳した分：店舗・日付・仕入先・金額を一覧で。
要確認になった分：店舗・ファイル名・読み取れた範囲の内容（分かる範囲でよい）・保留理由を一覧で、『OneDriveの元写真を確認のうえ、Excel台帳（納品書写真と同じOneDrive内、「納品書集計/納品書集計.xlsx」）に直接1行追記してください』と添える。
不明フォルダに画像がある場合：件数を伝え、『店舗が自動判定できませんでした。OneDriveの「納品書写真/不明」フォルダを開いて、正しい店舗フォルダへ手動で移動するか、Excel台帳に直接記帳してください』と添える。
返信は不要な旨（『返信不要です。読み取りが違う場合だけ教えてください』程度）を添える。
今回処理した画像が0件、かつ不明フォルダも0件なら、手順5は何もしない（新規0件の日は通知しない）。"
  else
    STEP5_TEXT="このグループでは手順5は実行しません（最終グループでまとめて報告するため）。そのまま手順6に進んでください。"
  fi

  PROMPT="【実行環境について】
これは夜間バッチによる完全無人の自動実行です。あなたへの応答者は存在しません。
『実行してよいですか？』のような確認・質問は一切せず、判定が終わり次第そのまま実行してください（確認質問を出すと、誰も答えられないため処理がそこで停止してしまいます）。
これは全${BATCH_COUNT}グループ中の${BATCH_NUM}グループ目です。1グループの対象は少数（最大${BATCH_SIZE}件）に絞ってあります。

【目的】
ラーメン店7店舗が共有フォルダ（OneDrive）にアップロードした納品書の写真を読み取り、内容に自信がある分だけExcel台帳（${LEDGER_XLSX}）に自動記帳する。自信が持てない分は記帳せず、Slackで1通にまとめて報告する。報告を見た人が、OneDrive上の元写真を直接確認し、同じExcelファイルに手入力で追記する運用にする（専用の修正アプリは使わない）。

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

【手順0：Slack返信への対応】
${STEP0_TEXT}

【手順1：対象ファイルの読み取り】
${STEP1_INTRO}
各画像について、Readで直接開いて日本語の納品書として次を読み取る：
- date：納品日（YYYY-MM-DD形式。読めなければ空文字）
- supplier：仕入先の会社名（読めなければ空文字）
- total と taxType：税抜金額（税抜金額）が明記されていればそれをtotalとし、taxTypeを\"excluded\"とする。税込金額（税込金額）が明記されていればそれをtotalとし、taxTypeを\"included\"とする。\n  消費税欄に具体的な税額・税込金額の記載が無く、『軽減8%』『8%』『10%』のような税率表記だけ、または0円・空欄の場合は、記載されている金額（対象額・小計・合計など）をtotalとし、taxTypeを\"excluded\"として扱う（税抜金額として記帳する、という会社の運用ルール）。\n  上記のいずれにも当てはまらない場合（手書きで金額自体が判読できない等、金額そのものが読み取れない場合）のみtaxTypeを\"unknown\"とする。
- store：画像が入っていたフォルダ名をそのまま使う

【手順2：自動保存か要確認かの判定】
次のいずれかに該当する画像は\"held_for_review\"（要確認）とし、スプレッドシートには書き込まない：
- date または supplier が空文字
- total が0以下
- taxType が \"included\"（税込金額しか書かれておらず、税抜金額への変換を思い込みで決め打ちすると記帳ミスになるため）または \"unknown\"（金額自体が読み取れない場合）
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
成功したら状態ファイルにこの画像を status \"auto_saved\" として記録する（note は空欄、processedAt は現在時刻）。

【手順5：Slack報告】
${STEP5_TEXT}

【手順6：ログ】
最後に、今回このグループで何をしたか（新規検出件数／自動記帳件数／要確認件数とその内訳）を簡潔に報告してください。"

  # 1グループあたり20分で強制終了する保険をかける
  TIMEOUT_SECONDS=1200
  BATCH_START_EPOCH=$(date +%s)
  echo "--- グループ${BATCH_NUM}/${BATCH_COUNT}（${#BATCH[@]}件）開始: $(date) ---" >> "$LOG_FILE"
  "$CLAUDE_BIN" -p \
    --allowedTools "$ALLOWED_TOOLS" \
    --add-dir "$ONEDRIVE_ROOT" \
    --verbose \
    "$PROMPT" \
    >> "$LOG_FILE" 2>&1 &
  CLAUDE_PID=$!
  ( sleep "$TIMEOUT_SECONDS"
    if kill -0 "$CLAUDE_PID" 2>/dev/null; then
      kill -9 "$CLAUDE_PID" 2>/dev/null
      echo "タイムアウト: グループ${BATCH_NUM}が${TIMEOUT_SECONDS}秒経っても完了しなかったため強制終了しました ($(date))" >> "$LOG_FILE"
    fi
  ) &
  WATCHER_PID=$!
  wait "$CLAUDE_PID" 2>/dev/null
  CLAUDE_EXIT=$?
  kill "$WATCHER_PID" 2>/dev/null
  wait "$WATCHER_PID" 2>/dev/null
  BATCH_ELAPSED=$(( $(date +%s) - BATCH_START_EPOCH ))

  if [ "$CLAUDE_EXIT" -eq 0 ]; then
    echo "--- グループ${BATCH_NUM}/${BATCH_COUNT} 正常終了（所要${BATCH_ELAPSED}秒）: $(date) ---" >> "$LOG_FILE"
  else
    OVERALL_EXIT=1
    echo "--- 警告: グループ${BATCH_NUM}/${BATCH_COUNT} 異常終了（exit ${CLAUDE_EXIT}、所要${BATCH_ELAPSED}秒、タイムアウトの可能性）。このグループの未処理分は状態ファイルに記録されていないため次回また対象になります: $(date) ---" >> "$LOG_FILE"
  fi

  i=$((END + 1))
done

# ログイン切れ等で失敗していたら、Claudeを介さず直接Slackへ警告する
"$HOME/Claude/scripts/notify_claude_login_issue.sh" "納品書OCR" "$LOG_FILE" "$OVERALL_EXIT"

echo "done: $(date)" >> "$LOG_DIR/last_run_invoice_ocr.log"

# 古いログを30日で自動整理
find "$LOG_DIR" -name "invoice_ocr_*.log" -mtime +30 -delete
