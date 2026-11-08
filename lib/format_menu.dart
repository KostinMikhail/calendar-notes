// Плавающее меню над выделенным текстом (жирный, зачёркнутый, три цвета) и
// запоминаемая видимость верхней панели форматирования.
//
// Меню — только надстройка над редактором: форматирует так же, как
// панель (controller.formatSelection), фокус и выделение не трогает.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'main.dart'
    show kAccent, kAccentLight, kDivider, kGreen, kRed, kSurface,
        kTextSecondary, kYellow;
import 'offline_web_stub.dart' if (dart.library.js_interop) 'offline_web.dart'
    as web;

// ============================================================
//  Положение меню
// ============================================================

/// Где поставить меню (левый верхний угол, в тех же координатах, что и
/// [anchor] / [viewport]). [anchor] — прямоугольник выделения, [viewport] —
/// видимая область редактора. Над выделением по центру; сверху нет места —
/// под ним; по горизонтали — в пределах области. null — выделение целиком
/// вне видимой области (меню не показываем).
Offset? placeFormatMenu({
  required Rect anchor,
  required Size menu,
  required Rect viewport,
  double gap = 8,
  double margin = 4,
}) {
  if (anchor.bottom < viewport.top || anchor.top > viewport.bottom) {
    return null;
  }
  // видимая часть выделения
  final top = math.max(anchor.top, viewport.top);
  final bottom = math.min(anchor.bottom, viewport.bottom);

  var y = top - gap - menu.height;
  if (y < viewport.top) {
    y = bottom + gap; // сверху тесно — под выделением
    if (y + menu.height > viewport.bottom) {
      // ни сверху, ни снизу — у верхнего края области
      y = viewport.top;
    }
  }

  final minX = viewport.left + margin;
  final maxX = viewport.right - margin - menu.width;
  var x = anchor.center.dx - menu.width / 2;
  if (maxX < minX) {
    x = viewport.left; // меню шире области
  } else {
    x = x.clamp(minX, maxX);
  }
  return Offset(x, y);
}

// ============================================================
//  Состояние и применение форматирования (как в панели)
// ============================================================

/// Формат есть у всего выделения (смешанное — нет); так же определяет
/// активные кнопки верхняя панель
bool selectionHasFormat(QuillController c, Attribute attr) {
  final current = c.getSelectionStyle().attributes[attr.key];
  return current != null && current.value == attr.value;
}

/// Включить/выключить формат на всём выделении: есть у всего — снять,
/// нет или смешанное — поставить всему
void toggleSelectionFormat(QuillController c, Attribute attr) {
  c.formatSelection(
      selectionHasFormat(c, attr) ? Attribute.clone(attr, null) : attr);
}

/// Цвет всего выделения (#RRGGBB) или null (нет / разный)
String? selectionColor(QuillController c) {
  final v = c.getSelectionStyle().attributes[Attribute.color.key]?.value;
  return v is String ? v : null;
}

/// Цвет текста: [hex] — поставить; повторно тот же — снять (как кружок в
/// панели); null — «без цвета»
void applySelectionColor(QuillController c, String? hex) {
  if (hex == null || selectionColor(c) == hex) {
    c.formatSelection(Attribute.clone(Attribute.color, null));
  } else {
    c.formatSelection(ColorAttribute(hex));
  }
}

// ============================================================
//  Видимость верхней панели форматирования (localStorage)
// ============================================================

/// Хранилище строк (в тестах — подделка)
abstract class PrefStore {
  String? read(String key);
  void write(String key, String value);
}

/// localStorage браузера (ошибки — молча, см. offline_web.dart)
class LocalPrefStore implements PrefStore {
  const LocalPrefStore();

  @override
  String? read(String key) => web.readLocal(key);

  @override
  void write(String key, String value) => web.writeLocal(key, value);
}

/// Показана ли панель форматирования. По умолчанию (и при любой ошибке
/// хранилища) — скрыта.
class ToolbarVisibilityPref {
  const ToolbarVisibilityPref([this.store = const LocalPrefStore()]);

  final PrefStore store;

  static const String storageKey = 'calendar-notes.toolbar-visible';

  bool load() {
    try {
      return store.read(storageKey) == '1';
    } catch (_) {
      return false;
    }
  }

  void save(bool visible) {
    try {
      store.write(storageKey, visible ? '1' : '0');
    } catch (_) {}
  }
}

/// Кнопка в шапке заметки: показать/скрыть панель форматирования
class ToolbarToggleButton extends StatelessWidget {
  const ToolbarToggleButton(
      {super.key, required this.visible, required this.onPressed});

  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      isSelected: visible,
      icon: Icon(Icons.text_format,
          color: visible ? kAccentLight : kAccent),
      style: visible
          ? IconButton.styleFrom(
              backgroundColor: kAccent.withValues(alpha: 0.18))
          : null,
      tooltip: visible
          ? 'Скрыть панель форматирования'
          : 'Показать панель форматирования',
      onPressed: onPressed,
    );
  }
}

