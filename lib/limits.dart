// Ограничения размера заметки (дня или темы). Те же числа стоят в
// firestore.rules (isValidNote, isValidTopic): если поменять здесь —
// поменять и там, иначе запись отклонит сервер.

/// Оформленный текст (delta в JSON), символов
const int kMaxNoteDeltaLength = 800000;

/// Простой текст заметки, символов
const int kMaxNoteTextLength = 200000;

/// Предел Firestore — 1 МиБ на документ в байтах UTF-8 (кириллица —
/// 2 байта на букву). Берём с запасом на имена полей и служебные данные.
const int kMaxNoteBytes = 1000000;

/// Длина строки в байтах UTF-8 без создания копии
int utf8Length(String s) {
  var n = 0;
  final len = s.length;
  for (var i = 0; i < len; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x80) {
      n += 1;
    } else if (c < 0x800) {
      n += 2;
    } else if (c >= 0xD800 &&
        c <= 0xDBFF &&
        i + 1 < len &&
        (s.codeUnitAt(i + 1) & 0xFC00) == 0xDC00) {
      n += 4; // суррогатная пара — один символ из 4 байт
      i++;
    } else {
      n += 3;
    }
  }
  return n;
}

enum NoteSizeLimit { text, delta, bytes }

/// Чем заметка превысила предел: [value] из [limit]
class NoteTooBig {
  const NoteTooBig(this.limit, this.value, this.max);
  final NoteSizeLimit limit;
  final int value;
  final int max;
}

/// Ошибка «заметка слишком большая» — запись не отправлялась
class NoteTooBigError implements Exception {
  const NoteTooBigError(this.problem);
  final NoteTooBig problem;
  @override
  String toString() => noteTooBigText(problem);
}

/// null — заметка помещается. Длины считаются в единицах UTF-16, как
/// `String.length`: для эмодзи это строже, чем считают правила, — запас.
NoteTooBig? noteSizeProblem(String delta, String text) {
  if (text.length > kMaxNoteTextLength) {
    return NoteTooBig(NoteSizeLimit.text, text.length, kMaxNoteTextLength);
  }
  if (delta.length > kMaxNoteDeltaLength) {
    return NoteTooBig(NoteSizeLimit.delta, delta.length, kMaxNoteDeltaLength);
  }
  // быстрый выход: даже по 3 байта на символ не дотянет до предела
  if ((delta.length + text.length) * 3 <= kMaxNoteBytes) return null;
  final bytes = utf8Length(delta) + utf8Length(text);
  if (bytes > kMaxNoteBytes) {
    return NoteTooBig(NoteSizeLimit.bytes, bytes, kMaxNoteBytes);
  }
  return null;
}

/// 215300 → «215 300»
String groupDigits(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return b.toString();
}

/// Понятный текст для строки статуса
String noteTooBigText(NoteTooBig p) {
  if (p.limit == NoteSizeLimit.text) {
    return 'Не сохраняется: ${groupDigits(p.value)} из '
        '${groupDigits(p.max)} символов — сократите текст';
  }
  final pct = (p.value * 100 / p.max).ceil();
  return 'Не сохраняется: с оформлением $pct% от предела — сократите текст';
}
