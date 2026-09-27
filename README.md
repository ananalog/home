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

## Клонирование

```
git clone --recursive https://github.com/ananalog/home
# если уже склонировано без --recursive:
git submodule update --init --recursive
# подтянуть свежие версии всех компонентов:
git submodule update --remote --recursive
```
