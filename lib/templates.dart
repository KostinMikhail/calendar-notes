// Шаблоны дня: стандартные (из кода) и изменённые пользователем (Firestore).
//
// Как собирается новый пустой день:
//   1. Шаблон дня недели — изменённый пользователем или стандартный.
//      Делится на блоки по строкам-разделителям.
//   2. По правилам в коде (не настраиваются) добавляются особые блоки,
//      текст которых пользователь может изменить:
//      • «Вадим викли» — отдельным блоком перед последним блоком;
//      • отчёт в первый рабочий день месяца — в первый блок перед первой
//        пустой строкой после заголовка (или в конец блока);
//      • напоминание накануне праздника — в последний блок сразу после его
//        первой строки (заголовка).
//   3. Блоки снова соединяются разделителями.
// Без пользовательских настроек результат совпадает с прежним байт в байт.
//
// Firestore: users/{uid}/settings/templates
//   { version: 1, weekdays: {"1".."7": delta}, blocks: {id: delta},
//     updatedAt: serverTimestamp }
// Нет ключа — стандартный шаблон; пустой документ — пустой день.

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_quill/flutter_quill.dart' show Document;

import 'offline.dart';

const String kNotForgetTitle = 'Не забыть:';

/// Заголовок блока задач (у его пунктов — кнопки ✗/✓, см. tasks.dart)
const String kTasksTitle = 'Задачи на день:';
const String kMonthlyReport = 'Отчёт по команде СДК';
const String kHolidayNote = 'завтра выходной, не забудь всем рассказать';
const String kVadimWeekTitle = 'Вадим викли:';

/// Особые блоки, которые код добавляет в определённые дни
const String kBlockVadimWeek = 'vadimWeek';
const String kBlockMonthlyReport = 'monthlyReport';
const String kBlockHolidayNote = 'holidayNote';
const List<String> kTemplateBlocks = [
  kBlockVadimWeek,
  kBlockMonthlyReport,
  kBlockHolidayNote,
];

const int kTemplatesVersion = 1;
const int kMaxTemplateDeltaLength = 100000;

/// Общий объём всех шаблонов (документ Firestore ограничен 1 МиБ)
const int kMaxTemplatesTotalLength = 300000;

/// Пустой документ редактора
const String kEmptyTemplateDelta = '[{"insert":"\\n"}]';

// ============================================================
//  Стандартные шаблоны
// ============================================================

class TemplateSection {
  TemplateSection(this.title, this.items);
  final String title;
  final List<String> items; // '' — пустой пункт
}

/// Блоки дня недели по умолчанию (1 — понедельник … 7 — воскресенье)
List<TemplateSection> defaultWeekdaySections(int weekday) {
  const retro = 'вернёмся к action items с ретры последней ретры';
  const mts = 'Новые автоответчики от МТС?';

  switch (weekday) {
    case DateTime.monday:
      return [
        TemplateSection(kTasksTitle, ['']),
        TemplateSection('АИ дейли:', [mts, retro, '']),
        TemplateSection('СДК дейли:', ['']),
        TemplateSection('Девопс дейли:', ['']),
        TemplateSection('Фронт викли:', ['Вова ревью', retro]),
        TemplateSection(kNotForgetTitle, ['']),
      ];
    case DateTime.tuesday:
      return [
        TemplateSection(
            kTasksTitle, ['подготовиться к завтрашнему сайт викли', '']),
        TemplateSection('АИ дейли:', [mts, '']),
        TemplateSection('СДК дейли:', ['']),
        TemplateSection('Девопс дейли:', ['']),
        TemplateSection('Ксюша викли:', ['']),
        TemplateSection(kNotForgetTitle, ['']),
      ];
    case DateTime.wednesday:
      return [
        TemplateSection(kTasksTitle, ['']),
        TemplateSection('АИ дейли:', [mts, '']),
        TemplateSection('СДК дейли:', ['']),
        TemplateSection('Девопс дейли:', ['']),
        TemplateSection('Фронт дейли:', ['']),
        TemplateSection('Юля викли:', ['']),
        TemplateSection('Сайт викли:', ['']),
        TemplateSection(kNotForgetTitle, ['']),
      ];
    case DateTime.thursday:
      return [
        TemplateSection(kTasksTitle, ['']),
        TemplateSection('АИ дейли:', [mts, '']),
        TemplateSection('СДК дейли:', ['']),
        TemplateSection('Девопс дейли:', ['']),
        TemplateSection('Фронт дейли:', ['']),
        TemplateSection('Лиза викли:', ['']),
        TemplateSection(kNotForgetTitle, ['вечером в 16 кофе', '']),
      ];
    case DateTime.friday:
      return [
        TemplateSection(kTasksTitle, ['ОТЧЁТ ПО САЙТУ', '']),
        TemplateSection('АИ дейли:', [mts, '']),
        TemplateSection('СДК дейли:', ['']),
        TemplateSection('Девопс дейли:', ['']),
        TemplateSection('Фронт дейли:', ['']),
        TemplateSection('Сайт викли:', ['']),
        TemplateSection(kNotForgetTitle, ['']),
      ];
    default:
      return <TemplateSection>[]; // суббота и воскресенье — без шаблона
  }
}

