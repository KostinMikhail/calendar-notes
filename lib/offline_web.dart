// Браузер: проверка хранилищ, сигнал «онлайн/офлайн», localStorage и
// предупреждение при закрытии вкладки. Только dart:js_interop (из SDK),
// без новых пакетов. Для тестов и других платформ — offline_web_stub.dart.
import 'dart:async';
import 'dart:js_interop';

@JS('navigator')
external _Navigator get _navigator;

extension type _Navigator(JSObject _) implements JSObject {
  external bool get onLine;
}

@JS('localStorage')
external _Storage? get _localStorage;

extension type _Storage(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
  external void removeItem(String key);
}

@JS('indexedDB')
external _IdbFactory? get _indexedDB;

extension type _IdbFactory(JSObject _) implements JSObject {
  external _IdbRequest open(String name);
  external JSObject deleteDatabase(String name);
}

extension type _IdbRequest(JSObject _) implements JSObject {
  external set onsuccess(JSFunction f);
  external set onerror(JSFunction f);
  external _IdbDatabase? get result;
}

extension type _IdbDatabase(JSObject _) implements JSObject {
  external void close();
}

extension type _Event(JSObject _) implements JSObject {
  external void preventDefault();
  external set returnValue(JSAny value);
}

@JS('addEventListener')
external void _addEventListener(String type, JSFunction listener);

/// IndexedDB и localStorage работают (не приватный режим с запретом,
/// не заблокированы настройками сайта)
Future<bool> storageAvailable() async {
  try {
    final ls = _localStorage;
    if (ls == null) return false;
    ls.setItem('cn-probe', '1');
    ls.removeItem('cn-probe');
  } catch (_) {
    return false;
  }
  try {
    final idb = _indexedDB;
    if (idb == null) return false;
    final done = Completer<bool>();
    final req = idb.open('calendar-notes-probe');
    req.onsuccess = ((JSAny _) {
      try {
        req.result?.close();
        idb.deleteDatabase('calendar-notes-probe');
      } catch (_) {}
      if (!done.isCompleted) done.complete(true);
    }).toJS;
    req.onerror = ((JSAny _) {
      if (!done.isCompleted) done.complete(false);
    }).toJS;
    return await done.future
        .timeout(const Duration(seconds: 3), onTimeout: () => false);
  } catch (_) {
    return false;
  }
}

/// Что думает браузер о сети (null — неизвестно)
bool? browserOnline() {
  try {
    return _navigator.onLine;
  } catch (_) {
    return null;
  }
}

void Function(bool online)? _onlineCallback;
bool _onlineListening = false;

/// События браузера online / offline. Слушатели окна ставятся один раз;
/// новый вызов заменяет получателя, null — снимает его.
void onBrowserOnlineChanged(void Function(bool online)? callback) {
  _onlineCallback = callback;
  if (callback == null || _onlineListening) return;
  _onlineListening = true;
  try {
    _addEventListener(
        'online', ((JSAny _) => _onlineCallback?.call(true)).toJS);
    _addEventListener(
        'offline', ((JSAny _) => _onlineCallback?.call(false)).toJS);
  } catch (_) {
    _onlineListening = false;
  }
}

String? readLocal(String key) {
  try {
    return _localStorage?.getItem(key);
  } catch (_) {
    return null;
  }
}

void writeLocal(String key, String value) {
  try {
    _localStorage?.setItem(key, value);
  } catch (_) {}
}

bool _leaveGuard = false;
bool _leaveListener = false;
void Function()? _beforeUnload;

void _listenBeforeUnload() {
  if (_leaveListener) return;
  _leaveListener = true;
  try {
    _addEventListener(
        'beforeunload',
        ((JSObject e) {
          // сначала дать странице сохранить (поставить запись в очередь) —
          // хук может включить защиту
          try {
            _beforeUnload?.call();
          } catch (_) {}
          if (!_leaveGuard) return;
          final ev = _Event(e);
          ev.preventDefault();
          ev.returnValue = ''.toJS;
        }).toJS);
  } catch (_) {}
}

/// Спрашивать браузером «Покинуть сайт?» при закрытии вкладки
void setLeaveGuard(bool on) {
  _leaveGuard = on;
  if (on) _listenBeforeUnload();
}

/// Вызывается при закрытии/перезагрузке вкладки до решения о вопросе
void setBeforeUnloadHook(void Function()? hook) {
  _beforeUnload = hook;
  if (hook != null) _listenBeforeUnload();
}

// ---------- оформление: значок вкладки, цвет вкладки, фон страницы ----------

@JS('document')
external _Document get _document;

extension type _Document(JSObject _) implements JSObject {
  external _Element? querySelector(String selector);
  external _Element createElement(String tag);
  external _Element? get head;
  external _Element? get body;
  external _Element? get documentElement;
}

extension type _Element(JSObject _) implements JSObject {
  external void setAttribute(String name, String value);
  external void appendChild(_Element child);
  external _Style get style;
}

extension type _Style(JSObject _) implements JSObject {
  external set backgroundColor(String value);
}

_Element? _headTag(String selector, String tag, Map<String, String> attrs) {
  final found = _document.querySelector(selector);
  if (found != null) return found;
  final head = _document.head;
  if (head == null) return null;
  final el = _document.createElement(tag);
  attrs.forEach((k, v) => el.setAttribute(k, v));
  head.appendChild(el);
  return el;
}

void setBrowserChrome({required String favicon, required String color}) {
  try {
    _headTag('link[rel="icon"]', 'link', {'rel': 'icon', 'type': 'image/png'})
        ?.setAttribute('href', favicon);
    _headTag('meta[name="theme-color"]', 'meta', {'name': 'theme-color'})
        ?.setAttribute('content', color);
    _document.documentElement?.style.backgroundColor = color;
    _document.body?.style.backgroundColor = color;
  } catch (_) {}
}
