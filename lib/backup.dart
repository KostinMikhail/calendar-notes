// Резервные копии заметок: формат файла, проверка, выгрузка и восстановление.
//
// Заметка в Firestore (users/{uid}/notes/{yyyy-MM-dd}):
//   delta     — строка: JSON-массив операций Quill Delta (как есть)
//   text      — простой текст заметки
//   accent    — цвет блока «Не забыть», например '#FFD54A'
//   updatedAt — время сервера
// В копию delta кладётся той же строкой, без пересборки, поэтому
// восстанавливается байт в байт.

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_quill/flutter_quill.dart' show Document;

const String kBackupFormat = 'calendar-notes-backup';
const int kBackupVersion = 1;

/// Первый день, который попадает в резервную копию
final DateTime kBackupStart = DateTime(2026, 10, 1);

/// Самый большой файл копии, который приложение согласится читать
const int kMaxBackupBytes = 50 * 1024 * 1024;

// Те же ограничения, что в firestore.rules — иначе запись отклонит сервер
const int kMaxDeltaLength = 800000;
const int kMaxTextLength = 200000;

// Ограничения Firestore на одну пакетную запись: до 500 операций и 10 МиБ.
// Берём с запасом.
const int kMaxOpsPerBatch = 400;
const int kMaxBatchBytes = 4 * 1024 * 1024;

const List<String> _monthsGen = [
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
  'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'
];

final RegExp _dateKeyRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final RegExp _accentRe = RegExp(r'^#[0-9A-Fa-f]{6}$');

/// Ошибка с понятным пользователю текстом
class BackupException implements Exception {
  BackupException(this.message);
  final String message;

  @override
  String toString() => message;
}

String backupDateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String backupFileName(DateTime localNow) =>
    'calendar-notes-backup-${backupDateKey(localNow)}.json';

/// 'yyyy-MM-dd' → '4 ноября 2026'
String formatRuDate(String key) {
  final d = DateTime.parse(key);
  return '${d.day} ${_monthsGen[d.month - 1]} ${d.year}';
}

bool isValidDateKey(Object? s) {
  if (s is! String || !_dateKeyRe.hasMatch(s)) return false;
  final d = DateTime.tryParse(s);
  return d != null && backupDateKey(d) == s; // отсекает 2026-02-30 и т.п.
}

/// Одна заметка в копии
class BackupNote {
  const BackupNote({
    required this.date,
    required this.delta,
    required this.text,
    required this.accent,
    this.updatedAt,
  });

  final String date;
  final String delta; // исходная строка Quill Delta
  final String text;
  final String accent;
  final String? updatedAt; // ISO 8601 UTC, только для справки

  int get approxBytes => delta.length + text.length + accent.length + 64;

  Map<String, Object?> toJson() => {
        'date': date,
        'delta': delta,
        'text': text,
        'accent': accent,
        'updatedAt': updatedAt,
      };
}

/// Разобранная и проверенная копия
class BackupData {
  const BackupData({
    required this.createdAt,
    required this.from,
    required this.to,
    required this.notes,
  });

  final DateTime createdAt; // UTC
  final String from;
  final String to;
  final List<BackupNote> notes;
}

/// Проверяет, что строка — корректный документ Quill Delta.
/// [where] — для текста ошибки.
void validateDelta(String delta, String where) {
  Object? ops;
  try {
    ops = jsonDecode(delta);
  } catch (_) {
    throw BackupException('$where: содержимое заметки повреждено (не JSON)');
  }
  if (ops is! List || ops.isEmpty) {
    throw BackupException('$where: содержимое заметки не похоже на Quill Delta');
  }
  for (var i = 0; i < ops.length; i++) {
    final op = ops[i];
    if (op is! Map ||
        !op.containsKey('insert') ||
        op.keys.any((k) => k != 'insert' && k != 'attributes')) {
      throw BackupException('$where: неверная операция Delta №${i + 1}');
    }
    final insert = op['insert'];
    if (insert is! String && insert is! Map) {
      throw BackupException('$where: неверная вставка в операции №${i + 1}');
    }
    final attrs = op['attributes'];
    if (attrs != null && attrs is! Map) {
      throw BackupException('$where: неверные атрибуты в операции №${i + 1}');
    }
  }
  final last = ops.last as Map;
  if (last['insert'] is! String || !(last['insert'] as String).endsWith('\n')) {
    throw BackupException('$where: заметка должна заканчиваться переводом строки');
  }
  try {
    Document.fromJson(ops);
  } catch (_) {
    throw BackupException('$where: редактор не может открыть эту заметку');
  }
}

