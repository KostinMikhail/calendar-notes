// Web Worker с nspell (web/spell/v1/spell_worker.js). Всё локально:
// словари грузятся с этого же сайта, текст никуда не отправляется.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'spell_backend.dart';

/// Где лежат воркер и словари (папка с версией — файлы кэшируются надолго)
const String kSpellWorkerUrl = 'spell/v1/spell_worker.js';

SpellBackend createBackend() => _WorkerBackend();

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external factory _Worker(String url);
  external void postMessage(JSAny? message);
  external set onmessage(JSFunction? f);
  external set onerror(JSFunction? f);
  external void terminate();
}

extension type _MessageEvent(JSObject _) implements JSObject {
  external JSAny? get data;
}

class _WorkerBackend implements SpellBackend {
  _Worker? _worker;
  int _nextId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  @override
  Future<void> start() async {
    final w = _Worker(kSpellWorkerUrl);
    _worker = w;
    w.onmessage = ((JSObject e) {
      final data = _MessageEvent(e).data;
      if (data == null) return;
      Map<String, dynamic> m;
      try {
        m = jsonDecode((data as JSString).toDart) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      final c = _pending.remove(m['id']);
      if (c == null) return;
      if (m['error'] != null) {
        c.completeError(StateError(m['error'].toString()));
      } else {
        c.complete(m);
      }
    }).toJS;
    w.onerror = ((JSObject _) {
      _failAll(StateError('spell worker error'));
    }).toJS;
    // словари: английский (быстро), затем русский (~2–3 с)
    await _send({'type': 'init', 'base': '', 'langs': ['en', 'ru']})
        .timeout(const Duration(seconds: 90));
  }

  void _failAll(Object e) {
    final all = _pending.values.toList();
    _pending.clear();
    for (final c in all) {
      if (!c.isCompleted) c.completeError(e);
    }
  }

  Future<Map<String, dynamic>> _send(Map<String, dynamic> msg) {
    final w = _worker;
    if (w == null) return Future.error(StateError('not started'));
    final id = ++_nextId;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    w.postMessage(jsonEncode({...msg, 'id': id}).toJS);
    return c.future;
  }

  @override
  Future<List<bool>> check(String lang, List<String> words) async {
    final m = await _send({'type': 'check', 'lang': lang, 'words': words});
    return [for (final v in m['results'] as List) v == true];
  }

  @override
  Future<List<String>> suggest(String lang, String word) async {
    final m = await _send({'type': 'suggest', 'lang': lang, 'word': word});
    return [for (final v in m['suggestions'] as List) v.toString()];
  }

  @override
  void dispose() {
    _failAll(StateError('disposed'));
    _worker?.terminate();
    _worker = null;
  }
}
