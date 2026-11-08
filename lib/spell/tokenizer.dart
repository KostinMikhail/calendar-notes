// Разбор текста на слова для проверки правописания и правила, какие слова
// не проверять. Чистые функции — проверяются тестами.
import 'obscene_words.dart';

/// Алфавит слова
enum SpellScript { cyrillic, latin }

/// Слово для проверки: [start]/[end] — позиции в строке, [word] — само
/// слово для словаря (апостроф ’ → ')
class SpellToken {
  const SpellToken(this.start, this.end, this.word, this.script);
  final int start;
  final int end;
  final String word;
  final SpellScript script;

  /// Язык словаря
  String get lang => script == SpellScript.cyrillic ? 'ru' : 'en';

  @override
  String toString() => '$word[$start,$end)';
}

final RegExp _cyr = RegExp(r'[Ѐ-ӿ]');
final RegExp _lat = RegExp(r'[A-Za-zÀ-ɏ]');
final RegExp _letter = RegExp(r'\p{L}', unicode: true);
final RegExp _digit = RegExp(r'\p{N}', unicode: true);

/// Куски, которые не проверяются целиком: адреса, почта, @упоминания, #теги
final RegExp _skipSpans = RegExp(
  r'(?:https?://|ftp://|www\.)\S+'
  r'|[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}.\-]+\.[\p{L}]{2,}'
  r'|[@#][\p{L}\p{N}_]+'
  r'|\b[\p{L}\p{N}\-]+(?:\.[\p{L}\p{N}\-]+)*\.(?:ru|рф|com|org|net|io|dev|app|me|info|su|ua|by|kz|рус)\b(?:/\S*)?',
  unicode: true,
  caseSensitive: false,
);

/// Слово из букв, цифр, апострофов и дефисов
final RegExp _chunk = RegExp(r"[\p{L}\p{N}'’\-]+", unicode: true);

bool _isApostrophe(String c) => c == "'" || c == '’';

/// Слова строки [text], которые нужно проверить. Не проверяются: адреса,
/// почта, @/#, слова с цифрами, слова из 1–2 букв, слова ЗАГЛАВНЫМИ,
/// слова из букв двух алфавитов. Слова через дефис проверяются по частям.
List<SpellToken> spellTokens(String text) {
  final skip = [for (final m in _skipSpans.allMatches(text)) (m.start, m.end)];
  bool skipped(int s, int e) {
    for (final (a, b) in skip) {
      if (s < b && e > a) return true;
    }
    return false;
  }

  final out = <SpellToken>[];
  for (final m in _chunk.allMatches(text)) {
    if (skipped(m.start, m.end)) continue;
    final chunk = m.group(0)!;
    if (_digit.hasMatch(chunk)) continue; // abc123, 2-й
    // части через дефис
    var partStart = 0;
    for (var i = 0; i <= chunk.length; i++) {
      if (i < chunk.length && chunk[i] != '-') continue;
      _addPart(text, m.start + partStart, m.start + i, out);
      partStart = i + 1;
    }
  }
  return out;
}

void _addPart(String text, int start, int end, List<SpellToken> out) {
  // апострофы по краям — не часть слова ('цитата', rock’n’roll’)
  while (start < end && _isApostrophe(text[start])) {
    start++;
  }
  while (end > start && _isApostrophe(text[end - 1])) {
    end--;
  }
  if (end - start < 3) return; // одна-две буквы
  final raw = text.substring(start, end);
  final letters = raw.split('').where((c) => _letter.hasMatch(c)).length;
  if (letters < 3) return;
  final hasCyr = _cyr.hasMatch(raw);
  final hasLat = _lat.hasMatch(raw);
  if (hasCyr == hasLat) return; // смесь алфавитов (или ни одного)
  if (isAllCaps(raw)) return; // СДК, API, JSON
  out.add(SpellToken(start, end, raw.replaceAll('’', "'"),
      hasCyr ? SpellScript.cyrillic : SpellScript.latin));
}

/// Всё слово заглавными (аббревиатура)
bool isAllCaps(String w) => w == w.toUpperCase() && w != w.toLowerCase();

/// Слово для личного словаря и сравнения: нижний регистр, ё → е, ’ → '
String normalizeWord(String w) => w
    .trim()
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll('’', "'");

/// Обсценная лексика — не подчёркиваем (см. obscene_words.dart)
bool isObsceneAllowed(String word) {
  final w = normalizeWord(word);
  if (kObsceneExact.contains(w)) return true;
  for (final p in kObscenePrefixes) {
    if (w.startsWith(p)) return true;
  }
  for (final r in kObsceneInfixes) {
    if (w.contains(r)) return true;
  }
  for (final p in kObsceneEbPrefixes) {
    if (w.startsWith('$pеб')) return true;
  }
  return false;
}
