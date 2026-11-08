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

/// События браузера online / offline
void onBrowserOnlineChanged(void Function(bool online) callback) {
  try {
    _addEventListener('online', ((JSAny _) => callback(true)).toJS);
    _addEventListener('offline', ((JSAny _) => callback(false)).toJS);
  } catch (_) {}
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

/// Спрашивать браузером «Покинуть сайт?» при закрытии вкладки
void setLeaveGuard(bool on) {
  _leaveGuard = on;
  if (!on || _leaveListener) return;
  _leaveListener = true;
  try {
    _addEventListener(
        'beforeunload',
        ((JSObject e) {
          if (!_leaveGuard) return;
          final ev = _Event(e);
          ev.preventDefault();
          ev.returnValue = ''.toJS;
        }).toJS);
  } catch (_) {}
}
