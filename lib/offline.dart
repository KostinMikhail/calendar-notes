// Работа без сети во ВКЛАДКЕ, КОТОРАЯ УЖЕ ОТКРЫТА.
//
// • Локальная копия Firestore в IndexedDB (configureFirestoreCache): всё
//   записанное без сети лежит в очереди на устройстве и уходит на сервер
//   само, когда связь вернётся (в том числе после перезагрузки вкладки —
//   при следующем открытии сайта с сетью).
// • Сохранение не ждёт сервер дольше пары секунд (waitAck, SaveTracker):
//   запись уже в очереди — значит, сохранена на устройстве. Отказ сервера,
//   пришедший позже, не теряет текст (SaveTracker.onRejected).
// • Чтение: сначала сервер с коротким ожиданием, без сети — локальная
//   копия (readPreferServer).
// • Фоновая загрузка всех заметок в локальную копию (OfflineDownloader) и
//   «неизвестный день» (isUnknownDay).
//
// Открыть или перезагрузить сайт без сети по-прежнему нельзя: страница и
// библиотеки грузятся из сети (это вне задачи).
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'limits.dart' show NoteTooBigError;

import 'offline_web_stub.dart' if (dart.library.js_interop) 'offline_web.dart'
    as web;

// ============================================================
//  Тексты
// ============================================================

const String kStatusSaving = 'Сохранение...';
const String kStatusSaved = 'Сохранено ✓';
const String kStatusQueued =
    'Сохранено на устройстве — отправится при появлении сети';
const String kOfflineChip = 'Офлайн';
const String kNeedNetwork = 'Нужна сеть';
const String kNeedNetworkSignIn = 'Нужна сеть для входа';
const String kSearchLocalHint = 'Результаты из локальной копии';
const String kCacheLimitedHint =
    'Офлайн-защита ограничена: правки без сети не переживут закрытие вкладки';
const String kUnknownDayWarning =
    'Этого дня нет на устройстве. Если он уже заполнен, при появлении сети '
    'ваша запись заменит его.';
const String kSignOutPendingTitle = 'Есть несинхронизированные изменения';
const String kSignOutPendingBody =
    'Есть несинхронизированные изменения, при выходе они могут быть '
    'потеряны. Выйти?';

/// Сколько ждать подтверждения сервера, прежде чем считать запись
/// «сохранённой на устройстве»
const Duration kAckWait = Duration(milliseconds: 1800);

/// Сколько ждать ответа сервера при открытии дня, прежде чем взять
/// локальную копию
const Duration kReadWait = Duration(seconds: 3);

// ============================================================
//  Локальная копия Firestore
// ============================================================

bool _cacheLimited = false;

/// Локальную копию на диске включить не удалось: работаем как раньше
/// (копия только в памяти вкладки)
bool get offlineCacheLimited => _cacheLimited;

/// Включает локальную копию Firestore в IndexedDB. Вызывать сразу после
/// Firebase.initializeApp и ДО любого другого обращения к Firestore —
/// позже настройки уже не применяются.
///
/// Режим нескольких вкладок: все открытые вкладки делят одну копию (с
/// одной вкладкой-«владельцем» вторая осталась бы без защиты).
/// Если браузер не даёт IndexedDB/localStorage (запрет в настройках,
/// некоторые приватные режимы) — копия в памяти, как было до этого.
Future<bool> configureFirestoreCache(FirebaseFirestore db) async {
  if (!kIsWeb) return true; // Android/iOS: локальная копия включена всегда
  var ok = await web.storageAvailable();
  try {
    db.settings = ok
        ? const Settings(
            persistenceEnabled: true,
            cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
            webPersistentTabManager: WebPersistentMultipleTabManager(),
          )
        : const Settings(persistenceEnabled: false);
  } catch (_) {
    ok = false;
  }
  _cacheLimited = !ok;
  return ok;
}

/// Браузер: события online/offline (для быстрого значка «Офлайн»).
/// Слушатель один на страницу: новый вызов заменяет прежний, null — снять.
void listenBrowserOnline(void Function(bool online)? callback) =>
    web.onBrowserOnlineChanged(callback);

