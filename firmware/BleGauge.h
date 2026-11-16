/*
 * BleGauge.h  -  ส่งค่า car.* ไปแอพมือถือผ่าน BLE (NimBLE-Arduino 1.4.x)
 *
 * ติดตั้ง: Library Manager -> "NimBLE-Arduino" (เวอร์ชัน 1.4.x)
 * ใช้งาน : 1) วางไฟล์นี้ในโฟลเดอร์ Test1
 *          2) ใน Test1.ino ใส่ #include "BleGauge.h" ก่อนบรรทัด #include "UI.h"
 *          3) ใน setup() เพิ่ม bleStart();  (ต่อจาก ui_init())
 *
 * Service  : 7a0f0001-5a41-5201-9c11-2a52a1c0de01
 *  - DATA  (notify) 7a0f0002-...  : แพ็กเก็ต 34 ไบต์ ทุก BLE_PERIOD_MS
 *  - CMD   (write)  7a0f0003-...  : [cmd][arg]   cmd 1 = ลบ DTC, cmd 2 = เปลี่ยนรุ่นรถ (arg = BM_*), cmd 3 = ความเร็ว GPS [u16 km/h x10]
 *  - IMG   (write)  7a0f0004-...  : ส่งโลโก้เปิดเครื่อง 320x240 RGB565 (153600 ไบต์) เก็บใน LittleFS (/logo.raw)
 *        [1][u32 size]  เริ่ม | [2][data...] ข้อมูล | [3][u16 sum] จบ (sum = ผลรวมไบต์ทั้งหมด mod 65536) | [4] ลบโลโก้ (กลับไปใช้ภาพเดิมในโค้ด)
 *        สถานะส่งกลับในแพ็กเก็ต DATA ไบต์ที่ 5: 0 ว่าง, 1 กำลังรับ, 2 สำเร็จ, 3 ผิดพลาด
 *        FW 1.0.9 ไฟล์ BIN สำหรับแฟลช ECU (รับได้เฉพาะตอนเกจเปิดหน้าเตรียมแฟลช) เก็บที่ /ecu.bin
 *        [0x21][u32 size][ชื่อไฟล์ ASCII สูงสุด 32] เริ่ม | [0x22][data...] | [0x23][u16 sum] จบ  (สถานะดูในส่วนแฟลชของแพ็กเก็ต DATA)
 *  - CMD เพิ่ม: [0x12] = ล้างผลแฟลชครั้งก่อน (DONE/FAIL -> READY)
 *    FW 1.0.14: cmd 4 = DTC ของแอพ: [4][0] หยุดอ่าน, [4][1] เปิดอ่านต่อเนื่อง, [4][2] อ่านใหม่ทันที | cmd 1 ลบ DTC ตอบสถานะในไบต์ 77
 *    FW 1.0.10: ยกเลิกคำสั่งเริ่มแฟลชจากแอพ (0x10) -> เริ่มแฟลชด้วยปุ่ม FLASH บนเกจเท่านั้น
 *    FW 1.0.13: offset จากแอปถูกเก็บลง /ecu.ofs คู่กับไฟล์ (พร้อม ID กล่องตอนส่ง) ; BLE หลุดกลางการส่ง = ยกเลิกการรับอัตโนมัติ
 *    FW 1.0.12: 0x21 รองรับ offset override จากแอป -> [0x21][u32 size][0x00][u32 startOff][u32 ckOff][ชื่อ] (เลือกตาม ID กล่อง); ไม่มี marker = เลือกตามขนาดไฟล์เหมือนเดิม
 *
 * แพ็กเก็ต DATA (little-endian):
 *   0 u8 version(=1)   1 u8 state   2 u8 proto   3 u8 flags (bit0 = ข้อมูลสด)
 *   4 u8 bikeModel     5 u8 imgState
 *   6.. int16 x 14  : rpm, speed*10, ect*10, iat*10, eot*10, tps*10, map*10,
 *                     batt*100, afr*100, ign*10, inj*100, o2v*1000, stft*1000, ltft*1000
 *   ltft*1000 อยู่ที่ offset 32 (แอพรุ่นเก่าอ่านแค่ 34 ไบต์แรก)
 *   ส่วนแฟลช ECU (FW 1.0.9) :
 *   34 u8 ver(=1)  35 u8 อยู่หน้าเตรียมแฟลช  36 u8 phase (FP_*)  37 u8 สถานะ ECU (ES_*)  38 u8 error (FE_*)  39 u8 % รวม
 *   40 u32 ขนาดไฟล์ในเกจ (0 = ไม่มี)  44 u16 sum16 ของไฟล์  46 u8 sum8 ของไฟล์ (ต้อง 0)  47 u8 แบต x10 (0 = ไม่รู้)
 *   48 u32 ไบต์ที่เขียนแล้ว  52 u32 ไบต์ทั้งหมด  56 u16 เวลาที่ใช้ (s)  58 u16 เวลาที่เหลือโดยประมาณ (s)
 *   60 u8[5] ECM ID  65 u8 มี ECM ID  66 u32 ไบต์ที่รับไฟล์แล้ว
 *   70 u8 FLASHCOUNT จากกล่อง (0xFF = ยังอ่านไม่ได้)  71 u8 ค่าก่อนกด FLASH (0xFF = ไม่มี)
 *   72 u8 FW major  73 u8 FW minor  74 u8 FW patch (เวอร์ชันเฟิร์มแวร์เกจ)  -> รวม 75 ไบต์ (FW 1.0.13)
 *   FW 1.0.14 ต่อท้าย (แอพรุ่นเก่าอ่านแค่ 75 ไบต์แรก):
 *   DTC   75 u8 ver(=1)  76 u8 flags (bit0 = ผลอ่านใช้ได้, bit1 = กำลังอ่านให้แอพ)  77 u8 clearState (0 ว่าง 1 กำลังลบ 2 สำเร็จ 3 ไม่สำเร็จ)
 *         78 u8 nCur  79 u8 nSto  80..111 คู่ [code][sub] สูงสุด 16 คู่ (nCur คู่แรก = ปัจจุบัน ต่อด้วยในอดีต)
 *   INFO  112 u8 ver(=1)  113 u8 มี ECU ID  114..118 ECU ID 5 ไบต์  119 ตาราง A  120 ตาราง B  121 ตาราง S
 *         122 u16 อัตราข้อมูล Hz x10  124 u16 เวลาเชื่อมต่อ ECU (s, 0 = ไม่ได้ต่อ)  126 u8 อายุข้อมูลล่าสุด x100 ms (255 = เกิน)
 *         127 u8 OBD2 header (0 ISO9141, 1 KWP)  -> รวม 128 ไบต์
 *   ค่า NaN / ไม่มีข้อมูล = 0x7FFF
 */
