// Проверка правописания на уровне приложения: включена ли, загружены ли
// словари, кэш ответов словаря на сеанс, личный словарь.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../format_menu.dart' show LocalPrefStore, PrefStore;
import 'personal_dictionary.dart';
import 'spell_backend.dart';
import 'suggestions.dart';
import 'tokenizer.dart';

/// Включена ли проверка (localStorage). По умолчанию и при ошибке
/// хранилища — включена.
class SpellPref {
  const SpellPref([this.store = const LocalPrefStore()]);
  final PrefStore store;

  static const String storageKey = 'calendar-notes.spellcheck';

  bool load() {
    try {
      return store.read(storageKey) != '0';
    } catch (_) {
      return true;
    }
  }

  void save(bool on) {
    try {
      store.write(storageKey, on ? '1' : '0');
    } catch (_) {}
  }
}

enum SpellState { idle, loading, ready, failed }

class SpellEngine extends ChangeNotifier {
  SpellEngine({
    required this.backend,
    required this.dictionary,
    this.pref = const SpellPref(),
    this.startDelay = const Duration(seconds: 3),
    this.requestTimeout = const Duration(seconds: 10),
  }) : _enabled = pref.load() {
    dictionary.addListener(_onDictionary);
  }

  final SpellBackend backend;
  final PersonalDictionary dictionary;
  final SpellPref pref;

  /// Загрузка словарей — не сразу при входе, чтобы не мешать первой
  /// загрузке заметки
  final Duration startDelay;

  /// Сколько ждать ответа словаря на один запрос (аудит, F12): завис —
  /// подчёркиваний нет, вариантов нет, меню не висит на «Поиск вариантов…»
  final Duration requestTimeout;

  bool _enabled;
  SpellState _state = SpellState.idle;
  Timer? _startTimer;
  bool _disposed = false;

  /// Ответы словаря на сеанс: 'ru:слово' → верно ли
  final Map<String, bool> _verdicts = {};

  /// Сообщить один раз, что словари не загрузились
  void Function()? onFailed;

  bool get enabled => _enabled;
  SpellState get state => _state;

  /// Можно подчёркивать (включено и словари готовы)
  bool get active => _enabled && _state == SpellState.ready;

  /// Начать загрузку (если включено). Ничего не блокирует.
  void start() {
    if (!_enabled || _state != SpellState.idle || _disposed) return;
    _state = SpellState.loading;
    _startTimer = Timer(startDelay, _boot);
  }

  Future<void> _boot() async {
    try {
      await backend.start();
      if (_disposed) return;
      _state = SpellState.ready;
      unawaited(dictionary.load());
    } catch (_) {
      if (_disposed) return;
      _state = SpellState.failed;
      onFailed?.call();
    }
    _notify();
  }

  void setEnabled(bool on) {
    if (on == _enabled) return;
    _enabled = on;
    pref.save(on);
    if (on) start();
    _notify();
  }

  void _onDictionary() => _notify();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String _dictForm(String w) =>
      w.replaceAll('ё', 'е').replaceAll('Ё', 'Е');

  static String _key(SpellToken t) => '${t.lang}:${_dictForm(t.word)}';

  /// Ответ словаря для слова уже есть
  bool isKnown(SpellToken t) =>
      _verdicts.containsKey(_key(t)) || _acceptedLocally(t.word);

  bool _acceptedLocally(String word) =>
      dictionary.contains(word) || isObsceneAllowed(word);

  /// Слово с ошибкой (только если ответ словаря уже есть)
  bool isMisspelled(SpellToken t) {
    if (_acceptedLocally(t.word)) return false;
    return _verdicts[_key(t)] == false;
  }

  /// Спросить у словаря о словах, ответа на которые ещё нет
  Future<void> checkTokens(Iterable<SpellToken> tokens) async {
    if (!active) return;
    final byLang = <String, Set<String>>{};
    for (final t in tokens) {
      if (isKnown(t)) continue;
      byLang.putIfAbsent(t.lang, () => {}).add(_dictForm(t.word));
    }
    for (final e in byLang.entries) {
      final words = e.value.toList();
      for (var i = 0; i < words.length; i += 400) {
        final part = words.skip(i).take(400).toList();
        final res =
            await backend.check(e.key, part).timeout(requestTimeout);
        for (var j = 0; j < part.length && j < res.length; j++) {
          _verdicts['${e.key}:${part[j]}'] = res[j];
        }
      }
    }
  }

  /// До 5 вариантов исправления в регистре слова
  Future<List<String>> suggestions(SpellToken t) async {
    if (!active) return const [];
    try {
      final raw = await backend
          .suggest(t.lang, _dictForm(t.word))
          .timeout(requestTimeout);
      return rankSuggestions(t.word, raw);
    } catch (_) {
      return const [];
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _startTimer?.cancel();
    dictionary.removeListener(_onDictionary);
    backend.dispose();
    super.dispose();
  }
}
