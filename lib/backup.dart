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

import 'images.dart'
    show
        EncodedImage,
        encodedImageProblem,
        imageIdsInDelta,
        isValidImageId,
        kImageMaxStoredSide,
        kImageMimes,
        kMaxImageDataLength;
import 'limits.dart';
import 'topics.dart' show topicKey;

const String kBackupFormat = 'calendar-notes-backup';

/// 1 — только заметки дней; 2 — плюс необязательный раздел topics;
/// 3 — плюс необязательный раздел dictionary (личный словарь);
/// 4 — плюс необязательный раздел images (картинки из заметок и тем).
/// Файлы прежних версий читаются как раньше.
const int kBackupVersion = 4;

/// Ограничения личного словаря (как в firestore.rules)
const int kMaxBackupDictionaryWords = 5000;
const int kMaxBackupDictionaryWordLength = 64;

const int kMaxTopicTitleLength = 80;
final RegExp _topicIdRe = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// Первый день, который попадает в резервную копию
final DateTime kBackupStart = DateTime(2026, 10, 1);

/// Самый большой файл копии, который приложение согласится читать
const int kMaxBackupBytes = 200 * 1024 * 1024; // с картинками

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

/// Картинка в копии (users/{uid}/images/{id}); [data] — base64, как в базе
class BackupImage {
  const BackupImage({
    required this.id,
    required this.mime,
    required this.width,
    required this.height,
    required this.data,
  });

  final String id;
  final String mime;
  final int width;
  final int height;
  final String data;

  int get approxBytes => data.length + mime.length + 96;

  Map<String, Object?> toJson() => {
        'id': id,
        'mime': mime,
        'width': width,
        'height': height,
        'data': data,
      };
}

/// Картинка из документа Firestore для копии (null — документ не подходит)
BackupImage? imageForBackup(String id, Map<String, dynamic>? d) {
  if (d == null || !isValidImageId(id)) return null;
  final data = d['data'];
  final mime = d['mime'];
  final w = d['width'];
  final h = d['height'];
  if (data is! String || mime is! String || w is! int || h is! int) return null;
  final img = BackupImage(id: id, mime: mime, width: w, height: h, data: data);
  try {
    _checkImage('Картинка', img);
  } on BackupException {
    return null;
  }
  return img;
}

void _checkImage(String where, BackupImage img) {
  if (!isValidImageId(img.id)) {
    throw BackupException('$where: неверный идентификатор картинки');
  }
  if (!kImageMimes.contains(img.mime)) {
    throw BackupException('$where: неподдерживаемый формат картинки');
  }
  if (img.data.isEmpty || img.data.length > kMaxImageDataLength) {
    throw BackupException('$where: картинка слишком большая или пустая');
  }
  if (img.width < 1 ||
      img.height < 1 ||
      img.width > kImageMaxStoredSide ||
      img.height > kImageMaxStoredSide) {
    throw BackupException('$where: неверный размер картинки');
  }
  try {
    final bytes = base64Decode(img.data);
    final problem = encodedImageProblem(EncodedImage(
        bytes: bytes, mime: img.mime, width: img.width, height: img.height));
    if (problem != null) throw BackupException('$where: $problem');
  } on FormatException {
    throw BackupException('$where: картинка повреждена');
  }
}

/// id картинок, на которые ссылаются заметки и темы
Set<String> imageIdsForBackup(
    List<BackupNote> notes, List<BackupTopic> topics) => {
      for (final n in notes) ...imageIdsInDelta(n.delta),
      for (final t in topics) ...imageIdsInDelta(t.delta),
    };

/// Разобранная и проверенная копия
class BackupData {
  const BackupData({
    required this.createdAt,
    required this.from,
    required this.to,
    required this.notes,
    this.topics = const [],
    this.dictionary = const [],
    this.images = const [],
  });

  /// Картинки (только в файлах версии 4 и новее); восстанавливаются только
  /// те, которых ещё нет (картинка в базе не меняется)
  final List<BackupImage> images;

