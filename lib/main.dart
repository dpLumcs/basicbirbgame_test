import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const double gameWidth = 400;
const double gameHeight = 700;
const double groundTop = 628;
const double gravity = 1120;
const double flapStrength = -340;
const double pipeSpeed = 145;
const double gapSize = 184;
const double pipeSpacing = 224;
const double pipeWidth = 69;
const double birdX = 110;
const double birdRadius = 15;
const int maxHistory = 30; // runs kept in storage
const int visibleRuns = 8; // runs shown on the history page

const ink = Color(0xff364654);
const blue = Color(0xff527089);
const paper = Color(0xfffbf8eb);
const green = Color(0xffa7c986);
const yellow = Color(0xfff3d776);
const redInk = Color(0xffc9605a);

// Tap targets (in game coordinates, 400 x 700).
const Rect playRect = Rect.fromLTWH(105, 330, 190, 58);
const Rect historyRect = Rect.fromLTWH(105, 406, 190, 58);
const Rect backRect = Rect.fromLTWH(52, 524, 120, 52);
const Rect clearRect = Rect.fromLTWH(228, 524, 120, 52);
const Rect retryRect = Rect.fromLTWH(80, 358, 110, 54);
const Rect menuRect = Rect.fromLTWH(210, 358, 110, 54);

// In-game pause button (top left) and its dropdown menu.
const Rect pauseButtonRect = Rect.fromLTWH(14, 18, 46, 46);
const Rect menuPanelRect = Rect.fromLTWH(14, 72, 188, 188);
const Rect pauseOptRect = Rect.fromLTWH(26, 84, 164, 48);
const Rect resumeOptRect = Rect.fromLTWH(26, 142, 164, 48);
const Rect menuOptRect = Rect.fromLTWH(26, 200, 164, 48);

// ---------------------------------------------------------------------------
// Small storage wrapper (shared_preferences: works on Android, iOS and web).
// Loaded once in main(), so reads/writes stay synchronous. Fails silently.
// ---------------------------------------------------------------------------
late SharedPreferences _prefs;

String? _read(String key) {
  try {
    return _prefs.getString(key);
  } catch (_) {
    return null;
  }
}

