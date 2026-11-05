// Окно «Поиск по заметкам» и кэш заметок для него.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' show Document;

import 'backup.dart' show describeError, formatRuDate, isValidDateKey;
import 'main.dart'
    show
        kAccent,
        kAccentLight,
        kCard,
        kDivider,
        kSurface,
        kTextPrimary,
        kTextSecondary,
        kWeekdaysShort;
import 'search.dart';

/// Видимый текст документа заметки. Если поля text нет — собирается из
/// delta. null — текст получить не удалось (заметка пропускается).
String? noteTextFromData(Map<String, dynamic> data) {
  final text = data['text'];
  if (text is String && text.isNotEmpty) return text;
  final delta = data['delta'];
  if (delta is String && delta.isNotEmpty) {
    try {
      return Document.fromJson(jsonDecode(delta) as List).toPlainText();
    } catch (_) {
      return null;
    }
  }
  return text is String ? text : null;
}

/// Заметки пользователя в памяти: загружаются одним запросом и живут
/// 5 минут. Хранится только ключ дня и текст.
class NoteSearchCache {
  NoteSearchCache(this._load);

  /// Загрузка всех документов заметок: id → поля
  final Future<Map<String, Map<String, dynamic>>> Function() _load;

  static const Duration ttl = Duration(minutes: 5);

  Map<String, SearchNote>? _notes;
  DateTime? _loadedAt;
  Future<void>? _loading;

  bool get isFresh =>
      _notes != null &&
      _loadedAt != null &&
      DateTime.now().difference(_loadedAt!) < ttl;

  Map<String, SearchNote> get notes => _notes ?? const {};

  /// Загружает, если кэша нет или он устарел
  Future<void> ensure() {
    if (isFresh) return Future.value();
    return _loading ??= _fetch().whenComplete(() => _loading = null);
  }

  Future<void> _fetch() async {
    final docs = await _load();
    final map = <String, SearchNote>{};
    docs.forEach((id, data) {
      if (!isValidDateKey(id)) return;
      final text = noteTextFromData(data);
      if (text != null) map[id] = SearchNote(id, text);
    });
    _notes = map;
    _loadedAt = DateTime.now();
  }

  /// После сохранения дня — обновить его запись (если кэш есть)
  void put(String key, String text) {
    final n = _notes;
    if (n != null) n[key] = SearchNote(key, text);
  }

  /// После восстановления из копии — всё перечитать
  void invalidate() {
    _notes = null;
    _loadedAt = null;
  }
}

/// Выбранный результат: день и слова запроса (для выделения в редакторе)
class SearchPick {
  const SearchPick(this.key, this.words);
  final String key;
  final List<String> words;
}

/// Открывает окно поиска. Возвращает выбранный день или null.
Future<SearchPick?> showNoteSearch(
  BuildContext context, {
  required NoteSearchCache cache,
  required Set<String> boilerplate,
  required String? Function() liveKey,
  required String Function() liveText,
  required bool Function(String key) inCalendarRange,
}) {
  return showDialog<SearchPick>(
    context: context,
    barrierDismissible: true,
    builder: (_) => NoteSearchDialog(
      cache: cache,
      boilerplate: boilerplate,
      liveKey: liveKey,
      liveText: liveText,
      inCalendarRange: inCalendarRange,
    ),
  );
}

class NoteSearchDialog extends StatefulWidget {
  const NoteSearchDialog({
    super.key,
    required this.cache,
    required this.boilerplate,
    required this.liveKey,
    required this.liveText,
    required this.inCalendarRange,
  });

  final NoteSearchCache cache;
  final Set<String> boilerplate;
  final String? Function() liveKey;
  final String Function() liveText;
  final bool Function(String key) inCalendarRange;

  @override
  State<NoteSearchDialog> createState() => _NoteSearchDialogState();
}

class _NoteSearchDialogState extends State<NoteSearchDialog> {
  static const int _maxRows = 100;

  final _query = TextEditingController();
  final _queryFocus = FocusNode();
  final _list = ScrollController();
  Timer? _debounce;

