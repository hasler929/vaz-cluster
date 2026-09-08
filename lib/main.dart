import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:soundpool/soundpool.dart';

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
      title: 'RevHeadz VAZ Edition',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121315),
      ),
      home: const RevHeadzDashboardScreen(),
    );
  }
}

// ============================================================================
// 1. ЗВУКОВОЙ ДВИЖОК И ФИЗИКА ОБОРОТОВ ДВИГАТЕЛЯ
// ============================================================================
class EngineController {
  late Soundpool _pool;
  Timer? _ticker;

  int _soundIdle = -1;
  int _soundAccel = -1;
  int _soundCoast = -1;
  int _soundLimiter = -1;

  int _streamIdle = 0;
  int _streamAccel = 0;
  int _streamCoast = 0;

  final double minRpm = 850.0;
  final double maxRpm = 7500.0;
  final double redlineRpm = 5600.0;
  
  double currentRpm = 850.0;
  double throttle = 0.0;
  int currentGear = 1;
  bool isClutchPressed = false;
  double vehicleSpeed = 0.0;

  final List<double> gearRatios = [3.636, 1.95, 1.357, 0.941, 0.784]; // КПП ВАЗ 2108-2109
  final double finalDrive = 3.9;

  Function()? onUpdate;

  Future<void> init() async {
    _pool = Soundpool.fromOptions(
      options: const SoundpoolOptions(
        streamType: StreamType.music,
        maxStreams: 8,
      ),
    );

    try {
      _soundIdle = await _loadSound('assets/audio/idle.wav');
      _soundAccel = await _loadSound('assets/audio/engine_accel.wav');
      _soundCoast = await _loadSound('assets/audio/engine_coast.wav');
      _soundLimiter = await _loadSound('assets/audio/limiter_pop.wav');

      _streamIdle = await _pool.play(_soundIdle, repeat: -1, rate: 1.0, volume: 1.0);
      _streamAccel = await _pool.play(_soundAccel, repeat: -1, rate: 1.0, volume: 0.0);
      _streamCoast = await _pool.play(_soundCoast, repeat: -1, rate: 1.0, volume: 0.0);
    } catch (_) {
      // Приложение работает и без звуковых файлов в режиме симуляции приборов
    }

    _startLoop();
  }

  Future<int> _loadSound(String path) async {
    final rawData = await rootBundle.load(path);
    return await _pool.load(rawData);
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

  void _updatePhysics(double dt) {
    if (isClutchPressed) {
      if (throttle > 0.05) {
        currentRpm += (throttle * 9500.0) * dt;
      } else {
        currentRpm -= 4500.0 * dt;
      }
      vehicleSpeed -= (vehicleSpeed * 0.15) * dt;
    } else {
      if (throttle > 0.05) {
        double accel = (throttle * 7800.0) / (currentGear * 0.75);
        currentRpm += accel * dt;
      } else {
        currentRpm -= 3200.0 * dt;
      }

      double targetSpeed = (currentRpm / (gearRatios[currentGear - 1] * finalDrive * 12.0));
      vehicleSpeed += (targetSpeed - vehicleSpeed) * (dt * 2.2);
    }

    if (currentRpm >= maxRpm) {
      currentRpm = maxRpm - 350.0;
      if (_soundLimiter != -1) {
        _pool.play(_soundLimiter, volume: 0.85);
      }
    }

    currentRpm = currentRpm.clamp(minRpm, maxRpm);
    vehicleSpeed = vehicleSpeed.clamp(0.0, 180.0);
  }

  void _updateAudio() {
    if (_soundIdle == -1) return;

    double playbackRate = (currentRpm / 2800.0).clamp(0.5, 2.5);

    double idleVol = (1.0 - (currentRpm - minRpm) / 1400.0).clamp(0.0, 1.0);
    double loadVol = (throttle * (currentRpm / maxRpm)).clamp(0.0, 1.0);
    double coastVol = ((1.0 - throttle) * (currentRpm - minRpm) / (maxRpm - minRpm)).clamp(0.0, 1.0);

    _pool.setVolume(streamId: _streamIdle, volume: idleVol);
    _pool.setRate(streamId: _streamIdle, rate: (currentRpm / minRpm).clamp(0.8, 1.3));

    _pool.setVolume(streamId: _streamAccel, volume: loadVol);
    _pool.setRate(streamId: _streamAccel, rate: playbackRate);

    _pool.setVolume(streamId: _streamCoast, volume: coastVol);
    _pool.setRate(streamId: _streamCoast, rate: playbackRate);
  }

  void dispose() {
    _ticker?.cancel();
    _pool.release();
  }
}

// ============================================================================
// 2. ИНТЕРФЕЙС ЭКРАНА: КНОПКИ REVHEADZ + ПРИБОРКА ВАЗ
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
                // Левая панель: Кнопки RevHeadz
                Expanded(
                  flex: 3,
                  child: _buildLeftControlPanel(),
                ),

                // Центр: Приборная панель ВАЗ
                Expanded(
                  flex: 7,
                  child: _buildVazInstrumentCluster(),
                ),