void _checkNoteFields(String where, String delta, String text, String accent) {
  if (delta.length > kMaxDeltaLength) {
    throw BackupException('$where: заметка слишком большая');
  }
  if (text.length > kMaxTextLength) {
    throw BackupException('$where: текст заметки слишком большой');
  }
  if (!_accentRe.hasMatch(accent)) {
    throw BackupException('$where: неверный цвет блока «Не забыть»');
  }
  validateDelta(delta, where);
}

String? _timestampToIso(Object? v) {
  if (v is Timestamp) return v.toDate().toUtc().toIso8601String();
  if (v is DateTime) return v.toUtc().toIso8601String();
  return null;
}

/// Заметка из документа Firestore (поля проверяются)
BackupNote noteFromFirestore(String id, Map<String, dynamic> data) {
  final where = 'Заметка за ${isValidDateKey(id) ? formatRuDate(id) : id}';
  final delta = data['delta'];
  final text = data['text'];
  final accent = data['accent'];
  if (delta is! String || text is! String || accent is! String) {
    throw BackupException('$where хранится в неожиданном формате');
  }
  _checkNoteFields(where, delta, text, accent);
  return BackupNote(
    date: id,
    delta: delta,
    text: text,
    accent: accent,
    updatedAt: _timestampToIso(data['updatedAt']),
  );
}

/// Заметки для копии: с 1 октября 2026 по [today] включительно,
/// по возрастанию даты. Дни без документа в копию не попадают.
List<BackupNote> notesForExport(
  Map<String, Map<String, dynamic>> docs, {
  required DateTime today,
}) {
  final from = backupDateKey(kBackupStart);
  final to = backupDateKey(today);
  final ids = docs.keys
      .where((id) =>
          isValidDateKey(id) && id.compareTo(from) >= 0 && id.compareTo(to) <= 0)
      .toList()
    ..sort();
  return [for (final id in ids) noteFromFirestore(id, docs[id]!)];
}

/// JSON файла копии
String encodeBackup(
  List<BackupNote> notes, {
  required DateTime today,
  required DateTime createdAtUtc,
}) {
  final doc = {
    'format': kBackupFormat,
    'version': kBackupVersion,
    'createdAt': createdAtUtc.toUtc().toIso8601String(),
    'dateRange': {
      'from': backupDateKey(kBackupStart),
      'to': backupDateKey(today),
    },
    'notes': [for (final n in notes) n.toJson()],
  };
  return const JsonEncoder.withIndent('  ').convert(doc);
}

void _onlyKeys(Map m, Set<String> allowed, String where) {
  for (final k in m.keys) {
    if (!allowed.contains(k)) {
      throw BackupException('$where: неизвестное поле «$k»');
    }
  }
}

T _field<T>(Map m, String key, String where) {
  if (!m.containsKey(key)) {
    throw BackupException('$where: нет обязательного поля «$key»');
  }
  final v = m[key];
  if (v is! T) throw BackupException('$where: поле «$key» неверного типа');
  return v;
}

