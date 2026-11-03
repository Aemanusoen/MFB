import 'dart:typed_data';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ---------- BLE UUIDs (ต้องตรงกับ BleGauge.h) ----------
final Guid kSvc = Guid('7a0f0001-5a41-5201-9c11-2a52a1c0de01');
final Guid kData = Guid('7a0f0002-5a41-5201-9c11-2a52a1c0de01');
final Guid kCmd = Guid('7a0f0003-5a41-5201-9c11-2a52a1c0de01');

const kBg = Color(0xFF0B0B0E);
const kAccent = Color(0xFFFF2A2A);
const kDim = Color(0xFF2F2F38);
const kBorder = Color(0xFF4A2A2C);
const kLabel = Color(0xFF8D8D9A);
const kRed = Color(0xFFFF3B5C);
const kGreen = Color(0xFF3CFF8A);
const kAmber = Color(0xFFFFB020);

// ---------- ข้อมูลจาก ESP32 ----------
class Telemetry {
  final bool fresh;
  final int state, proto, bike;
  final double? rpm, speed, ect, iat, eot, tps, map, batt, afr, ign, inj, o2v, stft, ltft;
  Telemetry({
    this.fresh = false, this.state = 0, this.proto = 0, this.bike = 0,
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
      state: b[1], proto: b[2], fresh: (b[3] & 1) != 0, bike: b[4],
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
  double peakRpm = 0;
  String? error;

  BluetoothDevice? _dev;
  BluetoothCharacteristic? _cmd;
  StreamSubscription? _scanSub, _dataSub, _connSub, _gpsSub;
  Timer? _demoTimer, _retryTimer;
  bool _auto = false;

  bool get ecuLive => link == LinkState.connected && t.fresh;
  double? get shownSpeed => t.speed ?? gpsSpeed;

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

  void _track() {
    final s = shownSpeed;
    if (s != null && s > topSpeed) topSpeed = s;
    if (t.rpm != null && t.rpm! > peakRpm) peakRpm = t.rpm!;
  }

  void resetPeaks() {
    topSpeed = 0;
    peakRpm = 0;
    notifyListeners();
  }

  // ----- BLE -----
  Future<void> connect() async {
    if (demo) toggleDemo();
    _auto = true;
    error = null;
    await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      try { await FlutterBluePlus.turnOn(); } catch (_) {}
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
      try { await dev.requestMtu(185); } catch (_) {}
      final services = await dev.discoverServices();
      final svc = services.firstWhere((s) => s.uuid == kSvc);
      final data = svc.characteristics.firstWhere((c) => c.uuid == kData);
      _cmd = svc.characteristics.firstWhere((c) => c.uuid == kCmd);
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
    try { await _dev?.disconnect(); } catch (_) {}
    link = LinkState.idle;
    t = Telemetry();
    notifyListeners();
  }

  Future<void> sendCmd(List<int> bytes) async {
    try { await _cmd?.write(bytes, withoutResponse: false); } catch (_) {}
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
          rpm: 1500 + 7000 * k, speed: 90 * k, ect: 82 + 6 * k, iat: 34,
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

// ---------- UI ----------
void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
        theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: kBg),
        home: const GaugePage(),
      );
}

class GaugePage extends StatefulWidget {
  const GaugePage({super.key});
  @override
  State<GaugePage> createState() => _GaugePageState();
}

class _GaugePageState extends State<GaugePage> {
  final c = GaugeController();
  @override
  void initState() {
    super.initState();
    c.init();
    c.addListener(() => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  String _fmt(double? v, int dec) => v == null ? '--' : v.toStringAsFixed(dec);

  @override
  Widget build(BuildContext context) {
    final t = c.t;
    final linkTxt = switch (c.link) {
      LinkState.idle => 'OFFLINE',
      LinkState.scanning => 'SCANNING',
      LinkState.connecting => 'CONNECTING',
      LinkState.connected => 'CONNECTED',
    };
    final linkCol = c.link == LinkState.connected ? kGreen : (c.link == LinkState.idle ? kRed : kAmber);
    final speed = c.demo || c.link == LinkState.connected ? (c.shownSpeed ?? 0) : (c.gpsSpeed ?? 0);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(children: [
            // ----- top bar -----
            Row(children: [
              const Text('MFB-PRO', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: kAccent, letterSpacing: 1)),
              const SizedBox(width: 14),
              _chip(linkTxt, linkCol),
              _chip(c.ecuLive || c.demo ? 'ECU LIVE' : 'NO ECU', c.ecuLive || c.demo ? kGreen : kRed),
              _chip(c.gpsOk ? 'GPS' : 'NO GPS', c.gpsOk ? kGreen : kRed),
              const Spacer(),
              _btn(c.link == LinkState.connected ? 'ตัดการเชื่อมต่อ' : 'เชื่อมต่อ',
                  () => c.link == LinkState.connected ? c.disconnect() : c.connect()),
              const SizedBox(width: 8),
              _btn('DEMO', c.toggleDemo, active: c.demo),
            ]),
            const SizedBox(height: 8),
            Expanded(
              child: Row(children: [
                SizedBox(width: 190, child: Column(children: [
                  _tile('TPS', '%', _fmt(t.tps, 0), col: const Color(0xFF2EE6A6)),
                  _tile('AFR', 'O2', _fmt(t.afr, 1), col: const Color(0xFFFF5A5F), bar: t.afr == null ? null : ((t.afr! - 10) / 8).clamp(0, 1)),
                  _tile('IGN', '°BTDC', _fmt(t.ign, 1), col: const Color(0xFFB07CFF)),
                ])),
                Expanded(child: _centerGauge(speed, t.rpm)),
                SizedBox(width: 190, child: Column(children: [
                  _tile('ECT', '°C', _fmt(t.ect ?? t.eot, 0), col: const Color(0xFF3AA0FF), warn: (t.ect ?? 0) > 105),
                  _tile('IAT', '°C', _fmt(t.iat, 0), col: const Color(0xFF7FD6FF)),
                  _tile('BATTERY', 'V', _fmt(t.batt, 1), col: const Color(0xFFFFC233), warn: t.batt != null && t.batt! < 11.8),
                  _tile('TOP SPEED', 'KM/H', c.topSpeed.toStringAsFixed(1), col: const Color(0xFFFF8A3D), onTap: c.resetPeaks, hint: 'RESET'),
                ])),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _centerGauge(double speed, double? rpm) {
    return Stack(alignment: Alignment.center, children: [
      CustomPaint(
        size: Size.infinite,
        painter: ArcPainter(value: (speed / 180).clamp(0, 1).toDouble(), rpmFrac: rpm == null ? 0 : (rpm / 10000).clamp(0, 1).toDouble()),
      ),
      Column(mainAxisSize: MainAxisSize.min, children: [
        Text(speed.toStringAsFixed(0), style: const TextStyle(fontSize: 76, fontWeight: FontWeight.w900, color: Colors.white, height: 1)),
        Text('km/h${c.t.speed == null ? ' · GPS' : ' · ECU'}', style: const TextStyle(color: kLabel, fontSize: 13)),
        const SizedBox(height: 6),
        Text(rpm == null ? 'RPM --' : 'RPM ${rpm.toStringAsFixed(0)}', style: const TextStyle(fontSize: 18, color: Colors.white70)),
      ]),
    ]);
  }

  Widget _chip(String s, Color col) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(4)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(s, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
        ]),
      );

  Widget _btn(String s, VoidCallback f, {bool active = false}) => InkWell(
        onTap: f,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active ? kAccent.withOpacity(.35) : null,
            border: Border.all(color: kAccent, width: 2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(s, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        ),
      );

  Widget _tile(String label, String unit, String value, {Color col = Colors.white, double? bar, bool warn = false, VoidCallback? onTap, String? hint}) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
          decoration: BoxDecoration(
            border: Border.all(color: warn ? kRed : kBorder, width: 1.5),
            borderRadius: BorderRadius.circular(7),
            gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF1A1A20), Color(0xFF0B0B0E)]),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: kLabel)),
              Text(hint ?? unit, style: const TextStyle(fontSize: 10, color: kLabel)),
            ]),
            Expanded(child: FittedBox(alignment: Alignment.centerLeft, fit: BoxFit.scaleDown,
              child: Text(value, style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: warn ? kRed : col)))),
            if (bar != null) LinearProgressIndicator(value: bar, minHeight: 4, color: col, backgroundColor: kDim),
          ]),
        ),
      ),
    );
  }
}

