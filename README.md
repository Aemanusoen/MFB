# MFB-PRO – ESP32 (BLE) + แอพ Flutter

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
