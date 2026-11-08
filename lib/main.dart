import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb, mapEquals, visibleForTesting;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:url_launcher/url_launcher.dart';

import 'backup.dart';
import 'dividers.dart';
import 'firebase_options.dart';
import 'format_menu.dart';
import 'spell/dictionary_dialog.dart';
import 'spell/personal_dictionary.dart';
import 'spell/spell_backend.dart';
import 'spell/spell_engine.dart';
import 'spell/spell_host.dart';
import 'offline.dart';
import 'search.dart' show findInText, kObjectReplacement;
import 'search_dialog.dart';
import 'tasks.dart';
import 'editor_utils.dart';
import 'templates.dart';
import 'today.dart';
import 'topics.dart';
import 'topics_panel.dart';

export 'templates.dart' show kNotForgetTitle, kMonthlyReport, kHolidayNote;

part 'editor_kit.dart';
part 'templates_dialog.dart';

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
  // локальная копия заметок на устройстве — до любого обращения к Firestore
  await configureFirestoreCache(FirebaseFirestore.instance);
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

/// Рабочий день по правилам приложения (для тестов переноса задач)
@visibleForTesting
bool isWorkingDay(DateTime d) => _isWorkday(d);

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
// Тексты стандартных шаблонов, kNotForgetTitle / kMonthlyReport /
// kHolidayNote и сборка дня — в templates.dart (настраиваются в «Шаблонах»).
// Условия — какой особый блок в какой день — остаются здесь, в коде.

/// Разделитель между блоками шаблона: тонкая плашка на всю ширину редактора
class DividerEmbedBuilder extends EmbedBuilder {
  const DividerEmbedBuilder();

  @override
  String get key => 'divider';