  bool _loading = false;
  String? _error;
  String _applied = ''; // запрос, по которому посчитаны результаты
  List<SearchHit> _hits = const [];
  int _active = 0; // подсвеченная строка
  List<GlobalKey> _rowKeys = const [];

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQueryChanged);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _queryFocus.dispose();
    _list.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.cache.isFresh) {
      _run();
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.cache.ensure();
      if (!mounted) return;
      setState(() => _loading = false);
      _run();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = describeError(e);
      });
    }
    // кнопка «Повторить» исчезает вместе с фокусом — вернуть его в поле,
    // иначе ввод может уйти в редактор под окном
    if (mounted) _queryFocus.requestFocus();
  }

  /// Заметки для поиска: кэш + живой текст открытого дня
  List<SearchNote> _sources() {
    final map = Map<String, SearchNote>.of(widget.cache.notes);
    final key = widget.liveKey();
    if (key != null) map[key] = SearchNote(key, widget.liveText());
    return map.values.toList();
  }

  void _onQueryChanged() {
    if (_query.text == _applied) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _run);
    setState(() {}); // кнопка «×»
  }

  void _run() {
    if (!mounted) return;
    final q = _query.text;
    final hits = (_loading || _error != null)
        ? const <SearchHit>[]
        : searchNotes(_sources(), q, widget.boilerplate);
    setState(() {
      _applied = q;
      _hits = hits;
      _rowKeys = List.generate(
          math.min(hits.length, _maxRows), (_) => GlobalKey());
      _active = _firstEnabled(0, 1) ?? 0;
    });
    if (_list.hasClients) _list.jumpTo(0);
  }

  bool _enabled(int i) => widget.inCalendarRange(_hits[i].key);

  int? _firstEnabled(int from, int step) {
    for (var i = from; i >= 0 && i < _rowKeys.length; i += step) {
      if (_enabled(i)) return i;
    }
    return null;
  }

  void _move(int step) {
    if (_rowKeys.isEmpty) return;
    final next = _firstEnabled(_active + step, step);
    if (next == null) return;
    setState(() => _active = next);
    final ctx = _rowKeys[next].currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 120),
          alignmentPolicy: step > 0
              ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
              : ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    }
  }

  void _open(int i) {
    if (i < 0 || i >= _rowKeys.length || !_enabled(i)) return;
    Navigator.of(context)
        .pop(SearchPick(_hits[i].key, queryWords(_applied)));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (e is KeyDownEvent) {
        // дождаться поиска, если запрос ещё не применён
        if (_query.text != _applied) {
          _debounce?.cancel();
          _run();
        }
        _open(_active);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------- вид ----------

  String _statusText() {
    if (_loading) return 'Загрузка заметок…';
    if (_error != null) return '';
    final q = _applied;
    if (q.trim().isEmpty) return 'Заметок для поиска: ${_sources().length}';
    if (!isQueryLongEnough(q)) return 'Введите минимум 2 символа';
    return 'Найдено дней: ${_hits.length}';
  }

  Widget _searchField() {
    return Focus(
      onKeyEvent: _onKey,
      child: TextField(
        controller: _query,
        focusNode: _queryFocus,
        autofocus: true,
        style: const TextStyle(color: kTextPrimary),
        cursorColor: kAccent,
        decoration: InputDecoration(
          hintText: 'Поиск по заметкам',
          hintStyle: const TextStyle(color: kTextSecondary),
          prefixIcon: const Icon(Icons.search, color: kTextSecondary),
          suffixIcon: _query.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Очистить',
                  icon: const Icon(Icons.close, color: kTextSecondary),
                  onPressed: () {
                    _query.clear();
                    _queryFocus.requestFocus();
                  },
                ),
          filled: true,
          fillColor: kCard,
          isDense: true,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kDivider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kAccent),
          ),
        ),
      ),
    );
  }

  String _dateLabel(String key) {
    final d = DateTime.parse(key);
    return '${formatRuDate(key)}, ${kWeekdaysShort[d.weekday - 1]}';
  }

  Widget _snippet(Snippet s) {
    final spans = <TextSpan>[];
    var pos = 0;
    for (final r in s.highlights) {
      if (r.start > pos) spans.add(TextSpan(text: s.text.substring(pos, r.start)));
      spans.add(TextSpan(
        text: s.text.substring(r.start, r.end),
        style: TextStyle(
          color: kAccentLight,
          fontWeight: FontWeight.w700,
          backgroundColor: kAccent.withValues(alpha: 0.18),
        ),
      ));
      pos = r.end;
    }
    if (pos < s.text.length) spans.add(TextSpan(text: s.text.substring(pos)));
    return Text.rich(
      TextSpan(
        style: const TextStyle(color: kTextSecondary, fontSize: 13, height: 1.35),
        children: spans,
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _row(int i) {
    final hit = _hits[i];
    final enabled = _enabled(i);
    final active = enabled && i == _active;
    final row = Container(
      key: _rowKeys[i],
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: active ? kAccent.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: active ? kAccent : Colors.transparent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _dateLabel(hit.key),
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (hit.hits.count > 1)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: kDivider),
                  ),
                  child: Text(
                    pluralMatches(hit.hits.count),
                    style: const TextStyle(color: kTextSecondary, fontSize: 11),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          _snippet(buildSnippet(hit.hits.lines.first)),
        ],
      ),
    );
    if (!enabled) {
      return Tooltip(
        message: 'Дата вне диапазона календаря',
        child: Opacity(opacity: 0.4, child: row),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _active = i),
      child: GestureDetector(onTap: () => _open(i), child: row),
    );
  }

  Widget _body() {
    if (_loading && _query.text.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: kAccent),
          ),
        ),
      );
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: LinearProgressIndicator(color: kAccent, backgroundColor: kCard),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Text(
              'Не удалось загрузить заметки: $_error.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFFF5C5C), fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: kAccent),
              onPressed: _load,
              child: const Text('Повторить'),
            ),
          ],
        ),
      );
    }
    if (!isQueryLongEnough(_applied)) return const SizedBox.shrink();
    if (_hits.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text('Ничего не найдено',
              style: TextStyle(color: kTextSecondary)),
        ),
      );
    }
    final shown = _rowKeys.length;
    return Flexible(
      child: ListView.builder(
        controller: _list,
        shrinkWrap: true,
        itemCount: shown + (_hits.length > shown ? 1 : 0),
        itemBuilder: (_, i) {
          if (i < shown) return _row(i);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'Показано $shown из ${_hits.length}. Уточните запрос.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: kTextSecondary, fontSize: 12),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: kSurface,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kDivider),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.min(560, size.width - 32),
          maxHeight: size.height * 0.75,
        ),
        child: SizedBox(
          width: math.min(560, size.width - 32),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _searchField(),
                const SizedBox(height: 10),
                Text(
                  _statusText(),
                  style: const TextStyle(color: kTextSecondary, fontSize: 12),
                ),
                const SizedBox(height: 8),
                _body(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
