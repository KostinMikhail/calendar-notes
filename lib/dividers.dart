// Разделитель (block embed 'divider'): всегда отдельная строка без
// оформления строки, в буфере обмена — без символа-заглушки, удаляется
// Backspace/Delete с соседней строки. Чистые функции: проверяются тестами.
import 'dart:convert';

import 'package:flutter/services.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

/// Разделитель в текстовом виде для буфера обмена: ничего (вместо U+FFFC,
/// который в других программах выглядит странным символом)
const String kDividerPlainText = '';

const String _objectReplacement = '￼';

/// Настройки контроллеров редакторов с разделителями (заметки, темы,
/// шаблоны)
const QuillControllerConfig kEditorControllerConfig = QuillControllerConfig(
  // ignore: experimental_member_use
  clipboardConfig: QuillClipboardConfig(
      // ignore: experimental_member_use
      onPlainTextPaste: cleanPastedPlainText),
);

/// Текст из буфера перед вставкой: переводы строк Windows (\r\n) — как в
/// документе (\n), чтобы своё же копирование узнавалось и вставлялось с
/// оформлением и разделителями; символ-заглушка U+FFFC выбрасывается
/// (иначе он вставился бы буквой — странным символом в пункте списка)
Future<String?> cleanPastedPlainText(String text) async =>
    cleanPlainText(text);

String cleanPlainText(String text) => text
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll(_objectReplacement, '');

// ------------------------------------------------------------
//  Разбор документа
// ------------------------------------------------------------

class _Scan {
  _Scan(this.text, this.dividers, this.newlineAttrs);

  /// Текст документа: разделители (и другие вставки) — U+FFFC
  final String text;

  /// Позиции разделителей
  final Set<int> dividers;

  /// Атрибуты переносов строк (только непустые): позиция → атрибуты
  final Map<int, Map<String, dynamic>> newlineAttrs;

  /// Перенос, которым кончается строка с позицией [offset]
  int lineEnd(int offset) => text.indexOf('\n', offset);
}

_Scan _scan(List<dynamic> ops) {
  final text = StringBuffer();
  final dividers = <int>{};
  final attrsAt = <int, Map<String, dynamic>>{};
  var off = 0;
  for (final raw in ops) {
    final op = raw as Map;
    final ins = op['insert'];
    final attrs = op['attributes'];
    if (ins is String) {
      if (attrs is Map && attrs.isNotEmpty) {
        for (var i = 0; i < ins.length; i++) {
          if (ins.codeUnitAt(i) == 10) {
            attrsAt[off + i] = Map<String, dynamic>.from(attrs);
          }
        }
      }
      text.write(ins);
      off += ins.length;
    } else {
      if (ins is Map && ins.containsKey('divider')) dividers.add(off);
      text.write(_objectReplacement);
      off += 1;
    }
  }
  return _Scan(text.toString(), dividers, attrsAt);
}

// ------------------------------------------------------------
//  Инвариант: строка разделителя — только разделитель, без оформления
// ------------------------------------------------------------

/// Правка, после которой каждый разделитель стоит отдельной строкой без
/// атрибутов строки (список, отступ, заголовок, выравнивание, цитата,
/// код, задача — любые). Текст не теряется и не склеивается: если рядом с
/// разделителем в той же строке есть текст, строка разрезается, и текст
/// сохраняет своё оформление. null — всё и так в порядке.
Delta? dividerLineFix(List<dynamic> ops) {
  final s = _scan(ops);
  if (s.dividers.isEmpty) return null;
  final delta = Delta();
  var pos = 0;
  var changed = false;
  void retainTo(int to) {
    if (to > pos) {
      delta.retain(to - pos);
      pos = to;
    }
  }

  final sorted = s.dividers.toList()..sort();
  for (final d in sorted) {
    final end = s.lineEnd(d + 1);
    if (end < 0) continue;
    final lineAttrs = s.newlineAttrs[end];
    // перед разделителем в той же строке — текст (не другой разделитель:
    // тот уже отрезал строку после себя)
    final textBefore =
        d > 0 && s.text[d - 1] != '\n' && !s.dividers.contains(d - 1);
    final textAfter = end != d + 1;
    if (textBefore) {
      // текст перед разделителем остаётся строкой со своим оформлением
      retainTo(d);
      delta.insert('\n', lineAttrs);
      changed = true;
    }
    if (textAfter) {
      // строку разделителя закрывает новый перенос без оформления; текст
      // после него сохраняет прежний перенос (и оформление)
      retainTo(d + 1);
      delta.insert('\n');
      changed = true;
    } else if (lineAttrs != null) {
      retainTo(d + 1);
      delta.retain(1, {for (final k in lineAttrs.keys) k: null});
      pos = d + 2;
      changed = true;
    }
  }
  return changed ? delta : null;
}

