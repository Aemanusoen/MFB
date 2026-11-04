import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

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

class ThemeCtl extends ChangeNotifier {
  static final ThemeCtl i = ThemeCtl._();
  ThemeCtl._();
  int idx = 0;
  AppTheme get t => kThemes[idx];

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getInt('theme') ?? 0;
      idx = (v >= 0 && v < kThemes.length) ? v : 0;
    } catch (_) {}
  }

  Future<void> set(int v) async {
    idx = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('theme', v);
    } catch (_) {}
  }
}

// ---------- ข้อมูลจาก ESP32 ----------
class Telemetry {
  final bool fresh;
  final int state, proto, bike, img;
  final double? rpm, speed, ect, iat, eot, tps, map, batt, afr, ign, inj, o2v, stft, ltft;
  Telemetry({
    this.fresh = false, this.state = 0, this.proto = 0, this.bike = 0, this.img = 0,
    this.rpm, this.speed, this.ect, this.iat, this.eot, this.tps, this.map,
    this.batt, this.afr, this.ign, this.inj, this.o2v, this.stft, this.ltft,
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
  StreamSubscription? _scanSub, _dataSub, _connSub, _gpsSub;
  Timer? _demoTimer, _retryTimer;
  bool _auto = false;

  bool get ecuLive => link == LinkState.connected && t.fresh;

  /// ความเร็วที่แสดงกลางเกจ: ใช้ GPS เป็นหลัก ถ้าไม่มี GPS ใช้ค่าจาก ECU
  double? get shownSpeed => demo ? t.speed : (gpsOk ? gpsSpeed : t.speed);
  String get speedSrc => (!demo && gpsOk) ? 'GPS' : 'ECU';

  Future<void> init() async {
    await WakelockPlus.enable();
    await _startGps();
  }

  Future<void> _startGps() async {
    try {
      final perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0),
      ).listen((p) {
        gpsOk = true;
        gpsSpeed = math.max(0, p.speed * 3.6);
        _track();
        notifyListeners();
      }, onError: (_) {
        gpsOk = false;
        notifyListeners();
      });
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

  String? mnStr(String k, int dec) => mm[k] == null ? null : mm[k]![0].toStringAsFixed(dec);
  String? mxStr(String k, int dec) => mm[k] == null ? null : mm[k]![1].toStringAsFixed(dec);

  void _track() {
    final s = shownSpeed;
    if (s != null && s > topSpeed) topSpeed = s;
    if (t.fresh || demo) {
      _mmUpdate('rpm', t.rpm, skipZero: true);
      _mmUpdate('tps', t.tps);
      _mmUpdate('afr', t.afr);
      _mmUpdate('ign', t.ign);
      _mmUpdate('ect', t.ect ?? t.eot);
      _mmUpdate('iat', t.iat);
      _mmUpdate('batt', t.batt);
    }
  }

  void resetPeaks() {
    topSpeed = 0;
    mm.clear();
    notifyListeners();
  }

  // ----- BLE -----
  Future<void> connect() async {
    if (demo) toggleDemo();
    _auto = true;
    error = null;
    await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {}
    }
    await _scanAndConnect();
  }

  Future<void> _scanAndConnect() async {
    if (!_auto) return;
    link = LinkState.scanning;
    notifyListeners();
    await _scanSub?.cancel();
    final done = Completer<BluetoothDevice?>();
    _scanSub = FlutterBluePlus.scanResults.listen((rs) {
      for (final r in rs) {
        if (!done.isCompleted) done.complete(r.device);
      }
    });
    await FlutterBluePlus.startScan(withServices: [kSvc], timeout: const Duration(seconds: 8));
    final dev = await done.future.timeout(const Duration(seconds: 9), onTimeout: () => null);
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    if (dev == null) {
      error = 'ไม่พบ MFB-PRO';
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

  // ----- DEMO -----
  void toggleDemo() {
    demo = !demo;
    _demoTimer?.cancel();
    if (demo) {
      final sw = Stopwatch()..start();
      _demoTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
        final s = sw.elapsedMilliseconds / 1000.0;
        final k = (math.sin(s * 0.6) + 1) / 2;
        t = Telemetry(
          fresh: true, state: 1, proto: 1,
          rpm: 950 + 10200 * k, speed: 120 * k, ect: 82 + 6 * k, iat: 34,
          tps: 5 + 80 * k, batt: 13.8, afr: 13.2 + 2 * (1 - k), ign: 12 + 18 * k,
        );
        _track();
        notifyListeners();
      });
    } else {
      t = Telemetry();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _demoTimer?.cancel();
    _retryTimer?.cancel();
    _scanSub?.cancel();
    _dataSub?.cancel();
    _connSub?.cancel();
    _gpsSub?.cancel();
    super.dispose();
  }
}

// ======================= UI =======================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeCtl.i.load();
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
    final th = ThemeCtl.i.t;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        FadeTransition(
          opacity: fade,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 40),
            child: Image.asset('assets/splash.jpg', fit: BoxFit.contain),
          ),
        ),
        Positioned(
          left: 0, right: 0, bottom: 18,
          child: Center(
            child: SizedBox(
              width: 280,
              child: AnimatedBuilder(
                animation: ac,
                builder: (_, __) => Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('LOADING  ${(ac.value * 100).round()}%',
                      style: TextStyle(fontFamily: kFont, fontSize: 9, color: th.c, letterSpacing: 1)),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: ac.value, minHeight: 5, color: th.c, backgroundColor: Colors.white12),
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

// ---------- หน้าเกจหลัก ----------
class GaugePage extends StatefulWidget {
  const GaugePage({super.key});
  @override
  State<GaugePage> createState() => _GaugePageState();
}

class _GaugePageState extends State<GaugePage> {
  final c = GaugeController();

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    c.init();
    c.addListener(_rebuild);
    ThemeCtl.i.addListener(_rebuild);
  }

  @override
  void dispose() {
    ThemeCtl.i.removeListener(_rebuild);
    c.removeListener(_rebuild);
    c.dispose();
    super.dispose();
  }

  String _fmt(double? v, int dec) => v == null ? '--' : v.toStringAsFixed(dec);

  @override
  Widget build(BuildContext context) {
    final th = ThemeCtl.i.t;
    final t = c.t;
    final linkTxt = switch (c.link) {
      LinkState.idle => 'OFFLINE',
      LinkState.scanning => 'SCANNING',
      LinkState.connecting => 'CONNECTING',
      LinkState.connected => 'CONNECTED',
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
                Text('MFB-PRO',
                    style: TextStyle(
                        fontFamily: kFont, fontSize: 17, color: th.c,
                        shadows: [Shadow(color: th.c, blurRadius: 10)])),
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
                    () => c.link == LinkState.connected ? c.disconnect() : c.connect(), th),
                const SizedBox(width: 6),
                _btn('DEMO', c.toggleDemo, th, active: c.demo),
                const SizedBox(width: 6),
                _iconBtn(Icons.settings, th, () {
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsPage(c: c)));
                }),
              ]),
              const SizedBox(height: 6),
              Expanded(
                child: Row(children: [
                  SizedBox(
                    width: 168,
                    child: Column(children: [
                      Expanded(child: StatTile(th: th, label: 'TPS', unit: '%', value: _fmt(t.tps, 0), mn: c.mnStr('tps', 0), mx: c.mxStr('tps', 0))),
                      Expanded(child: StatTile(th: th, label: 'AFR', unit: 'O2', value: _fmt(t.afr, 1), mn: c.mnStr('afr', 1), mx: c.mxStr('afr', 1))),
                      Expanded(child: StatTile(th: th, label: 'IGN', unit: '°BTDC', value: _fmt(t.ign, 1), mn: c.mnStr('ign', 1), mx: c.mxStr('ign', 1))),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: LayoutBuilder(builder: (_, cs) => _center(cs, th))),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 168,
                    child: Column(children: [
                      Expanded(child: StatTile(th: th, label: 'ECT', unit: '°C', value: _fmt(t.ect ?? t.eot, 0), mn: c.mnStr('ect', 0), mx: c.mxStr('ect', 0), warn: (t.ect ?? 0) > 105)),
                      Expanded(child: StatTile(th: th, label: 'IAT', unit: '°C', value: _fmt(t.iat, 0), mn: c.mnStr('iat', 0), mx: c.mxStr('iat', 0))),
                      Expanded(child: StatTile(th: th, label: 'BATTERY', unit: 'V', value: _fmt(t.batt, 1), mn: c.mnStr('batt', 1), mx: c.mxStr('batt', 1), warn: t.batt != null && t.batt! < 11.8)),
                      Expanded(child: StatTile(th: th, label: 'TOP SPEED', unit: 'KM/H', value: c.topSpeed.toStringAsFixed(1), footer: 'TAP = RESET', onTap: c.resetPeaks)),
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

  // เกจกลาง: ความเร็ว GPS อยู่กลางเกจ, RPM อยู่ด้านล่างเกจ
  Widget _center(BoxConstraints cs, AppTheme th) {
    final w = cs.maxWidth, h = cs.maxHeight;
    const tileH = 66.0;
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
          builder: (_, v, __) => CustomPaint(painter: GaugePainter(frac: v, r: r, th: th)),
        ),
      ),
      Positioned(
        left: cx - r * 0.5, width: r, top: cy - r * 0.34, height: r * 0.72,
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
          Text('km/h · ${c.speedSrc}', style: TextStyle(fontSize: math.max(10.0, r * 0.085), color: th.c2, fontWeight: FontWeight.bold)),
        ]),
      ),
      Positioned(
        left: cx - tileW / 2, width: tileW, top: cy + 0.74 * r, height: tileH,
        child: StatTile(
          th: th, label: 'RPM', unit: 'x1000', value: rpm == null ? '--' : rpm.toStringAsFixed(0),
          mn: c.mnStr('rpm', 0), mx: c.mxStr('rpm', 0), bottomMargin: 0, valueSize: 26),
      ),
    ]);
  }

  Widget _chip(String s, Color col) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
            color: Colors.black54, border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(6)),
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

