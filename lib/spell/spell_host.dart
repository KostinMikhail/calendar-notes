// Обёртка редактора: серые подчёркивания слов с ошибками (поверх текста,
// в документ ничего не пишется) и меню по правому клику на таком слове.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../main.dart' show kAccent, kDivider, kSurface, kTextPrimary,
    kTextSecondary;
import 'spell_edit.dart';
import 'spell_engine.dart';
import 'tokenizer.dart';

/// Цвет подчёркивания: приглушённый серый (вторичный текст на 65 %)
const Color kSpellUnderline = Color(0xA68D8A9C);

/// Пауза после последней правки перед проверкой
const Duration kSpellDebounce = Duration(milliseconds: 400);

class _Line {
  const _Line(this.start, this.text);
  final int start;
  final String text;
  int get end => start + text.length;
}

/// Слово с ошибкой в документе
class SpellHit {
  const SpellHit(this.range, this.token);
  final TextRange range;
  final SpellToken token;
}

class SpellCheckHost extends StatefulWidget {
  const SpellCheckHost({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.editorKey,
    required this.engine,
    required this.menuOpen,
    required this.child,
    this.scrollController,
  });

  final QuillController controller;
  final FocusNode focusNode;
  final GlobalKey<EditorState> editorKey;

  /// null — проверки нет (например, нет входа)
  final SpellEngine? engine;

  /// Открыто меню вариантов (плавающее меню форматирования ждёт)
  final ValueNotifier<bool> menuOpen;
  final ScrollController? scrollController;
  final Widget child;

  @override
  State<SpellCheckHost> createState() => SpellCheckHostState();
}

class SpellCheckHostState extends State<SpellCheckHost> {
  final _repaint = ValueNotifier<int>(0);
  List<_Line> _lines = const [];
  List<TextRange> _links = const [];
  String _text = '';
  Document? _doc;
  StreamSubscription<DocChange>? _docSub;

  /// Текст строки → слова с ошибками в ней (позиции внутри строки)
  final Map<String, List<SpellToken>> _flags = {};
  Timer? _debounce;
  int _gen = 0;

  /// Слово, которое сейчас набирают (не подчёркиваем, пока курсор в нём)
  TextRange? _editing;

  // меню
  final OverlayPortalController _menu = OverlayPortalController();
  SpellHit? _menuHit;
  List<String>? _suggestions; // null — ещё ищем
  Offset _menuPos = Offset.zero;
  int? _menuPointer;
  bool _browserMenuOff = false;

  QuillController get _c => widget.controller;
  SpellEngine? get _engine => widget.engine;

  @visibleForTesting
  int get flaggedLines => _flags.length;

  @override
  void initState() {
    super.initState();
    _subscribe();
    _attachDoc();
    _schedule();
  }

  void _subscribe() {
    _c.addListener(_onController);
    widget.engine?.addListener(_onEngine);
    widget.scrollController?.addListener(_onScroll);
    widget.focusNode.addListener(_onFocus);
  }

  void _unsubscribe(SpellCheckHost w) {
    w.controller.removeListener(_onController);
    w.engine?.removeListener(_onEngine);
    w.scrollController?.removeListener(_onScroll);
    w.focusNode.removeListener(_onFocus);
  }

  @override
  void didUpdateWidget(SpellCheckHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.engine != widget.engine ||
        oldWidget.scrollController != widget.scrollController ||
        oldWidget.focusNode != widget.focusNode) {
      _unsubscribe(oldWidget);
      _subscribe();
      _attachDoc();
      _flags.clear();
      _schedule();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _docSub?.cancel();
    _unsubscribe(widget);
    _closeMenu();
    _setBrowserMenu(true);
    _repaint.dispose();
    super.dispose();
  }

  // ---------- текст и проверка ----------

  /// Документ сменился (другой день/тема) — строки заново, подписка заново
  void _attachDoc() {
    final doc = _c.document;
    if (identical(doc, _doc)) return;
    _docSub?.cancel();
    _doc = doc;
    _docSub = doc.changes.listen((_) => _onTextChanged());
    _editing = null;
    _rebuild();
  }

  void _rebuild() {
    final text = _c.document.toPlainText();
    _text = text;
    final lines = <_Line>[];
    var start = 0;
    for (final part in text.split('\n')) {
      lines.add(_Line(start, part));
      start += part.length + 1;
    }
    _lines = lines;
    _links = linkRanges(_c.document.toDelta());
  }

