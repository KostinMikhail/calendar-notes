import 'dart:convert';

import 'package:calendar_notes/backup.dart';
import 'package:flutter_test/flutter_test.dart';

const String kDelta = '[{"insert":"Тема","attributes":{"bold":true}},'
    '{"insert":"\\n"},{"insert":"ссылка","attributes":{"link":"https://x.y"}},'
    '{"insert":"\\n","attributes":{"list":"ordered"}}]';
const String kEmpty = '[{"insert":"\\n"}]';

final DateTime today = DateTime(2026, 11, 5);

BackupTopic topic(String id, {String title = 'Проект', int order = 0, String delta = kDelta}) =>
    BackupTopic(id: id, title: title, delta: delta, text: 'Тема\nссылка\n', order: order);

BackupNote note(String date, String label) => BackupNote(
    date: date, delta: '[{"insert":"$label\\n"}]', text: '$label\n', accent: '#FFD54A');

Map<String, Object?> rawTopic(String id,
        {Object? title = 'Проект', Object? order = 0, Object? delta = kDelta}) =>
    {
      'id': id,
      'title': title,
      'delta': delta,
      'text': 'x\n',
      'order': order,
      'createdAt': '2026-11-01T10:00:00.000Z',
      'updatedAt': null,
    };

String fileJson({int version = 2, List<Object?>? topics, bool withTopics = true}) =>
    jsonEncode({
      'format': 'calendar-notes-backup',
      'version': version,
      'createdAt': '2026-11-05T10:00:00.000Z',
      'dateRange': {'from': '2026-10-01', 'to': '2026-11-05'},
      'notes': [
        {
          'date': '2026-10-01',
          'delta': kEmpty,
          'text': '\n',
          'accent': '#FFD54A',
          'updatedAt': null,
        }
      ],
      if (withTopics) 'topics': topics ?? [rawTopic('abc')],
    });

Matcher throwsBackup(String part) => throwsA(isA<BackupException>()
    .having((e) => e.message, 'message', contains(part)));

/// Хранилище заметок и тем в памяти (как Firestore: set заменяет целиком,
/// update требует существующий документ)
class FakeStore2 implements NoteStore, TopicRestoreStore {
  final Map<String, BackupNote> notes = {};
  final Map<String, BackupTopic> topics = {};
  final List<List<NoteWrite>> commits = [];
  Set<int> failOn = {};

  @override
  Future<Map<String, BackupNote?>> readCurrent(List<String> dates) async =>
      {for (final d in dates) d: notes[d]};

  @override
  Future<Map<String, BackupTopic?>> readCurrentTopics(List<String> ids) async =>
      {for (final id in ids) id: topics[id]};

  @override
  Future<void> commit(List<NoteWrite> writes) async {
    commits.add(writes);
    if (failOn.contains(commits.length)) throw StateError('network');
    for (final w in writes) {
      if (w.isTopic) {
        if (w.topic == null) {
          topics.remove(w.date);
        } else {
          if (w.topicExisted && !topics.containsKey(w.date)) {
            throw StateError('update of missing document');
          }
          topics[w.date] = w.topic!;
        }
      } else if (w.note == null) {
        notes.remove(w.date);
      } else {
        notes[w.date] = w.note!;
      }
    }
  }
}

/// Хранилище только для заметок (как старое)
class NotesOnlyStore implements NoteStore {
  int commits = 0;
  @override
  Future<Map<String, BackupNote?>> readCurrent(List<String> dates) async => {};
  @override
  Future<void> commit(List<NoteWrite> writes) async => commits++;
}

