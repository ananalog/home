# Home

Система управления домашними устройствами: сервер в локальной сети (.NET), датчики и устройства на ESP32,
Telegram Mini App и CLI `homectl`, Android-приложение для настройки устройств по Bluetooth.

## Состав

| Путь | Репозиторий | Что внутри |
|---|---|---|
| [`doc/`](doc/README.md) | — | исследования и проектные решения |
| `protocol/` | [home-protocol](https://github.com/ananalog/home-protocol) | бинарный протокол: схема, генератор, тест-векторы |
| `server/` | [home-server](https://github.com/ananalog/home-server) | сервер, `homectl`, эмулятор, Mini App |
| `firmware/` | [home-firmware](https://github.com/ananalog/home-firmware) | прошивки ESP32 (ESP-IDF) |
| `android/` | [home-android](https://github.com/ananalog/home-android) | Android-приложение |

`server`, `firmware` и `android` сами подключают `home-protocol` сабмодулем в `external/home-protocol`,
поэтому каждый из них собирается и отдельно.

## Состояние

Все этапы реализованы в первом приближении, серверная часть покрыта тестами; прошивка и Android-приложение
ждут проверки на железе. Подробно и пошаговый первый запуск — [doc/09-status.md](doc/09-status.md).

## Клонирование

```
git clone --recursive https://github.com/ananalog/home
# если уже склонировано без --recursive:
git submodule update --init --recursive
# подтянуть свежие версии всех компонентов:
git submodule update --remote --recursive
```

## Частые команды

```
make build                          # всё в dist/ (с тестами)
make deploy HOST=user@192.168.1.10  # релиз сервера с проверкой и откатом
make firmware DEVICE=co2-egg        # прошивка
make fw-publish HOST=user@192.168.1.10
make check                          # все компоненты на одной версии протокола
```

Подготовка чистого сервера — `sudo scripts/server-bootstrap.sh --help`.