/// Блоки → операции Delta (как раньше в _buildTemplate):
/// заголовок обычным шрифтом, пункты — нумерованный список, блок
/// «Не забыть» — цветом [accent], между блоками — разделитель.
List<Map<String, dynamic>> renderSections(
    List<TemplateSection> sections, String accent) {
  final ops = <Map<String, dynamic>>[];
  for (var s = 0; s < sections.length; s++) {
    final sec = sections[s];
    final isNotForget = sec.title == kNotForgetTitle;

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
  return ops;
}

/// Стандартный особый блок
List<Map<String, dynamic>> defaultBlockOps(String block, String accent) {
  switch (block) {
    case kBlockVadimWeek:
      return renderSections([TemplateSection(kVadimWeekTitle, [''])], accent);
    case kBlockMonthlyReport:
      return [
        {'insert': kMonthlyReport},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
      ];
    case kBlockHolidayNote:
      // попадает в блок «Не забыть» — поэтому цветом блока
      return [
        {
          'insert': kHolidayNote,
          'attributes': {'color': accent},
        },
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
      ];
    default:
      return const [];
  }
}

// ============================================================
//  Строки документа
// ============================================================

/// Одна строка документа: содержимое и атрибуты перевода строки
class TemplateLine {
  TemplateLine(this.inline, this.attrs);
  final List<Map<String, dynamic>> inline;
  final Map<String, dynamic>? attrs;

  bool get isEmpty => inline.isEmpty;

  bool get isDivider =>
      inline.length == 1 &&
      inline.first['insert'] is Map &&
      (inline.first['insert'] as Map).containsKey('divider');

  String get plainText => [
        for (final op in inline)
          if (op['insert'] is String) op['insert'] as String
      ].join();
}

/// Delta → строки
List<TemplateLine> opsToLines(List<dynamic> ops) {
  final lines = <TemplateLine>[];
  var cur = <Map<String, dynamic>>[];
  for (final raw in ops) {
    final op = raw as Map;
    final insert = op['insert'];
    final attrs = op['attributes'] is Map
        ? Map<String, dynamic>.from(op['attributes'] as Map)
        : null;
    if (insert is String) {
      final parts = insert.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].isNotEmpty) {
          cur.add({'insert': parts[i], 'attributes': ?attrs});
        }
        if (i < parts.length - 1) {
          lines.add(TemplateLine(cur, attrs));
          cur = [];
        }
      }
    } else {
      cur.add({'insert': insert, 'attributes': ?attrs});
    }
  }
  if (cur.isNotEmpty) lines.add(TemplateLine(cur, null));
  return lines;
}

/// Строки → Delta
List<Map<String, dynamic>> linesToOps(List<TemplateLine> lines) => [
      for (final l in lines) ...[
        ...l.inline,
        {
          'insert': '\n',
          if (l.attrs != null && l.attrs!.isNotEmpty) 'attributes': l.attrs,
        },
      ],
    ];

/// Пустой шаблон: ни одной строки или одна пустая строка. Оформление строки
/// не важно: после «выделить всё → удалить» редактор оставляет у пустой
/// строки, например, пункт списка — это всё равно пустой шаблон.
bool isEmptyTemplate(List<TemplateLine> lines) =>
    lines.isEmpty || (lines.length == 1 && lines.first.isEmpty);

