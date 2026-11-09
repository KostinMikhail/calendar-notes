// Анимации приложения: единые длительности и кривые, режим
// «Уменьшить анимации» и несколько маленьких обёрток.
//
// Правила:
// - все длительности — только отсюда (Motion.fast / normal / slow);
// - анимации только визуальные: ничего не задерживают и не блокируют ввод;
// - при уменьшенных анимациях любая длительность — Duration.zero.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'format_menu.dart' show LocalPrefStore, PrefStore;
import 'skins.dart' show rebuildAllWidgets;

// ============================================================
//  Настройка «Уменьшить анимации»
// ============================================================

/// Явный выбор в меню (localStorage). Нет записи или ошибка хранилища —
/// null: следуем системной настройке.
class MotionPref {
  const MotionPref([this.store = const LocalPrefStore()]);
  final PrefStore store;

  static const String storageKey = 'calendar_reduce_motion';

  bool? load() {
    try {
      return switch (store.read(storageKey)) {
        '1' => true,
        '0' => false,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  void save(bool reduced) {
    try {
      store.write(storageKey, reduced ? '1' : '0');
    } catch (_) {}
  }
}

/// Уменьшены ли анимации: явный выбор в меню важнее системной настройки
/// (в вебе системная — prefers-reduced-motion, движок Flutter передаёт её
/// в AccessibilityFeatures.disableAnimations и следит за изменениями).
class MotionSettings extends ChangeNotifier {
  MotionSettings({this._userChoice, this._system = false});

  bool? _userChoice;
  bool _system;

  /// Выбор в меню (null — не выбирали)
  bool? get userChoice => _userChoice;

  /// Системная настройка
  bool get system => _system;

  /// Итог — то, что показывает галочка в меню
  bool get reduced => _userChoice ?? _system;

  void setSystem(bool value) {
    if (value == _system) return;
    final before = reduced;
    _system = value;
    if (reduced != before) notifyListeners();
  }

  /// Выбор в меню: запоминается явно (даже если совпадает с системной)
  void setReduced(bool value, [MotionPref pref = const MotionPref()]) {
    final before = reduced;
    _userChoice = value;
    pref.save(value);
    if (reduced != before) notifyListeners();
  }

  /// Для тестов и запуска
  void reset({bool? userChoice, bool system = false}) {
    final before = reduced;
    _userChoice = userChoice;
    _system = system;
    if (reduced != before) notifyListeners();
  }
}

/// Текущая настройка анимаций
final MotionSettings motion = MotionSettings();

bool _motionStarted = false;

/// До runApp: сохранённый выбор и системная настройка; дальше —
/// следить за системной и перерисовывать всё при смене (без перезапуска)
void initMotion([MotionPref pref = const MotionPref()]) {
  final binding = WidgetsBinding.instance;
  motion.reset(
    userChoice: pref.load(),
    system: binding.platformDispatcher.accessibilityFeatures.disableAnimations,
  );
  if (_motionStarted) return;
  _motionStarted = true;
  binding.addObserver(_SystemMotionObserver());
  motion.addListener(rebuildAllWidgets);
}

class _SystemMotionObserver with WidgetsBindingObserver {
  @override
  void didChangeAccessibilityFeatures() {
    motion.setSystem(WidgetsBinding
        .instance.platformDispatcher.accessibilityFeatures.disableAnimations);
  }
}

// ============================================================
//  Длительности и кривые
// ============================================================

abstract final class Motion {
  /// Базовые значения (без учёта «Уменьшить анимации»)
  static const Duration fastBase = Duration(milliseconds: 120);
  static const Duration normalBase = Duration(milliseconds: 180);
  static const Duration slowBase = Duration(milliseconds: 250);

  /// Шаг «лесенки» для строк списка и сколько строк участвует
  static const Duration staggerBase = Duration(milliseconds: 20);
  static const int staggerCap = 6;

  /// Появление
  static const Curve enter = Curves.easeOutCubic;

  /// Исчезновение
  static const Curve exit = Curves.easeInCubic;

  /// Перемещение / изменение размера
  static const Curve move = Curves.easeInOutCubic;

  static bool get reduced => motion.reduced;

  static Duration _d(Duration base) => reduced ? Duration.zero : base;

  /// Наведение, нажатие, мелкие переключения
  static Duration get fast => _d(fastBase);

  /// Меню, диалоги, смена содержимого
  static Duration get normal => _d(normalBase);

  /// Колонка календаря, листание месяца
  static Duration get slow => _d(slowBase);

  /// Задержка строки [index] в списке (не больше staggerCap шагов)
  static Duration stagger(int index) =>
      reduced ? Duration.zero : staggerBase * index.clamp(0, staggerCap);

  /// Листание месяца в календаре. table_calendar не принимает нулевую
  /// длительность (assert в прокрутке), поэтому «без анимации» — 1 мс.
  static Duration get calendarPage =>
      reduced ? const Duration(milliseconds: 1) : slowBase;

  /// Всплывающие меню
  static AnimationStyle get menu => reduced
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: normalBase,
          reverseDuration: fastBase,
          curve: enter,
          reverseCurve: exit,
        );

  /// Диалоги (затухание; лёгкое увеличение даёт FadeScaleIn)
  static AnimationStyle get dialog => reduced
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: normalBase,
          reverseDuration: fastBase,
          curve: enter,
          reverseCurve: exit,
        );

  /// Всплывающие сообщения снизу: обычный выезд, длительность из модуля
  static AnimationStyle get snackBar => reduced
      ? AnimationStyle.noAnimation
      : const AnimationStyle(duration: slowBase, reverseDuration: normalBase);
}

// ============================================================
//  Обёртки
// ============================================================

/// Затухание без лишней цены в покое. Обычные FadeTransition/Opacity
/// держат слой прозрачности всегда, и в вебе это saveLayer на каждую
/// перерисовку — даже при полной видимости (для редактора с длинной
/// заметкой это заметно). Здесь при полной видимости ребёнок рисуется
/// напрямую, слой — только пока идёт анимация. Нажатия проходят всегда.
class LightFade extends SingleChildRenderObjectWidget {
  const LightFade({super.key, required this.opacity, super.child});

