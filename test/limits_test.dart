// Размер заметки (аудит, F2): слишком большую заметку не отправляем,
// показываем понятный текст, держим её текст в памяти.
import 'dart:async';
import 'dart:convert';

import 'package:calendar_notes/limits.dart';
import 'package:calendar_notes/offline.dart';
import 'package:calendar_notes/tasks.dart';
import 'package:calendar_notes/templates.dart' show TemplateLine;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';

SavePayload _p(String json) => SavePayload(json: json, text: json);

const _tooBig = NoteTooBigError(
    NoteTooBig(NoteSizeLimit.text, 200001, kMaxNoteTextLength));

void main() {
  group('лимиты совпадают с firestore.rules', () {
    test('числа из правил', () {
      expect(kMaxNoteDeltaLength, 800000);
      expect(kMaxNoteTextLength, 200000);
      expect(kMaxNoteBytes, lessThan(1024 * 1024));
    });
  });

  group('utf8Length', () {
    for (final s in [
      '',
      'abc',
      'Привет',
      'смесь latin и кириллицы',
      '€ ₽ 漢字',
      '😀 эмодзи 👍🏽',
      '\uD800 одинокий суррогат',
      '{"insert":"Строка\\n"}',
    ]) {
      test('«$s» — как utf8.encode', () {
        expect(utf8Length(s), utf8.encode(s).length);
      });
    }
  });

  group('noteSizeProblem', () {
    test('обычная заметка — помещается', () {
      expect(noteSizeProblem('[{"insert":"текст\\n"}]', 'текст'), isNull);
    });

    test('ровно на пределе — помещается', () {
      final text = 'a' * kMaxNoteTextLength;
      expect(noteSizeProblem(text, text), isNull);
    });

    test('текст на символ длиннее предела', () {
      final text = 'a' * (kMaxNoteTextLength + 1);
      final p = noteSizeProblem('[]', text)!;
      expect(p.limit, NoteSizeLimit.text);
      expect(p.value, kMaxNoteTextLength + 1);
      expect(p.max, kMaxNoteTextLength);
    });

    test('оформление длиннее предела', () {
      final p = noteSizeProblem('x' * (kMaxNoteDeltaLength + 1), 'короткий')!;
      expect(p.limit, NoteSizeLimit.delta);
    });

    test('символов в пределах, но кириллица не влезает в 1 МиБ', () {
      // 190 000 букв: text ≈ 380 КБ, delta с тем же текстом ≈ 380 КБ и
      // ещё оформление — по символам правила пропустят, Firestore — нет
      final text = 'я' * 190000;
      final delta = jsonEncode([
        {'insert': text},
        {'insert': 'ж' * 150000, 'attributes': {'bold': true}},
        {'insert': '\n'},
      ]);
      expect(text.length, lessThanOrEqualTo(kMaxNoteTextLength));
      expect(delta.length, lessThanOrEqualTo(kMaxNoteDeltaLength));
      final p = noteSizeProblem(delta, text)!;
      expect(p.limit, NoteSizeLimit.bytes);
      expect(p.value, utf8.encode(delta).length + utf8.encode(text).length);
    });

    test('та же длина латиницей — помещается', () {
      final text = 'z' * 190000;
      final delta = jsonEncode([
        {'insert': text},
        {'insert': '\n'},
      ]);
      expect(noteSizeProblem(delta, text), isNull);
    });
  });

  group('текст для пользователя', () {
    test('по символам — сколько из скольких', () {
      final s = noteTooBigText(
          const NoteTooBig(NoteSizeLimit.text, 215300, kMaxNoteTextLength));
      expect(s, contains('215 300 из 200 000 символов'));
      expect(s, startsWith('Не сохраняется'));
      expect(s, contains('сократите текст'));
      expect(s, isNot(contains('permission')));
    });

    test('по оформлению и байтам — проценты', () {
      final s = noteTooBigText(
          const NoteTooBig(NoteSizeLimit.bytes, 1120000, kMaxNoteBytes));
      expect(s, contains('112% от предела'));
    });

    test('groupDigits', () {
      expect(groupDigits(0), '0');
      expect(groupDigits(999), '999');
      expect(groupDigits(1000), '1 000');
      expect(groupDigits(1234567), '1 234 567');
    });

    test('ошибка показывает тот же текст', () {
      expect(_tooBig.toString(), noteTooBigText(_tooBig.problem));
    });
  });

  group('SaveTracker.hold — слишком большая заметка', () {
    test('держит текст, без onRejected; есть несохранённое', () {
      final t = SaveTracker();
      var calls = 0;
      t.onRejected = (_, _) => calls++;
      var notified = 0;
      t.addListener(() => notified++);
      t.hold('d', _p('огромная'), _tooBig);
      expect(calls, 0);
      expect(notified, 1);
      expect(t.rejected('d')!.payload.json, 'огромная');
      expect(t.hasTooBig, isTrue);
      expect(t.hasUnsynced, isTrue);
      expect(t.hasRejected, isTrue); // выход из аккаунта предупредит
      expect(t.isUnsettled('d'), isTrue); // правки «из базы» не затрут
    });

    test('поздний ответ на прежнюю запись удержание не снимает', () async {
      final t = SaveTracker(ackWait: const Duration(milliseconds: 20));
      final w = Completer<void>();
      await t.track('d', w.future, _p('v1')); // в очереди
      t.hold('d', _p('v2 огромная'), _tooBig);
      w.complete(); // v1 дошла
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(t.rejected('d')!.payload.json, 'v2 огромная');
      expect(t.hasTooBig, isTrue);
    });

    test('сократили и сохранили — удержание снято', () async {
      final t = SaveTracker();
      t.hold('d', _p('огромная'), _tooBig);
      await t.track('d', Future<void>.value(), _p('короткая'));
      expect(t.rejected('d'), isNull);
      expect(t.hasTooBig, isFalse);
      expect(t.hasUnsynced, isFalse);
    });

    test('обычный отказ сервера — не «слишком большая»', () async {
      final t = SaveTracker();
      await t.track(
          'd',
          Future<void>.error(
              FirebaseException(plugin: 'cloud_firestore', code: 'x')),
          _p('a'));
      expect(t.hasRejected, isTrue);
      expect(t.hasTooBig, isFalse);
    });

    test('forget снимает удержание', () {
      final t = SaveTracker();
      t.hold('d', _p('огромная'), _tooBig);
      t.forget('d');
      expect(t.hasTooBig, isFalse);
    });
  });

  group('перенос задачи — тот же предел в байтах', () {
    test('по символам в пределах, но в байтах больше — перенос отменён', () {
      // '€' — 3 байта: 196 000 символов ≈ 588 КБ в text и столько же в delta
      final lines = [
        for (var i = 0; i < 4; i++)
          TemplateLine([
            {'insert': '€' * 49000}
          ], null),
      ];
      expect(() => noteDataOf(lines, '', '20 ноября'),
          throwsA(isA<TaskCarryError>()));
    });

    test('обычная заметка переносится', () {
      final d = noteDataOf([
        TemplateLine([
          {'insert': 'задача'}
        ], null)
      ], '', '20 ноября');
      expect(d.text, contains('задача'));
    });
  });
}
