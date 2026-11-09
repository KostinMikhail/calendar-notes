// Блок «Темы» под календарём и диалоги для тем.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart'
    show FadeSwitcher, Motion, PressScale, SizeFade, showAppDialog;
import 'main.dart'
    show
        kAccent,
        kAccentLight,
        kBackground,
        kCard,
        kDivider,
        kSurface,
        kTextPrimary,
        kTextSecondary;
import 'topics.dart';

class TopicsPanel extends StatefulWidget {
  const TopicsPanel({
    super.key,
    required this.controller,
    required this.selectedId,
    required this.onOpen,
    required this.onCreate,
    required this.onRename,
    required this.onDelete,
    this.enabled = true,
  });

  final TopicsController controller;
  final String? selectedId;
  final ValueChanged<String> onOpen;
  final VoidCallback onCreate;
  final ValueChanged<String> onRename;
  final ValueChanged<String> onDelete;

  /// false — идёт копия/восстановление, действия недоступны
  final bool enabled;

  @override
  State<TopicsPanel> createState() => _TopicsPanelState();
}

/// Строка списка: живая тема или уходящая (удалена — только тает)
class _Entry {
  _Entry(this.topic, {this.leaving = false});
  final Topic topic;
  final bool leaving;
}

class _TopicsPanelState extends State<TopicsPanel> {
  TopicsController get controller => widget.controller;
  String? get selectedId => widget.selectedId;
  ValueChanged<String> get onOpen => widget.onOpen;
  VoidCallback get onCreate => widget.onCreate;
  ValueChanged<String> get onRename => widget.onRename;
  ValueChanged<String> get onDelete => widget.onDelete;
  bool get enabled => widget.enabled;

  /// Что показано в списке: темы контроллера и уходящие строки на своих
  /// прежних местах. Данные меняются сразу (в контроллере), здесь — только
  /// вид.
  List<_Entry> _entries = const [];

