import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const STDApp());
}

// ── Colors ────────────────────────────────────────────────────────────────────

const Color _bg      = Color(0xFF0A0E1A);
const Color _surface = Color(0xFF121828);
const Color _border  = Color(0xFF1E2740);
const Color _accentA = Color(0xFF00C2FF);
const Color _accentB = Color(0xFF0066FF);
const Color _green   = Color(0xFF00E676);
const Color _yellow  = Color(0xFFFFD740);
const Color _red     = Color(0xFFFF5252);
const Color _textSub = Color(0xFF5A7090);

const String _testUrl = 'https://ash-speed.hetzner.com/100MB.bin';

// ── Dynamic gauge scale ───────────────────────────────────────────────────────

double _scaleForSpeed(double mbps) {
  if (mbps >= 500) return 1000;
  if (mbps >= 100) return 500;
  if (mbps >= 50)  return 100;
  return 50;
}

// ── State ─────────────────────────────────────────────────────────────────────

enum TestState { idle, running, done, error }

// ── Controller ────────────────────────────────────────────────────────────────

class SpeedController extends ChangeNotifier {
  TestState state    = TestState.idle;
  int       threads  = 8;
  int       duration = 10;
  double    speedMbps = 0, peakMbps = 0, avgMbps = 0;
  double    progress  = 0;
  int       bytesTotal = 0, elapsedMs = 0;
  String?   error;

  final List<http.Client> _clients = [];
  Timer?   _ticker, _stopper;
  int      _lastBytes = 0;
  DateTime? _start;
  bool     _cancelled = false;

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

class _SpeedPageState extends State<SpeedPage> with TickerProviderStateMixin {

  final SpeedController _ctrl = SpeedController();

  late AnimationController _pulseCtrl;
  late AnimationController _glowCtrl;
  late AnimationController _scaleAnimCtrl;
  late Animation<double>   _scaleAnim;

  double _gaugeScale     = 50;   // current displayed scale
  double _targetScale    = 50;   // where we're animating toward
  double _displaySpeed   = 0;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onUpdate);

