import 'package:calendar_notes/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:table_calendar/table_calendar.dart';

final today = DateTime(2026, 11, 8);

/// Календарь как в приложении: тот же стиль, та же логика отмеченного дня
/// и та же ячейка
Widget calendar({
  required DateTime selected,
  required bool topicOpen,
  DateTime? focused,
}) {
  return MaterialApp(
    home: Scaffold(
      body: TableCalendar(
        firstDay: DateTime(2020),
        lastDay: DateTime(2030),
        focusedDay: focused ?? today,
        currentDay: today,
        startingDayOfWeek: StartingDayOfWeek.monday,
        selectedDayPredicate: (d) => isSameDay(
            calendarHighlightDay(
                selected: selected, topicOpen: topicOpen, now: today),
            d),
        calendarStyle: kCalendarStyle,
        calendarBuilders: CalendarBuilders(
          selectedBuilder:
              selectedDayBuilder(topicOpen: topicOpen, now: () => today),
        ),
      ),
    ),
  );
}

/// Стиль номера дня [n] в текущем месяце
TextStyle? styleOf(WidgetTester tester, int n) {
  final texts = tester.widgetList<Text>(find.text('$n')).toList();
  expect(texts.length, 1, reason: 'день $n — одна ячейка');
  return texts.single.style;
}

Finder mutedCell(int n) => find.ancestor(
    of: find.text('$n'), matching: find.byType(MutedSelectedDay));

void main() {
  group('какой день отмечен', () {
    test('открыт день — он сам; открыта тема — сегодняшний', () {
      final sel = DateTime(2026, 11, 12);
      expect(calendarHighlightDay(selected: sel, topicOpen: false, now: today),
          sel);
      expect(calendarHighlightDay(selected: sel, topicOpen: true, now: today),
          today);
    });
  });

  testWidgets('открыт день — яркое выделение, приглушённого нет',
      (tester) async {
    await tester.pumpWidget(
        calendar(selected: DateTime(2026, 11, 12), topicOpen: false));
    expect(find.byType(MutedSelectedDay), findsNothing);
    expect(styleOf(tester, 12), kCalendarStyle.selectedTextStyle);
    expect(styleOf(tester, 8), kCalendarStyle.todayTextStyle);
  });

  testWidgets('открыта тема — приглушён сегодняшний день, день перехода — '
      'обычный', (tester) async {
    await tester.pumpWidget(
        calendar(selected: DateTime(2026, 11, 12), topicOpen: true));
    expect(find.byType(MutedSelectedDay), findsOneWidget);
    expect(mutedCell(8), findsOneWidget);
    expect(mutedCell(12), findsNothing);
    final box = tester.widget<Container>(
        find.descendant(of: mutedCell(8), matching: find.byType(Container)));
    final deco = box.decoration as BoxDecoration;
    expect(deco.color, kMutedSelection);
    expect(deco.shape, BoxShape.circle);
    expect(deco.color,
        isNot((kCalendarStyle.selectedDecoration as BoxDecoration).color));
    // номер — отметка сегодняшнего дня (сиреневый жирный)
    expect(styleOf(tester, 8), kCalendarStyle.todayTextStyle);
    // день, с которого перешли, и остальные дни — как обычно
    expect(styleOf(tester, 12), kCalendarStyle.defaultTextStyle);
    expect(styleOf(tester, 13), kCalendarStyle.defaultTextStyle);
    expect(styleOf(tester, 14), kCalendarStyle.weekendTextStyle);
  });

  testWidgets('перешли в тему с сегодняшнего дня — тоже сегодняшний',
      (tester) async {
    await tester.pumpWidget(calendar(selected: today, topicOpen: true));
    expect(mutedCell(8), findsOneWidget);
    expect(styleOf(tester, 8), kCalendarStyle.todayTextStyle);
  });

  testWidgets('возврат к дню — снова яркое выделение на нём', (tester) async {
    final sel = DateTime(2026, 11, 12);
    await tester.pumpWidget(calendar(selected: sel, topicOpen: true));
    expect(mutedCell(8), findsOneWidget);
    await tester.pumpWidget(calendar(selected: sel, topicOpen: false));
    await tester.pumpAndSettle();
    expect(find.byType(MutedSelectedDay), findsNothing);
    expect(styleOf(tester, 12), kCalendarStyle.selectedTextStyle);
    expect(styleOf(tester, 8), kCalendarStyle.todayTextStyle);
  });

  testWidgets('переход в тему — сразу приглушённо, без кадра яркого круга',
      (tester) async {
    await tester.pumpWidget(calendar(selected: today, topicOpen: false));
    await tester.pumpWidget(calendar(selected: today, topicOpen: true));
    // первый же кадр после переключения
    expect(mutedCell(8), findsOneWidget);
    expect(
        find.descendant(
            of: mutedCell(8), matching: find.byType(AnimatedContainer)),
        findsNothing);
  });

  testWidgets('другой месяц — заливки нет; вернулись — снова на сегодня',
      (tester) async {
    final sel = DateTime(2026, 11, 12);
    await tester.pumpWidget(calendar(
        selected: sel, topicOpen: true, focused: DateTime(2026, 12, 1)));
    expect(find.byType(MutedSelectedDay), findsNothing);
    await tester.pumpWidget(calendar(selected: sel, topicOpen: true));
    await tester.pumpAndSettle(); // листание месяца
    expect(mutedCell(8), findsOneWidget);
  });
}
