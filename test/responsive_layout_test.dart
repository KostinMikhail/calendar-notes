// Раскладка для узкого окна: заметка на всю страницу, календарь и темы —
// выезжающая панель. Широкое окно — как раньше. Смена ширины не пересоздаёт
// редактор и ничего не сохраняет.
import 'package:calendar_notes/motion.dart';
import 'package:calendar_notes/responsive_layout.dart';
import 'package:calendar_notes/search_dialog.dart';
import 'package:calendar_notes/spell/dictionary_dialog.dart';
import 'package:calendar_notes/spell/personal_dictionary.dart';
import 'package:calendar_notes/topics_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

const _bg = Color(0xFF0E0D13);
const _surface = Color(0xFF17151F);

/// Страница как в приложении: колонка (календарь + темы) и панель заметки
/// с кнопкой у даты, редактором до низа и строкой статуса
class _Page extends StatefulWidget {
  const _Page({required this.controller, required this.focus});
  final QuillController controller;
  final FocusNode focus;
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  bool wideOpen = true;
  bool navOpen = false;
  String opened = 'день 9';
  final status = ValueNotifier<String>('Сохранено ✓');
  final scroll = ScrollController();
  int noteBuilds = 0;

  void pick(String what) {
    setState(() {
      opened = what;
      navOpen = false;
    });
  }