void _write(String key, String value) {
  try {
    _prefs.setString(key, value);
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Game model
// ---------------------------------------------------------------------------
enum GameState { menu, history, ready, playing, gameOver }

class Pipe {
  Pipe(this.x, this.gapY);
  double x;
  final double gapY;
  bool scored = false;
}

class Run {
  const Run(this.score, this.time);
  final int score;
  final DateTime time;
}

class Game {
  Game() {
    _load();
  }

  final math.Random random = math.Random();
  final List<Pipe> pipes = [];
  final List<Run> history = []; // newest first
  GameState state = GameState.menu;
  double birdY = 310;
  double velocity = 0;
  double time = 0;
  double flapPulse = 0;
  double deathPulse = 0;
  double sinceDeath = 9;
  int score = 0;
  int best = 0;
  int bestAtStart = 0;
  bool newBest = false;
  bool clearArmed = false;
  bool paused = false; // simulation frozen
  bool menuOpen = false; // top-left dropdown is showing

  // ---- persistence ----
  void _load() {
    best = int.tryParse(_read('doodle_best') ?? '') ?? 0;
    bestAtStart = best;
    final raw = _read('doodle_history') ?? '';
    for (final item in raw.split(',')) {
      final parts = item.split(':');
      if (parts.length != 2) continue;
      final s = int.tryParse(parts[0]);
      final t = int.tryParse(parts[1]);
      if (s != null && t != null) {
        history.add(Run(s, DateTime.fromMillisecondsSinceEpoch(t)));
      }
    }
  }

  void _save() {
    _write('doodle_best', '$best');
    _write(
        'doodle_history',
        history
            .map((r) => '${r.score}:${r.time.millisecondsSinceEpoch}')
            .join(','));
  }

  void clearHistory() {
    history.clear();
    best = 0;
    bestAtStart = 0;
    clearArmed = false;
    _save();
  }

  // ---- state changes ----
  void reset() {
    state = GameState.ready;
    birdY = 310;
    velocity = 0;
    flapPulse = 0;
    deathPulse = 0;
    score = 0;
    bestAtStart = best;
    newBest = false;
    clearArmed = false;
    paused = false;
    menuOpen = false;
    pipes.clear();
  }

  void toMenu() {
    reset();
    state = GameState.menu;
  }

  void retry() {
    reset();
    flap();
  }

  // ---- pause / resume ----
  bool get inRun => state == GameState.ready || state == GameState.playing;

  void pause() {
    if (inRun) paused = true;
  }

  void resume() {
    paused = false;
    menuOpen = false;
  }

  void togglePause() {
    if (!inRun) return;
    paused ? resume() : pause();
  }

  void _menuTap(Offset p) {
    if (pauseOptRect.contains(p)) {
      pause();
    } else if (resumeOptRect.contains(p)) {
      resume();
    } else if (menuOptRect.contains(p)) {
      toMenu();
    } else if (pauseButtonRect.contains(p)) {
      menuOpen = false; // the button doubles as a close (X) while open
    }
    // taps anywhere else are ignored so the bird does not flap by accident
  }

  void flap() {
    if (paused) return;
    if (state == GameState.ready) {
      state = GameState.playing;
      pipes.add(Pipe(gameWidth + 95, _gapY()));
    }
    if (state != GameState.playing) return;
    velocity = flapStrength;
    flapPulse = 1;
  }

  // ---- input ----
  void tap(Offset p) {
    switch (state) {
      case GameState.menu:
        if (playRect.contains(p)) {
          reset();
        } else if (historyRect.contains(p)) {
          state = GameState.history;
        }
        break;
      case GameState.history:
        if (backRect.contains(p)) {
          toMenu();
        } else if (clearRect.contains(p) && history.isNotEmpty) {
          if (clearArmed) {
            clearHistory();
          } else {
            clearArmed = true;
          }
        }
        break;
      case GameState.ready:
      case GameState.playing:
        if (menuOpen) {
          _menuTap(p);
        } else if (pauseButtonRect.contains(p)) {
          menuOpen = true;
        } else if (paused) {
          resume(); // tap anywhere to resume after a keyboard/auto pause
        } else {
          flap();
        }
        break;
      case GameState.gameOver:
        if (sinceDeath < .35) return; // avoid accidental instant retry
        if (menuRect.contains(p)) {
          toMenu();
        } else {
          retry();
        }
        break;
    }
  }

  void space() {
    switch (state) {
      case GameState.menu:
        reset();
        break;
      case GameState.history:
        toMenu();
        break;
      case GameState.ready:
      case GameState.playing:
        if (paused) {
          resume();
        } else {
          flap();
        }
        break;
      case GameState.gameOver:
        if (sinceDeath >= .35) retry();
        break;
    }
  }

  void escape() {
    if (state != GameState.menu) toMenu();
  }

  // ---- simulation ----
  double _gapY() => 215 + random.nextDouble() * 200;

  void _die() {
    if (state != GameState.playing) return;
    state = GameState.gameOver;
    deathPulse = 1;
    sinceDeath = 0;
    best = math.max(best, score);
    newBest = score > bestAtStart;
    history.insert(0, Run(score, DateTime.now()));
    if (history.length > maxHistory) {
      history.removeRange(maxHistory, history.length);
    }
    _save();
  }

  void update(double dt) {
    if (paused) return;
    time += dt;
    sinceDeath += dt;
    flapPulse = math.max(0, flapPulse - dt * 4.5);
    deathPulse = math.max(0, deathPulse - dt * 2.8);
    if (state != GameState.playing) return;
    velocity += gravity * dt;
    birdY += velocity * dt;
    for (final pipe in pipes) {
      pipe.x -= pipeSpeed * dt;
      if (!pipe.scored && pipe.x + pipeWidth < birdX) {
        pipe.scored = true;
        score++;
        best = math.max(best, score);
      }
      if (_circleRect(birdX, birdY, birdRadius - 2,
              Rect.fromLTWH(pipe.x, 0, pipeWidth, pipe.gapY - gapSize / 2)) ||
          _circleRect(
              birdX,
              birdY,
              birdRadius - 2,
              Rect.fromLTWH(pipe.x, pipe.gapY + gapSize / 2, pipeWidth,
                  groundTop - pipe.gapY - gapSize / 2))) {
        _die();
      }
    }
    pipes.removeWhere((pipe) => pipe.x + pipeWidth < -10);
    if (pipes.isEmpty || pipes.last.x < gameWidth - pipeSpacing) {
      pipes.add(Pipe(gameWidth + 10, _gapY()));
    }
    if (birdY - birdRadius < 0 || birdY + birdRadius >= groundTop) {
      birdY = birdY.clamp(birdRadius, groundTop - birdRadius).toDouble();
      _die();
    }
  }

  bool _circleRect(double x, double y, double radius, Rect rect) {
    final dx = x - x.clamp(rect.left, rect.right);
    final dy = y - y.clamp(rect.top, rect.bottom);
    return dx * dx + dy * dy <= radius * radius;
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------
class DoodlePainter extends CustomPainter {
  DoodlePainter(this.game);
  final Game game;

  Paint pen([double width = 2.2, Color color = ink]) => Paint()
    ..color = color
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;

  // Each outline samples a fixed seed, so its sketchy edges do not flicker.
  Path sketchRect(Rect r, int seed, [double jitter = 1.5]) {
    final rng = math.Random(seed);
    final path = Path();
    final corners = <Offset>[
      r.topLeft, r.topRight, r.bottomRight, r.bottomLeft, r.topLeft
    ];
    for (var side = 0; side < 4; side++) {
      for (var i = 0; i <= 8; i++) {
        if (side > 0 && i == 0) continue;
        final t = i / 8;
        final a = corners[side], b = corners[side + 1];
        final p = Offset(
            a.dx + (b.dx - a.dx) * t + (rng.nextDouble() - .5) * jitter * 2,
            a.dy + (b.dy - a.dy) * t + (rng.nextDouble() - .5) * jitter * 2);
        if (side == 0 && i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
    }
    path.close();
    return path;
  }

  void shadedRect(Canvas canvas, Rect rect, int seed, Color fill) {
    final shape = sketchRect(rect, seed);
    canvas.drawPath(shape, Paint()..color = fill);
    canvas.save();
    canvas.clipPath(shape);
    final rng = math.Random(seed + 94);
    for (double x = rect.left - rect.height;
        x < rect.right + rect.height;
        x += 11) {
      final shift = rng.nextDouble() * 3;
      canvas.drawLine(Offset(x + shift, rect.bottom),
          Offset(x + rect.height * .72 + shift, rect.top),
          pen(.75, ink.withValues(alpha: .16)));
    }
    canvas.restore();
    canvas.drawPath(shape, pen());
    canvas.drawPath(sketchRect(rect.translate(1.6, -1), seed + 1, 1.0),
        pen(.65, ink.withValues(alpha: .43)));
  }

  // ---- text helpers ----
  TextPainter textPainter(String text, double size, Color color) => TextPainter(
        text: TextSpan(
            text: text,
            style: TextStyle(
              fontFamily: 'cursive',
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w700,
              fontSize: size,
              color: color,
              shadows: const [
                Shadow(
                    offset: Offset(1, 1),
                    blurRadius: 0,
                    color: Color(0x33859499))
              ],
            )),
        textDirection: ui.TextDirection.ltr,
      )..layout();

  void label(Canvas canvas, String text, Offset center, double size,
      {Color color = ink, double angle = -.035}) {
    final painter = textPainter(text, size, color);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
    canvas.restore();
  }

  /// align: 0 = anchor is the left edge, 0.5 = centre, 1 = right edge.
  void aligned(Canvas canvas, String text, Offset anchor, double size,
      {Color color = ink, double align = 0}) {
    final painter = textPainter(text, size, color);
    painter.paint(canvas,
        Offset(anchor.dx - painter.width * align, anchor.dy - painter.height / 2));
  }

  // ---- UI helpers ----
  void button(Canvas canvas, Rect r, String text, int seed, Color fill,
      {double size = 26, bool enabled = true}) {
    final shape = sketchRect(r, seed, 1.6);
    canvas.drawPath(
        shape, Paint()..color = enabled ? fill : const Color(0xffe6e3d6));
    canvas.drawPath(shape, pen(2.2, enabled ? ink : ink.withValues(alpha: .35)));
    canvas.drawPath(sketchRect(r.translate(1.8, 1.6), seed + 1, 1.0),
        pen(.7, ink.withValues(alpha: .4)));
    label(canvas, text, r.center, size,
        angle: -.02, color: enabled ? ink : ink.withValues(alpha: .35));
  }

  /// Pause overlay + top-left button and dropdown (ready / playing only).
  void hud(Canvas canvas) {
    if (game.paused) {
      canvas.drawRect(const Rect.fromLTWH(0, 0, gameWidth, gameHeight),
          Paint()..color = paper.withValues(alpha: .6));
      label(canvas, 'Paused', const Offset(205, 320), 46);
      if (!game.menuOpen) {
        label(canvas, 'tap or press P to resume', const Offset(205, 372), 20,
            color: blue, angle: .02);
      }
    }

    // Button: hamburger icon, turns into an X while the menu is open.
    button(canvas, pauseButtonRect, '', 71, yellow);
    final c = pauseButtonRect.center;
    if (game.menuOpen) {
      canvas.drawLine(c.translate(-9, -9), c.translate(9, 9), pen(3));
      canvas.drawLine(c.translate(-9, 9), c.translate(9, -9), pen(3));
    } else {
      for (var i = -1; i <= 1; i++) {
        canvas.drawLine(
            c.translate(-10, i * 9.0), c.translate(10, i * 9.0), pen(3));
      }
    }

    if (game.menuOpen) {
      panel(canvas, menuPanelRect, 81);
      button(canvas, pauseOptRect, 'Pause', 82, yellow,
          size: 22, enabled: !game.paused);
      button(canvas, resumeOptRect, 'Resume', 83, green,
          size: 22, enabled: game.paused);
      button(canvas, menuOptRect, 'Back to Menu', 84, const Color(0xffe8b3a8),
          size: 20);
    }
  }

  void panel(Canvas canvas, Rect r, int seed) {
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(14)),
        Paint()..color = paper.withValues(alpha: .95));
    canvas.drawPath(sketchRect(r, seed), pen(2));
    canvas.drawPath(
        sketchRect(r.translate(2, 2), seed + 1, 1.0), pen(.7, ink.withValues(alpha: .35)));
  }

  String stamp(DateTime t) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final mm = t.minute.toString().padLeft(2, '0');
    return '${t.day} ${months[t.month - 1]}, ${t.hour}:$mm';
  }

  // ---- scenery ----
  void clouds(Canvas canvas) {
    for (var i = 0; i < 4; i++) {
      final drift = game.time * (8 + i * 3);
      final x = ((i * 134.0 + 75 - drift) % 540 + 540) % 540 - 70;
      final y = 95.0 + (i % 3) * 86;
      final path = Path()
        ..moveTo(x - 31, y + 9)
        ..quadraticBezierTo(x - 41, y - 7, x - 22, y - 10)
        ..quadraticBezierTo(x - 18, y - 29, x, y - 21)
        ..quadraticBezierTo(x + 13, y - 35, x + 26, y - 15)
        ..quadraticBezierTo(x + 43, y - 13, x + 35, y + 5)
        ..quadraticBezierTo(x + 24, y + 12, x - 31, y + 9);
      canvas.drawPath(path, Paint()..color = const Color(0xfff9fbf7));
      canvas.drawPath(path, pen(1.3, blue.withValues(alpha: .55)));
      canvas.drawLine(Offset(x - 12, y + 3), Offset(x + 16, y + 4),
          pen(.8, blue.withValues(alpha: .3)));
    }
  }

  void pipe(Canvas canvas, Pipe p, int index) {
    final top = p.gapY - gapSize / 2;
    final bottom = p.gapY + gapSize / 2;
    shadedRect(canvas, Rect.fromLTWH(p.x + 4, -12, pipeWidth - 8, top + 12),
        index * 23 + 3, green);
    shadedRect(canvas, Rect.fromLTWH(p.x - 5, top - 21, pipeWidth + 10, 21),
        index * 23 + 4, const Color(0xffb6d599));
    shadedRect(
        canvas,
        Rect.fromLTWH(p.x + 4, bottom, pipeWidth - 8, groundTop - bottom),
        index * 23 + 5,
        green);
    shadedRect(canvas, Rect.fromLTWH(p.x - 5, bottom, pipeWidth + 10, 21),
        index * 23 + 6, const Color(0xffb6d599));
  }

  void bird(Canvas canvas) {
    final menu = game.state == GameState.menu;
    final idle = menu || game.state == GameState.ready;
    final bob = math.sin(game.time * 3) * 6;
    final x = menu ? 200.0 : birdX;
    final y = menu ? 255 + bob : (idle ? game.birdY + bob : game.birdY);
    final tilt = menu
        ? math.sin(game.time * 2) * .12
        : (game.velocity / 540).clamp(-.48, 1.05).toDouble();
    final s = menu ? 1.5 : 1.0;
    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(tilt);
    canvas.scale(s * (1 + game.flapPulse * .11), s * (1 - game.flapPulse * .13));
    final blob = Path()
      ..moveTo(-18, -3)
      ..quadraticBezierTo(-16, -18, -2, -17)
      ..quadraticBezierTo(16, -20, 18, -3)
      ..quadraticBezierTo(23, 14, 5, 17)
      ..quadraticBezierTo(-15, 20, -19, 6)
      ..close();
    canvas.drawPath(blob, Paint()..color = yellow);
    canvas.drawPath(blob, pen(2.4));
    canvas.drawPath(
        blob.shift(const Offset(1, -1)), pen(.7, blue.withValues(alpha: .55)));
    final wingY = 4 +
        math.sin(game.time * 19) * (game.state == GameState.playing ? 5 : 2);
    canvas.drawOval(
        Rect.fromCenter(center: Offset(-7, wingY), width: 17, height: 11),
        Paint()..color = const Color(0xffe9bb58));
    canvas.drawOval(
        Rect.fromCenter(center: Offset(-7, wingY), width: 17, height: 11),
        pen(1.7));
    final beak = Path()
      ..moveTo(17, -2)
      ..lineTo(27, 2)
      ..lineTo(17, 6)
      ..close();
    canvas.drawPath(beak, Paint()..color = const Color(0xffe99565));
    canvas.drawPath(beak, pen(1.6));
    canvas.drawCircle(const Offset(8, -8), 4, Paint()..color = paper);
    canvas.drawCircle(const Offset(9, -8), 1.8, Paint()..color = ink);
    for (var i = 0; i < 3; i++) {
      canvas.drawLine(Offset(-12 + i * 5, 12), Offset(-8 + i * 5, 14),
          pen(.7, ink.withValues(alpha: .3)));
    }
    canvas.restore();
  }

  void ground(Canvas canvas) {
    canvas.drawRect(
        const Rect.fromLTWH(0, groundTop, gameWidth, gameHeight - groundTop),
        Paint()..color = const Color(0xffeee8ce));
    canvas.drawLine(const Offset(0, groundTop), const Offset(gameWidth, groundTop),
        pen(2.5));
    final offset =
        (game.time * (game.state == GameState.playing ? pipeSpeed : 15)) % 22;
    for (double x = -22 - offset; x < gameWidth + 22; x += 22) {
      final n = (x / 22).round();
      final h = 5.0 + (n.abs() % 4) * 2;
      canvas.drawLine(
          Offset(x, groundTop + 1), Offset(x - 4, groundTop - h), pen(1.2, blue));
      canvas.drawLine(Offset(x, groundTop + 1),
          Offset(x + 5, groundTop - h * .7), pen(1.2, blue));
      canvas.drawLine(Offset(x - 8, groundTop + 25), Offset(x + 3, groundTop + 19),
          pen(.8, ink.withValues(alpha: .23)));
    }
  }

  // ---- screens ----
  void menuScreen(Canvas canvas) {
    label(canvas, 'Opus Bird', const Offset(202, 128), 52);
    final wave = Path()..moveTo(95, 166);
    for (var i = 0; i < 7; i++) {
      wave.quadraticBezierTo(
          95 + i * 30 + 15, i.isEven ? 159 : 173, 95 + (i + 1) * 30, 166);
    }
    canvas.drawPath(wave, pen(1.8, blue.withValues(alpha: .8)));
    label(canvas, 'js play the game gng', const Offset(202, 196), 16,
        color: blue, angle: .02);

    button(canvas, playRect, 'Play', 11, yellow, size: 30);
    button(canvas, historyRect, 'History', 21, green, size: 28);

    label(canvas, 'Best: ${game.best}', const Offset(202, 510), 24, color: blue);
    label(canvas, 'SPACE = play  ·  P = pause  ·  ESC = menu', const Offset(202, 560), 15,
        color: blue.withValues(alpha: .8), angle: .015);
  }

  void historyScreen(Canvas canvas) {
    panel(canvas, const Rect.fromLTWH(28, 70, 344, 530), 77);
    label(canvas, 'History', const Offset(200, 112), 38);

    final runs = game.history;
    final total = runs.fold<int>(0, (a, r) => a + r.score);
    final avg = runs.isEmpty ? 0.0 : total / runs.length;
    label(
        canvas,
        'Best ${game.best}  ·  Avg ${avg.toStringAsFixed(1)}  ·  Runs ${runs.length}',
        const Offset(202, 156),
        18,
        color: blue,
        angle: -.015);

    if (runs.isEmpty) {
      label(canvas, 'No runs yet.', const Offset(200, 285), 26, color: blue);
      label(canvas, 'Go flap something!', const Offset(200, 325), 22, color: blue);
    } else {
      final shown = math.min(visibleRuns, runs.length);
      for (var i = 0; i < shown; i++) {
        final r = runs[i];
        final y = 205.0 + i * 36;
        final isBest = r.score == game.best && game.best > 0;
        aligned(canvas, '#${i + 1}', Offset(52, y), 17,
            color: ink.withValues(alpha: .6));
        aligned(canvas, '${r.score} pts', Offset(92, y), 23);
        if (isBest) {
          aligned(canvas, 'best', Offset(182, y + 2), 16, color: redInk);
        }
        aligned(canvas, stamp(r.time), Offset(350, y + 1), 16,
            color: blue, align: 1);
        canvas.drawLine(Offset(50, y + 18), Offset(350, y + 19.5),
            pen(.7, ink.withValues(alpha: .2)));
      }
      if (runs.length > shown) {
        label(canvas, '+ ${runs.length - shown} older runs', const Offset(200, 497),
            15, color: blue.withValues(alpha: .8), angle: 0);
      }
    }

    button(canvas, backRect, 'Back', 31, yellow, size: 24);
    button(canvas, clearRect, game.clearArmed ? 'Sure?' : 'Clear', 41,
        game.clearArmed ? const Color(0xffe8b3a8) : green,
        size: 24);
  }

  void gameOverScreen(Canvas canvas) {
    panel(canvas, const Rect.fromLTWH(60, 190, 280, 246), 42);
    label(canvas, 'Game Over', const Offset(202, 232), 40);
    label(canvas, 'Score: ${game.score}', const Offset(202, 285), 26);
    if (game.newBest) {
      label(canvas, 'New best!', const Offset(202, 322), 24,
          color: redInk, angle: .03);
    } else {
      label(canvas, 'Best: ${game.best}', const Offset(202, 322), 22, color: blue);
    }
    button(canvas, retryRect, 'Retry', 51, yellow, size: 22);
    button(canvas, menuRect, 'Menu', 61, green, size: 22);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawColor(paper, BlendMode.src);
    final grid = pen(.7, const Color(0x3583a8b8));
    for (double x = 20; x < gameWidth; x += 28) {
      canvas.drawLine(Offset(x, 0), Offset(x, gameHeight), grid);
    }
    for (double y = 18; y < gameHeight; y += 28) {
      canvas.drawLine(Offset(0, y), Offset(gameWidth, y), grid);
    }
    clouds(canvas);
    canvas.save();
    if (game.deathPulse > 0) {
      canvas.translate(math.sin(game.time * 65) * game.deathPulse * 6, 0);
    }
    for (var i = 0; i < game.pipes.length; i++) {
      pipe(canvas, game.pipes[i], i + (game.pipes[i].gapY * 10).round());
    }
    ground(canvas);
    bird(canvas);
    canvas.restore();

    switch (game.state) {
      case GameState.playing:
        label(canvas, '${game.score}', const Offset(205, 65), 46);
        hud(canvas);
        break;
      case GameState.ready:
        label(canvas, 'Get Ready!', const Offset(205, 173), 46);
        label(canvas, 'Tap to Start', const Offset(208, 400), 27,
            color: blue, angle: .025);
        label(canvas, 'click or press SPACE to flap', const Offset(209, 443), 17,
            color: blue);
        hud(canvas);
        break;
      case GameState.menu:
        menuScreen(canvas);
        break;
      case GameState.history:
        historyScreen(canvas);
        break;
      case GameState.gameOver:
        gameOverScreen(canvas);
        break;
    }

    if (game.deathPulse > 0) {
      canvas.drawRect(
          Offset.zero & size,
          Paint()
            ..color = const Color(0xffe89a85)
                .withValues(alpha: game.deathPulse * .16));
    }
  }

  @override
  bool shouldRepaint(covariant DoodlePainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _prefs = await SharedPreferences.getInstance();
  runApp(const DoodleBirdApp());
}

class DoodleBirdApp extends StatelessWidget {
  const DoodleBirdApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Doodle Bird',
        home: const GameScreen(),
      );
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});
  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final Game game = Game();
  final FocusNode focusNode = FocusNode();
  late final Ticker ticker;
  Duration? previous;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ticker = createTicker((elapsed) {
      final dt = previous == null
          ? 0.0
          : ((elapsed - previous!).inMicroseconds / 1000000)
              .clamp(0.0, .033)
              .toDouble();
      previous = elapsed;
      setState(() => game.update(dt));
    })
      ..start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ticker.dispose();
    focusNode.dispose();
    super.dispose();
  }

  // Auto-pause when the app goes to the background (call, home button, etc.)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) setState(game.pause);
  }

  void act(VoidCallback action) {
    focusNode.requestFocus();
    setState(action);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xffd6dce0),
        body: Center(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: gameWidth,
              height: gameHeight,
              child: KeyboardListener(
                focusNode: focusNode,
                onKeyEvent: (event) {
                  if (event is! KeyDownEvent) return;
                  if (event.logicalKey == LogicalKeyboardKey.space) {
                    act(game.space);
                  } else if (event.logicalKey == LogicalKeyboardKey.escape) {
                    act(game.escape);
                  } else if (event.logicalKey == LogicalKeyboardKey.keyP) {
                    act(game.togglePause);
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) =>
                      act(() => game.tap(details.localPosition)),
                  child: CustomPaint(
                    size: const Size(gameWidth, gameHeight),
                    painter: DoodlePainter(game),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}