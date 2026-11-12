// Браузер: картинки для заметок — сжатие (canvas), чтение из буфера обмена
// (Ctrl+V) и перетаскивание файлов. Только dart:js_interop (из SDK), без
// новых пакетов. Для тестов и других платформ — image_web_stub.dart.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';
import 'dart:typed_data';

import 'images.dart'
    show EncodedImage, kImageMaxSide, kMaxImageDataLength, encodedImageProblem;

// ---------- типы браузера ----------

extension type _Blob(JSObject _) implements JSObject {
  external String get type;
  external int get size;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

@JS('Blob')
extension type _NewBlob._(JSObject _) implements _Blob {
  external factory _NewBlob(JSArray<JSAny> parts, JSObject options);
}

@JS('createImageBitmap')
external JSPromise<_ImageBitmap> _createImageBitmap(JSObject source);

extension type _ImageBitmap(JSObject _) implements JSObject {
  external int get width;
  external int get height;
  external void close();
}

@JS('document')
external _Document get _document;

extension type _Document(JSObject _) implements JSObject {
  external JSObject createElement(String tag);
  external void addEventListener(String type, JSFunction listener);
}

extension type _Canvas(JSObject _) implements JSObject {
  external set width(int v);
  external set height(int v);
  external _Context2D? getContext(String id);
  external void toBlob(JSFunction callback, String type, num quality);
}

extension type _Context2D(JSObject _) implements JSObject {
  external set fillStyle(String v);
  external set imageSmoothingQuality(String v);
  external void fillRect(num x, num y, num w, num h);
  external void drawImage(JSObject image, num x, num y, num w, num h);
}

@JS('navigator.clipboard')
external _Clipboard? get _clipboard;

extension type _Clipboard(JSObject _) implements JSObject {
  external JSPromise<JSArray<_ClipboardItem>> read();
}

extension type _ClipboardItem(JSObject _) implements JSObject {
  external JSArray<JSString> get types;
  external JSPromise<_Blob> getType(String type);
}

extension type _DragEvent(JSObject _) implements JSObject {
  external void preventDefault();
  external _DataTransfer? get dataTransfer;
}

extension type _DataTransfer(JSObject _) implements JSObject {
  external JSObject get types;
  external _FileList get files;
  external set dropEffect(String v);
}

extension type _FileList(JSObject _) implements JSObject {
  external int get length;
  external _Blob? item(int i);
}

Future<Uint8List> _bytesOf(_Blob b) async =>
    (await b.arrayBuffer().toDart).toDart.asUint8List();

// ---------- сжатие ----------

Future<_Blob?> _toBlob(_Canvas c, String type, double quality) {
  final done = Completer<_Blob?>();
  c.toBlob(
      ((JSObject? b) {
        if (!done.isCompleted) done.complete(b == null ? null : _Blob(b));
      }).toJS,
      type,
      quality);
  return done.future.timeout(const Duration(seconds: 20), onTimeout: () => null);
}

_Canvas _canvas(int w, int h) {
  final c = _Canvas(_document.createElement('canvas'));
  c.width = w;
  c.height = h;
  return c;
}

/// Картинка (любой формат, который умеет браузер) → WebP (или JPEG, где
/// WebP не кодируется) не больше [kImageMaxSide] по длинной стороне и не
/// длиннее [kMaxImageDataLength] в base64. null — открыть не удалось или
/// не помещается даже после сжатия.
Future<EncodedImage?> compressImage(Uint8List bytes, String mime) async {
  _ImageBitmap bmp;
  try {
    final blob = _NewBlob([bytes.toJS].toJS, {'type': mime}.jsify() as JSObject);
    bmp = await _createImageBitmap(blob).toDart;
  } catch (_) {
    return null;
  }
  try {
    final sw = bmp.width, sh = bmp.height;
    if (sw <= 0 || sh <= 0) return null;
    for (final side in [kImageMaxSide, 1280, 1024, 800, 640]) {
      final scale = min(1.0, side / max(sw, sh));
      final w = max(1, (sw * scale).round());
      final h = max(1, (sh * scale).round());
      for (final q in [0.85, 0.72, 0.6]) {
        // WebP сохраняет прозрачность
        final c = _canvas(w, h);
        final ctx = c.getContext('2d');
        if (ctx == null) return null;
        ctx.imageSmoothingQuality = 'high';
        ctx.drawImage(bmp, 0, 0, w, h);
        var out = await _toBlob(c, 'image/webp', q);
        var outMime = 'image/webp';
        if (out == null || out.type != 'image/webp') {
          // браузер не кодирует WebP (Safari) — JPEG на белом фоне
          final j = _canvas(w, h);
          final jctx = j.getContext('2d');
          if (jctx == null) return null;
          jctx.fillStyle = '#ffffff';
          jctx.fillRect(0, 0, w, h);
          jctx.imageSmoothingQuality = 'high';
          jctx.drawImage(bmp, 0, 0, w, h);
          out = await _toBlob(j, 'image/jpeg', q);
          outMime = 'image/jpeg';
        }
        if (out == null) return null;
        final data = await _bytesOf(out);
        final img =
            EncodedImage(bytes: data, mime: outMime, width: w, height: h);
        if (img.dataLength <= kMaxImageDataLength &&
            encodedImageProblem(img) == null) {
          return img;
        }
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    try {
      bmp.close();
    } catch (_) {}
  }
}

// ---------- буфер обмена ----------

/// Картинка из буфера обмена (снимок экрана, «Копировать картинку»).
/// null — картинки нет или браузер не дал прочитать буфер.
Future<(Uint8List, String)?> readClipboardImage() async {
  try {
    final cb = _clipboard;
    if (cb == null) return null;
    final items = (await cb.read().toDart).toDart;
    for (final item in items) {
      for (final t in item.types.toDart) {
        final type = t.toDart;
        if (!type.startsWith('image/')) continue;
        final blob = await item.getType(type).toDart;
        return (await _bytesOf(blob), type);
      }
    }
  } catch (_) {}
  return null;
}

// ---------- перетаскивание ----------

void Function(List<(Uint8List, String)> images, int otherFiles)? _onDrop;
bool _dropListening = false;

bool _hasFiles(_DataTransfer? dt) {
  if (dt == null) return false;
  try {
    final r = dt.types.callMethod<JSAny?>('includes'.toJS, 'Files'.toJS);
    return r.isA<JSBoolean>() && (r as JSBoolean).toDart;
  } catch (_) {
    return false;
  }
}

/// Файлы, брошенные на страницу. Брошенный файл браузер больше не
/// открывает вместо приложения (это потеряло бы несохранённый текст).
/// [onDrop] получает картинки и число остальных (не картинок) файлов;
/// null — снять получателя.
void listenImageDrops(
    void Function(List<(Uint8List, String)> images, int otherFiles)? onDrop) {
  _onDrop = onDrop;
  if (_dropListening) return;
  _dropListening = true;
  try {
    _document.addEventListener(
        'dragover',
        ((JSObject e) {
          final ev = _DragEvent(e);
          final dt = ev.dataTransfer;
          if (!_hasFiles(dt)) return;
          ev.preventDefault();
          try {
            dt!.dropEffect = _onDrop == null ? 'none' : 'copy';
          } catch (_) {}
        }).toJS);
    _document.addEventListener(
        'drop',
        ((JSObject e) {
          final ev = _DragEvent(e);
          final dt = ev.dataTransfer;
          if (!_hasFiles(dt)) return;
          ev.preventDefault();
          final cb = _onDrop;
          if (cb == null) return;
          final files = dt!.files;
          final blobs = <_Blob>[];
          var others = 0;
          for (var i = 0; i < files.length; i++) {
            final f = files.item(i);
            if (f == null) continue;
            if (f.type.startsWith('image/')) {
              blobs.add(f);
            } else {
              others++;
            }
          }
          unawaited(() async {
            final out = <(Uint8List, String)>[];
            for (final b in blobs) {
              try {
                out.add((await _bytesOf(b), b.type));
              } catch (_) {
                others++;
              }
            }
            _onDrop?.call(out, others);
          }());
        }).toJS);
  } catch (_) {
    _dropListening = false;
  }
}
