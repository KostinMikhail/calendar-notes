import 'dart:async';
import 'dart:convert';

import 'package:calendar_notes/main.dart' show isWorkingDay;
import 'package:calendar_notes/tasks.dart';
import 'package:calendar_notes/templates.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------- помощники ----------

Map<String, dynamic> nl(Map<String, dynamic>? attrs) =>
    {'insert': '\n', 'attributes': ?attrs};
const task = {'list': 'ordered', 'task': 'open'};
const done = {'list': 'ordered', 'task': 'done'};
const sub1 = {'list': 'ordered', 'indent': 1};
const sub2 = {'list': 'ordered', 'indent': 2};
const divider = {
  'insert': {'divider': 'hr'},
};

/// Строки документа: текст и атрибуты перевода строки
List<String> rows(List<dynamic> ops) => [
      for (final l in opsToLines(ops))
        '${l.isDivider ? '---' : l.plainText}|${jsonEncode(l.attrs ?? {})}',
    ];

List<String> docRows(Document d) => rows(d.toDelta().toJson());

Document doc(List<Map<String, dynamic>> ops) => Document.fromJson(ops);

/// Типичный день: блок задач, разделитель, следующий блок
List<Map<String, dynamic>> day({List<Map<String, dynamic>>? items}) => [
      {'insert': 'Задачи на день:\n'},
      ...items ??
          [
            {'insert': 'первая'},
            nl(task),
            nl(task),
          ],
      divider,
      {'insert': '\nАИ дейли:\nпункт'},
      nl({'list': 'ordered'}),
    ];

TaskGroup groupOf(List<Map<String, dynamic>> ops, int line) =>
    taskGroupAt(opsToLines(Document.fromJson(ops).toDelta().toJson()), line)!;

class FakeStore implements TaskNoteStore {
  final Map<String, NoteData> notes = {};
  int writes = 0;
  Object? failWith;

  @override
  Future<void> transact(
      String key, NoteData? Function(NoteData? current) modify) async {
    if (failWith != null) throw failWith!;
    final next = modify(notes[key]);
    if (next != null) {
      notes[key] = next;
      writes++;
    }
  }
}

TemplateComposition template(List<Map<String, dynamic>> ops) =>
    TemplateComposition(
        linesToOps(markTaskSection(opsToLines(ops))), '#B388FF');

