# 05. Общее ядро прошивки ESP32

Все устройства строятся на общем компоненте `home_core`; код конкретного устройства —
это описание точек + драйверы + логика, обычно несколько сотен строк.

## Фреймворк

**ESP-IDF v5.x** (C), не Arduino:
- полный контроль таблицы разделов (`factory` + два OTA-слота);
- OTA с автоматическим откатом (`CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE`);
- NimBLE (легче Bluedroid по RAM/flash);
- аппаратный SHA-256 для проверки OTA-образов;
- шифрование в LAN и по BLE не используется (решение владельца); при необходимости позже включаются
  LE Secure Connections, Secure Boot v2 и Flash Encryption без изменения протокола.

Сборка — в Docker-образе `espressif/idf:v5.x` (версия закреплена), см. [07-build-deploy.md](07-build-deploy.md).

## Структура репозитория `home-firmware`

```
components/
  home_proto/        сгенерированный кодек (зависимость на home-protocol через idf_component.yml)
  home_core/
    include/home.h   публичный API для устройств
    src/
      core.c         инициализация, конечный автомат, event loop
      config.c       настройки в NVS (сеть, сервер, имя, режим BLE)
      net.c          Wi-Fi STA, DHCP/статический IP, hostname, переподключения
      discovery.c    mDNS-поиск _home._tcp, UDP DISCOVER
      link.c         TCP-сессия с сервером, фрейминг + CRC, ping, очередь исходящих
      ble.c          GATT-сервис, фрагментация, код с экрана / окно после кнопки
      dispatch.c     обработка сообщений (общая для TCP и BLE)
      points.c       реестр точек, DESCRIBE/GET/SET/REPORT
      ota.c          OTA_BEGIN/DATA/END, возобновление, пометка валидности
      reset.c        сброс настроек / к заводской прошивке, кнопка
      logfwd.c       перехват esp_log → кольцевой буфер → сообщения LOG
      buffer.c       буфер телеметрии на время оффлайна
      identity.c     device_id, заводские данные
    Kconfig
  drivers/
    acd1200/  scd4x/  ssd1306/  button/ ...
devices/
  co2-egg/
    main/ main.c board.h points.c display.c
    partitions.csv
    sdkconfig.defaults
    version.txt
tools/
  mkfactory.py       генерация раздела fctry (NVS) с device-данными
```

## API для устройства

```c
static const home_point_t points[] = {
  { .id = 1, .key = "co2", .kind = HOME_SENSOR, .type = HOME_F32, .unit = "ppm",
    .min = 400, .max = 5000, .ui = HOME_UI_GAUGE, .flags = HOME_F_HISTORY,
    .thresholds = {800, 1200} },
  { .id = 10, .key = "report_interval", .kind = HOME_SETTING, .type = HOME_I32,
    .unit = "s", .min = 5, .max = 600, .def = 30, .flags = HOME_F_PERSIST },
  { .id = 20, .key = "calibrate", .kind = HOME_ACTION, .args = calibrate_args },
};

void app_main(void) {
  home_core_start(&(home_device_t){
    .model = HOME_MODEL_CO2_EGG, .hw_rev = 1,
    .points = points, .n_points = countof(points),
    .on_set = on_set, .on_invoke = on_invoke,
  });
  // дальше — своя задача опроса датчика:
  home_report_f32(1, ppm);   // ядро само решает: отправить сейчас, буферизовать, склеить
}
```

Ядро само: хранит `PERSIST`-настройки в NVS, отвечает на `DESCRIBE/GET`, валидирует `SET`
по min/max, шлёт `STATE` после подключения, отдаёт состояние на экран устройства через колбэки.

## Задачи и состояния

FreeRTOS-задачи: `net` (Wi-Fi + link), `ble`, `app` (датчик), `ui` (экран/светодиод).
Общение — через `esp_event` и очереди.

```
BOOT → [нет Wi-Fi-настроек] → UNCONFIGURED (только BLE, экран «настройте»)
     → [есть]              → WIFI_CONNECTING → IP_OK → SERVER_DISCOVERY
                            → HANDSHAKE → PENDING_ADOPTION | ONLINE
ONLINE ⇄ OFFLINE (буферизация телеметрии, переподключение с backoff 1…60 с)
```

BLE работает параллельно во всех состояниях (режим `always`). На ESP32-C3 один радиотракт,
Wi-Fi и BLE сосуществуют через coexistence — для нашего трафика этого достаточно.

## Сеть

- Wi-Fi STA, настройки храним сами (`esp_wifi_set_storage(WIFI_STORAGE_RAM)`) в NVS-пространстве `net`.
- **DHCP** (по умолчанию) или **статика**: IP, маска, шлюз, DNS1/DNS2
  (`esp_netif_dhcpc_stop` + `esp_netif_set_ip_info` + `esp_netif_set_dns_info`).
- Hostname: `home-co2-a1b2` (виден в роутере).
- Защита от «кирпича» после неверной статики: если за 2 минуты нет связи со шлюзом/сервером,
  а до изменения была — откат к предыдущим сетевым настройкам (как «подтверждение изменений» в роутерах).
  BLE всё это время доступен.
