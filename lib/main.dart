import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const STDApp());
}

// ── Colors ────────────────────────────────────────────────────────────────────

const Color _bg        = Color(0xFF0A0E1A);
const Color _surface   = Color(0xFF121828);
const Color _border    = Color(0xFF1E2740);
const Color _accentA   = Color(0xFF00C2FF);   // cyan
const Color _accentB   = Color(0xFF0066FF);   // blue
const Color _green     = Color(0xFF00E676);
const Color _yellow    = Color(0xFFFFD740);
const Color _red       = Color(0xFFFF5252);
const Color _textSub   = Color(0xFF5A7090);
const Color _textDim   = Color(0xFF2D4060);

const String _testUrl  = 'https://ash-speed.hetzner.com/100MB.bin';
const double _maxScale = 1000.0; // gauge max Mbps

// ── State ─────────────────────────────────────────────────────────────────────

enum TestState { idle, running, done, error }

// ── Controller ────────────────────────────────────────────────────────────────

class SpeedController extends ChangeNotifier {
  TestState state    = TestState.idle;
  int       threads  = 8;
  int       duration = 10;
  double speedMbps = 0, peakMbps = 0, avgMbps = 0;
  double progress  = 0;
  int bytesTotal = 0, elapsedMs = 0;
  String? error;
  final List<double> history = [];   // live speed samples for sparkline

  final List<http.Client> _clients = [];
  Timer? _ticker, _stopper;
  int _lastBytes = 0;
  DateTime? _start;
  bool _cancelled = false;

  void setThreads(int v)  { if (state != TestState.running) { threads  = v; notifyListeners(); } }
  void setDuration(int v) { if (state != TestState.running) { duration = v; notifyListeners(); } }

  Future<void> toggle() async {
    if (state == TestState.running) { _finish(); return; }
    if (state == TestState.done || state == TestState.error) { reset(); return; }
    await _startTest();
  }

  Future<void> _startTest() async {
    _resetCounters();
    state = TestState.running;
    notifyListeners();
    _start     = DateTime.now();
    _cancelled = false;

    _ticker  = Timer.periodic(const Duration(milliseconds: 500), (_) => _sample());
    _stopper = Timer(Duration(seconds: duration), () { if (!_cancelled) _finish(); });

    try {
      await Future.wait(List.generate(threads, (_) => _stream()));
    } catch (e) {
      if (!_cancelled) _onError(e.toString());
    }
  }

  Future<void> _stream() async {
    while (!_cancelled) {
      final client = http.Client();
      _clients.add(client);
      try {
        final res = await client.send(http.Request('GET', Uri.parse(_testUrl)));
        await for (final chunk in res.stream) {
          if (_cancelled) break;
          bytesTotal += chunk.length;
          elapsedMs   = DateTime.now().difference(_start!).inMilliseconds;
          progress    = (elapsedMs / (duration * 1000)).clamp(0.0, 1.0);
        }
      } catch (_) {
      } finally {
        _clients.remove(client);
        client.close();
      }
    }
  }

  void _sample() {
    final delta = bytesTotal - _lastBytes;
    _lastBytes  = bytesTotal;
    speedMbps   = (delta * 8) / 500000;
    if (speedMbps > peakMbps) peakMbps = speedMbps;
    elapsedMs = DateTime.now().difference(_start!).inMilliseconds;
    progress  = (elapsedMs / (duration * 1000)).clamp(0.0, 1.0);
    history.add(speedMbps);
    notifyListeners();
  }

  void _finish() {
    _cancelled = true;
    _ticker?.cancel(); _stopper?.cancel();
    for (final c in _clients) c.close();
    _clients.clear();
    avgMbps  = (bytesTotal * 8) / (duration * 1000000.0);
    progress = 1.0;
    state    = TestState.done;
    notifyListeners();
  }

  void _onError(String msg) {
    _cancelled = true;
    _ticker?.cancel(); _stopper?.cancel();
    for (final c in _clients) c.close();
    _clients.clear();
    state = TestState.error;
    error = msg;
    notifyListeners();
  }

  void _resetCounters() {
    _cancelled = true;
    _ticker?.cancel(); _stopper?.cancel();
    for (final c in _clients) c.close();
    _clients.clear();
    speedMbps = peakMbps = avgMbps = progress = 0;
    bytesTotal = elapsedMs = 0;
    error      = null;
    _lastBytes = 0;
    history.clear();
  }

