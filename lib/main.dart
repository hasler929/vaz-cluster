import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const RevHeadzVazApp());
}

class RevHeadzVazApp extends StatelessWidget {
  const RevHeadzVazApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RevHeadz VAZ Turbo Edition',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121315),
      ),
      home: const RevHeadzDashboardScreen(),
    );
  }
}

// ============================================================================
// 1. ВСТРОЕННЫЙ СИНТЕЗАТОР ЗВУКОВ
// ============================================================================
class BuiltinSoundGenerator {
  static Uint8List createWavHeader(int dataLength, int sampleRate, int numChannels, int bitsPerSample) {
    final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    final buffer = ByteData(44);

    buffer.setUint8(0, 0x52); buffer.setUint8(1, 0x49); buffer.setUint8(2, 0x46); buffer.setUint8(3, 0x46);
    buffer.setUint32(4, 36 + dataLength, Endian.little);
    buffer.setUint8(8, 0x57); buffer.setUint8(9, 0x41); buffer.setUint8(10, 0x56); buffer.setUint8(11, 0x45);
    buffer.setUint8(12, 0x66); buffer.setUint8(13, 0x6D); buffer.setUint8(14, 0x74); buffer.setUint8(15, 0x20);
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little);
    buffer.setUint16(22, numChannels, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(32, blockAlign, Endian.little);
    buffer.setUint16(34, bitsPerSample, Endian.little);
    buffer.setUint8(36, 0x64); buffer.setUint8(37, 0x61); buffer.setUint8(38, 0x74); buffer.setUint8(39, 0x61);
    buffer.setUint32(40, dataLength, Endian.little);

    return buffer.buffer.asUint8List();
  }

  static Uint8List generateEngineLoopWav({required double baseFreq, required double durationSec, bool isLoad = false}) {
    const sampleRate = 22050;
    final numSamples = (sampleRate * durationSec).toInt();
    final pcmData = Int16List(numSamples);
    final rand = math.Random();

    for (int i = 0; i < numSamples; i++) {
      double t = i / sampleRate;
      double s1 = math.sin(2 * math.pi * baseFreq * t);
      double s2 = 0.5 * math.sin(4 * math.pi * baseFreq * t);
      double s3 = 0.25 * math.sin(6 * math.pi * baseFreq * t);
      double noise = (rand.nextDouble() * 2 - 1) * (isLoad ? 0.35 : 0.15);

      double sample = (s1 + s2 + s3 + noise) / 2.0;
      if (isLoad) {
        sample = (sample * 1.6).clamp(-1.0, 1.0);
      }
      pcmData[i] = (sample * 28000).toInt();
    }

    final header = createWavHeader(numSamples * 2, sampleRate, 1, 16);
    final fullWav = Uint8List(header.length + pcmData.lengthInBytes);
    fullWav.setRange(0, header.length, header);
    fullWav.setRange(header.length, fullWav.length, pcmData.buffer.asUint8List());
    return fullWav;
  }

  static Uint8List generateBlowOffWav() {
    const sampleRate = 22050;
    const durationSec = 0.45;
    final numSamples = (sampleRate * durationSec).toInt();
    final pcmData = Int16List(numSamples);
    final rand = math.Random();

    for (int i = 0; i < numSamples; i++) {
      double t = i / numSamples;
      double envelope = math.exp(-6.0 * t);
      double noise = (rand.nextDouble() * 2.0 - 1.0) * envelope;
      double chirp = math.sin(2 * math.pi * (1800.0 - 1200.0 * t) * (i / sampleRate)) * envelope * 0.5;
      pcmData[i] = ((noise + chirp) * 26000).clamp(-32000, 32000).toInt();
    }

    final header = createWavHeader(numSamples * 2, sampleRate, 1, 16);
    final fullWav = Uint8List(header.length + pcmData.lengthInBytes);
    fullWav.setRange(0, header.length, header);
    fullWav.setRange(header.length, fullWav.length, pcmData.buffer.asUint8List());
    return fullWav;
  }
}

