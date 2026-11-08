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
];

// ---------- ค่าคีย์ที่แสดงได้ (เหมือน TEST1 + TOP SPD) ----------
const int kTps = 0, kTemp = 1, kBatt = 2, kAfr = 3, kInj = 4, kIgn = 5, kRpm = 6, kMap = 7,
    kSpd = 8, kEot = 9, kIat = 10, kO2 = 11, kStft = 12, kLtft = 13, kTop = 14;

class KeyDef {
  final String name, unit;
  final int dec;
  const KeyDef(this.name, this.unit, this.dec);
}

const kKeys = <KeyDef>[
  KeyDef('TPS', '%', 1), KeyDef('W.TEMP', '°C', 0), KeyDef('BATT', 'V', 1), KeyDef('AFR', '', 1),
  KeyDef('INJ', 'ms', 2), KeyDef('IGN', '°BTDC', 1), KeyDef('RPM', 'rpm', 0), KeyDef('MAP', 'kPa', 0),
  KeyDef('SPD', 'km/h', 0), KeyDef('EOT', '°C', 0), KeyDef('IAT', '°C', 0), KeyDef('O2', 'V', 2),
  KeyDef('STFT', '', 3), KeyDef('LTFT', '', 3), KeyDef('TOP SPD', 'km/h', 0),
];

// สีค่าคงที่ (ไม่เปลี่ยนตามธีม)
const kTpsBlue = Color(0xFF3D6BFF);
const kBattRed = Color(0xFFFF3B3B);
const kAfrLow = Color(0xFF2EB8FF); // < 13  ฟ้า
const kAfrOk = Color(0xFF3CFF8A); // 13-14.7 เขียว
const kAfrHigh = Color(0xFFFF3B3B); // > 14.7 แดง
const kLogoRed = Color(0xFFFF2A2A);

Color afrColor(double v) => v < 13.0 ? kAfrLow : (v <= 14.7 ? kAfrOk : kAfrHigh);

/// สีไล่เฉดเขียว -> เหลือง -> แดง ตามตำแหน่งรอบเครื่อง เทียบกับ SHIFT RPM
Color rpmColor(double rpm, int shift) {
  final t = (rpm / math.max(1, shift)).clamp(0.0, 1.0).toDouble();
  const g = Color(0xFF29E868), y = Color(0xFFFFD21F), r = Color(0xFFFF2A2A);
  return t < 0.65 ? Color.lerp(g, y, t / 0.65)! : Color.lerp(y, r, (t - 0.65) / 0.35)!;
}

// ---------- การตั้งค่าที่บันทึกในเครื่อง ----------
class Cfg extends ChangeNotifier {
  static final Cfg i = Cfg._();
  Cfg._();
  int themeIdx = 0;
  int shift = 10000; // SHIFT LIGHT RPM
  int tempWarn = 105; // °C
  bool speedGps = true; // true = GPS, false = ECU
  int graphOn = 15; // หน้า GRAPH: บิตเปิด-ปิดเส้นกราฟ RPM/TPS/GPS/AFR
  List<int> main = [kTps, kAfr, kIgn, kTemp, kEot, kBatt, kIat]; // ซ้าย 3 + ขวา 4
  List<int> grid = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

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
      main = _parse(p.getString('main'), 7) ?? main;
      grid = _parse(p.getString('grid'), 12) ?? grid;
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
  Telemetry({
    this.fresh = false, this.state = 0, this.proto = 0, this.bike = 0, this.img = 0,
    this.rpm, this.speed, this.ect, this.iat, this.eot, this.tps, this.map,
    this.batt, this.afr, this.ign, this.inj, this.o2v, this.stft, this.ltft, this.fl,
  });

  static Telemetry? parse(List<int> b) {
    if (b.length < 34 || b[0] != 1) return null;
    final d = ByteData.sublistView(Uint8List.fromList(b));
    double? f(int off, double k) {
      final v = d.getInt16(off, Endian.little);
      return v == 0x7FFF ? null : v / k;
    }

    return Telemetry(
      state: b[1], proto: b[2], fresh: (b[3] & 1) != 0, bike: b[4], img: b[5],
      rpm: f(6, 1), speed: f(8, 10), ect: f(10, 10), iat: f(12, 10),
      eot: f(14, 10), tps: f(16, 10), map: f(18, 10), batt: f(20, 100),
      afr: f(22, 100), ign: f(24, 10), inj: f(26, 100), o2v: f(28, 1000),
      stft: f(30, 1000), ltft: f(32, 1000),
      fl: FlashStat.parse(b),
    );
  }
}

enum LinkState { idle, scanning, connecting, connected }

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
  Future<String?> sendBin(Uint8List data, void Function(double) onProgress, {String name = ''}) async {
    final ch = _imgCh;
    if (ch == null || link != LinkState.connected || _dev == null) return 'ยังไม่ได้เชื่อมต่อเกจ';
    final f0 = t.fl;
    if (f0 == null) return 'เฟิร์มแวร์เกจยังไม่รองรับการแฟลช (ต้อง FW 1.0.10 ขึ้นไป)';
    if (!f0.prep) return 'เกจยังไม่อยู่หน้าเตรียมแฟลช';
    _logoBusy = true;
    try {
      final chunk = (_dev!.mtuNow - 4).clamp(16, 200).toInt();
      final n = data.length;
      // ชื่อไฟล์ (ASCII เท่านั้น สูงสุด 32 ตัว) ให้เกจแสดง
      final nm = [for (final u in name.codeUnits) (u >= 0x20 && u < 0x7F) ? u : 0x5F].take(32).toList();
      await ch.write([0x21, n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255, ...nm]);
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
  SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
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
      pageBuilder: (_, __, ___) => const GaugePage(),
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
    builder: (dctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xF2060606),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: th.c, width: 1.2),
              boxShadow: [BoxShadow(color: th.c.withOpacity(0.4), blurRadius: 14)],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('SELECT', style: TextStyle(fontFamily: kFont, fontSize: 12, color: th.c)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (int k = 0; k < kKeys.length; k++)
                  InkWell(
                    onTap: () {
                      Cfg.i.setSlot(arr, idx, k);
                      Navigator.of(dctx).pop();
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      width: 92,
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: arr[idx] == k ? th.c.withOpacity(0.3) : Colors.black45,
                        border: Border.all(color: arr[idx] == k ? th.c : Colors.white24, width: arr[idx] == k ? 1.6 : 1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(kKeys[k].name, style: const TextStyle(fontFamily: kFont, fontSize: 9)),
                    ),
                  ),
              ]),
            ]),
          ),
        ),
      ),
    ),
  );
}

// ---------- หน้าเกจหลัก (2 หน้า: GAUGE / GRID) ----------
class GaugePage extends StatefulWidget {
  const GaugePage({super.key});
  @override
  State<GaugePage> createState() => _GaugePageState();
}

