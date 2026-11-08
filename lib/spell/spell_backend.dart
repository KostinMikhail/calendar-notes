// Движок проверки (словари Hunspell): в браузере — Web Worker с nspell
// (spell_backend_web.dart), в тестах — подделка.
import 'spell_backend_stub.dart'
    if (dart.library.js_interop) 'spell_backend_web.dart' as impl;

abstract class SpellBackend {
  /// Загрузить словари (ru, en). Ошибка — проверка отключается.
  Future<void> start();

  /// Верно ли написаны слова (по порядку)
  Future<List<bool>> check(String lang, List<String> words);

  /// Варианты исправления (как отдаёт словарь)
  Future<List<String>> suggest(String lang, String word);

  void dispose();
}

/// Движок для этой платформы
SpellBackend createSpellBackend() => impl.createBackend();
