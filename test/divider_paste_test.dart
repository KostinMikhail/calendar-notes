// Тесты обращаются к буферу обмена Quill так же, как редактор в вебе.
// ignore_for_file: experimental_member_use, invalid_use_of_internal_member

import 'package:calendar_notes/dividers.dart';
import 'package:calendar_notes/main.dart' show DividerEmbedBuilder;
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/internal.dart'
    show ClipboardService, ClipboardServiceProvider;
import 'package:flutter_test/flutter_test.dart';

// ------------------------------------------------------------
//  Буфер обмена в тестах: setData / getData через канал платформы
// ------------------------------------------------------------

String? clipboardText;

void mockClipboard() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    switch (call.method) {
      case 'Clipboard.setData':
        clipboardText = (call.arguments as Map)['text'] as String?;
        return null;
      case 'Clipboard.getData':
        return clipboardText == null ? null : {'text': clipboardText};
      case 'Clipboard.hasStrings':
        return {'value': clipboardText != null && clipboardText!.isNotEmpty};
    }
    return null;
  });
}

/// Как в браузере: HTML/Markdown/картинок из буфера Quill не получает
/// (DefaultClipboardService в вебе отдаёт null), остаётся только текст
class WebLikeClipboard extends ClipboardService {
  @override
  Future<String?> getHtmlText() async => null;
  @override
  Future<String?> getHtmlFile() async => null;
  @override
  Future<String?> getMarkdownFile() async => null;
  @override
  Future<Uint8List?> getImageFile() async => null;
  @override
  Future<Uint8List?> getGifFile() async => null;
  @override
  Future<void> copyImage(Uint8List imageBytes) async {}
}

const divider = {'insert': {'divider': 'hr'}};

Map<String, dynamic> nl([Map<String, dynamic>? attrs]) =>
    {'insert': '\n', 'attributes': ?attrs};

const ol = {'list': 'ordered'};
const ul = {'list': 'bullet'};

/// Источник: встреча — три пункта, разделитель, пункт
List<Map<String, dynamic>> sourceOps() => [
      {'insert': 'Встреча'},
      nl(),
      {'insert': 'первое'},
      nl(ol),
      {'insert': 'второе'},
      nl(ol),
      {'insert': 'третье'},
      nl(ol),
      divider,
      nl(),
      {'insert': 'после'},
      nl(ol),
    ];

QuillController controllerWith(List<Map<String, dynamic>> ops) {
  final c = QuillController(
    config: kEditorControllerConfig,
    document: Document.fromJson(ops),
    selection: const TextSelection.collapsed(offset: 0),
  );
  // как в редакторе: разделитель знает свой вид в буфере обмена
  c.document.embedBuilders = const [DividerEmbedBuilder()];
  // как в редакторе: инвариант «строка разделителя без оформления строки»
  // (тот же вызов, что в редакторе: без шага в истории Ctrl+Z)
  c.document.changes.listen((_) => fixDividerLines(c));
  return c;
}

/// Копирует [start, end) так же, как Ctrl+C в редакторе
void copy(QuillController c, int start, int end) {
  c.updateSelection(
      TextSelection(baseOffset: start, extentOffset: end), ChangeSource.local);
  c.clipboardSelection(true);
}

/// Вставляет в позицию [at] так же, как Ctrl+V (тот же метод Quill)
Future<void> paste(QuillController c, int at) async {
  c.updateSelection(TextSelection.collapsed(offset: at), ChangeSource.local);
  await c.clipboardPaste();
  await Future<void>.delayed(Duration.zero); // слушатель изменений
}

