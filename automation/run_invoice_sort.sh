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
# 2026-09-14変更：OneDriveの「クラウドのみ（未ダウンロード）」状態の写真は、夜間はダウンロードが間に合わず
# mvが「Resource deadlock avoided」で失敗し、9/12に27枚すべてが移らず残っていた。
# 読み取り側（run_invoice_ocr.sh）と同じく、先に読み込んで実体化させてから移し、
# 待っても読めない写真は今回は移さず（元の場所に残るので）翌日また対象にする。
MIHON_FILES=("${(@0)$(find "$MIHON_INBOX_DIR" -mindepth 2 -maxdepth 2 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \) -print0 2>/dev/null)}")
MIHON_FILES=(${MIHON_FILES:#})
MIHON_NOT_READY=("${MIHON_FILES[@]}")
for wait_sec in 0 30 60; do
  [ ${#MIHON_NOT_READY[@]} -eq 0 ] && break
  [ "$wait_sec" -gt 0 ] && sleep "$wait_sec"
  STILL=()
  for f in "${MIHON_NOT_READY[@]}"; do
    cat "$f" > /dev/null 2>&1 || STILL+=("$f")
  done
  MIHON_NOT_READY=("${STILL[@]}")
done
for f in "${MIHON_FILES[@]}"; do
  if (( ${MIHON_NOT_READY[(Ie)$f]} )); then
    echo "見本の移動を見送り（OneDriveから取得できず、翌日また試す）: $f ($(date))" >> "$LOG_DIR/last_run_invoice_sort.log"
    continue
  fi
  supplier=$(basename "$(dirname "$f")")
  dest_dir="$PROJECT_DIR/見本/$supplier"
  mkdir -p "$dest_dir"
  dest="$dest_dir/$(basename "$f")"
  # 同名ファイルが既にあれば上書きせずタイムスタンプを付けて退避
  [ -e "$dest" ] && dest="$dest_dir/$(date +%Y%m%d%H%M%S)_$(basename "$f")"
  if mv "$f" "$dest" 2>> "$LOG_DIR/last_run_invoice_sort.log"; then
    echo "見本を移動: $f -> $dest ($(date))" >> "$LOG_DIR/last_run_invoice_sort.log"
  else
    echo "見本の移動に失敗（翌日また試す）: $f ($(date))" >> "$LOG_DIR/last_run_invoice_sort.log"
  fi
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

# 2026-09-12追加：OneDriveの「クラウドのみ（未ダウンロード）」状態の写真は、開いた瞬間に
# ダウンロードが始まるが、夜間は間に合わずEDEADLKエラーで読めないことがある。
# ここで先に読み込んで実体化させ、待っても読めない写真は今回の対象から外す
# （処理済みにもしないので翌日また自動で対象になる。要確認には回さない）。
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
  READY_FILES=()
  for f in "${TARGET_FILES[@]}"; do
    skip=0
    for n in "${NOT_READY[@]}"; do [ "$f" = "$n" ] && skip=1 && break; done
    [ "$skip" -eq 0 ] && READY_FILES+=("$f")
  done
  echo "警告: OneDriveから取得できず今回は見送った写真 ${#NOT_READY[@]}枚（処理済みにしないので次回また対象になります） ($(date))" >> "$LOG_FILE"
  printf '  見送り: %s\n' "${NOT_READY[@]}" >> "$LOG_FILE"
  TARGET_FILES=("${READY_FILES[@]}")
fi

if [ ${#TARGET_FILES[@]} -eq 0 ]; then
  echo "エラー: $(date) - 対象写真がすべてOneDriveから取得できませんでした（OneDriveアプリの再起動が必要な可能性があります）。ファイルは動かしていません" >> "$LOG_DIR/last_run_invoice_sort.log"
  exit 1
fi

FILE_LIST=$(printf '%s\n' "${TARGET_FILES[@]}")

MOVE_SCRIPT="$PROJECT_DIR/move_sorted.py"
SUPPLIER_MAP_FILE="$PROJECT_DIR/仕入先_店舗マップ.txt"
MIHON_DIR="$PROJECT_DIR/見本"
ALLOWED_TOOLS="Read,Bash(python3 ${MOVE_SCRIPT}:*)"

# 「!」始まりの行は「店舗を自動判定しない仕入先」なので、通常の対応表からは除いて別扱いにする
SUPPLIER_MAP_RULES=$(grep -v '^!' "$SUPPLIER_MAP_FILE" | grep -v '^>')
REBILL_RULES=$(grep '^>' "$SUPPLIER_MAP_FILE" | sed 's/^>//')

# 店舗ごとの住所・目印。住所8770を本店と決めつける誤りを防ぐ注意書きもここに入っている
STORE_ADDR_FILE="$PROJECT_DIR/店舗_住所マップ.txt"
if [ -f "$STORE_ADDR_FILE" ]; then
  STORE_ADDR_BLOCK="
【店舗ごとの住所・目印】
$(cat "$STORE_ADDR_FILE")
"
else
  STORE_ADDR_BLOCK=""
fi
if [ -n "$REBILL_RULES" ]; then
  REBILL_BLOCK="
【手順2の例外：届け先と仕入れの計上先が違う仕入先】
次の仕入先は、納品書の届け先に店舗名が書かれていても、仕入れとして計上する店舗が別になる。
届け先の記載よりこちらのルールを優先し、矢印の右側の店舗を使うこと。
${REBILL_RULES}
"
else
  REBILL_BLOCK=""
fi
NO_AUTO_STORE=$(grep '^!' "$SUPPLIER_MAP_FILE" | sed 's/^!//' | paste -sd '、' -)
if [ -n "$NO_AUTO_STORE" ]; then
  NO_AUTO_STORE_BLOCK="
【手順2の例外：店舗を自動判定しない仕入先】
次の仕入先は複数の店舗に納品があるため、届け先の店舗が具体的に明記されていない限り、
宛名が会社名だけ（『燕』『麺屋燕』『TUBAMEカンパニー』等）でも本店とみなしてはいけない。必ず『不明』にすること。
対象：${NO_AUTO_STORE}
"
else
  NO_AUTO_STORE_BLOCK=""
fi

# 2026-09-12追加：仕入先名の表記ゆれ（同じ会社が「株式会社マルフク」「マルフク」など
# 複数の名前で記録され、フォルダが分かれて重複判定の原因になっていた）を止めるため、
# Obsidianの名寄せ表を毎回読み込んでAIに渡す。
# 表を1つの正本にしてあるので、ユーザーがObsidianでこの.mdを編集すれば翌日から反映される。
SUPPLIER_NAME_DOC="$HOME/Claude/Obsidian/kyosuke-brain/AI/reference/仕入先の正式名称_対応表.md"
if [ -f "$SUPPLIER_NAME_DOC" ]; then
  SUPPLIER_NAMES_TEXT=$(python3 -c "
import re,sys
doc=open(sys.argv[1],encoding='utf-8').read()
out=[]
for name,al in re.findall(r'^\\|\\s*([^|\\s][^|]*?)\\s*\\|\\s*([^|]*?)\\s*\\|\\s*\$',doc,re.M):
    if name=='正式名称' or set(name)<=set('-― '):
        continue
    al=al.strip()
    if al and al!='－':
        out.append('・'+name+'（納品書に「'+al+'」と書かれていても '+name+' にする）')
    else:
        out.append('・'+name)
print(chr(10).join(out))
" "$SUPPLIER_NAME_DOC")
else
  SUPPLIER_NAMES_TEXT=""
  echo "警告: 仕入先の名寄せ表が見つかりません（$SUPPLIER_NAME_DOC）。仕入先名の統一なしで実行します: $(date)" >> "$LOG_DIR/last_run_invoice_sort.log"
fi

if [ -n "$SUPPLIER_NAMES_TEXT" ]; then
  SUPPLIER_NAMES_BLOCK="
【最重要：仕入先名は必ず下の正式名称リストに揃える】
読み取った社名がリストのどれかに該当する場合は、納品書上の表記（株式会社・有限会社の有無、旧字体、読み違えやすい字）がどうであっても、必ずリストの正式名称をそのまま使うこと。
${SUPPLIER_NAMES_TEXT}
リストのどれにも当てはまらない新しい仕入先だった場合は、読み取れたままの社名を使い、最後の報告に『リストに無い仕入先：<社名>』と明記すること。似ているだけの名前に勝手に寄せてはいけない。
"
else
  SUPPLIER_NAMES_BLOCK=""
fi
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
${MIHON_DIR}/<仕入先名>/<店舗名>/ に見本画像（過去に店舗が確定した納品書の手本）が置かれていることがある。
置かれていれば、その書式（ロゴ・レイアウト・得意先コードの位置と桁数）と見比べて、仕入先の判定に使ってよい。
さらに手順2の店舗判定でも、見本と同じ得意先コード・届け先住所が写っていれば、その見本のフォルダ名（店舗）を根拠として使ってよい（信頼度：高）。
見本が無い、またはフォルダが空の場合は無視してよい。
仕入先が全く読み取れない場合は『不明』として次の手順に進んでよい。
${SUPPLIER_NAMES_BLOCK}

【手順2：店舗の判定】
次の優先順位で判定する。
上から順に見ていき、当てはまったところで決める。前の番号で決まらなかったときだけ次へ進むこと。

1. 届け先として具体的な店舗名が書いてある（例：燕セントラルキッチン、麺屋燕 本店、富士山静岡空港店、紺屋町店）
   → その店舗にする（信頼度：高）
2. 届け先の住所や得意先コードが、下の【店舗ごとの住所・目印】または見本フォルダの写真と一致する
   → その店舗にする（信頼度：高）
3. 下の仕入先→店舗の対応関係に、その仕入先が載っている
   → その店舗にする（信頼度：低）
   ${SUPPLIER_MAP_RULES}
4. 届け先の記載が『燕』『麺屋燕』『TUBAMEカンパニー』のように会社全体を指すだけで、
   ここまでで決まらなかった場合 → 本店とみなす（信頼度：低）
5. 上記のいずれでも決められない場合は『不明』とする

※2026-09-12に順番を変更。以前は「会社名だけなら本店」が対応表より先にあったため、
　伝票に店舗名を書かない仕入先（クリチク等）が対応表に載っていても本店に入ってしまっていた。
${NO_AUTO_STORE_BLOCK}${REBILL_BLOCK}${STORE_ADDR_BLOCK}

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
最後に、何をどこに仕分けたか（元ファイル名→店舗→仕入先→年月→信頼度→保存ファイル名）を簡潔に一覧で報告してください。正式名称リストに無い仕入先があった場合は、一覧とは別に『リストに無い仕入先』としてまとめて書いてください。"

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

# 2026-09-12変更：以前は「claudeが正常終了したか」で処理済みを記録していたが、
# OneDrive障害で1枚も移動できていないのに正常終了した場合（2026-08-31に発生、72枚が
# 永久に仕分けされない状態になった）まで処理済みにしてしまっていた。
# 判断の根拠を「実際に受信箱から消えたか」だけに変える。受信箱に残っている写真は
# 処理済みにせず、次回また自動で対象になる。
MOVED_FILES=()
STAYED_FILES=()
for f in "${TARGET_FILES[@]}"; do
  if [ -e "$f" ]; then
    STAYED_FILES+=("$f")
  else
    MOVED_FILES+=("$f")
  fi
done

if [ ${#MOVED_FILES[@]} -gt 0 ]; then
  printf '%s\n' "${MOVED_FILES[@]}" >> "$PROCESSED_FILE"
fi

echo "実績: 仕分け済み ${#MOVED_FILES[@]}枚 / 受信箱に残った ${#STAYED_FILES[@]}枚（残った分は処理済みにせず次回また対象にします） ($(date))" >> "$LOG_FILE"
if [ ${#STAYED_FILES[@]} -gt 0 ]; then
  printf '  受信箱に残った: %s\n' "${STAYED_FILES[@]}" >> "$LOG_FILE"
fi

if [ "$CLAUDE_EXIT" -ne 0 ]; then
  echo "警告: claude呼び出しが異常終了（exit ${CLAUDE_EXIT}、タイムアウトの可能性） ($(date))" >> "$LOG_FILE"
fi

# ログイン切れ等で失敗していたら、Claudeを介さず直接Slackへ警告する
"$HOME/Claude/scripts/notify_claude_login_issue.sh" "納品書写真仕分け" "$LOG_FILE" "$CLAUDE_EXIT"

echo "done: $(date)" >> "$LOG_DIR/last_run_invoice_sort.log"

# 古いログを30日で自動整理
find "$LOG_DIR" -name "invoice_sort_*.log" -mtime +30 -delete
