#!/usr/bin/env bash
# backup.sh — نسخ احتياطي للملفات وقواعد MySQL/MariaDB و SQLite، بضغط وتشفير اختياري،
# واحتفاظ يومي/أسبوعي/شهري، ونسخة خارج السيرفر، وتقرير على تيليجرام.
#
#   backup.sh [-c backup.conf]                 نسخة جديدة ثم تنظيف القديم
#   backup.sh [-c backup.conf] prune           تنظيف القديم فقط
#   backup.sh restore ARCHIVE DIR [-i KEY]     فك نسخة في مجلد للمراجعة (لا يلمس الموقع الحي)
set -uo pipefail
export LC_ALL=C
umask 077

CONF=/etc/server-backup/backup.conf
ARGS=()
while [ $# -gt 0 ]; do
  case $1 in
    -c) CONF=$2; shift 2 ;;
    -i) KEY=$2; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
CMD=${ARGS[0]:-backup}

# القيم الافتراضية — يغيّرها ملف الإعداد
NAME=$(hostname -s 2>/dev/null || echo server)
DEST=/var/backups/server-backup
DIRS=""
EXCLUDES=""
MYSQL_DATABASES=""      # أسماء مفصولة بمسافة، أو all
MYSQL_DEFAULTS=/root/.my.cnf
SQLITE_FILES=""
COMPRESS=zstd           # zstd أو gzip
ENCRYPT_TO=""           # مفتاح age العام (age1...). فارغ = بلا تشفير
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
REMOTE=""               # user@host:/path عبر rsync + ssh. فارغ = بلا نسخة خارجية
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""
TELEGRAM_API=https://api.telegram.org
if [ "$CMD" != restore ]; then
  [ -f "$CONF" ] || { echo "لا يوجد ملف إعداد: $CONF" >&2; exit 2; }
  # shellcheck source=/dev/null
  . "$CONF"
fi

STAMP=${BACKUP_DATE:-$(date +%Y-%m-%d_%H%M)}   # BACKUP_DATE للاختبارات فقط
T0=$(date +%s)
LOG=()
log() { LOG+=("$*"); echo "[$(date +%H:%M:%S)] $*"; }

if [ "$COMPRESS" = zstd ] && command -v zstd >/dev/null; then
  ZIP=(zstd -q -T0 -3); EXT=zst; UNZIP=(zstd -q -d -c)
else
  ZIP=(gzip -6); EXT=gz; UNZIP=(gzip -d -c)