// ---------- วงโค้งความเร็ว + เส้น RPM ----------
class ArcPainter extends CustomPainter {
  final double value, rpmFrac;
  ArcPainter({required this.value, required this.rpmFrac});

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width, size.height) / 2 - 8;
    final center = Offset(size.width / 2, size.height / 2 + 6);
    const start = math.pi * 0.75, sweep = math.pi * 1.5;
    const n = 48;
    for (int i = 0; i < n; i++) {
      final a = start + sweep * i / n;
      final on = i / n < value;
      final p = Paint()
        ..color = on ? (i / n > .85 ? kRed : const Color(0xFF3AA0FF)) : kDim
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.butt;
      canvas.drawLine(center + Offset(math.cos(a), math.sin(a)) * (r - 14), center + Offset(math.cos(a), math.sin(a)) * r, p);
    }
    // RPM bar ใต้ตัวเลข
    final w = r * 1.1, y = center.dy + r * 0.62;
    final bg = Paint()..color = kDim..strokeWidth = 6..strokeCap = StrokeCap.round;
    final fg = Paint()..color = rpmFrac > .85 ? kRed : Colors.white..strokeWidth = 6..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(center.dx - w / 2, y), Offset(center.dx + w / 2, y), bg);
    if (rpmFrac > 0) canvas.drawLine(Offset(center.dx - w / 2, y), Offset(center.dx - w / 2 + w * rpmFrac, y), fg);
  }

  @override
  bool shouldRepaint(ArcPainter o) => o.value != value || o.rpmFrac != rpmFrac;
}