- Сервер: заданный адрес или mDNS.

## Разделы flash (4 МБ)

```csv
# Name,    Type, SubType, Offset,   Size
nvs,       data, nvs,     0x9000,   0x6000
otadata,   data, ota,     0xF000,   0x2000
phy_init,  data, phy,     0x11000,  0x1000
factory,   app,  factory, 0x20000,  0x140000
ota_0,     app,  ota_0,   0x160000, 0x140000
ota_1,     app,  ota_1,   0x2A0000, 0x140000
fctry,     data, nvs,     0x3E0000, 0x6000
storage,   data, nvs,     0x3E6000, 0x1A000
```

- Три слота приложения по 1.25 МБ (Wi-Fi + NimBLE + крипто + экран при `-Os` ≈ 1.0–1.1 МБ,
  следить за размером в CI: сборка падает при заполнении > 90%).
- `nvs` — пользовательские настройки (сбрасываются). `fctry` — заводские данные
  (hw_rev, серийник, дата производства), **не сбрасываются**.
  `storage` — калибровочные/служебные данные ядра.
- Размер flash платы нужно подтвердить (см. [06-co2-egg.md](06-co2-egg.md)); при 8 МБ слоты увеличиваются.

## OTA и откат

1. Образ пишется в следующий свободный `ota_N` (`factory` никогда не перезаписывается по воздуху).
2. После `OTA_END` и проверки SHA-256 — `esp_ota_set_boot_partition`, перезагрузка.
3. Новая прошивка стартует в состоянии `PENDING_VERIFY`. Она помечает себя валидной
   (`esp_ota_mark_app_valid_cancel_rollback`), когда:
   - установлена сессия с сервером (`WELCOME` получен), **или**
   - по BLE выполнена команда «подтвердить прошивку» (прошивка с телефона без сервера).
4. Не подтвердилась за 5 минут, упала/перезагрузилась до подтверждения →
   загрузчик возвращает предыдущий слот. Сервер увидит старую версию → `rolled_back`.

### Дескриптор образа

Кроме стандартного `esp_app_desc_t` (project_name, version, дата сборки, версия IDF) в образ
кладётся собственный дескриптор в секции `.rodata_custom_desc`:

```c
typedef struct {
  uint32_t magic;          // 'HOME'
  uint16_t model;          // HOME_MODEL_CO2_EGG = 0x0001
  uint16_t hw_rev_mask;    // поддерживаемые ревизии платы
  uint8_t  proto_major, proto_minor;
  uint8_t  reserved[22];
} home_image_desc_t;
```

Сервер и Android читают его из `.bin` (фиксированное смещение после `esp_app_desc_t`) и не дают
прошить образ не той модели.

## Сброс

| Режим | Что происходит |
|---|---|
| `settings` | стирается раздел `nvs` (Wi-Fi, IP, сервер, имя, пользовательские настройки); прошивка остаётся |
| `firmware` | `esp_ota_set_boot_partition(factory)` — загрузка заводской прошивки; настройки остаются |
| `all` | оба пункта: устройство как с завода |

Источники: BLE (Android), сервер (Mini App/CLI, только admin), кнопка на устройстве:
- удержание 5 с — `settings` (на экране обратный отсчёт, отпустил — отмена);
- удержание 15 с — `all`.

**Аварийный путь, если приложение не запускается вообще:** загрузчик ESP-IDF умеет
`CONFIG_BOOTLOADER_FACTORY_RESET` — если при старте удерживать выбранный GPIO, стирает `nvs`
и грузит `factory`. Важно: GPIO9 (BOOT) на ESP32-C3 — strapping-пин (удержание при сбросе
включает режим загрузки ROM), поэтому для этой функции нужен другой свободный пин
(выберем после изучения схемы платы). Сбой новой прошивки при запуске и так закрывается автоматическим
откатом (см. выше). Последний рубеж — прошивка по USB.

## Идентичность

- `device_id` = базовый MAC (6 байт), в UI — `A1B2` (последние 2 байта).
- Модели — реестр в `home-protocol` (`0x0001 co2-egg`, `0x0002 relay-…`, …).

## Логи и диагностика

- `esp_log` перехватывается (`esp_log_set_vprintf`) → кольцевой буфер 8 КБ → сообщения `LOG`
  на сервер/телефон (уровень задаётся удалённо), плюс UART/USB-Serial-JTAG как обычно.
- Причина последней перезагрузки, свободная куча, минимум кучи, RSSI — в `HELLO`/`NET_STATUS`.
- Core dump в flash (`CONFIG_ESP_COREDUMP_ENABLE_TO_FLASH`) с выгрузкой на сервер — этап 2.
- Task WDT включён; зависание задачи → перезагрузка → сервер видит `reset_reason`.

## Время и оффлайн-буфер

- Время берётся из `WELCOME` (сервер — источник времени; NTP в интернет устройствам не нужен).
- Пока нет связи, показания складываются в кольцевой буфер в RAM (например 240 записей)
  с отметками времени и досылаются пачкой `REPORT` после переподключения.
