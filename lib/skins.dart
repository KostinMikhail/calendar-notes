// Оформление (skin): шесть тёмных цветовых схем со своими картинками и
// котом. В интерфейсе — «Оформление»; слово «тема» занято разделом «Темы».
// Значения — из themes.json (в корне проекта), вшиты константами.
import 'dart:async';

import 'package:flutter/material.dart';

import 'format_menu.dart' show LocalPrefStore, PrefStore;
import 'offline_web_stub.dart' if (dart.library.js_interop) 'offline_web.dart'
    as web;

@immutable
class AppSkin {
  const AppSkin({
    required this.id,
    required this.title,
    required this.catName,
    required this.background,
    required this.surface,
    required this.card,
    required this.accent,
    required this.accentLight,
    required this.textPrimary,
    required this.textSecondary,
    required this.divider,
    required this.subtle,
    required this.muted,
    this.onSurface,
  });

  final String id;
  final String title;
  final String catName;

  final Color background;
  final Color surface;
  final Color card;
  final Color accent;
  final Color accentLight;
  final Color textPrimary;
  final Color textSecondary;
  final Color divider;

  /// Тонкие линии (разделитель в заметке)
  final Color subtle;

  /// Приглушённый текст (дни соседнего месяца)
  final Color muted;

  /// Цвет основного текста Material (текст заметки). null — [textPrimary].
  /// У «Фиолетовой ночи» — как было всегда (белый из ColorScheme.dark).
  final Color? onSurface;

  Color get editorText => onSurface ?? textPrimary;

  String get banner => 'assets/images/themes/$id/banner.png';
  String get emptyDay => 'assets/images/themes/$id/empty_day.png';

  /// Значок вкладки (web/favicons)
  String get favicon => 'favicons/$id.png';
}

/// Шесть встроенных оформлений; первое — по умолчанию (прежний вид)
const List<AppSkin> kSkins = [
  AppSkin(
    id: 'violet',
    title: 'Фиолетовая ночь',
    catName: 'Лазерный кот',
    background: Color(0xFF0E0D13),
    surface: Color(0xFF15141C),
    card: Color(0xFF1C1A25),
    accent: Color(0xFF9C8FCB),
    accentLight: Color(0xFFC9BCE6),
    textPrimary: Color(0xFFECEAF2),
    textSecondary: Color(0xFF8D8A9C),
    divider: Color(0xFF292734),
    subtle: Color(0xFF34313F),
    muted: Color(0xFF55526A),
    onSurface: Colors.white,
  ),
  AppSkin(
    id: 'aurora',
    title: 'Полярное сияние',
    catName: 'Кот-космонавт',
    background: Color(0xFF091112),
    surface: Color(0xFF0E1819),
    card: Color(0xFF142124),
    accent: Color(0xFF74D6B6),
    accentLight: Color(0xFFB8F2DA),
    textPrimary: Color(0xFFE7F9ED),
    textSecondary: Color(0xFF7FB5A8),
    divider: Color(0xFF163333),
    subtle: Color(0xFF183838),
    muted: Color(0xFF37887A),
  ),
  AppSkin(
    id: 'mars',
    title: 'Марсианский закат',
    catName: 'Сонный кот на луне',
    background: Color(0xFF130D0B),
    surface: Color(0xFF1B1210),
    card: Color(0xFF251915),
    accent: Color(0xFFE59B5B),
    accentLight: Color(0xFFF5C791),
    textPrimary: Color(0xFFFDEAD7),
    textSecondary: Color(0xFFBD9476),
    divider: Color(0xFF422318),
    subtle: Color(0xFF46271B),
    muted: Color(0xFFA55E36),
  ),
  AppSkin(
    id: 'blue',
    title: 'Глубокий синий',
    catName: 'Кибер-кот',
    background: Color(0xFF080C15),
    surface: Color(0xFF0D1320),
    card: Color(0xFF131B2B),
    accent: Color(0xFF8EBEEC),
    accentLight: Color(0xFFC7E2F9),
    textPrimary: Color(0xFFE9F4FE),
    textSecondary: Color(0xFF8DA8C5),
    divider: Color(0xFF172944),
    subtle: Color(0xFF1B304D),
    muted: Color(0xFF4777AD),
  ),
  AppSkin(
    id: 'nebula',
    title: 'Розовая туманность',
    catName: 'Кот-звезда',
    background: Color(0xFF120A11),
    surface: Color(0xFF1A101A),
    card: Color(0xFF241723),
    accent: Color(0xFFE292D0),
    accentLight: Color(0xFFF6C8EB),
    textPrimary: Color(0xFFFDE9F2),
    textSecondary: Color(0xFFBB8FB6),
    divider: Color(0xFF3E1C3D),
    subtle: Color(0xFF432140),
    muted: Color(0xFF9F5096),
  ),
  AppSkin(
    id: 'graphite',
    title: 'Графит и янтарь',
    catName: 'Кот-пилот',
    background: Color(0xFF0E0E0F),
    surface: Color(0xFF151516),
    card: Color(0xFF1D1D1F),
    accent: Color(0xFFAAAAAF),
    accentLight: Color(0xFFD5D5D9),
    textPrimary: Color(0xFFF3EEE2),
    textSecondary: Color(0xFF9C9CA4),
    divider: Color(0xFF2A2A2C),
    subtle: Color(0xFF2D2D30),
    muted: Color(0xFF68686D),
  ),
];

