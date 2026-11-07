# Установка на роутер

> **Все команды этой страницы выполняются на роутере по SSH**
> (`ssh root@<IP-роутера>`). Скопируйте пакеты и `SHA256SUMS` на роутер в `/tmp`
> заранее. Что подготовить — в [README](../README.md#установка-на-openwrt).

Репозиторий **публичный**: файлы выпуска доступны всем без авторизации. Прямые
ссылки и автоустановщик работают анонимно, без токена GitHub.

## Что устанавливается

В поставке **два независимых клиентских ядра** и **необязательная** панель
LuCI. Каждое ядро — самостоятельный пакет: транспорт, служба, UCI, CLI. Можно
установить одно ядро или оба.

- **Ядро 2.1.9** (`csqtt-core-2.1.9`) — полный транспорт 2.1.9.
- **Ядро 2.5.1** (`csqtt-core-2.5.0`) — сборка на базе CSQTT 2.5.0 с
  community-патчами; отображается как «Ядро 2.5.1», внутреннее имя `2.5.0`.
- **Панель LuCI 2.0** (`luci-app-csqtt`) — веб-интерфейс; `architecture all`,
  одинакова для всех платформ, **всегда на русском** (перевод встроен в панель,
  отдельный `luci-i18n-csqtt-ru` не нужен).

Публичные имена файлов:
`csqtt-core-<core>-openwrt-<release>-<arch>.<apk|ipk>`;
панель — `luci-app-csqtt-2.0-openwrt-<release>.<apk|ipk>`.
Полная таблица — в [перечне релизных файлов](release-files.md).

Зависимости (`kmod-tun`, `luci-base`, `rpcd-mod-ucode`, `ucode-mod-socket`,
`coreutils-timeout`) подтягиваются из репозитория устройства и должны
соответствовать версии OpenWrt на роутере.

## Какой набор выбрать

| Роутер | Менеджер | Формат |
|---|---|---|
| OpenWrt 25.12.x | `apk` | `.apk` |
| OpenWrt SNAPSHOT | `apk` | `.apk` |
| OpenWrt 24.10.x | `opkg` | `.ipk` |

Архитектуру смотрите командой:

```sh
. /etc/openwrt_release; echo "$DISTRIB_ARCH"
# aarch64_cortex-a53 | aarch64_generic | x86_64 | arm_cortex-a7_neon-vfpv4
```

Если архитектуры нет в списке (в том числе MIPS) — пакетов для неё не
выпускается.

## Установка: панель + ядра (вручную)

Если скачана полная поставка, проверьте целостность рядом с файлами (на ПК):

При скачивании всех файлов по отдельности с GitHub Release серверные бинарники
окажутся в корне каталога: GitHub не сохраняет подкаталоги. Перед полной
проверкой восстановите их размещение, указанное в SHA256SUMS:

```sh
mkdir -p server
mv csqtt-server-linux-amd64-2.1.9 server/
mv csqtt-server-linux-amd64-2.5.1 server/
```

Это требуется только для полной поставки. Для установки только на роутер
скачивать серверные бинарники не нужно — ниже описана проверка отдельного пакета.

```sh
sha256sum -c SHA256SUMS
```

Если скачаны только выбранные пакеты, проверяйте каждое точное имя отдельно
(пример; файл и SHA256SUMS должны лежать рядом):

```sh
file=csqtt-core-2.5.1-openwrt-25.12-aarch64_cortex-a53.apk
awk -v f="./$file" '$2==f {print}' SHA256SUMS > selected.sha256
test -s selected.sha256 && sha256sum -c selected.sha256
```

**OpenWrt 25.12.x / SNAPSHOT (`apk`):**

```sh
apk update
apk add --allow-untrusted \
  /tmp/csqtt-core-2.1.9-openwrt-25.12-aarch64_cortex-a53.apk \
  /tmp/csqtt-core-2.5.1-openwrt-25.12-aarch64_cortex-a53.apk \
  /tmp/luci-app-csqtt-2.0-openwrt-25.12.apk
```

**OpenWrt 24.10.x (`opkg`):**

```sh
opkg update
opkg install --force-reinstall \
  /tmp/csqtt-core-2.1.9-openwrt-24.10-aarch64_cortex-a53.ipk \
  /tmp/csqtt-core-2.5.1-openwrt-24.10-aarch64_cortex-a53.ipk \
  /tmp/luci-app-csqtt-2.0-openwrt-24.10.ipk
```

> `--allow-untrusted` (apk) нужен, потому что пакеты собраны локально и не
> подписаны ключом репозитория OpenWrt. `--force-reinstall` у `opkg` — при
> замене того же номера версии; при понижении версии используется
> `--force-downgrade` (см. [обновление](update.md)).

После установки обновите кэш меню LuCI (перезайдите в веб-интерфейс) и откройте
**Службы → CSQTT**.

## Установка: только ядро (без панели)

Одно ядро — например 2.5.1:

```sh
apk add --allow-untrusted /tmp/csqtt-core-2.5.1-openwrt-25.12-aarch64_cortex-a53.apk
```

Оба ядра без панели:

```sh
apk add --allow-untrusted \
  /tmp/csqtt-core-2.1.9-openwrt-25.12-aarch64_cortex-a53.apk \
  /tmp/csqtt-core-2.5.1-openwrt-25.12-aarch64_cortex-a53.apk
```

Общие точки входа (`/usr/bin/csqtt`, `/etc/init.d/csqtt`,
`/etc/logrotate.d/csqtt`) создаёт **активное ядро**: приоритет у 2.1.9, затем
2.5.0, независимо от порядка установки. Если установлено только ядро 2.5.0,
движок 2.1.9 недоступен — панель не предлагает его как рабочий движок.

## Автоматическая установка

Откройте меню установки из GitHub:

```sh
wget --no-proxy -qO /tmp/csqtt-install.sh https://raw.githubusercontent.com/starkugz/csqtt-openwrt/v2.0/install-csqtt.sh \
  && ash /tmp/csqtt-install.sh --menu
```

Состав установки (после скачивания установщика):

```sh
sh install-csqtt.sh --menu                     # меню состава установки
sh install-csqtt.sh --set panel                # только LuCI
sh install-csqtt.sh --set panel-2.1.9           # LuCI + 2.1.9
sh install-csqtt.sh --set panel-2.5.1           # LuCI + 2.5.1
sh install-csqtt.sh --set core-2.1.9            # только 2.1.9, LuCI сохранить
sh install-csqtt.sh --set core-2.5.1            # только 2.5.1, LuCI сохранить
sh install-csqtt.sh --set cores                # оба ядра, LuCI сохранить
sh install-csqtt.sh --set full                 # оба ядра + LuCI
CSQTT_VERSION=v2.0 sh install-csqtt.sh --set full # конкретный выпуск
CSQTT_LOCAL_DIR=/tmp/release sh install-csqtt.sh --menu # локальная поставка
```

Установщик: определяет менеджер и архитектуру, скачивает `SHA256SUMS`, выбирает
пакеты **по манифесту**, проверяет SHA-256, делает сухой прогон зависимостей,
сохраняет резервную копию `/etc/config/csqtt` и только затем устанавливает.

> **Публичные имена поддерживаются.** `install-csqtt.sh` понимает публичную
> форму `csqtt-core-<core>-openwrt-<release>-<arch>.<ext>` (ядро 2.5.0
> сопоставляется ярлыку **2.5.1**), прежние внешние имена `csqtt-<core>-openwrt-…`
> и внутренние трёхфайловые (`csqtt-core-2.5.0_2.5.0_<arch>.apk`). Проверки —
> в `openwrt/tests/installer/run.sh`; [перечень релизных
> файлов](release-files.md).

## Первоначальная настройка

Ссылку подключения `csqtt://…` выдаёт владелец сервера. Далее:

1. Откройте LuCI → **Службы → CSQTT → Профили**.
2. **Импортировать ссылку** (или **Добавить профиль**) и проверьте поля.
   Для режима `auto_js` укажите **токен VK** (или полный OAuth redirect-URL).
3. Включите профиль.
4. На странице **Настройки** включите **CSQTT включён**, затем на странице
   **Статус** нажмите **Запустить**.
5. Убедитесь, что на странице **Статус** есть служба, сессия и трафик.

Настройка без LuCI (UCI и CLI) — в [расширенных настройках](advanced.md).

## Проверка

```sh
csqtt status             # 0 подключён / 1 нет / 2 служба не запущена
csqtt doctor             # read-only диагностика
ip -4 addr show csqtt0
curl --interface csqtt0 --max-time 15 https://1.1.1.1/cdn-cgi/trace
```

Если внешний IP в ответе `curl` — это IP сервера CSQTT, трафик идёт через
туннель. Сама по себе установка CSQTT **не переводит** трафик в туннель —
направление выполняет прокси-клиент
([совместимость](compatibility.md)).

## Удаление

```sh
wget --no-proxy -qO /tmp/csqtt-uninstall.sh https://raw.githubusercontent.com/starkugz/csqtt-openwrt/v2.0/uninstall-csqtt.sh \
  && ash /tmp/csqtt-uninstall.sh
```

Скрипт останавливает службу, снимает автозапуск и удаляет **только** пакеты
CSQTT; `/etc/config/csqtt` сохраняется (при необходимости восстанавливается из
защищённой резервной копии). Настройки серверной части на VPS не затрагиваются.
Команды удаления вручную — в [обновлении](update.md#удаление).
