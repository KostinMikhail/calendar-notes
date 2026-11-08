import 'dart:convert';

import 'package:calendar_notes/dividers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

const hr = {'insert': {'divider': 'hr'}};

Map<String, dynamic> t(String s) => {'insert': s};

Map<String, dynamic> nl([Map<String, dynamic>? a]) =>
    {'insert': '\n', 'attributes': ?a};

List<dynamic> apply(List<dynamic> ops) => normalizeDividerOps(ops);

/// Строки документа как «текст|атрибуты»
List<String> lines(List<dynamic> ops) {
  final out = <String>[];
  final buf = StringBuffer();
  for (final op in Delta.fromJson(ops).toJson()) {
    final ins = op['insert'];
    final a = op['attributes'];
    if (ins is Map) {
      buf.write('<hr>');
      continue;
    }
    final parts = (ins as String).split('\n');
    for (var i = 0; i < parts.length; i++) {
      buf.write(parts[i]);
      if (i < parts.length - 1) {
        out.add(a == null ? buf.toString() : '$buf|${jsonEncode(a)}');
        buf.clear();
      }
    }
  }
  return out;
}

TextSelection at(int o) => TextSelection.collapsed(offset: o);

void main() {
  group('dividerLineFix — строка разделителя без оформления', () {
    test('снимаются список, отступ, заголовок, выравнивание, задача', () {
      for (final a in [
        {'list': 'ordered'},
        {'list': 'bullet', 'indent': 2},
        {'header': 2},
        {'align': 'center'},
        {'blockquote': true},
        {'code-block': true},
        {'list': 'ordered', 'task': 'open'},
      ]) {
        final ops = [t('до'), nl(), hr, nl(a), t('после'), nl()];
        expect(lines(apply(ops)), ['до', '<hr>', 'после'], reason: '$a');
      }
    });

    test('строки текста не трогаются', () {
      final ops = [
        t('один'),
        nl({'list': 'ordered'}),
        hr,
        nl({'list': 'ordered'}),
        t('два'),
        nl({'list': 'bullet', 'indent': 1}),
      ];
      expect(lines(apply(ops)), [
        'один|{"list":"ordered"}',
        '<hr>',
        'два|{"list":"bullet","indent":1}',
      ]);
    });

    test('в порядке — null; повторное применение ничего не меняет', () {
      final ok = [t('a'), nl(), hr, nl(), t('b'), nl()];
      expect(dividerLineFix(ok), isNull);
      final bad = [
        t('a'),
        nl(),
        hr,
        nl({'list': 'ordered', 'indent': 1}),
        nl(),
      ];
      final once = apply(bad);
      expect(dividerLineFix(once), isNull);
      expect(apply(once), once);
    });

    test('разделитель в одной строке с текстом — строка режется, текст цел',
        () {
      final ops = [
        t('перед'),
        hr,
        t('после'),
        nl({'list': 'ordered'}),
      ];
      expect(lines(apply(ops)), [
        'перед|{"list":"ordered"}',
        '<hr>',
        'после|{"list":"ordered"}',
      ]);
    });

    test('несколько разделителей подряд в одной строке', () {
      final ops = [hr, hr, nl({'list': 'ordered'})];
      expect(lines(apply(ops)), ['<hr>', '<hr>']);
    });

    test('без разделителей — исходный список как есть', () {
      final ops = [t('a'), nl({'list': 'ordered'})];
      expect(identical(apply(ops), ops), isTrue);
    });

    test('JSON без исправлений — та же строка (сохранённое не «меняется»)',
        () {
      final ok = jsonEncode([t('a'), nl(), hr, nl(), t('b'), nl()]);
      expect(identical(normalizeDividerJson(ok), ok), isTrue);
      final bad = jsonEncode([hr, nl({'list': 'ordered'})]);
      expect(normalizeDividerJson(bad), jsonEncode([hr, nl()]));
      expect(normalizeDividerJson('не json'), 'не json');
    });
  });

  group('испорченная заметка при загрузке', () {
    test('исправляется молча: «сохранённое» = исправленное, правки нет', () {
      // так было после бага: разделитель стал пунктом списка
      final saved = jsonEncode([
        t('Встреча'),
        nl(),
        t('пункт'),
        nl({'list': 'ordered'}),
        hr,
        nl({'list': 'ordered', 'indent': 1}),
        t('дальше'),
        nl(),
      ]);
      final doc = dividerSafeDocument(jsonDecode(saved));
      final json = jsonEncode(doc.toDelta().toJson());
      expect(lines(doc.toDelta().toJson()),
          ['Встреча', 'пункт|{"list":"ordered"}', '<hr>', 'дальше']);
      // как в _loadNoteInner: эталон берётся из открытого документа, поэтому
      // заметка не «несохранённая», пока её не начали править
      final lastSaved = json;
      expect(jsonEncode(doc.toDelta().toJson()) != lastSaved, isFalse);
      // а подписка на базу видит ту же (исправленную) версию — не чужую
      expect(normalizeDividerJson(saved), lastSaved);
    });
  });

  group('буфер обмена: текст', () {
    test('символ-заглушка и \\r\\n убираются', () {
      expect(cleanPlainText('один\r\n￼\r\nдва'), 'один\n\nдва');
      expect(cleanPlainText('a￼b'), 'ab');
      expect(cleanPlainText('обычный текст'), 'обычный текст');
      expect(cleanPlainText('https://example.com'), 'https://example.com');
    });
  });

  group('Backspace под разделителем', () {
    // «до\n<hr>\nпосле\n»: до=0..1, \n=2, hr=3, \n=4, после=5..
    final ops = [t('до'), nl(), hr, nl(), t('после'), nl()];

    test('в начале строки под разделителем — убрать его', () {
      expect(dividerAboveCaret(ops, at(5)), 3);
      final out = Delta.fromJson(ops).compose(removeDividerDelta(3));
      expect(lines(out.toJson()), ['до', 'после']); // строки не склеены
    });

    test('не в начале строки / с выделением — не наш случай', () {
      expect(dividerAboveCaret(ops, at(6)), isNull);
      expect(
          dividerAboveCaret(
              ops, const TextSelection(baseOffset: 5, extentOffset: 7)),
          isNull);
    });

    test('строка с оформлением (список, задача) — сначала обычный Backspace',
        () {
      for (final a in [
        {'list': 'ordered'},
        {'list': 'ordered', 'indent': 1},
        {'list': 'ordered', 'task': 'open'},
        {'header': 1},
      ]) {
        final o = [t('до'), nl(), hr, nl(), t('после'), nl(a)];
        expect(dividerAboveCaret(o, at(5)), isNull, reason: '$a');
      }
    });

    test('пустая строка под разделителем остаётся', () {
      final o = [t('до'), nl(), hr, nl(), nl(), t('x'), nl()];
      expect(dividerAboveCaret(o, at(5)), 3);
      final out = Delta.fromJson(o).compose(removeDividerDelta(3));
      expect(lines(out.toJson()), ['до', '', 'x']);
    });

    test('два разделителя подряд — по одному за нажатие (ближний)', () {
      // «a\n<hr>\n<hr>\nb\n»: a=0, \n=1, hr=2, \n=3, hr=4, \n=5, b=6
      final o = [t('a'), nl(), hr, nl(), hr, nl(), t('b'), nl()];
      expect(dividerAboveCaret(o, at(6)), 4);
      final once = Delta.fromJson(o).compose(removeDividerDelta(4)).toJson();
      expect(lines(once), ['a', '<hr>', 'b']);
      expect(dividerAboveCaret(once, at(4)), 2);
      final twice = Delta.fromJson(once).compose(removeDividerDelta(2)).toJson();
      expect(lines(twice), ['a', 'b']);
    });

    test('разделитель первой строкой документа', () {
      final o = [hr, nl(), t('текст'), nl()];
      expect(dividerAboveCaret(o, at(2)), 0);
      expect(dividerAboveCaret(o, at(0)), isNull);
    });
  });

  group('Delete над разделителем', () {
    final ops = [t('до'), nl(), hr, nl(), t('после'), nl()];

    test('в конце строки над разделителем — убрать его, курсор на месте', () {
      expect(dividerBelowCaret(ops, at(2)), 3);
      final out = Delta.fromJson(ops).compose(removeDividerDelta(3));
      expect(lines(out.toJson()), ['до', 'после']);
    });

    test('строка над разделителем — пункт списка: тоже убирает, пункт цел',
        () {
      final o = [t('до'), nl({'list': 'ordered'}), hr, nl(), t('п'), nl()];
      expect(dividerBelowCaret(o, at(2)), 3);
      final out = Delta.fromJson(o).compose(removeDividerDelta(3));
      expect(lines(out.toJson()), ['до|{"list":"ordered"}', 'п']);
    });

    test('не в конце строки / с выделением / нет разделителя — не наш случай',
        () {
      expect(dividerBelowCaret(ops, at(1)), isNull);
      expect(
          dividerBelowCaret(
              ops, const TextSelection(baseOffset: 0, extentOffset: 2)),
          isNull);
      expect(dividerBelowCaret(ops, at(10)), isNull); // последняя строка
    });

    test('пустая строка над разделителем остаётся', () {
      final o = [t('a'), nl(), nl(), hr, nl(), t('b'), nl()];
      expect(dividerBelowCaret(o, at(2)), 3);
      final out = Delta.fromJson(o).compose(removeDividerDelta(3));
      expect(lines(out.toJson()), ['a', '', 'b']);
    });

    test('разделитель последней строкой документа', () {
      final o = [t('текст'), nl(), hr, nl()];
      expect(dividerBelowCaret(o, at(5)), 6);
      final out = Delta.fromJson(o).compose(removeDividerDelta(6));
      expect(lines(out.toJson()), ['текст']);
    });
  });
}
