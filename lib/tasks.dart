// Задачи в блоке «Задачи на день»: кнопки ✗/✓, подпункты, перенос задачи
// на следующий рабочий день.
//
// Как хранится (в Delta заметки, как и всё остальное):
//   • задача — обычный пункт нумерованного списка верхнего уровня
//     ({"list":"ordered"}) с атрибутом строки "task":
//       "open"                — открыта (по умолчанию);
//       "done"                — выполнена (текст зелёный);
//       "carried:yyyy-MM-dd"  — не выполнена, перенесена на этот день
//                               (текст зачёркнут);
//   • подпункт — вложенный пункт списка ({"list":"ordered","indent":1..}),
//     без атрибута: «a. b. c.», глубже «i. ii. iii.» — как обычно в редакторе.
// Цвет и зачёркивание рисуются при показе (по атрибуту строки), сам текст
// и его оформление не меняются — снятие отметки возвращает всё как было.
// Атрибут не текст: поле text (поиск) не меняется.
//
// Блок задач — от строки «Задачи на день:» до разделителя или следующей
// непустой строки без списка (заголовка следующего блока).

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

import 'skins.dart' show currentSkin;
import 'templates.dart'
    show TemplateComposition, TemplateLine, kTasksTitle, linesToOps, opsToLines;

/// Атрибут строки с состоянием задачи
const String kTaskAttr = 'task';

// ============================================================
//  Состояния
// ============================================================

enum TaskState { open, done, carried }

/// Состояние задачи; у перенесённой — ключ дня, куда перенесена
@immutable
class TaskValue {
  const TaskValue._(this.state, [this.target]);
  const TaskValue.carried(String target) : this._(TaskState.carried, target);

  final TaskState state;
  final String? target;

  static const TaskValue open = TaskValue._(TaskState.open);
  static const TaskValue done = TaskValue._(TaskState.done);

  /// Значение атрибута → состояние; неизвестное значение — открытая задача
  static TaskValue parse(Object? v) {
    if (v == 'done') return done;
    if (v is String && v.startsWith('carried:')) {
      final key = v.substring(8);
      if (parseDayKey(key) != null) return TaskValue.carried(key);
    }
    return open;
  }

  String encode() => switch (state) {
        TaskState.open => 'open',
        TaskState.done => 'done',
        TaskState.carried => 'carried:$target',
      };

  @override
  bool operator ==(Object other) =>
      other is TaskValue && other.state == state && other.target == target;

  @override
  int get hashCode => Object.hash(state, target);
}

enum TaskControl { cross, check }

/// Что сделать по нажатию кнопки: новое состояние и нужно ли перенести
/// задачу (✗) или отменить перенос (снять ✗ или нажать ✓ у перенесённой).
@immutable
class TaskStep {
  const TaskStep(this.to, {this.carry = false, this.uncarry = false});
  final TaskState to;
  final bool carry;
  final bool uncarry;
}

/// Нажатие неактивной кнопки включает её (и выключает другую), нажатие
/// активной — возвращает задачу в «открыта». Обе сразу не бывают.
TaskStep taskStep(TaskState from, TaskControl control) {
  switch (control) {
    case TaskControl.check:
      if (from == TaskState.done) return const TaskStep(TaskState.open);
      return TaskStep(TaskState.done, uncarry: from == TaskState.carried);
    case TaskControl.cross:
      if (from == TaskState.carried) {
        return const TaskStep(TaskState.open, uncarry: true);
      }
      return const TaskStep(TaskState.carried, carry: true);
  }
}

/// Перенос и отмена переноса — транзакции Firestore: без связи они не
/// работают (в отличие от обычных записей, которые ждут в очереди)
bool taskStepNeedsNetwork(TaskStep step) => step.carry || step.uncarry;

// ============================================================
//  Даты
// ============================================================