#pragma once
#include <NimBLEDevice.h>
#include <LittleFS.h>

#define FW_VER_MAJ     1        // เวอร์ชันเฟิร์มแวร์ (ส่งให้แอพแสดงในหน้า SETTING, ไบต์ 72..74 ของแพ็กเก็ต DATA)
#define FW_VER_MIN     0
#define FW_VER_PATCH   20
#define BLE_NAME       "MFB-PRO"
// ชื่อ BLE ไม่ซ้ำกันระหว่างเกจ: "MFB-PRO-" + 2 ไบต์ท้ายของ MAC ชิป (ไม่ต้องตั้งเอง ไม่หายตอนแฟลช FW)
static char bleNameBuf[20] = "";
static const char *bleDevName() {
  if (!bleNameBuf[0]) {
    uint64_t m = ESP.getEfuseMac();
    snprintf(bleNameBuf, sizeof bleNameBuf, "%s-%02X%02X", BLE_NAME, (unsigned)((m >> 32) & 0xFF), (unsigned)((m >> 40) & 0xFF));
  }
  return bleNameBuf;
}
#define BLE_PERIOD_MS  80
#define BLE_PKT_LEN    128  // FW 1.0.14: 75 เดิม + DTC (75..111) + ECU INFO (112..127) | MTU 185 พอ
#define BLE_NAN        0x7FFF

