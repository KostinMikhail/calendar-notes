// Проверка орфографии для Calendar Notes: работает в Web Worker, всё
// локально. Словари грузятся с того же сайта (/spell/v1/*.txt).
// Сообщения — JSON-строки: {id, type: 'init'|'check'|'suggest', ...}.
'use strict';
var nspell = require('nspell');
var spellers = {};

function fetchText(url) {
  return fetch(url, {credentials: 'same-origin'}).then(function (r) {
    if (!r.ok) throw new Error(url + ': HTTP ' + r.status);
    return r.text();
  }).then(function (t) {
    // переписывание «всё на index.html» — это не словарь
    if (/^\s*</.test(t)) throw new Error(url + ': not a dictionary');
    return t;
  });
}

function load(base, lang) {
  if (spellers[lang]) return Promise.resolve();
  return Promise.all([
    fetchText(base + lang + '.aff.txt'),
    fetchText(base + lang + '.dic.txt'),
  ]).then(function (files) {
    spellers[lang] = nspell(files[0], files[1]);
  });
}

self.onmessage = function (e) {
  var m;
  try { m = JSON.parse(e.data); } catch (_) { return; }
  function reply(o) { o.id = m.id; self.postMessage(JSON.stringify(o)); }
  function fail(err) { reply({error: String((err && err.message) || err)}); }
  try {
    if (m.type === 'init') {
      var chain = Promise.resolve();
      m.langs.forEach(function (l) {
        chain = chain.then(function () { return load(m.base, l); });
      });
      chain.then(function () { reply({ok: true}); }, fail);
    } else if (m.type === 'check') {
      var s = spellers[m.lang];
      if (!s) throw new Error('dictionary not loaded: ' + m.lang);
      reply({results: m.words.map(function (w) { return s.correct(w); })});
    } else if (m.type === 'suggest') {
      var sp = spellers[m.lang];
      reply({suggestions: sp ? sp.suggest(m.word).slice(0, 30) : []});
    }
  } catch (err) { fail(err); }
};
