import 'spell_backend.dart';

/// Не браузер: проверки нет (start() сообщает об ошибке — функция
/// тихо отключается)
SpellBackend createBackend() => _NoBackend();

class _NoBackend implements SpellBackend {
  @override
  Future<void> start() async => throw UnsupportedError('spell check: web only');

  @override
  Future<List<bool>> check(String lang, List<String> words) async =>
      [for (final _ in words) true];

  @override
  Future<List<String>> suggest(String lang, String word) async => const [];

  @override
  void dispose() {}
}
