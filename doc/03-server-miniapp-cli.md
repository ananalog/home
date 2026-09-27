# 03. Сервер (.NET), Telegram Mini App, бот, CLI

## Сервер (`home-server`)

**C#, .NET 10 (LTS), ASP.NET Core.** Один процесс: HTTP API, живые события (SSE), gateway устройств, бот, фоновые задачи.
Публикуется как self-contained single-file для `linux-x64` — на сервере .NET-рантайм ставить не нужно.

### Структура решения

```
home-server/
  Home.sln
  external/home-protocol/            сабмодуль: сгенерированный Home.Protocol (C#) + тест-векторы
  src/
    Home.Server/                     ASP.NET Core хост
      Program.cs                     Kestrel: :8080 HTTP, :7700 TCP (ConnectionHandler)
      Gateway/                       DeviceConnectionHandler, DeviceSession, фреймы, ping
      Discovery/                     mDNS-анонс _home._tcp, UDP DISCOVER
      Devices/                       реестр, принятие, точки
      Telemetry/                     приём REPORT, история, агрегации (BackgroundService)
      Ota/                           хранилище образов, парсинг дескриптора, задания раскатки
      Api/                           Minimal API endpoints, SSE-поток /api/v1/stream
      Auth/                          Telegram initData, токены CLI, роли
      Bot/                           клиент Bot API, long polling, уведомления, OfflineMonitor
      Data/                          EF Core DbContext, миграции (SQLite)
      wwwroot/                       собранный Mini App (из web/miniapp)
    Home.Client/                     типизированный клиент API (используется CLI и тестами)
    Home.Cli/                        homectl (System.CommandLine + Spectre.Console), Native AOT
    Home.Simulator/                  эмулятор устройств по протоколу
  web/miniapp/                       Svelte + Vite + TS
  tests/
    Home.Protocol.Tests/             тест-векторы
    Home.Server.Tests/               юнит-тесты
    Home.Integration.Tests/          сервер (WebApplicationFactory) + эмуляторы + Home.Client
```

### Ключевые детали реализации

- **TCP-gateway в Kestrel**: `options.ListenAnyIP(7700, l => l.UseConnectionHandler<DeviceConnectionHandler>())`.
  Чтение фреймов через `PipeReader` без лишних аллокаций, одна `DeviceSession` на соединение,
  исходящие — через `Channel<T>`; запрос-ответ по `req_id` через `TaskCompletionSource` с таймаутом.
- **Живые данные** — `GET /api/v1/stream` (server-sent events): значения, online/offline, устройство, OTA, события;
  `?logs=<id>` — ещё и логи устройства. Mini App читает через EventSource, `homectl watch` — тот же поток.
- **Фоновые задачи** — `BackgroundService`: даунсэмплинг истории, OTA-раскатка, проверка «оффлайн > N минут», бэкап.
- **Конфиг** — `appsettings.json` рядом с бинарником + `/etc/home/home.json` (`HOME_CONFIG`) + переменные окружения `Home__…`;
  токен бота — из файла (`/etc/home/secrets/bot_token`).
- **Логи** — стандартный `ILogger` → journald (systemd), при желании Serilog.

### Хранение (SQLite, EF Core)

| Таблица | Содержимое |
|---|---|
| `Devices` | `DeviceId`, модель, имя, комната, статус (`New/Adopted/Blocked`), версия прошивки, IP, LastSeen |
| `PointDefs` | описание точек по `(Model, FwVersion)` |
| `SamplesRaw` | `(Device, Point, Ts, Value)` — 7 дней |
| `Samples1m` / `Samples1h` | min/max/avg — 90 дней / бессрочно |
| `Firmware` | модель, версия, sha256, размер, путь к файлу, changelog, канал |
| `OtaJobs` / `OtaJobItems` | задания раскатки, статус по устройствам |
| `Users` | `TelegramId` (= chat id личного чата), имя, роль, кто и когда добавил |
| `AccessRequests` | запросы доступа от незнакомых пользователей бота |
| `ApiTokens` | токены CLI (хэш), имя, срок |
| `Events` / `Audit` | события устройств и журнал действий пользователей |

Для истории — сырые данные в `SamplesRaw` пишутся пачками (раз в секунду), чтобы не делать транзакцию на каждое значение.

### HTTP API

`/api/v1`, JSON, OpenAPI генерируется ASP.NET Core (`Microsoft.AspNetCore.OpenApi`) → из него TS-клиент для Mini App.