void main() {
  group('файл копии с темами', () {
    test('туда и обратно: темы и заметки без потерь', () {
      final json = encodeBackup(
        [note('2026-10-01', 'день')],
        topics: [topic('b', order: 1), topic('a', title: 'Идеи', order: 0)],
        today: today,
        createdAtUtc: DateTime.utc(2026, 11, 5, 10),
      );
      final root = jsonDecode(json) as Map;
      expect(root['version'], 2);
      expect((root['topics'] as List).length, 2);

      final back = parseBackup(json, today: today);
      expect(back.notes.single.date, '2026-10-01');
      expect(back.topics.map((t) => t.id), ['a', 'b']); // по order
      expect(back.topics.first.title, 'Идеи');
      expect(back.topics.first.delta, kDelta); // байт в байт
    });

    test('старый файл версии 1 без тем читается как раньше', () {
      final data = parseBackup(fileJson(version: 1, withTopics: false), today: today);
      expect(data.notes.single.date, '2026-10-01');
      expect(data.topics, isEmpty);
    });

    test('в файле версии 1 раздела тем быть не может', () {
      expect(() => parseBackup(fileJson(version: 1), today: today),
          throwsBackup('неизвестное поле «topics»'));
    });

    test('в версии 2 раздел тем необязателен', () {
      expect(parseBackup(fileJson(withTopics: false), today: today).topics,
          isEmpty);
    });

    test('неверные темы отклоняются целиком', () {
      for (final (raw, part) in [
        (rawTopic('a b'), 'идентификатор'),
        (rawTopic('a', title: '   '), 'название'),
        (rawTopic('a', title: 'x' * 81), 'название'),
        (rawTopic('a', order: '1'), 'неверного типа'),
        (rawTopic('a', delta: '[]'), 'Quill Delta'),
        ({...rawTopic('a'), 'uid': 'чужой'}, 'неизвестное поле «uid»'),
      ]) {
        expect(() => parseBackup(fileJson(topics: [raw]), today: today),
            throwsBackup(part),
            reason: '$raw');
      }
      expect(
          () => parseBackup(fileJson(topics: [rawTopic('a'), rawTopic('a')]),
              today: today),
          throwsBackup('встречается дважды'));
    });

    test('тема из Firestore с неверными полями не выгружается молча', () {
      expect(() => topicsForExport({'x': {'title': 'Т', 'delta': kDelta}}),
          throwsBackup('неожиданном формате'));
    });
  });

  group('восстановление тем', () {
    test('существующая тема обновляется, новая создаётся, прочие не тронуты',
        () async {
      final store = FakeStore2()
        ..topics['old'] = topic('old', title: 'Было')
        ..topics['other'] = topic('other', title: 'Не в копии')
        ..notes['2026-10-02'] = note('2026-10-02', 'текущая');
      final r = await runRestore(
        store,
        [note('2026-10-01', 'из копии')],
        topics: [topic('old', title: 'Стало'), topic('new', title: 'Новая')],
      );
      expect(r.ok, isTrue);
      expect(r.total, 3);
      expect(r.written, 3);
      expect(store.topics['old']!.title, 'Стало');
      expect(store.topics['new']!.title, 'Новая');
      expect(store.topics['other']!.title, 'Не в копии');
      expect(store.notes['2026-10-02']!.text, 'текущая\n');
      // флаги «обновить» / «создать»
      final tw = store.commits.single.where((w) => w.isTopic).toList();
      expect(tw.firstWhere((w) => w.date == 'old').topicExisted, isTrue);
      expect(tw.firstWhere((w) => w.date == 'new').topicExisted, isFalse);
    });

    test('сбой: созданные темы удаляются, изменённые возвращаются', () async {
      final store = FakeStore2()..topics['old'] = topic('old', title: 'Было');
      final notes = [
        for (var i = 0; i < 30; i++)
          note(backupDateKey(DateTime(2026, 10, 1).add(Duration(days: i))), 'n$i'),
      ];
      // 400+ записей → несколько пакетов; второй падает
      final topics = [
        topic('old', title: 'Стало'),
        for (var i = 0; i < 420; i++) topic('n$i', title: 'Т$i', delta: kEmpty),
      ];
      store.failOn = {2};
      final r = await runRestore(store, notes, topics: topics);
      expect(r.ok, isFalse);
      expect(r.rolledBack, isTrue);
      expect(store.topics.keys, ['old']);
      expect(store.topics['old']!.title, 'Было');
      expect(store.notes, isEmpty);
    });

    test('откат не удался — в отчёте ключи тем с префиксом t:', () async {
      final store = FakeStore2()..failOn = {2, 3};
      final topics = [
        for (var i = 0; i < 450; i++) topic('n$i', title: 'Т$i', delta: kEmpty),
      ];
      final r = await runRestore(store, const [], topics: topics);
      expect(r.ok, isFalse);
      expect(r.rolledBack, isFalse);
      expect(r.notRolledBack.first, 't:n0');
    });

    test('только темы, без заметок — заметки не читаются', () async {
      final store = FakeStore2();
      final r = await runRestore(store, const [], topics: [topic('a')]);
      expect(r.ok, isTrue);
      expect(store.topics.keys, ['a']);
    });

    test('хранилище без поддержки тем — ничего не записано', () async {
      final store = NotesOnlyStore();
      final r = await runRestore(store, [note('2026-10-01', 'x')],
          topics: [topic('a')]);
      expect(r.ok, isFalse);
      expect(r.written, 0);
      expect(store.commits, 0);
    });
  });
}
