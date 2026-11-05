import 'package:calendar_notes/topics.dart';
import 'package:flutter_test/flutter_test.dart';

/// Хранилище тем в памяти: записывает, какие операции пришли
class FakeTopicStore implements TopicStore {
  final Map<String, Topic> data = {};
  final Map<String, TopicContent> content = {};
  final List<Map<String, int>> orderWrites = [];
  bool failNext = false;
  int _seq = 0;

  void _maybeFail() {
    if (failNext) {
      failNext = false;
      throw StateError('network');
    }
  }

  @override
  Future<List<Topic>> list() async => data.values.toList();

  @override
  Future<String> create(String title, int order) async {
    _maybeFail();
    final id = 'id${_seq++}';
    data[id] = Topic(id: id, title: title, order: order);
    content[id] = const TopicContent(kEmptyTopicDelta, '');
    return id;
  }

  @override
  Future<void> rename(String id, String title) async {
    _maybeFail();
    data[id] = data[id]!.copyWith(title: title);
  }

  @override
  Future<void> delete(String id) async {
    _maybeFail();
    data.remove(id);
    content.remove(id);
  }

  @override
  Future<void> setOrders(Map<String, int> orders) async {
    _maybeFail();
    orderWrites.add(Map.of(orders));
    orders.forEach((id, o) => data[id] = data[id]!.copyWith(order: o));
  }

  @override
  Future<TopicContent?> load(String id) async => content[id];

  @override
  Future<void> saveContent(String id, String delta, String text) async {
    content[id] = TopicContent(delta, text);
  }
}

Topic t(String id, int order) => Topic(id: id, title: id, order: order);

void main() {
  group('название темы', () {
    test('пробелы и переводы строк схлопываются, края обрезаются', () {
      expect(normalizeTopicTitle('  Проект   X \n планы '), 'Проект X планы');
    });

    test('пустое — «Без названия»', () {
      expect(normalizeTopicTitle(''), 'Без названия');
      expect(normalizeTopicTitle('   \n\t '), 'Без названия');
    });

    test('не длиннее 80 символов', () {
      final long = 'а' * 100;
      expect(normalizeTopicTitle(long).length, 80);
      expect(normalizeTopicTitle('б' * 80), 'б' * 80);
    });

    test('обрезка не рвёт суррогатную пару', () {
      final s = '${'x' * 79}😀';
      final n = normalizeTopicTitle(s);
      expect(n, 'x' * 79);
    });
  });

  group('ключи цели', () {
    test('тема и день различаются', () {
      expect(topicKey('abc'), 't:abc');
      expect(topicIdOf('t:abc'), 'abc');
      expect(topicIdOf('2026-11-05'), isNull);
      expect(topicIdOf(null), isNull);
    });
  });

  group('порядок', () {
    test('новая тема — в конец', () {
      expect(nextTopicOrder(const []), 0);
      expect(nextTopicOrder([t('a', 0), t('b', 7), t('c', 3)]), 8);
    });

    test('перенос вниз меняет только сдвинутые', () {
      final (list, changed) =
          reorderTopics([t('a', 0), t('b', 1), t('c', 2), t('d', 3)], 0, 2);
      expect(list.map((x) => x.id), ['b', 'c', 'a', 'd']);
      expect(changed, {'b': 0, 'c': 1, 'a': 2});
    });

    test('перенос вверх', () {
      final (list, changed) =
          reorderTopics([t('a', 0), t('b', 1), t('c', 2), t('d', 3)], 3, 1);
      expect(list.map((x) => x.id), ['a', 'd', 'b', 'c']);
      expect(changed, {'d': 1, 'b': 2, 'c': 3});
    });

    test('на то же место — ничего не пишется', () {
      final (_, changed) = reorderTopics([t('a', 0), t('b', 1)], 1, 1);
      expect(changed, isEmpty);
    });

    test('порядок с пропусками выравнивается', () {
      final (list, changed) = reorderTopics([t('a', 0), t('b', 5), t('c', 9)], 2, 0);
      expect(list.map((x) => '${x.id}${x.order}'), ['c0', 'a1', 'b2']);
      expect(changed, {'c': 0, 'a': 1, 'b': 2});
    });
  });

  group('контроллер списка', () {
    test('загрузка сортирует по order', () async {
      final store = FakeTopicStore()
        ..data['x'] = t('x', 2)
        ..data['y'] = t('y', 0);
      final c = TopicsController(store);
      await c.load();
      expect(c.topics.map((x) => x.id), ['y', 'x']);
      expect(c.loaded, isTrue);
    });

    test('создание: «Новая тема» в конце списка', () async {
      final store = FakeTopicStore()..data['x'] = t('x', 4);
      final c = TopicsController(store);
      await c.load();
      final created = await c.create();
      expect(created.title, 'Новая тема');
      expect(created.order, 5);
      expect(c.topics.last.id, created.id);
      expect(store.data[created.id]!.order, 5);
    });

    test('переименование нормализует название', () async {
      final store = FakeTopicStore()..data['x'] = t('x', 0);
      final c = TopicsController(store);
      await c.load();
      await c.rename('x', '   ');
      expect(c.byId('x')!.title, 'Без названия');
      expect(store.data['x']!.title, 'Без названия');
    });

    test('сбой переименования: список перечитан, ошибка проброшена', () async {
      final store = FakeTopicStore()..data['x'] = t('x', 0);
      final c = TopicsController(store);
      await c.load();
      store.failNext = true;
      await expectLater(c.rename('x', 'Новое'), throwsStateError);
      expect(c.byId('x')!.title, 'x');
    });

    test('удаление', () async {
      final store = FakeTopicStore()
        ..data['x'] = t('x', 0)
        ..data['y'] = t('y', 1);
      final c = TopicsController(store);
      await c.load();
      await c.delete('x');
      expect(c.topics.map((x) => x.id), ['y']);
      expect(store.data.keys, ['y']);
    });

    test('перестановка пишет только изменившиеся order', () async {
      final store = FakeTopicStore();
      for (var i = 0; i < 5; i++) {
        store.data['t$i'] = t('t$i', i);
      }
      final c = TopicsController(store);
      await c.load();
      await c.reorder(4, 3);
      expect(store.orderWrites.single, {'t4': 3, 't3': 4});
      expect(c.topics.map((x) => x.id), ['t0', 't1', 't2', 't4', 't3']);
    });

    test('сбой перестановки: порядок берётся с сервера', () async {
      final store = FakeTopicStore()
        ..data['a'] = t('a', 0)
        ..data['b'] = t('b', 1);
      final c = TopicsController(store);
      await c.load();
      store.failNext = true;
      await expectLater(c.reorder(0, 1), throwsStateError);
      expect(c.topics.map((x) => x.id), ['a', 'b']);
    });
  });
}
