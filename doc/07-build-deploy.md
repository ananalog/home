# 07. Сборка, подготовка сервера, деплой

## Целевой сервер

- Debian 12 / Ubuntu 24.04 (x86_64 мини-ПК или Raspberry Pi 4/5 arm64).
- Статический IP или DHCP-резервация (устройства найдут и по mDNS, но так надёжнее).
- Никаких рантаймов: Go-бинарник статический, SQLite встроен (`modernc.org/sqlite`, без CGO).

### Раскладка на сервере

```
/opt/home/releases/<version>/home     бинарник (+ встроенный Mini App)
/opt/home/current -> releases/<version>
/usr/local/bin/homectl -> /opt/home/current/home
/etc/home/config.toml                 конфиг (порты, путь БД, bot token из файла)
/etc/home/secrets/bot_token           0600, владелец home
/var/lib/home/home.db                 БД
/var/lib/home/firmware/               образы прошивок
/var/lib/home/keys/server.key         ключ X25519 сервера
/var/backups/home/                    ночные бэкапы
/run/home/api.sock                    unix-сокет для локального CLI
```

## Скрипты репозитория `home`

```
Makefile
scripts/
  build.sh             сборка miniapp + бинарников amd64/arm64 → dist/
  server-bootstrap.sh  подготовка чистого сервера (идемпотентно)
  deploy.sh            выкладка релиза на сервер + проверка + откат
  backup.sh            ручной бэкап/восстановление
deploy/
  home.service         systemd-юнит
  home-backup.service / home-backup.timer
  cloudflared/config.yml.example
  config.toml.example
  nftables.conf.example
```

### `make` цели

```
make proto        # подтянуть/сгенерировать код протокола (версия из go.mod)
make miniapp      # npm ci && npm run build → web/dist
make build        # miniapp + go build для текущей платформы
make release      # dist/home-<ver>-linux-{amd64,arm64}.tar.gz + sha256
make test         # go test ./... + тесты miniapp + интеграционные с эмулятором
make lint         # golangci-lint, eslint/svelte-check
make deploy HOST=home.lan [VERSION=…]
make dev          # сервер + vite dev + 3 эмулятора, Mini App через quick-tunnel
```

### `server-bootstrap.sh` (запуск один раз, повторный запуск безопасен)

1. Проверка ОС/архитектуры, `apt install` минимума: `ca-certificates curl sqlite3 nftables chrony`.
2. Системный пользователь и группа `home`, каталоги с правами (см. раскладку).
3. Генерация ключа сервера (если нет), шаблон `config.toml`, запрос токена бота (или флаг `--bot-token-file`).
4. systemd-юнит с hardening:
   `DynamicUser=no, User=home, ProtectSystem=strict, ReadWritePaths=/var/lib/home /run/home,
   NoNewPrivileges=yes, PrivateTmp=yes, CapabilityBoundingSet=, RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK`.
5. Firewall (nftables): входящие из LAN — `7700/tcp` (устройства), `5353/udp` (mDNS), `7701/udp` (discover),
   `8080/tcp` (API из LAN, по желанию), `22/tcp`; всё остальное закрыто.
6. Cloudflare Tunnel (если выбран): установка `cloudflared`, `cloudflared tunnel login/create`,
   маршрут `home.example.com → http://localhost:8080`, сервис systemd.
7. Таймер бэкапов: ночью `sqlite3 .backup` (консистентно при работе) + каталог прошивок,
   хранение 14 копий, опционально выгрузка (rclone) наружу.
8. journald: ограничение размера логов.
9. Итог: вывод чек-листа (адрес Mini App, как добавить первого админа, как настроить бота в @BotFather).

Альтернатива для нескольких серверов или «инфраструктуры как кода» — тот же набор шагов ролью Ansible;
для одного домашнего сервера bash-скрипта достаточно.

