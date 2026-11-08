import 'package:calendar_notes/format_menu.dart';
import 'package:calendar_notes/main.dart' show kGreen, kRed, kYellow;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

QuillController ctl(List<Map<String, dynamic>> ops) => QuillController(
      document: Document.fromJson(ops),
      selection: const TextSelection.collapsed(offset: 0),
    );

void select(QuillController c, int a, int b) => c.updateSelection(
    TextSelection(baseOffset: a, extentOffset: b), ChangeSource.local);

class MemStore implements PrefStore {
  final Map<String, String> data = {};
  bool throws = false;

  @override
  String? read(String key) {
    if (throws) throw StateError('storage blocked');
    return data[key];
  }

  @override
  void write(String key, String value) {
    if (throws) throw StateError('storage blocked');
    data[key] = value;
  }
}

void main() {
  group('placeFormatMenu', () {
    const viewport = Rect.fromLTWH(100, 100, 600, 400);
    const menu = Size(110, 42);

    test('над выделением, по центру', () {
      final p = placeFormatMenu(
          anchor: const Rect.fromLTWH(300, 300, 100, 20),
          menu: menu,
          viewport: viewport)!;
      expect(p.dx, 350 - 55);
      expect(p.dy, 300 - 8 - 42);
    });

    test('сверху нет места — под выделением', () {
      final p = placeFormatMenu(
          anchor: const Rect.fromLTWH(300, 110, 100, 20),
          menu: menu,
          viewport: viewport)!;
      expect(p.dy, 130 + 8);
    });

    test('прижимается к левому и правому краю', () {
      final left = placeFormatMenu(
          anchor: const Rect.fromLTWH(100, 300, 10, 20),
          menu: menu,
          viewport: viewport)!;
      expect(left.dx, 104);
      final right = placeFormatMenu(
          anchor: const Rect.fromLTWH(690, 300, 10, 20),
          menu: menu,
          viewport: viewport)!;
      expect(right.dx, 700 - 4 - 110);
    });

    test('крошечное выделение (одна буква) — над ним', () {
      final p = placeFormatMenu(
          anchor: const Rect.fromLTWH(400, 300, 1, 18),
          menu: menu,
          viewport: viewport)!;
      expect(p.dx, closeTo(400.5 - 55, 0.001));
      expect(p.dy, 300 - 50);
    });

    test('огромное выделение больше области — по видимой части', () {
      final p = placeFormatMenu(
          anchor: const Rect.fromLTWH(100, 0, 600, 2000),
          menu: menu,
          viewport: viewport)!;
      // сверху места нет (выделение начинается выше области), снизу тоже —
      // у верхнего края видимой области
      expect(p.dy, 100);
      expect(p.dx, 400 - 55);
    });

    test('выделение частично выше области — по видимой части, под ней', () {
      final p = placeFormatMenu(
          anchor: const Rect.fromLTWH(300, 50, 100, 80),
          menu: menu,
          viewport: viewport)!;
      expect(p.dy, 130 + 8);
    });

    test('выделение целиком вне видимой области — меню нет', () {
      expect(
          placeFormatMenu(
              anchor: const Rect.fromLTWH(300, 20, 100, 20),
              menu: menu,
              viewport: viewport),
          isNull);
      expect(
          placeFormatMenu(
              anchor: const Rect.fromLTWH(300, 600, 100, 20),
              menu: menu,
              viewport: viewport),
          isNull);
    });

    test('меню шире области — у левого края', () {
      final p = placeFormatMenu(
          anchor: const Rect.fromLTWH(120, 300, 10, 20),
          menu: const Size(700, 42),
          viewport: viewport)!;
      expect(p.dx, 100);
    });
  });

  group('форматы выделения', () {
    test('жирный: весь — активен, смешанный — нет, пустой — нет', () {
      final c = ctl([
        {'insert': 'жир', 'attributes': {'bold': true}},
        {'insert': 'ный\n'},
      ]);
      select(c, 0, 3);
      expect(selectionHasFormat(c, Attribute.bold), isTrue);
      select(c, 0, 6);
      expect(selectionHasFormat(c, Attribute.bold), isFalse);
      select(c, 4, 6);
      expect(selectionHasFormat(c, Attribute.bold), isFalse);
    });

    test('переключение: снять, смешанное — поставить всему', () {
      final c = ctl([
        {'insert': 'жир', 'attributes': {'bold': true}},
        {'insert': 'ный\n'},
      ]);
      select(c, 0, 6);
      toggleSelectionFormat(c, Attribute.bold); // смешанное → всем
      expect(c.document.toDelta().toJson().first,
          {'insert': 'жирный', 'attributes': {'bold': true}});
      toggleSelectionFormat(c, Attribute.bold); // всё жирное → снять
      expect(c.document.toDelta().toJson(), [
        {'insert': 'жирный\n'}
      ]);
      expect(c.selection, const TextSelection(baseOffset: 0, extentOffset: 6));
    });

    test('зачёркивание', () {
      final c = ctl([
        {'insert': 'текст\n'}
      ]);
      select(c, 0, 5);
      toggleSelectionFormat(c, Attribute.strikeThrough);
      expect(selectionHasFormat(c, Attribute.strikeThrough), isTrue);
      toggleSelectionFormat(c, Attribute.strikeThrough);
      expect(selectionHasFormat(c, Attribute.strikeThrough), isFalse);
    });

    test('цвет: те же цвета, что в панели; повтор — снять; «без цвета»', () {
      final c = ctl([
        {'insert': 'текст\n'}
      ]);
      select(c, 0, 5);
      expect(selectionColor(c), isNull);
      for (final hex in [kRed, kYellow, kGreen]) {
        applySelectionColor(c, hex);
        expect(selectionColor(c), hex);
      }
      applySelectionColor(c, kGreen); // тот же — снимает (как кружок в панели)
      expect(selectionColor(c), isNull);
      applySelectionColor(c, kRed);
      applySelectionColor(c, null);
      expect(selectionColor(c), isNull);
      expect(c.document.toDelta().toJson(), [
        {'insert': 'текст\n'}
      ]);
    });

    test('цвет: смешанное выделение — нет цвета, применение — всему', () {
      final c = ctl([
        {'insert': 'крас', 'attributes': {'color': kRed}},
        {'insert': 'ный\n'},
      ]);
      select(c, 0, 7);
      expect(selectionColor(c), isNull);
      applySelectionColor(c, kYellow);
      select(c, 0, 7);
      expect(selectionColor(c), kYellow);
    });
  });

  group('видимость панели форматирования', () {
    test('по умолчанию скрыта', () {
      expect(ToolbarVisibilityPref(MemStore()).load(), isFalse);
    });

    test('запоминается: показана / скрыта', () {
      final s = MemStore();
      final pref = ToolbarVisibilityPref(s);
      pref.save(true);
      expect(ToolbarVisibilityPref(s).load(), isTrue);
      pref.save(false);
      expect(ToolbarVisibilityPref(s).load(), isFalse);
    });

    test('хранилище с ошибкой — скрыта, ничего не падает', () {
      final s = MemStore()..throws = true;
      final pref = ToolbarVisibilityPref(s);
      expect(pref.load(), isFalse);
      pref.save(true); // не бросает
    });

    test('мусор в хранилище — скрыта', () {
      final s = MemStore()
        ..data[ToolbarVisibilityPref.storageKey] = 'yes please';
      expect(ToolbarVisibilityPref(s).load(), isFalse);
    });
  });

  group('кнопка и панель', () {
    testWidgets('кнопка в шапке показывает и прячет панель', (tester) async {
      var visible = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                ToolbarToggleButton(
                  visible: visible,
                  onPressed: () => setState(() => visible = !visible),
                ),
                CollapsibleToolbar(
                  visible: visible,
                  child: const Text('ПАНЕЛЬ'),
                ),
              ],
            ),
          ),
        ),
      ));
      expect(find.text('ПАНЕЛЬ'), findsNothing);
      expect(find.byTooltip('Показать панель форматирования'), findsOneWidget);
      await tester.tap(find.byType(ToolbarToggleButton));
      await tester.pumpAndSettle();
      expect(find.text('ПАНЕЛЬ'), findsOneWidget);
      expect(find.byTooltip('Скрыть панель форматирования'), findsOneWidget);
      await tester.tap(find.byType(ToolbarToggleButton));
      await tester.pumpAndSettle();
      expect(find.text('ПАНЕЛЬ'), findsNothing);
    });
  });

  group('плавающее меню', () {
    late QuillController c;
    late FocusNode focus;
    late GlobalKey<EditorState> key;

    Future<void> pumpEditor(WidgetTester tester) async {
      c = ctl([
        {'insert': 'первое слово\nвторая строка\n'}
      ]);
      focus = FocusNode();
      key = GlobalKey<EditorState>();
      final scroll = ScrollController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.only(top: 120),
            child: SizedBox(
              width: 600,
              height: 300,
              child: FormatMenuHost(
                controller: c,
                focusNode: focus,
                editorKey: key,
                scrollController: scroll,
                child: QuillEditor(
                  controller: c,
                  focusNode: focus,
                  scrollController: scroll,
                  config: QuillEditorConfig(editorKey: key, expands: true),
                ),
              ),
            ),
          ),
        ),
      ));
      focus.requestFocus();
      await tester.pump();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
    }

    testWidgets('выделение — меню над ним; выделение снято — меню нет',
        (tester) async {
      await pumpEditor(tester);
      select(c, 7, 12); // «слово»
      await settle(tester);
      expect(find.byTooltip('Жирный'), findsOneWidget);
      expect(find.byTooltip('Зачёркнутый (Ctrl+Shift+X)'), findsOneWidget);
      // цвета — сразу в меню, без отдельной кнопки и «без цвета»
      expect(find.byTooltip('Красный'), findsOneWidget);
      expect(find.byTooltip('Жёлтый'), findsOneWidget);
      expect(find.byTooltip('Зелёный'), findsOneWidget);
      expect(find.byTooltip('Цвет текста'), findsNothing);
      expect(find.byTooltip('Без цвета'), findsNothing);
      // первая строка: сверху в редакторе места нет — меню под выделением
      final menuTop = tester.getTopLeft(find.byTooltip('Жирный')).dy;
      expect(menuTop, greaterThan(120 + 10));

      // строка ниже — меню над ней
      c.replaceText(0, 0, '\n\n\n\n\n', const TextSelection.collapsed(offset: 0));
      await tester.pump(); // разметка нового текста
      select(c, 12, 17);
      await settle(tester);
      final selTop = tester.getTopLeft(find.byType(QuillEditor)).dy;
      final above = tester.getBottomLeft(find.byTooltip('Жирный')).dy;
      expect(above, greaterThan(selTop));
      expect(above, lessThan(selTop + 5 * 30)); // выше пятой строки

      c.updateSelection(
          const TextSelection.collapsed(offset: 3), ChangeSource.local);
      await settle(tester);
      expect(find.byTooltip('Жирный'), findsNothing);
    });

    testWidgets('кнопки форматируют, фокус и выделение остаются',
        (tester) async {
      await pumpEditor(tester);
      select(c, 7, 12);
      await settle(tester);
      await tester.tap(find.byTooltip('Жирный'));
      await settle(tester);
      expect(selectionHasFormat(c, Attribute.bold), isTrue);
      expect(c.selection, const TextSelection(baseOffset: 7, extentOffset: 12));
      expect(focus.hasFocus, isTrue);
      expect(find.byTooltip('Жирный'), findsOneWidget); // меню на месте

      await tester.tap(find.byTooltip('Зачёркнутый (Ctrl+Shift+X)'));
      await settle(tester);
      expect(selectionHasFormat(c, Attribute.strikeThrough), isTrue);

      // цвет — одним нажатием
      await tester.tap(find.byTooltip('Зелёный'));
      await settle(tester);
      expect(selectionColor(c), kGreen);
      expect(focus.hasFocus, isTrue);
      expect(c.selection, const TextSelection(baseOffset: 7, extentOffset: 12));
      expect(find.byTooltip('Жирный'), findsOneWidget); // меню на месте

      // другой цвет — заменяет
      await tester.tap(find.byTooltip('Красный'));
      await settle(tester);
      expect(selectionColor(c), kRed);

      // нажатие на уже выбранный цвет — обычный цвет текста
      await tester.tap(find.byTooltip(
          'Красный — нажмите ещё раз, чтобы убрать цвет'));
      await settle(tester);
      expect(selectionColor(c), isNull);
      expect(find.byTooltip('Красный'), findsOneWidget);
      // жирный и зачёркнутый остались
      expect(selectionHasFormat(c, Attribute.bold), isTrue);
      expect(selectionHasFormat(c, Attribute.strikeThrough), isTrue);
    });

    testWidgets('ввод текста прячет меню', (tester) async {
      await pumpEditor(tester);
      select(c, 7, 12);
      await settle(tester);
      expect(find.byTooltip('Жирный'), findsOneWidget);
      c.replaceText(7, 5, 'x', const TextSelection.collapsed(offset: 8));
      await tester.pump();
      expect(find.byTooltip('Жирный'), findsNothing);
      await settle(tester);
      expect(find.byTooltip('Жирный'), findsNothing);
    });

    testWidgets('без фокуса меню нет', (tester) async {
      await pumpEditor(tester);
      select(c, 7, 12);
      await settle(tester);
      focus.unfocus();
      await settle(tester);
      expect(find.byTooltip('Жирный'), findsNothing);
    });

    testWidgets('редактор убран со страницы — меню не остаётся',
        (tester) async {
      await pumpEditor(tester);
      select(c, 7, 12);
      await settle(tester);
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await settle(tester);
      expect(find.byTooltip('Жирный'), findsNothing);
    });
  });
}
