import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:table_calendar/table_calendar.dart';

import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

// ============================================================
//  Палитра
// ============================================================
const Color kBackground = Color(0xFF161616);
const Color kSurface = Color(0xFF1F1F1F);
const Color kCard = Color(0xFF292929);
const Color kAccent = Color(0xFFE8C84A);
const Color kAccentLight = Color(0xFFF5DC6E);
const Color kTextPrimary = Color(0xFFF0F0F0);
const Color kTextSecondary = Color(0xFF888888);
const Color kDivider = Color(0xFF333333);

// Цвета текста (кнопки в панели форматирования)
const String kRed = '#FF5C5C';
const String kYellow = '#FFD54A';
const String kGreen = '#4CD97B';

// Случайный цвет для списка «Не забыть»: жёлтый, фиолетовый, синий, оранжевый, розовый
const List<String> kNotForgetColors = [
  '#FFD54A',
  '#B388FF',
  '#5AB0FF',
  '#FF9F43',
  '#FF7EB6',
];

// ============================================================
//  Русские названия
// ============================================================
const List<String> kMonthsNom = [
  'Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь',
  'Июль', 'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь'
];
const List<String> kMonthsShort = [
  'Янв', 'Фев', 'Мар', 'Апр', 'Май', 'Июн',
  'Июл', 'Авг', 'Сен', 'Окт', 'Ноя', 'Дек'
];
const List<String> kWeekdaysShort = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

// ============================================================
//  Праздники РФ (нерабочие будние дни, с учётом переносов)
//  Формат 'ММ-ДД'. Для лет, которых нет в таблице, применяется
//  простое правило (см. _holidaysOf).
// ============================================================
const Map<int, Set<String>> kOfficialDaysOff = {
  // Постановление Правительства РФ от 24.09.2025 № 1466
  2026: {
    '01-01', '01-02', '01-05', '01-06', '01-07', '01-08', '01-09',
    '02-23',
    '03-09',
    '05-01', '05-11',
    '06-12',
    '11-04',
    '12-31',
  },
  // Постановление Правительства РФ от 17.09.2026 № 1187
  2027: {
    '01-01', '01-04', '01-05', '01-06', '01-07', '01-08',
    '02-22', '02-23',
    '03-08',
    '05-03', '05-10',
    '06-14',
    '11-04', '11-05',
    '12-31',
  },
};

final Map<int, Set<String>> _holidayCache = {};

String _md(DateTime d) =>
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Set<String> _holidaysOf(int year) {
  final table = kOfficialDaysOff[year];
  if (table != null) return table;
  return _holidayCache.putIfAbsent(year, () {
    final fixed = <DateTime>[
      for (var d = 1; d <= 8; d++) DateTime(year, 1, d),
      DateTime(year, 2, 23),
      DateTime(year, 3, 8),
      DateTime(year, 5, 1),
      DateTime(year, 5, 9),
      DateTime(year, 6, 12),
      DateTime(year, 11, 4),
    ];
    final fixedKeys = fixed.map(_md).toSet();
    final result = <String>{};
    for (final d in fixed) {
      var x = d;
      if (x.weekday >= 6) {
        // праздник выпал на выходной — переносится на ближайший рабочий день
        do {
          x = DateTime(x.year, x.month, x.day + 1);
        } while (x.weekday >= 6 || fixedKeys.contains(_md(x)));
      }
      result.add(_md(x));
    }
    return result;
  });
}

bool _isHoliday(DateTime d) => _holidaysOf(d.year).contains(_md(d));
bool _isWorkday(DateTime d) => d.weekday <= 5 && !_isHoliday(d);

/// Первый рабочий день месяца
bool _isFirstWorkdayOfMonth(DateTime d) {
  if (!_isWorkday(d)) return false;
  for (var i = 1; i < d.day; i++) {
    if (_isWorkday(DateTime(d.year, d.month, i))) return false;
  }
  return true;
}

/// Рабочий день, после которого начинается период с государственным праздником
bool _isDayBeforeHoliday(DateTime d) {
  if (!_isWorkday(d)) return false;
  var n = DateTime(d.year, d.month, d.day + 1);
  var guard = 0;
  while (!_isWorkday(n) && guard < 20) {
    if (_isHoliday(n)) return true;
    n = DateTime(n.year, n.month, n.day + 1);
    guard++;
  }
  return false;
}

