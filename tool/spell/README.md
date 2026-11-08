# Проверка правописания: воркер и словари

`web/spell/v1/` собирается отсюда (в репозитории лежит уже готовый результат):

```
cd tool/spell
npm install
node bundle.cjs                      # → spell_worker.js (nspell + is-buffer, без сборщиков)
cp spell_worker.js ../../web/spell/v1/
cp node_modules/dictionary-ru/index.aff ../../web/spell/v1/ru.aff.txt
cp node_modules/dictionary-ru/index.dic ../../web/spell/v1/ru.dic.txt
cp node_modules/dictionary-en/index.aff ../../web/spell/v1/en.aff.txt
cp node_modules/dictionary-en/index.dic ../../web/spell/v1/en.dic.txt
node test_worker.cjs ../../web/spell/v1   # «привет»/«превет», «hello»/«teh»
```

При замене словарей — новая папка `v2` (файлы кэшируются браузером на 30 дней).
Лицензии: `web/spell/v1/LICENSE-*.txt` (dictionary-ru — BSD-3-Clause,
dictionary-en — MIT и BSD, nspell и is-buffer — MIT).