String dayKeyOf(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 'yyyy-MM-dd' → местная дата; null — не ключ дня
DateTime? parseDayKey(String key) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(key);
  if (m == null) return null;
  final d = DateTime(
      int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
  return dayKeyOf(d) == key ? d : null;
}

/// Следующий рабочий день строго после даты заметки (сегодняшняя дата
/// не учитывается). [isWorkday] — правило рабочих дней приложения.
DateTime nextWorkingDay(DateTime noteDate, bool Function(DateTime) isWorkday) {
  var d = DateTime(noteDate.year, noteDate.month, noteDate.day + 1);
  for (var i = 0; i < 60 && !isWorkday(d); i++) {
    d = DateTime(d.year, d.month, d.day + 1);
  }
  return d;
}

const List<String> _weekdays = [
  'понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота',
  'воскресенье',
];
const List<String> _months = [
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа',
  'сентября', 'октября', 'ноября', 'декабря',
];

/// «понедельник, 9 ноября»
String formatTaskDate(DateTime d) =>
    '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}';

const List<String> _weekdaysAcc = [
  'понедельник', 'вторник', 'среду', 'четверг', 'пятницу', 'субботу',
  'воскресенье',
];

/// Подпись окошка у ✗: «Перенесено на завтра», в пределах недели —
/// на день недели («на понедельник»), дальше — на дату («на 11 января»)
String carriedLabel(DateTime noteDate, DateTime target) {
  final days = DateTime.utc(target.year, target.month, target.day)
      .difference(DateTime.utc(noteDate.year, noteDate.month, noteDate.day))
      .inDays;
  if (days == 1) return 'Перенесено на завтра';
  if (days < 7) return 'Перенесено на ${_weekdaysAcc[target.weekday - 1]}';
  return 'Перенесено на ${target.day} ${_months[target.month - 1]}';
}

// ============================================================
//  Блок задач: границы (общие для Delta и документа редактора)
// ============================================================

/// То, что нужно знать о строке для поиска блока
@immutable
class LineShape {
  const LineShape(
      {required this.text, required this.isList, required this.isDivider});

  /// Видимый текст без перевода строки ('' — пустая строка)
  final String text;
  final bool isList;
  final bool isDivider;
}

/// Блок задач: строка заголовка и конец (не включая). Тело блока —
/// строки heading+1 .. end-1.
typedef TaskSection = ({int heading, int end});

bool _isTitle(LineShape l) =>
    !l.isList && !l.isDivider && l.text.trim() == kTasksTitle;

bool _endsSection(LineShape l) =>
    l.isDivider || (!l.isList && l.text.isNotEmpty);

TaskSection? findTaskSection(List<LineShape> lines) {
  for (var i = 0; i < lines.length; i++) {
    if (!_isTitle(lines[i])) continue;
    var j = i + 1;
    while (j < lines.length && !_endsSection(lines[j])) {
      j++;
    }
    return (heading: i, end: j);
  }
  return null;
}

// ============================================================
//  Строки Delta (TemplateLine): шаблон, группа задачи, перенос
// ============================================================

bool _isListLine(TemplateLine l) => l.attrs?['list'] != null;
int _indentOf(Map<String, dynamic>? attrs) {
  final v = attrs?['indent'];
  return v is int ? v : 0;
}

LineShape _shapeOf(TemplateLine l) => LineShape(
      text: l.isEmpty
          ? ''
          : (l.plainText.isEmpty ? '￼' : l.plainText),
      isList: _isListLine(l),
      isDivider: l.isDivider,
    );

TaskSection? _sectionOfLines(List<TemplateLine> lines) =>
    findTaskSection([for (final l in lines) _shapeOf(l)]);

Map<String, dynamic> _taskAttrs(Map<String, dynamic>? attrs) => {
      for (final e in (attrs ?? const {}).entries)
        if (e.key != kTaskAttr && e.key != 'indent' && e.key != 'list')
          e.key: e.value,
      'list': 'ordered',
      kTaskAttr: 'open',
    };

Map<String, dynamic>? _withoutTask(Map<String, dynamic>? attrs) {
  if (attrs == null || !attrs.containsKey(kTaskAttr)) return attrs;
  final m = Map<String, dynamic>.of(attrs)..remove(kTaskAttr);
  return m.isEmpty ? null : m;
}

/// Позиция для добавления в конец блока: перед хвостом из пустых строк
/// (пустые абзацы и, если [skipEmptyItems], пустые пункты верхнего уровня)
int _appendPoint(List<TemplateLine> lines, TaskSection s,
    {required bool skipEmptyItems}) {
  var j = s.end;
  while (j - 1 > s.heading) {
    final l = lines[j - 1];
    if (!l.isEmpty) break;
    final top = _isListLine(l) && _indentOf(l.attrs) == 0;
    if (_isListLine(l) && !(skipEmptyItems && top)) break;
    j--;
  }
  return j;
}

/// Шаблон нового дня: пункты верхнего уровня блока задач становятся
/// открытыми задачами (остальной текст — без изменений). Если в блоке нет
/// пустой задачи, в конец блока добавляется одна — чтобы было куда писать.
List<TemplateLine> markTaskSection(List<TemplateLine> lines) {
  final s = _sectionOfLines(lines);
  if (s == null) return lines;
  final out = [...lines];
  var hasEmpty = false;
  for (var i = s.heading + 1; i < s.end; i++) {
    final l = out[i];
    if (_isListLine(l) && _indentOf(l.attrs) == 0) {
      out[i] = TemplateLine(l.inline, _taskAttrs(l.attrs));
      if (l.isEmpty) hasEmpty = true;
    }
  }
  if (!hasEmpty) {
    out.insert(_appendPoint(out, s, skipEmptyItems: false),
        TemplateLine(const [], _taskAttrs(null)));
  }
  return out;
}

/// Задача и её подпункты (идущие сразу под ней пункты с отступом)
@immutable
class TaskGroup {
  const TaskGroup(this.task, this.subs);
  final TemplateLine task;
  final List<TemplateLine> subs;

  /// Пустую задачу переносить нельзя
  bool get isBlank =>
      task.plainText.trim().isEmpty &&
      !task.inline.any((op) => op['insert'] is! String);

  /// Строки копии: задача — открытая, подпункты — как есть
  List<TemplateLine> copyLines() => [
        TemplateLine(_cloneInline(task.inline), _taskAttrs(task.attrs)),
        for (final s in subs)
          TemplateLine(_cloneInline(s.inline), _withoutTask(s.attrs)),
      ];
}

List<Map<String, dynamic>> _cloneInline(List<Map<String, dynamic>> inline) =>
    (jsonDecode(jsonEncode(inline)) as List).cast<Map<String, dynamic>>();

/// Группа задачи в строке [index] (строки — из той же Delta). null — это не
/// пункт верхнего уровня блока задач.
TaskGroup? taskGroupAt(List<TemplateLine> lines, int index) {
  final s = _sectionOfLines(lines);
  if (s == null || index <= s.heading || index >= s.end) return null;
  final l = lines[index];
  if (!_isListLine(l) || _indentOf(l.attrs) != 0) return null;
  final subs = <TemplateLine>[];
  for (var j = index + 1; j < s.end; j++) {
    final x = lines[j];
    if (!_isListLine(x) || _indentOf(x.attrs) < 1) break;
    subs.add(x);
  }
  return TaskGroup(l, subs);
}

/// Каноническая запись содержимого строки: соседние куски с одинаковым
/// оформлением склеены (Delta может хранить их по-разному)
String _inlineSig(List<Map<String, dynamic>> inline) {
  final out = <Map<String, dynamic>>[];
  for (final op in inline) {
    final ins = op['insert'];
    final attrs = op['attributes'];
    if (out.isNotEmpty &&
        ins is String &&
        out.last['insert'] is String &&
        jsonEncode(out.last['attributes']) == jsonEncode(attrs)) {
      out.last = {
        'insert': (out.last['insert'] as String) + ins,
        'attributes': ?attrs,
      };
    } else {
      out.add({'insert': ins, 'attributes': ?attrs});
    }
  }
  return jsonEncode(out);
}

String _attrsSig(Map<String, dynamic>? attrs) {
  final m = _withoutTask(attrs) ?? const {};
  final keys = m.keys.toList()..sort();
  return jsonEncode({for (final k in keys) k: m[k]});
}

/// Нетронутая копия группы в строке [i]: открытая задача с тем же текстом
/// и ровно теми же подпунктами
bool _matchesAt(List<TemplateLine> lines, TaskSection s, int i, TaskGroup g) {
  final l = lines[i];
  if (!_isListLine(l) || _indentOf(l.attrs) != 0) return false;
  if (TaskValue.parse(l.attrs?[kTaskAttr]) != TaskValue.open ||
      l.attrs?[kTaskAttr] == null) {
    return false;
  }
  if (_inlineSig(l.inline) != _inlineSig(g.task.inline)) return false;
  for (var k = 0; k < g.subs.length; k++) {
    final j = i + 1 + k;
    if (j >= s.end) return false;
    final x = lines[j];
    if (!_isListLine(x) || _indentOf(x.attrs) < 1) return false;
    if (_inlineSig(x.inline) != _inlineSig(g.subs[k].inline) ||
        _attrsSig(x.attrs) != _attrsSig(g.subs[k].attrs)) {
      return false;
    }
  }
  final after = i + 1 + g.subs.length;
  if (after < s.end) {
    final x = lines[after];
    if (_isListLine(x) && _indentOf(x.attrs) >= 1) return false;
  }
  return true;
}

int _findGroup(List<TemplateLine> lines, TaskSection s, TaskGroup g) {
  for (var i = s.heading + 1; i < s.end; i++) {
    if (_matchesAt(lines, s, i, g)) return i;
  }
  return -1;
}

/// Добавляет копию группы в конец блока задач. Нет блока — в конец
/// документа добавляются разделитель, заголовок и группа. null — такая
/// открытая задача там уже есть (повтор не добавляется).
List<TemplateLine>? insertTaskGroup(List<TemplateLine> lines, TaskGroup g) {
  final out = [...lines];
  final s = _sectionOfLines(out);
  if (s != null) {
    if (_findGroup(out, s, g) >= 0) return null;
    out.insertAll(_appendPoint(out, s, skipEmptyItems: true), g.copyLines());
    return out;
  }
  // блока нет: убираем пустые абзацы в конце и дописываем блок
  while (out.isNotEmpty &&
      out.last.isEmpty &&
      (out.last.attrs == null || out.last.attrs!.isEmpty)) {
    out.removeLast();
  }
  if (out.isNotEmpty && !out.last.isDivider) {
    out.add(TemplateLine([
      {
        'insert': {'divider': 'hr'},
      },
    ], null));
  }
  out.add(TemplateLine([
    {'insert': kTasksTitle},
  ], null));
  out.addAll(g.copyLines());
  return out;
}

/// Убирает первую нетронутую копию группы из блока задач. null — копии
/// нет (её изменили, отметили или удалили).
List<TemplateLine>? removeTaskGroup(List<TemplateLine> lines, TaskGroup g) {
  final s = _sectionOfLines(lines);
  if (s == null) return null;
  final i = _findGroup(lines, s, g);
  if (i < 0) return null;
  return [...lines]..removeRange(i, i + 1 + g.subs.length);
}

// ============================================================
//  Запись в заметку другого дня (транзакция)
// ============================================================

/// Ограничения правил Firestore для заметки
const int kMaxNoteDeltaLength = 800000;
const int kMaxNoteTextLength = 200000;

/// Поля заметки дня (как в Firestore)
@immutable
class NoteData {
  const NoteData({required this.delta, required this.text, required this.accent});
  final String delta;
  final String text;
  final String accent;
}

class TaskCarryError implements Exception {
  TaskCarryError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Хранилище заметок для переноса: чтение → изменение → запись одной
/// транзакцией. [modify] получает текущую заметку (null — её нет) и
/// возвращает новую (null — ничего не записывать). [modify] может
/// вызываться повторно (повтор транзакции) — он не должен иметь побочных
/// эффектов, кроме перезаписи своих результатов.
abstract class TaskNoteStore {
  Future<void> transact(String key, NoteData? Function(NoteData? current) modify);
}

/// users/{uid}/notes. [notes] — null, если нет входа.
class FirestoreTaskNoteStore implements TaskNoteStore {
  FirestoreTaskNoteStore(this.notes);
  final CollectionReference<Map<String, dynamic>>? Function() notes;

  @override
  Future<void> transact(
      String key, NoteData? Function(NoteData? current) modify) async {
    final col = notes();
    if (col == null) throw StateError('signed out');
    final ref = col.doc(key);
    await ref.firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final data = snap.data();
      final cur = data == null
          ? null
          : NoteData(
              delta: data['delta'] is String ? data['delta'] as String : '',
              text: data['text'] is String ? data['text'] as String : '',
              accent: data['accent'] is String ? data['accent'] as String : '',
            );
      final next = modify(cur);
      if (next != null) {
        tx.set(ref, {
          'delta': next.delta,
          'text': next.text,
          'accent': next.accent,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    }, timeout: const Duration(seconds: 30));
  }
}

/// Строки заметки так, как её покажет приложение. null — заметки нет или
/// она пустая (тогда приложение показывает шаблон дня).
List<TemplateLine>? _linesOfNote(NoteData? n) {
  if (n == null) return null;
  if (n.delta.isNotEmpty) {
    try {
      final ops = jsonDecode(n.delta) as List;
      Document.fromJson(ops);
      return opsToLines(ops);
    } catch (_) {
      return opsToLines((Document()..insert(0, n.text)).toDelta().toJson());
    }
  }
  if (n.text.trim().isEmpty) return null;
  return opsToLines((Document()..insert(0, n.text)).toDelta().toJson());
}

/// Строки → поля заметки (Delta нормализована редактором, text — как при
/// обычном сохранении). Слишком большая заметка — ошибка, ничего не пишем.
NoteData noteDataOf(List<TemplateLine> lines, String accent, String label) {
  final doc = lines.isEmpty ? Document() : Document.fromJson(linesToOps(lines));
  final delta = jsonEncode(doc.toDelta().toJson());
  final text = doc.toPlainText().replaceAll('￼', '');
  if (delta.length > kMaxNoteDeltaLength || text.length > kMaxNoteTextLength) {
    throw TaskCarryError('Заметка на $label слишком большая — перенос отменён');
  }
  return NoteData(delta: delta, text: text, accent: accent);
}

enum CarryOutcome { added, duplicate }

enum UncarryOutcome { removed, modified, missing }

class TaskCarrier {
  TaskCarrier(this.store);
  final TaskNoteStore store;

  /// Копия группы — в заметку [targetKey]. Нет заметки — она создаётся из
  /// [emptyNote] (шаблон этого дня).
  Future<CarryOutcome> carry({
    required String targetKey,
    required TaskGroup group,
    required TemplateComposition emptyNote,
    required String label,
  }) async {
    var outcome = CarryOutcome.added;
    await store.transact(targetKey, (cur) {
      outcome = CarryOutcome.added;
      var lines = _linesOfNote(cur);
      var accent = cur?.accent ?? '';
      if (lines == null) {
        lines = emptyNote.ops.isEmpty ? <TemplateLine>[] : opsToLines(emptyNote.ops);
        if (cur == null || accent.isEmpty) accent = emptyNote.accent;
      }
      final next = insertTaskGroup(lines, group);
      if (next == null) {
        outcome = CarryOutcome.duplicate;
        return null;
      }
      return noteDataOf(next, accent, label);
    });
    return outcome;
  }

  /// Убирает нетронутую копию группы из заметки [targetKey]
  Future<UncarryOutcome> uncarry({
    required String targetKey,
    required TaskGroup group,
    required String label,
  }) async {
    var outcome = UncarryOutcome.missing;
    await store.transact(targetKey, (cur) {
      final lines = _linesOfNote(cur);
      if (lines == null) {
        outcome = UncarryOutcome.missing;
        return null;
      }
      final next = removeTaskGroup(lines, group);
      if (next == null) {
        outcome = UncarryOutcome.modified;
        return null;
      }
      outcome = UncarryOutcome.removed;
      return noteDataOf(next, cur!.accent, label);
    });
    return outcome;
  }
}

// ============================================================
//  Документ редактора: строки, разметка задач, клавиши, чистка
// ============================================================

/// Строка документа редактора
class DocLine {
  DocLine(this.node, this.start, this.length, this.attrs, this.text,
      this.isDivider);
  final Line node;
  final int start;

  /// Вместе с переводом строки
  final int length;
  final Map<String, dynamic> attrs;
  final String text;
  final bool isDivider;

  /// Позиция перевода строки
  int get end => start + length - 1;
  bool get isEmpty => length == 1;
  bool get isList => attrs['list'] != null;
  int get indent => _indentOf(attrs);
  Object? get task => attrs[kTaskAttr];

  LineShape get shape => LineShape(
      text: isEmpty ? '' : (text.isEmpty ? '￼' : text),
      isList: isList,
      isDivider: isDivider);
}

List<DocLine> docLines(Document doc) {
  final out = <DocLine>[];
  var offset = 0;
  void add(Line l) {
    final first = l.children.isEmpty ? null : l.children.first;
    final isDivider = l.children.length == 1 &&
        first is Embed &&
        first.value.type == 'divider';
    final buf = StringBuffer();
    for (final c in l.children) {
      if (c is QuillText) {
        buf.write(c.value);
      } else {
        buf.write('￼');
      }
    }
    out.add(DocLine(l, offset, l.length, l.style.toJson() ?? const {},
        buf.toString(), isDivider));
    offset += l.length;
  }

  for (final n in doc.root.children) {
    if (n is Line) {
      add(n);
    } else if (n is Block) {
      for (final c in n.children) {
        add(c as Line);
      }
    }
  }
  return out;
}

TaskSection? _sectionOfDoc(List<DocLine> lines) =>
    findTaskSection([for (final l in lines) l.shape]);

int _lineIndexAt(List<DocLine> lines, int offset) {
  for (var i = 0; i < lines.length; i++) {
    if (offset <= lines[i].end) return i;
  }
  return lines.length - 1;
}

/// Как показывать строки: в заметках дня — по-настоящему, в редакторе
/// шаблонов — неактивные кнопки, в темах — никак
enum TaskMode { off, interactive, inert }

enum TaskLineKind { task, sub }

class TaskLineInfo {
  TaskLineInfo(this.kind, this.value, this.line);
  final TaskLineKind kind;

  /// Состояние задачи; у подпункта — состояние его задачи (подпункты
  /// показываются так же: выполненная — вся зелёная, перенесённая — вся
  /// зачёркнута)
  final TaskValue value;
  final DocLine line;
}

/// Какие строки документа — задачи и их подпункты
class TaskIndex {
  TaskIndex(this.byLine);
  final Map<Line, TaskLineInfo> byLine;

  static final TaskIndex empty = TaskIndex(const {});

  static TaskIndex build(Document doc, TaskMode mode) {
    if (mode == TaskMode.off) return empty;
    final lines = docLines(doc);
    final s = _sectionOfDoc(lines);
    if (s == null) return empty;
    final map = <Line, TaskLineInfo>{};
    TaskValue? parent; // состояние задачи над подпунктами (null — не задача)
    for (var i = s.heading + 1; i < s.end; i++) {
      final l = lines[i];
      if (l.isList && l.indent == 0) {
        final isTask = mode == TaskMode.inert ||
            (l.task != null && l.attrs['list'] == 'ordered');
        parent = !isTask
            ? null
            : (mode == TaskMode.inert ? TaskValue.open : TaskValue.parse(l.task));
        if (parent != null) {
          map[l.node] = TaskLineInfo(TaskLineKind.task, parent, l);
        }
      } else if (l.isList) {
        if (parent != null) {
          map[l.node] = TaskLineInfo(TaskLineKind.sub, parent, l);
        }
      } else {
        parent = null;
      }
    }
    return TaskIndex(map);
  }
}

/// Правка документа от клавиши: изменение и куда поставить курсор
class TaskEdit {
  TaskEdit(this.delta, [this.caret]);

  /// Пустая — клавиша поглощена без изменений
  final Delta delta;
  final int? caret;
}

Map<String, dynamic> _openTaskLineAttrs(Map<String, dynamic> attrs) =>
    _taskAttrs(attrs);

/// Enter в блоке задач. null — обычное поведение редактора.
///  • в задаче: ниже появляется новая открытая задача (текст после курсора
///    переходит в неё), состояние текущей не меняется;
///  • в пустой задаче — выход из списка (обычная строка);
///  • в пустом подпункте — на уровень выше, из «a.» — снова задача;
///  • в конце заголовка блока без пунктов — первая задача под ним.
TaskEdit? planTaskEnter(Document doc, TextSelection sel) {
  if (!sel.isValid) return null;
  final lines = docLines(doc);
  final s = _sectionOfDoc(lines);
  if (s == null) return null;
  final li = _lineIndexAt(lines, sel.start);
  final l = lines[li];
  if (sel.end > l.end) return null; // выделение на несколько строк

  if (li == s.heading) {
    final hasItems = [
      for (var i = s.heading + 1; i < s.end; i++) lines[i],
    ].any((x) => x.isList);
    if (!hasItems && sel.isCollapsed && sel.start == l.end) {
      // новый перевод строки закрывает заголовок, прежний — у новой задачи
      // (вставлять после последнего перевода строки документа нельзя)
      return TaskEdit(
        Delta()
          ..retain(l.end)
          ..insert('\n', l.attrs.isEmpty ? null : Map.of(l.attrs))
          ..retain(1, {
            for (final k in l.attrs.keys) k: null,
            ..._openTaskLineAttrs(const {}),
          }),
        l.end + 1,
      );
    }
    return null;
  }
  if (li <= s.heading || li >= s.end || !l.isList) return null;

  if (l.indent == 0) {
    if (l.isEmpty) {
      return TaskEdit(
        Delta()
          ..retain(l.end)
          ..retain(1, {'list': null, 'indent': null, kTaskAttr: null}),
        l.start,
      );
    }
    // новый перевод строки на месте курсора закрывает верхнюю часть и
    // получает всё оформление строки (состояние задачи сохраняется);
    // прежний перевод строки остаётся у нижней части — новой открытой задачи
    final p = sel.start;
    final q = sel.end;
    final d = Delta();
    if (p > 0) d.retain(p);
    if (q > p) d.delete(q - p);
    d.insert('\n', Map.of(l.attrs));
    if (l.end - q > 0) d.retain(l.end - q);
    d.retain(1, {
      if (l.indent != 0) 'indent': null,
      'list': 'ordered',
      kTaskAttr: 'open',
    });
    return TaskEdit(d, p + 1);
  }

  // подпункт
  if (l.isEmpty && sel.isCollapsed) {
    return TaskEdit(
      Delta()
        ..retain(l.end)
        ..retain(
            1,
            l.indent == 1
                ? {'indent': null, 'list': 'ordered', kTaskAttr: 'open'}
                : {'indent': l.indent - 1}),
      l.start,
    );
  }
  return null; // обычный Enter: следующий подпункт того же уровня
}

/// Tab / Shift+Tab в блоке задач. null — обычное поведение.
///  • Tab в задаче: подпункт «a.» задачи выше (кнопки исчезают);
///    у первой задачи блока — ничего;
///  • Shift+Tab в задаче — ничего;
///  • в подпункте Tab / Shift+Tab — на один уровень глубже / выше,
///    из «a.» вверх — снова открытая задача.
TaskEdit? planTaskTab(Document doc, TextSelection sel, {required bool shift}) {
  if (!sel.isValid) return null;
  final lines = docLines(doc);
  final s = _sectionOfDoc(lines);
  if (s == null) return null;
  final li = _lineIndexAt(lines, sel.start);
  final l = lines[li];
  if (sel.end > l.end) return null;
  if (li <= s.heading || li >= s.end || !l.isList) return null;

  if (l.indent == 0) {
    if (shift) return TaskEdit(Delta());
    final hasParent = li - 1 > s.heading && lines[li - 1].isList;
    if (!hasParent) return TaskEdit(Delta());
    return TaskEdit(Delta()
      ..retain(l.end)
      ..retain(1, {'indent': 1, 'list': 'ordered', kTaskAttr: null}));
  }
  // подпункт: ровно на один уровень глубже / выше
  if (shift) {
    return TaskEdit(Delta()
      ..retain(l.end)
      ..retain(
          1,
          l.indent == 1
              ? {'indent': null, 'list': 'ordered', kTaskAttr: 'open'}
              : {'indent': l.indent - 1}));
  }
  if (l.indent >= kMaxTaskIndent) return TaskEdit(Delta());
  return TaskEdit(Delta()
    ..retain(l.end)
    ..retain(1, {'indent': l.indent + 1}));
}

/// Самый глубокий уровень подпункта
const int kMaxTaskIndent = 5;

/// Backspace в начале строки блока задач. null — обычное поведение.
///  • пустая задача — снимается отметка задачи (обычная строка);
///  • подпункт «a.» — на верхний уровень, снова открытой задачей.
TaskEdit? planTaskBackspace(Document doc, TextSelection sel) {
  if (!sel.isValid || !sel.isCollapsed) return null;
  final lines = docLines(doc);
  final s = _sectionOfDoc(lines);
  if (s == null) return null;
  final li = _lineIndexAt(lines, sel.start);
  final l = lines[li];
  if (sel.start != l.start) return null;
  if (li <= s.heading || li >= s.end || !l.isList) return null;
  if (l.indent == 0 && l.task != null && l.isEmpty) {
    return TaskEdit(Delta()
      ..retain(l.end)
      ..retain(1, {'list': null, kTaskAttr: null}));
  }
  if (l.indent == 1) {
    return TaskEdit(Delta()
      ..retain(l.end)
      ..retain(1, {'indent': null, 'list': 'ordered', kTaskAttr: 'open'}));
  }
  return null;
}

/// Переключатели списков (Ctrl+Shift+7/8, кнопки) не трогают задачи
bool selectionTouchesTask(Document doc, TextSelection sel) {
  if (!sel.isValid) return false;
  final index = TaskIndex.build(doc, TaskMode.interactive);
  for (final info in index.byLine.values) {
    if (info.kind != TaskLineKind.task) continue;
    final l = info.line;
    if (l.start <= sel.end && sel.start <= l.end) return true;
  }
  return false;
}

/// Смена состояния задачи в строке [line]
Delta taskStateDelta(DocLine line, TaskValue value) => Delta()
  ..retain(line.end)
  ..retain(1, {kTaskAttr: value.encode()});

/// Чистка после изменения документа (вставка, перенос строк, отмена…).
/// null — исправлять нечего.
///  • задача может быть только пунктом нумерованного списка верхнего уровня;
///  • вставленные строки вне блока задач теряют отметку задачи;
///  • при вставке из буфера ([fromPaste]) строки верхнего уровня в блоке
///    становятся открытыми задачами, вставленные задачи — открытыми
///    (отмена удаления — тоже вставка, но состояния она возвращает как было);
///  • в темах и в редакторе шаблонов отметок задач нет вовсе.
/// Старые заметки не переделываются: трогаются только вставленные строки.
Delta? sanitizeTasks(Document doc, DocChange change, TaskMode mode,
    {bool fromPaste = false}) {
  final lines = docLines(doc);

  // переводы строк, вставленные этим изменением (позиции в новом документе)
  final inserted = <int>{};
  var pos = 0;
  for (final op in change.change.toList()) {
    if (op.isRetain) {
      pos += op.length!;
    } else if (op.isInsert) {
      final data = op.data;
      if (data is String) {
        for (var i = 0; i < data.length; i++) {
          if (data[i] == '\n') inserted.add(pos + i);
        }
      }
      pos += op.length!;
    }
  }
  // документ уже ушёл дальше — позиции из этого изменения не годятся
  if (change.before.compose(change.change) != doc.toDelta()) {
    inserted.clear();
  }
  final pasted = fromPaste && inserted.isNotEmpty;

  TaskSection? s;
  if (mode == TaskMode.interactive) {
    // вставленные при вставке строки не обрывают блок задач
    s = findTaskSection([
      for (final l in lines)
        pasted && inserted.contains(l.end) && !l.isDivider && !_isTitle(l.shape)
            ? LineShape(text: l.shape.text, isList: true, isDivider: false)
            : l.shape,
    ]);
  }

  final fix = Delta();
  var cursor = 0;
  void set(DocLine l, Map<String, dynamic> attrs) {
    if (l.end > cursor) fix.retain(l.end - cursor);
    fix.retain(1, attrs);
    cursor = l.end + 1;
  }

  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    final t = l.task;
    if (mode != TaskMode.interactive) {
      if (t != null) set(l, {kTaskAttr: null});
      continue;
    }
    final inBody = s != null && i > s.heading && i < s.end;
    final isNew = inserted.contains(l.end);
    if (t != null && (l.attrs['list'] != 'ordered' || l.indent > 0)) {
      set(l, {kTaskAttr: null});
    } else if (isNew && !inBody) {
      if (t != null) set(l, {kTaskAttr: null});
    } else if (pasted && isNew && inBody && l.indent == 0) {
      if (t == null && (l.isList || !l.isEmpty)) {
        set(l, {'list': 'ordered', kTaskAttr: 'open'});
      } else if (t != null && t != 'open') {
        set(l, {kTaskAttr: 'open'}); // вставленная задача — открытая
      }
    }
  }
  return fix.isEmpty ? null : fix;
}

// ============================================================
//  Кнопки ✗ / ✓ слева от задачи
// ============================================================

const Color kTaskCrossColor = Color(0xFFFF6B6B);
const Color kTaskCheckColor = Color(0xFF4FD08A);

/// Подсказка у ✗ без связи
const String kTaskNeedNetwork = 'Нужна сеть для переноса задачи';

/// Цвет текста выполненной задачи
const Color kTaskDoneTextColor = Color(0xFF6FDC9B);

/// Ширина колонки с кнопками (вместо номера пункта): две кнопки по 28 + зазор
const double kTaskHitWidth = 28;
const double kTaskLeadingWidth = kTaskHitWidth * 2 + 6;

class TaskControls extends StatelessWidget {
  const TaskControls({
    super.key,
    required this.value,
    this.inert = false,
    this.busy = false,
    this.crossTooltip,
    this.onCross,
    this.onCheck,
    this.crossDisabled = false,
  });

  final TaskValue value;

  /// Только показ (редактор шаблонов): всегда «открыта», без нажатий
  final bool inert;

  /// Идёт перенос: ✗ показывает ожидание
  final bool busy;
  final String? crossTooltip;
  final VoidCallback? onCross;
  final VoidCallback? onCheck;

  /// Нет связи: ✗ (перенос) недоступен
  final bool crossDisabled;

  @override
  Widget build(BuildContext context) {
    final carried = !inert && value.state == TaskState.carried;
    final cross = _TaskBox(
      color: kTaskCrossColor,
      icon: Icons.close_rounded,
      active: carried,
      busy: busy,
      tooltip: inert ? null : (crossDisabled ? kTaskNeedNetwork : crossTooltip),
      onTap: inert || crossDisabled ? null : onCross,
    );
    final done = !inert && value.state == TaskState.done;
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: kTaskLeadingWidth,
        height: 24,
        child: Row(
          children: [
            crossDisabled && !inert ? Opacity(opacity: 0.35, child: cross) : cross,
            _TaskBox(
              color: kTaskCheckColor,
              icon: Icons.check_rounded,
              active: done,
              tooltip: inert ? null : 'Выполнено',
              onTap: inert ? null : onCheck,
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskBox extends StatelessWidget {
  const _TaskBox({
    required this.color,
    required this.icon,
    required this.active,
    this.busy = false,
    this.tooltip,
    this.onTap,
  });

  final Color color;
  final IconData icon;
  final bool active;
  final bool busy;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: active ? color : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: active ? color : color.withValues(alpha: 0.6),
          width: 1.5,
        ),
      ),
      child: busy
          ? Padding(
              padding: const EdgeInsets.all(2.5),
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: active ? currentSkin.value.background : color,
              ),
            )
          : Icon(
              icon,
              size: 12,
              color: active
                  ? currentSkin.value.background
                  : color.withValues(alpha: 0.7),
            ),
    );
    Widget hit = SizedBox(
      width: kTaskHitWidth,
      height: 24,
      child: Center(child: box),
    );
    if (onTap != null) {
      hit = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: busy ? null : onTap,
          child: hit,
        ),
      );
    }
    if (tooltip != null) {
      hit = Tooltip(
        message: tooltip!,
        waitDuration: const Duration(milliseconds: 400),
        child: hit,
      );
    }
    return Semantics(
      button: onTap != null,
      checked: active,
      label: tooltip,
      child: hit,
    );
  }
}

// ============================================================
//  Изменения из другой вкладки
// ============================================================

/// Изменение из другой вкладки (или переноса задачи) поверх своих правок.
/// [base] — что было сохранено, когда начали править; [local] — что в
/// редакторе сейчас; [remote] — что теперь в базе. Возвращает изменение,
/// которое нужно применить к редактору, чтобы в нём оказалось и своё,
/// и чужое (как при совместном редактировании). Пустое — ничего нового.
Delta rebaseRemoteChange(
    {required Delta base, required Delta local, required Delta remote}) {
  final remoteChange = base.diff(remote);
  final localChange = base.diff(local);
  // чужое изменение «поверх» своего; при совпадении места своё — раньше
  return localChange.transform(remoteChange, true);
}