#define BLE_SVC_UUID   "7a0f0001-5a41-5201-9c11-2a52a1c0de01"
#define BLE_DATA_UUID  "7a0f0002-5a41-5201-9c11-2a52a1c0de01"
#define BLE_CMD_UUID   "7a0f0003-5a41-5201-9c11-2a52a1c0de01"
#define BLE_IMG_UUID   "7a0f0004-5a41-5201-9c11-2a52a1c0de01"

#define LOGO_W      320
#define LOGO_H      240
#define LOGO_BYTES  (LOGO_W * LOGO_H * 2)

static NimBLEServer*         bleServer = nullptr;
static NimBLECharacteristic* bleData   = nullptr;
static volatile bool         bleConnected = false;
static bool                  appOn = true;        // เปิด/ปิดการเชื่อมต่อแอพมือถือ (เก็บใน NVS โดย UI.h)
static bool                  bleStarted = false;
// ความเร็ว GPS ที่แอพมือถือส่งมา (km/h) - ถ้าเก่าเกิน 3 วินาทีถือว่าไม่มีสัญญาณ (NAN)
static volatile float        gpsKmh = NAN;
static volatile uint32_t     gpsMs  = 0;
static inline float gpsVal() { uint32_t m = gpsMs; if (!m || (millis() - m) > 3000) return NAN; return gpsKmh; }
static volatile uint8_t      imgState = 0;

// ---------- โลโก้เปิดเครื่องที่ส่งมาจากแอพ ----------
// ใช้ใน UI.h ตอนวาด splash: ถ้ามีไฟล์ใช้ภาพนี้ ถ้าไม่มีใช้ splash_img เดิม
static bool logoOpen(File &f) {
  if (!LittleFS.begin(true)) return false;
  if (!LittleFS.exists("/logo.raw")) return false;
  f = LittleFS.open("/logo.raw", "r");
  if (!f) return false;
  if ((size_t)f.size() != (size_t)LOGO_BYTES) { f.close(); return false; }
  return true;
}

struct ImgMsg { uint8_t type; uint8_t len; uint8_t d[244]; };   // FW 1.0.20: ชิ้นละสูงสุด 244 ไบต์ (MTU 247)
static QueueHandle_t imgQ = nullptr;

