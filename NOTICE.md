# Сторонние компоненты

Пакеты выпусков содержат образы контейнеров, собранные из следующих проектов (с нашими изменениями там, где указано).

| Компонент | Лицензия | Где | Изменения |
|---|---|---|---|
| OpenUDS (broker) | BSD-3-Clause | образ `broker` | патчи (туннели с привязкой к адресу, провайдер vSphere, транспорт HTML5 и др.) |
| UDS Tunnel (Rust) | BSD-3-Clause | образ `tunnel` | клиентский сертификат (mTLS), TLS поверх протокола туннеля, таймаут рукопожатия |
| Apache Guacamole (client, server) | Apache-2.0 | образы `guacamole`, `guacd` | обновлённые библиотеки, убраны неиспользуемые модули |
| FreeRDP | Apache-2.0 | образ `guacd` | — |
| HAProxy | GPL-2.0 (+ LGPL для заголовков) | образ `dbproxy`, пакет ОС на фронтах | — |
| keepalived | GPL-2.0 | образ `keepalived` | — |
| memcached | BSD-3-Clause | образ `memcached` | — |
| MariaDB / Galera | GPL-2.0 | пакеты ОС на узлах БД | — |
| Python, FastAPI, Starlette, Uvicorn и др. | PSF / MIT / BSD | образы `panel`, `installer`, `broker` | — |

Исходные тексты лицензий находятся внутри соответствующих образов. Лицензия собственного кода CloudUDS будет указана отдельно.

Из каких исходников, на каких версиях и как собирается выпуск — [docs/build-and-release.md](docs/build-and-release.md).
