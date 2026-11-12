import 'dart:async';
import 'dart:convert';

import 'package:calendar_notes/backup.dart';
import 'package:calendar_notes/main.dart' show kSurface;
import 'package:calendar_notes/format_menu.dart' show PrefStore;
import 'package:calendar_notes/spell/personal_dictionary.dart';
import 'package:calendar_notes/spell/spell_backend.dart';
import 'package:calendar_notes/spell/spell_edit.dart';
import 'package:calendar_notes/spell/spell_engine.dart';
import 'package:calendar_notes/spell/spell_host.dart';
import 'package:calendar_notes/spell/suggestions.dart';
import 'package:calendar_notes/spell/tokenizer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

// ------------------------------------------------------------
//  Подделки
// ------------------------------------------------------------

class FakeBackend implements SpellBackend {
  FakeBackend({Set<String>? ru, Set<String>? en, this.fail = false})
      : ru = ru ?? {'привет', 'встреча', 'кто', 'нибудь', 'еще', 'все'},
        en = en ?? {'hello', 'the', "don't", "it's", 'well', 'known', 'world'};

  final Set<String> ru;
  final Set<String> en;
  final bool fail;
  final List<String> asked = []; // какие слова спрашивали
  int startCalls = 0;
  bool disposed = false;

  @override
  Future<void> start() async {
    startCalls++;
    if (fail) throw StateError('no dictionaries');
  }

  @override
  Future<List<bool>> check(String lang, List<String> words) async {
    asked.addAll(words);
    final dict = lang == 'ru' ? ru : en;
    return [for (final w in words) dict.contains(w.toLowerCase())];
  }

  @override
  Future<List<String>> suggest(String lang, String word) async {
    if (word.toLowerCase() == 'превет') {
      return ['ревет', 'поревет', 'преет', 'прервет', 'привет'];
    }
    if (word.toLowerCase() == 'teh') {
      return ['ten', 'eh', 'meh', 'tea', 'tech', 'ted', 'tee', 'tel', 'the'];
    }
    return const [];
  }

  @override
  void dispose() => disposed = true;
}

class MemDictStore implements DictionaryStore {
  final List<String> words = [];
  bool fail = false;
  int addCalls = 0;

  @override
  Future<List<String>?> load() async {
    if (fail) throw StateError('offline');
    return List.of(words);
  }

  @override
  Future<void> add(List<String> w) async {
    addCalls++;
    if (fail) throw StateError('permission-denied');
    for (final x in w) {
      if (!words.contains(x)) words.add(x); // как arrayUnion
    }
  }

  @override
  Future<void> remove(String w) async {
    if (fail) throw StateError('permission-denied');
    words.remove(w); // как arrayRemove
  }
}

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

SpellEngine engineWith(FakeBackend b, {MemDictStore? store, MemPrefs? prefs}) {
  return SpellEngine(
    backend: b,
    dictionary: PersonalDictionary(store ?? MemDictStore()),
    pref: SpellPref(prefs ?? MemPrefs()),
    startDelay: Duration.zero,
  );
}

Future<void> ready(SpellEngine e) async {
  e.start();
  await Future<void>.delayed(const Duration(milliseconds: 5));
}

List<String> words(String text) => [for (final t in spellTokens(text)) t.word];