/// Пауза перед [failures]-м автоматическим повтором загрузки заметки:
/// 5, 10, 20, 40 с, дальше раз в минуту (аудит, F10). Кнопка «Повторить»
/// не ждёт.
Duration loadRetryDelay(int failures) {
  if (failures <= 1) return const Duration(seconds: 5);
  if (failures >= 5) return const Duration(seconds: 60);
  return Duration(seconds: 5 << (failures - 1));
}

/// Браузер считает, что сети нет
bool get browserSaysOffline => web.browserOnline() == false;

/// Просить подтверждение при закрытии вкладки
void setLeaveGuard(bool on) => web.setLeaveGuard(on);

/// [hook] вызывается при закрытии или перезагрузке вкладки — до того, как
/// браузер решит, спрашивать ли «Покинуть сайт?»
void setBeforeUnloadHook(void Function()? hook) =>
    web.setBeforeUnloadHook(hook);

/// Сколько после постановки записи в очередь её считаем «свежей»: Firestore
/// кладёт очередь в IndexedDB асинхронно, и закрытие вкладки в этот момент
/// может её потерять
const Duration kFreshWriteWindow = Duration(seconds: 1);

/// Спрашивать ли браузером «Покинуть сайт?» при закрытии вкладки:
/// • [dirty] — в редакторе правки, ещё не поставленные в очередь;
/// • [freshWrite] — запись только что ушла в очередь (≤ [kFreshWriteWindow]);
/// • [tooBig] — заметка не сохраняется из-за размера, текст только в памяти;
/// • без локальной копии на диске ([cacheLimited]) — всё, что не дошло до
///   сервера ([unsynced]).
/// С локальной копией очередь, уже лежащая в IndexedDB, переживает закрытие
/// вкладки — по ней не спрашиваем.
bool needsLeaveGuard({
  required bool dirty,
  required bool freshWrite,
  required bool tooBig,
  required bool cacheLimited,
  required bool unsynced,
}) =>
    dirty || freshWrite || tooBig || (cacheLimited && unsynced);

// ============================================================
//  Есть ли связь
// ============================================================

/// «Офлайн» — по сигналам Firestore (снимок из кэша у постоянно открытой
/// подписки) и браузера. Уход в офлайн по Firestore — с небольшой
/// задержкой (при запуске первый снимок всегда из кэша), возврат — сразу.
class ConnectionMonitor extends ChangeNotifier {
  ConnectionMonitor({
    this.offlineDelay = const Duration(milliseconds: 1500),
    this.startupDelay = const Duration(seconds: 5),
  });

  final Duration offlineDelay;
  final Duration startupDelay;

  bool _browserOffline = false;
  bool _storeOffline = false;
  bool _seenServer = false;
  Timer? _pending;
  bool _disposed = false;
  final List<void Function()> _onReconnect = [];

  bool get offline => _browserOffline || _storeOffline;

  /// Вызывается, когда связь вернулась
  void addReconnectListener(void Function() f) => _onReconnect.add(f);

  void browserChanged(bool online) {
    final was = offline;
    _browserOffline = !online;
    _emit(was);
  }

  /// Снимок постоянной подписки: [fromCache] — данные не подтверждены
  /// сервером (нет связи)
  void storeChanged(bool fromCache) {
    if (_disposed) return;
    if (!fromCache) {
      _seenServer = true;
      _pending?.cancel();
      _pending = null;
      if (_storeOffline) {
        final was = offline;
        _storeOffline = false;
        _emit(was);
      }
      return;
    }
    if (_storeOffline || _pending != null) return;
    _pending = Timer(_seenServer ? offlineDelay : startupDelay, () {
      _pending = null;
      if (_disposed) return;
      final was = offline;
      _storeOffline = true;
      _emit(was);
    });
  }

