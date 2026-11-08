import 'dart:async';

import 'package:calendar_notes/offline.dart';
import 'package:calendar_notes/tasks.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';

FirebaseException fbError(String code) =>
    FirebaseException(plugin: 'cloud_firestore', code: code);

const _short = Duration(milliseconds: 40);

Future<void> later([int ms = 80]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

SavePayload payload(String json) => SavePayload(json: json, text: json);

// ------------------------------------------------------------
//  Подделка источника для фоновой загрузки
// ------------------------------------------------------------

class FakeCopySource implements OfflineCopySource {
  FakeCopySource(this.data);

  /// коллекция → отсортированные id
  final Map<String, List<String>> data;
  final List<String> calls = [];
  bool failOnce = false;
  int failAtCall = -1;
  int extrasCalls = 0;

  @override
  List<String> get collections => data.keys.toList();

  @override
  Future<int?> total() async =>
      data.values.fold<int>(0, (s, l) => s + l.length);

  @override
  Future<List<String>> page(String c, String? afterId, int limit) async {
    calls.add('$c:${afterId ?? '-'}');
    if (calls.length - 1 == failAtCall) {
      failAtCall = -1;
      throw fbError('unavailable');
    }
    final ids = data[c]!;
    final start = afterId == null ? 0 : ids.indexOf(afterId) + 1;
    return ids.skip(start).take(limit).toList();
  }

  @override
  Future<void> extras() async => extrasCalls++;
}

class MemoryMarker implements CopyMarker {
  final Set<String> done = {};
  @override
  bool isComplete(String uid) => done.contains(uid);
  @override
  void markComplete(String uid) => done.add(uid);
}

List<String> ids(String prefix, int n) =>
    [for (var i = 0; i < n; i++) '$prefix${i.toString().padLeft(4, '0')}'];

// ------------------------------------------------------------
//  Упрощённая «вкладка»: та же логика, что в _saveNote / смене дня
//  (shouldSaveDay + SaveTracker), запись — в подделку очереди Firestore.
// ------------------------------------------------------------

class FakeQueue {
  final List<(String key, String json, Completer<void> ack)> writes = [];

  Future<void> set(String key, String json) {
    final c = Completer<void>();
    writes.add((key, json, c));
    return c.future;
  }
}

class Session {
  Session(this.queue);
  final FakeQueue queue;
  final tracker = SaveTracker(ackWait: _short);
  String? loadedKey;
  String targetKey = '';
  String savedJson = '';
  String editor = '';
  String status = '';

  void open(String key, String content) {
    targetKey = key;
    loadedKey = key;
    savedJson = content;
    editor = content;
  }

  /// как _saveNote: запись ставится в очередь сразу, ответ — не дольше
  /// ackWait
  Future<void> save() async {
    final key = targetKey;
    if (!shouldSaveDay(
        loadedKey: loadedKey,
        targetKey: key,
        currentJson: editor,
        savedJson: savedJson)) {
      return;
    }
    final json = editor;
    final write = queue.set(key, json);
    savedJson = json;
    status = kStatusSaving;
    final out = await tracker.track(key, write, payload(json));
    if (targetKey != key) return;
    if (out == SaveOutcome.acked) status = kStatusSaved;
    if (out == SaveOutcome.queued) status = kStatusQueued;
  }

  /// как _onDaySelected: сохранить (не дожидаясь сервера) и открыть другой
  Future<void> switchTo(String key, String content) async {
    unawaited(save());
    loadedKey = null;
    open(key, content);
    status = '';
  }
}

void main() {
  group('waitAck', () {
    test('подтверждение вовремя — acked', () async {
      final r = await waitAck(Future<void>.value(), wait: _short);
      expect(r, WriteAck.acked);
    });

    test('подтверждения нет — queued, не дольше срока', () async {
      final sw = Stopwatch()..start();
      final r = await waitAck(Completer<void>().future, wait: _short);
      expect(r, WriteAck.queued);
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });

    test('подтверждение позже — onLateAck', () async {
      final c = Completer<void>();
      var late = false;
      final r = await waitAck(c.future, wait: _short, onLateAck: () => late = true);
      expect(r, WriteAck.queued);
      c.complete();
      await later();
      expect(late, isTrue);
    });

    test('ошибка позже — onLateError', () async {
      final c = Completer<void>();
      Object? err;
      final r = await waitAck(c.future, wait: _short, onLateError: (e) => err = e);
      expect(r, WriteAck.queued);
      c.completeError(fbError('permission-denied'));
      await later();
      expect((err as FirebaseException).code, 'permission-denied');
    });

    test('ошибка сразу — исключение', () async {
      expect(waitAck(Future<void>.error(fbError('invalid-argument')), wait: _short),
          throwsA(isA<FirebaseException>()));
    });
  });

  group('SaveTracker', () {
    test('ответ вовремя — acked, ничего не висит', () async {
      final t = SaveTracker(ackWait: _short);
      final acked = <String>[];
      t.onAcked = acked.add;
      final out = await t.track('2026-11-11', Future<void>.value(), payload('a'));
      expect(out, SaveOutcome.acked);
      expect(acked, ['2026-11-11']);
      expect(t.hasPending, isFalse);
    });

    test('без сети — queued, потом подтверждение: статус уходит в «Сохранено»',
        () async {
      final q = FakeQueue();
      final s = Session(q)..open('2026-11-11', 'base');
      var drained = false;
      s.tracker.addListener(() {
        if (!s.tracker.hasPending && s.status == kStatusQueued) {
          s.status = kStatusSaved;
          drained = true;
        }
      });
      s.editor = 'typed';
      await s.save();
      expect(s.status, kStatusQueued);
      expect(s.tracker.hasPending, isTrue);
      expect(s.tracker.isUnsettled('2026-11-11'), isTrue);
      q.writes.single.$3.complete(); // сеть вернулась
      await later();
      expect(drained, isTrue);
      expect(s.status, kStatusSaved);
      expect(s.tracker.isUnsettled('2026-11-11'), isFalse);
    });

    test('отказ сервера позже — текст сохранён в отказе, заметка снова «грязная»',
        () async {
      final q = FakeQueue();
      final s = Session(q)..open('2026-11-11', 'base');
      RejectedSave? rejected;
      s.tracker.onRejected = (key, r) {
        rejected = r;
        if (key == s.loadedKey) s.savedJson = '\u0000rejected';
      };
      s.editor = 'важный текст';
      await s.save();
      expect(s.status, kStatusQueued);
      q.writes.single.$3.completeError(fbError('permission-denied'));
      await later();
      expect(rejected!.payload.json, 'важный текст');
      expect(s.editor, 'важный текст'); // в редакторе текст не тронут
      expect(s.savedJson != s.editor, isTrue); // автосохранение повторит
      expect(s.tracker.hasUnsynced, isTrue);
      expect(s.tracker.rejected('2026-11-11'), isNotNull);
    });

    test('после отказа успешная запись снимает отказ', () async {
      final t = SaveTracker(ackWait: _short);
      await t.track('d', Future<void>.error(fbError('permission-denied')), payload('a'));
      expect(t.rejected('d'), isNotNull);
      await t.track('d', Future<void>.value(), payload('a'));
      expect(t.rejected('d'), isNull);
      expect(t.hasUnsynced, isFalse);
    });

    test('записи одного дня: решает последняя, отказ старой не важен', () async {
      final t = SaveTracker(ackWait: _short);
      final rejected = <String>[];
      t.onRejected = (k, r) => rejected.add(r.payload.json);
      final w1 = Completer<void>();
      final w2 = Completer<void>();
      await t.track('d', w1.future, payload('v1'));
      await t.track('d', w2.future, payload('v2'));
      w1.completeError(fbError('permission-denied'));
      await later();
      expect(rejected, isEmpty); // v2 содержит весь документ целиком
      expect(t.isUnsettled('d'), isTrue);
      w2.complete();
      await later();
      expect(t.hasUnsynced, isFalse);
    });

    test('порядок записей в очереди сохраняется (последняя — новее)', () async {
      final q = FakeQueue();
      final s = Session(q)..open('2026-11-11', '');
      for (final v in ['a', 'ab', 'abc']) {
        s.editor = v;
        await s.save();
      }
      expect([for (final w in q.writes) w.$2], ['a', 'ab', 'abc']);
      expect(q.writes.every((w) => w.$1 == '2026-11-11'), isTrue);
    });
  });

  group('смена дня, пока запись в очереди', () {
    test('не ждёт сервер и не пишет в чужой день', () async {
      final q = FakeQueue();
      final s = Session(q)..open('2026-11-11', 'base11');
      s.editor = 'правка 11';
      final sw = Stopwatch()..start();
      await s.switchTo('2026-11-12', 'base12');
      expect(sw.elapsedMilliseconds, lessThan(30)); // сервер не ждали
      expect(s.targetKey, '2026-11-12');
      expect(q.writes.single.$1, '2026-11-11');
      expect(q.writes.single.$2, 'правка 11');

      // нетронутый 12-й не записывается
      await s.save();
      expect(q.writes.length, 1);

      s.editor = 'правка 12';
      await s.switchTo('2026-11-13', 'base13');
      expect(q.writes.length, 2);
      expect(q.writes[1].$1, '2026-11-12');
      expect(q.writes[1].$2, 'правка 12');
      await later();
      // статус старого дня не попадает на новый
      expect(s.status, '');
      expect(s.tracker.isUnsettled('2026-11-11'), isTrue);
      expect(s.tracker.isUnsettled('2026-11-13'), isFalse);
    });

    test('пока день не загружен — не сохраняем', () {
      expect(
          shouldSaveDay(
              loadedKey: null,
              targetKey: '2026-11-12',
              currentJson: 'x',
              savedJson: 'y'),
          isFalse);
      expect(
          shouldSaveDay(
              loadedKey: '2026-11-11',
              targetKey: '2026-11-12',
              currentJson: 'x',
              savedJson: 'y'),
          isFalse);
    });

    test('нетронутый шаблон не сохраняется', () {
      expect(
          shouldSaveDay(
              loadedKey: '2026-11-12',
              targetKey: '2026-11-12',
              currentJson: 'template',
              savedJson: 'template'),
          isFalse);
      expect(
          shouldSaveDay(
              loadedKey: '2026-11-12',
              targetKey: '2026-11-12',
              currentJson: 'template+text',
              savedJson: 'template'),
          isTrue);
    });
  });

  group('readPreferServer', () {
    test('онлайн — сервер', () async {
      var cache = 0;
      final r = await readPreferServer<String>(
          offline: false,
          server: () async => 'server',
          cache: () async {
            cache++;
            return 'cache';
          });
      expect(r.value, 'server');
      expect(r.fromCache, isFalse);
      expect(cache, 0);
    });

    test('офлайн — сразу локальная копия, сервер не спрашиваем', () async {
      var server = 0;
      final r = await readPreferServer<String>(
          offline: true,
          server: () async {
            server++;
            return 'server';
          },
          cache: () async => 'cache');
      expect(r.value, 'cache');
      expect(r.fromCache, isTrue);
      expect(server, 0);
    });

    test('сервер не ответил вовремя — копия; поздний ответ отброшен',
        () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        // внутри зоны: ошибки future не переходят границу зоны
        final late = Completer<String>();
        final r = await readPreferServer<String>(
            offline: false,
            server: () => late.future,
            cache: () async => 'cache',
            timeout: _short);
        expect(r.value, 'cache');
        expect(r.fromCache, isTrue);
        late.completeError(fbError('unavailable'));
        await later();
      }, (e, _) => errors.add(e));
      expect(errors, isEmpty); // поздняя ошибка никуда не «вылетает»
    });

    test('нет связи (unavailable) — копия', () async {
      final r = await readPreferServer<String>(
          offline: false,
          server: () async => throw fbError('unavailable'),
          cache: () async => 'cache');
      expect(r.value, 'cache');
    });

    test('ошибка доступа — пробрасывается', () async {
      expect(
          readPreferServer<String>(
              offline: false,
              server: () async => throw fbError('permission-denied'),
              cache: () async => 'cache'),
          throwsA(isA<FirebaseException>()));
    });

    test('поздний ответ сервера не затирает открытый день', () async {
      // последовательность загрузок как в _loadNoteInner: применяется только
      // результат последней
      var seq = 0;
      String? open;
      final slow = Completer<String>();
      Future<void> load(String day, Future<String> Function() server) async {
        final my = ++seq;
        final r = await readPreferServer<String>(
            offline: false,
            server: server,
            cache: () async => 'cache:$day',
            timeout: _short);
        if (my == seq) open = r.value;
      }

      final first = load('11', () => slow.future);
      await load('12', () async => 'server:12');
      slow.complete('server:11');
      await first;
      await later();
      expect(open, 'server:12');
    });
  });

  group('неизвестный день', () {
    test('все сочетания', () {
      for (final fromCache in [false, true]) {
        for (final exists in [false, true]) {
          for (final complete in [false, true]) {
            final expected = fromCache && !exists && !complete;
            expect(
                isUnknownDay(
                    fromCache: fromCache,
                    exists: exists,
                    downloadComplete: complete),
                expected,
                reason: 'fromCache=$fromCache exists=$exists complete=$complete');
          }
        }
      }
    });
  });

  group('OfflineDownloader', () {
    test('постранично по id, обе коллекции, отметка после полной загрузки',
        () async {
      final src = FakeCopySource({'notes': ids('n', 250), 'topics': ids('t', 3)});
      final marker = MemoryMarker();
      final d = OfflineDownloader(
          source: src, marker: marker, uid: 'u1', isOffline: () => false);
      final progress = <String?>[];
      d.addListener(() => progress.add(d.progressText));
      await d.run();
      expect(src.calls, ['notes:-', 'notes:n0099', 'notes:n0199', 'topics:-']);
      expect(d.done, 253);
      expect(d.complete, isTrue);
      expect(d.completeThisLoad, isTrue);
      expect(marker.isComplete('u1'), isTrue);
      expect(src.extrasCalls, 1);
      expect(progress, contains('Копия для офлайна: 100/253'));
      expect(d.progressText, isNull); // закончили — подсказки нет
      // второй раз за загрузку страницы — не грузим
      await d.run();
      expect(src.calls.length, 4);
    });

    test('без сети — пропуск, отметки нет', () async {
      final src = FakeCopySource({'notes': ids('n', 5)});
      final marker = MemoryMarker();
      final d = OfflineDownloader(
          source: src, marker: marker, uid: 'u1', isOffline: () => true);
      await d.run();
      expect(src.calls, isEmpty);
      expect(d.complete, isFalse);
      expect(marker.done, isEmpty);
    });

    test('сбой посередине — отметки нет; при появлении сети продолжает с места',
        () async {
      final src = FakeCopySource({'notes': ids('n', 250), 'topics': ids('t', 2)})
        ..failAtCall = 1;
      final marker = MemoryMarker();
      var offline = false;
      final d = OfflineDownloader(
          source: src,
          marker: marker,
          uid: 'u1',
          isOffline: () => offline,
          retryDelay: const Duration(hours: 1));
      await d.run();
      expect(d.complete, isFalse);
      expect(marker.done, isEmpty);
      expect(src.calls, ['notes:-', 'notes:n0099']);
      offline = true;
      d.onReconnect(); // всё ещё офлайн — ничего
      expect(src.calls.length, 2);
      offline = false;
      d.onReconnect();
      await later();
      expect(src.calls, [
        'notes:-',
        'notes:n0099',
        'notes:n0099', // повтор той же страницы, а не с начала
        'notes:n0199',
        'topics:-',
      ]);
      expect(d.complete, isTrue);
      expect(marker.isComplete('u1'), isTrue);
      d.dispose();
    });

    test('отметке из прошлого раза верим только при копии на диске', () {
      final marker = MemoryMarker()..markComplete('u1');
      final src = FakeCopySource({'notes': []});
      expect(
          OfflineDownloader(
                  source: src, marker: marker, uid: 'u1', isOffline: () => true)
              .complete,
          isTrue);
      expect(
          OfflineDownloader(
                  source: src,
                  marker: marker,
                  uid: 'u1',
                  isOffline: () => true,
                  markerTrusted: false)
              .complete,
          isFalse);
      expect(
          OfflineDownloader(
                  source: src, marker: marker, uid: 'u2', isOffline: () => true)
              .complete,
          isFalse);
    });
  });

  group('выход из аккаунта', () {
    test('очередь не разошлась — есть несинхронизированное', () async {
      final r = await hasUnsyncedWrites(
          waitForPendingWrites: () => Completer<void>().future,
          hasRejected: () => false,
          wait: _short);
      expect(r, isTrue);
    });

    test('всё подтверждено — выходим как раньше', () async {
      final r = await hasUnsyncedWrites(
          waitForPendingWrites: () async {},
          hasRejected: () => false,
          wait: _short);
      expect(r, isFalse);
    });

    test('отклонённая запись — тоже несинхронизировано', () async {
      final r = await hasUnsyncedWrites(
          waitForPendingWrites: () async {},
          hasRejected: () => true,
          wait: _short);
      expect(r, isTrue);
    });
  });

  group('ConnectionMonitor', () {
    test('из кэша — офлайн с задержкой; сервер — сразу онлайн и повтор',
        () async {
      final m = ConnectionMonitor(offlineDelay: _short, startupDelay: _short);
      var reconnects = 0;
      m.addReconnectListener(() => reconnects++);
      m.storeChanged(false); // первый ответ сервера
      expect(m.offline, isFalse);
      m.storeChanged(true);
      expect(m.offline, isFalse); // ещё не офлайн (задержка)
      await later();
      expect(m.offline, isTrue);
      m.storeChanged(false);
      expect(m.offline, isFalse);
      expect(reconnects, 1);
      m.dispose();
    });

    test('короткий снимок из кэша при запуске — не офлайн', () async {
      final m = ConnectionMonitor(
          offlineDelay: _short, startupDelay: const Duration(milliseconds: 200));
      m.storeChanged(true);
      await later(50);
      m.storeChanged(false);
      await later(250);
      expect(m.offline, isFalse);
      m.dispose();
    });

    test('браузер сообщил «нет сети» — сразу офлайн', () {
      final m = ConnectionMonitor();
      m.browserChanged(false);
      expect(m.offline, isTrue);
      m.browserChanged(true);
      expect(m.offline, isFalse);
      m.dispose();
    });
  });

  group('без сети — только то, что требует сервер', () {
    test('перенос и отмена переноса требуют сети, отметка ✓ — нет', () {
      expect(taskStepNeedsNetwork(taskStep(TaskState.open, TaskControl.cross)),
          isTrue);
      expect(
          taskStepNeedsNetwork(taskStep(TaskState.carried, TaskControl.cross)),
          isTrue);
      expect(
          taskStepNeedsNetwork(taskStep(TaskState.carried, TaskControl.check)),
          isTrue);
      expect(taskStepNeedsNetwork(taskStep(TaskState.open, TaskControl.check)),
          isFalse);
      expect(taskStepNeedsNetwork(taskStep(TaskState.done, TaskControl.check)),
          isFalse);
    });

    testWidgets('✗ без сети: подсказка «Нужна сеть…», нажатие не работает',
        (tester) async {
      var cross = 0;
      var check = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TaskControls(
            value: TaskValue.open,
            crossTooltip: 'перенести',
            crossDisabled: true,
            onCross: () => cross++,
            onCheck: () => check++,
          ),
        ),
      ));
      expect(find.byTooltip(kTaskNeedNetwork), findsOneWidget);
      expect(find.byTooltip('перенести'), findsNothing);
      await tester.tap(find.byIcon(Icons.close_rounded), warnIfMissed: false);
      await tester.tap(find.byIcon(Icons.check_rounded));
      expect(cross, 0);
      expect(check, 1); // ✓ работает и без сети
    });

    testWidgets('✗ при связи — как раньше', (tester) async {
      var cross = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TaskControls(
            value: TaskValue.open,
            crossTooltip: 'перенести',
            onCross: () => cross++,
          ),
        ),
      ));
      expect(find.byTooltip('перенести'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close_rounded));
      expect(cross, 1);
    });
  });
}