```
GET    /devices                      список (+ текущие значения, онлайн)
GET    /devices/{id}                 описание, точки, сетевой статус
PATCH  /devices/{id}                 имя, комната
POST   /devices/{id}/adopt|reject
DELETE /devices/{id}
POST   /devices/{id}/points/{key}    {value}  — SET
POST   /devices/{id}/actions/{key}   {args}   — INVOKE
POST   /devices/{id}/reboot|identify|factory-reset
PUT    /devices/{id}/network         DHCP/статика
GET    /devices/{id}/history?point=co2&from=&to=&step=
GET/POST /rooms
GET    /firmware ; POST /firmware (multipart .bin)
POST   /ota/jobs ; GET /ota/jobs/{id}
GET/POST/PATCH/DELETE /users         управление доступом (admin)
GET    /access-requests ; POST /access-requests/{id}/approve|deny
GET/POST/DELETE /tokens
GET    /system ; GET /healthz
```

### Раскатка OTA

- Стратегии: одно устройство; все устройства модели; «канарейка» — сначала одно, после успешного `HELLO`
  с новой версией — остальные по N штук.
- Перед отправкой: модель в дескрипторе образа = модель устройства, `hw_rev` поддерживается, образ влезает в слот.
- Вернулось с новой версией → `Done`; со старой (сработал откат) → `RolledBack`, уведомление в бот.

## Доступ снаружи: белый IP + DuckDNS

Mini App открывается в WebView Telegram на телефоне — нужен HTTPS-адрес, доступный из интернета.

```
телефон → https://myhome.duckdns.org (белый IP) → роутер :443 → сервер Caddy :443 → Kestrel 127.0.0.1:8080
```

- **DuckDNS**: домен `<имя>.duckdns.org` → ваш белый IP. Обновление IP — systemd-таймер раз в 5 минут
  (`curl "https://www.duckdns.org/update?domains=<имя>&token=<token>&ip="`), даже если IP статический — на случай смены.
- **Caddy** получает и продлевает сертификат Let's Encrypt сам. На роутере пробросить **443/tcp**
  (TLS-ALPN-01) и желательно **80/tcp** (HTTP-01 + редирект на HTTPS). Если провайдер закрывает 80/443 —
  сертификат получается через DNS-01 по API DuckDNS (Caddy с плагином `caddy-dns/duckdns`),
  а Mini App открывается по нестандартному порту: `https://myhome.duckdns.org:8443`.
- **Если 443 уже занят другим приложением** — Home выставляется на другом внешнем порту, например 8443:
  `server-bootstrap.sh … --https-port 8443`. Caddy слушает только 8443, порты 80/443 не трогает, а сертификат получает
  через DNS-запись DuckDNS (модуль `caddy-dns/duckdns`, ставится скриптом). На роутере — проброс 8443 → сервер:8443,
  адрес Mini App — `https://<имя>.duckdns.org:8443`. Альтернатива без порта в адресе — добавить сайт `<имя>.duckdns.org`
  в уже работающий на 443 прокси (nginx/Caddy/Traefik) с `proxy_pass` на сервер Home `:8080`.
- Kestrel слушает HTTP **только на 127.0.0.1:8080** (и на LAN для локального CLI по желанию); наружу — только через Caddy.
- **Дома через Wi-Fi (NAT loopback / hairpin NAT).** Это отдельная от проброса портов вещь. Телефон в домашнем Wi-Fi
  открывает `myhome.duckdns.org` → домен указывает на **белый IP роутера** → запрос уходит на роутер изнутри сети и
  должен «развернуться» обратно на сервер по пробросу. Одни роутеры это умеют (Keenetic, MikroTik с правилом, большинство
  современных), другие — нет: тогда через мобильный интернет Mini App открывается, а из дома по Wi-Fi — нет.
  Проверка: после проброса портов открыть адрес с телефона по Wi-Fi и по мобильному интернету.
  Если из дома не открывается — включить NAT loopback/hairpin в настройках роутера, а если такой опции нет —
  добавить на роутере локальную DNS-запись `myhome.duckdns.org → LAN-IP сервера` (сертификат останется валидным).
- Бот использует long polling — входящие соединения ему не нужны.
- Защита публичного входа: всё API только с авторизацией, rate limiting (встроенный `Microsoft.AspNetCore.RateLimiting`),
  отдельного фронта для порта 7700 нет, SSH наружу не пробрасывается.

## Авторизация и пользователи

- **Mini App:** при открытии отправляет `Telegram.WebApp.initData`. Сервер проверяет подпись:
  `secret = HMAC_SHA256(key="WebAppData", msg=bot_token)`, `hash == HMAC_SHA256(key=secret, msg=data_check_string)`,
  и свежесть `auth_date`. Затем ищет `user.id` в `Users` → выдаёт токен сессии.