  void reset() {
    _resetCounters();
    state = TestState.idle;
    notifyListeners();
  }

  @override
  void dispose() { _resetCounters(); super.dispose(); }
}

// ── App ───────────────────────────────────────────────────────────────────────

class STDApp extends StatelessWidget {
  const STDApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Speed Test',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(primary: _accentA, surface: _surface),
        sliderTheme: SliderThemeData(
          activeTrackColor: _accentA,
          inactiveTrackColor: _border,
          thumbColor: _accentA,
          overlayColor: _accentA.withOpacity(0.15),
          trackHeight: 3,
        ),
      ),
      home: const SpeedPage(),
    );
  }
}

// ── Page ──────────────────────────────────────────────────────────────────────

class SpeedPage extends StatefulWidget {
  const SpeedPage({super.key});
  @override
  State<SpeedPage> createState() => _SpeedPageState();
}

class _SpeedPageState extends State<SpeedPage>
    with TickerProviderStateMixin {

  final SpeedController _ctrl = SpeedController();
  late AnimationController _needleCtrl;
  late AnimationController _pulseCtrl;
  late AnimationController _glowCtrl;
  double _displaySpeed = 0;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onUpdate);

    _needleCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 600));
    _pulseCtrl  = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 1600))
      ..repeat(reverse: true);
    _glowCtrl   = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  void _onUpdate() {
    final target = _ctrl.state == TestState.done
        ? _ctrl.avgMbps : _ctrl.speedMbps;
    setState(() { _displaySpeed = target; });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _needleCtrl.dispose();
    _pulseCtrl.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  String _fmtBytes(int b) {
    if (b < 1048576)    return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1073741824).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.4),
              radius: 1.2,
              colors: [Color(0xFF0D1830), Color(0xFF0A0E1A)],
            ),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 32),
                  _buildGaugeMeter(),
                  const SizedBox(height: 28),
                  _buildSpeedDisplay(),
                  const SizedBox(height: 20),
                  _buildStartButton(),
                  const SizedBox(height: 24),
                  _buildStatsRow(),
                  const SizedBox(height: 20),
                  _buildProgressBar(),
                  if (_ctrl.history.length > 2) ...[
                    const SizedBox(height: 20),
                    _buildSparkline(),
                  ],
                  const SizedBox(height: 20),
                  _buildSettings(),
                  if (_ctrl.state == TestState.error) ...[
                    const SizedBox(height: 16),
                    Center(child: Text(_ctrl.error ?? 'Unknown error',
                        style: const TextStyle(fontSize: 12, color: _red))),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Row(children: [
      Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
              colors: [_accentA, _accentB],
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          boxShadow: [BoxShadow(color: _accentA.withOpacity(0.4),
              blurRadius: 12)],
        ),
        child: const Icon(Icons.speed_rounded, color: Colors.white, size: 20),
      ),
      const SizedBox(width: 10),
      const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('SPEED TEST',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900,
                color: Colors.white, letterSpacing: 2.5)),
        Text('Download Speed Meter',
            style: TextStyle(fontSize: 10, color: _textSub, letterSpacing: 0.5)),
      ]),
      const Spacer(),
      _buildStatusChip(),
    ]);
  }

  Widget _buildStatusChip() {
    Color c; String t;
    switch (_ctrl.state) {
      case TestState.running: c = _accentA; t = 'LIVE';   break;
      case TestState.done:    c = _green;   t = 'DONE';   break;
      case TestState.error:   c = _red;     t = 'ERROR';  break;
      default:                c = _textSub; t = 'READY';
    }
    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (_, child) => Opacity(
        opacity: _ctrl.state == TestState.running
            ? 0.6 + 0.4 * _pulseCtrl.value : 1.0,
        child: child,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: c.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.withOpacity(0.4)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 6, height: 6,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(t, style: TextStyle(fontSize: 10,
              fontWeight: FontWeight.w800, color: c, letterSpacing: 1.5)),
        ]),
      ),
    );
  }

  // ── Arc Gauge Meter ──────────────────────────────────────────────────────

  Widget _buildGaugeMeter() {
    return Center(
      child: AnimatedBuilder(
        animation: Listenable.merge([_pulseCtrl, _glowCtrl]),
        builder: (_, __) {
          final ratio = (_displaySpeed / _maxScale).clamp(0.0, 1.0);
          final glowIntensity = _ctrl.state == TestState.running
              ? 0.6 + 0.4 * _glowCtrl.value : 0.4;
          return SizedBox(
            width: 280, height: 200,
            child: CustomPaint(
              painter: GaugePainter(
                ratio: ratio,
                isRunning: _ctrl.state == TestState.running,
                glowIntensity: glowIntensity,
                pulseValue: _pulseCtrl.value,
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Speed Display ─────────────────────────────────────────────────────────

  Widget _buildSpeedDisplay() {
    final speed = _displaySpeed;
    return Column(children: [
      TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: speed),
        duration: const Duration(milliseconds: 400),
        builder: (_, v, __) => Text(
          v.toStringAsFixed(1),
          style: const TextStyle(
            fontSize: 72,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            height: 1,
            letterSpacing: -3,
          ),
        ),
      ),
      const SizedBox(height: 4),
      const Text('Mbps',
          style: TextStyle(fontSize: 14, color: _textSub,
              letterSpacing: 3, fontWeight: FontWeight.w600)),
    ]);
  }

  // ── Start / Stop Button ──────────────────────────────────────────────────

  Widget _buildStartButton() {
    final isRunning = _ctrl.state == TestState.running;
    final isDone    = _ctrl.state == TestState.done;
    final isError   = _ctrl.state == TestState.error;

    String label; Color c1; Color c2; IconData icon;
    if (isRunning) {
      label = 'STOP'; c1 = const Color(0xFFFF5252);
      c2 = const Color(0xFFFF1744); icon = Icons.stop_rounded;
    } else if (isDone || isError) {
      label = 'TEST AGAIN'; c1 = _accentA;
      c2 = _accentB; icon = Icons.refresh_rounded;
    } else {
      label = 'START'; c1 = _accentA;
      c2 = _accentB; icon = Icons.play_arrow_rounded;
    }

    return Center(
      child: GestureDetector(
        onTap: _ctrl.toggle,
        child: AnimatedBuilder(
          animation: _pulseCtrl,
          builder: (_, child) => Transform.scale(
            scale: isRunning ? 0.97 + 0.03 * _pulseCtrl.value : 1.0,
            child: child,
          ),
          child: Container(
            height: 56,
            width: 200,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: LinearGradient(colors: [c1, c2],
                  begin: Alignment.topLeft, end: Alignment.bottomRight),
              boxShadow: [
                BoxShadow(color: c1.withOpacity(isRunning ? 0.6 : 0.35),
                    blurRadius: isRunning ? 24 : 16,
                    offset: const Offset(0, 6)),
              ],
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w800,
                  color: Colors.white, letterSpacing: 2)),
            ]),
          ),
        ),
      ),
    );
  }

  // ── Stats Row ─────────────────────────────────────────────────────────────

  Widget _buildStatsRow() {
    return Row(children: [
      _statCard('LIVE', '${_ctrl.speedMbps.toStringAsFixed(1)}', _accentA,
          Icons.bolt_rounded),
      const SizedBox(width: 10),
      _statCard('PEAK', '${_ctrl.peakMbps.toStringAsFixed(1)}', _yellow,
          Icons.trending_up_rounded),
      const SizedBox(width: 10),
      _statCard('AVG', _ctrl.state == TestState.done
          ? _ctrl.avgMbps.toStringAsFixed(1) : '--', _green,
          Icons.equalizer_rounded),
    ]);
  }

  Widget _statCard(String label, String value, Color color, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _border),
          boxShadow: [BoxShadow(color: color.withOpacity(0.08),
              blurRadius: 16, spreadRadius: -2)],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 9,
                fontWeight: FontWeight.w800, color: color, letterSpacing: 1.5)),
          ]),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(fontSize: 20,
              fontWeight: FontWeight.w800, color: color, height: 1)),
          Text('Mbps', style: const TextStyle(fontSize: 9, color: _textSub)),
        ]),
      ),
    );
  }

  // ── Progress Bar ──────────────────────────────────────────────────────────

  Widget _buildProgressBar() {
    final isRunning = _ctrl.state == TestState.running;
    final elapsed   = (_ctrl.elapsedMs / 1000)
        .clamp(0.0, _ctrl.duration.toDouble());

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('PROGRESS', style: const TextStyle(fontSize: 10,
            fontWeight: FontWeight.w700, color: _textSub, letterSpacing: 1.5)),
        Text(isRunning
            ? '${elapsed.toStringAsFixed(1)}s / ${_ctrl.duration}s'
            : _fmtBytes(_ctrl.bytesTotal),
            style: const TextStyle(fontSize: 10, color: _textSub)),
      ]),
      const SizedBox(height: 8),
      Stack(children: [
        Container(height: 6,
            decoration: BoxDecoration(
                color: _border, borderRadius: BorderRadius.circular(3))),
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 6,
          width: (MediaQuery.of(context).size.width - 40) * _ctrl.progress,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            gradient: const LinearGradient(colors: [_accentA, _accentB]),
            boxShadow: [BoxShadow(color: _accentA.withOpacity(0.5),
                blurRadius: 6)],
          ),
        ),
      ]),
    ]);
  }

  // ── Sparkline ─────────────────────────────────────────────────────────────

  Widget _buildSparkline() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('SPEED HISTORY', style: TextStyle(fontSize: 10,
          fontWeight: FontWeight.w700, color: _textSub, letterSpacing: 1.5)),
      const SizedBox(height: 8),
      Container(
        height: 60,
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: CustomPaint(
            painter: SparklinePainter(samples: _ctrl.history),
            size: const Size(double.infinity, 60),
          ),
        ),
      ),
    ]);
  }

  // ── Settings ──────────────────────────────────────────────────────────────

  Widget _buildSettings() {
    return Column(children: [
      _settingRow('THREADS', '${_ctrl.threads}',
          _ctrl.threads.toDouble(), 1, 32,
          [4, 8, 16, 32], _ctrl.threads,
          (v) => _ctrl.setThreads(v.round()), _ctrl.setThreads),
      const SizedBox(height: 12),
      _settingRow('DURATION', '${_ctrl.duration}s',
          _ctrl.duration.toDouble(), 5, 30,
          [5, 10, 15, 30], _ctrl.duration,
          (v) => _ctrl.setDuration(v.round()), _ctrl.setDuration),
    ]);
  }

  Widget _settingRow(String label, String display,
      double val, double min, double max,
      List<int> presets, int selected,
      ValueChanged<double> onSlider, ValueChanged<int> onPreset) {
    final disabled = _ctrl.state == TestState.running;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(fontSize: 11,
              fontWeight: FontWeight.w800, color: _textSub, letterSpacing: 1.5)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
                color: _accentA.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _accentA.withOpacity(0.25))),
            child: Text(display, style: const TextStyle(fontSize: 12,
                fontWeight: FontWeight.w800, color: _accentA)),
          ),
        ]),
        Slider(value: val, min: min, max: max,
            divisions: (max - min).round(),
            onChanged: disabled ? null : onSlider),
        Row(mainAxisAlignment: MainAxisAlignment.end,
            children: presets.map((t) {
              final sel = selected == t;
              return Padding(
                padding: const EdgeInsets.only(left: 6),
                child: GestureDetector(
                  onTap: disabled ? null : () => onPreset(t),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: sel ? _accentA.withOpacity(0.15) : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: sel ? _accentA.withOpacity(0.5) : _textDim),
                    ),
                    child: Text('$t', style: TextStyle(fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: sel ? _accentA : _textSub)),
                  ),
                ),
              );
            }).toList()),
      ]),
    );
  }
}