  final Animation<double> opacity;

  @override
  RenderLightFade createRenderObject(BuildContext context) =>
      RenderLightFade(opacity);

  @override
  void updateRenderObject(BuildContext context, RenderLightFade renderObject) =>
      renderObject.opacity = opacity;
}

class RenderLightFade extends RenderProxyBox {
  RenderLightFade(this._opacity);

  Animation<double> _opacity;
  int _alpha = 255;

  /// Текущая прозрачность 0..255 (для тестов)
  int get alpha => _alpha;

  set opacity(Animation<double> value) {
    if (identical(value, _opacity)) return;
    if (attached) _opacity.removeListener(_update);
    _opacity = value;
    if (attached) {
      _opacity.addListener(_update);
      _update();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _opacity.addListener(_update);
    _update();
  }

  @override
  void detach() {
    _opacity.removeListener(_update);
    super.detach();
  }

  void _update() {
    final a = Color.getAlphaFromOpacity(_opacity.value.clamp(0.0, 1.0));
    if (a == _alpha) return;
    final wasLayer = alwaysNeedsCompositing;
    final old = _alpha;
    _alpha = a;
    if (wasLayer != alwaysNeedsCompositing) markNeedsCompositingBitsUpdate();
    markNeedsPaint();
    if (old == 0 || a == 0) markNeedsSemanticsUpdate();
  }

  @override
  bool get alwaysNeedsCompositing => child != null && _alpha > 0 && _alpha < 255;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || _alpha == 0) {
      layer = null;
      return;
    }
    if (_alpha == 255) {
      layer = null;
      context.paintChild(child!, offset);
      return;
    }
    layer = context.pushOpacity(offset, _alpha, super.paint,
        oldLayer: layer as OpacityLayer?);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (child != null && _alpha != 0) visitor(child!);
  }
}

/// Появление при первом показе: затухание + чуть-чуть увеличение и/или
/// сдвиг вверх. Нажатия проходят сразу (без IgnorePointer).
class FadeScaleIn extends StatefulWidget {
  const FadeScaleIn({
    super.key,
    required this.child,
    this.duration,
    this.delay = Duration.zero,
    this.scaleFrom = 1,
    this.dy = 0,
    this.alignment = Alignment.center,
    this.fade = true,
  });

  final Widget child;

  /// false — без затухания (например, его уже делает маршрут диалога)
  final bool fade;

  /// null — Motion.normal
  final Duration? duration;

  /// Задержка начала (без таймеров: часть общей длительности)
  final Duration delay;
  final double scaleFrom;

  /// Сдвиг в логических пикселях в начале (положительный — ниже)
  final double dy;
  final Alignment alignment;

