// Раскладка страницы для любой ширины окна.
//
// Широкое окно: слева колонка (баннер, календарь, «Сегодня», темы) шириной
// 320, справа заметка; колонку можно свернуть кнопкой у даты.
// Узкое окно: заметка на всю ширину и до низа страницы, колонка — панель,
// которая выезжает слева поверх заметки (с затемнением).
//
// Дерево одно на все ширины: панель заметки всегда на одном и том же месте
// (Row → Expanded), поэтому при смене ширины редактор не пересоздаётся —
// текст, курсор, выделение, прокрутка и фокус остаются.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';

/// Окно уже этого — узкая раскладка. При открытой колонке (320) и полях
/// страницы (2×20) заметке остаётся ширина окна − 360: от 720 это не меньше
/// 360 — шапка и панель форматирования помещаются без сжатия. Уже 720 (телефон
/// в любой ориентации кроме крупных, планшет 600–700) заметке лучше отдать всю
/// ширину, а колонку открывать поверх.
const double kNarrowLayoutMaxWidth = 720;

/// Ширина левой колонки в широком окне (как было)
const double kLeftColumnWidth = 320;

/// Узкая ли раскладка при такой ширине окна
bool isNarrowLayout(double width) => width < kNarrowLayoutMaxWidth;

/// Поле страницы вокруг панелей
double pagePadding(bool narrow) => narrow ? 12 : 20;

/// Ширина выезжающей панели: как колонка, но не шире окна − 48
double sideOverlayWidth(double viewport) =>
    math.max(0, math.min(kLeftColumnWidth, viewport - 48));

const List<String> _monthsGen = [
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
  'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'
];

/// Дата в шапке заметки: «9 ноября 2026». [short] (очень узкая шапка) —
/// без года, если он текущий: «9 ноября».
String formatHeaderDate(DateTime day,
    {bool short = false, required DateTime now}) {
  final base = '${day.day} ${_monthsGen[day.month - 1]}';
  return short && day.year == now.year ? base : '$base ${day.year}';
}

/// Каркас страницы. [leftColumn] строится только там, где он виден
/// (в колонке слева или в выезжающей панели); [notePanel] — всегда, на
/// одном месте дерева.
class ResponsiveShell extends StatelessWidget {
  const ResponsiveShell({
    super.key,
    required this.leftColumn,
    required this.notePanel,
    required this.wideColumnOpen,
    required this.overlayOpen,
    required this.onCloseOverlay,
    required this.scrimColor,
    required this.overlayColor,
    required this.overlayBorderColor,
  });

  final WidgetBuilder leftColumn;
  final Widget Function(BuildContext context, bool narrow) notePanel;

  /// Широкое окно: колонка открыта (выбор пользователя, узкое окно его не
  /// меняет)
  final bool wideColumnOpen;

  /// Узкое окно: панель календаря и тем открыта
  final bool overlayOpen;

  /// Закрыть панель (щелчок по затемнению, Esc, переход к широкому окну)
  final VoidCallback onCloseOverlay;

