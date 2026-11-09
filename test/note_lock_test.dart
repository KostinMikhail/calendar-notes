// Ввод в редактор, пока выбранная заметка не загружена (аудит, F1):
// ввод закрыт (readOnly), а при ошибке загрузки вместо старого текста —
// плашка с «Повторить».
import 'package:calendar_notes/main.dart' show NoteLoadError, loadErrorText;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

/// Как центр приложения: один редактор, ввод открывается/закрывается
/// флагом контроллера (QuillEditor читает его при сборке)
class _Harness extends StatefulWidget {
  const _Harness({required this.controller});
  final QuillController controller;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final focus = FocusNode();
  final scroll = ScrollController();

  void setLocked(bool locked) =>
      setState(() => widget.controller.readOnly = locked);

  @override
  void dispose() {
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: Scaffold(
          body: IgnorePointer(
            ignoring: widget.controller.readOnly,
            child: QuillEditor(
              controller: widget.controller,
              focusNode: focus,
              scrollController: scroll,
              config: const QuillEditorConfig(expands: true),
            ),
          ),
        ),
      );
}

void main() {
  group('ввод закрыт, пока заметка не загружена', () {
    testWidgets('закрыт — набранное не попадает в документ; открыли — '
        'попадает', (tester) async {
      final c = QuillController.basic();
      c.document = Document()..insert(0, 'Старый день');
      c.readOnly = true;
      await tester.pumpWidget(_Harness(controller: c));
      final h = tester.state<_HarnessState>(find.byType(_Harness));

      // фокус остался в редакторе (как после щелчка по другому дню)
      h.focus.requestFocus();
      await tester.pump();
      // клавиатура до редактора не доходит: соединения ввода нет
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(c.document.toPlainText(), 'Старый день\n');

      // загрузилась новая заметка — ввод открыт
      c.document = Document()..insert(0, 'Новый день');
      h.setLocked(false);
      await tester.pump();
      h.focus.requestFocus();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      c.updateSelection(
          const TextSelection.collapsed(offset: 10), ChangeSource.local);
      await tester.pump();
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'Новый день!\n',
        selection: TextSelection.collapsed(offset: 11),
      ));
      await tester.pump();
      expect(c.document.toPlainText(), 'Новый день!\n');
    });

    testWidgets('закрыт — щелчок не ставит курсор', (tester) async {
      final c = QuillController.basic();
      c.document = Document()..insert(0, 'Старый день');
      c.readOnly = true;
      await tester.pumpWidget(_Harness(controller: c));
      final h = tester.state<_HarnessState>(find.byType(_Harness));
      await tester.tap(find.byType(QuillEditor), warnIfMissed: false);
      await tester.pump();
      expect(h.focus.hasFocus, isFalse);
    });

    testWidgets('программная подмена документа при закрытом вводе работает',
        (tester) async {
      final c = QuillController.basic();
      c.readOnly = true;
      await tester.pumpWidget(_Harness(controller: c));
      // загрузка ставит документ до открытия ввода
      c.document = Document()..insert(0, 'Загружено');
      c.replaceText(0, 0, '> ', const TextSelection.collapsed(offset: 2));
      await tester.pump();
      expect(c.document.toPlainText(), '> Загружено\n');
    });
  });

  group('плашка «не удалось загрузить»', () {
    test('понятный текст по коду ошибки', () {
      expect(loadErrorText('permission-denied'), contains('Нет доступа'));
      expect(loadErrorText('unavailable'), contains('Нет связи'));
      expect(loadErrorText('deadline-exceeded'), contains('Нет связи'));
      expect(loadErrorText('internal'), contains('(internal)'));
      expect(loadErrorText(null), 'Не удалось загрузить заметку.');
    });

    testWidgets('текст, подсказка и «Повторить»', (tester) async {
      var retries = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 300,
            child: NoteLoadError(
              message: loadErrorText('unavailable'),
              onRetry: () => retries++,
            ),
          ),
        ),
      ));
      expect(find.textContaining('Нет связи'), findsOneWidget);
      expect(find.text('Пробуем снова автоматически.'), findsOneWidget);
      await tester.tap(find.text('Повторить'));
      expect(retries, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('узкое место — без переполнения', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 220,
            child: NoteLoadError(
                message: loadErrorText('permission-denied'), onRetry: () {}),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
    });
  });
}