    _pulseCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 1400))..repeat(reverse: true);

    _glowCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 900))..repeat(reverse: true);

    _scaleAnimCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 600));
    _scaleAnim = Tween<double>(begin: 50, end: 50).animate(
        CurvedAnimation(parent: _scaleAnimCtrl, curve: Curves.easeInOut));
    _scaleAnim.addListener(() {
      setState(() { _gaugeScale = _scaleAnim.value; });
    });
  }

  void _onUpdate() {
    final speed = _ctrl.state == TestState.done
        ? _ctrl.avgMbps : _ctrl.speedMbps;
    setState(() { _displaySpeed = speed; });

    if (_ctrl.state == TestState.running) {
      final needed = _scaleForSpeed(_ctrl.peakMbps);
      if (needed != _targetScale) {
        _targetScale = needed;
        _scaleAnim = Tween<double>(begin: _gaugeScale, end: needed).animate(
            CurvedAnimation(parent: _scaleAnimCtrl, curve: Curves.easeInOut));
        _scaleAnimCtrl
          ..reset()
          ..forward();
      }
    }
    if (_ctrl.state == TestState.idle) {
      _targetScale = 50;
      _gaugeScale  = 50;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _pulseCtrl.dispose();
    _glowCtrl.dispose();
    _scaleAnimCtrl.dispose();
    super.dispose();
  }

  void _openSettings() {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.6),
      builder: (_) => _SettingsDialog(ctrl: _ctrl),
    );
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
              center: Alignment(0, -0.5),
              radius: 1.1,
              colors: [Color(0xFF0D1830), Color(0xFF0A0E1A)],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Spacer(flex: 1),
                        _buildGaugeMeter(),
                        const SizedBox(height: 12),
                        _buildSpeedDisplay(),
                        const Spacer(flex: 1),
                        _buildStartButton(),
                        const SizedBox(height: 32),
                        _buildStatsRow(),
                        const Spacer(flex: 1),
                        _buildProgressBar(),
                        const SizedBox(height: 32),
                        if (_ctrl.state == TestState.error)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(_ctrl.error ?? 'Unknown error',
                                style: const TextStyle(fontSize: 12, color: _red)),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 0),
      child: Row(children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
                colors: [_accentA, _accentB],
                begin: Alignment.topLeft, end: Alignment.bottomRight),
            boxShadow: [BoxShadow(color: _accentA.withOpacity(0.35), blurRadius: 10)],
          ),
          child: const Icon(Icons.speed_rounded, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        const Text('SPEED TEST',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900,
                color: Colors.white, letterSpacing: 2.5)),
        const Spacer(),
        IconButton(
          onPressed: _openSettings,
          icon: const Icon(Icons.tune_rounded, color: _textSub, size: 22),
          tooltip: 'Settings',
        ),
      ]),
    );
  }

  // ── Arc Gauge ─────────────────────────────────────────────────────────────

  Widget _buildGaugeMeter() {
    return AnimatedBuilder(
      animation: Listenable.merge([_glowCtrl]),
      builder: (_, __) {
        final ratio = (_displaySpeed / _gaugeScale).clamp(0.0, 1.0);
        final glowI = _ctrl.state == TestState.running
            ? 0.55 + 0.45 * _glowCtrl.value : 0.3;
        return SizedBox(
          width: 300, height: 180,
          child: CustomPaint(
            painter: GaugePainter(
              ratio: ratio,
              maxScale: _gaugeScale,
              isRunning: _ctrl.state == TestState.running,
              glowIntensity: glowI,
            ),
          ),
        );
      },
    );
  }

  // ── Speed number ──────────────────────────────────────────────────────────

  Widget _buildSpeedDisplay() {
    return Column(children: [
      TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: _displaySpeed),
        duration: const Duration(milliseconds: 350),
        builder: (_, v, __) => Text(
          v.toStringAsFixed(1),
          style: const TextStyle(
            fontSize: 68, fontWeight: FontWeight.w900,
            color: Colors.white, height: 1, letterSpacing: -3,
          ),
        ),
      ),
      const Text('Mbps', style: TextStyle(fontSize: 13, color: _textSub,
          letterSpacing: 3, fontWeight: FontWeight.w600)),
    ]);
  }

  // ── Start / Stop button ───────────────────────────────────────────────────

  Widget _buildStartButton() {
    final isRunning = _ctrl.state == TestState.running;
    final isRetry   = _ctrl.state == TestState.done || _ctrl.state == TestState.error;

    final String label;
    final Color  c1, c2;
    final IconData icon;

    if (isRunning) {
      label = 'STOP'; c1 = _red; c2 = const Color(0xFFFF1744);
      icon  = Icons.stop_rounded;
    } else if (isRetry) {
      label = 'TEST AGAIN'; c1 = _accentA; c2 = _accentB;
      icon  = Icons.refresh_rounded;
    } else {
      label = 'START'; c1 = _accentA; c2 = _accentB;
      icon  = Icons.play_arrow_rounded;
    }

    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (_, child) => Transform.scale(
        scale: isRunning ? 0.97 + 0.03 * _pulseCtrl.value : 1.0,
        child: child,
      ),
      child: GestureDetector(
        onTap: _ctrl.toggle,
        child: Container(
          height: 56, width: 200,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(colors: [c1, c2],
                begin: Alignment.topLeft, end: Alignment.bottomRight),
            boxShadow: [BoxShadow(
                color: c1.withOpacity(isRunning ? 0.65 : 0.35),
                blurRadius: isRunning ? 26 : 18,
                offset: const Offset(0, 6))],
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 14,
                fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 1.5)),
          ]),
        ),
      ),
    );
  }

  // ── Peak & Avg stats ──────────────────────────────────────────────────────

  Widget _buildStatsRow() {
    return Row(children: [
      _statCard('PEAK', '${_ctrl.peakMbps.toStringAsFixed(1)}', _yellow,
          Icons.trending_up_rounded),
      const SizedBox(width: 12),
      _statCard('AVG', _ctrl.state == TestState.done
          ? _ctrl.avgMbps.toStringAsFixed(1) : '--', _green,
          Icons.equalizer_rounded),
    ]);
  }

  Widget _statCard(String label, String value, Color color, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _border),
          boxShadow: [BoxShadow(color: color.withOpacity(0.07),
              blurRadius: 16, spreadRadius: -2)],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 9,
                fontWeight: FontWeight.w800, color: color, letterSpacing: 1.5)),
          ]),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(fontSize: 22,
              fontWeight: FontWeight.w800, color: color, height: 1)),
          const Text('Mbps', style: TextStyle(fontSize: 9, color: _textSub)),
        ]),
      ),
    );
  }

  // ── Progress bar ──────────────────────────────────────────────────────────

  Widget _buildProgressBar() {
    final isRunning = _ctrl.state == TestState.running;
    final elapsed   = (_ctrl.elapsedMs / 1000)
        .clamp(0.0, _ctrl.duration.toDouble());

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(isRunning
            ? '${elapsed.toStringAsFixed(1)}s / ${_ctrl.duration}s'
            : _ctrl.state == TestState.idle ? '' : '${_ctrl.duration}s',
            style: const TextStyle(fontSize: 10, color: _textSub)),
        Text(_ctrl.bytesTotal > 0 ? _fmtBytes(_ctrl.bytesTotal) : '',
            style: const TextStyle(fontSize: 10, color: _textSub)),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Stack(children: [
          Container(height: 5, color: _border),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 5,
            width: (MediaQuery.of(context).size.width - 48) * _ctrl.progress,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [_accentA, _accentB]),
              boxShadow: [BoxShadow(color: _accentA.withOpacity(0.5), blurRadius: 6)],
            ),
          ),
        ]),
      ),
    ]);
  }

  String _fmtBytes(int b) {
    if (b < 1048576)    return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1073741824).toStringAsFixed(2)} GB';
  }
}