void main() {
  group('разбор на слова', () {
    test('кириллица и латиница, знаки препинания, эмодзи', () {
      expect(words('Привет, мир! Hello world… 🙂 ещё'),
          ['Привет', 'мир', 'Hello', 'world', 'ещё']);
      final t = spellTokens('ой, встреча');
      expect(t.last.start, 4);
      expect(t.last.end, 11);
      expect(t.last.script, SpellScript.cyrillic);
      expect(spellTokens('hello').single.lang, 'en');
    });

    test('слова через дефис — по частям; апострофы', () {
      expect(words('кто-нибудь well-known'), ['кто', 'нибудь', 'well', 'known']);
      expect(words("don't it’s 'цитата'"), ["don't", "it's", 'цитата']);
    });

    test('не проверяются: ЗАГЛАВНЫЕ, цифры, 1–2 буквы, смесь алфавитов', () {
      expect(words('СДК API JSON abc123 2-й а бы ok of Пiвет'), isEmpty);
    });

    test('не проверяются: адреса, почта, @упоминания, #теги', () {
      expect(
          words('см https://exampel.com/pаth и www.tеst.ru, '
              'пиши vasia@mail.ru или @kostin #задачка example.org'),
          ['пиши', 'или']);
    });

    test('ё и е — одно и то же для словаря и личного словаря', () {
      expect(normalizeWord('Ёлка'), 'елка');
      expect(normalizeWord('it’s'), "it's");
    });

    test('обсценная лексика не подчёркивается; обычные слова — да', () {
      for (final w in ['хуй', 'охуеть', 'пиздец', 'ебать', 'заебал',
          'отъебись', 'блядь', 'бля', 'сука', 'нахуй', 'Мудак']) {
        expect(isObsceneAllowed(w), isTrue, reason: w);
      }
      for (final w in ['хлебаа', 'требую', 'сравнени', 'командаа', 'небо',
          'привет', 'тебе']) {
        expect(isObsceneAllowed(w), isFalse, reason: w);
      }
    });
  });

  group('варианты исправления', () {
    test('частая опечатка — первой: teh → the, превет → привет', () {
      expect(rankSuggestions('teh',
          ['ten', 'eh', 'meh', 'tea', 'tech', 'ted', 'tee', 'tel', 'the']).first,
          'the');
      expect(rankSuggestions('превет',
          ['ревет', 'поревет', 'преет', 'прервет', 'привет']).first, 'привет');
    });

    test('не больше 5, без повторов, аббревиатуры ниже', () {
      final r = rankSuggestions('teh', ['NEH', 'the', 'The', 'ten', 'tea',
          'tee', 'ted', 'tel']);
      expect(r.length, 5);
      expect(r.first, 'the');
      expect(r.contains('NEH'), isFalse);
      expect(r.toSet().length, r.length);
    });

    test('регистр как у слова', () {
      expect(adaptCase('Превет', 'привет'), 'Привет');
      expect(adaptCase('москва', 'Москва'), 'Москва');
      expect(rankSuggestions('Превет', ['привет']), ['Привет']);
    });

    test('расстояние: перестановка соседних букв = 1', () {
      expect(damerauDistance('teh', 'the'), 1);
      expect(damerauDistance('превет', 'привет'), 1);
      expect(damerauDistance('abc', 'abc'), 0);
    });
  });

  group('движок', () {
    test('выключено — словари не грузятся, ничего не проверяется', () async {
      final b = FakeBackend();
      final prefs = MemPrefs()..data[SpellPref.storageKey] = '0';
      final e = engineWith(b, prefs: prefs);
      await ready(e);
      expect(e.enabled, isFalse);
      expect(b.startCalls, 0);
      await e.checkTokens(spellTokens('превет'));
      expect(b.asked, isEmpty);
    });

    test('включение запоминается; хранилище с ошибкой — включено', () async {
      final prefs = MemPrefs();
      final e = engineWith(FakeBackend(), prefs: prefs);
      expect(e.enabled, isTrue);
      e.setEnabled(false);
      expect(prefs.data[SpellPref.storageKey], '0');
      expect(SpellPref(prefs).load(), isFalse);
      e.setEnabled(true);
      expect(SpellPref(prefs).load(), isTrue);
      expect(SpellPref(MemPrefs()..throws = true).load(), isTrue);
      expect(SpellPref(MemPrefs()..data[SpellPref.storageKey] = 'мусор').load(),
          isTrue);
    });

    test('словари не загрузились — тихо выключается, одно сообщение', () async {
      final e = engineWith(FakeBackend(fail: true));
      var failed = 0;
      e.onFailed = () => failed++;
      await ready(e);
      expect(e.state, SpellState.failed);
      expect(e.active, isFalse);
      expect(failed, 1);
    });

    test('ошибки, кэш на сеанс, личный словарь сбрасывает подчёркивание',
        () async {
      final b = FakeBackend();
      final e = engineWith(b);
      await ready(e);
      final t = spellTokens('превет привет')..toList();
      await e.checkTokens(t);
      expect(e.isMisspelled(t[0]), isTrue);
      expect(e.isMisspelled(t[1]), isFalse);
      final asked = b.asked.length;
      await e.checkTokens(spellTokens('превет'));
      expect(b.asked.length, asked); // уже в кэше

      var notified = 0;
      e.addListener(() => notified++);
      await e.dictionary.add('Превет');
      expect(notified, greaterThan(0)); // хосты пересчитают подчёркивания
      expect(e.isMisspelled(t[0]), isFalse);
      await e.dictionary.remove('превет');
      expect(e.isMisspelled(t[0]), isTrue);
    });

    test('ё → е перед словарём (ещё не подчёркивается)', () async {
      final b = FakeBackend();
      final e = engineWith(b);
      await ready(e);
      final t = spellTokens('ещё всё');
      await e.checkTokens(t);
      expect(t.where(e.isMisspelled), isEmpty);
    });

    test('варианты — до 5, в регистре слова', () async {
      final e = engineWith(FakeBackend());
      await ready(e);
      final s = await e.suggestions(spellTokens('Teh').single);
      expect(s.first, 'The');
      expect(s.length, lessThanOrEqualTo(5));
    });
  });

  group('личный словарь', () {
    test('добавление и удаление: в памяти сразу, в базе — объединением',
        () async {
      final store = MemDictStore()..words.addAll(['вася']);
      final d = PersonalDictionary(store);
      await d.load();
      expect(d.contains('Вася'), isTrue);
      expect(await d.add('Кострома'), isTrue);
      expect(d.contains('кострома'), isTrue);
      expect(store.words, ['вася', 'кострома']);
      await d.add('кострома'); // повтор — без записи
      expect(store.addCalls, 1);
      await d.remove('Кострома');
      expect(store.words, ['вася']);
    });

    test('слишком длинное / с пробелом — не добавляется', () async {
      final d = PersonalDictionary(MemDictStore());
      expect(await d.add('а' * 65), isFalse);
      expect(await d.add('два слова'), isFalse);
      expect(await d.add('а' * 64), isTrue);
    });

    test('предел 5000 слов', () async {
      final store = MemDictStore()
        ..words.addAll([for (var i = 0; i < kMaxDictionaryWords; i++) 'w$i']);
      final errors = <String>[];
      final d = PersonalDictionary(store, onError: errors.add);
      await d.load();
      expect(await d.add('лишнее'), isFalse);
      expect(errors.single, contains('заполнен'));
    });

    test('ошибка записи (правила не задеплоены) — слово остаётся на сеанс, '
        'сообщение об ошибке', () async {
      final store = MemDictStore();
      final errors = <String>[];
      final d = PersonalDictionary(store, onError: errors.add);
      store.fail = true;
      expect(await d.add('Кострома'), isTrue);
      expect(d.contains('кострома'), isTrue);
      expect(errors.single, startsWith('Ошибка сохранения словаря'));
    });

    test('восстановление из копии — объединение, ничего не удаляется',
        () async {
      final store = MemDictStore()..words.addAll(['свое']);
      final d = PersonalDictionary(store);
      await d.load();
      final added = await d.addAll(['Чужое', 'свое', 'ещё']);
      expect(added, 2);
      expect(d.words, ['еще', 'свое', 'чужое']);
      expect(store.words, containsAll(['свое', 'чужое', 'еще']));
    });

    test('экспорт: свежий список из базы; без связи — из памяти', () async {
      final store = MemDictStore()..words.addAll(['раз']);
      final d = PersonalDictionary(store);
      await d.load();
      store.words.add('два'); // добавили в другой вкладке
      expect(await d.exportWords(), ['два', 'раз']);
      store.fail = true;
      expect(await d.exportWords(), ['раз']);
    });
  });

  group('правки документа', () {
    test('замена слова: оформление первой буквы, остальное не тронуто', () {
      final doc = Document.fromJson([
        {'insert': 'Скажи '},
        {'insert': 'превет', 'attributes': {'bold': true, 'color': '#FF5C5C'}},
        {'insert': ' всем\n', 'attributes': {}},
      ]);
      final d = replaceWordDelta(doc, const TextRange(start: 6, end: 12), 'привет');
      doc.compose(d, ChangeSource.local);
      expect(doc.toDelta().toJson(), [
        {'insert': 'Скажи '},
        {'insert': 'привет', 'attributes': {'bold': true, 'color': '#FF5C5C'}},
        {'insert': ' всем\n'},
      ]);
    });

    test('ссылки и слово у курсора', () {
      final doc = Document.fromJson([
        {'insert': 'см '},
        {'insert': 'ссылкка', 'attributes': {'link': 'https://a.ru'}},
        {'insert': ' тут\n'},
      ]);
      expect(linkRanges(doc.toDelta()), [const TextRange(start: 3, end: 10)]);
      expect(wordAround('один превет два', 9), const TextRange(start: 5, end: 11));
      expect(wordAround('один ', 5), const TextRange(start: 5, end: 5));
    });
  });

  group('резервная копия', () {
    final today = DateTime(2026, 11, 8);
    final note = BackupNote(
        date: '2026-11-01',
        delta: jsonEncode([{'insert': 'день\n'}]),
        text: 'день\n',
        accent: '#B388FF');

    test('словарь в копии и обратно', () {
      final json = encodeBackup([note],
          dictionary: ['вася', 'кострома'],
          today: today,
          createdAtUtc: DateTime.utc(2026, 11, 8));
      final root = jsonDecode(json) as Map;
      expect(root['version'], kBackupVersion);
      expect(root['dictionary'], ['вася', 'кострома']);
      final back = parseBackup(json, today: today);
      expect(back.dictionary, ['вася', 'кострома']);
      expect(back.notes.single.date, '2026-11-01');
    });

    test('копия без словаря и старые файлы (версия 1 и 2) — как раньше', () {
      final json = encodeBackup([note],
          today: today, createdAtUtc: DateTime.utc(2026, 11, 8));
      expect((jsonDecode(json) as Map).containsKey('dictionary'), isFalse);
      for (final v in [1, 2]) {
        final old = jsonEncode({
          'format': 'calendar-notes-backup',
          'version': v,
          'createdAt': '2026-11-08T00:00:00.000Z',
          'dateRange': {'from': '2026-10-01', 'to': '2026-11-08'},
          'notes': [note.toJson()],
          if (v == 2) 'topics': [],
        });
        final b = parseBackup(old, today: today);
        expect(b.notes.single.date, '2026-11-01');
        expect(b.dictionary, isEmpty);
      }
    });

    test('словарь в файле старой версии — ошибка (как любое лишнее поле)', () {
      final bad = jsonEncode({
        'format': 'calendar-notes-backup',
        'version': 2,
        'createdAt': '2026-11-08T00:00:00.000Z',
        'dateRange': {'from': '2026-10-01', 'to': '2026-11-08'},
        'notes': [],
        'dictionary': ['x'],
      });
      expect(() => parseBackup(bad, today: today),
          throwsA(isA<BackupException>()));
    });

    test('неверные слова в разделе словаря — ошибка', () {
      String file(Object dict) => jsonEncode({
            'format': 'calendar-notes-backup',
            'version': 3,
            'createdAt': '2026-11-08T00:00:00.000Z',
            'dateRange': {'from': '2026-10-01', 'to': '2026-11-08'},
            'notes': [],
            'dictionary': dict,
          });
      expect(() => parseBackup(file('x'), today: today),
          throwsA(isA<BackupException>()));
      expect(() => parseBackup(file([1]), today: today),
          throwsA(isA<BackupException>()));
      expect(() => parseBackup(file(['а' * 65]), today: today),
          throwsA(isA<BackupException>()));
      expect(parseBackup(file(['Ёж', 'еж', 'Вася']), today: today).dictionary,
          ['вася', 'еж']);
    });
  });

  group('подчёркивания в редакторе', () {
    late QuillController c;
    late FocusNode focus;
    late GlobalKey<EditorState> key;
    late GlobalKey<SpellCheckHostState> hostKey;
    late SpellEngine engine;
    late FakeBackend backend;
    late ValueNotifier<bool> menuOpen;

    Future<void> settle(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 450)); // пауза проверки
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }

    Future<void> pumpEditor(WidgetTester tester, List<Map<String, dynamic>> ops,
        {bool enabled = true}) async {
      c = QuillController(
          document: Document.fromJson(ops),
          selection: const TextSelection.collapsed(offset: 0));
      focus = FocusNode();
      key = GlobalKey<EditorState>();
      hostKey = GlobalKey<SpellCheckHostState>();
      backend = FakeBackend();
      final prefs = MemPrefs();
      if (!enabled) prefs.data[SpellPref.storageKey] = '0';
      engine = engineWith(backend, prefs: prefs);
      menuOpen = ValueNotifier(false);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 300,
            child: SpellCheckHost(
              key: hostKey,
              controller: c,
              focusNode: focus,
              editorKey: key,
              engine: engine,
              menuOpen: menuOpen,
              child: QuillEditor(
                controller: c,
                focusNode: focus,
                scrollController: ScrollController(),
                config: QuillEditorConfig(editorKey: key, expands: true),
              ),
            ),
          ),
        ),
      ));
      await tester.runAsync(() async {
        engine.start();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await settle(tester);
    }

    List<String> hits() {
      final s = hostKey.currentState!;
      final text = c.document.toPlainText();
      return [
        for (final h in s.hitsBetween(0, text.length))
          text.substring(h.range.start, h.range.end)
      ];
    }

    testWidgets('слово с ошибкой отмечено; документ не меняется ни на байт',
        (tester) async {
      await pumpEditor(tester, [
        {'insert': 'Скажи превет всем и hello teh\n'}
      ]);
      final before = jsonEncode(c.document.toDelta().toJson());
      expect(hits(), ['Скажи', 'превет', 'всем', 'teh']);
      expect(jsonEncode(c.document.toDelta().toJson()), before);
      expect(c.document.history.hasUndo, isFalse); // и в истории ничего
    });

    testWidgets('выключено — ничего не подчёркнуто и не проверяется',
        (tester) async {
      await pumpEditor(tester, [
        {'insert': 'превет\n'}
      ], enabled: false);
      expect(hits(), isEmpty);
      expect(backend.asked, isEmpty);
      expect(backend.startCalls, 0);
    });

    testWidgets('ссылка не подчёркивается', (tester) async {
      await pumpEditor(tester, [
        {'insert': 'превет', 'attributes': {'link': 'https://a.ru'}},
        {'insert': ' превет\n'},
      ]);
      expect(hits(), ['превет']);
      final h = hostKey.currentState!.hitsBetween(0, 20).single;
      expect(h.range.start, 7);
    });

    testWidgets('набираемое слово не подчёркивается, пока курсор в нём',
        (tester) async {
      await pumpEditor(tester, [
        {'insert': 'привет\n'}
      ]);
      expect(hits(), isEmpty);
      // набираем «превет» в конце строки — курсор остаётся в слове
      c.replaceText(6, 0, ' превет', const TextSelection.collapsed(offset: 13));
      await settle(tester);
      expect(hits(), isEmpty);
      // курсор ушёл
      c.updateSelection(
          const TextSelection.collapsed(offset: 0), ChangeSource.local);
      await tester.pump();
      expect(hits(), ['превет']);
    });

    testWidgets('правка одной строки — перепроверяется только она',
        (tester) async {
      await pumpEditor(tester, [
        {'insert': 'превет раз\nпревет два\nпривет\n'}
      ]);
      backend.asked.clear();
      c.replaceText(0, 0, 'новое ', const TextSelection.collapsed(offset: 0));
      await settle(tester);
      // спросили только новое слово; «превет», «два»… — из кэша сеанса
      expect(backend.asked, ['новое']);
    });

    testWidgets('проверка — через 400 мс после последней правки', (tester) async {
      await pumpEditor(tester, [
        {'insert': 'привет\n'}
      ]);
      backend.asked.clear();
      c.replaceText(0, 0, 'один ', const TextSelection.collapsed(offset: 0));
      await tester.pump(const Duration(milliseconds: 200));
      c.replaceText(0, 0, 'два ', const TextSelection.collapsed(offset: 0));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      expect(backend.asked, isEmpty); // правки идут — ждём
      await settle(tester);
      expect(backend.asked.toSet(), {'один', 'два'}); // одна проверка на обе
    });

    testWidgets('слово в личном словаре — подчёркивание пропадает везде',
        (tester) async {
      await pumpEditor(tester, [
        {'insert': 'превет\nпревет\n'}
      ]);
      expect(hits(), ['превет', 'превет']);
      await tester.runAsync(() => engine.dictionary.add('превет'));
      await settle(tester);
      expect(hits(), isEmpty);
    });

    testWidgets('другой документ (день/тема) — подчёркивания пересчитаны',
        (tester) async {
      await pumpEditor(tester, [
        {'insert': 'превет\n'}
      ]);
      expect(hits(), ['превет']);
      c.document = Document.fromJson([
        {'insert': 'hello teh\n'}
      ]);
      await settle(tester);
      expect(hits(), ['teh']);
    });

    testWidgets('правый щелчок по слову: выделяет, варианты, замена', (tester) async {
      await pumpEditor(tester, [
        {'insert': 'Скажи '},
        {'insert': 'превет', 'attributes': {'bold': true}},
        {'insert': '\n'},
      ]);
      final s = hostKey.currentState!;
      final hit = s.hitsBetween(0, 20).firstWhere((h) => h.range.start == 6);
      s.openMenu(hit, const Offset(100, 100));
      await settle(tester);
      expect(c.selection, const TextSelection(baseOffset: 6, extentOffset: 12));
      expect(menuOpen.value, isTrue);
      expect(find.text('привет'), findsOneWidget);
      expect(find.text('Добавить в словарь'), findsOneWidget);
      await tester.tap(find.text('привет'));
      await settle(tester);
      expect(c.document.toDelta().toJson(), [
        {'insert': 'Скажи '},
        {'insert': 'привет', 'attributes': {'bold': true}},
        {'insert': '\n'},
      ]);
      expect(c.selection, const TextSelection.collapsed(offset: 12));
      expect(menuOpen.value, isFalse);
      expect(c.hasUndo, isTrue); // Ctrl+Z отменит замену
    });

    testWidgets('нет вариантов — «Нет вариантов»; добавить в словарь',
        (tester) async {
      await pumpEditor(tester, [
        {'insert': 'Кострома\n'}
      ]);
      final s = hostKey.currentState!;
      s.openMenu(s.hitsBetween(0, 20).single, const Offset(50, 50));
      await settle(tester);
      expect(find.text('Нет вариантов'), findsOneWidget);
      await tester.tap(find.text('Добавить в словарь'));
      await settle(tester);
      expect(engine.dictionary.contains('кострома'), isTrue);
      expect(hits(), isEmpty);
      expect(find.text('Добавлено в словарь'), findsOneWidget);
      // небольшое тёмное плавающее окошко, а не белая полоса во всю ширину
      final snack = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snack.behavior, SnackBarBehavior.floating);
      expect(snack.backgroundColor, kSurface);
      expect(snack.width, lessThanOrEqualTo(320));
      // «Отменить» в уведомлении (вызываем его действие)
      tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
      await settle(tester);
      expect(engine.dictionary.contains('кострома'), isFalse);
      expect(hits(), ['Кострома']);
    });

    testWidgets('Esc закрывает меню', (tester) async {
      await pumpEditor(tester, [
        {'insert': 'превет\n'}
      ]);
      final s = hostKey.currentState!;
      s.openMenu(s.hitsBetween(0, 20).single, const Offset(50, 50));
      await settle(tester);
      expect(find.text('Добавить в словарь'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Добавить в словарь'), findsNothing);
      expect(menuOpen.value, isFalse);
    });

    testWidgets('правый щелчок мимо ошибок — наше меню не появляется',
        (tester) async {
      await pumpEditor(tester, [
        {'insert': 'привет\n'}
      ]);
      final center = tester.getCenter(find.byType(QuillEditor));
      final g = await tester.startGesture(center,
          kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await g.up();
      await settle(tester);
      expect(find.text('Добавить в словарь'), findsNothing);
      expect(menuOpen.value, isFalse);
    });
  });

  group('зависший словарь (аудит, F12)', () {
    SpellEngine hungEngine(HungBackend b) => SpellEngine(
          backend: b,
          dictionary: PersonalDictionary(MemDictStore()),
          pref: SpellPref(MemPrefs()),
          startDelay: Duration.zero,
          requestTimeout: const Duration(milliseconds: 50),
        );

    test('варианты не приходят — пустой список, меню не висит', () async {
      final e = hungEngine(HungBackend());
      e.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(e.active, isTrue);
      final clock = Stopwatch()..start();
      final list = await e.suggestions(spellTokens('превет').single);
      expect(list, isEmpty);
      expect(clock.elapsedMilliseconds, lessThan(2000));
      e.dispose();
    });

    test('проверка не приходит — ошибка (подчеркнём при следующей правке)',
        () async {
      final e = hungEngine(HungBackend());
      e.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await expectLater(e.checkTokens(spellTokens('превет мир')),
          throwsA(isA<TimeoutException>()));
      e.dispose();
    });

    test('по умолчанию ждём 10 с', () {
      final e = engineWith(FakeBackend());
      expect(e.requestTimeout, const Duration(seconds: 10));
      e.dispose();
    });
  });
}

/// Словарь загрузился, но на запросы не отвечает
class HungBackend implements SpellBackend {
  @override
  Future<void> start() async {}

  @override
  Future<List<bool>> check(String lang, List<String> words) =>
      Completer<List<bool>>().future;

  @override
  Future<List<String>> suggest(String lang, String word) =>
      Completer<List<String>>().future;

  @override
  void dispose() {}
}
