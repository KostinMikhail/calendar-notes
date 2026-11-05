import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:url_launcher/url_launcher.dart';

import 'backup.dart';
import 'firebase_options.dart';
import 'search.dart' show findInText, kObjectReplacement;
import 'search_dialog.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Firebase запускается уже под экраном загрузки (см. AuthGate)
  runApp(const MyApp());
}

/// Запуск Firebase и настройка сессии входа
Future<void> _initFirebase() async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  if (kIsWeb) {
    // Веб: сессия хранится в localStorage и переживает перезагрузку
    // страницы и закрытие браузера. На Android/iOS Firebase сам хранит
    // сессию между запусками.
    await FirebaseAuth.instance.setPersistence(Persistence.LOCAL);
  }
}

// ============================================================
//  Палитра
// ============================================================
const Color kBackground = Color(0xFF0E0D13);
const Color kSurface = Color(0xFF15141C);
const Color kCard = Color(0xFF1C1A25);
const Color kAccent = Color(0xFF9C8FCB);
const Color kAccentLight = Color(0xFFC9BCE6);
const Color kTextPrimary = Color(0xFFECEAF2);
const Color kTextSecondary = Color(0xFF8D8A9C);
const Color kDivider = Color(0xFF292734);

// Цвета текста (кнопки в панели форматирования)
const String kRed = '#FF5C5C';
const String kYellow = '#FFD54A';
const String kGreen = '#4CD97B';

// Случайный цвет для списка «Не забыть»: жёлтый, фиолетовый, синий, оранжевый, розовый
const List<String> kNotForgetColors = [
  '#FFD54A',
  '#B388FF',
  '#5AB0FF',
  '#FF9F43',
  '#FF7EB6',
];

// ============================================================
//  Русские названия
// ============================================================
const List<String> kMonthsNom = [
  'Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь',
  'Июль', 'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь'
];
const List<String> kMonthsShort = [
  'Янв', 'Фев', 'Мар', 'Апр', 'Май', 'Июн',
  'Июл', 'Авг', 'Сен', 'Окт', 'Ноя', 'Дек'
];
const List<String> kWeekdaysShort = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

// Границы календаря (их же проверяет поиск)
final DateTime kCalendarFirstDay = DateTime(2020);
final DateTime kCalendarLastDay = DateTime(2030, 12, 31);

// ============================================================
//  Праздники РФ (нерабочие будние дни, с учётом переносов)
//  Формат 'ММ-ДД'. Для лет, которых нет в таблице, применяется
//  простое правило (см. _holidaysOf).
// ============================================================
const Map<int, Set<String>> kOfficialDaysOff = {
  // Постановление Правительства РФ от 24.09.2025 № 1466
  2026: {
    '01-01', '01-02', '01-05', '01-06', '01-07', '01-08', '01-09',
    '02-23',
    '03-09',
    '05-01', '05-11',
    '06-12',
    '11-04',
    '12-31',
  },
  // Постановление Правительства РФ от 17.09.2026 № 1187
  2027: {
    '01-01', '01-04', '01-05', '01-06', '01-07', '01-08',
    '02-22', '02-23',
    '03-08',
    '05-03', '05-10',
    '06-14',
    '11-04', '11-05',
    '12-31',
  },
};

final Map<int, Set<String>> _holidayCache = {};

String _md(DateTime d) =>
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Set<String> _holidaysOf(int year) {
  final table = kOfficialDaysOff[year];
  if (table != null) return table;
  return _holidayCache.putIfAbsent(year, () {
    final fixed = <DateTime>[
      for (var d = 1; d <= 8; d++) DateTime(year, 1, d),
      DateTime(year, 2, 23),
      DateTime(year, 3, 8),
      DateTime(year, 5, 1),
      DateTime(year, 5, 9),
      DateTime(year, 6, 12),
      DateTime(year, 11, 4),
    ];
    final fixedKeys = fixed.map(_md).toSet();
    final result = <String>{};
    for (final d in fixed) {
      var x = d;
      if (x.weekday >= 6) {
        // праздник выпал на выходной — переносится на ближайший рабочий день
        do {
          x = DateTime(x.year, x.month, x.day + 1);
        } while (x.weekday >= 6 || fixedKeys.contains(_md(x)));
      }
      result.add(_md(x));
    }
    return result;
  });
}

bool _isHoliday(DateTime d) => _holidaysOf(d.year).contains(_md(d));
bool _isWorkday(DateTime d) => d.weekday <= 5 && !_isHoliday(d);

/// Первый рабочий день месяца
bool _isFirstWorkdayOfMonth(DateTime d) {
  if (!_isWorkday(d)) return false;
  for (var i = 1; i < d.day; i++) {
    if (_isWorkday(DateTime(d.year, d.month, i))) return false;
  }
  return true;
}

/// Рабочий день, после которого начинается период с государственным праздником
bool _isDayBeforeHoliday(DateTime d) {
  if (!_isWorkday(d)) return false;
  var n = DateTime(d.year, d.month, d.day + 1);
  var guard = 0;
  while (!_isWorkday(n) && guard < 20) {
    if (_isHoliday(n)) return true;
    n = DateTime(n.year, n.month, n.day + 1);
    guard++;
  }
  return false;
}

/// Каждый второй четверг, начиная с 05.11.2026 — «Вадим викли»
bool _isVadimWeek(DateTime d) {
  if (d.weekday != DateTime.thursday) return false;
  final diff = DateTime.utc(d.year, d.month, d.day)
      .difference(DateTime.utc(2026, 11, 5))
      .inDays;
  return diff >= 0 && diff % 14 == 0;
}

// ============================================================
//  Шаблон заметки на день
// ============================================================
const String kNotForgetTitle = 'Не забыть:';
const String kMonthlyReport = 'Отчёт по команде СДК';
const String kHolidayNote = 'завтра выходной, не забудь всем рассказать';

/// Разделитель между блоками шаблона: тонкая плашка на всю ширину редактора
class DividerEmbedBuilder extends EmbedBuilder {
  const DividerEmbedBuilder();

  @override
  String get key => 'divider';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      child: Container(
        height: 2,
        margin: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF34313F),
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}

/// Верхняя строка меню ссылки: адрес; клик копирует его в буфер обмена
/// и рядом на секунду показывает плашку «Скопировано». Меню не закрывается.
class _CopyUrlEntry extends PopupMenuEntry<String> {
  const _CopyUrlEntry(this.url);
  final String url;

  @override
  double get height => 36;

  @override
  bool represents(String? value) => false;

  @override
  State<_CopyUrlEntry> createState() => _CopyUrlEntryState();
}