  final DateTime createdAt; // UTC
  final String from;
  final String to;
  final List<BackupNote> notes;

  /// Темы (только в файлах версии 2 и новее)
  final List<BackupTopic> topics;

  /// Личный словарь (только в файлах версии 3 и новее); восстанавливается
  /// объединением со словами, которые уже есть
  final List<String> dictionary;
}

/// Тема в копии (users/{uid}/topics/{id})
class BackupTopic {
  const BackupTopic({
    required this.id,
    required this.title,
    required this.delta,
    required this.text,
    required this.order,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String title;
  final String delta; // исходная строка Quill Delta
  final String text;
  final int order;
  final String? createdAt; // ISO 8601 UTC, для справки
  final String? updatedAt;

  int get approxBytes => title.length + delta.length + text.length + 96;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'delta': delta,
        'text': text,
        'order': order,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
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
  if (delta.length > kMaxNoteDeltaLength) {
    throw BackupException('$where: заметка слишком большая');
  }
  if (text.length > kMaxNoteTextLength) {
    throw BackupException('$where: текст заметки слишком большой');
  }
  if (noteSizeProblem(delta, text) != null) {
    throw BackupException('$where: заметка слишком большая');
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
  List<BackupTopic> topics = const [],
  List<String> dictionary = const [],
  List<BackupImage> images = const [],
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
    'topics': [for (final t in topics) t.toJson()],
    if (dictionary.isNotEmpty) 'dictionary': dictionary,
    if (images.isNotEmpty) 'images': [for (final i in images) i.toJson()],
  };
  return const JsonEncoder.withIndent('  ').convert(doc);
}

void _checkTopicFields(String where, BackupTopic t) {
  if (!_topicIdRe.hasMatch(t.id)) {
    throw BackupException('$where: неверный идентификатор темы');
  }
  if (t.title.trim().isEmpty || t.title.length > kMaxTopicTitleLength) {
    throw BackupException('$where: неверное название');
  }
  if (t.delta.length > kMaxNoteDeltaLength) {
    throw BackupException('$where: тема слишком большая');
  }
  if (t.text.length > kMaxNoteTextLength) {
    throw BackupException('$where: текст темы слишком большой');
  }
  if (noteSizeProblem(t.delta, t.text) != null) {
    throw BackupException('$where: тема слишком большая');
  }
  validateDelta(t.delta, where);
}

/// Тема из документа Firestore (поля проверяются)
BackupTopic topicFromFirestore(String id, Map<String, dynamic> data) {
  final title = data['title'];
  final delta = data['delta'];
  final text = data['text'];
  final order = data['order'];
  final where = 'Тема «${title is String ? title : id}»';
  if (title is! String || delta is! String || text is! String || order is! int) {
    throw BackupException('$where хранится в неожиданном формате');
  }
  final t = BackupTopic(
    id: id,
    title: title,
    delta: delta,
    text: text,
    order: order,
    createdAt: _timestampToIso(data['createdAt']),
    updatedAt: _timestampToIso(data['updatedAt']),
  );
  _checkTopicFields(where, t);
  return t;
}

/// Все темы для копии, в порядке списка
List<BackupTopic> topicsForExport(Map<String, Map<String, dynamic>> docs) {
  final list = [
    for (final e in docs.entries) topicFromFirestore(e.key, e.value),
  ]..sort((a, b) =>
      a.order != b.order ? a.order.compareTo(b.order) : a.id.compareTo(b.id));
  return list;
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
  _onlyKeys(
      root,
      {
        'format', 'version', 'createdAt', 'dateRange', 'notes',
        // раздел тем появился в версии 2; в файлах версии 1 его быть не может
        if (version >= 2) 'topics',
        // личный словарь — с версии 3
        if (version >= 3) 'dictionary',
        // картинки — с версии 4
        if (version >= 4) 'images',
      },
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

  final topics = <BackupTopic>[];
  final rawTopics = root['topics'];
  if (rawTopics != null) {
    if (rawTopics is! List) {
      throw BackupException('$where: поле «topics» неверного типа');
    }
    final seenIds = <String>{};
    for (var i = 0; i < rawTopics.length; i++) {
      final raw = rawTopics[i];
      final at = 'Тема №${i + 1}';
      if (raw is! Map) throw BackupException('$at: неверная структура');
      _onlyKeys(raw,
          {'id', 'title', 'delta', 'text', 'order', 'createdAt', 'updatedAt'},
          at);
      final id = _field<String>(raw, 'id', at);
      final title = _field<String>(raw, 'title', at);
      final w = title.trim().isEmpty ? at : 'Тема «$title»';
      if (!seenIds.add(id)) throw BackupException('$w встречается дважды');
      final delta = _field<String>(raw, 'delta', w);
      final text = _field<String>(raw, 'text', w);
      final order = _field<int>(raw, 'order', w);
      for (final k in ['createdAt', 'updatedAt']) {
        final v = raw[k];
        if (v != null && (v is! String || DateTime.tryParse(v) == null)) {
          throw BackupException('$w: неверное поле «$k»');
        }
      }
      final t = BackupTopic(
        id: id,
        title: title,
        delta: delta,
        text: text,
        order: order,
        createdAt: raw['createdAt'] as String?,
        updatedAt: raw['updatedAt'] as String?,
      );
      _checkTopicFields(w, t);
      topics.add(t);
    }
    topics.sort((a, b) =>
        a.order != b.order ? a.order.compareTo(b.order) : a.id.compareTo(b.id));
  }
  final dictionary = _parseDictionary(root['dictionary'], where);
  final images = _parseImages(root['images'], where);
  return BackupData(
      createdAt: createdAt.toUtc(),
      from: from,
      to: to,
      notes: notes,
      topics: topics,
      dictionary: dictionary,
      images: images);
}

/// Раздел «images»: картинки (каждая проверяется целиком)
List<BackupImage> _parseImages(Object? raw, String where) {
  if (raw == null) return const [];
  if (raw is! List) {
    throw BackupException('$where: поле «images» неверного типа');
  }
  final seen = <String>{};
  final out = <BackupImage>[];
  for (var i = 0; i < raw.length; i++) {
    final m = raw[i];
    final at = 'Картинка №${i + 1}';
    if (m is! Map) throw BackupException('$at: неверная структура');
    _onlyKeys(m, {'id', 'mime', 'width', 'height', 'data'}, at);
    final img = BackupImage(
      id: _field<String>(m, 'id', at),
      mime: _field<String>(m, 'mime', at),
      width: _field<int>(m, 'width', at),
      height: _field<int>(m, 'height', at),
      data: _field<String>(m, 'data', at),
    );
    if (!seen.add(img.id)) throw BackupException('$at встречается дважды');
    _checkImage(at, img);
    out.add(img);
  }
  return out;
}

/// Раздел «dictionary»: список слов. Слова — в нижнем регистре, без повторов.
List<String> _parseDictionary(Object? raw, String where) {
  if (raw == null) return const [];
  if (raw is! List) {
    throw BackupException('$where: поле «dictionary» неверного типа');
  }
  if (raw.length > kMaxBackupDictionaryWords) {
    throw BackupException('Личный словарь: больше '
        '$kMaxBackupDictionaryWords слов');
  }
  final out = <String>{};
  for (var i = 0; i < raw.length; i++) {
    final w = raw[i];
    if (w is! String) {
      throw BackupException('Личный словарь: слово №${i + 1} — не строка');
    }
    final n = w.trim().toLowerCase().replaceAll('ё', 'е');
    if (n.isEmpty ||
        n.length > kMaxBackupDictionaryWordLength ||
        n.contains(RegExp(r'\s'))) {
      throw BackupException('Личный словарь: неверное слово №${i + 1}');
    }
    out.add(n);
  }
  return out.toList()..sort();
}

// ============================================================
//  Восстановление
// ============================================================

/// Запись одной заметки (note == null — удалить документ, нужно для отката)
/// или одной темы ([NoteWrite.topic]).
class NoteWrite {
  const NoteWrite(this.date, this.note)
      : topic = null,
        isTopic = false,
        topicExisted = false;

  /// Тема [id]: topic == null — удалить; [topicExisted] — документ уже есть
  /// (обновляется, createdAt не трогается), иначе создаётся.
  const NoteWrite.topic(String id, this.topic, {this.topicExisted = false})
      : date = id,
        note = null,
        isTopic = true;

  /// Дата заметки или id темы
  final String date;
  final BackupNote? note;
  final BackupTopic? topic;
  final bool isTopic;
  final bool topicExisted;

  int get approxBytes =>
      isTopic ? (topic?.approxBytes ?? 64) : (note?.approxBytes ?? 64);

  /// Ключ для отчёта: дата или `t:<id>`
  String get key => isTopic ? topicKey(date) : date;
}

/// Хранилище картинок для восстановления
abstract class ImageRestoreStore {
  /// Какие из этих картинок уже есть
  Future<Set<String>> existing(List<String> ids);

  /// Создать картинки (атомарно в пределах вызова)
  Future<void> create(List<BackupImage> images);
}

/// Восстанавливает картинки, которых ещё нет (есть — не трогаются: картинка
/// не меняется). Пакеты — в пределах лимитов Firestore. Возвращает число
/// созданных; ошибка — исключение (созданные до ошибки остаются: лишняя
/// картинка ничему не мешает).
Future<int> restoreImages(ImageRestoreStore store, List<BackupImage> images,
    {void Function(int done, int total)? onProgress}) async {
  if (images.isEmpty) return 0;
  final have = await store.existing([for (final i in images) i.id]);
  final missing = [for (final i in images) if (!have.contains(i.id)) i];
  var done = 0;
  var batch = <BackupImage>[];
  var bytes = 0;
  Future<void> flush() async {
    if (batch.isEmpty) return;
    await store.create(batch);
    done += batch.length;
    onProgress?.call(done, missing.length);
    batch = <BackupImage>[];
    bytes = 0;
  }

  for (final img in missing) {
    if (batch.isNotEmpty &&
        (batch.length >= kMaxOpsPerBatch ||
            bytes + img.approxBytes > kMaxBatchBytes)) {
      await flush();
    }
    batch.add(img);
    bytes += img.approxBytes;
  }
  await flush();
  return done;
}

/// Картинки на Firestore: users/{uid}/images
class FirestoreImageStore implements ImageRestoreStore {
  FirestoreImageStore(this.images);
  final CollectionReference<Map<String, dynamic>> images;

  @override
  Future<Set<String>> existing(List<String> ids) async {
    final snaps = await Future.wait([
      for (final id in ids)
        images.doc(id).get(const GetOptions(source: Source.server)),
    ]).timeout(const Duration(seconds: 120));
    return {for (final s in snaps) if (s.exists) s.id};
  }

  @override
  Future<void> create(List<BackupImage> list) async {
    final batch = images.firestore.batch();
    for (final i in list) {
      batch.set(images.doc(i.id), {
        'data': i.data,
        'mime': i.mime,
        'width': i.width,
        'height': i.height,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit().timeout(const Duration(seconds: 120));
  }
}

/// Хранилище заметок текущего пользователя
abstract class NoteStore {
  /// Текущие версии заметок за эти даты (null — заметки нет)
  Future<Map<String, BackupNote?>> readCurrent(List<String> dates);

  /// Атомарная пакетная запись
  Future<void> commit(List<NoteWrite> writes);
}

/// Хранилище, которое умеет восстанавливать и темы
abstract class TopicRestoreStore {
  /// Текущие версии тем (null — темы нет)
  Future<Map<String, BackupTopic?>> readCurrentTopics(List<String> ids);
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
  final int written; // заметок и тем, записанных до сбоя
  final String? error;
  final bool rolledBack; // записанное до сбоя возвращено как было
  /// Что вернуть не удалось: даты заметок и `t:<id>` тем
  final List<String> notRolledBack;
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
  List<BackupTopic> topics = const [],
  void Function(int done, int total)? onProgress,
}) async {
  final total = notes.length + topics.length;
  if (total == 0) return const RestoreResult(ok: true, total: 0, written: 0);

  final dates = [for (final n in notes) n.date];
  final ids = [for (final t in topics) t.id];
  Map<String, BackupNote?> before = const {};
  Map<String, BackupTopic?> topicsBefore = const {};
  try {
    if (notes.isNotEmpty) before = await store.readCurrent(dates);
    if (topics.isNotEmpty) {
      if (store is! TopicRestoreStore) {
        throw StateError('topics are not supported by this store');
      }
      topicsBefore = await (store as TopicRestoreStore).readCurrentTopics(ids);
    }
  } catch (e) {
    return RestoreResult(
      ok: false,
      total: total,
      written: 0,
      error: 'не удалось прочитать текущие заметки: ${describeError(e)}. '
          'Ничего не изменено.',
    );
  }

  final batches = chunkWrites([
    for (final n in notes) NoteWrite(n.date, n),
    for (final t in topics)
      NoteWrite.topic(t.id, t, topicExisted: topicsBefore[t.id] != null),
  ]);
  final committed = <NoteWrite>[];
  onProgress?.call(0, total);

  for (final batch in batches) {
    try {
      await store.commit(batch);
    } catch (e) {
      // откат уже записанного
      final rollback = [
        for (final w in committed)
          if (w.isTopic)
            NoteWrite.topic(w.date, topicsBefore[w.date], topicExisted: true)
          else
            NoteWrite(w.date, before[w.date]),
      ];
      final failed = <String>[];
      for (final rb in chunkWrites(rollback)) {
        try {
          await store.commit(rb);
        } catch (_) {
          failed.addAll(rb.map((w) => w.key));
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
    committed.addAll(batch);
    onProgress?.call(committed.length, total);
  }
  return RestoreResult(ok: true, total: total, written: committed.length);
}

/// Хранилище на Firestore: коллекции заметок (и тем) вошедшего пользователя
class FirestoreNoteStore implements NoteStore, TopicRestoreStore {
  FirestoreNoteStore(this.notes, {this.topics});
  final CollectionReference<Map<String, dynamic>> notes;
  final CollectionReference<Map<String, dynamic>>? topics;

  @override
  Future<Map<String, BackupTopic?>> readCurrentTopics(List<String> ids) async {
    final col = topics;
    if (col == null) throw StateError('no topics collection');
    final snaps = await Future.wait([
      for (final id in ids)
        col.doc(id).get(const GetOptions(source: Source.server)),
    ]).timeout(_timeout);
    return {
      for (final s in snaps)
        s.id: s.exists ? topicFromFirestore(s.id, s.data()!) : null,
    };
  }

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
      if (w.isTopic) {
        _topicWrite(batch, w);
        continue;
      }
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

  /// Тема: существующая — update (createdAt не трогаем, правила требуют его
  /// неизменным), новая — set с createdAt = время сервера, null — удалить.
  void _topicWrite(WriteBatch batch, NoteWrite w) {
    final col = topics;
    if (col == null) throw StateError('no topics collection');
    final ref = col.doc(w.date);
    final t = w.topic;
    if (t == null) {
      batch.delete(ref);
      return;
    }
    final fields = <String, Object>{
      'title': t.title,
      'delta': t.delta,
      'text': t.text,
      'order': t.order,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (w.topicExisted) {
      batch.update(ref, fields);
    } else {
      batch.set(ref, {...fields, 'createdAt': FieldValue.serverTimestamp()});
    }
  }
}
