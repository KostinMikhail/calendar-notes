// Личный словарь: users/{uid}/settings/dictionary
// { words: [строки ≤ 64 символов, не больше 5000], updatedAt: serverTimestamp }
// В памяти — множество нормализованных слов (нижний регистр, ё → е).
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../offline.dart';
import 'tokenizer.dart' show normalizeWord;

const int kMaxDictionaryWords = 5000;
const int kMaxDictionaryWordLength = 64;

/// Сколько слов добавляется одной записью (столько проверяют правила)
const int kDictionaryChunk = 20;

/// Слово годится для словаря (после нормализации)
bool isValidDictionaryWord(String w) =>
    w.isNotEmpty &&
    w.length <= kMaxDictionaryWordLength &&
    !w.contains(RegExp(r'\s'));

/// Хранилище словаря (Firestore; в тестах — подделка)
abstract class DictionaryStore {
  /// Слова из базы (без связи — из локальной копии). null — нет документа.
  Future<List<String>?> load();

  /// Добавить слова (объединение со списком в базе)
  Future<void> add(List<String> words);

  /// Убрать слово
  Future<void> remove(String word);
}

/// users/{uid}/settings/dictionary
class FirestoreDictionaryStore implements DictionaryStore {
  FirestoreDictionaryStore(this.ref, {this.offline, this.onLateError});

  /// null — нет входа
  final DocumentReference<Map<String, dynamic>>? Function() ref;
  final bool Function()? offline;

  /// Запись ушла в очередь без связи, а потом сервер её отклонил
  final void Function(Object error)? onLateError;

  DocumentReference<Map<String, dynamic>> get _doc {
    final r = ref();
    if (r == null) throw StateError('signed out');
    return r;
  }

  @override
  Future<List<String>?> load() async {
    final r = await readDoc(_doc, offline: offline?.call() ?? false);
    final data = r.value?.data();
    if (data == null) return null;
    final words = data['words'];
    if (words is! List) return const [];
    return [for (final w in words) if (w is String) w];
  }

  @override
  Future<void> add(List<String> words) async {
    // правила проверяют не больше kDictionaryChunk новых слов за запись
    for (var i = 0; i < words.length; i += kDictionaryChunk) {
      final chunk = words.skip(i).take(kDictionaryChunk).toList();
      await waitAck(
        _doc.set({
          'words': FieldValue.arrayUnion(chunk),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)),
        onLateError: (e) => onLateError?.call(e),
      );
    }
  }

  @override
  Future<void> remove(String word) => waitAck(
        _doc.set({
          'words': FieldValue.arrayRemove([word]),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)),
        onLateError: (e) => onLateError?.call(e),
      );
}

/// Словарь в памяти: добавление и удаление сразу видны (подчёркивания
/// обновляются), запись в базу — следом. Ошибка записи — слово остаётся
/// до конца сеанса, [onError] сообщает о ней.
class PersonalDictionary extends ChangeNotifier {
  PersonalDictionary(this.store, {this.onError});

  final DictionaryStore store;
  void Function(String message)? onError;

  final Set<String> _words = {};
  bool _loaded = false;
  Future<void>? _loading;

  bool get loaded => _loaded;
  int get length => _words.length;

  /// Слова по алфавиту
  List<String> get words => _words.toList()..sort();

  bool contains(String word) => _words.contains(normalizeWord(word));

  /// Загрузить из базы (ошибки — молча, словарь просто пустой)
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final list = await store.load();
      if (list != null) {
        for (final w in list) {
          final n = normalizeWord(w);
          if (isValidDictionaryWord(n)) _words.add(n);
        }
      }
      _loaded = true;
      notifyListeners();
    } catch (_) {
      _loading = null; // попробуем ещё раз при следующем обращении
    }
  }

  /// Свежий список из базы (для резервной копии); при ошибке — то, что в
  /// памяти
  Future<List<String>> exportWords() async {
    try {
      final list = await store.load();
      final all = {..._words};
      for (final w in list ?? const <String>[]) {
        final n = normalizeWord(w);
        if (isValidDictionaryWord(n)) all.add(n);
      }
      return all.toList()..sort();
    } catch (_) {
      return words;
    }
  }

  /// Добавить слово. false — слово не подходит или словарь полон.
  Future<bool> add(String word) async {
    final n = normalizeWord(word);
    if (!isValidDictionaryWord(n)) return false;
    if (_words.contains(n)) return true;
    if (_words.length >= kMaxDictionaryWords) {
      onError?.call('Личный словарь заполнен ($kMaxDictionaryWords слов)');
      return false;
    }
    _words.add(n);
    notifyListeners();
    try {
      await store.add([n]);
    } catch (e) {
      onError?.call('Ошибка сохранения словаря: ${_describe(e)}');
    }
    return true;
  }

  /// Убрать слово
  Future<void> remove(String word) async {
    final n = normalizeWord(word);
    if (!_words.remove(n)) return;
    notifyListeners();
    try {
      await store.remove(n);
    } catch (e) {
      onError?.call('Ошибка сохранения словаря: ${_describe(e)}');
    }
  }

  /// Объединить со словами из резервной копии (ничего не удаляется).
  /// Ответ — сколько слов добавлено.
  Future<int> addAll(Iterable<String> words) async {
    final fresh = <String>[];
    for (final w in words) {
      final n = normalizeWord(w);
      if (!isValidDictionaryWord(n) || _words.contains(n)) continue;
      if (_words.length + fresh.length >= kMaxDictionaryWords) break;
      if (!fresh.contains(n)) fresh.add(n);
    }
    if (fresh.isEmpty) return 0;
    _words.addAll(fresh);
    notifyListeners();
    await store.add(fresh); // ошибку видит вызывающий (восстановление)
    return fresh.length;
  }

  static String _describe(Object e) =>
      e is FirebaseException ? e.code : e.toString();
}