class _CopyUrlEntryState extends State<_CopyUrlEntry> {
  bool _copied = false;
  Timer? _hide;

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.url));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _copied = true);
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Нажмите, чтобы скопировать',
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: _copy,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    widget.url,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF5AB0FF),
                      fontSize: 13,
                      decoration: TextDecoration.underline,
                      decorationColor: Color(0xFF5AB0FF),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedOpacity(
                  opacity: _copied ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: kAccent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'Скопировано',
                      style: TextStyle(
                        color: kBackground,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Sect {
  final String title;
  final List<String> items; // '' — пустой пункт
  _Sect(this.title, this.items);
}

List<_Sect> _sectionsFor(DateTime day) {
  const retro = 'вернёмся к action items с ретры последней ретры';
  const mts = 'Новые автоответчики от МТС?';

  switch (day.weekday) {
    case DateTime.monday:
      return [
        _Sect('Задачи на день:', ['']),
        _Sect('АИ дейли:', [mts, retro, '']),
        _Sect('СДК дейли:', ['']),
        _Sect('Девопс дейли:', ['']),
        _Sect('Фронт викли:', ['Вова ревью', retro]),
        _Sect(kNotForgetTitle, ['']),
      ];
    case DateTime.tuesday:
      return [
        _Sect('Задачи на день:', ['подготовиться к завтрашнему сайт викли', '']),
        _Sect('АИ дейли:', [mts, '']),
        _Sect('СДК дейли:', ['']),
        _Sect('Девопс дейли:', ['']),
        _Sect('Ксюша викли:', ['']),
        _Sect(kNotForgetTitle, ['']),
      ];
    case DateTime.wednesday:
      return [
        _Sect('Задачи на день:', ['']),
        _Sect('АИ дейли:', [mts, '']),
        _Sect('СДК дейли:', ['']),
        _Sect('Девопс дейли:', ['']),
        _Sect('Фронт дейли:', ['']),
        _Sect('Юля викли:', ['']),
        _Sect('Сайт викли:', ['']),
        _Sect(kNotForgetTitle, ['']),
      ];
    case DateTime.thursday:
      return [
        _Sect('Задачи на день:', ['']),
        _Sect('АИ дейли:', [mts, '']),
        _Sect('СДК дейли:', ['']),
        _Sect('Девопс дейли:', ['']),
        _Sect('Фронт дейли:', ['']),
        _Sect('Лиза викли:', ['']),
        _Sect(kNotForgetTitle, ['вечером в 16 кофе', '']),
      ];
    case DateTime.friday:
      return [
        _Sect('Задачи на день:', ['ОТЧЁТ ПО САЙТУ', '']),
        _Sect('АИ дейли:', [mts, '']),
        _Sect('СДК дейли:', ['']),
        _Sect('Девопс дейли:', ['']),
        _Sect('Фронт дейли:', ['']),
        _Sect('Сайт викли:', ['']),
        _Sect(kNotForgetTitle, ['']),
      ];
    default:
      return <_Sect>[]; // суббота и воскресенье — без шаблона
  }
}

String _pickAccent() =>
    kNotForgetColors[Random().nextInt(kNotForgetColors.length)];

Document _buildTemplate(DateTime day, String accent) {
  final sections = _sectionsFor(day);
  if (sections.isEmpty) return Document();

  // Каждый второй четверг — дополнительный блок «Вадим викли»
  if (_isVadimWeek(day)) {
    sections.insert(sections.length - 1, _Sect('Вадим викли:', ['']));
  }

  // Первый рабочий день месяца — отчёт по СДК в задачах на день
  if (_isFirstWorkdayOfMonth(day)) {
    final tasks = sections.first.items;
    final i = tasks.indexOf('');
    tasks.insert(i < 0 ? tasks.length : i, kMonthlyReport);
  }

  // День перед государственным праздником — напоминание в «Не забыть»
  if (_isDayBeforeHoliday(day)) {
    sections.last.items.insert(0, kHolidayNote);
  }

  final ops = <Map<String, dynamic>>[];
  for (var s = 0; s < sections.length; s++) {
    final sec = sections[s];
    final isNotForget = sec.title == kNotForgetTitle;

    // 1. Заголовок блока — обычным (не жирным) шрифтом
    ops.add({
      'insert': sec.title,
      if (isNotForget) 'attributes': {'color': accent},
    });
    ops.add({'insert': '\n'});

    for (final item in sec.items) {
      if (item.isNotEmpty) {
        ops.add({
          'insert': item,
          if (isNotForget) 'attributes': {'color': accent},
        });
      }
      ops.add({
        'insert': '\n',
        'attributes': {'list': 'ordered'},
      });
    }

    if (s != sections.length - 1) {
      ops.add({
        'insert': {'divider': 'hr'},
      });
      ops.add({'insert': '\n'});
    }
  }
  return Document.fromJson(ops);
}

/// Строки, которые шаблоны дней вставляют сами (заголовки блоков, готовые
/// пункты, отчёт, напоминание о празднике, «Вадим викли»). Поиск их
/// пропускает. Набор берётся из самих шаблонов за год вперёд — тексты
/// нигде не дублируются.
final Set<String> kTemplateLines = () {
  final lines = <String>{};
  final start = DateTime(2026, 11, 1);
  for (var i = 0; i < 366; i++) {
    final day = DateTime(start.year, start.month, start.day + i);
    final text = _buildTemplate(day, kNotForgetColors.first).toPlainText();
    for (final line in text.split('\n')) {
      final visible = line.replaceAll(kObjectReplacement, '').trim();
      if (visible.isNotEmpty) lines.add(visible);
    }
  }
  return lines;
}();

// ============================================================
//  Приложение
// ============================================================
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Calendar Notes',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ru'), Locale('en')],
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBackground,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          secondary: kAccentLight,
          surface: kSurface,
        ),
        useMaterial3: true,
        fontFamily: 'sans-serif',
      ),
      home: const AuthGate(),
    );
  }
}

// ============================================================
//  Вход
// ============================================================

/// Выбирает экран по состоянию входа: загрузка → вход → календарь.
/// Единственный источник правды — поток authStateChanges().
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  Stream<User?>? _authChanges;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await _initFirebase();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!mounted) return;
    setState(() => _authChanges = FirebaseAuth.instance.authStateChanges());
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const _Splash(
          message: 'Не удалось запустить приложение. Обновите страницу.');
    }
    final changes = _authChanges;
    if (changes == null) return const _Splash();

    return StreamBuilder<User?>(
      stream: changes,
      builder: (context, snap) {
        // пока Firebase восстанавливает сессию — только индикатор,
        // чтобы экран входа не мелькал
        if (snap.connectionState == ConnectionState.waiting) {
          return const _Splash();
        }
        final user = snap.data;
        if (user == null) return const LoginPage();
        // ключ по uid: при смене пользователя состояние создаётся заново
        return CalendarPage(key: ValueKey(user.uid), uid: user.uid);
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash({this.message});
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      body: Center(
        child: message == null
            ? const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Text(message!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: kTextSecondary)),
              ),
      ),
    );
  }
}