  void _onTextChanged() {
    if (!mounted) return;
    _rebuild();
    final sel = _c.selection;
    _editing = sel.isValid && sel.isCollapsed
        ? wordAround(_text, sel.baseOffset)
        : null;
    _closeMenu();
    _schedule();
    _repaint.value++;
  }

  void _onController() {
    if (!identical(_c.document, _doc)) {
      _attachDoc();
      _closeMenu();
      _schedule();
    }
    // курсор ушёл из набираемого слова — теперь его можно подчеркнуть
    final e = _editing;
    if (e != null) {
      final sel = _c.selection;
      if (!sel.isValid ||
          !sel.isCollapsed ||
          sel.baseOffset < e.start ||
          sel.baseOffset > e.end) {
        _editing = null;
      }
    }
    _repaint.value++;
  }

  void _onEngine() {
    final engine = _engine;
    if (engine == null || !engine.enabled) {
      _closeMenu();
      _setBrowserMenu(true);
    }
    _flags.clear(); // личный словарь или включение изменились
    _schedule(immediate: true);
    _repaint.value++;
  }

  void _onScroll() {
    _closeMenu();
    _repaint.value++;
  }

  void _onFocus() {
    if (!widget.focusNode.hasFocus) _closeMenu();
  }

  void _schedule({bool immediate = false}) {
    _debounce?.cancel();
    _debounce = Timer(immediate ? Duration.zero : kSpellDebounce, _run);
  }

  /// Проверка строк, которых ещё нет в кэше: частями, с паузами, чтобы
  /// страница не подвисала на больших заметках
  Future<void> _run() async {
    final engine = _engine;
    if (!mounted || engine == null || !engine.active) return;
    final gen = ++_gen;
    final todo = <String>{
      for (final l in _lines)
        if (l.text.isNotEmpty && !_flags.containsKey(l.text)) l.text,
    }.toList();
    if (_flags.length + todo.length > 20000) _flags.clear();
    const chunk = 50; // ~10–15 мс на порцию: не дольше кадра
    for (var i = 0; i < todo.length; i += chunk) {
      final part = todo.skip(i).take(chunk).toList();
      final tokens = {for (final t in part) t: spellTokens(t)};
      try {
        await engine.checkTokens(tokens.values.expand((x) => x));
      } catch (_) {
        return; // словарь недоступен — попробуем при следующей правке
      }
      if (!mounted || gen != _gen || !engine.active) return;
      tokens.forEach((text, list) {
        _flags[text] = [for (final t in list) if (engine.isMisspelled(t)) t];
      });
      _repaint.value++;
      await Future<void>.delayed(Duration.zero);
      if (!mounted || gen != _gen) return;
    }
  }

  // ---------- где слова с ошибками ----------