/// Каждый второй четверг, начиная с 05.11.2026 — «Вадим викли»
bool _isVadimWeek(DateTime d) {
  if (d.weekday != DateTime.thursday) return false;
  final diff = DateTime.utc(d.year, d.month, d.day)
      .difference(DateTime.utc(2026, 11, 5))
      .inDays;
  return diff >= 0 && diff % 14 == 0;
}

// ============================================================
//  Шаблон заметки на день
// ============================================================
const String kNotForgetTitle = 'Не забыть:';
const String kMonthlyReport = 'Отчёт по команде СДК';
const String kHolidayNote = 'завтра выходной, не забудь всем рассказать';

/// Разделитель между блоками шаблона: тонкая плашка на всю ширину редактора
class DividerEmbedBuilder extends EmbedBuilder {
  const DividerEmbedBuilder();

  @override
  String get key => 'divider';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      child: Container(
        height: 2,
        margin: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF4A4A4A),
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}

class _Sect {
  final String title;
  final List<String> items; // '' — пустой пункт
  _Sect(this.title, this.items);
}

List<_Sect> _sectionsFor(DateTime day) {
  const retro = 'вернёмся к action items с ретры последней ретры';
  const mts = 'Новые автоответчики от МТС?';

  switch (day.weekday) {
    case DateTime.monday:
      return [
        _Sect('Задачи на день:', ['']),
        _Sect('АИ дейли:', [mts, retro, '']),
        _Sect('СДК дейли:', ['']),
        _Sect('Девопс дейли:', ['']),
        _Sect('Фронт викли:', ['Вова ревью', retro]),
        _Sect(kNotForgetTitle, ['']),
      ];
    case DateTime.tuesday:
      return [
        _Sect('Задачи на день:', ['подготовиться к завтрашнему сайт викли', '']),
        _Sect('АИ дейли:', [mts, '']),
        _Sect('СДК дейли:', ['']),
        _Sect('Девопс дейли:', ['']),
        _Sect('Ксюша викли:', ['']),
        _Sect(kNotForgetTitle, ['']),
      ];
    case DateTime.wednesday:
      return [
        _Sect('Задачи на день:', ['']),
        _Sect('АИ дейли:', [mts, '']),
        _Sect('СДК дейли:', ['']),
        _Sect('Девопс дейли:', ['']),
        _Sect('Фронт дейли:', ['']),
        _Sect('Юля викли:', ['']),
        _Sect('Сайт викли:', ['']),
        _Sect(kNotForgetTitle, ['']),
      ];
    case DateTime.thursday:
      return [
        _Sect('Задачи на день:', ['']),
        _Sect('АИ дейли:', [mts, '']),
        _Sect('СДК дейли:', ['']),
        _Sect('Девопс дейли:', ['']),
        _Sect('Фронт дейли:', ['']),
        _Sect('Лиза викли:', ['']),
        _Sect(kNotForgetTitle, ['вечером в 16 кофе', '']),
      ];
    case DateTime.friday:
      return [
        _Sect('Задачи на день:', ['ОТЧЁТ ПО САЙТУ', '']),
        _Sect('АИ дейли:', [mts, '']),
        _Sect('СДК дейли:', ['']),
        _Sect('Девопс дейли:', ['']),
        _Sect('Фронт дейли:', ['']),
        _Sect('Сайт викли:', ['']),
        _Sect(kNotForgetTitle, ['']),
      ];
    default:
      return <_Sect>[]; // суббота и воскресенье — без шаблона
  }
}

String _pickAccent() =>
    kNotForgetColors[Random().nextInt(kNotForgetColors.length)];

