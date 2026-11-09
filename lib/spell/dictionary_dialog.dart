// Окно «Личный словарь»: список слов, удаление, добавление вручную
import 'package:flutter/material.dart';

import '../main.dart'
    show kAccent, kBackground, kCard, kDivider, kSurface, kTextPrimary,
        kTextSecondary;
import '../motion.dart' show showAppDialog;
import 'personal_dictionary.dart';
import 'tokenizer.dart' show normalizeWord;

Future<void> showPersonalDictionaryDialog(
    BuildContext context, PersonalDictionary dictionary) {
  dictionary.load(); // словарь мог быть не загружен (проверка выключена)
  return showAppDialog<void>(
    context: context,
    builder: (_) => _DictionaryDialog(dictionary: dictionary),
  );
}

class _DictionaryDialog extends StatefulWidget {
  const _DictionaryDialog({required this.dictionary});
  final PersonalDictionary dictionary;

  @override
  State<_DictionaryDialog> createState() => _DictionaryDialogState();
}

class _DictionaryDialogState extends State<_DictionaryDialog> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final n = normalizeWord(_input.text);
    if (n.isEmpty) return;
    if (!isValidDictionaryWord(n)) {
      setState(() => _error = 'Одно слово без пробелов, до '
          '$kMaxDictionaryWordLength символов');
      return;
    }
    setState(() => _error = null);
    _input.clear();
    _focus.requestFocus();
    await widget.dictionary.add(n);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kSurface,
      title: Row(
        children: [
          Icon(Icons.spellcheck, color: kAccent),
          SizedBox(width: 10),
          // узкое окно — заголовок сжимается с многоточием
          Flexible(
            child: Text('Личный словарь',
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      content: SizedBox(
        width: 380,
        // низкое окно (телефон боком) — список короче, окно помещается
        height: (MediaQuery.sizeOf(context).height - 220).clamp(160.0, 420.0),
        child: ListenableBuilder(
          listenable: widget.dictionary,
          builder: (context, _) {
            final words = widget.dictionary.words;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Эти слова не подчёркиваются при проверке правописания.',
                  style: TextStyle(color: kTextSecondary, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        focusNode: _focus,
                        autofocus: true,
                        style: TextStyle(color: kTextPrimary),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Новое слово',
                          errorText: _error,
                          filled: true,
                          fillColor: kCard,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: kDivider),
                          ),
                        ),
                        onSubmitted: (_) => _add(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Добавить',
                      icon: Icon(Icons.add, color: kAccent),
                      onPressed: _add,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text('Слов: ${words.length}',
                    style:
                        TextStyle(color: kTextSecondary, fontSize: 12)),
                const SizedBox(height: 6),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: kCard,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: kDivider),
                    ),
                    child: words.isEmpty
                        ? Center(
                            child: Text(
                              widget.dictionary.loaded
                                  ? 'Словарь пуст. Добавьте слово здесь или '
                                      'правым щелчком по подчёркнутому слову.'
                                  : 'Загрузка…',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: kTextSecondary, fontSize: 13),
                            ),
                          )
                        : ListView.builder(
                            itemCount: words.length,
                            itemBuilder: (context, i) => ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              title: Text(words[i],
                                  style: TextStyle(color: kTextPrimary)),
                              trailing: IconButton(
                                tooltip: 'Убрать из словаря',
                                icon: Icon(Icons.close,
                                    size: 18, color: kTextSecondary),
                                onPressed: () =>
                                    widget.dictionary.remove(words[i]),
                              ),
                            ),
                          ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: kAccent, foregroundColor: kBackground),
          onPressed: () => Navigator.pop(context),
          child: const Text('Готово'),
        ),
      ],
    );
  }
}
