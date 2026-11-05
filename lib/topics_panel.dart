// Блок «Темы» под календарём и диалоги для тем.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

class TopicsPanel extends StatelessWidget {
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
                  const Expanded(
                    child: Text(
                      'Темы',
                      style: TextStyle(
                        color: kTextPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Новая тема',
                    icon: const Icon(Icons.add, color: kAccent),
                    onPressed: enabled ? onCreate : null,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: kDivider),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final c = controller;
    if (c.loading && !c.loaded) {
      return const Center(
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
    if (c.topics.isEmpty) {
      return const Center(
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
    final topics = c.topics;
    return ReorderableListView.builder(
      // тянуть можно только за ручку — прокрутка не начинает перетаскивание
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: topics.length,
      onReorderItem: (oldIndex, newIndex) {
        if (!enabled) return;
        c.reorder(oldIndex, newIndex).catchError((_) {});
      },
      proxyDecorator: (child, _, _) => Material(
        color: kCard,
        elevation: 4,
        borderRadius: BorderRadius.circular(10),
        child: child,
      ),
      itemBuilder: (context, i) => _item(context, topics[i], i),
    );
  }

  Widget _item(BuildContext context, Topic t, int index) {
    final selected = t.id == selectedId;
    return Padding(
      key: ValueKey(t.id),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: selected ? kAccent.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? () => onOpen(t.id) : null,
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: selected ? kAccent : Colors.transparent),
            ),
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  enabled: enabled,
                  child: const MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.drag_indicator,
                          size: 18, color: kTextSecondary),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    t.title,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      color: selected ? kAccentLight : kTextPrimary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Действия',
                  enabled: enabled,
                  color: kCard,
                  icon: const Icon(Icons.more_vert,
                      size: 18, color: kTextSecondary),
                  onSelected: (v) {
                    if (v == 'rename') onRename(t.id);
                    if (v == 'delete') onDelete(t.id);
                  },
                  itemBuilder: (_) => const [
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
  final result = await showDialog<String>(
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
            style: const TextStyle(color: kTextPrimary),
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
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kSurface,
      title: const Text('Удалить тему?'),
      content: Text(
        'Тема «$title» будет удалена вместе с содержимым. '
        'Отменить это нельзя.',
        style: const TextStyle(color: kTextPrimary),
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
