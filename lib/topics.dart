// Темы — заметки, не привязанные к дате: модель, хранилище, список.
//
// Firestore: users/{uid}/topics/{autoId}
//   title     — название, 1..80 символов
//   delta     — строка JSON Quill Delta (как у заметок дня)
//   text      — простой текст (для поиска)
//   order     — целое, порядок в списке
//   createdAt — время создания (не меняется)
//   updatedAt — время изменения содержимого/названия

import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

const String kTopicDefaultTitle = 'Новая тема';
const String kTopicUntitled = 'Без названия';
const int kTopicTitleMax = 80;

/// Пустой документ редактора (как Document().toDelta())
const String kEmptyTopicDelta = '[{"insert":"\\n"}]';

/// Ключ открытой цели для темы. Ключи дней — 'yyyy-MM-dd', поэтому
/// с ключами тем они не пересекаются.
const String kTopicKeyPrefix = 't:';

String topicKey(String id) => '$kTopicKeyPrefix$id';

/// id темы из ключа цели; null — это не тема (день)
String? topicIdOf(String? key) =>
    key != null && key.startsWith(kTopicKeyPrefix)
        ? key.substring(kTopicKeyPrefix.length)
        : null;

/// Название темы: пробелы и переводы строк схлопываются, края обрезаются,
/// пустое → «Без названия», длиннее 80 символов — обрезается.
String normalizeTopicTitle(String raw) {
  var t = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return kTopicUntitled;
  if (t.length > kTopicTitleMax) {
    t = t.substring(0, kTopicTitleMax);
    // не оставлять половину суррогатной пары
    final last = t.codeUnitAt(t.length - 1);
    if (last >= 0xD800 && last <= 0xDBFF) t = t.substring(0, t.length - 1);
    t = t.trimRight();
  }
  return t;
}

class Topic {
  const Topic({
    required this.id,
    required this.title,
    required this.order,
    this.updatedAt,
  });

  final String id;
  final String title;
  final int order;
  final DateTime? updatedAt;

