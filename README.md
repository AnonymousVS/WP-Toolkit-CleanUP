# WP-Toolkit-CleanUP

ลบ plugin และ theme เริ่มต้นของ WordPress โดยอัตโนมัติ หลังติดตั้งผ่าน WP Toolkit บน cPanel/WHM

## สิ่งที่ script ทำ

- ลบ plugin: `akismet`, `hello`
- ลบ theme: `twentytwenty`, `twentytwentyone`, `twentytwentytwo`, `twentytwentythree`, `twentytwentyfour`
- เพิ่ม `CORE_UPGRADE_SKIP_NEW_BUNDLED true` ใน wp-config.php เพื่อกัน plugin/theme กลับมาตอนอัปเดต WordPress
- รันแบบ parallel 8 jobs เหมาะสำหรับ server ที่มีไซต์จำนวนมาก
- ข้ามไซต์ที่ทำไปแล้ว ไม่ทำซ้ำ
- รันอัตโนมัติทุกคืนเวลาตี 1 ผ่าน cron
- เก็บ log ไว้ 7 วัน แล้วลบอัตโนมัติ

## ติดตั้ง
```bash
curl -fsSL https://raw.githubusercontent.com/AnonymousVS/WP-Toolkit-CleanUP/main/wp-cleanup-auto.sh \
  -o /usr/local/sbin/wp-cleanup-auto.sh && bash /usr/local/sbin/wp-cleanup-auto.sh
```

## รันด้วยตัวเอง
```bash
bash /usr/local/sbin/wp-cleanup-auto.sh
```

## ดู Log
```bash
tail -f /var/log/wp-cleanup.log
```

## ความต้องการของระบบ

- cPanel/WHM
- WP-CLI
- Root access