// ============================================================================
// 2. ДВИЖОК ОБОРОТОВ, ТУРБОНАДДУВ И ЗВУК
// ============================================================================
class EngineController {
  final AudioPlayer _enginePlayer = AudioPlayer();
  final AudioPlayer _fxPlayer = AudioPlayer();
  Timer? _ticker;

  Uint8List? _blowOffBytes;

  final double minRpm = 850.0;
  final double maxRpm = 7500.0;
  final double redlineRpm = 5600.0;

  double currentRpm = 850.0;
  double throttle = 0.0;
  double previousThrottle = 0.0;
  int currentGear = 1;
  bool isClutchPressed = false;
  double vehicleSpeed = 0.0;

  double boostPressure = 0.0;
  final double maxBoost = 1.5;

  final List<double> gearRatios = [3.636, 1.95, 1.357, 0.941, 0.784];
  final double finalDrive = 3.9;

  Function()? onUpdate;

  Future<void> init() async {
    try {
      final engineLoop = BuiltinSoundGenerator.generateEngineLoopWav(baseFreq: 45.0, durationSec: 1.2, isLoad: true);
      _blowOffBytes = BuiltinSoundGenerator.generateBlowOffWav();

      await _enginePlayer.setReleaseMode(ReleaseMode.loop);
      await _enginePlayer.play(BytesSource(engineLoop));
      await _enginePlayer.setVolume(0.8);
    } catch (_) {}

    _startLoop();
  }

  void _startLoop() {
    const dt = 1.0 / 60.0;
    _ticker = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      _updatePhysics(dt);
      _updateAudio();
      onUpdate?.call();
    });
  }

  void setThrottle(double value) {
    throttle = value.clamp(0.0, 1.0);
  }

  void shiftUp() {
    if (currentGear < gearRatios.length) {
      currentGear++;
      _recalcRpmAfterShift();
      _triggerBlowOffCheck();
    }
  }

  void shiftDown() {
    if (currentGear > 1) {
      currentGear--;
      _recalcRpmAfterShift();
    }
  }

  void _recalcRpmAfterShift() {
    if (vehicleSpeed > 0 && !isClutchPressed) {
      currentRpm = (vehicleSpeed * gearRatios[currentGear - 1] * finalDrive * 12.0)
          .clamp(minRpm, maxRpm);
    }
  }

  void _triggerBlowOffCheck() {
    if (boostPressure > 0.35 && _blowOffBytes != null) {
      _fxPlayer.play(BytesSource(_blowOffBytes!));
      boostPressure = 0.0;
    }
  }

  void _updatePhysics(double dt) {
    if (previousThrottle > 0.35 && throttle < 0.15) {
      _triggerBlowOffCheck();
    }
    previousThrottle = throttle;

    if (throttle > 0.1 && currentRpm > 2200) {
      double targetBoost = (throttle * ((currentRpm - 2000) / (maxRpm - 2000)) * maxBoost).clamp(0.0, maxBoost);
      boostPressure += (targetBoost - boostPressure) * (dt * 3.5);
    } else {
      boostPressure -= (boostPressure * 4.0) * dt;
      if (boostPressure < 0) boostPressure = 0.0;
    }

    double boostMultiplier = 1.0 + (boostPressure * 0.85);

    if (isClutchPressed) {
      if (throttle > 0.05) {
        currentRpm += (throttle * 9500.0 * boostMultiplier) * dt;
      } else {
        currentRpm -= 4500.0 * dt;
      }
      vehicleSpeed -= (vehicleSpeed * 0.15) * dt;
    } else {
      if (throttle > 0.05) {
        double accel = ((throttle * 7800.0 * boostMultiplier) / (currentGear * 0.75));
        currentRpm += accel * dt;
      } else {
        currentRpm -= 3200.0 * dt;
      }

      double targetSpeed = (currentRpm / (gearRatios[currentGear - 1] * finalDrive * 12.0));
      vehicleSpeed += (targetSpeed - vehicleSpeed) * (dt * 2.2);
    }

    if (currentRpm >= maxRpm) {
      currentRpm = maxRpm - 350.0;
    }

    currentRpm = currentRpm.clamp(minRpm, maxRpm);
    vehicleSpeed = vehicleSpeed.clamp(0.0, 180.0);
  }

  void _updateAudio() {
    double playbackRate = (currentRpm / 2200.0).clamp(0.5, 2.5);
    _enginePlayer.setPlaybackRate(playbackRate);
  }

  void dispose() {
    _ticker?.cancel();
    _enginePlayer.dispose();
    _fxPlayer.dispose();
  }
}