  @override
  State<FadeScaleIn> createState() => _FadeScaleInState();
}

class _FadeScaleInState extends State<FadeScaleIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late Animation<double> _t;

  @override
  void initState() {
    super.initState();
    final d = widget.duration ?? Motion.normal;
    final delay = d == Duration.zero ? Duration.zero : widget.delay;
    final total = d + delay;
    _c = AnimationController(vsync: this, duration: total);
    final start = total == Duration.zero
        ? 0.0
        : delay.inMicroseconds / total.inMicroseconds;
    _t = CurvedAnimation(
        parent: _c, curve: Interval(start, 1, curve: Motion.enter));
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget child = widget.child;
    if (widget.scaleFrom != 1) {
      child = ScaleTransition(
        scale: Tween(begin: widget.scaleFrom, end: 1.0).animate(_t),
        alignment: widget.alignment,
        child: child,
      );
    }
    if (widget.dy != 0) {
      child = AnimatedBuilder(
        animation: _t,
        builder: (_, c) => Transform.translate(
            offset: Offset(0, widget.dy * (1 - _t.value)), child: c),
        child: child,
      );
    }
    return widget.fade ? LightFade(opacity: _t, child: child) : child;
  }
}

/// Мягкое появление содержимого по сигналу: при каждом изменении [signal]
/// — затухание от 0 и сдвиг на несколько пикселей вверх. [hidden] = true —
/// сразу спрятать (до следующего сигнала). Ребёнок не пересоздаётся (тот
/// же элемент, то же состояние), нажатия и ввод проходят всё время.
/// В покое — без слоя прозрачности.
class RevealOnSignal extends StatefulWidget {
  const RevealOnSignal({
    super.key,
    required this.signal,
    required this.child,
    this.hidden,
    this.dy = 4,
  });

  final ValueListenable<int> signal;
  final ValueListenable<bool>? hidden;
  final Widget child;
  final double dy;

  @override
  State<RevealOnSignal> createState() => _RevealOnSignalState();
}

class _RevealOnSignalState extends State<RevealOnSignal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, value: 1);
  late final Animation<double> _t =
      CurvedAnimation(parent: _c, curve: Motion.enter);

  @override
  void initState() {
    super.initState();
    widget.signal.addListener(_play);
    widget.hidden?.addListener(_hide);
  }

  @override
  void didUpdateWidget(RevealOnSignal old) {
    super.didUpdateWidget(old);
    if (old.signal != widget.signal) {
      old.signal.removeListener(_play);
      widget.signal.addListener(_play);
    }
    if (old.hidden != widget.hidden) {
      old.hidden?.removeListener(_hide);
      widget.hidden?.addListener(_hide);
    }
  }

  void _hide() {
    if (widget.hidden?.value != true) return;
    _c.stop();
    _c.value = 0;
  }

  void _play() {
    final d = Motion.normal;
    if (d == Duration.zero) {
      _c.value = 1;
      return;
    }
    _c.duration = d;
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    widget.signal.removeListener(_play);
    widget.hidden?.removeListener(_hide);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LightFade(
      opacity: _t,
      child: AnimatedBuilder(
        animation: _t,
        builder: (_, c) => Transform.translate(
            offset: Offset(0, widget.dy * (1 - _t.value)), child: c),
        child: widget.child,
      ),
    );
  }
}

/// Показ/скрытие блока: плавно меняется размер вдоль [axis] и прозрачность.
/// Содержимое имеет свой размер и обрезается (без переполнения во время
/// анимации); пока блок уходит — нажатия по нему не принимаются; когда
/// скрыт — содержимого в дереве нет.
class CollapseReveal extends StatefulWidget {
  const CollapseReveal({
    super.key,
    required this.open,
    required this.child,
    this.axis = Axis.horizontal,
  });

  final bool open;
  final Widget child;
  final Axis axis;

  @override
  State<CollapseReveal> createState() => _CollapseRevealState();
}

