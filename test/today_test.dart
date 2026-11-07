import 'package:calendar_notes/main.dart' show TodayButton;
import 'package:calendar_notes/today.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('localDate', () {
    test('убирает время, дата — по местным часам', () {
      expect(localDate(DateTime(2026, 11, 7, 23, 59, 59)), DateTime(2026, 11, 7));
      expect(localDate(DateTime(2026, 11, 8, 0, 0, 1)), DateTime(2026, 11, 8));
    });

    test('переход через полночь и Новый год', () {
      final before = DateTime(2026, 12, 31, 23, 59);
      final after = before.add(const Duration(minutes: 2));
      expect(localDate(before), DateTime(2026, 12, 31));
      expect(localDate(after), DateTime(2027, 1, 1));
    });
  });

  group('isOnToday', () {
    final now = DateTime(2026, 11, 7, 15, 30);
    bool on({
      DateTime? selected,
      DateTime? focused,
      DateTime? at,
      bool topic = false,
      bool picker = false,
    }) =>
        isOnToday(
          selected: selected ?? DateTime(2026, 11, 7),
          focused: focused ?? DateTime(2026, 11, 1),
          now: at ?? now,
          topicOpen: topic,
          monthPickerOpen: picker,
        );

    test('открыт сегодняшний день и текущий месяц — да', () {
      expect(on(), isTrue);
      // время у выбранного дня не мешает (при старте это DateTime.now())
      expect(on(selected: DateTime(2026, 11, 7, 9, 12)), isTrue);
      // table_calendar отдаёт дни в UTC — это та же дата
      expect(on(selected: DateTime.utc(2026, 11, 7)), isTrue);
    });

    test('выбран другой день — нет', () {
      expect(on(selected: DateTime(2026, 11, 6)), isFalse);
      expect(on(selected: DateTime(2025, 11, 7)), isFalse);
    });

    test('сетка на другом месяце или годе — нет', () {
      expect(on(focused: DateTime(2026, 10, 15)), isFalse);
      expect(on(focused: DateTime(2025, 11, 1)), isFalse);
    });

    test('открыта тема или выбор месяцев — нет', () {
      expect(on(topic: true), isFalse);
      expect(on(picker: true), isFalse);
    });

    test('вкладка открыта через полночь — «сегодня» уже другое', () {
      final nextDay = DateTime(2026, 11, 8, 0, 5);
      expect(on(at: nextDay), isFalse);
      // 31 декабря → 1 января: и день, и месяц, и год другие
      expect(
        on(
          selected: DateTime(2026, 12, 31),
          focused: DateTime(2026, 12, 1),
          at: DateTime(2027, 1, 1, 0, 1),
        ),
        isFalse,
      );
    });
  });

  group('TodayButton', () {
    Future<void> pump(WidgetTester t,
        {required bool subdued, required VoidCallback onPressed, double width = 300}) {
      return t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: TodayButton(subdued: subdued, onPressed: onPressed),
            ),
          ),
        ),
      ));
    }

    testWidgets('нажатие вызывает переход, есть подсказка', (t) async {
      var taps = 0;
      await pump(t, subdued: false, onPressed: () => taps++);
      expect(find.text('Сегодня'), findsOneWidget);
      expect(find.byTooltip('Перейти на сегодня'), findsOneWidget);
      expect(find.bySemanticsLabel('Перейти на сегодня'), findsOneWidget);
      await t.tap(find.text('Сегодня'));
      expect(taps, 1);
    });

    testWidgets('приглушённая — всё равно нажимается', (t) async {
      var taps = 0;
      await pump(t, subdued: true, onPressed: () => taps++);
      await t.tap(find.text('Сегодня'));
      expect(taps, 1);
    });

    testWidgets('узкая колонка — без переполнения', (t) async {
      await pump(t, subdued: false, onPressed: () {}, width: 120);
      expect(t.takeException(), isNull);
    });
  });
}