/// Разбор строки Delta из настроек. null — данные испорчены (тогда
/// используется стандартный шаблон).
List<TemplateLine>? parseTemplateDelta(String? json) {
  if (json == null || json.length > kMaxTemplateDeltaLength) return null;
  try {
    final ops = jsonDecode(json);
    if (ops is! List || ops.isEmpty) return null;
    for (final op in ops) {
      if (op is! Map ||
          !op.containsKey('insert') ||
          op.keys.any((k) => k != 'insert' && k != 'attributes')) {
        return null;
      }
      final ins = op['insert'];
      if (ins is! String && ins is! Map) return null;
      if (op['attributes'] != null && op['attributes'] is! Map) return null;
    }
    final last = ops.last as Map;
    if (last['insert'] is! String || !(last['insert'] as String).endsWith('\n')) {
      return null;
    }
    Document.fromJson(ops); // редактор должен суметь открыть
    return opsToLines(ops);
  } catch (_) {
    return null;
  }
}

// ============================================================
//  Настройки
// ============================================================

class TemplateSettings {
  const TemplateSettings({this.weekdays = const {}, this.blocks = const {}});

  /// 1..7 → Delta шаблона дня недели (нет ключа — стандартный)
  final Map<int, String> weekdays;

  /// id особого блока → Delta (нет ключа — стандартный)
  final Map<String, String> blocks;

  static const TemplateSettings defaults = TemplateSettings();

  bool get isEmpty => weekdays.isEmpty && blocks.isEmpty;

  /// Из документа Firestore. Неизвестная версия или испорченные значения
  /// пропускаются — для них используются стандартные шаблоны.
  factory TemplateSettings.fromMap(Map<String, dynamic>? data) {
    if (data == null || data['version'] != kTemplatesVersion) {
      return const TemplateSettings();
    }
    final weekdays = <int, String>{};
    final w = data['weekdays'];
    if (w is Map) {
      for (var d = 1; d <= 7; d++) {
        final v = w['$d'];
        if (v is String && parseTemplateDelta(v) != null) weekdays[d] = v;
      }
    }
    final blocks = <String, String>{};
    final b = data['blocks'];
    if (b is Map) {
      for (final id in kTemplateBlocks) {
        final v = b[id];
        if (v is String && parseTemplateDelta(v) != null) blocks[id] = v;
      }
    }
    return TemplateSettings(weekdays: weekdays, blocks: blocks);
  }

  /// Для записи в Firestore (updatedAt добавляет хранилище)
  Map<String, dynamic> toMap() => {
        'version': kTemplatesVersion,
        'weekdays': {for (final e in weekdays.entries) '${e.key}': e.value},
        'blocks': Map<String, String>.of(blocks),
      };
}

/// Проверка перед сохранением: null — всё в порядке, иначе текст ошибки
String? validateTemplateSettings(TemplateSettings s) {
  var total = 0;
  final all = <String, String>{
    for (final e in s.weekdays.entries) 'день ${e.key}': e.value,
    for (final e in s.blocks.entries) e.key: e.value,
  };
  for (final e in all.entries) {
    if (e.value.length > kMaxTemplateDeltaLength) {
      return 'Шаблон слишком большой (${e.key})';
    }
    if (parseTemplateDelta(e.value) == null) {
      return 'Шаблон повреждён (${e.key})';
    }
    total += e.value.length;
  }
  if (total > kMaxTemplatesTotalLength) {
    return 'Шаблоны слишком большие в сумме';
  }
  return null;
}

// ============================================================
//  Сборка дня
// ============================================================

class TemplateComposition {
  const TemplateComposition(this.ops, this.accent);

  /// Операции Delta; пустой список — пустой день
  final List<Map<String, dynamic>> ops;

  /// Цвет блока «Не забыть» для новых пунктов
  final String accent;
}

/// Цвет строки «Не забыть:» в пользовательском шаблоне
String? _accentOf(List<TemplateLine> lines) {
  for (final l in lines) {
    if (l.plainText.trim() == kNotForgetTitle) {
      for (final op in l.inline) {
        final a = op['attributes'];
        if (a is Map && a['color'] is String) return a['color'] as String;
      }
    }
  }
  return null;
}

List<TemplateLine> _blockLines(
    String block, TemplateSettings settings, String accent) {
  final custom = parseTemplateDelta(settings.blocks[block]);
  final lines = custom ?? opsToLines(defaultBlockOps(block, accent));
  return isEmptyTemplate(lines) ? const [] : lines;
}