- **Кого пускать решает CLI (и Mini App для админов).** Идентификатор — Telegram user id; в личном чате с ботом
  `chat_id` совпадает с `user_id`, поэтому «добавить chat id» и «добавить пользователя» — одно и то же.

```
homectl users add 123456789 --name "Маша" --role user
homectl users list
homectl users role 123456789 admin
homectl users remove 123456789
```

- **Как узнать свой id:** написать боту `/start` — незнакомому пользователю бот отвечает
  «Ваш id 123456789, доступа нет, запрос отправлен администраторам», создаёт `AccessRequest`
  и шлёт админам сообщение с кнопками «Разрешить / Отклонить». Или админ: `homectl users requests` → `homectl users approve <id>`.
- **Роли:** `admin` — всё (принятие устройств, OTA, сброс, пользователи); `user` — управление и просмотр; `viewer` — только просмотр.
- **Первый администратор** — на сервере: `homectl users add <id> --role admin`
  (локальный CLI работает через unix-сокет `/run/home/api.sock` без токена, доступ — группа `home`).
- **CLI с другого компьютера:** `homectl login --server https://myhome.duckdns.org --token <токен>`,
  токен создаёт админ: `homectl tokens create --name laptop`.

## Mini App: экраны и UX

Принципы: крупные плитки, минимум текста, тема Telegram (`themeParams`), нативные `BackButton`/`MainButton`,
`HapticFeedback` при переключении, живые значения через SSE, работа одной рукой.

1. **Дом** — вкладки комнат; плитки: главное значение крупно, цвет по порогам, переключатели прямо на плитке
   (оптимистичное обновление), серая плитка — оффлайн.
2. **Устройство** — все точки по описанию, график 24ч/7д/30д (uPlot), «расширенные» свёрнуты, инфо: версия, IP, RSSI, аптайм.
3. **Новые устройства** — «Найдено новое устройство» → «Принять», комната, имя; «Мигнуть» чтобы понять, какое это.
4. **Прошивки** (admin) — образы по моделям, загрузка `.bin`, «Обновить все CO2 до 1.3.0», прогресс по каждому.
5. **Настройки** — пользователи и запросы доступа, уведомления (пороги CO2, оффлайн > N минут), о системе.

## Telegram-бот

- Кнопка меню → открыть Mini App.
- Уведомления: пороги, оффлайн, OTA завершено/откатилось, новое устройство, запрос доступа.
- Текстовые команды на всякий случай: `/start`, `/status`, `/co2`, `/id`.

## CLI `homectl`

Работает через тот же API → паритет с Mini App гарантирован. Вывод — таблицы, `--json` для скриптов.
Публикуется Native AOT (один маленький бинарник, мгновенный старт).

```
homectl login --server https://myhome.duckdns.org --token …
homectl devices list [--room kitchen] [--offline] [--new]
homectl devices show <dev>
homectl devices rename <dev> "Спальня CO2" ; devices move <dev> bedroom
homectl devices adopt <dev> ; devices reject <dev> ; devices remove <dev>
homectl get <dev> [point...]
homectl set <dev> <point> <value>               # homectl set relay-1 power on
homectl invoke <dev> <action> [k=v ...]         # homectl invoke co2-a1b2 calibrate ppm=420
homectl watch [<dev>]                            # живой поток значений/событий
homectl history <dev> <point> --since 24h [--step 5m] [--csv]
homectl logs <dev> [-f] [--level debug]
homectl reboot|identify <dev>
homectl factory-reset <dev> --mode settings|firmware|all
homectl net <dev> --dhcp | --ip 192.168.1.50/24 --gw 192.168.1.1 --dns 192.168.1.1
homectl fw list
homectl fw upload co2-egg-1.3.0.bin [--channel beta]
homectl fw flash <dev...> --version 1.3.0 | --model co2-egg --all [--canary]
homectl fw status [<job>]
homectl rooms list|add|remove
homectl users list|add|remove|role|requests|approve|deny
homectl tokens create|list|revoke
homectl system status             # бэкап — sudo home-backup (скрипт, ночной таймер)
homectl completion bash|zsh|fish
```

## Эмулятор устройств (`Home.Simulator`)

Реализация устройства на C# по тому же протоколу: подключается к серверу, отдаёт описание точек,
шлёт правдоподобную телеметрию, принимает команды и OTA (проверяет хэш). Для разработки без железа,
интеграционных тестов в CI и проверки обрывов связи / OTA-сбоев.