// ── Settings Dialog ───────────────────────────────────────────────────────────

class _SettingsDialog extends StatefulWidget {
  final SpeedController ctrl;
  const _SettingsDialog({required this.ctrl});
  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late int _threads;
  late int _duration;

  @override
  void initState() {
    super.initState();
    _threads  = widget.ctrl.threads;
    _duration = widget.ctrl.duration;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFF121828),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF1E2740)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.6),
              blurRadius: 40, spreadRadius: 8)],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Title
          Row(children: [
            const Icon(Icons.tune_rounded, color: _accentA, size: 18),
            const SizedBox(width: 8),
            const Text('Settings', style: TextStyle(fontSize: 16,
                fontWeight: FontWeight.w800, color: Colors.white)),
            const Spacer(),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: const Icon(Icons.close_rounded, color: _textSub, size: 20),
            ),
          ]),
          const SizedBox(height: 24),

          // Threads
          _buildSetting(
            label: 'Threads',
            value: '$_threads',
            sliderVal: _threads.toDouble(),
            min: 1, max: 32,
            presets: [4, 8, 16, 32],
            selected: _threads,
            onSlider: (v) => setState(() => _threads = v.round()),
            onPreset: (v) => setState(() => _threads = v),
          ),
          const SizedBox(height: 20),

          // Duration
          _buildSetting(
            label: 'Duration',
            value: '${_duration}s',
            sliderVal: _duration.toDouble(),
            min: 5, max: 30,
            presets: [5, 10, 15, 30],
            selected: _duration,
            onSlider: (v) => setState(() => _duration = v.round()),
            onPreset: (v) => setState(() => _duration = v),
          ),
          const SizedBox(height: 28),

          // Apply button
          GestureDetector(
            onTap: () {
              widget.ctrl.setThreads(_threads);
              widget.ctrl.setDuration(_duration);
              Navigator.of(context).pop();
            },
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: const LinearGradient(
                    colors: [_accentA, _accentB],
                    begin: Alignment.topLeft, end: Alignment.bottomRight),
                boxShadow: [BoxShadow(color: _accentA.withOpacity(0.3),
                    blurRadius: 14, offset: const Offset(0, 4))],
              ),
              child: const Center(
                child: Text('Apply', style: TextStyle(fontSize: 14,
                    fontWeight: FontWeight.w800, color: Colors.white,
                    letterSpacing: 1)),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildSetting({
    required String label, required String value,
    required double sliderVal, required double min, required double max,
    required List<int> presets, required int selected,
    required ValueChanged<double> onSlider, required ValueChanged<int> onPreset,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: const TextStyle(fontSize: 12,
            fontWeight: FontWeight.w700, color: Colors.white)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: _accentA.withOpacity(0.1),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: _accentA.withOpacity(0.25)),
          ),
          child: Text(value, style: const TextStyle(fontSize: 12,
              fontWeight: FontWeight.w800, color: _accentA)),
        ),
      ]),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: _accentA,
          inactiveTrackColor: const Color(0xFF1E2740),
          thumbColor: _accentA,
          overlayColor: _accentA.withOpacity(0.15),
          trackHeight: 3,
        ),
        child: Slider(value: sliderVal, min: min, max: max,
            divisions: (max - min).round(), onChanged: onSlider),
      ),
      Row(mainAxisAlignment: MainAxisAlignment.end,
          children: presets.map((t) {
            final sel = selected == t;
            return Padding(
              padding: const EdgeInsets.only(left: 8),
              child: GestureDetector(
                onTap: () => onPreset(t),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: sel ? _accentA.withOpacity(0.15) : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: sel ? _accentA.withOpacity(0.5) : const Color(0xFF2D4060)),
                  ),
                  child: Text('$t', style: TextStyle(fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: sel ? _accentA : _textSub)),
                ),
              ),
            );
          }).toList()),
    ]);
  }
}