/// Панель форматирования, которая плавно появляется и прячется
/// (вместе с отступом под ней)
class CollapsibleToolbar extends StatelessWidget {
  const CollapsibleToolbar(
      {super.key, required this.visible, required this.child, this.gap = 12});

  final bool visible;
  final Widget child;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: visible
            ? Padding(padding: EdgeInsets.only(bottom: gap), child: child)
            : const SizedBox(width: double.infinity, height: 0),
      ),
    );
  }
}

// ============================================================
//  Плавающее меню
// ============================================================

const double _kBtn = 32;
const double _kPad = 4;
const double _kGapBtn = 2;

/// Размер меню из [n] кнопок
Size formatMenuSize(int n) =>
    Size(_kPad * 2 + n * _kBtn + (n - 1) * _kGapBtn + 2, _kBtn + _kPad * 2 + 2);

/// Оборачивает редактор: над непустым выделением показывает меню
/// «жирный / зачёркнутый / цвет». [editorKey] — тот же ключ, что в
/// QuillEditorConfig.editorKey (через него берётся положение выделения).
class FormatMenuHost extends StatefulWidget {
  const FormatMenuHost({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.editorKey,
    required this.child,
    this.scrollController,
    this.suppressed,
  });

  final QuillController controller;
  final FocusNode focusNode;
  final GlobalKey<EditorState> editorKey;
  final ScrollController? scrollController;
  final Widget child;

  /// true — меню не показывать (открыто меню вариантов правописания)
  final ValueListenable<bool>? suppressed;

  @override
  State<FormatMenuHost> createState() => _FormatMenuHostState();
}