static void imgTask(void*) {
  ImgMsg m; File f; bool open = false;
  uint32_t expect = 0, got = 0; uint16_t sum = 0;
  File bf; bool bOpen = false; uint32_t bExpect = 0; uint16_t bSum = 0;   // ไฟล์ BIN สำหรับแฟลช ECU
  static char bName[33];
  bool bOver = false; uint32_t bOff = 0, bCk = 0;                        // offset จากแอพของไฟล์ที่กำลังรับ
  for (;;) {
    if (xQueueReceive(imgQ, &m, pdMS_TO_TICKS(1000)) != pdTRUE) {
      // ไม่มีข้อมูลเข้ามา 1 วินาที: ถ้า BLE หลุดกลางการส่ง ให้ยกเลิกการรับ (ไม่ค้างสถานะ RECEIVING)
      if (!bleConnected) {
        if (bOpen) { bf.close(); bOpen = false; LittleFS.remove(FL_TMP); fErr = FE_RECV; if (fPhase == FP_RECV) fPhase = FP_PREP; }
        if (open)  { f.close(); open = false; LittleFS.remove("/logo.tmp"); imgState = 3; }
      }
      continue;
    }
    switch (m.type) {
      case 0x21: {                                // BIN START [u32 size]
        if (bOpen) { bf.close(); bOpen = false; }
        if (!fPrepOn) { fErr = FE_NOPREP; break; }
        if (fBusy()) { fErr = FE_BUSY; break; }
        if (m.len < 4) { fErr = FE_RECV; break; }
        bExpect = (uint32_t)m.d[0] | ((uint32_t)m.d[1] << 8) | ((uint32_t)m.d[2] << 16) | ((uint32_t)m.d[3] << 24);
        if (bExpect == 0 || bExpect > FL_MAX_SIZE || !LittleFS.begin(true)) { fErr = FE_PARAM; break; }
        LittleFS.remove(FL_TMP);
        LittleFS.remove(FL_PATH);                 // แทนที่ไฟล์เดิม (ให้พื้นที่พอในพาร์ทิชันเล็ก)
        LittleFS.remove(FL_NAME);
        LittleFS.remove(FL_OFS);
        fFileOk = false; fFileSize = 0; fPlanOk = false;
        if (LittleFS.totalBytes() - LittleFS.usedBytes() < (size_t)bExpect + 8192) { fErr = FE_SPACE; fPhase = FP_PREP; break; }
        bf = LittleFS.open(FL_TMP, "w");
        if (!bf) { fErr = FE_RECV; fPhase = FP_PREP; break; }
        bOpen = true; bSum = 0; fRecv = 0; fRecvTotal = bExpect; fErr = FE_NONE; fPhase = FP_RECV;
        bOver = false; bOff = 0; bCk = 0;
        uint8_t ni = 4;                            // จุดเริ่มชื่อไฟล์
        if (m.len >= 13 && m.d[4] == 0x00) {       // marker 0x00 -> มี offset override: start u32 + checksum u32 (เลือกตาม ID กล่อง)
          bOff = (uint32_t)m.d[5] | ((uint32_t)m.d[6] << 8) | ((uint32_t)m.d[7] << 16) | ((uint32_t)m.d[8] << 24);
          bCk  = (uint32_t)m.d[9] | ((uint32_t)m.d[10] << 8) | ((uint32_t)m.d[11] << 16) | ((uint32_t)m.d[12] << 24);
          bOver = true; ni = 13;
        }
        { uint8_t nl = 0;                         // ชื่อไฟล์ (ตัวที่ไม่ใช่ ASCII พิมพ์ได้ -> '_')
          for (uint8_t i = ni; i < m.len && nl < sizeof bName - 1; i++) { char ch = (char)m.d[i]; bName[nl++] = (ch >= 0x20 && ch < 0x7F) ? ch : '_'; }
          bName[nl] = 0; }
        break;
      }
      case 0x22: {                                // BIN DATA
        if (!bOpen) break;
        if (fRecv + m.len > bExpect || bf.write(m.d, m.len) != m.len) { bf.close(); bOpen = false; LittleFS.remove(FL_TMP); fErr = FE_RECV; fPhase = FP_PREP; break; }
        for (uint8_t i = 0; i < m.len; i++) bSum += m.d[i];
        fRecv = fRecv + m.len;
        break;
      }
      case 0x23: {                                // BIN END [u16 sum]
        if (!bOpen) { fErr = FE_RECV; break; }
        bf.close(); bOpen = false;
        uint16_t want = (m.len >= 2) ? (uint16_t)(m.d[0] | (m.d[1] << 8)) : 0;
        if (fRecv == bExpect && want == bSum && LittleFS.rename(FL_TMP, FL_PATH)) {
          LittleFS.remove(FL_NAME);
          if (bName[0]) { File nf = LittleFS.open(FL_NAME, "w"); if (nf) { nf.write((const uint8_t *)bName, strlen(bName)); nf.close(); } }
          LittleFS.remove(FL_OFS);
          if (bOver) {                             // เก็บ offset จากแอพ + ID กล่องตอนส่ง คู่กับไฟล์ (อยู่ต่อหลังออกจากหน้า/รีบูต)
            uint8_t o[14];
            o[0] = (uint8_t)bOff; o[1] = (uint8_t)(bOff >> 8); o[2] = (uint8_t)(bOff >> 16); o[3] = (uint8_t)(bOff >> 24);
            o[4] = (uint8_t)bCk;  o[5] = (uint8_t)(bCk >> 8);  o[6] = (uint8_t)(bCk >> 16);  o[7] = (uint8_t)(bCk >> 24);
            for (int i = 0; i < 5; i++) o[8 + i] = fEcmId[i];
            o[13] = fEcmOk ? 1 : 0;
            File of = LittleFS.open(FL_OFS, "w"); if (of) { of.write(o, sizeof o); of.close(); }
          }
          fFileMeta();
          fPhase = fFileOk ? FP_READY : FP_PREP;
          if (!fFileOk) fErr = FE_RECV;
        } else {
          LittleFS.remove(FL_TMP);
          fErr = FE_RECV; fPhase = FP_PREP;
        }
        break;
      }
      case 1: {                                   // START [u32 size]
        if (open) { f.close(); open = false; }
        if (m.len < 4) { imgState = 3; break; }
        expect = (uint32_t)m.d[0] | ((uint32_t)m.d[1] << 8) | ((uint32_t)m.d[2] << 16) | ((uint32_t)m.d[3] << 24);
        if (expect != (uint32_t)LOGO_BYTES || !LittleFS.begin(true)) { imgState = 3; break; }
        LittleFS.remove("/logo.tmp");
        if (LittleFS.totalBytes() - LittleFS.usedBytes() < (size_t)LOGO_BYTES + 4096) LittleFS.remove("/logo.raw");   // พาร์ทิชันเล็ก (Minimal SPIFFS): พื้นที่ไม่พอเก็บ 2 ไฟล์ -> ลบโลโก้เก่าก่อน
        f = LittleFS.open("/logo.tmp", "w");
        if (!f) { imgState = 3; break; }
        open = true; got = 0; sum = 0; imgState = 1;
        break;
      }
      case 2: {                                   // DATA
        if (!open) break;
        if (got + m.len > expect || f.write(m.d, m.len) != m.len) { f.close(); open = false; imgState = 3; break; }
        for (uint8_t i = 0; i < m.len; i++) sum += m.d[i];
        got += m.len;
        break;
      }
      case 3: {                                   // END [u16 sum]
        if (!open) { imgState = 3; break; }
        f.close(); open = false;
        uint16_t want = (m.len >= 2) ? (uint16_t)(m.d[0] | (m.d[1] << 8)) : 0;
        if (got == expect && want == sum) {
          LittleFS.remove("/logo.raw");
          LittleFS.rename("/logo.tmp", "/logo.raw");
          imgState = 2;
        } else {
          LittleFS.remove("/logo.tmp");
          imgState = 3;
        }
        break;
      }
      case 4:                                     // DELETE -> กลับไปใช้โลโก้เดิม
        if (LittleFS.begin(true)) LittleFS.remove("/logo.raw");
        imgState = 2;
        break;
    }
  }
}