class _CollapseRevealState extends State<CollapseReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, value: widget.open ? 1 : 0)
        ..addStatusListener((_) {
          if (mounted) setState(() {});
        });
  late final Animation<double> _size = CurvedAnimation(
      parent: _c, curve: Motion.move, reverseCurve: Motion.move);
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Motion.enter, reverseCurve: Motion.exit);

  @override
  void didUpdateWidget(CollapseReveal old) {
    super.didUpdateWidget(old);
    if (old.open == widget.open) return;
    _c.duration = Motion.slow;
    _c.reverseDuration = Motion.slow;
    if (widget.open) {
      _c.forward();
    } else {
      _c.reverse();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_c.isDismissed && !widget.open) return const SizedBox.shrink();
    return SizeTransition(
      axis: widget.axis,
      sizeFactor: _size,
      alignment: widget.axis == Axis.horizontal
          ? AlignmentDirectional.centerStart
          : AlignmentDirectional.topCenter,
      child: IgnorePointer(
        ignoring: !widget.open, // уходящий блок
        child: LightFade(opacity: _fade, child: widget.child),
      ),
    );
  }
}

/// Строка списка: появляется (растёт по высоте и проявляется) или уходит
/// (тает и схлопывается, потом [onGone]). [animate] = false — сразу на
/// месте, без анимации (например, строки при первой загрузке списка).
/// Уходящая строка нажатий не принимает.
class SizeFade extends StatefulWidget {
  const SizeFade.appear({super.key, required this.child, this.animate = true})
      : leaving = false,
        onGone = null;

  const SizeFade.leave({super.key, required this.child, this.onGone})
      : leaving = true,
        animate = true;

  final Widget child;
  final bool animate;
  final bool leaving;
  final VoidCallback? onGone;

  @override
  State<SizeFade> createState() => _SizeFadeState();
}

class _SizeFadeState extends State<SizeFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _size;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    final d = widget.animate ? Motion.normal : Duration.zero;
    _c = AnimationController(
        vsync: this, duration: d, value: widget.leaving ? 1 : 0);
    _size = CurvedAnimation(parent: _c, curve: Motion.move);
    _fade = CurvedAnimation(
        parent: _c,
        curve: widget.leaving ? Motion.exit : Motion.enter);
    if (widget.leaving) {
      _c.reverse().whenComplete(() {
        if (mounted) widget.onGone?.call();
      });
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget child = LightFade(opacity: _fade, child: widget.child);
    if (widget.leaving) child = IgnorePointer(child: child);
    return SizeTransition(
      sizeFactor: _size,
      alignment: AlignmentDirectional.topCenter,
      child: child,
    );
  }
}

/// Отклик кнопки: при нажатии чуть уменьшается, курсор — «рука».
/// Нажатие не перехватывается (Listener), кнопка работает как раньше.
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.scale = 0.96,
    this.enabled = true,
  });

  final Widget child;
  final double scale;
  final bool enabled;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
      child: Listener(
        onPointerDown: widget.enabled ? (_) => _set(true) : null,
        onPointerUp: (_) => _set(false),
        onPointerCancel: (_) => _set(false),
        child: AnimatedScale(
          scale: _down && widget.enabled ? widget.scale : 1,
          duration: Motion.fast,
          curve: Motion.enter,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Быстрая смена небольшого текста (заголовок, статус): старый тает,
/// новый проявляется с крошечным сдвигом. Только для маленьких виджетов —
/// не для редактора.
class FadeSwitcher extends StatelessWidget {
  const FadeSwitcher({
    super.key,
    required this.child,
    this.alignment = Alignment.centerLeft,
    this.dy = 0.15,
    this.duration,
  });

  final Widget child;
  final Alignment alignment;

  /// Сдвиг нового текста в долях его высоты
  final double dy;

  /// null — Motion.fast
  final Duration? duration;

  @override
  Widget build(BuildContext context) {
    final d = duration ?? Motion.fast;
    return AnimatedSwitcher(
      duration: d,
      reverseDuration: d,
      switchInCurve: Motion.enter,
      switchOutCurve: Motion.exit,
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        children: [
          for (final p in previous) IgnorePointer(child: p),
          ?current,
        ],
      ),
      transitionBuilder: (child, a) => LightFade(
        opacity: a,
        child: dy == 0
            ? child
            : SlideTransition(
                position: Tween(begin: Offset(0, dy), end: Offset.zero)
                    .animate(a),
                child: child,
              ),
      ),
      child: child,
    );
  }
}

/// showDialog с анимацией приложения: затухание + лёгкое увеличение
/// (или, [slide], — небольшой сдвиг вверх, как у поиска)
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool slide = false,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    animationStyle: Motion.dialog,
    builder: (ctx) => FadeScaleIn(
      duration: Motion.normal,
      fade: false, // затухает сам маршрут диалога
      scaleFrom: slide ? 1 : 0.97,
      dy: slide ? 10 : 0,
      child: builder(ctx),
    ),
  );
}