/// Шаблон нового пустого дня. Условия (какой блок в какой день) задаёт
/// код; [settings] меняет только тексты.
TemplateComposition composeTemplate({
  required int weekday,
  required bool vadimWeek,
  required bool firstWorkday,
  required bool dayBeforeHoliday,
  required TemplateSettings settings,
  required String accent,
}) {
  final custom = parseTemplateDelta(settings.weekdays[weekday]);
  final usedAccent = custom == null ? accent : (_accentOf(custom) ?? accent);
  final base = custom ??
      opsToLines(renderSections(defaultWeekdaySections(weekday), accent));
  if (isEmptyTemplate(base)) return TemplateComposition(const [], usedAccent);

  // блоки, разделённые строками-разделителями
  final sections = <List<TemplateLine>>[[]];
  for (final l in base) {
    if (l.isDivider) {
      sections.add([]);
    } else {
      sections.last.add(l);
    }
  }

  // Каждый второй четверг — отдельный блок перед последним
  if (vadimWeek) {
    final block = _blockLines(kBlockVadimWeek, settings, usedAccent);
    if (block.isNotEmpty) sections.insert(sections.length - 1, [...block]);
  }

  // Первый рабочий день месяца — в первый блок перед первой пустой строкой
  if (firstWorkday) {
    final block = _blockLines(kBlockMonthlyReport, settings, usedAccent);
    final first = sections.first;
    var at = -1;
    for (var i = 1; i < first.length; i++) {
      if (first[i].isEmpty) {
        at = i;
        break;
      }
    }
    first.insertAll(at < 0 ? first.length : at, block);
  }

  // Накануне праздника — в последний блок сразу после заголовка
  if (dayBeforeHoliday) {
    final block = _blockLines(kBlockHolidayNote, settings, usedAccent);
    final last = sections.last;
    last.insertAll(last.isEmpty ? 0 : 1, block);
  }

  final lines = <TemplateLine>[];
  for (var s = 0; s < sections.length; s++) {
    lines.addAll(sections[s]);
    if (s != sections.length - 1) {
      lines.add(TemplateLine([
        {
          'insert': {'divider': 'hr'},
        },
      ], null));
    }
  }
  return TemplateComposition(linesToOps(lines), usedAccent);
}

/// Стандартный шаблон для показа в редакторе настроек (строка Delta)
String defaultTemplateJson({int? weekday, String? block, required String accent}) {
  final ops = weekday != null
      ? renderSections(defaultWeekdaySections(weekday), accent)
      : defaultBlockOps(block!, accent);
  if (ops.isEmpty) return kEmptyTemplateDelta;
  return jsonEncode(Document.fromJson(ops).toDelta().toJson());
}

// ============================================================
//  Хранилище
// ============================================================

abstract class TemplateStore {
  /// Нет документа — стандартные шаблоны
  Future<TemplateSettings> load();
  Future<void> save(TemplateSettings settings);

  /// Последнее сохранение пока только на устройстве (нет связи)
  bool get lastSaveQueued => false;
}

/// users/{uid}/settings/templates. [ref] — null, если нет входа.
class FirestoreTemplateStore implements TemplateStore {
  FirestoreTemplateStore(this.ref, {this.offline, this.onLateError});
  final DocumentReference<Map<String, dynamic>>? Function() ref;

  /// Сейчас нет связи (тогда читаем из локальной копии)
  final bool Function()? offline;

  /// Сохранение, ушедшее в очередь без связи, позже отклонено сервером
  final void Function(Object error)? onLateError;

  bool _lastQueued = false;

  @override
  bool get lastSaveQueued => _lastQueued;

  DocumentReference<Map<String, dynamic>> get _doc {
    final r = ref();
    if (r == null) throw StateError('signed out');
    return r;
  }

  @override
  Future<TemplateSettings> load() async {
    final r = await readDoc(_doc, offline: offline?.call() ?? false);
    final snap = r.value;
    // без связи и без локальной копии настройки неизвестны: стандартные
    // шаблоны при сохранении затёрли бы настоящие
    if (r.fromCache && (snap == null || !snap.exists)) {
      throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'unavailable',
          message: 'Настроек шаблонов нет на устройстве');
    }
    return TemplateSettings.fromMap(snap?.data());
  }

  @override
  Future<void> save(TemplateSettings settings) async {
    // set без merge: документ заменяется целиком (так проверяют правила).
    // Без связи — не ждём сервер: запись уже в очереди на устройстве.
    final ack = await waitAck(
      _doc.set(
          {...settings.toMap(), 'updatedAt': FieldValue.serverTimestamp()}),
      onLateError: (e) => onLateError?.call(e),
    );
    _lastQueued = ack == WriteAck.queued;
  }
}