// ── Gauge Painter ─────────────────────────────────────────────────────────────

class GaugePainter extends CustomPainter {
  final double ratio;
  final double maxScale;
  final bool   isRunning;
  final double glowIntensity;

  const GaugePainter({
    required this.ratio,
    required this.maxScale,
    required this.isRunning,
    required this.glowIntensity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.92;
    final r  = size.width * 0.43;

    const startAngle = math.pi;
    const sweepFull  = math.pi;

    // background arc
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      startAngle, sweepFull, false,
      Paint()
        ..color = const Color(0xFF1A2540)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.round,
    );

    _drawTicks(canvas, cx, cy, r);

    if (ratio > 0) {
      final sweep = sweepFull * ratio;

      // glow
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: r),
        startAngle, sweep, false,
        Paint()
          ..shader = SweepGradient(
            startAngle: startAngle,
            endAngle: startAngle + sweep,
            colors: [
              const Color(0xFF0066FF).withOpacity(0),
              const Color(0xFF00C2FF).withOpacity(glowIntensity * 0.55),
            ],
          ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 28
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );

      // main arc
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: r),
        startAngle, sweep, false,
        Paint()
          ..shader = SweepGradient(
            startAngle: startAngle,
            endAngle: startAngle + sweep,
            colors: const [Color(0xFF0066FF), Color(0xFF00C2FF), Color(0xFF00FFD0)],
          ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 14
          ..strokeCap = StrokeCap.round,
      );

      // tip dot
      final tipAngle = startAngle + sweep;
      final tipX = cx + r * math.cos(tipAngle);
      final tipY = cy + r * math.sin(tipAngle);
      canvas.drawCircle(Offset(tipX, tipY), 6,
          Paint()..color = const Color(0xFF00C2FF)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      canvas.drawCircle(Offset(tipX, tipY), 4, Paint()..color = Colors.white);
    }

    _drawLabels(canvas, cx, cy, r);
  }

  void _drawTicks(Canvas canvas, double cx, double cy, double r) {
    const total = 10;
    for (int i = 0; i <= total; i++) {
      final angle  = math.pi + (math.pi * i / total);
      final isMajor = i % 5 == 0;
      final inner  = r - (isMajor ? 12 : 7);
      canvas.drawLine(
        Offset(cx + (r + 2) * math.cos(angle), cy + (r + 2) * math.sin(angle)),
        Offset(cx + inner * math.cos(angle),    cy + inner * math.sin(angle)),
        Paint()
          ..color = isMajor ? const Color(0xFF2D4570) : const Color(0xFF1E2E48)
          ..strokeWidth = isMajor ? 2 : 1
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _drawLabels(Canvas canvas, double cx, double cy, double r) {
    // Show 0, 25%, 50%, 75%, 100% of current maxScale
    final Map<double, String> labels = {
      0.0:  '0',
      0.25: _fmtScale(maxScale * 0.25),
      0.5:  _fmtScale(maxScale * 0.5),
      0.75: _fmtScale(maxScale * 0.75),
      1.0:  _fmtScale(maxScale),
    };
    labels.forEach((frac, text) {
      final angle = math.pi + math.pi * frac;
      final lx = cx + (r - 24) * math.cos(angle);
      final ly = cy + (r - 24) * math.sin(angle);
      final tp = TextPainter(
        text: TextSpan(text: text,
            style: const TextStyle(fontSize: 8.5, color: Color(0xFF3A5070),
                fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(lx - tp.width / 2, ly - tp.height / 2));
    });
  }

  String _fmtScale(double v) {
    if (v >= 1000) return '1G';
    if (v >= 100 && v == v.truncateToDouble()) return '${v.toInt()}';
    return v < 10 ? v.toStringAsFixed(1) : '${v.toInt()}';
  }

  @override
  bool shouldRepaint(GaugePainter old) =>
      old.ratio != ratio || old.maxScale != maxScale ||
      old.glowIntensity != glowIntensity;
}