static inline int16_t bleScale(float v, float k) {
  if (isnan(v)) return BLE_NAN;
  float s = v * k;
  if (s > 32000.f) s = 32000.f;
  if (s < -32000.f) s = -32000.f;
  return (int16_t)lroundf(s);
}
static inline void blePut(uint8_t *p, int idx, int16_t v) {
  p[idx] = (uint8_t)(v & 0xFF);
  p[idx + 1] = (uint8_t)((uint16_t)v >> 8);
}

class BleSrvCb : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, ble_gap_conn_desc* desc) override {
    bleConnected = true;
    s->updateConnParams(desc->conn_handle, 12, 24, 0, 200);   // 15-30 ms interval
  }
  void onDisconnect(NimBLEServer* s) override {
    bleConnected = false; gpsMs = 0; dtcApp = false;
    if (appOn) NimBLEDevice::startAdvertising();      // ถ้าปิดการเชื่อมต่อแอพไว้ ไม่โฆษณาต่อ
  }
};

class BleCmdCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    std::string v = c->getValue();
    if (v.size() < 1) return;
    uint8_t cmd = (uint8_t)v[0];
    if (cmd == 1) {                                  // ลบ DTC (เฉพาะ Honda)
      if (car.proto == PR_HONDA) { setClearState(1); dtcClearReq = true; }
      else setClearState(3);
    } else if (cmd == 4 && v.size() >= 2) {          // DTC ของแอพ: 0 หยุด / 1 อ่านต่อเนื่อง / 2 อ่านใหม่ทันที
      uint8_t a = (uint8_t)v[1];
      if (a == 0) dtcApp = false;
      else { if (a == 2) setClearState(0); dtcApp = true; if (a == 2) dtcRestart = true; }
    } else if (cmd == 3 && v.size() >= 3) {          // GPS speed จากแอพ: [3][u16 km/h x10 LE] (0xFFFF = ไม่มีสัญญาณ)
      uint16_t sp = (uint8_t)v[1] | ((uint16_t)(uint8_t)v[2] << 8);
      gpsKmh = (sp == 0xFFFF) ? NAN : sp / 10.0f; gpsMs = millis();
    } else if (cmd == 0x13 && v.size() >= 7) {         // เริ่มแฟลชจากแอพ: [0x13][u32 ขนาดไฟล์ LE][u16 ผลรวมไบต์ LE]
      // เริ่มเฉพาะเมื่อไฟล์ในเกจตรงกับที่แอพยืนยัน และเงื่อนไขเดียวกับกดปุ่ม FLASH บนเกจทุกข้อ
      const uint32_t sz = (uint8_t)v[1] | ((uint32_t)(uint8_t)v[2] << 8) | ((uint32_t)(uint8_t)v[3] << 16) | ((uint32_t)(uint8_t)v[4] << 24);
      const uint16_t sm = (uint8_t)v[5] | ((uint16_t)(uint8_t)v[6] << 8);
      const uint8_t es = fEcu;
      const bool ecuOk = es == ES_OK || es == ES_FLASH || es == ES_RECOVER_OLD || es == ES_RECOVER_NEW;
      if (fPrepOn && fFileOk && fPlanOk && !fBusy() && fPhase != FP_RECV && !fStartReq && !fDelReq && ecuOk &&
          sz == fFileSize && sm == fFileSum) {
        fErr = FE_NONE; fStartReq = true;                // kTask (ecuFlashPrep) เริ่มแฟลช
      }
    } else if (cmd == 0x12) {                          // ล้างผลแฟลชครั้งก่อน
      if (fPrepOn && !fBusy() && fPhase != FP_RECV) { fErr = FE_NONE; fPct = 0; fDone = 0; fTotal = 0; fElapsedMs = 0; fEtaMs = 0; fPhase = fFileOk ? FP_READY : FP_PREP; }
    } else if (cmd == 2 && v.size() >= 2) {
      uint8_t m = (uint8_t)v[1];
      if (m < BM_COUNT && m != bikeModel) { bikeModel = m; bikeChanged = true; }   // ไม่บันทึกลง Flash (ตั้งถาวรที่หน้า SETUP)
    }
  }
};

class BleImgCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    std::string v = c->getValue();
    if (v.size() < 1 || v.size() > 1 + sizeof(ImgMsg::d) || !imgQ) return;
    ImgMsg m; m.type = (uint8_t)v[0]; m.len = (uint8_t)(v.size() - 1);
    if (m.len) memcpy(m.d, v.data() + 1, m.len);
    // FW 1.0.20: แอพส่งแบบไม่รอตอบ -> รอคิวได้นานขึ้น (3 วิ) = backpressure ถ้าเขียน Flash ไม่ทัน (ข้อมูลไม่หาย)
    if (xQueueSend(imgQ, &m, pdMS_TO_TICKS(3000)) != pdTRUE) DBG("[ble] img queue full - chunk dropped\n");   // ผลรวมตอนจบจะไม่ตรง -> แจ้งล้มเหลว
  }
};

static void bleTask(void*) {
  uint8_t p[BLE_PKT_LEN];
  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(BLE_PERIOD_MS));
    if (!bleConnected) continue;
    memset(p, 0, sizeof(p));
    p[0] = 1;
    p[1] = car.state;
    p[2] = car.proto;
    p[3] = (carFresh() ? 1 : 0);
    p[4] = bikeModel;
    p[5] = imgState;
    blePut(p, 6,  bleScale(car.rpm,   1));
    blePut(p, 8,  bleScale(car.speed, 10));
    blePut(p, 10, bleScale(car.ect,   10));
    blePut(p, 12, bleScale(car.iat,   10));
    blePut(p, 14, bleScale(car.eot,   10));
    blePut(p, 16, bleScale(car.tps,   10));
    blePut(p, 18, bleScale(car.map,   10));
    blePut(p, 20, bleScale(car.batt,  100));
    blePut(p, 22, bleScale(car.afr,   100));
    blePut(p, 24, bleScale(car.ign,   10));
    blePut(p, 26, bleScale(car.inj,   100));
    blePut(p, 28, bleScale(car.o2v,   1000));
    blePut(p, 30, bleScale(car.stft,  1000));
    blePut(p, 32, bleScale(car.ltft,  1000));
    // ---- สถานะแฟลช ECU ----
    p[34] = 1;
    p[35] = fPrepOn ? 1 : 0;
    p[36] = fPhase; p[37] = fEcu; p[38] = fErr; p[39] = fPct;
    { uint32_t fs = fFileOk ? fFileSize : 0; memcpy(p + 40, &fs, 4); }
    { uint16_t s16 = fFileSum; memcpy(p + 44, &s16, 2); }
    p[46] = fFileCk8;
    { float bt = fBatt; p[47] = isnan(bt) ? 0 : (uint8_t)constrain(lroundf(bt * 10), 1, 255); }
    { uint32_t d = fDone, t = fTotal; memcpy(p + 48, &d, 4); memcpy(p + 52, &t, 4); }
    { uint32_t el = fBusy() ? (millis() - fT0) : fElapsedMs; uint32_t es = el / 1000, rs = fEtaMs / 1000; uint16_t e16 = (uint16_t)(es > 65535 ? 65535 : es), r16 = (uint16_t)(rs > 65535 ? 65535 : rs);
      memcpy(p + 56, &e16, 2); memcpy(p + 58, &r16, 2); }
    for (int i = 0; i < 5; i++) p[60 + i] = fEcmId[i];
    p[65] = fEcmOk ? 1 : 0;
    { uint32_t rc = fRecv; memcpy(p + 66, &rc, 4); }
    p[70] = fFlashCnt < 0 ? 0xFF : (uint8_t)fFlashCnt;
    p[71] = fFlashCnt0 < 0 ? 0xFF : (uint8_t)fFlashCnt0;
    p[72] = FW_VER_MAJ; p[73] = FW_VER_MIN; p[74] = FW_VER_PATCH;   // เวอร์ชันเฟิร์มแวร์ (แอพอ่านไปแสดงในหน้า SETTING)
    {                                                  // ---- DTC (FW 1.0.14, ไบต์ 75..111) ----
      DtcList L;
      portENTER_CRITICAL(&dtcMux); L = dtcPub; portEXIT_CRITICAL(&dtcMux);
      p[75] = 1;
      p[76] = (L.valid ? 1 : 0) | (dtcApp ? 2 : 0);
      p[77] = L.clearState;
      uint8_t nc = L.valid ? L.nCur : 0, ns = L.valid ? L.nSto : 0, k = 0;
      if (nc > 16) nc = 16;
      if (ns > 16 - nc) ns = 16 - nc;
      p[78] = nc; p[79] = ns;
      for (uint8_t i = 0; i < nc; i++, k++) { p[80 + k * 2] = L.cur[i].code; p[81 + k * 2] = L.cur[i].sub; }
      for (uint8_t i = 0; i < ns; i++, k++) { p[80 + k * 2] = L.sto[i].code; p[81 + k * 2] = L.sto[i].sub; }
    }
    {                                                  // ---- ECU INFO (FW 1.0.14, ไบต์ 112..127) ----
      static uint32_t r0 = 0, s0 = 0, linkT0 = 0; static uint16_t hz10 = 0;
      const uint32_t now = millis(), sq = car.seq;
      if (!r0) { r0 = now; s0 = sq; }
      else if (now - r0 >= 1000) { hz10 = (uint16_t)((sq - s0) * 10000UL / (now - r0)); r0 = now; s0 = sq; }
      const bool fr = carFresh();
      if (fr) { if (!linkT0) linkT0 = now ? now : 1; } else linkT0 = 0;
      p[112] = 1;
      p[113] = car.ecuIdOk ? 1 : 0;
      for (int i = 0; i < 5; i++) p[114 + i] = car.ecuId[i];
      p[119] = car.tableA; p[120] = car.tableB; p[121] = car.tableS;
      memcpy(p + 122, &hz10, 2);
      { uint32_t ls = linkT0 ? (now - linkT0) / 1000 : 0; uint16_t l16 = (uint16_t)(ls > 65535 ? 65535 : ls); memcpy(p + 124, &l16, 2); }
      { uint32_t a = carAgeMs() / 100; p[126] = (uint8_t)(a > 254 ? 255 : a); }
      p[127] = obdKwpHeader ? 1 : 0;
    }
    bleData->setValue(p, BLE_PKT_LEN);
    bleData->notify();
  }
}

