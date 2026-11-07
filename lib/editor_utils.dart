// Мелкие функции редактора без Flutter-виджетов: проверяются тестами.

import 'package:flutter/services.dart';

/// Ctrl+Shift+«минус» — вставить разделитель. С Shift минус в разных
/// раскладках приходит как minus или underscore; на цифровом блоке —
/// numpadSubtract. Смотрим и на физическую клавишу.
bool isDividerHotkey({
  required bool ctrl,
  required bool shift,
  required bool alt,
  required LogicalKeyboardKey logical,
  required PhysicalKeyboardKey physical,
}) =>
    ctrl &&
    shift &&
    !alt &&
    (physical == PhysicalKeyboardKey.minus ||
        physical == PhysicalKeyboardKey.numpadSubtract ||
        logical == LogicalKeyboardKey.minus ||
        logical == LogicalKeyboardKey.underscore ||
        logical == LogicalKeyboardKey.numpadSubtract);

/// Изменение документа для вставки разделителя (операции Delta) и где
/// поставить курсор после неё
class DividerInsert {
  const DividerInsert(this.ops, this.caret);
  final List<Map<String, dynamic>> ops;
  final int caret;
}

const Map<String, dynamic> _dividerOp = {
  'insert': {'divider': 'hr'},
};

/// Вставка разделителя отдельной строкой в позицию [offset] документа
/// [docOps] (Delta документа, как toDelta().toJson()):
///  • курсор в начале строки — разделитель перед этой строкой;
///  • в конце непустой строки — после неё;
///  • в середине — строка делится, обе части сохраняют её оформление
///    (например, пункт списка), разделитель между ними.
/// Курсор встаёт на строку после разделителя.
DividerInsert dividerInsertOps(List<dynamic> docOps, int offset) {
  // текст документа (вставки-объекты — один символ) и оформление строк
  final plain = StringBuffer();
  final lineAttrs = <int, Map<String, dynamic>?>{}; // позиция '\n' → атрибуты
  for (final raw in docOps) {
    final op = raw as Map;
    final ins = op['insert'];
    final attrs = op['attributes'] is Map
        ? Map<String, dynamic>.from(op['attributes'] as Map)
        : null;
    if (ins is String) {
      for (var i = 0; i < ins.length; i++) {
        if (ins[i] == '\n') lineAttrs[plain.length] = attrs;
        plain.write(ins[i]);
      }
    } else {
      plain.write('\uFFFC');
    }
  }
  final text = plain.toString();
  if (text.isEmpty) {
    return const DividerInsert([_dividerOp, {'insert': '\n'}], 2);
  }
  final o = offset.clamp(0, text.length - 1);
  final atLineStart = o == 0 || text[o - 1] == '\n';
  final atLineEnd = text[o] == '\n';

  if (atLineStart) {
    return DividerInsert([
      if (o > 0) {'retain': o},
      _dividerOp,
      {'insert': '\n'},
    ], o + 2);
  }
  if (atLineEnd && o != text.length - 1) {
    return DividerInsert([
      {'retain': o + 1},
      _dividerOp,
      {'insert': '\n'},
    ], o + 3);
  }
  // середина строки или конец документа (за последний перевод строки
  // вставлять нельзя): делим строку, курсор — на строку после разделителя
  final lineEnd = text.indexOf('\n', o);
  final attrs = lineAttrs[lineEnd];
  return DividerInsert([
    {'retain': o},
    {
      'insert': '\n',
      if (attrs != null && attrs.isNotEmpty) 'attributes': attrs,
    },
    _dividerOp,
    {'insert': '\n'},
  ], o + 3);
}
