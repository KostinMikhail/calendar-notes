import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:calendar_notes/format_menu.dart' show PrefStore;
import 'package:calendar_notes/skins.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

class MemPrefs implements PrefStore {
  final Map<String, String> data = {};
  bool throws = false;
  @override
  String? read(String key) {
    if (throws) throw StateError('blocked');
    return data[key];
  }

  @override
  void write(String key, String value) {
    if (throws) throw StateError('blocked');
    data[key] = value;
  }
}

Color hexColor(String s) => Color(int.parse(s.replaceFirst('0x', ''), radix: 16));

double _lum(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  tearDown(() => currentSkin.value = kSkins.first);

  group('таблица оформлений', () {
    test('шесть оформлений, id уникальны, первое — фиолетовое', () {
      expect(kSkins.length, 6);
      expect(kSkins.map((s) => s.id).toSet().length, 6);
      expect(kSkins.map((s) => s.id),
          ['violet', 'aurora', 'mars', 'blue', 'nebula', 'graphite']);
      expect(kSkins.first.id, kDefaultSkinId);
      for (final s in kSkins) {
        expect(s.title, isNotEmpty);
        expect(s.catName, isNotEmpty);
      }
    });

    test('картинки и значки есть на диске и объявлены в pubspec.yaml', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final s in kSkins) {
        expect(File(s.banner).existsSync(), isTrue, reason: s.banner);
        expect(File(s.emptyDay).existsSync(), isTrue, reason: s.emptyDay);
        expect(File('web/${s.favicon}').existsSync(), isTrue, reason: s.favicon);
        expect(pubspec, contains('- assets/images/themes/${s.id}/'),
            reason: 'папка ${s.id} объявлена');
      }
    });

    test('цвета совпадают с themes.json', () {
      final json = jsonDecode(File('themes.json').readAsStringSync()) as List;
      expect(json.length, kSkins.length);
      for (final raw in json) {
        final m = raw as Map<String, dynamic>;
        final s = skinById(m['id'] as String);
        expect(s.id, m['id']);
        expect(s.title, m['title']);
        expect(s.catName, m['cat']);
        expect(s.banner, m['banner']);
        expect(s.emptyDay, m['emptyDay']);
        expect(s.favicon, m['favicon']);
        final c = m['colors'] as Map<String, dynamic>;
        final tokens = {
          'kBackground': s.background,
          'kSurface': s.surface,
          'kCard': s.card,
          'kAccent': s.accent,
          'kAccentLight': s.accentLight,
          'kTextPrimary': s.textPrimary,
          'kTextSecondary': s.textSecondary,
          'kDivider': s.divider,
          'kSubtle': s.subtle,
          'kMuted': s.muted,
        };
        expect(c.keys.toSet(), tokens.keys.toSet());
        tokens.forEach((k, v) =>
            expect(v, hexColor(c[k] as String), reason: '${s.id}.$k'));
      }
    });

    test('«Фиолетовая ночь» — ровно прежние цвета приложения', () {
      final v = kSkins.first;
      expect(v.background, const Color(0xFF0E0D13));
      expect(v.surface, const Color(0xFF15141C));
      expect(v.card, const Color(0xFF1C1A25));
      expect(v.accent, const Color(0xFF9C8FCB));
      expect(v.accentLight, const Color(0xFFC9BCE6));
      expect(v.textPrimary, const Color(0xFFECEAF2));
      expect(v.textSecondary, const Color(0xFF8D8A9C));
      expect(v.divider, const Color(0xFF292734));
      expect(v.subtle, const Color(0xFF34313F)); // разделитель в заметке
      expect(v.muted, const Color(0xFF55526A)); // дни соседнего месяца
      // производные: заливка дня при открытой теме, подчёркивание правописания
      expect(v.accent.withAlpha(0x66), const Color(0x669C8FCB));
      expect(v.textSecondary.withAlpha(0xA6), const Color(0xA68D8A9C));
      // текст заметки — как раньше (ColorScheme.dark по умолчанию)
      final theme = skinTheme(v);
      expect(theme.colorScheme.onSurface, const ColorScheme.dark().onSurface);
      expect(theme.colorScheme.primary, const Color(0xFF9C8FCB));
      expect(theme.colorScheme.secondary, const Color(0xFFC9BCE6));
      expect(theme.colorScheme.surface, const Color(0xFF15141C));
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0E0D13));
    });

    test('таблица цветов в web/index.html совпадает с Dart', () {
      final html = File('web/index.html').readAsStringSync();
      final m = RegExp(r'var SKIN_BACKGROUNDS = (\{[^}]*\});').firstMatch(html);
      expect(m, isNotNull, reason: 'таблица в index.html');
      final table = (jsonDecode(m!.group(1)!) as Map).cast<String, String>();
      expect(table, {for (final s in kSkins) s.id: cssColor(s.background)});
      expect(html, contains("localStorage.getItem('${SkinPref.storageKey}')"));
      expect(html, contains('<meta name="theme-color"'));
    });
  });

  group('запоминание', () {
    test('нет значения — фиолетовое; верное — оно; мусор и ошибка — фиолетовое',
        () {
      final prefs = MemPrefs();
      expect(SkinPref(prefs).load().id, 'violet');
      prefs.data[SkinPref.storageKey] = 'mars';
      expect(SkinPref(prefs).load().id, 'mars');
      prefs.data[SkinPref.storageKey] = 'неизвестное';
      expect(SkinPref(prefs).load().id, 'violet');
      expect(SkinPref(MemPrefs()..throws = true).load().id, 'violet');
      SkinPref(MemPrefs()..throws = true).save(kSkins[2]); // не бросает
    });

    test('выбор сохраняется', () {
      final prefs = MemPrefs();
      setSkin(skinById('nebula'), SkinPref(prefs));
      expect(prefs.data[SkinPref.storageKey], 'nebula');
      expect(currentSkin.value.id, 'nebula');
      initSkin(SkinPref(prefs));
      expect(currentSkin.value.id, 'nebula');
    });
  });

  test('контраст: текст ≥ 4.5, акцент ≥ 3 на фоне, панели и карточке', () {
    final low = <String>[];
    for (final s in kSkins) {
      for (final bg in [s.background, s.surface, s.card]) {
        void need(String name, Color c, double min) {
          final r = contrast(c, bg);
          if (r < min) low.add('${s.id}.$name ${r.toStringAsFixed(2)}');
        }

        need('textPrimary', s.textPrimary, 4.5);
        need('textSecondary', s.textSecondary, 4.5);
        need('accent', s.accent, 3.0);
        // цвета текста в заметках и ссылки (не зависят от оформления)
        for (final c in const [
          Color(0xFFFF5C5C),
          Color(0xFFFFD54A),
          Color(0xFF4CD97B),
          Color(0xFF5AB0FF),
        ]) {
          need('semantic ${c.toARGB32().toRadixString(16)}', c, 4.5);
        }
      }
    }
    expect(low, isEmpty);
  });

  group('смена оформления на лету', () {
    testWidgets('несохранённый текст, курсор и фокус остаются; сохранения нет; '
        'всё перерисовано в новых цветах', (tester) async {
      final probe = _Probe();
      await tester.pumpWidget(_App(probe: probe));
      final state = probe.state!;
      state.focus.requestFocus();
      await tester.pump();
      state.controller.replaceText(
          0, 0, 'несохранённый текст', const TextSelection.collapsed(offset: 19));
      state.controller.updateSelection(
          const TextSelection(baseOffset: 3, extentOffset: 10), ChangeSource.local);
      await tester.pump();
      final controller = state.controller;
      final saves = probe.saves;
      final status = state.status.value;

      setSkin(skinById('mars'), SkinPref(MemPrefs()));
      await tester.pump();

      expect(identical(probe.state, state), isTrue); // State тот же
      expect(probe.inits, 1); // initState не вызывался заново
      expect(identical(state.controller, controller), isTrue);
      expect(controller.document.toPlainText(), 'несохранённый текст\n');
      expect(controller.selection,
          const TextSelection(baseOffset: 3, extentOffset: 10));
      expect(state.focus.hasFocus, isTrue);
      expect(probe.saves, saves); // ни одного сохранения
      expect(state.status.value, status);

      // константные виджеты тоже перерисованы новыми цветами
      final dot = tester.widget<Container>(find.byKey(const Key('accent-dot')));
      expect((dot.decoration as BoxDecoration).color, skinById('mars').accent);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, skinById('mars').background);
      expect(Theme.of(tester.element(find.byType(QuillEditor))).colorScheme.primary,
          skinById('mars').accent);
      // картинки — нового оформления
      final img = tester.widget<Image>(find.byKey(const Key('banner')));
      expect((img.image as AssetImage).assetName, skinById('mars').banner);
      expect(img.filterQuality, FilterQuality.none);
    });
  });
}