// ── Gauge Painter ─────────────────────────────────────────────────────────────

class GaugePainter extends CustomPainter {
  final double ratio;
  final bool   isRunning;
  final double glowIntensity;
  final double pulseValue;

  const GaugePainter({
    required this.ratio,
    required this.isRunning,
    required this.glowIntensity,
    required this.pulseValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.88;
    final r  = size.width * 0.44;

    const startAngle = math.pi;
    const sweepFull  = math.pi;

    // ── Background arc ──
    final bgPaint = Paint()
      ..color = const Color(0xFF1A2540)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: r),
        startAngle, sweepFull, false, bgPaint);

    // ── Tick marks ──
    _drawTicks(canvas, cx, cy, r);

    // ── Speed arc ──
    if (ratio > 0) {
      final sweep = sweepFull * ratio;
      final arcColor = _arcColor(ratio);

      // glow
      final glowPaint = Paint()
        ..shader = SweepGradient(
          startAngle: startAngle,
          endAngle: startAngle + sweep,
          colors: [arcColor.withOpacity(0), arcColor.withOpacity(glowIntensity * 0.5)],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 30
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
      canvas.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: r),
          startAngle, sweep, false, glowPaint);

      // main arc
      final arcPaint = Paint()
        ..shader = _arcShader(ratio, startAngle, sweep, cx, cy, r)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: r),
          startAngle, sweep, false, arcPaint);

      // tip dot
      final tipAngle = startAngle + sweep;
      final tipX = cx + r * math.cos(tipAngle);
      final tipY = cy + r * math.sin(tipAngle);
      canvas.drawCircle(Offset(tipX, tipY), 7,
          Paint()..color = arcColor
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      canvas.drawCircle(Offset(tipX, tipY), 5,
          Paint()..color = Colors.white);
    }

    // ── Labels ──
    _drawLabels(canvas, cx, cy, r);
  }

  Color _arcColor(double ratio) {
    if (ratio < 0.4) return const Color(0xFF00C2FF);
    if (ratio < 0.75) return const Color(0xFF00E0FF);
    return const Color(0xFF00FFCC);
  }

  Shader _arcShader(double ratio, double start, double sweep, double cx, double cy, double r) {
    return SweepGradient(
      startAngle: start,
      endAngle: start + sweep,
      colors: const [Color(0xFF0066FF), Color(0xFF00C2FF), Color(0xFF00FFD0)],
    ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
  }

  void _drawTicks(Canvas canvas, double cx, double cy, double r) {
    const total = 10;
    for (int i = 0; i <= total; i++) {
      final angle = math.pi + (math.pi * i / total);
      final isMajor = i % 5 == 0;
      final inner = r - (isMajor ? 14 : 8);
      final x1 = cx + (r + 2) * math.cos(angle);
      final y1 = cy + (r + 2) * math.sin(angle);
      final x2 = cx + inner * math.cos(angle);
      final y2 = cy + inner * math.sin(angle);
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2),
          Paint()
            ..color = isMajor
                ? const Color(0xFF2D4570)
                : const Color(0xFF1E2E48)
            ..strokeWidth = isMajor ? 2 : 1
            ..strokeCap = StrokeCap.round);
    }
  }

  void _drawLabels(Canvas canvas, double cx, double cy, double r) {
    final labels = {0: '0', 0.25: '250', 0.5: '500', 0.75: '750', 1.0: '1G'};
    labels.forEach((ratio, text) {
      final angle = math.pi + math.pi * ratio;
      final lx = cx + (r - 28) * math.cos(angle);
      final ly = cy + (r - 28) * math.sin(angle);
      final tp = TextPainter(
        text: TextSpan(text: text,
            style: const TextStyle(fontSize: 9, color: Color(0xFF3A5070),
                fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(lx - tp.width / 2, ly - tp.height / 2));
    });
  }

  @override
  bool shouldRepaint(GaugePainter old) =>
      old.ratio != ratio || old.isRunning != isRunning ||
      old.glowIntensity != glowIntensity;
}

// ── Sparkline Painter ─────────────────────────────────────────────────────────

class SparklinePainter extends CustomPainter {
  final List<double> samples;
  const SparklinePainter({required this.samples});

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;
    final maxV = samples.reduce(math.max).clamp(1.0, double.infinity);
    final pts = <Offset>[];
    for (int i = 0; i < samples.length; i++) {
      final x = size.width * i / (samples.length - 1);
      final y = size.height - (samples[i] / maxV) * size.height * 0.85;
      pts.add(Offset(x, y));
    }
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (int i = 1; i < pts.length; i++) {
      final prev = pts[i - 1];
      final curr = pts[i];
      final cp1 = Offset((prev.dx + curr.dx) / 2, prev.dy);
      final cp2 = Offset((prev.dx + curr.dx) / 2, curr.dy);
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, curr.dx, curr.dy);
    }
    // fill
    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fillPath, Paint()
      ..shader = LinearGradient(
        colors: [const Color(0xFF00C2FF).withOpacity(0.3), Colors.transparent],
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
      ).createShader(Offset.zero & size)
      ..style = PaintingStyle.fill);
    // line
    canvas.drawPath(path, Paint()
      ..color = const Color(0xFF00C2FF)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(SparklinePainter old) => old.samples.length != samples.length;
}
