# Перечень релизных файлов и соответствие имён

Состав выпуска **CSQTT 2.0** и таблица «публичное имя файла ↔ внутренний
пакет». Схема публичных имён **согласована с владельцем**; ядро 2.5.0 в
публичном имени называется **`csqtt-core-2.5.1-…`**.

## Соответствие: показано ↔ внутренний пакет ↔ файл

| Показано в LuCI | Внутренний пакет | Внутренняя версия | Публичное имя файла |
|---|---|---|---|
| Панель LuCI 2.0 | `luci-app-csqtt` | `2.0` (`rN`) | `luci-app-csqtt-2.0-openwrt-<release>.<apk\|ipk>` |
| Ядро 2.1.9 | `csqtt-core-2.1.9` | `2.1.9` (`rN`) | `csqtt-core-2.1.9-openwrt-<release>-<arch>.<apk\|ipk>` |
| Ядро 2.5.1 | `csqtt-core-2.5.0` | `2.5.0` (`rN`) | `csqtt-core-2.5.1-openwrt-<release>-<arch>.<apk\|ipk>` |

- `<release>` — `24.10` (opkg, `.ipk`) · `25.12` (apk, `.apk`) · `snapshot`
  (apk, `.apk`).
- `<arch>` — `aarch64_cortex-a53` · `aarch64_generic` · `x86_64` ·
  `arm_cortex-a7_neon-vfpv4` (для SNAPSHOT — только `aarch64_cortex-a53`).
- `rN` — внутренняя ревизия пакета; в публичном имени **не используется**.
- Внутренние имена и версии/ревизии **не переименовываются**: ядро 2.5.1
  остаётся пакетом `csqtt-core-2.5.0`, ключи `core_version` —
  `auto|2.1.9|2.5.0`, `status.json` — `"2.5.0"`.

## Три варианта имени (важно)

| Форма | Пример | Поддержка |
|---|---|---|
| Внутреннее трёхфайловое | `csqtt-core-2.5.0_2.5.0_aarch64_cortex-a53.apk` | ✅ `install-csqtt.sh` |
| Прежнее внешнее | `csqtt-2.5.0-openwrt-25.12-aarch64_cortex-a53.apk` | ✅ `install-csqtt.sh` |
| **Публичное (действующее)** | `csqtt-core-2.5.1-openwrt-25.12-aarch64_cortex-a53.apk` | ✅ `install-csqtt.sh` |

`install-csqtt.sh` понимает форму `csqtt-core-<core>-openwrt-<release>-<arch>.<ext>`
и отдельно сопоставляет публичное имя ядра 2.5.0 с ярлыком **2.5.1**
(`core_public_name`: 2.5.0 → 2.5.1). Панель укладывается в общий шаблон
`luci-app-csqtt-<pkg>-openwrt-…`. Тесты установщика включают публичные имена
(фикстуры и проверки 83–89 в `openwrt/tests/installer/run.sh`).

## Клиентские пакеты и манифесты (23 файла)

### OpenWrt 24.10.x — `opkg`, `.ipk`

Ядро 2.1.9 (`csqtt-core-2.1.9`):

- `csqtt-core-2.1.9-openwrt-24.10-aarch64_cortex-a53.ipk`
- `csqtt-core-2.1.9-openwrt-24.10-aarch64_generic.ipk`
- `csqtt-core-2.1.9-openwrt-24.10-x86_64.ipk`
- `csqtt-core-2.1.9-openwrt-24.10-arm_cortex-a7_neon-vfpv4.ipk`

Ядро 2.5.1 (`csqtt-core-2.5.0`):

- `csqtt-core-2.5.1-openwrt-24.10-aarch64_cortex-a53.ipk`
- `csqtt-core-2.5.1-openwrt-24.10-aarch64_generic.ipk`
- `csqtt-core-2.5.1-openwrt-24.10-x86_64.ipk`
- `csqtt-core-2.5.1-openwrt-24.10-arm_cortex-a7_neon-vfpv4.ipk`

Панель LuCI 2.0 (`luci-app-csqtt`, `all`):

- `luci-app-csqtt-2.0-openwrt-24.10.ipk`

### OpenWrt 25.12.x — `apk`, `.apk`

Ядро 2.1.9 (`csqtt-core-2.1.9`):

- `csqtt-core-2.1.9-openwrt-25.12-aarch64_cortex-a53.apk`
- `csqtt-core-2.1.9-openwrt-25.12-aarch64_generic.apk`
- `csqtt-core-2.1.9-openwrt-25.12-x86_64.apk`
- `csqtt-core-2.1.9-openwrt-25.12-arm_cortex-a7_neon-vfpv4.apk`

