# 03. Сервер, Telegram Mini App, бот, CLI

## Сервер (`home-server`)

Один бинарник Go. Подкоманды одного бинарника:
`home serve` — сервер, `home ctl …` (он же симлинк `homectl`) — CLI, `home sim` — эмулятор устройств.

### Структура пакетов (репозиторий `home`)

```
cmd/home/                 main: serve | ctl | sim | migrate | backup
internal/gateway/         TCP :7700, Noise-сессии, маршрутизация сообщений, ping
internal/discovery/       mDNS-анонс _home._tcp, ответ на UDP DISCOVER
internal/registry/        устройства, точки, комнаты, принятие
internal/telemetry/       приём REPORT, запись истории, агрегации
internal/ota/             хранилище прошивок, парсинг образов, задания раскатки
internal/api/             REST + WebSocket, OpenAPI
internal/auth/            Telegram initData, токены CLI, роли
internal/bot/             Telegram-бот: уведомления, кнопка открытия Mini App
internal/rules/           автоматизации (этап 2)
internal/store/           SQLite, миграции
pkg/client/               Go-клиент API (используется CLI и интеграционными тестами)
web/miniapp/              Svelte-приложение, собирается в web/dist и встраивается через embed
deploy/                   systemd-юниты, скрипты (см. 07)
```

### Хранение

SQLite в режиме WAL, файл `/var/lib/home/home.db`.

| Таблица | Содержимое |
|---|---|
| `devices` | `device_id`, модель, имя, комната, публичный ключ, статус (`pending/adopted/blocked`), последняя версия, last_seen |
| `points` | описание точек по `(model, fw_version)` |
| `samples_raw` | `(device, point, ts, value)` — 7 дней |
| `samples_1m` / `samples_1h` | min/max/avg — 90 дней / бессрочно |
| `firmware` | модель, версия, sha256, размер, путь к файлу, changelog, канал (`stable/beta`) |
| `ota_jobs` | задания: устройства, статус, прогресс, ошибки |
| `users` | telegram_id, имя, роль (`admin`/`user`/`viewer`) |
| `tokens` | токены CLI (хэш), описание, срок |
| `events` / `audit` | события устройств и журнал действий пользователей (кто что переключил/прошил) |

Даунсэмплинг — фоновой задачей раз в минуту/час. Для десятков датчиков это мегабайты в год.

### HTTP API

`/api/v1`, JSON, описан в OpenAPI (`api/openapi.yaml`) → из него генерируется TS-клиент для Mini App.

```
GET    /devices                      список (+ текущие значения, онлайн)
GET    /devices/{id}                 описание, точки, сетевой статус
PATCH  /devices/{id}                 имя, комната
POST   /devices/{id}/adopt|reject    принятие
DELETE /devices/{id}
POST   /devices/{id}/points/{key}    {value}  — SET
POST   /devices/{id}/actions/{key}   {args}   — INVOKE
POST   /devices/{id}/reboot|identify|factory-reset
GET    /devices/{id}/history?point=co2&from=&to=&step=
GET    /devices/{id}/logs            (live — через WS)
GET/POST /rooms
GET    /firmware                     список образов
POST   /firmware                     загрузка .bin (multipart)
POST   /ota/jobs                     {firmware_id, devices[] | model, strategy}
GET    /ota/jobs/{id}
GET/POST/DELETE /users, /tokens
GET    /system                       версия, аптайм, место на диске, статус туннеля
GET    /ws                           поток: values, online/offline, ota progress, events, logs
GET    /healthz
```

### Раскатка OTA

- Стратегии: одно устройство; все устройства модели; «канарейка» — сначала одно,
  после его успешного `HELLO` с новой версией — остальные по N штук.
- Перед отправкой сервер проверяет: модель в дескрипторе образа = модель устройства,
  `hw_rev` входит в список поддерживаемых, образ не меньше/не больше раздела.
- Результат: устройство вернулось с новой версией → `done`; вернулось со старой
  (сработал откат) → `rolled_back`, уведомление в бот.

## Доступ к Mini App извне

Mini App открывается в WebView Telegram на телефоне пользователя — **ему нужен HTTPS-адрес,
доступный с телефона**, в том числе вне дома.