/// Разбирает и полностью проверяет файл копии. Любая ошибка — исключение,
/// ничего не пропускается молча. [today] — текущая локальная дата.
BackupData parseBackup(String source, {required DateTime today}) {
  Object? root;
  try {
    root = jsonDecode(source);
  } catch (_) {
    throw BackupException('Файл повреждён или это не JSON');
  }
  if (root is! Map) {
    throw BackupException('Это не резервная копия Calendar Notes');
  }
  if (root['format'] != kBackupFormat) {
    throw BackupException('Это не резервная копия Calendar Notes');
  }
  final version = root['version'];
  if (version is! int) {
    throw BackupException('В файле нет корректной версии формата');
  }
  if (version > kBackupVersion) {
    throw BackupException(
        'Файл создан более новой версией приложения (формат $version). '
        'Обновите приложение и попробуйте снова.');
  }
  if (version < 1) {
    throw BackupException('Версия формата $version не поддерживается');
  }
  const where = 'Файл';
  _onlyKeys(root, {'format', 'version', 'createdAt', 'dateRange', 'notes'},
      where);

  final createdRaw = _field<String>(root, 'createdAt', where);
  final createdAt = DateTime.tryParse(createdRaw);
  if (createdAt == null || !createdRaw.endsWith('Z')) {
    throw BackupException('Неверная дата создания копии');
  }

  final range = _field<Map>(root, 'dateRange', where);
  _onlyKeys(range, {'from', 'to'}, 'Период копии');
  final from = range['from'];
  final to = range['to'];
  if (!isValidDateKey(from) || !isValidDateKey(to)) {
    throw BackupException('Неверный период копии');
  }
  final start = backupDateKey(kBackupStart);
  final todayKey = backupDateKey(today);
  if ((from as String).compareTo(start) < 0) {
    throw BackupException('Период копии начинается раньше ${formatRuDate(start)}');
  }
  if ((to as String).compareTo(todayKey) > 0) {
    throw BackupException('Период копии заканчивается в будущем (${formatRuDate(to)})');
  }
  if (from.compareTo(to) > 0) {
    throw BackupException('Неверный период копии: начало позже конца');
  }

  final rawNotes = _field<List>(root, 'notes', where);
  final seen = <String>{};
  final notes = <BackupNote>[];
  for (var i = 0; i < rawNotes.length; i++) {
    final raw = rawNotes[i];
    final at = 'Заметка №${i + 1}';
    if (raw is! Map) throw BackupException('$at: неверная структура');
    _onlyKeys(raw, {'date', 'delta', 'text', 'accent', 'updatedAt'}, at);

    final date = _field<Object?>(raw, 'date', at);
    if (!isValidDateKey(date)) throw BackupException('$at: неверная дата «$date»');
    final key = date as String;
    final w = 'Заметка за ${formatRuDate(key)}';
    if (key.compareTo(from) < 0 || key.compareTo(to) > 0) {
      throw BackupException('$w вне периода копии');
    }
    if (!seen.add(key)) throw BackupException('$w встречается дважды');

    final delta = _field<String>(raw, 'delta', w);
    final text = _field<String>(raw, 'text', w);
    final accent = _field<String>(raw, 'accent', w);
    final updated = raw['updatedAt'];
    if (updated != null &&
        (updated is! String || DateTime.tryParse(updated) == null)) {
      throw BackupException('$w: неверное время изменения');
    }
    _checkNoteFields(w, delta, text, accent);
    notes.add(BackupNote(
      date: key,
      delta: delta,
      text: text,
      accent: accent,
      updatedAt: updated as String?,
    ));
  }
  notes.sort((a, b) => a.date.compareTo(b.date));
  return BackupData(createdAt: createdAt.toUtc(), from: from, to: to, notes: notes);
}

// ============================================================
//  Восстановление
// ============================================================

/// Запись одной заметки (note == null — удалить документ, нужно для отката)
class NoteWrite {
  const NoteWrite(this.date, this.note);
  final String date;
  final BackupNote? note;

  int get approxBytes => note?.approxBytes ?? 64;
}

/// Хранилище заметок текущего пользователя
abstract class NoteStore {
  /// Текущие версии заметок за эти даты (null — заметки нет)
  Future<Map<String, BackupNote?>> readCurrent(List<String> dates);

  /// Атомарная пакетная запись
  Future<void> commit(List<NoteWrite> writes);
}

/// Делит записи на пакеты в пределах лимитов Firestore
List<List<NoteWrite>> chunkWrites(List<NoteWrite> writes) {
  final batches = <List<NoteWrite>>[];
  var cur = <NoteWrite>[];
  var bytes = 0;
  for (final w in writes) {
    if (cur.isNotEmpty &&
        (cur.length >= kMaxOpsPerBatch || bytes + w.approxBytes > kMaxBatchBytes)) {
      batches.add(cur);
      cur = <NoteWrite>[];
      bytes = 0;
    }
    cur.add(w);
    bytes += w.approxBytes;
  }
  if (cur.isNotEmpty) batches.add(cur);
  return batches;
}

class RestoreResult {
  const RestoreResult({
    required this.ok,
    required this.total,
    required this.written,
    this.error,
    this.rolledBack = false,
    this.notRolledBack = const [],
  });

