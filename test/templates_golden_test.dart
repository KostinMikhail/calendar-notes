// Стандартные шаблоны после переноса в templates.dart должны совпадать
// с прежним выводом байт в байт. Снимок сделан ДО изменений
// (test/fixtures/template_golden.json, 823 дня с 2026-10-01 по 2028-12-31).
import 'dart:convert';
import 'dart:io';

import 'package:calendar_notes/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('стандартные шаблоны совпадают с прежними для каждого дня', () {
    final golden = jsonDecode(
        File('test/fixtures/template_golden.json').readAsStringSync()) as Map;
    final accent = golden['accent'] as String;
    final outputs = (golden['outputs'] as List).cast<String>();
    final days = (golden['days'] as Map).cast<String, int>();
    expect(days.length, 823);

    var mismatches = 0;
    days.forEach((key, id) {
      final doc = debugBuildTemplate(DateTime.parse(key), accent);
      final now = jsonEncode(doc.toDelta().toJson());
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
}