Docker не используется для сервера намеренно: mDNS/broadcast требуют `network_mode: host`,
а выигрыша у одного статического бинарника нет. Если хочется — `Dockerfile` можно добавить как опцию.

### `deploy.sh`

```
deploy.sh <host> [version]
  1. берёт dist/home-<ver>-linux-<arch>.tar.gz (arch определяет по `ssh uname -m`)
  2. проверяет sha256, копирует в /opt/home/releases/<ver>/
  3. бэкап БД перед миграцией
  4. home migrate --check (совместимость миграций)
  5. переключает симлинк current, systemctl restart home
  6. ждёт /healthz = ok и переподключения устройств (N из M за 60 с)
  7. при неудаче — симлинк назад, восстановление БД из шага 3, restart, код ошибки
  8. чистит старые релизы (хранит 5)
```

Доставка — `ssh`/`rsync` по ключу. Деплой на сервер из CI возможен (self-hosted runner в домашней сети
или через туннель), но на старте надёжнее запускать вручную с ноутбука.

## Прошивки (`home-firmware`)

```
scripts/
  fw-build.sh <device> [--release]   сборка в Docker espressif/idf:vX.Y
  fw-flash-usb.sh <device> <port>    первичная «заводская» прошивка по USB
  fw-publish.sh <device> <server>    загрузка релиза на сервер (homectl fw upload)
  fw-monitor.sh <port>               idf.py monitor
```

- **Версия** — из git-тега `co2-egg/v1.2.0` (`git describe`), вшивается в `esp_app_desc_t.version`.
- **Результат сборки** в `dist/co2-egg/1.2.0/`:
  `bootloader.bin`, `partition-table.bin`, `ota_data_initial.bin`, `co2-egg-1.2.0.bin` (приложение),
  `manifest.json` (модель, версия, sha256, размер, hw_rev, proto, git commit), `co2-egg-1.2.0.elf` (для разбора крэшей).
- **`fw-flash-usb.sh`** (esptool): стирает flash, пишет bootloader, таблицу разделов, `otadata`,
  образ в **`factory`**, генерирует и пишет раздел `fctry` (`tools/mkfactory.py` → NVS-образ через
  `nvs_partition_gen.py`: серийник, hw_rev, PIN для устройств без экрана), печатает данные для наклейки/QR.
- Проверка размера: сборка падает, если приложение занимает > 90% слота.
- Воспроизводимость: фиксированная версия Docker-образа IDF и `dependencies.lock` компонентов.

## Android (`home-android`)

- `./gradlew assembleDebug` / `assembleRelease`; ключ подписи — из секретов CI (`KEYSTORE_BASE64`, пароли).
- Версия — из тега (`versionName`), `versionCode` — из числа коммитов/тега.

## CI (GitHub Actions)

| Репозиторий | На PR | На тег |
|---|---|---|
| `home-protocol` | генерация + проверка, что сгенерированный код закоммичен; тест-векторы на Go/C (host gcc)/Kotlin | релиз с архивами кода |
| `home` | lint, `go test`, тесты miniapp, интеграция «сервер + эмуляторы» | `make release`, GitHub Release с бинарниками amd64/arm64 и sha256 |
| `home-firmware` | сборка всех устройств в Docker IDF, юнит-тесты драйверов (host), контроль размера | Release с `.bin` + `manifest.json` для устройства из тега |
| `home-android` | сборка, юнит-тесты, lint | подписанный APK в Release |

Кэширование: Go modules, npm, Gradle, ccache для IDF.

## Разработка Mini App

- Бот для разработки отдельный (`@myhome_dev_bot`), свой URL Mini App.
- `make dev`: сервер на `:8080`, `vite` с HMR, `cloudflared tunnel --url http://localhost:5173`
  (быстрый туннель с временным HTTPS-адресом) → адрес прописывается dev-боту.
- Вне Telegram Mini App открывается в браузере с поддельным `initData` в dev-режиме
  (только при `HOME_DEV=1`, в релизной сборке такой код не компилируется).
