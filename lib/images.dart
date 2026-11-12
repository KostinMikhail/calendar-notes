// Картинки в заметках.
//
// Сама картинка — отдельный документ users/{uid}/images/{id}:
//   data      — картинка (WebP/JPEG/PNG) в base64, не больше kMaxImageDataLength
//   mime      — 'image/webp' | 'image/jpeg' | 'image/png'
//   width, height — размер в пикселях
//   createdAt — время сервера
// В заметке — только ссылка: вставка {insert: {image: 'img:<id>'}} отдельной
// строкой (как разделитель). Поэтому заметка остаётся маленькой, а поиск и
// правописание картинку не видят. Документ картинки не меняется (только
// создаётся и читается); в резервную копию попадают картинки, на которые
// ссылаются заметки и темы.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'main.dart' show kCard, kDivider, kTextSecondary, kSurface, kAccent;
import 'motion.dart' show showAppDialog;
import 'offline.dart' show readDoc;
import 'image_web_stub.dart' if (dart.library.js_interop) 'image_web.dart'
    as web;

/// Картинка (байты файла) → сжатая для записи; null — не открылась или
/// не помещается даже после сжатия. Только в браузере.
Future<EncodedImage?> compressNoteImage(Uint8List bytes, String mime) =>
    web.compressImage(bytes, mime);

/// Картинка из буфера обмена (байты и тип) или null
Future<(Uint8List, String)?> clipboardImage() => web.readClipboardImage();

/// Получатель файлов, брошенных на страницу (null — снять)
void onImageDrops(
        void Function(List<(Uint8List, String)> images, int otherFiles)?
            onDrop) =>
    web.listenImageDrops(onDrop);

/// Ключ вставки в Delta (как у стандартной картинки Quill)
const String kImageEmbedKey = 'image';

/// Ссылка на картинку из нашей базы: `img:<id>`
const String kImageRefPrefix = 'img:';

/// Картинка в base64 — не длиннее (как в firestore.rules): с остальными
/// полями документ укладывается в предел Firestore 1 МиБ
const int kMaxImageDataLength = 900000;

/// Самая длинная сторона после сжатия
const int kImageMaxSide = 1600;

/// Самая большая сторона, которую примут правила (на всякий случай)
const int kImageMaxStoredSide = 4096;

const Set<String> kImageMimes = {'image/webp', 'image/jpeg', 'image/png'};

final RegExp _imageIdRe = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

bool isValidImageId(String id) => _imageIdRe.hasMatch(id);

/// Новый id картинки: 20 символов, как у Firestore
String newImageId([Random? random]) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final r = random ?? Random.secure();
  return String.fromCharCodes(
      List.generate(20, (_) => chars.codeUnitAt(r.nextInt(chars.length))));
}

String imageRef(String id) => '$kImageRefPrefix$id';

/// Ссылка из вставки → id картинки (null — не наша картинка, например
/// адрес из интернета: такие не загружаем)
String? imageIdOfRef(Object? data) {
  if (data is! String || !data.startsWith(kImageRefPrefix)) return null;
  final id = data.substring(kImageRefPrefix.length);
  return isValidImageId(id) ? id : null;
}

/// Операция Delta вставки картинки
Map<String, dynamic> imageEmbedOp(String id) => {
      'insert': {kImageEmbedKey: imageRef(id)},
    };

/// id всех наших картинок в Delta (строка JSON). Повреждённая Delta — пусто.
Set<String> imageIdsInDelta(String deltaJson) {
  final out = <String>{};
  Object? ops;
  try {
    ops = jsonDecode(deltaJson);
  } catch (_) {
    return out;
  }
  if (ops is! List) return out;
  for (final op in ops) {
    if (op is! Map) continue;
    final ins = op['insert'];
    if (ins is Map) {
      final id = imageIdOfRef(ins[kImageEmbedKey]);
      if (id != null) out.add(id);
    }
  }
  return out;
}

/// Готовая к записи картинка (уже сжатая)
@immutable
class EncodedImage {
  const EncodedImage({
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
  });
  final Uint8List bytes;
  final String mime;
  final int width;
  final int height;