  Widget leftColumn(BuildContext context) => CustomScrollView(
        key: const ValueKey('left-column'),
        slivers: [
          SliverToBoxAdapter(
            child: Container(
              height: 330,
              color: _surface,
              child: Column(
                children: [
                  const SizedBox(height: 120, child: Text('баннер')),
                  TextButton(
                      onPressed: () => pick('день 20'),
                      child: const Text('20')),
                  TextButton(
                      onPressed: () => pick('сегодня'),
                      child: const Text('Сегодня')),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 260,
              child: ListView(children: [
                ListTile(
                    title: const Text('Тема А'),
                    onTap: () => pick('тема А')),
              ]),
            ),
          ),
        ],
      );

  Widget notePanel(BuildContext context, bool narrow) {
    noteBuilds++;
    return Container(
      key: const ValueKey('note-panel'),
      padding: EdgeInsets.all(narrow ? 14 : 20),
      color: _surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            IconButton(
              key: const ValueKey('nav-toggle'),
              tooltip: 'Календарь и темы',
              icon: const Icon(Icons.calendar_today),
              onPressed: () => setState(() {
                if (narrow) {
                  navOpen = !navOpen;
                } else {
                  wideOpen = !wideOpen;
                }
              }),
            ),
            IconButton(icon: const Icon(Icons.search), onPressed: () {}),
            IconButton(icon: const Icon(Icons.text_format), onPressed: () {}),
            Expanded(
              child: Text('$opened — 9 ноября 2026',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            IconButton(icon: const Icon(Icons.menu), onPressed: () {}),
          ]),
          const SizedBox(height: 10),
          Expanded(
            child: QuillEditor(
              controller: widget.controller,
              focusNode: widget.focus,
              scrollController: scroll,
              config: const QuillEditorConfig(expands: true),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (_, s, _) => Text(s, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: ResponsiveShell(
            leftColumn: leftColumn,
            notePanel: notePanel,
            wideColumnOpen: wideOpen,
            overlayOpen: navOpen,
            onCloseOverlay: () {
              if (navOpen) setState(() => navOpen = false);
            },
            scrimColor: _bg.withValues(alpha: 0.72),
            overlayColor: _bg,
            overlayBorderColor: _surface,
          ),
        ),
      );
}

Future<void> _size(WidgetTester t, double w, double h) async {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = 1;
  await t.pump();
  await t.pump(const Duration(seconds: 1));
}

QuillController _controller() =>
    QuillController.basic()..document = (Document()..insert(0, 'Мой текст заметки'));

Future<_PageState> _pump(WidgetTester t, QuillController c, FocusNode f,
    {double w = 1400, double h = 900}) async {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    localizationsDelegates: const [FlutterQuillLocalizations.delegate],
    home: _Page(controller: c, focus: f),
  ));
  await t.pump(const Duration(seconds: 1));
  return t.state<_PageState>(find.byType(_Page));
}

final _leftColumn = find.byKey(const ValueKey('left-column'));
final _overlayPanel = find.byKey(const ValueKey('side-overlay-panel'));
final _scrim = find.byKey(const ValueKey('side-overlay-scrim'));
final _notePanel = find.byKey(const ValueKey('note-panel'));

void main() {
  test('порог и размеры', () {
    expect(isNarrowLayout(kNarrowLayoutMaxWidth - 1), isTrue);
    expect(isNarrowLayout(kNarrowLayoutMaxWidth), isFalse);
    // при открытой колонке заметке остаётся не меньше 360
    expect(kNarrowLayoutMaxWidth - 2 * pagePadding(false) - kLeftColumnWidth,
        greaterThanOrEqualTo(360));
    expect(sideOverlayWidth(1000), 320);
    expect(sideOverlayWidth(300), 252);
    expect(sideOverlayWidth(20), 0);
  });

  test('дата в шапке: короткая — без текущего года', () {
    final now = DateTime(2026, 11, 9);
    expect(formatHeaderDate(DateTime(2026, 11, 9), now: now), '9 ноября 2026');
    expect(formatHeaderDate(DateTime(2026, 11, 9), short: true, now: now),
        '9 ноября');
    expect(formatHeaderDate(DateTime(2025, 1, 31), short: true, now: now),
        '31 января 2025');
  });

  group('размеры окна', () {
    for (final s in const [
      Size(1400, 900),
      Size(900, 700),
      Size(720, 800),
      Size(719, 800),
      Size(600, 800),
      Size(559, 800),
      Size(480, 800),
      Size(360, 640),
      Size(320, 568),
      Size(300, 600),
      Size(640, 300),
    ]) {
      testWidgets('${s.width.toInt()}×${s.height.toInt()}', (t) async {
        final c = _controller();
        final f = FocusNode();
        await _pump(t, c, f, w: s.width, h: s.height);
        expect(t.takeException(), isNull);
        final narrow = isNarrowLayout(s.width);
        final pad = pagePadding(narrow);
        final note = t.getRect(_notePanel);
        if (narrow) {
          expect(_leftColumn, findsNothing);
          // заметка — на всю ширину и до низа (с полем страницы)
          expect(note.left, pad);
          expect(note.width, s.width - 2 * pad);
          expect(note.top, pad);
          expect(note.bottom, s.height - pad);
        } else {
          expect(_leftColumn, findsOneWidget);
          final col = t.getRect(_leftColumn);
          expect(col.width, kLeftColumnWidth - 20);
          expect(note.left, greaterThan(col.right));
          expect(note.bottom, closeTo(s.height - pad, 0.01));
        }
        expect(_overlayPanel, findsNothing);
      });
    }
  });

  group('панель в узком окне', () {
    testWidgets('кнопка открывает и закрывает, щелчок по затемнению и Esc '
        'закрывают', (t) async {
      final st = await _pump(t, _controller(), FocusNode(), w: 400, h: 800);
      await t.tap(find.byKey(const ValueKey('nav-toggle')));
      await t.pumpAndSettle();
      expect(_overlayPanel, findsOneWidget);
      expect(t.getRect(_overlayPanel).width, 320);
      expect(t.getRect(_overlayPanel).left, 0);
      expect(t.takeException(), isNull);

      // затемнение
      await t.tapAt(const Offset(380, 400));
      await t.pumpAndSettle();
      expect(st.navOpen, isFalse);
      expect(_overlayPanel, findsNothing);

      // Esc
      await t.tap(find.byKey(const ValueKey('nav-toggle')));
      await t.pumpAndSettle();
      expect(_overlayPanel, findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(st.navOpen, isFalse);
      expect(_overlayPanel, findsNothing);
      expect(_scrim, findsNothing);
    });

    testWidgets('выбор дня, «Сегодня» и темы закрывает панель', (t) async {
      final st = await _pump(t, _controller(), FocusNode(), w: 360, h: 640);
      for (final (label, target) in const [
        ('20', 'день 20'),
        ('Сегодня', 'сегодня'),
        ('Тема А', 'тема А'),
      ]) {
        await t.tap(find.byKey(const ValueKey('nav-toggle')));
        await t.pumpAndSettle();
        await t.tap(find.descendant(of: _overlayPanel, matching: find.text(label)));
        await t.pumpAndSettle();
        expect(st.opened, target);
        expect(st.navOpen, isFalse);
        expect(_overlayPanel, findsNothing);
      }
    });

    testWidgets('панель не выше и не шире окна, прокручивается (640×300)',
        (t) async {
      await _pump(t, _controller(), FocusNode(), w: 640, h: 300);
      await t.tap(find.byKey(const ValueKey('nav-toggle')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final r = t.getRect(_overlayPanel);
      expect(r.height, 300);
      await t.drag(_overlayPanel, const Offset(0, -300));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('Тема А'), findsOneWidget);
    });

    testWidgets('на 300 панель — окно − 48', (t) async {
      await _pump(t, _controller(), FocusNode(), w: 300, h: 600);
      await t.tap(find.byKey(const ValueKey('nav-toggle')));
      await t.pumpAndSettle();
      expect(t.getRect(_overlayPanel).width, 252);
      expect(t.takeException(), isNull);
    });

    testWidgets('Esc при закрытой панели не перехватывается', (t) async {
      final st = await _pump(t, _controller(), FocusNode(), w: 400, h: 800);
      final handled = await t.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(handled, isFalse);
      expect(st.navOpen, isFalse);
    });

    testWidgets('панель забирает фокус: ввод не попадает в заметку',
        (t) async {
      final c = _controller();
      final f = FocusNode();
      await _pump(t, c, f, w: 400, h: 800);
      f.requestFocus();
      await t.pump();
      expect(f.hasFocus, isTrue);
      await t.tap(find.byKey(const ValueKey('nav-toggle')));
      await t.pumpAndSettle();
      expect(f.hasFocus, isFalse);
      expect(c.document.toPlainText(), 'Мой текст заметки\n');
    });
  });

  group('смена ширины', () {
    testWidgets('тот же редактор: текст, курсор, выделение, фокус, '
        'ничего не сохраняется', (t) async {
      final c = _controller();
      final f = FocusNode();
      final st = await _pump(t, c, f, w: 1200, h: 800);
      f.requestFocus();
      c.updateSelection(
          const TextSelection(baseOffset: 4, extentOffset: 9),
          ChangeSource.local);
      await t.pump();
      final editor = t.element(find.byType(QuillEditor));
      final page = t.state(find.byType(_Page));
      var changes = 0;
      c.addListener(() => changes++);
      var statusChanges = 0;
      st.status.addListener(() => statusChanges++);

      for (final w in const [500.0, 1200.0, 360.0, 719.0, 720.0, 1400.0]) {
        await _size(t, w, 800);
        expect(t.takeException(), isNull, reason: '$w');
        expect(identical(t.element(find.byType(QuillEditor)), editor), isTrue,
            reason: 'редактор пересоздан при $w');
        expect(identical(t.state(find.byType(_Page)), page), isTrue);
        expect(c.document.toPlainText(), 'Мой текст заметки\n');
        expect(c.selection,
            const TextSelection(baseOffset: 4, extentOffset: 9));
        expect(f.hasFocus, isTrue, reason: 'фокус потерян при $w');
      }
      expect(changes, 0);
      expect(statusChanges, 0);
    });

    testWidgets('свёрнутая в широком окне колонка остаётся свёрнутой после '
        'узкого', (t) async {
      final st = await _pump(t, _controller(), FocusNode(), w: 1200, h: 800);
      await t.tap(find.byKey(const ValueKey('nav-toggle')));
      await t.pumpAndSettle();
      expect(st.wideOpen, isFalse);
      expect(_leftColumn, findsNothing);

      await _size(t, 400, 800);
      // в узком окне открыли и закрыли панель — выбор широкого не меняется
      await t.tap(find.byKey(const ValueKey('nav-toggle')));
      await t.pumpAndSettle();
      await t.tapAt(const Offset(390, 400));
      await t.pumpAndSettle();
      await _size(t, 1200, 800);
      expect(st.wideOpen, isFalse);
      expect(_leftColumn, findsNothing);

      // открыли в широком — после узкого снова открыта
      await t.tap(find.byKey(const ValueKey('nav-toggle')));
      await t.pumpAndSettle();
      expect(_leftColumn, findsOneWidget);
      await _size(t, 400, 800);
      expect(_leftColumn, findsNothing);
      await _size(t, 1200, 800);
      expect(st.wideOpen, isTrue);
      expect(_leftColumn, findsOneWidget);
    });

    testWidgets('открытая панель закрывается, когда окно стало широким',
        (t) async {
      final st = await _pump(t, _controller(), FocusNode(), w: 400, h: 800);
      await t.tap(find.byKey(const ValueKey('nav-toggle')));
      await t.pumpAndSettle();
      expect(st.navOpen, isTrue);
      await _size(t, 1000, 800);
      await t.pumpAndSettle();
      expect(st.navOpen, isFalse);
      expect(_overlayPanel, findsNothing);
      expect(_leftColumn, findsOneWidget);
      // снова узкое — панель не появляется сама
      await _size(t, 400, 800);
      expect(_overlayPanel, findsNothing);
    });
  });

  testWidgets('«Уменьшить анимации» — панель появляется и исчезает сразу',
      (t) async {
    final was = motion.reduced;
    motion.setReduced(true);
    addTearDown(() => motion.setReduced(was));
    final st = await _pump(t, _controller(), FocusNode(), w: 400, h: 800);
    await t.tap(find.byKey(const ValueKey('nav-toggle')));
    await t.pump();
    await t.pump();
    expect(t.getRect(_overlayPanel).left, 0);
    st.pick('день 20');
    await t.pump();
    await t.pump();
    expect(_overlayPanel, findsNothing);
  });

  group('окна на ширине 320', () {
    Future<void> open(WidgetTester t, Future<void> Function(BuildContext) show) async {
      t.view.physicalSize = const Size(320, 568);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      late BuildContext ctx;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.expand();
        })),
      ));
      show(ctx);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    }

    testWidgets('поиск', (t) async {
      await open(
          t,
          (c) => showNoteSearch(c,
              cache: NoteSearchCache(() async => {}),
              boilerplate: const {},
              liveKey: () => null,
              liveText: () => '',
              inCalendarRange: (_) => true));
      await t.enterText(find.byType(TextField).first, 'очень длинный запрос');
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('название темы', (t) async {
      await open(t, (c) => showTopicTitleDialog(c, initial: 'Тема'));
    });

    testWidgets('удаление темы', (t) async {
      await open(t,
          (c) => confirmTopicDelete(c, 'Очень длинное название темы для узкого окна'));
    });

    testWidgets('личный словарь', (t) async {
      final store = _MemStore()..words.addAll(['калибровка', 'дашборд']);
      final dict = PersonalDictionary(store);
      await dict.load();
      await open(t, (c) => showPersonalDictionaryDialog(c, dict));
    });
  });
}

class _MemStore implements DictionaryStore {
  final List<String> words = [];
  @override
  Future<List<String>?> load() async => List.of(words);
  @override
  Future<void> add(List<String> w) async => words.addAll(w);
  @override
  Future<void> remove(String word) async => words.remove(word);
}