fi

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }
tg() {
  [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || return 0
  curl -fsS -m 15 -o /dev/null "$TELEGRAM_API/bot$TELEGRAM_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$1" -d parse_mode=HTML || echo "تعذر إرسال التقرير إلى تيليجرام" >&2
}
fail() {
  log "✘ $*"
  tg "🔴 <b>فشل النسخ الاحتياطي — $NAME</b>
$*
$(printf '%s\n' "${LOG[@]: -5}")"
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  exit 1
}

# ---------- الاحتفاظ: آخر نسخة من كل يوم/أسبوع/شهر ----------
# الأسماء NAME-YYYY-MM-DD_HHMM.tar[.age] تُرتَّب أبجدياً كما تُرتَّب زمنياً
prune() {
  local f base d keep=() n_d=0 n_w=0 n_m=0 last_d="" last_w="" last_m="" deleted=0
  while read -r f; do
    base=${f##*/}
    d=${base#"$NAME"-}
    d=${d:0:10}
    local k=0
    if [ "$d" != "$last_d" ] && [ $n_d -lt "$KEEP_DAILY" ]; then k=1; n_d=$((n_d + 1)); fi
    local w m
    w=$(date -d "$d" +%G-%V)
    m=${d:0:7}
    if [ "$w" != "$last_w" ] && [ $n_w -lt "$KEEP_WEEKLY" ]; then k=1; n_w=$((n_w + 1)); fi
    if [ "$m" != "$last_m" ] && [ $n_m -lt "$KEEP_MONTHLY" ]; then k=1; n_m=$((n_m + 1)); fi
    # أحدث نسخة في كل يوم/أسبوع/شهر هي الأولى في الترتيب التنازلي، فنتذكر المفتاح بعدها
    [ "$d" != "$last_d" ] && last_d=$d
    [ "$w" != "$last_w" ] && last_w=$w
    [ "$m" != "$last_m" ] && last_m=$m
    if [ $k = 1 ]; then keep+=("$base"); else rm -f -- "$f" && deleted=$((deleted + 1)); fi
  done < <(find "$DEST" -maxdepth 1 -type f -name "$NAME-????-??-??_????.tar*" | sort -r)
  KEPT=${#keep[@]}
  log "الاحتفاظ: بقيت $KEPT نسخة، وحُذفت $deleted"
}

# ---------- الاستعادة: تفك النسخة في مجلد وتتحقق من بصماتها ----------
restore() {
  local archive=${ARGS[1]:-} out=${ARGS[2]:-}
  [ -f "$archive" ] && [ -n "$out" ] || { echo "الاستعمال: backup.sh restore ARCHIVE DIR [-i age-key.txt]" >&2; exit 2; }
  mkdir -p "$out" || exit 1
  if [[ $archive == *.age ]]; then
    [ -n "${KEY:-}" ] || { echo "النسخة مشفرة: أضف -i ملف المفتاح الخاص" >&2; exit 2; }
    age -d -i "$KEY" "$archive" | tar -x -C "$out"
    local st=("${PIPESTATUS[@]}")
    [ "${st[0]}" = 0 ] && [ "${st[1]}" = 0 ] || { echo "✘ فك التشفير فشل (مفتاح خاطئ أو ملف تالف)" >&2; exit 1; }
  else
    tar -x -C "$out" -f "$archive" || exit 1
  fi
  (cd "$out" && sha256sum -c --quiet SHA256SUMS) || { echo "✘ البصمات لا تطابق: النسخة تالفة" >&2; exit 1; }
  echo "✔ البصمات مطابقة"
  local p
  for p in "$out"/mysql/*.sql.* "$out"/sqlite/*.sqlite.*; do
    [ -f "$p" ] || continue
    case $p in *.zst) zstd -q -d --rm "$p" ;; *.gz) gzip -d "$p" ;; esac
  done
  if [ -f "$out/files.tar.zst" ] || [ -f "$out/files.tar.gz" ]; then
    mkdir -p "$out/files"
    if [ -f "$out/files.tar.zst" ]; then zstd -q -d -c "$out/files.tar.zst" | tar -x -C "$out/files"; else tar -xz -C "$out/files" -f "$out/files.tar.gz"; fi
    rm -f "$out"/files.tar.*
  fi
  echo "✔ فُكت في $out"
  [ -d "$out/files" ] && echo "  الملفات:   $out/files/"
  for p in "$out"/mysql/*.sql; do [ -f "$p" ] && echo "  قاعدة:     mysql -e 'CREATE DATABASE $(basename "$p" .sql)_restore' && mysql $(basename "$p" .sql)_restore < $p"; done
  for p in "$out"/sqlite/*.sqlite; do [ -f "$p" ] && echo "  SQLite:    $p"; done
  echo "راجع ما فُك قبل أن تنسخه فوق الموقع الحي."
}

case $CMD in
  restore) restore; exit $? ;;
  prune) mkdir -p "$DEST" && prune; exit 0 ;;
  backup) ;;
  *) echo "أمر غير معروف: $CMD" >&2; exit 2 ;;
esac

# ---------- النسخ ----------
mkdir -p "$DEST" || exit 1
exec 9>"$DEST/.lock"
flock -n 9 || { echo "نسخة أخرى تعمل الآن" >&2; exit 1; }
WORK=$(mktemp -d "$DEST/.work-XXXXXX")
trap '[ -n "${WORK:-}" ] && rm -rf "$WORK"' EXIT
log "بدأ النسخ: $NAME $STAMP"
PARTS=0

# قواعد MySQL/MariaDB: --single-transaction يأخذ لقطة متسقة لجداول InnoDB دون أن يقفل الموقع
if [ -n "$MYSQL_DATABASES" ]; then
  mkdir -p "$WORK/mysql"
  dbs=$MYSQL_DATABASES
  if [ "$dbs" = all ]; then
    dbs=$(mysql --defaults-extra-file="$MYSQL_DEFAULTS" -N -B -e 'SHOW DATABASES' | grep -Ev '^(information_schema|performance_schema|sys|mysql)$') || fail "تعذر سرد قواعد MySQL"
  fi
  for db in $dbs; do
    mysqldump --defaults-extra-file="$MYSQL_DEFAULTS" --single-transaction --quick --routines --triggers --events --hex-blob \
      --default-character-set=utf8mb4 "$db" | "${ZIP[@]}" >"$WORK/mysql/$db.sql.$EXT"
    st=("${PIPESTATUS[@]}")
    [ "${st[0]}" = 0 ] && [ "${st[1]}" = 0 ] || fail "mysqldump فشل في قاعدة $db"
    log "MySQL $db: $(human "$(stat -c %s "$WORK/mysql/$db.sql.$EXT")")"
    PARTS=$((PARTS + 1))
  done
fi

# SQLite: VACUUM INTO يأخذ لقطة متسقة في معاملة قراءة واحدة حتى والقاعدة تُكتب.
# cp ينسخ ملفاً نصف مكتوب، و .backup يعيد من البداية مع كل كتابة فلا ينتهي على قاعدة مشغولة
if [ -n "$SQLITE_FILES" ]; then
  mkdir -p "$WORK/sqlite"
  for f in $SQLITE_FILES; do
    [ -f "$f" ] || fail "ملف SQLite غير موجود: $f"
    out="$WORK/sqlite/$(basename "$f")"
    [ -e "$out" ] && out="$WORK/sqlite/$(echo "$f" | tr '/' '_')"
    sqlite3 "$f" ".timeout 30000" "VACUUM INTO '$out'" || fail "تعذر نسخ $f"
    [ "$(sqlite3 "$out" 'PRAGMA integrity_check')" = ok ] || fail "نسخة $f لم تجتز فحص السلامة"
    "${ZIP[@]}" --rm "$out" 2>/dev/null || { "${ZIP[@]}" <"$out" >"$out.$EXT" && rm -f "$out"; }
    log "SQLite $(basename "$f"): $(human "$(stat -c %s "$out.$EXT")")"
    PARTS=$((PARTS + 1))
  done
fi

# الملفات
if [ -n "$DIRS" ]; then
  ex=()
  for e in $EXCLUDES; do ex+=(--exclude="$e"); done
  # shellcheck disable=SC2086
  tar --create --file - --one-file-system --warning=no-file-changed "${ex[@]}" $DIRS 2>"$WORK/tar.err" | "${ZIP[@]}" >"$WORK/files.tar.$EXT"
  st=("${PIPESTATUS[@]}")
  # tar يرجع 1 إذا تغيّر ملف أثناء قراءته: نسخة صالحة مع تحذير. 2 فما فوق خطأ حقيقي
  [ "${st[0]}" -le 1 ] && [ "${st[1]}" = 0 ] || fail "tar فشل: $(grep -v 'Removing leading' "$WORK/tar.err" | head -3)"
  [ "${st[0]}" = 1 ] && log "تحذير: ملفات تغيّرت أثناء نسخها"
  log "الملفات: $(human "$(stat -c %s "$WORK/files.tar.$EXT")")"
  PARTS=$((PARTS + 1))
fi
rm -f "$WORK/tar.err"
[ $PARTS -gt 0 ] || fail "لا شيء للنسخ: حدّد DIRS أو MYSQL_DATABASES أو SQLITE_FILES"

# بصمات وفحص كل جزء مضغوط قبل الحزم
(
  cd "$WORK" || exit 1
  while IFS= read -r p; do "${UNZIP[@]}" "$p" >/dev/null || { echo "$p"; exit 1; }; done < <(find . -type f -name "*.$EXT")
  find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs -r sha256sum >SHA256SUMS
) || fail "جزء مضغوط تالف"
printf 'name=%s\ndate=%s\nhost=%s\n' "$NAME" "$STAMP" "$(hostname)" >"$WORK/info.txt"

# الحزم في ملف واحد، ثم التشفير بمفتاح age العام: السيرفر يشفّر ولا يستطيع فك التشفير
FINAL="$DEST/$NAME-$STAMP.tar"
[ -n "$ENCRYPT_TO" ] && FINAL+=.age
if [ -n "$ENCRYPT_TO" ]; then
  tar -C "$WORK" -c . | age -r "$ENCRYPT_TO" >"$FINAL.part"
  st=("${PIPESTATUS[@]}")
  [ "${st[0]}" = 0 ] && [ "${st[1]}" = 0 ] || { rm -f "$FINAL.part"; fail "التشفير فشل (هل ENCRYPT_TO مفتاح age عام صحيح؟)"; }
else
  tar -C "$WORK" -cf "$FINAL.part" . || { rm -f "$FINAL.part"; fail "الحزم فشل"; }
fi
mv "$FINAL.part" "$FINAL"
SIZE=$(stat -c %s "$FINAL")
log "النسخة: $(basename "$FINAL") ($(human "$SIZE"))"
rm -rf "$WORK"
WORK=""

# النسخة الخارجية: ملف النسخة الجديد فقط، بلا حذف هناك.
# السيرفر المخترَق لا يستطيع مسح نسخك القديمة؛ نظّفها على الطرف الآخر بـ backup.sh prune
if [ -n "$REMOTE" ]; then
  rsync -a --partial -e "ssh -o BatchMode=yes -o ConnectTimeout=20" "$FINAL" "$REMOTE/" || fail "رفع النسخة إلى $REMOTE فشل (النسخة المحلية سليمة)"
  log "رُفعت إلى $REMOTE"
fi

prune
FREE=$(df -P -k "$DEST" | awk 'NR == 2 { print $4 * 1024 }')
DUR=$(($(date +%s) - T0))
tg "✅ <b>نسخة احتياطية — $NAME</b>
$(printf '%s\n' "${LOG[@]:1}")
المدة: ${DUR} ث · المساحة الحرة: $(human "$FREE")"
exit 0