class _Probe {
  _EditorState? state;
  int inits = 0;
  int saves = 0;
}

/// Как в приложении: тема и цвета из текущего оформления, редактор со
/// своим состоянием, «автосохранение» считает вызовы
class _App extends StatelessWidget {
  const _App({required this.probe});
  final _Probe probe;

  @override
  Widget build(BuildContext context) => MaterialApp(
        theme: skinTheme(currentSkin.value),
        themeAnimationDuration: Duration.zero,
        home: _Editor(probe: probe),
      );
}

class _Editor extends StatefulWidget {
  const _Editor({required this.probe});
  final _Probe probe;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  final controller = QuillController.basic();
  final focus = FocusNode();
  final status = ValueNotifier<String>('');
  String _saved = '';

  @override
  void initState() {
    super.initState();
    widget.probe.state = this;
    widget.probe.inits++;
    // «автосохранение»: срабатывает, только если текст изменился
    controller.addListener(() {
      final t = controller.document.toPlainText();
      if (t != _saved && t != '\n') {
        _saved = t;
        if (widget.probe.saves >= 0) widget.probe.saves++;
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: currentSkin.value.background,
        body: Column(
          children: [
            const _AccentDot(),
            Image.asset(currentSkin.value.banner,
                key: const Key('banner'), filterQuality: FilterQuality.none),
            Expanded(
              child: QuillEditor(
                controller: controller,
                focusNode: focus,
                scrollController: ScrollController(),
                config: const QuillEditorConfig(),
              ),
            ),
          ],
        ),
      );
}

class _AccentDot extends StatelessWidget {
  const _AccentDot();
  @override
  Widget build(BuildContext context) => Container(
        key: const Key('accent-dot'),
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: currentSkin.value.accent),
      );
}