Document _buildTemplate(DateTime day, String accent) {
  final sections = _sectionsFor(day);
  if (sections.isEmpty) return Document();

  // Каждый второй четверг — дополнительный блок «Вадим викли»
  if (_isVadimWeek(day)) {
    sections.insert(sections.length - 1, _Sect('Вадим викли:', ['']));
  }

  // Первый рабочий день месяца — отчёт по СДК в задачах на день
  if (_isFirstWorkdayOfMonth(day)) {
    final tasks = sections.first.items;
    final i = tasks.indexOf('');
    tasks.insert(i < 0 ? tasks.length : i, kMonthlyReport);
  }

  // День перед государственным праздником — напоминание в «Не забыть»
  if (_isDayBeforeHoliday(day)) {
    sections.last.items.insert(0, kHolidayNote);
  }

  final ops = <Map<String, dynamic>>[];
  for (var s = 0; s < sections.length; s++) {
    final sec = sections[s];
    final isNotForget = sec.title == kNotForgetTitle;

    // 1. Заголовок блока — обычным (не жирным) шрифтом
    ops.add({
      'insert': sec.title,
      if (isNotForget) 'attributes': {'color': accent},
    });
    ops.add({'insert': '\n'});

    for (final item in sec.items) {
      if (item.isNotEmpty) {
        ops.add({
          'insert': item,
          if (isNotForget) 'attributes': {'color': accent},
        });
      }
      ops.add({
        'insert': '\n',
        'attributes': {'list': 'ordered'},
      });
    }

    if (s != sections.length - 1) {
      ops.add({
        'insert': {'divider': 'hr'},
      });
      ops.add({'insert': '\n'});
    }
  }
  return Document.fromJson(ops);
}

