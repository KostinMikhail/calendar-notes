// Поиск по заметкам: нормализация, поиск по строкам, фрагменты, склонения.
// Чистый Dart — без Flutter и Firebase, чтобы всё проверялось тестами.
//
// Главное правило: нормализация сохраняет длину посимвольно, поэтому
// позиции совпадений в нормализованной строке совпадают с позициями
// в исходной. Одна и та же функция [findInText] используется для поиска,
// для фрагмента в результатах и для выделения в редакторе.

/// Символ, которым редактор обозначает вставки (разделители)
const String kObjectReplacement = '\uFFFC';

/// Минимальная длина запроса (без пробелов)
const int kMinQueryLength = 2;

/// Строчные буквы и «ё» → «е». Длина строки не меняется: если у символа
/// строчная форма другой длины, остаётся исходный символ. Символ вставки
/// [kObjectReplacement] становится пробелом — по нему не ищется.
String normalizeForSearch(String s) {
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (ch == kObjectReplacement) {
      b.write(' ');
      continue;
    }
    var low = ch.toLowerCase();
    if (low.length != 1) low = ch;
    if (low == 'ё') low = 'е';
    b.write(low);
  }
  return b.toString();
}

/// Слова запроса (уже нормализованные)
List<String> queryWords(String query) => normalizeForSearch(query)
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .toList();

/// Достаточно ли длинный запрос (символов без пробелов)
bool isQueryLongEnough(String query) =>
    query.replaceAll(RegExp(r'\s+'), '').length >= kMinQueryLength;

/// Диапазон [start, end) в строке
class TextRange2 {
  const TextRange2(this.start, this.end);
  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is TextRange2 && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '[$start, $end)';
}

/// Совпадения в одной строке заметки
class LineHit {
  const LineHit({
    required this.offset,
    required this.line,
    required this.ranges,
  });

  /// Позиция начала строки в тексте заметки
  final int offset;

  /// Сама строка (исходный текст)
  final String line;

  /// Все вхождения всех слов в строке, по возрастанию, без наложений
  final List<TextRange2> ranges;
}

/// Итог поиска по одной заметке
class TextHits {
  const TextHits(this.lines, this.count);

  /// Строки с совпадениями, по порядку
  final List<LineHit> lines;

  /// Всего вхождений всех слов
  final int count;

  /// Первое совпадение в координатах всего текста
  TextRange2 get first {
    final l = lines.first;
    final r = l.ranges.first;
    return TextRange2(l.offset + r.start, l.offset + r.end);
  }
}

/// Строка не участвует в поиске: пустая, разделитель или строка шаблона,
/// которую не меняли
bool _skipLine(String line, Set<String> boilerplate) {
  final visible = line.replaceAll(kObjectReplacement, '').trim();
  return visible.isEmpty || boilerplate.contains(visible);
}

/// Все вхождения [word] в [hay], без наложений
List<TextRange2> _occurrences(String hay, String word) {
  final res = <TextRange2>[];
  var from = 0;
  while (true) {
    final i = hay.indexOf(word, from);
    if (i < 0) break;
    res.add(TextRange2(i, i + word.length));
    from = i + word.length;
  }
  return res;
}

/// Сливает пересекающиеся и соседние диапазоны
List<TextRange2> _merge(List<TextRange2> ranges) {
  if (ranges.isEmpty) return ranges;
  final sorted = [...ranges]..sort((a, b) => a.start != b.start
      ? a.start.compareTo(b.start)
      : a.end.compareTo(b.end));
  final out = <TextRange2>[sorted.first];
  for (final r in sorted.skip(1)) {
    final last = out.last;
    if (r.start <= last.end) {
      if (r.end > last.end) out[out.length - 1] = TextRange2(last.start, r.end);
    } else {
      out.add(r);
    }
  }
  return out;
}

/// Поиск по тексту заметки построчно. Совпадение — только если КАЖДОЕ слово
/// встречается в заметке (в любых строках). null — не найдено.
///
/// [words] — результат [queryWords]. [normalized] — заранее посчитанный
/// [normalizeForSearch] от [text] (если есть).
TextHits? findInText(
  String text,
  List<String> words,
  Set<String> boilerplate, {
  String? normalized,
  bool Function(String word)? foundElsewhere,
}) {
  if (words.isEmpty) return null;
  final norm = normalized ?? normalizeForSearch(text);
  assert(norm.length == text.length);

  // [foundElsewhere] — слово уже нашлось вне текста (в названии темы)
  final found = [for (final w in words) foundElsewhere?.call(w) ?? false];
  final lines = <LineHit>[];
  var count = 0;
  var offset = 0;
  for (final line in text.split('\n')) {
    final start = offset;
    offset += line.length + 1;
    if (_skipLine(line, boilerplate)) continue;

    final normLine = norm.substring(start, start + line.length);
    final ranges = <TextRange2>[];
    for (var w = 0; w < words.length; w++) {
      final occ = _occurrences(normLine, words[w]);
      if (occ.isEmpty) continue;
      found[w] = true;
      count += occ.length;
      ranges.addAll(occ);
    }
    if (ranges.isNotEmpty) {
      lines.add(LineHit(offset: start, line: line, ranges: _merge(ranges)));
    }
  }
  if (found.contains(false)) return null;
  return TextHits(lines, count);
}