| Вариант | Плюсы | Минусы |
|---|---|---|
| **Cloudflare Tunnel** (рекомендуется) | бесплатно, без белого IP и проброса портов, HTTPS автоматически, можно добавить Cloudflare Access | нужен домен в Cloudflare; трафик идёт через CF |
| VPS + WireGuard + Caddy | полный контроль | платный VPS, больше настройки |
| Tailscale Funnel | просто | домен `*.ts.net`, ограничения |
| Только дома: домен → LAN-IP + сертификат Let's Encrypt через DNS-01 | ничего не торчит наружу | не работает вне домашней сети |

Бот использует **long polling** — входящие соединения ему не нужны вообще.
Порт устройств 7700 наружу **никогда** не публикуется: туннель проксирует только HTTP `:8080`.

## Авторизация

- **Mini App:** при открытии приложение отправляет `Telegram.WebApp.initData`. Сервер проверяет
  подпись: `secret = HMAC_SHA256(key="WebAppData", msg=bot_token)`,
  `hash == HMAC_SHA256(key=secret, msg=data_check_string)`, и свежесть `auth_date` (≤ 1 час).
  Затем ищет `user.id` в таблице `users` → выдаёт короткоживущий токен сессии.
- **Роли:** `admin` — всё (принятие, OTA, сброс, пользователи); `user` — управление и просмотр;
  `viewer` — только просмотр.
- **Первый администратор:** `homectl users add <telegram_id> --role admin` на сервере
  или `HOME_BOOTSTRAP_ADMIN` в конфиге.
- **CLI:** на самом сервере — через unix-сокет `/run/home/api.sock` (доступ по группе `home`,
  токен не нужен); с ноутбука — по HTTP с токеном (`homectl login --server … --token …`).

## Mini App: экраны и UX

Принципы: крупные плитки, минимум текста, тема и цвета Telegram (`themeParams`),
нативные `BackButton`/`MainButton`, тактильная отдача (`HapticFeedback`) при переключении,
живые значения через WebSocket, работа одной рукой.

1. **Дом** — вкладки комнат; плитки устройств: главное значение крупно, цвет по порогам,
   тап по переключателю — мгновенное действие (оптимистичное обновление), серая плитка — оффлайн.
2. **Устройство** — все точки по описанию (датчики, переключатели, слайдеры, кнопки действий),
   график 24ч/7д/30д (uPlot), «расширенные» настройки свёрнуты, инфо: версия, IP, RSSI, аптайм.
3. **Новые устройства** — баннер «Найдено новое устройство», код сверки, «Принять», выбор комнаты и имени.
4. **Прошивки** (admin) — список образов по моделям, загрузка `.bin` из файла,
   «Обновить все CO2 до 1.3.0», прогресс по каждому устройству.
5. **Настройки** — пользователи, уведомления (пороги CO2, оффлайн > N минут), о системе.

## Telegram-бот

- Кнопка меню → открыть Mini App.
- Уведомления: превышение порогов, устройство оффлайн, OTA завершено/откатилось, новое устройство.
- Пара текстовых команд на случай, если WebView недоступен: `/status`, `/co2`.

## CLI `homectl`

Работает через тот же API → паритет с Mini App гарантирован. Вывод — таблицы, `--json` для скриптов.

```
homectl login --server https://home.example.com --token …
homectl devices list [--room kitchen] [--offline]
homectl devices show <dev>
homectl devices rename <dev> "Спальня CO2" ; devices move <dev> bedroom
homectl devices adopt <dev> [--code 1234] ; devices reject <dev> ; devices remove <dev>
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
homectl fw upload dist/co2-egg-1.3.0.bin [--channel beta]
homectl fw flash <dev...> --version 1.3.0 | --model co2-egg --all [--canary]
homectl fw status [<job>]
homectl rooms list|add|remove
homectl users list|add <tg_id> --role admin|remove
homectl tokens create --name laptop | revoke
homectl system status ; homectl backup ./home-backup.db
homectl sim co2-egg --count 3                    # эмулятор устройств для разработки
```

Автодополнение для bash/zsh/fish (cobra генерирует).

## Эмулятор устройств (`home sim`)

Go-реализация устройства по тому же протоколу: подключается к серверу, отдаёт описание
точек, шлёт правдоподобную телеметрию, принимает команды и даже OTA (проверяет хэш).
Нужен, чтобы:
- разрабатывать сервер и Mini App без железа;
- гонять интеграционные тесты в CI (сервер + 10 эмуляторов + сценарии через `pkg/client`);
- проверять поведение при обрывах связи и OTA-сбоях.