// ============================================================
//  Приложение
// ============================================================
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Calendar Notes',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ru'), Locale('en')],
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBackground,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          secondary: kAccentLight,
          surface: kSurface,
        ),
        useMaterial3: true,
        fontFamily: 'sans-serif',
      ),
      home: const CalendarPage(),
    );
  }
}

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage>
    with WidgetsBindingObserver {
  DateTime _selectedDay = DateTime.now();
  DateTime _focusedDay = DateTime.now();

  late final QuillController _controller;
  late final FocusNode _editorFocus;
  final ScrollController _editorScroll = ScrollController();
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  bool _calendarVisible = true;
  bool _showMonths = false;
  int _pickerYear = DateTime.now().year;

  // --- состояние сохранения ---
  final ValueNotifier<String> _status = ValueNotifier<String>('');
  Timer? _autoTimer;
  String _lastSavedJson = '';
  String _lastSeenJson = '';
  int _lastLen = 0;
  String? _loadedKey; // для какого дня заметка уже загружена
  bool _saving = false;
  String _accent = kNotForgetColors.first;
  bool _recoloring = false;

  // --- разделители: курсор не должен на них попадать ---
  int? _prevCaret;
  bool _snapping = false;

  String _dayKey(DateTime day) =>
      '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  String _formatDate(DateTime day) {
    const months = [
      'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
      'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'
    ];
    return '${day.day} ${months[day.month - 1]} ${day.year}';
  }

  String _currentJson() => jsonEncode(_controller.document.toDelta().toJson());

  bool get _isDirty => _currentJson() != _lastSavedJson;

  void _setStatus(String s) {
    if (mounted) _status.value = s;
  }

  // ---------- жизненный цикл ----------

  @override
  void initState() {
    super.initState();
    _controller = QuillController.basic();
    _editorFocus = FocusNode();
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onControllerChanged);
    _loadNote(_selectedDay);
    // автосохранение каждые 5 секунд, если есть несохранённые правки
    _autoTimer = Timer.periodic(const Duration(seconds: 5), (_) => _autoSave());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    WidgetsBinding.instance.removeObserver(this);
    _autoTimer?.cancel();
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _editorFocus.dispose();
    _editorScroll.dispose();
    _status.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // вкладку свернули / переключились — сохраняем сразу
    if (state != AppLifecycleState.resumed) _autoSave();
  }

  // ---------- Firestore ----------

  bool _loadingNow = false;

  Future<void> _loadNote(DateTime day) async {
    _loadingNow = true;
    try {
      await _loadNoteInner(day);
    } finally {
      _loadingNow = false;
    }
  }

  Future<void> _loadNoteInner(DateTime day) async {
    final key = _dayKey(day);
    _loadedKey = null; // пока не загрузили — сохранять нельзя (чтобы не затереть заметку)

    DocumentSnapshot<Map<String, dynamic>> doc;
    try {
      doc = await _db.collection('notes').doc(key).get();
    } on FirebaseException catch (e) {
      _setStatus('Не удалось загрузить (${e.code})');
      return;
    } catch (_) {
      _setStatus('Не удалось загрузить');
      return;
    }
    // пока грузилось, мог быть выбран другой день
    if (!mounted || key != _dayKey(_selectedDay)) return;

    var accent = _pickAccent();
    Document document;
    final data = doc.data();
    final delta = data?['delta'];
    final text = (data?['text'] ?? '').toString();

    if (delta is String && delta.isNotEmpty) {
      try {
        document = Document.fromJson(jsonDecode(delta));
      } catch (_) {
        document = Document()..insert(0, text);
      }
      final savedAccent = data?['accent'];
      if (savedAccent is String && savedAccent.isNotEmpty) accent = savedAccent;
    } else if (text.trim().isNotEmpty) {
      // старые заметки (только обычный текст)
      document = Document()..insert(0, text);
    } else {
      // пустой день — подставляем шаблон
      document = _buildTemplate(day, accent);
    }

    // запоминаем «эталон» до подмены документа, чтобы загрузка не считалась правкой
    final json = jsonEncode(document.toDelta().toJson());
    _lastSavedJson = json;
    _lastSeenJson = json;
    _lastLen = document.length;
    _accent = accent;

    _controller.document = document;
    _controller.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );
    _loadedKey = key;
    _setStatus('');
  }

  void _autoSave() {
    final key = _dayKey(_selectedDay);
    if (_loadedKey != key) {
      // заметка так и не загрузилась (например, нет доступа) — пробуем снова
      if (!_loadingNow) _loadNote(_selectedDay);
      return;
    }
    if (_isDirty) _saveNote();
  }

  Future<void> _saveNote() async {
    final key = _dayKey(_selectedDay);
    if (_loadedKey != key || _saving) return;
    _saving = true;
    final json = _currentJson();
    final plain = _controller.document.toPlainText().replaceAll('\uFFFC', '');
    _setStatus('Сохранение...');
    try {
      await _db.collection('notes').doc(key).set({
        'delta': json,
        'text': plain,
        'accent': _accent,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (key == _dayKey(_selectedDay)) _lastSavedJson = json;
      _setStatus('Сохранено ✓');
    } on FirebaseException catch (e) {
      _setStatus('Ошибка сохранения (${e.code})');
    } catch (_) {
      _setStatus('Ошибка сохранения');
    } finally {
      _saving = false;
    }
  }

  Future<void> _onDaySelected(DateTime selectedDay, DateTime focusedDay) async {
    // не теряем несохранённые правки предыдущего дня
    while (_saving) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (_loadedKey == _dayKey(_selectedDay) && _isDirty) {
      await _saveNote();
    }
    if (!mounted) return;
    setState(() {
      _selectedDay = selectedDay;
      _focusedDay = focusedDay;
    });
    _status.value = '';
    _loadNote(selectedDay);
  }

  // ---------- реакция на изменения в редакторе ----------

  void _onControllerChanged() {
    if (_recoloring || _snapping) return;
    _snapSelectionOffDividers();
    final json = _currentJson();
    if (json == _lastSeenJson) return; // просто движение курсора
    _lastSeenJson = json;

    final len = _controller.document.length;
    final grew = len > _lastLen;
    _lastLen = len;
    if (grew) _keepNotForgetColor();
  }

  /// Новый текст в нумерованном списке под «Не забыть:» окрашивается цветом блока
  void _keepNotForgetColor() {
    final sel = _controller.selection;
    if (!sel.isCollapsed || sel.baseOffset < 1) return;

    final plain = _controller.document.toPlainText();
    final titleAt = plain.lastIndexOf(kNotForgetTitle);
    if (titleAt < 0) return;

    final o = sel.baseOffset;
    if (o <= titleAt + kNotForgetTitle.length || o - 1 >= plain.length) return;
    if (plain[o - 1] == '\n') return;

    final st = _controller.document.collectStyle(o - 1, 1);
    if (st.attributes[Attribute.list.key]?.value != 'ordered') return;
    if (st.attributes.containsKey(Attribute.color.key)) return;

    _recoloring = true;
    try {
      _controller.formatText(o - 1, 1, ColorAttribute(_accent));
    } finally {
      _recoloring = false;
    }
  }

  // ---------- горячие клавиши ----------

  /// Глобальный перехват: срабатывает раньше, чем сам редактор,
  /// но только пока курсор стоит в поле заметки.
  bool _onGlobalKey(KeyEvent event) {
    if (!_editorFocus.hasFocus) return false;
    return _onEditorKey(_editorFocus, event) == KeyEventResult.handled;
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
    }

    if (ctrl && !shift && !alt) {
      // Ctrl+V поверх выделенного текста: если в буфере ссылка — текст
      // остаётся, но становится гиперссылкой
      if (physical == PhysicalKeyboardKey.keyV &&
          event is KeyDownEvent &&
          !_controller.selection.isCollapsed) {
        _pasteOverSelection();
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
        final sel = _controller.selection;
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
    final attrs = _controller.getSelectionStyle().attributes;
    if (!attrs.containsKey(Attribute.list.key)) return;
    _controller.indentSelection(!shift);
  }

  /// Backspace в начале пункта списка: сначала уменьшает вложенность,
  /// затем снимает список; под разделителем строку с ним не склеивает.
  bool _handleBackspace() {
    final sel = _controller.selection;
    if (!sel.isCollapsed) return false;
    final pos = sel.baseOffset;
    final plain = _controller.document.toPlainText();
    final atLineStart = pos == 0 || (pos <= plain.length && plain[pos - 1] == '\n');
    if (!atLineStart) return false;

    final attrs = _controller.getSelectionStyle().attributes;
    final isList = attrs.containsKey(Attribute.list.key);
    final indent = attrs[Attribute.indent.key]?.value;
    if (isList && indent is int && indent > 0) {
      _controller.indentSelection(false);
      return true;
    }

    // строка сразу под разделителем
    final d = pos - 2;
    if (d >= 0 && _dividerOffsets().contains(d)) {
      if (isList) {
        _controller.formatSelection(Attribute.clone(Attribute.list, null));
      } else {
        _snapping = true;
        try {
          _controller.updateSelection(
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

  /// Позиции всех разделителей в документе
  List<int> _dividerOffsets() {
    final res = <int>[];
    var off = 0;
    for (final op in _controller.document.toDelta().toList()) {
      final data = op.data;
      if (data is Map && data.containsKey('divider')) res.add(off);
      off += op.length ?? 0;
    }
    return res;
  }

  /// Разделитель нельзя выделить и нельзя поставить на него курсор:
  /// если выделение попало на него, оно сдвигается на соседнюю строку.
  void _snapSelectionOffDividers() {
    final sel = _controller.selection;
    if (!sel.isValid) return;
    final divs = _dividerOffsets();
    final prev = _prevCaret;
    if (divs.isEmpty) {
      _prevCaret = sel.extentOffset;
      return;
    }
    final len = _controller.document.length;
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
        _controller.updateSelection(next, ChangeSource.local);
      } finally {
        _snapping = false;
      }
      _prevCaret = next.extentOffset;
    } else {
      _prevCaret = sel.extentOffset;
    }
  }

  // ---------- вставка из буфера обмена поверх выделения ----------

  Future<void> _pasteOverSelection() async {
    final sel = _controller.selection;
    final start = sel.start;
    final len = sel.end - sel.start;
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      return;
    }
    if (text == null || text.isEmpty) return;

    final url = _asUrl(text);
    if (url != null) {
      // текст остаётся, становится ссылкой (синей и подчёркнутой)
      _controller.formatText(start, len, Attribute.clone(Attribute.color, null));
      _controller.formatText(start, len, LinkAttribute(url));
      _controller.updateSelection(
        TextSelection.collapsed(offset: start + len),
        ChangeSource.local,
      );
    } else {
      _controller.replaceText(
        start,
        len,
        text,
        TextSelection.collapsed(offset: start + text.length),
      );
    }
    _editorFocus.requestFocus();
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
    final current = _controller.getSelectionStyle().attributes[attr.key];
    return current != null && current.value == attr.value;
  }

  void _toggle(Attribute attr) {
    _controller.formatSelection(
      _isActive(attr) ? Attribute.clone(attr, null) : attr,
    );
    _editorFocus.requestFocus();
  }

  bool _isColor(String hex) {
    final current =
        _controller.getSelectionStyle().attributes[Attribute.color.key];
    return current != null && current.value == hex;
  }

  void _toggleColor(String hex) {
    if (_isColor(hex)) {
      _controller.formatSelection(Attribute.clone(Attribute.color, null));
    } else {
      _controller.formatSelection(ColorAttribute(hex));
    }
    _editorFocus.requestFocus();
  }

  Future<void> _insertLink() async {
    final sel = _controller.selection;
    final hasSelection = !sel.isCollapsed;
    final urlCtrl = TextEditingController();
    final textCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('Вставить ссылку'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!hasSelection)
              TextField(
                controller: textCtrl,
                decoration: const InputDecoration(labelText: 'Текст'),
              ),
            TextField(
              controller: urlCtrl,
              autofocus: true,
              decoration:
                  const InputDecoration(labelText: 'Адрес (https://...)'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Вставить')),
        ],
      ),
    );
    if (ok != true) return;

    var url = urlCtrl.text.trim();
    if (url.isEmpty) return;
    if (!url.startsWith(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:'))) {
      url = 'https://$url';
    }

    if (hasSelection) {
      _controller.formatSelection(Attribute.clone(Attribute.color, null));
      _controller.formatSelection(LinkAttribute(url));
    } else {
      final text = textCtrl.text.trim().isEmpty ? url : textCtrl.text.trim();
      final index = sel.baseOffset < 0 ? 0 : sel.baseOffset;
      _controller.replaceText(
        index,
        0,
        text,
        TextSelection.collapsed(offset: index + text.length),
      );
      _controller.formatText(index, text.length, LinkAttribute(url));
    }
    _editorFocus.requestFocus();
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
      listenable: _controller,
      builder: (context, _) {
        final hasLink = _controller
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
              tooltip: 'Ссылка (или выделите текст и вставьте ссылку Ctrl+V)',
              active: hasLink,
              onPressed: _insertLink,
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

  // ---------- календарь ----------

  Widget _calendarPanel() {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kDivider),
      ),
      padding: const EdgeInsets.all(8),
      child: _showMonths ? _monthPicker() : _monthView(),
    );
  }

  Widget _monthView() {
    return TableCalendar(
      firstDay: DateTime(2020),
      lastDay: DateTime(2030, 12, 31),
      focusedDay: _focusedDay,
      startingDayOfWeek: StartingDayOfWeek.monday,
      rowHeight: 40,
      daysOfWeekHeight: 24,
      selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
      onDaySelected: _onDaySelected,
      onPageChanged: (d) => _focusedDay = d,
      // клик по названию месяца — показать все месяцы года
      onHeaderTapped: (_) => setState(() {
        _pickerYear = _focusedDay.year;
        _showMonths = true;
      }),
      calendarBuilders: CalendarBuilders(
        dowBuilder: (context, day) => Center(
          child: Text(
            kWeekdaysShort[day.weekday - 1],
            style: const TextStyle(
              color: kTextSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
      calendarStyle: const CalendarStyle(
        cellMargin: EdgeInsets.all(4),
        defaultTextStyle: TextStyle(color: kTextPrimary),
        weekendTextStyle: TextStyle(color: kTextSecondary),
        outsideTextStyle: TextStyle(color: Color(0xFF555555)),
        todayTextStyle:
            TextStyle(color: kAccentLight, fontWeight: FontWeight.bold),
        selectedTextStyle:
            TextStyle(color: kBackground, fontWeight: FontWeight.bold),
        todayDecoration:
            BoxDecoration(color: Colors.transparent, shape: BoxShape.circle),
        selectedDecoration:
            BoxDecoration(color: kAccent, shape: BoxShape.circle),
      ),
      headerStyle: HeaderStyle(
        formatButtonVisible: false,
        titleCentered: true,
        titleTextFormatter: (date, locale) =>
            '${kMonthsNom[date.month - 1]} ${date.year}',
        titleTextStyle: const TextStyle(
            color: kTextPrimary, fontSize: 16, fontWeight: FontWeight.w600),
        leftChevronIcon: const Icon(Icons.chevron_left, color: kAccent),
        rightChevronIcon: const Icon(Icons.chevron_right, color: kAccent),
      ),
    );
  }

  Widget _monthPicker() {
    final now = DateTime.now();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: _pickerYear > 2020
                  ? () => setState(() => _pickerYear--)
                  : null,
              icon: const Icon(Icons.chevron_left, color: kAccent),
            ),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _showMonths = false),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Center(
                    child: Text(
                      '$_pickerYear',
                      style: const TextStyle(
                        color: kTextPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              onPressed: _pickerYear < 2030
                  ? () => setState(() => _pickerYear++)
                  : null,
              icon: const Icon(Icons.chevron_right, color: kAccent),
            ),
          ],
        ),
        const SizedBox(height: 4),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.7,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
          children: [
            for (var m = 1; m <= 12; m++) _monthCell(m, now),
          ],
        ),
      ],
    );
  }

  Widget _monthCell(int m, DateTime now) {
    final selected = _focusedDay.year == _pickerYear && _focusedDay.month == m;
    final isNow = now.year == _pickerYear && now.month == m;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() {
        _focusedDay = DateTime(_pickerYear, m, 1);
        _showMonths = false;
      }),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? kAccent : kCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: (isNow && !selected) ? kAccent : kDivider,
          ),
        ),
        child: Text(
          kMonthsShort[m - 1],
          style: TextStyle(
            color: selected ? kBackground : kTextPrimary,
            fontWeight: selected || isNow ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  // ---------- заметка ----------

  Widget _notePanel() {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kDivider),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // кнопка сворачивания календаря — рядом с датой
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  _calendarVisible
                      ? Icons.calendar_month
                      : Icons.calendar_today,
                  color: kAccent,
                ),
                tooltip:
                    _calendarVisible ? 'Скрыть календарь' : 'Показать календарь',
                onPressed: () =>
                    setState(() => _calendarVisible = !_calendarVisible),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  _formatDate(_selectedDay),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kAccentLight,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kDivider),
            ),
            child: _toolbar(),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kDivider),
              ),
              child: QuillEditor(
                controller: _controller,
                focusNode: _editorFocus,
                scrollController: _editorScroll,
                config: QuillEditorConfig(
                  placeholder: 'Что важного в этот день...',
                  padding: EdgeInsets.zero,
                  expands: true,
                  embedBuilders: const [DividerEmbedBuilder()],
                  customStyles: DefaultStyles(
                    link: const TextStyle(
                      color: Color(0xFF5AB0FF),
                      decoration: TextDecoration.underline,
                      decorationColor: Color(0xFF5AB0FF),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: ValueListenableBuilder<String>(
              valueListenable: _status,
              builder: (context, status, _) {
                Color color = kTextSecondary;
                if (status == 'Сохранено ✓') color = kAccent;
                if (status.startsWith('Ошибка') ||
                    status.startsWith('Не удалось')) {
                  color = const Color(0xFFFF5C5C);
                }
                return Text(status,
                    style: TextStyle(color: color, fontSize: 13));
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------- общий каркас ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 800;

            if (wide) {
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1400),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Календарь слева
                        AnimatedSize(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOut,
                          child: SizedBox(
                            width: _calendarVisible ? 320 : 0,
                            child: _calendarVisible
                                ? Padding(
                                    padding: const EdgeInsets.only(right: 20),
                                    child: Align(
                                      alignment: Alignment.topCenter,
                                      child: SingleChildScrollView(
                                        child: _calendarPanel(),
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                        ),
                        // Заметка посередине
                        Expanded(child: _notePanel()),
                      ],
                    ),
                  ),
                ),
              );
            }

            // Узкий экран (телефон): календарь сверху, заметка ниже
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_calendarVisible) ...[
                  _calendarPanel(),
                  const SizedBox(height: 16),
                ],
                SizedBox(height: 560, child: _notePanel()),
              ],
            );
          },
        ),
      ),
    );
  }
}
