// Не браузер (тесты, Android/iOS): сжатия, чтения картинки из буфера и
// перетаскивания файлов нет.
import 'dart:typed_data';

import 'images.dart' show EncodedImage;

Future<EncodedImage?> compressImage(Uint8List bytes, String mime) async => null;

Future<(Uint8List, String)?> readClipboardImage() async => null;

void listenImageDrops(
    void Function(List<(Uint8List, String)> images, int otherFiles)? onDrop) {}
