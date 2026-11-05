import 'package:calendar_notes/main.dart'
    show kTemplateLines, kNotForgetTitle, kMonthlyReport, kHolidayNote;
import 'package:calendar_notes/search.dart';
import 'package:flutter_test/flutter_test.dart';

const Set<String> kBoiler = {
  'Задачи на день:',
  'СДК дейли:',
  'Новые автоответчики от МТС?',
  'Не забыть:',
};

/// Фрагменты строки, попавшие в диапазоны
List<String> marked(String s, List<TextRange2> ranges) =>
    [for (final r in ranges) s.substring(r.start, r.end)];

void main() {
  group('нормализация', () {
    test('строчные буквы и ё → е, длина сохраняется', () {
      const src = 'ЁЛКА Ёж ёлка Hello МИР';
      final n = normalizeForSearch(src);
      expect(n, 'елка еж елка hello мир');
      expect(n.length, src.length);
    });

    test('символы, у которых строчная форма длиннее, остаются как есть', () {
      const src = 'İstanbul'; // 'İ'.toLowerCase() — два символа
      final n = normalizeForSearch(src);
      expect(n.length, src.length);
      expect(n.substring(1), 'stanbul');
    });

    test('пробелы не схлопываются, \\uFFFC становится пробелом', () {
      expect(normalizeForSearch('a  b\n\tc'), 'a  b\n\tc');
      expect(normalizeForSearch('a\uFFFCb'), 'a b');
    });

    test('слова запроса и минимальная длина', () {
      expect(queryWords('  Привет   ЁЖ '), ['привет', 'еж']);
      expect(isQueryLongEnough('а'), isFalse);
      expect(isQueryLongEnough(' а '), isFalse);
      expect(isQueryLongEnough('а б'), isTrue);
      expect(isQueryLongEnough('аб'), isTrue);
      expect(searchNotes([SearchNote('2026-10-01', 'а')], 'а', {}), isEmpty);
    });
  });

  group('поиск в тексте', () {
    test('без учёта регистра и ё/е', () {
      const text = 'Купить ЁЛКУ\nи Ёжика';
      final h = findInText(text, queryWords('елку'), {})!;
      expect(text.substring(h.first.start, h.first.end), 'ЁЛКУ');
      expect(findInText(text, queryWords('ЁЖИК'), {}), isNotNull);
    });

    test('несколько слов — И: каждое должно встретиться', () {
      const text = 'Позвонить Вове\nобсудить релиз';
      expect(findInText(text, queryWords('вове релиз'), {}), isNotNull);
      expect(findInText(text, queryWords('вове отпуск'), {}), isNull);
      final h = findInText(text, queryWords('релиз вове'), {})!;
      expect(h.count, 2);
      expect(h.lines.length, 2);
    });

    test('позиции совпадений указывают на исходный текст', () {
      const text = 'Задачи на день:\nСделать ЁЛКУ\n\uFFFC\nещё раз ёлку и елку';
      final h = findInText(text, queryWords('Елку'), kBoiler)!;
      expect(h.count, 3);
      for (final l in h.lines) {
        for (final r in l.ranges) {
          final abs = text.substring(l.offset + r.start, l.offset + r.end);
          expect(normalizeForSearch(abs), 'елку');
          expect(l.line.substring(r.start, r.end), abs);
        }
      }
      expect(text.substring(h.first.start, h.first.end), 'ЁЛКУ');
    });

    test('строки шаблона не ищутся, изменённые — ищутся', () {
      const untouched = 'Задачи на день:\n\nСДК дейли:\nготово\n';
      expect(findInText(untouched, queryWords('СДК'), kBoiler), isNull);
      expect(findInText(untouched, queryWords('день'), kBoiler), isNull);

      const edited = 'Задачи на день:\nСДК дейли: созвон перенесли\n';
      final h = findInText(edited, queryWords('СДК'), kBoiler)!;
      expect(h.lines.single.line, 'СДК дейли: созвон перенесли');
    });

    test('строка шаблона с пробелами по краям тоже пропускается', () {
      const text = '  Новые автоответчики от МТС?  \nМТС прислали ответ';
      final h = findInText(text, queryWords('мтс'), kBoiler)!;
      expect(h.count, 1);
      expect(h.lines.single.line, 'МТС прислали ответ');
    });

    test('символ вставки \\uFFFC не мешает и не ищется', () {
      const text = '\uFFFC\nпосле\uFFFCразделителя';
      final h = findInText(text, queryWords('после'), {})!;
      expect(h.first, const TextRange2(2, 7));
      expect(findInText(text, ['\uFFFC'], {}), isNull);
    });

    test('пересекающиеся слова сливаются в один диапазон', () {
      final h = findInText('абвгд', queryWords('абв вгд'), {})!;
      expect(h.lines.single.ranges, [const TextRange2(0, 5)]);
      expect(h.count, 2);
    });
  });

  group('фрагмент', () {
    test('короткая строка целиком, все вхождения подсвечены', () {
      final h = findInText('Кот и котик, КОТ', queryWords('кот'), {})!;
      final s = buildSnippet(h.lines.first);
      expect(s.text, 'Кот и котик, КОТ');
      expect(marked(s.text, s.highlights), ['Кот', 'кот', 'КОТ']);
      expect(h.count, 3);
    });

    test('длинная строка обрезается по словам с «…»', () {
      final before = List.generate(20, (i) => 'слово$i').join(' ');
      final after = List.generate(40, (i) => 'хвост$i').join(' ');
      final line = '$before НАЙТИ $after';
      final h = findInText(line, queryWords('найти'), {})!;
      final s = buildSnippet(h.lines.first);
      expect(s.text.startsWith('…'), isTrue);
      expect(s.text.endsWith('…'), isTrue);
      expect(s.text.length, lessThan(line.length));
      // обрезано по границам слов
      final inner = s.text.substring(1, s.text.length - 1);
      expect(inner.startsWith('слово'), isTrue);
      expect(inner.endsWith(' '), isFalse);
      expect(RegExp(r'хвост\d+$').hasMatch(inner), isTrue);
      expect(marked(s.text, s.highlights), ['НАЙТИ']);
      // около 40 символов до и около 100 после
      final at = s.text.indexOf('НАЙТИ');
      expect(at, inInclusiveRange(30, 42));
      expect(s.text.length - at, inInclusiveRange(80, 103));
    });

    test('подсвечиваются все слова запроса в фрагменте', () {
      final h =
          findInText('надо позвонить Вове про релиз', queryWords('вове релиз'), {})!;
      final s = buildSnippet(h.lines.first);
      expect(marked(s.text, s.highlights), ['Вове', 'релиз']);
    });
  });

  group('склонения', () {
    test('1, 2, 5, 11, 21, 22, 25', () {
      expect(pluralMatches(1), '1 совпадение');
      expect(pluralMatches(2), '2 совпадения');
      expect(pluralMatches(5), '5 совпадений');
      expect(pluralMatches(11), '11 совпадений');
      expect(pluralMatches(21), '21 совпадение');
      expect(pluralMatches(22), '22 совпадения');
      expect(pluralMatches(25), '25 совпадений');
      expect(pluralMatches(12), '12 совпадений');
      expect(pluralMatches(111), '111 совпадений');
    });
  });

  group('поиск по заметкам', () {
    test('слово на трёх днях — ровно эти три, новые сверху', () {
      final notes = [
        SearchNote('2026-10-02', 'Встреча с ДИЗАЙНЕРОМ'),
        SearchNote('2026-10-05', 'ничего'),
        SearchNote('2026-11-01', 'дизайнер прислал макет'),
        SearchNote('2026-10-20', 'дизайнеру — правки'),
      ];
      final res = searchNotes(notes, 'дизайнер', kBoiler);
      expect(res.map((r) => r.key), ['2026-11-01', '2026-10-20', '2026-10-02']);
    });

    test('заголовок шаблона сам по себе не находит нетронутые дни', () {
      final notes = [
        SearchNote('2026-10-01', 'Задачи на день:\n\nСДК дейли:\n\n'),
        SearchNote('2026-10-02', 'СДК дейли:\nпочинили СДК'),
      ];
      final res = searchNotes(notes, 'СДК', kBoiler);
      expect(res.map((r) => r.key), ['2026-10-02']);
    });

    test('строки шаблонов собираются из самих шаблонов', () {
      for (final s in [
        'Задачи на день:',
        'АИ дейли:',
        'СДК дейли:',
        'Девопс дейли:',
        'Фронт викли:',
        'Фронт дейли:',
        'Ксюша викли:',
        'Юля викли:',
        'Сайт викли:',
        'Лиза викли:',
        'Вадим викли:',
        'Новые автоответчики от МТС?',
        'вернёмся к action items с ретры последней ретры',
        'Вова ревью',
        'подготовиться к завтрашнему сайт викли',
        'вечером в 16 кофе',
        'ОТЧЁТ ПО САЙТУ',
        kNotForgetTitle,
        kMonthlyReport,
        kHolidayNote,
      ]) {
        expect(kTemplateLines, contains(s));
      }
      expect(kTemplateLines.any((l) => l.trim().isEmpty), isFalse);
      expect(kTemplateLines.any((l) => l.contains('\uFFFC')), isFalse);
    });

    test('нормализованный текст запоминается', () {
      final n = SearchNote('2026-10-01', 'ЁЖ');
      expect(identical(n.normalized, n.normalized), isTrue);
    });
  });
}