// ---------- กรอบแสดงค่า: เส้นขอบบางเรืองแสง + ขีดสั้นมุมซ้ายบน + ▼ต่ำสุด ▲สูงสุด ----------
class StatTile extends StatelessWidget {
  final AppTheme th;
  final String label, unit, value;
  final String? mn, mx, footer;
  final bool warn;
  final VoidCallback? onTap;
  final double bottomMargin;
  final double valueSize;
  const StatTile({
    super.key, required this.th, required this.label, required this.unit, required this.value,
    this.mn, this.mx, this.footer, this.warn = false, this.onTap, this.bottomMargin = 6, this.valueSize = 30,
  });

  @override
  Widget build(BuildContext context) {
    final col = warn ? kBad : th.c;
    return LayoutBuilder(builder: (_, cs) {
      final tall = cs.maxHeight >= 60;
      return GestureDetector(
        onTap: onTap,
        child: Container(
          margin: EdgeInsets.only(bottom: bottomMargin),
          decoration: BoxDecoration(
            color: const Color(0xCC060606),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: col.withOpacity(0.85), width: 1.1),
            boxShadow: [BoxShadow(color: col.withOpacity(0.35), blurRadius: 10)],
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
              padding: const EdgeInsets.fromLTRB(10, 7, 10, 4),
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
                              fontFamily: kFont, fontSize: valueSize, color: Colors.white,
                              shadows: [Shadow(color: col, blurRadius: 9), Shadow(color: col.withOpacity(0.6), blurRadius: 3)])),
                    ),
                  ),
                ),
                if (tall && mn != null && mx != null)
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text.rich(TextSpan(children: [
                      const TextSpan(text: '▼ ', style: TextStyle(color: kGreen, fontSize: 9)),
                      TextSpan(text: mn!, style: const TextStyle(color: kGreen, fontSize: 12)),
                    ])),
                    Text.rich(TextSpan(children: [
                      const TextSpan(text: '▲ ', style: TextStyle(color: kBad, fontSize: 9)),
                      TextSpan(text: mx!, style: const TextStyle(color: kBad, fontSize: 12)),
                    ])),
                  ])
                else if (tall && footer != null)
                  Text(footer!, style: const TextStyle(fontSize: 9, color: Colors.white38)),
              ]),
            ),
          ]),
        ),
      );
    });
  }
}

