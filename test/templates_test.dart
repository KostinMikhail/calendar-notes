import 'dart:convert';

import 'package:calendar_notes/templates.dart';
import 'package:flutter_quill/flutter_quill.dart' show Document;
import 'package:flutter_test/flutter_test.dart';

const String accent = '#B388FF';

/// Простой текст документа из операций
String plain(List<Map<String, dynamic>> ops) =>
    ops.isEmpty ? '' : Document.fromJson(ops).toPlainText();

String delta(List<Map<String, dynamic>> ops) =>
    jsonEncode(Document.fromJson(ops).toDelta().toJson());

/// Шаблон из строк: '---' — разделитель, '* x' — пункт списка
String tpl(List<String> lines) => jsonEncode([
      for (final l in lines)
        if (l == '---') ...[
          {
            'insert': {'divider': 'hr'},
          },
          {'insert': '\n'},
        ] else if (l.startsWith('* ')) ...[
          if (l.length > 2) {'insert': l.substring(2)},
          {
            'insert': '\n',
            'attributes': {'list': 'ordered'},
          },
        ] else ...[
          if (l.isNotEmpty) {'insert': l},
          {'insert': '\n'},
        ],
    ]);

TemplateComposition compose(int weekday, TemplateSettings s,
        {bool vadim = false, bool first = false, bool holiday = false}) =>
    composeTemplate(
      weekday: weekday,
      vadimWeek: vadim,
      firstWorkday: first,
      dayBeforeHoliday: holiday,
      settings: s,
      accent: accent,
    );

