// Проверка собранного spell_worker.js в Node: подменяем self/fetch и
// гоняем те же сообщения, что шлёт приложение.
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const dir = process.argv[2]; // папка с файлами, как на сайте (spell/v1)
const code = fs.readFileSync(path.join(dir, 'spell_worker.js'), 'utf8');
const replies = [];
const pending = new Map();
const self = {
  postMessage: (s) => {
    const m = JSON.parse(s);
    replies.push(m);
    const r = pending.get(m.id);
    if (r) { pending.delete(m.id); r(m); }
  },
};
const fetch = async (url) => {
  const file = path.join(dir, path.basename(url));
  if (!fs.existsSync(file)) return {ok: false, status: 404, text: async () => ''};
  return {ok: true, status: 200, text: async () => fs.readFileSync(file, 'utf8')};
};
vm.runInNewContext(code, {self, fetch, Promise, console, JSON, String, Error, Object, Array});

let nextId = 1;
function send(msg) {
  const id = nextId++;
  return new Promise((res) => {
    pending.set(id, res);
    self.onmessage({data: JSON.stringify({...msg, id})});
  });
}

(async () => {
  let t = Date.now();
  const init = await send({type: 'init', base: '/spell/v1/', langs: ['en', 'ru']});
  console.log('init', JSON.stringify(init), (Date.now() - t) + 'ms');
  const ru = await send({type: 'check', lang: 'ru', words: ['привет', 'превет', 'еще', 'ещё', 'все', 'встреча']});
  console.log('ru check', JSON.stringify(ru.results));
  const ruS = await send({type: 'suggest', lang: 'ru', word: 'превет'});
  console.log('ru suggest превет', JSON.stringify(ruS.suggestions));
  const en = await send({type: 'check', lang: 'en', words: ['hello', 'teh', "don't", "it's"]});
  console.log('en check', JSON.stringify(en.results));
  const enS = await send({type: 'suggest', lang: 'en', word: 'teh'});
  console.log('en suggest teh', JSON.stringify(enS.suggestions));
  const bad = await send({type: 'check', lang: 'de', words: ['x']});
  console.log('unknown lang', JSON.stringify(bad));
  const ok = ru.results[0] === true && ru.results[1] === false && ruS.suggestions.includes('привет') &&
    en.results[0] === true && en.results[1] === false && enS.suggestions.includes('the');
  console.log(ok ? 'RESULT: OK' : 'RESULT: FAIL');
  process.exit(ok ? 0 : 1);
})();
