import 'dart:convert';

import 'package:calendar_notes/backup.dart';
import 'package:flutter_test/flutter_test.dart';

// Насыщенная заметка: жирный, зачёркнутый, ссылка, цвет, списки с вложенностью,
// разделитель-embed — всё, что умеет редактор
const String kRichDelta = '[{"insert":"Задачи на день:"},{"insert":"\\n"},'
    '{"insert":"жирный","attributes":{"bold":true}},{"insert":" и "},'
    '{"insert":"зачёркнутый","attributes":{"strike":true}},'
    '{"insert":"\\n","attributes":{"list":"ordered"}},'
    '{"insert":"ссылка","attributes":{"link":"https://example.com"}},'
    '{"insert":"\\n","attributes":{"list":"ordered","indent":1}},'
    '{"insert":{"divider":"hr"}},{"insert":"\\n"},'
    '{"insert":"Не забыть:","attributes":{"color":"#B388FF"}},{"insert":"\\n"},'
    '{"insert":"красный","attributes":{"color":"#FF5C5C"}},'
    '{"insert":"\\n","attributes":{"list":"bullet"}}]';

const String kEmptyDelta = '[{"insert":"\\n"}]';

Map<String, dynamic> doc(String delta,
        {String text = 'текст\n', String accent = '#FFD54A'}) =>
    {'delta': delta, 'text': text, 'accent': accent};

BackupNote note(String date, [String delta = kEmptyDelta, String text = '\n']) =>
    BackupNote(date: date, delta: delta, text: text, accent: '#FFD54A');

final DateTime today = DateTime(2026, 11, 4);

String backupJson({
  Object? format = 'calendar-notes-backup',
  Object? version = 1,
  Object? createdAt = '2026-11-04T18:00:00.000Z',
  Object? from = '2026-10-01',
  Object? to = '2026-11-04',
  List<Object?>? notes,
  Map<String, Object?> extra = const {},
}) =>
    jsonEncode({
      'format': format,
      'version': version,
      'createdAt': createdAt,
      'dateRange': {'from': from, 'to': to},
      'notes': notes ??
          [
            {
              'date': '2026-10-01',
              'delta': kRichDelta,
              'text': 'x\n',
              'accent': '#FFD54A',
              'updatedAt': '2026-11-04T17:00:00.000Z',
            }
          ],
      ...extra,
    });

Matcher throwsBackup(String part) => throwsA(isA<BackupException>()
    .having((e) => e.message, 'message', contains(part)));

/// Имитация Firestore: set заменяет документ целиком, delete удаляет
class FakeStore implements NoteStore {
  FakeStore(this.data);
  final Map<String, BackupNote> data;
  final List<int> batchSizes = [];
  int commits = 0;
  int? failOnCommit; // номер вызова commit (с 1), который упадёт
  Set<int> alsoFail = {}; // ещё номера вызовов, которые упадут
  bool failRead = false;

  @override
  Future<Map<String, BackupNote?>> readCurrent(List<String> dates) async {
    if (failRead) throw StateError('offline');
    return {for (final d in dates) d: data[d]};
  }

  @override
  Future<void> commit(List<NoteWrite> writes) async {
    commits++;
    if (commits == failOnCommit || alsoFail.contains(commits)) {
      throw StateError('network');
    }
    batchSizes.add(writes.length);
    for (final w in writes) {
      if (w.note == null) {
        data.remove(w.date);
      } else {
        data[w.date] = w.note!;
      }
    }
  }
}