                // Правая панель: Ползунок акселератора
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
                width: 58,
                height: 58,
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
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
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
            height: 48,
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
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 1.2,
                ),
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
        boxShadow: const [
          BoxShadow(color: Colors.black87, blurRadius: 4, offset: Offset(0, 2))
        ],
      ),
      child: IconButton(
        onPressed: onPressed,
        icon: Text(
          label,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w900,
            color: onPressed == null ? Colors.white24 : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildVazInstrumentCluster() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8.0),
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: const Color(0xFF08090A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A2D33), width: 3),
        boxShadow: const [
          BoxShadow(color: Colors.black, blurRadius: 10, spreadRadius: 2)
        ],
      ),
      child: Row(
        children: [
          // Спидометр ВАЗ
          Expanded(
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
          // Лампы приборки
          Container(
            width: 70,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildWarningIcon(Icons.oil_barrel, _engine.currentRpm < 900 && isEngineRunning, Colors.red),
                _buildWarningIcon(Icons.battery_alert, (!isEngineRunning || _engine.currentRpm < 600), Colors.red),
                _buildWarningIcon(Icons.warning_amber_rounded, _engine.currentRpm > 5600, Colors.amber),
                _buildWarningIcon(Icons.airline_seat_recline_normal, false, Colors.red),
              ],
            ),
          ),
          // Тахометр ВАЗ
          Expanded(
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
    return Icon(
      icon,
      size: 20,
      color: active ? activeColor : const Color(0xFF1E2126),
    );
  }

  Widget _buildRightThrottlePanel() {
    return Column(
      children: [
        const Text(
          'THROTTLE',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: GestureDetector(
            onVerticalDragUpdate: (details) {
              if (!isEngineRunning) return;
              final box = context.findRenderObject() as RenderBox;
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
                boxShadow: const [
                  BoxShadow(color: Colors.black87, blurRadius: 4, offset: Offset(1, 1))
                ],
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
                      (index) => Container(
                        width: 24,
                        height: 2,
                        color: Colors.white12,
                      ),
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

// ============================================================================
// 3. ОТРИСОВКА ШКАЛ ПРИБОРОВ ВАЗ (СКОРОСТЬ И ОБОРОТЫ)
// ============================================================================
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

    final dialBg = Paint()..color = const Color(0xFF0E1012);
    canvas.drawCircle(center, radius, dialBg);

    final rimPaint = Paint()
      ..color = const Color(0xFF282A2E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius, rimPaint);

    final tickPaint = Paint()
      ..color = const Color(0xFFD4E6B5)
      ..strokeWidth = 1.8;

    final redlinePaint = Paint()
      ..color = const Color(0xFFFF3B30)
      ..strokeWidth = 3.5;

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );

    int totalSteps = (maxValue / step).round();
    for (int i = 0; i <= totalSteps; i++) {
      double currentVal = i * step;
      double angle = startAngle + (currentVal / maxValue) * sweepAngle;

      bool isRed = currentVal >= redlineStart;
      Paint currentTickPaint = isRed ? redlinePaint : tickPaint;

      double tickLength = 10.0;
      Offset p1 = Offset(
        center.dx + (radius - 6) * math.cos(angle),
        center.dy + (radius - 6) * math.sin(angle),
      );
      Offset p2 = Offset(
        center.dx + (radius - 6 - tickLength) * math.cos(angle),
        center.dy + (radius - 6 - tickLength) * math.sin(angle),
      );
      canvas.drawLine(p1, p2, currentTickPaint);

      if (i < totalSteps) {
        double midAngle = angle + (step / (2 * maxValue)) * sweepAngle;
        Offset mp1 = Offset(
          center.dx + (radius - 6) * math.cos(midAngle),
          center.dy + (radius - 6) * math.sin(midAngle),
        );
        Offset mp2 = Offset(
          center.dx + (radius - 6 - 5) * math.cos(midAngle),
          center.dy + (radius - 6 - 5) * math.sin(midAngle),
        );
        canvas.drawLine(mp1, mp2, tickPaint);
      }

      textPainter.text = TextSpan(
        text: currentVal.toInt().toString(),
        style: TextStyle(
          color: isRed ? const Color(0xFFFF3B30) : const Color(0xFFD4E6B5),
          fontSize: 10,
          fontWeight: FontWeight.bold,
          fontFamily: 'sans-serif',
        ),
      );
      textPainter.layout();

      double textRadius = radius - 24;
      Offset textPos = Offset(
        center.dx + textRadius * math.cos(angle) - textPainter.width / 2,
        center.dy + textRadius * math.sin(angle) - textPainter.height / 2,
      );
      textPainter.paint(canvas, textPos);
    }

    textPainter.text = TextSpan(
      text: title,
      style: const TextStyle(
        color: Color(0xFF88A070),
        fontSize: 10,
        fontWeight: FontWeight.bold,
      ),
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(center.dx - textPainter.width / 2, center.dy + radius * 0.42),
    );

    double clampedVal = value.clamp(0.0, maxValue);
    double needleAngle = startAngle + (clampedVal / maxValue) * sweepAngle;

    final needlePaint = Paint()
      ..color = const Color(0xFFFF5500)
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    Offset needleTip = Offset(
      center.dx + (radius - 14) * math.cos(needleAngle),
      center.dy + (radius - 14) * math.sin(needleAngle),
    );
    Offset needleBack = Offset(
      center.dx - 10 * math.cos(needleAngle),
      center.dy - 10 * math.sin(needleAngle),
    );

    canvas.drawLine(needleBack, needleTip, needlePaint);

    canvas.drawCircle(center, 6, Paint()..color = const Color(0xFF111111));
    canvas.drawCircle(center, 3, Paint()..color = const Color(0xFFFF5500));
  }

  @override
  bool shouldRepaint(covariant VazGaugePainter oldDelegate) => true;
}