  /// Длина в base64
  int get dataLength => ((bytes.length + 2) ~/ 3) * 4;
}

/// Картинка не подходит для записи — понятная причина или null
String? encodedImageProblem(EncodedImage img) {
  if (!kImageMimes.contains(img.mime)) return 'неподдерживаемый формат';
  if (img.bytes.isEmpty) return 'пустой файл';
  if (img.width <= 0 ||
      img.height <= 0 ||
      img.width > kImageMaxStoredSide ||
      img.height > kImageMaxStoredSide) {
    return 'неверный размер';
  }
  if (img.dataLength > kMaxImageDataLength) {
    return 'слишком большая даже после сжатия';
  }
  return null;
}

/// Поля документа картинки
Map<String, dynamic> imageDocFields(EncodedImage img) => {
      'data': base64Encode(img.bytes),
      'mime': img.mime,
      'width': img.width,
      'height': img.height,
      'createdAt': FieldValue.serverTimestamp(),
    };

/// Картинка из документа (поля проверяются; что-то не так — null)
EncodedImage? imageFromDoc(Map<String, dynamic>? d) {
  if (d == null) return null;
  final data = d['data'];
  final mime = d['mime'];
  final w = d['width'];
  final h = d['height'];
  if (data is! String || mime is! String || w is! int || h is! int) {
    return null;
  }
  if (data.length > kMaxImageDataLength || !kImageMimes.contains(mime)) {
    return null;
  }
  try {
    return EncodedImage(
        bytes: base64Decode(data), mime: mime, width: w, height: h);
  } catch (_) {
    return null;
  }
}

/// Результат загрузки картинки для показа
enum ImageLoadState { ok, missing, offline }

@immutable
class LoadedImage {
  const LoadedImage(this.state, [this.image]);
  final ImageLoadState state;
  final EncodedImage? image;
}

/// Источник картинок для редактора (подменяется в тестах)
abstract class ImageSource {
  Future<LoadedImage> load(String id);
}

/// Картинки вошедшего пользователя: чтение (с памятью на сессию) и запись
class ImageStore implements ImageSource {
  ImageStore(this.collection, {required this.offline, this.onLateError});

  /// users/{uid}/images; null — нет входа
  final CollectionReference<Map<String, dynamic>>? Function() collection;

  /// Сейчас нет связи (читаем только локальную копию)
  final bool Function() offline;

  /// Сервер позже отклонил запись картинки
  final void Function(Object error)? onLateError;

  final Map<String, Future<LoadedImage>> _cache = {};

  @override
  Future<LoadedImage> load(String id) {
    if (!isValidImageId(id)) {
      return Future.value(const LoadedImage(ImageLoadState.missing));
    }
    return _cache.putIfAbsent(id, () async {
      final r = await _read(id);
      // без связи картинки ещё нет на устройстве — спросим снова позже
      if (r.state != ImageLoadState.ok) _cache.remove(id);
      return r;
    });
  }

  Future<LoadedImage> _read(String id) async {
    final col = collection();
    if (col == null) return const LoadedImage(ImageLoadState.missing);
    final wasOffline = offline();
    try {
      final r = await readDoc(col.doc(id), offline: wasOffline);
      final img = imageFromDoc(r.value?.data());
      if (img != null) return LoadedImage(ImageLoadState.ok, img);
      return LoadedImage(r.fromCache || wasOffline
          ? ImageLoadState.offline
          : ImageLoadState.missing);
    } catch (_) {
      return LoadedImage(
          wasOffline ? ImageLoadState.offline : ImageLoadState.missing);
    }
  }

  /// Записывает картинку и сразу возвращает её id (запись — в очереди
  /// Firestore: без связи уйдёт позже). Картинка сразу видна в редакторе.
  String save(EncodedImage img) {
    final col = collection();
    if (col == null) throw StateError('signed out');
    final problem = encodedImageProblem(img);
    if (problem != null) throw ArgumentError(problem);
    final id = newImageId();
    _cache[id] = Future.value(LoadedImage(ImageLoadState.ok, img));
    col.doc(id).set(imageDocFields(img)).catchError((Object e) {
      onLateError?.call(e);
    });
    return id;
  }