  final bool ok;
  final int total;
  final int written; // заметок, записанных до сбоя
  final String? error;
  final bool rolledBack; // записанное до сбоя возвращено как было
  final List<String> notRolledBack; // даты, которые вернуть не удалось
}

/// Понятный текст ошибки Firestore/сети (без технических подробностей)
String describeError(Object e) {
  if (e is TimeoutException) {
    return 'сервер не ответил вовремя (проверьте интернет)';
  }
  if (e is FirebaseException) {
    switch (e.code) {
      case 'permission-denied':
      case 'unauthenticated':
        return 'нет доступа — возможно, вход истёк, войдите заново';
      case 'unavailable':
      case 'deadline-exceeded':
        return 'сервер недоступен (проверьте интернет)';
      case 'resource-exhausted':
        return 'превышен лимит запросов Firestore, попробуйте позже';
      default:
        return 'ошибка Firestore (${e.code})';
    }
  }
  if (e is BackupException) return e.message;
  return 'непредвиденная ошибка';
}

/// Восстановление с перезаписью: каждая заметка из копии полностью заменяет
/// заметку с той же датой (или создаётся). Остальные даты не трогаются.
///
/// Firestore атомарен только в пределах одного пакета. Поэтому перед записью
/// запоминаются текущие версии затронутых дат, и если какой-то пакет не
/// записался, уже записанные пакеты возвращаются к прежним версиям.
Future<RestoreResult> runRestore(
  NoteStore store,
  List<BackupNote> notes, {
  void Function(int done, int total)? onProgress,
}) async {
  final total = notes.length;
  if (total == 0) return const RestoreResult(ok: true, total: 0, written: 0);

  final dates = [for (final n in notes) n.date];
  Map<String, BackupNote?> before;
  try {
    before = await store.readCurrent(dates);
  } catch (e) {
    return RestoreResult(
      ok: false,
      total: total,
      written: 0,
      error: 'не удалось прочитать текущие заметки: ${describeError(e)}. '
          'Ничего не изменено.',
    );
  }

  final batches = chunkWrites([for (final n in notes) NoteWrite(n.date, n)]);
  final committed = <String>[];
  onProgress?.call(0, total);

  for (final batch in batches) {
    try {
      await store.commit(batch);
    } catch (e) {
      // откат уже записанного
      final rollback = [for (final d in committed) NoteWrite(d, before[d])];
      final failed = <String>[];
      for (final rb in chunkWrites(rollback)) {
        try {
          await store.commit(rb);
        } catch (_) {
          failed.addAll(rb.map((w) => w.date));
        }
      }
      return RestoreResult(
        ok: false,
        total: total,
        written: committed.length,
        error: describeError(e),
        rolledBack: committed.isNotEmpty && failed.isEmpty,
        notRolledBack: failed,
      );
    }
    committed.addAll(batch.map((w) => w.date));
    onProgress?.call(committed.length, total);
  }
  return RestoreResult(ok: true, total: total, written: committed.length);
}

/// Хранилище на Firestore: коллекция заметок вошедшего пользователя
class FirestoreNoteStore implements NoteStore {
  FirestoreNoteStore(this.notes);
  final CollectionReference<Map<String, dynamic>> notes;

  static const _timeout = Duration(seconds: 60);

  @override
  Future<Map<String, BackupNote?>> readCurrent(List<String> dates) async {
    final sorted = [...dates]..sort();
    final snap = await notes
        .where(FieldPath.documentId, isGreaterThanOrEqualTo: sorted.first)
        .where(FieldPath.documentId, isLessThanOrEqualTo: sorted.last)
        .get(const GetOptions(source: Source.server))
        .timeout(_timeout);
    final existing = {for (final d in snap.docs) d.id: d.data()};
    return {
      for (final d in dates)
        d: existing.containsKey(d) ? noteFromFirestore(d, existing[d]!) : null,
    };
  }

  @override
  Future<void> commit(List<NoteWrite> writes) async {
    final batch = notes.firestore.batch();
    for (final w in writes) {
      final ref = notes.doc(w.date);
      final n = w.note;
      if (n == null) {
        batch.delete(ref);
      } else {
        // set без merge — документ заменяется целиком
        batch.set(ref, {
          'delta': n.delta,
          'text': n.text,
          'accent': n.accent,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    }
    await batch.commit().timeout(_timeout);
  }
}
