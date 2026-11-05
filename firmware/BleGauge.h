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
 *
 * แพ็กเก็ต DATA (little-endian):
 *   0 u8 version(=1)   1 u8 state   2 u8 proto   3 u8 flags (bit0 = ข้อมูลสด)
 *   4 u8 bikeModel     5 u8 imgState
 *   6.. int16 x 14  : rpm, speed*10, ect*10, iat*10, eot*10, tps*10, map*10,
 *                     batt*100, afr*100, ign*10, inj*100, o2v*1000, stft*1000, ltft*1000
 *   ltft*1000 อยู่ที่ offset 32 รวมทั้งหมด 34 ไบต์
 *   ค่า NaN / ไม่มีข้อมูล = 0x7FFF
 */
#pragma once
#include <NimBLEDevice.h>
#include <LittleFS.h>

#define BLE_NAME       "MFB-PRO"
#define BLE_PERIOD_MS  80
#define BLE_PKT_LEN    34
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

struct ImgMsg { uint8_t type; uint8_t len; uint8_t d[200]; };
static QueueHandle_t imgQ = nullptr;

static void imgTask(void*) {
  ImgMsg m; File f; bool open = false;
  uint32_t expect = 0, got = 0; uint16_t sum = 0;
  for (;;) {
    if (xQueueReceive(imgQ, &m, portMAX_DELAY) != pdTRUE) continue;
    switch (m.type) {
      case 1: {                                   // START [u32 size]
        if (open) { f.close(); open = false; }
        if (m.len < 4) { imgState = 3; break; }
        expect = (uint32_t)m.d[0] | ((uint32_t)m.d[1] << 8) | ((uint32_t)m.d[2] << 16) | ((uint32_t)m.d[3] << 24);
        if (expect != (uint32_t)LOGO_BYTES || !LittleFS.begin(true)) { imgState = 3; break; }
        LittleFS.remove("/logo.tmp");
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
    bleConnected = false; gpsMs = 0;
    if (appOn) NimBLEDevice::startAdvertising();      // ถ้าปิดการเชื่อมต่อแอพไว้ ไม่โฆษณาต่อ
  }
};

class BleCmdCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    std::string v = c->getValue();
    if (v.size() < 1) return;
    uint8_t cmd = (uint8_t)v[0];
    if (cmd == 1) {
      dtcClearReq = true;
    } else if (cmd == 3 && v.size() >= 3) {          // GPS speed จากแอพ: [3][u16 km/h x10 LE] (0xFFFF = ไม่มีสัญญาณ)
      uint16_t sp = (uint8_t)v[1] | ((uint16_t)(uint8_t)v[2] << 8);
      gpsKmh = (sp == 0xFFFF) ? NAN : sp / 10.0f; gpsMs = millis();
    } else if (cmd == 2 && v.size() >= 2) {
      uint8_t m = (uint8_t)v[1];
      if (m < BM_COUNT && m != bikeModel) { bikeModel = m; bikeChanged = true; }   // ไม่บันทึกลง Flash (ตั้งถาวรที่หน้า SETUP)
    }
  }
};

class BleImgCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    std::string v = c->getValue();
    if (v.size() < 1 || v.size() > 201 || !imgQ) return;
    ImgMsg m; m.type = (uint8_t)v[0]; m.len = (uint8_t)(v.size() - 1);
    if (m.len) memcpy(m.d, v.data() + 1, m.len);
    xQueueSend(imgQ, &m, pdMS_TO_TICKS(500));     // รอได้สูงสุด 0.5 วิ = backpressure ให้แอพส่งช้าลงถ้าเขียน Flash ไม่ทัน
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
    bleData->setValue(p, BLE_PKT_LEN);
    bleData->notify();
  }
}

static void bleStart() {
  NimBLEDevice::init(BLE_NAME);
  NimBLEDevice::setMTU(185);
  NimBLEDevice::setPower(ESP_PWR_LVL_P6);
  bleServer = NimBLEDevice::createServer();
  bleServer->setCallbacks(new BleSrvCb());
  NimBLEService* svc = bleServer->createService(BLE_SVC_UUID);
  bleData = svc->createCharacteristic(BLE_DATA_UUID, NIMBLE_PROPERTY::NOTIFY);
  NimBLECharacteristic* cmd = svc->createCharacteristic(BLE_CMD_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  cmd->setCallbacks(new BleCmdCb());
  NimBLECharacteristic* img = svc->createCharacteristic(BLE_IMG_UUID, NIMBLE_PROPERTY::WRITE);
  img->setCallbacks(new BleImgCb());
  imgQ = xQueueCreate(12, sizeof(ImgMsg));
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
