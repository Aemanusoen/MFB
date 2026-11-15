# MFB-PRO – ESP32 (BLE) + แอพ Flutter

## แอพ 1.2.1 (คู่กับเกจ FW 1.0.14)

- SETTING: CONNECT ตัด SPEED SOURCE (สลับ GPS/ECU ได้โดยแตะเลขความเร็วกลางเกจ) · ALERT มีภาษาไทยต่อท้าย · LOGO หัวข้อ "เปลี่ยนโลโก้เกจ"
- หน้า GAUGE / GRID: ชื่ออังกฤษในช่องค่าใหญ่ขึ้น · ทุกช่องมี BAR (อุณหภูมิ เขียว→ส้ม→แดง ตามค่าที่ตั้งเตือน)
- หน้า GRAPH: ช่องค่ามีภาษาไทย · AFR LOG: 11.5 หนา · 14.7 · 16.5 บาง
- TUNE: เปิด BIN หรือ XDF จากภายนอกอย่างใดอย่างหนึ่ง → ปุ่มเปลี่ยนเป็น "เลือก XDF/BIN จากแอป" (โหลดเฉพาะอีกไฟล์)
- TUNE: หน้าต่างเลือกไฟล์ในแอปย่อให้เห็นหลายไฟล์ + ปุ่มเรียง รุ่นรถ / ขนาด มาก-น้อย ↔ น้อย-มาก
- TUNE: บันทึกเข้าคลังเก็บ XDF คู่กัน (เปิดจากคลังได้ทั้ง BIN + XDF) · ชื่อไฟล์_1 / _2 / _3 ไม่มีวันที่
- TUNE แผงปรับค่า: ใส่ค่าอิสระ (ไม่ใส่ = ป๊อปอัพเตือนกลางจอ) · − + % = ใช้ค่าที่ใส่ · X / Y / XY = ความแรง (1 = 100%) เลือกแถว/คอลัมน์เดียวได้ · ~ = ความแรง 0.01–0.10 · ปรับได้ถึงค่าสุดของข้อมูล (เตือนเมื่อชนขอบ)
- TUNE 3D: 2 นิ้ว บีบ/กาง = ซูม, ลากพร้อมกัน = เลื่อนกราฟ · FIT = กลับตำแหน่งเดิม

## แอพ 1.2.0 (คู่กับเกจ FW 1.0.14)
- เปิดแอพ -> หน้าแรกเลือกเมนู GAUGE / TUNE / FLASH (ฟันเฟืองมุมขวาบน = SETTING) ทุกหน้ามีปุ่มย้อนกลับ
- SETTING แบ่งเมนูย่อย: CONNECT (เชื่อมต่อ/ค้นหาเกจ, GPS) · ECU INFO · THEME · ALERT · LOGO · FIRMWARE
- หน้า GAUGE: ช่องค่าซ้าย 3 ขวา 3 (ภาษาไทยต่อท้ายชื่อ) กว้างเกือบชิดเกจ, เกจใหญ่ขึ้น, ป้าย GPS บอกจำนวนดาวเทียม (ใช้อยู่/ทั้งหมด)
- หน้า DTC (ปัดหน้าที่ 6): อ่าน/ลบโค้ดผ่านเกจ (Honda) — ต้องใช้เกจ FW 1.0.14

## 1) Firmware (ESP32 CYD)
1. Library Manager -> ติดตั้ง **NimBLE-Arduino 1.4.x**
2. คัดลอก `firmware/BleGauge.h` ไปไว้ในโฟลเดอร์ `Test1`
3. แก้ `Test1.ino` 2 จุด
   - ก่อนบรรทัด `#include "UI.h"` เพิ่ม `#include "BleGauge.h"`
   - ใน `setup()` ต่อจาก `ui_init();` เพิ่ม `bleStart();`
4. ถ้า RAM/Flash ไม่พอ เลือก Partition Scheme = "Huge APP" หรือ "No OTA (2MB APP)"

## 2) แอพ Flutter
```
flutter create mfb_pro
# แทนที่ pubspec.yaml และ lib/main.dart ด้วยไฟล์ในโฟลเดอร์ app/
flutter pub get
flutter run            # หรือ flutter build apk --release
```
### Android: android/app/src/main/AndroidManifest.xml (ใส่ใน <manifest>)
```
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
```
และตั้ง `minSdkVersion 21` (ใน android/app/build.gradle)

### iOS: ios/Runner/Info.plist
NSBluetoothAlwaysUsageDescription, NSLocationWhenInUseUsageDescription

## ใช้งาน
เปิดเกจ -> เปิดแอพ -> กด "เชื่อมต่อ" (หา MFB-PRO เอง และต่อใหม่อัตโนมัติถ้าหลุด)
ความเร็วใช้จาก ECU ถ้ามี (Lead/Giorno/PCX) ไม่มีจะใช้ GPS (Wave)
กด DEMO เพื่อทดสอบหน้าจอโดยไม่ต้องต่อบอร์ด · แตะช่อง TOP SPEED เพื่อ RESET

## โปรโตคอล
ดูหัวไฟล์ BleGauge.h (แพ็กเก็ต 34 ไบต์ little-endian ทุก 80 ms; คำสั่งเขียน: [1] = ลบ DTC, [2, รุ่น] = เปลี่ยนรุ่น)

## Build APK บน GitHub (ไม่ต้องลง Flutter)
1. สร้าง repo ใหม่บน GitHub แล้วอัปโหลดไฟล์ทั้งหมดในโฟลเดอร์นี้ (รวมโฟลเดอร์ `.github`)
2. เข้าแท็บ **Actions** -> workflow "Build Android APK" (รันเองอัตโนมัติเมื่อ push หรือกด Run workflow)
3. รอ ~5 นาที เปิดรอบที่รันเสร็จ -> หัวข้อ **Artifacts** -> ดาวน์โหลด `MFB-PRO-apk` (ได้ app-release.apk)
4. ส่งไฟล์เข้ามือถือ Android แล้วติดตั้ง (ต้องอนุญาต "ติดตั้งจากแหล่งที่ไม่รู้จัก")