class _GaugePageState extends State<GaugePage> {
  final c = GaugeController();
  final pc = PageController();
  int page = 0;

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    c.init();
    c.addListener(_rebuild);
    Cfg.i.addListener(_rebuild);
  }

  @override
  void dispose() {
    Cfg.i.removeListener(_rebuild);
    c.removeListener(_rebuild);
    c.dispose();
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
    final linkTxt = switch (c.link) {
      LinkState.idle => 'OFFLINE',
      LinkState.scanning => 'SCANNING',
      LinkState.connecting => 'CONNECTING',
      LinkState.connected => c.gaugeName ?? 'CONNECTED',
    };
    final linkCol = c.link == LinkState.connected ? kGreen : (c.link == LinkState.idle ? kBad : kAmber);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        Image.asset('assets/bg.jpg', fit: BoxFit.cover),
        Container(color: Colors.black.withOpacity(0.55)),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
            child: Column(children: [
              Row(children: [
                Text.rich(
                  TextSpan(children: [
                    const TextSpan(text: 'MFB-', style: TextStyle(color: kLogoRed, shadows: [Shadow(color: kLogoRed, blurRadius: 10)])),
                    TextSpan(text: 'PRO', style: TextStyle(color: th.c, shadows: [Shadow(color: th.c, blurRadius: 10)])),
                  ]),
                  style: const TextStyle(fontFamily: kFont, fontSize: 17),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      _chip(linkTxt, linkCol),
                      _chip(c.ecuLive || c.demo ? 'ECU LIVE' : 'NO ECU', c.ecuLive || c.demo ? kGreen : kBad),
                      _chip(c.gpsOk ? 'GPS' : 'NO GPS', c.gpsOk ? kGreen : kBad),
                    ]),
                  ),
                ),
                _btn(c.link == LinkState.connected ? 'ตัดการเชื่อมต่อ' : 'เชื่อมต่อ',
                    () => c.link == LinkState.connected ? c.disconnect() : pickGauge(context, c), th),
                const SizedBox(width: 6),
                _btn('DEMO', c.toggleDemo, th, active: c.demo),
                const SizedBox(width: 6),
                _btn('FLASH⚡', () {
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => FlashPage(c: c)));
                }, th),
                const SizedBox(width: 6),
                _btn('TUNE💻', () {
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => TunePage(c: c)));
                }, th),
                const SizedBox(width: 6),
                _iconBtn(Icons.settings, th, () {
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsPage(c: c)));
                }),
              ]),
              const SizedBox(height: 6),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: PageView(
                    controller: pc,
                    onPageChanged: (i) {
                      c.graphVisible = i == 2;
                      setState(() => page = i);
                    },
                    children: [_mainPage(th, blinkOn), _gridPage(th, blinkOn), _graphPage(th), _dragPage(th)],
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
              for (int i = 0; i < 4; i++)
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
              Text(const ['GAUGE', 'GRID', 'GRAPH', 'DRAG LOG'][page], style: const TextStyle(fontFamily: kFont, fontSize: 7, color: Colors.white54)),
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
  Widget _mainPage(AppTheme th, bool blinkOn) {
    final m = Cfg.i.main;
    return Row(children: [
      SizedBox(
        width: 168,
        child: Column(children: [
          for (int i = 0; i < 3; i++) Expanded(child: _slotTile(m[i], () => pickKey(context, m, i), blinkOn)),
        ]),
      ),
      const SizedBox(width: 8),
      Expanded(child: LayoutBuilder(builder: (_, cs) => _center(cs, th))),
      const SizedBox(width: 8),
      SizedBox(
        width: 168,
        child: Column(children: [
          for (int i = 3; i < 7; i++) Expanded(child: _slotTile(m[i], () => pickKey(context, m, i), blinkOn)),
        ]),
      ),
    ]);
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
        decoration: BoxDecoration(
          color: const Color(0xCC060606),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: th.c.withOpacity(0.85), width: 1.1),
          boxShadow: [BoxShadow(color: th.c.withOpacity(0.3), blurRadius: 10)],
        ),
        child: child,
      );

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
                  decoration: BoxDecoration(
                    color: c.dragSel == i ? th.c.withOpacity(0.3) : Colors.black45,
                    border: Border.all(color: c.dragSel == i ? th.c : Colors.white24, width: c.dragSel == i ? 1.6 : 1),
                    borderRadius: BorderRadius.circular(6),
                  ),
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
          decoration: BoxDecoration(
            color: Colors.black45,
            border: Border.all(color: kBad, width: 1.4),
            borderRadius: BorderRadius.circular(6),
            boxShadow: [BoxShadow(color: kBad.withOpacity(0.3), blurRadius: 8)],
          ),
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
          decoration: BoxDecoration(
            color: const Color(0xCC060606),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: th.c.withOpacity(0.85), width: 1.1),
            boxShadow: [BoxShadow(color: th.c.withOpacity(0.35), blurRadius: 10)],
          ),
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
        decoration: BoxDecoration(
          color: const Color(0xCC060606),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? col : Colors.white24, width: on ? 1.6 : 1.0),
          boxShadow: on ? [BoxShadow(color: col.withOpacity(0.4), blurRadius: 10)] : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_gNames[i], style: TextStyle(fontFamily: kFont, fontSize: 9, color: on ? col : Colors.white38)),
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

  /// สร้างช่องค่าจากคีย์: สี/บาร์/กระพริบตามกฎ
  Widget _slotTile(int key, VoidCallback onTap, bool blinkOn, {double vs = 30}) {
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
      case kBatt:
        vc = kBattRed;
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
      case kTemp:
      case kEot:
        alert = v != null && v >= cfg.tempWarn;
        break;
    }
    return StatTile(
      th: cfg.t, label: kd.name, unit: kd.unit, value: s, valueColor: vc,
      alert: alert, blinkOn: blinkOn, bar: bar, barColor: bc, onTap: onTap, valueSize: vs,
    );
  }

  // เกจกลาง: ความเร็ว (แตะสลับ GPS/ECU) อยู่กลางเกจ, RPM อยู่ใต้เกจ
  Widget _center(BoxConstraints cs, AppTheme th) {
    final cfg = Cfg.i;
    final w = cs.maxWidth, h = cs.maxHeight;
    const tileH = 80.0;
    final r = math.max(60.0, math.min(w / 2 - 4, (h - tileH - 8) / 1.74));
    final cx = w / 2, cy = r + 4;
    final rpm = c.t.rpm;
    final frac = rpm == null ? 0.0 : (rpm / kMaxRpm).clamp(0.0, 1.0).toDouble();
    final sp = c.shownSpeed;
    final tileW = math.min(math.max(r * 1.5, 150.0), 230.0);

    return Stack(children: [
      Positioned.fill(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: frac),
          duration: const Duration(milliseconds: 140),
          builder: (_, v, __) => CustomPaint(painter: GaugePainter(frac: v, r: r, th: th, shift: cfg.shift)),
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
                child: Text(sp == null ? '--' : sp.toStringAsFixed(0),
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
        left: cx - tileW / 2, width: tileW, top: cy + 0.74 * r, height: tileH,
        child: StatTile(
          th: th, label: 'RPM', unit: 'rpm', value: rpm == null ? '--' : rpm.toStringAsFixed(0),
          bar: frac, barColor: (p) => rpmColor(p * kMaxRpm, cfg.shift),
          mn: c.mnStr('rpm'), mx: c.mxStr('rpm'), bottomMargin: 0, valueSize: 26,
        ),
      ),
    ]);
  }

  Widget _chip(String s, Color col) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: col, shape: BoxShape.circle, boxShadow: [BoxShadow(color: col, blurRadius: 5)])),
          const SizedBox(width: 6),
          Text(s, style: const TextStyle(fontFamily: kFont, fontSize: 8.5)),
        ]),
      );

  Widget _btn(String s, VoidCallback f, AppTheme th, {bool active = false}) => InkWell(
        onTap: f,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active ? th.c.withOpacity(0.3) : Colors.black45,
            border: Border.all(color: th.c, width: 1.4),
            borderRadius: BorderRadius.circular(6),
            boxShadow: [BoxShadow(color: th.c.withOpacity(0.35), blurRadius: 8)],
          ),
          child: Text(s, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        ),
      );

  Widget _iconBtn(IconData ic, AppTheme th, VoidCallback f) => InkWell(
        onTap: f,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: Colors.black45,
            border: Border.all(color: th.c, width: 1.4),
            borderRadius: BorderRadius.circular(6),
            boxShadow: [BoxShadow(color: th.c.withOpacity(0.35), blurRadius: 8)],
          ),
          child: Icon(ic, size: 20, color: th.c),
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
  const SegBar({super.key, required this.frac, required this.color, this.n = 18});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 6,
      child: Row(children: [
        for (int i = 0; i < n; i++)
          Expanded(
            child: Builder(builder: (_) {
              final pos = (i + 0.5) / n;
              final lit = pos <= frac;
              final col = color(pos);
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: lit ? col : Colors.white.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(1.5),
                  boxShadow: lit ? [BoxShadow(color: col.withOpacity(0.6), blurRadius: 4)] : null,
                ),
              );
            }),
          ),
      ]),
    );
  }
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
  const StatTile({
    super.key, required this.th, required this.label, required this.unit, required this.value,
    this.valueColor, this.alert = false, this.blinkOn = false, this.bar, this.barColor,
    this.mn, this.mx, this.onTap, this.bottomMargin = 6, this.valueSize = 30,
  });

  @override
  Widget build(BuildContext context) {
    final active = alert && blinkOn; // กรอบกระพริบแดงเมื่อค่าเกินที่ตั้ง
    final col = active ? kBad : th.c;
    final vcol = alert ? kBad : (valueColor ?? Colors.white);
    final glow = alert ? kBad : (valueColor ?? th.c);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: bottomMargin),
        decoration: BoxDecoration(
          color: const Color(0xCC060606),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: col.withOpacity(active ? 1.0 : 0.85), width: active ? 2.0 : 1.1),
          boxShadow: [BoxShadow(color: col.withOpacity(active ? 0.85 : 0.35), blurRadius: active ? 18 : 10)],
        ),
        child: Stack(children: [
          Positioned(
            top: 0, left: 12,
            child: Container(
              width: 38, height: 3,
              decoration: BoxDecoration(
                color: col,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(2)),
                boxShadow: [BoxShadow(color: col, blurRadius: 6)],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 5),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: kFont, fontSize: 9, color: Colors.white54))),
                Text(unit, style: const TextStyle(fontFamily: kFont, fontSize: 8, color: Colors.white38)),
              ]),
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(value,
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

    // วงบางด้านใน + โซนแดงเริ่มที่ SHIFT RPM
    final r2 = r * 0.80;
    final rect2 = Rect.fromCircle(center: c, radius: r2);
    canvas.drawArc(rect2, start, sweep, false,
        Paint()
          ..color = Colors.white.withOpacity(0.2)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    final zs = (shift / kMaxRpm).clamp(0.0, 1.0).toDouble();
    if (zs < 1.0) {
      canvas.drawArc(rect2, start + sweep * zs, sweep * (1 - zs), false,
          Paint()
            ..color = const Color(0xFFFF2A2A)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.6
            ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 2));
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

    // เข็ม
    final ang = start + sweep * frac;
    final dir = Offset(math.cos(ang), math.sin(ang));
    final p1 = c + dir * (r * 0.36), p2 = c + dir * (r * 0.78);
    canvas.drawLine(p1, p2,
        Paint()
          ..color = th.c
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    canvas.drawLine(p1, p2,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round);
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
        decoration: BoxDecoration(
          color: Colors.black45,
          border: Border.all(color: widget.th.c, width: 1.4),
          borderRadius: BorderRadius.circular(6),
        ),
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

  @override
  Widget build(BuildContext context) {
    final cfg = Cfg.i;
    final th = cfg.t;
    final connected = widget.c.link == LinkState.connected;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        Image.asset('assets/bg.jpg', fit: BoxFit.cover),
        Container(color: Colors.black.withOpacity(0.7)),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Row(children: [
                IconButton(onPressed: () => Navigator.of(context).pop(), icon: Icon(Icons.arrow_back, color: th.c)),
                Text('SETTING', style: TextStyle(fontFamily: kFont, fontSize: 18, color: th.c, shadows: [Shadow(color: th.c, blurRadius: 10)])),
              ]),
              Expanded(
                child: SingleChildScrollView(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(children: [
                        _panel(th, 'ธีมสี', Wrap(spacing: 14, runSpacing: 14, children: [
                          for (int i = 0; i < kThemes.length; i++) _themeDot(i),
                        ])),
                        const SizedBox(height: 12),
                        _panel(
                          th,
                          'แจ้งเตือน',
                          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            _stepper('SHIFT LIGHT RPM', '${cfg.shift}', () => cfg.addShift(-1000), () => cfg.addShift(1000), th),
                            const SizedBox(height: 12),
                            _stepper('TEMP', '${cfg.tempWarn} °C', () => cfg.addTemp(-1), () => cfg.addTemp(1), th),
                            const SizedBox(height: 14),
                            _action('RESET MIN/MAX', Icons.refresh, th, () {
                              widget.c.resetMinMax();
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(duration: Duration(seconds: 1), content: Text('รีเซ็ตค่าต่ำสุด/สูงสุดแล้ว')));
                            }),
                          ]),
                        ),
                      ]),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _panel(
                        th,
                        'โลโก้ MFB-PRO บนบอร์ด (TEST1)',
                        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Center(
                            child: Container(
                              width: 220, height: 165,
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: th.c, width: 1.4),
                                boxShadow: [BoxShadow(color: th.c.withOpacity(0.4), blurRadius: 10)],
                              ),
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
                    ),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _stepper(String label, String value, VoidCallback dec, VoidCallback inc, AppTheme th) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontFamily: kFont, fontSize: 10, color: Colors.white70)),
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

  Widget _panel(AppTheme th, String title, Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xCC060606),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: th.c.withOpacity(0.8), width: 1.1),
          boxShadow: [BoxShadow(color: th.c.withOpacity(0.3), blurRadius: 10)],
        ),
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

  Widget _action(String s, IconData ic, AppTheme th, VoidCallback f, {bool enabled = true}) => Opacity(
        opacity: enabled ? 1 : 0.4,
        child: InkWell(
          onTap: enabled ? f : null,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(color: Colors.black45, border: Border.all(color: th.c, width: 1.3), borderRadius: BorderRadius.circular(6)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(ic, size: 16, color: th.c),
              const SizedBox(width: 6),
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
  Uint8List? commit; // ค่าที่กด ✅ บันทึกแล้ว (❌ = กลับไปค่านี้)
  String? binName, xdfName;
  XdfDef? xdf;
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

  void loadBin(String name, Uint8List b) {
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

  void loadXdf(String name, XdfDef d) {
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
    vals.forEach((rc, v) {
      final x = t.eq.inv(v, minRaw.toDouble(), maxRaw.toDouble());
      if (!x.isFinite) return;
      final raw = x.round().clamp(minRaw, maxRaw).toInt();
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
    final stem = dot > 0 ? n.substring(0, dot) : n;
    final d = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${stem}_MFB_${d.year}${p2(d.month)}${p2(d.day)}_${p2(d.hour)}${p2(d.minute)}.bin';
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

// ID กล่อง (5 ไบต์) -> ชื่อรุ่น  (คีย์เป็นเลขฐาน 16 เว้นวรรค ตัวใหญ่) ; เติมรุ่นอื่นเมื่อได้ ID จริง
const kEcuModels = <String, String>{
  '01 01 88 0D 01': 'Wave110i (2013–2017)',
};
String ecmHex(List<int>? e) => e == null ? '' : e.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
String? ecuModelName(List<int>? e) {
  if (e == null) return null;
  final m = kEcuModels[ecmHex(e)];
  if (m != null) return m;
  for (final o in kOriginals) {
    if (o.matches(e) && o.model.isNotEmpty) return o.model;
  }
  return null;
}

const kOriginals = <OrigPack>[
  OrigPack('K03-H01', 'assets/original/K03-H01.bin', 'assets/original/K03-H01.xdf',
      model: 'Wave110i (2013–2017)', ecuId: [0x01, 0x01, 0x88, 0x0D, 0x01], binKb: 64, xdfKb: 17),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: th.c, width: 1.3)),
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
                        decoration: BoxDecoration(
                          color: last ? th.c.withOpacity(0.18) : Colors.white.withOpacity(0.04),
                          border: Border.all(color: last ? th.c : Colors.white24, width: last ? 1.5 : 1),
                          borderRadius: BorderRadius.circular(10),
                        ),
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
  bool _dirty = false, _loaded = false;

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
    final same = rows == nr && cols == nc;
    rpm = nrpm;
    tps = ntps;
    src = best.title;
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

/// สี AFR: รวย (ต่ำ) = แดง .. 14.7 = เขียว .. บาง (สูง) = ฟ้า/น้ำเงิน
Color _afrColor(double v) {
  const stops = <Color>[Color(0xFFD81B3C), Color(0xFFF0961E), Color(0xFF2ED278), Color(0xFF2896E8), Color(0xFF505ADC)];
  final t = ((v - 11.5) / (16.5 - 11.5)).clamp(0.0, 1.0).toDouble();
  final p = t * (stops.length - 1);
  final k = p.floor().clamp(0, stops.length - 2).toInt();
  return Color.lerp(stops[k], stops[k + 1], p - k)!;
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
            decoration: BoxDecoration(
              color: active ? col.withOpacity(0.22) : Colors.black45,
              border: Border.all(color: col, width: 1.3),
              borderRadius: BorderRadius.circular(8),
            ),
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
                decoration: BoxDecoration(
                  color: const Color(0xCC060606),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: th.c.withOpacity(0.85), width: 1.1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: log.ready
                      ? LayoutBuilder(builder: (_, cs) {
                          _sz = Size(cs.maxWidth, cs.maxHeight);
                          return GestureDetector(
                            onTapUp: (d) => _tapCell(d.localPosition),
                            child: CustomPaint(size: Size.infinite, painter: _AfrPainter(log, th)),
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
                const Text('11.5 รวย · 14.7 · 16.5 บาง', style: TextStyle(fontSize: 10.5, color: Colors.white60)),
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

  static const double hw = 40, hh = 18;
  /// (x0, y0, cw, ch) ของช่องข้อมูล
  static (double, double, double, double) geom(Size s, int rows, int cols) =>
      (hw, hh, (s.width - hw) / cols, (s.height - hh) / rows);

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
  const TunePage({super.key, required this.c});
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
  int stepMul = 1;
  double yaw = -0.85, pitch = 0.62, zoom = 1, _zoom0 = 1;
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
  }

  @override
  void dispose() {
    _spin?.cancel();
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

  double _step(XdfTable t) => t.eq.lsb * stepMul;

  /// ค่าในช่อง "ค่า" (ว่าง = null) รับเลขฐาน 16 แบบ 0x41 ได้
  double? get _amt {
    final v = amtCtl.text.trim().replaceAll(',', '.');
    if (v.isEmpty) return null;
    if (v.toLowerCase().startsWith('0x')) return int.tryParse(v.substring(2), radix: 16)?.toDouble();
    return double.tryParse(v);
  }

  Future<void> _bump(int dir) async {
    final t = s.table;
    if (t == null || !_needSel() || !await _canEdit(t)) return;
    final a = _amt;
    final st = (a != null && a != 0) ? a.abs() : _step(t);
    s.write(t, {for (final rc in _cells) rc: s.val(t, rc.$1, rc.$2) + dir * st}, '${dir > 0 ? '+' : '−'} ${_numStr(st)}', merge: true);
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
    if (t == null || !_needSel() || !await _canEdit(t)) return;
    final p = _amt ?? await _askNum('เปลี่ยนเป็น %', 'เช่น 5 = เพิ่ม 5% , -3 = ลด 3%');
    if (p == null) return;
    final n = s.write(t, {for (final rc in _cells) rc: s.val(t, rc.$1, rc.$2) * (1 + p / 100)}, '% ${_numStr(p)}');
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
  Future<void> _interp(int mode) async {
    final t = s.table;
    final g = _sel;
    if (t == null || g == null || !_needSel() || !await _canEdit(t)) return;
    final (r0, c0, r1, c1) = g;
    if ((mode == 0 || mode == 2) && c1 == c0) {
      _snack('เลือกอย่างน้อย 2 คอลัมน์');
      return;
    }
    if ((mode == 1 || mode == 2) && r1 == r0) {
      _snack('เลือกอย่างน้อย 2 แถว');
      return;
    }
    final px = _axisPos(t, true), py = _axisPos(t, false);
    double fx(int c) => (px[c] - px[c0]) / (px[c1] - px[c0]);
    double fy(int r) => (py[r] - py[r0]) / (py[r1] - py[r0]);
    final out = <(int, int), double>{};
    final v00 = s.val(t, r0, c0), v01 = s.val(t, r0, c1), v10 = s.val(t, r1, c0), v11 = s.val(t, r1, c1);
    for (int r = r0; r <= r1; r++) {
      for (int c = c0; c <= c1; c++) {
        double v;
        if (mode == 0) {
          final a = s.val(t, r, c0), b = s.val(t, r, c1), f = fx(c);
          v = a + (b - a) * f;
        } else if (mode == 1) {
          final a = s.val(t, r0, c), b = s.val(t, r1, c), f = fy(r);
          v = a + (b - a) * f;
        } else {
          final u = fx(c), w = fy(r);
          v = v00 * (1 - u) * (1 - w) + v01 * u * (1 - w) + v10 * (1 - u) * w + v11 * u * w;
        }
        out[(r, c)] = v;
      }
    }
    final n = s.write(t, out, const ['ไล่ค่า X', 'ไล่ค่า Y', 'ไล่ค่า XY'][mode]);
    if (n == 0) _snack('ค่าไม่เปลี่ยน');
  }

  /// ~ smooth: แต่ละช่องที่เลือก = ค่าเฉลี่ยของตัวเองกับช่องรอบข้าง 8 ช่อง (อ่านค่าเดิมก่อนแก้ทั้งหมด)
  Future<void> _smooth() async {
    final t = s.table;
    if (t == null || !_needSel() || !await _canEdit(t)) return;
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
      if (n > 0) out[rc] = sum / n;
    }
    final k = s.write(t, out, '~ smooth ${out.length} ช่อง');
    if (k == 0) _snack('ค่าไม่เปลี่ยน (เรียบอยู่แล้ว หรือน้อยกว่า 1 ขั้นของข้อมูล)');
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
    final n = s.write(t, out, 'วาง ${rows}×$cols');
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
    if (t == null || !_needSel() || !await _canEdit(t)) return;
    final cells = _cells;
    final avg = cells.map((rc) => s.val(t, rc.$1, rc.$2)).reduce((a, b) => a + b) / cells.length;
    final v = (ask ? null : _amt) ??
        await _askNum('ใส่ค่า (${cells.length} ช่อง)', t.outType == 3 ? 'เช่น 65 หรือ 0x41' : 'ค่าใหม่', initial: t.fmt(avg));
    if (v == null) return;
    s.write(t, {for (final rc in cells) rc: v}, '= ${_numStr(v)}');
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

  bool get _hasEdits => s.changedBytes > 0;

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
      s.loadXdf(f.$1, d);
      setState(_resetView);
      _snack('XDF: ${d.tables.length} ตาราง (2D ${d.tables.where((t) => t.is2D).length}) + ${d.flags.length} FLAGS');
    } on XdfError catch (e) {
      await _showXdfError(e.msg);
    } catch (e) {
      _snack('เปิดไฟล์ไม่สำเร็จ: $e');
    }
  }

  /// เลือก BIN + XDF ต้นฉบับ (ORIGINAL) ที่มากับแอพ — จับคู่ตาม ID กล่อง, ไม่แฟลชอัตโนมัติ
  Future<void> _openOriginals() async {
    final th = Cfg.i.t;
    final ecm = c.t.fl?.ecm; // ID กล่องที่ต่ออยู่ (null = ยังไม่ต่อ/ยังอ่านไม่ได้)
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
          list.sort((a, b) => (a.model.isEmpty ? a.name : a.model).compareTo(b.model.isEmpty ? b.name : b.model)); // เรียงตามรุ่นรถ

          Widget hbtn(IconData ic, Color bc, Color fc, VoidCallback onTap) => InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(color: const Color(0xFF12161C), border: Border.all(color: bc), borderRadius: BorderRadius.circular(12)),
                  child: Icon(ic, color: fc, size: 20),
                ),
              );
          Widget tabBtn(String t, int i) => Expanded(
                child: InkWell(
                  onTap: () => setM(() => tab = i),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: tab == i ? th.c.withOpacity(0.18) : const Color(0xFF12161C),
                      border: Border.all(color: tab == i ? th.c : Colors.white24, width: tab == i ? 1.4 : 1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(t, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: tab == i ? Colors.white : Colors.white60)),
                  ),
                ),
              );
          Widget card(OrigPack o) {
            final on = o.matches(ecm);
            return InkWell(
              onTap: () => Navigator.of(dctx).pop(o),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                margin: const EdgeInsets.only(bottom: 9),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: on ? const Color(0xFF0E1D16) : const Color(0xFF0F1013),
                  border: Border.all(color: on ? kGreen.withOpacity(0.7) : Colors.white12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      RichText(
                        text: TextSpan(style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white), children: [
                          TextSpan(text: o.model.isEmpty ? o.name : o.model.split(' (').first),
                          TextSpan(text: '  ${o.name}', style: const TextStyle(fontSize: 14, color: Colors.white70, fontFeatures: [FontFeature.tabularFigures])),
                        ]),
                      ),
                      const SizedBox(height: 3),
                      Text('BIN ${o.binKb} KB · XDF ${o.xdfKb} KB', style: const TextStyle(fontSize: 12.5, color: Colors.white54)),
                    ]),
                  ),
                  if (o.ecuId != null)
                    Container(
                      margin: const EdgeInsets.only(left: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                      decoration: BoxDecoration(
                        border: Border.all(color: on ? kGreen.withOpacity(0.7) : Colors.white24),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(ecmHex(o.ecuId), style: TextStyle(fontSize: 11, color: on ? kGreen : Colors.white54)),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(on ? Icons.check : Icons.chevron_right, color: on ? kGreen : th.c, size: 20),
                  ),
                ]),
              ),
            );
          }

          return Dialog(
            backgroundColor: const Color(0xFF0C0D10),
            insetPadding: EdgeInsets.symmetric(horizontal: sz.width * 0.1, vertical: 26),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: th.c, width: 1.2)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // หัว
              Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF1A1114)))),
                child: Row(children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(color: const Color(0xFF15090B), border: Border.all(color: th.c), borderRadius: BorderRadius.circular(14)),
                    child: Icon(Icons.memory, color: th.c, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('เลือก BIN/XDF จากแอป', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      RichText(
                        text: const TextSpan(style: TextStyle(fontSize: 12.5, color: Colors.white60), children: [
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
                  const SizedBox(width: 8),
                  hbtn(Icons.close, th.c, const Color(0xFFFF6B6E), () => Navigator.of(dctx).pop()),
                ]),
              ),
              // แท็บ
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                child: Row(children: [tabBtn('ไฟล์สำหรับรถคันนี้', 0), const SizedBox(width: 12), tabBtn('ไฟล์ทั้งหมด', 1)]),
              ),
              // ช่องค้นหา (เมื่อเปิด)
              if (searching)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                  child: TextField(
                    controller: qCtl,
                    autofocus: true,
                    style: const TextStyle(fontSize: 14),
                    onChanged: (v) => setM(() => q = v),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'ค้นหารุ่น / รหัส ECU',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      filled: true,
                      fillColor: const Color(0xFF12161C),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: th.c.withOpacity(0.5))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.white24)),
                    ),
                  ),
                ),
              // บรรทัดสรุป + สถานะการต่อ
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 2, 22, 10),
                child: Row(children: [
                  Expanded(child: Text('แสดง ${list.length}/${kOriginals.length} ชุด · เรียงตาม รุ่นรถ', style: const TextStyle(fontSize: 13, color: Colors.white54))),
                  Text(
                    ecm != null ? '● ต่อ ECU: ${ecuModelName(ecm) ?? 'ไม่ทราบรุ่น'} · ${ecmHex(ecm)}' : '● ยังไม่เชื่อมต่อ ECU',
                    style: TextStyle(fontSize: 12.5, color: ecm != null ? kGreen : Colors.white38),
                  ),
                ]),
              ),
              // รายการ
              Flexible(
                child: list.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(tab == 0 ? Icons.usb_off : Icons.folder_off, color: Colors.white24, size: 40),
                          const SizedBox(height: 12),
                          Text(
                            tab == 0
                                ? (ecm == null ? 'กรุณาเชื่อมต่อ ECU แล้วกดสแกน ECU\nหรือแตะ "ไฟล์ทั้งหมด" เพื่อดูทุกชุด' : 'ยังไม่มีไฟล์ในแอปที่ตรงกับ ID กล่องนี้\n(${ecmHex(ecm)})')
                                : (q.trim().isEmpty ? 'ยังไม่มีไฟล์ฝังในแอป' : 'ไม่พบไฟล์ที่ค้นหา'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 14, color: Colors.white54, height: 1.5),
                          ),
                          if (tab == 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 14),
                              child: TextButton(onPressed: () => setM(() => tab = 1), child: Text('ดูไฟล์ทั้งหมด ›', style: TextStyle(color: th.c2))),
                            ),
                        ]),
                      )
                    : ListView(padding: const EdgeInsets.fromLTRB(20, 2, 20, 16), shrinkWrap: true, children: [for (final o in list) card(o)]),
              ),
            ]),
          );
        });
      },
    );
    if (p == null || !mounted) return;
    if (_hasEdits && !await _confirm('เปิดไฟล์ ORIGINAL', 'ค่าที่แก้ใน BIN ปัจจุบันจะหายไป', ok: 'เปิด ${p.name}')) return;
    try {
      final bin = (await rootBundle.load(p.bin)).buffer.asUint8List();
      final xb = (await rootBundle.load(p.xdf)).buffer.asUint8List();
      final d = XdfDef.parse(Uint8List.fromList(xb));
      s.loadBin(p.binName, Uint8List.fromList(bin));
      s.loadXdf(p.xdfName, d);
      setState(_resetView);
      _snack('เปิด ${p.name} แล้ว — เลือกตารางจากเมนูตารางจูน');
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
    try {
      final b = await BinLib.i.read(e);
      s.loadBin('${e.name}.bin', b);
      setState(_resetView);
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
    final fname = s.newFileName();
    final stem = fname.toLowerCase().endsWith('.bin') ? fname.substring(0, fname.length - 4) : fname;
    final tc = TextEditingController(text: stem);
    Widget box(Color col, String head, String body) => Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: col.withOpacity(0.12),
            border: Border.all(color: col, width: 1.2),
            borderRadius: BorderRadius.circular(8),
          ),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: th.c, width: 1.2)),
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
              Text(
                  names.isEmpty
                      ? 'ยังไม่มีการแก้ไข (ไฟล์จะเหมือนต้นฉบับ)'
                      : 'แก้ไข ${s.changedBytes} ไบต์ ใน ${names.length} รายการ: ${names.take(8).join(', ')}${names.length > 8 ? ' …' : ''}',
                  style: const TextStyle(fontSize: 12.5)),
              box(kAmber, 'CHECKSUM (ไม่แก้อัตโนมัติ)',
                  'ผลรวมไบต์ของไฟล์ตอนนี้ = 0x${sum8.toRadixString(16).toUpperCase().padLeft(2, '0')}${sum8 == 0 ? ' (ผ่าน)' : ' (ยังไม่ผ่าน)'}\n'
                      'เกจเลือก Start Offset และแก้ checksum ให้เองตามขนาดไฟล์ ตอนกด FLASH ที่เกจ (ตอนนี้รองรับ 48 KB และ 64 KB)'),
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
        await BinLib.i.save(name, bytes);
        _snack('บันทึกเข้าคลังแล้ว: $name — แฟลชได้ที่หน้า FLASH⚡');
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

  _Proj3 _proj3(XdfTable t, double lo, double hi) => _Proj3(_v3, t.rows, t.cols, lo, hi, yaw, pitch, zoom);

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
  // 2 นิ้ว: ซูม
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
        setState(() => zoom = (_zoom0 * (ps[0] - ps[1]).distance / _pinch0).clamp(0.4, 4.0).toDouble());
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
          s.write(t, {for (final e in _dragBase.entries) e.key: e.value + dv}, 'ลากจุด 3D', merge: true);
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
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: Column(children: [
              _topBar(th),
              SizedBox(
                height: 17,
                child: Row(children: [
                  Expanded(
                    child: Text('BIN: ${s.binName ?? '-'}     XDF: ${s.xdfName ?? '-'}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
                  ),
                  if (s.ready && t != null && t.valid) Text(_selInfo(t), style: const TextStyle(fontSize: 10.5, color: Colors.white60)),
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
            decoration: BoxDecoration(
              color: active ? cc.withOpacity(0.3) : Colors.black45,
              border: Border.all(color: cc, width: 1.3),
              borderRadius: BorderRadius.circular(8),
              boxShadow: active ? [BoxShadow(color: cc.withOpacity(0.4), blurRadius: 8)] : null,
            ),
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

  Future<void> _openAfr() async {
    AfrLog.i.attach(c);
    AfrLog.i.syncAxes(s);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AfrLogPage(c: c)));
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: th.c, width: 1.4)),
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
                      hintText: t == null ? 'ใส่ค่าที่ต้องการ' : 'ใส่ค่า (STEP ${_numStr(_step(t))})',
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
          PopupMenuItem(value: 1, child: _menuRow(Icons.folder_special, 'เลือก BIN/XDF จากแอป', 'ไฟล์ ORIGINAL: ${kOriginals.map((o) => o.name).join(', ')}', kGreen)),
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
          decoration: BoxDecoration(color: Colors.black45, border: Border.all(color: th.c, width: 1.3), borderRadius: BorderRadius.circular(8)),
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
          decoration: BoxDecoration(
            color: const Color(0xE60E0E14),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white24, width: 1.2),
          ),
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
                decoration: BoxDecoration(
                  color: th.c.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: th.c2.withOpacity(0.6)),
                  boxShadow: [BoxShadow(color: th.c.withOpacity(0.4), blurRadius: 12)],
                ),
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
        'เลือก BIN + XDF จากเมนูไฟล์ เพื่อเริ่มแก้ไข',
        'เลือก BIN/XDF จากแอป',
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
    final frame = BoxDecoration(
      color: const Color(0xCC060606),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: th.c.withOpacity(0.85), width: 1.1),
      boxShadow: [BoxShadow(color: th.c.withOpacity(0.3), blurRadius: 10)],
    );
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
                            v: v, lo: lo, hi: hi, yaw: yaw, pitch: pitch, zoom: zoom, lr: lp.$1, lc: lp.$2, th: th,
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
                  sel: _sel, lr: lp.$1, lc: lp.$2, th: th, rev: s.rev,
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: th.c, width: 1.2)),
              child: StatefulBuilder(builder: (dctx, setM) {
                Widget section(IconData ic, String title, int n, bool open, VoidCallback toggle, List<Widget> kids) => Column(children: [
                      InkWell(
                        onTap: toggle,
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 5),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: th.c.withOpacity(0.6)),
                          ),
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
                        decoration: BoxDecoration(
                          color: on ? th.c.withOpacity(0.2) : Colors.white.withOpacity(0.03),
                          border: Border.all(color: on ? th.c : Colors.white12, width: on ? 1.5 : 1),
                          borderRadius: BorderRadius.circular(8),
                        ),
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
                          else if (t.valid && s.tableChanged(t))
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
                            decoration: BoxDecoration(color: Colors.white.withOpacity(0.03), border: Border.all(color: Colors.white12), borderRadius: BorderRadius.circular(8)),
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
          decoration: BoxDecoration(
            color: on ? th.c.withOpacity(0.35) : Colors.white10,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: on ? th.c : Colors.white30),
          ),
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
  _GridPainter({
    required this.s, required this.t, required this.v, required this.lo, required this.hi,
    required this.rowL, required this.colL, required this.sx, required this.sy,
    required this.cw, required this.ch, required this.hw, required this.hh,
    required this.sel, required this.lr, required this.lc, required this.th, required this.rev,
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
        final col = _heat(hi > lo ? (x - lo) / span : 0.5);
        fill.color = col;
        canvas.drawRect(rect.deflate(cw > 16 ? 0.5 : 0.2), fill);
        if (showTxt) {
          _TP.center(canvas, _TP.get(t.fmt(x), fs, const Color(0xFF000000), maxW: cw), rect.center);   // ตัวเลขสีดำทุกช่อง
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

// ---------- การฉายภาพ 3D (ใช้ร่วมกันระหว่างวาด และหาจุดที่นิ้วแตะ) ----------
class _Proj3 {
  static const zh = 1.5; // ความสูงแกน Z เทียบความกว้างฐาน
  static const camD = 6.0; // ระยะกล้อง: มีระยะลึก ใกล้ใหญ่กว่า
  final int nr, nc;
  final double lo, span, sc, ox, oy, cyw, syw, cp, sp;
  _Proj3(Size size, this.nr, this.nc, this.lo, double hi, double yaw, double pitch, double zoom)
      : span = hi > lo ? hi - lo : 1.0,
        sc = math.min(size.width * 0.36, size.height * 0.72) * zoom,
        ox = size.width * 0.50,
        oy = size.height * 0.56,
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
  _SurfacePainter({
    this.spin = false,
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
    final P = _Proj3(size, nr, nc, lo, hi, yaw, pitch, zoom);
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
// เกจเลือก Start Offset / ตำแหน่ง checksum เองตามขนาดไฟล์ (kFlashProfiles) และแก้ checksum ให้ก่อนแฟลช
// เกจต้องเปิดหน้าเตรียมแฟลชอยู่ (SETUP > CONNECT APP > ECU FLASH) ถึงจะรับไฟล์ได้

class BinEntry {
  String name;
  int size, sum16, ck8;
  DateTime time;
  String offset, cks; // ค่าที่ใช้แฟลชครั้งล่าสุด (จำไว้ให้ ไม่ได้ใส่อัตโนมัติจากที่อื่น)
  bool fix;
  BinEntry(this.name, this.size, this.sum16, this.ck8, this.time, {this.offset = '', this.cks = '', this.fix = false});

  static BinEntry make(String name, Uint8List b, {BinEntry? keep}) {
    int s = 0;
    for (final x in b) {
      s += x;
    }
    return BinEntry(name, b.length, s & 0xFFFF, s & 0xFF, DateTime.now(),
        offset: keep?.offset ?? '', cks: keep?.cks ?? '', fix: keep?.fix ?? false);
  }

  Map<String, dynamic> toJson() =>
      {'n': name, 's': size, 'sum': sum16, 'ck': ck8, 't': time.millisecondsSinceEpoch, 'o': offset, 'c': cks, 'f': fix};

  static BinEntry? fromJson(dynamic j) {
    try {
      return BinEntry(j['n'] as String, (j['s'] as num).toInt(), (j['sum'] as num).toInt(), (j['ck'] as num).toInt(),
          DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()),
          offset: (j['o'] as String?) ?? '', cks: (j['c'] as String?) ?? '', fix: (j['f'] as bool?) ?? false);
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

  Future<BinEntry> save(String name, Uint8List bytes) async {
    await load();
    name = clean(name);
    final d = await _d();
    await _f(d, name).writeAsBytes(bytes, flush: true);
    BinEntry? old;
    for (final e in items) {
      if (e.name == name) old = e;
    }
    items.removeWhere((e) => e.name == name);
    final e = BinEntry.make(name, bytes, keep: old);
    items.insert(0, e);
    await _saveIdx();
    notifyListeners();
    return e;
  }

  Future<Uint8List> read(BinEntry e) async => _f(await _d(), e.name).readAsBytes();

  Future<void> remove(BinEntry e) async {
    final d = await _d();
    try {
      await _f(d, e.name).delete();
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
      8: 'เขียนไม่สำเร็จ (ส่งซ้ำครบแล้ว)',
      9: 'กล่องตอบที่อยู่ไม่ตรง',
      10: 'ตรวจสอบหลังเขียนไม่ผ่าน',
      11: 'เกจอ่านไฟล์ไม่ได้',
      12: 'พื้นที่ในเกจไม่พอ',
      13: 'เกจกำลังทำงานอยู่',
      14: 'Start Offset / ขนาดไฟล์ไม่ถูกต้อง',
      15: 'รับไฟล์ไม่สำเร็จ',
      16: 'สาย K-Line หลุด',
      17: 'ขนาดไฟล์นี้ยังแฟลชไม่ได้ (รองรับ 48 / 64 KB)',
      18: 'แก้ checksum ในเกจไม่สำเร็จ',
    }[e] ??
    'error $e';

/// ค่าแฟลชตามขนาดไฟล์ (ต้องตรงกับ F_PROFS ใน EcuFlash.h ของเกจ) : ขนาด -> (start offset, ตำแหน่ง checksum)
const Map<int, (int, int)> kFlashProfiles = {
  0x10000: (0x8000, 0x0000), // 64 KB
  0x0C000: (0x4000, 0xFFFF), // 48 KB
};

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
                    subtitle: Text('${(e.size / 1024).toStringAsFixed(1)} KB · ${_dateStr(e.time)}', style: const TextStyle(fontSize: 11)),
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
class FlashPage extends StatefulWidget {
  final GaugeController c;
  const FlashPage({super.key, required this.c});
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

  void _rb() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    lib.addListener(_rb);
    c.addListener(_rb);
    Cfg.i.addListener(_rb);
    lib.load();
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
    if (!kFlashProfiles.containsKey(d.length)) return;
    setState(() {
      working = true;
      msg = null;
      up = 0;
    });
    await c.clearFlash();
    final err = await c.sendBin(d, (v) {
      if (mounted) setState(() => up = v);
    }, name: nm);
    if (!mounted) return;
    setState(() {
      working = false;
      up = null;
      msg = err;
    });
    _snack(err ?? 'ส่งไฟล์แล้ว ✓ กดปุ่ม FLASH ที่เกจเพื่อเริ่มแฟลช');
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
                    child: Text('แก้ตารางที่หน้า TUNE💻 แล้วบันทึกเข้าคลัง → เลือกไฟล์ → ส่งไปเกจ → กด FLASH ที่เกจ',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: Colors.white54)),
                  ),
                ]),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(flex: 4, child: _frame(th, _libPanel(th))),
                  const SizedBox(width: 8),
                  Expanded(flex: 5, child: _frame(th, _flashPanel(th))),
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
        decoration: BoxDecoration(
          color: const Color(0xCC060606),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: th.c.withOpacity(0.85), width: 1.1),
          boxShadow: [BoxShadow(color: th.c.withOpacity(0.3), blurRadius: 10)],
        ),
        child: child,
      );

  Widget _btn(AppTheme th, String s, VoidCallback? f, {IconData? ic, Color? col, bool big = false}) {
    final cc = col ?? th.c;
    return Opacity(
      opacity: f == null ? 0.4 : 1,
      child: InkWell(
        onTap: f,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: big ? 12 : 7),
          decoration: BoxDecoration(
            color: big ? cc.withOpacity(0.25) : Colors.black45,
            border: Border.all(color: cc, width: 1.4),
            borderRadius: BorderRadius.circular(8),
            boxShadow: big && f != null ? [BoxShadow(color: cc.withOpacity(0.45), blurRadius: 12)] : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            if (ic != null) ...[Icon(ic, size: big ? 20 : 16, color: cc), const SizedBox(width: 6)],
            Text(s, style: TextStyle(fontSize: big ? 15 : 12, fontWeight: FontWeight.bold)),
          ]),
        ),
      ),
    );
  }

  Widget _libPanel(AppTheme th) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text('คลังไฟล์ที่จูนไว้', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: th.c2)),
        const Spacer(),
        _btn(th, 'เลือกจากมือถือ', working || (c.t.fl?.busy ?? false) ? null : _pickPhone, ic: Icons.phone_android),
      ]),
      if (extName != null)
        Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          decoration: BoxDecoration(
            color: th.c.withOpacity(0.2),
            border: Border.all(color: th.c, width: 1.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Icon(Icons.phone_android, size: 20, color: th.c2),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(extName!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                Text('${((data?.length ?? 0) / 1024).toStringAsFixed(1)} KB · จากมือถือ (ไม่ได้เก็บเข้าคลัง)',
                    style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
              ]),
            ),
          ]),
        ),
      const SizedBox(height: 8),
      Expanded(
        child: lib.items.isEmpty
            ? const Center(
                child: Text('คลังยังว่าง\nบันทึกจากหน้า TUNE💻 (ไฟล์ > บันทึกเข้าคลังไฟล์)\nหรือกด "เลือกจากมือถือ" เพื่อแฟลชไฟล์ในเครื่องโดยตรง',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 12.5)))
            : ListView(children: [
                for (final e in lib.items)
                  InkWell(
                    onTap: working || (c.t.fl?.busy ?? false) ? null : () => _select(e),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 5),
                      padding: const EdgeInsets.fromLTRB(8, 6, 2, 6),
                      decoration: BoxDecoration(
                        color: sel == e ? th.c.withOpacity(0.2) : Colors.white.withOpacity(0.03),
                        border: Border.all(color: sel == e ? th.c : Colors.white12, width: sel == e ? 1.5 : 1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(children: [
                        Icon(Icons.memory, size: 20, color: th.c2),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                            Text(
                                '${(e.size / 1024).toStringAsFixed(1)} KB · ${_dateStr(e.time)} · ผลรวม ${_hx(e.ck8)}${e.ck8 == 0 ? ' ✓' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
                          ]),
                        ),
                        PopupMenuButton<int>(
                          color: const Color(0xFF16161D),
                          icon: const Icon(Icons.more_vert, size: 18, color: Colors.white54),
                          onSelected: (v) => _entryMenu(e, v),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 1, child: Text('เปลี่ยนชื่อ')),
                            PopupMenuItem(value: 2, child: Text('ส่งออกไฟล์…')),
                            PopupMenuItem(value: 3, child: Text('ลบ', style: TextStyle(color: kBad))),
                          ],
                        ),
                      ]),
                    ),
                  ),
              ]),
      ),
    ]);
  }

  Widget _row(String a, String b, {Color? col}) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 92, child: Text(a, style: const TextStyle(fontSize: 12, color: Colors.white54))),
          Expanded(child: Text(b, style: TextStyle(fontSize: 12.5, color: col ?? Colors.white))),
        ]),
      );

  Widget _flashPanel(AppTheme th) {
    final f = c.t.fl;
    final connected = c.link == LinkState.connected && !c.demo;
    final busy = f?.busy ?? false;
    final d = data;
    final prof = d == null ? null : kFlashProfiles[d.length];
    final sum16 = d?.fold<int>(0, (a, x) => (a + x) & 0xFFFF);
    final sum8 = (sum16 ?? 0) & 0xFF;
    final onGauge = f != null && d != null && f.fileSize == d.length && f.fileSum == sum16;
    final canSend = connected && f != null && f.prep && !busy && f.phase != 2 && !working && d != null && prof != null;

    String gaugeTxt;
    Color gaugeCol;
    if (c.demo) {
      gaugeTxt = 'ปิด DEMO ก่อน แล้วเชื่อมต่อเกจ';
      gaugeCol = kAmber;
    } else if (!connected) {
      gaugeTxt = 'ยังไม่ได้เชื่อมต่อเกจ (กดเชื่อมต่อที่หน้าหลัก)';
      gaugeCol = kBad;
    } else if (f == null) {
      gaugeTxt = 'เฟิร์มแวร์เกจยังไม่รองรับ (ต้อง FW 1.0.10 ขึ้นไป)';
      gaugeCol = kBad;
    } else if (!f.prep) {
      gaugeTxt = 'เปิดที่เกจ: SETUP > CONNECT APP > ECU FLASH';
      gaugeCol = kAmber;
    } else {
      gaugeTxt = 'อยู่หน้าเตรียมแฟลช ✓';
      gaugeCol = kGreen;
    }

    // ความคืบหน้า (ส่งไฟล์ / แฟลชที่เกจ — แอพดูอย่างเดียว)
    String phase = '';
    double? prog;
    String sizeTxt = '', timeTxt = '';
    if (up != null) {
      phase = 'กำลังส่งไฟล์ไปเกจ';
      prog = up;
      final n = d?.length ?? 0;
      sizeTxt = '${(n * up! / 1024).round()}/${(n / 1024).round()} KB';
    } else if (f != null && f.prep) {
      phase = flashPhaseText(f.phase);
      if (busy || f.phase >= 9) {
        prog = f.phase == 9 ? 1.0 : (f.total > 0 ? f.done / f.total : f.pct / 100);
        sizeTxt = '${((f.phase == 9 ? f.total : f.done) / 1024).round()}/${(f.total / 1024).round()} KB';
        timeTxt = _mmss(f.elapsed);
      }
    }
    final phaseCol = f?.phase == 9 ? kGreen : (f?.phase == 10 ? kBad : Colors.white);

    String fileTxt = '';
    Color fileCol = kGreen;
    if (d != null) {
      if (prof == null) {
        fileTxt = 'ขนาด ${(d.length / 1024).toStringAsFixed(1)} KB ยังแฟลชไม่ได้ (ตอนนี้รองรับ 48 KB และ 64 KB)';
        fileCol = kAmber;
      } else {
        fileTxt = '${(d.length / 1024).round()} KB → เกจใช้ Start Offset ${_hx(prof.$1, 4)} · checksum ที่ ${_hx(prof.$2, 4)}\n'
            '${sum8 == 0 ? 'checksum ผ่านแล้ว' : 'checksum ยังไม่ผ่าน (ผลรวม ${_hx(sum8)}) — เกจจะแก้ให้อัตโนมัติก่อนแฟลช'}';
        fileCol = sum8 == 0 ? kGreen : kAmber;
      }
    }

    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('สถานะเกจ', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: th.c2)),
        const SizedBox(height: 4),
        _row('หน้าเกจ', gaugeTxt, col: gaugeCol),
        if (f != null && f.prep) ...[
          _row('กล่อง ECU', '${flashEcuText(f.ecu)}${f.ecm != null ? '  ·  ID ${ecmHex(f.ecm)}' : ''}',
              col: (f.ecu == 2 || f.ecu == 3) ? kGreen : ((f.ecu == 5 || f.ecu == 6) ? kAmber : Colors.white70)),
          if (f.ecm != null)
            _row('รุ่น', ecuModelName(f.ecm) ?? 'ไม่ทราบรุ่น (ID ${ecmHex(f.ecm)})',
                col: ecuModelName(f.ecm) != null ? th.c2 : Colors.white54),
          _row('ไฟล์ในเกจ',
              f.fileSize > 0 ? '${(f.fileSize / 1024).toStringAsFixed(1)} KB · sum ${_hx(f.fileSum, 4)}${onGauge ? ' (ตรงกับไฟล์ที่เลือก)' : ''}' : 'ยังไม่มี'),
          _row('FLASHCOUNT', f.count == null ? '-- (อ่านได้เมื่อกล่องอยู่สถานะ OK)' : '${f.count}${f.phase == 9 && f.count0 != null && f.count! > f.count0! ? '  (เดิม ${f.count0} → แฟลชเข้ากล่องแล้ว ✓)' : ''}',
              col: f.count == null ? Colors.white54 : (f.phase == 9 && f.count0 != null && f.count! > f.count0! ? kGreen : Colors.white)),
          if (f.batt != null) _row('แบต (ล่าสุด)', '${f.batt!.toStringAsFixed(1)} V', col: f.batt! < 12.0 ? kAmber : Colors.white),
        ],
        const Divider(color: Colors.white12, height: 16),
        Text(extName != null ? 'ไฟล์: $extName (จากมือถือ)' : (sel == null ? 'เลือกไฟล์จากคลัง หรือจากมือถือ' : 'ไฟล์: ${sel!.name}'),
            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: th.c2)),
        const SizedBox(height: 6),
        if (d != null) Text(fileTxt, style: TextStyle(fontSize: 12, color: fileCol, height: 1.35)),
        const SizedBox(height: 10),
        _btn(th, onGauge ? 'ส่งไฟล์ไปเกจอีกครั้ง' : 'ส่งไฟล์ไปเกจ', canSend ? _send : null, ic: Icons.send_to_mobile, big: true),
        const SizedBox(height: 6),
        const Text(
            'ส่งไฟล์แล้วกดปุ่ม FLASH ที่หน้าเกจเพื่อเริ่มแฟลช (แอพสั่งแฟลชไม่ได้)\n'
            'เกจจะไม่ให้กด FLASH ถ้าไม่พบกล่อง ECU · ลบไฟล์ในเกจได้ที่ปุ่ม "ลบไฟล์" บนเกจ',
            style: TextStyle(fontSize: 11.5, color: Colors.white54, height: 1.35)),
        const SizedBox(height: 10),
        if (phase.isNotEmpty) ...[
          Row(children: [
            Expanded(child: Text(phase, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: phaseCol))),
            if (prog != null) Text('${(prog * 100).round()}%', style: const TextStyle(fontFamily: kFont, fontSize: 13)),
          ]),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: prog, minHeight: 8, color: phaseCol == Colors.white ? th.c : phaseCol, backgroundColor: Colors.white12),
          ),
          const SizedBox(height: 4),
          Row(children: [
            Text(sizeTxt, style: const TextStyle(fontSize: 12, color: Colors.white70)),
            const Spacer(),
            Text(timeTxt, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ]),
        ],
        if (busy) const Text('เกจกำลังแฟลช — ห้ามปิดกุญแจ / ถอดสาย (ออกจากหน้านี้ได้ เกจแฟลชต่อเอง)', style: TextStyle(fontSize: 12, color: kBad)),
        if (f != null && f.err != 0) Text('เกจแจ้ง: ${flashErrText(f.err)}', style: const TextStyle(fontSize: 12, color: kBad)),
        if (msg != null) Text(msg!, style: const TextStyle(fontSize: 12, color: kBad)),
        if (f != null && f.phase == 9)
          const Text('แฟลชสำเร็จ — ปิดกุญแจ ~10 วินาทีแล้วเปิดใหม่ ก่อนสตาร์ทเครื่อง', style: TextStyle(fontSize: 12.5, color: kGreen)),
        if (f != null && (f.phase == 9 || f.phase == 10) && !working)
          Padding(padding: const EdgeInsets.only(top: 6), child: Align(alignment: Alignment.centerLeft, child: _btn(th, 'ล้างผล', () => c.clearFlash()))),
      ]),
    );
  }
}
