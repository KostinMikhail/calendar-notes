// Склеивает worker_src.js + nspell + is-buffer в один файл для Web Worker
// (простой загрузчик CommonJS, без сторонних сборщиков).
const fs = require('fs');
const path = require('path');

const root = __dirname;
const entry = path.join(root, 'worker_src.js');
const modules = new Map(); // абсолютный путь → {id, code, deps}
let nextId = 0;

function resolve(from, request) {
  if (request === 'nspell') return path.join(root, 'node_modules/nspell/lib/index.js');
  if (request === 'is-buffer') return path.join(root, 'node_modules/is-buffer/index.js');
  if (request.startsWith('.')) {
    let p = path.resolve(path.dirname(from), request);
    if (!p.endsWith('.js')) p += '.js';
    return p;
  }
  throw new Error('unknown module ' + request + ' in ' + from);
}

function add(file) {
  if (modules.has(file)) return modules.get(file).id;
  const rec = {id: nextId++, code: '', deps: {}};
  modules.set(file, rec);
  let code = fs.readFileSync(file, 'utf8');
  code = code.replace(/require\((['"])([^'"]+)\1\)/g, (m, q, req) => {
    const id = add(resolve(file, req));
    return '__req(' + id + ')';
  });
  rec.code = code;
  return rec.id;
}

const entryId = add(entry);
const parts = [];
parts.push('/* Calendar Notes spell worker: nspell (MIT, (c) Titus Wormer), is-buffer (MIT, (c) Feross Aboukhadijeh). See LICENSE-*.txt next to this file. */');
parts.push('(function(){var __defs={},__cache={};function __req(i){if(__cache[i])return __cache[i].exports;var m={exports:{}};__cache[i]=m;__defs[i](m,m.exports);return m.exports;}');
for (const [file, rec] of modules) {
  parts.push('__defs[' + rec.id + ']=function(module,exports){' + '\n' + rec.code + '\n};');
}
parts.push('__req(' + entryId + ');})();');
const out = parts.join('\n');
fs.writeFileSync(path.join(root, 'spell_worker.js'), out);
console.log('modules', modules.size, 'bytes', out.length);
