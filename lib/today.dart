// Кнопка «Сегодня» под календарём: чистая логика (проверяется тестами).

/// Календарная дата по местным часам, без времени
DateTime localDate(DateTime t) => DateTime(t.year, t.month, t.day);

/// Уже «на сегодня»: открыта заметка сегодняшнего дня (не тема),
/// сетка показывает текущий месяц и выбор месяцев закрыт.
/// Тогда кнопка «Сегодня» ничего не делает и выглядит приглушённой.
bool isOnToday({
  required DateTime selected,
  required DateTime focused,
  required DateTime now,
  required bool topicOpen,
  required bool monthPickerOpen,
}) =>
    !topicOpen &&
    !monthPickerOpen &&
    selected.year == now.year &&
    selected.month == now.month &&
    selected.day == now.day &&
    focused.year == now.year &&
    focused.month == now.month;