class _FormatMenuHostState extends State<FormatMenuHost>
    with WidgetsBindingObserver {
  static const Duration _settle = Duration(milliseconds: 130);

  final OverlayPortalController _portal = OverlayPortalController();
  Timer? _debounce;
  /// Нажатые сейчас указатели вне меню (выделение мышью ещё идёт)
  final Set<int> _outside = {};

  /// Указатель, нажатый на меню (его нажатие не прячет меню)
  int? _menuPointer;
  Offset? _pos; // где меню (глобально)
  String _lastText = '';

  QuillController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _lastText = _c.document.toPlainText();
    _subscribe();
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  void _subscribe() {
    _c.addListener(_onControllerChanged);
    widget.focusNode.addListener(_onFocusChanged);
    widget.scrollController?.addListener(_onScroll);
    widget.suppressed?.addListener(_onSuppressed);
  }

  void _unsubscribe(FormatMenuHost w) {
    w.controller.removeListener(_onControllerChanged);
    w.focusNode.removeListener(_onFocusChanged);
    w.scrollController?.removeListener(_onScroll);
    w.suppressed?.removeListener(_onSuppressed);
  }

  void _onSuppressed() {
    if (widget.suppressed?.value ?? false) {
      _hide();
    } else {
      _schedule();
    }
  }

  @override
  void didUpdateWidget(FormatMenuHost old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller ||
        old.focusNode != widget.focusNode ||
        old.scrollController != widget.scrollController ||
        old.suppressed != widget.suppressed) {
      _unsubscribe(old);
      _subscribe();
      _hide();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _unsubscribe(widget);
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    super.dispose();
  }

  // ---------- когда показывать ----------

  void _onControllerChanged() {
    final text = _c.document.toPlainText();
    if (text != _lastText) {
      // ввод, удаление, другой день — меню прячется
      _lastText = text;
      _hide();
    }
    _schedule();
  }

  void _onFocusChanged() {
    if (!widget.focusNode.hasFocus) {
      _debounce?.cancel();
      _hide();
    } else {
      _schedule();
    }
  }

  /// Во время прокрутки меню нет; появится, когда прокрутка закончится
  void _onScroll() {
    _hide();
    _schedule();
  }

  @override
  void didChangeMetrics() {
    _hide();
    _schedule();
  }

  void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) {
      if (e.pointer == _menuPointer) return; // нажали на меню
      // нажатие мимо меню (новое выделение, другой день…) — прячем
      _outside.add(e.pointer);
      _hide();
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      if (_outside.remove(e.pointer)) {
        _schedule(); // выделение мышью — меню после отпускания
      }
    }
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(_settle, _update);
  }

  void _update() {
    if (!mounted) return;
    final sel = _c.selection;
    final routeOk = ModalRoute.of(context)?.isCurrent ?? true;
    if (!sel.isValid ||
        sel.isCollapsed ||
        !widget.focusNode.hasFocus ||
        _outside.isNotEmpty ||
        (widget.suppressed?.value ?? false) ||
        !routeOk) {
      _hide();
      return;
    }
    final anchor = _selectionRect(sel);
    final box = context.findRenderObject();
    if (anchor == null || box is! RenderBox || !box.hasSize) {
      _hide();
      return;
    }
    final viewport = box.localToGlobal(Offset.zero) & box.size;
    final size = formatMenuSize(_items);
    final pos = placeFormatMenu(anchor: anchor, menu: size, viewport: viewport);
    if (pos == null) {
      _hide();
      return;
    }
    setState(() => _pos = pos);
    if (!_portal.isShowing) _portal.show();
  }

  /// Прямоугольник выделения на экране (глобальные координаты)
  Rect? _selectionRect(TextSelection sel) {
    final editor = widget.editorKey.currentState?.renderEditor;
    if (editor == null || !editor.attached || !editor.hasSize) return null;
    try {
      final points = editor.getEndpointsForSelection(sel);
      if (points.isEmpty) return null;
      final lineH =
          editor.preferredLineHeight(TextPosition(offset: sel.start));
      final a = editor.localToGlobal(points.first.point);
      final b = editor.localToGlobal(points.last.point);
      return Rect.fromLTRB(math.min(a.dx, b.dx), math.min(a.dy, b.dy) - lineH,
          math.max(a.dx, b.dx), math.max(a.dy, b.dy));
    } catch (_) {
      return null; // документ сменился между кадрами и т.п.
    }
  }

  void _hide() {
    if (_portal.isShowing) _portal.hide();
  }

  // ---------- действия ----------

  /// Форматирование из меню: выделение остаётся, фокус — в редакторе
  void _apply(void Function() format) {
    format();
    _lastText = _c.document.toPlainText(); // текст не менялся — меню остаётся
    widget.focusNode.requestFocus();
    _schedule();
  }

  // ---------- вид ----------

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _buildMenu,
      child: widget.child,
    );
  }

  Widget _buildMenu(BuildContext context) {
    final pos = _pos;
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (pos == null || overlayBox is! RenderBox) return const SizedBox.shrink();
    final local = overlayBox.globalToLocal(pos);
    return Stack(
      children: [
        Positioned(
          left: local.dx,
          top: local.dy,
          // нажатия по меню — «внутри редактора»: фокус не снимается
          child: Listener(
            onPointerDown: (e) => _menuPointer = e.pointer,
            child: TextFieldTapRegion(
              child: ListenableBuilder(
                listenable: _c,
                builder: (context, _) => _bubble(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _bubble() {
    final children = _menuItems();
    final size = formatMenuSize(children.length);
    return Container(
      width: size.width,
      height: size.height,
      padding: const EdgeInsets.all(_kPad),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDivider),
        boxShadow: const [
          BoxShadow(
              color: Color(0x66000000), blurRadius: 10, offset: Offset(0, 3)),
        ],
      ),
      child: Row(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: _kGapBtn),
            children[i],
          ],
        ],
      ),
    );
  }

  /// Кнопок в меню: жирный, зачёркнутый и три цвета
  static const int _items = 5;

  List<Widget> _menuItems() {
    final current = selectionColor(_c);
    // цвет сразу в меню; нажатие на уже выбранный — обычный цвет текста
    Widget dot(String hex, String name) => _MenuButton(
          tooltip: current == hex
              ? '$name — нажмите ещё раз, чтобы убрать цвет'
              : name,
          active: false, // выбранный цвет — белое кольцо, как в панели
          onPressed: () => _apply(() => applySelectionColor(_c, hex)),
          child: _dot(_hexColor(hex), current == hex),
        );
    return [
      _MenuButton(
        tooltip: 'Жирный',
        active: selectionHasFormat(_c, Attribute.bold),
        onPressed: () =>
            _apply(() => toggleSelectionFormat(_c, Attribute.bold)),
        child: _icon(Icons.format_bold, selectionHasFormat(_c, Attribute.bold)),
      ),
      _MenuButton(
        tooltip: 'Зачёркнутый (Ctrl+Shift+X)',
        active: selectionHasFormat(_c, Attribute.strikeThrough),
        onPressed: () =>
            _apply(() => toggleSelectionFormat(_c, Attribute.strikeThrough)),
        child: _icon(Icons.strikethrough_s,
            selectionHasFormat(_c, Attribute.strikeThrough)),
      ),
      dot(kRed, 'Красный'),
      dot(kYellow, 'Жёлтый'),
      dot(kGreen, 'Зелёный'),
    ];
  }

  static Color _hexColor(String hex) =>
      Color(int.parse('FF${hex.substring(1)}', radix: 16));

  Widget _icon(IconData icon, bool active) =>
      Icon(icon, size: 18, color: active ? kAccentLight : kTextSecondary);

  Widget _dot(Color c, bool active) => Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(
              color: active ? Colors.white : Colors.transparent, width: 2),
        ),
      );
}

/// Кнопка меню: срабатывает на нажатии (до любых смен фокуса), сама фокус
/// не берёт
class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.tooltip,
    required this.active,
    required this.onPressed,
    required this.child,
  });

  final String tooltip;
  final bool active;
  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            if (e.buttons == kPrimaryButton || e.kind != PointerDeviceKind.mouse) {
              onPressed();
            }
          },
          child: Container(
            width: _kBtn,
            height: _kBtn,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? kAccent.withValues(alpha: 0.2) : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                  color: active ? kAccent : Colors.transparent),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