  Topic copyWith({String? title, int? order, DateTime? updatedAt}) => Topic(
        id: id,
        title: title ?? this.title,
        order: order ?? this.order,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// Содержимое темы
class TopicContent {
  const TopicContent(this.delta, this.text);
  final String delta;
  final String text;
}

/// Порядок новой темы — после всех существующих
int nextTopicOrder(List<Topic> topics) =>
    topics.isEmpty ? 0 : topics.map((t) => t.order).reduce(math.max) + 1;

/// Перестановка [oldIndex] → [newIndex] (newIndex — итоговая позиция, как в
/// ReorderableListView.onReorderItem). Возвращает новый список с порядками
/// 0..n-1 и только те темы, у которых порядок изменился.
(List<Topic>, Map<String, int>) reorderTopics(
    List<Topic> topics, int oldIndex, int newIndex) {
  final list = [...topics];
  if (oldIndex < 0 || oldIndex >= list.length) return (list, const {});
  final moved = list.removeAt(oldIndex);
  list.insert(newIndex.clamp(0, list.length), moved);
  final changed = <String, int>{};
  for (var i = 0; i < list.length; i++) {
    if (list[i].order != i) {
      changed[list[i].id] = i;
      list[i] = list[i].copyWith(order: i);
    }
  }
  return (list, changed);
}

/// Хранилище тем текущего пользователя
abstract class TopicStore {
  Future<List<Topic>> list();
  Future<String> create(String title, int order);
  Future<void> rename(String id, String title);
  Future<void> delete(String id);

  /// Пакетно меняет только поле order у перечисленных тем
  Future<void> setOrders(Map<String, int> orders);

  /// null — темы нет
  Future<TopicContent?> load(String id);
  Future<void> saveContent(String id, String delta, String text);
}

/// Список тем для панели: загрузка, создание, переименование, удаление,
/// порядок. Изменения сразу видны в списке; при ошибке список
/// перечитывается с сервера, ошибка пробрасывается вызывающему.
class TopicsController extends ChangeNotifier {
  TopicsController(this.store);

  final TopicStore store;

  List<Topic> _topics = const [];
  bool _loading = false;
  bool _loaded = false;
  Object? _error;
  bool _disposed = false;

  List<Topic> get topics => _topics;
  bool get loading => _loading;
  bool get loaded => _loaded;
  Object? get error => _error;

  Topic? byId(String id) {
    for (final t in _topics) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> load() async {
    _loading = true;
    _error = null;
    _notify();
    try {
      final list = await store.list();
      list.sort((a, b) => a.order != b.order
          ? a.order.compareTo(b.order)
          : a.id.compareTo(b.id));
      _topics = list;
      _loaded = true;
    } catch (e) {
      _error = e;
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// После сбоя — показать то, что реально лежит в базе
  Future<void> _resync() async {
    try {
      await load();
    } catch (_) {}
  }

  Future<Topic> create() async {
    final order = nextTopicOrder(_topics);
    final id = await store.create(kTopicDefaultTitle, order);
    final topic = Topic(
        id: id, title: kTopicDefaultTitle, order: order, updatedAt: DateTime.now());
    _topics = [..._topics, topic];
    _notify();
    return topic;
  }

  Future<void> rename(String id, String rawTitle) async {
    final title = normalizeTopicTitle(rawTitle);
    final t = byId(id);
    if (t == null || t.title == title) return;
    _topics = [
      for (final x in _topics)
        x.id == id ? x.copyWith(title: title, updatedAt: DateTime.now()) : x
    ];
    _notify();
    try {
      await store.rename(id, title);
    } catch (_) {
      await _resync();
      rethrow;
    }
  }

  Future<void> delete(String id) async {
    _topics = [for (final x in _topics) if (x.id != id) x];
    _notify();
    try {
      await store.delete(id);
    } catch (_) {
      await _resync();
      rethrow;
    }
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    final (list, changed) = reorderTopics(_topics, oldIndex, newIndex);
    _topics = list;
    _notify();
    if (changed.isEmpty) return;
    try {
      await store.setOrders(changed);
    } catch (_) {
      await _resync();
      rethrow;
    }
  }

  /// После сохранения содержимого — время изменения (для поиска)
  void touch(String id) {
    _topics = [
      for (final x in _topics)
        x.id == id ? x.copyWith(updatedAt: DateTime.now()) : x
    ];
  }
}

/// Хранилище на Firestore. [ref] возвращает коллекцию тем вошедшего
/// пользователя или null (нет входа) — тогда операции не выполняются.
class FirestoreTopicStore implements TopicStore {
  FirestoreTopicStore(this.ref);

  final CollectionReference<Map<String, dynamic>>? Function() ref;

  static const _timeout = Duration(seconds: 30);
  static const int _maxBatch = 400;

  CollectionReference<Map<String, dynamic>> get _col {
    final c = ref();
    if (c == null) throw StateError('signed out');
    return c;
  }

  static DateTime? _time(Object? v) => v is Timestamp ? v.toDate() : null;

  @override
  Future<List<Topic>> list() async {
    final snap = await _col.get().timeout(_timeout);
    return [
      for (final d in snap.docs)
        Topic(
          id: d.id,
          title: d.data()['title'] is String
              ? d.data()['title'] as String
              : kTopicUntitled,
          order: d.data()['order'] is int ? d.data()['order'] as int : 0,
          updatedAt: _time(d.data()['updatedAt']),
        ),
    ];
  }

  @override
  Future<String> create(String title, int order) async {
    final doc = _col.doc();
    await doc.set({
      'title': title,
      'delta': kEmptyTopicDelta,
      'text': '',
      'order': order,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }).timeout(_timeout);
    return doc.id;
  }

  @override
  Future<void> rename(String id, String title) => _col.doc(id).update({
        'title': title,
        'updatedAt': FieldValue.serverTimestamp(),
      }).timeout(_timeout);

  @override
  Future<void> delete(String id) => _col.doc(id).delete().timeout(_timeout);

  @override
  Future<void> setOrders(Map<String, int> orders) async {
    final col = _col;
    final entries = orders.entries.toList();
    for (var i = 0; i < entries.length; i += _maxBatch) {
      final batch = col.firestore.batch();
      for (final e in entries.skip(i).take(_maxBatch)) {
        // только order: правила разрешают такое изменение без updatedAt
        batch.update(col.doc(e.key), {'order': e.value});
      }
      await batch.commit().timeout(_timeout);
    }
  }

  @override
  Future<TopicContent?> load(String id) async {
    final snap = await _col.doc(id).get();
    if (!snap.exists) return null;
    final d = snap.data()!;
    return TopicContent(
      d['delta'] is String ? d['delta'] as String : '',
      d['text'] is String ? d['text'] as String : '',
    );
  }

  @override
  Future<void> saveContent(String id, String delta, String text) =>
      // update, а не set: удалённую тему не воскрешаем
      _col.doc(id).update({
        'delta': delta,
        'text': text,
        'updatedAt': FieldValue.serverTimestamp(),
      });
}