void main() {
  group('настройки', () {
    test('в Firestore и обратно', () {
      final s = TemplateSettings(
        weekdays: {1: tpl(['Пн']), 6: kEmptyTemplateDelta},
        blocks: {kBlockHolidayNote: tpl(['* праздник'])},
      );
      final m = s.toMap();
      expect(m['version'], 1);
      expect(m['weekdays'], {'1': tpl(['Пн']), '6': kEmptyTemplateDelta});
      final back = TemplateSettings.fromMap(m);
      expect(back.weekdays, s.weekdays);
      expect(back.blocks, s.blocks);
    });

    test('нет документа / чужая версия — стандартные шаблоны', () {
      expect(TemplateSettings.fromMap(null).isEmpty, isTrue);
      expect(
          TemplateSettings.fromMap({
            'version': 2,
            'weekdays': {'1': tpl(['x'])},
          }).isEmpty,
          isTrue);
    });

    test('испорченные значения пропускаются (будет стандартный шаблон)', () {
      final s = TemplateSettings.fromMap({
        'version': 1,
        'weekdays': {
          '1': 'не json',
          '2': '[]',
          '3': '[{"insert":"без перевода строки"}]',
          '4': 42,
          '5': tpl(['ok']),
          '9': tpl(['лишний день']),
        },
        'blocks': {'unknown': tpl(['x']), kBlockVadimWeek: '{"a":1}'},
      });
      expect(s.weekdays.keys, [5]);
      expect(s.blocks, isEmpty);
    });

    test('проверка перед сохранением', () {
      expect(validateTemplateSettings(const TemplateSettings()), isNull);
      expect(
          validateTemplateSettings(TemplateSettings(weekdays: {1: 'oops'})),
          contains('повреждён'));
      final huge = jsonEncode([
        {'insert': '${'x' * kMaxTemplateDeltaLength}\n'}
      ]);
      expect(validateTemplateSettings(TemplateSettings(weekdays: {1: huge})),
          contains('слишком большой'));
      final big = jsonEncode([
        {'insert': '${'x' * 90000}\n'}
      ]);
      expect(
          validateTemplateSettings(TemplateSettings(
              weekdays: {1: big, 2: big, 3: big, 4: big})),
          contains('в сумме'));
    });
  });

  group('сборка дня', () {
    test('без настроек — стандартный шаблон (как renderSections)', () {
      for (var d = 1; d <= 7; d++) {
        final c = compose(d, TemplateSettings.defaults);
        final expected = renderSections(defaultWeekdaySections(d), accent);
        expect(c.ops.isEmpty, expected.isEmpty);
        if (expected.isNotEmpty) expect(delta(c.ops), delta(expected));
        expect(c.accent, accent);
      }
    });

    test('изменённый шаблон дня недели используется только для своего дня', () {
      final s = TemplateSettings(weekdays: {1: tpl(['Мой понедельник', '* дело'])});
      expect(plain(compose(1, s).ops), 'Мой понедельник\nдело\n');
      expect(plain(compose(2, s).ops),
          plain(compose(2, TemplateSettings.defaults).ops));
    });

    test('пустой шаблон — пустой день, даже в особые дни', () {
      final s = TemplateSettings(weekdays: {3: kEmptyTemplateDelta});
      expect(compose(3, s, first: true, holiday: true).ops, isEmpty);
      // после «выделить всё → удалить» остаётся пустой пункт списка
      final cleared = TemplateSettings(weekdays: {3: tpl(['* '])});
      expect(compose(3, cleared, first: true).ops, isEmpty);
      // а «нет ключа» — это стандартный шаблон
      expect(compose(3, TemplateSettings.defaults).ops, isNotEmpty);
    });

    test('испорченный шаблон — стандартный, без ошибки', () {
      const s = TemplateSettings(weekdays: {4: 'не json'});
      expect(delta(compose(4, s).ops),
          delta(compose(4, TemplateSettings.defaults).ops));
    });

    test('особые блоки встают на прежние места в изменённом шаблоне', () {
      final s = TemplateSettings(weekdays: {
        4: tpl(['Задачи:', '* одно', '* ', '---', 'Встречи:', '* ', '---',
            'Не забыть:', '* кофе'])
      });
      final c = compose(4, s, vadim: true, first: true, holiday: true);
      expect(
          plain(c.ops),
          'Задачи:\nодно\nОтчёт по команде СДК\n\n' // отчёт — перед пустым пунктом
          '\uFFFC\nВстречи:\n\n'
          '\uFFFC\nВадим викли:\n\n' // Вадим — перед последним блоком
          '\uFFFC\nНе забыть:\nзавтра выходной, не забудь всем рассказать\nкофе\n');
    });

    test('нет пустого пункта — отчёт в конец первого блока', () {
      final s = TemplateSettings(weekdays: {1: tpl(['Задачи:', '* одно'])});
      expect(plain(compose(1, s, first: true).ops),
          'Задачи:\nодно\nОтчёт по команде СДК\n');
    });

    test('тексты особых блоков настраиваются; пустой блок не вставляется', () {
      final s = TemplateSettings(
        weekdays: {2: tpl(['А', '---', 'Б'])},
        blocks: {
          kBlockVadimWeek: kEmptyTemplateDelta,
          kBlockHolidayNote: tpl(['* завтра отдыхаем!']),
        },
      );
      expect(plain(compose(2, s, vadim: true, holiday: true).ops),
          'А\n\uFFFC\nБ\nзавтра отдыхаем!\n');
    });

    test('разделители шаблона сохраняются как есть', () {
      final t = tpl(['---', 'x', '---', '---', 'y', '---']);
      final s = TemplateSettings(weekdays: {5: t});
      expect(delta(compose(5, s).ops),
          jsonEncode(Document.fromJson(jsonDecode(t) as List).toDelta().toJson()));
    });

    test('цвет «Не забыть» берётся из изменённого шаблона', () {
      final t = jsonEncode([
        {
          'insert': 'Не забыть:',
          'attributes': {'color': '#FF9F43'},
        },
        {'insert': '\n'},
      ]);
      final c = compose(1, TemplateSettings(weekdays: {1: t}), holiday: true);
      expect(c.accent, '#FF9F43');
      // стандартное напоминание окрашено тем же цветом
      final ops = Document.fromJson(c.ops).toDelta().toJson();
      expect(ops.any((o) =>
          o['insert'] == kHolidayNote &&
          (o['attributes'] as Map?)?['color'] == '#FF9F43'), isTrue);
    });

    test('стандартный текст для редактора настроек', () {
      expect(defaultTemplateJson(weekday: 6, accent: accent), kEmptyTemplateDelta);
      final mon = jsonDecode(defaultTemplateJson(weekday: 1, accent: accent));
      expect(Document.fromJson(mon as List).toPlainText(), startsWith('Задачи на день:'));
      final rep = defaultTemplateJson(block: kBlockMonthlyReport, accent: accent);
      expect(Document.fromJson(jsonDecode(rep) as List).toPlainText(),
          'Отчёт по команде СДК\n');
    });
  });
}