  /// Темы, появившиеся после первой загрузки — им анимация появления
  final Set<String> _appearing = {};
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    controller.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(TopicsPanel old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
      _seeded = false;
      _entries = const [];
      _sync();
    }
  }

  @override
  void dispose() {
    controller.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    final topics = controller.topics;
    final ids = {for (final t in topics) t.id};
    final merged = [for (final t in topics) _Entry(t)];
    if (_seeded) {
      final before = {for (final e in _entries) if (!e.leaving) e.topic.id};
      for (final t in topics) {
        if (!before.contains(t.id)) _appearing.add(t.id);
      }
      // удалённые (и ещё не дотаявшие) строки — на прежних местах
      for (var i = 0; i < _entries.length; i++) {
        final e = _entries[i];
        if (ids.contains(e.topic.id)) continue;
        merged.insert(
            i.clamp(0, merged.length), _Entry(e.topic, leaving: true));
      }
    }
    if (controller.loaded) _seeded = true;
    _appearing.removeWhere((id) => !ids.contains(id));
    if (mounted) {
      setState(() => _entries = merged);
    } else {
      _entries = merged;
    }
  }

  void _gone(_Entry e) {
    if (!mounted) return;
    setState(() => _entries = [for (final x in _entries) if (x != e) x]);
  }

  bool get _hasLeaving => _entries.any((e) => e.leaving);

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kDivider),
      ),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 6, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Темы',
                      style: TextStyle(
                        color: kTextPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  PressScale(
                    enabled: enabled,
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Новая тема',
                      icon: Icon(Icons.add, color: kAccent),
                      onPressed: enabled ? onCreate : null,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: kDivider),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final c = controller;
    if (c.loading && !c.loaded) {
      return Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.2, color: kAccent),
        ),
      );
    }
    if (c.error != null && !c.loaded) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Не удалось загрузить темы',
                style: TextStyle(color: Color(0xFFFF5C5C), fontSize: 13)),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: kAccent),
              onPressed: c.load,
              child: const Text('Повторить'),
            ),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Пока нет тем. Нажмите «+», чтобы создать.',
            textAlign: TextAlign.center,
            style: TextStyle(color: kTextSecondary, fontSize: 13),
          ),
        ),
      );
    }
    final entries = _entries;
    // пока удалённая строка тает (доли секунды), перетаскивание выключено:
    // номера строк на экране и в списке тем ненадолго не совпадают
    final canDrag = enabled && !_hasLeaving;
    return ReorderableListView.builder(
      // тянуть можно только за ручку — прокрутка не начинает перетаскивание
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: entries.length,
      onReorderItem: (oldIndex, newIndex) {
        if (!canDrag) return;
        c.reorder(oldIndex, newIndex).catchError((_) {});
      },
      // перетаскиваемая строка приподнимается и чуть увеличивается,
      // соседи раздвигаются (встроенное поведение списка)
      proxyDecorator: (child, _, animation) => AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final t = Motion.enter.transform(animation.value);
          return Transform.scale(
            scale: 1 + 0.02 * t,
            child: Opacity(
              opacity: 1 - 0.08 * t,
              child: Material(
                color: kCard,
                elevation: 6 * t,
                borderRadius: BorderRadius.circular(10),
                child: child,
              ),
            ),
          );
        },
        child: child,
      ),
      itemBuilder: (context, i) {
        final e = entries[i];
        if (e.leaving) {
          return SizeFade.leave(
            key: ValueKey('gone:${e.topic.id}'),
            onGone: () => _gone(e),
            child: _item(context, e.topic, i, dragEnabled: false),
          );
        }
        return SizeFade.appear(
          key: ValueKey(e.topic.id),
          animate: _appearing.contains(e.topic.id),
          child: _item(context, e.topic, i, dragEnabled: canDrag),
        );
      },
    );
  }

  Widget _item(BuildContext context, Topic t, int index,
      {required bool dragEnabled}) {
    final selected = t.id == selectedId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        // выбор темы — заливка и рамка перетекают
        animationDuration: Motion.fast,
        color: selected ? kAccent.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? () => onOpen(t.id) : null,
          child: AnimatedContainer(
            duration: Motion.fast,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: selected ? kAccent : kAccent.withValues(alpha: 0)),
            ),
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  enabled: dragEnabled,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.drag_indicator,
                          size: 18, color: kTextSecondary),
                    ),
                  ),
                ),
                Expanded(
                  // переименование — быстрое перетекание названия
                  child: FadeSwitcher(
                    dy: 0,
                    child: Text(
                      t.title,
                      key: ValueKey(t.title),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(
                        color: selected ? kAccentLight : kTextPrimary,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Действия',
                  enabled: enabled,
                  color: kCard,
                  popUpAnimationStyle: Motion.menu,
                  icon: Icon(Icons.more_vert,
                      size: 18, color: kTextSecondary),
                  onSelected: (v) {
                    if (v == 'rename') onRename(t.id);
                    if (v == 'delete') onDelete(t.id);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'rename',
                      height: 40,
                      child: Row(children: [
                        Icon(Icons.edit_outlined, size: 18, color: kAccent),
                        SizedBox(width: 10),
                        Text('Переименовать',
                            style: TextStyle(color: kTextPrimary)),
                      ]),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      height: 40,
                      child: Row(children: [
                        Icon(Icons.delete_outline,
                            size: 18, color: Color(0xFFFF5C5C)),
                        SizedBox(width: 10),
                        Text('Удалить', style: TextStyle(color: kTextPrimary)),
                      ]),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Диалог названия темы. Enter — сохранить, Esc — отмена (null).
/// Возвращает уже нормализованное название.
Future<String?> showTopicTitleDialog(
  BuildContext context, {
  required String initial,
  String heading = 'Название темы',
}) async {
  final ctrl = TextEditingController(text: initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  final result = await showAppDialog<String>(
    context: context,
    builder: (ctx) {
      void submit() => Navigator.pop(ctx, normalizeTopicTitle(ctrl.text));
      return AlertDialog(
        backgroundColor: kSurface,
        title: Text(heading),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: kTopicTitleMax,
            maxLengthEnforcement: MaxLengthEnforcement.enforced,
            style: TextStyle(color: kTextPrimary),
            cursorColor: kAccent,
            decoration: const InputDecoration(hintText: kTopicDefaultTitle),
            onSubmitted: (_) => submit(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: kAccent, foregroundColor: kBackground),
            onPressed: submit,
            child: const Text('Сохранить'),
          ),
        ],
      );
    },
  );
  // ctrl не освобождаем сразу: поле ещё видно во время анимации закрытия
  return result;
}

/// Подтверждение удаления темы
Future<bool> confirmTopicDelete(BuildContext context, String title) async {
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kSurface,
      title: const Text('Удалить тему?'),
      content: Text(
        'Тема «$title» будет удалена вместе с содержимым. '
        'Отменить это нельзя.',
        style: TextStyle(color: kTextPrimary),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена')),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF5C5C),
              foregroundColor: kBackground),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Удалить'),
        ),
      ],
    ),
  );
  return ok == true;
}
