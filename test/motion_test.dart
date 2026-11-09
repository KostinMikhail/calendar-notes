import 'package:calendar_notes/format_menu.dart' show PrefStore;
import 'package:calendar_notes/motion.dart';
import 'package:calendar_notes/topics.dart';
import 'package:calendar_notes/topics_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

class MemPrefs implements PrefStore {
  final Map<String, String> data = {};
  bool throws = false;
  @override
  String? read(String key) {
    if (throws) throw StateError('blocked');
    return data[key];
  }

  @override
  void write(String key, String value) {
    if (throws) throw StateError('blocked');
    data[key] = value;
  }
}

/// Темы в памяти: что удалено — видно сразу
class MemTopicStore implements TopicStore {
  final Map<String, Topic> data = {};
  final List<String> deleted = [];
  int _seq = 0;

  @override
  Future<List<Topic>> list() async => data.values.toList();
  @override
  Future<String> create(String title, int order) async {
    final id = 'n${_seq++}';
    data[id] = Topic(id: id, title: title, order: order);
    return id;
  }

  @override
  Future<void> rename(String id, String title) async =>
      data[id] = data[id]!.copyWith(title: title);
  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    data.remove(id);
  }

  @override
  Future<void> setOrders(Map<String, int> orders) async {}
  @override
  Future<TopicContent?> load(String id) async => null;
  @override
  Future<void> saveContent(String id, String delta, String text) async {}
}

/// Итоговая прозрачность: произведение всех затуханий над виджетом
double opacityAbove(WidgetTester tester, Finder f) {
  var v = 1.0;
  for (final w in tester.widgetList<FadeTransition>(
      find.ancestor(of: f.first, matching: find.byType(FadeTransition)))) {
    v *= w.opacity.value;
  }
  for (final w in tester.widgetList<LightFade>(
      find.ancestor(of: f.first, matching: find.byType(LightFade)))) {
    v *= w.opacity.value;
  }
  return v;
}