/// Строки документа: (текст строки, атрибуты строки)
List<(String, Map<String, dynamic>)> lines(QuillController c) {
  final out = <(String, Map<String, dynamic>)>[];
  final buf = StringBuffer();
  for (final op in c.document.toDelta().toJson()) {
    final ins = op['insert'];
    final attrs = (op['attributes'] as Map?)?.cast<String, dynamic>() ?? {};
    if (ins is Map) {
      buf.write('<hr>');
      continue;
    }
    final s = ins as String;
    final parts = s.split('\n');
    for (var i = 0; i < parts.length; i++) {
      buf.write(parts[i]);
      if (i < parts.length - 1) {
        out.add((buf.toString(), attrs));
        buf.clear();
      }
    }
  }
  return out;
}

/// Нет ни строки, где разделитель с оформлением или рядом с текстом;
/// нет символа-заглушки U+FFFC в тексте
void expectHealthy(QuillController c) {
  for (final (text, attrs) in lines(c)) {
    if (text.contains('<hr>')) {
      expect(text, '<hr>', reason: 'разделитель — отдельной строкой');
      expect(attrs, isEmpty, reason: 'у строки разделителя нет оформления');
    }
    expect(text.contains('￼'), isFalse,
        reason: 'в тексте нет символа-заглушки: "$text"');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    ClipboardServiceProvider.setInstance(WebLikeClipboard());
    mockClipboard();
    clipboardText = null;
  });

  // Копируем «первое…третье + разделитель» (до начала строки «после»)
  const copyStart = 8; // начало «первое»
  int copyEnd(QuillController src) =>
      src.document.toPlainText().indexOf('после');

  group('воспроизведение: вставка разделителя в список', () {
    test('буфер — из этой же вкладки (внутренняя вставка)', () async {
      final src = controllerWith(sourceOps());
      copy(src, copyStart, copyEnd(src));
      final dst = controllerWith([
        {'insert': 'пункт'},
        nl(ol),
      ]);
      await paste(dst, 5); // конец «пункт»
      expectHealthy(dst);
      expect(lines(dst).where((l) => l.$1 == '<hr>').length, 1);
    });

    test('буфер — из другой вкладки / после перезагрузки (обычный текст)',
        () async {
      final src = controllerWith(sourceOps());
      copy(src, copyStart, copyEnd(src));
      // как будто вставляем в другой вкладке: запомненного копирования нет,
      // в буфере только текст
      final text = clipboardText!;
      // копирование без выделения сбрасывает запомненное (как новая вкладка)
      copy(controllerWith([nl()]), 0, 0);
      clipboardText = text;
      final dst = controllerWith([
        {'insert': 'пункт'},
        nl(ol),
      ]);
      await paste(dst, 5);
      expectHealthy(dst);
    });

    test('текст для буфера — без символа-заглушки', () {
      final src = controllerWith(sourceOps());
      copy(src, copyStart, copyEnd(src));
      expect(clipboardText, isNotNull);
      expect(clipboardText!.contains('￼'), isFalse);
      expect(clipboardText, contains('третье'));
    });
  });

  group('вставка в разные места', () {
    Future<QuillController> pasteInto(
        List<Map<String, dynamic>> dst, int at, {bool plain = false}) async {
      final src = controllerWith(sourceOps());
      copy(src, copyStart, copyEnd(src));
      if (plain) {
        final text = clipboardText!;
        copy(controllerWith([nl()]), 0, 0);
        clipboardText = text;
      }
      final c = controllerWith(dst);
      await paste(c, at);
      return c;
    }

    final cases = <String, (List<Map<String, dynamic>>, int)>{
      'маркированный список': ([{'insert': 'пункт'}, nl(ul)], 5),
      'нумерованный список': ([{'insert': 'пункт'}, nl(ol)], 5),
      'вложенный список (a./i.)': (
        [
          {'insert': 'верх'},
          nl(ol),
          {'insert': 'вложенный'},
          nl({'list': 'ordered', 'indent': 2}),
        ],
        14
      ),
      'обычная строка': ([{'insert': 'текст'}, nl()], 5),
      'задача': (
        [
          {'insert': 'дело'},
          nl({'list': 'ordered', 'task': 'open'}),
        ],
        4
      ),
      'начало документа': ([{'insert': 'пункт'}, nl(ol)], 0),
      'конец документа (пустая строка)': (
        [{'insert': 'пункт'}, nl(ol), nl()],
        6
      ),
    };

    for (final e in cases.entries) {
      test('${e.key}: разделитель остаётся разделителем', () async {
        final c = await pasteInto(e.value.$1, e.value.$2);
        expectHealthy(c);
        final ls = lines(c);
        expect(ls.where((l) => l.$1 == '<hr>').length, 1);
        // вставленные пункты — пункты списка
        final second = ls.firstWhere((l) => l.$1 == 'второе');
        expect(second.$2['list'], 'ordered');
      });

      test('${e.key}: текст из другой вкладки — без символа и без пункта-'
          'заглушки', () async {
        final c = await pasteInto(e.value.$1, e.value.$2, plain: true);
        expectHealthy(c);
        expect(c.document.toPlainText(), contains('второе'));
      });
    }

    test('несколько разделителей за раз', () async {
      final src = controllerWith([
        {'insert': 'а'},
        nl(ol),
        divider,
        nl(),
        {'insert': 'б'},
        nl(ol),
        divider,
        nl(),
        divider,
        nl(),
        {'insert': 'в'},
        nl(ol),
      ]);
      copy(src, 0, src.document.length - 1);
      final c = controllerWith([
        {'insert': 'пункт'},
        nl(ol),
      ]);
      await paste(c, 5);
      expectHealthy(c);
      expect(lines(c).where((l) => l.$1 == '<hr>').length, 3);
    });

    test('испорченный разделитель в источнике — после вставки исправлен',
        () async {
      final src = controllerWith([
        {'insert': 'а'},
        nl(ol),
        divider,
        nl({'list': 'ordered', 'indent': 1}),
        {'insert': 'б'},
        nl(ol),
      ]);
      // испорченную строку в исходный документ кладём минуя исправление
      expect(lines(src).any((l) => l.$1 == '<hr>' && l.$2.isNotEmpty), isTrue);
      copy(src, 0, src.document.length - 1);
      final c = controllerWith([
        {'insert': 'x'},
        nl(ol),
      ]);
      await paste(c, 1);
      expectHealthy(c);
    });

    test('Ctrl+Z отменяет вставку одним шагом', () async {
      final dstOps = [
        {'insert': 'пункт'},
        nl(ol),
      ];
      final c = await pasteInto(dstOps, 5);
      expect(lines(c).length, greaterThan(1));
      c.undo();
      await Future<void>.delayed(Duration.zero);
      expect(c.document.toDelta().toJson(),
          Document.fromJson(dstOps).toDelta().toJson());
    });

    test('переводы строк Windows (\r\n) — своё копирование узнаётся',
        () async {
      final src = controllerWith(sourceOps());
      copy(src, copyStart, copyEnd(src));
      clipboardText = clipboardText!.replaceAll('\n', '\r\n');
      final c = controllerWith([
        {'insert': 'пункт'},
        nl(ol),
      ]);
      await paste(c, 5);
      expectHealthy(c);
      expect(lines(c).where((l) => l.$1 == '<hr>').length, 1);
      expect(c.document.toPlainText().contains('\r'), isFalse);
    });

    test('обычный текст снаружи с U+FFFC — символ выбрасывается', () async {
      clipboardText = 'внешний￼текст';
      final c = controllerWith([
        {'insert': 'x'},
        nl(),
      ]);
      await paste(c, 1);
      expect(c.document.toPlainText(), 'xвнешнийтекст\n');
    });

    test('обычная вставка текста не меняется', () async {
      clipboardText = 'просто текст';
      final c = controllerWith([
        {'insert': 'ab'},
        nl(ol),
      ]);
      await paste(c, 1);
      final ls = lines(c);
      expect(ls.length, 1);
      expect(ls.single.$1, 'aпросто текстb');
      expect(ls.single.$2, ol);
    });
  });
}