Ядро 2.5.1 (`csqtt-core-2.5.0`):

- `csqtt-core-2.5.1-openwrt-25.12-aarch64_cortex-a53.apk`
- `csqtt-core-2.5.1-openwrt-25.12-aarch64_generic.apk`
- `csqtt-core-2.5.1-openwrt-25.12-x86_64.apk`
- `csqtt-core-2.5.1-openwrt-25.12-arm_cortex-a7_neon-vfpv4.apk`

Панель LuCI 2.0 (`luci-app-csqtt`, `all`):

- `luci-app-csqtt-2.0-openwrt-25.12.apk`

### OpenWrt SNAPSHOT — `apk`, `.apk`

Ядро 2.1.9:

- `csqtt-core-2.1.9-openwrt-snapshot-aarch64_cortex-a53.apk`

Ядро 2.5.1:

- `csqtt-core-2.5.1-openwrt-snapshot-aarch64_cortex-a53.apk`

Панель LuCI 2.0:

- `luci-app-csqtt-2.0-openwrt-snapshot.apk`

### Служебные файлы

- `SHA256SUMS` — контрольные суммы всех пакетов (источник истины);
- `MANIFEST.txt` — технический манифест: версии, ревизии, происхождение ядер.

### Итог

| Группа | Файлов |
|---|---:|
| Ядра 24.10 (2 × 4 арх.) | 8 |
| Ядра 25.12 (2 × 4 арх.) | 8 |
| Ядра SNAPSHOT (2 × 1 арх.) | 2 |
| Панель (по одной на линию) | 3 |
| `SHA256SUMS`, `MANIFEST.txt` | 2 |
| **Всего** | **23** |

## Чего в выпуске 2.0 нет (и не выдумывать)

- **MIPS** и другие архитектуры, кроме перечисленных выше.
- Отдельный управляющий пакет `csqtt`, метапакеты `csqtt-setup-*`.
- Отдельный пакет перевода `luci-i18n-csqtt-ru` — русский интерфейс встроен в
  панель.
- Архивы наборов (`*.tar.gz`) — публикация прямыми пакетами.
- Серверные бинарники не являются OpenWrt-пакетами; они включены отдельно в `server/`.

## Серверная часть (отдельная поставка)

Серверные файлы **не входят** в 23 файла выпуска выше — это отдельная поставка.
Серверных вариантов два; оба устанавливаются одними и теми же инструментами
([`server-install.sh`](../server-install/README.md),
[`server-deploy.sh`](../server-deploy/README.md)) и выбираются вручную (без
автопереключения).

| Вариант | Источник | SHA-256 бинарника | Распространение |
|---|---|---|---|
| **Сервер 2.1.9** | официальный релиз `amurcanov/csqtt` v2.1.9 (APK `CSQTT-universal.apk`) | `9740816075518c9d1d09524db0a9abb48a73b554a8dba6963f40b800ce65f9d3` | в `server/`, PolyForm Noncommercial |
| **Сервер 2.5.1** | база CSQTT 2.5.0 + community-патч `01` | `6bb29d0ea9ac47fcbd11d118022b9dba6dc309dc121491d73e6208db60cb9d35` | в `server/`, PolyForm Noncommercial |

SHA-256 всего официального APK 2.1.9 —
`49771d60a53d731452f3301e53dbe6bdee9142876e6b295dbf88f59f0b5aaf82`. Рядом с
поставкой лежат `server/csqtt-server-linux-amd64-2.1.9.sha256` и
`server/csqtt-server-linux-amd64-2.5.1.sha256`. Подробности — в
[инструкции для VPS](server.md).

## Проверка перед публикацией

1. Собрать все 21 пакет и пересчитать `SHA256SUMS`.
2. Сверить `MANIFEST.txt` (внутренние версии `2.1.9` / `2.5.0` / `2.0`,
   `core_version`).
3. Проверить, что в именах нет `rN`, ядро 2.5.0 опубликовано как `2.5.1`, и
   панель — один файл на линию.
4. Прогнать проверку приватности (см. [README выпуска](release-v2.0.md)).
5. Убедиться, что автоустановщик выбирает пакеты с действующими публичными
   именами (тесты установщика).
6. Только после этого — push, тег и публикация (по отдельному поручению).

Серверные файлы: `server/csqtt-server-linux-amd64-2.1.9`,
`server/csqtt-server-linux-amd64-2.5.1`. Общий SHA256SUMS содержит 28 строк:
21 клиентский пакет, 5 скриптов и 2 серверных бинарника.
