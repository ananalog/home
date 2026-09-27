# 07. Сборка, подготовка сервера, деплой

## Целевой сервер

- **x86_64**, Debian 12/13 или Ubuntu 24.04 LTS.
- Статический IP в LAN или DHCP-резервация на роутере (нужна для проброса портов).
- Белый IP у провайдера + домен **DuckDNS**.
- .NET-рантайм на сервере **не нужен**: сервер публикуется self-contained single-file (`linux-x64`),
  `homectl` — Native AOT.

### Раскладка на сервере

```
/opt/home/releases/<version>/home-server    сервер (+ wwwroot с Mini App рядом)
/opt/home/releases/<version>/homectl        CLI
/opt/home/current -> releases/<version>
/usr/local/bin/homectl -> /opt/home/current/homectl
/etc/home/appsettings.Production.json       конфиг (порты, путь БД, домен, настройки уведомлений)
/etc/home/secrets/bot_token                 0600, владелец home
/etc/home/secrets/duckdns_token             0600, root
/etc/caddy/Caddyfile                        reverse proxy + TLS
/var/lib/home/home.db                       БД (SQLite)
/var/lib/home/firmware/                     образы прошивок
/var/backups/home/                          ночные бэкапы
/run/home/api.sock                          unix-сокет для локального CLI
```

## Зонтичный репозиторий `home`

```
home/
  doc/
  protocol/  server/  firmware/  android/     сабмодули
  scripts/
    build-all.sh          собрать всё: протокол → сервер → прошивки → APK → dist/
    server-bootstrap.sh   подготовка чистого сервера (идемпотентно)
    deploy.sh             выкладка релиза сервера + проверка + откат
    fw-publish.sh         загрузить собранные прошивки на сервер (homectl fw upload)
    check-protocol.sh     все компоненты ссылаются на совместимую версию home-protocol
    backup.sh             ручной бэкап/восстановление
  deploy/
    home.service                       systemd-юнит сервера
    home-backup.service / .timer       ночной бэкап
    duckdns.service / duckdns.timer    обновление IP в DuckDNS
    Caddyfile.example
    appsettings.Production.json.example
    nftables.conf.example
  Makefile
```

### `make` цели зонтика

```
make init          # git submodule update --init --recursive
make update        # подтянуть последние версии сабмодулей (осознанно, с коммитом в зонтик)
make build         # scripts/build-all.sh
make server        # только сервер + CLI + Mini App → dist/server/
make firmware      # все устройства в Docker ESP-IDF → dist/firmware/
make android       # APK → dist/android/
make test          # тесты всех компонентов
make deploy HOST=home.lan
make fw-publish HOST=home.lan
```

## Сборка сервера (`home-server`)

```
cd web/miniapp && npm ci && npm run build            # → src/Home.Server/wwwroot
dotnet test
dotnet publish src/Home.Server -c Release -r linux-x64 --self-contained \
    -p:PublishSingleFile=true -o dist/server
dotnet publish src/Home.Cli -c Release -r linux-x64 -p:PublishAot=true -o dist/server
tar czf home-<ver>-linux-x64.tar.gz -C dist/server .
```

- Версия — из git-тега (`MinVer` или `-p:Version=`), видна в `/api/v1/system` и `homectl system status`.
- Можно собирать и на Windows/macOS: кросс-публикация под `linux-x64` работает для self-contained;
  для Native AOT `homectl` сборка должна идти на Linux (или в Docker `mcr.microsoft.com/dotnet/sdk:10.0`).

## `server-bootstrap.sh`

Запускается один раз на чистом сервере (`sudo ./server-bootstrap.sh --domain myhome --duckdns-token-file … --bot-token-file …`),
повторный запуск безопасен.

1. Проверка ОС/архитектуры (x86_64), `apt install`: `ca-certificates curl sqlite3 nftables chrony caddy`
   (Caddy — из официального apt-репозитория).
2. Системный пользователь и группа `home`, каталоги с правами (см. раскладку).
3. Секреты: токен бота и токен DuckDNS в `/etc/home/secrets/` (0600).
4. **DuckDNS**: `duckdns.timer` раз в 5 минут вызывает
   `curl -fsS "https://www.duckdns.org/update?domains=<имя>&token=$(cat …)&ip="`; первый вызов — сразу, с проверкой ответа `OK`.
5. **Caddy**: `Caddyfile`
   ```
   myhome.duckdns.org {
       encode zstd gzip
       reverse_proxy 127.0.0.1:8080
   }
   ```
   Caddy сам получает сертификат Let's Encrypt (нужен проброс 443, желательно и 80 на роутере).