  int _lineIndexAt(int offset) {
    var lo = 0, hi = _lines.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_lines[mid].start <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  bool _overlapsLink(TextRange r) {
    for (final l in _links) {
      if (r.start < l.end && r.end > l.start) return true;
    }
    return false;
  }

  /// Слова с ошибками между позициями [from] и [to] (видимая часть)
  Iterable<SpellHit> hitsBetween(int from, int to) sync* {
    final engine = _engine;
    if (engine == null || !engine.active || _lines.isEmpty) return;
    final editing = _editing;
    for (var i = _lineIndexAt(math.max(0, from)); i < _lines.length; i++) {
      final line = _lines[i];
      if (line.start > to) break;
      final flags = _flags[line.text];
      if (flags == null) continue;
      for (final t in flags) {
        final r = TextRange(start: line.start + t.start, end: line.start + t.end);
        if (editing != null && r.start <= editing.end && r.end >= editing.start) {
          continue;
        }
        if (_overlapsLink(r)) continue;
        yield SpellHit(r, t);
      }
    }
  }

  /// Отрезки подчёркиваний в координатах этого виджета: (начало, x конца)
  List<(Offset, double)> _underlines() {
    final editor = widget.editorKey.currentState?.renderEditor;
    final box = context.findRenderObject();
    if (editor == null ||
        !editor.attached ||
        !editor.hasSize ||
        box is! RenderBox ||
        !box.hasSize) {
      return const [];
    }
    final out = <(Offset, double)>[];
    try {
      final top = box.localToGlobal(Offset.zero);
      final bottom = box.localToGlobal(box.size.bottomRight(Offset.zero));
      final from = editor.getPositionForOffset(top).offset;
      final to = editor.getPositionForOffset(bottom).offset;
      for (final h in hitsBetween(from, to)) {
        final pts = editor.getEndpointsForSelection(
            TextSelection(baseOffset: h.range.start, extentOffset: h.range.end));
        if (pts.isEmpty) continue;
        final a = box.globalToLocal(editor.localToGlobal(pts.first.point));
        final b = box.globalToLocal(editor.localToGlobal(pts.last.point));
        if ((a.dy - b.dy).abs() > 1) continue; // слово перенесено — пропуск
        if (a.dy < -4 || a.dy > box.size.height + 4) continue;
        out.add((Offset(math.min(a.dx, b.dx), a.dy - 1), math.max(a.dx, b.dx)));
      }
    } catch (_) {
      return const []; // разметка ещё не обновилась
    }
    return out;
  }

  /// Слово с ошибкой под точкой экрана [global]
  SpellHit? hitAt(Offset global) {
    final engine = _engine;
    final editor = widget.editorKey.currentState?.renderEditor;
    if (engine == null || !engine.active || editor == null || !editor.attached) {
      return null;
    }
    try {
      final pos = editor.getPositionForOffset(global).offset;
      for (final h in hitsBetween(pos - 1, pos + 1)) {
        if (pos < h.range.start || pos > h.range.end) continue;
        final pts = editor.getEndpointsForSelection(
            TextSelection(baseOffset: h.range.start, extentOffset: h.range.end));
        final a = editor.localToGlobal(pts.first.point);
        final b = editor.localToGlobal(pts.last.point);
        final lineH =
            editor.preferredLineHeight(TextPosition(offset: h.range.start));
        final rect = Rect.fromLTRB(math.min(a.dx, b.dx), a.dy - lineH,
                math.max(a.dx, b.dx), a.dy)
            .inflate(2);
        if (rect.contains(global)) return h;
      }
    } catch (_) {}
    return null;
  }

  // ---------- правый клик ----------

  /// Над словом с ошибкой меню браузера не показываем (вместо него — наше)
  void _setBrowserMenu(bool on) {
    if (!kIsWeb || on == !_browserMenuOff) return;
    _browserMenuOff = !on;
    if (on) {
      BrowserContextMenu.enableContextMenu();
    } else {
      BrowserContextMenu.disableContextMenu();
    }
  }

  void _onHover(PointerHoverEvent e) {
    if (!kIsWeb) return;
    _setBrowserMenu(hitAt(e.position) == null);
  }

  void _onPointerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse ||
        (e.buttons & kSecondaryMouseButton) == 0) {
      return;
    }
    final hit = hitAt(e.position);
    if (hit == null) return; // не наше слово — всё как обычно
    _menuPointer = e.pointer;
    openMenu(hit, e.position);
  }

  /// Выделить слово и показать варианты у точки [global]
  void openMenu(SpellHit hit, Offset global) {
    _c.updateSelection(
      TextSelection(baseOffset: hit.range.start, extentOffset: hit.range.end),
      ChangeSource.local,
    );
    widget.focusNode.requestFocus();
    setState(() {
      _menuHit = hit;
      _suggestions = null;
      _menuPos = global;
    });
    if (!_menu.isShowing) {
      _menu.show();
      HardwareKeyboard.instance.addHandler(_onKey);
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
    }
    widget.menuOpen.value = true;
    final engine = _engine;
    engine?.suggestions(hit.token).then((list) {
      if (!mounted || !identical(_menuHit, hit)) return;
      setState(() => _suggestions = list);
    });
  }

  void _closeMenu() {
    if (!_menu.isShowing && _menuHit == null) return;
    if (_menu.isShowing) _menu.hide();
    HardwareKeyboard.instance.removeHandler(_onKey);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    _menuHit = null;
    // при dispose: дочерние виджеты уже убраны, флаг ещё жив (его хозяин —
    // страница редактора, она уничтожается позже)
    widget.menuOpen.value = false;
  }

  bool _onKey(KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
      _closeMenu();
      return true;
    }
    return false;
  }

  void _onGlobalPointer(PointerEvent e) {
    if (e is! PointerDownEvent) return;
    if (e.pointer == _menuPointer) return; // нажатие, открывшее меню / по меню
    _closeMenu();
  }

  void _replace(String word) {
    final hit = _menuHit;
    _closeMenu();
    if (hit == null) return;
    // меню закрывается при любой правке, так что слово на месте; на всякий
    // случай — проверка, что позиции ещё в тексте
    final doc = _c.document;
    if (hit.range.end > doc.length - 1) return;
    final caret = TextSelection.collapsed(offset: hit.range.start + word.length);
    _c.compose(replaceWordDelta(doc, hit.range, word), caret, ChangeSource.local);
    // compose сам пересчитывает старое выделение — курсор ставим явно
    _c.updateSelection(caret, ChangeSource.local);
    widget.focusNode.requestFocus();
  }

  void _addToDictionary() {
    final hit = _menuHit;
    _closeMenu();
    final engine = _engine;
    if (hit == null || engine == null) return;
    final word = hit.token.word;
    engine.dictionary.add(word);
    widget.focusNode.requestFocus();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 4),
      content: const Text('Добавлено в словарь'),
      action: SnackBarAction(
        label: 'Отменить',
        onPressed: () => engine.dictionary.remove(word),
      ),
    ));
  }

  // ---------- вид ----------

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _menu,
      overlayChildBuilder: _buildMenu,
      child: MouseRegion(
        opaque: false,
        onHover: _onHover,
        onExit: (_) => _setBrowserMenu(true),
        child: Listener(
          onPointerDown: _onPointerDown,
          child: Stack(
            children: [
              widget.child,
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _UnderlinePainter(
                      repaint: Listenable.merge([
                        _repaint,
                        ?widget.scrollController,
                      ]),
                      segments: _underlines,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const double _itemH = 34;
  static const double _menuW = 230;

  Widget _buildMenu(BuildContext context) {
    final hit = _menuHit;
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (hit == null || overlayBox is! RenderBox) return const SizedBox.shrink();
    final list = _suggestions;
    final rows = <Widget>[];
    if (list == null) {
      rows.add(_item('Поиск вариантов…', null));
    } else if (list.isEmpty) {
      rows.add(_item('Нет вариантов', null));
    } else {
      for (final s in list) {
        rows.add(_item(s, () => _replace(s), bold: true));
      }
    }
    rows.add(Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 4), color: kDivider));
    rows.add(_item('Добавить в словарь', _addToDictionary));
    final height = (rows.length - 1) * _itemH + 9 + 10;

    final size = overlayBox.size;
    var p = overlayBox.globalToLocal(_menuPos) + const Offset(2, 2);
    if (p.dx + _menuW > size.width - 4) p = Offset(size.width - 4 - _menuW, p.dy);
    if (p.dy + height > size.height - 4) p = Offset(p.dx, p.dy - height - 4);
    p = Offset(math.max(4, p.dx), math.max(4, p.dy));

    return Stack(
      children: [
        Positioned(
          left: p.dx,
          top: p.dy,
          child: Listener(
            onPointerDown: (e) => _menuPointer = e.pointer,
            child: TextFieldTapRegion(
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: _menuW,
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  decoration: BoxDecoration(
                    color: kSurface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kDivider),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x66000000),
                          blurRadius: 12,
                          offset: Offset(0, 4)),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: rows,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _item(String text, VoidCallback? onTap, {bool bold = false}) {
    final enabled = onTap != null;
    Widget row = Container(
      height: _itemH,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: enabled ? kTextPrimary : kTextSecondary,
          fontSize: 14,
          fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
    if (!enabled) return row;
    return _MenuRow(onTap: onTap, child: row);
  }
}

/// Пункт меню: срабатывает на нажатии левой кнопкой, подсвечивается при
/// наведении, фокус не берёт
class _MenuRow extends StatefulWidget {
  const _MenuRow({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          if (e.kind != PointerDeviceKind.mouse ||
              e.buttons == kPrimaryMouseButton) {
            widget.onTap();
          }
        },
        child: ColoredBox(
          color: _hover ? kAccent.withValues(alpha: 0.18) : Colors.transparent,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Тонкая серая волнистая линия под словами
class _UnderlinePainter extends CustomPainter {
  _UnderlinePainter({required Listenable repaint, required this.segments})
      : super(repaint: repaint);

  final List<(Offset, double)> Function() segments;

  @override
  void paint(Canvas canvas, Size size) {
    final segs = segments();
    if (segs.isEmpty) return;
    final paint = Paint()
      ..color = kSpellUnderline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final (start, endX) in segs) {
      final path = Path()..moveTo(start.dx, start.dy);
      var x = start.dx;
      var up = true;
      while (x < endX) {
        final nx = math.min(x + 2, endX);
        path.lineTo(nx, start.dy + (up ? -1 : 1));
        up = !up;
        x = nx;
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_UnderlinePainter old) => true;
}