// ============================================================================
// 3. ИНТЕРФЕЙС ПРИБОРНОЙ ПАНЕЛИ ВАЗ
// ============================================================================
class RevHeadzDashboardScreen extends StatefulWidget {
  const RevHeadzDashboardScreen({super.key});

  @override
  State<RevHeadzDashboardScreen> createState() => _RevHeadzDashboardScreenState();
}

class _RevHeadzDashboardScreenState extends State<RevHeadzDashboardScreen> {
  final EngineController _engine = EngineController();
  bool isEngineRunning = true;
  bool isAutoMode = false;

  @override
  void initState() {
    super.initState();
    _engine.init().then((_) {
      _engine.onUpdate = () => setState(() {});
    });
  }

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1E2024), Color(0xFF0D0E10)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 6.0),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: _buildLeftControlPanel(),
                ),
                Expanded(
                  flex: 7,
                  child: _buildVazInstrumentCluster(),
                ),
                Expanded(
                  flex: 2,
                  child: _buildRightThrottlePanel(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLeftControlPanel() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            GestureDetector(
              onTap: () {
                setState(() {
                  isEngineRunning = !isEngineRunning;
                  if (!isEngineRunning) {
                    _engine.setThrottle(0.0);
                  }
                });
              },
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: isEngineRunning
                        ? [const Color(0xFFFF3333), const Color(0xFF880000)]
                        : [const Color(0xFF444444), const Color(0xFF222222)],
                  ),
                  border: Border.all(color: Colors.white24, width: 2),
                  boxShadow: isEngineRunning
                      ? [BoxShadow(color: Colors.red.withOpacity(0.5), blurRadius: 10)]
                      : [],
                ),
                child: Center(
                  child: Text(
                    isEngineRunning ? 'STOP' : 'START\nENGINE',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white),
                  ),
                ),
              ),
            ),
            Column(
              children: [
                Text(
                  isAutoMode ? 'AUTO' : 'MANUAL',
                  style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold),
                ),
                Switch(
                  value: isAutoMode,
                  activeColor: const Color(0xFFFF5500),
                  inactiveThumbColor: const Color(0xFF888888),
                  inactiveTrackColor: const Color(0xFF2A2A2A),
                  onChanged: (val) {
                    setState(() {
                      isAutoMode = val;
                    });
                  },
                ),
              ],
            ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildRevHeadzButton(
              label: '–',
              onPressed: isAutoMode ? null : () => _engine.shiftDown(),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.white12),
              ),
              child: Text(
                '${_engine.currentGear}',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.orangeAccent),
              ),
            ),
            _buildRevHeadzButton(
              label: '+',
              onPressed: isAutoMode ? null : () => _engine.shiftUp(),
            ),
          ],
        ),
        GestureDetector(
          onTapDown: (_) {
            setState(() {
              _engine.isClutchPressed = true;
            });
          },
          onTapUp: (_) {
            setState(() {
              _engine.isClutchPressed = false;
            });
          },
          onTapCancel: () {
            setState(() {
              _engine.isClutchPressed = false;
            });
          },
          child: Container(
            width: double.infinity,
            height: 46,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: _engine.isClutchPressed
                    ? [const Color(0xFF00AAFF), const Color(0xFF004488)]
                    : [const Color(0xFF333842), const Color(0xFF1E2128)],
              ),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white24, width: 1.5),
            ),
            child: const Center(
              child: Text(
                'CLUTCH (СЦЕПЛЕНИЕ)',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1.2),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRevHeadzButton({required String label, required VoidCallback? onPressed}) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: const Color(0xFF2B2E38),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
        boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 4, offset: Offset(0, 2))],
      ),
      child: IconButton(
        onPressed: onPressed,
        icon: Text(
          label,
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: onPressed == null ? Colors.white24 : Colors.white),
        ),
      ),
    );
  }

  Widget _buildVazInstrumentCluster() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 6.0),
      padding: const EdgeInsets.all(6.0),
      decoration: BoxDecoration(
        color: const Color(0xFF08090A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A2D33), width: 3),
        boxShadow: const [BoxShadow(color: Colors.black, blurRadius: 10, spreadRadius: 2)],
      ),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: AspectRatio(
              aspectRatio: 1,
              child: CustomPaint(
                painter: VazGaugePainter(
                  value: isEngineRunning ? _engine.vehicleSpeed : 0.0,
                  maxValue: 180,
                  title: 'km/h',
                  step: 20,
                  redlineStart: 180,
                  isTachometer: false,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                SizedBox(
                  width: 84,
                  height: 84,
                  child: CustomPaint(
                    painter: BoostGaugePainter(
                      boost: isEngineRunning ? _engine.boostPressure : 0.0,
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildWarningIcon(Icons.oil_barrel, _engine.currentRpm < 900 && isEngineRunning, Colors.red),
                    const SizedBox(width: 8),
                    _buildWarningIcon(Icons.battery_alert, (!isEngineRunning || _engine.currentRpm < 600), Colors.red),
                    const SizedBox(width: 8),
                    _buildWarningIcon(Icons.warning_amber_rounded, _engine.currentRpm > 5600, Colors.amber),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            flex: 4,
            child: AspectRatio(
              aspectRatio: 1,
              child: CustomPaint(
                painter: VazGaugePainter(
                  value: isEngineRunning ? (_engine.currentRpm / 100) : 0.0,
                  maxValue: 80,
                  title: 'min⁻¹ x100',
                  step: 10,
                  redlineStart: 56,
                  isTachometer: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWarningIcon(IconData icon, bool active, Color activeColor) {
    return Icon(icon, size: 18, color: active ? activeColor : const Color(0xFF1E2126));
  }

  Widget _buildRightThrottlePanel() {
    return Column(
      children: [
        const Text('THROTTLE', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        const SizedBox(height: 6),
        Expanded(
          child: GestureDetector(
            onVerticalDragUpdate: (details) {
              if (!isEngineRunning) return;
              final localPos = details.localPosition.dy;
              double val = 1.0 - (localPos / 180.0);
              _engine.setThrottle(val.clamp(0.0, 1.0));
            },
            onVerticalDragEnd: (_) => _engine.setThrottle(0.0),
            child: Container(
              width: 54,
              decoration: BoxDecoration(
                color: const Color(0xFF181A20),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: const Color(0xFF333842), width: 2),
              ),
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  FractionallySizedBox(
                    heightFactor: isEngineRunning ? _engine.throttle : 0.0,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26),
                        gradient: const LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Color(0xFFFF7700), Color(0xFFFF2200)],
                        ),
                      ),
                    ),
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: List.generate(
                      10,
                      (index) => Container(width: 24, height: 2, color: Colors.white12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class BoostGaugePainter extends CustomPainter {
  final double boost;
  BoostGaugePainter({required this.boost});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;
    const startAngle = 0.75 * math.pi;
    const sweepAngle = 1.5 * math.pi;

    canvas.drawCircle(center, radius, Paint()..color = const Color(0xFF0F1014));
    canvas.drawCircle(center, radius, Paint()..color = const Color(0xFF3B4048)..style = PaintingStyle.stroke..strokeWidth = 2.5);

    final tickPaint = Paint()..color = Colors.cyanAccent.withOpacity(0.8)..strokeWidth = 1.5;
    for (int i = 0; i <= 6; i++) {
      double angle = startAngle + (i / 6.0) * sweepAngle;
      Offset p1 = Offset(center.dx + (radius - 4) * math.cos(angle), center.dy + (radius - 4) * math.sin(angle));
      Offset p2 = Offset(center.dx + (radius - 10) * math.cos(angle), center.dy + (radius - 10) * math.sin(angle));
      canvas.drawLine(p1, p2, tickPaint);
    }

    final tp = TextPainter(
      text: TextSpan(text: '${boost.toStringAsFixed(1)}\nBAR', style: const TextStyle(color: Colors.cyanAccent, fontSize: 9, fontWeight: FontWeight.bold, height: 1.0)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy + 8));

    double clampedBoost = boost.clamp(0.0, 1.5);
    double needleAngle = startAngle + (clampedBoost / 1.5) * sweepAngle;
    Offset needleTip = Offset(center.dx + (radius - 8) * math.cos(needleAngle), center.dy + (radius - 8) * math.sin(needleAngle));
    canvas.drawLine(center, needleTip, Paint()..color = Colors.cyanAccent..strokeWidth = 2.0..strokeCap = StrokeCap.round);
    canvas.drawCircle(center, 3, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant BoostGaugePainter oldDelegate) => true;
}

class VazGaugePainter extends CustomPainter {
  final double value;
  final double maxValue;
  final String title;
  final double step;
  final double redlineStart;
  final bool isTachometer;

  VazGaugePainter({
    required this.value,
    required this.maxValue,
    required this.title,
    required this.step,
    required this.redlineStart,
    required this.isTachometer,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;
    const startAngle = 0.75 * math.pi;
    const sweepAngle = 1.5 * math.pi;

    canvas.drawCircle(center, radius, Paint()..color = const Color(0xFF0E1012));
    canvas.drawCircle(center, radius, Paint()..color = const Color(0xFF282A2E)..style = PaintingStyle.stroke..strokeWidth = 3);

    final tickPaint = Paint()..color = const Color(0xFFD4E6B5)..strokeWidth = 1.8;
    final redlinePaint = Paint()..color = const Color(0xFFFF3B30)..strokeWidth = 3.5;
    final textPainter = TextPainter(textDirection: TextDirection.ltr, textAlign: TextAlign.center);

    int totalSteps = (maxValue / step).round();
    for (int i = 0; i <= totalSteps; i++) {
      double currentVal = i * step;
      double angle = startAngle + (currentVal / maxValue) * sweepAngle;
      bool isRed = currentVal >= redlineStart;

      Offset p1 = Offset(center.dx + (radius - 6) * math.cos(angle), center.dy + (radius - 6) * math.sin(angle));
      Offset p2 = Offset(center.dx + (radius - 16) * math.cos(angle), center.dy + (radius - 16) * math.sin(angle));
      canvas.drawLine(p1, p2, isRed ? redlinePaint : tickPaint);

      textPainter.text = TextSpan(
        text: currentVal.toInt().toString(),
        style: TextStyle(color: isRed ? const Color(0xFFFF3B30) : const Color(0xFFD4E6B5), fontSize: 10, fontWeight: FontWeight.bold),
      );
      textPainter.layout();
      Offset textPos = Offset(center.dx + (radius - 24) * math.cos(angle) - textPainter.width / 2, center.dy + (radius - 24) * math.sin(angle) - textPainter.height / 2);
      textPainter.paint(canvas, textPos);
    }

    textPainter.text = TextSpan(text: title, style: const TextStyle(color: Color(0xFF88A070), fontSize: 10, fontWeight: FontWeight.bold));
    textPainter.layout();
    textPainter.paint(canvas, Offset(center.dx - textPainter.width / 2, center.dy + radius * 0.42));

    double clampedVal = value.clamp(0.0, maxValue);
    double needleAngle = startAngle + (clampedVal / maxValue) * sweepAngle;
    Offset needleTip = Offset(center.dx + (radius - 14) * math.cos(needleAngle), center.dy + (radius - 14) * math.sin(needleAngle));
    Offset needleBack = Offset(center.dx - 10 * math.cos(needleAngle), center.dy - 10 * math.sin(needleAngle));

    canvas.drawLine(needleBack, needleTip, Paint()..color = const Color(0xFFFF5500)..strokeWidth = 3.0..strokeCap = StrokeCap.round);
    canvas.drawCircle(center, 6, Paint()..color = const Color(0xFF111111));
    canvas.drawCircle(center, 3, Paint()..color = const Color(0xFFFF5500));
  }

  @override
  bool shouldRepaint(covariant VazGaugePainter oldDelegate) => true;
}
