# سكربت نسخ احتياطي للسيرفر بالعربية (Bash)

سكربت واحد ينسخ ملفات موقعك وقواعد MySQL/MariaDB وملفات SQLite في ملف واحد كل ليلة: يضغطه، ويشفّره إن أردت، ويحتفظ بنسخ يومية وأسبوعية وشهرية، ويرفع نسخة خارج السيرفر، ويرسل لك تقريراً على تيليجرام. ومعه أمر استعادة يتحقق من سلامة كل جزء.

بلا برامج غريبة: `bash` و`tar` و`zstd` (أو `gzip`)، و`mysqldump` و`sqlite3` إن كانت عندك قواعد، و`age` للتشفير.

شرح المشروع كاملاً، والتجارب التي أجريناها عليه: **https://qeeid.com/server-backup-script-bash-source-code/**

## ما يفعله

- **MySQL / MariaDB**: `mysqldump --single-transaction` لقطة متسقة لكل قاعدة دون أن يقفل الموقع، وكلمة المرور من ملف لا من سطر الأوامر
- **SQLite**: `VACUUM INTO` (لقطة متسقة حتى والقاعدة تُكتب، لا `cp` ولا `.backup`)، ثم `PRAGMA integrity_check` على النسخة قبل قبولها
- **الملفات**: `tar` مع استثناءات (الكاش، `node_modules`...)، ولا يعبر إلى أقراص أخرى
- **الضغط**: zstd (أسرع وأصغر من gzip غالباً)، أو gzip إن لم يوجد
- **التحقق**: كل جزء مضغوط يُفك تجريبياً، وبصمة SHA-256 لكل جزء داخل النسخة
- **التشفير** (اختياري): بمفتاح age **العام**؛ المفتاح الخاص لا يكون على السيرفر أصلاً، فمن يخترق السيرفر لا يقرأ نسخك
- **الاحتفاظ**: أحدث نسخة من كل يوم لآخر 7 أيام، ومن كل أسبوع لآخر 4 أسابيع، ومن كل شهر لآخر 6 أشهر (قابلة للتغيير): 14 نسخة تغطي نحو 5 أشهر
- **نسخة خارجية**: يرفع الملف الجديد بـ rsync عبر ssh، **ولا يحذف شيئاً هناك**؛ فالسيرفر المخترَق لا يستطيع مسح نسخك القديمة
- **تقرير تيليجرام** بأحجام الأجزاء والمدة والمساحة الحرة، وتقرير فشل يقول السبب
- **قفل**: لا تعمل نسختان معاً

## التثبيت

```bash
sudo mkdir -p /opt/server-backup /etc/server-backup
sudo cp backup.sh /opt/server-backup/ && sudo chmod 700 /opt/server-backup/backup.sh
sudo cp backup.conf.example /etc/server-backup/backup.conf && sudo chmod 600 /etc/server-backup/backup.conf
sudo nano /etc/server-backup/backup.conf
```

بيانات MySQL في ملف خاص بصلاحية 600 (`/root/.my.cnf`):

```ini
[client]
user=backup
password=كلمة-مرور-قوية
```

ومستخدم بأقل صلاحيات تكفي للنسخ:

```sql
CREATE USER 'backup'@'localhost' IDENTIFIED BY 'كلمة-مرور-قوية';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, PROCESS ON *.* TO 'backup'@'localhost';
```

للتشفير: أنشئ المفتاح **على جهازك لا على السيرفر**، وضع العام فقط في الإعداد:

```bash
age-keygen -o backup-key.txt     # احفظه في مكان آمن خارج السيرفر
grep public backup-key.txt       # age1... ← ENCRYPT_TO في backup.conf
```

جرّبه مرة يدوياً، ثم أضفه إلى cron (الساعة 3:17 فجراً كل يوم):

```bash
sudo /opt/server-backup/backup.sh
echo '17 3 * * * root /opt/server-backup/backup.sh >/var/log/server-backup.log 2>&1' | sudo tee /etc/cron.d/server-backup
```

## الاستعادة

```bash
backup.sh restore /var/backups/server-backup/web-1-2026-11-25_0317.tar.age /tmp/restore -i backup-key.txt
```

يفك النسخة في مجلد منفصل، ويتحقق من بصمة كل جزء، ويطبع لك أوامر استيراد القواعد في قاعدة جديدة. لا يلمس موقعك الحي: راجع ما فُك ثم انسخه بنفسك.

**جرّب الاستعادة مرة كل شهر.** النسخة التي لم تُجرَّب استعادتها ليست نسخة.

## الاختبارات

```bash
bash tests/run.sh
```

34 اختباراً: نسخة كاملة واستعادتها ومقارنة كل ملف (بأسماء عربية)، وقاعدة MySQL بنص عربي تُستعاد في قاعدة جديدة، والتشفير والمفتاح الخاطئ، واكتشاف نسخة تالفة ببصماتها، ونسخ SQLite وهي تُكتب، والاحتفاظ على مدى 400 يوم مقارنة بحساب مستقل، والفشل (ملف مفقود، قاعدة غير موجودة) وتقريره، وgzip، والنسخة الخارجية، والقفل. اختبارات MySQL تعمل إن وُجد خادم محلي.

## الترخيص

MIT

---

**Arabic server backup script** — files + MySQL/MariaDB (`--single-transaction`) + SQLite (`VACUUM INTO` + integrity check), zstd, per-part SHA-256, optional age public-key encryption, GFS retention (daily/weekly/monthly), push-only offsite copy via rsync, Telegram reports, verified restore. Bash. MIT.