/// Фрагмент строки для списка результатов
class Snippet {
  const Snippet(this.text, this.highlights);
  final String text;
  final List<TextRange2> highlights;
}

/// Фрагмент вокруг первого совпадения: ~[before] символов до и ~[after]
/// после его начала, обрезка по границам слов, «…» на обрезанных краях.
Snippet buildSnippet(LineHit hit, {int before = 40, int after = 100}) {
  final line = hit.line;
  final first = hit.ranges.first.start;
  var start = first - before;
  var end = first + after;
  if (start <= 0) {
    start = 0;
  } else {
    // начинаем с начала слова, но не позже совпадения
    final ws = line.indexOf(RegExp(r'\s'), start);
    if (ws >= 0 && ws < first) start = ws + 1;
  }
  if (end >= line.length) {
    end = line.length;
  } else {
    final firstEnd = hit.ranges.first.end;
    final ws = line.lastIndexOf(RegExp(r'\s'), end);
    if (ws > firstEnd) end = ws;
    if (end < firstEnd) end = firstEnd;
  }

  final cutStart = start > 0;
  final cutEnd = end < line.length;
  final body = line
      .substring(start, end)
      .replaceAll('\n', ' ')
      .replaceAll(kObjectReplacement, ' ');
  final shift = (cutStart ? 1 : 0) - start;
  final highlights = <TextRange2>[
    for (final r in hit.ranges)
      if (r.end > start && r.start < end)
        TextRange2(
          (r.start < start ? start : r.start) + shift,
          (r.end > end ? end : r.end) + shift,
        ),
  ];
  return Snippet(
    '${cutStart ? '…' : ''}$body${cutEnd ? '…' : ''}',
    highlights,
  );
}

/// «1 совпадение», «2 совпадения», «5 совпадений»
String pluralMatches(int n) {
  final m10 = n % 10;
  final m100 = n % 100;
  final String word;
  if (m10 == 1 && m100 != 11) {
    word = 'совпадение';
  } else if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) {
    word = 'совпадения';
  } else {
    word = 'совпадений';
  }
  return '$n $word';
}

/// Заметка для поиска: ключ дня и текст. Нормализованный текст считается
/// при первом поиске и запоминается.
class SearchNote {
  SearchNote(this.key, this.text);
  final String key; // yyyy-MM-dd
  final String text;
  String? _normalized;
  String get normalized => _normalized ??= normalizeForSearch(text);
}

/// Найденный день
class SearchHit {
  const SearchHit(this.key, this.hits);
  final String key;
  final TextHits hits;
}

/// Поиск по всем заметкам: найденные дни, новые сверху
List<SearchHit> searchNotes(
  Iterable<SearchNote> notes,
  String query,
  Set<String> boilerplate,
) {
  if (!isQueryLongEnough(query)) return const [];
  final words = queryWords(query);
  final res = <SearchHit>[];
  for (final n in notes) {
    final h = findInText(n.text, words, boilerplate, normalized: n.normalized);
    if (h != null) res.add(SearchHit(n.key, h));
  }
  res.sort((a, b) => b.key.compareTo(a.key));
  return res;
}

// ============================================================
//  Темы
// ============================================================

/// Тема для поиска: название и текст (нормализованные — по запросу)
class SearchTopic {
  SearchTopic(this.id, this.title, this.text, {this.updatedAt});
  final String id;
  final String title;
  final String text;
  final DateTime? updatedAt;
  String? _normTitle;
  String? _normText;
  String get normalizedTitle => _normTitle ??= normalizeForSearch(title);
  String get normalizedText => _normText ??= normalizeForSearch(text);
}

/// Найденная тема
class TopicSearchHit {
  const TopicSearchHit(this.topic, this.titleRanges, this.hits);
  final SearchTopic topic;

  /// Совпадения в названии (для подсветки)
  final List<TextRange2> titleRanges;

  /// Совпадения в тексте; lines может быть пустым, если слова нашлись
  /// только в названии
  final TextHits hits;

  bool get titleMatch => titleRanges.isNotEmpty;
  int get count => hits.count + titleRanges.length;
}

/// Поиск по темам: каждое слово запроса — в названии или в тексте.
/// Сначала темы с совпадением в названии, затем недавно изменённые.
List<TopicSearchHit> searchTopics(Iterable<SearchTopic> topics, String query) {
  if (!isQueryLongEnough(query)) return const [];
  final words = queryWords(query);
  final res = <TopicSearchHit>[];
  for (final t in topics) {
    final nt = t.normalizedTitle;
    final hits = findInText(t.text, words, const {},
        normalized: t.normalizedText, foundElsewhere: nt.contains);
    if (hits == null) continue;
    final titleRanges = _merge([for (final w in words) ..._occurrences(nt, w)]);
    res.add(TopicSearchHit(t, titleRanges, hits));
  }
  res.sort((a, b) {
    if (a.titleMatch != b.titleMatch) return a.titleMatch ? -1 : 1;
    final ua = a.topic.updatedAt, ub = b.topic.updatedAt;
    if (ua != null && ub != null && ua != ub) return ub.compareTo(ua);
    if ((ua == null) != (ub == null)) return ua == null ? 1 : -1;
    return a.topic.title.compareTo(b.topic.title);
  });
  return res;
}
