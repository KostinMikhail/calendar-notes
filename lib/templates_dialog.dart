part of 'main.dart';

/// Окно «Шаблоны»: тексты шаблонов по дням недели и особых блоков.
/// Редактор — тот же, что у заметок (_EditorKit): панель, горячие клавиши,
/// ссылки, разделители.
class _TemplatesDialog extends StatefulWidget {
  const _TemplatesDialog({
    required this.initial,
    required this.store,
    required this.onSaved,
    this.spell,
  });

  final TemplateSettings initial;
  final TemplateStore store;
  final ValueChanged<TemplateSettings> onSaved;

  /// Проверка правописания приложения (null — нет)
  final SpellEngine? spell;

  @override
  State<_TemplatesDialog> createState() => _TemplatesDialogState();
}

class _TemplatesDialogState extends State<_TemplatesDialog>
    with _EditorKit<_TemplatesDialog> {
  // задачи в «Задачах на день» видны, но кнопки неактивны
  @override
  TaskMode get _taskMode => TaskMode.inert;

  static const List<String> _weekdayNames = [
    'Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота',
    'Воскресенье'
  ];
  static const Map<String, (String, String)> _blockInfo = {
    kBlockVadimWeek: (
      'Вадим викли',
      'Каждый второй четверг — отдельным блоком перед последним блоком дня.'
    ),
    kBlockMonthlyReport: (
      'Отчёт в первый рабочий день месяца',
      'В первый блок дня — перед первым пустым пунктом.'
    ),
    kBlockHolidayNote: (
      'Напоминание накануне праздника',
      'В последний блок дня («Не забыть») — сразу после заголовка.'
    ),
  };

  final QuillController _tc =
      QuillController.basic(config: kEditorControllerConfig);
  final FocusNode _tf = FocusNode();
  final ScrollController _scroll = ScrollController();

  @override
  QuillController get _ec => _tc;

  @override
  SpellEngine? get _spellEngine => widget.spell;
  @override
  FocusNode get _ef => _tf;

  /// Изменённые шаблоны: 'w1'..'w7' — дни недели, `b:<id>` — особые блоки.
  /// Нет ключа — стандартный шаблон.
  late Map<String, String> _custom;
  late Map<String, String> _saved; // как сейчас лежит в базе
  late String _key;
  String _loadedJson = ''; // что было в редакторе при открытии шаблона
  String _status = '';
  bool _saving = false;

  /// Цвет блока «Не забыть» в стандартных шаблонах при показе
  String get _accent => kNotForgetColors.first;

  @override
  void initState() {
    super.initState();
    _custom = {
      for (final e in widget.initial.weekdays.entries) 'w${e.key}': e.value,
      for (final e in widget.initial.blocks.entries) 'b:${e.key}': e.value,
    };
    _saved = Map.of(_custom);
    _key = 'w${DateTime.now().weekday}';
    // горячие клавиши — только пока в фокусе этот редактор (см. _onGlobalKey)
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    _tc.addListener(_onChanged);
    _show(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    _tc.removeListener(_onChanged);
    _tc.dispose();
    _tf.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (_snapping) return;
    _snapSelectionOffDividers();
  }

  String _json() => jsonEncode(_tc.document.toDelta().toJson());

  String _defaultJson(String key) => key.startsWith('w')
      ? defaultTemplateJson(weekday: int.parse(key.substring(1)), accent: _accent)
      : defaultTemplateJson(block: key.substring(2), accent: _accent);

  String _label(String key) {
    final name = key.startsWith('w')
        ? _weekdayNames[int.parse(key.substring(1)) - 1]
        : _blockInfo[key.substring(2)]!.$1;
    return _custom.containsKey(key) ? '$name • изменён' : name;
  }

  void _show(String key) {
    final json = _custom[key] ?? _defaultJson(key);
    Document doc;
    try {
      doc = dividerSafeDocument(jsonDecode(json));
    } catch (_) {
      doc = Document();
    }
    _tc.document = doc;
    _tc.updateSelection(
        const TextSelection.collapsed(offset: 0), ChangeSource.local);
    _loadedJson = _json();
  }

  /// Правки в редакторе → в изменённые шаблоны (только если что-то поменяли)
  void _commit() {
    final now = _json();
    if (now != _loadedJson) {
      _custom[_key] = now;
      _loadedJson = now;
    }
  }

  bool _hasUnsaved() {
    _commit();
    return !mapEquals(_custom, _saved);
  }

  void _select(String? key) {
    if (key == null || key == _key) return;
    _commit();
    setState(() {
      _key = key;
      _status = '';
    });
    _show(key);
  }

  TemplateSettings _toSettings() => TemplateSettings(
        weekdays: {
          for (final e in _custom.entries)
            if (e.key.startsWith('w')) int.parse(e.key.substring(1)): e.value,
        },
        blocks: {
          for (final e in _custom.entries)
            if (e.key.startsWith('b:')) e.key.substring(2): e.value,
        },
      );

  Future<void> _save() async {
    if (_saving) return;
    _commit();
    final settings = _toSettings();
    final err = validateTemplateSettings(settings);
    if (err != null) {
      setState(() => _status = 'Ошибка: $err');
      return;
    }
    setState(() {
      _saving = true;
      _status = 'Сохранение...';
    });
    try {
      await widget.store.save(settings);
      _saved = Map.of(_custom);
      widget.onSaved(settings);
      if (mounted) {
        setState(() => _status =
            widget.store.lastSaveQueued ? kStatusQueued : kStatusSaved);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = 'Ошибка сохранения: ${describeError(e)}');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirm(String title, String body, String ok) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: Text(title),
        content: Text(body, style: const TextStyle(color: kTextPrimary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: kAccent, foregroundColor: kBackground),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ok),
          ),
        ],
      ),
    );
    return res == true;
  }

  Future<void> _resetCurrent() async {
    if (!await _confirm(
        'Сбросить шаблон?',
        '«${_label(_key).replaceAll(' • изменён', '')}» вернётся к стандартному. '
            'Изменение вступит в силу после «Сохранить».',
        'Сбросить')) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _custom.remove(_key);
      _status = '';
    });
    _show(_key);
  }

  Future<void> _resetAll() async {
    if (!await _confirm(
        'Сбросить все шаблоны?',
        'Все дни недели и особые блоки вернутся к стандартным. '
            'Изменение вступит в силу после «Сохранить».',
        'Сбросить всё')) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _custom.clear();
      _status = '';
    });
    _show(_key);
  }

  Future<void> _close() async {
    if (_saving) return;
    if (_hasUnsaved() &&
        !await _confirm('Закрыть без сохранения?',
            'Изменения в шаблонах не сохранены и будут потеряны.', 'Закрыть')) {
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Widget _selector() {
    final keys = [
      for (var d = 1; d <= 7; d++) 'w$d',
      for (final b in kTemplateBlocks) 'b:$b',
    ];
    return DropdownButton<String>(
      value: _key,
      isExpanded: true,
      dropdownColor: kCard,
      underline: const SizedBox.shrink(),
      style: const TextStyle(color: kTextPrimary, fontSize: 14),
      items: [
        for (final k in keys)
          DropdownMenuItem(
            value: k,
            child: Text(_label(k), overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _select,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isBlock = _key.startsWith('b:');
    final statusColor = _status.startsWith('Ошибка')
        ? const Color(0xFFFF5C5C)
        : (_status == 'Сохранено ✓' ? kAccent : kTextSecondary);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Dialog(
        backgroundColor: kSurface,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: kDivider),
        ),
        child: SizedBox(
          width: min(760, size.width - 32),
          height: size.height * 0.85,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.view_agenda_outlined, color: kAccent),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Шаблоны дня',
                        style: TextStyle(
                          color: kAccentLight,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(_status,
                        style: TextStyle(color: statusColor, fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Шаблон подставляется только в новый пустой день. '
                  'Уже созданные заметки не меняются. Пустой шаблон — '
                  'день начнётся с чистого листа.',
                  style: TextStyle(color: kTextSecondary, fontSize: 12),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kDivider),
                  ),
                  child: _selector(),
                ),
                if (isBlock) ...[
                  const SizedBox(height: 6),
                  Text(
                    _blockInfo[_key.substring(2)]!.$2,
                    style:
                        const TextStyle(color: kTextSecondary, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kDivider),
                  ),
                  child: _toolbar(),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: kCard,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: kDivider),
                    ),
                    child: Builder(
                      builder: (editorContext) => _withFormatMenu(
                          QuillEditor(
                            controller: _tc,
                            focusNode: _tf,
                            scrollController: _scroll,
                            config: _editorConfig(
                                'Пустой шаблон — день начнётся с чистого листа',
                                editorContext),
                          ),
                          _scroll),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton(
                          style: TextButton.styleFrom(
                              foregroundColor: kTextSecondary),
                          onPressed: _saving ? null : _resetCurrent,
                          child: const Text('Сбросить к стандартному'),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                              foregroundColor: kTextSecondary),
                          onPressed: _saving ? null : _resetAll,
                          child: const Text('Сбросить всё'),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: _saving ? null : _close,
                          child: const Text('Отмена'),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: kAccent,
                              foregroundColor: kBackground),
                          onPressed: _saving ? null : _save,
                          child: const Text('Сохранить'),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