static void bleStart() {
  NimBLEDevice::init(bleDevName());               // ชื่อไม่ซ้ำกัน: MFB-PRO-XXXX (XXXX จาก MAC ของชิป)
  NimBLEDevice::setMTU(247);                      // FW 1.0.20: 185 -> 247 ส่งไฟล์/โลโก้ชิ้นใหญ่ขึ้น
  NimBLEDevice::setPower(ESP_PWR_LVL_P6);
  bleServer = NimBLEDevice::createServer();
  bleServer->setCallbacks(new BleSrvCb());
  NimBLEService* svc = bleServer->createService(BLE_SVC_UUID);
  bleData = svc->createCharacteristic(BLE_DATA_UUID, NIMBLE_PROPERTY::NOTIFY);
  NimBLECharacteristic* cmd = svc->createCharacteristic(BLE_CMD_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  cmd->setCallbacks(new BleCmdCb());
  NimBLECharacteristic* img = svc->createCharacteristic(BLE_IMG_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);   // FW 1.0.20: เขียนแบบไม่รอตอบได้ (ส่งเร็วขึ้น)
  img->setCallbacks(new BleImgCb());
  imgQ = xQueueCreate(16, sizeof(ImgMsg));          // 16 x 246 B ~ 3.9 KB
  xTaskCreate(imgTask, "img", 5120, NULL, 1, NULL);
  svc->start();
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(BLE_SVC_UUID);
  adv->setScanResponse(true);
  adv->start();
  xTaskCreatePinnedToCore(bleTask, "ble", 4096, NULL, 2, NULL, 1);
  bleStarted = true;
}

// เปิด/ปิดการเชื่อมต่อแอพ: OFF = หยุดโฆษณา + ตัดการเชื่อมต่อที่ค้างอยู่ | ON = เริ่มโฆษณา (ถ้ายังไม่เคยเริ่ม BLE จะเริ่มให้)
static void bleAppSet(bool on) {
  appOn = on;
  if (on) {
    if (!bleStarted) bleStart(); else NimBLEDevice::getAdvertising()->start();
  } else if (bleStarted) {
    NimBLEDevice::getAdvertising()->stop();
    if (bleServer) { for (uint16_t h : bleServer->getPeerDevices()) bleServer->disconnect(h); }
    bleConnected = false;
  }
}

static const char *bleStatus() {
  if (!appOn) return "OFF";
  if (!bleStarted) return "STARTING";
  return bleConnected ? "CONNECTED" : "WAITING";
}
