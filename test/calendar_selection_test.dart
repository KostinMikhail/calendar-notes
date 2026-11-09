import 'package:calendar_notes/main.dart';
import 'package:calendar_notes/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:table_calendar/table_calendar.dart';

final today = DateTime(2026, 11, 8);

/// Календарь как в приложении: тот же стиль, та же логика отмеченного дня
/// и те же ячейки
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
        pageAnimationDuration: Motion.calendarPage,
        selectedDayPredicate: (d) => isSameDay(
            calendarHighlightDay(
                selected: selected, topicOpen: topicOpen, now: today),
            d),
        calendarStyle: kCalendarStyle,
        calendarBuilders:
            dayCellBuilders(topicOpen: topicOpen, now: () => today),
      ),
    ),
  );
}

/// Ячейка дня [n] текущего месяца
DayCell cell(WidgetTester tester, int n) {
  final f = find.ancestor(of: find.text('$n'), matching: find.byType(DayCell));
  expect(f, findsOneWidget, reason: 'день $n — одна ячейка');
  return tester.widget<DayCell>(f);
}

/// Цвет круга, который сейчас нарисован (с учётом анимации)
Color? circleNow(WidgetTester tester, int n) {
  final f = find.descendant(
      of: find.ancestor(of: find.text('$n'), matching: find.byType(DayCell)),
      matching: find.byType(DecoratedBox));
  final box = tester.renderObject<RenderDecoratedBox>(f.first);
  return (box.decoration as BoxDecoration).color;
}

/// Цвет номера, который сейчас нарисован
Color? textNow(WidgetTester tester, int n) =>
    tester.renderObject<RenderParagraph>(find.text('$n')).text.style?.color;

void main() {
  tearDown(() => motion.reset());

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
    await tester.pumpAndSettle();
    expect(cell(tester, 12).mark, DayMark.bright);
    expect(cell(tester, 8).mark, DayMark.none);
    expect(cell(tester, 8).isToday, isTrue);
    expect(circleNow(tester, 12), kAccent);
    expect(textNow(tester, 12), kCalendarStyle.selectedTextStyle.color);
    expect(textNow(tester, 8), kCalendarStyle.todayTextStyle.color);
    expect(find.byWidgetPredicate((w) => w is DayCell && w.mark == DayMark.muted),
        findsNothing);
  });

  testWidgets('открыта тема — приглушён сегодняшний день, день перехода — '
      'обычный', (tester) async {
    await tester.pumpWidget(
        calendar(selected: DateTime(2026, 11, 12), topicOpen: true));
    await tester.pumpAndSettle();
    expect(cell(tester, 8).mark, DayMark.muted);
    expect(cell(tester, 12).mark, DayMark.none);
    expect(circleNow(tester, 8), kMutedSelection);
    expect(kMutedSelection,
        isNot((kCalendarStyle.selectedDecoration as BoxDecoration).color));
    // номер — отметка сегодняшнего дня (сиреневый жирный)
    expect(textNow(tester, 8), kCalendarStyle.todayTextStyle.color);
    // день, с которого перешли, и остальные дни — как обычно
    expect(circleNow(tester, 12)!.a, 0);
    expect(textNow(tester, 12), kCalendarStyle.defaultTextStyle.color);
    expect(textNow(tester, 13), kCalendarStyle.defaultTextStyle.color);
    expect(textNow(tester, 14), kCalendarStyle.weekendTextStyle.color);
  });

  testWidgets('перешли в тему с сегодняшнего дня — тоже сегодняшний',
      (tester) async {
    await tester.pumpWidget(calendar(selected: today, topicOpen: true));
    await tester.pumpAndSettle();
    expect(cell(tester, 8).mark, DayMark.muted);
    expect(textNow(tester, 8), kCalendarStyle.todayTextStyle.color);
  });

  testWidgets('возврат к дню — снова яркое выделение на нём', (tester) async {
    final sel = DateTime(2026, 11, 12);
    await tester.pumpWidget(calendar(selected: sel, topicOpen: true));
    await tester.pumpAndSettle();
    expect(cell(tester, 8).mark, DayMark.muted);
    await tester.pumpWidget(calendar(selected: sel, topicOpen: false));
    await tester.pumpAndSettle();
    expect(cell(tester, 12).mark, DayMark.bright);
    expect(cell(tester, 8).mark, DayMark.none);
    expect(circleNow(tester, 12), kAccent);
    expect(circleNow(tester, 8)!.a, 0);
    expect(textNow(tester, 8), kCalendarStyle.todayTextStyle.color);
  });

  testWidgets('смена выбранного дня — круг плавно гаснет и появляется, '
      'ячейки не пересоздаются', (tester) async {
    await tester.pumpWidget(
        calendar(selected: DateTime(2026, 11, 12), topicOpen: false));
    await tester.pumpAndSettle();
    final state12 = tester.state(find.ancestor(
        of: find.text('12'), matching: find.byType(DayCell)));
    await tester.pumpWidget(
        calendar(selected: DateTime(2026, 11, 20), topicOpen: false));
    await tester.pump(Motion.fastBase ~/ 2);
    // середина: старый ещё не погас, новый ещё не яркий
    expect(circleNow(tester, 12)!.a, inExclusiveRange(0, 1));
    expect(circleNow(tester, 20)!.a, inExclusiveRange(0, 1));
    expect(
        tester.state(find.ancestor(
            of: find.text('12'), matching: find.byType(DayCell))),
        same(state12));
    await tester.pump(Motion.fastBase);
    expect(circleNow(tester, 12)!.a, 0);
    expect(circleNow(tester, 20), kAccent);
  });

  testWidgets('переход в тему — яркое плавно переходит в приглушённое',
      (tester) async {
    await tester.pumpWidget(calendar(selected: today, topicOpen: false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(calendar(selected: today, topicOpen: true));
    await tester.pump(Motion.fastBase ~/ 2);
    final mid = circleNow(tester, 8)!;
    expect(mid, isNot(kAccent));
    expect(mid, isNot(kMutedSelection));
    await tester.pump(Motion.fastBase);
    expect(circleNow(tester, 8), kMutedSelection);
  });

  testWidgets('уменьшенные анимации — приглушённо с первого же кадра',
      (tester) async {
    motion.reset(userChoice: true);
    await tester.pumpWidget(calendar(selected: today, topicOpen: false));
    await tester.pump();
    expect(circleNow(tester, 8), kAccent);
    await tester.pumpWidget(calendar(selected: today, topicOpen: true));
    await tester.pump();
    expect(circleNow(tester, 8), kMutedSelection);
    expect(textNow(tester, 8), kCalendarStyle.todayTextStyle.color);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('наведение — лёгкая подсветка, ушли — гаснет', (tester) async {
    await tester.pumpWidget(
        calendar(selected: DateTime(2026, 11, 12), topicOpen: false));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('18')));
    await tester.pumpAndSettle();
    expect(circleNow(tester, 18)!.a, greaterThan(0));
    expect(circleNow(tester, 18)!.a, lessThan(0.2));
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(circleNow(tester, 18)!.a, 0);
  });

  testWidgets('другой месяц — заливки нет; вернулись — снова на сегодня',
      (tester) async {
    final sel = DateTime(2026, 11, 12);
    await tester.pumpWidget(calendar(
        selected: sel, topicOpen: true, focused: DateTime(2026, 12, 1)));
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is DayCell && w.mark == DayMark.muted),
        findsNothing);
    await tester.pumpWidget(calendar(selected: sel, topicOpen: true));
    await tester.pumpAndSettle(); // листание месяца
    expect(cell(tester, 8).mark, DayMark.muted);
  });
}
