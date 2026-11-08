// Порядок и регистр вариантов исправления. Словарь (nspell) отдаёт
// варианты без учёта частых опечаток: «teh» → «the» у него девятый.
import 'dart:math' as math;

/// Расстояние Дамерау — Левенштейна (перестановка соседних букв = 1)
int damerauDistance(String a, String b) {
  final n = a.length, m = b.length;
  final d = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = 0; i <= n; i++) {
    d[i][0] = i;
  }
  for (var j = 0; j <= m; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      var v = math.min(math.min(d[i - 1][j] + 1, d[i][j - 1] + 1),
          d[i - 1][j - 1] + cost);
      if (i > 1 &&
          j > 1 &&
          a[i - 1] == b[j - 2] &&
          a[i - 2] == b[j - 1]) {
        v = math.min(v, d[i - 2][j - 2] + 1);
      }
      d[i][j] = v;
    }
  }
  return d[n][m];
}

bool _sameLetters(String a, String b) {
  if (a.length != b.length) return false;
  final x = a.split('')..sort();
  final y = b.split('')..sort();
  return x.join() == y.join();
}

bool _allCaps(String w) => w == w.toUpperCase() && w != w.toLowerCase();

/// Регистр варианта как у слова: «Превет» → «Привет»; имена собственные
/// («Москва») остаются как в словаре
String adaptCase(String word, String suggestion) {
  if (suggestion.isEmpty || word.isEmpty) return suggestion;
  final first = word[0];
  final capitalized =
      first == first.toUpperCase() && first != first.toLowerCase();
  if (capitalized) {
    return suggestion[0].toUpperCase() + suggestion.substring(1);
  }
  return suggestion;
}

/// До [max] вариантов: сначала самые близкие (перестановка букв — частая
/// опечатка), той же длины; аббревиатуры — ниже; без повторов.
List<String> rankSuggestions(String word, List<String> raw, {int max = 5}) {
  final lw = word.toLowerCase();
  final scored = <(String, List<int>)>[];
  for (var i = 0; i < raw.length; i++) {
    final s = raw[i];
    final ls = s.toLowerCase();
    if (ls == lw) continue;
    scored.add((
      s,
      [
        damerauDistance(lw, ls),
        _allCaps(s) && !_allCaps(word) ? 1 : 0,
        _sameLetters(lw, ls) ? 0 : 1,
        ls.length == lw.length ? 0 : 1,
        i,
      ],
    ));
  }
  scored.sort((a, b) {
    for (var k = 0; k < a.$2.length; k++) {
      final c = a.$2[k].compareTo(b.$2[k]);
      if (c != 0) return c;
    }
    return 0;
  });
  final out = <String>[];
  for (final (s, _) in scored) {
    final v = adaptCase(word, s);
    if (!out.contains(v)) out.add(v);
    if (out.length == max) break;
  }
  return out;
}
