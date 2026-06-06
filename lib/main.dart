import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const STDApp());
}

const Color _bg      = Color(0xFF0C0C0E);
const Color _surface = Color(0xFF161618);
const Color _border  = Color(0xFF252528);
const Color _accent  = Color(0xFFED482B);
const Color _textSub = Color(0xFF888890);

const String _testUrl = 'https://ash-speed.hetzner.com/100MB.bin';

enum TestState { idle, running, done, error }

// ── Controller ────────────────────────────────────────────────────────────────

class SpeedController extends ChangeNotifier {
  TestState state = TestState.idle;
  int threads  = 8;
  int duration = 10;
  double speedMbps = 0, peakMbps = 0, avgMbps = 0;
  double progress  = 0;
  int bytesTotal = 0, elapsedMs = 0;
  String? error;

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
    await _start_test();
  }

  Future<void> _start_test() async {
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
          notifyListeners();
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
      title: 'STD',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(primary: _accent, surface: _surface),
        sliderTheme: SliderThemeData(
          activeTrackColor: _accent,
          inactiveTrackColor: _border,
          thumbColor: _accent,
          overlayColor: _accent.withOpacity(0.15),
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
    with SingleTickerProviderStateMixin {
  final SpeedController _ctrl = SpeedController();
  late AnimationController _pulse;
  late Animation<double>   _pulseAnim;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() {}));

    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.94, end: 1.0).animate(
        CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); _pulse.dispose(); super.dispose(); }

  Color get _stateColor {
    switch (_ctrl.state) {
      case TestState.running: return _accent;
      case TestState.done:    return const Color(0xFF30D158);
      case TestState.error:   return const Color(0xFFFF453A);
      default:                return const Color(0xFF3A3A3E);
    }
  }

  String _fmtBytes(int b) {
    if (b < 1048576)    return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1073741824).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                const SizedBox(height: 40),
                _gauge(),
                const SizedBox(height: 32),
                _progressRow(),
                const SizedBox(height: 24),
                _statsRow(),
                const SizedBox(height: 24),
                _selector('Threads', '${_ctrl.threads}',
                    _ctrl.threads.toDouble(), 1, 32,
                    [4, 8, 16, 32], _ctrl.threads,
                    (v) => _ctrl.setThreads(v.round()), _ctrl.setThreads),
                const SizedBox(height: 12),
                _selector('Duration', '${_ctrl.duration}s',
                    _ctrl.duration.toDouble(), 5, 30,
                    [5, 10, 15, 30], _ctrl.duration,
                    (v) => _ctrl.setDuration(v.round()), _ctrl.setDuration),
                if (_ctrl.state == TestState.error) ...[
                  const SizedBox(height: 16),
                  Center(child: Text(_ctrl.error ?? 'Unknown error',
                      style: const TextStyle(fontSize: 12,
                          color: Color(0xFFFF453A)))),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Header ──

  Widget _header() {
    return Row(children: [
      Image.asset('assets/logo.png', width: 30, height: 30,
          errorBuilder: (_, __, ___) =>
              const Icon(Icons.wifi_tethering_rounded, color: _accent, size: 30)),
      const SizedBox(width: 10),
      const Text('STD', style: TextStyle(fontSize: 20,
          fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 1.5)),
      const Spacer(),
      // Status badge
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _statusBadge(),
      ),
    ]);
  }

  Widget _statusBadge() {
    switch (_ctrl.state) {
      case TestState.running:
        return _badge('Testing...', _accent);
      case TestState.done:
        return _badge('Done  ✓', const Color(0xFF30D158));
      case TestState.error:
        return _badge('Error', const Color(0xFFFF453A));
      default:
        return _badge('Tap to start', _textSub);
    }
  }

  Widget _badge(String text, Color color) {
    return Container(
      key: ValueKey(text),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(text, style: TextStyle(fontSize: 12,
          fontWeight: FontWeight.w600, color: color)),
    );
  }

  // ── Gauge (tap to start/stop) ──

  Widget _gauge() {
    final isRunning = _ctrl.state == TestState.running;
    final speed     = _ctrl.state == TestState.done
        ? _ctrl.avgMbps : _ctrl.speedMbps;

    return Center(
      child: GestureDetector(
        onTap: _ctrl.toggle,
        child: AnimatedBuilder(
          animation: _pulseAnim,
          builder: (_, child) => Transform.scale(
            scale: isRunning ? _pulseAnim.value : 1.0,
            child: child,
          ),
          child: Container(
            width: 220, height: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _surface,
              border: Border.all(color: _stateColor.withOpacity(0.5), width: 2),
              boxShadow: [
                BoxShadow(color: _stateColor.withOpacity(0.18),
                    blurRadius: 48, spreadRadius: 6),
              ],
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              // Speed number
              Text(speed.toStringAsFixed(1),
                  style: TextStyle(fontSize: 56,
                      fontWeight: FontWeight.w800,
                      color: _stateColor,
                      height: 1, letterSpacing: -2)),
              const SizedBox(height: 4),
              Text('Mbps', style: TextStyle(fontSize: 13,
                  color: _textSub, letterSpacing: 1.5,
                  fontWeight: FontWeight.w500)),
              const SizedBox(height: 10),
              // Hint label inside gauge
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: _gaugeHint(),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _gaugeHint() {
    switch (_ctrl.state) {
      case TestState.idle:
        return Container(
          key: const ValueKey('idle'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          decoration: BoxDecoration(
            color: _accent.withOpacity(0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _accent.withOpacity(0.3)),
          ),
          child: const Text('▶  Start',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                  color: _accent)),
        );
      case TestState.running:
        return Container(
          key: const ValueKey('running'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text('■  Stop',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                  color: _textSub)),
        );
      case TestState.done:
        return Container(
          key: const ValueKey('done'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFF30D158).withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text('↺  Again',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                  color: Color(0xFF30D158))),
        );
      default:
        return Container(
          key: const ValueKey('err'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFFFF453A).withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text('↺  Retry',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                  color: Color(0xFFFF453A))),
        );
    }
  }

  // ── Progress bar ──

  Widget _progressRow() {
    final isRunning = _ctrl.state == TestState.running;
    final elapsed   = (_ctrl.elapsedMs / 1000)
        .clamp(0.0, _ctrl.duration.toDouble());

    return Column(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: _ctrl.progress, minHeight: 4,
          backgroundColor: _border,
          valueColor: AlwaysStoppedAnimation(_stateColor),
        ),
      ),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(
          isRunning
              ? '${elapsed.toStringAsFixed(1)}s / ${_ctrl.duration}s'
              : '${_ctrl.duration}s',
          style: const TextStyle(fontSize: 12, color: _textSub)),
        Text(_fmtBytes(_ctrl.bytesTotal),
            style: const TextStyle(fontSize: 12, color: _textSub)),
      ]),
    ]);
  }

  // ── Stats ──

  Widget _statsRow() {
    return Row(children: [
      _stat('Live',  '${_ctrl.speedMbps.toStringAsFixed(1)}', _accent),
      const SizedBox(width: 10),
      _stat('Peak',  '${_ctrl.peakMbps.toStringAsFixed(1)}', const Color(0xFFFFD60A)),
      const SizedBox(width: 10),
      _stat('Avg',
          _ctrl.state == TestState.done
              ? _ctrl.avgMbps.toStringAsFixed(1) : '--',
          const Color(0xFF30D158)),
    ]);
  }

  Widget _stat(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(color: _surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: TextStyle(fontSize: 17,
              fontWeight: FontWeight.w700, color: color)),
          const SizedBox(height: 3),
          Text('$label (Mbps)',
              style: const TextStyle(fontSize: 10, color: _textSub)),
        ]),
      ),
    );
  }

  // ── Selector ──

  Widget _selector(String label, String display,
      double val, double min, double max,
      List<int> presets, int selected,
      ValueChanged<double> onSlider, ValueChanged<int> onPreset) {
    final disabled = _ctrl.state == TestState.running;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: BoxDecoration(color: _surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border)),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(fontSize: 13,
              fontWeight: FontWeight.w600, color: Colors.white)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
                color: _accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(6)),
            child: Text(display, style: const TextStyle(fontSize: 13,
                fontWeight: FontWeight.w700, color: _accent)),
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
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: sel ? _accent.withOpacity(0.15) : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: sel ? _accent.withOpacity(0.5) : _border),
                    ),
                    child: Text('$t', style: TextStyle(fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: sel ? _accent : _textSub)),
                  ),
                ),
              );
            }).toList()),
      ]),
    );
  }
}