/// Документ (ops) с исправленными строками разделителей — для загрузки
/// заметки в редактор
List<dynamic> normalizeDividerOps(List<dynamic> ops) {
  final fix = dividerLineFix(ops);
  if (fix == null) return ops;
  return Delta.fromJson(ops).compose(fix).toJson();
}

/// Документ для редактора из сохранённого delta (List) с исправленными
/// строками разделителей. Исправление не считается правкой: «сохранённое»
/// содержимое берётся уже из исправленного документа.
Document dividerSafeDocument(Object? ops) =>
    Document.fromJson(normalizeDividerOps(ops as List));

/// То же для JSON-строки delta; без исправлений — та же строка
String normalizeDividerJson(String json) {
  final List<dynamic> ops;
  try {
    ops = jsonDecode(json) as List;
  } catch (_) {
    return json;
  }
  final fix = dividerLineFix(ops);
  if (fix == null) return json;
  return jsonEncode(Delta.fromJson(ops).compose(fix).toJson());
}

/// Исправить строки разделителей в документе редактора без шага в
/// истории Ctrl+Z (вставка и её исправление отменяются одним Ctrl+Z).
/// true — что-то исправлено.
bool fixDividerLines(QuillController c) {
  final fix = dividerLineFix(c.document.toDelta().toJson());
  if (fix == null) return false;
  final sel = c.selection;
  final next = sel.isValid
      ? TextSelection(
          baseOffset: fix.transformPosition(sel.baseOffset),
          extentOffset: fix.transformPosition(sel.extentOffset))
      : sel;
  final history = c.document.history;
  final was = history.ignoreChange;
  history.ignoreChange = true;
  try {
    c.compose(fix, next, ChangeSource.local);
  } finally {
    history.ignoreChange = was;
  }
  return true;
}

// ------------------------------------------------------------
//  Удаление разделителя с клавиатуры
// ------------------------------------------------------------

/// Backspace: курсор (без выделения) в самом начале строки сразу под
/// разделителем, и у этой строки нет оформления (список, отступ, задача…
/// — тогда сначала работает обычный Backspace). Ответ — позиция
/// разделителя, который нужно убрать; null — не наш случай.
int? dividerAboveCaret(List<dynamic> ops, TextSelection sel) {
  if (!sel.isValid || !sel.isCollapsed) return null;
  final pos = sel.baseOffset;
  if (pos < 2) return null;
  final s = _scan(ops);
  if (pos > s.text.length) return null;
  if (s.text[pos - 1] != '\n' || !s.dividers.contains(pos - 2)) return null;
  final end = s.lineEnd(pos);
  if (end < 0 || s.newlineAttrs.containsKey(end)) return null;
  return pos - 2;
}

/// Delete: курсор (без выделения) в самом конце строки сразу над
/// разделителем. Строка курсора при удалении не меняется, поэтому её
/// оформление не важно. Ответ — позиция разделителя; null — не наш случай.
int? dividerBelowCaret(List<dynamic> ops, TextSelection sel) {
  if (!sel.isValid || !sel.isCollapsed) return null;
  final pos = sel.baseOffset;
  final s = _scan(ops);
  if (pos < 0 || pos + 1 >= s.text.length) return null;
  if (s.text[pos] != '\n' || !s.dividers.contains(pos + 1)) return null;
  return pos + 1;
}

/// Убрать разделитель в позиции [d] вместе с его переносом строки
Delta removeDividerDelta(int d) => Delta()
  ..retain(d)
  ..delete(2);