6. systemd-юнит `home.service` с hardening:
   `User=home, ProtectSystem=strict, ReadWritePaths=/var/lib/home /run/home, NoNewPrivileges=yes, PrivateTmp=yes,
   CapabilityBoundingSet=, RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK`,
   `Environment=DOTNET_ENVIRONMENT=Production`, `Restart=always`.
7. **Firewall** (nftables):
   - из интернета (через роутер): только `443/tcp` и `80/tcp` → Caddy;
   - из LAN: `7700/tcp` (устройства), `5353/udp` (mDNS), `7701/udp` (discover), `22/tcp` (SSH), `8080/tcp` (API для CLI в LAN — по желанию);
   - всё остальное закрыто.
8. Таймер бэкапов: ночью `sqlite3 home.db ".backup …"` + каталог прошивок, хранение 14 копий.
9. journald: ограничение размера логов.
10. Итоговый чек-лист на экран:
    - пробросить на роутере 443 (и 80) → IP сервера;
    - в @BotFather: создать бота, `/newapp` или «Menu Button» → `https://myhome.duckdns.org`;
    - добавить первого админа: `homectl users add <ваш telegram id> --role admin`;
    - проверить: `curl https://myhome.duckdns.org/healthz`.

## `deploy.sh`

```
deploy.sh <host> [version]
  1. берёт dist/server/home-<ver>-linux-x64.tar.gz, проверяет sha256
  2. копирует (rsync по ssh) в /opt/home/releases/<ver>/
  3. бэкап БД перед миграциями
  4. переключает симлинк current, systemctl restart home (миграции EF Core применяются при старте)
  5. ждёт /healthz = ok и переподключения устройств (N из M за 60 с)
  6. при неудаче — симлинк назад, восстановление БД из шага 3, restart, ненулевой код выхода
  7. удаляет старые релизы (хранит 5)
```

Запускается с рабочего компьютера по SSH-ключу. Автодеплой из CI — позже (self-hosted runner на самом сервере).

## Прошивки (`home-firmware`)

```
scripts/
  fw-build.sh <device> [--release]   сборка в Docker espressif/idf:vX.Y (версия закреплена)
  fw-flash-usb.sh <device> [port]    первичная прошивка по USB
  fw-monitor.sh [port]               idf.py monitor
```

- **Версия** — из git-тега `co2-egg/v1.2.0`, вшивается в `esp_app_desc_t.version`.
- **Результат** в `dist/co2-egg/1.2.0/`: `bootloader.bin`, `partition-table.bin`, `ota_data_initial.bin`,
  `co2-egg-1.2.0.bin`, `manifest.json` (модель, версия, sha256, размер, hw_rev, proto, commit), `.elf` для разбора крэшей.
- **`fw-flash-usb.sh`** (esptool): стирает flash, пишет bootloader, таблицу разделов, `otadata`,
  образ в **`factory`**, раздел `fctry` (`tools/mkfactory.py` → `nvs_partition_gen.py`: серийник, hw_rev),
  печатает `device_id`.
- Сборка падает, если приложение занимает > 90% слота.
- Публикация на сервер — из зонтика: `scripts/fw-publish.sh` → `homectl fw upload dist/firmware/...`.

## Android (`home-android`)

- `./gradlew assembleDebug` / `assembleRelease`; ключ подписи — из переменных окружения / секретов CI.
- Версия — из тега (`versionName`), `versionCode` — счётчик.

## CI (GitHub Actions)

| Репозиторий | На PR | На тег |
|---|---|---|
| `home-protocol` | генерация + проверка, что сгенерированный код закоммичен; тест-векторы на C# / C (gcc на хосте) / Kotlin | релиз |
| `home-server` | `dotnet test` (юнит + интеграционные с эмуляторами), сборка Mini App, lint | архив linux-x64 + sha256 в Release |
| `home-firmware` | сборка всех устройств в Docker IDF, host-тесты драйверов, контроль размера | `.bin` + `manifest.json` в Release |
| `home-android` | сборка, юнит-тесты, lint | подписанный APK |
| `home` (зонтик) | `make init` + `check-protocol.sh` + `make build` (дымовой тест всего набора) | — |

## Разработка Mini App

- Отдельный dev-бот (`@myhome_dev_bot`) с URL Mini App на dev-адрес.
- Локально: сервер на `:8080` + `vite` с HMR; для открытия в Telegram нужен HTTPS — удобнее всего поднять
  dev-стенд прямо на домашнем сервере под поддоменом (например вторым доменом DuckDNS `myhome-dev.duckdns.org`
  в том же Caddyfile → порт dev-сервера).
- Вне Telegram Mini App открывается в браузере с поддельным `initData` только в `Development`-окружении
  (в Production этот путь отключён).
