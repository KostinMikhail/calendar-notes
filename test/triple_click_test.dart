import 'package:calendar_notes/editor_utils.dart';
import 'package:flutter_quill/flutter_quill.dart' show Document;
import 'package:flutter_test/flutter_test.dart';

/// Текст выделения, которое дал бы тройной щелчок в позиции [at]
String? sel(Document doc, int at) {
  final r = lineRangeAt(doc, at);
  return r == null ? null : doc.toPlainText().substring(r.start, r.end);
}

final Document plain = Document.fromJson([
  {'insert': 'первая строка\nвторая строка\nтретья\n'},
]);

void main() {
  group('lineRangeAt', () {
    test('обычная строка: начало, середина, конец — без перевода строки', () {
      // «вторая строка» начинается с 14
      expect(sel(plain, 14), 'вторая строка');
      expect(sel(plain, 20), 'вторая строка');
      expect(sel(plain, 27), 'вторая строка'); // позиция перевода строки
      final r = lineRangeAt(plain, 20)!;
      expect(plain.toPlainText()[r.end], '\n');
    });

    test('первая и последняя строки документа', () {
      expect(sel(plain, 0), 'первая строка');
      expect(sel(plain, 30), 'третья');
      expect(sel(plain, 34), 'третья'); // последний перевод строки
    });

    test('длинная строка с переносами — одна логическая строка', () {
      final long = 'слово ' * 200;
      final doc = Document.fromJson([
        {'insert': 'до\n${long.trim()}\nпосле\n'},
      ]);
      expect(sel(doc, 500), long.trim());
    });

    test('пустая строка — выделять нечего', () {
      final doc = Document.fromJson([
        {'insert': 'a\n\nb\n'},
      ]);
      expect(lineRangeAt(doc, 2), isNull);
      expect(sel(doc, 0), 'a');
      expect(sel(doc, 3), 'b');
    });

    test('документ из одной пустой строки', () {
      expect(lineRangeAt(Document(), 0), isNull);
    });

    test('пункт списка (и вложенный) — только текст, без номера', () {
      final doc = Document.fromJson([
        {'insert': 'Задачи:\nпервый'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
        {'insert': 'вложенный'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered', 'indent': 1},
        },
      ]);
      expect(sel(doc, 10), 'первый');
      expect(sel(doc, 17), 'вложенный');
    });

    test('строка с жирным текстом и ссылкой — целиком', () {
      final doc = Document.fromJson([
        {'insert': 'см. '},
        {
          'insert': 'ссылку',
          'attributes': {'link': 'https://example.com'},
        },
        {'insert': ' и '},
        {
          'insert': 'жирное',
          'attributes': {'bold': true},
        },
        {'insert': '\n'},
      ]);
      expect(sel(doc, 6), 'см. ссылку и жирное');
    });

    test('разделитель: сама строка — нет, соседние — да', () {
      final doc = Document.fromJson([
        {'insert': 'над\n'},
        {
          'insert': {'divider': 'hr'},
        },
        {'insert': '\nпод\n'},
      ]);
      expect(lineRangeAt(doc, 4), isNull); // разделитель
      expect(lineRangeAt(doc, 5), isNull); // его перевод строки
      expect(sel(doc, 3), 'над');
      expect(sel(doc, 6), 'под');
    });
  });

  group('счётчик щелчков', () {
    Duration ms(int v) => Duration(milliseconds: v);
    const p = Offset(100, 100);

    test('три быстрых щелчка в одном месте — третий', () {
      final c = ClickCounter();
      expect(c.register(p, ms(0)), 1);
      expect(c.register(p, ms(200)), 2);
      expect(c.register(const Offset(103, 98), ms(400)), 3);
    });

    test('два щелчка — не тройной', () {
      final c = ClickCounter();
      c.register(p, ms(0));
      expect(c.register(p, ms(150)), 2);
    });

    test('медленные щелчки — каждый первый', () {
      final c = ClickCounter();
      expect(c.register(p, ms(0)), 1);
      expect(c.register(p, ms(700)), 1);
      expect(c.register(p, ms(1400)), 1);
    });

    test('щелчки далеко друг от друга — новая серия', () {
      final c = ClickCounter();
      c.register(p, ms(0));
      c.register(p, ms(100));
      expect(c.register(const Offset(140, 100), ms(200)), 1);
    });

    test('после третьего счёт начинается заново', () {
      final c = ClickCounter();
      c.register(p, ms(0));
      c.register(p, ms(100));
      c.register(p, ms(200));
      expect(c.register(p, ms(300)), 1);
    });

    test('очень быстрые щелчки (меньше 20 мс) — всё равно три', () {
      final c = ClickCounter();
      expect(c.register(p, ms(0)), 1);
      expect(c.register(p, ms(8)), 2);
      expect(c.register(p, ms(17)), 3);
    });

    test('сброс', () {
      final c = ClickCounter();
      c.register(p, ms(0));
      c.register(p, ms(100));
      c.reset();
      expect(c.count, 0);
      expect(c.register(p, ms(150)), 1);
    });
  });
}