void main() {
  tearDown(() => motion.reset());

  group('длительности', () {
    test('по имени: быстро / обычно / медленно', () {
      motion.reset();
      expect(Motion.fast, const Duration(milliseconds: 120));
      expect(Motion.normal, const Duration(milliseconds: 180));
      expect(Motion.slow, const Duration(milliseconds: 250));
      expect(Motion.calendarPage, const Duration(milliseconds: 250));
      expect(Motion.stagger(0), Duration.zero);
      expect(Motion.stagger(2), const Duration(milliseconds: 40));
      // лесенка ограничена
      expect(Motion.stagger(100), Motion.staggerBase * Motion.staggerCap);
      expect(Motion.stagger(100) <= const Duration(milliseconds: 150), isTrue);
      expect(Motion.menu.duration, Motion.normalBase);
      expect(Motion.dialog.duration, Motion.normalBase);
      expect(Motion.snackBar.duration, Motion.slowBase);
    });

    test('уменьшенные анимации — всё мгновенно', () {
      motion.reset(userChoice: true);
      expect(Motion.fast, Duration.zero);
      expect(Motion.normal, Duration.zero);
      expect(Motion.slow, Duration.zero);
      expect(Motion.stagger(3), Duration.zero);
      expect(Motion.menu, AnimationStyle.noAnimation);
      expect(Motion.dialog, AnimationStyle.noAnimation);
      expect(Motion.snackBar, AnimationStyle.noAnimation);
      // календарь не принимает ноль — 1 мс, то есть сразу
      expect(Motion.calendarPage, const Duration(milliseconds: 1));
    });
  });

  group('«Уменьшить анимации»', () {
    test('выбор в меню важнее системной настройки', () {
      final m = MotionSettings(userChoice: false, system: true);
      expect(m.reduced, isFalse);
      final m2 = MotionSettings(userChoice: true, system: false);
      expect(m2.reduced, isTrue);
    });

    test('выбора нет — следуем системе, и она меняется на лету', () {
      final m = MotionSettings();
      var notes = 0;
      m.addListener(() => notes++);
      expect(m.reduced, isFalse);
      m.setSystem(true);
      expect(m.reduced, isTrue);
      expect(notes, 1);
      m.setSystem(true); // то же — без лишних уведомлений
      expect(notes, 1);
    });

    test('при явном выборе система не влияет', () {
      final prefs = MemPrefs();
      final m = MotionSettings();
      m.setReduced(false, MotionPref(prefs));
      var notes = 0;
      m.addListener(() => notes++);
      m.setSystem(true);
      expect(m.reduced, isFalse);
      expect(notes, 0);
    });

    test('выбор запоминается явно, даже совпадая с системой', () {
      final prefs = MemPrefs();
      final m = MotionSettings(system: true);
      m.setReduced(true, MotionPref(prefs));
      expect(prefs.data[MotionPref.storageKey], '1');
      expect(m.userChoice, isTrue);
      m.setReduced(false, MotionPref(prefs));
      expect(prefs.data[MotionPref.storageKey], '0');
      expect(m.reduced, isFalse);
      expect(MotionPref(prefs).load(), isFalse);
    });

    test('хранилище: нет записи, мусор или ошибка — по системе', () {
      final prefs = MemPrefs();
      expect(MotionPref(prefs).load(), isNull);
      prefs.data[MotionPref.storageKey] = 'x';
      expect(MotionPref(prefs).load(), isNull);
      final broken = MemPrefs()..throws = true;
      expect(MotionPref(broken).load(), isNull);
      MotionPref(broken).save(true); // не бросает
      final m = MotionSettings(
          userChoice: MotionPref(broken).load(), system: true);
      expect(m.reduced, isTrue);
      final m2 = MotionSettings(
          userChoice: MotionPref(broken).load(), system: false);
      expect(m2.reduced, isFalse);
    });
  });

  group('появление', () {
    testWidgets('обычно — завершается за свою длительность', (tester) async {
      await tester.pumpWidget(const Directionality(
          textDirection: TextDirection.ltr,
          child: FadeScaleIn(scaleFrom: 0.97, child: Text('x'))));
      expect(opacityAbove(tester, find.text('x')), lessThan(1));
      await tester.pump(); // первый кадр анимации
      await tester.pump(Motion.normalBase);
      expect(opacityAbove(tester, find.text('x')), 1);
      // анимация заканчивается, когда время строго больше длительности
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('с задержкой — без таймеров, всё равно успокаивается',
        (tester) async {
      await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: FadeScaleIn(
              delay: Motion.stagger(3), dy: 6, child: const Text('x'))));
      await tester.pump(Motion.stagger(3) ~/ 2);
      expect(opacityAbove(tester, find.text('x')), 0);
      await tester.pumpAndSettle();
      expect(opacityAbove(tester, find.text('x')), 1);
    });

    testWidgets('уменьшенные — сразу, за один кадр', (tester) async {
      motion.reset(userChoice: true);
      await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: FadeScaleIn(
              delay: Motion.stagger(3), dy: 6, child: const Text('x'))));
      await tester.pump();
      expect(opacityAbove(tester, find.text('x')), 1);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('нажатия проходят во время появления', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
          home: FadeScaleIn(
              child: TextButton(
                  onPressed: () => taps++, child: const Text('ok')))));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.tap(find.text('ok'));
      expect(taps, 1);
      await tester.pumpAndSettle();
    });
  });

  group('смена дня/темы в редакторе', () {
    testWidgets(
        'один и тот же редактор: появление не создаёт второго, контроллер '
        'и фокус те же, ввод работает во время появления', (tester) async {
      final probe = _EditorProbe();
      await tester.pumpWidget(_EditorHarness(probe: probe));
      await tester.pumpAndSettle();
      final state = probe.state!;
      final controller = state.controller;
      expect(find.byType(QuillEditor), findsOneWidget);

      // «загрузили другой день»: документ поставлен сразу, потом сигнал
      state.install('Новый день');
      await tester.pump();
      // старого содержимого уже нет — сразу новое
      expect(controller.document.toPlainText(), 'Новый день\n');

      for (var i = 0; i < 6; i++) {
        expect(find.byType(QuillEditor), findsOneWidget);
        expect(find.byType(QuillRawEditor), findsOneWidget);
        expect(identical(state.controller, controller), isTrue);
        await tester.pump(Motion.normalBase ~/ 6);
      }
      expect(probe.inits, 1);

      // ещё раз и сразу печатаем, пока проявляется
      state.install('Третий день');
      await tester.pump(const Duration(milliseconds: 30));
      final reveal = find.byType(RevealOnSignal);
      expect(opacityAbove(tester, find.byType(QuillEditor)), lessThan(1));
      await tester.tap(find.byType(QuillEditor));
      await tester.pump();
      expect(state.focus.hasFocus, isTrue, reason: 'нажатие дошло');
      controller.replaceText(
          controller.document.length - 1,
          0,
          '!',
          TextSelection.collapsed(offset: controller.document.length));
      await tester.pump();
      expect(controller.document.toPlainText(), 'Третий день!\n');
      expect(find.byType(QuillEditor), findsOneWidget);
      expect(reveal, findsOneWidget);
      await tester.pump(Motion.normalBase);
      // (мигает курсор — поэтому проверяем само появление, а не «всё стоит»)
      expect(opacityAbove(tester, find.byType(QuillEditor)), 1);
    });

    testWidgets('выбрали другой день — старый текст сразу не виден, '
        'редактор тот же; загрузился — проявляется', (tester) async {
      for (final reduced in [false, true]) {
        motion.reset(userChoice: reduced);
        final probe = _EditorProbe();
        await tester.pumpWidget(_EditorHarness(probe: probe, key: UniqueKey()));
        final state = probe.state!;
        state.install('Старый день');
        await tester.pumpAndSettle();
        expect(opacityAbove(tester, find.byType(QuillEditor)), 1);

        state.select();
        await tester.pump(); // первый же кадр
        expect(opacityAbove(tester, find.byType(QuillEditor)), 0,
            reason: 'старый текст под новой датой не показываем');
        expect(find.byType(QuillEditor), findsOneWidget);
        expect(identical(state.controller, probe.state!.controller), isTrue);

        state.install('Новый день');
        await tester.pump();
        await tester.pump(Motion.normal + const Duration(milliseconds: 1));
        expect(opacityAbove(tester, find.byType(QuillEditor)), 1);
        expect(state.controller.document.toPlainText(), 'Новый день\n');
        expect(probe.inits, 1);
      }
    });

    testWidgets('уменьшенные анимации — новое содержимое сразу целиком',
        (tester) async {
      motion.reset(userChoice: true);
      final probe = _EditorProbe();
      await tester.pumpWidget(_EditorHarness(probe: probe));
      await tester.pump();
      probe.state!.install('День');
      await tester.pump();
      expect(opacityAbove(tester, find.byType(QuillEditor)), 1);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('в покое — без слоя прозрачности над редактором, '
        'во время появления — слой есть', (tester) async {
      final probe = _EditorProbe();
      await tester.pumpWidget(_EditorHarness(probe: probe));
      probe.state!.install('День');
      await tester.pump();
      await tester.pump(Motion.normalBase ~/ 2);
      final f = find
          .ancestor(
              of: find.byType(QuillEditor), matching: find.byType(LightFade))
          .first;
      var ro = tester.renderObject<RenderLightFade>(f);
      expect(ro.alpha, inExclusiveRange(0, 255));
      expect(ro.debugLayer, isNotNull);
      await tester.pumpAndSettle();
      ro = tester.renderObject<RenderLightFade>(f);
      expect(ro.alpha, 255);
      expect(ro.debugLayer, isNull); // полная видимость — рисуется напрямую
      // и обычной FadeTransition над редактором нет
      expect(
          find.ancestor(
              of: find.byType(QuillEditor),
              matching: find.byType(FadeTransition)),
          findsWidgets); // (переход маршрута MaterialApp — не наш)
      expect(
          find.descendant(
              of: find.byType(RevealOnSignal),
              matching: find.byType(FadeTransition)),
          findsNothing);
    });
  });

  group('колонка календаря', () {
    Widget layout({required bool open, required double width}) => MaterialApp(
          home: Material(
            child: Center(
            child: SizedBox(
              width: width,
              height: 500,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CollapseReveal(
                    open: open,
                    child: SizedBox(
                      width: 320,
                      child: Column(children: [
                        const Text('Ноябрь 2026'),
                        for (var i = 0; i < 5; i++)
                          const Row(children: [
                            Expanded(child: Text('Пн Вт Ср Чт Пт Сб Вс')),
                          ]),
                      ]),
                    ),
                  ),
                  const Expanded(child: ColoredBox(color: Colors.black)),
                ],
              ),
            ),
          ),
          ),
        );

    testWidgets('свернуть/развернуть — без переполнения на любом кадре, '
        'уходящая колонка не нажимается', (tester) async {
      for (final width in [1200.0, 820.0]) {
        await tester.pumpWidget(layout(open: true, width: width));
        await tester.pumpAndSettle();
        await tester.pumpWidget(layout(open: false, width: width));
        for (var i = 0; i < 10; i++) {
          await tester.pump(Motion.slowBase ~/ 10);
          expect(tester.takeException(), isNull);
          if (find.text('Ноябрь 2026').evaluate().isNotEmpty) {
            final ig = tester.widget<IgnorePointer>(find
                .ancestor(
                    of: find.text('Ноябрь 2026'),
                    matching: find.byType(IgnorePointer))
                .first);
            expect(ig.ignoring, isTrue);
          }
        }
        await tester.pumpAndSettle();
        expect(find.text('Ноябрь 2026'), findsNothing); // скрыта — нет в дереве
        await tester.pumpWidget(layout(open: true, width: width));
        await tester.pump();
        expect(find.text('Ноябрь 2026'), findsOneWidget);
        for (var i = 0; i < 10; i++) {
          await tester.pump(Motion.slowBase ~/ 10);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(CollapseReveal)).width, 320);
      }
    });

    testWidgets('сверху вниз (узкий экран) — тоже без переполнения',
        (tester) async {
      Widget narrow(bool open) => MaterialApp(
            home: Material(child: ListView(children: [
              CollapseReveal(
                open: open,
                axis: Axis.vertical,
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: 300, child: Text('календарь')),
                    SizedBox(height: 300, child: Text('темы')),
                  ],
                ),
              ),
              const SizedBox(height: 560, child: Text('заметка')),
            ])),
          );
      await tester.pumpWidget(narrow(true));
      await tester.pumpWidget(narrow(false));
      for (var i = 0; i < 10; i++) {
        await tester.pump(Motion.slowBase ~/ 10);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
      expect(find.text('календарь'), findsNothing);
      expect(tester.getTopLeft(find.text('заметка')).dy, 0);
    });

    testWidgets('уменьшенные анимации — сразу', (tester) async {
      motion.reset(userChoice: true);
      await tester.pumpWidget(layout(open: true, width: 1200));
      await tester.pumpWidget(layout(open: false, width: 1200));
      await tester.pump();
      expect(find.text('Ноябрь 2026'), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('список тем', () {
    Future<(TopicsController, MemTopicStore)> pumpPanel(
        WidgetTester tester) async {
      final store = MemTopicStore()
        ..data['a'] = const Topic(id: 'a', title: 'Работа', order: 0)
        ..data['b'] = const Topic(id: 'b', title: 'Дом', order: 1);
      final c = TopicsController(store);
      await c.load();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 400,
            child: TopicsPanel(
              controller: c,
              selectedId: null,
              onOpen: (_) {},
              onCreate: () {},
              onRename: (_) {},
              onDelete: (_) {},
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (c, store);
    }

    testWidgets('первая загрузка — без анимации', (tester) async {
      await pumpPanel(tester);
      expect(find.text('Работа'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('удаление: данные — сразу, строка плавно уходит',
        (tester) async {
      final (c, store) = await pumpPanel(tester);
      await c.delete('a');
      // данные уже изменены, до конца анимации
      expect(store.deleted, ['a']);
      expect(c.topics.map((t) => t.id), ['b']);
      await tester.pump();
      await tester.pump(Motion.normalBase ~/ 2);
      // строка ещё видна, тает и не нажимается
      expect(find.text('Работа'), findsOneWidget);
      expect(opacityAbove(tester, find.text('Работа')), lessThan(1));
      final ig = tester.widget<IgnorePointer>(find
          .ancestor(
              of: find.text('Работа'), matching: find.byType(IgnorePointer))
          .first);
      expect(ig.ignoring, isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Работа'), findsNothing);
      expect(find.text('Дом'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('удалили последнюю — подсказка после того, как строка ушла',
        (tester) async {
      final (c, _) = await pumpPanel(tester);
      await c.delete('a');
      await c.delete('b');
      await tester.pumpAndSettle();
      expect(find.textContaining('Пока нет тем'), findsOneWidget);
    });

    testWidgets('новая тема плавно появляется', (tester) async {
      final (c, _) = await pumpPanel(tester);
      await c.create();
      await tester.pump();
      await tester.pump(Motion.normalBase ~/ 2);
      expect(find.text(kTopicDefaultTitle), findsOneWidget);
      expect(opacityAbove(tester, find.text(kTopicDefaultTitle)), lessThan(1));
      await tester.pumpAndSettle();
      expect(opacityAbove(tester, find.text(kTopicDefaultTitle)), 1);
    });

    testWidgets('уменьшенные анимации — удаление сразу', (tester) async {
      motion.reset(userChoice: true);
      final (c, _) = await pumpPanel(tester);
      await c.delete('a');
      await tester.pump();
      await tester.pump();
      expect(find.text('Работа'), findsNothing);
    });
  });

  testWidgets('отклик нажатия: кнопка чуть уменьшается и работает',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: PressScale(
          child: IconButton(
              onPressed: () => taps++, icon: const Icon(Icons.search)),
        ),
      ),
    ));
    final g = await tester.startGesture(tester.getCenter(find.byIcon(Icons.search)));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
        lessThan(1));
    await g.up();
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
  });

  testWidgets('смена текста статуса — быстрое перетекание', (tester) async {
    Widget status(String s) => Directionality(
          textDirection: TextDirection.ltr,
          child: FadeSwitcher(child: Text(s, key: ValueKey(s))),
        );
    await tester.pumpWidget(status('Сохранение…'));
    await tester.pumpWidget(status('Сохранено ✓'));
    await tester.pump(Motion.fastBase ~/ 2);
    expect(find.text('Сохранение…'), findsOneWidget);
    expect(find.text('Сохранено ✓'), findsOneWidget);
    await tester.pump(Motion.fastBase);
    expect(find.text('Сохранение…'), findsNothing);
    expect(find.text('Сохранено ✓'), findsOneWidget);
  });
}

class _EditorProbe {
  _EditorHarnessState? state;
  int inits = 0;
}

/// Как центр приложения: один редактор, документ ставится сразу,
/// затем сигнал — область мягко проявляется
class _EditorHarness extends StatefulWidget {
  const _EditorHarness({required this.probe, super.key});
  final _EditorProbe probe;
  @override
  State<_EditorHarness> createState() => _EditorHarnessState();
}

class _EditorHarnessState extends State<_EditorHarness> {
  final controller = QuillController.basic();
  final focus = FocusNode();
  final scroll = ScrollController();
  final signal = ValueNotifier<int>(0);
  final hidden = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    widget.probe.state = this;
    widget.probe.inits++;
  }

  /// Выбрали другой день — его текст ещё грузится
  void select() => hidden.value = true;

  void install(String text) {
    controller.document = Document()..insert(0, text);
    hidden.value = false;
    signal.value++;
  }

  @override
  void dispose() {
    controller.dispose();
    focus.dispose();
    scroll.dispose();
    signal.dispose();
    hidden.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: Scaffold(
          body: RepaintBoundary(
            child: RevealOnSignal(
              signal: signal,
              hidden: hidden,
              child: QuillEditor(
                controller: controller,
                focusNode: focus,
                scrollController: scroll,
                config: const QuillEditorConfig(),
              ),
            ),
          ),
        ),
      );
}
