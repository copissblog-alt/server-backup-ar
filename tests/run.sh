#!/usr/bin/env bash
# اختبارات backup.sh: نسخ واستعادة ومقارنة، تشفير، تلف، SQLite أثناء الكتابة، الاحتفاظ لسنة، الفشل والتقارير.
# التشغيل: bash tests/run.sh   (يحتاج sqlite3 و python3. اختبارات MySQL تعمل إن وُجد خادم يقبل: mysql -u root)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
B="$ROOT/backup.sh"
T=$(mktemp -d)
trap 'kill $TG 2>/dev/null; kill $W 2>/dev/null; rm -rf "$T"' EXIT
W=""
PASS=0 FAIL=0 SKIP=0
ok() { if [ "$2" = 0 ]; then PASS=$((PASS + 1)); echo "PASS $1"; else FAIL=$((FAIL + 1)); echo "FAIL $1 ${3:-}"; fi; }
is() { [ "$2" = "$3" ]; ok "$1" $? "(got '$2', want '$3')"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP $1"; }

PORT=$((20000 + RANDOM % 20000))
python3 "$ROOT/tests/fake_tg.py" $T/tg.log $PORT & TG=$!
touch $T/tg.log

mkdir -p $T/site/{img,cache,uploads}
echo "<?php echo 'مرحبا';" >$T/site/index.php
head -c 200000 /dev/urandom >$T/site/img/logo.png
echo tmp >$T/site/cache/page.html
echo "فاتورة" >"$T/site/uploads/ملف عربي.txt"
sqlite3 $T/app.sqlite "PRAGMA journal_mode=WAL; CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT); WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 5000) INSERT INTO t (v) SELECT hex(randomblob(50)) FROM c;" >/dev/null

MYSQL=0
if mysql -u root -e 'SELECT 1' >/dev/null 2>&1; then
  MYSQL=1
  printf '[client]\nuser=root\n' >$T/my.cnf
  mysql -u root -e "DROP DATABASE IF EXISTS bk_test; CREATE DATABASE bk_test CHARACTER SET utf8mb4; CREATE TABLE bk_test.orders (id INT PRIMARY KEY, name VARCHAR(50), total DECIMAL(10,2)) ENGINE=InnoDB; INSERT INTO bk_test.orders VALUES (1,'نورة',150.50),(2,'O''Brien',99.00);"
fi

conf() { # conf FILE [extra lines...]
  local f=$1; shift
  {
    echo "NAME=web-1"
    echo "DEST=$T/backups"
    echo "DIRS=\"$T/site\""
    echo "EXCLUDES=\"*/cache/*\""
    echo "SQLITE_FILES=\"$T/app.sqlite\""
    [ $MYSQL = 1 ] && echo "MYSQL_DATABASES=bk_test" && echo "MYSQL_DEFAULTS=$T/my.cnf"
    echo "TELEGRAM_TOKEN=T"
    echo "TELEGRAM_CHAT_ID=42"
    echo "TELEGRAM_API=http://127.0.0.1:$PORT"
    printf '%s\n' "$@"
  } >"$f"
}
sleep 0.4

# ===== نسخة عادية ثم استعادتها =====
conf $T/a.conf
BACKUP_DATE=2026-11-25_0300 bash $B -c $T/a.conf >$T/out 2>&1; ok "backup exits 0" $?
A=$T/backups/web-1-2026-11-25_0300.tar
[ -f $A ]; ok "one archive named NAME-DATE.tar" $?
is "archive readable only by its owner (600)" "$(stat -c %a $A)" "600"
cp $A $T/good.tar
ls $T/backups/.work-* >/dev/null 2>&1; ok "no temporary work dirs left" $(( ! $? ))
bash $B restore $A $T/r1 >$T/rout 2>&1; ok "restore exits 0" $?
grep -q "البصمات مطابقة" $T/rout; ok "restore verifies SHA256 of every part" $?
SITE_IN=$T/r1/files${T}/site
diff -r --exclude=cache $T/site $SITE_IN >/dev/null; ok "restored files identical (Arabic names included)" $?
[ -z "$(ls -A $SITE_IN/cache 2>/dev/null)" ]; ok "excluded cache files not in the backup" $?
is "restored SQLite passes integrity_check" "$(sqlite3 $T/r1/sqlite/app.sqlite 'PRAGMA integrity_check')" "ok"
is "restored SQLite has every row" "$(sqlite3 $T/r1/sqlite/app.sqlite 'SELECT COUNT(*) FROM t')" "5000"
grep -q "✅ <b>نسخة احتياطية — web-1</b>" $T/tg.log; ok "Telegram success report" $?
grep -q "الملفات: " $T/tg.log; ok "report lists the parts with sizes" $?
if [ $MYSQL = 1 ]; then
  mysql -u root -e "DROP DATABASE IF EXISTS bk_test_restore; CREATE DATABASE bk_test_restore CHARACTER SET utf8mb4" && mysql -u root bk_test_restore <$T/r1/mysql/bk_test.sql
  is "MySQL dump restores into a new database (Arabic text intact)" "$(mysql -u root -N -e 'SELECT GROUP_CONCAT(name ORDER BY id) FROM bk_test_restore.orders')" "نورة,O'Brien"
  mysql -u root -e "DROP DATABASE bk_test_restore"
else skip "MySQL restore (no server)"; fi

# ===== التشفير =====
if command -v age >/dev/null; then
  age-keygen -o $T/key.txt 2>$T/pub.txt
  conf $T/e.conf "ENCRYPT_TO=$(grep -o 'age1[a-z0-9]*' $T/pub.txt)"
  BACKUP_DATE=2026-11-25_0400 bash $B -c $T/e.conf >/dev/null 2>&1
  E=$T/backups/web-1-2026-11-25_0400.tar.age
  [ -f $E ]; ok "encrypted archive .tar.age" $?
  ! grep -aq "SQLite format 3" $E && ! grep -aq "مرحبا" $E; ok "no plaintext inside the encrypted file" $?
  bash $B restore $E $T/r2 -i $T/key.txt >/dev/null 2>&1; ok "restore with the private key" $?
  age-keygen -o $T/other.txt 2>/dev/null
  bash $B restore $E $T/r3 -i $T/other.txt >/dev/null 2>&1; ok "wrong key refused" $(( ! $? ))
  bash $B restore $E $T/r4 >/dev/null 2>&1; ok "encrypted restore without key refused" $(( ! $? ))
else skip "encryption (age not installed)"; fi

# ===== التلف =====
cp $T/good.tar $T/bad.tar
python3 - $T/bad.tar <<'PY'
import os, sys; f = open(sys.argv[1], 'r+b'); f.seek(os.path.getsize(sys.argv[1]) // 2); f.write(b'\x00' * 64); f.close()
PY
bash $B restore $T/bad.tar $T/r5 >$T/bout 2>&1; rc=$?
[ $rc != 0 ] && grep -q "البصمات لا تطابق" $T/bout; ok "a damaged archive is detected by its checksums" $?

is "several runs on one day: only the newest is kept" "$(ls $T/backups | grep -c '2026-11-25')" "1"

# ===== SQLite أثناء الكتابة المستمرة (وضع journal العادي، أصعب الحالات) =====
sqlite3 $T/busy.sqlite "PRAGMA journal_mode=DELETE; CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT); WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 30000) INSERT INTO t (v) SELECT hex(randomblob(100)) FROM c;" >/dev/null
python3 - $T/busy.sqlite <<'PY' & W=$!
import sqlite3, random, sys, time
c = sqlite3.connect(sys.argv[1], timeout=30, isolation_level=None)
while True:
    c.execute('BEGIN IMMEDIATE')
    for _ in range(1000):
        c.execute('UPDATE t SET v = hex(randomblob(100)) WHERE id = ?', (random.randint(1, 30000),))
    c.execute('COMMIT')
    time.sleep(0.02)
PY
sleep 0.5
conf $T/w.conf "SQLITE_FILES=$T/busy.sqlite" "DIRS=" "MYSQL_DATABASES="
okn=0
for i in 1 2 3; do
  BACKUP_DATE=2026-11-24_050$i bash $B -c $T/w.conf >/dev/null 2>&1 && okn=$((okn + 1))
done
kill $W; W=""
is "3 backups while the database is being written non-stop: all finish and pass integrity_check" "$okn" "3"

# ===== الاحتفاظ: نسختان يومياً لمدة 400 يوم =====
P=$T/prune; mkdir -p $P
for i in $(seq 0 399); do
  d=$(date -d "2026-11-25 -$i days" +%Y-%m-%d)
  touch "$P/web-1-${d}_0100.tar" "$P/web-1-${d}_1300.tar"
done
touch $P/other-2020-01-01_0100.tar
conf $T/p.conf "DEST=$P" "KEEP_DAILY=7" "KEEP_WEEKLY=4" "KEEP_MONTHLY=6"
bash $B -c $T/p.conf prune >/dev/null 2>&1
expected=$(python3 - <<'PY'
import datetime as dt
days = [dt.date(2026, 11, 25) - dt.timedelta(i) for i in range(400)]
keep, sd, sw, sm = set(), [], [], []
for d in days:  # أحدث أولاً؛ أحدث نسخة في اليوم هي 1300
    w, m = d.isocalendar()[:2], (d.year, d.month)
    k = False
    if d not in sd and len(sd) < 7: sd.append(d); k = True
    if w not in sw and len(sw) < 4: sw.append(w); k = True
    if m not in sm and len(sm) < 6: sm.append(m); k = True
    if k: keep.add(f"web-1-{d}_1300.tar")
print(len(keep), ' '.join(sorted(keep))[:60])
PY
)
got=$(ls $P | grep '^web-1' | sort)
is "400 days x2 -> kept set matches daily 7 / weekly 4 / monthly 6" "$(echo "$got" | wc -l) $(echo "$got" | tr '\n' ' ' | cut -c1-60)" "$expected"
[ -f $P/other-2020-01-01_0100.tar ]; ok "files of another NAME are never touched" $?
is "only the newest copy of each kept day survives" "$(ls $P | grep -c '_0100')" "1"

# ===== الفشل =====
: >$T/tg.log
conf $T/f.conf "SQLITE_FILES=$T/missing.sqlite"
BACKUP_DATE=2026-11-25_0600 bash $B -c $T/f.conf >/dev/null 2>&1; rc=$?
is "missing SQLite file -> exit 1" "$rc" "1"
[ ! -f $T/backups/web-1-2026-11-25_0600.tar ]; ok "no half archive left behind" $?
grep -q "🔴 <b>فشل النسخ الاحتياطي — web-1</b>" $T/tg.log && grep -q "missing.sqlite" $T/tg.log; ok "Telegram failure report says why" $?
if [ $MYSQL = 1 ]; then
  conf $T/m.conf "MYSQL_DATABASES=no_such_db"
  BACKUP_DATE=2026-11-25_0700 bash $B -c $T/m.conf >/dev/null 2>&1; rc=$?
  is "mysqldump error (unknown database) -> exit 1, not a silent empty dump" "$rc" "1"
else skip "mysqldump failure (no server)"; fi
bash $B -c $T/none.conf >/dev/null 2>&1; is "missing config -> exit 2" "$?" "2"

# ===== gzip بدل zstd، والنسخة الخارجية، والقفل =====
conf $T/g.conf "COMPRESS=gzip" "REMOTE=$T/offsite"
mkdir -p $T/offsite
BACKUP_DATE=2026-11-25_0800 bash $B -c $T/g.conf >/dev/null 2>&1; ok "gzip backup" $?
tar -tf $T/backups/web-1-2026-11-25_0800.tar | grep -q 'files.tar.gz'; ok "parts are .gz" $?
[ -f $T/offsite/web-1-2026-11-25_0800.tar ]; ok "copied to REMOTE" $?
bash $B restore $T/backups/web-1-2026-11-25_0800.tar $T/r6 >/dev/null 2>&1 && diff -r --exclude=cache $T/site $T/r6/files${T}/site >/dev/null; ok "gzip archive restores identical" $?
exec 8>$T/backups/.lock; flock 8
BACKUP_DATE=2026-11-25_0900 bash $B -c $T/a.conf >/dev/null 2>&1; is "second run while one is running -> refused" "$?" "1"
flock -u 8

[ $MYSQL = 1 ] && mysql -u root -e "DROP DATABASE bk_test"
echo
echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
