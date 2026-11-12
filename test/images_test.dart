// Картинки в заметках: ссылки в Delta, проверка размера, показ в редакторе,
// резервная копия и восстановление.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:calendar_notes/backup.dart';
import 'package:calendar_notes/editor_utils.dart';
import 'package:calendar_notes/images.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

/// Картинка 1×1 PNG
final Uint8List _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

EncodedImage _img({int w = 1, int h = 1, String mime = 'image/png'}) =>
    EncodedImage(bytes: _png, mime: mime, width: w, height: h);

class _FakeSource implements ImageSource {
  _FakeSource(this.result);
  LoadedImage result;
  final List<String> asked = [];
  @override
  Future<LoadedImage> load(String id) async {
    asked.add(id);
    return result;
  }
}

class _FakeRestore implements ImageRestoreStore {
  _FakeRestore(this.have);
  final Set<String> have;
  final List<List<String>> batches = [];
  @override
  Future<Set<String>> existing(List<String> ids) async =>
      ids.where(have.contains).toSet();
  @override
  Future<void> create(List<BackupImage> images) async {
    batches.add([for (final i in images) i.id]);
    have.addAll(images.map((i) => i.id));
  }
}

BackupImage _bimg(String id, {String? data}) => BackupImage(
    id: id,
    mime: 'image/png',
    width: 1,
    height: 1,
    data: data ?? base64Encode(_png));

Future<void> _pumpEditor(WidgetTester t, String ref, ImageSource? src) async {
  final c = QuillController.basic()
    ..document = Document.fromJson([
      {'insert': 'до\n'},
      {
        'insert': {kImageEmbedKey: ref}
      },
      {'insert': '\nпосле\n'},
    ]);
  await t.pumpWidget(MaterialApp(
    localizationsDelegates: const [FlutterQuillLocalizations.delegate],
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 600,
        child: QuillEditor(
          controller: c,
          focusNode: FocusNode(),
          scrollController: ScrollController(),
          config: QuillEditorConfig(
            expands: true,
            embedBuilders: [ImageEmbedBuilder(src)],
          ),
        ),
      ),
    ),
  ));
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
}