// ---------- เกจ RPM สไตล์แท่งเซกเมนต์ + เข็ม + ตัวเลข 0-15 ----------
class GaugePainter extends CustomPainter {
  final double frac, r;
  final AppTheme th;
  GaugePainter({required this.frac, required this.r, required this.th});

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
      final inZone = pos * kMaxRpm >= kZoneRpm;
      final lit = pos <= frac;
      final a0 = start + seg * i + seg * 0.1;
      final col = lit
          ? (inZone ? th.c2 : th.c)
          : (inZone ? th.c.withOpacity(0.30) : Colors.white.withOpacity(0.13));
      if (lit) {
        canvas.drawArc(rect, a0, seg * 0.8, false,
            Paint()
              ..color = th.c.withOpacity(0.7)
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

    // วงบางด้านใน + โซนเรดไลน์
    final r2 = r * 0.80;
    final rect2 = Rect.fromCircle(center: c, radius: r2);
    canvas.drawArc(rect2, start, sweep, false,
        Paint()
          ..color = Colors.white.withOpacity(0.2)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    final zs = kZoneRpm / kMaxRpm;
    canvas.drawArc(rect2, start + sweep * zs, sweep * (1 - zs), false,
        Paint()
          ..color = th.c
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 2));

    // ขีดและตัวเลข 0..15
    for (int k = 0; k <= 15; k++) {
      final ang = start + sweep * k / 15;
      final dir = Offset(math.cos(ang), math.sin(ang));
      final zone = k * 1000 >= kZoneRpm;
      canvas.drawLine(c + dir * (r2 - r * 0.05), c + dir * r2,
          Paint()
            ..color = zone ? th.c : Colors.white70
            ..strokeWidth = 1.6);
      final tp = TextPainter(
        text: TextSpan(
            text: '$k',
            style: TextStyle(fontFamily: kFont, fontSize: r * 0.072, color: zone ? th.c2 : Colors.white.withOpacity(0.9))),
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
  bool shouldRepaint(GaugePainter o) => o.frac != frac || o.r != r || o.th != th;
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
    ThemeCtl.i.addListener(_rebuild);
    widget.c.addListener(_rebuild);
  }

  @override
  void dispose() {
    ThemeCtl.i.removeListener(_rebuild);
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
    final th = ThemeCtl.i.t;
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
                    // ----- ธีมสี -----
                    Expanded(
                      child: _panel(th, 'ธีมสี', Wrap(spacing: 14, runSpacing: 14, children: [
                        for (int i = 0; i < kThemes.length; i++) _themeDot(i),
                      ])),
                    ),
                    const SizedBox(width: 12),
                    // ----- โลโก้บอร์ด -----
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
                          if (msg != null)
                            Padding(padding: const EdgeInsets.only(top: 8), child: Text(msg!, style: const TextStyle(fontSize: 12))),
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

  Widget _panel(AppTheme th, String title, Widget child) => Container(
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
    final sel = ThemeCtl.i.idx == i;
    return GestureDetector(
      onTap: () => ThemeCtl.i.set(i),
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
            decoration: BoxDecoration(
              color: Colors.black45,
              border: Border.all(color: th.c, width: 1.3),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(ic, size: 16, color: th.c),
              const SizedBox(width: 6),
              Text(s, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ]),
          ),
        ),
      );
}
