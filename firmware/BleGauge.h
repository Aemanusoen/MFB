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
 *  - CMD   (write)  7a0f0003-...  : [cmd][arg]   cmd 1 = ลบ DTC, cmd 2 = เปลี่ยนรุ่นรถ (arg = BM_*)
 *
 * แพ็กเก็ต DATA (little-endian):
 *   0 u8 version(=1)   1 u8 state   2 u8 proto   3 u8 flags (bit0 = ข้อมูลสด)
 *   4 u8 bikeModel     5 u8 reserved
 *   6.. int16 x 14  : rpm, speed*10, ect*10, iat*10, eot*10, tps*10, map*10,
 *                     batt*100, afr*100, ign*10, inj*100, o2v*1000, stft*1000, ltft*1000
 *   ltft*1000 อยู่ที่ offset 32 รวมทั้งหมด 34 ไบต์
 *   ค่า NaN / ไม่มีข้อมูล = 0x7FFF
 */
#pragma once
#include <NimBLEDevice.h>

#define BLE_NAME       "MFB-PRO"
#define BLE_PERIOD_MS  80
#define BLE_PKT_LEN    34
#define BLE_NAN        0x7FFF

#define BLE_SVC_UUID   "7a0f0001-5a41-5201-9c11-2a52a1c0de01"
#define BLE_DATA_UUID  "7a0f0002-5a41-5201-9c11-2a52a1c0de01"
#define BLE_CMD_UUID   "7a0f0003-5a41-5201-9c11-2a52a1c0de01"

static NimBLEServer*         bleServer = nullptr;
static NimBLECharacteristic* bleData   = nullptr;
static volatile bool         bleConnected = false;

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
    bleConnected = false;
    NimBLEDevice::startAdvertising();
  }
};

class BleCmdCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    std::string v = c->getValue();
    if (v.size() < 1) return;
    uint8_t cmd = (uint8_t)v[0];
    if (cmd == 1) {
      dtcClearReq = true;
    } else if (cmd == 2 && v.size() >= 2) {
      uint8_t m = (uint8_t)v[1];
      if (m < BM_COUNT && m != bikeModel) { bikeModel = m; bikeChanged = true; }   // ไม่บันทึกลง Flash (ตั้งถาวรที่หน้า SETUP)
    }
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
  NimBLECharacteristic* cmd = svc->createCharacteristic(BLE_CMD_UUID, NIMBLE_PROPERTY::WRITE);
  cmd->setCallbacks(new BleCmdCb());
  svc->start();
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(BLE_SVC_UUID);
  adv->setScanResponse(true);
  adv->start();
  xTaskCreatePinnedToCore(bleTask, "ble", 4096, NULL, 2, NULL, 0);
}