void main() {
  group('ссылки на картинки', () {
    test('новый id — 20 символов, подходит правилам, не повторяется', () {
      final r = Random(1);
      final ids = {for (var i = 0; i < 200; i++) newImageId(r)};
      expect(ids.length, 200);
      for (final id in ids) {
        expect(id.length, 20);
        expect(isValidImageId(id), isTrue);
      }
    });

    test('ссылка ↔ id; чужие адреса не загружаем', () {
      expect(imageRef('abcdEFGH12'), 'img:abcdEFGH12');
      expect(imageIdOfRef('img:abcdEFGH12'), 'abcdEFGH12');
      expect(imageIdOfRef('https://example.com/a.png'), isNull);
      expect(imageIdOfRef('img:../../x'), isNull);
      expect(imageIdOfRef('img:short'), isNull);
      expect(imageIdOfRef(42), isNull);
      expect(imageIdOfRef(null), isNull);
    });

    test('id картинок в Delta', () {
      final delta = jsonEncode([
        {'insert': 'текст\n'},
        imageEmbedOp('aaaaaaaa11'),
        {'insert': '\n'},
        {
          'insert': {'divider': 'hr'}
        },
        {'insert': '\n'},
        imageEmbedOp('bbbbbbbb22'),
        {'insert': '\n'},
        {
          'insert': {'image': 'https://example.com/x.png'}
        },
        {'insert': '\n'},
        imageEmbedOp('aaaaaaaa11'),
        {'insert': '\n'},
      ]);
      expect(imageIdsInDelta(delta), {'aaaaaaaa11', 'bbbbbbbb22'});
      expect(imageIdsInDelta('не json'), isEmpty);
      expect(imageIdsInDelta('{"a":1}'), isEmpty);
    });

    test('вставка — отдельной строкой, как разделитель', () {
      final doc = [
        {'insert': 'первая строка\nвторая\n'}
      ];
      // середина первой строки — строка делится
      final mid = blockEmbedInsertOps(doc, 6, imageEmbedOp('cccccccc33'));
      final d = Document.fromJson(doc)..compose(Delta.fromJson(mid.ops),
          ChangeSource.local);
      final ops = d.toDelta().toJson();
      expect(ops.where((o) => o['insert'] is Map).length, 1);
      expect(d.toPlainText(), 'первая\n￼\n строка\nвторая\n');
      expect(mid.caret, 9);
      // пустой документ
      final empty = blockEmbedInsertOps([
        {'insert': '\n'}
      ], 0, imageEmbedOp('cccccccc33'));
      expect(empty.ops.first, imageEmbedOp('cccccccc33'));
    });
  });

  group('размер и формат', () {
    test('подходящая картинка', () {
      expect(encodedImageProblem(_img()), isNull);
    });

    test('неподходящие', () {
      expect(encodedImageProblem(_img(mime: 'image/gif')), isNotNull);
      expect(encodedImageProblem(_img(w: 0)), isNotNull);
      expect(encodedImageProblem(_img(h: kImageMaxStoredSide + 1)), isNotNull);
      final big = EncodedImage(
          bytes: Uint8List(kMaxImageDataLength), // base64 длиннее предела
          mime: 'image/webp',
          width: 100,
          height: 100);
      expect(encodedImageProblem(big), contains('слишком большая'));
      expect(
          encodedImageProblem(EncodedImage(
              bytes: Uint8List(0), mime: 'image/png', width: 1, height: 1)),
          isNotNull);
    });

    test('длина в base64 считается верно', () {
      for (final n in [1, 2, 3, 4, 100, 675000]) {
        final img = EncodedImage(
            bytes: Uint8List(n), mime: 'image/png', width: 1, height: 1);
        expect(img.dataLength, base64Encode(Uint8List(n)).length);
      }
      // предел правил: с остальными полями документ < 1 МиБ
      expect(kMaxImageDataLength + 200, lessThan(1024 * 1024));
    });

    test('документ ↔ картинка', () {
      final f = imageDocFields(_img());
      expect(f.keys.toSet(), {'data', 'mime', 'width', 'height', 'createdAt'});
      final back = imageFromDoc({...f}..remove('createdAt'));
      expect(back!.bytes, _png);
      expect(back.mime, 'image/png');
      expect(imageFromDoc(null), isNull);
      expect(imageFromDoc({'data': 1}), isNull);
      expect(
          imageFromDoc({'data': '%%%', 'mime': 'image/png', 'width': 1, 'height': 1}),
          isNull);
      expect(
          imageFromDoc({
            'data': base64Encode(_png),
            'mime': 'text/html',
            'width': 1,
            'height': 1
          }),
          isNull);
    });
  });

  group('показ в редакторе', () {
    testWidgets('загружена — картинка, по щелчку — во весь экран', (t) async {
      final src =
          _FakeSource(LoadedImage(ImageLoadState.ok, _img(w: 300, h: 200)));
      await _pumpEditor(t, 'img:dddddddd44', src);
      expect(src.asked, ['dddddddd44']);
      expect(find.byType(Image), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.byType(Image));
      await t.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await t.tap(find.byTooltip('Закрыть'));
      await t.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
    });

    testWidgets('нет в базе — заглушка, не падает', (t) async {
      await _pumpEditor(t, 'img:eeeeeeee55',
          _FakeSource(const LoadedImage(ImageLoadState.missing)));
      expect(find.text('Картинка недоступна'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('нет связи — подсказка', (t) async {
      await _pumpEditor(t, 'img:ffffffff66',
          _FakeSource(const LoadedImage(ImageLoadState.offline)));
      expect(find.text('Картинка появится, когда будет связь'), findsOneWidget);
    });

    testWidgets('чужой адрес не загружается', (t) async {
      final src = _FakeSource(LoadedImage(ImageLoadState.ok, _img()));
      await _pumpEditor(t, 'https://example.com/tracker.png', src);
      expect(src.asked, isEmpty);
      expect(find.text('Картинка недоступна'), findsOneWidget);
    });

    testWidgets('редактор без картинок (шаблоны) — заглушка', (t) async {
      await _pumpEditor(t, 'img:gggggggg77', null);
      expect(find.text('Картинка недоступна'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('в тексте заметки картинки нет', (t) async {
      final d = Document.fromJson([
        {'insert': 'a\n'},
        imageEmbedOp('hhhhhhhh88'),
        {'insert': '\nb\n'},
      ]);
      expect(d.toPlainText().replaceAll('￼', ''), 'a\n\nb\n');
    });
  });

  group('резервная копия', () {
    final today = DateTime(2026, 11, 12);
    BackupNote noteWith(String date, String id) => BackupNote(
          date: date,
          delta: jsonEncode([
            {'insert': 'x\n'},
            imageEmbedOp(id),
            {'insert': '\n'},
          ]),
          text: 'x\n\n',
          accent: '#FFD54A',
        );

    test('картинки из заметок и тем', () {
      final topic = BackupTopic(
          id: 'topic1',
          title: 'Т',
          delta: jsonEncode([imageEmbedOp('tttttttt99'), {'insert': '\n'}]),
          text: '\n',
          order: 0);
      expect(
          imageIdsForBackup(
              [noteWith('2026-11-01', 'nnnnnnnn11')], [topic]),
          {'nnnnnnnn11', 'tttttttt99'});
    });

    test('запись и чтение копии с картинками', () {
      final json = encodeBackup([noteWith('2026-11-01', 'nnnnnnnn11')],
          today: today,
          createdAtUtc: DateTime.utc(2026, 11, 12),
          images: [_bimg('nnnnnnnn11')]);
      final data = parseBackup(json, today: today);
      expect(data.images.single.id, 'nnnnnnnn11');
      expect(base64Decode(data.images.single.data), _png);
      expect(jsonDecode(json)['version'], 4);
    });

    test('копия без картинок — раздела нет', () {
      final json = encodeBackup([noteWith('2026-11-01', 'nnnnnnnn11')],
          today: today, createdAtUtc: DateTime.utc(2026, 11, 12));
      expect((jsonDecode(json) as Map).containsKey('images'), isFalse);
      expect(parseBackup(json, today: today).images, isEmpty);
    });

    String withImages(Object images, {int version = 4}) {
      final m = jsonDecode(encodeBackup([],
          today: today, createdAtUtc: DateTime.utc(2026, 11, 12))) as Map;
      m['version'] = version;
      m['images'] = images;
      return jsonEncode(m);
    }

    for (final (label, bad) in [
      ('неверный id', {..._bimg('x').toJson()}),
      ('формат', {..._bimg('iiiiiiii00').toJson(), 'mime': 'image/gif'}),
      ('ширина', {..._bimg('iiiiiiii00').toJson(), 'width': 0}),
      ('высота', {..._bimg('iiiiiiii00').toJson(), 'height': 5000}),
      ('испорчен base64', {..._bimg('iiiiiiii00').toJson(), 'data': '%%%'}),
      ('пустая', {..._bimg('iiiiiiii00').toJson(), 'data': ''}),
      ('лишнее поле', {..._bimg('iiiiiiii00').toJson(), 'url': 'x'}),
      ('слишком большая',
          {..._bimg('iiiiiiii00').toJson(), 'data': 'A' * (kMaxImageDataLength + 4)}),
    ]) {
      test('отказ: $label', () {
        expect(() => parseBackup(withImages([bad]), today: today),
            throwsA(isA<BackupException>()));
      });
    }

    test('отказ: повтор и картинки в старой версии файла', () {
      final one = _bimg('iiiiiiii00').toJson();
      expect(() => parseBackup(withImages([one, one]), today: today),
          throwsA(isA<BackupException>()));
      expect(() => parseBackup(withImages([one], version: 3), today: today),
          throwsA(isA<BackupException>()));
    });

    test('картинка из базы для копии', () {
      final f = imageDocFields(_img())..remove('createdAt');
      expect(imageForBackup('jjjjjjjj11', f)!.mime, 'image/png');
      expect(imageForBackup('x', f), isNull);
      expect(imageForBackup('jjjjjjjj11', null), isNull);
      expect(imageForBackup('jjjjjjjj11', {...f, 'data': '%%'}), isNull);
    });
  });

  group('восстановление картинок', () {
    test('есть — не трогаются, нет — создаются', () async {
      final store = _FakeRestore({'aaaaaaaa11'});
      final n = await restoreImages(
          store, [_bimg('aaaaaaaa11'), _bimg('bbbbbbbb22')]);
      expect(n, 1);
      expect(store.batches, [
        ['bbbbbbbb22']
      ]);
    });

    test('пакеты в пределах объёма', () async {
      final store = _FakeRestore({});
      final big = 'A' * 880000; // ~0,9 МБ каждая
      final list = [
        for (var i = 0; i < 10; i++)
          BackupImage(
              id: 'kkkkkkkk$i' '0',
              mime: 'image/png',
              width: 1,
              height: 1,
              data: big),
      ];
      final n = await restoreImages(store, list);
      expect(n, 10);
      expect(store.batches.length, greaterThan(1));
      for (final b in store.batches) {
        expect(b.length * 880000, lessThanOrEqualTo(kMaxBatchBytes));
      }
    });

    test('пусто — ничего не делается', () async {
      final store = _FakeRestore({});
      expect(await restoreImages(store, const []), 0);
      expect(store.batches, isEmpty);
    });
  });
}