const String kDefaultSkinId = 'violet';

/// Оформление по id; неизвестное — по умолчанию
AppSkin skinById(String? id) =>
    kSkins.firstWhere((s) => s.id == id, orElse: () => kSkins.first);

/// Выбранное оформление на этом устройстве (localStorage)
class SkinPref {
  const SkinPref([this.store = const LocalPrefStore()]);
  final PrefStore store;

  static const String storageKey = 'calendar_skin';

  AppSkin load() {
    try {
      return skinById(store.read(storageKey));
    } catch (_) {
      return kSkins.first;
    }
  }

  void save(AppSkin skin) {
    try {
      store.write(storageKey, skin.id);
    } catch (_) {}
  }
}

/// Текущее оформление
final ValueNotifier<AppSkin> currentSkin = ValueNotifier<AppSkin>(kSkins.first);

/// До runApp: сохранённое оформление (без мелькания чужих цветов)
void initSkin([SkinPref pref = const SkinPref()]) {
  currentSkin.value = pref.load();
  _applyBrowserChrome(currentSkin.value);
}

/// Сменить оформление сразу, без перезагрузки и без пересоздания
/// состояния (заметка, курсор, таймеры, открытые окна — как были)
void setSkin(AppSkin skin, [SkinPref pref = const SkinPref()]) {
  if (identical(skin, currentSkin.value)) return;
  currentSkin.value = skin;
  pref.save(skin);
  _applyBrowserChrome(skin);
  rebuildAllWidgets();
}

/// Значок вкладки, цвет вкладки и фон страницы
void _applyBrowserChrome(AppSkin skin) =>
    web.setBrowserChrome(favicon: skin.favicon, color: cssColor(skin.background));

/// #RRGGBB
String cssColor(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// Перерисовать все виджеты: цвета берутся из текущего оформления в build.
/// Состояния (State) не пересоздаются — только заново вызывается build.
void rebuildAllWidgets() {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return;
  void visit(Element e) {
    e.markNeedsBuild();
    e.visitChildren(visit);
  }

  root.visitChildren(visit);
}

/// Тема Material для оформления — тот же набор, что был в MyApp
ThemeData skinTheme(AppSkin s) => ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: s.background,
      colorScheme: ColorScheme.dark(
        primary: s.accent,
        secondary: s.accentLight,
        surface: s.surface,
        onSurface: s.editorText,
      ),
      useMaterial3: true,
      fontFamily: 'sans-serif',
    );

/// Образец оформления в меню: фон, акцент и светлый акцент
class SkinSwatch extends StatelessWidget {
  const SkinSwatch({super.key, required this.skin});
  final AppSkin skin;

  @override
  Widget build(BuildContext context) {
    Widget dot(Color c) => Container(
          width: 10,
          height: 10,
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: skin.background,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: skin.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [dot(skin.card), dot(skin.accent), dot(skin.accentLight)],
      ),
    );
  }
}

/// Картинки: текущего оформления — сразу, остальных — потом, в фоне
void precacheSkinImages(BuildContext context) {
  final now = currentSkin.value;
  for (final p in [now.banner, now.emptyDay]) {
    precacheImage(AssetImage(p), context).ignore();
  }
  Timer(const Duration(seconds: 8), () {
    if (!context.mounted) return;
    for (final s in kSkins) {
      if (identical(s, now)) continue;
      precacheImage(AssetImage(s.banner), context).ignore();
      precacheImage(AssetImage(s.emptyDay), context).ignore();
    }
  });
}