/// Понятный текст ошибки входа (без технических подробностей)
String authErrorMessage(String code) {
  switch (code) {
    case 'invalid-credential':
    case 'wrong-password':
    case 'user-not-found':
    case 'INVALID_LOGIN_CREDENTIALS':
      return 'Неверный email или пароль';
    case 'invalid-email':
      return 'Некорректный формат email';
    case 'missing-email':
      return 'Введите email';
    case 'missing-password':
      return 'Введите пароль';
    case 'network-request-failed':
      return 'Нет связи с сервером. Проверьте интернет и попробуйте снова';
    case 'too-many-requests':
      return 'Слишком много попыток. Подождите немного и попробуйте снова';
    case 'user-disabled':
      return 'Эта учётная запись отключена';
    case 'operation-not-allowed':
      return 'Вход по email и паролю не включён в настройках Firebase';
    default:
      return 'Не удалось выполнить действие. Попробуйте ещё раз';
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _obscure = true;
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _show({String? error, String? info}) {
    if (!mounted) return;
    setState(() {
      _error = error;
      _info = info;
    });
  }

  Future<void> _signIn() async {
    if (_busy) return; // не отправляем повторный запрос
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty) return _show(error: 'Введите email');
    if (password.isEmpty) return _show(error: 'Введите пароль');

    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: password);
      // предложить браузеру/менеджеру паролей запомнить вход
      TextInput.finishAutofillContext();
      // дальше AuthGate сам откроет календарь
    } on FirebaseAuthException catch (e) {
      _show(error: authErrorMessage(e.code));
    } catch (_) {
      _show(error: authErrorMessage(''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetPassword() async {
    if (_busy) return;
    final email = _email.text.trim();
    if (email.isEmpty) {
      return _show(error: 'Введите email, на который прислать ссылку для сброса');
    }
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    // одинаковый ответ для любого адреса — не раскрываем, есть ли такой аккаунт
    final done =
        'Если для $email есть учётная запись, на этот адрес отправлено письмо '
        'со ссылкой для сброса пароля. Проверьте также папку «Спам».';
    try {
      await FirebaseAuth.instance.setLanguageCode('ru');
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      _show(info: done);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found') {
        _show(info: done);
      } else {
        _show(error: authErrorMessage(e.code));
      }
    } catch (_) {
      _show(error: authErrorMessage(''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  InputDecoration _field(String label, {Widget? suffix}) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: kTextSecondary),
        floatingLabelStyle: const TextStyle(color: kAccent),
        filled: true,
        fillColor: kCard,
        suffixIcon: suffix,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: kDivider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: kAccent),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: kDivider),
        ),
      );

  Widget _message(String text, Color color) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 13)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: kSurface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kDivider),
                ),
                child: AutofillGroup(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.calendar_month, color: kAccent),
                          SizedBox(width: 10),
                          Text(
                            'Calendar Notes',
                            style: TextStyle(
                              color: kAccentLight,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Войдите, чтобы открыть заметки',
                        style: TextStyle(color: kTextSecondary, fontSize: 13),
                      ),
                      const SizedBox(height: 22),
                      TextField(
                        controller: _email,
                        enabled: !_busy,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                        autofillHints: const [
                          AutofillHints.email,
                          AutofillHints.username,
                        ],
                        style: const TextStyle(color: kTextPrimary),
                        decoration: _field('Email'),
                        onSubmitted: (_) => _passwordFocus.requestFocus(),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        focusNode: _passwordFocus,
                        enabled: !_busy,
                        obscureText: _obscure,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        style: const TextStyle(color: kTextPrimary),
                        decoration: _field(
                          'Пароль',
                          suffix: IconButton(
                            tooltip:
                                _obscure ? 'Показать пароль' : 'Скрыть пароль',
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              color: kTextSecondary,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                        onSubmitted: (_) => _signIn(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        _message(_error!, const Color(0xFFFF5C5C)),
                      ],
                      if (_info != null) ...[
                        const SizedBox(height: 14),
                        _message(_info!, kAccent),
                      ],
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 44,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: kAccent,
                            foregroundColor: kBackground,
                            disabledBackgroundColor:
                                kAccent.withValues(alpha: 0.5),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: _busy ? null : _signIn,
                          child: _busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: kBackground,
                                  ),
                                )
                              : const Text(
                                  'Войти',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: _busy ? null : _resetPassword,
                        style: TextButton.styleFrom(foregroundColor: kAccent),
                        child: const Text('Забыли пароль?'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
//  Календарь и заметки
// ============================================================

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key, required this.uid});

  /// uid вошедшего пользователя (из AuthGate)
  final String uid;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage>
    with WidgetsBindingObserver {
  DateTime _selectedDay = DateTime.now();
  DateTime _focusedDay = DateTime.now();

  late final QuillController _controller;
  late final FocusNode _editorFocus;
  final ScrollController _editorScroll = ScrollController();
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  bool _calendarVisible = true;
  bool _showMonths = false;
  int _pickerYear = DateTime.now().year;

  // --- состояние сохранения ---
  final ValueNotifier<String> _status = ValueNotifier<String>('');
  Timer? _autoTimer;
  String _lastSavedJson = '';
  String _lastSeenJson = '';
  int _lastLen = 0;
  String? _loadedKey; // для какого дня заметка уже загружена
  bool _saving = false;
  String _accent = kNotForgetColors.first;
  bool _recoloring = false;

  // --- разделители: курсор не должен на них попадать ---
  int? _prevCaret;
  bool _snapping = false;

  String _dayKey(DateTime day) =>
      '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  String _formatDate(DateTime day) {
    const months = [
      'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
      'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'
    ];
    return '${day.day} ${months[day.month - 1]} ${day.year}';
  }

  String _currentJson() => jsonEncode(_controller.document.toDelta().toJson());

  bool get _isDirty => _currentJson() != _lastSavedJson;

  void _setStatus(String s) {
    if (mounted) _status.value = s;
  }

  // ---------- жизненный цикл ----------

  @override
  void initState() {
    super.initState();
    _controller = QuillController.basic();
    _editorFocus = FocusNode();
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onControllerChanged);
    _loadNote(_selectedDay);
    // автосохранение каждые 5 секунд, если есть несохранённые правки
    _autoTimer = Timer.periodic(const Duration(seconds: 5), (_) => _autoSave());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    WidgetsBinding.instance.removeObserver(this);
    _autoTimer?.cancel();
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _editorFocus.dispose();
    _editorScroll.dispose();
    _status.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // вкладку свернули / переключились — сохраняем сразу
    if (state != AppLifecycleState.resumed) _autoSave();
  }

  // ---------- аккаунт и выход ----------

  bool _signingOut = false;

  /// Меню в правом верхнем углу: копия, восстановление, выход
  Widget _appMenu() {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    PopupMenuItem<String> item(String value, IconData icon, String title) =>
        PopupMenuItem<String>(
          value: value,
          height: 40,
          child: Row(
            children: [
              Icon(icon, size: 18, color: kAccent),
              const SizedBox(width: 10),
              Text(title, style: const TextStyle(color: kTextPrimary)),
            ],
          ),
        );

    return PopupMenuButton<String>(
      tooltip: _backupBusy ? 'Идёт работа с резервной копией' : 'Меню',
      enabled: !_backupBusy, // пока идёт копия/восстановление — меню закрыто
      color: kCard,
      icon: _backupBusy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.menu, color: kTextSecondary),
      onSelected: (v) {
        switch (v) {
          case 'backup':
            _createBackup();
            break;
          case 'restore':
            _restoreBackup();
            break;
          case 'logout':
            _signOut();
            break;
        }
      },
      itemBuilder: (_) => [
        if (email.isNotEmpty)
          PopupMenuItem<String>(
            enabled: false,
            height: 32,
            child: Text(email,
                style: const TextStyle(color: kTextSecondary, fontSize: 13)),
          ),
        item('backup', Icons.download_outlined, 'Создать резервную копию'),
        item('restore', Icons.upload_outlined, 'Восстановить из копии'),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'logout',
          height: 40,
          child: Row(
            children: [
              Icon(Icons.logout, size: 18, color: kTextSecondary),
              SizedBox(width: 10),
              Text('Выйти', style: TextStyle(color: kTextPrimary)),
            ],
          ),
        ),
      ],
    );
  }

  // ---------- резервная копия ----------

  bool _backupBusy = false;

  /// Дожидается текущего сохранения и сохраняет несохранённые правки.
  /// false — правки сохранить не удалось.
  Future<bool> _flushPendingSave() async {
    for (var i = 0; _saving && i < 300; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (_saving) return false;
    if (_loadedKey == _dayKey(_selectedDay) && _isDirty) {
      await _saveNote();
    }
    return !(_loadedKey == _dayKey(_selectedDay) && _isDirty);
  }

  Future<void> _showMessage(String title, String body,
      {bool error = false}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: Row(
          children: [
            Icon(error ? Icons.error_outline : Icons.check_circle_outline,
                color: error ? const Color(0xFFFF5C5C) : kAccent),
            const SizedBox(width: 10),
            Expanded(child: Text(title)),
          ],
        ),
        content: Text(body, style: const TextStyle(color: kTextPrimary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  DateTime _localToday() {
    final now = DateTime.now(); // локальная дата устройства
    return DateTime(now.year, now.month, now.day);
  }

  Future<void> _createBackup() async {
    if (_backupBusy) return;
    final notes = _notes;
    if (notes == null) return;
    setState(() => _backupBusy = true);
    try {
      if (!await _flushPendingSave()) {
        await _showMessage(
            'Копия не создана',
            'Не удалось сохранить текущую заметку, поэтому копия была бы '
                'неполной. Проверьте интернет и попробуйте снова.',
            error: true);
        return;
      }

      final today = _localToday();
      final from = backupDateKey(kBackupStart);
      final to = backupDateKey(today);
      final period = '${formatRuDate(from)} — ${formatRuDate(to)}';

      List<BackupNote> list;
      try {
        final snap = await notes
            .where(FieldPath.documentId, isGreaterThanOrEqualTo: from)
            .where(FieldPath.documentId, isLessThanOrEqualTo: to)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 60));
        list = notesForExport({for (final d in snap.docs) d.id: d.data()},
            today: today);
      } on BackupException catch (e) {
        await _showMessage('Копия не создана', e.message, error: true);
        return;
      } catch (e) {
        await _showMessage('Копия не создана',
            'Не удалось получить заметки: ${describeError(e)}.',
            error: true);
        return;
      }

      if (list.isEmpty) {
        await _showMessage('Нет заметок',
            'За период $period нет сохранённых заметок. Файл не создан.');
        return;
      }

      final name = backupFileName(today);
      final json = encodeBackup(list,
          today: today, createdAtUtc: DateTime.now().toUtc());
      Uri? saved;
      try {
        saved = await FilePicker.saveFile(
          fileName: name,
          bytes: utf8.encode(json),
          mimeType: 'application/json',
          dialogTitle: 'Сохранить резервную копию',
        );
      } catch (_) {
        await _showMessage('Копия не создана',
            'Не удалось сохранить файл. Попробуйте ещё раз.',
            error: true);
        return;
      }
      // в браузере файл просто скачивается (saved == null); на остальных
      // платформах null — пользователь закрыл окно сохранения
      if (!kIsWeb && saved == null) return;

      await _showMessage(
          'Резервная копия создана',
          'Файл: $name\n'
              'Заметок: ${list.length}\n'
              'Период: $period');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<bool> _confirmRestore(BackupData data) async {
    final created = data.createdAt.toLocal();
    final time =
        '${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('Восстановить из копии?'),
        content: SingleChildScrollView(
          child: Text(
            'Копия создана: ${formatRuDate(backupDateKey(created))}, $time\n'
            'Период: ${formatRuDate(data.from)} — ${formatRuDate(data.to)}\n'
            'Заметок в копии: ${data.notes.length}\n\n'
            'Способ: перезапись.\n'
            '• Заметки за те же даты будут заменены версиями из копии.\n'
            '• Заметки, которых нет в копии, останутся как есть.\n'
            '• Заметки вне периода копии не изменятся.\n'
            '• Шаблоны по дням недели не изменятся.',
            style: const TextStyle(color: kTextPrimary, height: 1.4),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: kAccent, foregroundColor: kBackground),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Восстановить'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _restoreBackup() async {
    if (_backupBusy) return;
    if (_notes == null) return;
    setState(() => _backupBusy = true);
    var touched = false;
    try {
      // 1. файл
      PlatformFile? file;
      try {
        file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['json'],
          dialogTitle: 'Выберите резервную копию',
        );
      } catch (_) {
        await _showMessage('Не удалось открыть файл',
            'Окно выбора файла не открылось. Попробуйте ещё раз.',
            error: true);
        return;
      }
      if (file == null) return; // отменили выбор

      String text;
      try {
        final size = await file.length();
        if (size != null && size > kMaxBackupBytes) {
          throw BackupException('Файл слишком большой для резервной копии');
        }
        text = utf8.decode(await file.readAsBytes());
      } on BackupException catch (e) {
        await _showMessage('Восстановление отменено', e.message, error: true);
        return;
      } catch (_) {
        await _showMessage('Восстановление отменено',
            'Не удалось прочитать файл: нет доступа или он не в кодировке UTF-8.',
            error: true);
        return;
      }

      // 2. полная проверка до любых изменений
      BackupData data;
      try {
        data = parseBackup(text, today: _localToday());
      } on BackupException catch (e) {
        await _showMessage('Файл не подходит',
            '${e.message}.\n\nНичего не изменено.',
            error: true);
        return;
      }
      if (data.notes.isEmpty) {
        await _showMessage('Восстанавливать нечего',
            'В резервной копии нет заметок. Ничего не изменено.');
        return;
      }

      // 3. подтверждение
      if (!mounted || !await _confirmRestore(data)) return;

      // 4. сохраняем текущие правки и больше не даём их записывать
      if (!await _flushPendingSave()) {
        await _showMessage(
            'Восстановление отменено',
            'Не удалось сохранить текущую заметку. Проверьте интернет и '
                'попробуйте снова. Ничего не изменено.',
            error: true);
        return;
      }
      final notes = _notes;
      if (notes == null || !mounted) return;
      touched = true;
      _loadedKey = null; // старое содержимое редактора больше не сохранится

      // 5. запись с прогрессом
      final progress = ValueNotifier<(int, int)>((0, data.notes.length));
      BuildContext? dialogCtx;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          dialogCtx = ctx;
          return PopScope(
            canPop: false,
            child: AlertDialog(
              backgroundColor: kSurface,
              title: const Text('Восстановление…'),
              content: ValueListenableBuilder<(int, int)>(
                valueListenable: progress,
                builder: (_, p, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(
                      value: p.$2 == 0 ? null : p.$1 / p.$2,
                      color: kAccent,
                      backgroundColor: kCard,
                    ),
                    const SizedBox(height: 12),
                    Text('Восстановлено ${p.$1} из ${p.$2}',
                        style: const TextStyle(color: kTextPrimary)),
                  ],
                ),
              ),
            ),
          );
        },
      );

      final result = await runRestore(
        FirestoreNoteStore(notes),
        data.notes,
        onProgress: (done, total) => progress.value = (done, total),
      );

      final c = dialogCtx;
      if (c != null && c.mounted) Navigator.of(c).pop();
      progress.dispose();

      if (result.ok) {
        await _showMessage('Восстановление завершено',
            'Восстановлено заметок: ${result.written} из ${result.total}.');
      } else {
        final String state;
        if (result.written == 0) {
          state = 'Ничего не изменено.';
        } else if (result.rolledBack) {
          state = 'Записанные до сбоя заметки (${result.written}) '
              'возвращены к прежнему виду.';
        } else {
          state = 'Восстановление выполнено частично: записано '
              '${result.written} из ${result.total}. Вернуть прежний вид не '
              'удалось для дат: '
              '${result.notRolledBack.map(formatRuDate).join(', ')}.';
        }
        await _showMessage('Восстановление не завершено',
            'Причина: ${result.error}.\n\n$state\n\n'
                'Можно повторить восстановление из того же файла.',
            error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _backupBusy = false);
        // показываем то, что теперь лежит в базе
        if (touched) {
          _searchCache.invalidate();
          _loadNote(_selectedDay);
        }
      }
    }
  }

  /// Выход только на этом устройстве: на других вход сохраняется.
  /// Заметки в Firestore не трогаем.
  Future<void> _signOut() async {
    if (_signingOut) return;

    // сначала сохраняем последние правки
    while (_saving) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (_loadedKey == _dayKey(_selectedDay) && _isDirty) {
      await _saveNote();
    }
    if (!mounted) return;
    if (_loadedKey == _dayKey(_selectedDay) && _isDirty) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kSurface,
          title: const Text('Изменения не сохранены'),
          content: const Text(
              'Последние правки не удалось сохранить. Выйти и потерять их?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Остаться')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Выйти')),
          ],
        ),
      );
      if (leave != true || !mounted) return;
    }

    // убираем данные пользователя из памяти, дальше никаких операций с заметками
    _signingOut = true;
    _autoTimer?.cancel();
    _loadedKey = null;
    _lastSavedJson = '';
    _lastSeenJson = '';
    _lastLen = 0;
    _controller.document = Document();
    _status.value = '';

    try {
      await FirebaseAuth.instance.signOut();
      // AuthGate покажет экран входа, эта страница будет закрыта
    } catch (_) {
      if (!mounted) return;
      _signingOut = false;
      _autoTimer =
          Timer.periodic(const Duration(seconds: 5), (_) => _autoSave());
      _loadNote(_selectedDay);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось выйти. Попробуйте ещё раз')),
      );
    }
  }

  // ---------- Firestore ----------

  /// Заметки текущего пользователя: users/{uid}/notes/{yyyy-MM-dd}.
  /// uid берётся только из Firebase Auth. Нет входа (или вошёл уже другой
  /// пользователь) — null, и операции с заметками не выполняются.
  CollectionReference<Map<String, dynamic>>? get _notes {
    final user = FirebaseAuth.instance.currentUser;
    if (_signingOut || user == null || user.uid != widget.uid) return null;
    return _db.collection('users').doc(user.uid).collection('notes');
  }

  // ---------- поиск по заметкам ----------

  late final NoteSearchCache _searchCache = NoteSearchCache(() async {
    final notes = _notes;
    if (notes == null) throw StateError('signed out');
    // только с сервера: без связи — ошибка, а не пустой кэш
    final snap = await notes
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 30));
    return {for (final d in snap.docs) d.id: d.data()};
  });

  /// Слова, которые нужно выделить, когда загрузится этот день
  SearchPick? _pendingFind;

  Future<void> _openSearch() async {
    if (_notes == null) return; // без входа поиск не открываем
    final pick = await showNoteSearch(
      context,
      cache: _searchCache,
      boilerplate: kTemplateLines,
      // открытый день ищем по тексту редактора — с несохранёнными правками
      liveKey: () =>
          _loadedKey == _dayKey(_selectedDay) ? _loadedKey : null,
      liveText: () => _controller.document.toPlainText(),
      inCalendarRange: (key) {
        final d = DateTime.parse(key);
        return !d.isBefore(kCalendarFirstDay) && !d.isAfter(kCalendarLastDay);
      },
    );
    if (pick == null || !mounted) return;
    if (_loadedKey == pick.key && _dayKey(_selectedDay) == pick.key) {
      _selectFirstMatch(pick.words);
      return;
    }
    final day = DateTime.parse(pick.key);
    _pendingFind = pick;
    // как клик по дню в календаре: сохранить текущий день и открыть нужный
    await _onDaySelected(day, day);
  }

  /// Выделяет первое совпадение в открытой заметке (содержимое не меняется)
  void _selectFirstMatch(List<String> words) {
    final hits = findInText(
        _controller.document.toPlainText(), words, kTemplateLines);
    if (hits == null) return;
    final r = hits.first;
    _editorFocus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.updateSelection(
        TextSelection(baseOffset: r.start, extentOffset: r.end),
        ChangeSource.local,
      );
    });
  }

  bool _loadingNow = false;

  Future<void> _loadNote(DateTime day) async {
    _loadingNow = true;
    try {
      await _loadNoteInner(day);
    } finally {
      _loadingNow = false;
    }
  }

  Future<void> _loadNoteInner(DateTime day) async {
    final key = _dayKey(day);
    _loadedKey = null; // пока не загрузили — сохранять нельзя (чтобы не затереть заметку)

    final notes = _notes;
    if (notes == null) return;

    DocumentSnapshot<Map<String, dynamic>> doc;
    try {
      doc = await notes.doc(key).get();
    } on FirebaseException catch (e) {
      _setStatus('Не удалось загрузить (${e.code})');
      return;
    } catch (_) {
      _setStatus('Не удалось загрузить');
      return;
    }
    // пока грузилось, мог быть выбран другой день
    if (!mounted || key != _dayKey(_selectedDay)) return;

    var accent = _pickAccent();
    Document document;
    final data = doc.data();
    final delta = data?['delta'];
    final text = (data?['text'] ?? '').toString();

    if (delta is String && delta.isNotEmpty) {
      try {
        document = Document.fromJson(jsonDecode(delta));
      } catch (_) {
        document = Document()..insert(0, text);
      }
      final savedAccent = data?['accent'];
      if (savedAccent is String && savedAccent.isNotEmpty) accent = savedAccent;
    } else if (text.trim().isNotEmpty) {
      // старые заметки (только обычный текст)
      document = Document()..insert(0, text);
    } else {
      // пустой день — подставляем шаблон
      document = _buildTemplate(day, accent);
    }

    // запоминаем «эталон» до подмены документа, чтобы загрузка не считалась правкой
    final json = jsonEncode(document.toDelta().toJson());
    _lastSavedJson = json;
    _lastSeenJson = json;
    _lastLen = document.length;
    _accent = accent;

    _controller.document = document;
    _controller.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );
    _loadedKey = key;
    _setStatus('');

    // переход из поиска — выделить найденное
    final find = _pendingFind;
    _pendingFind = null;
    if (find != null && find.key == key) _selectFirstMatch(find.words);
  }

  void _autoSave() {
    if (_backupBusy) return; // во время копии/восстановления — ничего не пишем
    final key = _dayKey(_selectedDay);
    if (_loadedKey != key) {
      // заметка так и не загрузилась (например, нет доступа) — пробуем снова
      if (!_loadingNow) _loadNote(_selectedDay);
      return;
    }
    if (_isDirty) _saveNote();
  }

  Future<void> _saveNote() async {
    final key = _dayKey(_selectedDay);
    if (_loadedKey != key || _saving) return;
    final notes = _notes;
    if (notes == null) return;
    _saving = true;
    final json = _currentJson();
    final plain = _controller.document.toPlainText().replaceAll('\uFFFC', '');
    _setStatus('Сохранение...');
    try {
      await notes.doc(key).set({
        'delta': json,
        'text': plain,
        'accent': _accent,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (key == _dayKey(_selectedDay)) _lastSavedJson = json;
      _searchCache.put(key, plain);
      _setStatus('Сохранено ✓');
    } on FirebaseException catch (e) {
      _setStatus('Ошибка сохранения (${e.code})');
    } catch (_) {
      _setStatus('Ошибка сохранения');
    } finally {
      _saving = false;
    }
  }

  Future<void> _onDaySelected(DateTime selectedDay, DateTime focusedDay) async {
    if (_backupBusy) return; // идёт копия/восстановление
    // не теряем несохранённые правки предыдущего дня
    while (_saving) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (_loadedKey == _dayKey(_selectedDay) && _isDirty) {
      await _saveNote();
    }
    if (!mounted) return;
    setState(() {
      _selectedDay = selectedDay;
      _focusedDay = focusedDay;
    });
    _status.value = '';
    _loadNote(selectedDay);
  }

  // ---------- реакция на изменения в редакторе ----------

  void _onControllerChanged() {
    if (_recoloring || _snapping) return;
    _snapSelectionOffDividers();
    final json = _currentJson();
    if (json == _lastSeenJson) return; // просто движение курсора
    _lastSeenJson = json;

    final len = _controller.document.length;
    final grew = len > _lastLen;
    _lastLen = len;
    if (grew) _keepNotForgetColor();
  }

  /// Новый текст в нумерованном списке под «Не забыть:» окрашивается цветом блока
  void _keepNotForgetColor() {
    final sel = _controller.selection;
    if (!sel.isCollapsed || sel.baseOffset < 1) return;

    final plain = _controller.document.toPlainText();
    final titleAt = plain.lastIndexOf(kNotForgetTitle);
    if (titleAt < 0) return;

    final o = sel.baseOffset;
    if (o <= titleAt + kNotForgetTitle.length || o - 1 >= plain.length) return;
    if (plain[o - 1] == '\n') return;

    final st = _controller.document.collectStyle(o - 1, 1);
    if (st.attributes[Attribute.list.key]?.value != 'ordered') return;
    if (st.attributes.containsKey(Attribute.color.key)) return;
    if (st.attributes.containsKey(Attribute.link.key)) return; // ссылки не красим

    _recoloring = true;
    try {
      _controller.formatText(o - 1, 1, ColorAttribute(_accent));
    } finally {
      _recoloring = false;
    }
  }

  // ---------- горячие клавиши ----------

  /// Глобальный перехват: срабатывает раньше, чем сам редактор,
  /// но только пока курсор стоит в поле заметки.
  bool _onGlobalKey(KeyEvent event) {
    if (!_editorFocus.hasFocus) return false;
    return _onEditorKey(_editorFocus, event) == KeyEventResult.handled;
  }

  KeyEventResult _onEditorKey(FocusNode node, KeyEvent event) {
    final hk = HardwareKeyboard.instance;
    final ctrl = hk.isControlPressed || hk.isMetaPressed;
    final shift = hk.isShiftPressed;
    final alt = hk.isAltPressed;
    final logical = event.logicalKey;
    final physical = event.physicalKey;

    if (event is KeyUpEvent) return KeyEventResult.ignored;

    if (ctrl && shift) {
      // Ctrl+Shift+7 — нумерованный список, Ctrl+Shift+8 — маркированный
      if (physical == PhysicalKeyboardKey.digit7) {
        if (event is KeyDownEvent) _toggle(Attribute.ol);
        return KeyEventResult.handled;
      }
      if (physical == PhysicalKeyboardKey.digit8) {
        if (event is KeyDownEvent) _toggle(Attribute.ul);
        return KeyEventResult.handled;
      }
    }

    if (ctrl && !shift && !alt) {
      // Ctrl+V: ссылка из буфера ложится на выделенный текст или
      // вставляется как ссылка; всё остальное — обычная вставка Quill.
      // Буфер в вебе читается асинхронно, поэтому сразу отвечаем «handled».
      if (physical == PhysicalKeyboardKey.keyV) {
        if (event is KeyDownEvent) _smartPaste();
        return KeyEventResult.handled;
      }
      // Ctrl+K — диалог «текст + адрес»
      if (physical == PhysicalKeyboardKey.keyK) {
        if (event is KeyDownEvent) _insertLink();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (!ctrl && !alt) {
      if (logical == LogicalKeyboardKey.tab) {
        _handleTab(shift);
        return KeyEventResult.handled;
      }
      if (logical == LogicalKeyboardKey.backspace && !shift) {
        if (_handleBackspace()) return KeyEventResult.handled;
      }
      if (logical == LogicalKeyboardKey.delete && !shift) {
        // Delete в конце строки перед разделителем не должен «съедать» его
        final sel = _controller.selection;
        if (sel.isCollapsed &&
            _dividerOffsets().contains(sel.baseOffset + 1)) {
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  /// Tab / Shift+Tab: уровень вложенности пункта списка (1. → a. → i.)
  void _handleTab(bool shift) {
    final attrs = _controller.getSelectionStyle().attributes;
    if (!attrs.containsKey(Attribute.list.key)) return;
    _controller.indentSelection(!shift);
  }

  /// Backspace в начале пункта списка: сначала уменьшает вложенность,
  /// затем снимает список; под разделителем строку с ним не склеивает.
  bool _handleBackspace() {
    final sel = _controller.selection;
    if (!sel.isCollapsed) return false;
    final pos = sel.baseOffset;
    final plain = _controller.document.toPlainText();
    final atLineStart = pos == 0 || (pos <= plain.length && plain[pos - 1] == '\n');
    if (!atLineStart) return false;

    final attrs = _controller.getSelectionStyle().attributes;
    final isList = attrs.containsKey(Attribute.list.key);
    final indent = attrs[Attribute.indent.key]?.value;
    if (isList && indent is int && indent > 0) {
      _controller.indentSelection(false);
      return true;
    }

    // строка сразу под разделителем
    final d = pos - 2;
    if (d >= 0 && _dividerOffsets().contains(d)) {
      if (isList) {
        _controller.formatSelection(Attribute.clone(Attribute.list, null));
      } else {
        _snapping = true;
        try {
          _controller.updateSelection(
            TextSelection.collapsed(offset: d > 0 ? d - 1 : 0),
            ChangeSource.local,
          );
        } finally {
          _snapping = false;
        }
      }
      return true;
    }
    return false;
  }

  // ---------- разделители (неактивные плашки) ----------

  /// Позиции всех разделителей в документе
  List<int> _dividerOffsets() {
    final res = <int>[];
    var off = 0;
    for (final op in _controller.document.toDelta().toList()) {
      final data = op.data;
      if (data is Map && data.containsKey('divider')) res.add(off);
      off += op.length ?? 0;
    }
    return res;
  }

  /// Разделитель нельзя выделить и нельзя поставить на него курсор:
  /// если выделение попало на него, оно сдвигается на соседнюю строку.
  void _snapSelectionOffDividers() {
    final sel = _controller.selection;
    if (!sel.isValid) return;
    final divs = _dividerOffsets();
    final prev = _prevCaret;
    if (divs.isEmpty) {
      _prevCaret = sel.extentOffset;
      return;
    }
    final len = _controller.document.length;
    var s = sel.start;
    var e = sel.end;
    var changed = false;

    for (final d in divs) {
      // строка разделителя: символ d и перенос d+1
      final cameFromBelow = prev != null && prev > d + 1;
      if (s == e) {
        if (s == d || s == d + 1) {
          final target = cameFromBelow ? (d > 0 ? d - 1 : 0) : (d + 2 < len ? d + 2 : len - 1);
          s = target;
          e = target;
          changed = true;
        }
      } else if (s >= d && e <= d + 2) {
        final target = d + 2 < len ? d + 2 : len - 1;
        s = target;
        e = target;
        changed = true;
      } else {
        if (s == d || s == d + 1) {
          s = d + 2;
          changed = true;
        }
        if (e == d + 1) {
          e = d;
          changed = true;
        }
      }
    }

    if (changed) {
      final forward = sel.baseOffset <= sel.extentOffset;
      final next = TextSelection(
        baseOffset: forward ? s : e,
        extentOffset: forward ? e : s,
      );
      _snapping = true;
      try {
        _controller.updateSelection(next, ChangeSource.local);
      } finally {
        _snapping = false;
      }
      _prevCaret = next.extentOffset;
    } else {
      _prevCaret = sel.extentOffset;
    }
  }

  // ---------- ссылки (как в Slack) ----------

  /// Ctrl+V. Буфер в вебе читается асинхронно (и с разрешения браузера),
  /// поэтому всё делаем после ответа «handled». Ошибка чтения — ничего не делаем.
  Future<void> _smartPaste() async {
    final sel = _controller.selection;
    if (!sel.isValid) return;
    final doc = _controller.document;

    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      return;
    }
    if (!mounted) return;

    final url = _asUrl(text);
    if (url != null) {
      // пока читали буфер, могли переключить день или сдвинуть курсор
      if (!identical(doc, _controller.document) || _controller.selection != sel) {
        return;
      }
      // с выделением: текст остаётся и становится ссылкой;
      // без выделения: вставляется сам адрес как ссылка
      _applyLink(sel.start, sel.end - sel.start, text!.trim(), url);
      return;
    }

    // не ссылка — обычная вставка редактора (замена выделения, форматирование и т.д.)
    try {
      // тот же метод, который Quill сам вызывает на Ctrl+V
      // ignore: experimental_member_use
      await _controller.clipboardPaste();
    } catch (_) {}
  }

  /// Ссылка на диапазон [start, start+len) или вставка [label] в позицию [start].
  /// Цвет с текста снимается. Всё делается одной правкой — один шаг Ctrl+Z.
  void _applyLink(int start, int len, String label, String url) {
    final docLen = _controller.document.length;
    if (start < 0 || start + len > docLen - 1) return;

    int caret;
    if (len > 0) {
      _composeOneStep(_inlineDelta(start, len, {
        Attribute.color.key: null,
        Attribute.link.key: url,
      }));
      caret = start + len;
    } else {
      if (label.isEmpty) return;
      _composeOneStep(
          Delta()..retain(start)..insert(label, {Attribute.link.key: url}));
      caret = start + label.length;
    }
    _controller.updateSelection(
      TextSelection.collapsed(offset: caret),
      ChangeSource.local,
    );
    _editorFocus.requestFocus();
  }

  /// Delta, которая накладывает inline-атрибуты на текст диапазона,
  /// пропуская переносы строк и разделители
  Delta _inlineDelta(int start, int len, Map<String, dynamic> attrs) {
    final plain = _controller.document.toPlainText();
    final end = min(start + len, plain.length - 1);
    bool isSkip(int i) => plain[i] == '\n' || plain[i] == '￼';

    final delta = Delta()..retain(start);
    var i = start;
    while (i < end) {
      final skip = isSkip(i);
      var j = i;
      while (j < end && isSkip(j) == skip) {
        j++;
      }
      if (skip) {
        delta.retain(j - i);
      } else {
        delta.retain(j - i, attrs);
      }
      i = j;
    }
    return delta;
  }

  void _composeOneStep(Delta delta) {
    _controller.compose(delta, _controller.selection, ChangeSource.local);
  }

  /// Адрес для открытия: без схемы — добавляем https://
  String _normalizeUrl(String raw) {
    final s = raw.trim();
    final asUrl = _asUrl(s);
    if (asUrl != null) return asUrl;
    if (s.startsWith(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:'))) return s;
    return 'https://$s';
  }

  /// Открывает ссылку в новой вкладке. Вызывается синхронно из клика:
  /// launchUrl в вебе доходит до window.open без await.
  void _openUrl(String url) {
    final uri = Uri.tryParse(_normalizeUrl(url));
    if (uri == null) return;
    launchUrl(uri, webOnlyWindowName: '_blank').catchError((_) => false);
  }

  /// Клик по ссылке в редакторе — маленькое меню вместо перехода
  GestureRecognizer? _linkRecognizer(Attribute attribute, Leaf leaf) {
    if (attribute.key != Attribute.link.key || attribute.value == null) {
      return null;
    }
    return TapGestureRecognizer()
      ..onTapUp = (details) => _showLinkMenu(leaf, details.globalPosition);
  }

  Future<void> _showLinkMenu(Leaf leaf, Offset globalPos) async {
    final url = leaf.style.attributes[Attribute.link.key]?.value?.toString();
    if (url == null || url.isEmpty) return;
    final doc = _controller.document;
    final range = getLinkRange(leaf);

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final p = overlay.globalToLocal(globalPos);

    PopupMenuItem<String> item(String value, IconData icon, String title,
            {VoidCallback? onTap}) =>
        PopupMenuItem<String>(
          value: value,
          height: 40,
          onTap: onTap,
          child: Row(
            children: [
              Icon(icon, size: 18, color: kTextSecondary),
              const SizedBox(width: 10),
              Text(title, style: const TextStyle(color: kTextPrimary)),
            ],
          ),
        );

    final choice = await showMenu<String>(
      context: context,
      color: kCard,
      position: RelativeRect.fromLTRB(
        p.dx,
        p.dy + 8,
        overlay.size.width - p.dx,
        overlay.size.height - p.dy,
      ),
      items: [
        // клик по адресу — копирование в буфер, меню остаётся открытым
        _CopyUrlEntry(url),
        // открываем прямо в обработчике клика, пока браузер считает это
        // действием пользователя
        item('open', Icons.open_in_new, 'Открыть', onTap: () => _openUrl(url)),
        item('edit', Icons.edit_outlined, 'Изменить'),
        item('remove', Icons.link_off, 'Убрать ссылку'),
      ],
    );
    if (!mounted || choice == null) return;
    // пока меню было открыто, могли переключить день
    if (!identical(doc, _controller.document)) return;
    if (range.end > _controller.document.length - 1) return;

    switch (choice) {
      case 'open':
        break; // уже открыто в onTap пункта меню
      case 'edit':
        await _insertLink(range: range, currentUrl: url);
        break;
      case 'remove':
        // текст остаётся, снимается только ссылка
        _composeOneStep(_inlineDelta(
            range.start, range.end - range.start, {Attribute.link.key: null}));
        _editorFocus.requestFocus();
        break;
    }
  }

  String? _asUrl(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty || RegExp(r'\s').hasMatch(s)) return null;
    if (RegExp(r'^(https?|ftp)://\S+$', caseSensitive: false).hasMatch(s) ||
        RegExp(r'^mailto:\S+$', caseSensitive: false).hasMatch(s)) {
      return s;
    }
    if (RegExp(r'^www\.\S+\.\S+$', caseSensitive: false).hasMatch(s)) {
      return 'https://$s';
    }
    return null;
  }

  // ---------- форматирование ----------

  bool _isActive(Attribute attr) {
    final current = _controller.getSelectionStyle().attributes[attr.key];
    return current != null && current.value == attr.value;
  }

  void _toggle(Attribute attr) {
    _controller.formatSelection(
      _isActive(attr) ? Attribute.clone(attr, null) : attr,
    );
    _editorFocus.requestFocus();
  }

  bool _isColor(String hex) {
    final current =
        _controller.getSelectionStyle().attributes[Attribute.color.key];
    return current != null && current.value == hex;
  }

  void _toggleColor(String hex) {
    if (_isColor(hex)) {
      _controller.formatSelection(Attribute.clone(Attribute.color, null));
    } else {
      _controller.formatSelection(ColorAttribute(hex));
    }
    _editorFocus.requestFocus();
  }

  /// Ctrl+K / кнопка в панели / «Изменить» в меню ссылки.
  /// Если текст выделен (или передан [range]), поле «Текст» заполнено им
  /// и недоступно для правки.
  Future<void> _insertLink({TextRange? range, String? currentUrl}) async {
    final sel = _controller.selection;
    if (range == null && !sel.isValid) return;
    final start = range?.start ?? sel.start;
    final len = range != null ? range.end - range.start : sel.end - sel.start;
    final hasSelection = len > 0;
    final doc = _controller.document;

    final selectedText = hasSelection
        ? doc
            .toPlainText()
            .substring(start, start + len)
            .replaceAll('￼', '')
            .replaceAll('\n', ' ')
        : '';
    final oldUrl = currentUrl ??
        (hasSelection
            ? doc.collectStyle(start, len).attributes[Attribute.link.key]?.value
                as String?
            : null);

    final urlCtrl = TextEditingController(text: oldUrl ?? '');
    final textCtrl = TextEditingController(text: selectedText);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: Text(oldUrl == null ? 'Вставить ссылку' : 'Изменить ссылку'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: textCtrl,
                enabled: !hasSelection,
                decoration: const InputDecoration(labelText: 'Текст'),
              ),
              TextField(
                controller: urlCtrl,
                autofocus: true,
                decoration:
                    const InputDecoration(labelText: 'Адрес (https://...)'),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(oldUrl == null ? 'Вставить' : 'Сохранить')),
        ],
      ),
    );
    final rawUrl = urlCtrl.text.trim();
    final label = textCtrl.text.trim();
    urlCtrl.dispose();
    textCtrl.dispose();
    if (ok != true || !mounted) {
      _editorFocus.requestFocus();
      return;
    }
    if (rawUrl.isEmpty || !identical(doc, _controller.document)) return;

    final url = _normalizeUrl(rawUrl);
    if (hasSelection) {
      _applyLink(start, len, '', url);
    } else {
      _applyLink(start, 0, label.isEmpty ? rawUrl : label, url);
    }
  }

  // ---------- элементы интерфейса ----------

  Widget _toolButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    required bool active,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: active ? kAccent.withValues(alpha: 0.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: active ? kAccent : Colors.transparent),
          ),
          child: Icon(icon,
              size: 19, color: active ? kAccentLight : kTextSecondary),
        ),
      ),
    );
  }

  Widget _colorDot(String hex, String tooltip) {
    final c = Color(int.parse('FF${hex.substring(1)}', radix: 16));
    final active = _isColor(hex);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _toggleColor(hex),
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(
                color: active ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _vDivider() => Container(
        width: 1,
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: kDivider,
      );

  Widget _toolbar() {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final hasLink = _controller
            .getSelectionStyle()
            .attributes
            .containsKey(Attribute.link.key);
        return Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 2,
          runSpacing: 2,
          children: [
            _toolButton(
              icon: Icons.format_bold,
              tooltip: 'Жирный (Ctrl+B)',
              active: _isActive(Attribute.bold),
              onPressed: () => _toggle(Attribute.bold),
            ),
            _toolButton(
              icon: Icons.strikethrough_s,
              tooltip: 'Зачёркнутый',
              active: _isActive(Attribute.strikeThrough),
              onPressed: () => _toggle(Attribute.strikeThrough),
            ),
            _toolButton(
              icon: Icons.link,
              tooltip: 'Ссылка (Ctrl+K, или выделите текст и вставьте ссылку Ctrl+V)',
              active: hasLink,
              onPressed: () => _insertLink(),
            ),
            _vDivider(),
            _colorDot(kRed, 'Красный'),
            _colorDot(kYellow, 'Жёлтый'),
            _colorDot(kGreen, 'Зелёный'),
            _vDivider(),
            _toolButton(
              icon: Icons.format_list_numbered,
              tooltip: 'Нумерованный список (Ctrl+Shift+7)',
              active: _isActive(Attribute.ol),
              onPressed: () => _toggle(Attribute.ol),
            ),
            _toolButton(
              icon: Icons.format_list_bulleted,
              tooltip: 'Маркированный список (Ctrl+Shift+8)',
              active: _isActive(Attribute.ul),
              onPressed: () => _toggle(Attribute.ul),
            ),
          ],
        );
      },
    );
  }

  // ---------- календарь ----------

  Widget _calendarPanel() {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kDivider),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // баннер с дизерингом (318x112): одна точка = один логический пиксель
          Image.asset(
            'assets/images/banner.png',
            width: double.infinity,
            height: 112,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.none,
            errorBuilder: (_, __, ___) => const SizedBox(height: 0),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: _showMonths ? _monthPicker() : _monthView(),
          ),
        ],
      ),
    );
  }

  Widget _monthView() {
    return TableCalendar(
      firstDay: kCalendarFirstDay,
      lastDay: kCalendarLastDay,
      focusedDay: _focusedDay,
      startingDayOfWeek: StartingDayOfWeek.monday,
      rowHeight: 40,
      daysOfWeekHeight: 24,
      selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
      onDaySelected: _onDaySelected,
      onPageChanged: (d) => _focusedDay = d,
      // клик по названию месяца — показать все месяцы года
      onHeaderTapped: (_) => setState(() {
        _pickerYear = _focusedDay.year;
        _showMonths = true;
      }),
      calendarBuilders: CalendarBuilders(
        dowBuilder: (context, day) => Center(
          child: Text(
            kWeekdaysShort[day.weekday - 1],
            style: const TextStyle(
              color: kTextSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
      calendarStyle: const CalendarStyle(
        cellMargin: EdgeInsets.all(4),
        defaultTextStyle: TextStyle(color: kTextPrimary),
        weekendTextStyle: TextStyle(color: kTextSecondary),
        outsideTextStyle: TextStyle(color: Color(0xFF55526A)),
        todayTextStyle:
            TextStyle(color: kAccentLight, fontWeight: FontWeight.bold),
        selectedTextStyle:
            TextStyle(color: kBackground, fontWeight: FontWeight.bold),
        todayDecoration:
            BoxDecoration(color: Colors.transparent, shape: BoxShape.circle),
        selectedDecoration:
            BoxDecoration(color: kAccent, shape: BoxShape.circle),
      ),
      headerStyle: HeaderStyle(
        formatButtonVisible: false,
        titleCentered: true,
        titleTextFormatter: (date, locale) =>
            '${kMonthsNom[date.month - 1]} ${date.year}',
        titleTextStyle: const TextStyle(
            color: kTextPrimary, fontSize: 16, fontWeight: FontWeight.w600),
        leftChevronIcon: const Icon(Icons.chevron_left, color: kAccent),
        rightChevronIcon: const Icon(Icons.chevron_right, color: kAccent),
      ),
    );
  }

  Widget _monthPicker() {
    final now = DateTime.now();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: _pickerYear > 2020
                  ? () => setState(() => _pickerYear--)
                  : null,
              icon: const Icon(Icons.chevron_left, color: kAccent),
            ),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _showMonths = false),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Center(
                    child: Text(
                      '$_pickerYear',
                      style: const TextStyle(
                        color: kTextPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              onPressed: _pickerYear < 2030
                  ? () => setState(() => _pickerYear++)
                  : null,
              icon: const Icon(Icons.chevron_right, color: kAccent),
            ),
          ],
        ),
        const SizedBox(height: 4),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.7,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
          children: [
            for (var m = 1; m <= 12; m++) _monthCell(m, now),
          ],
        ),
      ],
    );
  }

  Widget _monthCell(int m, DateTime now) {
    final selected = _focusedDay.year == _pickerYear && _focusedDay.month == m;
    final isNow = now.year == _pickerYear && now.month == m;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() {
        _focusedDay = DateTime(_pickerYear, m, 1);
        _showMonths = false;
      }),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? kAccent : kCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: (isNow && !selected) ? kAccent : kDivider,
          ),
        ),
        child: Text(
          kMonthsShort[m - 1],
          style: TextStyle(
            color: selected ? kBackground : kTextPrimary,
            fontWeight: selected || isNow ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  // ---------- заметка ----------

  Widget _notePanel() {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kDivider),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // кнопка сворачивания календаря — рядом с датой
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  _calendarVisible
                      ? Icons.calendar_month
                      : Icons.calendar_today,
                  color: kAccent,
                ),
                tooltip:
                    _calendarVisible ? 'Скрыть календарь' : 'Показать календарь',
                onPressed: () =>
                    setState(() => _calendarVisible = !_calendarVisible),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.search, color: kAccent),
                tooltip: 'Поиск по заметкам',
                onPressed: _openSearch,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _formatDate(_selectedDay),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kAccentLight,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _appMenu(),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kDivider),
            ),
            child: _toolbar(),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kDivider),
              ),
              child: Stack(
                children: [
                  // заставка видна, пока в заметке ничего нет (например, выходной)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ListenableBuilder(
                        listenable: _controller,
                        builder: (context, _) {
                          final empty = _controller.document.isEmpty();
                          return AnimatedOpacity(
                            duration: const Duration(milliseconds: 250),
                            opacity: empty ? 1 : 0,
                            child: Center(
                              child: Image.asset(
                                'assets/images/empty_day.png',
                                width: 176,
                                height: 176,
                                filterQuality: FilterQuality.none,
                                errorBuilder: (_, __, ___) =>
                                    const SizedBox.shrink(),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  QuillEditor(
                controller: _controller,
                focusNode: _editorFocus,
                scrollController: _editorScroll,
                config: QuillEditorConfig(
                  placeholder: 'Что важного в этот день...',
                  padding: EdgeInsets.zero,
                  expands: true,
                  embedBuilders: const [DividerEmbedBuilder()],
                  // клик по ссылке — меню «Открыть / Изменить / Убрать ссылку»
                  customRecognizerBuilder: _linkRecognizer,
                  customStyles: DefaultStyles(
                    link: const TextStyle(
                      color: Color(0xFF5AB0FF),
                      decoration: TextDecoration.underline,
                      decorationColor: Color(0xFF5AB0FF),
                    ),
                  ),
                ),
              ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: ValueListenableBuilder<String>(
              valueListenable: _status,
              builder: (context, status, _) {
                Color color = kTextSecondary;
                if (status == 'Сохранено ✓') color = kAccent;
                if (status.startsWith('Ошибка') ||
                    status.startsWith('Не удалось')) {
                  color = const Color(0xFFFF5C5C);
                }
                return Text(status,
                    style: TextStyle(color: color, fontSize: 13));
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------- общий каркас ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 800;

            if (wide) {
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1400),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Календарь слева
                        AnimatedSize(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOut,
                          child: SizedBox(
                            width: _calendarVisible ? 320 : 0,
                            child: _calendarVisible
                                ? Padding(
                                    padding: const EdgeInsets.only(right: 20),
                                    child: Align(
                                      alignment: Alignment.topCenter,
                                      child: SingleChildScrollView(
                                        child: _calendarPanel(),
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                        ),
                        // Заметка посередине
                        Expanded(child: _notePanel()),
                      ],
                    ),
                  ),
                ),
              );
            }

            // Узкий экран (телефон): календарь сверху, заметка ниже
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_calendarVisible) ...[
                  _calendarPanel(),
                  const SizedBox(height: 16),
                ],
                SizedBox(height: 560, child: _notePanel()),
              ],
            );
          },
        ),
      ),
    );
  }
}