  /// Уже прочитанная (или только что вставленная) картинка — без ожидания
  Future<LoadedImage>? cached(String id) => _cache[id];

  void clear() => _cache.clear();
}

// ============================================================
//  Показ в редакторе
// ============================================================

/// Вставка-картинка: отдельной строкой, не выше [maxHeight], не шире
/// строки. Щелчок — открыть в полный размер.
class ImageEmbedBuilder extends EmbedBuilder {
  const ImageEmbedBuilder(this.source, {this.maxHeight = 420});

  /// null — картинки не загружаются (например, редактор шаблонов)
  final ImageSource? source;
  final double maxHeight;

  @override
  String get key => kImageEmbedKey;

  @override
  bool get expanded => false;

  /// В буфере обмена (текст) — ничего
  @override
  String toPlainText(Embed node) => '';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final id = imageIdOfRef(embedContext.node.value.data);
    final src = source;
    if (id == null || src == null) {
      return const NoteImageStub(text: 'Картинка недоступна');
    }
    return NoteImage(
        key: ValueKey('img:$id'),
        id: id,
        source: src,
        maxHeight: maxHeight);
  }
}

/// Картинка в заметке (загрузка — один раз, дальше из памяти)
class NoteImage extends StatefulWidget {
  const NoteImage(
      {super.key, required this.id, required this.source, this.maxHeight = 420});
  final String id;
  final ImageSource source;
  final double maxHeight;

  @override
  State<NoteImage> createState() => _NoteImageState();
}

class _NoteImageState extends State<NoteImage> {
  late Future<LoadedImage> _load = widget.source.load(widget.id);

  @override
  void didUpdateWidget(NoteImage old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.source != widget.source) {
      _load = widget.source.load(widget.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LoadedImage>(
      future: _load,
      builder: (context, snap) {
        final r = snap.data;
        if (r == null) {
          return SizedBox(
            height: 96,
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: kAccent),
              ),
            ),
          );
        }
        final img = r.image;
        if (r.state != ImageLoadState.ok || img == null) {
          return NoteImageStub(
            text: r.state == ImageLoadState.offline
                ? 'Картинка появится, когда будет связь'
                : 'Картинка недоступна',
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: LayoutBuilder(builder: (context, c) {
            // не шире строки и не выше maxHeight, пропорции сохраняются
            final maxW = c.maxWidth.isFinite ? c.maxWidth : img.width.toDouble();
            var w = min(img.width.toDouble(), maxW);
            var h = w * img.height / img.width;
            if (h > widget.maxHeight) {
              h = widget.maxHeight;
              w = h * img.width / img.height;
            }
            return Align(
              alignment: Alignment.centerLeft,
              child: MouseRegion(
                cursor: SystemMouseCursors.zoomIn,
                child: GestureDetector(
                  onTap: () => showImageViewer(context, img),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      img.bytes,
                      width: w,
                      height: h,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) =>
                          const NoteImageStub(text: 'Картинка повреждена'),
                    ),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

/// Заглушка вместо картинки (нет, недоступна, повреждена)
class NoteImageStub extends StatelessWidget {
  const NoteImageStub({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDivider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, size: 18, color: kTextSecondary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: kTextSecondary, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// Картинка во весь экран: можно приблизить и подвинуть; закрыть — щелчок
/// мимо, Esc или крестик
Future<void> showImageViewer(BuildContext context, EncodedImage img) {
  return showAppDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      backgroundColor: kSurface,
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          InteractiveViewer(
            maxScale: 6,
            child: Center(
              child: Image.memory(img.bytes,
                  fit: BoxFit.contain, gaplessPlayback: true),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              tooltip: 'Закрыть',
              icon: Icon(Icons.close, color: kTextSecondary),
              onPressed: () => Navigator.pop(ctx),
            ),
          ),
        ],
      ),
    ),
  );
}