void main() {
  group('экспорт', () {
    test('имя файла и ключ даты', () {
      expect(backupFileName(DateTime(2026, 11, 4, 23, 59)),
          'calendar-notes-backup-2026-11-04.json');
      expect(backupDateKey(DateTime(2026, 1, 5)), '2026-01-05');
    });

    test('период: с 1 октября 2026 по сегодня включительно', () {
      final docs = {
        '2026-09-30': doc(kEmptyDelta),
        '2026-10-01': doc(kRichDelta),
        '2026-10-15': doc(kEmptyDelta),
        '2026-11-04': doc(kEmptyDelta),
        '2026-11-05': doc(kEmptyDelta),
        'not-a-date': doc(kEmptyDelta),
      };
      final list = notesForExport(docs, today: today);
      expect(list.map((n) => n.date),
          ['2026-10-01', '2026-10-15', '2026-11-04']);
    });

    test('Delta сохраняется байт в байт, пустая заметка тоже выгружается', () {
      final list = notesForExport({
        '2026-10-01': doc(kRichDelta, accent: '#B388FF'),
        '2026-10-02': doc(kEmptyDelta, text: '\n'),
      }, today: today);
      expect(list[0].delta, kRichDelta);
      expect(list[0].accent, '#B388FF');
      expect(list[1].delta, kEmptyDelta);
      expect(list[1].text, '\n');
    });

    test('нет заметок — пустой список (файл не создаётся)', () {
      expect(notesForExport({'2026-09-01': doc(kEmptyDelta)}, today: today),
          isEmpty);
    });

    test('повреждённая заметка в базе не выгружается молча', () {
      expect(
          () => notesForExport({'2026-10-01': {'text': 'x'}}, today: today),
          throwsBackup('неожиданном формате'));
    });

    test('файл копии: формат, версия, период и обратный разбор без потерь', () {
      final notes = notesForExport(
          {'2026-10-01': doc(kRichDelta), '2026-10-02': doc(kEmptyDelta)},
          today: today);
      final json = encodeBackup(notes,
          today: today, createdAtUtc: DateTime.utc(2026, 11, 4, 18));
      final root = jsonDecode(json) as Map;
      expect(root['format'], 'calendar-notes-backup');
      // версия 2: добавился необязательный раздел тем
      expect(root['version'], 2);
      expect(root['topics'], isEmpty);
      expect(root['createdAt'], '2026-11-04T18:00:00.000Z');
      expect(root['dateRange'], {'from': '2026-10-01', 'to': '2026-11-04'});
      expect((root['notes'] as List).length, 2);

      final back = parseBackup(json, today: today);
      expect(back.notes.length, 2);
      expect(back.notes[0].delta, kRichDelta);
      expect(back.notes[1].delta, kEmptyDelta);
      expect(back.from, '2026-10-01');
      expect(back.to, '2026-11-04');
    });

    test('в копии нет лишних данных о пользователе', () {
      final json = encodeBackup([note('2026-10-01')],
          today: today, createdAtUtc: DateTime.utc(2026));
      expect(json, isNot(contains('uid')));
      expect(json, isNot(contains('email')));
      expect(json, isNot(contains('token')));
    });
  });

  group('проверка файла', () {
    test('корректный файл принимается', () {
      final data = parseBackup(backupJson(), today: today);
      expect(data.notes.single.date, '2026-10-01');
      expect(data.createdAt, DateTime.utc(2026, 11, 4, 18));
    });

    test('пустая копия разбирается (восстанавливать нечего)', () {
      expect(parseBackup(backupJson(notes: []), today: today).notes, isEmpty);
    });

    test('не JSON', () {
      expect(() => parseBackup('{oops', today: today), throwsBackup('не JSON'));
      expect(() => parseBackup('[]', today: today),
          throwsBackup('не резервная копия'));
    });

    test('чужой формат', () {
      expect(() => parseBackup(backupJson(format: 'other'), today: today),
          throwsBackup('не резервная копия'));
    });

    test('версия новее — понятное сообщение', () {
      expect(() => parseBackup(backupJson(version: 3), today: today),
          throwsBackup('более новой версией'));
      expect(() => parseBackup(backupJson(version: 0), today: today),
          throwsBackup('не поддерживается'));
      expect(() => parseBackup(backupJson(version: '1'), today: today),
          throwsBackup('версии формата'));
    });

    test('нет обязательных полей / лишние поля', () {
      final noCreated = jsonDecode(backupJson()) as Map..remove('createdAt');
      expect(() => parseBackup(jsonEncode(noCreated), today: today),
          throwsBackup('createdAt'));
      expect(() => parseBackup(backupJson(extra: {'x': 1}), today: today),
          throwsBackup('неизвестное поле «x»'));
      expect(
          () => parseBackup(
              backupJson(notes: [
                {'date': '2026-10-01', 'delta': kEmptyDelta, 'text': '\n'}
              ]),
              today: today),
          throwsBackup('accent'));
      expect(
          () => parseBackup(
              backupJson(notes: [
                {
                  'date': '2026-10-01',
                  'delta': kEmptyDelta,
                  'text': '\n',
                  'accent': '#FFD54A',
                  'uid': 'someone-else',
                }
              ]),
              today: today),
          throwsBackup('неизвестное поле «uid»'));
    });

    test('неверная дата создания', () {
      expect(() => parseBackup(backupJson(createdAt: 'вчера'), today: today),
          throwsBackup('дата создания'));
    });

    test('период: раньше 1 октября 2026, в будущем, перевёрнутый', () {
      expect(() => parseBackup(backupJson(from: '2026-09-30'), today: today),
          throwsBackup('начинается раньше'));
      expect(
          () => parseBackup(backupJson(to: '2026-11-05', notes: []),
              today: today),
          throwsBackup('в будущем'));
      expect(
          () => parseBackup(
              backupJson(from: '2026-10-10', to: '2026-10-05', notes: []),
              today: today),
          throwsBackup('начало позже конца'));
    });

    Map<String, Object?> n(String date, {String delta = kEmptyDelta}) => {
          'date': date,
          'delta': delta,
          'text': '\n',
          'accent': '#FFD54A',
          'updatedAt': null,
        };

    test('неверные и выходящие за период даты заметок', () {
      expect(
          () => parseBackup(backupJson(notes: [n('2026-02-30')]), today: today),
          throwsBackup('неверная дата'));
      expect(
          () => parseBackup(backupJson(notes: [n('1.10.2026')]), today: today),
          throwsBackup('неверная дата'));
      expect(
          () => parseBackup(backupJson(to: '2026-10-31', notes: [n('2026-11-01')]),
              today: today),
          throwsBackup('вне периода'));
    });

    test('дубликаты дат отклоняются', () {
      expect(
          () => parseBackup(backupJson(notes: [n('2026-10-03'), n('2026-10-03')]),
              today: today),
          throwsBackup('встречается дважды'));
    });

    test('повреждённая Delta отклоняется', () {
      for (final bad in [
        'не json',
        '{}',
        '[]',
        '[{"retain":1}]',
        '[{"insert":5}]',
        '[{"insert":"без перевода строки"}]',
        '[{"insert":"x\\n","attributes":"bold"}]',
        '[{"insert":"x\\n","eval":"code"}]',
      ]) {
        expect(
            () => parseBackup(backupJson(notes: [n('2026-10-01', delta: bad)]),
                today: today),
            throwsA(isA<BackupException>()),
            reason: bad);
      }
    });

    test('неверный цвет и типы полей', () {
      final m = n('2026-10-01')..['accent'] = 'red';
      expect(() => parseBackup(backupJson(notes: [m]), today: today),
          throwsBackup('цвет'));
      final t = n('2026-10-01')..['text'] = 42;
      expect(() => parseBackup(backupJson(notes: [t]), today: today),
          throwsBackup('неверного типа'));
    });
  });

  group('восстановление (перезапись)', () {
    BackupNote v(String date, String label) => BackupNote(
        date: date,
        delta: '[{"insert":"$label\\n"}]',
        text: '$label\n',
        accent: '#FFD54A');

    test('пример из ТЗ: совпадающие даты заменены, остальные не тронуты',
        () async {
      final store = FakeStore({
        '2026-09-15': v('2026-09-15', 'вне периода'),
        '2026-10-01': v('2026-10-01', 'текущая A'),
        '2026-10-02': v('2026-10-02', 'текущая B'),
        '2026-10-03': v('2026-10-03', 'текущая C'),
        '2026-10-04': v('2026-10-04', 'текущая D'),
      });
      final r = await runRestore(store, [
        v('2026-10-01', 'копия A'),
        v('2026-10-03', 'копия C'),
        v('2026-10-07', 'новая'),
      ]);
      expect(r.ok, isTrue);
      expect(r.written, 3);
      expect(store.data['2026-10-01']!.text, 'копия A\n');
      expect(store.data['2026-10-02']!.text, 'текущая B\n');
      expect(store.data['2026-10-03']!.text, 'копия C\n');
      expect(store.data['2026-10-04']!.text, 'текущая D\n');
      expect(store.data['2026-10-07']!.text, 'новая\n'); // создана
      expect(store.data['2026-09-15']!.text, 'вне периода\n');
      expect(store.data.length, 6);
    });

    test('содержимое восстанавливается без изменений', () async {
      final store = FakeStore({});
      final data = parseBackup(backupJson(), today: today);
      await runRestore(store, data.notes);
      expect(store.data['2026-10-01']!.delta, kRichDelta);
    });

    test('большая копия делится на пакеты в пределах лимита', () async {
      final notes = [
        for (var i = 0; i < 1000; i++)
          note(backupDateKey(DateTime(2026, 10, 1).add(Duration(days: i))))
      ];
      final store = FakeStore({});
      final progress = <int>[];
      final r = await runRestore(store, notes,
          onProgress: (d, t) => progress.add(d));
      expect(r.ok, isTrue);
      expect(store.data.length, 1000);
      expect(store.batchSizes.every((s) => s <= kMaxOpsPerBatch), isTrue);
      expect(store.batchSizes.length, 3);
      expect(progress.last, 1000);
    });

    test('пакеты ограничены и по объёму', () {
      final big = 'x' * 700000;
      final writes = [
        for (var i = 0; i < 20; i++)
          NoteWrite('d$i',
              BackupNote(date: 'd$i', delta: big, text: '', accent: '#FFD54A'))
      ];
      final batches = chunkWrites(writes);
      for (final b in batches) {
        final bytes = b.fold<int>(0, (s, w) => s + w.approxBytes);
        expect(bytes <= kMaxBatchBytes, isTrue);
      }
      expect(batches.expand((b) => b).length, 20);
    });

    test('сбой записи: успехом не считается, записанное откатывается',
        () async {
      final original = {
        for (var i = 0; i < 500; i++)
          backupDateKey(DateTime(2026, 10, 1).add(Duration(days: i))):
              v(backupDateKey(DateTime(2026, 10, 1).add(Duration(days: i))),
                  'было $i'),
      };
      final store = FakeStore(Map.of(original))..failOnCommit = 2;
      final notes = [
        for (var i = 0; i < 900; i++)
          v(backupDateKey(DateTime(2026, 10, 1).add(Duration(days: i))),
              'копия $i')
      ];
      final r = await runRestore(store, notes);
      expect(r.ok, isFalse);
      expect(r.written, kMaxOpsPerBatch);
      expect(r.rolledBack, isTrue);
      expect(r.notRolledBack, isEmpty);
      // база вернулась к исходному виду: старые заметки как были,
      // созданные восстановлением — удалены
      expect(store.data.keys.toSet(), original.keys.toSet());
      for (final k in original.keys) {
        expect(store.data[k]!.text, original[k]!.text);
      }
    });

    test('сбой и отката: даты, которые не вернулись, называются', () async {
      // 2-й commit (второй пакет) падает, 3-й (откат первого) тоже
      final store = FakeStore({})
        ..failOnCommit = 2
        ..alsoFail = {3};
      final notes = [
        for (var i = 0; i < 450; i++)
          note(backupDateKey(DateTime(2026, 10, 1).add(Duration(days: i))))
      ];
      final r = await runRestore(store, notes);
      expect(r.ok, isFalse);
      expect(r.rolledBack, isFalse);
      expect(r.written, kMaxOpsPerBatch);
      expect(r.notRolledBack.length, kMaxOpsPerBatch);
      expect(r.notRolledBack.first, '2026-10-01');
    });

    test('не удалось прочитать текущее состояние — ничего не записано',
        () async {
      final store = FakeStore({'2026-10-01': note('2026-10-01')})
        ..failRead = true;
      final r = await runRestore(store, [note('2026-10-01', kRichDelta)]);
      expect(r.ok, isFalse);
      expect(r.written, 0);
      expect(store.commits, 0);
      expect(r.error, contains('Ничего не изменено'));
    });

    test('неверный файл не доходит до записи', () {
      final store = FakeStore({});
      for (final bad in [
        '{oops',
        backupJson(version: 99),
        backupJson(notes: [
          {'date': '2026-10-01', 'delta': '[]', 'text': '', 'accent': '#FFD54A'}
        ]),
      ]) {
        expect(() => parseBackup(bad, today: today),
            throwsA(isA<BackupException>()));
      }
      expect(store.commits, 0);
    });
  });
}
