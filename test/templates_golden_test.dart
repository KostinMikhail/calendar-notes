// Стандартные шаблоны должны совпадать с прежним выводом байт в байт —
// с одним отличием: пункты верхнего уровня блока «Задачи на день» стали
// открытыми задачами (атрибут строки "task":"open"). Снимок сделан ДО
// изменений (test/fixtures/template_golden.json, 823 дня с 2026-10-01 по
// 2028-12-31).
import 'dart:convert';
import 'dart:io';

import 'package:calendar_notes/main.dart';
import 'package:calendar_notes/tasks.dart';
import 'package:calendar_notes/templates.dart';
import 'package:flutter_quill/flutter_quill.dart' show Document;
import 'package:flutter_test/flutter_test.dart';

/// Delta без атрибута задачи (нормализованная редактором)
String withoutTasks(List<dynamic> ops) {
  final stripped = [
    for (final op in ops)
      {
        'insert': (op as Map)['insert'],
        if (op['attributes'] is Map)
          if ((Map.of(op['attributes'] as Map)..remove(kTaskAttr)).isNotEmpty)
            'attributes': Map.of(op['attributes'] as Map)..remove(kTaskAttr),
      },
  ];
  return jsonEncode(Document.fromJson(stripped).toDelta().toJson());
}

void main() {
  final golden = jsonDecode(
      File('test/fixtures/template_golden.json').readAsStringSync()) as Map;
  final accent = golden['accent'] as String;
  final outputs = (golden['outputs'] as List).cast<String>();
  final days = (golden['days'] as Map).cast<String, int>();

  test('стандартные шаблоны совпадают с прежними (кроме отметки задач)', () {
    expect(days.length, 823);
    var mismatches = 0;
    days.forEach((key, id) {
      final doc = debugBuildTemplate(DateTime.parse(key), accent);
      final now = withoutTasks(doc.toDelta().toJson());
      if (now != outputs[id]) {
        mismatches++;
        if (mismatches <= 3) {
          // ignore: avoid_print
          print('$key\nбыло:  ${outputs[id]}\nстало: $now');
        }
      }
    });
    expect(mismatches, 0);
  });

  test('отметка задачи — ровно у пунктов верхнего уровня блока задач', () {
    days.forEach((key, _) {
      final doc = debugBuildTemplate(DateTime.parse(key), accent);
      final lines = opsToLines(doc.toDelta().toJson());
      final day = DateTime.parse(key);
      final weekend = day.weekday >= 6;
      final s = findTaskSection([
        for (final l in lines)
          LineShape(
              text: l.isEmpty ? '' : l.plainText,
              isList: l.attrs?['list'] != null,
              isDivider: l.isDivider),
      ]);
      if (weekend) {
        expect(s, isNull, reason: key);
        return;
      }
      expect(s, isNotNull, reason: key);
      var emptyTasks = 0;
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        final inBody = i > s!.heading && i < s.end;
        final top = l.attrs?['list'] != null && l.attrs?['indent'] == null;
        if (inBody && top) {
          expect(l.attrs?[kTaskAttr], 'open', reason: '$key строка $i');
          if (l.isEmpty) emptyTasks++;
        } else {
          expect(l.attrs?[kTaskAttr], isNull, reason: '$key строка $i');
        }
      }
      expect(emptyTasks, greaterThanOrEqualTo(1), reason: key);
    });
  });
}
