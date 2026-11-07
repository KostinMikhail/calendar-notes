part of 'main.dart';

/// Общие функции редактора: панель форматирования, горячие клавиши, ссылки,
/// разделители. Ими пользуются редактор заметок и редактор шаблонов.
/// [_ec] и [_ef] — контроллер и фокус «своего» редактора; глобальный
/// обработчик клавиш срабатывает, только пока в фокусе именно он.
mixin _EditorKit<T extends StatefulWidget> on State<T> {
  QuillController get _ec;
  FocusNode get _ef;

  // --- разделители: курсор не должен на них попадать ---
  int? _prevCaret;
  bool _snapping = false;

  // ---------- горячие клавиши ----------

  /// Глобальный перехват: срабатывает раньше, чем сам редактор,
  /// но только пока курсор стоит в поле заметки.
  bool _onGlobalKey(KeyEvent event) {
    if (!_ef.hasFocus) return false;
    return _onEditorKey(_ef, event) == KeyEventResult.handled;
  }

  KeyEventResult _onEditorKey(FocusNode node, KeyEvent event) {
    final hk = HardwareKeyboard.instance;
    final ctrl = hk.isControlPressed || hk.isMetaPressed;
    final shift = hk.isShiftPressed;
    final alt = hk.isAltPressed;
    final logical = event.logicalKey;
    final physical = event.physicalKey;

    if (event is KeyUpEvent) return KeyEventResult.ignored;

    if (ctrl && shift) {
      // Ctrl+Shift+7 — нумерованный список, Ctrl+Shift+8 — маркированный
      if (physical == PhysicalKeyboardKey.digit7) {
        if (event is KeyDownEvent) _toggle(Attribute.ol);
        return KeyEventResult.handled;
      }
      if (physical == PhysicalKeyboardKey.digit8) {
        if (event is KeyDownEvent) _toggle(Attribute.ul);
        return KeyEventResult.handled;
      }
      // Ctrl+Shift+«минус» — разделитель (и не масштаб страницы в браузере)
      if (isDividerHotkey(
          ctrl: ctrl,
          shift: shift,
          alt: alt,
          logical: logical,
          physical: physical)) {
        if (event is KeyDownEvent) _insertDivider();
        return KeyEventResult.handled;
      }
    }

    if (ctrl && !shift && !alt) {
      // Ctrl+V: ссылка из буфера ложится на выделенный текст или
      // вставляется как ссылка; всё остальное — обычная вставка Quill.
      // Буфер в вебе читается асинхронно, поэтому сразу отвечаем «handled».
      if (physical == PhysicalKeyboardKey.keyV) {
        if (event is KeyDownEvent) _smartPaste();
        return KeyEventResult.handled;
      }
      // Ctrl+K — диалог «текст + адрес»
      if (physical == PhysicalKeyboardKey.keyK) {
        if (event is KeyDownEvent) _insertLink();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (!ctrl && !alt) {
      if (logical == LogicalKeyboardKey.tab) {
        _handleTab(shift);
        return KeyEventResult.handled;
      }
      if (logical == LogicalKeyboardKey.backspace && !shift) {
        if (_handleBackspace()) return KeyEventResult.handled;
      }
      if (logical == LogicalKeyboardKey.delete && !shift) {
        // Delete в конце строки перед разделителем не должен «съедать» его
        final sel = _ec.selection;
        if (sel.isCollapsed &&
            _dividerOffsets().contains(sel.baseOffset + 1)) {
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  /// Tab / Shift+Tab: уровень вложенности пункта списка (1. → a. → i.)
  void _handleTab(bool shift) {
    final attrs = _ec.getSelectionStyle().attributes;
    if (!attrs.containsKey(Attribute.list.key)) return;
    _ec.indentSelection(!shift);
  }

  /// Backspace в начале пункта списка: сначала уменьшает вложенность,
  /// затем снимает список; под разделителем строку с ним не склеивает.
  bool _handleBackspace() {
    final sel = _ec.selection;
    if (!sel.isCollapsed) return false;
    final pos = sel.baseOffset;
    final plain = _ec.document.toPlainText();
    final atLineStart = pos == 0 || (pos <= plain.length && plain[pos - 1] == '\n');
    if (!atLineStart) return false;

    final attrs = _ec.getSelectionStyle().attributes;
    final isList = attrs.containsKey(Attribute.list.key);
    final indent = attrs[Attribute.indent.key]?.value;
    if (isList && indent is int && indent > 0) {
      _ec.indentSelection(false);
      return true;
    }

    // строка сразу под разделителем
    final d = pos - 2;
    if (d >= 0 && _dividerOffsets().contains(d)) {
      if (isList) {
        _ec.formatSelection(Attribute.clone(Attribute.list, null));
      } else {
        _snapping = true;
        try {
          _ec.updateSelection(
            TextSelection.collapsed(offset: d > 0 ? d - 1 : 0),
            ChangeSource.local,
          );
        } finally {
          _snapping = false;
        }
      }
      return true;
    }
    return false;
  }

  // ---------- разделители (неактивные плашки) ----------

  /// Вставить разделитель отдельной строкой на месте курсора
  /// (Ctrl+Shift+«минус»). Одно изменение — один шаг Ctrl+Z.
  void _insertDivider() {
    final sel = _ec.selection;
    if (!sel.isValid) return;
    final ins =
        dividerInsertOps(_ec.document.toDelta().toJson(), sel.start);
    _ec.compose(Delta.fromJson(ins.ops), _ec.selection, ChangeSource.local);
    _ec.updateSelection(
      TextSelection.collapsed(
          offset: ins.caret.clamp(0, _ec.document.length - 1)),
      ChangeSource.local,
    );
    _ef.requestFocus();
  }

  /// Общие настройки редактора (заметки, темы, шаблоны)
  QuillEditorConfig _editorConfig(String placeholder) => QuillEditorConfig(
        placeholder: placeholder,
        padding: EdgeInsets.zero,
        expands: true,
        embedBuilders: const [DividerEmbedBuilder()],
        // клик по ссылке — меню «Открыть / Изменить / Убрать ссылку»
        customRecognizerBuilder: _linkRecognizer,
        customStyles: DefaultStyles(
          link: const TextStyle(
            color: Color(0xFF5AB0FF),
            decoration: TextDecoration.underline,
            decorationColor: Color(0xFF5AB0FF),
          ),
        ),
      );

  /// Позиции всех разделителей в документе
  List<int> _dividerOffsets() {
    final res = <int>[];
    var off = 0;
    for (final op in _ec.document.toDelta().toList()) {
      final data = op.data;
      if (data is Map && data.containsKey('divider')) res.add(off);
      off += op.length ?? 0;
    }
    return res;
  }

  /// Разделитель нельзя выделить и нельзя поставить на него курсор:
  /// если выделение попало на него, оно сдвигается на соседнюю строку.
  void _snapSelectionOffDividers() {
    final sel = _ec.selection;
    if (!sel.isValid) return;
    final divs = _dividerOffsets();
    final prev = _prevCaret;
    if (divs.isEmpty) {
      _prevCaret = sel.extentOffset;
      return;
    }
    final len = _ec.document.length;
    var s = sel.start;
    var e = sel.end;
    var changed = false;

    for (final d in divs) {
      // строка разделителя: символ d и перенос d+1
      final cameFromBelow = prev != null && prev > d + 1;
      if (s == e) {
        if (s == d || s == d + 1) {
          final target = cameFromBelow ? (d > 0 ? d - 1 : 0) : (d + 2 < len ? d + 2 : len - 1);
          s = target;
          e = target;
          changed = true;
        }
      } else if (s >= d && e <= d + 2) {
        final target = d + 2 < len ? d + 2 : len - 1;
        s = target;
        e = target;
        changed = true;
      } else {
        if (s == d || s == d + 1) {
          s = d + 2;
          changed = true;
        }
        if (e == d + 1) {
          e = d;
          changed = true;
        }
      }
    }

    if (changed) {
      final forward = sel.baseOffset <= sel.extentOffset;
      final next = TextSelection(
        baseOffset: forward ? s : e,
        extentOffset: forward ? e : s,
      );
      _snapping = true;
      try {
        _ec.updateSelection(next, ChangeSource.local);
      } finally {
        _snapping = false;
      }
      _prevCaret = next.extentOffset;
    } else {
      _prevCaret = sel.extentOffset;
    }
  }

  // ---------- ссылки (как в Slack) ----------

  /// Ctrl+V. Буфер в вебе читается асинхронно (и с разрешения браузера),
  /// поэтому всё делаем после ответа «handled». Ошибка чтения — ничего не делаем.
  Future<void> _smartPaste() async {
    final sel = _ec.selection;
    if (!sel.isValid) return;
    final doc = _ec.document;

    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      return;
    }
    if (!mounted) return;

    final url = _asUrl(text);
    if (url != null) {
      // пока читали буфер, могли переключить день или сдвинуть курсор
      if (!identical(doc, _ec.document) || _ec.selection != sel) {
        return;
      }
      // с выделением: текст остаётся и становится ссылкой;
      // без выделения: вставляется сам адрес как ссылка
      _applyLink(sel.start, sel.end - sel.start, text!.trim(), url);
      return;
    }

    // не ссылка — обычная вставка редактора (замена выделения, форматирование и т.д.)
    try {
      // тот же метод, который Quill сам вызывает на Ctrl+V
      // ignore: experimental_member_use
      await _ec.clipboardPaste();
    } catch (_) {}
  }

  /// Ссылка на диапазон [start, start+len) или вставка [label] в позицию [start].
  /// Цвет с текста снимается. Всё делается одной правкой — один шаг Ctrl+Z.
  void _applyLink(int start, int len, String label, String url) {
    final docLen = _ec.document.length;
    if (start < 0 || start + len > docLen - 1) return;

    int caret;
    if (len > 0) {
      _composeOneStep(_inlineDelta(start, len, {
        Attribute.color.key: null,
        Attribute.link.key: url,
      }));
      caret = start + len;
    } else {
      if (label.isEmpty) return;
      _composeOneStep(
          Delta()..retain(start)..insert(label, {Attribute.link.key: url}));
      caret = start + label.length;
    }
    _ec.updateSelection(
      TextSelection.collapsed(offset: caret),
      ChangeSource.local,
    );
    _ef.requestFocus();
  }

  /// Delta, которая накладывает inline-атрибуты на текст диапазона,
  /// пропуская переносы строк и разделители
  Delta _inlineDelta(int start, int len, Map<String, dynamic> attrs) {
    final plain = _ec.document.toPlainText();
    final end = min(start + len, plain.length - 1);
    bool isSkip(int i) => plain[i] == '\n' || plain[i] == '￼';

    final delta = Delta()..retain(start);
    var i = start;
    while (i < end) {
      final skip = isSkip(i);
      var j = i;
      while (j < end && isSkip(j) == skip) {
        j++;
      }
      if (skip) {
        delta.retain(j - i);
      } else {
        delta.retain(j - i, attrs);
      }
      i = j;
    }
    return delta;
  }

  void _composeOneStep(Delta delta) {
    _ec.compose(delta, _ec.selection, ChangeSource.local);
  }

  /// Адрес для открытия: без схемы — добавляем https://
  String _normalizeUrl(String raw) {
    final s = raw.trim();
    final asUrl = _asUrl(s);
    if (asUrl != null) return asUrl;
    if (s.startsWith(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:'))) return s;
    return 'https://$s';
  }

  /// Открывает ссылку в новой вкладке. Вызывается синхронно из клика:
  /// launchUrl в вебе доходит до window.open без await.
  void _openUrl(String url) {
    final uri = Uri.tryParse(_normalizeUrl(url));
    if (uri == null) return;
    launchUrl(uri, webOnlyWindowName: '_blank').catchError((_) => false);
  }

  /// Клик по ссылке в редакторе — маленькое меню вместо перехода
  GestureRecognizer? _linkRecognizer(Attribute attribute, Leaf leaf) {
    if (attribute.key != Attribute.link.key || attribute.value == null) {
      return null;
    }
    return TapGestureRecognizer()
      ..onTapUp = (details) => _showLinkMenu(leaf, details.globalPosition);
  }

  Future<void> _showLinkMenu(Leaf leaf, Offset globalPos) async {
    final url = leaf.style.attributes[Attribute.link.key]?.value?.toString();
    if (url == null || url.isEmpty) return;
    final doc = _ec.document;
    final range = getLinkRange(leaf);

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final p = overlay.globalToLocal(globalPos);

    PopupMenuItem<String> item(String value, IconData icon, String title,
            {VoidCallback? onTap}) =>
        PopupMenuItem<String>(
          value: value,
          height: 40,
          onTap: onTap,
          child: Row(
            children: [
              Icon(icon, size: 18, color: kTextSecondary),
              const SizedBox(width: 10),
              Text(title, style: const TextStyle(color: kTextPrimary)),
            ],
          ),
        );

    final choice = await showMenu<String>(
      context: context,
      color: kCard,
      position: RelativeRect.fromLTRB(
        p.dx,
        p.dy + 8,
        overlay.size.width - p.dx,
        overlay.size.height - p.dy,
      ),
      items: [
        // клик по адресу — копирование в буфер, меню остаётся открытым
        _CopyUrlEntry(url),
        // открываем прямо в обработчике клика, пока браузер считает это
        // действием пользователя
        item('open', Icons.open_in_new, 'Открыть', onTap: () => _openUrl(url)),
        item('edit', Icons.edit_outlined, 'Изменить'),
        item('remove', Icons.link_off, 'Убрать ссылку'),
      ],
    );
    if (!mounted || choice == null) return;
    // пока меню было открыто, могли переключить день
    if (!identical(doc, _ec.document)) return;
    if (range.end > _ec.document.length - 1) return;

    switch (choice) {
      case 'open':
        break; // уже открыто в onTap пункта меню
      case 'edit':
        await _insertLink(range: range, currentUrl: url);
        break;
      case 'remove':
        // текст остаётся, снимается только ссылка
        _composeOneStep(_inlineDelta(
            range.start, range.end - range.start, {Attribute.link.key: null}));
        _ef.requestFocus();
        break;
    }
  }

  String? _asUrl(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty || RegExp(r'\s').hasMatch(s)) return null;
    if (RegExp(r'^(https?|ftp)://\S+$', caseSensitive: false).hasMatch(s) ||
        RegExp(r'^mailto:\S+$', caseSensitive: false).hasMatch(s)) {
      return s;
    }
    if (RegExp(r'^www\.\S+\.\S+$', caseSensitive: false).hasMatch(s)) {
      return 'https://$s';
    }
    return null;
  }

  // ---------- форматирование ----------

  bool _isActive(Attribute attr) {
    final current = _ec.getSelectionStyle().attributes[attr.key];
    return current != null && current.value == attr.value;
  }

  void _toggle(Attribute attr) {
    _ec.formatSelection(
      _isActive(attr) ? Attribute.clone(attr, null) : attr,
    );
    _ef.requestFocus();
  }

  bool _isColor(String hex) {
    final current =
        _ec.getSelectionStyle().attributes[Attribute.color.key];
    return current != null && current.value == hex;
  }

  void _toggleColor(String hex) {
    if (_isColor(hex)) {
      _ec.formatSelection(Attribute.clone(Attribute.color, null));
    } else {
      _ec.formatSelection(ColorAttribute(hex));
    }
    _ef.requestFocus();
  }

  /// Ctrl+K / кнопка в панели / «Изменить» в меню ссылки.
  /// Если текст выделен (или передан [range]), поле «Текст» заполнено им
  /// и недоступно для правки.
  Future<void> _insertLink({TextRange? range, String? currentUrl}) async {
    final sel = _ec.selection;
    if (range == null && !sel.isValid) return;
    final start = range?.start ?? sel.start;
    final len = range != null ? range.end - range.start : sel.end - sel.start;
    final hasSelection = len > 0;
    final doc = _ec.document;

    final selectedText = hasSelection
        ? doc
            .toPlainText()
            .substring(start, start + len)
            .replaceAll('￼', '')
            .replaceAll('\n', ' ')
        : '';
    final oldUrl = currentUrl ??
        (hasSelection
            ? doc.collectStyle(start, len).attributes[Attribute.link.key]?.value
                as String?
            : null);

    final urlCtrl = TextEditingController(text: oldUrl ?? '');
    final textCtrl = TextEditingController(text: selectedText);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: Text(oldUrl == null ? 'Вставить ссылку' : 'Изменить ссылку'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: textCtrl,
                enabled: !hasSelection,
                decoration: const InputDecoration(labelText: 'Текст'),
              ),
              TextField(
                controller: urlCtrl,
                autofocus: true,
                decoration:
                    const InputDecoration(labelText: 'Адрес (https://...)'),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(oldUrl == null ? 'Вставить' : 'Сохранить')),
        ],
      ),
    );
    final rawUrl = urlCtrl.text.trim();
    final label = textCtrl.text.trim();
    urlCtrl.dispose();
    textCtrl.dispose();
    if (ok != true || !mounted) {
      _ef.requestFocus();
      return;
    }
    if (rawUrl.isEmpty || !identical(doc, _ec.document)) return;

    final url = _normalizeUrl(rawUrl);
    if (hasSelection) {
      _applyLink(start, len, '', url);
    } else {
      _applyLink(start, 0, label.isEmpty ? rawUrl : label, url);
    }
  }

  // ---------- элементы интерфейса ----------

  Widget _toolButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    required bool active,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: active ? kAccent.withValues(alpha: 0.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: active ? kAccent : Colors.transparent),
          ),
          child: Icon(icon,
              size: 19, color: active ? kAccentLight : kTextSecondary),
        ),
      ),
    );
  }

  Widget _colorDot(String hex, String tooltip) {
    final c = Color(int.parse('FF${hex.substring(1)}', radix: 16));
    final active = _isColor(hex);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _toggleColor(hex),
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(
                color: active ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _vDivider() => Container(
        width: 1,
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: kDivider,
      );

  Widget _toolbar() {
    return ListenableBuilder(
      listenable: _ec,
      builder: (context, _) {
        final hasLink = _ec
            .getSelectionStyle()
            .attributes
            .containsKey(Attribute.link.key);
        return Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 2,
          runSpacing: 2,
          children: [
            _toolButton(
              icon: Icons.format_bold,
              tooltip: 'Жирный (Ctrl+B)',
              active: _isActive(Attribute.bold),
              onPressed: () => _toggle(Attribute.bold),
            ),
            _toolButton(
              icon: Icons.strikethrough_s,
              tooltip: 'Зачёркнутый',
              active: _isActive(Attribute.strikeThrough),
              onPressed: () => _toggle(Attribute.strikeThrough),
            ),
            _toolButton(
              icon: Icons.link,
              tooltip: 'Ссылка (Ctrl+K, или выделите текст и вставьте ссылку Ctrl+V)',
              active: hasLink,
              onPressed: () => _insertLink(),
            ),
            _vDivider(),
            _colorDot(kRed, 'Красный'),
            _colorDot(kYellow, 'Жёлтый'),
            _colorDot(kGreen, 'Зелёный'),
            _vDivider(),
            _toolButton(
              icon: Icons.format_list_numbered,
              tooltip: 'Нумерованный список (Ctrl+Shift+7)',
              active: _isActive(Attribute.ol),
              onPressed: () => _toggle(Attribute.ol),
            ),
            _toolButton(
              icon: Icons.format_list_bulleted,
              tooltip: 'Маркированный список (Ctrl+Shift+8)',
              active: _isActive(Attribute.ul),
              onPressed: () => _toggle(Attribute.ul),
            ),
          ],
        );
      },
    );
  }
}
