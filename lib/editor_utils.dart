// Мелкие функции редактора без Flutter-виджетов: проверяются тестами.

import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' show Document;

/// Строка документа вокруг [offset] для выделения тройным щелчком
/// (см. [lineRangeInText])
TextRange? lineRangeAt(Document doc, int offset) =>
    lineRangeInText(doc.toPlainText(), offset);

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

/// Ctrl+Shift+X — зачёркнутый. По физической клавише: в русской раскладке
/// та же клавиша — «Ч».
bool isStrikeHotkey({
  required bool ctrl,
  required bool shift,
  required bool alt,
  required PhysicalKeyboardKey physical,
}) =>
    ctrl && shift && !alt && physical == PhysicalKeyboardKey.keyX;

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
DividerInsert dividerInsertOps(List<dynamic> docOps, int offset) =>
    blockEmbedInsertOps(docOps, offset, _dividerOp);

/// То же для любой вставки-объекта отдельной строкой ([embedOp] —
/// операция вида {insert: {ключ: значение}}, например картинка)
DividerInsert blockEmbedInsertOps(
    List<dynamic> docOps, int offset, Map<String, dynamic> embedOp) {
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
    return DividerInsert([embedOp, {'insert': '\n'}], 2);
  }
  final o = offset.clamp(0, text.length - 1);
  final atLineStart = o == 0 || text[o - 1] == '\n';
  final atLineEnd = text[o] == '\n';

  if (atLineStart) {
    return DividerInsert([
      if (o > 0) {'retain': o},
      embedOp,
      {'insert': '\n'},
    ], o + 2);
  }
  if (atLineEnd && o != text.length - 1) {
    return DividerInsert([
      {'retain': o + 1},
      embedOp,
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
    embedOp,
    {'insert': '\n'},
  ], o + 3);
}

// ============================================================
//  Тройной щелчок — выделить строку
// ============================================================

/// Строка (абзац до перевода строки) вокруг позиции [offset] в простом
/// тексте документа — без завершающего перевода строки. null — выделять
/// нечего: пустая строка или строка-разделитель.
TextRange? lineRangeInText(String plain, int offset) {
  if (plain.isEmpty) return null;
  final o = offset.clamp(0, plain.length - 1);
  final start = o == 0 ? 0 : plain.lastIndexOf('\n', o - 1) + 1;
  var end = plain.indexOf('\n', o);
  if (end < 0) end = plain.length;
  if (end <= start) return null; // пустая строка
  final text = plain.substring(start, end);
  // разделитель (и другие вставки) — строка из одного символа-объекта
  if (text.replaceAll('\uFFFC', '').isEmpty) return null;
  return TextRange(start: start, end: end);
}

/// Подсчёт щелчков мышью подряд: следующий засчитывается, если он пришёл
/// не позже [window] после предыдущего и не дальше [slop] пикселей.
/// После третьего счёт начинается заново.
class ClickCounter {
  ClickCounter({
    this.window = const Duration(milliseconds: 500),
    this.slop = 8,
  });

  final Duration window;
  final double slop;

  Duration? _lastTime;
  Offset? _lastPos;
  int _count = 0;

  /// Номер щелчка в серии (1, 2, 3)
  int get count => _count;

  int register(Offset position, Duration time) {
    final last = _lastTime;
    final lastPos = _lastPos;
    if (last != null &&
        lastPos != null &&
        _count < 3 &&
        time - last <= window &&
        (position - lastPos).distance <= slop) {
      _count++;
    } else {
      _count = 1;
    }
    _lastTime = time;
    _lastPos = position;
    return _count;
  }

  void reset() {
    _count = 0;
    _lastTime = null;
    _lastPos = null;
  }
}

// ---------- ссылки: только безопасные адреса ----------

/// Схемы, которые можно сохранить в ссылке и открыть. Всё остальное
/// (javascript:, data:, file:, blob:, intent:…) — нельзя: открытие такой
/// ссылки может выполнить код или показать чужое содержимое.
const Set<String> kLinkSchemes = {'http', 'https', 'mailto', 'tel'};

/// Подсказка, когда адрес не подошёл
const String kLinkSchemesHint = 'Можно только адреса http, https, mailto и tel';

final RegExp _schemeRe = RegExp(
  r'^([a-zA-Z][a-zA-Z0-9+.-]*):(.*)$',
  dotAll: true,
);
final RegExp _controlRe = RegExp(r'[\u0000-\u001F\u007F-\u009F\s]');

/// Адрес, введённый пользователем, → адрес для ссылки или null, если
/// такой адрес ссылкой быть не может. Без схемы (example.com,
/// localhost:3000/путь) добавляется https://.
String? normalizeLink(String raw) {
  final s = raw.trim();
  if (s.isEmpty || _controlRe.hasMatch(s)) return null;
  final m = _schemeRe.firstMatch(s);
  String url;
  if (m == null) {
    url = 'https://$s';
  } else {
    final scheme = m.group(1)!;
    final rest = m.group(2)!;
    // «example.com:8080», «localhost:3000» — это адрес с портом, не схема
    final looksLikeHost = scheme.contains('.') || RegExp(r'^\d').hasMatch(rest);
    if (looksLikeHost) {
      url = 'https://$s';
    } else if (kLinkSchemes.contains(scheme.toLowerCase())) {
      url = s;
    } else {
      return null;
    }
  }
  return safeLinkUri(url) == null ? null : url;
}

/// Сохранённая ссылка → адрес для открытия или null (не открываем).
/// Проверяется заново при каждом открытии: ссылка могла попасть в заметку
/// до этой проверки (старая версия, восстановление из копии).
Uri? safeLinkUri(String url) {
  final s = url.trim();
  if (s.isEmpty || _controlRe.hasMatch(s)) return null;
  final m = _schemeRe.firstMatch(s);
  final full =
      m == null ||
          m.group(1)!.contains('.') ||
          RegExp(r'^\d').hasMatch(m.group(2)!)
      ? 'https://$s'
      : s;
  final uri = Uri.tryParse(full);
  if (uri == null || !kLinkSchemes.contains(uri.scheme)) return null;
  if ((uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isEmpty) {
    return null;
  }
  if ((uri.scheme == 'mailto' || uri.scheme == 'tel') && uri.path.isEmpty) {
    return null;
  }
  return uri;
}