  void _emit(bool was) {
    if (_disposed || was == offline) return;
    notifyListeners();
    if (was && !offline) {
      for (final f in List.of(_onReconnect)) {
        f();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pending?.cancel();
    _onReconnect.clear();
    super.dispose();
  }
}

// ============================================================
//  Запись: не ждать сервер дольше пары секунд
// ============================================================

enum WriteAck {
  /// сервер подтвердил
  acked,

  /// подтверждения пока нет: запись в очереди на устройстве
  queued,
}

/// Ждёт подтверждения записи не дольше [wait]. Ошибка до этого срока —
/// исключение. Позже — [onLateAck] / [onLateError] (исходная запись
/// продолжает отслеживаться).
Future<WriteAck> waitAck(
  Future<void> write, {
  Duration wait = kAckWait,
  void Function()? onLateAck,
  void Function(Object error)? onLateError,
}) {
  final c = Completer<WriteAck>();
  final timer = Timer(wait, () {
    if (!c.isCompleted) c.complete(WriteAck.queued);
  });
  write.then((_) {
    timer.cancel();
    if (!c.isCompleted) {
      c.complete(WriteAck.acked);
    } else {
      onLateAck?.call();
    }
  }, onError: (Object e, StackTrace st) {
    timer.cancel();
    if (!c.isCompleted) {
      c.completeError(e, st);
    } else {
      onLateError?.call(e);
    }
  });
  return c.future;
}

/// Содержимое одной записи заметки (дня или темы)
class SavePayload {
  const SavePayload({required this.json, required this.text, this.accent});
  final String json;
  final String text;
  final String? accent;
}

/// Запись, которую сервер отклонил (после этого Firestore сам убирает её
/// из локальной копии) — текст держим здесь, чтобы не потерять
class RejectedSave {
  const RejectedSave(this.payload, this.error);
  final SavePayload payload;
  final Object error;
}

enum SaveOutcome { acked, queued, failed }

/// Учёт записей заметок: что ещё не подтверждено сервером, что отклонено.
/// Записи одной заметки Firestore отправляет строго по порядку; решает
/// последняя (в ней весь документ целиком), отказ более старой при
/// следующей записи не важен.
class SaveTracker extends ChangeNotifier {
  SaveTracker({this.ackWait = kAckWait});

  final Duration ackWait;

  /// Последняя запись заметки [key] подтверждена сервером
  void Function(String key)? onAcked;

  /// Последнюю запись заметки [key] сервер отклонил (сразу или позже)
  void Function(String key, RejectedSave rejected)? onRejected;

  int _seq = 0;
  bool _disposed = false;
  final Map<int, String> _pending = {};
  final Map<String, int> _latest = {};
  final Map<String, RejectedSave> _rejected = {};

  /// Есть записи без подтверждения сервера
  bool get hasPending => _pending.isNotEmpty;

  /// Есть что-то не дошедшее до сервера (в очереди или отклонённое)
  bool get hasUnsynced => _pending.isNotEmpty || _rejected.isNotEmpty;

  bool get hasRejected => _rejected.isNotEmpty;

  /// Есть заметки, которые не отправлялись из-за размера (их текст только
  /// в памяти вкладки)
  bool get hasTooBig =>
      _rejected.values.any((r) => r.error is NoteTooBigError);

  /// У заметки есть неподтверждённая или отклонённая запись — пока так,
  /// изменения «из базы» для неё не применяем (иначе откат после отказа
  /// сервера стёр бы текст в редакторе)
  bool isUnsettled(String key) =>
      _rejected.containsKey(key) || _pending.containsValue(key);

  RejectedSave? rejected(String key) => _rejected[key];

  /// Отклонённую запись больше не храним (например, тема удалена)
  void forget(String key) {
    if (_rejected.remove(key) != null) notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    onAcked = null;
    onRejected = null;
    super.dispose();
  }

  /// Запись не отправляли (например, заметка слишком большая) — держим
  /// текст как отклонённый. Более ранние записи этой заметки его уже не
  /// снимут: решает последняя. [onRejected] не вызывается.
  void hold(String key, SavePayload payload, Object error) {
    _latest[key] = ++_seq;
    _rejected[key] = RejectedSave(payload, error);
    notifyListeners();
  }

  /// [write] уже начата (уже в очереди Firestore). Ответ — не позже
  /// [ackWait].
  Future<SaveOutcome> track(
      String key, Future<void> write, SavePayload payload) async {
    final seq = ++_seq;
    _pending[seq] = key;
    _latest[key] = seq;
    notifyListeners();

    void settle(Object? error) {
      _pending.remove(seq);
      if (_latest[key] == seq) {
        if (error == null) {
          _rejected.remove(key);
          onAcked?.call(key);
        } else {
          final r = RejectedSave(payload, error);
          _rejected[key] = r;
          onRejected?.call(key, r);
        }
      }
      notifyListeners();
    }

    try {
      final ack = await waitAck(
        write,
        wait: ackWait,
        onLateAck: () => settle(null),
        onLateError: settle,
      );
      if (ack == WriteAck.acked) {
        settle(null);
        return SaveOutcome.acked;
      }
      return SaveOutcome.queued;
    } catch (e) {
      settle(e);
      return SaveOutcome.failed;
    }
  }
}

// ============================================================
//  Чтение: сервер с коротким ожиданием, иначе локальная копия
// ============================================================

class CacheRead<T> {
  const CacheRead(this.value, {required this.fromCache});
  final T value;

  /// Ответ не с сервера, а из локальной копии
  final bool fromCache;
}

/// Ошибка из-за связи (а не из-за доступа)
bool isConnectionError(Object e) =>
    e is TimeoutException ||
    (e is FirebaseException &&
        (e.code == 'unavailable' || e.code == 'deadline-exceeded'));

/// [offline] — сразу локальная копия; иначе сервер, а если он не ответил
/// за [timeout] (или нет связи) — локальная копия. Поздний ответ сервера
/// отбрасывается. Ошибки доступа пробрасываются как есть.
Future<CacheRead<T>> readPreferServer<T>({
  required bool offline,
  required Future<T> Function() server,
  required Future<T> Function() cache,
  Duration timeout = kReadWait,
}) async {
  if (!offline) {
    // поздний ответ (и поздняя ошибка) сервера гасится здесь
    final c = Completer<CacheRead<T>?>();
    final timer = Timer(timeout, () {
      if (!c.isCompleted) c.complete(null);
    });
    server().then((v) {
      timer.cancel();
      if (!c.isCompleted) c.complete(CacheRead(v, fromCache: false));
    }, onError: (Object e, StackTrace st) {
      timer.cancel();
      if (!c.isCompleted) c.completeError(e, st);
    });
    try {
      final r = await c.future;
      if (r != null) return r;
    } catch (e) {
      if (!isConnectionError(e)) rethrow;
    }
  }
  return CacheRead(await cache(), fromCache: true);
}

/// Документ: сервер (как обычный get) или локальная копия. null — в
/// локальной копии документа нет.
Future<CacheRead<DocumentSnapshot<Map<String, dynamic>>?>> readDoc(
  DocumentReference<Map<String, dynamic>> ref, {
  required bool offline,
  Duration timeout = kReadWait,
}) async {
  final r = await readPreferServer<DocumentSnapshot<Map<String, dynamic>>?>(
    offline: offline,
    server: () => ref.get(),
    cache: () => readDocFromCache(ref),
    timeout: timeout,
  );
  // обычный get без связи сам отвечает из локальной копии
  final fromCache = r.fromCache || (r.value?.metadata.isFromCache ?? false);
  return CacheRead(r.value, fromCache: fromCache);
}

Future<DocumentSnapshot<Map<String, dynamic>>?> readDocFromCache(
    DocumentReference<Map<String, dynamic>> ref) async {
  try {
    return await ref.get(const GetOptions(source: Source.cache));
  } on FirebaseException catch (e) {
    if (e.code == 'unavailable' || e.code == 'not-found') return null;
    rethrow;
  }
}

/// Запрос: сервер ([serverOnly] — именно с сервера, как в поиске и
/// резервной копии) или локальная копия
Future<CacheRead<QuerySnapshot<Map<String, dynamic>>>> readQuery(
  Query<Map<String, dynamic>> query, {
  required bool offline,
  Duration timeout = kReadWait,
  bool serverOnly = false,
}) =>
    readPreferServer<QuerySnapshot<Map<String, dynamic>>>(
      offline: offline,
      server: () => serverOnly
          ? query.get(const GetOptions(source: Source.server))
          : query.get(),
      cache: () => query.get(const GetOptions(source: Source.cache)),
      timeout: timeout,
    );

// ============================================================
//  Неизвестный день
// ============================================================

/// День открыт без ответа сервера, в локальной копии его нет и полной
/// копии всех заметок на устройстве ещё не было: возможно, на сервере он
/// заполнен. Открываем как обычный пустой день, но с предупреждением.
bool isUnknownDay({
  required bool fromCache,
  required bool exists,
  required bool downloadComplete,
}) =>
    fromCache && !exists && !downloadComplete;

/// Можно ли записывать день: только то, что загружено, туда же, и только
/// если в нём что-то изменили (нетронутый шаблон не сохраняем)
bool shouldSaveDay({
  required String? loadedKey,
  required String targetKey,
  required String currentJson,
  required String savedJson,
}) =>
    loadedKey != null && loadedKey == targetKey && currentJson != savedJson;

/// Можно ли вводить текст в редактор: в нём та заметка, которая выбрана, и
/// она загружена. Иначе ввод попал бы в чужой (старый) документ, сохранить
/// его нельзя (см. [shouldSaveDay]) и он пропал бы при подмене документа.
bool noteEditable({
  required String? loadedKey,
  required String targetKey,
  bool signingOut = false,
}) =>
    !signingOut && loadedKey != null && loadedKey == targetKey;

// ============================================================
//  Фоновая загрузка всех заметок в локальную копию
// ============================================================

/// Откуда грузить (Firestore — FirestoreCopySource; в тестах — подделка)
abstract class OfflineCopySource {
  /// Коллекции по порядку
  List<String> get collections;

  /// Сколько всего документов (для подсказки); null — неизвестно
  Future<int?> total();

  /// Страница id документов после [afterId] (по id), с сервера
  Future<List<String>> page(String collection, String? afterId, int limit);

  /// Прочие документы (настройки шаблонов)
  Future<void> extras();
}

/// Отметка «полная копия уже была» для пользователя
abstract class CopyMarker {
  bool isComplete(String uid);
  void markComplete(String uid);
}

/// Отметка в localStorage браузера (ошибки — молча)
class LocalCopyMarker implements CopyMarker {
  const LocalCopyMarker();

  static String _key(String uid) => 'calendar-notes.offline-copy.$uid';

  @override
  bool isComplete(String uid) => web.readLocal(_key(uid)) == '1';

  @override
  void markComplete(String uid) => web.writeLocal(_key(uid), '1');
}

/// Раз за загрузку страницы: все заметки (и темы, настройки) с сервера
/// постранично — они остаются в локальной копии. Без сети — пропуск и
/// повтор при её появлении. Ошибки — молча. Сами документы в памяти не
/// держим.
class OfflineDownloader extends ChangeNotifier {
  OfflineDownloader({
    required this.source,
    required this.marker,
    required this.uid,
    required this.isOffline,
    this.pageSize = 100,
    this.markerTrusted = true,
    this.retryDelay = const Duration(seconds: 60),
    this.maxRetries = 3,
  });

  final OfflineCopySource source;
  final CopyMarker marker;
  final String uid;
  final bool Function() isOffline;
  final int pageSize;

  /// Отметке в localStorage можно верить, только если локальная копия на
  /// диске (иначе после перезагрузки на устройстве ничего нет)
  final bool markerTrusted;
  final Duration retryDelay;
  final int maxRetries;

  bool _completeNow = false;
  bool _running = false;
  bool _stopped = false;
  int _done = 0;
  int? _total;
  bool _totalAsked = false;
  int _ci = 0;
  String? _after;
  bool _extrasDone = false;
  int _retries = 0;
  Timer? _retry;

  /// Полная копия есть: в этой загрузке страницы или раньше
  bool get complete =>
      _completeNow || (markerTrusted && marker.isComplete(uid));

  /// Полная копия получена в этой загрузке страницы
  bool get completeThisLoad => _completeNow;

  bool get running => _running;
  int get done => _done;

  /// «Копия для офлайна: 120/250», пока идёт
  String? get progressText {
    if (!_running) return null;
    final t = _total;
    return 'Копия для офлайна: $_done${t != null ? '/$t' : ''}';
  }

  /// Запуск или продолжение с места остановки
  Future<void> run() async {
    if (_running || _completeNow || _stopped || isOffline()) return;
    _retry?.cancel();
    _retry = null;
    _running = true;
    notifyListeners();
    var failed = false;
    try {
      if (!_totalAsked) {
        _totalAsked = true;
        try {
          _total = await source.total();
        } catch (_) {}
      }
      final cols = source.collections;
      while (_ci < cols.length) {
        if (_stopped || isOffline()) return;
        final ids = await source.page(cols[_ci], _after, pageSize);
        _done += ids.length;
        if (ids.length < pageSize) {
          _ci++;
          _after = null;
        } else {
          _after = ids.last;
        }
        notifyListeners();
      }
      if (!_extrasDone) {
        await source.extras();
        _extrasDone = true;
      }
      _completeNow = true;
      marker.markComplete(uid);
    } catch (_) {
      failed = true; // молча; продолжим позже с того же места
    } finally {
      _running = false;
      if (!_stopped) notifyListeners();
    }
    if (failed && !_stopped && !isOffline() && _retries < maxRetries) {
      _retries++;
      _retry = Timer(retryDelay, run);
    }
  }

  /// Связь вернулась — продолжить
  void onReconnect() {
    _retries = 0;
    run();
  }

  @override
  void dispose() {
    _stopped = true;
    _retry?.cancel();
    super.dispose();
  }
}

/// Источник для фоновой загрузки на Firestore
class FirestoreCopySource implements OfflineCopySource {
  FirestoreCopySource(this.user, {this.timeout = const Duration(seconds: 60)});

  /// users/{uid}; null — вышли из аккаунта
  final DocumentReference<Map<String, dynamic>>? Function() user;
  final Duration timeout;

  DocumentReference<Map<String, dynamic>> get _user {
    final u = user();
    if (u == null) throw StateError('signed out');
    return u;
  }

  @override
  List<String> get collections => const ['notes', 'topics'];

  @override
  Future<int?> total() async {
    var sum = 0;
    for (final c in collections) {
      final r = await _user
          .collection(c)
          .count()
          .get(source: AggregateSource.server)
          .timeout(timeout);
      final n = r.count;
      if (n == null) return null;
      sum += n;
    }
    return sum;
  }

  @override
  Future<List<String>> page(
      String collection, String? afterId, int limit) async {
    Query<Map<String, dynamic>> q =
        _user.collection(collection).orderBy(FieldPath.documentId);
    if (afterId != null) q = q.startAfter([afterId]);
    final snap = await q
        .limit(limit)
        .get(const GetOptions(source: Source.server))
        .timeout(timeout);
    return [for (final d in snap.docs) d.id];
  }

  @override
  Future<void> extras() async {
    await _user
        .collection('settings')
        .doc('templates')
        .get(const GetOptions(source: Source.server))
        .timeout(timeout);
  }
}

// ============================================================
//  Выход из аккаунта
// ============================================================

/// Есть ли записи, не дошедшие до сервера (в том числе оставшиеся в
/// очереди с прошлого раза). Ждёт сервер не дольше [wait].
Future<bool> hasUnsyncedWrites({
  required Future<void> Function() waitForPendingWrites,
  required bool Function() hasRejected,
  Duration wait = const Duration(seconds: 2),
}) async {
  try {
    await waitForPendingWrites().timeout(wait);
  } catch (_) {
    return true;
  }
  // ответы по отслеживаемым записям приходят следом
  await Future<void>.delayed(Duration.zero);
  return hasRejected();
}
