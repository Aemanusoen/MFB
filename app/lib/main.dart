import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart' show FilePicker, FilePickerResult, FileType;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart' show getApplicationDocumentsDirectory;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:xml/xml.dart';

// ---------- BLE UUIDs (ต้องตรงกับ BleGauge.h) ----------
final Guid kSvc = Guid('7a0f0001-5a41-5201-9c11-2a52a1c0de01');
final Guid kData = Guid('7a0f0002-5a41-5201-9c11-2a52a1c0de01');
final Guid kCmd = Guid('7a0f0003-5a41-5201-9c11-2a52a1c0de01');
final Guid kImg = Guid('7a0f0004-5a41-5201-9c11-2a52a1c0de01');

const kFont = 'Ethnocentric';
const kGreen = Color(0xFF3CFF8A);
const kAmber = Color(0xFFFFB020);
const kBad = Color(0xFFFF4D4D);
const kMaxRpm = 15000.0;
const kZoneRpm = 12000.0;

// ---------- ธีมสี ----------
class AppTheme {
  final String name;
  final Color c; // สีหลัก
  final Color c2; // สีอ่อน/โซนแดงไลน์
  const AppTheme(this.name, this.c, this.c2);
}

const kThemes = <AppTheme>[
  AppTheme('แดง', Color(0xFFFF2A2A), Color(0xFFFF8A8A)),
  AppTheme('ม่วง', Color(0xFFB04CFF), Color(0xFFDDB0FF)),
  AppTheme('ฟ้า', Color(0xFF2EB8FF), Color(0xFFA2E3FF)),
  AppTheme('เขียวนีออน', Color(0xFF39FF14), Color(0xFFB4FF9E)),
  AppTheme('ชมพู', Color(0xFFFF4FD8), Color(0xFFFFAEEF)),
  AppTheme('น้ำเงิน', Color(0xFF2A5BFF), Color(0xFFAFC2FF)),
];

// เวอร์ชันเฟิร์มแวร์ที่แอพรุ่นนี้ออกแบบมาให้ใช้คู่กัน (แสดงเทียบในหน้า SETTING)
const kAppFw = '1.0.15';
const kAppVer = '1.4.0'; // เวอร์ชันแอพ (ตรงกับ pubspec.yaml)

// ---------- ค่าคีย์ที่แสดงได้ (เหมือน TEST1 + TOP SPD) ----------
const int kTps = 0, kTemp = 1, kBatt = 2, kAfr = 3, kInj = 4, kIgn = 5, kRpm = 6, kMap = 7,
    kSpd = 8, kEot = 9, kIat = 10, kO2 = 11, kStft = 12, kLtft = 13, kTop = 14;

class KeyDef {
  final String name, unit;
  final int dec;
  final String th; // ชื่อภาษาไทยต่อท้ายชื่อในช่องค่า
  const KeyDef(this.name, this.unit, this.dec, [this.th = '']);
}

const kKeys = <KeyDef>[
  KeyDef('TPS', '%', 1, 'ลิ้นเร่ง'), KeyDef('W.TEMP', '°C', 0, 'อุณหภูมิน้ำ'), KeyDef('BATT', 'V', 1, 'แบตเตอรี่'),
  KeyDef('AFR', '', 1, 'อากาศ : น้ำมัน'), KeyDef('INJ', 'ms', 2, 'เวลาฉีด'), KeyDef('IGN', '°BTDC', 1, 'องศาจุดระเบิด'),
  KeyDef('RPM', 'rpm', 0, 'รอบเครื่อง'), KeyDef('MAP', 'kPa', 0, 'แรงดันไอดี'), KeyDef('SPD', 'km/h', 0, 'ความเร็ว'),
  KeyDef('EOT', '°C', 0, 'อุณหภูมิน้ำมันเครื่อง'), KeyDef('IAT', '°C', 0, 'อุณหภูมิอากาศ'), KeyDef('O2', 'V', 2, 'เซนเซอร์ O2'),
  KeyDef('STFT', '', 3, 'ชดเชยน้ำมันระยะสั้น'), KeyDef('LTFT', '', 3, 'ชดเชยน้ำมันระยะยาว'), KeyDef('TOP SPD', 'km/h', 0, 'ความเร็วสูงสุด'),
];

// สีค่าคงที่ (ไม่เปลี่ยนตามธีม)
const kTpsBlue = Color(0xFF3D6BFF);
const kBattRed = Color(0xFFFF3B3B);
const kAfrLow = Color(0xFF2EB8FF); // < 13  ฟ้า
const kAfrOk = Color(0xFF3CFF8A); // 13-14.7 เขียว
const kAfrHigh = Color(0xFFFF3B3B); // > 14.7 แดง
const kLogoRed = Color(0xFFFF2A2A);

Color afrColor(double v) => v < 13.0 ? kAfrLow : (v <= 14.7 ? kAfrOk : kAfrHigh);

/// สีแถบอุณหภูมิ: เขียว -> ส้ม (ใกล้ค่าที่ตั้งเตือน 15 °C) -> แดง (ถึง/เกินค่าที่ตั้งเตือน)
Color tempBarColor(double v, double warn) => v >= warn ? kBad : (v >= warn - 15 ? kAmber : kGreen);

/// สีไล่เฉดเขียว -> เหลือง -> แดง ตามตำแหน่งรอบเครื่อง เทียบกับ SHIFT RPM
Color rpmColor(double rpm, int shift) {
  final t = (rpm / math.max(1, shift)).clamp(0.0, 1.0).toDouble();
  const g = Color(0xFF29E868), y = Color(0xFFFFD21F), r = Color(0xFFFF2A2A);
  return t < 0.65 ? Color.lerp(g, y, t / 0.65)! : Color.lerp(y, r, (t - 0.65) / 0.35)!;
}

// ---------- คำอธิบาย DTC Honda (ตรงกับ DTC_TABLE ในเฟิร์มแวร์เกจ) : (อังกฤษ, ไทย) ----------
const Map<int, (String, String)> kDtcDesc = {
  101: ('MAP sensor low voltage', 'เซนเซอร์ MAP แรงดันต่ำ'),
  102: ('MAP sensor high voltage', 'เซนเซอร์ MAP แรงดันสูง'),
  201: ('MAP sensor performance', 'เซนเซอร์ MAP ทำงานผิดปกติ'),
  601: ('Baro sensor low voltage', 'เซนเซอร์ความดันบรรยากาศ แรงดันต่ำ'),
  602: ('Baro sensor high voltage', 'เซนเซอร์ความดันบรรยากาศ แรงดันสูง'),
  701: ('ECT sensor low voltage', 'เซนเซอร์อุณหภูมิน้ำ (ECT) แรงดันต่ำ'),
  702: ('ECT sensor high voltage', 'เซนเซอร์อุณหภูมิน้ำ (ECT) แรงดันสูง'),
  801: ('TP sensor low voltage', 'เซนเซอร์ลิ้นเร่ง (TP) แรงดันต่ำ'),
  802: ('TP sensor high voltage', 'เซนเซอร์ลิ้นเร่ง (TP) แรงดันสูง'),
  901: ('IAT sensor low voltage', 'เซนเซอร์อุณหภูมิอากาศ (IAT) แรงดันต่ำ'),
  902: ('IAT sensor high voltage', 'เซนเซอร์อุณหภูมิอากาศ (IAT) แรงดันสูง'),
  1101: ('VS sensor no signal', 'เซนเซอร์ความเร็ว (VS) ไม่มีสัญญาณ'),
  1201: ('No.1 primary injector', 'หัวฉีดหลัก สูบ 1'),
  1301: ('No.2 primary injector', 'หัวฉีดหลัก สูบ 2'),
  1401: ('No.3 primary injector', 'หัวฉีดหลัก สูบ 3'),
  1501: ('No.4 primary injector', 'หัวฉีดหลัก สูบ 4'),
  1601: ('No.1 secondary injector', 'หัวฉีดรอง สูบ 1'),
  1701: ('No.2 secondary injector', 'หัวฉีดรอง สูบ 2'),
  1801: ('CMP sensor no signal', 'เซนเซอร์เพลาลูกเบี้ยว (CMP) ไม่มีสัญญาณ'),
  1901: ('CKP sensor no signal', 'เซนเซอร์เพลาข้อเหวี่ยง (CKP) ไม่มีสัญญาณ'),
  2101: ('O2 sensor 1 low voltage', 'เซนเซอร์ O2 ตัวที่ 1 แรงดันต่ำ'),
  2102: ('O2 sensor 1 high voltage', 'เซนเซอร์ O2 ตัวที่ 1 แรงดันสูง'),
  2201: ('O2 sensor 2 low voltage', 'เซนเซอร์ O2 ตัวที่ 2 แรงดันต่ำ'),
  2202: ('O2 sensor 2 high voltage', 'เซนเซอร์ O2 ตัวที่ 2 แรงดันสูง'),
};
(String, String)? dtcDesc(int code, int sub) => kDtcDesc[code * 100 + sub];

const kBikeNames = ['WAVE', 'LEAD', 'PCX160', 'GIORNO']; // ตรงกับ BM_* ในเฟิร์มแวร์เกจ

// ---------- การตั้งค่าที่บันทึกในเครื่อง ----------
class Cfg extends ChangeNotifier {
  static final Cfg i = Cfg._();
  Cfg._();
  int themeIdx = 0;
  int shift = 10000; // SHIFT LIGHT RPM
  int tempWarn = 105; // °C
  bool speedGps = true; // true = GPS, false = ECU
  int graphOn = 15; // หน้า GRAPH: บิตเปิด-ปิดเส้นกราฟ RPM/TPS/GPS/AFR
  List<int> main = [kTps, kAfr, kIgn, kTemp, kEot, kBatt]; // ซ้าย 3 + ขวา 3
  List<int> grid = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
  List<int> center = [kRpm]; // ช่องใต้เกจ (เลือกค่าได้ ค่าเริ่มต้น RPM)

  AppTheme get t => kThemes[themeIdx];

  List<int>? _parse(String? s, int len) {
    if (s == null) return null;
    final l = s.split(',').map((e) => int.tryParse(e)).toList();
    if (l.length != len || l.any((e) => e == null || e < 0 || e >= kKeys.length)) return null;
    return l.cast<int>();
  }

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getInt('theme') ?? 0;
      themeIdx = (v >= 0 && v < kThemes.length) ? v : 0;
      shift = (p.getInt('shift') ?? 10000).clamp(1000, 15000).toInt();
      tempWarn = (p.getInt('tempWarn') ?? 105).clamp(60, 150).toInt();
      speedGps = p.getBool('speedGps') ?? true;
      graphOn = (p.getInt('gon') ?? 15) & 15;
      main = _parse(p.getString('main'), 6) ?? _parse(p.getString('main'), 7)?.sublist(0, 6) ?? main; // แอพรุ่นเก่าเก็บ 7 ช่อง -> ใช้ 6 ช่องแรก
      grid = _parse(p.getString('grid'), 12) ?? grid;
      center = _parse(p.getString('ctr'), 1) ?? center;
    } catch (_) {}
  }

  Future<void> _save() async {
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('theme', themeIdx);
      await p.setInt('shift', shift);
      await p.setInt('tempWarn', tempWarn);
      await p.setBool('speedGps', speedGps);
      await p.setInt('gon', graphOn);
      await p.setString('main', main.join(','));
      await p.setString('grid', grid.join(','));
      await p.setString('ctr', center.join(','));
    } catch (_) {}
  }

  Future<void> setTheme(int v) {
    themeIdx = v;
    return _save();
  }

  Future<void> addShift(int d) {
    shift = (shift + d).clamp(1000, 15000).toInt();
    return _save();
  }

  Future<void> addTemp(int d) {
    tempWarn = (tempWarn + d).clamp(60, 150).toInt();
    return _save();
  }

  Future<void> toggleGraph(int i) {
    graphOn ^= (1 << i);
    return _save();
  }

  Future<void> toggleSpeed() {
    speedGps = !speedGps;
    return _save();
  }

  Future<void> setSlot(List<int> arr, int idx, int key) {
    final j = arr.indexOf(key);
    if (j >= 0 && j != idx) arr[j] = arr[idx]; // ถ้าค่านี้อยู่ช่องอื่นแล้ว ให้สลับกัน (เหมือน TEST1)
    arr[idx] = key;
    return _save();
  }
}

// ---------- DRAG LOG ----------
enum DragSt { ready, run, done }

class DragRun {
  List<double?> t = List<double?>.filled(4, null); // เวลา (วินาที) ที่ 201 / 402 / 500 / 1000 m
  List<double?> v = List<double?>.filled(4, null); // ความเร็ว (km/h) ที่ระยะนั้น
  double maxKmh = 0;
  bool get hasData => t[0] != null || maxKmh > 0;
  void clear() {
    t = List<double?>.filled(4, null);
    v = List<double?>.filled(4, null);
    maxKmh = 0;
  }

  Map<String, dynamic> toJson() => {'t': t, 'v': v, 'm': maxKmh};

  static DragRun fromJson(dynamic j) {
    final r = DragRun();
    try {
      final tt = (j['t'] as List), vv = (j['v'] as List);
      for (int i = 0; i < 4; i++) {
        r.t[i] = (tt[i] as num?)?.toDouble();
        r.v[i] = (vv[i] as num?)?.toDouble();
      }
      r.maxKmh = (j['m'] as num?)?.toDouble() ?? 0;
    } catch (_) {}
    return r;
  }
}

// ---------- สถานะแฟลช ECU จากเกจ (FW 1.0.9: แพ็กเก็ต DATA ไบต์ 34..69) ----------
class FlashStat {
  final bool prep; // เกจเปิดหน้าเตรียมแฟลชอยู่
  final int phase, ecu, err, pct, fileSize, fileSum, fileCk8, done, total, elapsed, eta, recv;
  final double? batt;
  final List<int>? ecm;
  final int? count, count0; // FLASHCOUNT จากกล่อง / ค่าก่อนกด FLASH (null = ยังอ่านไม่ได้, FW 1.0.10)
  const FlashStat({
    required this.prep, required this.phase, required this.ecu, required this.err, required this.pct,
    required this.fileSize, required this.fileSum, required this.fileCk8, required this.done, required this.total,
    required this.elapsed, required this.eta, required this.recv, this.batt, this.ecm, this.count, this.count0,
  });
  bool get busy => phase >= 4 && phase <= 8;

  static FlashStat? parse(List<int> b) {
    if (b.length < 70 || b[34] < 1) return null;
    final d = ByteData.sublistView(Uint8List.fromList(b));
    return FlashStat(
      prep: b[35] != 0, phase: b[36], ecu: b[37], err: b[38], pct: b[39],
      fileSize: d.getUint32(40, Endian.little), fileSum: d.getUint16(44, Endian.little), fileCk8: b[46],
      batt: b[47] == 0 ? null : b[47] / 10,
      done: d.getUint32(48, Endian.little), total: d.getUint32(52, Endian.little),
      elapsed: d.getUint16(56, Endian.little), eta: d.getUint16(58, Endian.little),
      ecm: b[65] != 0 ? b.sublist(60, 65) : null, recv: d.getUint32(66, Endian.little),
      count: b.length >= 72 && b[70] != 0xFF ? b[70] : null,
      count0: b.length >= 72 && b[71] != 0xFF ? b[71] : null,
    );
  }
}

// ---------- ข้อมูลจาก ESP32 ----------
class Telemetry {
  final bool fresh;
  final int state, proto, bike, img;
  final double? rpm, speed, ect, iat, eot, tps, map, batt, afr, ign, inj, o2v, stft, ltft;
  final FlashStat? fl; // null = เฟิร์มแวร์เกจไม่รองรับการแฟลช (ต่ำกว่า 1.0.9)
  final int? fwMaj, fwMin, fwPatch; // เวอร์ชันเฟิร์มแวร์เกจ (null = เฟิร์มแวร์เก่าที่ยังไม่ส่งเวอร์ชัน)
  // DTC จากเกจ (FW 1.0.14, ไบต์ 75..111): dtcSup = เกจรองรับ, dtcValid = ผลอ่านใช้ได้, dtcClear 0 ว่าง 1 กำลังลบ 2 สำเร็จ 3 ไม่สำเร็จ
  final bool dtcSup, dtcValid;
  final int dtcClear;
  final List<List<int>> dtcCur, dtcSto; // [code, sub]
  // ECU INFO (FW 1.0.14, ไบต์ 112..127)
  final bool infoSup, kwp;
  final List<int>? ecuId;
  final int tabA, tabB, tabS, linkSec, ageDs;
  final double hz;
  Telemetry({
    this.fresh = false, this.state = 0, this.proto = 0, this.bike = 0, this.img = 0,
    this.rpm, this.speed, this.ect, this.iat, this.eot, this.tps, this.map,
    this.batt, this.afr, this.ign, this.inj, this.o2v, this.stft, this.ltft, this.fl,
    this.fwMaj, this.fwMin, this.fwPatch,
    this.dtcSup = false, this.dtcValid = false, this.dtcClear = 0, this.dtcCur = const [], this.dtcSto = const [],
    this.infoSup = false, this.kwp = false, this.ecuId, this.tabA = 0, this.tabB = 0, this.tabS = 0, this.linkSec = 0, this.ageDs = 255, this.hz = 0,
  });
  String? get fwText => fwMaj == null ? null : '$fwMaj.$fwMin.$fwPatch';

  static Telemetry? parse(List<int> b) {
    if (b.length < 34 || b[0] != 1) return null;
    final d = ByteData.sublistView(Uint8List.fromList(b));
    double? f(int off, double k) {
      final v = d.getInt16(off, Endian.little);
      return v == 0x7FFF ? null : v / k;
    }

    final hasDtc = b.length >= 112 && b[75] >= 1;
    final hasInfo = b.length >= 128 && b[112] >= 1;
    final nc = hasDtc ? math.min(16, b[78]) : 0;
    final ns = hasDtc ? math.min(16 - nc, b[79]) : 0;
    return Telemetry(
      state: b[1], proto: b[2], fresh: (b[3] & 1) != 0, bike: b[4], img: b[5],
      rpm: f(6, 1), speed: f(8, 10), ect: f(10, 10), iat: f(12, 10),
      eot: f(14, 10), tps: f(16, 10), map: f(18, 10), batt: f(20, 100),
      afr: f(22, 100), ign: f(24, 10), inj: f(26, 100), o2v: f(28, 1000),
      stft: f(30, 1000), ltft: f(32, 1000),
      fl: FlashStat.parse(b),
      fwMaj: b.length >= 75 ? b[72] : null,
      fwMin: b.length >= 75 ? b[73] : null,
      fwPatch: b.length >= 75 ? b[74] : null,
      dtcSup: hasDtc, dtcValid: hasDtc && (b[76] & 1) != 0, dtcClear: hasDtc ? b[77] : 0,
      dtcCur: [for (int i = 0; i < nc; i++) [b[80 + i * 2], b[81 + i * 2]]],
      dtcSto: [for (int i = 0; i < ns; i++) [b[80 + (nc + i) * 2], b[81 + (nc + i) * 2]]],
      infoSup: hasInfo, kwp: hasInfo && b[127] == 1,
      ecuId: hasInfo && b[113] != 0 ? b.sublist(114, 119) : null,
      tabA: hasInfo ? b[119] : 0, tabB: hasInfo ? b[120] : 0, tabS: hasInfo ? b[121] : 0,
      hz: hasInfo ? d.getUint16(122, Endian.little) / 10 : 0,
      linkSec: hasInfo ? d.getUint16(124, Endian.little) : 0, ageDs: hasInfo ? b[126] : 255,
    );
  }
}

enum LinkState { idle, scanning, connecting, connected }

// ---------- ป้ายสถานะบนหัวจอ (หน้าแรก / GAUGE / SETTING): เกจ BLE / ECU / GPS + จำนวนดาวเทียม ----------
Widget statusChip(String s, Color col, {String? extra, String? extra2}) => Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: hudDeco(border: Colors.white24, radius: 6, color: Colors.black54),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: col, shape: BoxShape.circle, boxShadow: [BoxShadow(color: col, blurRadius: 5)])),
        const SizedBox(width: 6),
        Text(s, style: const TextStyle(fontFamily: kFont, fontSize: 8.5)),
        if (extra != null) Text('  $extra', style: const TextStyle(fontFamily: kFont, fontSize: 8.5, color: kGreen)),
        if (extra2 != null) Text(extra2, style: const TextStyle(fontFamily: kFont, fontSize: 8.5, color: Colors.white54)),
      ]),
    );

Widget statusChips(GaugeController c) {
  final linkTxt = switch (c.link) {
    LinkState.idle => 'OFFLINE',
    LinkState.scanning => 'SCANNING',
    LinkState.connecting => 'CONNECTING',
    LinkState.connected => c.gaugeName ?? 'CONNECTED',
  };
  final linkCol = c.link == LinkState.connected ? kGreen : (c.link == LinkState.idle ? kBad : kAmber);
  final live = c.ecuLive || c.demo;
  return SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(children: [
      statusChip(linkTxt, linkCol),
      statusChip(live ? 'ECU LIVE' : 'NO ECU', live ? kGreen : kBad),
      c.gpsOk
          ? statusChip('GPS', kGreen, extra: '${c.satUsed ?? '-'}', extra2: ' /${c.satTotal ?? '-'} SAT')
          : statusChip('NO GPS', kBad),
    ]),
  );
}

/// โลโก้หัวแอพ (ภาพ assets/logo.png พื้นโปร่งใส) — size 17 ≈ สูง 20 px
Widget mfbLogo(AppTheme th, {double size = 17}) => Image.asset('assets/logo.png', height: size * 1.2, fit: BoxFit.contain, filterQuality: FilterQuality.medium);

// ---------- สไตล์ HUD: กรอบตัดมุมซ้ายบน/ขวาล่าง + ขีดมุมขวาบน + เรืองแสงเบา ๆ (~10%) ----------
class HudBorder extends ShapeBorder {
  final double cut;
  final BorderSide side;
  final bool tick; // ขีดสั้นมุมขวาบน
  const HudBorder({this.cut = 10, this.side = BorderSide.none, this.tick = true});

  Path _path(Rect r, double c) {
    c = math.min(c, math.min(r.width, r.height) / 2);
    return Path()
      ..moveTo(r.left + c, r.top)
      ..lineTo(r.right, r.top)
      ..lineTo(r.right, r.bottom - c)
      ..lineTo(r.right - c, r.bottom)
      ..lineTo(r.left, r.bottom)
      ..lineTo(r.left, r.top + c)
      ..close();
  }

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _path(rect, cut);
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => _path(rect.deflate(side.width), math.max(0.0, cut - side.width * 0.4));
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width <= 0) return;
    final w = side.width;
    canvas.drawPath(_path(rect.deflate(w / 2), math.max(0.0, cut - w * 0.2)), Paint()
      ..color = side.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeJoin = StrokeJoin.miter);
    if (tick && rect.width >= 60 && rect.height >= 26) {
      final l = math.min(22.0, rect.width * 0.15);
      canvas.drawRect(Rect.fromLTWH(rect.right - 6 - l, rect.top + w + 1.5, l, 2), Paint()..color = side.color.withOpacity(0.9));
    }
  }

  @override
  ShapeBorder scale(double t) => HudBorder(cut: cut * t, side: side.scale(t), tick: tick);
  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => a is HudBorder ? HudBorder(cut: a.cut + (cut - a.cut) * t, side: BorderSide.lerp(a.side, side, t), tick: tick) : super.lerpFrom(a, t);
  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => b is HudBorder ? HudBorder(cut: cut + (b.cut - cut) * t, side: BorderSide.lerp(side, b.side, t), tick: tick) : super.lerpTo(b, t);
  @override
  bool operator ==(Object o) => o is HudBorder && o.cut == cut && o.side == side && o.tick == tick;
  @override
  int get hashCode => Object.hash(cut, side, tick);
}

/// กรอบ HUD สำเร็จรูป: เส้นขอบ + เรืองแสง 10% ของสีขอบ
ShapeDecoration hudDeco({required Color border, double width = 1.1, double radius = 12, Color? color, Gradient? gradient, bool tick = true}) {
  final cut = (radius * 0.9).clamp(4.0, 14.0).toDouble();
  return ShapeDecoration(
    color: gradient == null ? color : null,
    gradient: gradient,
    shape: HudBorder(cut: cut, side: BorderSide(color: border, width: width), tick: tick),
    shadows: border.opacity == 0 ? null : [BoxShadow(color: border.withOpacity(0.10 * border.opacity.clamp(0.4, 1.0).toDouble()), blurRadius: 6, spreadRadius: 0.5)],
  );
}

/// พื้นกริดจาง ๆ แบบ HUD (วางทับพื้นหลังทุกหน้า)
class HudGrid extends StatelessWidget {
  final Color? color;
  const HudGrid({super.key, this.color});
  @override
  Widget build(BuildContext context) => IgnorePointer(child: CustomPaint(painter: _HudGridPainter(color ?? Cfg.i.t.c), size: Size.infinite));
}

class _HudGridPainter extends CustomPainter {
  final Color c;
  _HudGridPainter(this.c);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = c.withOpacity(0.05)
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 24) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = 0; y < size.height; y += 24) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(_HudGridPainter o) => o.c != c;
}

/// ตัวเลขไหลนุ่ม ๆ: ครั้งแรกนับขึ้นจาก 0, ค่าถัดไปไหลจากค่าเดิม (ข้อความที่ไม่ใช่ตัวเลขแสดงตรง ๆ)
class RollNum extends StatelessWidget {
  final String text;
  final TextStyle style;
  const RollNum(this.text, {super.key, required this.style});
  static final _num = RegExp(r'^-?\d+(\.\d+)?$');
  @override
  Widget build(BuildContext context) {
    final t = text.trim();
    if (!_num.hasMatch(t)) return Text(text, style: style);
    final v = double.parse(t);
    final dec = t.contains('.') ? t.split('.')[1].length : 0;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: v),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      builder: (_, x, __) => Text(x.toStringAsFixed(dec), style: style),
    );
  }
}

/// แตะแล้วขอบกรอบ HUD วาบแสงสั้น ๆ
class TapFlash extends StatefulWidget {
  final Widget child;
  final double cut;
  final bool enabled;
  const TapFlash({super.key, required this.child, this.cut = 11, this.enabled = true});
  @override
  State<TapFlash> createState() => _TapFlashState();
}

class _TapFlashState extends State<TapFlash> with SingleTickerProviderStateMixin {
  late final AnimationController ac = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  @override
  void dispose() {
    ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Listener(
      onPointerDown: (_) => ac.forward(from: 0),
      child: Stack(children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: ac,
              builder: (_, __) => ac.value == 0 || ac.value == 1 ? const SizedBox.shrink() : CustomPaint(painter: _FlashPainter(1 - ac.value, widget.cut)),
            ),
          ),
        ),
      ]),
    );
  }
}

class _FlashPainter extends CustomPainter {
  final double a, cut;
  _FlashPainter(this.a, this.cut);
  @override
  void paint(Canvas canvas, Size size) {
    final p = HudBorder(cut: cut).getOuterPath(Rect.fromLTWH(1, 1, size.width - 2, size.height - 2));
    canvas.drawPath(p, Paint()
      ..color = const Color(0xFFCFE0FF).withOpacity(0.55 * a)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    canvas.drawPath(p, Paint()
      ..color = Colors.white.withOpacity(0.9 * a)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6);
  }

  @override
  bool shouldRepaint(_FlashPainter o) => o.a != a;
}

/// เปลี่ยนหน้าแบบสไลด์ + จางเข้า
Route<T> hudRoute<T>(Widget page) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 340),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, a, __, child) {
        final cv = CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        return FadeTransition(
          opacity: cv,
          child: SlideTransition(position: Tween<Offset>(begin: const Offset(0.08, 0), end: Offset.zero).animate(cv), child: child),
        );
      },
    );

/// เส้นสแกนจาง ๆ ในช่องค่า
class _ScanPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.white.withOpacity(0.022);
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), p);
    }
  }

  @override
  bool shouldRepaint(_ScanPainter o) => false;
}

Widget glowIconBtn(IconData ic, AppTheme th, VoidCallback f) => InkWell(
      onTap: f,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: hudDeco(border: th.c, width: 1.4, radius: 6, color: Colors.black45),
        child: Icon(ic, size: 20, color: th.c),
      ),
    );

// ---------- ตัวจัดการ BLE + GPS + Demo ----------
class GaugeController extends ChangeNotifier {
  Telemetry t = Telemetry();
  LinkState link = LinkState.idle;
  bool demo = false;
  bool gpsOk = false;
  double? gpsSpeed; // km/h
  double topSpeed = 0;
  final Map<String, List<double>> mm = {}; // ต่ำสุด/สูงสุดของแต่ละค่า
  String? error;

  BluetoothDevice? _dev;
  BluetoothCharacteristic? _cmd, _imgCh;
  StreamSubscription? _scanSub, _dataSub, _connSub, _gpsSub, _gnssSub;
  static const EventChannel _gnss = EventChannel('mfb/gnss'); // จำนวนดาวเทียมจริงจาก Android (MainActivity.kt ที่ workflow เติมให้)
  Timer? _demoTimer, _retryTimer, _gpsWatch;
  bool _auto = false;
  String? gaugeId, gaugeName; // เกจที่เลือกไว้ (ต่อใหม่อัตโนมัติเฉพาะตัวนี้ ไม่ไปต่อเกจคันอื่น)
  int _gpsSentMs = 0, _gpsLastMs = 0;
  bool _logoBusy = false;

  // ----- หน้า GRAPH: เก็บย้อนหลัง 60 วินาที (300 ตัวอย่าง ทุก 200 ms) + MIN/MAX ของ RPM / TPS / GPS / AFR -----
  // ----- สถานะ GPS / DRAG LOG -----
  int? satUsed, satTotal; // จำนวนดาวเทียมที่ใช้คำนวณตำแหน่ง / จำนวนที่เห็นทั้งหมด (อ่านจริงจาก Android GNSS)
  int satMax = 0; // จำนวนมากสุดที่เครื่องนี้เคยจับได้
  double? gpsAccM, spdAccKmh; // ความแม่นยำตำแหน่ง (m) / ความเร็ว (km/h)
  static const List<double> dragDist = [201, 402, 500, 1000];
  final List<DragRun> runs = List.generate(3, (_) => DragRun());
  int dragSel = 0;
  DragSt dragSt = DragSt.ready;
  double dragMeters = 0, dragSecs = 0;
  DateTime? _dTs;
  double _dPrev = 0, _dDist = 0, _dT = 0;
  int _dStill = 0;

  // ----- นาฬิกาจับเวลาแบบวิ่งจริง (ไม่ค้างรอ GPS) -----
  /// ความเร็วที่ถือว่า "ออกตัว" (เริ่มจับเวลาเมื่อความเร็วผ่านค่านี้ขึ้นไป)
  static const double dragStartKmh = 5.0;
  /// เวลาที่แสดงบนนาฬิกา (วินาที) อัปเดต ~60 ครั้ง/วินาที เฉพาะตัวเลขนาฬิกา ไม่วาดทั้งหน้าใหม่
  final ValueNotifier<double> dragClock = ValueNotifier<double>(0);
  final Stopwatch _dSw = Stopwatch(); // นาฬิกาเครื่อง (monotonic) ใช้แสดงเวลาวิ่งระหว่างรอค่า GPS ถัดไป
  double _dSwOffset = 0; // เวลาที่ผ่านไปแล้วตั้งแต่จุดออกตัว ณ ตอนเริ่ม stopwatch
  Timer? _dTick;
  double? _rPrevKmh; // ค่า GPS ก่อนหน้าในสถานะ READY (ใช้หาจังหวะผ่าน 5 km/h)
  DateTime? _rPrevTs;

  /// พร้อมออกตัว = ค่าล่าสุดยังต่ำกว่า 5 km/h (ถ้ากำลังวิ่งอยู่แล้วต้องชะลอให้ต่ำกว่า 5 ก่อน)
  bool get dragArmed => _rPrevKmh != null && _rPrevKmh! < dragStartKmh;

  void _clockStart(double elapsedAtStart) {
    _dSwOffset = elapsedAtStart;
    _dSw
      ..reset()
      ..start();
    _dTick?.cancel();
    _dTick = Timer.periodic(const Duration(milliseconds: 16), (_) {
      dragClock.value = _dSwOffset + _dSw.elapsedMicroseconds / 1e6;
    });
    dragClock.value = elapsedAtStart;
  }

  void _clockStop(double finalSecs) {
    _dTick?.cancel();
    _dTick = null;
    _dSw.stop();
    dragClock.value = finalSecs;
  }

  bool get dragFull => runs[dragSel].hasData && dragSt != DragSt.run;

  Future<void> _dragLoad() async {
    try {
      final p = await SharedPreferences.getInstance();
      satMax = p.getInt('satMax') ?? 0;
      final sv = p.getString('drag');
      if (sv != null) {
        final l = jsonDecode(sv) as List;
        for (int i = 0; i < 3 && i < l.length; i++) {
          runs[i] = DragRun.fromJson(l[i]);
        }
      }
      dragSel = runs.indexWhere((r) => !r.hasData);
      if (dragSel < 0) dragSel = 0;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveSatMax() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('satMax', satMax);
    } catch (_) {}
  }

  void _startGnss() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _gnssSub?.cancel();
    _gnssSub = _gnss.receiveBroadcastStream().listen((e) {
      if (demo) return; // DEMO จำลองดาวเทียมเอง
      if (e is Map) {
        satUsed = (e['used'] as num?)?.toInt();
        satTotal = (e['visible'] as num?)?.toInt();
        if (satTotal != null && satTotal! > satMax) {
          satMax = satTotal!;
          _saveSatMax();
        }
        notifyListeners();
      }
    }, onError: (_) {});
  }

  Future<void> _dragSave() async {
    if (demo) return; // รอบที่วิ่งใน DEMO ไม่บันทึกทับ LOG จริง
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('drag', jsonEncode(runs.map((r) => r.toJson()).toList()));
    } catch (_) {}
  }

  void selectRun(int i) {
    if (dragSt == DragSt.run) return;
    dragSel = i;
    notifyListeners();
  }

  /// ล้าง LOG ทั้ง 3 RUN (ค่าจะไม่ถูกลบจนกว่าจะกดปุ่มนี้)
  void resetDragLog() {
    for (final r in runs) {
      r.clear();
    }
    dragSel = 0;
    dragSt = DragSt.ready;
    dragMeters = 0;
    dragSecs = 0;
    _clockStop(0);
    _dragSave();
    notifyListeners();
  }

  void _dragFinish() {
    final run = runs[dragSel];
    final fin = run.t[3] ?? _dT; // ถึง 1000 m = เวลาที่ 1000 m พอดี, หยุดก่อน = เวลาล่าสุด
    dragSecs = fin;
    _clockStop(run.t[0] == null ? 0 : fin);
    if (run.t[0] == null) {
      run.clear(); // ยังไม่ถึงระยะแรก = ยกเลิก ไม่บันทึก
    } else {
      _dragSave();
      final nxt = runs.indexWhere((r) => !r.hasData);
      if (nxt >= 0) dragSel = nxt; // ขยับไป RUN ว่างถัดไป
    }
    dragSt = DragSt.done;
  }

  /// เรียกทุกครั้งที่ได้ค่า GPS ใหม่ : จับเวลา/ระยะจากความเร็ว GPS (ประมาณค่า เพื่อจัดหน้าตาก่อน)
  void _dragUpdate(double kmh, DateTime ts) {
    final run = runs[dragSel];
    switch (dragSt) {
      case DragSt.ready:
        final pv = _rPrevKmh, pt = _rPrevTs;
        if (!run.hasData && pv != null && pt != null && pv < dragStartKmh && kmh >= dragStartKmh) {
          // จังหวะผ่าน 5 km/h อยู่ระหว่างค่าก่อนหน้ากับค่านี้ -> ประมาณเวลาจริงด้วยเส้นตรง
          final gap = ts.difference(pt).inMicroseconds / 1e6;
          final f = (kmh - pv) <= 0 ? 1.0 : ((dragStartKmh - pv) / (kmh - pv)).clamp(0.0, 1.0).toDouble();
          final since = (gap > 0 && gap < 2.0) ? (1 - f) * gap : 0.0; // เวลาตั้งแต่จุดออกตัวถึงค่านี้
          dragSt = DragSt.run;
          _dT = since;
          _dDist = (dragStartKmh + kmh) / 2 / 3.6 * since;
          _dTs = ts;
          _dPrev = kmh;
          _dStill = 0;
          run.clear();
          run.maxKmh = kmh;
          dragMeters = _dDist;
          dragSecs = _dT;
          // ค่า GPS มาถึงแอพช้ากว่าเวลาจริงของจุดนั้นเล็กน้อย -> ชดเชยให้นาฬิกาเริ่มตรงเวลา (จำกัดไม่เกิน 1 วินาที กันนาฬิกาเครื่อง/GPS ไม่ตรงกัน)
          final lag = DateTime.now().difference(ts).inMicroseconds / 1e6;
          _clockStart(since + ((lag > 0 && lag < 1.0) ? lag : 0.0));
        }
        _rPrevKmh = kmh;
        _rPrevTs = ts;
        break;
      case DragSt.run:
        final dt = ts.difference(_dTs ?? ts).inMicroseconds / 1e6;
        if (dt <= 0) break;
        final d = (_dPrev / 3.6 + kmh / 3.6) / 2 * dt;
        final d0 = _dDist, t0 = _dT;
        _dDist += d;
        _dT += dt;
        for (int k = 0; k < 4; k++) {
          if (run.t[k] == null && _dDist >= dragDist[k]) {
            final f = d <= 0 ? 1.0 : ((dragDist[k] - d0) / d).clamp(0.0, 1.0).toDouble();
            run.t[k] = t0 + f * dt;
            run.v[k] = _dPrev + f * (kmh - _dPrev);
          }
        }
        if (kmh > run.maxKmh) run.maxKmh = kmh;
        _dTs = ts;
        _dPrev = kmh;
        dragMeters = _dDist;
        dragSecs = _dT;
        if (run.t[3] != null) {
          _dragFinish();
        } else if (kmh < 2) {
          if (++_dStill >= 3) _dragFinish();
        } else {
          _dStill = 0;
        }
        break;
      case DragSt.done:
        if (kmh < 2) {
          dragSt = DragSt.ready; // หยุดนิ่งแล้ว พร้อมรอบถัดไป
          _rPrevKmh = kmh;
          _rPrevTs = ts;
        }
        break;
    }
  }

  static const int gN = 300;
  final List<List<double>> gHist = List.generate(4, (_) => <double>[]);
  final List<double?> gMin = List<double?>.filled(4, null);
  final List<double?> gMax = List<double?>.filled(4, null);
  bool graphVisible = false;
  Timer? _gTimer;

  double? gVal(int i) {
    final live = t.fresh || demo;
    switch (i) {
      case 0: return live ? t.rpm : null;
      case 1: return live ? t.tps : null;
      case 2: return demo ? t.speed : (gpsOk ? gpsSpeed : null);
      default: return live ? t.afr : null;
    }
  }

  void _gSample() {
    for (int i = 0; i < 4; i++) {
      final v = gVal(i);
      final h = gHist[i];
      h.add(v ?? double.nan);
      if (h.length > gN) h.removeAt(0);
      if (v != null) {
        if (gMin[i] == null || v < gMin[i]!) gMin[i] = v;
        if (gMax[i] == null || v > gMax[i]!) gMax[i] = v;
      }
    }
    if (graphVisible) notifyListeners();
  }

  bool get ecuLive => link == LinkState.connected && t.fresh;

  /// ความเร็วกลางเกจ: สลับโหมด GPS / ECU ได้ (แตะที่ตัวเลขความเร็ว)
  double? get shownSpeed => demo ? t.speed : (Cfg.i.speedGps ? (gpsOk ? gpsSpeed : null) : t.speed);
  String get speedSrc => Cfg.i.speedGps ? 'GPS' : 'ECU';

  double? keyVal(int k) {
    switch (k) {
      case kTps: return t.tps;
      case kTemp: return t.ect;
      case kBatt: return t.batt;
      case kAfr: return t.afr;
      case kInj: return t.inj;
      case kIgn: return t.ign;
      case kRpm: return t.rpm;
      case kMap: return t.map;
      case kSpd: return shownSpeed;
      case kEot: return t.eot;
      case kIat: return t.iat;
      case kO2: return t.o2v;
      case kStft: return t.stft;
      case kLtft: return t.ltft;
      case kTop: return topSpeed;
    }
    return null;
  }

  Future<void> init() async {
    await WakelockPlus.enable();
    _gTimer?.cancel();
    _gTimer = Timer.periodic(const Duration(milliseconds: 200), (_) => _gSample());
    _dragLoad();
    await _startGps();
  }

  Future<void> _startGps() async {
    try {
      final perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      _startGnss();
      // Android: ใช้ GPS ตรง (LocationManager) และขอทุก 200 ms -> ได้ความเร็วเร็วที่สุดเท่าที่ชิป GPS ให้ (ปกติ ~1 Hz ขึ้นไป)
      final LocationSettings ls = defaultTargetPlatform == TargetPlatform.android
          ? AndroidSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: 0,
              intervalDuration: const Duration(milliseconds: 200),
              forceLocationManager: true,
            )
          : const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0);
      _gpsSub = Geolocator.getPositionStream(locationSettings: ls).listen((p) {
        if (demo) return; // DEMO ใช้ GPS จำลอง (ไม่ให้ GPS จริงที่จอดนิ่งมาทับ)
        gpsOk = true;
        _gpsLastMs = DateTime.now().millisecondsSinceEpoch;
        gpsSpeed = math.max(0.0, p.speed * 3.6);
        gpsAccM = p.accuracy;
        spdAccKmh = p.speedAccuracy > 0 ? p.speedAccuracy * 3.6 : null;
        _dragUpdate(gpsSpeed!, p.timestamp);
        _track();
        _sendGps();
        notifyListeners();
      }, onError: (_) {
        gpsOk = false;
        notifyListeners();
      });
      // ถ้าไม่มีข้อมูล GPS เกิน 4 วินาที ถือว่าสัญญาณหาย
      _gpsWatch?.cancel();
      _gpsWatch = Timer.periodic(const Duration(seconds: 1), (_) {
        if (gpsOk && DateTime.now().millisecondsSinceEpoch - _gpsLastMs > 4000) {
          gpsOk = false;
          if (dragSt == DragSt.run) {
            _dragFinish(); // สัญญาณ GPS หายกลางรอบ: หยุดนาฬิกา เก็บช่วงที่วัดได้
          }
          _rPrevKmh = null; // ต้องได้ค่าต่ำกว่า 5 km/h ใหม่ก่อนออกตัวรอบถัดไป
          notifyListeners();
        }
      });
    } catch (_) {}
  }

  /// ส่งความเร็ว GPS ไปบอร์ด TEST1: [3][u16 km/h x10] (ไม่รอตอบกลับ เพื่อให้เร็ว)
  void _sendGps() {
    final c = _cmd;
    final sp = gpsSpeed;
    if (demo || link != LinkState.connected || c == null || _logoBusy || sp == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _gpsSentMs < 120) return;
    _gpsSentMs = now;
    final v = (sp * 10).round().clamp(0, 65534).toInt();
    try {
      c.write([3, v & 255, (v >> 8) & 255], withoutResponse: c.properties.writeWithoutResponse).catchError((_) {});
    } catch (_) {}
  }

  void _mmUpdate(String k, double? v, {bool skipZero = false}) {
    if (v == null) return;
    if (skipZero && v <= 0) return;
    final cur = mm[k];
    if (cur == null) {
      mm[k] = [v, v];
    } else {
      if (v < cur[0]) cur[0] = v;
      if (v > cur[1]) cur[1] = v;
    }
  }

  // ยังไม่มีค่า / เพิ่งรีเซ็ต -> แสดง 0 (ไม่ซ่อน)
  String mnStr(String k) => mm[k] == null ? '0' : mm[k]![0].toStringAsFixed(0);
  String mxStr(String k) => mm[k] == null ? '0' : mm[k]![1].toStringAsFixed(0);

  void _track() {
    final s = shownSpeed;
    if (s != null && s > topSpeed) topSpeed = s;
    if (t.fresh || demo) {
      _mmUpdate('rpm', t.rpm, skipZero: true);
    }
  }

  void resetMinMax() {
    topSpeed = 0;
    mm.clear();
    for (int i = 0; i < 4; i++) {
      gMin[i] = null;
      gMax[i] = null;
    }
    notifyListeners();
  }

  // ----- BLE -----
  /// ขอสิทธิ์ + เปิดบลูทูธ + โหลดเกจที่เคยเลือก ; true = พร้อมสแกน
  Future<bool> prepareBle() async {
    if (demo) toggleDemo();
    error = null;
    await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {}
    }
    if (gaugeId == null) {
      try {
        final p = await SharedPreferences.getInstance();
        gaugeId = p.getString('gauge_id');
        gaugeName = p.getString('gauge_name');
      } catch (_) {}
    }
    return await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on;
  }

  /// สแกนหาเกจทุกตัวให้หน้าต่างเลือก (ผลอยู่ใน FlutterBluePlus.scanResults)
  Future<void> startPickScan() async {
    _retryTimer?.cancel();
    _auto = false;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      await FlutterBluePlus.startScan(withServices: [kSvc], timeout: const Duration(seconds: 10));
    } catch (_) {}
  }

  Future<void> stopPickScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  /// ต่อกับเกจที่ผู้ใช้เลือก แล้วจำไว้
  Future<void> connectTo(BluetoothDevice dev, String name) async {
    await stopPickScan();
    gaugeId = dev.remoteId.str;
    gaugeName = name;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('gauge_id', gaugeId!);
      await p.setString('gauge_name', name);
    } catch (_) {}
    _auto = true;
    error = null;
    await _open(dev);
  }

  /// ต่อใหม่อัตโนมัติ (หลุดเอง): หาเฉพาะเกจตัวที่เลือกไว้
  Future<void> _scanAndConnect() async {
    if (!_auto || gaugeId == null) return;
    link = LinkState.scanning;
    notifyListeners();
    await _scanSub?.cancel();
    final done = Completer<BluetoothDevice?>();
    _scanSub = FlutterBluePlus.scanResults.listen((rs) {
      for (final r in rs) {
        if (r.device.remoteId.str == gaugeId && !done.isCompleted) done.complete(r.device);
      }
    });
    try {
      await FlutterBluePlus.startScan(withServices: [kSvc], timeout: const Duration(seconds: 8));
    } catch (_) {}
    final dev = await done.future.timeout(const Duration(seconds: 9), onTimeout: () => null);
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _scanSub?.cancel();
    if (dev == null) {
      error = 'ไม่พบ ${gaugeName ?? 'เกจ'}';
      link = LinkState.idle;
      notifyListeners();
      _scheduleRetry();
      return;
    }
    await _open(dev);
  }

  Future<void> _open(BluetoothDevice dev) async {
    try {
      link = LinkState.connecting;
      notifyListeners();
      _dev = dev;
      await dev.connect(timeout: const Duration(seconds: 10));
      try {
        await dev.requestMtu(185);
      } catch (_) {}
      final services = await dev.discoverServices();
      final svc = services.firstWhere((s) => s.uuid == kSvc);
      final data = svc.characteristics.firstWhere((c) => c.uuid == kData);
      _cmd = svc.characteristics.firstWhere((c) => c.uuid == kCmd);
      _imgCh = null;
      for (final c in svc.characteristics) {
        if (c.uuid == kImg) _imgCh = c;
      }
      await data.setNotifyValue(true);
      await _dataSub?.cancel();
      _dataSub = data.onValueReceived.listen((v) {
        if (demo) return; // DEMO เปิดอยู่: ไม่เอาค่าจากบอร์ดมาทับ
        final p = Telemetry.parse(v);
        if (p != null) {
          t = p;
          _track();
          _dtcTrack();
          notifyListeners();
        }
      });
      await _connSub?.cancel();
      _connSub = dev.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          link = LinkState.idle;
          t = Telemetry();
          notifyListeners();
          _scheduleRetry();
        }
      });
      link = LinkState.connected;
      if (_dtcWanted) dtcRead(); // เปิดหน้า DTC ค้างไว้ตอนต่อ -> สั่งอ่านทันที
      notifyListeners();
    } catch (e) {
      error = 'เชื่อมต่อไม่สำเร็จ';
      link = LinkState.idle;
      notifyListeners();
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (_auto) _retryTimer = Timer(const Duration(seconds: 3), _scanAndConnect);
  }

  Future<void> disconnect() async {
    _auto = false;
    _retryTimer?.cancel();
    await _dataSub?.cancel();
    await _connSub?.cancel();
    try {
      await _dev?.disconnect();
    } catch (_) {}
    link = LinkState.idle;
    t = Telemetry();
    notifyListeners();
  }

  Future<void> sendCmd(List<int> bytes) async {
    try {
      await _cmd?.write(bytes, withoutResponse: false);
    } catch (_) {}
  }

  // ---- DTC (หน้า DTC): อ่าน/ลบโค้ดผ่านเกจ (FW 1.0.14) ----
  bool _dtcWanted = false;      // หน้า DTC เปิดอยู่ -> ให้เกจอ่าน DTC ต่อเนื่อง
  bool dtcReading = false;      // กด "อ่านโค้ด" แล้ว รอผลรอบใหม่
  bool _dtcSawInvalid = false;
  int _dtcReqMs = 0;
  DateTime? dtcLastRead;
  void dtcWatch(bool on) {
    if (_dtcWanted == on) return;
    _dtcWanted = on;
    if (on) {
      dtcRead();
    } else if (link == LinkState.connected) {
      sendCmd([4, 0]);
    }
  }

  void dtcRead() {
    if (demo) {
      dtcLastRead = DateTime.now();
      notifyListeners();
      return;
    }
    if (link != LinkState.connected) return;
    dtcReading = true;
    _dtcSawInvalid = false;
    _dtcReqMs = DateTime.now().millisecondsSinceEpoch;
    sendCmd([4, 2]);
    notifyListeners();
  }

  void dtcClear() {
    if (link != LinkState.connected) return;
    sendCmd([1]);
  }

  void _dtcTrack() {
    if (!t.dtcSup) return;
    if (dtcReading) {
      if (!t.dtcValid) {
        _dtcSawInvalid = true;
      } else if (_dtcSawInvalid) {
        dtcReading = false;
        dtcLastRead = DateTime.now();
      }
      if (DateTime.now().millisecondsSinceEpoch - _dtcReqMs > 9000) dtcReading = false;
    } else if (dtcLastRead == null && t.dtcValid) {
      dtcLastRead = DateTime.now();
    }
  }

  /// ส่งโลโก้ 320x240 RGB565 (153600 ไบต์) ไปเก็บในบอร์ด คืนค่า null = สำเร็จ, ข้อความ = error
  Future<String?> sendLogo(Uint8List data, void Function(double) onProgress) async {
    final ch = _imgCh;
    if (ch == null || link != LinkState.connected || _dev == null) {
      return 'ยังไม่ได้เชื่อมต่อบอร์ด หรือเฟิร์มแวร์ยังไม่รองรับการส่งโลโก้';
    }
    _logoBusy = true;
    try {
      final chunk = (_dev!.mtuNow - 4).clamp(16, 200).toInt();
      final n = data.length;
      await ch.write([1, n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255]);
      int sum = 0;
      for (int off = 0; off < n; off += chunk) {
        final end = math.min(n, off + chunk);
        final part = data.sublist(off, end);
        for (final b in part) {
          sum = (sum + b) & 0xFFFF;
        }
        await ch.write([2, ...part]);
        onProgress(end / n);
      }
      await ch.write([3, sum & 255, (sum >> 8) & 255]);
      for (int i = 0; i < 40; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (t.img == 2) return null;
        if (t.img == 3) return 'บอร์ดรับภาพไม่สำเร็จ ลองส่งใหม่อีกครั้ง';
      }
      return 'ไม่ได้รับการยืนยันจากบอร์ด';
    } catch (e) {
      return 'ส่งไม่สำเร็จ: $e';
    } finally {
      _logoBusy = false;
    }
  }

  /// ส่งไฟล์ BIN ไปเก็บในเกจ (เกจต้องอยู่หน้าเตรียมแฟลช) คืนค่า null = สำเร็จ, ข้อความ = error
  Future<String?> sendBin(Uint8List data, void Function(double) onProgress, {String name = '', int? startOff, int? ckOff}) async {
    final ch = _imgCh;
    if (ch == null || link != LinkState.connected || _dev == null) return 'ยังไม่ได้เชื่อมต่อเกจ';
    final f0 = t.fl;
    if (f0 == null) return 'เฟิร์มแวร์เกจยังไม่รองรับการแฟลช (ต้อง FW 1.0.10 ขึ้นไป)';
    if (!f0.prep) return 'เกจยังไม่อยู่หน้าเตรียมแฟลช';
    _logoBusy = true;
    try {
      final chunk = (_dev!.mtuNow - 4).clamp(16, 200).toInt();
      final n = data.length;
      // offset override ตาม ID กล่อง: แนบ marker 0x00 + start u32 + checksum u32 (เกจจะใช้แทน by-size)
      final over = (startOff != null && ckOff != null);
      // ชื่อไฟล์ (ASCII เท่านั้น) ให้เกจแสดง — เว้นที่ให้ offset เมื่อแนบมาด้วย
      final nm = [for (final u in name.codeUnits) (u >= 0x20 && u < 0x7F) ? u : 0x5F].take(over ? 20 : 32).toList();
      if (over) {
        await ch.write([
          0x21, n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255,
          0x00,
          startOff & 255, (startOff >> 8) & 255, (startOff >> 16) & 255, (startOff >> 24) & 255,
          ckOff & 255, (ckOff >> 8) & 255, (ckOff >> 16) & 255, (ckOff >> 24) & 255,
          ...nm,
        ]);
      } else {
        await ch.write([0x21, n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255, ...nm]);
      }
      int sum = 0;
      bool sawRecv = false;
      for (int off = 0; off < n; off += chunk) {
        final end = math.min(n, off + chunk);
        final part = data.sublist(off, end);
        for (final b in part) {
          sum = (sum + b) & 0xFFFF;
        }
        await ch.write([0x22, ...part]);
        onProgress(end / n);
        final f = t.fl;
        if (f != null && f.phase == 2) sawRecv = true;
        if (sawRecv && f != null && f.phase != 2 && f.err != 0) return 'เกจรับไฟล์ไม่สำเร็จ: ${flashErrText(f.err)}';
        if (link != LinkState.connected) return 'การเชื่อมต่อหลุดระหว่างส่งไฟล์';
      }
      await ch.write([0x23, sum & 255, (sum >> 8) & 255]);
      for (int i = 0; i < 60; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        final f = t.fl;
        if (f != null && f.phase != 2 && f.fileSize == n && f.fileSum == sum) return null;
        if (f != null && f.phase != 2 && f.err != 0) return 'เกจรับไฟล์ไม่สำเร็จ: ${flashErrText(f.err)}';
      }
      return 'ไม่ได้รับการยืนยันจากเกจ';
    } catch (e) {
      return 'ส่งไม่สำเร็จ: $e';
    } finally {
      _logoBusy = false;
    }
  }

  /// ล้างผลแฟลชครั้งก่อนในเกจ (DONE/FAIL -> READY)
  Future<void> clearFlash() => sendCmd([0x12]);

  /// สั่งเริ่มแฟลชจากมือถือ (FW 1.0.15): เกจเริ่มเฉพาะเมื่อขนาด + ผลรวมไบต์ตรงกับไฟล์ในเกจ และเงื่อนไขเดียวกับปุ่ม FLASH บนเกจ
  Future<String?> startFlash(int size, int sum16) async {
    if (link != LinkState.connected || _cmd == null) return 'ยังไม่ได้เชื่อมต่อเกจ';
    try {
      await sendCmd([0x13, size & 255, (size >> 8) & 255, (size >> 16) & 255, (size >> 24) & 255, sum16 & 255, (sum16 >> 8) & 255]);
      return null;
    } catch (e) {
      return 'ส่งคำสั่งไม่สำเร็จ: $e';
    }
  }

  Future<String?> resetLogo() async {
    final ch = _imgCh;
    if (ch == null || link != LinkState.connected) return 'ยังไม่ได้เชื่อมต่อบอร์ด';
    try {
      await ch.write([4]);
      return null;
    } catch (e) {
      return 'ส่งคำสั่งไม่สำเร็จ: $e';
    }
  }

  // ----- DEMO: จำลองการขี่ครบทุกค่า -----
  // ECU 14 ค่า (RPM, SPEED, W.TEMP, IAT, EOT, TPS, MAP, BATT, AFR, IGN, INJ, O2, STFT, LTFT)
  // + GPS (ความเร็ว, ความแม่นยำ, ดาวเทียม) + DRAG LOG (ออกตัว 5 km/h, นาฬิกา 0.0000, ระยะ 201/402/500/1000 m)
  // วนรอบละ 48 วินาที: จอดติดเครื่อง 5 s -> ออกตัวเต็มคันเร่ง 34 s (เกิน 1000 m, สูงสุด ~148 km/h) -> เบรกจนหยุด 9 s
  // LOG DRAG จริงถูกพักไว้ระหว่าง DEMO (ไม่บันทึกทับ) และคืนค่าเดิมเมื่อปิด DEMO
  static const double _demoCycle = 48.0;
  List<dynamic>? _demoRunsBak;
  int _demoSelBak = 0;

  void toggleDemo() {
    demo = !demo;
    _demoTimer?.cancel();
    if (demo) {
      _demoRunsBak = runs.map((r) => r.toJson()).toList();
      _demoSelBak = dragSel;
      for (final r in runs) {
        r.clear();
      }
      dragSel = 0;
      _dragResetLive();
      final rnd = math.Random();
      final sw = Stopwatch()..start();
      const vmax = 150 / 3.6, tau = 8.0; // m/s ; ค่าคงที่เวลาเร่ง (ออกตัวแบบรถสายพาน)
      double last = 0, v = 0, ect = 72, eot = 70, stft = 1.0;
      int tick = 0;
      _demoTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final now = sw.elapsedMicroseconds / 1e6;
        final dt = (now - last).clamp(0.0, 0.2).toDouble();
        last = now;
        final ph = now % _demoCycle;
        final wob = math.sin(now * 7.3); // สั่นเล็กน้อยให้ดูเหมือนจริง
        double tps, rpm;
        bool decel = false;
        if (ph < 5) {
          // จอดติดเครื่อง (เดินเบา)
          v = math.max(0.0, v - 6 * dt);
          tps = 0;
          rpm = 1550 + 40 * wob;
          // LOG เต็ม 3 RUN แล้ว -> ล้างก่อนออกตัวรอบใหม่ (เฉพาะ DEMO)
          if (ph > 4.5 && dragSt != DragSt.run && runs.every((r) => r.hasData)) {
            for (final r in runs) {
              r.clear();
            }
            dragSel = 0;
          }
        } else if (ph < 39) {
          // ออกตัวเต็มคันเร่ง: dv/dt = (vmax - v) / tau
          v += (vmax - v) / tau * dt;
          tps = math.max(0.0, 100 - 12 * v / vmax);
          rpm = 6800 + 2700 * v / vmax + 60 * wob;
        } else {
          // เบรก ~4.8 m/s²
          v = math.max(0.0, v - 4.8 * dt);
          tps = 0;
          decel = v > 1;
          rpm = decel ? 2300 + 3600 * v / vmax : 1600 + 40 * wob;
        }
        final spd = v * 3.6;
        final load = tps / 100;
        // อุณหภูมิค่อยๆ อุ่นเครื่องขึ้นจนคงที่
        ect += (90 + 2 * load - ect) * dt / 25;
        eot += (96 + 4 * load - eot) * dt / 35;
        final double afr = decel
            ? math.min(19.0, 17.2 + 1.8 * v / vmax)
            : (load > 0.5 ? 12.9 + 0.25 * wob : 14.4 + 0.35 * math.sin(now * 2.1));
        final double o2v = afr < 14.7 ? (0.82 - (afr - 12.5) * 0.04 + 0.02 * wob) : (0.14 + 0.04 * rnd.nextDouble());
        stft += ((afr < 14.7 ? 0.96 : 1.04) - stft) * dt * 0.8 + (rnd.nextDouble() - 0.5) * 0.004;
        stft = stft.clamp(0.9, 1.1).toDouble();
        final double inj = decel ? 0.55 : (load == 0 ? 1.45 + 0.05 * wob : 1.4 + 5.2 * load * (0.6 + 0.4 * rpm / 9500));
        final double ign = decel ? 30.0 : (load == 0 ? 12 + wob : (18 + 14 * ((rpm - 6000) / 3500).clamp(0.0, 1.0)).toDouble());
        final double map = decel ? 22 + 2 * wob : 30 + 68 * load + 1.5 * wob;
        t = Telemetry(
          fresh: true, state: 1, proto: 1, bike: t.bike, img: 0,
          rpm: rpm, speed: spd, ect: ect, iat: 33 + 3 * (1 - v / vmax), eot: eot,
          tps: tps, map: map, batt: rpm < 2000 ? 13.4 + 0.03 * wob : 14.1 + 0.05 * wob,
          afr: afr, ign: ign, inj: inj, o2v: o2v, stft: stft, ltft: 0.984 + 0.004 * math.sin(now * 0.05),
        );
        // GPS จำลอง 10 Hz (ทุก 2 รอบ) -> ป้อนหน้า DRAG LOG / GRAPH / ความเร็ว GPS
        if (++tick % 2 == 0) {
          gpsOk = true;
          _gpsLastMs = DateTime.now().millisecondsSinceEpoch;
          gpsSpeed = spd < 0.5 ? 0.0 : math.max(0.0, spd + (rnd.nextDouble() - 0.5) * 0.6);
          gpsAccM = 3.0 + rnd.nextDouble() * 1.5;
          spdAccKmh = 0.5 + rnd.nextDouble() * 0.4;
          satTotal = 26;
          satUsed = 17 + (2 * math.sin(now / 20)).round();
          _dragUpdate(gpsSpeed!, DateTime.now());
        }
        _track();
        notifyListeners();
      });
    } else {
      t = Telemetry();
      // คืนสถานะ GPS ให้ GPS จริงอัปเดตต่อ และคืน LOG DRAG เดิม
      gpsOk = false;
      gpsSpeed = null;
      gpsAccM = null;
      spdAccKmh = null;
      satUsed = null;
      satTotal = null;
      final bak = _demoRunsBak;
      if (bak != null) {
        for (int i = 0; i < runs.length && i < bak.length; i++) {
          runs[i] = DragRun.fromJson(bak[i]);
        }
        dragSel = _demoSelBak;
      }
      _demoRunsBak = null;
      _dragResetLive();
    }
    notifyListeners();
  }

  /// ล้างสถานะรอบที่กำลังวิ่ง/นาฬิกา (ไม่แตะ LOG ที่บันทึกแล้ว)
  void _dragResetLive() {
    dragSt = DragSt.ready;
    dragMeters = 0;
    dragSecs = 0;
    _rPrevKmh = null;
    _rPrevTs = null;
    _clockStop(0);
  }

  @override
  void dispose() {
    _demoTimer?.cancel();
    _retryTimer?.cancel();
    _scanSub?.cancel();
    _dataSub?.cancel();
    _connSub?.cancel();
    _gpsSub?.cancel();
    _gpsWatch?.cancel();
    _gnssSub?.cancel();
    _dTick?.cancel();
    dragClock.dispose();
    _gTimer?.cancel();
    super.dispose();
  }
}

// ======================= UI =======================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Cfg.i.load();
  await EcuDb.load(); // ฐานข้อมูล ID กล่อง -> รุ่น / offset (assets/ecm_database.json)
  // แนวนอนทั้งสองด้าน หมุนตามเซนเซอร์ (ตั้ง android:screenOrientation="sensorLandscape" ใน workflow)
  // ไม่เรียก setPreferredOrientations เพราะ Flutter จะตั้งเป็น USER_LANDSCAPE ซึ่งไม่หมุนเมื่อปิดหมุนจออัตโนมัติ
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const MfbProApp());
}

class MfbProApp extends StatelessWidget {
  const MfbProApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'MFB-PRO',
        theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black),
        home: const SplashPage(),
      );
}

// ---------- หน้าเปิดแอพ: โลโก้เลือนเข้า-ออก 4 วิ + แถบโหลด ----------
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});
  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> with SingleTickerProviderStateMixin {
  late final AnimationController ac = AnimationController(vsync: this, duration: const Duration(seconds: 4));
  late final Animation<double> fade = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeOut)), weight: 30),
    TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 40),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeIn)), weight: 30),
  ]).animate(ac);

  @override
  void initState() {
    super.initState();
    ac.forward().whenComplete(_go);
  }

  void _go() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 500),
      pageBuilder: (_, __, ___) => const HomePage(),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  @override
  void dispose() {
    ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        FadeTransition(opacity: fade, child: Image.asset('assets/splash.jpg', fit: BoxFit.cover)),
        Positioned(
          left: 0, right: 0, bottom: 18,
          child: Center(
            child: SizedBox(
              width: 280,
              child: AnimatedBuilder(
                animation: ac,
                builder: (_, __) => Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('LOADING  ${(ac.value * 100).round()}%',
                      style: const TextStyle(fontFamily: kFont, fontSize: 9, color: Colors.white, letterSpacing: 1)),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(value: ac.value, minHeight: 5, color: Colors.white, backgroundColor: Colors.white24),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

// ---------- เลือกค่าที่จะแสดงในช่อง (เหมือนเมนู SELECT ของ TEST1) ----------
Future<void> pickKey(BuildContext context, List<int> arr, int idx) {
  final th = Cfg.i.t;
  return showDialog<void>(
    context: context,
    barrierDismissible: true, // แตะนอกกรอบเพื่อปิด
    barrierColor: Colors.black.withOpacity(0.65),
    builder: (dctx) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(dctx).pop(),
      child: Center(
        child: GestureDetector(
          onTap: () {}, // แตะในกรอบไม่ปิด
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Material(
              color: Colors.transparent,
              child: Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                decoration: hudDeco(border: th.c, width: 1.3, radius: 15, color: const Color(0xF707080D)),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('SELECT', style: TextStyle(fontFamily: kFont, fontSize: 12, color: th.c)),
                    const Spacer(),
                    const Text('แตะนอกกรอบเพื่อปิด', style: TextStyle(fontSize: 10.5, color: Colors.white38)),
                  ]),
                  const SizedBox(height: 10),
                  LayoutBuilder(builder: (_, cs) {
                    final w = (cs.maxWidth - 6 * 4) / 5;
                    return Wrap(spacing: 6, runSpacing: 6, children: [
                      for (int k = 0; k < kKeys.length; k++)
                        InkWell(
                          onTap: () {
                            Cfg.i.setSlot(arr, idx, k);
                            Navigator.of(dctx).pop();
                          },
                          child: Container(
                            width: w,
                            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                            alignment: Alignment.center,
                            decoration: hudDeco(
                                border: arr[idx] == k ? th.c : Colors.white24, width: arr[idx] == k ? 1.4 : 1, radius: 7,
                                color: arr[idx] == k ? th.c.withOpacity(0.3) : Colors.black45, tick: false),
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Text(kKeys[k].name, style: const TextStyle(fontFamily: kFont, fontSize: 9)),
                              const SizedBox(height: 2),
                              Text(kKeys[k].th, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.white60)),
                            ]),
                          ),
                        ),
                    ]);
                  }),
                ]),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

// ---------- หน้าเกจหลัก (2 หน้า: GAUGE / GRID) ----------
// ---------- หน้าแรก: เลือกเมนู GAUGE / TUNE / FLASH (+ SETTING มุมขวาบน) ----------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final c = GaugeController(); // ตัวเดียวทั้งแอพ: BLE / GPS / DEMO ทำงานต่อเนื่องระหว่างเปลี่ยนหน้า

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    c.init();
    c.addListener(_rebuild);
    Cfg.i.addListener(_rebuild);
    AfrLog.i.attach(c);
    AfrLog.i.ensureDefault(); // หน้า AFR LOG ใช้แกนเริ่มต้น 29×25 ได้ทันที (จำลองด้วย DEMO)
  }

  @override
  void dispose() {
    Cfg.i.removeListener(_rebuild);
    c.removeListener(_rebuild);
    c.dispose();
    super.dispose();
  }

  void _open(Widget page) => Navigator.of(context).push(hudRoute(page));

  Widget _card(AppTheme th, IconData ic, String name, String desc, String sub, VoidCallback f) => Expanded(
        child: GestureDetector(
          onTap: f,
          child: Container(
            decoration: hudDeco(border: th.c, width: 1.6, radius: 16, gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xE60B1430), Color(0xE605060B)])),
            child: Stack(children: [
              Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(ic, size: 64, color: th.c, shadows: [Shadow(color: th.c, blurRadius: 12)]),
                  const SizedBox(height: 10),
                  Text(name, style: TextStyle(fontFamily: kFont, fontSize: 22, color: Colors.white, shadows: [Shadow(color: th.c, blurRadius: 10)])),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(desc, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Colors.white70)),
                  ),
                ]),
              ),
              Positioned(
                left: 0, right: 0, bottom: 10,
                child: Text(sub, textAlign: TextAlign.center, style: const TextStyle(fontFamily: kFont, fontSize: 8, color: Colors.white38)),
              ),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final th = Cfg.i.t;
    final fw = c.t.fwText;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        Image.asset('assets/bg.jpg', fit: BoxFit.cover),
        Container(color: Colors.black.withOpacity(0.55)),
        const HudGrid(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Column(children: [
              Row(children: [
                mfbLogo(th),
                const SizedBox(width: 12),
                Expanded(child: statusChips(c)),
                glowIconBtn(Icons.settings, th, () => _open(SettingsPage(c: c))),
              ]),
              const SizedBox(height: 12),
              Expanded(
                child: Row(children: [
                  _card(th, Icons.speed, 'GAUGE', 'เกจวัด · ดูค่าเครื่องยนต์ · DTC', 'LIVE DATA', () => _open(GaugePage(c: c))),
                  const SizedBox(width: 14),
                  _card(th, Icons.tune, 'TUNE', 'จูนตาราง XDF / BIN · คลังไฟล์', 'MAP EDITOR', () => _open(TunePage(c: c))),
                  const SizedBox(width: 14),
                  _card(th, Icons.bolt, 'FLASH', 'แฟลชกล่อง ECU ผ่านเกจ', 'KEIHIN · SHINDENGEN', () => _open(FlashPage(c: c))),
                  const SizedBox(width: 14),
                  _card(th, Icons.menu_book, 'CUSTOMER', 'สมุดลูกค้า · ประวัติแฟลช', 'BOOK', () => _open(CustomerPage(c: c))),
                ]),
              ),
              const SizedBox(height: 6),
              Row(children: [
                const Text('APP $kAppVer', style: TextStyle(fontFamily: kFont, fontSize: 8, color: Colors.white38)),
                const Spacer(),
                Text(fw == null ? 'GAUGE FW --' : 'GAUGE FW $fw', style: const TextStyle(fontFamily: kFont, fontSize: 8, color: Colors.white38)),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}

class GaugePage extends StatefulWidget {
  final GaugeController c;
  const GaugePage({super.key, required this.c});
  @override
  State<GaugePage> createState() => _GaugePageState();
}

class _GaugePageState extends State<GaugePage> with SingleTickerProviderStateMixin {
  GaugeController get c => widget.c;
  // เปิดหน้า: เข็มกวาด 0 → สุด → 0 (~1.7 วิ) แล้ววิ่งตามค่าจริง
  late final AnimationController sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 1700))..forward();
  double get _sweepFrac {
    final t = sweep.value;
    if (t < 0.12) return 0;
    if (t < 0.52) return Curves.easeInOutCubic.transform((t - 0.12) / 0.40);
    return 1 - Curves.easeInOutCubic.transform((t - 0.52) / 0.48);
  }

  final pc = PageController();
  int page = 0;
  Size _afrSz = Size.zero;

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    c.addListener(_rebuild);
    Cfg.i.addListener(_rebuild);
  }

  @override
  void dispose() {
    Cfg.i.removeListener(_rebuild);
    c.removeListener(_rebuild);
    c.graphVisible = false;
    c.dtcWatch(false); // ออกจากหน้า GAUGE: หยุดให้เกจอ่าน DTC
    sweep.dispose();
    pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = Cfg.i;
    final th = cfg.t;
    final t = c.t;
    final blinkOn = (DateTime.now().millisecondsSinceEpoch ~/ 280) % 2 == 0;
    final shiftOn = t.rpm != null && t.rpm! >= cfg.shift;
    final pages = [_mainPage(th, blinkOn), _gridPage(th, blinkOn), _graphPage(th), _afrPage(th), _dragPage(th), _dtcPage(th)];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        Image.asset('assets/bg.jpg', fit: BoxFit.cover),
        Container(color: Colors.black.withOpacity(0.55)),
        const HudGrid(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
            child: Column(children: [
              Row(children: [
                glowIconBtn(Icons.arrow_back, th, () => Navigator.of(context).pop()), // กลับหน้าแรก
                const SizedBox(width: 10),
                mfbLogo(th),
                const SizedBox(width: 12),
                Expanded(child: statusChips(c)),
                _btn('DEMO', c.toggleDemo, th, active: c.demo),
              ]),
              const SizedBox(height: 6),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: PageView(
                    controller: pc,
                    onPageChanged: (i) {
                      c.graphVisible = i == 2;
                      c.dtcWatch(i == 5); // หน้า DTC: ให้เกจอ่านโค้ดต่อเนื่อง
                      setState(() => page = i);
                    },
                    children: [
                      for (int i = 0; i < pages.length; i++)
                        AnimatedBuilder(
                          animation: pc,
                          builder: (_, child) {
                            final pg = pc.hasClients && pc.position.haveDimensions ? (pc.page ?? page.toDouble()) : page.toDouble();
                            return Opacity(opacity: (1 - (pg - i).abs() * 0.75).clamp(0.0, 1.0).toDouble(), child: child);
                          },
                          child: pages[i],
                        ),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
        // ตัวบอกหน้า: สี่เหลี่ยมแนวนอน + ชื่อหน้า
        Positioned(
          left: 0, right: 0, bottom: 3,
          child: IgnorePointer(
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (int i = 0; i < 6; i++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == page ? 24 : 14, height: 5,
                  decoration: BoxDecoration(
                    color: i == page ? th.c : Colors.white30,
                    borderRadius: BorderRadius.circular(1.5),
                    boxShadow: i == page ? [BoxShadow(color: th.c, blurRadius: 6)] : null,
                  ),
                ),
              const SizedBox(width: 8),
              Text(const ['GAUGE', 'GRID', 'GRAPH', 'AFR LOG', 'DRAG LOG', 'DTC'][page], style: const TextStyle(fontFamily: kFont, fontSize: 7, color: Colors.white54)),
            ]),
          ),
        ),
        // แสงเตือน SHIFT: แดงฟุ้งจากขอบทั้ง 4 เข้ากลางจอ กระพริบ
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: shiftOn ? (blinkOn ? 1.0 : 0.15) : 0.0,
              duration: const Duration(milliseconds: 120),
              child: CustomPaint(painter: EdgeGlowPainter()),
            ),
          ),
        ),
      ]),
    );
  }

  // ----- หน้า 1: เกจ -----
  // ซ้าย 3 + ขวา 3 ช่องเท่ากัน ; ความกว้างช่องคำนวณจากขนาดเกจ ให้ยาวเกือบชิดหน้าปัด
  static const double _rpmTileH = 68;
  static double _gaugeR(double h) => math.max(60.0, (h - _rpmTileH - 6) / 1.70);
  Widget _mainPage(AppTheme th, bool blinkOn) {
    final m = Cfg.i.main;
    return LayoutBuilder(builder: (_, cs) {
      final r = _gaugeR(cs.maxHeight);
      final sw = ((cs.maxWidth - (2 * r + 8)) / 2 - 8).clamp(130.0, 280.0).toDouble();
      return Row(children: [
        SizedBox(
          width: sw,
          child: Column(children: [
            for (int i = 0; i < 3; i++) Expanded(child: _slotTile(m[i], () => pickKey(context, m, i), blinkOn)),
          ]),
        ),
        const SizedBox(width: 8),
        Expanded(child: LayoutBuilder(builder: (_, cc) => _center(cc, th, blinkOn))),
        const SizedBox(width: 8),
        SizedBox(
          width: sw,
          child: Column(children: [
            for (int i = 3; i < 6; i++) Expanded(child: _slotTile(m[i], () => pickKey(context, m, i), blinkOn)),
          ]),
        ),
      ]);
    });
  }

  // ----- หน้า 2: GRID 12 ช่อง -----
  Widget _gridPage(AppTheme th, bool blinkOn) {
    final g = Cfg.i.grid;
    return Column(children: [
      for (int r = 0; r < 3; r++)
        Expanded(
          child: Row(children: [
            for (int k = 0; k < 4; k++)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: k < 3 ? 6 : 0),
                  child: _slotTile(g[r * 4 + k], () => pickKey(context, g, r * 4 + k), blinkOn, vs: 36),
                ),
              ),
          ]),
        ),
    ]);
  }

  // ----- หน้า 4: DRAG LOG (จัดหน้าตาก่อน) -----
  Widget _frame(AppTheme th, Widget child, {EdgeInsets pad = const EdgeInsets.all(8)}) => Container(
        padding: pad,
        decoration: hudDeco(border: th.c.withOpacity(0.85), width: 1.1, radius: 12, color: const Color(0xCC060606)),
        child: child,
      );


  // ----- หน้า AFR LOG (ก่อน DRAG): ตาราง RPM×TPS เหมือน XDF, จำลองด้วย DEMO -----
  Widget _afrPage(AppTheme th) {
    final log = AfrLog.i;
    final live = c.demo || c.ecuLive;
    return _frame(
      th,
      Column(children: [
        Row(children: [
          Text('AFR LOG', style: TextStyle(fontFamily: kFont, fontSize: 12, color: th.c, shadows: [Shadow(color: th.c, blurRadius: 8)])),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                log.ready
                    ? '${log.rows}×${log.cols} · ${log.src} · ${log.filled} ช่อง'
                    : 'ยังไม่มีตาราง',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: live ? Colors.white70 : kAmber)),
          ),
          _afrMini(log.rec ? '● REC' : '❚❚', log.rec ? kGreen : kAmber, log.ready ? log.toggleRec : null),
          const SizedBox(width: 6),
          _afrMini('ล้าง', th.c,
              log.ready
                  ? () async {
                      if (await askYes(context, 'ล้าง AFR LOG', 'ลบค่าที่บันทึกไว้ทั้งหมด?', ok: 'ล้าง', col: kBad)) log.clear();
                    }
                  : null),
        ]),
        const SizedBox(height: 6),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: log.ready
                ? LayoutBuilder(builder: (_, cs) {
                    final h = _AfrPainter.hh + log.rows * _AfrPainter.rh;
                    _afrSz = Size(cs.maxWidth, h);
                    return SingleChildScrollView(
                      child: GestureDetector(
                        onTapUp: (dd) => _afrTap(dd.localPosition),
                        child: CustomPaint(size: Size(cs.maxWidth, h), painter: _AfrPainter(log, th)),
                      ),
                    );
                  })
                : const Center(child: Text('ยังไม่มีตาราง', style: TextStyle(color: Colors.white54))),
          ),
        ),
        const SizedBox(height: 4),
        Row(children: [
          Container(
            width: 120, height: 7,
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                gradient: LinearGradient(colors: [for (int k = 0; k <= 10; k++) _afrColor(11.5 + k * 0.5)])),
          ),
          const SizedBox(width: 6),
          const Text('11.5 หนา · 14.7 · 16.5 บาง', style: TextStyle(fontSize: 10, color: Colors.white60)),
          const Spacer(),
          const Text('กรอบขาว = ตำแหน่งตอนนี้ · แตะช่องดูค่า', style: TextStyle(fontSize: 10, color: Colors.white54)),
        ]),
      ]),
    );
  }

  Widget _afrMini(String t, Color col, VoidCallback? f) => InkWell(
        onTap: f,
        borderRadius: BorderRadius.circular(7),
        child: Opacity(
          opacity: f == null ? 0.4 : 1,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: hudDeco(border: col, width: 1.2, radius: 7, color: Colors.black45),
            child: Text(t, style: TextStyle(fontSize: 12, color: col, fontWeight: FontWeight.bold)),
          ),
        ),
      );

  void _afrTap(Offset p) {
    final log = AfrLog.i;
    if (!log.ready) return;
    final g = _AfrPainter.geom(_afrSz, log.rows, log.cols);
    final cc = ((p.dx - g.$1) / g.$3).floor(), r = ((p.dy - g.$2) / g.$4).floor();
    if (r < 0 || cc < 0 || r >= log.rows || cc >= log.cols) return;
    final v = log.at(r, cc);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 2),
          content: Text('RPM ${log.rpm[r].toStringAsFixed(0)} · TPS ${log.tps[cc].toStringAsFixed(1)} : '
              '${v == null ? 'ยังไม่มีข้อมูล' : 'AFR ${v.toStringAsFixed(2)} (${log.cnt[r][cc]} ครั้ง)'}')));
  }

  Widget _dragPage(AppTheme th) {
    final run = c.runs[c.dragSel];
    final sp = c.demo ? c.t.speed : (c.gpsOk ? c.gpsSpeed : null);
    // สีสัญญาณ GPS: ดาวเทียม >= 15 ดวง = เขียว (ถ้ายังไม่มีจำนวนดาวเทียมจริง ใช้ความแม่นยำตำแหน่งแทนไปก่อน)
    Color gpsCol;
    if (c.satUsed != null) {
      gpsCol = c.satUsed! >= 15 ? kGreen : (c.satUsed! >= 8 ? kAmber : kBad);
    } else if (!c.gpsOk) {
      gpsCol = kBad;
    } else {
      final a = c.gpsAccM ?? 99;
      gpsCol = a <= 10 ? kGreen : (a <= 25 ? kAmber : kBad);
    }
    final acc = c.spdAccKmh == null ? '--' : c.spdAccKmh!.round().toString();
    final stTxt = c.dragSt == DragSt.run ? 'RUNNING' : (c.dragFull ? 'RUN ${c.dragSel + 1} FULL' : (c.dragSt == DragSt.done ? 'DONE' : 'READY'));
    final stCol = c.dragSt == DragSt.run ? kAmber : (c.dragFull ? kBad : (c.dragSt == DragSt.done ? th.c : kGreen));
    const lab = TextStyle(fontSize: 13, color: Colors.white70);

    return Column(children: [
      _frame(
        th,
        Row(children: [
          Icon(Icons.signal_cellular_alt, color: gpsCol, size: 22),
          const SizedBox(width: 4),
          Text('GPS', style: TextStyle(fontFamily: kFont, fontSize: 12, color: gpsCol, shadows: [Shadow(color: gpsCol, blurRadius: 8)])),
          const SizedBox(width: 16),
          Text('Satellites in use: ${c.satUsed ?? '--'} of ${c.satTotal ?? '--'}', style: lab),
          if (c.satMax > 0) Text('  (max ${c.satMax})', style: const TextStyle(fontSize: 11, color: Colors.white38)),
          const SizedBox(width: 16),
          Text('Speed ${sp == null ? '--' : sp.round()} ± $acc km/h', style: lab),
          const Spacer(),
          Text(stTxt, style: TextStyle(fontFamily: kFont, fontSize: 11, color: stCol, shadows: [Shadow(color: stCol, blurRadius: 8)])),
        ]),
        pad: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      ),
      const SizedBox(height: 6),
      Expanded(
        child: Row(children: [
          Expanded(flex: 3, child: _frame(th, _splitTable(th, run))),
          const SizedBox(width: 6),
          Expanded(flex: 2, child: _frame(th, _dragControls(th, run))),
        ]),
      ),
      const SizedBox(height: 6),
      _speedTacho(th, sp),
    ]);
  }

  Widget _splitTable(AppTheme th, DragRun run) {
    Widget cell(String s, {bool head = false, bool right = true, Color? col, double size = 15}) => Align(
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(s,
                style: TextStyle(
                    fontFamily: kFont,
                    fontSize: head ? 9 : size,
                    color: head ? Colors.white54 : (col ?? Colors.white),
                    shadows: head || col == null ? null : [Shadow(color: col, blurRadius: 8)])),
          ),
        );
    Widget row(Widget a, Widget b, Widget d, {bool last = false}) => Expanded(
          child: Container(
            decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: Colors.white12))),
            child: Row(children: [
              Expanded(flex: 4, child: a),
              Expanded(flex: 4, child: b),
              Expanded(flex: 4, child: d),
            ]),
          ),
        );
    String tm(double? v) => v == null ? '--' : '${v.toStringAsFixed(4)} s';
    String kh(double? v) => v == null ? '--' : '${v.round()} km/h';
    return Column(children: [
      row(cell('DIST', head: true, right: false), cell('TIME', head: true), cell('SPEED', head: true)),
      for (int i = 0; i < 4; i++)
        row(cell('${GaugeController.dragDist[i].round()}m', right: false, col: th.c), cell(tm(run.t[i])), cell(kh(run.v[i]))),
      row(cell('MAX SPEED', right: false, size: 13, col: th.c), cell(''), cell(run.maxKmh > 0 ? '${run.maxKmh.round()} KM/H' : '-- KM/H'), last: true),
    ]);
  }

  Widget _dragControls(AppTheme th, DragRun run) {
    final running = c.dragSt == DragSt.run;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('LOG RUN', style: TextStyle(fontFamily: kFont, fontSize: 9, color: Colors.white54)),
      const SizedBox(height: 6),
      Row(children: [
        for (int i = 0; i < 3; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i < 2 ? 6 : 0),
              child: InkWell(
                onTap: () => c.selectRun(i),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  alignment: Alignment.center,
                  decoration: hudDeco(border: c.dragSel == i ? th.c : Colors.white24, width: c.dragSel == i ? 1.6 : 1, radius: 6, color: c.dragSel == i ? th.c.withOpacity(0.3) : Colors.black45),
                  child: Text('RUN ${i + 1}${c.runs[i].hasData ? ' ●' : ''}', style: const TextStyle(fontFamily: kFont, fontSize: 9)),
                ),
              ),
            ),
          ),
      ]),
      Expanded(
        child: Center(
          child: running || (c.dragSt == DragSt.done && c.dragClock.value > 0)
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  // นาฬิกาวิ่งจริง 0.0000 (อัปเดต ~60 ครั้ง/วินาที เฉพาะตัวเลขนี้) | จบรอบ = ค้างเวลาสุดท้าย
                  ValueListenableBuilder<double>(
                    valueListenable: c.dragClock,
                    builder: (_, v, __) => FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _monoNum('${v.toStringAsFixed(4)} s',
                          TextStyle(fontFamily: kFont, fontSize: 26, color: Colors.white, shadows: [Shadow(color: th.c, blurRadius: 10)])),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(running ? '${c.dragMeters.round()} m' : 'DONE · ${c.dragMeters.round()} m',
                      style: const TextStyle(fontSize: 14, color: Colors.white70)),
                ])
              : Text(
                  c.dragFull
                      ? 'RUN ${c.dragSel + 1} มีข้อมูลแล้ว\nเลือก RUN อื่น หรือกด RESET LOG'
                      : (c.dragArmed
                          ? 'รอออกตัว… (เริ่มจับเวลาเมื่อเกิน ${GaugeController.dragStartKmh.round()} km/h)'
                          : 'ชะลอให้ต่ำกว่า ${GaugeController.dragStartKmh.round()} km/h\nเพื่อเตรียมออกตัว'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.white54)),
        ),
      ),
      InkWell(
        onTap: running ? null : _confirmReset,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          alignment: Alignment.center,
          decoration: hudDeco(border: kBad, width: 1.4, radius: 6, color: Colors.black45),
          child: const Text('RESET LOG', style: TextStyle(fontFamily: kFont, fontSize: 10, color: kBad)),
        ),
      ),
    ]);
  }

  /// ตัวเลขกว้างคงที่ทีละตัว: ฟอนต์ Ethnocentric ตัวเลขกว้างไม่เท่ากัน ("1" แคบ) -> ถ้าไม่ล็อกความกว้าง นาฬิกาจะสั่นซ้ายขวาตอนวิ่ง
  Widget _monoNum(String s, TextStyle st) {
    final fs = st.fontSize ?? 14;
    double w(String ch) => ch == '.' ? fs * 0.42 : (ch == ' ' ? fs * 0.3 : (RegExp(r'[0-9]').hasMatch(ch) ? fs * 1.0 : fs * 0.9));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final ch in s.split(''))
        SizedBox(width: w(ch), child: Text(ch, textAlign: TextAlign.center, softWrap: false, overflow: TextOverflow.visible, style: st)),
    ]);
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF14141A),
        title: const Text('RESET LOG', style: TextStyle(fontFamily: kFont, fontSize: 14)),
        content: const Text('ลบ LOG ทั้ง 3 RUN ใช่หรือไม่?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(false), child: const Text('ยกเลิก')),
          TextButton(onPressed: () => Navigator.of(dctx).pop(true), child: const Text('ลบทั้งหมด', style: TextStyle(color: kBad))),
        ],
      ),
    );
    if (ok == true) c.resetDragLog();
  }

  /// TACHO SPEED 0-240 ไล่สีเขียว -> เหลือง -> แดง
  Widget _speedTacho(AppTheme th, double? sp) {
    final frac = ((sp ?? 0) / 240).clamp(0.0, 1.0).toDouble();
    const n = 48;
    return _frame(
      th,
      Row(children: [
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              height: 14,
              child: Row(children: [
                for (int i = 0; i < n; i++)
                  Expanded(
                    child: Builder(builder: (_) {
                      final pos = (i + 0.5) / n;
                      final lit = pos <= frac;
                      final col = rpmColor(pos * 240, 240);
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        decoration: BoxDecoration(
                          color: lit ? col : Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(2),
                          boxShadow: lit ? [BoxShadow(color: col.withOpacity(0.6), blurRadius: 5)] : null,
                        ),
                      );
                    }),
                  ),
              ]),
            ),
            const SizedBox(height: 3),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              for (int k = 0; k <= 240; k += 40) Text('$k', style: const TextStyle(fontFamily: kFont, fontSize: 8, color: Colors.white54)),
            ]),
          ]),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 96,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text('${sp == null ? '--' : sp.round()} km/h',
                style: TextStyle(fontFamily: kFont, fontSize: 18, color: Colors.white, shadows: [Shadow(color: th.c, blurRadius: 9)])),
          ),
        ),
      ]),
      pad: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    );
  }

  // ----- หน้า 3: GRAPH (4 ช่อง แตะเพื่อเปิด/ปิดเส้นกราฟ ค่ายังแสดงในช่องเหมือนเดิม) -----
  static const _gNames = ['RPM', 'TPS', 'GPS', 'AFR'];
  static const _gTh = ['รอบเครื่อง', 'ลิ้นเร่ง', 'ความเร็ว GPS', 'อากาศ : น้ำมัน'];

  // ----- หน้า 6: DTC อ่านโค้ด / ลบโค้ด (ผ่านเกจ, เฉพาะกล่อง Honda) -----
  Widget _dtcPage(AppTheme th) {
    final t = c.t;
    final conn = c.link == LinkState.connected;
    final demo = c.demo;
    final cur = demo ? const [[7, 1]] : t.dtcCur;
    final sto = demo ? const [[21, 1], [12, 1]] : t.dtcSto;
    final valid = demo || t.dtcValid;
    String? msg;
    Color msgCol = Colors.white70;
    if (demo) {
      msg = null;
    } else if (!conn) {
      msg = 'ยังไม่ได้เชื่อมต่อเกจ';
      msgCol = kAmber;
    } else if (!t.dtcSup) {
      msg = 'เฟิร์มแวร์เกจยังไม่รองรับ DTC ผ่านแอพ — อัปเดตเป็น FW 1.0.14 ขึ้นไป';
      msgCol = kAmber;
    } else if (t.proto != 1) {
      msg = 'อ่าน/ลบโค้ดได้เฉพาะกล่อง HONDA (K-LINE)';
      msgCol = kAmber;
    } else if (!t.fresh) {
      msg = 'ไม่มีการเชื่อมต่อกับกล่อง ECU';
      msgCol = kBad;
    } else if (c.dtcReading || !valid) {
      msg = 'กำลังอ่านโค้ดจากกล่อง ECU…';
      msgCol = th.c2;
    } else if (t.dtcClear == 1) {
      msg = 'กำลังลบโค้ด…';
      msgCol = th.c2;
    } else if (t.dtcClear == 3) {
      msg = 'ลบโค้ดไม่สำเร็จ (ลองบิดกุญแจ OFF-ON แล้วลบใหม่)';
      msgCol = kBad;
    } else if (cur.isEmpty && sto.isEmpty) {
      msg = t.dtcClear == 2 ? 'ลบโค้ดเรียบร้อย — ไม่พบโค้ด' : 'ไม่พบโค้ด (NO CODES)';
      msgCol = kGreen;
    }
    final canAct = demo || (conn && t.dtcSup && t.proto == 1 && t.fresh);
    final last = c.dtcLastRead;
    String lastTxt = '--';
    if (last != null) {
      final sec = DateTime.now().difference(last).inSeconds;
      lastTxt = sec < 60 ? '${sec}s' : '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
    }

    Widget row(List<int> d, bool now) {
      final col = now ? kBad : kAmber;
      final desc = dtcDesc(d[0], d[1]);
      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: hudDeco(border: col.withOpacity(0.55), radius: 8, color: col.withOpacity(0.10)),
        child: Row(children: [
          Container(width: 9, height: 9, decoration: BoxDecoration(color: col, shape: BoxShape.circle, boxShadow: [BoxShadow(color: col, blurRadius: 6)])),
          const SizedBox(width: 10),
          Text('${d[0].toString().padLeft(2, '0')}-${d[1].toString().padLeft(2, '0')}',
              style: TextStyle(fontFamily: kFont, fontSize: 13, color: Colors.white, shadows: [Shadow(color: col, blurRadius: 6)])),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(desc?.$2 ?? 'ไม่รู้จักโค้ดนี้', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              Text(desc?.$1 ?? 'Unknown code', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(color: col.withOpacity(0.25), borderRadius: BorderRadius.circular(4)),
            child: Text(now ? 'NOW' : 'PAST', style: TextStyle(fontFamily: kFont, fontSize: 8, color: col)),
          ),
        ]),
      );
    }

    Widget bigBtn(String en, String thTxt, IconData ic, Color col, VoidCallback? f, {bool filled = false}) => Opacity(
          opacity: f == null ? 0.4 : 1,
          child: GestureDetector(
            onTap: f,
            child: Container(
              decoration: hudDeco(border: col, width: 1.4, radius: 11, color: filled ? col.withOpacity(0.28) : Colors.black54),
              child: Container(
                alignment: Alignment.center,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(ic, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(en, style: TextStyle(fontFamily: kFont, fontSize: 12, color: Colors.white, shadows: [Shadow(color: col, blurRadius: 8)])),
                    Text(thTxt, style: const TextStyle(fontSize: 11, color: Colors.white70)),
                  ]),
                ]),
              ),
            ),
          ),
        );

    return Row(children: [
      SizedBox(
        width: 210,
        child: Column(children: [
          Expanded(
            child: Row(children: [
              Expanded(child: StatTile(th: th, label: 'NOW', thLabel: 'ปัจจุบัน', unit: 'CODES', value: valid ? '${cur.length}' : '--', valueColor: cur.isEmpty ? null : kBad, valueSize: 26)),
              const SizedBox(width: 6),
              Expanded(child: StatTile(th: th, label: 'PAST', thLabel: 'เคยเกิด', unit: 'CODES', value: valid ? '${sto.length}' : '--', valueColor: sto.isEmpty ? null : kAmber, valueSize: 26)),
            ]),
          ),
          Expanded(child: StatTile(th: th, label: 'LAST READ', thLabel: 'อ่านล่าสุด', unit: 'AGO', value: demo ? '3s' : lastTxt, valueSize: 22)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: bigBtn('READ', 'อ่านโค้ด', Icons.search, th.c, canAct && !c.dtcReading ? c.dtcRead : null, filled: true),
            ),
          ),
          Expanded(
            child: bigBtn('CLEAR', 'ลบโค้ด', Icons.delete_sweep, kBad, canAct && t.dtcClear != 1
                ? () async {
                    if (await askYes(context, 'ลบโค้ด DTC', 'ลบโค้ดทั้งหมดในกล่อง ECU?\nควรดับเครื่องยนต์ (บิดกุญแจ ON) ก่อนลบ', ok: 'ลบโค้ด', col: kBad)) c.dtcClear();
                  }
                : null),
          ),
        ]),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _frame(
          th,
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('DTC', style: TextStyle(fontFamily: kFont, fontSize: 13, color: th.c, shadows: [Shadow(color: th.c, blurRadius: 8)])),
              const SizedBox(width: 10),
              const Expanded(child: Text('รหัสปัญหาจากกล่อง ECU (HONDA)', style: TextStyle(fontSize: 12, color: Colors.white60))),
              if (c.dtcReading) SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: th.c)),
            ]),
            const SizedBox(height: 8),
            Expanded(
              child: msg != null && (cur.isEmpty && sto.isEmpty || !valid || c.dtcReading || !canAct)
                  ? Center(child: Text(msg, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: msgCol, fontWeight: FontWeight.bold)))
                  : ListView(children: [
                      if (msg != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(msg, style: TextStyle(fontSize: 12, color: msgCol))),
                      for (final d in cur) row(d, true),
                      for (final d in sto) row(d, false),
                    ]),
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _graphPage(AppTheme th) {
    final cfg = Cfg.i;
    return Column(children: [
      SizedBox(
        height: 78,
        child: Row(children: [
          for (int i = 0; i < 4; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i < 3 ? 6 : 0),
                child: _graphBox(i, (cfg.graphOn & (1 << i)) != 0),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 6),
      Expanded(
        child: Container(
          decoration: hudDeco(border: th.c.withOpacity(0.85), width: 1.1, radius: 12, color: const Color(0xCC060606)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: CustomPaint(painter: GraphPainter(hist: c.gHist, on: cfg.graphOn), size: Size.infinite),
          ),
        ),
      ),
    ]);
  }

  Widget _graphBox(int i, bool on) {
    final col = GraphPainter.cols[i];
    final v = c.gVal(i);
    final dec = (i == 1 || i == 3) ? 1 : 0;
    String f(double? x) => x == null ? '0' : x.toStringAsFixed(dec);
    return GestureDetector(
      onTap: () => Cfg.i.toggleGraph(i),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 4),
        decoration: hudDeco(border: on ? col : Colors.white24, width: on ? 1.6 : 1.0, radius: 12, color: const Color(0xCC060606)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Flexible(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: _gNames[i], style: TextStyle(fontFamily: kFont, fontSize: 11, color: on ? col : Colors.white38)),
                  TextSpan(text: '  ${_gTh[i]}', style: TextStyle(fontSize: 11, color: on ? Colors.white60 : Colors.white30)),
                ]),
                maxLines: 1, overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(on ? Icons.show_chart : Icons.visibility_off, size: 13, color: on ? col : Colors.white30),
          ]),
          Expanded(
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(v == null ? '--' : v.toStringAsFixed(dec),
                    style: TextStyle(fontFamily: kFont, fontSize: 22, color: Colors.white, shadows: [Shadow(color: col, blurRadius: 8)])),
              ),
            ),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text.rich(TextSpan(children: [
              const TextSpan(text: '▼ ', style: TextStyle(color: kGreen, fontSize: 8)),
              TextSpan(text: f(c.gMin[i]), style: const TextStyle(color: kGreen, fontSize: 11)),
            ])),
            Text.rich(TextSpan(children: [
              const TextSpan(text: '▲ ', style: TextStyle(color: kBad, fontSize: 8)),
              TextSpan(text: f(c.gMax[i]), style: const TextStyle(color: kBad, fontSize: 11)),
            ])),
          ]),
        ]),
      ),
    );
  }

  /// ช่วงเต็มแท่ง (ต่ำสุด, สูงสุด) ของช่องที่ใช้แถบสีธีม
  static const _barRange = <int, (double, double)>{
    kInj: (0.0, 15.0), kIgn: (0.0, 50.0), kMap: (0.0, 110.0), kSpd: (0.0, 180.0), kTop: (0.0, 180.0),
    kO2: (0.0, 1.0), kStft: (0.5, 1.5), kLtft: (0.5, 1.5),
  };
  static double _frac(double? v, double lo, double hi) => v == null ? 0.0 : ((v - lo) / (hi - lo)).clamp(0.0, 1.0).toDouble();

  /// สร้างช่องค่าจากคีย์: สี/บาร์/กระพริบตามกฎ
  Widget _slotTile(int key, VoidCallback onTap, bool blinkOn, {double vs = 30, double bm = 6}) {
    final kd = kKeys[key];
    final cfg = Cfg.i;
    final v = c.keyVal(key);
    final s = v == null ? '--' : v.toStringAsFixed(kd.dec);
    Color? vc;
    double? bar;
    Color Function(double)? bc;
    bool alert = false;
    switch (key) {
      case kTps:
        vc = kTpsBlue;
        bar = v == null ? 0.0 : (v / 100).clamp(0.0, 1.0).toDouble();
        bc = (_) => kTpsBlue;
        break;
      case kAfr:
        final col = v == null ? kAfrOk : afrColor(v);
        if (v != null) vc = col;
        bar = v == null ? 0.0 : ((v - 10) / 8).clamp(0.0, 1.0).toDouble();
        bc = (_) => col;
        break;
      case kRpm:
        bar = v == null ? 0.0 : (v / kMaxRpm).clamp(0.0, 1.0).toDouble();
        bc = (p) => rpmColor(p * kMaxRpm, cfg.shift);
        break;
      case kBatt:
        vc = kBattRed;
        bar = _frac(v, 10, 15);
        bc = (_) => kBattRed;
        break;
      case kTemp:
      case kEot:
      case kIat:
        alert = key != kIat && v != null && v >= cfg.tempWarn;
        final hi = key == kTemp ? 120.0 : (key == kEot ? 150.0 : 80.0);
        bar = _frac(v, 0, hi);
        bc = (p) => tempBarColor(p * hi, cfg.tempWarn.toDouble());
        break;
      default:
        // ช่องอื่น ๆ: แถบสีธีม ช่วงเต็มแท่งตามชนิดค่า
        final r = _barRange[key];
        if (r != null) {
          bar = _frac(v, r.$1, r.$2);
          bc = (_) => cfg.t.c;
        }
    }
    return StatTile(
      th: cfg.t, label: kd.name, unit: kd.unit, value: s, valueColor: vc, thLabel: kd.th,
      alert: alert, blinkOn: blinkOn, bar: bar, barColor: bc, onTap: onTap, valueSize: vs, bottomMargin: bm,
    );
  }

  // เกจกลาง: ความเร็ว (แตะสลับ GPS/ECU) อยู่กลางเกจ, RPM อยู่ใต้เกจ
  Widget _center(BoxConstraints cs, AppTheme th, bool blinkOn) {
    final cfg = Cfg.i;
    final w = cs.maxWidth, h = cs.maxHeight;
    const tileH = _rpmTileH;
    final r = math.max(60.0, math.min(w / 2 - 4, _gaugeR(h))); // เกจใหญ่ขึ้น: ช่อง RPM เตี้ยลงและชิดเกจขึ้น
    final cx = w / 2, cy = r + 4;
    final rpm = c.t.rpm;
    final frac = rpm == null ? 0.0 : (rpm / kMaxRpm).clamp(0.0, 1.0).toDouble();
    final sp = c.shownSpeed;
    final tileW = math.min(math.max(r * 1.5, 150.0), 230.0);

    return Stack(children: [
      Positioned.fill(
        child: AnimatedBuilder(
          animation: sweep,
          builder: (_, __) => sweep.isAnimating
              ? CustomPaint(painter: GaugePainter(frac: _sweepFrac, r: r, th: th, shift: cfg.shift))
              : TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: frac),
                  duration: const Duration(milliseconds: 300),
                  builder: (_, v, __) => CustomPaint(painter: GaugePainter(frac: v, r: r, th: th, shift: cfg.shift)),
                ),
        ),
      ),
      Positioned(
        left: cx - r * 0.5, width: r, top: cy - r * 0.34, height: r * 0.72,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: cfg.toggleSpeed,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: RollNum(sp == null ? '--' : sp.toStringAsFixed(0),
                    style: TextStyle(
                        fontFamily: kFont, fontSize: 60, color: Colors.white,
                        shadows: [Shadow(color: th.c, blurRadius: 14), Shadow(color: th.c.withOpacity(0.7), blurRadius: 4)])),
              ),
            ),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text('km/h · ${c.speedSrc}', style: TextStyle(fontSize: math.max(10.0, r * 0.085), color: th.c2, fontWeight: FontWeight.bold)),
              const SizedBox(width: 3),
              Icon(Icons.swap_horiz, size: math.max(12.0, r * 0.1), color: th.c2),
            ]),
          ]),
        ),
      ),
      Positioned(
        left: cx - tileW / 2, width: tileW, top: cy + 0.70 * r, height: tileH,
        // ช่องใต้เกจ: แตะเพื่อเลือกค่า (RPM = มี ▼ต่ำสุด / ▲สูงสุด)
        child: cfg.center[0] == kRpm
            ? StatTile(
                th: th, label: 'RPM', thLabel: 'รอบเครื่อง', unit: 'rpm', value: rpm == null ? '--' : rpm.toStringAsFixed(0),
                bar: frac, barColor: (p) => rpmColor(p * kMaxRpm, cfg.shift),
                mn: c.mnStr('rpm'), mx: c.mxStr('rpm'), bottomMargin: 0, valueSize: 22,
                onTap: () => pickKey(context, cfg.center, 0),
              )
            : _slotTile(cfg.center[0], () => pickKey(context, cfg.center, 0), blinkOn, vs: 22, bm: 0),
      ),
    ]);
  }

  Widget _btn(String s, VoidCallback f, AppTheme th, {bool active = false}) => InkWell(
        onTap: f,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: hudDeco(border: th.c, width: 1.4, radius: 6, color: active ? th.c.withOpacity(0.3) : Colors.black45),
          child: Text(s, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        ),
      );

}

// ---------- กราฟ 4 เส้น (RPM / TPS / GPS / AFR) ----------
class GraphPainter extends CustomPainter {
  final List<List<double>> hist;
  final int on;
  GraphPainter({required this.hist, required this.on});

  static const cols = <Color>[Color(0xFFFF3B3B), kTpsBlue, Color(0xFF3CFF8A), Color(0xFFFFC233)];

  static double norm(int i, double v) {
    double lo = 0, hi = 1;
    switch (i) {
      case 0: hi = kMaxRpm; break;
      case 1: hi = 100; break;
      case 2: hi = 180; break;
      default: lo = 10; hi = 18;
    }
    return ((v - lo) / (hi - lo)).clamp(0.0, 1.0).toDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 10.0;
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    for (int k = 0; k <= 4; k++) {
      final y = pad + (size.height - 2 * pad) * k / 4;
      canvas.drawLine(Offset(pad, y), Offset(size.width - pad, y), grid);
    }
    final step = (size.width - 2 * pad) / (GaugeController.gN - 1);
    for (int i = 0; i < 4; i++) {
      if ((on & (1 << i)) == 0) continue;
      final h = hist[i];
      final n = h.length;
      final path = Path();
      bool pen = false;
      for (int j = 0; j < n; j++) {
        final v = h[j];
        if (v.isNaN) {
          pen = false;
          continue;
        }
        final x = size.width - pad - (n - 1 - j) * step;
        final y = size.height - pad - norm(i, v) * (size.height - 2 * pad);
        if (!pen) {
          path.moveTo(x, y);
          pen = true;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = cols[i].withOpacity(0.55)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      canvas.drawPath(
          path,
          Paint()
            ..color = cols[i]
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeJoin = StrokeJoin.round);
    }
  }

  @override
  bool shouldRepaint(GraphPainter o) => true;
}

// ---------- แสงเตือนแดงจากขอบ 4 ด้าน ----------
class EdgeGlowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final d = math.min(size.width, size.height) * 0.32;
    void edge(Rect r, Alignment a, Alignment b) {
      canvas.drawRect(
          r,
          Paint()
            ..shader = LinearGradient(begin: a, end: b, colors: const [Color(0xE6FF1A1A), Color(0x00FF1A1A)]).createShader(r));
    }

    edge(Rect.fromLTWH(0, 0, size.width, d), Alignment.topCenter, Alignment.bottomCenter);
    edge(Rect.fromLTWH(0, size.height - d, size.width, d), Alignment.bottomCenter, Alignment.topCenter);
    edge(Rect.fromLTWH(0, 0, d, size.height), Alignment.centerLeft, Alignment.centerRight);
    edge(Rect.fromLTWH(size.width - d, 0, d, size.height), Alignment.centerRight, Alignment.centerLeft);
  }

  @override
  bool shouldRepaint(EdgeGlowPainter o) => false;
}

// ---------- บาร์แท่งเซกเมนต์ ----------
class SegBar extends StatelessWidget {
  final double frac;
  final Color Function(double) color;
  final int n;
  const SegBar({super.key, required this.frac, required this.color, this.n = 24});

  @override
  Widget build(BuildContext context) => SizedBox(height: 7, width: double.infinity, child: CustomPaint(painter: _SegPainter(frac, color, n)));
}

/// แท่งเซกเมนต์ทรงเอียง: ช่องที่ติดเรืองแสงตามสี, ช่องปลายสีขาว, ช่องที่ยังไม่ติดเป็นกรอบจาง
class _SegPainter extends CustomPainter {
  final double frac;
  final Color Function(double) color;
  final int n;
  _SegPainter(this.frac, this.color, this.n);
  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height, sl = h * 0.55, gap = 2.4;
    final w = (size.width - sl - gap * (n - 1)) / n;
    int last = -1;
    for (int i = 0; i < n; i++) {
      if ((i + 0.5) / n <= frac) last = i;
    }
    for (int i = 0; i < n; i++) {
      final x = i * (w + gap);
      final path = Path()
        ..moveTo(x + sl, 0)
        ..lineTo(x + sl + w, 0)
        ..lineTo(x + w, h)
        ..lineTo(x, h)
        ..close();
      if (i <= last) {
        final col = i == last ? Colors.white : color((i + 0.5) / n);
        canvas.drawPath(path, Paint()
          ..color = col.withOpacity(0.55)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5));
        canvas.drawPath(path, Paint()..color = col);
      } else {
        canvas.drawPath(path, Paint()..color = Colors.white.withOpacity(0.05));
        canvas.drawPath(path, Paint()
          ..color = Colors.white.withOpacity(0.11)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8);
      }
    }
  }

  @override
  bool shouldRepaint(_SegPainter o) => o.frac != frac || o.n != n || o.color != color;
}

// ---------- กรอบแสดงค่า ----------
class StatTile extends StatelessWidget {
  final AppTheme th;
  final String label, unit, value;
  final Color? valueColor;
  final bool alert, blinkOn;
  final double? bar;
  final Color Function(double)? barColor;
  final String? mn, mx;
  final VoidCallback? onTap;
  final double bottomMargin, valueSize;
  final String thLabel; // ชื่อภาษาไทยต่อท้ายชื่อ (ว่าง = ไม่แสดง)
  const StatTile({
    super.key, required this.th, required this.label, required this.unit, required this.value,
    this.valueColor, this.alert = false, this.blinkOn = false, this.bar, this.barColor,
    this.mn, this.mx, this.onTap, this.bottomMargin = 6, this.valueSize = 30, this.thLabel = '',
  });

  @override
  Widget build(BuildContext context) {
    final active = alert && blinkOn; // กรอบกระพริบแดงเมื่อค่าเกินที่ตั้ง
    final col = active ? kBad : th.c;
    final vcol = alert ? kBad : (valueColor ?? Colors.white);
    final glow = alert ? kBad : (valueColor ?? th.c);
    return GestureDetector(
      onTap: onTap,
      child: Padding(
       padding: EdgeInsets.only(bottom: bottomMargin),
       child: TapFlash(
        enabled: onTap != null,
        child: Container(
        decoration: ShapeDecoration(
          gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xF50D1018), Color(0xF5050507)]),
          shape: HudBorder(cut: 11, side: BorderSide(color: col.withOpacity(active ? 1.0 : 0.9), width: active ? 2.0 : 1.2), tick: false),
          shadows: [BoxShadow(color: col.withOpacity(active ? 0.85 : 0.10), blurRadius: active ? 18 : 6, spreadRadius: 0.5)],
        ),
        child: Stack(children: [
          Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _ScanPainter()))),
          Positioned(
            top: 3, left: 16,
            child: Container(
              width: 30, height: 2,
              decoration: BoxDecoration(color: col, boxShadow: [BoxShadow(color: col, blurRadius: 6)]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 5),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Flexible(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: label, style: const TextStyle(fontFamily: kFont, fontSize: 11, color: Colors.white)),
                      if (thLabel.isNotEmpty) TextSpan(text: '  $thLabel', style: const TextStyle(fontSize: 11, color: Colors.white60)),
                    ]),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(unit, style: const TextStyle(fontFamily: kFont, fontSize: 8, color: Colors.white38)),
              ]),
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: RollNum(value,
                        style: TextStyle(
                            fontFamily: kFont, fontSize: valueSize, color: vcol,
                            shadows: [Shadow(color: glow, blurRadius: 9), Shadow(color: glow.withOpacity(0.6), blurRadius: 3)])),
                  ),
                ),
              ),
              if (bar != null && barColor != null) SegBar(frac: bar!, color: barColor!),
              if (mn != null && mx != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text.rich(TextSpan(children: [
                      const TextSpan(text: '▼ ', style: TextStyle(color: kGreen, fontSize: 9)),
                      TextSpan(text: mn!, style: const TextStyle(color: kGreen, fontSize: 12)),
                    ])),
                    Text.rich(TextSpan(children: [
                      const TextSpan(text: '▲ ', style: TextStyle(color: kBad, fontSize: 9)),
                      TextSpan(text: mx!, style: const TextStyle(color: kBad, fontSize: 12)),
                    ])),
                  ]),
                ),
            ]),
          ),
        ]),
       ),
       ),
      ),
    );
  }
}

// ---------- เกจ RPM สไตล์แท่งเซกเมนต์ + เข็ม + ตัวเลข 0-15 ----------
class GaugePainter extends CustomPainter {
  final double frac, r;
  final AppTheme th;
  final int shift;
  GaugePainter({required this.frac, required this.r, required this.th, required this.shift});

  static const zoneRed = Color(0x59FF2A2A); // แดงโปร่งใสตายตัว (ท้ายแท่ง)

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, r + 4);
    const start = 0.75 * math.pi, sweep = 1.5 * math.pi;
    const n = 44;
    final thick = r * 0.13;
    final rect = Rect.fromCircle(center: c, radius: r - thick / 2);
    final seg = sweep / n;

    for (int i = 0; i < n; i++) {
      final pos = (i + 0.5) / n;
      final inZone = pos * kMaxRpm >= shift;
      final lit = pos <= frac;
      final a0 = start + seg * i + seg * 0.1;
      final segCol = rpmColor(pos * kMaxRpm, shift); // เขียว -> เหลือง -> แดง
      final col = lit ? segCol : (inZone ? zoneRed : Colors.white.withOpacity(0.13));
      if (lit) {
        canvas.drawArc(rect, a0, seg * 0.8, false,
            Paint()
              ..color = segCol.withOpacity(0.7)
              ..style = PaintingStyle.stroke
              ..strokeWidth = thick
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      }
      canvas.drawArc(rect, a0, seg * 0.8, false,
          Paint()
            ..color = col
            ..style = PaintingStyle.stroke
            ..strokeWidth = thick);
    }

    // แสงขาวปลายแถบ (ช่องสุดท้ายที่ติด) วิ่งตามเข็ม — เรืองเบา ๆ
    {
      final li = (frac * n - 0.5).floor();
      if (li >= 0) {
        final a0 = start + seg * li + seg * 0.1, am = a0 + seg * 0.4;
        final pt = c + Offset(math.cos(am), math.sin(am)) * (r - thick / 2);
        canvas.drawCircle(pt, thick * 1.1, Paint()
          ..shader = RadialGradient(colors: [Colors.white.withOpacity(0.45), Colors.white.withOpacity(0)])
              .createShader(Rect.fromCircle(center: pt, radius: thick * 1.1)));
        canvas.drawArc(rect, a0, seg * 0.8, false, Paint()
          ..color = Colors.white.withOpacity(0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = thick
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
        canvas.drawArc(rect, a0, seg * 0.8, false, Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = thick);
        for (int k = 1; k <= 2 && li - k >= 0; k++) {
          final b0 = start + seg * (li - k) + seg * 0.1;
          canvas.drawArc(rect, b0, seg * 0.8, false, Paint()
            ..color = Colors.white.withOpacity(0.25 / k)
            ..style = PaintingStyle.stroke
            ..strokeWidth = thick);
        }
      }
    }

    // วงนอกบาง + ขีดละเอียดทุก 250 rpm
    {
      final ro = r + 3;
      canvas.drawArc(Rect.fromCircle(center: c, radius: ro), start, sweep, false, Paint()
        ..color = th.c.withOpacity(0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
      for (int k = 0; k <= 60; k++) {
        final ang = start + sweep * k / 60;
        final d = Offset(math.cos(ang), math.sin(ang));
        final big = k % 4 == 0;
        canvas.drawLine(c + d * ro, c + d * (ro + (big ? 5 : 3)), Paint()
          ..color = Colors.white.withOpacity(big ? 0.55 : 0.18)
          ..strokeWidth = big ? 1.4 : 0.8);
      }
    }

    // วงสเกลด้านใน + โซนแดงเริ่มที่ SHIFT RPM
    final r2 = r * 0.80;
    final rect2 = Rect.fromCircle(center: c, radius: r2);
    canvas.drawArc(rect2, start, sweep, false,
        Paint()
          ..color = Colors.white.withOpacity(0.16)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);
    final zs = (shift / kMaxRpm).clamp(0.0, 1.0).toDouble();
    if (zs < 1.0) {
      canvas.drawArc(rect2, start + sweep * zs, sweep * (1 - zs), false,
          Paint()
            ..color = const Color(0xFFFF2A2A)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.6
            ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 2));
    }
    // เส้นความคืบหน้าบาง ๆ สีธีม วิ่งตามเข็ม (ด้านในวงสเกล)
    if (frac > 0) {
      final ri = Rect.fromCircle(center: c, radius: r2 - 4);
      canvas.drawArc(ri, start, sweep * frac, false, Paint()
        ..color = th.c.withOpacity(0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      canvas.drawArc(ri, start, sweep * frac, false, Paint()
        ..color = th.c
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round);
    }

    // ขีดและตัวเลข 0..15
    for (int k = 0; k <= 15; k++) {
      final ang = start + sweep * k / 15;
      final dir = Offset(math.cos(ang), math.sin(ang));
      final zone = k * 1000 >= shift;
      canvas.drawLine(c + dir * (r2 - r * 0.05), c + dir * r2,
          Paint()
            ..color = zone ? const Color(0xFFFF2A2A) : Colors.white70
            ..strokeWidth = 1.6);
      final tp = TextPainter(
        text: TextSpan(
            text: '$k',
            style: TextStyle(fontFamily: kFont, fontSize: r * 0.072, color: zone ? const Color(0xFFFF7A7A) : Colors.white.withOpacity(0.9))),
        textDirection: TextDirection.ltr,
      )..layout();
      final pos = c + dir * (r * 0.64);
      tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
    }

    // วงในแบบ HUD: เส้นประจาง ๆ + ขีดสีธีม 4 มุม (ล้อมตัวเลขความเร็ว)
    {
      final rh = r * 0.46;
      final dash = Paint()
        ..color = Colors.white.withOpacity(0.18)
        ..strokeWidth = 1;
      const nd = 72;
      for (int k = 0; k < nd; k++) {
        final a0 = 2 * math.pi * k / nd;
        canvas.drawArc(Rect.fromCircle(center: c, radius: rh), a0, 2 * math.pi / nd * 0.35, false, dash..style = PaintingStyle.stroke);
      }
      final corner = Paint()
        ..color = th.c.withOpacity(0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      for (final q in [-0.25, 0.25, 0.75, 1.25]) {
        canvas.drawArc(Rect.fromCircle(center: c, radius: rh), q * math.pi - 0.16, 0.32, false, corner);
      }
    }

    // เข็มทรงเรียว: โคนกว้าง ปลายแหลม + เรืองสีธีม + จุดขาวที่ปลาย
    final ang = start + sweep * frac;
    final dir = Offset(math.cos(ang), math.sin(ang));
    final nrm = Offset(-dir.dy, dir.dx);
    final p1 = c + dir * (r * 0.48), p2 = c + dir * (r * 0.80);
    const w0 = 3.2;
    Path needle(double w) => Path()
      ..moveTo((p1 + nrm * w).dx, (p1 + nrm * w).dy)
      ..lineTo(p2.dx, p2.dy)
      ..lineTo((p1 - nrm * w).dx, (p1 - nrm * w).dy)
      ..close();
    canvas.drawPath(needle(w0 * 1.6), Paint()
      ..color = th.c.withOpacity(0.9)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    canvas.drawPath(needle(w0), Paint()..color = Colors.white);
    canvas.drawCircle(p2, 1.8, Paint()..color = Colors.white);
    canvas.drawCircle(p2, 3.5, Paint()
      ..color = Colors.white.withOpacity(0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
  }

  @override
  bool shouldRepaint(GaugePainter o) => o.frac != frac || o.r != r || o.th != th || o.shift != shift;
}

// ---------- ปุ่ม - / + กดค้างเพื่อเพิ่ม/ลดต่อเนื่อง ----------
class StepBtn extends StatefulWidget {
  final String label;
  final VoidCallback onStep;
  final AppTheme th;
  const StepBtn({super.key, required this.label, required this.onStep, required this.th});
  @override
  State<StepBtn> createState() => _StepBtnState();
}

class _StepBtnState extends State<StepBtn> {
  Timer? _t;

  void _stop() {
    _t?.cancel();
    _t = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onStep,
      onLongPressStart: (_) {
        widget.onStep();
        _t = Timer.periodic(const Duration(milliseconds: 90), (_) => widget.onStep());
      },
      onLongPressEnd: (_) => _stop(),
      onLongPressCancel: _stop,
      child: Container(
        width: 38, height: 34,
        alignment: Alignment.center,
        decoration: hudDeco(border: widget.th.c, width: 1.4, radius: 6, color: Colors.black45),
        child: Text(widget.label, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: widget.th.c, height: 1.1)),
      ),
    );
  }
}

// ---------- หน้า SETTING ----------
class SettingsPage extends StatefulWidget {
  final GaugeController c;
  const SettingsPage({super.key, required this.c});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int sec = 0; // เมนูย่อย: 0 CONNECT 1 ECU INFO 2 THEME 3 ALERT 4 LOGO 5 FIRMWARE
  ui.Image? preview;
  Uint8List? raw565;
  double? progress;
  String? msg;
  bool busy = false;

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    Cfg.i.addListener(_rebuild);
    widget.c.addListener(_rebuild);
  }

  @override
  void dispose() {
    Cfg.i.removeListener(_rebuild);
    widget.c.removeListener(_rebuild);
    super.dispose();
  }

  Future<void> _pick() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1280);
      final src = (await codec.getNextFrame()).image;

      // ครอปแบบ cover ให้พอดี 320x240 ตามจอบอร์ด
      const w = 320.0, h = 240.0;
      final rec = ui.PictureRecorder();
      final cv = Canvas(rec);
      cv.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black);
      final sw = src.width.toDouble(), sh = src.height.toDouble();
      final sc = math.max(w / sw, h / sh);
      final dw = sw * sc, dh = sh * sc;
      cv.drawImageRect(src, Rect.fromLTWH(0, 0, sw, sh), Rect.fromLTWH((w - dw) / 2, (h - dh) / 2, dw, dh),
          Paint()..filterQuality = FilterQuality.high);
      final out = await rec.endRecording().toImage(320, 240);
      final bd = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) return;
      final rgba = bd.buffer.asUint8List();
      final b = Uint8List(320 * 240 * 2);
      for (int i = 0; i < 320 * 240; i++) {
        final r = rgba[i * 4], g = rgba[i * 4 + 1], bl = rgba[i * 4 + 2];
        final v = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (bl >> 3);
        b[i * 2] = v & 0xFF;
        b[i * 2 + 1] = (v >> 8) & 0xFF;
      }
      setState(() {
        preview = out;
        raw565 = b;
        msg = null;
        progress = null;
      });
    } catch (e) {
      setState(() => msg = 'เลือกรูปไม่สำเร็จ: $e');
    }
  }

  Future<void> _send() async {
    if (raw565 == null || busy) return;
    setState(() {
      busy = true;
      progress = 0;
      msg = null;
    });
    final err = await widget.c.sendLogo(raw565!, (p) {
      if (mounted) setState(() => progress = p);
    });
    if (!mounted) return;
    setState(() {
      busy = false;
      progress = null;
      msg = err ?? 'ส่งโลโก้สำเร็จ — จะแสดงตอนเปิดบอร์ดครั้งถัดไป';
    });
  }

  Future<void> _reset() async {
    if (busy) return;
    final err = await widget.c.resetLogo();
    if (!mounted) return;
    setState(() => msg = err ?? 'คืนค่าโลโก้เดิมของบอร์ดแล้ว');
  }

  static const _menu = <(IconData, String, String)>[
    (Icons.bluetooth, 'CONNECT', 'เชื่อมต่อ'),
    (Icons.info, 'ECU INFO', 'ข้อมูลกล่อง'),
    (Icons.palette, 'THEME', 'ธีมสี'),
    (Icons.notifications, 'ALERT', 'แจ้งเตือน'),
    (Icons.image, 'LOGO', 'โลโก้เกจ'),
    (Icons.memory, 'FIRMWARE', 'เฟิร์มแวร์'),
  ];

  Widget _menuItem(AppTheme th, int i) {
    final m = _menu[i];
    final on = sec == i;
    return GestureDetector(
      onTap: () => setState(() => sec = i),
      child: Container(
        height: 40,
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: hudDeco(border: on ? th.c : th.c.withOpacity(0.6), width: 1.2, radius: 9, color: on ? th.c : Colors.black54),
        child: Row(children: [
          Icon(m.$1, size: 18, color: on ? Colors.white : th.c),
          const SizedBox(width: 10),
          Text(m.$2, style: const TextStyle(fontFamily: kFont, fontSize: 10, color: Colors.white)),
          const Spacer(),
          Text(m.$3, style: TextStyle(fontSize: 11, color: on ? Colors.white70 : Colors.white54)),
        ]),
      ),
    );
  }

  // ---- เมนูย่อย CONNECT: สถานะ BLE + ปุ่มเชื่อมต่อ / ตัดการเชื่อมต่อ / ค้นหาเกจ + GPS ----
  Widget _connect(AppTheme th) {
    final c = widget.c;
    final conn = c.link == LinkState.connected;
    final (String, Color, String) st = switch (c.link) {
      LinkState.connected => ('CONNECTED', kGreen, 'เชื่อมต่อกับเกจ ${c.gaugeName ?? ''} แล้ว'),
      LinkState.connecting => ('CONNECTING', kAmber, 'กำลังเชื่อมต่อ ${c.gaugeName ?? ''}…'),
      LinkState.scanning => ('SCANNING', kAmber, 'กำลังค้นหาเกจ…'),
      LinkState.idle => ('OFFLINE', kBad, c.error ?? 'ยังไม่ได้เชื่อมต่อเกจ'),
    };
    final gps = c.gpsOk
        ? '${c.satUsed ?? '-'} / ${c.satTotal ?? '-'} ดวง${c.gpsAccM != null ? ' · ±${c.gpsAccM!.toStringAsFixed(1)} m' : ''}'
        : 'ยังไม่จับสัญญาณ';
    return _panel(
      th,
      'CONNECT · BLE',
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 14, height: 14, decoration: BoxDecoration(color: st.$2, shape: BoxShape.circle, boxShadow: [BoxShadow(color: st.$2, blurRadius: 8)])),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(st.$1, style: TextStyle(fontFamily: kFont, fontSize: 16, color: st.$2)),
              Text(st.$3, style: const TextStyle(fontSize: 12, color: Colors.white60)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (conn) _action('ตัดการเชื่อมต่อ', Icons.link_off, th, c.disconnect),
          _action(conn ? 'ค้นหา / เลือกเกจอื่น' : 'ค้นหา / เลือกเกจ', Icons.bluetooth_searching, th, () => pickGauge(context, c)),
        ]),
        const SizedBox(height: 12),
        _infoRow('GAUGE', c.gaugeName ?? '--', col: conn ? kGreen : Colors.white54),
        const SizedBox(height: 6),
        _infoRow('AUTO CONNECT', 'ต่อใหม่อัตโนมัติถ้าหลุด (เฉพาะเกจที่เลือกไว้)'),
        const SizedBox(height: 6),
        _infoRow('GAUGE FW', c.t.fwText ?? '--'),
        const SizedBox(height: 6),
        _infoRow('GPS', gps, col: c.gpsOk ? kGreen : kAmber),
      ]),
    );
  }

  Widget _ecuInfo(AppTheme th) {
    final c = widget.c;
    final t = c.t;
    final conn = c.link == LinkState.connected;
    final demo = c.demo;
    final live = demo || (conn && t.fresh);
    final id = demo ? const [0x01, 0x01, 0x88, 0x0D, 0x01] : t.ecuId;
    final idTxt = id == null ? '--' : ecmHex(id);
    final model = id == null ? null : ecuModelName(id);
    final dbId = id == null ? '' : ecmHex(id);
    final part = EcuDb.part[dbId];
    final typ = EcuDb.type[dbId];
    String hx(int v) => v == 0 ? '-' : v.toRadixString(16).toUpperCase().padLeft(2, '0');
    String mmss(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
    final proto = demo ? 1 : t.proto;
    final (String, Color) st = !conn && !demo
        ? ('ยังไม่ได้เชื่อมต่อเกจ', kAmber)
        : live
            ? ('CONNECTED', kGreen)
            : (t.state == 0 ? ('CONNECTING...', kAmber) : ('NO RESPONSE', kBad));
    final protoTxt = switch (proto) { 1 => 'HONDA K-LINE', 2 => 'OBD2 ${t.kwp ? 'KWP2000' : 'ISO9141'}', _ => '--' };
    final age = demo ? 1 : t.ageDs;
    final ageTxt = age >= 255 ? '--' : (age < 100 ? '${age * 100} ms' : '${age ~/ 10} s');
    final batt = demo ? 14.1 : t.batt;
    final sup = demo || t.infoSup;

    Widget row(String a, String b, {Color? col, bool big = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 108, child: Text(a, style: const TextStyle(fontFamily: kFont, fontSize: 9, color: Colors.white54))),
            Expanded(
              child: Text(b,
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: big ? 15 : 13.5, fontWeight: FontWeight.bold, color: col ?? Colors.white)),
            ),
          ]),
        );
    Widget box(String title, List<Widget> rows) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontFamily: kFont, fontSize: 12, color: th.c, shadows: [Shadow(color: th.c, blurRadius: 8)])),
            const SizedBox(height: 4),
            ...rows,
          ]),
        );

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      box('ECU', [
        row('STATUS', st.$1, col: st.$2),
        row('PROTOCOL', protoTxt),
        row('ECU ID', idTxt, big: true),
        row('BIKE', model ?? (id == null ? '--' : 'ไม่มีในฐานข้อมูล'), col: model != null ? th.c2 : Colors.white54),
        row('PART CODE', (part == null || part.isEmpty) ? '--' : part),
        row('ECU TYPE', typ == null ? '--' : typ.toUpperCase()),
        row('TABLES', proto == 1 ? (demo ? '11 20 D1' : '${hx(t.tabA)} ${hx(t.tabB)} ${hx(t.tabS)}') : '--'),
      ]),
      const SizedBox(width: 16),
      box('LINK', [
        row('DATA RATE', live ? '${(demo ? 18.6 : t.hz).toStringAsFixed(1)} Hz' : '--'),
        row('LAST DATA', sup ? ageTxt : '--', col: age <= 15 ? null : kAmber),
        row('LINK TIME', live ? mmss(demo ? 207 : t.linkSec) : '--'),
        row('BATTERY', batt == null || !live ? '--' : '${batt.toStringAsFixed(1)} V'),
        row('MODEL SET', t.bike < kBikeNames.length ? kBikeNames[t.bike] : '--'),
        row('GAUGE', conn ? (c.gaugeName ?? 'CONNECTED') : '--', col: conn ? kGreen : Colors.white54),
        row('GAUGE FW', t.fwText ?? '--', col: t.fwText == kAppFw || !conn ? null : kAmber),
        if (conn && !t.infoSup && !demo)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('เฟิร์มแวร์เกจยังไม่ส่งข้อมูล ECU INFO — อัปเดตเป็น FW 1.0.14 ขึ้นไป', style: TextStyle(fontSize: 12, color: kAmber)),
          ),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final cfg = Cfg.i;
    final th = cfg.t;
    final connected = widget.c.link == LinkState.connected;
    final Widget body = switch (sec) {
      0 => _connect(th),
      1 => _panel(th, 'ECU INFO · ข้อมูลกล่อง', _ecuInfo(th)),
      2 => _panel(th, 'ธีมสี', Wrap(spacing: 14, runSpacing: 14, children: [
                          for (int i = 0; i < kThemes.length; i++) _themeDot(i),
                        ])),
      3 => _panel(
                          th,
                          'แจ้งเตือน',
                          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            _stepper('SHIFT LIGHT RPM', '${cfg.shift}', () => cfg.addShift(-1000), () => cfg.addShift(1000), th, thLabel: 'รอบไฟเตือนเปลี่ยนเกียร์'),
                            const SizedBox(height: 12),
                            _stepper('TEMP', '${cfg.tempWarn} °C', () => cfg.addTemp(-1), () => cfg.addTemp(1), th, thLabel: 'อุณหภูมิแจ้งเตือน'),
                            const SizedBox(height: 14),
                            _action('', Icons.refresh, th, en: 'RESET MIN/MAX', thTxt: 'ล้างค่าต่ำสุด/สูงสุด', () {
                              widget.c.resetMinMax();
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(duration: Duration(seconds: 1), content: Text('รีเซ็ตค่าต่ำสุด/สูงสุดแล้ว')));
                            }),
                          ]),
                        ),
      4 => _panel(
                        th,
                        'เปลี่ยนโลโก้เกจ',
                        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Center(
                            child: Container(
                              width: 220, height: 165,
                              decoration: hudDeco(border: th.c, width: 1.4, radius: 8, color: Colors.black),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(7),
                                child: preview == null
                                    ? const Center(child: Text('ยังไม่ได้เลือกรูป', style: TextStyle(color: Colors.white38, fontSize: 12)))
                                    : RawImage(image: preview, fit: BoxFit.cover),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Center(child: Text('320 x 240 px', style: TextStyle(color: Colors.white38, fontSize: 10))),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            _action('เลือกรูป', Icons.image, th, _pick, enabled: !busy),
                            _action('ส่งไปบอร์ด', Icons.upload, th, _send, enabled: !busy && raw565 != null && connected),
                            _action('คืนโลโก้เดิม', Icons.restore, th, _reset, enabled: !busy && connected),
                          ]),
                          if (!connected)
                            const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Text('ต้องเชื่อมต่อบอร์ดก่อนจึงจะส่งรูปได้', style: TextStyle(color: kAmber, fontSize: 11)),
                            ),
                          if (progress != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: LinearProgressIndicator(value: progress, color: th.c, backgroundColor: Colors.white12, minHeight: 5),
                            ),
                          if (msg != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(msg!, style: const TextStyle(fontSize: 12))),
                        ]),
                      ),
      _ => _panel(
                          th,
                          'เฟิร์มแวร์',
                          Builder(builder: (_) {
                            final fw = widget.c.t.fwText;
                            final connected = widget.c.link == LinkState.connected;
                            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              _infoRow('เกจ (BLE)',
                                  !connected ? 'ยังไม่ได้เชื่อมต่อ' : (fw != null ? 'FW $fw' : 'ไม่ทราบ (เฟิร์มแวร์เก่า)'),
                                  col: !connected ? kAmber : (fw != null ? kGreen : kAmber)),
                              const SizedBox(height: 6),
                              _infoRow('แอพออกแบบสำหรับ', 'FW $kAppFw'),
                              if (connected && fw != null && fw != kAppFw)
                                const Padding(
                                  padding: EdgeInsets.only(top: 6),
                                  child: Text('เวอร์ชันเกจกับแอพไม่ตรงกัน — บางฟีเจอร์อาจทำงานไม่ครบ',
                                      style: TextStyle(color: kAmber, fontSize: 11)),
                                ),
                            ]);
                          }),
                        ),
    };
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        Image.asset('assets/bg.jpg', fit: BoxFit.cover),
        Container(color: Colors.black.withOpacity(0.7)),
        const HudGrid(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Column(children: [
              Row(children: [
                glowIconBtn(Icons.arrow_back, th, () => Navigator.of(context).pop()),
                const SizedBox(width: 10),
                Text('SETTING', style: TextStyle(fontFamily: kFont, fontSize: 18, color: th.c, shadows: [Shadow(color: th.c, blurRadius: 10)])),
                const SizedBox(width: 16),
                Expanded(child: Align(alignment: Alignment.centerRight, child: statusChips(widget.c))),
              ]),
              const SizedBox(height: 8),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 210, child: ListView(children: [for (int i = 0; i < _menu.length; i++) _menuItem(th, i)])),
                  const SizedBox(width: 10),
                  Expanded(child: SingleChildScrollView(child: body)),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _stepper(String label, String value, VoidCallback dec, VoidCallback inc, AppTheme th, {String thLabel = ''}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(TextSpan(children: [
            TextSpan(text: label, style: const TextStyle(fontFamily: kFont, fontSize: 11, color: Colors.white)),
            if (thLabel.isNotEmpty) TextSpan(text: '   $thLabel', style: const TextStyle(fontSize: 10.5, color: Colors.white60)),
          ])),
          const SizedBox(height: 6),
          Row(children: [
            StepBtn(label: '−', onStep: dec, th: th),
            const SizedBox(width: 10),
            SizedBox(
              width: 110,
              child: Center(
                child: Text(value,
                    style: TextStyle(fontFamily: kFont, fontSize: 17, color: Colors.white, shadows: [Shadow(color: th.c, blurRadius: 9)])),
              ),
            ),
            const SizedBox(width: 10),
            StepBtn(label: '+', onStep: inc, th: th),
          ]),
        ],
      );

  Widget _infoRow(String a, String b, {Color? col}) => Row(children: [
        SizedBox(width: 150, child: Text(a, style: const TextStyle(fontSize: 12.5, color: Colors.white60))),
        Expanded(child: Text(b, style: TextStyle(fontSize: 13, color: col ?? Colors.white, fontWeight: FontWeight.bold))),
      ]);

  Widget _panel(AppTheme th, String title, Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: hudDeco(border: th.c.withOpacity(0.8), width: 1.1, radius: 12, color: const Color(0xCC060606)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 12),
          child,
        ]),
      );

  Widget _themeDot(int i) {
    final t = kThemes[i];
    final sel = Cfg.i.themeIdx == i;
    return GestureDetector(
      onTap: () => Cfg.i.setTheme(i),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: t.c,
            shape: BoxShape.circle,
            border: Border.all(color: sel ? Colors.white : Colors.white24, width: sel ? 3 : 1),
            boxShadow: [BoxShadow(color: t.c.withOpacity(sel ? 0.9 : 0.4), blurRadius: sel ? 14 : 6)],
          ),
          child: sel ? const Icon(Icons.check, color: Colors.black) : null,
        ),
        const SizedBox(height: 4),
        Text(t.name, style: TextStyle(fontSize: 11, color: sel ? Colors.white : Colors.white60)),
      ]),
    );
  }

  Widget _action(String s, IconData ic, AppTheme th, VoidCallback f, {bool enabled = true, String en = '', String thTxt = ''}) => Opacity(
        opacity: enabled ? 1 : 0.4,
        child: InkWell(
          onTap: enabled ? f : null,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: hudDeco(border: th.c, width: 1.3, radius: 6, color: Colors.black45),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(ic, size: 16, color: th.c),
              const SizedBox(width: 6),
              if (en.isNotEmpty)
                Text.rich(TextSpan(children: [
                  TextSpan(text: en, style: const TextStyle(fontFamily: kFont, fontSize: 11, color: Colors.white)),
                  if (thTxt.isNotEmpty) TextSpan(text: '   $thTxt', style: const TextStyle(fontSize: 10.5, color: Colors.white60)),
                ]))
              else
                Text(s, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ]),
          ),
        ),
      );
}

// =====================================================================
// ===================== หน้า TUNE : ตารางจูน BIN / XDF ==================
// =====================================================================
// เปิดไฟล์ BIN (ข้อมูลกล่อง) + XDF (TunerPro XML บอกตำแหน่ง/สูตรของแต่ละตาราง) แล้วแก้ค่าในแอพ
// - ชื่อไทยใน XDF เป็น TIS-620 ใน &#NNN; (0xA1–0xFB) -> แปลงเป็น Unicode (U+0E01..)
// - mmedtypeflags: 0x01 = มีเครื่องหมาย, 0x02 = LSB first (little-endian), 0x04 = เรียงตามคอลัมน์
// - mmedmajorstridebits > 0 = ระยะห่างระหว่างช่อง (บิต) (ข้อมูล Honda สลับค่า/slope)
// - แกนลิงก์ไปตารางอื่นผ่าน <embedinfo type="3" linkobjid=...>
// แอพเขียนค่าลงกล่อง ECU ไม่ได้ (FW อ่าน K-Line อย่างเดียว) -> SAVE เป็นไฟล์ BIN ใหม่ แล้วแฟลชด้วยเครื่องมือเดิม
// ยังไม่รู้วิธีคำนวณ checksum ของกล่องรุ่นนี้ -> แอพไม่แก้ checksum ให้ (เตือนทุกครั้งตอน SAVE)

typedef _Fn = double Function(double x);

int _pi(String? s, [int d = 0]) {
  if (s == null) return d;
  final t = s.trim();
  if (t.isEmpty) return d;
  final neg = t.startsWith('-');
  final u = neg ? t.substring(1) : t;
  final v = (u.startsWith('0x') || u.startsWith('0X')) ? int.tryParse(u.substring(2), radix: 16) : int.tryParse(u);
  if (v == null) return d;
  return neg ? -v : v;
}

double? _pd(String? s) => s == null ? null : double.tryParse(s.trim());

/// ตัดเลข 0 ท้ายทศนิยม เช่น 0.3572 / 0.001 / 1
String _numStr(double v) {
  var s = v.toStringAsFixed(4);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '');
    s = s.replaceAll(RegExp(r'\.$'), '');
  }
  return s;
}

/// TIS-620 -> Unicode (เฉพาะข้อความที่ยังไม่ใช่ Unicode ไทย)
String _tis(String s) {
  if (s.runes.any((r) => r > 0xFF)) return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  final b = StringBuffer();
  for (final r in s.runes) {
    b.writeCharCode(r >= 0xA1 && r <= 0xFB ? r + 0x0D60 : r);
  }
  return b.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// สีไล่ตามค่า น้ำเงิน -> ฟ้า -> เขียว -> เหลือง -> ส้ม -> แดง
Color _heat(double t) {
  if (t.isNaN) t = 0.5;
  t = t.clamp(0.0, 1.0).toDouble();
  const stops = <Color>[
    Color(0xFF2B45D8), Color(0xFF1FA8E8), Color(0xFF2ED47A), Color(0xFFF2D22E), Color(0xFFF0641E), Color(0xFFD81B3C),
  ];
  final p = t * (stops.length - 1);
  final i = p.floor().clamp(0, stops.length - 2).toInt();
  return Color.lerp(stops[i], stops[i + 1], p - i)!;
}

// ---------- สมการ XDF เช่น "X*.3572 -15.72" : + - * / วงเล็บ ตัวแปร X ----------
class XdfEq {
  final String src;
  final _Fn f;
  final bool ok, linear;
  final double a, b; // ถ้าเป็นเส้นตรง: ค่า = a*ดิบ + b

  XdfEq._(this.src, this.f, this.ok, this.linear, this.a, this.b);

  static double _ident(double x) => x;

  factory XdfEq(String? s) {
    final src = (s == null || s.trim().isEmpty) ? 'X' : s.trim();
    _Fn fn;
    bool ok = true;
    try {
      fn = _EqParser(src).parse();
      if (fn(1.0).isNaN) throw const FormatException('nan');
    } catch (_) {
      fn = _ident;
      ok = false;
    }
    final b = fn(0), a = fn(1) - b, t = fn(1000);
    final lin = (t - (a * 1000 + b)).abs() <= 1e-6 * math.max(1.0, t.abs());
    return XdfEq._(src, fn, ok, lin, a, b);
  }

  /// ค่าที่แสดง -> ค่าดิบ (ยังไม่ปัด)
  double inv(double v, double lo, double hi) {
    if (linear && a != 0) return (v - b) / a;
    double l = lo, h = hi;
    final up = f(h) >= f(l);
    for (int i = 0; i < 60; i++) {
      final m = (l + h) / 2;
      if ((f(m) < v) == up) {
        l = m;
      } else {
        h = m;
      }
    }
    return (l + h) / 2;
  }

  /// ค่าที่เปลี่ยนต่อ 1 ค่าดิบ (ใช้เป็นระยะ STEP ของปุ่ม − +)
  double get lsb {
    final d = linear ? a.abs() : (f(1) - f(0)).abs();
    return d == 0 || d.isNaN ? 1.0 : d;
  }
}

class _EqParser {
  final String s;
  int i = 0;
  _EqParser(this.s);

  _Fn parse() {
    final e = _expr();
    _ws();
    if (i != s.length) throw FormatException('eq', s, i);
    return e;
  }

  void _ws() {
    while (i < s.length && (s[i] == ' ' || s[i] == '\t')) {
      i++;
    }
  }

  _Fn _expr() {
    var l = _term();
    while (true) {
      _ws();
      if (i >= s.length || (s[i] != '+' && s[i] != '-')) return l;
      final op = s[i++];
      final r = _term(), a = l;
      if (op == '+') {
        l = (x) => a(x) + r(x);
      } else {
        l = (x) => a(x) - r(x);
      }
    }
  }

  _Fn _term() {
    var l = _unary();
    while (true) {
      _ws();
      if (i >= s.length || (s[i] != '*' && s[i] != '/')) return l;
      final op = s[i++];
      final r = _unary(), a = l;
      if (op == '*') {
        l = (x) => a(x) * r(x);
      } else {
        l = (x) => a(x) / r(x);
      }
    }
  }

  _Fn _unary() {
    _ws();
    if (i < s.length && s[i] == '-') {
      i++;
      final u = _unary();
      return (x) => -u(x);
    }
    if (i < s.length && s[i] == '+') {
      i++;
      return _unary();
    }
    return _atom();
  }

  _Fn _atom() {
    _ws();
    if (i >= s.length) throw FormatException('eq', s, i);
    final ch = s[i];
    if (ch == '(') {
      i++;
      final e = _expr();
      _ws();
      if (i < s.length && s[i] == ')') i++;
      return e;
    }
    if (ch == 'X' || ch == 'x') {
      i++;
      return (x) => x;
    }
    final m = RegExp(r'(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?').matchAsPrefix(s, i);
    if (m == null) throw FormatException('eq', s, i);
    i = m.end;
    final v = double.parse(m.group(0)!);
    return (_) => v;
  }
}

// ---------- ตำแหน่งข้อมูลใน BIN (EMBEDDEDDATA) ----------
class XdfData {
  final int addr, bits, rows, cols, stride; // stride = ระยะระหว่างช่อง (ไบต์)
  final bool lsb, signed, colMajor;
  XdfData({
    required this.addr, required this.bits, required this.rows, required this.cols, required this.stride,
    required this.lsb, required this.signed, required this.colMajor,
  });

  int get bytes => math.max(1, bits ~/ 8);
  int get count => rows * cols;
  int addrOf(int r, int c) => addr + (colMajor ? c * rows + r : r * cols + c) * stride;
  int addrAt(int k) => addr + k * stride;
  int get span => (count - 1) * stride + bytes;

  static XdfData? from(XmlElement? e, _XdfDefaults d, int base) {
    if (e == null) return null;
    final a = e.getAttribute('mmedaddress');
    if (a == null) return null;
    final bits = math.max(8, _pi(e.getAttribute('mmedelementsizebits'), d.bits));
    final tf = e.getAttribute('mmedtypeflags');
    final fl = tf == null ? ((d.signed ? 1 : 0) | (d.lsb ? 2 : 0)) : _pi(tf);
    final ms = _pi(e.getAttribute('mmedmajorstridebits'));
    final eb = math.max(1, bits ~/ 8);
    return XdfData(
      addr: _pi(a) + base,
      bits: bits,
      rows: math.max(1, _pi(e.getAttribute('mmedrowcount'), 1)),
      cols: math.max(1, _pi(e.getAttribute('mmedcolcount'), 1)),
      stride: ms > 0 ? math.max(1, ms ~/ 8) : eb,
      lsb: (fl & 0x02) != 0,
      signed: (fl & 0x01) != 0,
      colMajor: (fl & 0x04) != 0,
    );
  }
}

class _XdfDefaults {
  final int bits;
  final bool lsb, signed;
  const _XdfDefaults(this.bits, this.lsb, this.signed);
}

class XdfAxis {
  final List<String> labels;
  final int? link;
  final XdfData? data;
  final XdfEq eq;
  final int dec;
  XdfAxis(this.labels, this.link, this.data, this.eq, this.dec);
}

class XdfTable {
  final int uid;
  final String title;
  final XdfData z;
  final XdfEq eq;
  final int dec, outType;
  final double? min, max;
  final XdfAxis x, y;
  bool valid = true; // อยู่ในขนาดไฟล์ BIN หรือไม่
  XdfTable(this.uid, this.title, this.z, this.eq, this.dec, this.outType, this.min, this.max, this.x, this.y);

  int get rows => z.rows;
  int get cols => z.cols;
  bool get is2D => rows > 1 && cols > 1;
  bool get isLock {
    final t = title.toLowerCase();
    return t.contains('ล็อค') || t.contains('ล็อก') || t.contains('lock');
  }

  String fmt(double v) {
    if (v.isNaN) return '--';
    if (outType == 3) return '0x${v.round().toRadixString(16).toUpperCase().padLeft(2, '0')}';
    return v.toStringAsFixed(dec.clamp(0, 6).toInt());
  }
}

class XdfFlag {
  final int uid;
  final String title;
  final XdfData d;
  final int mask;
  bool valid = true;
  XdfFlag(this.uid, this.title, this.d, this.mask);
}

class XdfError implements Exception {
  final String msg;
  XdfError(this.msg);
  @override
  String toString() => msg;
}

class XdfDef {
  final List<XdfTable> tables;
  final List<XdfFlag> flags;
  final Map<int, XdfTable> byId;
  XdfDef(this.tables, this.flags) : byId = {for (final t in tables) t.uid: t};

  static XdfDef parse(Uint8List bytes) {
    String txt;
    if (bytes.length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
      // UTF-16 (มี BOM)
      final le = bytes[0] == 0xFF;
      final u = <int>[];
      for (int i = 2; i + 1 < bytes.length; i += 2) {
        u.add(le ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
      }
      txt = String.fromCharCodes(u);
    } else {
      try {
        txt = utf8.decode(bytes);
      } catch (_) {
        txt = latin1.decode(bytes);
      }
    }
    if (txt.startsWith('﻿')) txt = txt.substring(1);
    // มีข้อมูลอื่นนำหน้า/ต่อท้าย -> ตัดเอาเฉพาะช่วง <XDFFORMAT ... </XDFFORMAT>
    final xs = txt.indexOf('<XDFFORMAT');
    if (xs > 0) {
      final xe = txt.lastIndexOf('</XDFFORMAT>');
      txt = xe > xs ? txt.substring(xs, xe + 12) : txt.substring(xs);
    }
    if (!txt.trimLeft().startsWith('<')) {
      throw XdfError('XDF นี้ถูกเข้ารหัสโดยผู้ทำไฟล์ (เปิดได้เฉพาะใน TunerPro) — ขอไฟล์แบบที่ไม่เข้ารหัสจากผู้ขาย');
    }
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(txt);
    } catch (e) {
      throw XdfError('อ่าน XDF ไม่ได้: $e');
    }
    final root = doc.rootElement;
    if (root.name.local != 'XDFFORMAT') throw XdfError('ไม่ใช่ไฟล์ TunerPro XDF (ไม่พบ <XDFFORMAT>)');

    // ค่าตั้งต้น + base offset
    int base = 0;
    var defs = const _XdfDefaults(8, false, false);
    final hdr = root.getElement('XDFHEADER');
    if (hdr != null) {
      final bo = hdr.getElement('BASEOFFSET');
      if (bo != null) {
        final off = _pi(bo.getAttribute('offset'));
        base = bo.getAttribute('subtract') == '1' ? -off : off;
      }
      final df = hdr.getElement('DEFAULTS');
      if (df != null) {
        defs = _XdfDefaults(_pi(df.getAttribute('datasizeinbits'), 8), df.getAttribute('lsbfirst') == '1', df.getAttribute('signed') == '1');
      }
    }

    XdfAxis axis(XmlElement? a) {
      if (a == null) return XdfAxis(const [], null, null, XdfEq('X'), 2);
      final labels = <String>[];
      for (final l in a.findElements('LABEL')) {
        final idx = _pi(l.getAttribute('index'), labels.length);
        if (idx < 0 || idx > 4096) continue;
        while (labels.length <= idx) {
          labels.add('');
        }
        labels[idx] = _tis(l.getAttribute('value') ?? '');
      }
      int? link;
      final ei = a.getElement('embedinfo');
      if (ei != null && ei.getAttribute('type') == '3') {
        final li = ei.getAttribute('linkobjid');
        if (li != null && li.trim().isNotEmpty) link = _pi(li);
      }
      return XdfAxis(
        labels,
        link,
        XdfData.from(a.getElement('EMBEDDEDDATA'), defs, base),
        XdfEq(a.getElement('MATH')?.getAttribute('equation')),
        _pi(a.getElement('decimalpl')?.innerText, 2),
      );
    }

    final tables = <XdfTable>[];
    for (final t in root.findElements('XDFTABLE')) {
      XmlElement? zx, xx, yx;
      for (final a in t.findElements('XDFAXIS')) {
        switch (a.getAttribute('id')) {
          case 'z':
            zx = a;
            break;
          case 'x':
            xx = a;
            break;
          case 'y':
            yx = a;
            break;
        }
      }
      if (zx == null) continue;
      final zd = XdfData.from(zx.getElement('EMBEDDEDDATA'), defs, base);
      if (zd == null) continue;
      final uid = _pi(t.getAttribute('uniqueid'), tables.length + 0x100000);
      var title = _tis(t.getElement('title')?.innerText ?? '');
      if (title.isEmpty) title = 'TABLE 0x${uid.toRadixString(16).toUpperCase()}';
      tables.add(XdfTable(
        uid, title, zd,
        XdfEq(zx.getElement('MATH')?.getAttribute('equation')),
        _pi(zx.getElement('decimalpl')?.innerText, 2),
        _pi(zx.getElement('outputtype')?.innerText, 1),
        _pd(zx.getElement('min')?.innerText),
        _pd(zx.getElement('max')?.innerText),
        axis(xx), axis(yx),
      ));
    }

    final flags = <XdfFlag>[];
    for (final f in root.findElements('XDFFLAG')) {
      final d = XdfData.from(f.getElement('EMBEDDEDDATA'), defs, base);
      if (d == null) continue;
      final uid = _pi(f.getAttribute('uniqueid'));
      var title = _tis(f.getElement('title')?.innerText ?? '');
      if (title.isEmpty) title = 'FLAG 0x${uid.toRadixString(16).toUpperCase()}';
      flags.add(XdfFlag(uid, title, d, _pi(f.getElement('mask')?.innerText, 1)));
    }
    if (tables.isEmpty && flags.isEmpty) throw XdfError('ไม่พบตารางใน XDF นี้');
    return XdfDef(tables, flags);
  }
}

// ---------- ประวัติการแก้ (ย้อนกลับ/ทำซ้ำ) เก็บเป็นไบต์ก่อน/หลัง ----------
class _Edit {
  final String label;
  final List<int> addr, before, after;
  final int t;
  _Edit(this.label, this.addr, this.before, this.after, this.t);
}

/// สถานะไฟล์ที่เปิดอยู่ (คงอยู่แม้ออกจากหน้า TUNE แล้วกลับเข้ามา)
class TuneSession extends ChangeNotifier {
  static final TuneSession i = TuneSession._();
  TuneSession._();

  Uint8List? orig, bin;
  Uint8List? saved; // ค่าตอนบันทึกเข้าคลังล่าสุด (จุดแดงหลังชื่อตาราง = ยังไม่ได้บันทึก)
  Uint8List? commit; // ค่าที่กด ✅ บันทึกแล้ว (❌ = กลับไปค่านี้)
  String? binName, xdfName;
  XdfDef? xdf;
  Uint8List? xdfRaw; // ไบต์ XDF เดิม (ใช้บันทึกคู่กับ BIN เข้าคลังไฟล์)
  int binSrc = 0, xdfSrc = 0; // แหล่งไฟล์: 0 = ยังไม่เปิด, 1 = ไฟล์ในแอป (ORIGINAL), 2 = ผู้ใช้เลือกเอง (มือถือ/คลังไฟล์)
  int lastClamp = 0; // จำนวนช่องที่ชนค่าสุดของข้อมูลในการเขียนครั้งล่าสุด
  double clampLo = 0, clampHi = 0;
  int sel = -1;
  bool lockOk = false; // ผู้ใช้ยืนยันปลดล็อกการแก้รหัสล็อคกล่องแล้ว (เฉพาะรอบนี้)
  final List<_Edit> undoList = [], redoList = [];
  int rev = 0;
  int _cbRev = -1, _cb = 0;

  bool get ready => bin != null && xdf != null;
  XdfTable? get table {
    final d = xdf;
    if (d == null || sel < 0 || sel >= d.tables.length) return null;
    return d.tables[sel];
  }

  void _changed() {
    rev++;
    notifyListeners();
  }

  void loadBin(String name, Uint8List b, {int src = 2}) {
    binSrc = src;
    cmpRef = null; // ไฟล์ใหม่: เลือกไฟล์ที่ใช้เทียบ Δ% ใหม่
    cmpName = null;
    saved = Uint8List.fromList(b);
    orig = Uint8List.fromList(b);
    bin = Uint8List.fromList(b);
    commit = Uint8List.fromList(b);
    binName = name;
    undoList.clear();
    redoList.clear();
    lockOk = false;
    _validate();
    _changed();
  }

  void loadXdf(String name, XdfDef d, {int src = 2, Uint8List? raw}) {
    xdfSrc = src;
    xdfRaw = raw == null ? null : Uint8List.fromList(raw);
    xdf = d;
    xdfName = name;
    sel = -1;
    undoList.clear();
    redoList.clear();
    _validate();
    _changed();
  }

  void select(int i) {
    sel = i;
    _changed();
  }

  int get invalidCount => xdf == null || bin == null ? 0 : xdf!.tables.where((t) => !t.valid).length + xdf!.flags.where((f) => !f.valid).length;

  void _validate() {
    final d = xdf;
    if (d == null) return;
    final n = bin?.length;
    bool ok(XdfData z) => n == null || (z.addr >= 0 && z.addr + z.span <= n);
    for (final t in d.tables) {
      t.valid = ok(t.z);
    }
    for (final f in d.flags) {
      f.valid = ok(f.d);
    }
    if (sel >= d.tables.length || (sel >= 0 && !d.tables[sel].valid)) sel = -1; // ไม่เลือกตารางเอง (ให้ผู้ใช้เลือกจากเมนูตารางจูน)
  }

  void clearBin() {
    binSrc = 0;
    saved = null;
    orig = null;
    bin = null;
    commit = null;
    binName = null;
    undoList.clear();
    redoList.clear();
    lockOk = false;
    _changed();
  }

  void clearXdf() {
    xdfSrc = 0;
    xdfRaw = null;
    xdf = null;
    xdfName = null;
    sel = -1;
    undoList.clear();
    redoList.clear();
    _changed();
  }

  // ----- ✅ / ❌ ต่อตาราง: เทียบ bin กับค่าที่บันทึกล่าสุด (commit) -----
  bool _diffAt(Uint8List? a, Uint8List? b, int addr, int n) {
    if (a == null || b == null) return false;
    for (int k = 0; k < n; k++) {
      final p = addr + k;
      if (p >= 0 && p < a.length && a[p] != b[p]) return true;
    }
    return false;
  }

  bool cellDirty(XdfTable t, int r, int c) => _diffAt(bin, commit, t.z.addrOf(r, c), t.z.bytes);

  bool tableDirty(XdfTable t) {
    if (!t.valid) return false;
    for (int r = 0; r < t.rows; r++) {
      for (int c = 0; c < t.cols; c++) {
        if (cellDirty(t, r, c)) return true;
      }
    }
    return false;
  }

  List<XdfTable> dirtyTables() => xdf == null ? const [] : [for (final t in xdf!.tables) if (tableDirty(t)) t];

  void commitTable(XdfTable t) {
    final b = bin, m = commit;
    if (b == null || m == null) return;
    for (int r = 0; r < t.rows; r++) {
      for (int c = 0; c < t.cols; c++) {
        final a = t.z.addrOf(r, c);
        for (int k = 0; k < t.z.bytes; k++) {
          final p = a + k;
          if (p >= 0 && p < b.length) m[p] = b[p];
        }
      }
    }
    _changed();
  }

  void commitAll() {
    if (bin == null) return;
    commit = Uint8List.fromList(bin!);
    _changed();
  }

  /// ❌ : คืนค่าตารางเป็นค่าที่กด ✅ ล่าสุด (ย้อนกลับได้ด้วย ↶)
  int revertTable(XdfTable t) {
    final b = bin, m = commit;
    if (b == null || m == null) return 0;
    final addr = <int>[], before = <int>[], after = <int>[];
    for (int r = 0; r < t.rows; r++) {
      for (int c = 0; c < t.cols; c++) {
        final a = t.z.addrOf(r, c);
        for (int k = 0; k < t.z.bytes; k++) {
          final p = a + k;
          if (p >= 0 && p < b.length && b[p] != m[p]) {
            addr.add(p);
            before.add(b[p]);
            after.add(m[p]);
          }
        }
      }
    }
    return _commit('❌ ${t.title}', addr, before, after, false);
  }

  int rawAt(Uint8List src, XdfData d, int a) {
    final n = d.bytes;
    int v = 0;
    for (int k = 0; k < n; k++) {
      final p = a + (d.lsb ? k : n - 1 - k);
      v |= ((p >= 0 && p < src.length) ? src[p] : 0) << (8 * k);
    }
    if (d.signed && v >= (1 << (n * 8 - 1))) v -= (1 << (n * 8));
    return v;
  }

  double val(XdfTable t, int r, int c, {bool original = false}) =>
      t.eq.f(rawAt(original ? orig! : bin!, t.z, t.z.addrOf(r, c)).toDouble());

  List<List<double>> values(XdfTable t) => [
        for (int r = 0; r < t.rows; r++) [for (int c = 0; c < t.cols; c++) val(t, r, c)],
      ];

  bool _rangeChanged(int a, int n) {
    final b = bin, o = orig;
    if (b == null || o == null) return false;
    for (int k = 0; k < n; k++) {
      final p = a + k;
      if (p >= 0 && p < b.length && b[p] != o[p]) return true;
    }
    return false;
  }

  bool cellChanged(XdfTable t, int r, int c) => _rangeChanged(t.z.addrOf(r, c), t.z.bytes);

  // ---- เทียบ Δ% กับไฟล์อ้างอิง (ORIGINAL ในแอป / ไฟล์ในคลัง / ไฟล์ตอนเปิด) ----
  Uint8List? cmpRef;
  String? cmpName;
  void setCmp(String name, Uint8List b) {
    cmpRef = Uint8List.fromList(b);
    cmpName = name;
    _changed();
  }

  /// ค่าในไฟล์อ้างอิง (null = ไม่มีไฟล์อ้างอิง / ตำแหน่งเกินขนาดไฟล์)
  double? refVal(XdfTable t, int r, int c) {
    final ref = cmpRef;
    if (ref == null) return null;
    final a = t.z.addrOf(r, c);
    if (a < 0 || a + t.z.bytes > ref.length) return null;
    return t.eq.f(rawAt(ref, t.z, a).toDouble());
  }

  /// เปลี่ยนจากไฟล์อ้างอิงกี่ % (null = เทียบไม่ได้)
  double? pctDiff(XdfTable t, int r, int c) {
    final o = refVal(t, r, c);
    if (o == null) return null;
    final v = val(t, r, c);
    if ((v - o).abs() < 1e-9) return 0;
    if (o.abs() < 1e-9) return null;
    return (v - o) / o.abs() * 100;
  }

  /// ตารางนี้มีค่าที่ยังไม่ได้บันทึกเข้าคลัง (เทียบกับตอนบันทึกล่าสุด / ตอนเปิดไฟล์)
  bool tableUnsaved(XdfTable t) {
    final b = bin, o = saved ?? orig;
    if (b == null || o == null) return false;
    final z = t.z;
    for (int r = 0; r < t.rows; r++) {
      for (int c = 0; c < t.cols; c++) {
        final a = z.addrOf(r, c);
        for (int k = 0; k < z.bytes; k++) {
          final p = a + k;
          if (p >= 0 && p < b.length && p < o.length && b[p] != o[p]) return true;
        }
      }
    }
    return false;
  }

  /// จำนวนไบต์ที่แก้แล้วยังไม่ได้บันทึกเข้าคลัง
  int get unsavedBytes {
    final b = bin, o = saved ?? orig;
    if (b == null || o == null) return 0;
    int n = 0;
    for (int k = 0; k < b.length && k < o.length; k++) {
      if (b[k] != o[k]) n++;
    }
    return n;
  }

  /// บันทึกเข้าคลังแล้ว: ล้างจุดแดงสถานะการเปลี่ยนแปลง
  void markSaved() {
    final b = bin;
    if (b == null) return;
    saved = Uint8List.fromList(b);
    _changed();
  }

  bool tableChanged(XdfTable t) {
    for (int r = 0; r < t.rows; r++) {
      for (int c = 0; c < t.cols; c++) {
        if (cellChanged(t, r, c)) return true;
      }
    }
    return false;
  }

  int get changedBytes {
    if (_cbRev == rev) return _cb;
    final b = bin, o = orig;
    int n = 0;
    if (b != null && o != null) {
      for (int k = 0; k < b.length; k++) {
        if (b[k] != o[k]) n++;
      }
    }
    _cbRev = rev;
    _cb = n;
    return n;
  }

  /// ค่าแกน (ตัวเลข) ถ้าแกนลิงก์ไปตารางอื่นหรืออ่านจาก BIN เอง ; แกนที่เป็นแค่ป้ายชื่อ = null
  List<double>? axisNums(XdfTable t, bool isX) {
    final ax = isX ? t.x : t.y;
    final n = isX ? t.cols : t.rows;
    final d = xdf, b = bin;
    if (d == null || b == null) return null;
    if (ax.link != null) {
      final lt = d.byId[ax.link];
      if (lt != null && lt.valid && lt != t) {
        final v = <double>[];
        for (int r = 0; r < lt.rows; r++) {
          for (int c = 0; c < lt.cols; c++) {
            v.add(val(lt, r, c));
          }
        }
        return [for (int k = 0; k < n; k++) k < v.length ? v[k] : double.nan];
      }
    }
    final ad = ax.data;
    if (ad != null && ad.addr >= 0 && ad.addr + ad.span <= b.length) {
      return [for (int k = 0; k < n; k++) k < ad.count ? ax.eq.f(rawAt(b, ad, ad.addrAt(k)).toDouble()) : double.nan];
    }
    return null;
  }

  int _axisDec(XdfTable t, bool isX) {
    final ax = isX ? t.x : t.y;
    final lt = ax.link == null ? null : xdf?.byId[ax.link];
    return (lt?.dec ?? ax.dec).clamp(0, 6).toInt();
  }

  List<String> axisLabels(XdfTable t, bool isX) {
    final n = isX ? t.cols : t.rows;
    final nums = axisNums(t, isX);
    if (nums != null) {
      final dec = _axisDec(t, isX);
      return [for (final v in nums) v.isNaN ? '-' : v.toStringAsFixed(dec)];
    }
    final ax = isX ? t.x : t.y;
    return [for (int k = 0; k < n; k++) (k < ax.labels.length && ax.labels[k].isNotEmpty) ? ax.labels[k] : '${k + 1}'];
  }

  // ----- เขียนค่า -----
  void _rawBytes(XdfData d, int a, int raw, List<int> addr, List<int> before, List<int> after) {
    final b = bin!;
    final n = d.bytes;
    final u = raw < 0 ? raw + (1 << (n * 8)) : raw;
    for (int k = 0; k < n; k++) {
      final p = a + (d.lsb ? k : n - 1 - k);
      if (p < 0 || p >= b.length) continue;
      final nv = (u >> (8 * k)) & 0xFF;
      if (b[p] != nv) {
        addr.add(p);
        before.add(b[p]);
        after.add(nv);
      }
    }
  }

  /// เขียนค่า (หน่วยที่แสดง) หลายช่อง ; คืนจำนวนไบต์ที่เปลี่ยน
  int write(XdfTable t, Map<(int, int), double> vals, String label, {bool merge = false}) {
    if (bin == null) return 0;
    final d = t.z;
    final nb = d.bytes * 8;
    final maxRaw = d.signed ? (1 << (nb - 1)) - 1 : (1 << nb) - 1;
    final minRaw = d.signed ? -(1 << (nb - 1)) : 0;
    final addr = <int>[], before = <int>[], after = <int>[];
    lastClamp = 0;
    final e0 = t.eq.f(minRaw.toDouble()), e1 = t.eq.f(maxRaw.toDouble());
    clampLo = math.min(e0, e1);
    clampHi = math.max(e0, e1);
    vals.forEach((rc, v) {
      final x = t.eq.inv(v, minRaw.toDouble(), maxRaw.toDouble());
      if (!x.isFinite) return;
      final xr = x.round();
      if (xr < minRaw || xr > maxRaw) lastClamp++; // เกินที่ข้อมูลเก็บได้ -> ตั้งไว้ที่ขอบ
      final raw = xr.clamp(minRaw, maxRaw).toInt();
      _rawBytes(d, d.addrOf(rc.$1, rc.$2), raw, addr, before, after);
    });
    return _commit(label, addr, before, after, merge);
  }

  int _commit(String label, List<int> addr, List<int> before, List<int> after, bool merge) {
    if (addr.isEmpty) return 0;
    final b = bin!;
    for (int k = 0; k < addr.length; k++) {
      b[addr[k]] = after[k];
    }
    _push(_Edit(label, addr, before, after, DateTime.now().millisecondsSinceEpoch), merge);
    _changed();
    return addr.length;
  }

  void _push(_Edit e, bool merge) {
    redoList.clear();
    if (merge && undoList.isNotEmpty && undoList.last.label == e.label && e.t - undoList.last.t < 800) {
      final o = undoList.removeLast();
      final bf = <int, int>{}, af = <int, int>{};
      for (int k = 0; k < o.addr.length; k++) {
        bf[o.addr[k]] = o.before[k];
        af[o.addr[k]] = o.after[k];
      }
      for (int k = 0; k < e.addr.length; k++) {
        bf.putIfAbsent(e.addr[k], () => e.before[k]);
        af[e.addr[k]] = e.after[k];
      }
      final ks = bf.keys.toList();
      e = _Edit(e.label, ks, [for (final k in ks) bf[k]!], [for (final k in ks) af[k]!], e.t);
    }
    undoList.add(e);
    if (undoList.length > 300) undoList.removeAt(0);
  }

  String? undo() {
    if (undoList.isEmpty || bin == null) return null;
    final e = undoList.removeLast();
    for (int k = e.addr.length - 1; k >= 0; k--) {
      bin![e.addr[k]] = e.before[k];
    }
    redoList.add(e);
    _changed();
    return e.label;
  }

  String? redo() {
    if (redoList.isEmpty || bin == null) return null;
    final e = redoList.removeLast();
    for (int k = 0; k < e.addr.length; k++) {
      bin![e.addr[k]] = e.after[k];
    }
    undoList.add(e);
    _changed();
    return e.label;
  }

  /// คืนค่าเดิมจากไฟล์ต้นฉบับ (ช่องที่ระบุ หรือทั้งไฟล์ถ้า cells = null)
  int revert(XdfTable? t, Iterable<(int, int)>? cells, String label) {
    final b = bin, o = orig;
    if (b == null || o == null) return 0;
    final addr = <int>[], before = <int>[], after = <int>[];
    void one(int p) {
      if (p >= 0 && p < b.length && b[p] != o[p]) {
        addr.add(p);
        before.add(b[p]);
        after.add(o[p]);
      }
    }

    if (t == null || cells == null) {
      for (int p = 0; p < b.length; p++) {
        one(p);
      }
    } else {
      for (final rc in cells) {
        final a = t.z.addrOf(rc.$1, rc.$2);
        for (int k = 0; k < t.z.bytes; k++) {
          one(a + k);
        }
      }
    }
    return _commit(label, addr, before, after, false);
  }

  bool flagOn(XdfFlag f, {bool original = false}) => (rawAt(original ? orig! : bin!, f.d, f.d.addr) & f.mask) != 0;

  void setFlag(XdfFlag f, bool on) {
    if (bin == null || !f.valid) return;
    final cur = rawAt(bin!, f.d, f.d.addr);
    final nv = on ? (cur | f.mask) : (cur & ~f.mask);
    final addr = <int>[], before = <int>[], after = <int>[];
    _rawBytes(f.d, f.d.addr, nv & ((1 << (f.d.bytes * 8)) - 1), addr, before, after);
    final m = commit;
    if (m != null) {
      for (int k = 0; k < addr.length; k++) {
        m[addr[k]] = after[k]; // FLAGS บันทึกทันทีที่กดสวิตช์
      }
    }
    _commit('FLAG ${f.title} ${on ? 'ON' : 'OFF'}', addr, before, after, false);
  }

  List<String> changedNames() {
    final d = xdf;
    if (d == null || bin == null) return const [];
    return [
      for (final t in d.tables)
        if (t.valid && tableChanged(t)) t.title,
      for (final f in d.flags)
        if (f.valid && flagOn(f) != flagOn(f, original: true)) 'FLAG ${f.title}',
    ];
  }

  /// ตารางรหัสล็อคกล่องที่ถูกแก้ : [(ตาราง, ค่าเดิม, ค่าใหม่)]
  List<(XdfTable, String, String)> lockChanges() {
    final d = xdf;
    if (d == null || bin == null) return const [];
    final out = <(XdfTable, String, String)>[];
    for (final t in d.tables) {
      if (!t.valid || !t.isLock || !tableChanged(t)) continue;
      String all(bool o) => [
            for (int r = 0; r < t.rows; r++)
              for (int c = 0; c < t.cols; c++) _lockStr(t, val(t, r, c, original: o)),
          ].join(', ');
      out.add((t, all(true), all(false)));
    }
    return out;
  }

  static String _lockStr(XdfTable t, double v) => '${v.round()} (0x${v.round().toRadixString(16).toUpperCase().padLeft(2, '0')})';

  String newFileName() {
    final n = binName ?? 'tune.bin';
    final dot = n.lastIndexOf('.');
    var stem = dot > 0 ? n.substring(0, dot) : n;
    stem = stem.replaceAll(RegExp(r'_MFB_\d{8}_\d{4}$'), '').replaceAll(RegExp(r'_\d+$'), ''); // ตัดวันที่/เลขลำดับเดิมออก
    if (stem.isEmpty) stem = 'tune';
    int k = 1;
    while (BinLib.i.exists('${stem}_$k')) {
      k++;
    }
    return '${stem}_$k.bin';
  }

}

/// หาตำแหน่ง (ทศนิยม) ของค่า v บนแกน a (รองรับแกนเรียงขึ้นหรือลง) ; อยู่นอกช่วง = ปลายที่ใกล้สุด
double? _axisFrac(List<double> a, double? v) {
  if (v == null || a.isEmpty) return null;
  if (a.length == 1) return 0;
  for (int k = 0; k < a.length - 1; k++) {
    final x0 = a[k], x1 = a[k + 1];
    if (x0.isNaN || x1.isNaN) continue;
    if (v >= math.min(x0, x1) && v <= math.max(x0, x1)) {
      return x1 == x0 ? k.toDouble() : k + (v - x0) / (x1 - x0);
    }
  }
  return (v - a.first).abs() < (v - a.last).abs() ? 0.0 : (a.length - 1).toDouble();
}

/// ชนิดแกนสำหรับ LIVE : 1 = รอบเครื่อง, 2 = คันเร่ง (%), 0 = ไม่รู้
int _axisKind(List<double>? a) {
  if (a == null) return 0;
  double mx = double.negativeInfinity;
  for (final v in a) {
    if (!v.isNaN && v > mx) mx = v;
  }
  if (mx > 400) return 1;
  if (mx > 1 && mx <= 110) return 2;
  return 0;
}

double _bilin(List<List<double>> v, double r, double c) {
  final nr = v.length, nc = v[0].length;
  final r0 = r.floor().clamp(0, nr - 1).toInt(), c0 = c.floor().clamp(0, nc - 1).toInt();
  final r1 = math.min(r0 + 1, nr - 1), c1 = math.min(c0 + 1, nc - 1);
  final fr = (r - r0).clamp(0.0, 1.0), fc = (c - c0).clamp(0.0, 1.0);
  final a = v[r0][c0] + (v[r0][c1] - v[r0][c0]) * fc;
  final b = v[r1][c0] + (v[r1][c1] - v[r1][c0]) * fc;
  return a + (b - a) * fr;
}

class _TP {
  static final Map<String, TextPainter> _m = {};
  static TextPainter get(String s, double fs, Color col, {bool bold = false, double maxW = double.infinity}) {
    final k = '$s|$fs|${col.hashCode}|$bold|$maxW';
    var tp = _m[k];
    if (tp == null) {
      if (_m.length > 2500) _m.clear();
      tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: fs, color: col, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: maxW);
      _m[k] = tp;
    }
    return tp;
  }

  static void center(Canvas cv, TextPainter tp, Offset c) => tp.paint(cv, c - Offset(tp.width / 2, tp.height / 2));
}

// ---------- ไฟล์ต้นฉบับ (ORIGINAL) ที่มากับแอพ : app/assets/original/ ----------
class OrigPack {
  final String name, bin, xdf, model;
  final List<int>? ecuId; // 5 ไบต์ ID กล่อง สำหรับจับคู่ "ไฟล์สำหรับรถคันนี้" (null = ยังไม่ระบุ)
  final int binKb, xdfKb;
  const OrigPack(this.name, this.bin, this.xdf, {this.model = '', this.ecuId, this.binKb = 0, this.xdfKb = 0});
  String get binName => bin.split('/').last;
  String get xdfName => xdf.split('/').last;
  // ตรงกับ ID กล่องที่ต่ออยู่หรือไม่
  bool matches(List<int>? ecm) {
    if (ecuId == null || ecm == null || ecuId!.length != ecm.length) return false;
    for (int i = 0; i < ecm.length; i++) {
      if (ecuId![i] != ecm[i]) return false;
    }
    return true;
  }
}

// ID กล่อง (5 ไบต์) -> ชื่อรุ่น  (คีย์เป็นเลขฐาน 16 เว้นวรรค ตัวใหญ่)
// สำรองไว้เผื่อโหลดฐานข้อมูลไม่สำเร็จ ; รายชื่อรุ่นหลัก 265 รุ่นมาจาก assets/ecm_database.json (ดู EcuDb)
const kEcuModels = <String, String>{
  '01 01 88 0D 01': 'Wave 110i (2019-2020)',
};
String ecmHex(List<int>? e) => e == null ? '' : e.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
String? ecuModelName(List<int>? e) {
  if (e == null) return null;
  final id = ecmHex(e);
  final m = EcuDb.model[id] ?? kEcuModels[id]; // ฐานข้อมูลก่อน แล้วค่อย fallback
  if (m != null && m.isNotEmpty) return m;
  for (final o in kOriginals) {
    if (o.matches(e) && o.model.isNotEmpty) return o.model;
  }
  return null;
}

// ฐานข้อมูล ECM จาก assets/ecm_database.json (ที่มา: repo josave-tuner) — ID -> รุ่น / offset / ชนิดกล่อง
class EcuDb {
  static final Map<String, String> model = {}; // "01 01 88 0D 01" -> ชื่อรุ่น
  static final Map<String, (int, int)> profile = {}; // ID -> (start_offset, checksum_offset)
  static final Map<String, String> type = {}; // ID -> 'keihin' / 'shindengen'
  static final Map<String, String> part = {}; // ID -> พาร์ทโค้ด
  static bool loaded = false;

  static String _fmtId(String raw) {
    final h = raw.replaceAll(' ', '').replaceAll('0x', '').toUpperCase();
    final b = <String>[];
    for (int i = 0; i + 2 <= h.length; i += 2) {
      b.add(h.substring(i, i + 2));
    }
    return b.join(' ');
  }

  static int? _hx(dynamic v) {
    if (v == null) return null;
    var s = v.toString().trim();
    if (s.isEmpty) return null;
    s = s.toLowerCase().replaceFirst('0x', '');
    return int.tryParse(s, radix: 16);
  }

  static Future<void> load() async {
    if (loaded) return;
    try {
      final raw = await rootBundle.loadString('assets/ecm_database.json');
      final d = json.decode(raw) as Map<String, dynamic>;
      for (final cat in d.keys) {
        final list = d[cat];
        if (list is! List) continue;
        for (final e in list) {
          if (e is! Map) continue;
          final id = _fmtId((e['ecm_id'] ?? '').toString());
          if (id.isEmpty) continue;
          model[id] = (e['model_name'] ?? '').toString();
          type[id] = cat.toString();
          part[id] = (e['part_code'] ?? '').toString();
          final so = _hx(e['start_offset']);
          final co = _hx(e['checksum_offset']);
          if (so != null && co != null) profile[id] = (so, co);
        }
      }
      loaded = true;
    } catch (_) {
      // โหลดไม่สำเร็จ -> ใช้ kEcuModels สำรองแทน
    }
  }
}

const kOriginals = <OrigPack>[
  OrigPack('K03-H01', 'assets/original/K03-H01.bin', 'assets/original/K03-H01.xdf',
      model: 'Wave 110i (2019-2020)', ecuId: [0x01, 0x01, 0x88, 0x0D, 0x01], binKb: 64, xdfKb: 17),
];

/// เลือกไฟล์จากเครื่องเฉพาะนามสกุลที่กำหนด (bin / xdf) ; คืน (ชื่อไฟล์, ไบต์) หรือ null
/// เลือกไฟล์จากมือถือ: เปิดตัวเลือกแบบ "ทุกไฟล์" เสมอ (Android บางเครื่องไม่รู้จัก .xdf/.bin แล้วแสดงไฟล์เป็นสีเทาเลือกไม่ได้)
/// anyName = true: ไม่ตรวจนามสกุล (ใช้กับ XDF — ตรวจจากเนื้อไฟล์แทน)
Future<(String, Uint8List)?> pickFileExt(String ext, void Function(String) err, {bool anyName = false}) async {
  FilePickerResult? r;
  try {
    r = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
  } catch (e) {
    err('เปิดตัวเลือกไฟล์ไม่ได้: $e');
    return null;
  }
  if (r == null || r.files.isEmpty) return null;
  final f = r.files.single;
  if (!anyName && !f.name.toLowerCase().endsWith('.${ext.toLowerCase()}')) {
    err('เลือกได้เฉพาะไฟล์ .$ext');
    return null;
  }
  var b = f.bytes;
  if ((b == null || b.isEmpty) && f.path != null) {
    try {
      b = await io.File(f.path!).readAsBytes();
    } catch (_) {}
  }
  if (b == null || b.isEmpty) {
    err('อ่านไฟล์ไม่ได้');
    return null;
  }
  return (f.name, b);
}

// ---------- หน้าต่างเลือกเกจ (กด "เชื่อมต่อ") : เกจแต่ละตัวชื่อไม่ซ้ำ MFB-PRO-XXXX ----------
Future<void> pickGauge(BuildContext context, GaugeController c) async {
  if (!await c.prepareBle()) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('เปิดบลูทูธก่อน แล้วกดเชื่อมต่ออีกครั้ง')));
    }
    return;
  }
  if (!context.mounted) return;
  final th = Cfg.i.t;
  final found = <String, ScanResult>{};
  bool scanning = true;
  StreamSubscription? sub, run;
  void Function(void Function())? setD;
  Future<void> scan() async {
    found.clear();
    scanning = true;
    setD?.call(() {});
    await c.startPickScan();
  }

  sub = FlutterBluePlus.scanResults.listen((rs) {
    for (final r in rs) {
      found[r.device.remoteId.str] = r;
    }
    setD?.call(() {});
  });
  run = FlutterBluePlus.isScanning.listen((v) {
    scanning = v;
    setD?.call(() {});
  });
  scan();
  final picked = await showDialog<ScanResult>(
    context: context,
    builder: (dctx) => StatefulBuilder(builder: (dctx, sd) {
      setD = sd;
      final list = found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
      String nm(ScanResult r) {
        final a = r.advertisementData.advName;
        return a.isNotEmpty ? a : (r.device.platformName.isNotEmpty ? r.device.platformName : 'MFB-PRO');
      }

      Widget bars(int rssi) {
        final lvl = rssi > -55 ? 4 : rssi > -67 ? 3 : rssi > -78 ? 2 : 1;
        return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (int k = 0; k < 4; k++)
            Container(width: 5, height: 6.0 + k * 4, margin: const EdgeInsets.only(right: 2), color: k < lvl ? th.c : Colors.white24),
        ]);
      }

      return AlertDialog(
        backgroundColor: const Color(0xFF14141A),
        shape: HudBorder(cut: 13, side: BorderSide(color: th.c, width: 1.3)),
        title: Row(children: [
          Expanded(child: Text('เลือกเกจที่จะเชื่อมต่อ', style: TextStyle(fontSize: 17, color: th.c, fontWeight: FontWeight.bold))),
          if (scanning) const Text('กำลังสแกน…', style: TextStyle(fontSize: 12.5, color: kAmber)),
        ]),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(list.isEmpty ? (scanning ? 'กำลังค้นหาเกจ MFB-PRO ใกล้ ๆ …' : 'ไม่พบเกจ — เปิดเกจ และตรวจว่าเปิด MOBILE APP (BLE) = ON')
                : 'พบ ${list.length} เกจ เรียงจากสัญญาณแรงสุด (ใกล้สุด)',
                style: const TextStyle(fontSize: 12.5, color: Colors.white60)),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView(shrinkWrap: true, children: [
                for (final r in list)
                  Builder(builder: (_) {
                    final last = r.device.remoteId.str == c.gaugeId;
                    return InkWell(
                      onTap: () => Navigator.of(dctx).pop(r),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                        decoration: hudDeco(border: last ? th.c : Colors.white24, width: last ? 1.5 : 1, radius: 10, color: last ? th.c.withOpacity(0.18) : Colors.white.withOpacity(0.04)),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(nm(r), style: const TextStyle(fontFamily: kFont, fontSize: 13)),
                              if (last) const Text('เชื่อมต่อล่าสุด', style: TextStyle(fontSize: 11.5, color: kGreen)),
                            ]),
                          ),
                          bars(r.rssi),
                          const SizedBox(width: 8),
                          Text('${r.rssi} dBm', style: const TextStyle(fontSize: 11.5, color: Colors.white54)),
                          Icon(Icons.chevron_right, color: last ? th.c : Colors.white38),
                        ]),
                      ),
                    );
                  }),
              ]),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: scanning ? null : scan, child: const Text('สแกนใหม่')),
          TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('ยกเลิก')),
        ],
      );
    }),
  );
  setD = null;
  await sub?.cancel();
  await run?.cancel();
  if (picked == null) {
    await c.stopPickScan();
    return;
  }
  final a = picked.advertisementData.advName;
  await c.connectTo(picked.device, a.isNotEmpty ? a : picked.device.platformName);
}

class _TriPainter extends CustomPainter {
  final Color c;
  _TriPainter(this.c);
  @override
  void paint(Canvas canvas, Size z) =>
      canvas.drawPath(Path()..moveTo(0, z.height)..lineTo(z.width / 2, 0)..lineTo(z.width, z.height)..close(), Paint()..color = c);
  @override
  bool shouldRepaint(_TriPainter o) => o.c != c;
}

// ---------- AFR LOG: เก็บค่า AFR สดลงตาราง RPM × TPS (แกนเดียวกับตารางน้ำมัน) ----------
// ดูอย่างเดียว ไม่เขียนลง BIN | เก็บเป็นค่าเฉลี่ยสะสมต่อช่อง + จำนวนครั้ง | บันทึกลงเครื่องทุก ~10 วินาที (Documents/afr_log.json)
// แกนเริ่มต้นของหน้า AFR LOG เมื่อยังไม่ได้เปิด XDF : RPM 29 แถว (1000..9400) × TPS 25 คอลัมน์ (0..100%)
final List<double> kAfrDefRpm = [for (int i = 0; i <= 44; i++) (800 + i * 300).toDouble()]; // 800..14000 (45 แถว) เลื่อนดูได้
final List<double> kAfrDefTps = [for (int i = 0; i < 25; i++) i * 100 / 24];

class AfrLog extends ChangeNotifier {
  static final AfrLog i = AfrLog._();
  AfrLog._();

  List<double> rpm = const [], tps = const []; // แกนแถว (RPM) / แกนคอลัมน์ (TPS)
  String src = ''; // ตารางที่ใช้แกน
  List<List<double>> sum = const [];
  List<List<int>> cnt = const [];
  (int, int)? liveCell;
  bool rec = true; // บันทึกอยู่
  GaugeController? _c;
  Telemetry? _lastT;
  int _lastMs = 0, _saveMs = 0;
  bool _dirty = false, _loaded = false, _isDefault = false;

  int get rows => rpm.length;
  int get cols => tps.length;
  bool get ready => rows > 1 && cols > 1;
  int get filled {
    int n = 0;
    for (final r in cnt) {
      for (final k in r) {
        if (k > 0) n++;
      }
    }
    return n;
  }

  double? at(int r, int c) => cnt[r][c] > 0 ? sum[r][c] / cnt[r][c] : null;

  /// ตั้งแกนเริ่มต้น 29×25 (RPM × TPS) เมื่อยังไม่ได้เปิด XDF — ให้หน้า AFR LOG ใช้งาน/จำลองได้ทันที
  /// ถ้าเปิด XDF ในหน้า TUNE ภายหลัง syncAxes จะแทนที่ด้วยแกนจริงของตารางน้ำมันเอง
  void ensureDefault() {
    if (ready) return;
    rpm = kAfrDefRpm;
    tps = kAfrDefTps;
    src = 'ค่าเริ่มต้น ${kAfrDefRpm.length}×${kAfrDefTps.length}';
    _isDefault = true;
    sum = [for (int k = 0; k < rows; k++) List<double>.filled(cols, 0)];
    cnt = [for (int k = 0; k < rows; k++) List<int>.filled(cols, 0)];
    _restore();
    notifyListeners();
  }

  void attach(GaugeController c) {
    if (identical(_c, c)) return;
    _c?.removeListener(_feed);
    _c = c;
    c.addListener(_feed);
  }

  /// ตั้งแกนจาก XDF ที่เปิดอยู่: ตาราง 2D ที่มีแกน RPM + TPS (เลือก 29×25 / ชื่อ "น้ำมัน" ก่อน)
  XdfDef? _ref;
  void syncAxes(TuneSession s) {
    final d = s.xdf;
    if (d == null || s.bin == null) return;
    if (identical(d, _ref) && ready) return; // XDF เดิม: แกนเดิม
    XdfTable? best;
    bool rpmOnRows = true;
    int bestScore = -1;
    for (final t in d.tables) {
      if (!t.valid || !t.is2D) continue;
      final ky = _axisKind(s.axisNums(t, false)), kx = _axisKind(s.axisNums(t, true));
      final onRows = ky == 1 && kx == 2, onCols = ky == 2 && kx == 1;
      if (!onRows && !onCols) continue;
      int sc = 1;
      if ((onRows && t.rows == 29 && t.cols == 25) || (onCols && t.rows == 25 && t.cols == 29)) sc += 4;
      final tl = t.title.toLowerCase();
      if (tl.contains('น้ำมัน') || tl.contains('fuel') || tl.contains('inj')) sc += 2;
      if (sc > bestScore) {
        bestScore = sc;
        best = t;
        rpmOnRows = onRows;
      }
    }
    if (best == null) return;
    _ref = d;
    final r = s.axisNums(best, !rpmOnRows)!, c = s.axisNums(best, rpmOnRows)!;
    final nr = rpmOnRows ? best.rows : best.cols, nc = rpmOnRows ? best.cols : best.rows;
    final nrpm = r.sublist(0, nr), ntps = c.sublist(0, nc);
    final same = !_isDefault && rows == nr && cols == nc;
    rpm = nrpm;
    tps = ntps;
    src = best.title;
    _isDefault = false;
    if (!same) {
      sum = [for (int k = 0; k < nr; k++) List<double>.filled(nc, 0)];
      cnt = [for (int k = 0; k < nr; k++) List<int>.filled(nc, 0)];
      _restore();
    }
    notifyListeners();
  }

  void _feed() {
    final c = _c;
    if (c == null || !ready) return;
    final t = c.t;
    if (identical(t, _lastT)) return;
    _lastT = t;
    final live = c.demo || c.ecuLive;
    final a = t.afr, rp = t.rpm, tp = t.tps;
    if (!live || a == null || rp == null || tp == null || !a.isFinite || a < 8 || a > 22) {
      if (liveCell != null) {
        liveCell = null;
        notifyListeners();
      }
      return;
    }
    final fr = _axisFrac(rpm, rp), fc = _axisFrac(tps, tp);
    if (fr == null || fc == null) return;
    final r = fr.round().clamp(0, rows - 1).toInt(), cc = fc.round().clamp(0, cols - 1).toInt();
    liveCell = (r, cc);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (rec && now - _lastMs >= 90) {
      _lastMs = now;
      sum[r][cc] += a;
      cnt[r][cc]++;
      _dirty = true;
      if (now - _saveMs > 10000) _save();
    }
    notifyListeners();
  }

  void clear() {
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        sum[r][c] = 0;
        cnt[r][c] = 0;
      }
    }
    _dirty = true;
    _save();
    notifyListeners();
  }

  void toggleRec() {
    rec = !rec;
    if (!rec) _save();
    notifyListeners();
  }

  Future<io.File> _file() async => io.File('${(await getApplicationDocumentsDirectory()).path}/afr_log.json');

  Future<void> _save() async {
    _saveMs = DateTime.now().millisecondsSinceEpoch;
    if (!_dirty || !ready) return;
    _dirty = false;
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({'rpm': rpm, 'tps': tps, 'sum': sum, 'cnt': cnt}));
    } catch (_) {}
  }

  /// โหลดข้อมูลเก่าถ้าแกนตรงกัน (เปิดแอพใหม่แล้วข้อมูลไม่หาย)
  Future<void> _restore() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      final r = [for (final v in j['rpm'] as List) (v as num).toDouble()];
      final c = [for (final v in j['tps'] as List) (v as num).toDouble()];
      if (r.length != rows || c.length != cols) return;
      for (int k = 0; k < rows; k++) {
        if ((r[k] - rpm[k]).abs() > 1) return;
      }
      for (int k = 0; k < cols; k++) {
        if ((c[k] - tps[k]).abs() > 0.5) return;
      }
      final sj = j['sum'] as List, cj = j['cnt'] as List;
      for (int a = 0; a < rows; a++) {
        for (int b = 0; b < cols; b++) {
          sum[a][b] = ((sj[a] as List)[b] as num).toDouble();
          cnt[a][b] = ((cj[a] as List)[b] as num).toInt();
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  void flush() => _save();
}

/// สี AFR: หนา (ต่ำ) = แดง .. 14.7 = เขียว .. บาง (สูง) = ฟ้า/น้ำเงิน
Color _afrColor(double v) {
  const stops = <Color>[Color(0xFFD81B3C), Color(0xFFF0961E), Color(0xFF2ED278), Color(0xFF2896E8), Color(0xFF505ADC)];
  final t = ((v - 11.5) / (16.5 - 11.5)).clamp(0.0, 1.0).toDouble();
  final p = t * (stops.length - 1);
  final k = p.floor().clamp(0, stops.length - 2).toInt();
  return Color.lerp(stops[k], stops[k + 1], p - k)!;
}

// ---------- AFR → จูนอัตโนมัติ: คำนวณ % น้ำมันที่ควรปรับต่อช่องจาก AFR LOG ----------
class AfrTunePage extends StatefulWidget {
  final TuneSession s;
  final XdfTable t;
  const AfrTunePage({super.key, required this.s, required this.t});
  @override
  State<AfrTunePage> createState() => _AfrTunePageState();
}

class _AfrTunePageState extends State<AfrTunePage> {
  static double target = 13.2, targetWot = 12.8, wotTps = 60, maxPct = 10, strength = 0.5;
  static int minCnt = 20;

  TuneSession get s => widget.s;
  XdfTable get t => widget.t;

  /// % ที่ควรปรับต่อช่อง (null = ข้อมูลไม่พอ) : + = เพิ่มน้ำมัน (AFR บาง), − = ลด (AFR หนา)
  List<List<double?>> _calc() {
    final lg = AfrLog.i;
    final ys = s.axisNums(t, false)!, xs = s.axisNums(t, true)!;
    final rpmOnRows = _axisKind(ys) == 1;
    return [
      for (int r = 0; r < t.rows; r++)
        [
          for (int c = 0; c < t.cols; c++)
            () {
              final rpm = rpmOnRows ? ys[r] : xs[c], tps = rpmOnRows ? xs[c] : ys[r];
              if (rpm.isNaN || tps.isNaN) return null;
              final fr = _axisFrac(lg.rpm, rpm), fc = _axisFrac(lg.tps, tps);
              if (fr == null || fc == null) return null;
              final lr = fr.round().clamp(0, lg.rows - 1).toInt(), lc = fc.round().clamp(0, lg.cols - 1).toInt();
              if (lg.cnt[lr][lc] < minCnt) return null;
              final afr = lg.at(lr, lc);
              if (afr == null) return null;
              final tg = tps >= wotTps ? targetWot : target;
              final p = ((afr / tg - 1) * 100 * strength).clamp(-maxPct, maxPct).toDouble();
              return (p * 10).round() / 10;
            }(),
        ],
    ];
  }

  Future<void> _edit(String title, double v, double step, double lo, double hi, void Function(double) set, {int dec = 1}) async {
    final ctl = TextEditingController(text: v.toStringAsFixed(dec));
    final r = await showDialog<double>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: const Color(0xFF14141A),
        title: Text(title, style: const TextStyle(fontSize: 15)),
        content: TextField(controller: ctl, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true)),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).pop(), child: const Text('ยกเลิก')),
          TextButton(onPressed: () => Navigator.of(d).pop(double.tryParse(ctl.text.trim())), child: const Text('ตกลง')),
        ],
      ),
    );
    if (r != null) setState(() => set(r.clamp(lo, hi).toDouble()));
  }

  @override
  Widget build(BuildContext context) {
    final th = Cfg.i.t;
    final p = _calc();
    int n = 0;
    double sum = 0;
    final out = <(int, int), double>{};
    for (int r = 0; r < t.rows; r++) {
      for (int c = 0; c < t.cols; c++) {
        final v = p[r][c];
        if (v == null || v == 0) continue;
        n++;
        sum += v;
        out[(r, c)] = s.val(t, r, c) * (1 + v / 100);
      }
    }
    Widget opt(String a, String b, String sub, VoidCallback f) => InkWell(
          onTap: f,
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.fromLTRB(9, 5, 9, 5),
            decoration: hudDeco(border: Colors.white24, width: 1, radius: 8, color: Colors.white.withOpacity(0.03), tick: false),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(a, style: const TextStyle(fontSize: 11.5, color: Colors.white70))),
                Text(b, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
              ]),
              Text(sub, style: const TextStyle(fontSize: 9.5, color: Colors.white38)),
            ]),
          ),
        );
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        Image.asset('assets/bg.jpg', fit: BoxFit.cover),
        Container(color: Colors.black.withOpacity(0.84)),
        const HudGrid(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: Column(children: [
              SizedBox(
                height: 32,
                child: Row(children: [
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    child: Row(children: [
                      Icon(Icons.chevron_left, color: th.c, size: 26),
                      Text('AFR AUTO-TUNE', style: TextStyle(fontFamily: kFont, fontSize: 13, color: th.c, shadows: [Shadow(color: th.c, blurRadius: 8)])),
                    ]),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Text('ตาราง: ${t.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white70))),
                ]),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: hudDeco(border: th.c.withOpacity(0.85), width: 1.1, radius: 12, color: const Color(0xCC060606)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Expanded(
                              child: Text('น้ำมันที่ควรปรับ (%) · AFR LOG ${AfrLog.i.filled} ช่อง',
                                  style: const TextStyle(fontSize: 10.5, color: Colors.white54))),
                          const Text('■ เพิ่มน้ำมัน (บาง)  ', style: TextStyle(fontSize: 10, color: Color(0xFFFF7A5A))),
                          const Text('■ ลดน้ำมัน (หนา)', style: TextStyle(fontSize: 10, color: Color(0xFF5AA0FF))),
                        ]),
                        const SizedBox(height: 4),
                        Expanded(child: CustomPaint(size: Size.infinite, painter: _PctGridPainter(p, s.axisNums(t, false)!, s.axisNums(t, true)!))),
                      ]),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 214,
                    padding: const EdgeInsets.all(8),
                    decoration: hudDeco(border: th.c.withOpacity(0.85), width: 1.1, radius: 12, color: const Color(0xCC060606)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(children: [
                            opt('AFR เป้าหมาย', target.toStringAsFixed(1), 'ช่วงปกติ (TPS < ${wotTps.round()}%)',
                                () => _edit('AFR เป้าหมาย', target, 0.1, 10, 16, (v) => target = v)),
                            opt('AFR ช่วงเร่ง', targetWot.toStringAsFixed(1), 'TPS ≥ ${wotTps.round()}%',
                                () => _edit('AFR ช่วงเร่ง', targetWot, 0.1, 10, 16, (v) => targetWot = v)),
                            opt('เริ่มช่วงเร่งที่ TPS', '${wotTps.round()} %', 'ตั้ง 100 = ใช้เป้าหมายเดียวทั้งตาราง',
                                () => _edit('TPS ช่วงเร่ง (%)', wotTps, 1, 0, 100, (v) => wotTps = v, dec: 0)),
                            opt('ข้อมูลขั้นต่ำ/ช่อง', '$minCnt ครั้ง', 'ช่องที่ข้อมูลน้อยกว่านี้ข้าม (·)',
                                () => _edit('ข้อมูลขั้นต่ำ/ช่อง', minCnt.toDouble(), 1, 1, 1000, (v) => minCnt = v.round(), dec: 0)),
                            opt('ปรับสูงสุด', '± ${maxPct.toStringAsFixed(0)} %', 'กันค่ากระโดด',
                                () => _edit('ปรับสูงสุด (%)', maxPct, 1, 1, 50, (v) => maxPct = v, dec: 0)),
                            opt('ความแรง', strength.toStringAsFixed(2), '1 = ปรับเต็ม %, 0.5 = ครึ่งเดียว',
                                () => _edit('ความแรง (0.05 – 1)', strength, 0.05, 0.05, 1, (v) => strength = v, dec: 2)),
                          ]),
                        ),
                      ),
                      Text.rich(TextSpan(style: const TextStyle(fontSize: 11, color: Colors.white70), children: [
                        const TextSpan(text: 'จะแก้ '),
                        TextSpan(text: '$n', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        const TextSpan(text: ' ช่อง · เฉลี่ย '),
                        TextSpan(
                            text: n == 0 ? '-' : '${sum / n > 0 ? '+' : ''}${(sum / n).toStringAsFixed(1)}%',
                            style: TextStyle(color: n == 0 ? Colors.white54 : (sum > 0 ? const Color(0xFFFF7A5A) : const Color(0xFF5AA0FF)), fontWeight: FontWeight.bold)),
                      ])),
                      const SizedBox(height: 6),
                      Opacity(
                        opacity: n == 0 ? 0.4 : 1,
                        child: InkWell(
                          onTap: n == 0 ? null : () => Navigator.of(context).pop(out),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            alignment: Alignment.center,
                            decoration: hudDeco(border: th.c, width: 1.4, radius: 9, color: th.c.withOpacity(0.35)),
                            child: Text('✓ ใส่ลงตาราง', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text('แก้แล้วย้อนกลับ (↶) ได้ · ยังไม่แฟลช', textAlign: TextAlign.center, style: TextStyle(fontSize: 9.5, color: Colors.white38)),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// ตาราง % (ใช้ในหน้า AFR AUTO-TUNE)
class _PctGridPainter extends CustomPainter {
  final List<List<double?>> p;
  final List<double> ys, xs;
  _PctGridPainter(this.p, this.ys, this.xs);
  @override
  void paint(Canvas canvas, Size size) {
    final nr = p.length, nc = nr == 0 ? 0 : p[0].length;
    if (nr == 0 || nc == 0) return;
    const hw = 40.0, hh = 16.0;
    final cw = (size.width - hw) / nc, ch = (size.height - hh) / nr;
    final fs = math.min(math.min(ch * 0.62, cw * 0.3), 11.0);
    String ax(double v) => v.isNaN ? '' : (v.abs() >= 100 ? v.round().toString() : v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, hh), Paint()..color = const Color(0xFF1A1A20));
    canvas.drawRect(Rect.fromLTWH(0, 0, hw, size.height), Paint()..color = const Color(0xFF1A1A20));
    for (int c = 0; c < nc; c++) {
      if (fs >= 4) _TP.center(canvas, _TP.get(ax(c < xs.length ? xs[c] : double.nan), math.min(fs, 9.0), Colors.white60, maxW: cw), Offset(hw + (c + 0.5) * cw, hh / 2));
    }
    for (int r = 0; r < nr; r++) {
      _TP.center(canvas, _TP.get(ax(r < ys.length ? ys[r] : double.nan), math.min(math.max(fs, 6.0), 9.0), Colors.white60, maxW: hw), Offset(hw / 2, hh + (r + 0.5) * ch));
      for (int c = 0; c < nc; c++) {
        final v = p[r][c];
        final rect = Rect.fromLTWH(hw + c * cw, hh + r * ch, cw, ch).deflate(0.5);
        Color col;
        if (v == null) {
          col = const Color(0xFF121216);
        } else {
          final k = (v.abs() / 8).clamp(0.0, 1.0).toDouble();
          col = v > 0 ? Color.lerp(const Color(0xFF28282F), const Color(0xFFFF5A3C), k)! : Color.lerp(const Color(0xFF28282F), const Color(0xFF3C96FF), k)!;
        }
        canvas.drawRect(rect, Paint()..color = col);
        if (fs >= 4) {
          _TP.center(canvas, _TP.get(v == null ? '·' : '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)}', fs, v == null ? Colors.white24 : Colors.white, maxW: cw), rect.center);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_PctGridPainter o) => true;
}

class AfrLogPage extends StatefulWidget {
  final GaugeController c;
  const AfrLogPage({super.key, required this.c});
  @override
  State<AfrLogPage> createState() => _AfrLogPageState();
}

class _AfrLogPageState extends State<AfrLogPage> {
  final log = AfrLog.i;
  Size _sz = Size.zero;

  void _rb() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    log.attach(widget.c);
    log.addListener(_rb);
    Cfg.i.addListener(_rb);
  }

  @override
  void dispose() {
    log.removeListener(_rb);
    Cfg.i.removeListener(_rb);
    log.flush();
    super.dispose();
  }

  void _tapCell(Offset p) {
    if (!log.ready) return;
    final g = _AfrPainter.geom(_sz, log.rows, log.cols);
    final c = ((p.dx - g.$1) / g.$3).floor(), r = ((p.dy - g.$2) / g.$4).floor();
    if (r < 0 || c < 0 || r >= log.rows || c >= log.cols) return;
    final v = log.at(r, c);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 2),
          content: Text('RPM ${log.rpm[r].toStringAsFixed(0)} · TPS ${log.tps[c].toStringAsFixed(1)} : '
              '${v == null ? 'ยังไม่มีข้อมูล' : 'AFR ${v.toStringAsFixed(2)} (${log.cnt[r][c]} ครั้ง)'}')));
  }

  Widget _btn(String t, Color col, VoidCallback? f, {bool active = false}) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: InkWell(
          onTap: f,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: hudDeco(border: col, width: 1.3, radius: 8, color: active ? col.withOpacity(0.22) : Colors.black45),
            child: Text(t, style: TextStyle(fontSize: 13, color: col, fontWeight: FontWeight.bold)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final th = Cfg.i.t;
    final live = widget.c.demo || widget.c.ecuLive;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Column(children: [
            SizedBox(
              height: 36,
              child: Row(children: [
                InkWell(
                  onTap: () => Navigator.of(context).pop(),
                  child: Row(children: [
                    Icon(Icons.chevron_left, color: th.c, size: 26),
                    Text('AFR LOG', style: TextStyle(fontFamily: kFont, fontSize: 15, color: th.c, shadows: [Shadow(color: th.c, blurRadius: 8)])),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                      log.ready
                          ? '${log.rows}×${log.cols} · แกนจาก "${log.src}" · บันทึกแล้ว ${log.filled} ช่อง${live ? '' : ' · ยังไม่มีข้อมูลสด (ต่อเกจ/เปิด DEMO)'}'
                          : 'เปิด BIN + XDF ในหน้า TUNE ก่อน (ใช้แกน RPM/TPS จากตารางน้ำมัน)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: live ? Colors.white70 : kAmber)),
                ),
                _btn(log.rec ? '● REC' : '❚❚ หยุด', log.rec ? kGreen : kAmber, log.ready ? log.toggleRec : null, active: true),
                _btn('ล้าง', th.c, log.ready
                    ? () async {
                        if (await askYes(context, 'ล้าง AFR LOG', 'ลบค่าที่บันทึกไว้ทั้งหมด?', ok: 'ล้าง', col: kBad)) log.clear();
                      }
                    : null),
              ]),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Container(
                decoration: hudDeco(border: th.c.withOpacity(0.85), width: 1.1, radius: 10, color: const Color(0xCC060606)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: log.ready
                      ? LayoutBuilder(builder: (_, cs) {
                          final h = _AfrPainter.hh + log.rows * _AfrPainter.rh;
                          _sz = Size(cs.maxWidth, h);
                          return SingleChildScrollView(
                            child: GestureDetector(
                              onTapUp: (d) => _tapCell(d.localPosition),
                              child: CustomPaint(size: Size(cs.maxWidth, h), painter: _AfrPainter(log, th)),
                            ),
                          );
                        })
                      : const Center(child: Text('ยังไม่มีตาราง', style: TextStyle(color: Colors.white54))),
                ),
              ),
            ),
            SizedBox(
              height: 22,
              child: Row(children: [
                Container(
                  width: 140, height: 8,
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      gradient: LinearGradient(colors: [for (int k = 0; k <= 10; k++) _afrColor(11.5 + k * 0.5)])),
                ),
                const SizedBox(width: 6),
                const Text('11.5 หนา · 14.7 · 16.5 บาง', style: TextStyle(fontSize: 10.5, color: Colors.white60)),
                const Spacer(),
                const Text('ช่องทึบ = บันทึกหลายครั้ง · ช่องมืด = ยังไม่มีข้อมูล · กรอบขาว = ตำแหน่งเครื่องตอนนี้ · แตะช่อง = ดูรายละเอียด',
                    style: TextStyle(fontSize: 10.5, color: Colors.white54)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _AfrPainter extends CustomPainter {
  final AfrLog log;
  final AppTheme th;
  _AfrPainter(this.log, this.th);

  static const double hw = 40, hh = 18, rh = 20;   // rh = ความสูงคงที่ต่อแถว (ถ้าเกินจอให้เลื่อนดู ไม่ย่อ)
  /// (x0, y0, cw, ch) ของช่องข้อมูล — ความสูงแถวคงที่ (rh) ไม่ขึ้นกับความสูงจอ
  static (double, double, double, double) geom(Size s, int rows, int cols) =>
      (hw, hh, (s.width - hw) / cols, rh);

  @override
  void paint(Canvas canvas, Size size) {
    final rows = log.rows, cols = log.cols;
    final g = geom(size, rows, cols);
    final gx = g.$1, gy = g.$2, cw = g.$3, ch = g.$4;
    final hp = Paint()..color = const Color(0xFF1A1A20);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, hh), hp);
    canvas.drawRect(Rect.fromLTWH(0, 0, hw, size.height), hp);
    final hs = math.min(9.5, cw * 0.3);
    _TP.center(canvas, _TP.get('RPM\\TPS', 7.5, Colors.white54), Offset(hw / 2, hh / 2));
    for (int c = 0; c < cols; c++) {
      final v = log.tps[c];
      _TP.center(canvas, _TP.get(v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1), hs, Colors.white70, maxW: cw), Offset(gx + c * cw + cw / 2, hh / 2));
    }
    final rs = math.min(9.5, ch * 0.7);
    for (int r = 0; r < rows; r++) {
      _TP.center(canvas, _TP.get(log.rpm[r].toStringAsFixed(0), rs, Colors.white70, maxW: hw), Offset(hw / 2, gy + r * ch + ch / 2));
    }
    final empty = Paint()..color = const Color(0xFF121216);
    final line = Paint()
      ..color = const Color(0xFF26262C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    final fill = Paint();
    final fs = math.min(ch * 0.66, math.min(cw * 0.28, 11.0));
    int maxN = 1;
    for (final r in log.cnt) {
      for (final k in r) {
        if (k > maxN) maxN = k;
      }
    }
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final rect = Rect.fromLTWH(gx + c * cw, gy + r * ch, cw, ch);
        final v = log.at(r, c);
        if (v == null) {
          canvas.drawRect(rect, empty);
          canvas.drawRect(rect, line);
          continue;
        }
        final a = (0.4 + 0.6 * math.min(1.0, log.cnt[r][c] / math.max(10, maxN * 0.5))).clamp(0.0, 1.0);
        fill.color = Color.lerp(const Color(0xFF121216), _afrColor(v), a)!;
        canvas.drawRect(rect.deflate(0.3), fill);
        if (fs >= 4.5) _TP.center(canvas, _TP.get(v.toStringAsFixed(1), fs, const Color(0xFF000000), maxW: cw), rect.center);
      }
    }
    final lc = log.liveCell;
    if (lc != null) {
      final rect = Rect.fromLTWH(gx + lc.$2 * cw, gy + lc.$1 * ch, cw, ch);
      canvas.drawRect(rect.inflate(1), Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4);
    }
  }

  @override
  bool shouldRepaint(_AfrPainter o) => true;
}

// ---------- หน้า TUNE ----------
class TunePage extends StatefulWidget {
  final GaugeController c;
  final BinEntry? initial; // เปิดหน้ามาพร้อมไฟล์จากคลัง (จากสมุดลูกค้า)
  const TunePage({super.key, required this.c, this.initial});
  @override
  State<TunePage> createState() => _TunePageState();
}

class _TunePageState extends State<TunePage> {
  final s = TuneSession.i;
  GaugeController get c => widget.c;

  // สถานะกาง/พับแต่ละหมวดของเมนูตารางจูน — จำไว้ข้ามการเปิดเมนู (ผู้ใช้กดพับไว้ ครั้งหน้าก็ยังพับ)
  bool _mnF = false, _mn2 = true, _mn1 = false;

  // ตาราง 2D
  double cw = 54, ch = 24, sx = 0, sy = 0;
  static const double hh = 24;
  double hw = 58;
  Size view = Size.zero;
  (int, int)? a0, a1; // จุดเริ่ม/จุดปลายของการเลือก
  int _shownSel = -2;
  int _gMode = 0; // 0 ไม่มี, 1 เลือกช่อง, 2 ซูม/เลื่อน 2 นิ้ว, 3 เลื่อนแนวนอน (หัวคอลัมน์), 4 เลื่อนแนวตั้ง (หัวแถว), 5 มุมซ้ายบน
  Offset _gStart = Offset.zero, _gLast = Offset.zero;
  bool _gMoved = false;
  double _cw0 = 54, _ch0 = 24, _fcx = 0, _fcy = 0;
  int _gDown = -1, _lastTouch = 0, _lastTapMs = 0;
  (int, int)? _lastTapCell;

  // มุมมอง
  bool view3d = false, live = true;
  bool showPct = false; // โหมด Δ% เทียบไฟล์อ้างอิง
  int stepMul = 1;
  double yaw = -0.85, pitch = 0.62, zoom = 1, _zoom0 = 1;
  Offset pan3 = Offset.zero, _pan0 = Offset.zero, _mid0 = Offset.zero; // 2 นิ้วลาก = เลื่อนกราฟ 3D
  Timer? _spin;
  bool _adjOpen = false; // แผง "ปรับค่า" กางอยู่
  final _adjKey = GlobalKey(), _bodyKey = GlobalKey();
  // 3D: 0 ไม่มี, 1 หมุน/ซูม, 2 ลากจุดขึ้น-ลงแก้ค่า, 3 แตะ 2 ครั้งแล้วลากคลุมเพื่อเลือก
  int _m3 = 0, _ptrs = 0, _downMs = 0, _tapUpMs = 0;
  Size _v3 = Size.zero;
  Offset _downPos = Offset.zero, _tapUpPos = Offset.zero;
  bool _dblArm = false;
  Offset? _boxA, _boxB;
  Map<(int, int), double> _dragBase = {};
  double _dragDy = 0;
  double? _fLo, _fHi; // ล็อกสเกลแกน Z ระหว่างลากแก้ค่า
  bool _asking = false;
  final amtCtl = TextEditingController();
  final _tblKey = GlobalKey();

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onLive() {
    if (live && mounted) setState(() {});
  }

  void _syncAfr() => AfrLog.i.syncAxes(s);

  @override
  void initState() {
    super.initState();
    s.addListener(_rebuild);
    s.addListener(_syncAfr);
    Cfg.i.addListener(_rebuild);
    c.addListener(_onLive);
    AfrLog.i.attach(c);
    _syncAfr();
    final e = widget.initial;
    if (e != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        if (_hasEdits && !await _confirm('เปิด ${e.name}', 'ค่าที่แก้ใน BIN ปัจจุบันจะหายไป', ok: 'เปิดไฟล์')) return;
        await _openEntry(e);
      });
    }
  }

  @override
  void dispose() {
    _spin?.cancel();
    _toastT?.cancel();
    _toastE?.remove();
    _toastE = null;
    s.removeListener(_rebuild);
    s.removeListener(_syncAfr);
    Cfg.i.removeListener(_rebuild);
    c.removeListener(_onLive);
    AfrLog.i.flush();
    amtCtl.dispose();
    super.dispose();
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: const Duration(seconds: 2), content: Text(m)));
  }

  // ----- การเลือก -----
  (int, int, int, int)? get _sel {
    final p = a0, q = a1;
    if (p == null || q == null) return null;
    return (math.min(p.$1, q.$1), math.min(p.$2, q.$2), math.max(p.$1, q.$1), math.max(p.$2, q.$2));
  }

  List<(int, int)> get _cells {
    final g = _sel;
    if (g == null) return const [];
    return [
      for (int r = g.$1; r <= g.$3; r++)
        for (int cc = g.$2; cc <= g.$4; cc++) (r, cc),
    ];
  }

  // ----- LIVE: ตำแหน่ง RPM/TPS สดบนตาราง -----
  bool get _liveData => c.demo || c.ecuLive;

  (double?, double?) _livePos(XdfTable t) {
    if (!live || !_liveData) return (null, null);
    final rpm = c.t.rpm, tps = c.t.tps;
    double? onAxis(List<double>? a) {
      final k = _axisKind(a);
      if (k == 1) return _axisFrac(a!, rpm);
      if (k == 2) return _axisFrac(a!, tps);
      return null;
    }

    double? rf = t.rows == 1 ? 0.0 : onAxis(s.axisNums(t, false));
    double? cf = t.cols == 1 ? 0.0 : onAxis(s.axisNums(t, true));
    if (!t.is2D && (t.rows == 1 ? cf == null : rf == null)) {
      final own = [for (final row in s.values(t)) ...row];
      final f = onAxis(own);
      if (f != null) {
        if (t.rows == 1) {
          cf = f;
        } else {
          rf = f;
        }
      }
    }
    if (rf == null || cf == null) return (null, null);
    return (rf, cf);
  }

  String _axisName(XdfTable t, bool isX) {
    final k = _axisKind(s.axisNums(t, isX));
    if (k == 1) return 'RPM';
    if (k == 2) return 'TPS %';
    final ax = isX ? t.x : t.y;
    final lt = ax.link == null ? null : s.xdf?.byId[ax.link];
    return lt?.title ?? (isX ? 'X' : 'Y');
  }

  // ----- เลื่อน/ขนาดตาราง -----
  void _clampScroll(XdfTable t) {
    final mx = math.max(0.0, t.cols * cw - (view.width - hw));
    final my = math.max(0.0, t.rows * ch - (view.height - hh));
    sx = sx.clamp(0.0, mx).toDouble();
    sy = sy.clamp(0.0, my).toDouble();
  }

  void _ensureVisible(XdfTable t, double rf, double cf) {
    final x = cf * cw, y = rf * ch;
    final w = view.width - hw, h = view.height - hh;
    if (w <= 0 || h <= 0) return;
    if (x < sx + cw) sx = x - cw;
    if (x > sx + w - 2 * cw) sx = x - w + 2 * cw;
    if (y < sy + ch) sy = y - ch;
    if (y > sy + h - 2 * ch) sy = y - h + 2 * ch;
    _clampScroll(t);
  }

  /// FIT: ย่อ/ขยายให้เห็นทั้งตารางพอดีจอ (3D = รีเซ็ตมุมมอง)
  void _fit() {
    final t = s.table;
    if (t == null) return;
    setState(() {
      if (view3d) {
        yaw = -0.85;
        pitch = 0.62;
        zoom = 1;
        pan3 = Offset.zero;
        return;
      }
      final w = view.width - hw, h = view.height - hh;
      if (w <= 0 || h <= 0) return;
      cw = (w / t.cols).clamp(12.0, 180.0).toDouble();
      ch = (h / t.rows).clamp(7.0, 80.0).toDouble();
      sx = 0;
      sy = 0;
      _lastTouch = _now;
    });
  }

  (int, int)? _cellAt(XdfTable t, Offset p, {bool clamp = false}) {
    var cc = ((p.dx - hw + sx) / cw).floor();
    var r = ((p.dy - hh + sy) / ch).floor();
    if (clamp) {
      cc = cc.clamp(0, t.cols - 1).toInt();
      r = r.clamp(0, t.rows - 1).toInt();
    } else if (cc < 0 || r < 0 || cc >= t.cols || r >= t.rows) {
      return null;
    }
    return (r, cc);
  }

  void _gStartH(XdfTable t, ScaleStartDetails d) {
    _lastTouch = _now;
    final p = d.localFocalPoint;
    _gStart = p;
    _gLast = p;
    _gMoved = false;
    _cw0 = cw;
    _ch0 = ch;
    if (d.pointerCount >= 2) {
      _gMode = 2;
      _fcx = (p.dx - hw + sx) / cw; // จุดในตารางที่อยู่ใต้นิ้ว (ซูมรอบจุดนี้)
      _fcy = (p.dy - hh + sy) / ch;
      return;
    }
    if (p.dy < hh && p.dx < hw) {
      _gMode = 5;
    } else if (p.dy < hh) {
      _gMode = 3; // หัวคอลัมน์: แตะ/ลาก = เลือกทั้งคอลัมน์ (ทุกแถว)
      _gDown = ((p.dx - hw + sx) / cw).floor().clamp(0, t.cols - 1).toInt();
      setState(() {
        a0 = (0, _gDown);
        a1 = (t.rows - 1, _gDown);
      });
    } else if (p.dx < hw) {
      _gMode = 4; // หัวแถว: แตะ/ลาก = เลือกทั้งแถว (ทุกคอลัมน์)
      _gDown = ((p.dy - hh + sy) / ch).floor().clamp(0, t.rows - 1).toInt();
      setState(() {
        a0 = (_gDown, 0);
        a1 = (_gDown, t.cols - 1);
      });
    } else {
      final rc = _cellAt(t, p);
      if (rc == null) {
        _gMode = 0;
        return;
      }
      _gMode = 1;
      setState(() {
        a0 = rc;
        a1 = rc;
      });
    }
  }

  void _gUpdateH(XdfTable t, ScaleUpdateDetails d) {
    _lastTouch = _now;
    final p = d.localFocalPoint;
    final dl = p - _gLast;
    _gLast = p;
    if ((p - _gStart).distance > 8) _gMoved = true;
    setState(() {
      switch (_gMode) {
        case 1:
          if (p.dx > view.width - 18) sx += 12;
          if (p.dx < hw + 8) sx -= 12;
          if (p.dy > view.height - 14) sy += 10;
          if (p.dy < hh + 6) sy -= 10;
          _clampScroll(t);
          a1 = _cellAt(t, p, clamp: true);
          break;
        case 2: // 2 นิ้ว: ซูมเข้า/ออกอิสระรอบจุดกลางนิ้ว + เลื่อนตามนิ้ว
          if (d.pointerCount >= 2) {
            cw = (_cw0 * d.scale).clamp(12.0, 180.0).toDouble();
            ch = (_ch0 * d.scale).clamp(7.0, 80.0).toDouble();
          }
          sx = _fcx * cw - (p.dx - hw);
          sy = _fcy * ch - (p.dy - hh);
          _clampScroll(t);
          break;
        case 3:
          if (p.dx > view.width - 18) sx += 12;
          if (p.dx < hw + 8) sx -= 12;
          _clampScroll(t);
          a0 = (0, _gDown);
          a1 = (t.rows - 1, ((p.dx - hw + sx) / cw).floor().clamp(0, t.cols - 1).toInt());
          break;
        case 4:
          if (p.dy > view.height - 14) sy += 10;
          if (p.dy < hh + 6) sy -= 10;
          _clampScroll(t);
          a0 = (_gDown, 0);
          a1 = (((p.dy - hh + sy) / ch).floor().clamp(0, t.rows - 1).toInt(), t.cols - 1);
          break;
      }
    });
  }

  void _gEndH(XdfTable t) {
    if (!_gMoved) {
      switch (_gMode) {
        case 3:
          if (_gDown >= 0 && _gDown < t.cols) {
            setState(() {
              a0 = (0, _gDown);
              a1 = (t.rows - 1, _gDown);
            });
          }
          break;
        case 4:
          if (_gDown >= 0 && _gDown < t.rows) {
            setState(() {
              a0 = (_gDown, 0);
              a1 = (_gDown, t.cols - 1);
            });
          }
          break;
        case 5:
          setState(() {
            a0 = (0, 0);
            a1 = (t.rows - 1, t.cols - 1);
          });
          break;
        case 1:
          final rc = a0;
          final now = _now;
          if (rc != null && rc == _lastTapCell && now - _lastTapMs < 380) {
            _lastTapMs = 0;
            _setVal(ask: true);
          } else {
            _lastTapCell = rc;
            _lastTapMs = now;
          }
          break;
      }
    }
    _gMode = 0;
  }

  // ----- ปรับค่า -----
  Future<bool> _canEdit(XdfTable t) async {
    if (!t.isLock || s.lockOk) return true;
    if (_asking) return false;
    _asking = true;
    final orig = s.val(t, 0, 0, original: true);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF14141A),
        title: const Row(children: [
          Icon(Icons.lock, color: kBad),
          SizedBox(width: 8),
          Text('รหัสล็อคกล่อง', style: TextStyle(fontSize: 16)),
        ]),
        content: Text(
            'ค่านี้คือรหัสล็อคกล่อง (ค่าในไฟล์เดิม = ${orig.round()} / 0x${orig.round().toRadixString(16).toUpperCase().padLeft(2, '0')})\n\n'
            'ถ้าเปลี่ยนแล้วจำรหัสใหม่ไม่ได้ อาจอ่านหรือแฟลชกล่องไม่ได้อีก\nต้องการปลดล็อกให้แก้ค่านี้หรือไม่?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(false), child: const Text('ยกเลิก')),
          TextButton(onPressed: () => Navigator.of(dctx).pop(true), child: const Text('ปลดล็อกแก้ไข', style: TextStyle(color: kBad))),
        ],
      ),
    );
    _asking = false;
    if (ok == true) {
      s.lockOk = true;
      return true;
    }
    return false;
  }

  bool _needSel() {
    if (s.table == null) return false;
    if (_sel == null) {
      _snack('เลือกช่องในตารางก่อน');
      return false;
    }
    return true;
  }


  // ป๊อปอัพเตือนเล็ก ๆ กลางจอ แล้วจางหายเอง (~1.5 วิ)
  OverlayEntry? _toastE;
  Timer? _toastT;
  void _toast(String m, {Color col = kAmber}) {
    _toastT?.cancel();
    _toastE?.remove();
    _toastE = null;
    if (!mounted) return;
    final e = OverlayEntry(builder: (_) => IgnorePointer(child: Center(child: _FadeToast(msg: m, col: col))));
    _toastE = e;
    Overlay.of(context).insert(e);
    _toastT = Timer(const Duration(milliseconds: 1600), () {
      e.remove();
      if (_toastE == e) _toastE = null;
    });
  }

  /// ค่าในช่อง "ใส่ค่าที่ต้องการ" — ว่าง = เด้งเตือน (บอกช่วงที่แนะนำของปุ่มนั้น แต่ไม่บังคับ)
  double? _need(String btn, String hint) {
    final a = _amt;
    if (a == null) _toast('ใส่ค่าก่อน · $btn แนะนำ $hint');
    return a;
  }

  /// เขียนค่า + เตือนถ้ามีช่องชนค่าสุดของข้อมูล (ปรับได้อิสระถึงค่าต่ำสุด/สูงสุดที่ข้อมูลเก็บได้)
  int _w(XdfTable t, Map<(int, int), double> vals, String label, {bool merge = false}) {
    final n = s.write(t, vals, label, merge: merge);
    if (s.lastClamp > 0) _toast('${s.lastClamp} ช่องชนค่าสุดของข้อมูล (${t.fmt(s.clampLo)} – ${t.fmt(s.clampHi)})');
    return n;
  }

  /// ค่าในช่อง "ค่า" (ว่าง = null) รับเลขฐาน 16 แบบ 0x41 ได้
  double? get _amt {
    final v = amtCtl.text.trim().replaceAll(',', '.');
    if (v.isEmpty) return null;
    if (v.toLowerCase().startsWith('0x')) return int.tryParse(v.substring(2), radix: 16)?.toDouble();
    return double.tryParse(v);
  }

  Future<void> _bump(int dir) async {
    final t = s.table;
    if (t == null || !_needSel()) return;
    final a = _need('− / +', '-100 – 100');
    if (a == null || !await _canEdit(t)) return;
    final d = dir * a; // + = บวกค่าที่ใส่, − = ลบค่าที่ใส่ (ใส่ค่าติดลบได้)
    _w(t, {for (final rc in _cells) rc: s.val(t, rc.$1, rc.$2) + d}, '${dir > 0 ? '+' : '−'} ${_numStr(a)}', merge: true);
  }

  Future<double?> _askNum(String title, String hint, {String initial = ''}) async {
    final tc = TextEditingController(text: initial);
    final th = Cfg.i.t;
    double? parse(String x) {
      final v = x.trim().replaceAll(',', '.');
      if (v.toLowerCase().startsWith('0x')) return int.tryParse(v.substring(2), radix: 16)?.toDouble();
      return double.tryParse(v);
    }

    final r = await showDialog<double>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF14141A),
        title: Text(title, style: TextStyle(fontFamily: kFont, fontSize: 13, color: th.c)),
        content: TextField(
          controller: tc,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: InputDecoration(hintText: hint, hintStyle: const TextStyle(fontSize: 12, color: Colors.white38)),
          onSubmitted: (x) => Navigator.of(dctx).pop(parse(x)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('ยกเลิก')),
          TextButton(onPressed: () => Navigator.of(dctx).pop(parse(tc.text)), child: Text('ตกลง', style: TextStyle(color: th.c))),
        ],
      ),
    );
    tc.dispose();
    return r;
  }

  Future<void> _pct() async {
    final t = s.table;
    if (t == null || !_needSel()) return;
    final p = _need('%', '-100 – 100');
    if (p == null || !await _canEdit(t)) return;
    final n = _w(t, {for (final rc in _cells) rc: s.val(t, rc.$1, rc.$2) * (1 + p / 100)}, '% ${_numStr(p)}');
    if (n == 0) _snack('ค่าไม่เปลี่ยน (น้อยกว่า 1 ขั้นของข้อมูล)');
  }

  // ----- เครื่องมือแผง "ปรับค่า": X / Y / XY ไล่ค่าตามแกน, ~ smooth, COPY / PASTE -----

  /// ตำแหน่งบนแกน (ใช้ค่าแกนจริงถ้าเรียงขึ้นหรือลงอย่างเดียว เช่น RPM ห่างไม่เท่ากัน ; ไม่งั้นใช้ลำดับช่อง)
  List<double> _axisPos(XdfTable t, bool isX) {
    final n = isX ? t.cols : t.rows;
    final a = s.axisNums(t, isX);
    if (a != null && a.length >= n) {
      bool up = true, down = true;
      for (int k = 1; k < n; k++) {
        if (!a[k].isFinite || !a[k - 1].isFinite) {
          up = down = false;
          break;
        }
        if (a[k] <= a[k - 1]) up = false;
        if (a[k] >= a[k - 1]) down = false;
      }
      if (up || down) return a.sublist(0, n);
    }
    return [for (int k = 0; k < n; k++) k.toDouble()];
  }

  /// mode 0 = X (ไล่ตามแนวนอนในแต่ละแถว), 1 = Y (ไล่ตามแนวตั้งในแต่ละคอลัมน์), 2 = XY (ยึด 4 มุม ไล่ทั้งสองแกน)
  /// ค่าในช่อง = ความแรง (1 = 100% ไล่เต็ม, 0.5 = ขยับครึ่งทางจากค่าเดิมไปหาค่าที่ไล่)
  /// เลือกคอลัมน์/แถวเดียวได้: ใช้คอลัมน์ซ้าย-ขวา / แถวบน-ล่าง ที่อยู่นอกส่วนที่เลือกเป็นจุดยึด
  Future<void> _interp(int mode) async {
    final t = s.table;
    final g = _sel;
    if (t == null || g == null || !_needSel()) return;
    const names = ['X', 'Y', 'XY'];
    final k = _need(names[mode], '0 – 1 (1 = 100%)');
    if (k == null || !await _canEdit(t)) return;
    final (r0, c0, r1, c1) = g;
    int ca = c0, cb = c1, ra = r0, rb = r1;
    if (mode != 1 && c1 == c0) {
      ca = c0 - 1;
      cb = c1 + 1;
      if (ca < 0 || cb >= t.cols) {
        _toast('คอลัมน์ติดขอบตาราง — ไม่มีช่องซ้าย-ขวาให้ไล่ค่า');
        return;
      }
    }
    if (mode != 0 && r1 == r0) {
      ra = r0 - 1;
      rb = r1 + 1;
      if (ra < 0 || rb >= t.rows) {
        _toast('แถวติดขอบตาราง — ไม่มีช่องบน-ล่างให้ไล่ค่า');
        return;
      }
    }
    final px = _axisPos(t, true), py = _axisPos(t, false);
    double fx(int c) => px[cb] == px[ca] ? 0 : (px[c] - px[ca]) / (px[cb] - px[ca]);
    double fy(int r) => py[rb] == py[ra] ? 0 : (py[r] - py[ra]) / (py[rb] - py[ra]);
    final out = <(int, int), double>{};
    final v00 = s.val(t, ra, ca), v01 = s.val(t, ra, cb), v10 = s.val(t, rb, ca), v11 = s.val(t, rb, cb);
    for (int r = r0; r <= r1; r++) {
      for (int c = c0; c <= c1; c++) {
        double v;
        if (mode == 0) {
          final a = s.val(t, r, ca), b = s.val(t, r, cb), f = fx(c);
          v = a + (b - a) * f;
        } else if (mode == 1) {
          final a = s.val(t, ra, c), b = s.val(t, rb, c), f = fy(r);
          v = a + (b - a) * f;
        } else {
          final u = fx(c), w = fy(r);
          v = v00 * (1 - u) * (1 - w) + v01 * u * (1 - w) + v10 * (1 - u) * w + v11 * u * w;
        }
        final old = s.val(t, r, c);
        out[(r, c)] = old + (v - old) * k;
      }
    }
    final n = _w(t, out, 'ไล่ค่า ${names[mode]} ×${_numStr(k)}');
    if (n == 0) _snack('ค่าไม่เปลี่ยน');
  }

  /// ~ smooth: แต่ละช่องที่เลือกขยับเข้าหาค่าเฉลี่ยของตัวเองกับช่องรอบข้าง 8 ช่อง (อ่านค่าเดิมก่อนแก้ทั้งหมด)
  /// ค่าในช่อง = ความแรง (แนะนำ 0.01 – 0.10 ; 1 = เท่าค่าเฉลี่ยเต็ม ๆ)
  Future<void> _smooth() async {
    final t = s.table;
    if (t == null || !_needSel()) return;
    final k = _need('~', '0.01 – 0.10');
    if (k == null || !await _canEdit(t)) return;
    final out = <(int, int), double>{};
    for (final rc in _cells) {
      double sum = 0;
      int n = 0;
      for (int dr = -1; dr <= 1; dr++) {
        for (int dc = -1; dc <= 1; dc++) {
          final r = rc.$1 + dr, c = rc.$2 + dc;
          if (r < 0 || c < 0 || r >= t.rows || c >= t.cols) continue;
          final v = s.val(t, r, c);
          if (!v.isFinite) continue;
          sum += v;
          n++;
        }
      }
      if (n > 0) {
        final old = s.val(t, rc.$1, rc.$2);
        out[rc] = old + (sum / n - old) * k;
      }
    }
    final w = _w(t, out, '~ smooth ×${_numStr(k)} ${out.length} ช่อง');
    if (w == 0) _snack('ค่าไม่เปลี่ยน (เรียบอยู่แล้ว หรือน้อยกว่า 1 ขั้นของข้อมูล)');
  }

  static List<List<double>>? _clip; // คลิปบอร์ด (คงอยู่ระหว่างเปลี่ยนตาราง)
  static String _clipFrom = '';

  void _copy() {
    final t = s.table;
    final g = _sel;
    if (t == null || g == null || !_needSel()) return;
    final (r0, c0, r1, c1) = g;
    _clip = [
      for (int r = r0; r <= r1; r++) [for (int c = c0; c <= c1; c++) s.val(t, r, c)],
    ];
    _clipFrom = t.title;
    setState(() {});
    _snack('คัดลอก ${r1 - r0 + 1}×${c1 - c0 + 1} ช่องจาก "${t.title}" แล้ว');
  }

  Future<void> _paste() async {
    final t = s.table;
    final cb = _clip;
    final g = _sel;
    if (t == null || cb == null || cb.isEmpty) return;
    if (g == null) {
      _snack('เลือกช่องมุมซ้ายบนที่จะวางก่อน');
      return;
    }
    if (!await _canEdit(t)) return;
    final out = <(int, int), double>{};
    for (int i = 0; i < cb.length; i++) {
      for (int j = 0; j < cb[i].length; j++) {
        final r = g.$1 + i, c = g.$2 + j;
        if (r >= t.rows || c >= t.cols || !cb[i][j].isFinite) continue;
        out[(r, c)] = cb[i][j];
      }
    }
    final rows = cb.length, cols = cb[0].length;
    final cut = out.length < rows * cols;
    final n = _w(t, out, 'วาง ${rows}×$cols');
    setState(() {
      a0 = (g.$1, g.$2);
      a1 = (math.min(t.rows - 1, g.$1 + rows - 1), math.min(t.cols - 1, g.$2 + cols - 1));
    });
    _snack(n == 0
        ? 'ค่าไม่เปลี่ยน (ค่าเท่าเดิม)'
        : 'วางจาก "$_clipFrom" แล้ว${cut ? ' (ส่วนที่เกินขอบตารางถูกตัดออก)' : ''}');
  }

  Future<void> _setVal({bool ask = false}) async {
    final t = s.table;
    if (t == null || !_needSel()) return;
    final cells = _cells;
    double? v;
    if (ask) {
      // แตะช่องเดิม 2 ครั้ง = ถามค่าใหม่ (เหมือนเดิม)
      if (!await _canEdit(t)) return;
      final avg = cells.map((rc) => s.val(t, rc.$1, rc.$2)).reduce((a, b) => a + b) / cells.length;
      v = await _askNum('ใส่ค่า (${cells.length} ช่อง)', t.outType == 3 ? 'เช่น 65 หรือ 0x41' : 'ค่าใหม่', initial: t.fmt(avg));
    } else {
      v = _need('=', '-100 – 1000');
      if (v == null || !await _canEdit(t)) return;
    }
    if (v == null) return;
    _w(t, {for (final rc in cells) rc: v}, '= ${_numStr(v)}');
  }

  void _undo() {
    final l = s.undo();
    _snack(l == null ? 'ไม่มีให้ย้อน' : 'ย้อน: $l');
  }

  void _redo() {
    final l = s.redo();
    _snack(l == null ? 'ไม่มีให้ทำซ้ำ' : 'ทำซ้ำ: $l');
  }

  // ----- ✅ บันทึกแล้วปิดตาราง / ❌ ปิดตาราง (ถามบันทึก/ไม่บันทึกก่อนปิด) -----
  void _okTable() {
    final t = s.table;
    if (t == null) return;
    final dirty = s.tableDirty(t);
    if (dirty) s.commitTable(t);
    _stopSpin();
    s.select(-1);
    _snack(dirty ? 'บันทึกค่า "${t.title}" แล้ว ✅' : 'ปิด "${t.title}" (ไม่มีค่าที่เปลี่ยน)');
  }

  Future<void> _cancelTable() async {
    final t = s.table;
    if (t == null) return;
    if (s.tableDirty(t)) {
      final r = await showDialog<int>(
        context: context,
        builder: (dctx) => AlertDialog(
          backgroundColor: const Color(0xFF14141A),
          title: const Text('ปิดตารางจูน', style: TextStyle(fontSize: 16)),
          content: Text('ตาราง "${t.title}" มีค่าที่แก้แต่ยังไม่ได้บันทึก\nต้องการบันทึกก่อนปิดหรือไม่?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dctx).pop(0), child: const Text('ยกเลิก')),
            TextButton(onPressed: () => Navigator.of(dctx).pop(1), child: const Text('ไม่บันทึก', style: TextStyle(color: kBad))),
            TextButton(onPressed: () => Navigator.of(dctx).pop(2), child: const Text('บันทึก', style: TextStyle(color: kGreen, fontWeight: FontWeight.bold))),
          ],
        ),
      );
      if (r == null || r == 0) return;
      if (r == 1) s.revertTable(t);
      if (r == 2) s.commitTable(t);
    }
    _stopSpin();
    s.select(-1);
  }

  /// เปลี่ยนตาราง: ถ้าตารางเดิมมีค่าค้าง ถามก่อน
  Future<void> _pickTable(int i) async {
    if (i == s.sel) return;
    final cur = s.table;
    if (cur != null && s.tableDirty(cur)) {
      final r = await showDialog<int>(
        context: context,
        builder: (dctx) => AlertDialog(
          backgroundColor: const Color(0xFF14141A),
          title: const Text('ยังไม่ได้บันทึก', style: TextStyle(fontSize: 16)),
          content: Text('ตาราง "${cur.title}" มีค่าที่แก้แต่ยังไม่ได้กด ✅'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dctx).pop(0), child: const Text('อยู่ต่อ')),
            TextButton(onPressed: () => Navigator.of(dctx).pop(1), child: const Text('ยกเลิกค่า ❌', style: TextStyle(color: kBad))),
            TextButton(onPressed: () => Navigator.of(dctx).pop(2), child: const Text('บันทึก ✅', style: TextStyle(color: kGreen))),
          ],
        ),
      );
      if (r == null || r == 0) return;
      if (r == 1) s.revertTable(cur);
      if (r == 2) s.commitTable(cur);
    }
    s.select(i);
  }

  // ----- ไฟล์ -----
  Future<bool> _confirm(String title, String msg, {String ok = 'ตกลง'}) => askYes(context, title, msg, ok: ok);

  bool get _hasEdits => s.unsavedBytes > 0; // บันทึกเข้าคลังแล้ว = ไม่ต้องถามก่อนเปิดไฟล์อื่น

  void _resetView() {
    a0 = null;
    a1 = null;
    sx = 0;
    sy = 0;
    _spin?.cancel();
    _spin = null;
  }

  Future<void> _openBin() async {
    if (_hasEdits && !await _confirm('เปิด BIN ใหม่', 'ค่าที่แก้ใน BIN ปัจจุบันจะหายไป (บันทึกเข้าคลังก่อนถ้าต้องการเก็บ)', ok: 'เปิดไฟล์ใหม่')) return;
    try {
      final f = await pickFileExt('bin', _snack);
      if (f == null) return;
      s.loadBin(f.$1, f.$2);
      setState(_resetView);
      final bad = s.invalidCount;
      if (bad > 0) _snack('มี $bad รายการใน XDF ที่อยู่นอกขนาดไฟล์ BIN (${f.$2.length} ไบต์) — ตรวจว่าเป็นไฟล์คู่กัน');
    } catch (e) {
      _snack('เปิดไฟล์ไม่สำเร็จ: $e');
    }
  }

  Future<void> _showXdfError(String m) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF14141A),
        title: const Text('เปิด XDF ไม่ได้', style: TextStyle(fontSize: 16)),
        content: Text(m),
        actions: [TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('ตกลง'))],
      ),
    );
  }

  Future<void> _openXdf() async {
    if (_hasEdits && !await _confirm('เปิด XDF ใหม่', 'ประวัติย้อนกลับจะถูกล้าง (ค่าที่แก้ใน BIN ยังอยู่)', ok: 'เปิดไฟล์ใหม่')) return;
    try {
      final f = await pickFileExt('xdf', _snack, anyName: true);   // ไฟล์ XDF ทุกชื่อ/นามสกุล — ตรวจจากเนื้อไฟล์
      if (f == null) return;
      final d = XdfDef.parse(f.$2);
      s.loadXdf(f.$1, d, raw: f.$2);
      setState(_resetView);
      _snack('XDF: ${d.tables.length} ตาราง (2D ${d.tables.where((t) => t.is2D).length}) + ${d.flags.length} FLAGS');
    } on XdfError catch (e) {
      await _showXdfError(e.msg);
    } catch (e) {
      _snack('เปิดไฟล์ไม่สำเร็จ: $e');
    }
  }

  /// โหมดปุ่ม "เลือกจากแอป": 0 = BIN+XDF, 1 = เฉพาะ BIN (มี XDF จากภายนอกแล้ว), 2 = เฉพาะ XDF (มี BIN จากภายนอกแล้ว)
  int get _pickMode => (s.binSrc == 2 && s.xdfSrc != 2) ? 2 : ((s.xdfSrc == 2 && s.binSrc != 2) ? 1 : 0);
  String get _pickLabel => const ['เลือก BIN/XDF จากแอป', 'เลือก BIN จากแอป', 'เลือก XDF จากแอป'][_pickMode];
  static int _origSort = 0; // 0 = รุ่นรถ, 1 = ขนาดไฟล์ มาก-น้อย, 2 = ขนาดไฟล์ น้อย-มาก (จำไว้ระหว่างเปิดหน้าต่าง)

  /// เลือก BIN + XDF ต้นฉบับ (ORIGINAL) ที่มากับแอพ — จับคู่ตาม ID กล่อง, ไม่แฟลชอัตโนมัติ
  /// ถ้าเปิด BIN หรือ XDF จากภายนอกไว้อย่างใดอย่างหนึ่ง จะโหลดจากแอปเฉพาะอีกไฟล์ (ไม่แทนที่ไฟล์ที่เปิดไว้)
  Future<void> _openOriginals() async {
    final th = Cfg.i.t;
    final ecm = c.t.fl?.ecm; // ID กล่องที่ต่ออยู่ (null = ยังไม่ต่อ/ยังอ่านไม่ได้)
    final mode = _pickMode;
    final title = _pickLabel;
    final p = await showDialog<OrigPack>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dctx) {
        int tab = (ecm != null && kOriginals.any((o) => o.matches(ecm))) ? 0 : 1; // มีไฟล์ตรงรุ่น -> เปิดแท็บรถคันนี้
        bool searching = false;
        String q = '';
        final qCtl = TextEditingController();
        return StatefulBuilder(builder: (dctx, setM) {
          final sz = MediaQuery.of(dctx).size;
          // รายการตามแท็บ
          List<OrigPack> list = tab == 0
              ? [for (final o in kOriginals) if (o.matches(ecm)) o]
              : List<OrigPack>.from(kOriginals);
          if (q.trim().isNotEmpty) {
            final k = q.trim().toLowerCase();
            list = [for (final o in list) if (('${o.model} ${o.name} ${ecmHex(o.ecuId)}').toLowerCase().contains(k)) o];
          }
          String nm(OrigPack o) => o.model.isEmpty ? o.name : o.model;
          int size(OrigPack o) => mode == 2 ? o.xdfKb * 100000 + o.binKb : o.binKb * 100000 + o.xdfKb; // เลือกเฉพาะ XDF = เรียงตามขนาด XDF
          list.sort((a, b) => switch (_origSort) {
                1 => size(b).compareTo(size(a)) != 0 ? size(b).compareTo(size(a)) : nm(a).compareTo(nm(b)),
                2 => size(a).compareTo(size(b)) != 0 ? size(a).compareTo(size(b)) : nm(a).compareTo(nm(b)),
                _ => nm(a).compareTo(nm(b)),
              });

          Widget hbtn(IconData ic, Color bc, Color fc, VoidCallback onTap) => InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(9),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: hudDeco(border: bc, radius: 9, color: const Color(0xFF12161C)),
                  child: Icon(ic, color: fc, size: 16),
                ),
              );
          Widget tabBtn(String t, int i) => Expanded(
                child: InkWell(
                  onTap: () => setM(() => tab = i),
                  borderRadius: BorderRadius.circular(9),
                  child: Container(
                    height: 30,
                    alignment: Alignment.center,
                    decoration: hudDeco(border: tab == i ? th.c : Colors.white24, width: tab == i ? 1.3 : 1, radius: 9, color: tab == i ? th.c.withOpacity(0.18) : const Color(0xFF12161C)),
                    child: Text(t, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: tab == i ? Colors.white : Colors.white60)),
                  ),
                ),
              );
          Widget sortBtn(String t, bool on, VoidCallback f) => Padding(
                padding: const EdgeInsets.only(left: 6),
                child: InkWell(
                  onTap: f,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    height: 26,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    decoration: hudDeco(border: on ? th.c2 : Colors.white24, radius: 8, color: on ? th.c.withOpacity(0.22) : const Color(0xFF12161C)),
                    child: Text(t, style: TextStyle(fontSize: 11.5, color: on ? Colors.white : Colors.white70)),
                  ),
                ),
              );
          Widget card(OrigPack o) {
            final on = o.matches(ecm);
            final szTxt = switch (mode) {
              1 => 'BIN ${o.binKb} KB · ใช้เฉพาะ BIN',
              2 => 'XDF ${o.xdfKb} KB · ใช้เฉพาะ XDF',
              _ => 'BIN ${o.binKb} KB · XDF ${o.xdfKb} KB',
            };
            return InkWell(
              onTap: () => Navigator.of(dctx).pop(o),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                margin: const EdgeInsets.only(bottom: 5),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: hudDeco(border: on ? kGreen.withOpacity(0.7) : Colors.white12, radius: 10, color: on ? const Color(0xFF0E1D16) : const Color(0xFF0F1013)),
                child: Row(children: [
                  RichText(
                    text: TextSpan(style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Colors.white), children: [
                      TextSpan(text: o.model.isEmpty ? o.name : o.model.split(' (').first),
                      TextSpan(text: '  ${o.name}', style: const TextStyle(fontSize: 12, color: Colors.white70, fontWeight: FontWeight.normal)),
                    ]),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(szTxt, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white54))),
                  if (o.ecuId != null)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                      decoration: hudDeco(border: on ? kGreen.withOpacity(0.7) : Colors.white24, radius: 6),
                      child: Text(ecmHex(o.ecuId), style: TextStyle(fontSize: 10, color: on ? kGreen : Colors.white54)),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(on ? Icons.check : Icons.chevron_right, color: on ? kGreen : th.c, size: 16),
                  ),
                ]),
              ),
            );
          }

          final sub = switch (mode) {
            1 => 'ใช้คู่กับ XDF: ${s.xdfName ?? '-'} (จากภายนอก) · XDF ไม่ถูกเปลี่ยน',
            2 => 'ใช้คู่กับ BIN: ${s.binName ?? '-'} (จากภายนอก) · BIN ไม่ถูกเปลี่ยน',
            _ => '',
          };
          return Dialog(
            backgroundColor: const Color(0xFF0C0D10),
            insetPadding: EdgeInsets.symmetric(horizontal: sz.width * 0.1, vertical: 12),
            shape: HudBorder(cut: 14, side: BorderSide(color: th.c, width: 1.2)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // หัว (ย่อให้เตี้ย เพื่อให้เห็นรายการไฟล์ได้มากขึ้น)
              Container(
                padding: const EdgeInsets.fromLTRB(14, 9, 14, 8),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF1A1114)))),
                child: Row(children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: hudDeco(border: th.c, radius: 9, color: const Color(0xFF15090B)),
                    child: Icon(Icons.memory, color: th.c, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                      if (sub.isNotEmpty)
                        Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: Colors.white60))
                      else
                        RichText(
                          text: const TextSpan(style: TextStyle(fontSize: 10.5, color: Colors.white60), children: [
                            TextSpan(text: 'จับคู่เฉพาะรหัส ECU ที่ยืนยันได้ · '),
                            TextSpan(text: 'ไม่แฟลชอัตโนมัติ', style: TextStyle(color: Color(0xFFFF7A7C), fontWeight: FontWeight.w600)),
                          ]),
                        ),
                    ]),
                  ),
                  hbtn(searching ? Icons.search_off : Icons.search, Colors.white24, Colors.white70, () => setM(() {
                        searching = !searching;
                        if (!searching) {
                          q = '';
                          qCtl.clear();
                        }
                      })),
                  const SizedBox(width: 6),
                  hbtn(Icons.close, th.c, const Color(0xFFFF6B6E), () => Navigator.of(dctx).pop()),
                ]),
              ),
              // แท็บ
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
                child: Row(children: [tabBtn('ไฟล์สำหรับรถคันนี้', 0), const SizedBox(width: 8), tabBtn('ไฟล์ทั้งหมด', 1)]),
              ),
              // ช่องค้นหา (เมื่อเปิด)
              if (searching)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
                  child: TextField(
                    controller: qCtl,
                    autofocus: true,
                    style: const TextStyle(fontSize: 13),
                    onChanged: (v) => setM(() => q = v),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'ค้นหารุ่น / รหัส ECU',
                      prefixIcon: const Icon(Icons.search, size: 16),
                      filled: true,
                      fillColor: const Color(0xFF12161C),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide: BorderSide(color: th.c.withOpacity(0.5))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide: const BorderSide(color: Colors.white24)),
                    ),
                  ),
                ),
              // บรรทัดสรุป + สถานะการต่อ + ปุ่มเรียง
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
                child: Row(children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(style: const TextStyle(fontSize: 11, color: Colors.white54), children: [
                        TextSpan(text: 'แสดง ${list.length}/${kOriginals.length} ชุด · '),
                        TextSpan(
                          text: ecm != null ? '● ต่อ ECU: ${ecuModelName(ecm) ?? 'ไม่ทราบรุ่น'}' : '● ยังไม่เชื่อมต่อ ECU',
                          style: TextStyle(color: ecm != null ? kGreen : Colors.white38),
                        ),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Text('เรียง:', style: TextStyle(fontSize: 11, color: Colors.white38)),
                  sortBtn('รุ่นรถ', _origSort == 0, () => setM(() => _origSort = 0)),
                  sortBtn(_origSort == 2 ? '↑ ขนาด น้อย-มาก' : '↓ ขนาด มาก-น้อย', _origSort != 0,
                      () => setM(() => _origSort = _origSort == 1 ? 2 : 1)), // กดซ้ำ = สลับ มาก-น้อย / น้อย-มาก
                ]),
              ),
              // รายการ
              Flexible(
                child: list.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(14, 16, 14, 24),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(tab == 0 ? Icons.usb_off : Icons.folder_off, color: Colors.white24, size: 32),
                          const SizedBox(height: 8),
                          Text(
                            tab == 0
                                ? (ecm == null ? 'กรุณาเชื่อมต่อ ECU แล้วกดสแกน ECU\nหรือแตะ "ไฟล์ทั้งหมด" เพื่อดูทุกชุด' : 'ยังไม่มีไฟล์ในแอปที่ตรงกับ ID กล่องนี้\n(${ecmHex(ecm)})')
                                : (q.trim().isEmpty ? 'ยังไม่มีไฟล์ฝังในแอป' : 'ไม่พบไฟล์ที่ค้นหา'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 13, color: Colors.white54, height: 1.5),
                          ),
                          if (tab == 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: TextButton(onPressed: () => setM(() => tab = 1), child: Text('ดูไฟล์ทั้งหมด ›', style: TextStyle(color: th.c2))),
                            ),
                        ]),
                      )
                    : ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 10), shrinkWrap: true, children: [for (final o in list) card(o)]),
              ),
            ]),
          );
        });
      },
    );
    if (p == null || !mounted) return;
    if (mode == 2) {
      if (_hasEdits && !await _confirm('เปิด XDF ใหม่', 'ประวัติย้อนกลับจะถูกล้าง (ค่าที่แก้ใน BIN ยังอยู่)', ok: 'เปิด ${p.xdfName}')) return;
    } else if (_hasEdits && !await _confirm('เปิดไฟล์ ORIGINAL', 'ค่าที่แก้ใน BIN ปัจจุบันจะหายไป', ok: 'เปิด ${p.name}')) {
      return;
    }
    try {
      if (mode != 2) {
        final bin = (await rootBundle.load(p.bin)).buffer.asUint8List();
        s.loadBin(p.binName, Uint8List.fromList(bin), src: 1);
      }
      if (mode != 1) {
        final xb = Uint8List.fromList((await rootBundle.load(p.xdf)).buffer.asUint8List());
        s.loadXdf(p.xdfName, XdfDef.parse(xb), src: 1, raw: xb);
      }
      setState(_resetView);
      final bad = s.invalidCount;
      _snack(bad > 0
          ? 'มี $bad รายการใน XDF ที่อยู่นอกขนาดไฟล์ BIN — ตรวจว่าเป็นไฟล์คู่กัน'
          : switch (mode) {
              1 => 'เปิด BIN ${p.binName} แล้ว — เลือกตารางจากเมนูตารางจูน',
              2 => 'เปิด XDF ${p.xdfName} แล้ว — เลือกตารางจากเมนูตารางจูน',
              _ => 'เปิด ${p.name} แล้ว — เลือกตารางจากเมนูตารางจูน',
            });
    } on XdfError catch (e) {
      await _showXdfError(e.msg);
    } catch (e) {
      _snack('เปิดไฟล์ในแอปไม่ได้: $e (ตรวจว่าใส่ไฟล์ไว้ใน assets/original แล้ว)');
    }
  }

  Future<void> _openFromLib() async {
    if (_hasEdits && !await _confirm('เปิด BIN จากคลัง', 'ค่าที่แก้ใน BIN ปัจจุบันจะหายไป', ok: 'เปิดไฟล์')) return;
    if (!mounted) return;
    final e = await pickFromLibrary(context);
    if (e == null) return;
    await _openEntry(e);
  }

  Future<void> _openEntry(BinEntry e) async {
    try {
      final b = await BinLib.i.read(e);
      s.loadBin('${e.name}.bin', b);
      final xb = await BinLib.i.readXdf(e);
      if (xb != null) {
        try {
          s.loadXdf(e.xdf, XdfDef.parse(xb), raw: xb);
        } on XdfError catch (err) {
          await _showXdfError(err.msg);
        }
      }
      setState(_resetView);
      _snack(xb != null ? 'เปิด ${e.name} + ${e.xdf} แล้ว' : 'เปิด ${e.name} แล้ว (ไฟล์นี้ไม่มี XDF บันทึกไว้)');
    } catch (err) {
      _snack('อ่านไฟล์ไม่ได้: $err');
    }
  }

  Future<void> _clearBin() async {
    if (s.bin == null) return;
    if (_hasEdits && !await _confirm('ล้าง BIN', 'ค่าที่แก้ใน BIN จะหายไป', ok: 'ล้าง BIN')) return;
    s.clearBin();
    setState(_resetView);
  }

  Future<void> _clearXdf() async {
    if (s.xdf == null) return;
    if (!await _confirm('ล้าง XDF', 'ปิดรายการตารางทั้งหมด (ค่าที่แก้ใน BIN ยังอยู่)', ok: 'ล้าง XDF')) return;
    s.clearXdf();
    setState(_resetView);
  }

  // ----- บันทึกเข้าคลังไฟล์ (ตั้งชื่อเอง) หรือส่งออก — ไม่แก้ checksum อัตโนมัติ -----
  Future<void> _save() async {
    if (s.bin == null) {
      _snack('ยังไม่ได้เปิดไฟล์ BIN');
      return;
    }
    final dirty = s.dirtyTables();
    if (dirty.isNotEmpty) {
      final ok = await askYes(
          context,
          'มีค่าที่ยังไม่ได้กด ✅',
          '${dirty.length} ตาราง: ${dirty.take(5).map((t) => t.title).join(', ')}${dirty.length > 5 ? ' …' : ''}\n'
              'บันทึก ✅ ทุกตารางแล้วเซฟเข้าคลัง?',
          ok: 'บันทึกทั้งหมด');
      if (!ok) return;
      s.commitAll();
    }
    if (!mounted) return;
    final th = Cfg.i.t;
    final names = s.changedNames();
    final locks = s.lockChanges();
    await BinLib.i.load();
    if (!mounted) return;
    final fname = s.newFileName();
    final stem = fname.toLowerCase().endsWith('.bin') ? fname.substring(0, fname.length - 4) : fname;
    final tc = TextEditingController(text: stem);
    Widget box(Color col, String head, String body) => Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.all(10),
          decoration: hudDeco(border: col, width: 1.2, radius: 8, color: col.withOpacity(0.12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(head, style: TextStyle(fontWeight: FontWeight.bold, color: col, fontSize: 13)),
            const SizedBox(height: 4),
            Text(body, style: const TextStyle(fontSize: 12.5, height: 1.35)),
          ]),
        );
    int sum8 = 0;
    for (final x in s.bin!) {
      sum8 = (sum8 + x) & 0xFF;
    }
    final nameKey = GlobalKey();
    final act = await showDialog<int>(
      context: context,
      builder: (dctx) {
        // แป้นพิมพ์ขึ้น (จอแนวนอนเหลือที่น้อย): ซ่อนหัว/รายละเอียด เหลือแถวเดียว = ช่องชื่อ + ปุ่ม ให้เห็นชื่อที่กำลังแก้
        final kb = MediaQuery.of(dctx).viewInsets.bottom > 0;
        Widget acts(bool small) => Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton(onPressed: () => Navigator.of(dctx).pop(0), child: const Text('ยกเลิก')),
              TextButton(onPressed: () => Navigator.of(dctx).pop(2), child: Text(small ? 'ส่งออก…' : 'ส่งออกไฟล์…')),
              TextButton(onPressed: () => Navigator.of(dctx).pop(1), child: Text(small ? 'บันทึก' : 'บันทึกเข้าคลัง', style: TextStyle(color: th.c, fontWeight: FontWeight.bold))),
            ]);
        return AlertDialog(
        backgroundColor: const Color(0xFF14141A),
        shape: HudBorder(cut: 11, side: BorderSide(color: th.c, width: 1.2)),
        insetPadding: EdgeInsets.symmetric(horizontal: 40, vertical: kb ? 4 : 24),
        titlePadding: kb ? EdgeInsets.zero : const EdgeInsets.fromLTRB(24, 20, 24, 0),
        contentPadding: kb ? const EdgeInsets.fromLTRB(16, 6, 8, 6) : const EdgeInsets.fromLTRB(24, 16, 24, 8),
        actionsPadding: kb ? EdgeInsets.zero : null,
        title: kb ? const SizedBox.shrink() : Text('บันทึกเข้าคลังไฟล์', style: TextStyle(fontSize: 16, color: th.c)),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: TextField(key: nameKey, controller: tc, decoration: const InputDecoration(labelText: 'ชื่อไฟล์ (ตั้งเองได้)', isDense: true))),
                if (kb) acts(true),
              ]),
              if (!kb) ...[
              const SizedBox(height: 8),
              Text('ต้นฉบับ: ${s.binName} (ไม่ถูกเขียนทับ)', style: const TextStyle(fontSize: 12.5, color: Colors.white70)),
              Text(s.xdfRaw != null ? 'XDF ที่ใช้: ${s.xdfName} (บันทึกไว้คู่กัน)' : 'XDF: ไม่มี (บันทึกแค่ BIN)',
                  style: TextStyle(fontSize: 12.5, color: s.xdfRaw != null ? kGreen : Colors.white54)),
              Text(
                  names.isEmpty
                      ? 'ยังไม่มีการแก้ไข (ไฟล์จะเหมือนต้นฉบับ)'
                      : 'แก้ไข ${s.changedBytes} ไบต์ ใน ${names.length} รายการ: ${names.take(8).join(', ')}${names.length > 8 ? ' …' : ''}',
                  style: const TextStyle(fontSize: 12.5)),
              box(kAmber, 'CHECKSUM (ไม่แก้อัตโนมัติ)',
                  'ผลรวมไบต์ของไฟล์ตอนนี้ = 0x${sum8.toRadixString(16).toUpperCase().padLeft(2, '0')}${sum8 == 0 ? ' (ผ่าน)' : ' (ยังไม่ผ่าน)'}\n'
                      'เกจคำนวณ checksum ใหม่ให้เองตอนกด FLASH ที่เกจ (Keihin ตาม ID กล่อง/ขนาดไฟล์ · Shindengen อัตโนมัติ)'),
              if (locks.isEmpty)
                box(Colors.white38, 'รหัสล็อคกล่อง', 'ไม่ได้เปลี่ยน')
              else
                box(kBad, '⚠ รหัสล็อคกล่องถูกเปลี่ยน',
                    '${locks.map((l) => '${l.$1.title}: ${l.$2} → ${l.$3}').join('\n')}\nจดรหัสใหม่ไว้ ถ้าจำไม่ได้อาจอ่าน/แฟลชกล่องไม่ได้อีก'),
              ],
            ]),
          ),
        ),
        actions: [if (!kb) acts(false)],
      );
      },
    );
    final name = BinLib.clean(tc.text);
    tc.dispose();
    if (act == null || act == 0) return;
    if (name.isEmpty) {
      _snack('ตั้งชื่อไฟล์ก่อน');
      return;
    }
    final bytes = Uint8List.fromList(s.bin!);
    if (act == 1) {
      try {
        await BinLib.i.load();
        if (!mounted) return;
        if (BinLib.i.exists(name) && !await askYes(context, 'ชื่อซ้ำ', 'มีไฟล์ชื่อ "$name" ในคลังแล้ว เขียนทับหรือไม่?', ok: 'เขียนทับ')) return;
        await BinLib.i.save(name, bytes, xdfName: s.xdfName, xdfRaw: s.xdfRaw);
        s.markSaved();
        _snack('บันทึกเข้าคลังแล้ว: $name${s.xdfRaw != null ? ' + XDF' : ''} — แฟลชได้ที่หน้า FLASH⚡');
      } catch (e) {
        _snack('บันทึกไม่สำเร็จ: $e');
      }
      return;
    }
    try {
      final path = await FilePicker.platform.saveFile(dialogTitle: 'ส่งออก BIN', fileName: '$name.bin', type: FileType.any, bytes: bytes);
      _snack(path == null ? 'ยกเลิกการส่งออก' : 'ส่งออกแล้ว: $path');
    } catch (e) {
      _snack('ส่งออกไม่สำเร็จ: $e');
    }
  }

  // ----- 3D พรีวิว (หมุนรอบ) -----
  // ----- 3D: แตะจุด = เลือก, ลากจุดขึ้น/ลง = แก้ค่า, แตะ 2 ครั้งแล้วลาก = เลือกคลุม -----
  static int _ms() => DateTime.now().millisecondsSinceEpoch;

  (List<List<double>>, double, double) _range3(XdfTable t) {
    final v = s.values(t);
    double lo = double.infinity, hi = double.negativeInfinity;
    for (final row in v) {
      for (final x in row) {
        if (x.isNaN) continue;
        if (x < lo) lo = x;
        if (x > hi) hi = x;
      }
    }
    if (!lo.isFinite) {
      lo = 0;
      hi = 1;
    }
    if (_fLo != null) {
      lo = _fLo!;
      hi = _fHi!;
    }
    return (v, lo, hi);
  }

  _Proj3 _proj3(XdfTable t, double lo, double hi) => _Proj3(_v3, t.rows, t.cols, lo, hi, yaw, pitch, zoom, pan3);

  /// จุดบนผิว 3D ที่ใกล้นิ้วที่สุด (ในรัศมี 26px, ถ้าซ้อนกันเลือกจุดที่อยู่หน้าสุด)
  (int, int)? _hit3(XdfTable t, Offset pos) {
    if (_v3.isEmpty || t.rows < 2 || t.cols < 2) return null;
    final (v, lo, hi) = _range3(t);
    final P = _proj3(t, lo, hi);
    (int, int)? best;
    double bestD = -1e9;
    for (int r = 0; r < t.rows; r++) {
      for (int c = 0; c < t.cols; c++) {
        if (v[r][c].isNaN) continue;
        final q = P.pt(r.toDouble(), c.toDouble(), v[r][c]);
        if ((q.$1 - pos).distance > 26) continue;
        if (q.$2 > bestD) {
          bestD = q.$2;
          best = (r, c);
        }
      }
    }
    return best;
  }

  // ----- 3D (อ่านนิ้วเองทั้งหมด ไม่ผ่าน GestureDetector เพื่อให้จับ "แตะ 2 ครั้งแล้วลาก" ได้แน่นอน) -----
  // 1 นิ้ว: แตะจุด = เลือก | ลากจุด = แก้ค่าขึ้น/ลง | ลากที่ว่าง = หมุน | แตะ 2 ครั้งแล้วลาก = เลือกคลุม
  // 2 นิ้ว: บีบ/กาง = ซูม, ลากพร้อมกัน = เลื่อนกราฟขึ้น-ลง ไม่เกิน ±50% (ปุ่ม PREVIEW / แถบสี อยู่ที่เดิม)
  final Map<int, Offset> _p3 = {};
  Offset _p3Start = Offset.zero, _p3Last = Offset.zero;
  int _p3DownMs = 0;
  bool _p3Moved = false;
  double _pinch0 = 0;

  void _p3Down(XdfTable t, PointerDownEvent e) {
    _p3[e.pointer] = e.localPosition;
    _stopSpin();
    if (_p3.length >= 2) {
      if (_m3 != 4) _end1();
      final ps = _p3.values.toList();
      _pinch0 = (ps[0] - ps[1]).distance;
      _zoom0 = zoom;
      _mid0 = (ps[0] + ps[1]) / 2;
      _pan0 = pan3;
      _m3 = 4;
      return;
    }
    final now = _ms();
    _dblArm = now - _tapUpMs < 450 && (e.localPosition - _tapUpPos).distance < 60;
    _p3DownMs = now;
    _p3Start = _p3Last = e.localPosition;
    _p3Moved = false;
    _m3 = 0;
  }

  void _p3Move(XdfTable t, PointerMoveEvent e) {
    if (!_p3.containsKey(e.pointer)) return;
    _p3[e.pointer] = e.localPosition;
    if (_m3 == 4) {
      if (_p3.length >= 2 && _pinch0 > 0) {
        final ps = _p3.values.toList();
        setState(() {
          zoom = (_zoom0 * (ps[0] - ps[1]).distance / _pinch0).clamp(0.4, 4.0).toDouble();
          final lim = _v3.height * 0.5; // เลื่อนขึ้น/ลงได้ไม่เกิน 50% ของความสูงกรอบ
          pan3 = Offset(0, (_pan0.dy + ((ps[0] + ps[1]) / 2 - _mid0).dy).clamp(-lim, lim).toDouble()); // ลาก 2 นิ้ว = เลื่อนกราฟขึ้น-ลงเท่านั้น
        });
      }
      return;
    }
    if (_p3.length != 1) return;
    final p = e.localPosition;
    if (!_p3Moved) {
      if ((p - _p3Start).distance < 8) return;
      _p3Moved = true;
      _begin1(t, _p3Start);
    }
    final dl = p - _p3Last;
    _p3Last = p;
    _move1(t, p, dl);
  }

  void _p3Up(XdfTable t, PointerEvent e) {
    if (_p3.remove(e.pointer) == null) return;
    if (_m3 == 4) {
      if (_p3.isEmpty) _m3 = 0;
      return;
    }
    if (e is PointerCancelEvent) {
      _end1();
      return;
    }
    final now = _ms();
    if (!_p3Moved && now - _p3DownMs < 350) {
      if (_dblArm) {
        // แตะ 2 ครั้งแต่ไม่ได้ลาก = ไม่ทำอะไร
        _dblArm = false;
        _tapUpMs = 0;
        return;
      }
      _tapUpMs = now;
      _tapUpPos = e.localPosition;
      final h = _hit3(t, e.localPosition);
      if (h != null) {
        setState(() {
          a0 = h;
          a1 = h;
        });
      }
      return;
    }
    _end1();
  }

  void _begin1(XdfTable t, Offset start) {
    if (_dblArm) {
      _m3 = 3;
      _boxA = start;
      _boxB = start;
      setState(() {});
      return;
    }
    final h = _hit3(t, start);
    if (h == null) {
      _m3 = 1;
      return;
    }
    if (t.isLock && !s.lockOk) {
      _m3 = 0;
      _canEdit(t);
      return;
    }
    final g = _sel;
    if (g == null || h.$1 < g.$1 || h.$1 > g.$3 || h.$2 < g.$2 || h.$2 > g.$4) {
      a0 = h;
      a1 = h;
    }
    final (_, lo, hi) = _range3(t);
    _fLo = lo;
    _fHi = hi;
    _dragBase = {for (final rc in _cells) rc: s.val(t, rc.$1, rc.$2)};
    _dragDy = 0;
    _m3 = 2;
    setState(() {});
  }

  void _move1(XdfTable t, Offset p, Offset dl) {
    switch (_m3) {
      case 1:
        setState(() {
          yaw -= dl.dx * 0.01;
          pitch = (pitch + dl.dy * 0.008).clamp(0.1, 1.5).toDouble();
        });
      case 2:
        {
          _dragDy += dl.dy;
          final lo = _fLo ?? 0, hi = _fHi ?? 1;
          final span = hi > lo ? hi - lo : 1.0;
          final px = _proj3(t, lo, hi).sc * _Proj3.zh * math.cos(pitch);
          if (px <= 0) return;
          final dv = -_dragDy / px * span;
          _w(t, {for (final e in _dragBase.entries) e.key: e.value + dv}, 'ลากจุด 3D', merge: true);
        }
      case 3:
        {
          _boxB = p;
          final rect = Rect.fromPoints(_boxA!, p);
          final (v, lo, hi) = _range3(t);
          final P = _proj3(t, lo, hi);
          int r0 = 1 << 30, c0 = 1 << 30, r1 = -1, c1 = -1;
          for (int r = 0; r < t.rows; r++) {
            for (int c = 0; c < t.cols; c++) {
              if (v[r][c].isNaN) continue;
              if (!rect.contains(P.pt(r.toDouble(), c.toDouble(), v[r][c]).$1)) continue;
              r0 = math.min(r0, r);
              c0 = math.min(c0, c);
              r1 = math.max(r1, r);
              c1 = math.max(c1, c);
            }
          }
          setState(() {
            if (r1 >= 0) {
              a0 = (r0, c0);
              a1 = (r1, c1);
            }
          });
        }
    }
  }

  void _end1() {
    final dragged = _m3 == 2;
    _m3 = 0;
    _boxA = null;
    _boxB = null;
    _fLo = null;
    _fHi = null;
    _dragBase = {};
    _dblArm = false;
    if (mounted) setState(() {});
    if (dragged && s.table != null && !s.tableDirty(s.table!)) _snack('ค่าไม่เปลี่ยน (น้อยกว่า 1 ขั้นของข้อมูล)');
  }

  void _toggleSpin() {
    if (_spin != null) {
      _spin!.cancel();
      setState(() => _spin = null);
      return;
    }
    _spin = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!mounted) return;
      setState(() {
        yaw += 0.0075;                                           // หมุนวนทางเดียวต่อเนื่อง (~14 วินาที/รอบ)
        if (yaw > math.pi * 2) yaw -= math.pi * 2;
      });
    });
    setState(() {});
  }

  void _stopSpin() {
    if (_spin == null) return;
    _spin!.cancel();
    _spin = null;
  }

  // ======================= UI =======================
  @override
  Widget build(BuildContext context) {
    final th = Cfg.i.t;
    if (_shownSel != s.sel) {
      _shownSel = s.sel;
      _resetView();
    }
    final t = s.table;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        Image.asset('assets/bg.jpg', fit: BoxFit.cover),
        Container(color: Colors.black.withOpacity(0.84)),
        const HudGrid(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: Column(children: [
              _topBar(th),
              SizedBox(
                height: 17,
                child: Row(children: [
                  Expanded(
                    child: Text(
                        showPct && s.cmpName != null
                            ? 'BIN: ${s.binName ?? '-'}  ·  เทียบกับ: ${s.cmpName}  (แตะค้าง Δ% เพื่อเปลี่ยน)'
                            : 'BIN: ${s.binName ?? '-'}     XDF: ${s.xdfName ?? '-'}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5, color: showPct ? kGreen : Colors.white54)),
                  ),
                  if (s.ready && t != null && t.valid) Text(showPct && s.cmpRef != null ? _pctInfo(t) : _selInfo(t), style: const TextStyle(fontSize: 10.5, color: Colors.white60)),
                ]),
              ),
              const SizedBox(height: 2),
              Expanded(
                child: Stack(key: _bodyKey, clipBehavior: Clip.none, children: [
                  Positioned.fill(child: _body(th)),
                  if (_adjOpen && s.ready && t != null && t.valid)
                    Positioned(top: -8, left: _adjLeft(), right: 0, child: Align(alignment: Alignment.topLeft, child: _adjPanel(th))),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _tb(AppTheme th, Widget child, VoidCallback? onTap, {bool active = false, Color? col, Key? key, double? width}) {
    final cc = col ?? th.c;
    return Padding(
      key: key,
      padding: const EdgeInsets.only(right: 4),
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 34,
            width: width,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: hudDeco(border: cc, width: 1.3, radius: 8, color: active ? cc.withOpacity(0.3) : Colors.black45),
            child: DefaultTextStyle.merge(style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold), child: child),
          ),
        ),
      ),
    );
  }

  Widget _sep() => Container(width: 1, height: 22, margin: const EdgeInsets.only(right: 4), color: Colors.white24);

  Widget _topBar(AppTheme th) {
    final t = s.table;
    final can = s.ready && t != null && t.valid;
    final is2D = t?.is2D ?? true;
    final dirty = t != null && s.tableDirty(t);
    return SizedBox(
      height: 34,
      child: Row(children: [
        _tb(th, Icon(Icons.arrow_back, size: 18, color: th.c), () => Navigator.of(context).pop(), width: 38),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _fileMenu(th),
              _tb(
                th,
                Row(mainAxisSize: MainAxisSize.min, children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 100),
                    child: Text(t?.title ?? 'ตารางจูน', maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  const Text(' ▾'),
                ]),
                s.ready ? () => _tableMenu(th) : null,
                key: _tblKey,
              ),
              _tb(
                th,
                Stack(clipBehavior: Clip.none, children: [
                  const Text('✅', style: TextStyle(fontSize: 16)),
                  if (dirty)
                    Positioned(right: -6, top: -4, child: Container(width: 7, height: 7, decoration: const BoxDecoration(color: kAmber, shape: BoxShape.circle))),
                ]),
                can ? _okTable : null,
                col: kGreen,
                active: dirty,
                width: 42,
              ),
              _tb(th, const Text('❌', style: TextStyle(fontSize: 15)), can ? _cancelTable : null, col: kBad, width: 42),
              _sep(),
              // ปรับค่า: แตะแล้วกางแผง ช่องค่า | − + % = | X Y XY ~
              _tb(
                th,
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.edit, size: 15, color: th.c),
                  const SizedBox(width: 5),
                  const Text('ปรับค่า'),
                  Icon(_adjOpen && can ? Icons.expand_less : Icons.expand_more, size: 18, color: th.c),
                ]),
                can ? () => setState(() => _adjOpen = !_adjOpen) : null,
                active: _adjOpen && can,
                key: _adjKey,
              ),
              _sep(),
              _tb(th, Icon(Icons.undo, size: 18, color: th.c), s.undoList.isNotEmpty ? _undo : null),
              _tb(th, Icon(Icons.redo, size: 18, color: th.c), s.redoList.isNotEmpty ? _redo : null),
              _sep(),
              _tb(th, const Text('COPY', style: TextStyle(fontFamily: kFont, fontSize: 10.5)), can && _sel != null ? _copy : null),
              _tb(th, const Text('PASTE', style: TextStyle(fontFamily: kFont, fontSize: 10.5)), can && _clip != null ? _paste : null),
              _tb(th, const Text('AFR', style: TextStyle(fontFamily: kFont, fontSize: 10.5, color: kGreen)), _openAfr, col: kGreen),
              _tb(th, const Text('AFR→จูน', style: TextStyle(fontSize: 11.5, color: kGreen)), can ? _afrTune : null, col: kGreen),
              GestureDetector(
                onLongPress: can ? _pickCmp : null, // แตะค้าง = เปลี่ยนไฟล์ที่เทียบ
                child: _tb(th, const Text('Δ%', style: TextStyle(fontFamily: kFont, fontSize: 11)), can ? _togglePct : null, active: showPct),
              ),
              _sep(),
              _tb(
                th,
                const Text('FIT'),
                can ? _fit : null,
              ),
              _tb(
                th,
                Text(view3d ? '2D' : (is2D ? '3D' : 'GRAPH')),
                can
                    ? () => setState(() {
                          view3d = !view3d;
                          if (!view3d) _stopSpin();
                        })
                    : null,
                active: view3d,
              ),
              _tb(
                th,
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 7, height: 7,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: live && _liveData ? kGreen : (live ? kAmber : Colors.white30)),
                  ),
                  const SizedBox(width: 5),
                  const Text('LIVE'),
                ]),
                () => setState(() {
                  live = !live;
                  _lastTouch = 0;
                }),
                active: live,
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  // ---- Δ% เทียบไฟล์อ้างอิง ----
  Future<void> _togglePct() async {
    if (showPct) {
      setState(() => showPct = false);
      return;
    }
    if (s.cmpRef == null && !await _autoCmp()) {
      await _pickCmp();
      if (s.cmpRef == null) return;
    }
    if (mounted) setState(() => showPct = true);
  }

  /// เลือกไฟล์ ORIGINAL ในแอปให้อัตโนมัติ: ตรง ID กล่อง > ชื่อ XDF ตรงกัน > ชื่อ BIN ตรงกัน
  Future<bool> _autoCmp() async {
    final ecm = c.t.fl?.ecm;
    OrigPack? p;
    for (final o in kOriginals) {
      if (o.matches(ecm)) p ??= o;
    }
    for (final o in kOriginals) {
      if (o.xdfName == s.xdfName) p ??= o;
    }
    for (final o in kOriginals) {
      if (o.binName == s.binName) p ??= o;
    }
    if (p == null) return false;
    try {
      final b = (await rootBundle.load(p.bin)).buffer.asUint8List();
      s.setCmp('${p.binName} (ORIGINAL ในแอป)', b);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// เลือกไฟล์ที่ใช้เทียบ: ORIGINAL ในแอป / ไฟล์ในคลัง / ไฟล์ตอนเปิด
  Future<void> _pickCmp() async {
    final th = Cfg.i.t;
    await BinLib.i.load();
    if (!mounted) return;
    final pick = await showDialog<(String, Future<Uint8List?> Function())>(
      context: context,
      barrierDismissible: true,
      builder: (dctx) {
        Widget item(String t, String sub, (String, Future<Uint8List?> Function()) v) => InkWell(
              onTap: () => Navigator.of(dctx).pop(v),
              child: Container(
                margin: const EdgeInsets.only(bottom: 5),
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                decoration: hudDeco(border: Colors.white24, width: 1, radius: 8, color: Colors.white.withOpacity(0.03), tick: false),
                child: Row(children: [
                  Expanded(child: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
                  Text(sub, style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
                ]),
              ),
            );
        Widget head(String t) => Padding(padding: const EdgeInsets.fromLTRB(2, 6, 0, 4), child: Text(t, style: TextStyle(fontFamily: kFont, fontSize: 8, color: th.c2)));
        return Dialog(
          backgroundColor: const Color(0xFF0C0D10),
          shape: HudBorder(cut: 14, side: BorderSide(color: th.c, width: 1.3)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('เทียบ Δ% กับไฟล์ไหน', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  if (s.orig != null) ...[
                    head('ไฟล์ตอนเปิด'),
                    item(s.binName ?? 'ไฟล์ตอนเปิด', 'ก่อนแก้ในรอบนี้', ('${s.binName ?? ''} (ตอนเปิด)', () async => s.orig)),
                  ],
                  head('ORIGINAL ในแอป'),
                  for (final o in kOriginals)
                    item('${o.model.isEmpty ? o.name : o.model}  ${o.name}', '${o.binKb} KB', ('${o.binName} (ORIGINAL ในแอป)', () async => (await rootBundle.load(o.bin)).buffer.asUint8List())),
                  if (BinLib.i.items.isNotEmpty) head('คลังไฟล์'),
                  for (final e in BinLib.i.items)
                    item(e.name, '${(e.size / 1024).toStringAsFixed(0)} KB · ${_dateStr(e.time)}', ('${e.name}.bin (คลังไฟล์)', () async => BinLib.i.read(e))),
                ]),
              ),
            ]),
          ),
        );
      },
    );
    if (pick == null || !mounted) return;
    try {
      final b = await pick.$2();
      if (b == null) return;
      s.setCmp(pick.$1, b);
      if (b.length != (s.bin?.length ?? 0)) _snack('ขนาดไฟล์ไม่เท่ากัน — เทียบได้เฉพาะช่องที่อยู่ในขนาดไฟล์');
      setState(() => showPct = true);
    } catch (e) {
      _snack('เปิดไฟล์ที่ใช้เทียบไม่ได้: $e');
    }
  }

  /// สรุป Δ% ของตารางที่เปิดอยู่
  String _pctInfo(XdfTable t) {
    int n = 0, all = 0;
    double mx = 0, mn = 0, sum = 0;
    for (int r = 0; r < t.rows; r++) {
      for (int c = 0; c < t.cols; c++) {
        final d = s.pctDiff(t, r, c);
        if (d == null) continue;
        all++;
        sum += d;
        if (d.abs() >= 0.05) n++;
        if (d > mx) mx = d;
        if (d < mn) mn = d;
      }
    }
    if (all == 0) return 'Δ% เทียบไม่ได้';
    String f(double v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)}%';
    return 'ต่าง $n/$all ช่อง · มากสุด ${f(mx)} · น้อยสุด ${f(mn)} · เฉลี่ย ${f(sum / all)}';
  }

  // ---- AFR → จูนอัตโนมัติ ----
  Future<void> _afrTune() async {
    final t = s.table;
    if (t == null || !t.valid || !t.is2D) {
      _snack('เลือกตารางน้ำมัน (2D แกน RPM × TPS) ก่อน');
      return;
    }
    final ky = _axisKind(s.axisNums(t, false)), kx = _axisKind(s.axisNums(t, true));
    if (!((ky == 1 && kx == 2) || (ky == 2 && kx == 1))) {
      _snack('ตารางนี้ไม่มีแกน RPM + TPS — เลือกตารางน้ำมันก่อน');
      return;
    }
    AfrLog.i.attach(c);
    AfrLog.i.syncAxes(s);
    if (!AfrLog.i.ready || AfrLog.i.filled == 0) {
      _snack('ยังไม่มีข้อมูล AFR LOG — วิ่งเก็บค่าที่หน้า AFR LOG ก่อน');
      return;
    }
    final out = await Navigator.of(context).push<Map<(int, int), double>>(hudRoute(AfrTunePage(s: s, t: t)));
    if (out == null || out.isEmpty || !mounted) return;
    if (!await _canEdit(t)) return;
    final n = _w(t, out, 'AFR → จูน ${out.length} ช่อง');
    _snack('ใส่ค่าจาก AFR ลง ${t.title} แล้ว $n ช่อง — ย้อนกลับ (↶) ได้');
  }

  Future<void> _openAfr() async {
    AfrLog.i.attach(c);
    AfrLog.i.syncAxes(s);
    await Navigator.of(context).push(hudRoute(AfrLogPage(c: c)));
  }

  double _adjLeft() {
    final a = _adjKey.currentContext?.findRenderObject() as RenderBox?;
    final b = _bodyKey.currentContext?.findRenderObject() as RenderBox?;
    if (a == null || b == null || !a.attached || !b.attached) return 0;
    return math.max(0.0, a.localToGlobal(Offset.zero).dx - b.localToGlobal(Offset.zero).dx - 12);
  }

  /// แผง "ปรับค่า" ลอยทับตาราง (ยังเลือกช่องในตารางได้ระหว่างเปิด / แตะปุ่ม "ปรับค่า" อีกครั้ง = ยุบ)
  Widget _adjPanel(AppTheme th) {
    final t = s.table;
    final can = s.ready && t != null && t.valid;
    Widget k(String txt, VoidCallback? f, {double fs = 16, bool eth = false}) =>
        _tb(th, Text(txt, style: TextStyle(fontSize: fs, fontFamily: eth ? kFont : null)), can ? f : null, width: eth && txt.length > 1 ? 50 : 42);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Padding(padding: const EdgeInsets.only(left: 44), child: CustomPaint(size: const Size(16, 8), painter: _TriPainter(th.c))),
      Material(
        color: const Color(0xF4141018),
        elevation: 10,
        shape: HudBorder(cut: 13, side: BorderSide(color: th.c, width: 1.4)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 7, 4, 7),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.only(right: 5),
                child: SizedBox(
                  width: 130,
                  height: 34,
                  child: TextField(
                    controller: amtCtl,
                    enabled: can,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
                      hintText: 'ใส่ค่าที่ต้องการ',
                      hintStyle: const TextStyle(fontSize: 11.5, color: Colors.white38),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white38)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: th.c2, width: 1.5)),
                      disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                    ),
                  ),
                ),
              ),
              _sep(),
              Opacity(opacity: can ? 1 : 0.4, child: StepBtn(label: '−', onStep: () => can ? _bump(-1) : null, th: th)),
              const SizedBox(width: 4),
              Opacity(opacity: can ? 1 : 0.4, child: StepBtn(label: '+', onStep: () => can ? _bump(1) : null, th: th)),
              const SizedBox(width: 4),
              k('%', _pct, fs: 15),
              k('=', () => _setVal(), fs: 15),
              _sep(),
              k('X', () => _interp(0), fs: 12, eth: true),
              k('Y', () => _interp(1), fs: 12, eth: true),
              k('XY', () => _interp(2), fs: 12, eth: true),
              k('~', _smooth, fs: 18),
            ]),
          ),
        ),
      ),
    ]);
  }

  Widget _fileMenu(AppTheme th) {
    final t = s.table;
    final cellsChanged = t != null && _sel != null && s.bin != null && _cells.any((rc) => s.cellChanged(t, rc.$1, rc.$2));
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: PopupMenuButton<int>(
        color: const Color(0xFF16161D),
        tooltip: 'ไฟล์',
        onSelected: (v) {
          switch (v) {
            case 1:
              _openOriginals();
              break;
            case 2:
              _openBin();
              break;
            case 3:
              _openXdf();
              break;
            case 4:
              _openFromLib();
              break;
            case 5:
              _save();
              break;
            case 6:
              _clearBin();
              break;
            case 7:
              _clearXdf();
              break;
            case 8:
              if (t != null) {
                final n = s.revert(t, _cells, 'คืนค่าเดิม ${_cells.length} ช่อง');
                _snack(n == 0 ? 'ช่องที่เลือกเป็นค่าเดิมอยู่แล้ว' : 'คืนค่าเดิมแล้ว');
              }
              break;
            case 9:
              _confirm('คืนค่าเดิมทั้งไฟล์', 'ยกเลิกการแก้ไขทั้งหมด (${s.changedBytes} ไบต์) — ย้อนกลับได้ด้วยปุ่ม ↶', ok: 'คืนค่าเดิม').then((ok) {
                if (ok) s.revert(null, null, 'คืนค่าเดิมทั้งไฟล์');
              });
              break;
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
              value: 1,
              child: _menuRow(Icons.folder_special, _pickLabel,
                  'ไฟล์ ORIGINAL: ${kOriginals.map((o) => o.name).join(', ')}${_pickMode == 0 ? '' : (_pickMode == 2 ? ' · BIN ปัจจุบันไม่ถูกเปลี่ยน' : ' · XDF ปัจจุบันไม่ถูกเปลี่ยน')}', kGreen)),
          PopupMenuItem(value: 2, child: _menuRow(Icons.folder_open, 'เปิด BIN', s.binName ?? 'เฉพาะไฟล์ .bin', th.c)),
          PopupMenuItem(value: 3, child: _menuRow(Icons.description, 'เปิด XDF', s.xdfName ?? 'เฉพาะไฟล์ .xdf', th.c)),
          PopupMenuItem(value: 4, child: _menuRow(Icons.folder_copy, 'เปิดไฟล์จากคลังไฟล์', 'ไฟล์ที่บันทึกไว้ในแอพ', th.c2)),
          PopupMenuItem(enabled: s.bin != null, value: 5, child: _menuRow(Icons.download, 'บันทึกเข้าคลังไฟล์', 'ตั้งชื่อเองได้ / ส่งออกไฟล์', kGreen)),
          PopupMenuItem(enabled: s.bin != null, value: 6, child: _menuRow(Icons.close, 'ล้าง BIN', '', kAmber)),
          PopupMenuItem(enabled: s.xdf != null, value: 7, child: _menuRow(Icons.close, 'ล้าง XDF', '', kAmber)),
          const PopupMenuDivider(),
          PopupMenuItem(enabled: cellsChanged, value: 8, child: _menuRow(Icons.restore, 'คืนค่าเดิมช่องที่เลือก', 'กลับเป็นค่าในไฟล์ที่เปิด', Colors.white54)),
          PopupMenuItem(enabled: s.changedBytes > 0, value: 9, child: _menuRow(Icons.settings_backup_restore, 'คืนค่าเดิมทั้งไฟล์', '${s.changedBytes} ไบต์ที่แก้', Colors.white54)),
        ],
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          alignment: Alignment.center,
          decoration: hudDeco(border: th.c, width: 1.3, radius: 8, color: Colors.black45),
          child: const Text('ไฟล์ ▾', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  Widget _menuRow(IconData ic, String a, String b, Color col) => Row(children: [
        Icon(ic, size: 20, color: col),
        const SizedBox(width: 12),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(a, style: const TextStyle(fontSize: 14)),
            if (b.isNotEmpty) Text(b, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
          ]),
        ),
      ]);

  /// ข้อความเล็กท้ายบรรทัดชื่อไฟล์: ค่าช่องที่เลือก + LIVE
  String _selInfo(XdfTable t) {
    final cells = _cells;
    String a = '';
    if (cells.isNotEmpty && s.bin != null) {
      final vs = cells.map((rc) => s.val(t, rc.$1, rc.$2)).toList();
      final avg = vs.reduce((x, y) => x + y) / vs.length;
      a = cells.length == 1 ? 'ค่า ${t.fmt(avg)}' : '${cells.length} ช่อง · เฉลี่ย ${avg.toStringAsFixed(math.min(6, t.dec + 1))}';
    }
    if (live && _liveData) {
      final l = 'RPM ${c.t.rpm?.round() ?? '--'} · TPS ${c.t.tps?.toStringAsFixed(1) ?? '--'}';
      a = a.isEmpty ? l : '$a     $l';
    }
    return a;
  }

  /// การ์ดตอนยังไม่ได้เลือกไฟล์/ตาราง
  Widget _emptyCard(AppTheme th, String title, String sub, String btn, VoidCallback onTap, {List<Widget> extra = const []}) {
    return Center(
      child: SingleChildScrollView(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 560),
          margin: const EdgeInsets.all(8),
          padding: const EdgeInsets.fromLTRB(28, 18, 28, 26),
          decoration: hudDeco(border: Colors.white24, width: 1.2, radius: 24, color: const Color(0xE60E0E14)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Container(width: 96, height: 4, decoration: BoxDecoration(color: th.c, borderRadius: BorderRadius.circular(2))),
            ),
            const SizedBox(height: 22),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Text(sub, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13.5, color: Colors.white60)),
            const SizedBox(height: 16),
            InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(26),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 14),
                decoration: hudDeco(border: th.c2.withOpacity(0.6), radius: 26, color: th.c.withOpacity(0.85)),
                child: Text(btn, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: Colors.white)),
              ),
            ),
            ...extra,
          ]),
        ),
      ),
    );
  }

  Widget _body(AppTheme th) {
    if (!s.ready) {
      return _emptyCard(
        th,
        'ยังไม่ได้เลือกไฟล์',
        switch (_pickMode) {
          1 => 'เปิด XDF จากภายนอกแล้ว — เลือก BIN ที่อยู่ในแอปมาใช้คู่กัน',
          2 => 'เปิด BIN จากภายนอกแล้ว — เลือก XDF ที่อยู่ในแอปมาใช้คู่กัน',
          _ => 'เลือก BIN + XDF จากเมนูไฟล์ เพื่อเริ่มแก้ไข',
        },
        _pickLabel,
        _openOriginals,
        extra: [
          const SizedBox(height: 10),
          Wrap(spacing: 4, alignment: WrapAlignment.center, children: [
            TextButton(onPressed: _openBin, child: Text(s.bin == null ? 'เปิด BIN' : 'BIN ✓', style: TextStyle(color: th.c2))),
            TextButton(onPressed: _openXdf, child: Text(s.xdf == null ? 'เปิด XDF' : 'XDF ✓', style: TextStyle(color: th.c2))),
            TextButton(onPressed: _openFromLib, child: Text('เปิดจากคลังไฟล์', style: TextStyle(color: th.c2))),
          ]),
        ],
      );
    }
    final t = s.table;
    if (t == null) {
      return _emptyCard(th, 'ยังไม่ได้เลือกตารางจูน', 'เลือกแมพจากเมนูตารางจูนเพื่อเริ่มแก้ไข', 'เปิดตารางจูน', () => _tableMenu(th));
    }
    if (!t.valid) {
      return Center(
        child: Text('ตารางนี้อยู่นอกขนาดไฟล์ BIN (@0x${t.z.addr.toRadixString(16)})\nตรวจว่า BIN กับ XDF เป็นไฟล์คู่กัน',
            textAlign: TextAlign.center, style: const TextStyle(color: kAmber)),
      );
    }
    final v = s.values(t);
    double lo = double.infinity, hi = double.negativeInfinity;
    for (final row in v) {
      for (final x in row) {
        if (x.isNaN) continue;
        if (x < lo) lo = x;
        if (x > hi) hi = x;
      }
    }
    if (!lo.isFinite) {
      lo = 0;
      hi = 1;
    }
    if (view3d && _fLo != null) {
      lo = _fLo!;
      hi = _fHi!;
    }
    final lp = _livePos(t);
    final frame = hudDeco(border: th.c.withOpacity(0.85), width: 1.1, radius: 10, color: const Color(0xCC060606));
    final rowL = s.axisLabels(t, false), colL = s.axisLabels(t, true);
    if (view3d) {
      return Container(
        decoration: frame,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: t.is2D
              ? Stack(children: [
                  Listener(
                    onPointerDown: (e) => _p3Down(t, e),
                    onPointerMove: (e) => _p3Move(t, e),
                    onPointerUp: (e) => _p3Up(t, e),
                    onPointerCancel: (e) => _p3Up(t, e),
                    child: Builder(builder: (_) {
                      return LayoutBuilder(builder: (_, cs) {
                        _v3 = Size(cs.maxWidth, cs.maxHeight);
                        return CustomPaint(
                          size: Size.infinite,
                          painter: _SurfacePainter(
                            v: v, lo: lo, hi: hi, yaw: yaw, pitch: pitch, zoom: zoom, pan: pan3, lr: lp.$1, lc: lp.$2, th: th,
                            rowL: rowL, colL: colL, t: t,
                            xName: _axisName(t, true), yName: _axisName(t, false), zName: t.title,
                            spin: _spin != null,
                            sel: _sel,
                            box: _boxA != null && _boxB != null ? Rect.fromPoints(_boxA!, _boxB!) : null,
                          ),
                        );
                      });
                    }),
                  ),
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: _tb(
                      th,
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(_spin != null ? Icons.stop : Icons.threesixty, size: 16, color: th.c),
                        const SizedBox(width: 5),
                        Text(_spin != null ? 'STOP' : 'PREVIEW'),
                      ]),
                      _toggleSpin,
                      active: _spin != null,
                    ),
                  ),
                ])
              : CustomPaint(
                  size: Size.infinite,
                  painter: _BarsPainter(
                    v: [for (final row in v) ...row],
                    labels: t.rows == 1 ? colL : rowL,
                    lo: lo, hi: hi,
                    lf: t.rows == 1 ? lp.$2 : lp.$1,
                    th: th, t: t,
                  ),
                ),
        ),
      );
    }

    final maxLab = rowL.fold<int>(1, (m, x) => math.max(m, x.length));
    hw = (14 + maxLab * 6.8).clamp(46.0, 130.0).toDouble();
    return Container(
      decoration: frame,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: LayoutBuilder(builder: (_, cs) {
          view = Size(cs.maxWidth, cs.maxHeight);
          _clampScroll(t);
          if (lp.$1 != null && lp.$2 != null && _now - _lastTouch > 3000) _ensureVisible(t, lp.$1!, lp.$2!);
          return Stack(children: [
            GestureDetector(
              onScaleStart: (d) => _gStartH(t, d),
              onScaleUpdate: (d) => _gUpdateH(t, d),
              onScaleEnd: (_) => _gEndH(t),
              child: CustomPaint(
                size: Size.infinite,
                painter: _GridPainter(
                  s: s, t: t, v: v, lo: lo, hi: hi, rowL: rowL, colL: colL,
                  sx: sx, sy: sy, cw: cw, ch: ch, hw: hw, hh: hh,
                  sel: _sel, lr: lp.$1, lc: lp.$2, th: th, rev: s.rev, pct: showPct && s.cmpRef != null,
                ),
              ),
            ),
            const Positioned(
              right: 8, bottom: 4,
              child: IgnorePointer(
                child: Text('1 นิ้ว = เลือก · 2 นิ้ว = ซูม/เลื่อน · แตะ/ลากหัวตาราง = เลือกทั้งแถว/คอลัมน์ · แตะ 2 ครั้ง = ใส่ค่า · FIT = พอดีจอ',
                    style: TextStyle(fontSize: 9.5, color: Colors.white30)),
              ),
            ),
          ]);
        }),
      ),
    );
  }

  // ----- เมนูตารางจูน (ดรอปดาวน์ใต้ปุ่ม): FLAGS / ตารางจูน / ค่า-แกน 1 มิติ -----
  Future<void> _tableMenu(AppTheme th) async {
    if (!s.ready) {
      _snack('เลือกไฟล์ BIN + XDF ก่อน');
      return;
    }
    final d = s.xdf!;
    final box = _tblKey.currentContext?.findRenderObject() as RenderBox?;
    final pos = box?.localToGlobal(Offset.zero) ?? const Offset(150, 40);
    final top = pos.dy + (box?.size.height ?? 34) + 6;
    final picked = await showGeneralDialog<int>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'ตารางจูน',
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 140),
      transitionBuilder: (_, a, __, child) => FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeOut), child: child),
      pageBuilder: (dctx, _, __) {
        final sz = MediaQuery.of(dctx).size;
        final w = math.min(300.0, sz.width - 16);
        final left = pos.dx.clamp(8.0, math.max(8.0, sz.width - w - 8)).toDouble();
        return Stack(children: [
          Positioned(
            left: left,
            top: top,
            width: w,
            bottom: 8,
            child: Material(
              color: const Color(0xF20C0C12),
              shape: HudBorder(cut: 13, side: BorderSide(color: th.c, width: 1.2)),
              child: StatefulBuilder(builder: (dctx, setM) {
                Widget section(IconData ic, String title, int n, bool open, VoidCallback toggle, List<Widget> kids) => Column(children: [
                      InkWell(
                        onTap: toggle,
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 5),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: hudDeco(border: th.c.withOpacity(0.6), radius: 12, color: Colors.white.withOpacity(0.05)),
                          child: Row(children: [
                            Icon(ic, color: th.c2, size: 18),
                            const SizedBox(width: 10),
                            Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                            const SizedBox(width: 8),
                            Text('($n)', style: const TextStyle(fontSize: 12, color: Colors.white54)),
                            const Spacer(),
                            AnimatedRotation(turns: open ? 0.5 : 0, duration: const Duration(milliseconds: 150), child: Icon(Icons.expand_more, color: th.c2)),
                          ]),
                        ),
                      ),
                      if (open) ...kids,
                      const SizedBox(height: 4),
                    ]);

                Widget tile(int i, Widget lead, String sub) {
                  final t = d.tables[i];
                  final on = s.sel == i;
                  return Opacity(
                    opacity: t.valid ? 1 : 0.4,
                    child: InkWell(
                      onTap: t.valid ? () => Navigator.of(dctx).pop(i) : null,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 4, left: 6),
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: sub.isEmpty ? 7 : 5),
                        decoration: hudDeco(border: on ? th.c : Colors.white12, width: on ? 1.5 : 1, radius: 8, color: on ? th.c.withOpacity(0.2) : Colors.white.withOpacity(0.03)),
                        child: Row(children: [
                          lead,
                          if (lead is! SizedBox) const SizedBox(width: 8),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                if (t.isLock) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.lock, size: 13, color: kBad)),
                                Flexible(child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
                              ]),
                              if (!t.valid || sub.isNotEmpty)
                                Text(t.valid ? sub : 'อยู่นอกไฟล์ BIN', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
                            ]),
                          ),
                          if (t.valid && s.tableDirty(t))
                            const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.circle, size: 8, color: kAmber))
                          else if (t.valid && s.tableUnsaved(t))
                            Container(width: 8, height: 8, decoration: BoxDecoration(color: th.c, shape: BoxShape.circle)),
                        ]),
                      ),
                    ),
                  );
                }

                String preview(XdfTable t) {
                  if (!t.valid) return '';
                  final vs = <String>[];
                  for (int r = 0; r < t.rows && vs.length < 5; r++) {
                    for (int cc = 0; cc < t.cols && vs.length < 5; cc++) {
                      vs.add(t.fmt(s.val(t, r, cc)));
                    }
                  }
                  return '${t.rows * t.cols > 1 ? '${t.rows}×${t.cols} · ' : ''}${vs.join('  ')}${t.rows * t.cols > 5 ? ' …' : ''}';
                }

                final items2 = [for (int i = 0; i < d.tables.length; i++) if (d.tables[i].is2D) i];
                final items1 = [for (int i = 0; i < d.tables.length; i++) if (!d.tables[i].is2D) i];
                return ListView(padding: const EdgeInsets.all(8), children: [
                  section(Icons.flag_outlined, 'FLAGS', d.flags.length, _mnF, () => setM(() => _mnF = !_mnF), [
                    for (final f in d.flags)
                      Opacity(
                        opacity: f.valid ? 1 : 0.4,
                        child: InkWell(
                          onTap: f.valid
                              ? () {
                                  s.setFlag(f, !s.flagOn(f));
                                  setM(() {});
                                }
                              : null,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 5, left: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                            decoration: hudDeco(border: Colors.white12, radius: 8, color: Colors.white.withOpacity(0.03)),
                            child: Row(children: [
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(f.title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                                  Text(
                                      '@0x${f.d.addr.toRadixString(16).toUpperCase()} bit 0x${f.mask.toRadixString(16).toUpperCase()}'
                                      '${f.valid && s.flagOn(f) != s.flagOn(f, original: true) ? ' · แก้แล้ว' : ''}',
                                      style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
                                ]),
                              ),
                              _pill(f.valid && s.flagOn(f), th),
                            ]),
                          ),
                        ),
                      ),
                  ]),
                  section(Icons.grid_on, 'ตารางจูน', items2.length, _mn2, () => setM(() => _mn2 = !_mn2), [
                    for (final i in items2) tile(i, const SizedBox.shrink(), ''), // แค่ชื่อตาราง (ไม่มีภาพย่อ / สูตร)
                  ]),
                  section(Icons.linear_scale, 'ค่า / แกน 1 มิติ', items1.length, _mn1, () => setM(() => _mn1 = !_mn1), [
                    for (final i in items1)
                      tile(i, Icon(d.tables[i].rows * d.tables[i].cols == 1 ? Icons.tag : Icons.linear_scale, size: 18, color: th.c2), preview(d.tables[i])),
                  ]),
                ]);
              }),
            ),
          ),
        ]);
      },
    );
    if (picked != null) await _pickTable(picked);
  }

  Widget _pill(bool on, AppTheme th) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text(on ? 'ON' : 'OFF', style: TextStyle(fontFamily: kFont, fontSize: 9, color: on ? th.c : Colors.white38)),
        const SizedBox(width: 6),
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 44, height: 24,
          padding: const EdgeInsets.all(3),
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          decoration: hudDeco(border: on ? th.c : Colors.white30, radius: 12, color: on ? th.c.withOpacity(0.35) : Colors.white10),
          child: Container(
            width: 16, height: 16,
            decoration: BoxDecoration(shape: BoxShape.circle, color: on ? th.c : Colors.white54, boxShadow: on ? [BoxShadow(color: th.c, blurRadius: 6)] : null),
          ),
        ),
      ]);
}

// ---------- ตาราง 2D (วาดเฉพาะช่องที่เห็น หัวแถว/หัวคอลัมน์ล็อกอยู่กับที่) ----------
// มุมขวาบนสีขาว = ต่างจากไฟล์ที่เปิด | มุมซ้ายบนสีเหลือง = แก้แล้วยังไม่กด ✅
class _GridPainter extends CustomPainter {
  final TuneSession s;
  final XdfTable t;
  final List<List<double>> v;
  final double lo, hi, sx, sy, cw, ch, hw, hh;
  final List<String> rowL, colL;
  final (int, int, int, int)? sel;
  final double? lr, lc;
  final AppTheme th;
  final int rev;
  final bool pct; // แสดง Δ% เทียบไฟล์อ้างอิง
  _GridPainter({
    required this.s, required this.t, required this.v, required this.lo, required this.hi,
    required this.rowL, required this.colL, required this.sx, required this.sy,
    required this.cw, required this.ch, required this.hw, required this.hh,
    required this.sel, required this.lr, required this.lc, required this.th, required this.rev, this.pct = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final nr = t.rows, nc = t.cols;
    final c0 = math.max(0, (sx / cw).floor()), c1 = math.min(nc - 1, ((sx + w - hw) / cw).ceil());
    final r0 = math.max(0, (sy / ch).floor()), r1 = math.min(nr - 1, ((sy + h - hh) / ch).ceil());
    final fs = math.min(math.min(ch * 0.72, cw * 0.26), 15.0);
    final showTxt = fs >= 4.5;                                   // ย่อเล็กแค่ไหนก็ยังแสดงตัวเลข (ตัวเล็กลงตามช่อง)
    final mk = (math.min(cw, ch) * 0.3).clamp(3.0, 8.0).toDouble();
    final span = hi > lo ? hi - lo : 1.0;
    final fill = Paint();
    final mark = Paint()..color = Colors.white;
    final mark2 = Paint()..color = kAmber;
    final g = sel;
    final lrI = lr?.round(), lcI = lc?.round();
    double cx(int c) => hw + c * cw - sx;
    double cy(int r) => hh + r * ch - sy;

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(hw, hh, w - hw, h - hh));
    for (int r = r0; r <= r1; r++) {
      for (int c = c0; c <= c1; c++) {
        final rect = Rect.fromLTWH(cx(c), cy(r), cw, ch);
        final x = v[r][c];
        if (pct) {
          // Δ%: เทาเมื่อเท่าเดิม, แดง = เพิ่ม, ฟ้า = ลด (เข้มตามขนาด เต็มที่ 8%)
          final d = s.pctDiff(t, r, c);
          Color col;
          if (d == null) {
            col = const Color(0xFF121216);
          } else if (d.abs() < 0.05) {
            col = const Color(0xFF2A2A33);
          } else {
            final k = (d.abs() / 8).clamp(0.0, 1.0).toDouble();
            col = d > 0 ? Color.lerp(const Color(0xFF3C2828), const Color(0xFFFF463C), k)! : Color.lerp(const Color(0xFF28283C), const Color(0xFF3C8CFF), k)!;
          }
          fill.color = col;
          canvas.drawRect(rect.deflate(cw > 16 ? 0.5 : 0.2), fill);
          if (showTxt) {
            final txt = d == null ? '·' : (d.abs() < 0.05 ? '0' : '${d > 0 ? '+' : ''}${d.toStringAsFixed(1)}');
            _TP.center(canvas, _TP.get(txt, fs, d == null || d.abs() < 0.05 ? Colors.white38 : Colors.white, maxW: cw), rect.center);
          }
        } else {
        final col = _heat(hi > lo ? (x - lo) / span : 0.5);
        fill.color = col;
        canvas.drawRect(rect.deflate(cw > 16 ? 0.5 : 0.2), fill);
        if (showTxt) {
          _TP.center(canvas, _TP.get(t.fmt(x), fs, const Color(0xFF000000), maxW: cw), rect.center);   // ตัวเลขสีดำทุกช่อง
        }
        }
        if (s.cellChanged(t, r, c)) {
          canvas.drawPath(
              Path()
                ..moveTo(rect.right - mk, rect.top + 0.5)
                ..lineTo(rect.right - 0.5, rect.top + 0.5)
                ..lineTo(rect.right - 0.5, rect.top + mk)
                ..close(),
              mark);
        }
        if (s.cellDirty(t, r, c)) {
          canvas.drawPath(
              Path()
                ..moveTo(rect.left + 0.5, rect.top + 0.5)
                ..lineTo(rect.left + mk, rect.top + 0.5)
                ..lineTo(rect.left + 0.5, rect.top + mk)
                ..close(),
              mark2);
        }
      }
    }
    if (g != null) {
      final rr = Rect.fromLTRB(cx(g.$2), cy(g.$1), cx(g.$4) + cw, cy(g.$3) + ch);
      canvas.drawRect(rr, Paint()..color = th.c.withOpacity(0.22));
      canvas.drawRect(rr.deflate(1), Paint()
        ..color = th.c
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2);
    }
    if (lrI != null && lcI != null) {
      final rr = Rect.fromLTWH(cx(lcI), cy(lrI), cw, ch);
      canvas.drawRect(rr.inflate(1), Paint()
        ..color = th.c.withOpacity(0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      canvas.drawRect(rr, Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4);
      final dp = Offset(hw + (lc! + 0.5) * cw - sx, hh + (lr! + 0.5) * ch - sy);
      canvas.drawCircle(dp, 4, Paint()..color = Colors.black);
      canvas.drawCircle(dp, 2.6, Paint()..color = th.c);
    }
    canvas.restore();

    // หัวคอลัมน์ (ล็อกด้านบน) — ตารางย่อเล็กมากแสดงป้ายเว้นระยะ
    final hb = Paint()..color = const Color(0xFF15151C);
    final hs = Paint()..color = th.c.withOpacity(0.28);
    final hfc = math.min(10.5, math.max(6.0, cw * 0.3)), hfr = math.min(10.5, math.max(6.0, ch * 0.85));
    final everyC = cw >= 20 ? 1 : (20 / cw).ceil();
    final everyR = ch >= 7 ? 1 : (7 / ch).ceil();
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(hw, 0, w - hw, hh));
    canvas.drawRect(Rect.fromLTWH(hw, 0, w - hw, hh), hb);
    for (int c = c0; c <= c1; c++) {
      final rect = Rect.fromLTWH(cx(c), 0, cw, hh);
      final inSel = g != null && c >= g.$2 && c <= g.$4;
      if (inSel) canvas.drawRect(rect.deflate(0.5), hs);
      final isLive = lcI == c;
      if (c % everyC == 0 || isLive) {
        _TP.center(canvas, _TP.get(c < colL.length ? colL[c] : '', hfc, isLive ? th.c : (inSel ? Colors.white : Colors.white70), bold: isLive, maxW: cw * everyC), rect.center);
      }
    }
    canvas.restore();

    // หัวแถว (ล็อกด้านซ้าย)
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, hh, hw, h - hh));
    canvas.drawRect(Rect.fromLTWH(0, hh, hw, h - hh), hb);
    for (int r = r0; r <= r1; r++) {
      final rect = Rect.fromLTWH(0, cy(r), hw, ch);
      final inSel = g != null && r >= g.$1 && r <= g.$3;
      if (inSel) canvas.drawRect(rect.deflate(0.5), hs);
      final isLive = lrI == r;
      if (r % everyR == 0 || isLive) {
        final tp = _TP.get(r < rowL.length ? rowL[r] : '', hfr, isLive ? th.c : (inSel ? Colors.white : Colors.white70), bold: isLive, maxW: hw - 8);
        tp.paint(canvas, Offset(hw - 5 - tp.width, rect.center.dy - tp.height / 2));
      }
    }
    canvas.restore();

    canvas.drawRect(Rect.fromLTWH(0, 0, hw, hh), Paint()..color = const Color(0xFF1C1C25));
    _TP.center(canvas, _TP.get('$nr×$nc', 9.5, Colors.white38, maxW: hw - 4), Offset(hw / 2, hh / 2));
    final ln = Paint()
      ..color = th.c.withOpacity(0.7)
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(0, hh), Offset(w, hh), ln);
    canvas.drawLine(Offset(hw, 0), Offset(hw, h), ln);

    final sb = Paint()..color = th.c.withOpacity(0.55);
    final tw = nc * cw, vw = w - hw;
    if (tw > vw && vw > 0) {
      final bw = math.max(24.0, vw * vw / tw);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(hw + (vw - bw) * (sx / (tw - vw)), h - 3, bw, 3), const Radius.circular(2)), sb);
    }
    final tht = nr * ch, vh = h - hh;
    if (tht > vh && vh > 0) {
      final bh = math.max(20.0, vh * vh / tht);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w - 3, hh + (vh - bh) * (sy / (tht - vh)), 3, bh), const Radius.circular(2)), sb);
    }
  }

  @override
  bool shouldRepaint(_GridPainter o) => true;
}

// ---------- ภาพย่อ heatmap ในเมนูตาราง ----------
class _ThumbPainter extends CustomPainter {
  final List<List<double>> v;
  _ThumbPainter(this.v);

  @override
  void paint(Canvas canvas, Size size) {
    if (v.isEmpty || v[0].isEmpty) return;
    double lo = double.infinity, hi = double.negativeInfinity;
    for (final row in v) {
      for (final x in row) {
        if (x.isNaN) continue;
        lo = math.min(lo, x);
        hi = math.max(hi, x);
      }
    }
    final nr = v.length, nc = v[0].length;
    final cw = size.width / nc, ch = size.height / nr;
    final p = Paint();
    for (int r = 0; r < nr; r++) {
      for (int c = 0; c < nc; c++) {
        p.color = _heat(hi > lo ? (v[r][c] - lo) / (hi - lo) : 0.5);
        canvas.drawRect(Rect.fromLTWH(c * cw, r * ch, cw + 0.4, ch + 0.4), p);
      }
    }
  }

  @override
  bool shouldRepaint(_ThumbPainter o) => true;
}

// ---------- ป๊อปอัพเตือนเล็กกลางจอ: ค่อย ๆ โผล่แล้วจางหาย ----------
class _FadeToast extends StatelessWidget {
  final String msg;
  final Color col;
  const _FadeToast({required this.msg, required this.col});
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 1500),
        builder: (_, t, child) => Opacity(opacity: t < 0.1 ? t / 0.1 : (t > 0.65 ? ((1 - t) / 0.35).clamp(0.0, 1.0).toDouble() : 1.0), child: child),
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: hudDeco(border: col, radius: 14, color: const Color(0xEE202028)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.warning_amber_rounded, size: 14, color: col),
              const SizedBox(width: 6),
              Text(msg, style: const TextStyle(fontSize: 11.5, color: Colors.white)),
            ]),
          ),
        ),
      );
}

// ---------- การฉายภาพ 3D (ใช้ร่วมกันระหว่างวาด และหาจุดที่นิ้วแตะ) ----------
class _Proj3 {
  static const zh = 1.5; // ความสูงแกน Z เทียบความกว้างฐาน
  static const camD = 6.0; // ระยะกล้อง: มีระยะลึก ใกล้ใหญ่กว่า
  final int nr, nc;
  final double lo, span, sc, ox, oy, cyw, syw, cp, sp;
  _Proj3(Size size, this.nr, this.nc, this.lo, double hi, double yaw, double pitch, double zoom, [Offset pan = Offset.zero])
      : span = hi > lo ? hi - lo : 1.0,
        sc = math.min(size.width * 0.36, size.height * 0.72) * zoom,
        ox = size.width * 0.50 + pan.dx,
        oy = size.height * 0.56 + pan.dy,
        cyw = math.cos(yaw),
        syw = math.sin(yaw),
        cp = math.cos(pitch),
        sp = math.sin(pitch);

  (Offset, double) pt(double r, double c, double val) {
    final x = nc > 1 ? c / (nc - 1) * 2 - 1 : 0.0;
    final y = nr > 1 ? 1 - r / (nr - 1) * 2 : 0.0; // กลับด้านแกนแถว (RPM): ค่าต่ำอยู่ทางขวา ค่าสูงอยู่ทางซ้าย
    final z = ((val - lo) / span - 0.5) * zh;
    final xr = x * cyw - y * syw, yr = x * syw + y * cyw;
    final depth = yr * cp + z * sp;
    final k = camD / (camD - depth);
    return (Offset(ox + xr * sc * k, oy + (yr * sp - z * cp) * sc * k), depth);
  }
}

// ---------- มุมมอง 3D แกน XYZ (ลากหมุน, ลากจุดแก้ค่า, แตะ 2 ครั้งแล้วลาก = เลือกคลุม, 2 นิ้วซูม, PREVIEW หมุนรอบ) ----------
class _SurfacePainter extends CustomPainter {
  final List<List<double>> v;
  final double lo, hi, yaw, pitch, zoom;
  final double? lr, lc;
  final AppTheme th;
  final List<String> rowL, colL;
  final String xName, yName, zName;
  final XdfTable t;
  final bool spin; // PREVIEW กำลังหมุน: ซ่อนเส้นแกน Z และตัวเลขแกน x y z
  final (int, int, int, int)? sel; // ช่องที่เลือก (r0,c0,r1,c1)
  final Rect? box; // กรอบลากคลุม
  final Offset pan; // เลื่อนกราฟด้วย 2 นิ้ว
  _SurfacePainter({
    this.spin = false,
    this.pan = Offset.zero,
    this.sel,
    this.box,
    required this.v, required this.lo, required this.hi, required this.yaw, required this.pitch, required this.zoom,
    required this.lr, required this.lc, required this.th, required this.rowL, required this.colL,
    required this.xName, required this.yName, required this.zName, required this.t,
  });

  static const cZ = Color(0xFF5AA9FF), cX = Color(0xFFFF7A6B), cY = Color(0xFFE6E6EE);

  @override
  void paint(Canvas canvas, Size size) {
    final nr = v.length, nc = v[0].length;
    if (nr < 2 || nc < 2) return;
    final P = _Proj3(size, nr, nc, lo, hi, yaw, pitch, zoom, pan);
    final span = P.span;
    (Offset, double) pt(double r, double c, double val) => P.pt(r, c, val);

    // พื้นฐาน + เส้นตาราง
    final gl = Paint()
      ..color = Colors.white.withOpacity(0.10)
      ..strokeWidth = 0.8;
    final stc = math.max(1, (nc / 8).ceil()), str = math.max(1, (nr / 8).ceil());
    for (int c = 0; c < nc; c += stc) {
      canvas.drawLine(pt(0, c.toDouble(), lo).$1, pt(nr - 1.0, c.toDouble(), lo).$1, gl);
    }
    for (int r = 0; r < nr; r += str) {
      canvas.drawLine(pt(r.toDouble(), 0, lo).$1, pt(r.toDouble(), nc - 1.0, lo).$1, gl);
    }
    final b = [pt(0, 0, lo).$1, pt(0, nc - 1.0, lo).$1, pt(nr - 1.0, nc - 1.0, lo).$1, pt(nr - 1.0, 0, lo).$1];
    canvas.drawPath(
        Path()
          ..moveTo(b[0].dx, b[0].dy)
          ..lineTo(b[1].dx, b[1].dy)
          ..lineTo(b[2].dx, b[2].dy)
          ..lineTo(b[3].dx, b[3].dy)
          ..close(),
        Paint()
          ..color = Colors.white24
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);

    // แกน Z ที่มุมฐานซ้ายสุดบนจอ
    final corners = <(double, double)>[(0.0, 0.0), (0.0, nc - 1.0), (nr - 1.0, nc - 1.0), (nr - 1.0, 0.0)];
    var zc = corners[0];
    for (final k in corners) {
      if (pt(k.$1, k.$2, lo).$1.dx < pt(zc.$1, zc.$2, lo).$1.dx) zc = k;
    }
    final zb = pt(zc.$1, zc.$2, lo).$1, zt = pt(zc.$1, zc.$2, hi).$1;
    final zp = Paint()
      ..color = cZ.withOpacity(0.7)
      ..strokeWidth = 1.3;
    if (!spin) canvas.drawLine(zb, zt, zp);
    final zdec = math.min(t.dec, 2).clamp(0, 2).toInt();
    for (int k = 0; k <= 5 && !spin; k++) {
      final val = lo + span * k / 5;
      final p = pt(zc.$1, zc.$2, val).$1;
      canvas.drawLine(p, p + const Offset(-6, 0), zp);
      final tp = _TP.get(val.toStringAsFixed(zdec), 11, cZ);
      tp.paint(canvas, Offset(p.dx - 9 - tp.width, p.dy - tp.height / 2));
    }
    final ztp = _TP.get('Z • $zName', 11.5, cZ, bold: true, maxW: 220);
    ztp.paint(canvas, Offset(zt.dx - ztp.width / 2, zt.dy - ztp.height - 8));

    // ผิว: เรียงจากไกลไปใกล้
    final quads = <(double, Path, Color)>[];
    for (int r = 0; r < nr - 1; r++) {
      for (int c = 0; c < nc - 1; c++) {
        final q0 = pt(r.toDouble(), c.toDouble(), v[r][c]);
        final q1 = pt(r.toDouble(), c + 1.0, v[r][c + 1]);
        final q2 = pt(r + 1.0, c + 1.0, v[r + 1][c + 1]);
        final q3 = pt(r + 1.0, c.toDouble(), v[r + 1][c]);
        final avg = (v[r][c] + v[r][c + 1] + v[r + 1][c + 1] + v[r + 1][c]) / 4;
        quads.add((
          (q0.$2 + q1.$2 + q2.$2 + q3.$2) / 4,
          Path()
            ..moveTo(q0.$1.dx, q0.$1.dy)
            ..lineTo(q1.$1.dx, q1.$1.dy)
            ..lineTo(q2.$1.dx, q2.$1.dy)
            ..lineTo(q3.$1.dx, q3.$1.dy)
            ..close(),
          _heat((avg - lo) / span),
        ));
      }
    }
    quads.sort((a, b) => a.$1.compareTo(b.$1));
    final fill = Paint();
    final edge = Paint()
      ..color = const Color(0x8C000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;
    for (final q in quads) {
      fill.color = q.$3;
      canvas.drawPath(q.$2, fill);
      canvas.drawPath(q.$2, edge);
    }

    // จุดที่เลือก
    final g = sel;
    if (g != null && !spin) {
      final dotF = Paint()..color = Colors.white;
      final dotS = Paint()
        ..color = th.c
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6;
      final rad = (g.$3 - g.$1 + 1) * (g.$4 - g.$2 + 1) > 120 ? 2.4 : 3.6;
      for (int r = g.$1; r <= g.$3 && r < nr; r++) {
        for (int c = g.$2; c <= g.$4 && c < nc; c++) {
          if (v[r][c].isNaN) continue;
          final p = pt(r.toDouble(), c.toDouble(), v[r][c]).$1;
          canvas.drawCircle(p, rad, dotF);
          canvas.drawCircle(p, rad, dotS);
        }
      }
    }
    final bx = box;
    if (bx != null) {
      canvas.drawRect(bx, Paint()..color = th.c.withOpacity(0.15));
      canvas.drawRect(bx, Paint()
        ..color = th.c
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2);
    }

    // แกน X (คอลัมน์) ตามขอบหน้า และแกน Y (แถว) ตามขอบข้างที่ใกล้ผู้ชม
    final rF = pt(0, (nc - 1) / 2, lo).$2 > pt(nr - 1.0, (nc - 1) / 2, lo).$2 ? 0.0 : nr - 1.0;
    final cF = pt((nr - 1) / 2, 0, lo).$2 > pt((nr - 1) / 2, nc - 1.0, lo).$2 ? 0.0 : nc - 1.0;
    final orr = math.max(0.9, (nr - 1) * 0.07), occ = math.max(0.9, (nc - 1) * 0.07);
    final rL = rF == 0 ? -orr : rF + orr, rT = rF == 0 ? -orr * 2.6 : rF + orr * 2.6;
    final cL = cF == 0 ? -occ : cF + occ, cT = cF == 0 ? -occ * 2.8 : cF + occ * 2.8;
    for (int c = 0; c < nc && !spin; c += stc) {
      _TP.center(canvas, _TP.get(c < colL.length ? colL[c] : '', 11, cX), pt(rL, c.toDouble(), lo).$1);
    }
    _TP.center(canvas, _TP.get(xName, 12, cX, bold: true, maxW: 200), pt(rT, (nc - 1) / 2, lo).$1);
    for (int r = 0; r < nr && !spin; r += str) {
      _TP.center(canvas, _TP.get(r < rowL.length ? rowL[r] : '', 11, cY), pt(r.toDouble(), cL, lo).$1);
    }
    _TP.center(canvas, _TP.get(yName, 12, cY, bold: true, maxW: 200), pt((nr - 1) / 2, cT, lo).$1);

    // LIVE
    final a = lr, bb = lc;
    if (a != null && bb != null) {
      final val = _bilin(v, a, bb);
      final p0 = pt(a, bb, lo).$1, p1 = pt(a, bb, val).$1;
      canvas.drawLine(p0, p1, Paint()
        ..color = Colors.white70
        ..strokeWidth = 1.4);
      canvas.drawCircle(p1, 9, Paint()
        ..color = th.c.withOpacity(0.6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      canvas.drawCircle(p1, 5, Paint()..color = th.c);
      canvas.drawCircle(p1, 5, Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
      final tp = _TP.get('LIVE ${t.fmt(val)}', 11, Colors.white, bold: true);
      final rr = Rect.fromLTWH(p1.dx + 10, p1.dy - 22, tp.width + 10, tp.height + 4);
      canvas.drawRRect(RRect.fromRectAndRadius(rr, const Radius.circular(4)), Paint()..color = th.c.withOpacity(0.85));
      tp.paint(canvas, rr.topLeft + const Offset(5, 2));
    }

    // แถบสี lo .. hi (มุมขวาล่าง)
    final lgBox = Rect.fromLTWH(size.width - 214, size.height - 58, 204, 48);
    canvas.drawRRect(RRect.fromRectAndRadius(lgBox, const Radius.circular(10)), Paint()..color = const Color(0xCC1A1A22));
    final lg = Rect.fromLTWH(lgBox.left + 12, lgBox.top + 10, lgBox.width - 24, 8);
    canvas.drawRRect(
        RRect.fromRectAndRadius(lg, const Radius.circular(4)),
        Paint()..shader = LinearGradient(colors: [for (int k = 0; k <= 5; k++) _heat(k / 5)]).createShader(lg));
    final mid = (lo + hi) / 2;
    final tl = _TP.get(t.fmt(lo), 10.5, Colors.white70), tm = _TP.get(t.fmt(mid), 10.5, Colors.white70), tr = _TP.get(t.fmt(hi), 10.5, Colors.white70);
    tl.paint(canvas, Offset(lg.left, lg.bottom + 5));
    tm.paint(canvas, Offset(lg.center.dx - tm.width / 2, lg.bottom + 5));
    tr.paint(canvas, Offset(lg.right - tr.width, lg.bottom + 5));
    if (!spin) {
      final hint = _TP.get('ลากที่ว่าง = หมุน · ลากจุดขึ้น/ลง = แก้ค่า · แตะ 2 ครั้งแล้วลาก = เลือกคลุม · 2 นิ้ว = ซูม · FIT = รีเซ็ต', 9.5, Colors.white30);
      hint.paint(canvas, Offset(size.width - hint.width - 10, 8));
    }
  }

  @override
  bool shouldRepaint(_SurfacePainter o) => true;
}

// ---------- กราฟแท่ง (ตาราง/แกน 1 มิติ) ----------
class _BarsPainter extends CustomPainter {
  final List<double> v;
  final List<String> labels;
  final double lo, hi;
  final double? lf;
  final AppTheme th;
  final XdfTable t;
  _BarsPainter({required this.v, required this.labels, required this.lo, required this.hi, required this.lf, required this.th, required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final n = v.length;
    if (n == 0) return;
    const pl = 10.0, pr = 10.0, pt = 22.0, pb = 24.0;
    final w = size.width - pl - pr, h = size.height - pt - pb;
    final bw = w / n;
    final lo0 = math.min(0.0, lo);
    final span = hi > lo0 ? hi - lo0 : 1.0;
    final y0 = pt + h - ((0 - lo0) / span) * h;
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    for (int k = 0; k <= 4; k++) {
      canvas.drawLine(Offset(pl, pt + h * k / 4), Offset(pl + w, pt + h * k / 4), grid);
    }
    final every = math.max(1, (34 / bw).ceil());
    for (int i = 0; i < n; i++) {
      final x = v[i];
      final y = pt + h - ((x - lo0) / span) * h;
      final r = Rect.fromLTRB(pl + i * bw + bw * 0.12, math.min(y, y0), pl + (i + 1) * bw - bw * 0.12, math.max(y, y0) + 0.5);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(2)), Paint()..color = _heat(hi > lo ? (x - lo) / (hi - lo) : 0.5));
      if (i % every == 0) {
        _TP.center(canvas, _TP.get(t.fmt(x), 9.5, Colors.white, maxW: bw * every), Offset(r.center.dx, math.min(y, y0) - 8));
        _TP.center(canvas, _TP.get(i < labels.length ? labels[i] : '', 9.5, Colors.white54, maxW: bw * every), Offset(r.center.dx, size.height - pb / 2));
      }
    }
    final f = lf;
    if (f != null) {
      final x = pl + (f + 0.5) * bw;
      canvas.drawLine(Offset(x, pt - 6), Offset(x, pt + h), Paint()
        ..color = th.c
        ..strokeWidth = 2);
      final tp = _TP.get('LIVE', 10, th.c, bold: true);
      tp.paint(canvas, Offset(x + 4, pt - 18));
    }
  }

  @override
  bool shouldRepaint(_BarsPainter o) => true;
}

// =====================================================================
// ===================== คลังไฟล์ BIN + หน้า FLASH ECU ====================
// =====================================================================
// คลังไฟล์: เก็บในพื้นที่ของแอพ (Documents/bin_lib/<ชื่อ>.bin + index.json) ตั้งชื่อเองได้
// หน้า FLASH: เลือกไฟล์จากคลัง -> ส่งไฟล์ไปเกจ -> กดปุ่ม FLASH ที่เกจ (FW 1.0.10: แอพสั่งเริ่มแฟลชไม่ได้แล้ว)
// FW 1.0.13: เกจสรุปชนิดกล่องจากไฟล์ (Keihin / Shindengen) ; Keihin ใช้ offset ที่แอพส่งตาม ID กล่อง ไม่มีค่อยเลือกตามขนาดไฟล์
// (kFlashProfiles) ; เกจคำนวณ checksum ใหม่ก่อนแฟลชเสมอ (ดู binPlan = ตรรกะเดียวกับ fPlanBuild ใน EcuFlash.h)
// เกจต้องเปิดหน้าเตรียมแฟลชอยู่ (SETUP > CONNECT APP > ECU FLASH) ถึงจะรับไฟล์ได้

class BinEntry {
  String name;
  int size, sum16, ck8;
  DateTime time;
  String offset, cks; // ค่าที่ใช้แฟลชครั้งล่าสุด (จำไว้ให้ ไม่ได้ใส่อัตโนมัติจากที่อื่น)
  bool fix;
  String xdf; // ชื่อ XDF ที่บันทึกไว้คู่กัน (ว่าง = ไม่มี)
  BinEntry(this.name, this.size, this.sum16, this.ck8, this.time, {this.offset = '', this.cks = '', this.fix = false, this.xdf = ''});

  static BinEntry make(String name, Uint8List b, {BinEntry? keep}) {
    int s = 0;
    for (final x in b) {
      s += x;
    }
    return BinEntry(name, b.length, s & 0xFFFF, s & 0xFF, DateTime.now(),
        offset: keep?.offset ?? '', cks: keep?.cks ?? '', fix: keep?.fix ?? false, xdf: keep?.xdf ?? '');
  }

  Map<String, dynamic> toJson() =>
      {'n': name, 's': size, 'sum': sum16, 'ck': ck8, 't': time.millisecondsSinceEpoch, 'o': offset, 'c': cks, 'f': fix, 'x': xdf};

  static BinEntry? fromJson(dynamic j) {
    try {
      return BinEntry(j['n'] as String, (j['s'] as num).toInt(), (j['sum'] as num).toInt(), (j['ck'] as num).toInt(),
          DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()),
          offset: (j['o'] as String?) ?? '', cks: (j['c'] as String?) ?? '', fix: (j['f'] as bool?) ?? false, xdf: (j['x'] as String?) ?? '');
    } catch (_) {
      return null;
    }
  }
}

class BinLib extends ChangeNotifier {
  static final BinLib i = BinLib._();
  BinLib._();

  io.Directory? _dir;
  final List<BinEntry> items = [];
  bool loaded = false;

  Future<io.Directory> _d() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationDocumentsDirectory();
    final d = io.Directory('${base.path}/bin_lib');
    if (!await d.exists()) await d.create(recursive: true);
    return _dir = d;
  }

  io.File _f(io.Directory d, String name) => io.File('${d.path}/$name.bin');
  io.File _fx(io.Directory d, String name) => io.File('${d.path}/$name.xdf'); // XDF ที่บันทึกคู่กับ BIN

  static String clean(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();

  Future<void> load({bool force = false}) async {
    if (loaded && !force) return;
    try {
      final d = await _d();
      final m = <String, BinEntry>{};
      final idx = io.File('${d.path}/index.json');
      if (await idx.exists()) {
        for (final j in jsonDecode(await idx.readAsString()) as List) {
          final e = BinEntry.fromJson(j);
          if (e != null) m[e.name] = e;
        }
      }
      await for (final f in d.list()) {
        if (f is io.File && f.path.toLowerCase().endsWith('.bin')) {
          final n = f.uri.pathSegments.last;
          final name = n.substring(0, n.length - 4);
          if (!m.containsKey(name)) m[name] = BinEntry.make(name, await f.readAsBytes());
        }
      }
      items
        ..clear()
        ..addAll(m.values.where((e) => _f(d, e.name).existsSync()));
      items.sort((a, b) => b.time.compareTo(a.time));
      loaded = true;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveIdx() async {
    final d = await _d();
    await io.File('${d.path}/index.json').writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  bool exists(String name) => items.any((e) => e.name == name);

  Future<BinEntry> save(String name, Uint8List bytes, {String? xdfName, Uint8List? xdfRaw}) async {
    await load();
    name = clean(name);
    final d = await _d();
    await _f(d, name).writeAsBytes(bytes, flush: true);
    if (xdfRaw != null) await _fx(d, name).writeAsBytes(xdfRaw, flush: true);
    BinEntry? old;
    for (final e in items) {
      if (e.name == name) old = e;
    }
    items.removeWhere((e) => e.name == name);
    final e = BinEntry.make(name, bytes, keep: old);
    if (xdfRaw != null) e.xdf = xdfName ?? '$name.xdf';
    items.insert(0, e);
    await _saveIdx();
    notifyListeners();
    return e;
  }

  Future<Uint8List> read(BinEntry e) async => _f(await _d(), e.name).readAsBytes();

  /// XDF ที่บันทึกคู่กับไฟล์นี้ (null = ไม่มี เช่นไฟล์ที่บันทึกก่อนเวอร์ชันนี้)
  Future<Uint8List?> readXdf(BinEntry e) async {
    if (e.xdf.isEmpty) return null;
    final f = _fx(await _d(), e.name);
    return await f.exists() ? f.readAsBytes() : null;
  }

  Future<void> remove(BinEntry e) async {
    final d = await _d();
    try {
      await _f(d, e.name).delete();
    } catch (_) {}
    try {
      final x = _fx(d, e.name);
      if (await x.exists()) await x.delete();
    } catch (_) {}
    items.remove(e);
    await _saveIdx();
    notifyListeners();
  }

  Future<String?> rename(BinEntry e, String to) async {
    to = clean(to);
    if (to.isEmpty) return 'ชื่อว่าง';
    if (to == e.name) return null;
    if (exists(to)) return 'มีชื่อ "$to" อยู่แล้ว';
    final d = await _d();
    await _f(d, e.name).rename(_f(d, to).path);
    try {
      final x = _fx(d, e.name);
      if (await x.exists()) await x.rename(_fx(d, to).path);
    } catch (_) {}
    e.name = to;
    await _saveIdx();
    notifyListeners();
    return null;
  }

  Future<void> update(BinEntry e) async {
    await _saveIdx();
    notifyListeners();
  }
}

// ---------- ข้อความสถานะแฟลช (ตรงกับ EcuFlash.h ในเกจ) ----------
const kFlPhase = [
  'ไม่ได้อยู่หน้าเตรียมแฟลช', 'รอรับไฟล์', 'กำลังรับไฟล์', 'พร้อมแฟลช', 'กำลังเข้าโหมดเขียน', 'รอเตรียมลบ (11 วินาที)',
  'กำลังลบข้อมูลเดิม', 'กำลังเขียนข้อมูล', 'กำลังตรวจสอบ', 'แฟลชสำเร็จ', 'แฟลชไม่สำเร็จ',
];
String flashPhaseText(int p) => p >= 0 && p < kFlPhase.length ? kFlPhase[p] : 'phase $p';
String flashEcuText(int s) => switch (s) {
      0 => 'OFF (สาย K-Line ไม่มีไฟ / ยังไม่บิดกุญแจ)',
      1 => 'ไม่ตอบ',
      2 => 'OK',
      3 => 'FLASH (โหมดเขียน)',
      4 => 'SECURE',
      5 => 'RECOVER',
      6 => 'RECOVER (แบบใหม่)',
      _ => 'กำลังตรวจ…',
    };
String flashErrText(int e) =>
    const {
      1: 'เกจยังไม่อยู่หน้าเตรียมแฟลช',
      2: 'ไม่มีไฟล์ในเกจ หรือไฟล์ไม่ตรงกับในแอพ',
      3: 'checksum ของไฟล์ไม่ผ่าน',
      4: 'กล่องยังไม่พร้อม (บิดกุญแจ ON ไม่ติดเครื่อง?)',
      5: 'ลบข้อมูลในกล่องไม่สำเร็จ',
      6: 'ลบข้อมูลผิดพลาด (erase block error)',
      7: 'เขียนไม่สำเร็จ (กล่องไม่ตอบบล็อกแรก)',
      8: 'เขียนไม่สำเร็จ (กล่องไม่ตอบ ส่งซ้ำครบแล้ว)',
      9: 'กล่องไม่รับบล็อกข้อมูล',
      10: 'ตรวจสอบหลังเขียนไม่ผ่าน',
      11: 'เกจอ่านไฟล์ไม่ได้',
      12: 'พื้นที่ในเกจไม่พอ',
      13: 'เกจกำลังทำงานอยู่',
      14: 'Start Offset / ขนาดไฟล์ไม่ถูกต้อง',
      15: 'รับไฟล์ไม่สำเร็จ',
      16: 'สาย K-Line หลุด',
      17: 'ขนาดไฟล์นี้ยังแฟลชไม่ได้ (ไม่อยู่ในตารางของเกจ)',
      18: 'แก้ checksum ในเกจไม่สำเร็จ',
      19: 'ID กล่องไม่ตรงกับตอนส่งไฟล์ — ส่งไฟล์ใหม่อีกครั้ง',
      20: 'ขอ seed จากกล่อง Shindengen ไม่สำเร็จ',
      21: 'seed/key ไม่ผ่าน (ไม่พบ key ในไฟล์ หรือกล่องไม่รับ)',
    }[e] ??
    'error $e';

/// ค่าแฟลชตามขนาดไฟล์ Keihin (ต้องตรงกับ F_PROFS ใน EcuFlash.h ของเกจ = GetOffsetsFromBinType ของโปรแกรม PC)
/// ขนาด -> (start offset, ตำแหน่ง checksum ในไฟล์)
const Map<int, (int, int)> kFlashProfiles = {
  0x0C000: (0x4000, 0x7600), // 48 KB
  0x0E000: (0x0000, 0xDFEF), // 56 KB
  0x10000: (0x8000, 0x0000), // 64 KB
  0x18000: (0x8000, 0x0000), // 96 KB
  0x20000: (0xE0000, 0xB000), // 128 KB
};
const int kFlashMaxSize = 512 * 1024; // FL_MAX_SIZE ของเกจ

/// แผนแฟลชที่เกจจะสรุปจากไฟล์ (เลียนแบบ fPlanBuild ใน EcuFlash.h เพื่อแสดงผลและกันส่งไฟล์ที่เกจจะปฏิเสธ)
class BinPlan {
  final String type; // KH / KH-H8C / KH-M32R / SH-V850 / SH-RH850 / SH-RH850B
  final bool sh; // Shindengen: start offset + checksum อัตโนมัติ
  final int off, ck; // ck ใช้เฉพาะ Keihin
  final bool fromId; // offset มาจากฐานข้อมูลตาม ID กล่อง (แอพส่งไปให้เกจ)
  final String? why; // null = แฟลชได้ ; ข้อความ = เหตุผลที่แฟลชไม่ได้
  const BinPlan(this.type, this.sh, this.off, this.ck, this.fromId, this.why);
  bool get ok => why == null;
}

bool _binTail(Uint8List d, List<int> sig) {
  final n = d.length;
  if (n < sig.length) return false;
  for (int i = 0; i < sig.length; i++) {
    if (d[n - sig.length + i] != sig[i]) return false;
  }
  return true;
}

int _binFind(Uint8List d, List<int> sig) {
  final lim = d.length - 7; // เกจ/โปรแกรม PC ค้นถึง size-7
  final a = sig[0];
  for (int i = 0; i < lim; i++) {
    if (d[i] != a) continue;
    bool m = true;
    for (int k = 1; k < sig.length; k++) {
      if (d[i + k] != sig[k]) {
        m = false;
        break;
      }
    }
    if (m) return i;
  }
  return -1;
}

BinPlan binPlan(Uint8List d, (int, int)? idProf) {
  final n = d.length;
  if (n < 128) return const BinPlan('?', false, 0, 0, false, 'ไฟล์เล็กเกินไป');
  if (n > kFlashMaxSize) {
    return BinPlan('?', false, 0, 0, false, 'ไฟล์ ${(n / 1024).round()} KB ใหญ่เกินที่เกจเก็บได้ (สูงสุด 512 KB)');
  }
  // ----- Shindengen: ท้ายไฟล์ 5A 5A 5A 5A + "SV850" / "SH850" -----
  if (_binTail(d, const [0x5A, 0x5A, 0x5A, 0x5A])) {
    final pV = _binFind(d, const [0x53, 0x56, 0x38, 0x35, 0x30]);
    final pR = _binFind(d, const [0x53, 0x48, 0x38, 0x35, 0x30]);
    final pW = _binFind(d, const [0x11, 0x12, 0x13, 0x14, 0x15, 0x15, 0x17]);
    String? t;
    if (pV >= 0 && (pR < 0 || pV < pR)) {
      t = 'SH-V850';
    } else if (pR >= 0) {
      final b = n > 0xA004 && d[0xA000] == 0xA5 && d[0xA001] == 0xA5 && d[0xA002] == 0xA5 && d[0xA003] == 0xA5 && d[0xA004] == 0x00;
      t = b ? 'SH-RH850B' : 'SH-RH850';
    } else if (pW >= 0) {
      t = 'SH-V850';
    }
    if (t != null) {
      final off = t == 'SH-RH850B' ? 0xA000 : 0x10000;
      final bad = (n % 128) != 0 || off >= n || (n >> 4) > 0x10000;
      return BinPlan(t, true, off, 0, false, bad ? 'ขนาดไฟล์ Shindengen ไม่ถูกต้อง' : null);
    }
  }
  // ----- Keihin -----
  String t = 'KH';
  if ((n == 57344 || n == 32768) && _binTail(d, const [0xFF, 0xFF, 0xAA, 0xAA])) {
    t = 'KH-H8C';
  } else if (n == 262144 && _binTail(d, const [0xFF, 0xFF, 0xFF, 0xAA, 0xAA, 0xAA, 0xAA])) {
    t = 'KH-M32R';
  }
  (int, int)? pr = idProf;
  final fromId = pr != null;
  pr ??= kFlashProfiles[n];
  if (pr == null && n == 262144 &&
      (_binTail(d, const [0xFF, 0xFF, 0xFF, 0, 0, 0, 0]) ||
          _binTail(d, const [0xFF, 0xFF, 0xFF, 0xAA, 0xAA, 0xAA, 0xAA]) ||
          _binTail(d, const [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))) {
    pr = (0, 0x3FFF8);
  }
  if (pr == null && n == 524288 && _binTail(d, const [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])) pr = (0, 0x7FFF8);
  if (pr == null) {
    return BinPlan(t, false, 0, 0, false, 'ขนาด ${(n / 1024).toStringAsFixed(1)} KB ไม่อยู่ในตารางของเกจ และไม่พบ ID กล่องในฐานข้อมูล');
  }
  final bs = t == 'KH-H8C' ? 64 : 128;
  String? why;
  if (pr.$2 >= n) {
    why = 'ตำแหน่ง checksum ${_hx(pr.$2, 4)} อยู่นอกไฟล์ ${(n / 1024).round()} KB — ไฟล์นี้ไม่ใช่ขนาดของกล่องรุ่นนี้';
  } else if ((pr.$1 & 15) != 0 || (n % bs) != 0 || ((pr.$1 >> 4) + (n >> 4)) > 0x10000) {
    why = 'Start Offset / ขนาดไฟล์ไม่ถูกต้อง';
  }
  return BinPlan(t, false, pr.$1, pr.$2, fromId, why);
}

String _mmss(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
String _hx(int v, [int w = 2]) => '0x${v.toRadixString(16).toUpperCase().padLeft(w, '0')}';

Future<String?> askText(BuildContext context, String title, String initial, {String hint = '', String ok = 'ตกลง'}) async {
  final tc = TextEditingController(text: initial);
  final th = Cfg.i.t;
  final r = await showDialog<String>(
    context: context,
    builder: (dctx) => AlertDialog(
      backgroundColor: const Color(0xFF14141A),
      title: Text(title, style: TextStyle(fontSize: 15, color: th.c)),
      content: TextField(
        controller: tc,
        autofocus: true,
        decoration: InputDecoration(hintText: hint, hintStyle: const TextStyle(fontSize: 12, color: Colors.white38)),
        onSubmitted: (x) => Navigator.of(dctx).pop(x),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('ยกเลิก')),
        TextButton(onPressed: () => Navigator.of(dctx).pop(tc.text), child: Text(ok, style: TextStyle(color: th.c))),
      ],
    ),
  );
  tc.dispose();
  return r;
}

Future<bool> askYes(BuildContext context, String title, String msg, {String ok = 'ตกลง', Color col = kAmber}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      backgroundColor: const Color(0xFF14141A),
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: Text(msg),
      actions: [
        TextButton(onPressed: () => Navigator.of(dctx).pop(false), child: const Text('ยกเลิก')),
        TextButton(onPressed: () => Navigator.of(dctx).pop(true), child: Text(ok, style: TextStyle(color: col))),
      ],
    ),
  );
  return r == true;
}

/// บันทึกเข้าคลังโดยถามชื่อ (ถ้าชื่อซ้ำถามก่อนเขียนทับ) ; คืน entry ที่บันทึก
Future<BinEntry?> saveToLibrary(BuildContext context, Uint8List bytes, String defName) async {
  await BinLib.i.load();
  if (!context.mounted) return null;
  final n0 = await askText(context, 'บันทึกเข้าคลังไฟล์', defName, hint: 'ตั้งชื่อไฟล์', ok: 'บันทึก');
  if (n0 == null) return null;
  final n = BinLib.clean(n0);
  if (n.isEmpty) return null;
  if (BinLib.i.exists(n) && context.mounted && !await askYes(context, 'ชื่อซ้ำ', 'มีไฟล์ชื่อ "$n" ในคลังแล้ว เขียนทับหรือไม่?', ok: 'เขียนทับ')) {
    return null;
  }
  return BinLib.i.save(n, bytes);
}

/// เลือกไฟล์จากคลัง
Future<BinEntry?> pickFromLibrary(BuildContext context) async {
  await BinLib.i.load();
  if (!context.mounted) return null;
  final th = Cfg.i.t;
  return showDialog<BinEntry>(
    context: context,
    builder: (dctx) => AlertDialog(
      backgroundColor: const Color(0xFF14141A),
      title: Text('เลือกไฟล์จากคลัง', style: TextStyle(fontSize: 15, color: th.c)),
      content: SizedBox(
        width: 480,
        height: 260,
        child: BinLib.i.items.isEmpty
            ? const Center(child: Text('คลังยังว่าง', style: TextStyle(color: Colors.white54)))
            : ListView(children: [
                for (final e in BinLib.i.items)
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.memory, color: th.c),
                    title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text.rich(TextSpan(style: const TextStyle(fontSize: 11), children: [
                      TextSpan(text: '${(e.size / 1024).toStringAsFixed(1)} KB · ${_dateStr(e.time)} · '),
                      TextSpan(
                          text: e.xdf.isNotEmpty ? 'XDF: ${e.xdf}' : 'ไม่มี XDF',
                          style: TextStyle(color: e.xdf.isNotEmpty ? kGreen : kAmber)),
                    ])),
                    onTap: () => Navigator.of(dctx).pop(e),
                  ),
              ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('ปิด'))],
    ),
  );
}

String _dateStr(DateTime t) {
  String p2(int v) => v.toString().padLeft(2, '0');
  return '${p2(t.day)}/${p2(t.month)}/${t.year} ${p2(t.hour)}:${p2(t.minute)}';
}

// ---------- หน้า FLASH ECU (แยกจากหน้าเขียนตาราง TUNE) ----------
// ---------- สมุดลูกค้า: รายชื่อ + รถ + ID กล่อง + ประวัติงาน (เก็บในเครื่อง customers.json) ----------
class CustJob {
  DateTime time;
  String kind; // FLASH / TUNE / NOTE
  String file; // ชื่อไฟล์ในคลัง (ไม่มี .bin) หรือชื่อไฟล์จากมือถือ
  String note;
  CustJob(this.time, this.kind, {this.file = '', this.note = ''});
  Map<String, dynamic> toJson() => {'t': time.millisecondsSinceEpoch, 'k': kind, 'f': file, 'n': note};
  static CustJob fromJson(Map j) =>
      CustJob(DateTime.fromMillisecondsSinceEpoch((j['t'] as num?)?.toInt() ?? 0), '${j['k'] ?? 'NOTE'}', file: '${j['f'] ?? ''}', note: '${j['n'] ?? ''}');
}

class Customer {
  String id, name, phone, plate, model, ecu, note;
  final List<CustJob> jobs;
  Customer(this.id, {this.name = '', this.phone = '', this.plate = '', this.model = '', this.ecu = '', this.note = '', List<CustJob>? jobs}) : jobs = jobs ?? [];
  DateTime get last => jobs.isEmpty ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(id) ?? 0) : jobs.map((j) => j.time).reduce((a, b) => a.isAfter(b) ? a : b);
  CustJob? lastOf(String kind) {
    CustJob? r;
    for (final j in jobs) {
      if ((kind.isEmpty ? j.kind != 'NOTE' : j.kind == kind) && j.file.isNotEmpty && (r == null || j.time.isAfter(r.time))) r = j;
    }
    return r;
  }

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'phone': phone, 'plate': plate, 'model': model, 'ecu': ecu, 'note': note, 'jobs': jobs.map((j) => j.toJson()).toList()};
  static Customer fromJson(Map j) => Customer('${j['id']}',
      name: '${j['name'] ?? ''}', phone: '${j['phone'] ?? ''}', plate: '${j['plate'] ?? ''}', model: '${j['model'] ?? ''}',
      ecu: '${j['ecu'] ?? ''}', note: '${j['note'] ?? ''}', jobs: [for (final x in (j['jobs'] as List? ?? const [])) CustJob.fromJson(x as Map)]);
}

String ecuHex(List<int>? e) => e == null ? '' : e.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

class CustBook extends ChangeNotifier {
  static final CustBook i = CustBook._();
  CustBook._();
  final List<Customer> items = [];
  bool loaded = false;

  Future<io.File> _f() async => io.File('${(await getApplicationDocumentsDirectory()).path}/customers.json');

  Future<void> load() async {
    if (loaded) return;
    try {
      final f = await _f();
      if (await f.exists()) {
        items
          ..clear()
          ..addAll([for (final j in jsonDecode(await f.readAsString()) as List) Customer.fromJson(j as Map)]);
      }
    } catch (_) {}
    loaded = true;
    _sort();
    notifyListeners();
  }

  void _sort() => items.sort((a, b) => b.last.compareTo(a.last));

  Future<void> save() async {
    _sort();
    notifyListeners();
    try {
      await (await _f()).writeAsString(jsonEncode(items.map((c) => c.toJson()).toList()), flush: true);
    } catch (_) {}
  }

  Customer? byEcu(String hex) {
    if (hex.isEmpty) return null;
    for (final c in items) {
      if (c.ecu == hex) return c;
    }
    return null;
  }

  Future<void> addJob(Customer c, CustJob j) async {
    if (!items.contains(c)) items.add(c);
    c.jobs.add(j);
    await save();
  }

  Future<void> remove(Customer c) async {
    items.remove(c);
    await save();
  }
}

/// แก้ข้อมูลลูกค้า (คืน true = บันทึก)
Future<bool> editCustomer(BuildContext context, Customer cu, {String? liveEcu}) async {
  final th = Cfg.i.t;
  final ctl = {
    'name': TextEditingController(text: cu.name),
    'plate': TextEditingController(text: cu.plate),
    'model': TextEditingController(text: cu.model),
    'phone': TextEditingController(text: cu.phone),
    'ecu': TextEditingController(text: cu.ecu),
    'note': TextEditingController(text: cu.note),
  };
  Widget f(String k, String label, {TextInputType? kb, Widget? suffix}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: TextField(
          controller: ctl[k],
          keyboardType: kb,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(isDense: true, labelText: label, suffixIcon: suffix, border: const OutlineInputBorder()),
        ),
      );
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => Dialog(
      backgroundColor: const Color(0xFF0C0D10),
      shape: HudBorder(cut: 14, side: BorderSide(color: th.c, width: 1.3)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 90, vertical: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(cu.name.isEmpty ? 'เพิ่มลูกค้า' : 'แก้ข้อมูลลูกค้า', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(children: [Expanded(child: f('name', 'ชื่อลูกค้า')), const SizedBox(width: 8), Expanded(child: f('phone', 'เบอร์โทร', kb: TextInputType.phone))]),
            Row(children: [Expanded(child: f('plate', 'ทะเบียน')), const SizedBox(width: 8), Expanded(child: f('model', 'รุ่นรถ'))]),
            f('ecu', 'ID กล่อง',
                suffix: liveEcu == null || liveEcu.isEmpty
                    ? null
                    : TextButton(onPressed: () => ctl['ecu']!.text = liveEcu, child: const Text('ใช้กล่องที่ต่ออยู่', style: TextStyle(fontSize: 11)))),
            f('note', 'โน้ต (ของแต่ง ฯลฯ)'),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('ยกเลิก')),
              TextButton(onPressed: () => Navigator.of(d).pop(true), child: const Text('บันทึก')),
            ]),
          ]),
        ),
      ),
    ),
  );
  if (ok == true) {
    cu
      ..name = ctl['name']!.text.trim()
      ..plate = ctl['plate']!.text.trim()
      ..model = ctl['model']!.text.trim()
      ..phone = ctl['phone']!.text.trim()
      ..ecu = ctl['ecu']!.text.trim().toUpperCase()
      ..note = ctl['note']!.text.trim();
    if (cu.name.isEmpty) cu.name = cu.plate.isEmpty ? 'ลูกค้า' : cu.plate;
  }
  for (final x in ctl.values) {
    x.dispose();
  }
  return ok == true;
}

/// หลังแฟลชสำเร็จ: ถามว่าจะบันทึกเข้าลูกค้าคนไหน (ID กล่องตรง = เลือกให้อัตโนมัติ)
Future<void> askSaveFlashJob(BuildContext context, {required String file, required String ecu, String note = ''}) async {
  final bk = CustBook.i;
  await bk.load();
  if (!context.mounted) return;
  final th = Cfg.i.t;
  Customer? sel = bk.byEcu(ecu);
  final res = await showDialog<Object>(
    context: context,
    builder: (d) => StatefulBuilder(
      builder: (d, ss) => Dialog(
        backgroundColor: const Color(0xFF0C0D10),
        shape: HudBorder(cut: 14, side: BorderSide(color: kGreen, width: 1.3)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 110, vertical: 16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('แฟลชสำเร็จ — บันทึกเข้าสมุดลูกค้า?', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: kGreen)),
            Text('$file${ecu.isEmpty ? '' : '  ·  ID $ecu'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white54)),
            const SizedBox(height: 6),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final cu in bk.items)
                  InkWell(
                    onTap: () => ss(() => sel = cu),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                      decoration: hudDeco(border: identical(sel, cu) ? th.c : Colors.white24, width: identical(sel, cu) ? 1.5 : 1, radius: 8,
                          color: identical(sel, cu) ? th.c.withOpacity(0.18) : Colors.white.withOpacity(0.03), tick: false),
                      child: Row(children: [
                        Expanded(child: Text('${cu.name}  ${cu.plate}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
                        if (ecu.isNotEmpty && cu.ecu == ecu) const Text('ID ตรง', style: TextStyle(fontSize: 10.5, color: kGreen)),
                        Text('  ${cu.model}', style: const TextStyle(fontSize: 11, color: Colors.white54)),
                      ]),
                    ),
                  ),
              ]),
            ),
            Row(children: [
              TextButton(onPressed: () => Navigator.of(d).pop('new'), child: const Text('+ ลูกค้าใหม่')),
              const Spacer(),
              TextButton(onPressed: () => Navigator.of(d).pop(), child: const Text('ข้าม')),
              TextButton(onPressed: sel == null ? null : () => Navigator.of(d).pop(sel), child: const Text('บันทึก')),
            ]),
          ]),
        ),
      ),
    ),
  );
  if (res == null || !context.mounted) return;
  Customer cu;
  if (res is Customer) {
    cu = res;
  } else {
    cu = Customer('${DateTime.now().millisecondsSinceEpoch}', ecu: ecu);
    if (!await editCustomer(context, cu, liveEcu: ecu)) return;
  }
  if (cu.ecu.isEmpty && ecu.isNotEmpty) cu.ecu = ecu;
  await bk.addJob(cu, CustJob(DateTime.now(), 'FLASH', file: file, note: note));
}

class CustomerPage extends StatefulWidget {
  final GaugeController c;
  const CustomerPage({super.key, required this.c});
  @override
  State<CustomerPage> createState() => _CustomerPageState();
}

class _CustomerPageState extends State<CustomerPage> {
  final bk = CustBook.i;
  Customer? sel;
  String q = '';

  void _rb() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    bk.addListener(_rb);
    widget.c.addListener(_rb);
    bk.load().then((_) {
      if (!mounted) return;
      final live = bk.byEcu(ecuHex(widget.c.t.fl?.ecm));
      setState(() => sel = live ?? (bk.items.isEmpty ? null : bk.items.first));
    });
    BinLib.i.load();
  }

  @override
  void dispose() {
    bk.removeListener(_rb);
    widget.c.removeListener(_rb);
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: const Duration(seconds: 3), content: Text(m)));
  }

  String get _live => ecuHex(widget.c.t.fl?.ecm);

  Future<void> _add() async {
    final cu = Customer('${DateTime.now().millisecondsSinceEpoch}', ecu: _live);
    if (!await editCustomer(context, cu, liveEcu: _live)) return;
    bk.items.add(cu);
    await bk.save();
    setState(() => sel = cu);
  }

  Future<void> _note(Customer cu) async {
    final ctl = TextEditingController();
    String kind = 'NOTE';
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, ss) => AlertDialog(
          backgroundColor: const Color(0xFF14141A),
          title: const Text('บันทึกงาน', style: TextStyle(fontSize: 15)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              for (final k in const ['NOTE', 'TUNE'])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(label: Text(k == 'NOTE' ? 'โน้ต' : 'จูน'), selected: kind == k, onSelected: (_) => ss(() => kind = k)),
                ),
            ]),
            TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(hintText: 'เช่น เปลี่ยนท่อ, AFR ก่อน 14.6 → หลัง 13.1')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('ยกเลิก')),
            TextButton(onPressed: () => Navigator.of(d).pop(true), child: const Text('บันทึก')),
          ],
        ),
      ),
    );
    final t = ctl.text.trim();
    ctl.dispose();
    if (ok != true || t.isEmpty) return;
    await bk.addJob(cu, CustJob(DateTime.now(), kind, note: t));
  }

  BinEntry? _libOf(CustJob? j) {
    if (j == null) return null;
    for (final e in BinLib.i.items) {
      if (e.name == j.file || '${e.name}.bin' == j.file) return e;
    }
    return null;
  }

  Future<void> _delete(Customer cu) async {
    if (!await askYes(context, 'ลบลูกค้า', 'ลบ ${cu.name} และประวัติทั้งหมด', ok: 'ลบ', col: kBad)) return;
    await bk.remove(cu);
    setState(() => sel = bk.items.isEmpty ? null : bk.items.first);
  }

  @override
  Widget build(BuildContext context) {
    final th = Cfg.i.t;
    final ql = q.toLowerCase();
    final list = [
      for (final cu in bk.items)
        if (ql.isEmpty || '${cu.name} ${cu.plate} ${cu.model} ${cu.phone} ${cu.ecu}'.toLowerCase().contains(ql)) cu
    ];
    final cu = sel != null && bk.items.contains(sel) ? sel : null;
    final live = _live;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        Image.asset('assets/bg.jpg', fit: BoxFit.cover),
        Container(color: Colors.black.withOpacity(0.84)),
        const HudGrid(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: Column(children: [
              SizedBox(
                height: 34,
                child: Row(children: [
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    child: Row(children: [
                      Icon(Icons.chevron_left, color: th.c, size: 26),
                      Text('CUSTOMER', style: TextStyle(fontFamily: kFont, fontSize: 13, color: th.c, shadows: [Shadow(color: th.c, blurRadius: 8)])),
                      const Text('  สมุดลูกค้า', style: TextStyle(fontSize: 12, color: Colors.white60)),
                    ]),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 32,
                      child: TextField(
                        onChanged: (v) => setState(() => q = v.trim()),
                        style: const TextStyle(fontSize: 13),
                        decoration: InputDecoration(
                          isDense: true, hintText: 'ค้นหา ชื่อ / ทะเบียน / รุ่น / ID', prefixIcon: const Icon(Icons.search, size: 18),
                          contentPadding: const EdgeInsets.symmetric(vertical: 6), border: OutlineInputBorder(borderSide: BorderSide(color: th.c)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: _add,
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: Alignment.center,
                      decoration: hudDeco(border: th.c, width: 1.3, radius: 8, color: th.c.withOpacity(0.3)),
                      child: const Text('+ เพิ่มลูกค้า', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(
                    width: 250,
                    padding: const EdgeInsets.all(6),
                    decoration: hudDeco(border: th.c.withOpacity(0.85), width: 1.1, radius: 12, color: const Color(0xCC060606)),
                    child: list.isEmpty
                        ? Center(child: Text(bk.items.isEmpty ? 'ยังไม่มีลูกค้า\nกด + เพิ่มลูกค้า' : 'ไม่พบ', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white38)))
                        : ListView(children: [
                            for (final x in list)
                              InkWell(
                                onTap: () => setState(() => sel = x),
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 5),
                                  padding: const EdgeInsets.fromLTRB(9, 5, 9, 5),
                                  decoration: hudDeco(border: identical(x, cu) ? th.c : Colors.white24, width: identical(x, cu) ? 1.5 : 1, radius: 8,
                                      color: identical(x, cu) ? th.c.withOpacity(0.16) : Colors.white.withOpacity(0.03), tick: false),
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Row(children: [
                                      Expanded(child: Text(x.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold))),
                                      if (live.isNotEmpty && x.ecu == live) const Text('● ต่ออยู่', style: TextStyle(fontSize: 9.5, color: kGreen)),
                                    ]),
                                    Text('${x.plate}${x.model.isEmpty ? '' : ' · ${x.model}'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white60)),
                                    Text('ล่าสุด ${_dateStr(x.last)} · ${x.jobs.length} งาน', style: const TextStyle(fontSize: 9.5, color: Colors.white38)),
                                  ]),
                                ),
                              ),
                          ]),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      decoration: hudDeco(border: th.c.withOpacity(0.85), width: 1.1, radius: 12, color: const Color(0xCC060606)),
                      child: cu == null ? const Center(child: Text('เลือกลูกค้าทางซ้าย', style: TextStyle(color: Colors.white38))) : _detail(th, cu, live),
                    ),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _btn(AppTheme th, String t, VoidCallback? f, {Color? col}) => Opacity(
        opacity: f == null ? 0.4 : 1,
        child: InkWell(
          onTap: f,
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: hudDeco(border: col ?? th.c, width: 1.3, radius: 8, color: (col ?? th.c).withOpacity(0.18)),
            child: Text(t, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
          ),
        ),
      );

  Widget _detail(AppTheme th, Customer cu, String live) {
    final lastFile = cu.lastOf('');
    final lastFlash = cu.lastOf('FLASH');
    final eFile = _libOf(lastFile), eFlash = _libOf(lastFlash);
    Widget kv(String k, String v, {Color? col}) => Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(children: [
            SizedBox(width: 70, child: Text(k, style: const TextStyle(fontSize: 11.5, color: Colors.white54))),
            Expanded(child: Text(v.isEmpty ? '-' : v, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: col ?? Colors.white))),
          ]),
        );
    final jobs = [...cu.jobs]..sort((a, b) => b.time.compareTo(a.time));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(cu.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, shadows: [Shadow(color: th.c, blurRadius: 8)]))),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.edit, size: 19, color: th.c),
          onPressed: () async {
            if (await editCustomer(context, cu, liveEcu: live)) await bk.save();
          },
        ),
        IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.delete_outline, size: 19, color: kBad), onPressed: () => _delete(cu)),
      ]),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Column(children: [kv('ทะเบียน', cu.plate), kv('รุ่นรถ', cu.model), kv('เบอร์โทร', cu.phone)])),
        const SizedBox(width: 10),
        Expanded(
          child: Column(children: [
            kv('ID กล่อง', cu.ecu, col: live.isNotEmpty && cu.ecu == live ? kGreen : null),
            kv('โน้ต', cu.note),
            kv('ไฟล์ล่าสุด', lastFile?.file ?? ''),
          ]),
        ),
      ]),
      const SizedBox(height: 6),
      Text('ประวัติงาน (${cu.jobs.length})', style: TextStyle(fontFamily: kFont, fontSize: 8.5, color: th.c2)),
      const SizedBox(height: 4),
      Expanded(
        child: jobs.isEmpty
            ? const Center(child: Text('ยังไม่มีประวัติ — แฟลชสำเร็จแล้วแอพจะถามให้บันทึก', style: TextStyle(fontSize: 11.5, color: Colors.white38)))
            : ListView(children: [
                for (final j in jobs)
                  GestureDetector(
                    onLongPress: () async {
                      if (!await askYes(context, 'ลบรายการ', '${_dateStr(j.time)} ${j.kind} ${j.file}', ok: 'ลบ', col: kBad)) return;
                      cu.jobs.remove(j);
                      await bk.save();
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                      decoration: BoxDecoration(border: Border(left: BorderSide(color: j.kind == 'FLASH' ? kGreen : (j.kind == 'TUNE' ? kAmber : Colors.white38), width: 3))),
                      child: Row(children: [
                        SizedBox(width: 82, child: Text(_dateStr(j.time), style: const TextStyle(fontSize: 10.5, color: Colors.white54))),
                        SizedBox(
                          width: 50,
                          child: Text(j.kind == 'FLASH' ? 'แฟลช' : (j.kind == 'TUNE' ? 'จูน' : 'โน้ต'),
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: j.kind == 'FLASH' ? kGreen : (j.kind == 'TUNE' ? kAmber : Colors.white70))),
                        ),
                        Expanded(
                          child: Text([if (j.file.isNotEmpty) j.file, if (j.note.isNotEmpty) j.note].join('  ·  '),
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                        ),
                      ]),
                    ),
                  ),
              ]),
      ),
      const SizedBox(height: 6),
      Row(children: [
        _btn(th, '+ บันทึกงาน', () => _note(cu)),
        const SizedBox(width: 6),
        _btn(th, 'เปิดไฟล์ล่าสุดใน TUNE', eFile == null ? null : () => Navigator.of(context).push(hudRoute(TunePage(c: widget.c, initial: eFile)))),
        const SizedBox(width: 6),
        _btn(th, '⚡ แฟลชไฟล์ล่าสุด', eFlash == null ? null : () => Navigator.of(context).push(hudRoute(FlashPage(c: widget.c, initial: eFlash))), col: kGreen),
      ]),
      if (lastFile != null && eFile == null)
        const Padding(padding: EdgeInsets.only(top: 3), child: Text('ไฟล์ล่าสุดไม่อยู่ในคลังไฟล์ (เลือกจากมือถือ) — เปิดซ้ำจากแอพไม่ได้', style: TextStyle(fontSize: 9.5, color: Colors.white38))),
    ]);
  }
}

class FlashPage extends StatefulWidget {
  final GaugeController c;
  final BinEntry? initial; // เปิดหน้ามาพร้อมไฟล์จากคลัง (จากสมุดลูกค้า)
  const FlashPage({super.key, required this.c, this.initial});
  @override
  State<FlashPage> createState() => _FlashPageState();
}

class _FlashPageState extends State<FlashPage> {
  final lib = BinLib.i;
  GaugeController get c => widget.c;
  BinEntry? sel;
  Uint8List? data;
  String? extName; // ไฟล์ที่เลือกจากมือถือ (ไม่ได้เก็บเข้าคลัง) — null = ใช้ไฟล์จากคลัง
  double? up; // ความคืบหน้าส่งไฟล์ไปเกจ
  bool working = false;
  String? msg;
  // จำผลสรุปไฟล์ไว้ (ค้นลายเซ็น + ผลรวมทั้งไฟล์ช้า ไม่ควรทำทุกครั้งที่ได้ข้อมูลจากเกจ)
  Uint8List? _planFor;
  String _planKey = '';
  BinPlan? _plan;
  int _sum16 = 0;
  BinPlan _planOf(Uint8List d, (int, int)? idProf) {
    final key = idProf == null ? '-' : '${idProf.$1}:${idProf.$2}';
    if (!identical(_planFor, d) || _planKey != key || _plan == null) {
      if (!identical(_planFor, d)) _sum16 = d.fold<int>(0, (a, x) => (a + x) & 0xFFFF);
      _planFor = d;
      _planKey = key;
      _plan = binPlan(d, idProf);
    }
    return _plan!;
  }

  int _lastPh = -1;
  void _rb() {
    if (mounted) setState(() {});
    // แฟลชสำเร็จ (เปลี่ยนจากกำลังแฟลช → 9): ถามบันทึกเข้าสมุดลูกค้า
    final ph = c.t.fl?.phase ?? -1;
    if (ph == 9 && _lastPh >= 4 && _lastPh <= 8) {
      final file = sel?.name ?? extName ?? '';
      final ecu = ecuHex(c.t.fl?.ecm);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) askSaveFlashJob(context, file: file, ecu: ecu);
      });
    }
    if (ph != _lastPh) _lastPh = ph;
  }

  @override
  void initState() {
    super.initState();
    lib.addListener(_rb);
    c.addListener(_rb);
    Cfg.i.addListener(_rb);
    lib.load();
    final e = widget.initial;
    if (e != null) _select(e);
  }

  @override
  void dispose() {
    lib.removeListener(_rb);
    c.removeListener(_rb);
    Cfg.i.removeListener(_rb);
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: const Duration(seconds: 3), content: Text(m)));
  }

  Future<void> _select(BinEntry e) async {
    try {
      final b = await lib.read(e);
      setState(() {
        sel = e;
        data = b;
        extName = null;
        msg = null;
      });
    } catch (err) {
      _snack('อ่านไฟล์ไม่ได้: $err');
    }
  }

  /// เลือกไฟล์ .bin จากมือถือมาแฟลชได้เลย (ไม่เก็บเข้าคลังไฟล์ของแอพ)
  Future<void> _pickPhone() async {
    try {
      final f = await pickFileExt('bin', _snack);
      if (f == null || !mounted) return;
      setState(() {
        sel = null;
        data = f.$2;
        extName = f.$1;
        msg = null;
      });
    } catch (err) {
      _snack('เปิดไฟล์ไม่สำเร็จ: $err');
    }
  }

  Future<void> _entryMenu(BinEntry e, int v) async {
    switch (v) {
      case 1:
        final n = await askText(context, 'เปลี่ยนชื่อ', e.name, ok: 'เปลี่ยน');
        if (n == null) return;
        final err = await lib.rename(e, n);
        if (err != null) _snack(err);
        break;
      case 2:
        try {
          final b = await lib.read(e);
          final p = await FilePicker.platform.saveFile(dialogTitle: 'ส่งออก BIN', fileName: '${e.name}.bin', type: FileType.any, bytes: b);
          if (p != null) _snack('ส่งออกแล้ว: $p');
        } catch (err) {
          _snack('ส่งออกไม่สำเร็จ: $err');
        }
        break;
      case 3:
        if (!await askYes(context, 'ลบไฟล์', 'ลบ "${e.name}" ออกจากคลัง?', ok: 'ลบ', col: kBad)) return;
        await lib.remove(e);
        if (sel == e) {
          setState(() {
            sel = null;
            data = null;
          });
        }
        break;
    }
  }

  // ----- ส่งไฟล์ไปเกจ (เริ่มแฟลชด้วยปุ่ม FLASH ที่เกจ) -----
  Future<void> _send() async {
    final d = data;
    final f = c.t.fl;
    final nm = extName ?? (sel != null ? '${sel!.name}.bin' : null);
    if (nm == null || d == null || f == null) return;
    // offset ตาม ID กล่อง (ฐานข้อมูล) ก่อน ถ้าไม่มีเกจเลือกตามขนาดไฟล์ ; Shindengen เกจหา offset/checksum เอง
    final idProf = f.ecm != null ? EcuDb.profile[ecmHex(f.ecm)] : null;
    final plan = binPlan(d, idProf);
    if (!plan.ok) return;
    setState(() {
      working = true;
      msg = null;
      up = 0;
    });
    await c.clearFlash();
    final err = await c.sendBin(d, (v) {
      if (mounted) setState(() => up = v);
    }, name: nm, startOff: plan.fromId ? plan.off : null, ckOff: plan.fromId ? plan.ck : null);
    if (!mounted) return;
    setState(() {
      working = false;
      up = null;
      msg = err;
    });
    _snack(err ?? (_gaugePhoneFlash ? 'ส่งไฟล์แล้ว ✓ กด ⚡ FLASH เพื่อเริ่มแฟลช' : 'ส่งไฟล์แล้ว ✓ กดปุ่ม FLASH ที่เกจเพื่อเริ่มแฟลช'));
  }

  // ======================= UI =======================
  @override
  Widget build(BuildContext context) {
    final th = Cfg.i.t;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        Image.asset('assets/bg.jpg', fit: BoxFit.cover),
        Container(color: Colors.black.withOpacity(0.84)),
        const HudGrid(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: Column(children: [
              SizedBox(
                height: 34,
                child: Row(children: [
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    child: Row(children: [
                      Icon(Icons.chevron_left, color: th.c, size: 26),
                      Text('FLASH ECU', style: TextStyle(fontFamily: kFont, fontSize: 14, color: th.c, shadows: [Shadow(color: th.c, blurRadius: 8)])),
                    ]),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('แก้ตารางที่หน้า TUNE💻 แล้วบันทึกเข้าคลัง → เลือกไฟล์ → ส่งไปเกจ → กด FLASH',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: Colors.white54)),
                  ),
                ]),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(flex: 10, child: _frame(th, _libPanel(th))),
                  const SizedBox(width: 8),
                  Expanded(flex: 19, child: _frame(th, _flashPanel(th))),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _frame(AppTheme th, Widget child) => Container(
        padding: const EdgeInsets.all(10),
        decoration: hudDeco(border: th.c.withOpacity(0.85), width: 1.1, radius: 12, color: const Color(0xCC060606)),
        child: child,
      );

  Widget _btn(AppTheme th, String s, VoidCallback? f, {IconData? ic, Color? col, bool big = false}) {
    final cc = col ?? th.c;
    return Opacity(
      opacity: f == null ? 0.4 : 1,
      child: InkWell(
        onTap: f,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: big ? 12 : 7),
          decoration: hudDeco(border: cc, width: 1.4, radius: 8, color: big ? cc.withOpacity(0.25) : Colors.black45),
          child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            if (ic != null) ...[Icon(ic, size: big ? 20 : 16, color: cc), const SizedBox(width: 6)],
            Flexible(child: Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: big ? 15 : 12, fontWeight: FontWeight.bold))),
          ]),
        ),
      ),
    );
  }

  Widget _libPanel(AppTheme th) {
    final lock = working || (c.t.fl?.busy ?? false);
    Widget item({required String name, required String sub, required bool on, required int ck8, VoidCallback? onTap, Widget? menu, IconData ic = Icons.description}) =>
        InkWell(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.only(bottom: 5),
            padding: const EdgeInsets.fromLTRB(7, 6, 2, 6),
            decoration: hudDeco(border: on ? th.c : Colors.white12, width: on ? 1.5 : 1, radius: 9, color: on ? th.c.withOpacity(0.2) : Colors.white.withOpacity(0.03)),
            child: Row(children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: on ? th.c : Colors.white.withOpacity(0.06), borderRadius: BorderRadius.circular(7)),
                child: Icon(ic, size: 17, color: on ? Colors.white : Colors.white70),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
                ]),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(border: Border.all(color: (ck8 == 0 ? kGreen : kAmber).withOpacity(0.5)), borderRadius: BorderRadius.circular(6)),
                child: Text(ck8 == 0 ? 'SUM ✓' : 'SUM ${_hx(ck8).substring(2)}', style: TextStyle(fontSize: 9.5, color: ck8 == 0 ? kGreen : kAmber)),
              ),
              menu ?? const SizedBox(width: 6),
            ]),
          ),
        );
    return Opacity(
      opacity: lock ? 0.55 : 1,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('คลังไฟล์', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: th.c2))),
          _btn(th, 'เปิด BIN', lock ? null : _pickPhone, ic: Icons.folder_open),
        ]),
        const SizedBox(height: 8),
        if (extName != null)
          item(
              name: extName!,
              sub: '${((data?.length ?? 0) / 1024).toStringAsFixed(1)} KB · จากมือถือ',
              on: true,
              ck8: (data ?? Uint8List(0)).fold<int>(0, (a, x) => (a + x) & 0xFF),
              ic: Icons.phone_android),
        Expanded(
          child: lib.items.isEmpty
              ? const Center(
                  child: Text('คลังยังว่าง\nบันทึกจากหน้า TUNE💻 (ไฟล์ > บันทึกเข้าคลังไฟล์)\nหรือกด "เปิด BIN" เพื่อแฟลชไฟล์ในเครื่องโดยตรง',
                      textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 12)))
              : ListView(children: [
                  for (final e in lib.items)
                    item(
                      name: e.name,
                      sub: '${(e.size / 1024).toStringAsFixed(0)} KB · ${_dateStr(e.time)}',
                      on: sel == e,
                      ck8: e.ck8,
                      onTap: lock ? null : () => _select(e),
                      menu: PopupMenuButton<int>(
                        color: const Color(0xFF16161D),
                        icon: const Icon(Icons.more_vert, size: 18, color: Colors.white54),
                        onSelected: (v) => _entryMenu(e, v),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 1, child: Text('เปลี่ยนชื่อ')),
                          PopupMenuItem(value: 2, child: Text('ส่งออกไฟล์…')),
                          PopupMenuItem(value: 3, child: Text('ลบ', style: TextStyle(color: kBad))),
                        ],
                      ),
                    ),
                ]),
        ),
      ]),
    );
  }

  // แถวขั้นตอน FILE → SEND → ERASE → WRITE → VERIFY → DONE
  // ok = จำนวนขั้นที่ผ่านแล้ว, now = ขั้นที่กำลังทำ (-1 = ไม่มี), bad = ขั้นที่ไม่สำเร็จ (-1 = ไม่มี)
  Widget _steps(AppTheme th, int ok, int now, int bad) {
    const names = ['FILE', 'SEND', 'ERASE', 'WRITE', 'VERIFY', 'DONE'];
    Widget dot(int i) {
      final isOk = i < ok, isNow = i == now, isBad = i == bad;
      final col = isBad ? kBad : (isNow ? th.c : (isOk ? kGreen : Colors.white24));
      return SizedBox(
        width: 48,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (isNow || isBad) ? col : (isOk ? kGreen.withOpacity(0.2) : const Color(0xFF111111)),
              border: Border.all(color: col, width: 2),
              boxShadow: (isOk || isNow || isBad) ? [BoxShadow(color: col.withOpacity(0.7), blurRadius: isNow ? 10 : 6)] : null,
            ),
            child: isOk && !isNow && !isBad
                ? const Icon(Icons.check, size: 10, color: kGreen)
                : (isBad ? const Icon(Icons.close, size: 10, color: Colors.white) : null),
          ),
          const SizedBox(height: 3),
          Text(names[i], style: TextStyle(fontFamily: kFont, fontSize: 6.5, color: isBad ? kBad : (isNow ? Colors.white : (isOk ? kGreen : Colors.white38)))),
        ]),
      );
    }

    Widget line(int i) {
      // เส้นก่อนขั้น i
      final full = i < ok && !(i == now);
      final toNow = i == now || i == bad;
      return Expanded(
        child: Container(
          height: 2,
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: full ? kGreen : (toNow ? null : Colors.white24),
            gradient: toNow ? LinearGradient(colors: [kGreen, i == bad ? kBad : th.c]) : null,
            boxShadow: full ? [BoxShadow(color: kGreen.withOpacity(0.6), blurRadius: 4)] : null,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(children: [
        for (int i = 0; i < 6; i++) ...[if (i > 0) line(i), dot(i)],
      ]),
    );
  }

  Widget _chip(String t, String v, Color dot) => Expanded(
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
          decoration: hudDeco(border: Colors.white24, width: 1, radius: 9, color: Colors.white.withOpacity(0.03), tick: false),
          child: Row(children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: dot, boxShadow: [BoxShadow(color: dot, blurRadius: 5)]),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t, style: const TextStyle(fontFamily: kFont, fontSize: 7, color: Colors.white54)),
                Text(v, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ]),
            ),
          ]),
        ),
      );

  /// เกจรองรับสั่งแฟลชจากมือถือ (FW 1.0.15 ขึ้นไป)
  bool get _gaugePhoneFlash {
    final t = c.t;
    if (t.fwMaj == null) return false;
    final v = t.fwMaj! * 10000 + t.fwMin! * 100 + t.fwPatch!;
    return v >= 10015;
  }

  /// กด ⚡ FLASH บนมือถือ: เช็กลิสต์ + กดค้าง 2 วิ เพื่อยืนยัน
  Future<void> _phoneFlash(List<(bool, String)> checks, String fileName, String sub) async {
    final th = Cfg.i.t;
    final allOk = checks.every((e) => e.$1);
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.72),
      builder: (dctx) => Dialog(
        backgroundColor: const Color(0xFF0C0708),
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
        shape: HudBorder(cut: 14, side: BorderSide(color: th.c, width: 1.4)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('⚡ เริ่มแฟลช $fileName ?', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: Colors.white60)),
              const SizedBox(height: 8),
              for (final ck in checks)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Icon(ck.$1 ? Icons.check_circle : Icons.cancel, size: 16, color: ck.$1 ? kGreen : kBad),
                    const SizedBox(width: 8),
                    Expanded(child: Text(ck.$2, style: TextStyle(fontSize: 12.5, color: ck.$1 ? Colors.white : kBad))),
                  ]),
                ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Icon(Icons.error, size: 16, color: kAmber),
                  SizedBox(width: 8),
                  Expanded(child: Text('บิดกุญแจ ON ไม่ติดเครื่อง · ห้ามดับ/ถอดสายระหว่างแฟลช', style: TextStyle(fontSize: 12.5, color: kAmber))),
                ]),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _btn(th, 'ยกเลิก', () => Navigator.of(dctx).pop(false), col: Colors.white38)),
                const SizedBox(width: 10),
                Expanded(
                  flex: 3,
                  child: allOk
                      ? _HoldButton(color: th.c, label: 'กดค้าง 2 วิ เพื่อ FLASH', onDone: () => Navigator.of(dctx).pop(true))
                      : Opacity(opacity: 0.4, child: _btn(th, 'ยังเริ่มแฟลชไม่ได้', null, col: kBad)),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
    if (go != true || !mounted) return;
    final d = data;
    if (d == null) return;
    final err = await c.startFlash(d.length, _sum16);
    if (!mounted) return;
    _snack(err ?? 'สั่งเริ่มแฟลชแล้ว — ห้ามปิดกุญแจ / ถอดสาย');
  }

  Widget _flashPanel(AppTheme th) {
    final f = c.t.fl;
    final connected = c.link == LinkState.connected && !c.demo;
    final busy = f?.busy ?? false;
    final d = data;
    final idProf = f?.ecm != null ? EcuDb.profile[ecmHex(f!.ecm)] : null; // offset ตาม ID กล่อง
    final plan = d == null ? null : _planOf(d, idProf); // แผนที่เกจจะสรุปจากไฟล์นี้
    final sum16 = d == null ? null : _sum16;
    // หมายเหตุ: หลังแฟลช เกจคำนวณ checksum ใหม่ลงไฟล์ในเกจ ผลรวมจึงอาจไม่ตรงกับไฟล์ในแอพอีก
    final onGauge = f != null && d != null && f.fileSize == d.length && f.fileSum == sum16;
    final canSend = connected && f != null && f.prep && !busy && f.phase != 2 && !working && d != null && plan != null && plan.ok;
    final ecuOk = f != null && (f.ecu == 2 || f.ecu == 3 || f.ecu == 5 || f.ecu == 6);
    final fname = extName ?? (sel != null ? '${sel!.name}.bin' : null);

    // ---- ชิปสถานะ ----
    String gTxt;
    Color gCol;
    if (c.demo) {
      gTxt = 'ปิด DEMO ก่อน';
      gCol = kAmber;
    } else if (!connected) {
      gTxt = 'ยังไม่เชื่อมต่อ';
      gCol = kBad;
    } else if (f == null) {
      gTxt = 'FW ไม่รองรับ';
      gCol = kBad;
    } else if (!f.prep) {
      gTxt = 'เปิดหน้า ECU FLASH';
      gCol = kAmber;
    } else if (busy) {
      gTxt = 'กำลังแฟลช';
      gCol = th.c;
    } else {
      gTxt = 'พร้อมแฟลช';
      gCol = kGreen;
    }
    final model = f?.ecm != null ? (ecuModelName(f!.ecm) ?? 'ไม่ทราบรุ่น') : '--';
    final eTxt = f == null || !f.prep ? '--' : '$model · ${switch (f.ecu) { 2 => 'OK', 3 => 'FLASH', 5 || 6 => 'RECOVER', 0 => 'OFF', 1 => 'ไม่ตอบ', _ => '...' }}';
    final eCol = f == null || !f.prep ? Colors.white24 : (ecuOk ? (f.ecu >= 5 ? kAmber : kGreen) : kBad);
    final inTxt = f == null || f.fileSize == 0 ? 'ยังไม่มีไฟล์' : (onGauge ? '${fname ?? 'ไฟล์'} ✓' : '${(f.fileSize / 1024).round()} KB (คนละไฟล์)');
    final inCol = f == null || f.fileSize == 0 ? Colors.white24 : (onGauge ? kGreen : kAmber);

    // ---- ขั้นตอน + ความคืบหน้า ----
    int ok = (d != null ? 1 : 0) + (onGauge || busy || (f?.phase ?? 0) >= 9 ? 1 : 0);
    int now = -1, bad = -1;
    String phTxt = '';
    double? prog;
    String sizeTxt = '', midTxt = '', timeTxt = '';
    Color phCol = Colors.white;
    if (up != null) {
      ok = d != null ? 1 : 0;
      now = 1;
      phTxt = 'กำลังส่งไฟล์ไปเกจ';
      prog = up;
      final n = d?.length ?? 0;
      sizeTxt = '${(n * up! / 1024).round()} / ${(n / 1024).round()} KB';
    } else if (f != null && f.prep && (busy || f.phase >= 9)) {
      final p = f.phase;
      if (p >= 4 && p <= 6) now = 2;
      if (p == 7) now = 3;
      if (p == 8) now = 4;
      if (p == 9) ok = 6;
      if (p == 10) bad = f.done > 0 ? 3 : 2;
      if (now >= 0) ok = now;
      if (bad >= 0) ok = bad;
      phTxt = p == 9 ? 'แฟลชสำเร็จ' : (p == 10 ? 'แฟลชไม่สำเร็จ' : flashPhaseText(p));
      phCol = p == 9 ? kGreen : (p == 10 ? kBad : Colors.white);
      prog = p == 9 ? 1.0 : (f.total > 0 ? f.done / f.total : f.pct / 100);
      sizeTxt = '${((p == 9 ? f.total : f.done) / 1024).round()} / ${(f.total / 1024).round()} KB';
      timeTxt = _mmss(f.elapsed);
      midTxt = p == 9 ? 'CHECKSUM OK' : (p == 10 ? (f.err != 0 ? flashErrText(f.err) : '') : (f.eta > 0 ? 'เหลือ ~${_mmss(f.eta)}' : ''));
    }

    // ---- ข้อมูลไฟล์ที่เลือก ----
    String info = '';
    Color infoCol = Colors.white70;
    if (d != null && plan != null) {
      final pl = plan;
      if (!pl.ok) {
        info = '${(d.length / 1024).toStringAsFixed(1)} KB · ${pl.type} — แฟลชไม่ได้: ${pl.why}';
        infoCol = kAmber;
      } else if (pl.sh) {
        info = '${(d.length / 1024).round()} KB · ${pl.type} (Shindengen) · เริ่ม ${_hx(pl.off, 4)} · checksum อัตโนมัติ';
      } else {
        info = '${(d.length / 1024).round()} KB · ${pl.type} · เริ่ม ${_hx(pl.off, 4)} · '
            '${(sum16 ?? 0) & 0xFF == 0 ? 'checksum ผ่าน' : 'เกจคำนวณ checksum ให้'}';
      }
    }

    // ---- ปุ่มแฟลชบนมือถือ ----
    final phoneOk = _gaugePhoneFlash;
    final canPhone = phoneOk && connected && f != null && f.prep && !busy && f.phase != 2 && !working && onGauge && ecuOk && plan != null && plan.ok;
    final checks = <(bool, String)>[
      (connected && f != null && f.prep, 'เกจอยู่หน้าเตรียมแฟลช'),
      (ecuOk, 'กล่อง ECU ตอบ (${f == null ? '--' : flashEcuText(f.ecu)})'),
      (onGauge, onGauge ? 'ไฟล์ในเกจตรงกับไฟล์ที่เลือก' : 'ไฟล์ในเกจไม่ตรง — กดส่งไฟล์ไปเกจก่อน'),
      (f?.batt == null || f!.batt! >= 12.0, 'แบต ${f?.batt == null ? '--' : f!.batt!.toStringAsFixed(1)} V'),
    ];

    final askSub = '$model · ${f?.ecm != null ? 'ID ${ecmHex(f!.ecm)} · ' : ''}${((d?.length ?? 0) / 1024).round()} KB';

    // ---- ข้อความบรรทัดล่าง ----
    String note;
    Color noteCol = Colors.white54;
    if (busy) {
      note = '⚠ ห้ามปิดกุญแจ / ถอดสาย — ออกจากหน้านี้ได้ เกจแฟลชต่อเอง';
      noteCol = const Color(0xFFFF6B6E);
    } else if (f != null && f.phase == 9) {
      note = 'ปิดกุญแจ ~10 วินาที แล้วเปิดใหม่ก่อนสตาร์ท'
          '${f.count != null && f.count0 != null && f.count! > f.count0! ? ' · FLASHCOUNT ${f.count0} → ${f.count}' : ''}';
      noteCol = kGreen;
    } else if (f != null && f.phase == 10) {
      note = 'เช็กแบต / สาย K-Line แล้วสั่ง FLASH อีกครั้ง';
      noteCol = kAmber;
    } else if (onGauge) {
      note = phoneOk ? 'กด ⚡ FLASH บนมือถือ หรือที่หน้าเกจก็ได้ · บิดกุญแจ ON ไม่ต้องสตาร์ท' : 'กดปุ่ม FLASH ที่หน้าเกจ (อัปเดตเกจเป็น FW 1.0.15 เพื่อกดจากมือถือ)';
    } else {
      note = 'เลือกไฟล์ แล้วกดส่งไปเกจ';
    }

    final showProg = phTxt.isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _steps(th, ok, now, bad),
      const SizedBox(height: 7),
      Row(children: [
        _chip('GAUGE', gTxt, gCol),
        const SizedBox(width: 6),
        _chip('ECU', eTxt, eCol),
        const SizedBox(width: 6),
        _chip('IN GAUGE', inTxt, inCol),
      ]),
      const SizedBox(height: 7),
      Expanded(
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // การ์ดไฟล์ที่เลือก
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: hudDeco(border: Colors.white24, width: 1, radius: 10, color: Colors.white.withOpacity(0.03)),
              child: Row(children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(color: d != null ? th.c : Colors.white10, borderRadius: BorderRadius.circular(9),
                      boxShadow: d != null ? [BoxShadow(color: th.c.withOpacity(0.5), blurRadius: 8)] : null),
                  child: const Icon(Icons.description, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(fname ?? 'ยังไม่ได้เลือกไฟล์', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    Text(d == null ? 'เลือกจากคลังไฟล์ หรือกด "เปิด BIN"' : info,
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: d == null ? Colors.white54 : infoCol)),
                  ]),
                ),
                if (f?.ecm != null) Text('ID ${ecmHex(f!.ecm)}', style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
              ]),
            ),
            const SizedBox(height: 8),
            if (showProg)
              Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                decoration: hudDeco(border: phCol == Colors.white ? Colors.white24 : phCol.withOpacity(0.5), width: 1, radius: 10, color: Colors.white.withOpacity(0.03)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                        child: Text('${phCol == kGreen ? '✓ ' : (phCol == kBad ? '✕ ' : '')}$phTxt',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: phCol))),
                    if (prog != null) Text('${(prog * 100).round()}', style: TextStyle(fontFamily: kFont, fontSize: 20, color: phCol)),
                    if (prog != null) const Text(' %', style: TextStyle(fontFamily: kFont, fontSize: 10, color: Colors.white54)),
                  ]),
                  const SizedBox(height: 6),
                  SizedBox(height: 20, child: CustomPaint(painter: _FlBarPainter(prog ?? 0, fail: phCol == kBad))),
                  const SizedBox(height: 5),
                  Row(children: [
                    Text(sizeTxt, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                    Expanded(
                        child: Text(midTxt, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: phCol == Colors.white ? Colors.white70 : phCol))),
                    if (timeTxt.isNotEmpty) Text('⏱ $timeTxt', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                  ]),
                ]),
              )
            else
              Row(children: [
                Expanded(child: _btn(th, onGauge ? 'ส่งไฟล์ไปเกจอีกครั้ง' : 'ส่งไฟล์ไปเกจ', canSend ? _send : null, ic: Icons.upload, big: !phoneOk || !onGauge)),
                if (phoneOk && onGauge) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: Opacity(
                      opacity: canPhone ? 1 : 0.4,
                      child: InkWell(
                        onTap: canPhone
                            ? () => _phoneFlash(checks, fname ?? 'ไฟล์', askSub)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          alignment: Alignment.center,
                          decoration: hudDeco(border: th.c, width: 1.4, radius: 9, gradient: LinearGradient(colors: [Color.lerp(th.c, Colors.black, 0.25)!, th.c])),
                          child: const Text('⚡ FLASH', style: TextStyle(fontFamily: kFont, fontSize: 15, color: Colors.white, shadows: [Shadow(color: Colors.white54, blurRadius: 6)])),
                        ),
                      ),
                    ),
                  ),
                ],
              ]),
            if (msg != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(msg!, style: const TextStyle(fontSize: 12, color: kBad))),
            if (f != null && f.err != 0 && f.phase != 10)
              Padding(padding: const EdgeInsets.only(top: 6), child: Text('เกจแจ้ง: ${flashErrText(f.err)}', style: const TextStyle(fontSize: 12, color: kBad))),
          ]),
        ),
      ),
      Text(note, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: noteCol)),
      if (f != null && (f.phase == 9 || f.phase == 10) && !working)
        Padding(padding: const EdgeInsets.only(top: 6), child: Center(child: _btn(th, 'ล้างผล', () => c.clearFlash()))),
    ]);
  }
}

/// แท่งความคืบหน้าทรงเอียง สีไล่แดง → เขียว (คงที่ ไม่เปลี่ยนตามธีม)
class _FlBarPainter extends CustomPainter {
  final double f;
  final bool fail;
  _FlBarPainter(this.f, {this.fail = false});
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, sl = 5.0;
    Path poly(double x0, double x1) => Path()
      ..moveTo(x0 + sl, 0)
      ..lineTo(x1 + sl, 0)
      ..lineTo(x1, h)
      ..lineTo(x0, h)
      ..close();
    canvas.drawPath(poly(0, w - sl), Paint()..color = const Color(0xFF26262D));
    final fw = (w - sl) * f.clamp(0.0, 1.0);
    if (fw <= 0) return;
    final paint = Paint();
    if (fail) {
      paint.color = kBad;
    } else {
      paint.shader = const LinearGradient(colors: [Color(0xFFFF2D2D), Color(0xFF2EE66B)]).createShader(Rect.fromLTWH(0, 0, w, h));
    }
    canvas.drawPath(poly(0, fw), Paint()
      ..color = (fail ? kBad : const Color(0xFFFF5A2D)).withOpacity(0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    canvas.drawPath(poly(0, fw), paint);
  }

  @override
  bool shouldRepaint(_FlBarPainter o) => o.f != f || o.fail != fail;
}

/// ปุ่มกดค้างเพื่อยืนยัน (แถบเติมเต็มใน 2 วินาที)
class _HoldButton extends StatefulWidget {
  final Color color;
  final String label;
  final VoidCallback onDone;
  const _HoldButton({required this.color, required this.label, required this.onDone});
  @override
  State<_HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<_HoldButton> with SingleTickerProviderStateMixin {
  late final AnimationController ac = AnimationController(vsync: this, duration: const Duration(seconds: 2))
    ..addListener(() => setState(() {}))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        HapticFeedback.heavyImpact();
        widget.onDone();
      }
    });

  @override
  void dispose() {
    ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTapDown: (_) => ac.forward(),
        onTapUp: (_) {
          if (ac.status != AnimationStatus.completed) ac.reverse();
        },
        onTapCancel: () {
          if (ac.status != AnimationStatus.completed) ac.reverse();
        },
        child: Container(
          height: 42,
          decoration: hudDeco(border: widget.color, width: 1.3, radius: 9, color: widget.color.withOpacity(0.18)),
          child: Stack(children: [
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: ac.value,
                child: Container(color: widget.color.withOpacity(0.85)),
              ),
            ),
            Center(child: Text(widget.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
          ]),
        ),
      );
}
