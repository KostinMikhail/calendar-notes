import 'package:calendar_notes/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:table_calendar/table_calendar.dart';

final today = DateTime(2026, 11, 8);

/// Календарь как в приложении: тот же стиль и та же ячейка выбранного дня
Widget calendar({
  required DateTime? selected,
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
        selectedDayPredicate: (d) => selected != null && isSameDay(selected, d),
        calendarStyle: kCalendarStyle,
        calendarBuilders: CalendarBuilders(
          selectedBuilder:
              selectedDayBuilder(topicOpen: topicOpen, now: () => today),
        ),
      ),
    ),
  );
}

/// Стиль номера дня [n] в текущем месяце (не «чужие» дни по краям)
TextStyle? styleOf(WidgetTester tester, int n) {
  final texts = tester.widgetList<Text>(find.text('$n')).toList();
  // «8» встречается один раз в ноябре; у дней вроде 1/30 могут быть
  // соседние месяцы — в тестах берём однозначные числа
  expect(texts.length, 1, reason: 'день $n — одна ячейка');
  return texts.single.style;
}

Finder mutedCell(int n) => find.ancestor(
    of: find.text('$n'), matching: find.byType(MutedSelectedDay));

void main() {
  testWidgets('открыт день — яркое выделение, приглушённого нет',
      (tester) async {
    await tester.pumpWidget(
        calendar(selected: DateTime(2026, 11, 12), topicOpen: false));
    expect(find.byType(MutedSelectedDay), findsNothing);
    expect(styleOf(tester, 12), kCalendarStyle.selectedTextStyle);
  });

  testWidgets('открыта тема — тот же день приглушённой заливкой', (tester) async {
    await tester.pumpWidget(
        calendar(selected: DateTime(2026, 11, 12), topicOpen: true));
    expect(find.byType(MutedSelectedDay), findsOneWidget);
    expect(mutedCell(12), findsOneWidget);
    final box = tester.widget<Container>(find.descendant(
        of: mutedCell(12), matching: find.byType(Container)));
    final deco = box.decoration as BoxDecoration;
    expect(deco.color, kMutedSelection);
    expect(deco.shape, BoxShape.circle);
    // отличается и от яркого выделения, и от обычного дня
    expect(deco.color,
        isNot((kCalendarStyle.selectedDecoration as BoxDecoration).color));
    expect(styleOf(tester, 12)!.color, kTextPrimary);
    // другие дни не тронуты
    expect(styleOf(tester, 13), kCalendarStyle.defaultTextStyle);
    expect(styleOf(tester, 14), kCalendarStyle.weekendTextStyle);
  });

  testWidgets('сегодняшняя отметка не меняется (тема открыта и нет)',
      (tester) async {
    for (final topicOpen in [false, true]) {
      await tester.pumpWidget(
          calendar(selected: DateTime(2026, 11, 12), topicOpen: topicOpen));
      expect(styleOf(tester, 8), kCalendarStyle.todayTextStyle);
      expect(mutedCell(8), findsNothing);
    }
  });

  testWidgets('выбранный день — сегодня, открыта тема: заливка + отметка дня',
      (tester) async {
    await tester.pumpWidget(calendar(selected: today, topicOpen: true));
    expect(mutedCell(8), findsOneWidget);
    expect(styleOf(tester, 8), kCalendarStyle.todayTextStyle);
  });

  testWidgets('выбранного дня нет — ничего приглушённого', (tester) async {
    await tester.pumpWidget(calendar(selected: null, topicOpen: true));
    expect(find.byType(MutedSelectedDay), findsNothing);
  });

  testWidgets('возврат к дню — снова яркое выделение (без анимации из темы)',
      (tester) async {
    await tester.pumpWidget(
        calendar(selected: DateTime(2026, 11, 12), topicOpen: true));
    expect(mutedCell(12), findsOneWidget);
    await tester.pumpWidget(
        calendar(selected: DateTime(2026, 11, 12), topicOpen: false));
    expect(find.byType(MutedSelectedDay), findsNothing);
    expect(styleOf(tester, 12), kCalendarStyle.selectedTextStyle);
  });

  testWidgets('переход в тему — сразу приглушённо, без кадра яркого круга',
      (tester) async {
    await tester.pumpWidget(
        calendar(selected: DateTime(2026, 11, 12), topicOpen: false));
    await tester.pumpWidget(
        calendar(selected: DateTime(2026, 11, 12), topicOpen: true));
    // первый же кадр после переключения
    expect(mutedCell(12), findsOneWidget);
    expect(find.descendant(
            of: mutedCell(12), matching: find.byType(AnimatedContainer)),
        findsNothing);
  });

  testWidgets('другой месяц — заливки нет; вернулись — снова на своём дне',
      (tester) async {
    final sel = DateTime(2026, 11, 12);
    await tester.pumpWidget(
        calendar(selected: sel, topicOpen: true, focused: DateTime(2026, 12, 1)));
    expect(find.byType(MutedSelectedDay), findsNothing);
    await tester.pumpWidget(calendar(selected: sel, topicOpen: true));
    await tester.pumpAndSettle(); // листание месяца
    expect(mutedCell(12), findsOneWidget);
  });
}
