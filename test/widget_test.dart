import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calendar_notes/main.dart';

void main() {
  group('authErrorMessage', () {
    test('неверные данные — одно общее сообщение', () {
      for (final code in [
        'invalid-credential',
        'wrong-password',
        'user-not-found',
        'INVALID_LOGIN_CREDENTIALS',
      ]) {
        expect(authErrorMessage(code), 'Неверный email или пароль');
      }
    });

    test('остальные коды', () {
      expect(authErrorMessage('invalid-email'), 'Некорректный формат email');
      expect(authErrorMessage('network-request-failed'), contains('интернет'));
      expect(authErrorMessage('too-many-requests'), contains('Слишком много'));
      expect(authErrorMessage('something-else'), contains('Попробуйте ещё раз'));
    });
  });

  group('LoginPage', () {
    Future<void> pump(WidgetTester tester) =>
        tester.pumpWidget(const MaterialApp(home: LoginPage()));

    testWidgets('есть поля, вход, сброс пароля и нет регистрации',
        (tester) async {
      await pump(tester);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Пароль'), findsOneWidget);
      expect(find.text('Войти'), findsOneWidget);
      expect(find.text('Забыли пароль?'), findsOneWidget);
      expect(find.textContaining('Регистрац'), findsNothing);
    });

    testWidgets('пароль можно показать и скрыть', (tester) async {
      await pump(tester);
      bool obscured() => tester
          .widget<EditableText>(find.descendant(
              of: find.widgetWithText(TextField, 'Пароль'),
              matching: find.byType(EditableText)))
          .obscureText;

      expect(obscured(), isTrue);
      await tester.tap(find.byTooltip('Показать пароль'));
      await tester.pump();
      expect(obscured(), isFalse);
      await tester.tap(find.byTooltip('Скрыть пароль'));
      await tester.pump();
      expect(obscured(), isTrue);
    });

    testWidgets('пустые поля — подсказка без запроса к Firebase',
        (tester) async {
      await pump(tester);
      await tester.tap(find.text('Войти'));
      await tester.pump();
      expect(find.text('Введите email'), findsOneWidget);

      await tester.enterText(
          find.widgetWithText(TextField, 'Email'), 'me@example.com');
      await tester.tap(find.text('Войти'));
      await tester.pump();
      expect(find.text('Введите пароль'), findsOneWidget);
    });

    testWidgets('сброс пароля без email просит ввести адрес', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Забыли пароль?'));
      await tester.pump();
      expect(find.textContaining('Введите email, на который'), findsOneWidget);
    });
  });
}
