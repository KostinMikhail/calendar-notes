// Правки документа для проверки правописания (чистые функции)
import 'package:flutter/services.dart' show TextRange;
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

/// Замена слова [range] на [word] одной правкой: оформление внутри строки
/// (жирный, цвет…) берётся у первой буквы старого слова; строка и
/// остальной текст не меняются.
Delta replaceWordDelta(Document doc, TextRange range, String word) {
  final style = doc.collectStyle(range.start, 1);
  final inline = <String, dynamic>{
    for (final a in style.attributes.values)
      if (a.scope == AttributeScope.inline && a.value != null) a.key: a.value,
  };
  final d = Delta();
  if (range.start > 0) d.retain(range.start);
  d.insert(word, inline.isEmpty ? null : inline);
  d.delete(range.end - range.start);
  return d;
}

/// Участки текста со ссылками (в них ничего не подчёркиваем)
List<TextRange> linkRanges(Delta delta) {
  final out = <TextRange>[];
  var off = 0;
  for (final op in delta.toList()) {
    final len = op.length ?? 0;
    final attrs = op.attributes;
    if (attrs != null && attrs.containsKey(Attribute.link.key)) {
      out.add(TextRange(start: off, end: off + len));
    }
    off += len;
  }
  return out;
}

final RegExp _wordChar = RegExp(r"[\p{L}\p{N}'’\-]", unicode: true);

/// Слово вокруг позиции [offset] в тексте (пусто — курсор не в слове)
TextRange wordAround(String text, int offset) {
  var s = offset.clamp(0, text.length);
  var e = s;
  while (s > 0 && _wordChar.hasMatch(text[s - 1])) {
    s--;
  }
  while (e < text.length && _wordChar.hasMatch(text[e])) {
    e++;
  }
  return TextRange(start: s, end: e);
}