  /// В буфере обмена (текст) — ничего, а не символ-заглушка U+FFFC
  @override
  String toPlainText(Embed node) => kDividerPlainText;

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

String _pickAccent() =>
    kNotForgetColors[Random().nextInt(kNotForgetColors.length)];

/// Шаблон нового пустого дня: шаблон дня недели + особые блоки по датам.
/// Тексты — из [settings] (или стандартные), условия — здесь, в коде.
/// Возвращает документ и цвет блока «Не забыть».
(Document, String) _composeDay(
    DateTime day, String accent, TemplateSettings settings) {
  final c = composeTemplate(
    weekday: day.weekday,
    // Каждый второй четверг — дополнительный блок «Вадим викли»
    vadimWeek: _isVadimWeek(day),
    // Первый рабочий день месяца — отчёт по СДК в задачах на день
    firstWorkday: _isFirstWorkdayOfMonth(day),
    // День перед государственным праздником — напоминание в «Не забыть»
    dayBeforeHoliday: _isDayBeforeHoliday(day),
    settings: settings,
    accent: accent,
  );
  if (c.ops.isEmpty) return (Document(), c.accent);
  // пункты блока «Задачи на день» — открытые задачи с кнопками ✗/✓
  final ops = linesToOps(markTaskSection(opsToLines(c.ops)));
  return (dividerSafeDocument(ops), c.accent);
}

/// Стандартный шаблон дня (без пользовательских настроек)
Document _buildTemplate(DateTime day, String accent) =>
    _composeDay(day, accent, TemplateSettings.defaults).$1;

/// Шаблон дня по умолчанию — для «золотого» теста (сверка с прежним выводом)
@visibleForTesting
Document debugBuildTemplate(DateTime day, String accent) =>
    _buildTemplate(day, accent);

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
    if (browserSaysOffline) return _show(error: kNeedNetworkSignIn);

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
    if (browserSaysOffline) return _show(error: kNeedNetwork);
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
    with WidgetsBindingObserver, _EditorKit<CalendarPage> {
  // редактор заметок — «свой» редактор для общих функций (_EditorKit)
  @override
  QuillController get _ec => _controller;
  @override
  FocusNode get _ef => _editorFocus;

  DateTime _selectedDay = DateTime.now();
  DateTime _focusedDay = DateTime.now();

  late final QuillController _controller;
  late final FocusNode _editorFocus;
  final ScrollController _editorScroll = ScrollController();
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  bool _calendarVisible = true;

  /// Проверка правописания (словари грузятся в фоне после входа)
  late final SpellEngine _spell = SpellEngine(
    backend: createSpellBackend(),
    dictionary: PersonalDictionary(
      FirestoreDictionaryStore(() => _dictionaryRef,
          offline: () => _offline, onLateError: _onDictionaryLateError),
      onError: _onDictionaryError,
    ),
  );

  @override
  SpellEngine? get _spellEngine => _spell;

  /// Панель форматирования над заметкой (запоминается на этом устройстве)
  static const _toolbarPref = ToolbarVisibilityPref();
  bool _toolbarVisible = _toolbarPref.load();

  void _toggleToolbar() {
    setState(() => _toolbarVisible = !_toolbarVisible);
    _toolbarPref.save(_toolbarVisible);
  }
  bool _showMonths = false;
  int _pickerYear = DateTime.now().year;

  // --- состояние сохранения ---
  final ValueNotifier<String> _status = ValueNotifier<String>('');
  Timer? _autoTimer;
  String _lastSavedJson = '';
  String _lastSeenJson = '';
  int _lastLen = 0;
  String? _loadedKey; // для какого дня заметка уже загружена

  // --- работа без сети (логика — offline.dart) ---
  final ConnectionMonitor _conn = ConnectionMonitor();
  final SaveTracker _saves = SaveTracker();
  late final OfflineDownloader _download = OfflineDownloader(
    source: FirestoreCopySource(() => _userRef),
    marker: const LocalCopyMarker(),
    uid: widget.uid,
    isOffline: () => _conn.offline,
    markerTrusted: !offlineCacheLimited,
  );
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _connSub;
  Timer? _downloadStart;

  /// Открыт «неизвестный» день (isUnknownDay) — предупреждение над редактором
  final ValueNotifier<bool> _unknownDay = ValueNotifier<bool>(false);

  /// Поиск взял заметки из локальной копии
  bool _searchFromCache = false;

  /// «Сохранённое содержимое» после отказа сервера: не совпадает ни с каким
  /// текстом — заметка снова несохранённая, автосохранение повторит запись
  static const String _rejectedMark = '\u0000rejected';

  bool get _offline => _conn.offline;

  // --- темы: открытая тема вместо дня ---
  String? _openTopicId; // null — в центре заметка выбранного дня
  int _loadSeq = 0; // номер последней загрузки: старые результаты не применяются
  late final TopicsController _topics = TopicsController(FirestoreTopicStore(
      () => _topicsRef,
      offline: () => _offline,
      onLateError: _onTopicLateError));

  // --- шаблоны дня: загружаются один раз за сеанс ---
  late final TemplateStore _templateStore = FirestoreTemplateStore(
      () => _templatesRef,
      offline: () => _offline,
      onLateError: _onTemplatesLateError);
  TemplateSettings _templateSettings = TemplateSettings.defaults;
  bool _templatesLoaded = false; // настройки получены (или их точно нет)
  Future<void>? _templatesLoading;

  /// Что сейчас открыто в редакторе: ключ дня 'yyyy-MM-dd' или `t:<id>`
  String get _targetKey =>
      _openTopicId != null ? topicKey(_openTopicId!) : _dayKey(_selectedDay);
  String _accent = kNotForgetColors.first;
  bool _recoloring = false;

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
    _controller = QuillController.basic(config: kEditorControllerConfig);
    _editorFocus = FocusNode();
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onControllerChanged);
    _saves.onRejected = _onSaveRejected;
    _saves.addListener(_onSavesChanged);
    _conn.addReconnectListener(_onReconnect);
    if (browserSaysOffline) _conn.browserChanged(false);
    listenBrowserOnline((online) {
      if (mounted) _conn.browserChanged(online);
    });
    _watchConnection();
    // копия всех заметок на устройство — в фоне, после открытия первого дня
    _downloadStart = Timer(const Duration(seconds: 3), _download.run);
    // словари правописания — тоже в фоне (если проверка включена)
    _spell.onFailed = _onSpellFailed;
    _spell.start();
    _templatesLoading = _loadTemplateSettings();
    _loadNote(_selectedDay);
    _topics.load();
    // автосохранение каждые 5 секунд, если есть несохранённые правки
    _autoTimer = Timer.periodic(const Duration(seconds: 5), (_) => _autoSave());
  }

  @override
  void dispose() {
    _hideTaskPopup();
    _noteSub?.cancel();
    _connSub?.cancel();
    _downloadStart?.cancel();
    _download.dispose();
    _saves.dispose();
    _conn.dispose();
    _unknownDay.dispose();
    _spell.dispose();
    setLeaveGuard(false);
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    WidgetsBinding.instance.removeObserver(this);
    _autoTimer?.cancel();
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _editorFocus.dispose();
    _editorScroll.dispose();
    _status.dispose();
    _topics.dispose();
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
          case 'templates':
            _openTemplates();
            break;
          case 'spell':
            setState(() => _spell.setEnabled(!_spell.enabled));
            break;
          case 'dictionary':
            showPersonalDictionaryDialog(context, _spell.dictionary);
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
        if (_offline)
          const PopupMenuItem<String>(
            enabled: false,
            height: 40,
            child: Row(
              children: [
                Icon(Icons.upload_outlined, size: 18, color: kTextSecondary),
                SizedBox(width: 10),
                Text('Восстановить из копии — $kNeedNetwork',
                    style: TextStyle(color: kTextSecondary)),
              ],
            ),
          )
        else
          item('restore', Icons.upload_outlined, 'Восстановить из копии'),
        item('templates', Icons.view_agenda_outlined, 'Шаблоны'),
        CheckedPopupMenuItem<String>(
          value: 'spell',
          height: 40,
          checked: _spell.enabled,
          child: const Text('Проверка правописания',
              style: TextStyle(color: kTextPrimary)),
        ),
        item('dictionary', Icons.spellcheck, 'Личный словарь'),
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
    for (var i = 0; _taskBusy && i < 300; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (_taskBusy) return false;
    if (_loadedKey == _targetKey && _isDirty) {
      await _saveNote();
    }
    return !(_loadedKey == _targetKey && _isDirty);
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
      var topicList = const <BackupTopic>[];
      var fromDevice = false;
      try {
        // с сервера; без связи (или пока последние правки не ушли на
        // сервер) — из локальной копии: в ней есть и ещё не отправленное
        var useCache = _offline;
        if (!useCache) {
          try {
            await _db
                .waitForPendingWrites()
                .timeout(const Duration(seconds: 10));
          } catch (_) {
            useCache = true;
          }
        }
        final snap = await readQuery(
            notes
                .where(FieldPath.documentId, isGreaterThanOrEqualTo: from)
                .where(FieldPath.documentId, isLessThanOrEqualTo: to),
            offline: useCache,
            serverOnly: true,
            timeout: const Duration(seconds: 60));
        fromDevice = snap.fromCache;
        list = notesForExport(
            {for (final d in snap.value.docs) d.id: d.data()},
            today: today);
        // темы — все, без привязки к периоду
        final topicsCol = _topicsRef;
        if (topicsCol != null) {
          final tsnap = await readQuery(topicsCol,
              offline: useCache || fromDevice,
              serverOnly: true,
              timeout: const Duration(seconds: 60));
          fromDevice = fromDevice || tsnap.fromCache;
          topicList = topicsForExport(
              {for (final d in tsnap.value.docs) d.id: d.data()});
        }
      } on BackupException catch (e) {
        await _showMessage('Копия не создана', e.message, error: true);
        return;
      } catch (e) {
        await _showMessage('Копия не создана',
            'Не удалось получить заметки: ${describeError(e)}.',
            error: true);
        return;
      }

      // личный словарь — тоже в копию (свежий из базы, иначе — из памяти)
      final dictionaryWords = await _spell.dictionary.exportWords();

      if (list.isEmpty && topicList.isEmpty && dictionaryWords.isEmpty) {
        await _showMessage('Нет заметок',
            'За период $period нет сохранённых заметок, тем тоже нет. '
                'Файл не создан.');
        return;
      }

      final name = backupFileName(today);
      final json = encodeBackup(list,
          topics: topicList,
          dictionary: dictionaryWords,
          today: today,
          createdAtUtc: DateTime.now().toUtc());
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
              'Тем: ${topicList.length}\n'
              '${dictionaryWords.isEmpty ? '' : 'Слов в личном словаре: ${dictionaryWords.length}\n'}'
              'Период: $period'
              '${fromDevice ? _deviceCopyNote() : ''}');
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
            'Заметок в копии: ${data.notes.length}\n'
            '${data.topics.isEmpty ? '' : 'Тем в копии: ${data.topics.length}\n'}'
            '${data.dictionary.isEmpty ? '' : 'Слов личного словаря в копии: ${data.dictionary.length}\n'}'
            '\n'
            'Способ: перезапись.\n'
            '• Заметки за те же даты будут заменены версиями из копии.\n'
            '• Заметки, которых нет в копии, останутся как есть.\n'
            '• Заметки вне периода копии не изменятся.\n'
            '${data.topics.isEmpty ? '' : '• Темы из копии заменят темы с тем же идентификатором или будут созданы; остальные темы не изменятся.\n'}'
            '${data.dictionary.isEmpty ? '' : '• Слова из копии добавятся в личный словарь; ваши слова останутся.\n'}'
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

  /// Дата заметки или «тема «…»» для отчёта о восстановлении
  String _restoreKeyLabel(String key) {
    final id = topicIdOf(key);
    if (id == null) return formatRuDate(key);
    return 'тема «${_topics.byId(id)?.title ?? id}»';
  }

  /// Пояснение к копии, собранной без сервера
  String _deviceCopyNote() =>
      '\n\nСобрана из локальной копии на устройстве (нет связи с сервером).'
      '${_download.complete ? '' : ' Полная копия заметок на это устройство '
          'ещё не загружалась — часть старых заметок могла не попасть.'}';

  Future<void> _restoreBackup() async {
    if (_backupBusy) return;
    if (_notes == null) return;
    // восстановление читает и пишет сервер (с откатом при сбое) — без сети
    // не начинаем
    if (_offline) {
      await _showMessage(
          kNeedNetwork,
          'Восстановление из копии работает только при подключении к '
              'интернету. Ничего не изменено.',
          error: true);
      return;
    }
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
      if (data.notes.isEmpty &&
          data.topics.isEmpty &&
          data.dictionary.isEmpty) {
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
      // все правки должны дойти до сервера (восстановление читает сервер)
      try {
        if (_offline) throw StateError('offline');
        await _db.waitForPendingWrites().timeout(const Duration(seconds: 15));
      } catch (_) {
        await _showMessage(
            kNeedNetwork,
            'Последние правки ещё не дошли до сервера. Проверьте интернет и '
                'попробуйте снова. Ничего не изменено.',
            error: true);
        return;
      }
      final notes = _notes;
      if (notes == null || !mounted) return;
      touched = true;
      _loadedKey = null; // старое содержимое редактора больше не сохранится

      // 5. запись с прогрессом
      final progress = ValueNotifier<(int, int)>(
          (0, data.notes.length + data.topics.length));
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

      final result = data.notes.isEmpty && data.topics.isEmpty
          ? const RestoreResult(ok: true, total: 0, written: 0)
          : await runRestore(
              FirestoreNoteStore(notes, topics: _topicsRef),
              data.notes,
              topics: data.topics,
              onProgress: (done, total) => progress.value = (done, total),
            );

      // личный словарь: объединение (слова, которых нет в копии, остаются)
      var dictionaryNote = '';
      if (data.dictionary.isNotEmpty) {
        try {
          await _spell.dictionary.load();
          final added = await _spell.dictionary.addAll(data.dictionary);
          dictionaryNote = '\nСлов добавлено в личный словарь: $added.';
        } catch (e) {
          dictionaryNote =
              '\nЛичный словарь не обновлён: ${describeError(e)}.';
        }
      }

      final c = dialogCtx;
      if (c != null && c.mounted) Navigator.of(c).pop();
      progress.dispose();

      if (result.ok) {
        await _showMessage(
            'Восстановление завершено',
            '${data.topics.isEmpty ? 'Восстановлено заметок: ${result.written} из ${result.total}.' : 'Восстановлено заметок: ${data.notes.length}, тем: ${data.topics.length}.'}'
            '$dictionaryNote');
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
              'удалось для ${data.topics.isEmpty ? 'дат' : 'записей'}: '
              '${result.notRolledBack.map(_restoreKeyLabel).join(', ')}.';
        }
        await _showMessage('Восстановление не завершено',
            'Причина: ${result.error}.\n\n$state$dictionaryNote\n\n'
                'Можно повторить восстановление из того же файла.',
            error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _backupBusy = false);
        // показываем то, что теперь лежит в базе
        if (touched) {
          _searchCache.invalidate();
          _topics.load();
          _loadTarget();
        }
      }
    }
  }

  /// Выход только на этом устройстве: на других вход сохраняется.
  /// Заметки в Firestore не трогаем.
  Future<void> _signOut() async {
    if (_signingOut) return;

    // сначала сохраняем последние правки (и дожидаемся переноса задачи)
    while (_taskBusy) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (_loadedKey == _targetKey && _isDirty) {
      await _saveNote();
    }
    if (!mounted) return;
    var confirmed = false;
    if (_loadedKey == _targetKey && _isDirty) {
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
      confirmed = true;
    }

    // правки, которые ещё не дошли до сервера (нет связи): локальная копия
    // остаётся на устройстве, но без входа отправить их некому
    if (!confirmed &&
        await hasUnsyncedWrites(
            waitForPendingWrites: _db.waitForPendingWrites,
            hasRejected: () => _saves.hasRejected)) {
      if (!mounted) return;
      final leave = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kSurface,
          title: const Text(kSignOutPendingTitle),
          content: const Text(kSignOutPendingBody),
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
    _unwatchNote();
    _loadedKey = null;
    _lastSavedJson = '';
    _lastSeenJson = '';
    _lastLen = 0;
    _docIsDay = false;
    _unknownDay.value = false;
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
      _loadTarget();
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
    // с сервера; без связи — из локальной копии (в окне — подсказка)
    final snap = await readQuery(notes,
        offline: _offline,
        serverOnly: true,
        timeout: const Duration(seconds: 10));
    _searchFromCache = snap.fromCache;
    return {for (final d in snap.value.docs) d.id: d.data()};
  }, loadTopics: () async {
    final topics = _topicsRef;
    if (topics == null) throw StateError('signed out');
    final snap = await readQuery(topics,
        offline: _offline || _searchFromCache,
        serverOnly: true,
        timeout: const Duration(seconds: 10));
    if (snap.fromCache) _searchFromCache = true;
    return {for (final d in snap.value.docs) d.id: d.data()};
  });

  /// Слова, которые нужно выделить, когда загрузится этот день
  SearchPick? _pendingFind;

  Future<void> _openSearch() async {
    if (_notes == null) return; // без входа поиск не открываем
    final pick = await showNoteSearch(
      context,
      cache: _searchCache,
      boilerplate: kTemplateLines,
      // открытый день или тему ищем по тексту редактора — с несохранёнными
      // правками
      liveKey: () => _loadedKey == _targetKey ? _loadedKey : null,
      liveText: () => _controller.document.toPlainText(),
      inCalendarRange: (key) {
        final d = DateTime.parse(key);
        return !d.isBefore(kCalendarFirstDay) && !d.isAfter(kCalendarLastDay);
      },
      topics: () => _topics.topics,
      localCopy: () => _offline || _searchFromCache,
    );
    if (pick == null || !mounted) return;
    final pickedTopic = topicIdOf(pick.key);
    if (_loadedKey == pick.key && _targetKey == pick.key) {
      _selectFirstMatch(pick.words,
          boilerplate: pickedTopic != null ? const {} : null);
      return;
    }
    if (pickedTopic != null) {
      _pendingFind = pick;
      await _openTopic(pickedTopic);
      return;
    }
    final day = DateTime.parse(pick.key);
    _pendingFind = pick;
    // как клик по дню в календаре: сохранить текущий день и открыть нужный
    await _onDaySelected(day, day);
  }

  /// Выделяет первое совпадение в открытой заметке (содержимое не меняется)
  /// [boilerplate]: null — строки шаблонов дня; у тем шаблонов нет ({}).
  void _selectFirstMatch(List<String> words, {Set<String>? boilerplate}) {
    final hits = findInText(_controller.document.toPlainText(), words,
        boilerplate ?? kTemplateLines);
    if (hits == null || hits.lines.isEmpty) return;
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
    _unknownDay.value = false;
    final seq = ++_loadSeq;

    final notes = _notes;
    if (notes == null) return;

    DocumentSnapshot<Map<String, dynamic>>? doc;
    var fromCache = false;
    try {
      // без связи (или сервер молчит дольше 3 с) — из локальной копии
      final r = await readDoc(notes.doc(key), offline: _offline);
      doc = r.value;
      fromCache = r.fromCache;
    } on FirebaseException catch (e) {
      if (seq == _loadSeq) _setStatus('Не удалось загрузить (${e.code})');
      return;
    } catch (_) {
      if (seq == _loadSeq) _setStatus('Не удалось загрузить');
      return;
    }
    // пока грузилось, мог быть выбран другой день или тема
    if (!mounted || seq != _loadSeq || key != _targetKey) return;

    var accent = _pickAccent();
    Document document;
    final data = doc?.data();
    final delta = data?['delta'];
    final text = (data?['text'] ?? '').toString();

    if (delta is String && delta.isNotEmpty) {
      try {
        document = dividerSafeDocument(jsonDecode(delta));
      } catch (_) {
        document = Document()..insert(0, text);
      }
      final savedAccent = data?['accent'];
      if (savedAccent is String && savedAccent.isNotEmpty) accent = savedAccent;
    } else if (text.trim().isNotEmpty) {
      // старые заметки (только обычный текст)
      document = Document()..insert(0, text);
    } else {
      // пустой день — подставляем шаблон (с учётом настроек «Шаблонов»)
      final settings = await _templateSettingsForDay();
      if (!mounted || seq != _loadSeq || key != _targetKey) return;
      final (built, usedAccent) = _composeDay(day, accent, settings);
      document = built;
      accent = usedAccent;
    }

    // запись этого дня отклонил сервер — показываем свой текст, а не откат
    final rejected = _saves.rejected(key);
    if (rejected != null) {
      try {
        document = dividerSafeDocument(jsonDecode(rejected.payload.json));
      } catch (_) {}
      final a = rejected.payload.accent;
      if (a != null && a.isNotEmpty) accent = a;
    }

    // запоминаем «эталон» до подмены документа, чтобы загрузка не считалась правкой
    final json = jsonEncode(document.toDelta().toJson());
    _lastSavedJson = json;
    _lastSeenJson = json;
    _lastLen = document.length;
    _accent = accent;

    _docIsDay = true;
    _setEditorDocument(document);
    _loadedKey = key;
    _setStatus('');
    _watchNote(key);
    if (rejected != null) {
      _lastSavedJson = _rejectedMark; // автосохранение повторит запись
      _setStatus(_saveErrorText(rejected.error));
    }
    // без сервера и без локальной копии этого дня — предупреждение
    _unknownDay.value = isUnknownDay(
        fromCache: fromCache,
        exists: doc?.exists ?? false,
        downloadComplete: _download.complete);

    // переход из поиска — выделить найденное
    final find = _pendingFind;
    _pendingFind = null;
    if (find != null && find.key == key) _selectFirstMatch(find.words);
  }

  /// Подменяет документ редактора и ставит курсор в начало.
  /// В вебе редактор на любое изменение забирает фокус клавиатуры; если
  /// поверх открыто окно (поиск, название темы…), фокус не забираем —
  /// иначе ввод из окна уйдёт в заметку.
  void _setEditorDocument(Document document) {
    final quiet = !(ModalRoute.of(context)?.isCurrent ?? true);
    _controller.skipRequestKeyboard = quiet;
    _controller.document = document;
    _controller.skipRequestKeyboard = quiet;
    _controller.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );
    _controller.skipRequestKeyboard = false;
  }

  /// Загружает то, что сейчас открыто: тему или день
  void _loadTarget() {
    final id = _openTopicId;
    if (id != null) {
      _loadTopic(id);
    } else {
      _loadNote(_selectedDay);
    }
  }

  Future<void> _loadTopic(String id) async {
    _loadingNow = true;
    try {
      await _loadTopicInner(id);
    } finally {
      _loadingNow = false;
    }
  }

  /// Загрузка темы в редактор. Без шаблонов дня: новая тема пустая.
  Future<void> _loadTopicInner(String id) async {
    final key = topicKey(id);
    _unwatchNote();
    _unknownDay.value = false;
    _loadedKey = null; // пока не загрузили — сохранять нельзя
    final seq = ++_loadSeq;
    if (_notes == null) return;

    TopicContent? content;
    try {
      content = await _topics.store.load(id);
    } on FirebaseException catch (e) {
      if (seq == _loadSeq) _setStatus('Не удалось загрузить (${e.code})');
      return;
    } catch (_) {
      if (seq == _loadSeq) _setStatus('Не удалось загрузить');
      return;
    }
    // пока грузилось, могли открыть другую тему или день
    if (!mounted || seq != _loadSeq || key != _targetKey) return;

    if (content == null) {
      // темы больше нет (удалена на другом устройстве) — вернуться к дню
      setState(() => _openTopicId = null);
      _topics.load();
      _loadNote(_selectedDay);
      return;
    }

    Document document;
    if (content.delta.isNotEmpty) {
      try {
        document = dividerSafeDocument(jsonDecode(content.delta));
      } catch (_) {
        document = Document()..insert(0, content.text);
      }
    } else {
      document = Document()..insert(0, content.text);
    }
    // запись темы отклонил сервер — показываем свой текст
    final rejected = _saves.rejected(key);
    if (rejected != null) {
      try {
        document = dividerSafeDocument(jsonDecode(rejected.payload.json));
      } catch (_) {}
    }

    final json = jsonEncode(document.toDelta().toJson());
    _lastSavedJson = json;
    _lastSeenJson = json;
    _lastLen = document.length;

    _docIsDay = false;
    _setEditorDocument(document);
    _loadedKey = key;
    _setStatus('');
    if (rejected != null) {
      _lastSavedJson = _rejectedMark; // автосохранение повторит запись
      _setStatus(_saveErrorText(rejected.error));
    }

    final find = _pendingFind;
    _pendingFind = null;
    if (find != null && find.key == key) {
      _selectFirstMatch(find.words, boilerplate: const {});
    }
  }

  void _autoSave() {
    if (_backupBusy) return; // во время копии/восстановления — ничего не пишем
    final key = _targetKey;
    if (_loadedKey != key) {
      // заметка так и не загрузилась (например, нет доступа) — пробуем снова
      if (!_loadingNow) _loadTarget();
      return;
    }
    if (_isDirty) _saveNote();
  }

  /// Сохранение открытой заметки. Запись ставится в очередь Firestore
  /// сразу (до первого await) — значит, правки уже на устройстве: смена дня
  /// может не ждать. Ответ сервера ждём не дольше пары секунд (без связи —
  /// «Сохранено на устройстве»); позднее подтверждение или отказ разбирает
  /// SaveTracker (_onSavesChanged / _onSaveRejected).
  Future<void> _saveNote() async {
    // сохраняем только то, что загружено в редактор, только туда же и
    // только если что-то изменили (нетронутый шаблон не пишем)
    final key = _targetKey;
    final json = _currentJson();
    if (!shouldSaveDay(
        loadedKey: _loadedKey,
        targetKey: key,
        currentJson: json,
        savedJson: _lastSavedJson)) {
      return;
    }
    final notes = _notes;
    if (notes == null) return;
    final topicId = topicIdOf(key);
    final plain = _controller.document.toPlainText().replaceAll('\uFFFC', '');
    final accent = _accent;
    _setStatus(kStatusSaving);
    Future<void> write;
    try {
      write = topicId != null
          ? _topics.store.saveContent(topicId, json, plain)
          : notes.doc(key).set({
              'delta': json,
              'text': plain,
              'accent': accent,
              'updatedAt': FieldValue.serverTimestamp(),
            });
    } catch (e) {
      _setStatus(_saveErrorText(e));
      return;
    }
    // запись в очереди (в локальной копии): эти правки уже сохранены
    _lastSavedJson = json;
    if (topicId != null) {
      _topics.touch(topicId);
      _searchCache.putTopicText(topicId, plain);
    } else {
      _searchCache.put(key, plain);
    }
    final out = await _saves.track(key, write,
        SavePayload(json: json, text: plain, accent: topicId == null ? accent : null));
    // пока ждали, открыли другое — статус того не трогаем
    if (!mounted || key != _targetKey || _loadedKey != key) return;
    if (out == SaveOutcome.acked) _setStatus(kStatusSaved);
    if (out == SaveOutcome.queued) _setStatus(kStatusQueued);
    // SaveOutcome.failed: статус и «несохранённость» — в _onSaveRejected
  }

  Future<void> _onDaySelected(DateTime selectedDay, DateTime focusedDay) async {
    if (_backupBusy) return; // идёт копия/восстановление
    // не теряем несохранённые правки предыдущего дня; перенос задачи
    // должен отметить задачу в этой же заметке — ждём и его
    while (_taskBusy) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    // запись уходит в очередь сразу; ответ сервера не ждём (без связи
    // его может долго не быть)
    if (_loadedKey == _targetKey && _isDirty) unawaited(_saveNote());
    if (!mounted) return;
    setState(() {
      _selectedDay = selectedDay;
      _focusedDay = focusedDay;
      _openTopicId = null; // клик по дню возвращает заметку дня
    });
    _status.value = '';
    _loadNote(selectedDay);
  }

  /// Уже открыт сегодняшний день и виден текущий месяц
  bool get _onToday => isOnToday(
        selected: _selectedDay,
        focused: _focusedDay,
        now: DateTime.now(),
        topicOpen: _openTopicId != null,
        monthPickerOpen: _showMonths,
      );

  /// Кнопка «Сегодня»: как клик по сегодняшнему дню в календаре
  /// (сохранение текущей заметки — внутри _onDaySelected), плюс сетка
  /// переходит на текущий месяц. «Сегодня» — по часам в момент нажатия.
  Future<void> _goToToday() async {
    if (_backupBusy || _goingToday || _onToday) return;
    final today = localDate(DateTime.now());
    if (_openTopicId == null && isSameDay(_selectedDay, today)) {
      // сегодняшняя заметка уже открыта — только вернуть сетку, без перезагрузки
      setState(() {
        _focusedDay = today;
        _showMonths = false;
      });
      return;
    }
    _goingToday = true; // повторное нажатие, пока ждём сохранение, — без эффекта
    try {
      setState(() => _showMonths = false);
      await _onDaySelected(today, today);
    } finally {
      _goingToday = false;
    }
  }

  bool _goingToday = false;

  // ---------- работа без сети (логика — offline.dart) ----------

  /// Личный словарь: users/{uid}/settings/dictionary
  DocumentReference<Map<String, dynamic>>? get _dictionaryRef =>
      _userRef?.collection('settings').doc('dictionary');

  void _onDictionaryError(String message) {
    if (!mounted || _signingOut) return;
    _setStatus(message);
  }

  void _onDictionaryLateError(Object e) => _onDictionaryError(
      'Ошибка сохранения словаря${e is FirebaseException ? ' (${e.code})' : ''}');

  bool _spellFailedShown = false;

  /// Словари не загрузились — проверка тихо выключается (одно сообщение)
  void _onSpellFailed() {
    if (!mounted || _spellFailedShown) return;
    _spellFailedShown = true;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Проверка правописания сейчас недоступна')));
  }

  /// users/{uid} вошедшего пользователя (null — нет входа)
  DocumentReference<Map<String, dynamic>>? get _userRef {
    final user = FirebaseAuth.instance.currentUser;
    if (_signingOut || user == null || user.uid != widget.uid) return null;
    return _db.collection('users').doc(user.uid);
  }

  /// Постоянная подписка на маленький документ (настройки шаблонов):
  /// снимок «из кэша» — связи с сервером нет
  void _watchConnection() {
    final ref = _templatesRef;
    if (ref == null) return;
    _connSub = ref.snapshots(includeMetadataChanges: true).listen(
          (s) => _conn.storeChanged(s.metadata.isFromCache),
          onError: (_) {},
        );
  }

  /// Связь вернулась: очередь записей Firestore уходит сама; здесь —
  /// фоновая копия и то, что не загрузилось без сети
  void _onReconnect() {
    if (!mounted || _signingOut) return;
    _download.onReconnect();
    if (_searchFromCache) {
      _searchCache.invalidate();
      _searchFromCache = false;
    }
    if (!_templatesLoaded) _templatesLoading = _loadTemplateSettings();
    if (_topics.error != null) _topics.load();
  }

  void _onSavesChanged() {
    if (!mounted) return;
    // очередь ушла на сервер
    if (!_saves.hasPending && _status.value == kStatusQueued) {
      _setStatus(kStatusSaved);
    }
    // копия только в памяти вкладки: закрытие вкладки потеряло бы очередь
    setLeaveGuard(offlineCacheLimited && _saves.hasUnsynced);
  }

  String _saveErrorText(Object e) => e is FirebaseException
      ? 'Ошибка сохранения (${e.code})'
      : 'Ошибка сохранения';

  /// Сервер отклонил запись (сразу или когда появилась связь). Firestore
  /// убирает её из локальной копии; текст не теряем.
  void _onSaveRejected(String key, RejectedSave r) {
    if (!mounted || _signingOut) return;
    final topicId = topicIdOf(key);
    if (topicId != null && _topics.byId(topicId) == null) {
      _saves.forget(key); // тему удалили — её текст не нужен
      return;
    }
    final msg = _saveErrorText(r.error);
    if (_loadedKey == key && _targetKey == key) {
      // в редакторе свой текст; «несохранённый» — автосохранение повторит
      _lastSavedJson = _rejectedMark;
      _setStatus(msg);
      return;
    }
    // заметка уже закрыта: текст в памяти, покажем его при открытии
    final where = topicId != null
        ? 'тема «${_topics.byId(topicId)?.title ?? ''}»'
        : formatRuDate(key);
    _setStatus('$msg: $where');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text('$msg: $where. Текст не потерян — откройте '
          '${topicId != null ? 'тему' : 'этот день'}, и он сохранится снова.'),
    ));
  }

  void _onTopicLateError(String what, Object e) {
    if (!mounted || _signingOut) return;
    _topicError(what, e);
    _topics.load();
  }

  void _onTemplatesLateError(Object e) {
    if (!mounted || _signingOut) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Шаблоны не сохранены на сервере: ${describeError(e)}')));
    _templatesLoaded = false;
    _templatesLoading = _loadTemplateSettings();
  }

  /// Строка статуса: подсказки о работе без сети и статус сохранения
  Widget _statusRow() => ListenableBuilder(
        listenable: Listenable.merge([_conn, _download]),
        builder: (context, _) {
          final progress = _download.progressText;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (progress != null) ...[
                Text(progress,
                    style:
                        const TextStyle(color: kTextSecondary, fontSize: 12)),
                const SizedBox(width: 10),
              ],
              if (offlineCacheLimited) ...[
                const Tooltip(
                  message: kCacheLimitedHint,
                  child: Text('Офлайн-защита ограничена',
                      style: TextStyle(color: kTextSecondary, fontSize: 12)),
                ),
                const SizedBox(width: 10),
              ],
              if (_conn.offline) ...[
                const _OfflineChip(),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: ValueListenableBuilder<String>(
                  valueListenable: _status,
                  builder: (context, status, _) {
                    Color color = kTextSecondary;
                    if (status == kStatusSaved) color = kAccent;
                    if (status.startsWith('Ошибка') ||
                        status.startsWith('Не удалось')) {
                      color = const Color(0xFFFF5C5C);
                    }
                    return Text(status,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: color, fontSize: 13));
                  },
                ),
              ),
            ],
          );
        },
      );

  // ---------- этот же день изменили в другой вкладке ----------
  // Например, в соседней вкладке перенесли задачу на открытый здесь день.
  // Изменение из базы вливается в редактор поверх своих несохранённых
  // правок (как при совместном редактировании), без перезагрузки.

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _noteSub;
  String? _noteSubKey;

  void _watchNote(String key) {
    if (_noteSubKey == key && _noteSub != null) return;
    _unwatchNote();
    final notes = _notes;
    if (notes == null) return;
    _noteSubKey = key;
    // с изменениями метаданных: ответ сервера после связи приходит и
    // тогда, когда содержимое не изменилось (снимает предупреждение
    // «неизвестный день»)
    _noteSub = notes.doc(key).snapshots(includeMetadataChanges: true).listen(
          (snap) {
            if (!snap.metadata.isFromCache && key == _loadedKey) {
              _unknownDay.value = false;
            }
            _onRemoteNote(key, snap);
          },
          onError: (_) {}, // нет доступа — просто не следим
        );
  }

  void _unwatchNote() {
    _noteSub?.cancel();
    _noteSub = null;
    _noteSubKey = null;
  }

  void _onRemoteNote(
      String key, DocumentSnapshot<Map<String, dynamic>> snap) {
    if (!mounted || _signingOut || snap.metadata.hasPendingWrites) return;
    if (_loadedKey != key || _targetKey != key || !_docIsDay) return;
    // своя запись ещё не подтверждена или отклонена: снимок из базы может
    // быть откатом — он не должен стереть текст в редакторе
    if (_saves.isUnsettled(key)) return;
    final data = snap.data();
    final rawJson = data?['delta'];
    if (data == null || rawJson is! String || rawJson.isEmpty) return;
    // строки разделителей — как после загрузки в редактор (иначе старая
    // испорченная заметка в базе выглядела бы «чужим изменением»)
    final remoteJson = normalizeDividerJson(rawJson);
    if (remoteJson == _lastSavedJson) return;
    if (remoteJson == _currentJson()) {
      _lastSavedJson = remoteJson;
      return;
    }
    try {
      final change = rebaseRemoteChange(
        base: Delta.fromJson(jsonDecode(_lastSavedJson) as List),
        local: _controller.document.toDelta(),
        remote: Delta.fromJson(jsonDecode(remoteJson) as List),
      );
      if (change.isNotEmpty) {
        // чужое изменение не должно забирать фокус (например, из поиска)
        _controller.skipRequestKeyboard = true;
        _controller.compose(change, _controller.selection, ChangeSource.remote);
        _controller.skipRequestKeyboard = false;
        // Ctrl+Z не должен отменять чужое изменение
        _controller.document.history.clear();
      }
    } catch (_) {
      if (_isDirty) {
        _setStatus('Заметка изменена в другой вкладке — откройте день заново');
        return;
      }
      // своих правок нет — просто показываем то, что в базе
      try {
        final doc = dividerSafeDocument(jsonDecode(remoteJson));
        final sel = _controller.selection;
        _controller.document = doc;
        _controller.updateSelection(
          TextSelection.collapsed(
              offset: sel.baseOffset.clamp(0, doc.length - 1)),
          ChangeSource.local,
        );
      } catch (_) {
        return;
      }
    }
    // в базе теперь remoteJson; свои несохранённые правки (если были)
    // остаются «несохранёнными» и уйдут следующим автосохранением
    _lastSavedJson = remoteJson;
    _lastSeenJson = _currentJson();
    _lastLen = _controller.document.length;
    final accent = data['accent'];
    if (accent is String && accent.isNotEmpty) _accent = accent;
    _searchCache.put(key, (data['text'] ?? '').toString());
    _setStatus('Обновлено из другой вкладки');
  }

  // ---------- задачи: кнопки ✗ / ✓ (см. tasks.dart) ----------

  /// В редакторе — заметка дня (не тема): только в ней работают задачи
  bool _docIsDay = false;

  /// Идёт перенос (или отмена переноса) задачи. Смена дня, тема, выход и
  /// резервная копия ждут его, как ждут сохранения: отметка должна попасть
  /// в ту же заметку, откуда нажали.
  bool _taskBusy = false;
  late final TaskCarrier _taskCarrier =
      TaskCarrier(FirestoreTaskNoteStore(() => _notes));

  @override
  TaskMode get _taskMode => _docIsDay ? TaskMode.interactive : TaskMode.off;

  @override
  Listenable? get _taskNetwork => _conn;

  @override
  bool get _taskOffline => _offline;

  /// Перенос — транзакция: дольше ждать нельзя (смена дня ждёт переноса)
  static const Duration _taskNetWait = Duration(seconds: 20);

  @override
  DateTime? get _taskNoteDate {
    final key = _loadedKey;
    return _docIsDay && key != null ? parseDayKey(key) : null;
  }

  bool _inDocument(Node node, Document doc) {
    Node n = node;
    while (n.parent != null) {
      n = n.parent!;
    }
    return identical(n, doc.root);
  }

  @override
  Future<void> _onTaskControl(
      Line line, TaskControl control, BuildContext anchor) async {
    if (_taskBusy || _backupBusy || _signingOut || !_docIsDay) return;
    // где нажали — рядом покажем окошко (запоминаем сразу: после ожидания
    // строка могла перерисоваться)
    final anchorBox = anchor.findRenderObject();
    final at = anchorBox is RenderBox && anchorBox.hasSize
        ? anchorBox.localToGlobal(Offset.zero) & anchorBox.size
        : null;
    final key = _loadedKey;
    if (key == null || key != _targetKey || _openTopicId != null) return;
    final noteDate = parseDayKey(key);
    if (noteDate == null) return;
    final doc = _controller.document;
    final lines = docLines(doc);
    final li = lines.indexWhere((l) => identical(l.node, line));
    if (li < 0) return;
    final info = TaskIndex.build(doc, TaskMode.interactive).byLine[line];
    if (info == null || info.kind != TaskLineKind.task) return;
    final from = info.value;
    final step = taskStep(from.state, control);
    final group = taskGroupAt(opsToLines(doc.toDelta().toJson()), li);
    if (group == null) return;
    // перенос и отмена переноса — транзакции, без сети не работают
    if (taskStepNeedsNetwork(step) && _offline) {
      _showTaskPopup(kTaskNeedNetwork, at);
      return;
    }

    // ✓ / снять ✓ — просто смена состояния (обычное сохранение)
    if (!step.carry && !step.uncarry) {
      _setTaskState(doc, line,
          step.to == TaskState.done ? TaskValue.done : TaskValue.open);
      return;
    }
    if (step.carry && group.isBlank) {
      _showTaskPopup('Пустую задачу нельзя перенести', at);
      return;
    }

    _taskBusy = true;
    _taskBusyLine.value = line;
    var message = '';
    try {
      // сначала другой день, потом отметка здесь: при ошибке задача
      // остаётся как была
      if (step.uncarry) {
        final targetKey = from.target!;
        final label = formatTaskDate(parseDayKey(targetKey)!);
        final out = await _taskCarrier
            .uncarry(targetKey: targetKey, group: group, label: label)
            .timeout(_taskNetWait);
        if (out == UncarryOutcome.removed) _searchCache.invalidate();
        if (out == UncarryOutcome.modified) {
          message = 'Задача на $label уже изменена и оставлена там';
        } else if (!step.carry && step.to == TaskState.open) {
          message = 'Перенос отменён';
        }
      }
      var next = step.to == TaskState.done ? TaskValue.done : TaskValue.open;
      if (step.carry) {
        final target = nextWorkingDay(noteDate, _isWorkday);
        final targetKey = dayKeyOf(target);
        final label = formatTaskDate(target);
        final settings = await _templateSettingsForDay();
        final (built, accent) = _composeDay(target, _pickAccent(), settings);
        await _taskCarrier.carry(
          targetKey: targetKey,
          group: group,
          emptyNote: TemplateComposition([
            for (final op in built.toDelta().toJson())
              Map<String, dynamic>.from(op as Map),
          ], accent),
          label: label,
        ).timeout(_taskNetWait);
        _searchCache.invalidate();
        next = TaskValue.carried(targetKey);
        message = carriedLabel(noteDate, target);
      }
      // смена дня ждёт переноса, так что заметка та же; строку могли удалить
      if (!mounted ||
          _loadedKey != key ||
          !identical(_controller.document, doc) ||
          !_inDocument(line, doc)) {
        _taskNotice('${message.isEmpty ? 'Перенос отменён' : message}'
            ' — строка задачи изменилась, отметка не поставлена');
        return;
      }
      _setTaskState(doc, line, next);
      _showTaskPopup(message, at);
      _autoSave();
    } on TaskCarryError catch (e) {
      _taskError(e.message);
    } on FirebaseException catch (e) {
      _taskError(step.carry
          ? 'Не удалось перенести задачу (${e.code})'
          : 'Не удалось отменить перенос (${e.code})');
    } catch (_) {
      _taskError(step.carry
          ? 'Не удалось перенести задачу'
          : 'Не удалось отменить перенос');
    } finally {
      _taskBusy = false;
      _taskBusyLine.value = null;
    }
  }

  /// Короткое сообщение о переносе (строку статуса сразу перепишет
  /// автосохранение, поэтому — всплывающее сообщение)
  void _taskNotice(String message) {
    if (!mounted || message.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  OverlayEntry? _taskPopup;
  Timer? _taskPopupTimer;

  /// Небольшое окошко рядом с кнопками задачи ([at] — где они на экране);
  /// само исчезает через пару секунд
  void _showTaskPopup(String text, Rect? at) {
    if (!mounted || text.isEmpty) return;
    final overlay = Overlay.maybeOf(context);
    final box = overlay?.context.findRenderObject();
    if (at == null || overlay == null || box is! RenderBox) {
      _taskNotice(text);
      return;
    }
    _hideTaskPopup();
    final p = box.globalToLocal(at.topLeft);
    // над кнопками; если места сверху нет — под ними
    final top = p.dy - 30 < 4 ? p.dy + at.height + 4 : p.dy - 30;
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        left: p.dx,
        top: top,
        child: IgnorePointer(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 150),
            builder: (_, v, child) => Opacity(opacity: v, child: child),
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: kCard,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kDivider),
                  boxShadow: const [
                    BoxShadow(color: Color(0x66000000), blurRadius: 8),
                  ],
                ),
                child: Text(
                  text,
                  style: const TextStyle(color: kTextPrimary, fontSize: 12),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    _taskPopup = entry;
    _taskPopupTimer =
        Timer(const Duration(milliseconds: 2200), _hideTaskPopup);
  }

  void _hideTaskPopup() {
    _taskPopupTimer?.cancel();
    _taskPopupTimer = null;
    final e = _taskPopup;
    _taskPopup = null;
    if (e != null && e.mounted) e.remove();
  }

  /// Ошибка переноса: и в строке статуса, и всплывающим сообщением.
  /// Задача при этом остаётся как была.
  void _taskError(String message) {
    _setStatus(message);
    _taskNotice(message);
  }

  /// Состояние задачи — атрибут строки; это обычная правка документа
  /// (сохранится автосохранением), но не шаг Ctrl+Z: иначе отмена
  /// разошлась бы с уже перенесённой копией.
  void _setTaskState(Document doc, Line line, TaskValue value) {
    for (final l in docLines(doc)) {
      if (identical(l.node, line)) {
        _composeQuiet(taskStateDelta(l, value));
        return;
      }
    }
  }

  // ---------- темы ----------

  // ---------- шаблоны дня ----------

  /// Настройки шаблонов вошедшего пользователя: users/{uid}/settings/templates
  DocumentReference<Map<String, dynamic>>? get _templatesRef {
    final user = FirebaseAuth.instance.currentUser;
    if (_signingOut || user == null || user.uid != widget.uid) return null;
    return _db
        .collection('users')
        .doc(user.uid)
        .collection('settings')
        .doc('templates');
  }

  /// Загрузка настроек. Ошибка — тихо остаёмся на стандартных шаблонах.
  Future<void> _loadTemplateSettings() async {
    try {
      final s = await _templateStore.load();
      _templateSettings = s;
      _templatesLoaded = true;
    } catch (_) {
      // нет связи / нет доступа — работаем со стандартными шаблонами
    }
  }

  /// Настройки для нового пустого дня: ждём загрузку не дольше 5 секунд,
  /// иначе — стандартные шаблоны (открытие дня не блокируется)
  Future<TemplateSettings> _templateSettingsForDay() async {
    final loading = _templatesLoading;
    if (!_templatesLoaded && loading != null) {
      try {
        await loading.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    return _templateSettings;
  }

  Future<void> _openTemplates() async {
    if (_backupBusy || _templatesRef == null) return;
    // без загруженных настроек сохранение затёрло бы чужие изменения —
    // сначала пробуем загрузить ещё раз
    if (!_templatesLoaded) {
      _templatesLoading = _loadTemplateSettings();
      try {
        await _templatesLoading!.timeout(const Duration(seconds: 15));
      } catch (_) {}
      if (!mounted) return;
      if (!_templatesLoaded) {
        await _showMessage('Шаблоны недоступны',
            'Не удалось загрузить настройки шаблонов. Проверьте интернет и '
                'попробуйте снова.',
            error: true);
        return;
      }
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TemplatesDialog(
        initial: _templateSettings,
        store: _templateStore,
        spell: _spell,
        // новые шаблоны — для следующих пустых дней, без перезагрузки;
        // уже открытый день не трогаем
        onSaved: (s) => _templateSettings = s,
      ),
    );
  }

  /// Коллекция тем вошедшего пользователя: users/{uid}/topics
  CollectionReference<Map<String, dynamic>>? get _topicsRef {
    final user = FirebaseAuth.instance.currentUser;
    if (_signingOut || user == null || user.uid != widget.uid) return null;
    return _db.collection('users').doc(user.uid).collection('topics');
  }

  /// Открыть тему в центре (так же, как переход на другой день:
  /// дождаться сохранения и сохранить текущие правки)
  Future<void> _openTopic(String id) async {
    if (_backupBusy) return;
    while (_taskBusy) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    // как при смене дня: запись в очереди сразу, сервер не ждём
    if (_loadedKey == _targetKey && _isDirty) unawaited(_saveNote());
    if (!mounted) return;
    setState(() => _openTopicId = id);
    _status.value = '';
    _loadTopic(id);
  }

  Future<void> _createTopic() async {
    if (_backupBusy || _notes == null) return;
    Topic topic;
    try {
      topic = await _topics.create();
    } catch (e) {
      _topicError('Не удалось создать тему', e);
      return;
    }
    await _openTopic(topic.id);
    if (!mounted) return;
    await _renameTopic(topic.id, heading: 'Новая тема');
  }

  Future<void> _renameTopic(String id, {String heading = 'Переименовать тему'}) async {
    final t = _topics.byId(id);
    if (t == null) return;
    final title =
        await showTopicTitleDialog(context, initial: t.title, heading: heading);
    if (title == null || !mounted) return;
    try {
      await _topics.rename(id, title);
    } catch (e) {
      _topicError('Не удалось переименовать тему', e);
    }
  }

  Future<void> _deleteTopic(String id) async {
    final t = _topics.byId(id);
    if (t == null || _backupBusy) return;
    if (!await confirmTopicDelete(context, t.title) || !mounted) return;
    if (_openTopicId == id) {
      // несохранённые правки удаляемой темы не нужны: сразу возвращаемся
      // к дню (с этого момента тема не сохраняется — ключ цели другой)
      setState(() => _openTopicId = null);
      _status.value = '';
      _loadNote(_selectedDay);
    }
    // записи уходят на сервер по порядку: сохранение темы (если было) —
    // раньше удаления; её отклонённый текст больше не нужен
    _saves.forget(topicKey(id));
    if (!mounted) return;
    try {
      await _topics.delete(id);
      _searchCache.removeTopic(id);
    } catch (e) {
      _topicError('Не удалось удалить тему', e);
    }
  }

  void _topicError(String what, Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what: ${describeError(e)}')),
    );
  }

  /// Название открытой темы в шапке; щелчок — переименовать
  Widget _topicHeader(String id) => ListenableBuilder(
        listenable: _topics,
        builder: (context, _) => _topicHeaderBody(id),
      );

  Widget _topicHeaderBody(String id) {
    final title = _topics.byId(id)?.title ?? '';
    return Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: 'Переименовать',
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _renameTopic(id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.topic_outlined, size: 18, color: kAccent),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kAccentLight,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
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

  /// Левая колонка: календарь, под ним темы на всю оставшуюся высоту
  /// (не меньше 260). Если места мало — колонка прокручивается целиком.
  Widget _leftColumn() => CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _calendarPanel()),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          SliverLayoutBuilder(
            builder: (context, c) => SliverToBoxAdapter(
              child: SizedBox(
                height: max(
                    260.0, c.viewportMainAxisExtent - c.precedingScrollExtent),
                child: _topicsPanel(),
              ),
            ),
          ),
        ],
      );

  Widget _topicsPanel() => TopicsPanel(
        controller: _topics,
        selectedId: _openTopicId,
        enabled: !_backupBusy,
        onOpen: (id) {
          if (id != _openTopicId) _openTopic(id);
        },
        onCreate: _createTopic,
        onRename: _renameTopic,
        onDelete: _deleteTopic,
      );

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
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: TodayButton(subdued: _onToday, onPressed: _goToToday),
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
      onPageChanged: (d) => setState(() => _focusedDay = d),
      // клик по названию месяца — показать все месяцы года
      onHeaderTapped: (_) => setState(() {
        _pickerYear = _focusedDay.year;
        _showMonths = true;
      }),
      calendarBuilders: CalendarBuilders(
        // открыта тема — день, к которому вернёмся, виден приглушённо
        selectedBuilder: selectedDayBuilder(topicOpen: _openTopicId != null),
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
      calendarStyle: kCalendarStyle,
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
              ToolbarToggleButton(
                visible: _toolbarVisible,
                onPressed: _toggleToolbar,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _openTopicId != null
                    ? _topicHeader(_openTopicId!)
                    : Text(
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
          // панель форматирования — по кнопке в шапке (по умолчанию скрыта)
          CollapsibleToolbar(
            visible: _toolbarVisible,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kDivider),
              ),
              child: _toolbar(),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _unknownDay,
            builder: (context, unknown, _) => unknown && _openTopicId == null
                ? const _UnknownDayBanner()
                : const SizedBox.shrink(),
          ),
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
                  // Builder: стили редактора берутся из контекста под Material
                  Builder(
                    builder: (editorContext) => _withFormatMenu(
                        QuillEditor(
                          controller: _controller,
                          focusNode: _editorFocus,
                          scrollController: _editorScroll,
                          config: _editorConfig(
                              _openTopicId != null
                                  ? 'Заметки по теме...'
                                  : 'Что важного в этот день...',
                              editorContext),
                        ),
                        _editorScroll),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: _statusRow(),
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
                                    child: _leftColumn(),
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
                  SizedBox(height: 300, child: _topicsPanel()),
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

/// Оформление дней календаря (сегодня, выбранный, выходные)
const CalendarStyle kCalendarStyle = CalendarStyle(
  cellMargin: EdgeInsets.all(4),
  defaultTextStyle: TextStyle(color: kTextPrimary),
  weekendTextStyle: TextStyle(color: kTextSecondary),
  outsideTextStyle: TextStyle(color: Color(0xFF55526A)),
  todayTextStyle: TextStyle(color: kAccentLight, fontWeight: FontWeight.bold),
  selectedTextStyle:
      TextStyle(color: kBackground, fontWeight: FontWeight.bold),
  todayDecoration:
      BoxDecoration(color: Colors.transparent, shape: BoxShape.circle),
  selectedDecoration: BoxDecoration(color: kAccent, shape: BoxShape.circle),
);

/// Заливка выбранного дня, пока открыта тема: тот же цвет, что у яркого
/// выделения, но на 40 %
const Color kMutedSelection = Color(0x669C8FCB);

/// Ячейка выбранного дня: открыта тема — приглушённая заливка (свой
/// виджет, без анимации — без кадра яркого круга); открыт день — null,
/// обычное яркое выделение календаря
FocusedDayBuilder? selectedDayBuilder({
  required bool topicOpen,
  DateTime Function() now = DateTime.now,
}) {
  if (!topicOpen) return null;
  return (context, day, focusedDay) =>
      MutedSelectedDay(day: day, isToday: isSameDay(day, now()));
}

/// Выбранный день, пока открыта тема. Сегодняшний день сохраняет свою
/// отметку (сиреневый жирный номер) поверх заливки.
class MutedSelectedDay extends StatelessWidget {
  const MutedSelectedDay({super.key, required this.day, required this.isToday});

  final DateTime day;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: kCalendarStyle.cellMargin,
      padding: kCalendarStyle.cellPadding,
      alignment: kCalendarStyle.cellAlignment,
      decoration: const BoxDecoration(
          color: kMutedSelection, shape: BoxShape.circle),
      child: Text(
        '${day.day}',
        style: isToday
            ? kCalendarStyle.todayTextStyle
            : const TextStyle(color: kTextPrimary, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Кнопка «Сегодня» под календарём. [subdued] — уже открыт сегодняшний
/// день: кнопка приглушена, но нажимается (ничего не произойдёт).
class TodayButton extends StatelessWidget {
  const TodayButton({super.key, required this.subdued, required this.onPressed});

  final bool subdued;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = subdued ? kTextSecondary : kAccentLight;
    return Tooltip(
      message: 'Перейти на сегодня',
      child: Semantics(
        button: true,
        label: 'Перейти на сегодня',
        excludeSemantics: true,
        child: SizedBox(
          width: double.infinity,
          height: 36,
          child: TextButton.icon(
            onPressed: onPressed,
            icon: Icon(Icons.today_outlined, size: 18, color: color),
            label: Text(
              'Сегодня',
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: subdued ? FontWeight.w500 : FontWeight.w600,
              ),
            ),
            style: TextButton.styleFrom(
              backgroundColor: subdued ? Colors.transparent : kCard,
              foregroundColor: color,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: kDivider),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Значок «Офлайн» рядом со статусом сохранения
class _OfflineChip extends StatelessWidget {
  const _OfflineChip();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Нет связи с сервером. Правки сохраняются на устройстве и '
          'уйдут сами, когда сеть вернётся.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kDivider),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 13, color: kAccentLight),
            SizedBox(width: 5),
            Text(kOfflineChip,
                style: TextStyle(color: kAccentLight, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Предупреждение над редактором: этого дня нет на устройстве
class _UnknownDayBanner extends StatelessWidget {
  const _UnknownDayBanner();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0x1AFFD54A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x66FFD54A)),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 17, color: Color(0xFFFFD54A)),
            SizedBox(width: 9),
            Expanded(
              child: Text(kUnknownDayWarning,
                  style: TextStyle(color: kTextPrimary, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}