  final Color scrimColor;
  final Color overlayColor;
  final Color overlayBorderColor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final narrow = isNarrowLayout(constraints.maxWidth);
      // окно стало широким при открытой панели — закрыть её
      if (!narrow && overlayOpen) {
        WidgetsBinding.instance.addPostFrameCallback((_) => onCloseOverlay());
      }
      final pad = pagePadding(narrow);
      return Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1400),
                child: Padding(
                  padding: EdgeInsets.all(pad),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Календарь слева: плавно меняется ширина, содержимое
                      // своей ширины обрезается и тает (без переполнения).
                      // В узком окне колонка убрана сразу (Offstage — ширина
                      // 0, иначе на время анимации заметке не хватило бы
                      // места); её заменяет панель. Обратно — плавно.
                      Offstage(
                        offstage: narrow,
                        child: CollapseReveal(
                          open: !narrow && wideColumnOpen,
                          child: SizedBox(
                            width: kLeftColumnWidth,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 20),
                              child: Builder(builder: leftColumn),
                            ),
                          ),
                        ),
                      ),
                      // Заметка: всегда здесь, на всю оставшуюся ширину и
                      // высоту
                      Expanded(child: notePanel(context, narrow)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: SideOverlay(
              open: narrow && overlayOpen,
              onClose: onCloseOverlay,
              scrimColor: scrimColor,
              panelColor: overlayColor,
              borderColor: overlayBorderColor,
              builder: (context) => Padding(
                padding: EdgeInsets.all(pad),
                child: leftColumn(context),
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// Панель, выезжающая слева поверх страницы, с затемнением. Закрывается
/// щелчком по затемнению и клавишей Esc (только когда сверху нет другого
/// окна). Пока открыта, фокус клавиатуры у неё: ввод не уходит в заметку.
class SideOverlay extends StatefulWidget {
  const SideOverlay({
    super.key,
    required this.open,
    required this.onClose,
    required this.builder,
    required this.scrimColor,
    required this.panelColor,
    required this.borderColor,
    this.semanticLabel = 'Календарь и темы',
  });

  final bool open;
  final VoidCallback onClose;
  final WidgetBuilder builder;
  final Color scrimColor;
  final Color panelColor;
  final Color borderColor;
  final String semanticLabel;

  @override
  State<SideOverlay> createState() => _SideOverlayState();
}

class _SideOverlayState extends State<SideOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, value: widget.open ? 1 : 0)
        ..addStatusListener((_) {
          if (mounted) setState(() {});
        });
  late final Animation<double> _slide =
      CurvedAnimation(parent: _c, curve: Motion.enter, reverseCurve: Motion.exit);
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'side overlay');
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    if (widget.open) _opened();
  }

  @override
  void didUpdateWidget(SideOverlay old) {
    super.didUpdateWidget(old);
    if (old.open == widget.open) return;
    _c.duration = Motion.slow;
    _c.reverseDuration = Motion.normal;
    if (widget.open) {
      _c.forward();
      _opened();
    } else {
      _c.reverse();
      _closed();
    }
  }

  void _opened() {
    if (!_listening) {
      HardwareKeyboard.instance.addHandler(_onKey);
      _listening = true;
    }
    // фокус — в панель (после кадра, когда она построена)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.open) _scope.requestFocus();
    });
  }

  void _closed() {
    if (_listening) {
      HardwareKeyboard.instance.removeHandler(_onKey);
      _listening = false;
    }
    if (_scope.hasFocus) _scope.unfocus();
  }

  /// Esc закрывает панель, только если сверху нет окна или меню
  bool _onKey(KeyEvent e) {
    if (!widget.open || e is! KeyDownEvent) return false;
    if (e.logicalKey != LogicalKeyboardKey.escape) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    widget.onClose();
    return true;
  }

  @override
  void dispose() {
    if (_listening) HardwareKeyboard.instance.removeHandler(_onKey);
    _scope.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_c.isDismissed && !widget.open) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, c) {
      final width = sideOverlayWidth(c.maxWidth);
      return IgnorePointer(
        ignoring: !widget.open, // уходящая панель щелчки не ловит
        child: Stack(
          children: [
            // затемнение поверх заметки
            Positioned.fill(
              child: FadeTransition(
                opacity: _c,
                child: Semantics(
                  label: 'Закрыть панель',
                  button: true,
                  child: GestureDetector(
                    key: const ValueKey('side-overlay-scrim'),
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onClose,
                    child: ColoredBox(color: widget.scrimColor),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: width,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(-1, 0),
                  end: Offset.zero,
                ).animate(_slide),
                child: Semantics(
                  scopesRoute: true,
                  namesRoute: true,
                  explicitChildNodes: true,
                  label: widget.semanticLabel,
                  child: FocusScope(
                    node: _scope,
                    child: DecoratedBox(
                      key: const ValueKey('side-overlay-panel'),
                      decoration: BoxDecoration(
                        color: widget.panelColor,
                        border: Border(
                            right: BorderSide(color: widget.borderColor)),
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: widget.builder(context),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}
