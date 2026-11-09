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
import 'motion.dart' show FadeScaleIn, Motion, showAppDialog;
import 'offline.dart' show kSearchLocalHint;
import 'search.dart';
import 'topics.dart' show Topic, topicIdOf, topicKey;

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
  NoteSearchCache(this._load, {this.loadTopics});

  /// Загрузка всех документов заметок: id → поля
  final Future<Map<String, Map<String, dynamic>>> Function() _load;

  /// Загрузка всех документов тем: id → поля (нужен только текст)
  final Future<Map<String, Map<String, dynamic>>> Function()? loadTopics;

  Map<String, String>? _topicTexts;

  /// Тексты тем: id → текст. Названия и список тем берутся из панели тем.
  Map<String, String> get topicTexts => _topicTexts ?? const {};

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
    final topicDocs = loadTopics == null
        ? const <String, Map<String, dynamic>>{}
        : await loadTopics!();
    final map = <String, SearchNote>{};
    docs.forEach((id, data) {
      if (!isValidDateKey(id)) return;
      final text = noteTextFromData(data);
      if (text != null) map[id] = SearchNote(id, text);
    });
    final topics = <String, String>{};
    topicDocs.forEach((id, data) {
      final text = noteTextFromData(data);
      if (text != null) topics[id] = text;
    });
    _notes = map;
    _topicTexts = topics;
    _loadedAt = DateTime.now();
  }

  /// После сохранения дня — обновить его запись (если кэш есть)
  void put(String key, String text) {
    final n = _notes;
    if (n != null) n[key] = SearchNote(key, text);
  }

  /// После сохранения темы — обновить её текст (если кэш есть)
  void putTopicText(String id, String text) {
    final t = _topicTexts;
    if (t != null) t[id] = text;
  }

  /// После удаления темы
  void removeTopic(String id) => _topicTexts?.remove(id);

  /// После восстановления из копии — всё перечитать
  void invalidate() {
    _notes = null;
    _topicTexts = null;
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
  List<Topic> Function()? topics,
  bool Function()? localCopy,
}) {
  return showAppDialog<SearchPick>(
    context: context,
    barrierDismissible: true,
    slide: true, // поиск — затухание и небольшой сдвиг вверх
    builder: (_) => NoteSearchDialog(
      cache: cache,
      boilerplate: boilerplate,
      liveKey: liveKey,
      liveText: liveText,
      inCalendarRange: inCalendarRange,
      topics: topics,
      localCopy: localCopy,
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
    this.topics,
    this.localCopy,
  });

  final NoteSearchCache cache;
  final Set<String> boilerplate;

  /// Ключ открытого в редакторе: дата или `t:<id>` темы (null — не загружено)
  final String? Function() liveKey;
  final String Function() liveText;
  final bool Function(String key) inCalendarRange;

  /// Текущий список тем (названия, время изменения)
  final List<Topic> Function()? topics;

  /// Заметки взяты из локальной копии (нет связи) — показать подсказку
  final bool Function()? localCopy;

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
  List<TopicSearchHit> _topicHits = const []; // идут в списке первыми
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
    if (key != null && topicIdOf(key) == null) {
      map[key] = SearchNote(key, widget.liveText());
    }
    return map.values.toList();
  }

  /// Темы для поиска: список из панели + тексты из кэша (открытая — из
  /// редактора, с несохранёнными правками)
  List<SearchTopic> _topicSources() {
    final list = widget.topics?.call() ?? const <Topic>[];
    final liveId = topicIdOf(widget.liveKey());
    return [
      for (final t in list)
        SearchTopic(
          t.id,
          t.title,
          t.id == liveId
              ? widget.liveText()
              : (widget.cache.topicTexts[t.id] ?? ''),
          updatedAt: t.updatedAt,
        ),
    ];
  }

  int get _topicCount => _topicHits.length;
  int get _total => _topicHits.length + _hits.length;

  void _onQueryChanged() {
    if (_query.text == _applied) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _run);
    setState(() {}); // кнопка «×»
  }

  void _run() {
    if (!mounted) return;
    final q = _query.text;
    final ready = !_loading && _error == null;
    final hits = ready
        ? searchNotes(_sources(), q, widget.boilerplate)
        : const <SearchHit>[];
    final topicHits =
        ready ? searchTopics(_topicSources(), q) : const <TopicSearchHit>[];
    setState(() {
      _applied = q;
      _hits = hits;
      _topicHits = topicHits;
      _rowKeys = List.generate(
          math.min(_total, _maxRows), (_) => GlobalKey());
      _active = _firstEnabled(0, 1) ?? 0;
    });
    if (_list.hasClients) _list.jumpTo(0);
  }

  bool _enabled(int i) =>
      i < _topicCount || widget.inCalendarRange(_hits[i - _topicCount].key);

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
          duration: Motion.fast,
          alignmentPolicy: step > 0
              ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
              : ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    }
  }

  void _open(int i) {
    if (i < 0 || i >= _rowKeys.length || !_enabled(i)) return;
    final key = i < _topicCount
        ? topicKey(_topicHits[i].topic.id)
        : _hits[i - _topicCount].key;
    Navigator.of(context).pop(SearchPick(key, queryWords(_applied)));
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
    final text = _resultText();
    return widget.localCopy?.call() ?? false
        ? '$text · $kSearchLocalHint'
        : text;
  }

  String _resultText() {
    final q = _applied;
    final topics = widget.topics?.call().length ?? 0;
    if (q.trim().isEmpty) {
      return 'Заметок для поиска: ${_sources().length}'
          '${topics > 0 ? ', тем: $topics' : ''}';
    }
    if (!isQueryLongEnough(q)) return 'Введите минимум 2 символа';
    if (_topicHits.isNotEmpty) {
      return 'Найдено тем: ${_topicHits.length}, дней: ${_hits.length}';
    }
    return 'Найдено дней: ${_hits.length}';
  }

  Widget _searchField() {
    return Focus(
      onKeyEvent: _onKey,
      child: TextField(
        controller: _query,
        focusNode: _queryFocus,
        autofocus: true,
        style: TextStyle(color: kTextPrimary),
        cursorColor: kAccent,
        decoration: InputDecoration(
          hintText: 'Поиск по заметкам',
          hintStyle: TextStyle(color: kTextSecondary),
          prefixIcon: Icon(Icons.search, color: kTextSecondary),
          suffixIcon: _query.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Очистить',
                  icon: Icon(Icons.close, color: kTextSecondary),
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
            borderSide: BorderSide(color: kDivider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: kAccent),
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
        style: TextStyle(color: kTextSecondary, fontSize: 13, height: 1.35),
        children: spans,
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// Название темы с подсветкой совпадений
  Widget _titleWithHighlights(String title, List<TextRange2> ranges) {
    final base = TextStyle(
        color: kTextPrimary, fontSize: 14, fontWeight: FontWeight.w600);
    final spans = <TextSpan>[];
    var pos = 0;
    for (final r in ranges) {
      if (r.start > pos) spans.add(TextSpan(text: title.substring(pos, r.start)));
      spans.add(TextSpan(
        text: title.substring(r.start, r.end),
        style: TextStyle(
          color: kAccentLight,
          backgroundColor: kAccent.withValues(alpha: 0.18),
        ),
      ));
      pos = r.end;
    }
    if (pos < title.length) spans.add(TextSpan(text: title.substring(pos)));
    return Text.rich(TextSpan(style: base, children: spans),
        maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  Widget _countBadge(int count) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: kDivider),
        ),
        child: Text(
          pluralMatches(count),
          style: TextStyle(color: kTextSecondary, fontSize: 11),
        ),
      );

  /// Строка результата-темы: значок и название вместо даты
  Widget _topicRow(int i) {
    final hit = _topicHits[i];
    final active = i == _active;
    final row = AnimatedContainer(
      key: _rowKeys[i],
      duration: Motion.fast, // подсветка строки перетекает
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
              Icon(Icons.topic_outlined, size: 16, color: kAccent),
              const SizedBox(width: 6),
              Expanded(
                child: _titleWithHighlights(hit.topic.title, hit.titleRanges),
              ),
              if (hit.count > 1) _countBadge(hit.count),
            ],
          ),
          if (hit.hits.lines.isNotEmpty) ...[
            const SizedBox(height: 4),
            _snippet(buildSnippet(hit.hits.lines.first)),
          ],
        ],
      ),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _active = i),
      child: GestureDetector(onTap: () => _open(i), child: row),
    );
  }

  Widget _row(int i) {
    if (i < _topicCount) return _topicRow(i);
    final hit = _hits[i - _topicCount];
    final enabled = _enabled(i);
    final active = enabled && i == _active;
    final row = AnimatedContainer(
      key: _rowKeys[i],
      duration: Motion.fast, // подсветка строки перетекает
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
                  style: TextStyle(
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
                    style: TextStyle(color: kTextSecondary, fontSize: 11),
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
      return Padding(
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
      return Padding(
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
    if (_total == 0) {
      return Padding(
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
        itemCount: shown + (_total > shown ? 1 : 0),
        itemBuilder: (_, i) {
          // новые результаты мягко проявляются, первые строки — лесенкой
          // (шаг 20 мс, не больше нескольких строк)
          if (i < shown) {
            return FadeScaleIn(
              key: ObjectKey(_rowKeys[i]),
              duration: Motion.fast,
              delay: Motion.stagger(i),
              child: _row(i),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'Показано $shown из $_total. Уточните запрос.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kTextSecondary, fontSize: 12),
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
        side: BorderSide(color: kDivider),
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
                  style: TextStyle(color: kTextSecondary, fontSize: 12),
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