void main() {
  // ============================================================
  group('состояния', () {
    test('✓ и ✗ включают, повтор выключает, обе сразу не бывают', () {
      var s = taskStep(TaskState.open, TaskControl.check);
      expect((s.to, s.carry, s.uncarry), (TaskState.done, false, false));
      s = taskStep(TaskState.done, TaskControl.check);
      expect((s.to, s.carry, s.uncarry), (TaskState.open, false, false));
      s = taskStep(TaskState.open, TaskControl.cross);
      expect((s.to, s.carry, s.uncarry), (TaskState.carried, true, false));
      s = taskStep(TaskState.carried, TaskControl.cross);
      expect((s.to, s.carry, s.uncarry), (TaskState.open, false, true));
      // переключение с одной кнопки на другую
      s = taskStep(TaskState.done, TaskControl.cross);
      expect((s.to, s.carry, s.uncarry), (TaskState.carried, true, false));
      s = taskStep(TaskState.carried, TaskControl.check);
      expect((s.to, s.carry, s.uncarry), (TaskState.done, false, true));
    });

    test('значение атрибута', () {
      expect(TaskValue.parse('open'), TaskValue.open);
      expect(TaskValue.parse('done'), TaskValue.done);
      expect(TaskValue.parse('carried:2026-11-09'),
          const TaskValue.carried('2026-11-09'));
      expect(TaskValue.parse('carried:мусор'), TaskValue.open);
      expect(TaskValue.parse(null), TaskValue.open);
      expect(const TaskValue.carried('2026-11-09').encode(),
          'carried:2026-11-09');
    });
  });

  // ============================================================
  group('следующий рабочий день после даты заметки', () {
    DateTime next(int y, int m, int d) =>
        nextWorkingDay(DateTime(y, m, d), isWorkingDay);

    test('будни, пятница, выходные', () {
      expect(next(2026, 11, 9), DateTime(2026, 11, 10)); // пн → вт
      expect(next(2026, 11, 12), DateTime(2026, 11, 13)); // чт → пт
      expect(next(2026, 11, 13), DateTime(2026, 11, 16)); // пт → пн
      expect(next(2026, 11, 14), DateTime(2026, 11, 16)); // сб → пн
      expect(next(2026, 11, 15), DateTime(2026, 11, 16)); // вс → пн
    });

    test('праздники и длинные выходные', () {
      expect(next(2026, 11, 3), DateTime(2026, 11, 5)); // 4 ноября
      expect(next(2026, 12, 30), DateTime(2027, 1, 11)); // Новый год 2027
      expect(next(2027, 5, 7), DateTime(2027, 5, 11)); // 10 мая
      expect(next(2027, 11, 3), DateTime(2027, 11, 8)); // 4–5 ноября
      expect(next(2027, 2, 19), DateTime(2027, 2, 24)); // 22–23 февраля
    });

    test('любой день 2026–2030 (в т.ч. год без таблицы): ближайший рабочий',
        () {
      for (var d = DateTime(2026, 1, 1);
          d.isBefore(DateTime(2031, 1, 1));
          d = DateTime(d.year, d.month, d.day + 1)) {
        final n = nextWorkingDay(d, isWorkingDay);
        expect(n.isAfter(d), isTrue);
        expect(isWorkingDay(n), isTrue, reason: '$d → $n');
        for (var x = DateTime(d.year, d.month, d.day + 1);
            x.isBefore(n);
            x = DateTime(x.year, x.month, x.day + 1)) {
          expect(isWorkingDay(x), isFalse, reason: '$d: $x пропущен');
        }
      }
    });

    test('зависит только от даты заметки (прошлое и будущее)', () {
      expect(next(2020, 3, 6), DateTime(2020, 3, 10)); // пт перед 9 марта
      expect(next(2035, 6, 1), nextWorkingDay(DateTime(2035, 6, 1), isWorkingDay));
    });

    test('подпись даты и ключ дня', () {
      expect(formatTaskDate(DateTime(2026, 11, 16)), 'понедельник, 16 ноября');
      expect(dayKeyOf(DateTime(2027, 1, 4)), '2027-01-04');
      expect(parseDayKey('2027-01-04'), DateTime(2027, 1, 4));
      expect(parseDayKey('2027-02-30'), isNull);
      expect(parseDayKey('t:abc'), isNull);
    });
  });

  // ============================================================
  group('блок задач в Delta', () {
    test('блок до разделителя, до заголовка, в конце, отсутствует', () {
      var s = findTaskSection([
        for (final l in opsToLines(day())) LineShape(
            text: l.isEmpty ? '' : l.plainText,
            isList: l.attrs?['list'] != null,
            isDivider: l.isDivider),
      ]);
      expect(s, (heading: 0, end: 3));

      s = findTaskSection(const [
        LineShape(text: 'Задачи на день:', isList: false, isDivider: false),
        LineShape(text: 'a', isList: true, isDivider: false),
        LineShape(text: '', isList: false, isDivider: false), // пустая — в блоке
        LineShape(text: 'Другое:', isList: false, isDivider: false),
      ]);
      expect(s, (heading: 0, end: 3));

      s = findTaskSection(const [
        LineShape(text: 'x', isList: false, isDivider: false),
        LineShape(text: 'Задачи на день:', isList: false, isDivider: false),
        LineShape(text: 'a', isList: true, isDivider: false),
      ]);
      expect(s, (heading: 1, end: 3));

      expect(
          findTaskSection(const [
            LineShape(text: 'Не забыть:', isList: false, isDivider: false),
          ]),
          isNull);
    });

    test('шаблон: пункты блока — задачи, остальное не трогается', () {
      final out = markTaskSection(opsToLines([
        {'insert': 'Задачи на день:\nготовый'},
        nl({'list': 'ordered'}),
        {'insert': 'маркер'},
        nl({'list': 'bullet'}),
        {'insert': 'вложенный'},
        nl(sub1),
        divider,
        {'insert': '\nАИ дейли:\n'},
        nl({'list': 'ordered'}),
      ]));
      expect(rows(linesToOps(out)), [
        'Задачи на день:|{}',
        'готовый|{"list":"ordered","task":"open"}',
        'маркер|{"list":"ordered","task":"open"}',
        'вложенный|{"list":"ordered","indent":1}',
        '|{"list":"ordered","task":"open"}', // пустая задача добавлена
        '---|{}',
        'АИ дейли:|{}',
        '|{"list":"ordered"}',
      ]);
    });

    test('группа: задача и её подпункты (до следующей задачи)', () {
      final ops = day(items: [
        {'insert': 'задача'},
        nl(task),
        {'insert': 'а'},
        nl(sub1),
        {'insert': 'i'},
        nl(sub2),
        {'insert': 'другая'},
        nl(task),
      ]);
      final g = groupOf(ops, 1);
      expect(g.task.plainText, 'задача');
      expect(g.subs.map((l) => l.plainText), ['а', 'i']);
      expect(groupOf(ops, 4).subs, isEmpty);
      expect(taskGroupAt(opsToLines(ops), 2), isNull); // подпункт
      expect(taskGroupAt(opsToLines(ops), 0), isNull); // заголовок
    });

    test('перенос: в конец блока (перед пустой задачей), оформление цело', () {
      final src = groupOf(day(items: [
        {'insert': 'см. '},
        {
          'insert': 'ссылку',
          'attributes': {'link': 'https://example.com', 'bold': true},
        },
        nl(done),
        {'insert': 'а'},
        nl(sub1),
        {'insert': 'i'},
        nl(sub2),
      ]), 1);
      final out = insertTaskGroup(opsToLines(day()), src)!;
      expect(rows(linesToOps(out)), [
        'Задачи на день:|{}',
        'первая|{"list":"ordered","task":"open"}',
        'см. ссылку|{"list":"ordered","task":"open"}', // открытая
        'а|{"list":"ordered","indent":1}',
        'i|{"list":"ordered","indent":2}',
        '|{"list":"ordered","task":"open"}', // пустая — в конце
        '---|{}',
        'АИ дейли:|{}',
        'пункт|{"list":"ordered"}',
      ]);
      // ссылка и жирный сохранены
      final copied = out[2].inline;
      expect(copied[1]['attributes'],
          {'link': 'https://example.com', 'bold': true});
    });

    test('повтор не добавляется; изменённая копия — уже другая задача', () {
      final g = groupOf(day(), 1); // «первая» без подпунктов
      expect(insertTaskGroup(opsToLines(day()), g), isNull);
      final g2 = groupOf(day(items: [
        {'insert': 'первая'},
        nl(task),
        {'insert': 'подпункт'},
        nl(sub1),
      ]), 1);
      expect(insertTaskGroup(opsToLines(day()), g2), isNotNull);
    });

    test('блока нет — разделитель, заголовок и задача в конце документа', () {
      final g = groupOf(day(), 1);
      final out = insertTaskGroup(
          opsToLines([
            {'insert': 'Заметка\n\n'},
          ]),
          g)!;
      expect(rows(linesToOps(out)), [
        'Заметка|{}',
        '---|{}',
        'Задачи на день:|{}',
        'первая|{"list":"ordered","task":"open"}',
      ]);
      // пустой документ — только заголовок и задача
      expect(rows(linesToOps(insertTaskGroup(opsToLines([nl(null)]), g)!)), [
        'Задачи на день:|{}',
        'первая|{"list":"ordered","task":"open"}',
      ]);
    });

    test('отмена переноса: только нетронутая копия, только первая', () {
      final g = groupOf(day(items: [
        {'insert': 'дело'},
        nl(done),
        {'insert': 'а'},
        nl(sub1),
      ]), 1);
      final once = insertTaskGroup(opsToLines(day()), g)!;
      // нетронутая — убирается
      expect(rows(linesToOps(removeTaskGroup(once, g)!)),
          rows(linesToOps(opsToLines(day()))));

      // отмечена там выполненной — остаётся
      final ticked = [...once];
      ticked[2] = TemplateLine(ticked[2].inline, {...ticked[2].attrs!, 'task': 'done'});
      expect(removeTaskGroup(ticked, g), isNull);

      // текст изменён — остаётся
      final edited = [...once];
      edited[2] = TemplateLine([
        {'insert': 'дело!'},
      ], edited[2].attrs);
      expect(removeTaskGroup(edited, g), isNull);

      // добавлен подпункт — остаётся
      final extended = [...once]
        ..insert(4, TemplateLine([
          {'insert': 'б'},
        ], sub1));
      expect(removeTaskGroup(extended, g), isNull);

      // две копии — убирается одна (первая)
      final twice = [...once]..insertAll(4, g.copyLines());
      final left = removeTaskGroup(twice, g)!;
      expect(left.where((l) => l.plainText == 'дело').length, 1);
    });

    test('пустую задачу переносить нельзя', () {
      expect(groupOf(day(), 2).isBlank, isTrue);
      expect(groupOf(day(), 1).isBlank, isFalse);
    });
  });

  // ============================================================
  group('запись в другой день (поддельное хранилище)', () {
    final g = groupOf(day(items: [
      {'insert': 'перенести'},
      nl(task),
      {'insert': 'деталь'},
      nl(sub1),
    ]), 1);

    test('заметки нет — создаётся из шаблона дня с задачей', () async {
      final store = FakeStore();
      final out = await TaskCarrier(store).carry(
          targetKey: '2026-11-16',
          group: g,
          emptyNote: template(day()),
          label: 'понедельник, 16 ноября');
      expect(out, CarryOutcome.added);
      final n = store.notes['2026-11-16']!;
      expect(rows(jsonDecode(n.delta) as List), [
        'Задачи на день:|{}',
        'первая|{"list":"ordered","task":"open"}',
        'перенести|{"list":"ordered","task":"open"}',
        'деталь|{"list":"ordered","indent":1}',
        '|{"list":"ordered","task":"open"}',
        '---|{}',
        'АИ дейли:|{}',
        'пункт|{"list":"ordered"}',
      ]);
      expect(n.accent, '#B388FF');
      // text — как при обычном сохранении (без отметок и объектов)
      expect(n.text,
          'Задачи на день:\nпервая\nперенести\nдеталь\n\n\nАИ дейли:\nпункт\n');
    });

    test('заметка есть — в её блок; повтор — без записи', () async {
      final store = FakeStore()
        ..notes['2026-11-16'] = NoteData(
            delta: jsonEncode(day()), text: 'x', accent: '#FF5C5C');
      final c = TaskCarrier(store);
      expect(
          await c.carry(
              targetKey: '2026-11-16',
              group: g,
              emptyNote: template(const []),
              label: 'x'),
          CarryOutcome.added);
      expect(store.notes['2026-11-16']!.accent, '#FF5C5C');
      expect(
          await c.carry(
              targetKey: '2026-11-16',
              group: g,
              emptyNote: template(const []),
              label: 'x'),
          CarryOutcome.duplicate);
      expect(store.writes, 1);
    });

    test('старая заметка только с текстом', () async {
      final store = FakeStore()
        ..notes['2026-11-16'] =
            const NoteData(delta: '', text: 'старый текст\n', accent: '');
      await TaskCarrier(store).carry(
          targetKey: '2026-11-16',
          group: g,
          emptyNote: template(day()),
          label: 'x');
      expect(rows(jsonDecode(store.notes['2026-11-16']!.delta) as List), [
        'старый текст|{}',
        '---|{}',
        'Задачи на день:|{}',
        'перенести|{"list":"ordered","task":"open"}',
        'деталь|{"list":"ordered","indent":1}',
      ]);
    });

    test('слишком большая заметка — ошибка, ничего не записано', () async {
      final big = 'x' * 200001;
      final store = FakeStore()
        ..notes['2026-11-16'] = NoteData(
            delta: jsonEncode([
              {'insert': '$big\n'},
              ...day(),
            ]),
            text: big,
            accent: '');
      await expectLater(
          TaskCarrier(store).carry(
              targetKey: '2026-11-16',
              group: g,
              emptyNote: template(const []),
              label: 'понедельник, 16 ноября'),
          throwsA(isA<TaskCarryError>().having((e) => e.message, 'message',
              contains('понедельник, 16 ноября'))));
      expect(store.writes, 0);
    });

    test('ошибка хранилища (нет сети) — пробрасывается', () async {
      final store = FakeStore()..failWith = Exception('offline');
      await expectLater(
          TaskCarrier(store).carry(
              targetKey: '2026-11-16',
              group: g,
              emptyNote: template(day()),
              label: 'x'),
          throwsException);
      expect(store.notes, isEmpty);
    });

    test('отмена: убрана / изменена / заметки нет', () async {
      final store = FakeStore();
      final c = TaskCarrier(store);
      expect(await c.uncarry(targetKey: '2026-11-16', group: g, label: 'x'),
          UncarryOutcome.missing);
      await c.carry(
          targetKey: '2026-11-16',
          group: g,
          emptyNote: template(day()),
          label: 'x');
      expect(await c.uncarry(targetKey: '2026-11-16', group: g, label: 'x'),
          UncarryOutcome.removed);
      expect(rows(jsonDecode(store.notes['2026-11-16']!.delta) as List),
          rows(linesToOps(markTaskSection(opsToLines(day())))));
      expect(await c.uncarry(targetKey: '2026-11-16', group: g, label: 'x'),
          UncarryOutcome.modified);
    });
  });

  // ============================================================
  group('клавиши в редакторе', () {
    TextSelection at(int o) => TextSelection.collapsed(offset: o);
    Document apply(Document d, TaskEdit? e) {
      expect(e, isNotNull);
      if (e!.delta.isNotEmpty) d.compose(e.delta, ChangeSource.local);
      return d;
    }

    // «Задачи на день:\n» = 16 символов; задача «купить» — 16..22
    List<Map<String, dynamic>> base({Map<String, dynamic> state = done}) => [
          {'insert': 'Задачи на день:\nкупить'},
          nl(state),
          divider,
          {'insert': '\nДругое:\n'},
        ];

    test('Enter в конце задачи — ниже новая открытая, своя — как была', () {
      final d = doc(base());
      final e = planTaskEnter(d, at(22))!;
      apply(d, e);
      expect(docRows(d).take(3), [
        'Задачи на день:|{}',
        'купить|{"list":"ordered","task":"done"}',
        '|{"list":"ordered","task":"open"}',
      ]);
      expect(e.caret, 23);
    });

    test('Enter в середине задачи — хвост уходит в новую открытую', () {
      final d = doc([
        {'insert': 'Задачи на день:\nку'},
        {
          'insert': 'пить',
          'attributes': {'bold': true},
        },
        nl(done),
      ]);
      apply(d, planTaskEnter(d, at(18)));
      expect(docRows(d), [
        'Задачи на день:|{}',
        'ку|{"list":"ordered","task":"done"}',
        'пить|{"list":"ordered","task":"open"}',
      ]);
      expect(d.toDelta().toJson()[2]['attributes'], {'bold': true});
    });

    test('Enter в пустой задаче — обычная строка (выход из списка)', () {
      final d = doc([
        {'insert': 'Задачи на день:\nкупить'},
        nl(task),
        nl(task),
      ]);
      apply(d, planTaskEnter(d, at(23)));
      expect(docRows(d).last, '|{}');
    });

    test('Tab — подпункт «a.» без кнопок; у первой задачи — ничего', () {
      final d = doc([
        {'insert': 'Задачи на день:\nпервая'},
        nl(task),
        {'insert': 'вторая'},
        nl(done),
      ]);
      final first = planTaskTab(d, at(17), shift: false)!;
      expect(first.delta.isEmpty, isTrue);
      apply(d, planTaskTab(d, at(25), shift: false));
      expect(docRows(d).last, 'вторая|{"list":"ordered","indent":1}');
      final idx = TaskIndex.build(d, TaskMode.interactive);
      expect(idx.byLine.values.map((i) => i.kind),
          [TaskLineKind.task, TaskLineKind.sub]);
      // Tab в подпункте — ровно на уровень глубже («i.»), Shift+Tab — назад
      apply(d, planTaskTab(d, at(25), shift: false));
      expect(docRows(d).last, 'вторая|{"list":"ordered","indent":2}');
      apply(d, planTaskTab(d, at(25), shift: true));
      expect(docRows(d).last, 'вторая|{"list":"ordered","indent":1}');
      // Shift+Tab в задаче — ничего
      expect(planTaskTab(d, at(17), shift: true)!.delta.isEmpty, isTrue);
    });

    test('Enter/Shift+Tab/Backspace в «a.» — снова открытая задача', () {
      List<Map<String, dynamic>> withSub(String text) => [
            {'insert': 'Задачи на день:\nзадача'},
            nl(task),
            if (text.isNotEmpty) {'insert': text},
            nl(sub1),
          ];
      // пустой подпункт + Enter
      var d = doc(withSub(''));
      apply(d, planTaskEnter(d, at(23)));
      expect(docRows(d).last, '|{"list":"ordered","task":"open"}');
      // Shift+Tab
      d = doc(withSub('деталь'));
      apply(d, planTaskTab(d, at(25), shift: true));
      expect(docRows(d).last, 'деталь|{"list":"ordered","task":"open"}');
      // Backspace в начале
      d = doc(withSub('деталь'));
      apply(d, planTaskBackspace(d, at(23)));
      expect(docRows(d).last, 'деталь|{"list":"ordered","task":"open"}');
      // пустой «i.» + Enter → «a.»
      d = doc([
        {'insert': 'Задачи на день:\nзадача'},
        nl(task),
        {'insert': 'а'},
        nl(sub1),
        nl(sub2),
      ]);
      apply(d, planTaskEnter(d, at(25)));
      expect(docRows(d).last, '|{"list":"ordered","indent":1}');
      // непустой подпункт + Enter — обычное поведение
      d = doc(withSub('деталь'));
      expect(planTaskEnter(d, at(29)), isNull);
    });

    test('Backspace в пустой задаче — снимает отметку', () {
      final d = doc([
        {'insert': 'Задачи на день:\nзадача'},
        nl(task),
        nl(done),
      ]);
      apply(d, planTaskBackspace(d, at(23)));
      expect(docRows(d).last, '|{}');
      // в начале непустой задачи — обычное поведение
      expect(planTaskBackspace(doc(base()), at(16)), isNull);
    });

    test('Enter в конце заголовка блока без пунктов — первая задача', () {
      final d = doc([
        {'insert': 'Задачи на день:\n'},
        divider,
        {'insert': '\n'},
      ]);
      final e = planTaskEnter(d, at(15))!;
      apply(d, e);
      expect(docRows(d).take(2),
          ['Задачи на день:|{}', '|{"list":"ordered","task":"open"}']);
      expect(e.caret, 16);
      // в блоке есть пункты — обычный Enter
      expect(planTaskEnter(doc(base()), at(15)), isNull);
    });

    test('вне блока задач — всё как раньше', () {
      final d = doc([
        {'insert': 'Другое:\nпункт'},
        nl({'list': 'ordered'}),
      ]);
      expect(planTaskEnter(d, at(13)), isNull);
      expect(planTaskTab(d, at(8), shift: false), isNull);
      expect(planTaskBackspace(d, at(8)), isNull);
    });

    test('списки (Ctrl+Shift+7/8) не трогают задачи', () {
      final d = doc(base());
      expect(selectionTouchesTask(d, at(18)), isTrue);
      expect(selectionTouchesTask(d, at(3)), isFalse);
      expect(selectionTouchesTask(d, at(27)), isFalse);
    });
  });

  // ============================================================
  group('чистка после изменений', () {
    Document change(Document d, Delta delta) {
      d.compose(delta, ChangeSource.local);
      return d;
    }

    DocChange last(Document before, Delta delta) =>
        DocChange(before.toDelta(), delta, ChangeSource.local);

    test('отметка у подпункта или не-списка снимается', () {
      final d = doc([
        {'insert': 'Задачи на день:\nзадача'},
        nl({'list': 'ordered', 'indent': 1, 'task': 'done'}),
        {'insert': 'абзац'},
        nl({'task': 'open'}),
      ]);
      final before = Document.fromDelta(d.toDelta());
      final delta = Delta()..retain(1); // документ не менялся
      final fix =
          sanitizeTasks(d, last(before, delta), TaskMode.interactive)!;
      d.compose(fix, ChangeSource.local);
      expect(docRows(d), [
        'Задачи на день:|{}',
        'задача|{"list":"ordered","indent":1}',
        'абзац|{}',
      ]);
    });

    test('вставленная вне блока задача — обычный пункт', () {
      final d = doc([
        {'insert': 'Задачи на день:\nзадача'},
        nl(task),
        divider,
        {'insert': '\nДругое:\nхвост\n'},
      ]);
      final before = Document.fromDelta(d.toDelta());
      final delta = Delta()
        ..retain(33)
        ..insert('копия')
        ..insert('\n', done);
      change(d, delta);
      final fix = sanitizeTasks(d, last(before, delta), TaskMode.interactive,
          fromPaste: true)!;
      d.compose(fix, ChangeSource.local);
      expect(docRows(d)[4], 'копия|{"list":"ordered"}');
      expect(docRows(d)[1], 'задача|{"list":"ordered","task":"open"}');
    });

    test('вставка в блок: строки — открытые задачи, отметки сброшены', () {
      final d = doc([
        {'insert': 'Задачи на день:\nзадача'},
        nl(task),
        divider,
        {'insert': '\n'},
      ]);
      final before = Document.fromDelta(d.toDelta());
      final delta = Delta()
        ..retain(23)
        ..insert('просто строка\n')
        ..insert('маркер')
        ..insert('\n', {'list': 'bullet'})
        ..insert('сделано')
        ..insert('\n', done)
        ..insert('деталь')
        ..insert('\n', sub1);
      change(d, delta);
      final fix = sanitizeTasks(d, last(before, delta), TaskMode.interactive,
          fromPaste: true)!;
      d.compose(fix, ChangeSource.local);
      expect(docRows(d).sublist(2, 6), [
        'просто строка|{"list":"ordered","task":"open"}',
        'маркер|{"list":"ordered","task":"open"}',
        'сделано|{"list":"ordered","task":"open"}',
        'деталь|{"list":"ordered","indent":1}',
      ]);
    });

    test('не вставка (например, отмена удаления) — состояние сохраняется',
        () {
      final d = doc([
        {'insert': 'Задачи на день:\nзадача'},
        nl(task),
        nl(task),
      ]);
      final before = Document.fromDelta(d.toDelta());
      final delta = Delta()
        ..retain(23)
        ..insert('сделано')
        ..insert('\n', done);
      change(d, delta);
      expect(sanitizeTasks(d, last(before, delta), TaskMode.interactive),
          isNull);
    });

    test('в темах и в шаблонах отметок задач нет', () {
      final d = doc([
        {'insert': 'Задачи на день:\nзадача'},
        nl(done),
      ]);
      final before = Document.fromDelta(d.toDelta());
      final delta = Delta()..retain(1);
      for (final mode in [TaskMode.off, TaskMode.inert]) {
        final fix = sanitizeTasks(d, last(before, delta), mode)!;
        final copy = Document.fromDelta(d.toDelta())
          ..compose(fix, ChangeSource.local);
        expect(docRows(copy).last, 'задача|{"list":"ordered"}');
      }
    });

    test('старая заметка без отметок — не переделывается', () {
      final d = doc([
        {'insert': 'Задачи на день:\nстарый пункт'},
        nl({'list': 'ordered'}),
      ]);
      final before = Document.fromDelta(d.toDelta());
      final delta = Delta()
        ..retain(17)
        ..insert('ы');
      change(d, delta);
      expect(sanitizeTasks(d, last(before, delta), TaskMode.interactive),
          isNull);
      expect(TaskIndex.build(d, TaskMode.interactive).byLine, isEmpty);
    });
  });

  // ============================================================
  group('доработки', () {
    test('подпункты — в состоянии своей задачи (перенесена / открыта)', () {
      final d = doc([
        {'insert': 'Задачи на день:\nперенесённая'},
        nl({'list': 'ordered', 'task': 'carried:2026-11-16'}),
        {'insert': 'деталь'},
        nl(sub1),
        {'insert': 'вглубь'},
        nl(sub2),
        {'insert': 'открытая'},
        nl(task),
        {'insert': 'её деталь'},
        nl(sub1),
      ]);
      final states = TaskIndex.build(d, TaskMode.interactive)
          .byLine
          .values
          .map((i) => '${i.line.text}:${i.value.state.name}')
          .toList();
      expect(states, [
        'перенесённая:carried',
        'деталь:carried',
        'вглубь:carried',
        'открытая:open',
        'её деталь:open',
      ]);
    });

    test('подпись окошка: завтра / день недели / дата', () {
      expect(carriedLabel(DateTime(2026, 11, 11), DateTime(2026, 11, 12)),
          'Перенесено на завтра');
      expect(carriedLabel(DateTime(2026, 11, 13), DateTime(2026, 11, 16)),
          'Перенесено на понедельник');
      expect(carriedLabel(DateTime(2026, 11, 3), DateTime(2026, 11, 5)),
          'Перенесено на четверг');
      expect(carriedLabel(DateTime(2026, 12, 30), DateTime(2027, 1, 11)),
          'Перенесено на 11 января');
      // через месяц и через Новый год — «завтра» тоже по календарю
      expect(carriedLabel(DateTime(2026, 12, 31), DateTime(2027, 1, 1)),
          'Перенесено на завтра');
    });

    test('другая вкладка: перенесённая задача вливается поверх своих правок',
        () {
      // вкладка открыла 12-е (база), пользователь дописал текст ниже
      final base = Document.fromJson(day()).toDelta();
      final local = Document.fromJson(day());
      local.insert(local.length - 1, ' мои правки');
      // тем временем в соседней вкладке на 12-е перенесли задачу
      final remoteLines = insertTaskGroup(
          opsToLines(day()),
          groupOf(day(items: [
            {'insert': 'перенесено'},
            nl(task),
            {'insert': 'деталь'},
            nl(sub1),
          ]), 1))!;
      final remote = Document.fromJson(linesToOps(remoteLines)).toDelta();

      final change = rebaseRemoteChange(
          base: base, local: local.toDelta(), remote: remote);
      local.compose(change, ChangeSource.remote);
      final r = docRows(local);
      expect(r, contains('перенесено|{"list":"ordered","task":"open"}'));
      expect(r, contains('деталь|{"list":"ordered","indent":1}'));
      expect(r.last, 'пункт мои правки|{"list":"ordered"}');
    });

    test('другая вкладка без своих правок — просто то, что в базе', () {
      final base = Document.fromJson(day()).toDelta();
      final remoteDoc = Document.fromJson(day())..insert(16, 'новое ');
      final local = Document.fromDelta(base);
      local.compose(
          rebaseRemoteChange(
              base: base, local: local.toDelta(), remote: remoteDoc.toDelta()),
          ChangeSource.remote);
      expect(local.toDelta(), remoteDoc.toDelta());
      // ничего нового — пустое изменение
      expect(
          rebaseRemoteChange(base: base, local: base, remote: base).isEmpty,
          isTrue);
    });
  });

  group('разметка строк', () {
    test('задачи и подпункты — только внутри блока', () {
      final d = doc([
        {'insert': 'Задачи на день:\nзадача'},
        nl(done),
        {'insert': 'деталь'},
        nl(sub1),
        divider,
        {'insert': '\nДругое:\nчужая'},
        nl(task), // отметка вне блока — без кнопок
      ]);
      final idx = TaskIndex.build(d, TaskMode.interactive);
      expect(
          idx.byLine.values.map((i) => '${i.line.text}:${i.kind.name}:'
              '${i.value.encode()}'),
          // подпункт показывается в состоянии своей задачи
          ['задача:task:done', 'деталь:sub:done']);
      expect(TaskIndex.build(d, TaskMode.off).byLine, isEmpty);
      // в шаблонах — все пункты верхнего уровня блока, всегда «открыта»
      final inert = TaskIndex.build(
          doc([
            {'insert': 'Задачи на день:\nпункт'},
            nl({'list': 'ordered'}),
          ]),
          TaskMode.inert);
      expect(inert.byLine.values.single.value, TaskValue.open);
    });

    test('поле text (поиск) не зависит от отметок', () {
      final a = doc([
        {'insert': 'Задачи на день:\nзадача'},
        nl(done),
      ]);
      final b = doc([
        {'insert': 'Задачи на день:\nзадача'},
        nl({'list': 'ordered'}),
      ]);
      expect(a.toPlainText(), b.toPlainText());
    });
  });

  // ============================================================
  group('кнопки ✗ / ✓', () {
    Future<void> pump(WidgetTester t, Widget w) => t.pumpWidget(
        MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 120, child: w)))));

    testWidgets('нажатия, подсказки, ожидание', (t) async {
      var cross = 0, check = 0;
      await pump(
          t,
          TaskControls(
            value: TaskValue.open,
            crossTooltip: 'Не выполнено — перенести на понедельник, 16 ноября',
            onCross: () => cross++,
            onCheck: () => check++,
          ));
      expect(find.byTooltip('Выполнено'), findsOneWidget);
      expect(
          find.byTooltip('Не выполнено — перенести на понедельник, 16 ноября'),
          findsOneWidget);
      await t.tap(find.byIcon(Icons.close_rounded));
      await t.tap(find.byIcon(Icons.check_rounded));
      expect((cross, check), (1, 1));

      // идёт перенос: ✗ не нажимается
      await pump(
          t,
          TaskControls(
              value: TaskValue.open,
              busy: true,
              crossTooltip: 'x',
              onCross: () => cross++,
              onCheck: () => check++));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.tap(find.byType(CircularProgressIndicator));
      expect(cross, 1);
      expect(t.takeException(), isNull);
    });

    testWidgets('в шаблонах — без нажатий и подсказок', (t) async {
      await pump(t, const TaskControls(value: TaskValue.open, inert: true));
      expect(find.byType(Tooltip), findsNothing);
      expect(find.byType(GestureDetector), findsNothing);
    });
  });

  group('сколько ждать перенос (аудит, F7/F9)', () {
    test('транзакция сдаётся раньше, чем приложение перестаёт ждать', () {
      expect(kTaskTxTimeout, lessThan(kTaskStepWait));
    });

    test('ожидание конца переноса длиннее самого долгого переноса', () {
      // настройки шаблонов + отмена переноса + перенос
      expect(kTaskIdleWait,
          greaterThan(kTaskSettingsWait + kTaskStepWait + kTaskStepWait));
    });

    test('waitUntilIdle: дождались', () async {
      var busy = true;
      Timer(const Duration(milliseconds: 60), () => busy = false);
      final ok = await waitUntilIdle(() => busy,
          max: const Duration(seconds: 2),
          step: const Duration(milliseconds: 10));
      expect(ok, isTrue);
    });

    test('waitUntilIdle: не занято — сразу true', () async {
      final clock = Stopwatch()..start();
      expect(await waitUntilIdle(() => false), isTrue);
      expect(clock.elapsedMilliseconds, lessThan(50));
    });

    test('waitUntilIdle: время вышло — false, не висит', () async {
      final clock = Stopwatch()..start();
      final ok = await waitUntilIdle(() => true,
          max: const Duration(milliseconds: 80),
          step: const Duration(milliseconds: 10));
      expect(ok, isFalse);
      expect(clock.elapsedMilliseconds, lessThan(1000));
    });

    test('нет ответа сервера — отдельный случай', () {
      expect(isTaskTimeout(TimeoutException('x')), isTrue);
      expect(
          isTaskTimeout(FirebaseException(
              plugin: 'cloud_firestore', code: 'deadline-exceeded')),
          isTrue);
      expect(
          isTaskTimeout(FirebaseException(
              plugin: 'cloud_firestore', code: 'permission-denied')),
          isFalse);
      expect(isTaskTimeout(TaskCarryError('x')), isFalse);
    });

    test('текст при тайм-ауте называет день и не обещает ошибку', () {
      final c = taskTimeoutText(carry: true, label: 'пт, 21 ноября');
      expect(c, contains('пт, 21 ноября'));
      expect(c, contains('могла перенестись'));
      expect(c, contains('дубля не создаст'));
      expect(c, isNot(contains('Не удалось')));
      final u = taskTimeoutText(carry: false, label: 'пт, 21 ноября');
      expect(u, contains('пт, 21 ноября'));
      expect(u, contains('могла остаться'));
    });
  });
}
