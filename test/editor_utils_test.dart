import 'package:calendar_notes/editor_utils.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' show ChangeSource, Document;
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

/// Применяет вставку разделителя к документу и возвращает строки:
/// текст строки + '|list' если у неё есть список; '—' — разделитель
(List<String>, int) apply(List<Map<String, dynamic>> docOps, int offset) {
  final doc = Document.fromJson(docOps);
  final ins = dividerInsertOps(doc.toDelta().toJson(), offset);
  doc.compose(Delta.fromJson(ins.ops), ChangeSource.local);
  final lines = <String>[];
  var cur = StringBuffer();
  for (final op in doc.toDelta().toJson()) {
    final i = op['insert'];
    if (i is Map) {
      cur.write('—');
      continue;
    }
    final s = i as String;
    for (var k = 0; k < s.length; k++) {
      if (s[k] == '\n') {
        final list = (op['attributes'] as Map?)?['list'];
        lines.add('$cur${list != null ? '|$list' : ''}');
        cur = StringBuffer();
      } else {
        cur.write(s[k]);
      }
    }
  }
  return (lines, ins.caret);
}

final List<Map<String, dynamic>> twoLines = [
  {'insert': 'первая\nвторая\n'},
];

final List<Map<String, dynamic>> listLine = [
  {'insert': 'заголовок\nпункт'},
  {
    'insert': '\n',
    'attributes': {'list': 'ordered'},
  },
];

void main() {
  group('сочетание клавиш разделителя', () {
    bool hk(LogicalKeyboardKey l, PhysicalKeyboardKey p,
            {bool ctrl = true, bool shift = true, bool alt = false}) =>
        isDividerHotkey(
            ctrl: ctrl, shift: shift, alt: alt, logical: l, physical: p);

    test('минус, подчёркивание, цифровой блок, физическая клавиша', () {
      expect(hk(LogicalKeyboardKey.minus, PhysicalKeyboardKey.minus), isTrue);
      expect(hk(LogicalKeyboardKey.underscore, PhysicalKeyboardKey.minus), isTrue);
      expect(hk(LogicalKeyboardKey.numpadSubtract,
          PhysicalKeyboardKey.numpadSubtract), isTrue);
      // раскладка дала другой логический символ, но клавиша та же
      expect(hk(LogicalKeyboardKey.keyQ, PhysicalKeyboardKey.minus), isTrue);
    });

    test('без Ctrl/Shift или с Alt — нет; цифры 7/8 — не разделитель', () {
      expect(hk(LogicalKeyboardKey.minus, PhysicalKeyboardKey.minus, shift: false),
          isFalse);
      expect(hk(LogicalKeyboardKey.minus, PhysicalKeyboardKey.minus, ctrl: false),
          isFalse);
      expect(hk(LogicalKeyboardKey.minus, PhysicalKeyboardKey.minus, alt: true),
          isFalse);
      expect(hk(LogicalKeyboardKey.digit7, PhysicalKeyboardKey.digit7), isFalse);
      expect(hk(LogicalKeyboardKey.digit8, PhysicalKeyboardKey.digit8), isFalse);
    });
  });

  group('вставка разделителя', () {
    test('в начале строки — перед ней', () {
      final (lines, caret) = apply(twoLines, 7); // начало «вторая»
      expect(lines, ['первая', '—', 'вторая']);
      expect(caret, 9);
    });

    test('в начале документа', () {
      final (lines, caret) = apply(twoLines, 0);
      expect(lines, ['—', 'первая', 'вторая']);
      expect(caret, 2);
    });

    test('в середине строки — строка делится', () {
      final (lines, caret) = apply(twoLines, 3); // «пер|вая»
      expect(lines, ['пер', '—', 'вая', 'вторая']);
      expect(caret, 6);
    });

    test('в конце строки — после неё', () {
      final (lines, caret) = apply(twoLines, 6); // «первая|»
      expect(lines, ['первая', '—', 'вторая']);
      expect(caret, 9);
    });

    test('в конце документа — разделитель и пустая строка для курсора', () {
      final (lines, caret) = apply(twoLines, 13); // «вторая|»
      expect(lines, ['первая', 'вторая', '—', '']);
      expect(caret, 16);
    });

    test('в середине пункта списка — обе части остаются пунктами', () {
      final (lines, _) = apply(listLine, 12); // «пу|нкт»
      expect(lines, ['заголовок', 'пу|ordered', '—', 'нкт|ordered']);
    });

    test('разделитель — отдельная строка без оформления', () {
      final doc = Document.fromJson(listLine);
      final ins = dividerInsertOps(doc.toDelta().toJson(), 12);
      doc.compose(Delta.fromJson(ins.ops), ChangeSource.local);
      final ops = doc.toDelta().toJson();
      final i = ops.indexWhere((o) => o['insert'] is Map);
      // перевод строки после разделителя — без оформления
      expect((ops[i + 1]['insert'] as String).startsWith('\n'), isTrue);
      expect(ops[i + 1]['attributes'], isNull);
      expect(ops[i - 1]['attributes'], {'list': 'ordered'}); // «пу» — пункт
    });
  });
}
