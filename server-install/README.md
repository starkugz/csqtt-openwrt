# Установка сервера CSQTT с нуля (установка, обновление, откат)

Самостоятельный инструмент для развёртывания **серверной части CSQTT** на
чистом Linux с systemd, обновления и точного отката. Это инструмент выпуска
**CSQTT 2.0**; он дополняет [`server-deploy.sh`](../server-deploy/README.md),
который **меняет только бинарник** уже развёрнутой службы.

Скрипт: [`server-install.sh`](server-install.sh).

> **Все команды этой страницы выполняются на VPS по SSH.** Для роутера они не
> подходят; команды для роутера — в [установке](../docs/install.md).

## Подтверждённая схема

Схема определена по официальному `deploy.sh` серверного архива community и
повторена здесь один в один:

| Параметр | Значение |
|---|---|
| ОС | Linux (Ubuntu/Debian), **systemd** |
| Архитектура | x86-64 (проверено); arm64 принимается, если совпадает с хостом |
| Служба systemd | `csqtt` (`/etc/systemd/system/csqtt.service`) |
| Бинарник | `/usr/local/bin/csqtt` |
| Хелперы | `/usr/local/lib/csqtt/network-up.sh`, `tun-recover.sh` |
| Каталог конфигурации | `/etc/csqtt` |
| Интерфейс | `csqtt1` |
| UDP-порт peer | `46000/udp` |
| TCP-порт панели | `46002/tcp` |
| sysctl | `/etc/sysctl.d/99-csqtt.conf`, `/etc/sysctl.d/99-csqtt-udp-buffers.conf` |

Нужны: `systemd`, `TUN` (`/dev/net/tun`), `ip`, `iptables`, права **root**,
свободный порт **80/TCP** (сертификат Let's Encrypt).

**Два серверных варианта.** Инструмент не присваивает версию: он фиксирует
SHA-256 конкретного входного бинарника. Поддерживаются оба варианта выпуска —
**2.1.9** (официальный релиз upstream) и **2.5.1** (база 2.5.0 + community-патч).

## Серверные бинарники (источник и лицензия)

Серверные бинарники **не входят** в каталог исходников установщика;
в скачиваемом комплекте они находятся в `server/`. См. [команды](CHECK-SERVER.md).

**Вариант 2.1.9** — официальный закреплённый артефакт upstream (сборка не
требуется): APK `CSQTT-universal.apk` из релиза `amurcanov/csqtt` v2.1.9,
SHA-256 всего APK `49771d60…f82`; из него берётся
`assets/csqtt-linux-amd64` (ELF x86-64, `x86_64-unknown-linux-musl`,
`CSQTT-WIRE-3`):

| Свойство | Значение |
|---|---|
| Файл | `assets/csqtt-linux-amd64` → `csqtt-server-linux-amd64` |
| SHA-256 | `9740816075518c9d1d09524db0a9abb48a73b554a8dba6963f40b800ce65f9d3` |
| Лицензия | PolyForm Noncommercial 1.0.0 (см. `../NOTICE.md`) |

**Вариант 2.5.1** — сборка community-архива CSQTT 2.5.0 с принятым патчем
сервера, распространяемая по PolyForm Noncommercial с Required Notice:

| Свойство | Значение |
|---|---|
| Происхождение | `amurcanov/csqtt` v2.5.0, community-патч `0001-server-downlink-pin-limit.patch` (`rust-server/tun_device.rs`) |
| Файл | `csqtt-server-linux-amd64` (ELF x86-64, musl, stripped) |
| SHA-256 | `6bb29d0ea9ac47fcbd11d118022b9dba6dc309dc121491d73e6208db60cb9d35` |
| Лицензия | PolyForm Noncommercial 1.0.0 (см. `../NOTICE.md`) |

Контрольная сумма **обязательна**: `--sha256` или `--sha256-file`. Инструмент
не принимает бинарник без проверки. Порядок получения бинарника 2.1.9 из
официального APK — в [инструкции для VPS](../docs/server.md).

## Установка с нуля

```sh
# 1. dry-run (ничего не меняет):
sudo bash server-install.sh preflight \
  --binary /path/csqtt-server-linux-amd64 \
  --sha256 6bb29d0ea9ac47fcbd11d118022b9dba6dc309dc121491d73e6208db60cb9d35

# 2. установка с нуля (unit, хелперы, sysctl, запуск, health-check):
sudo bash server-install.sh install \
  --binary /path/csqtt-server-linux-amd64 \
  --sha256 6bb29d0ea9ac47fcbd11d118022b9dba6dc309dc121491d73e6208db60cb9d35 --yes
```

Установка:

1. проверяет ОС/архитектуру/ELF/`systemd`/SHA-256;
2. создаёт `/usr/local/lib/csqtt` с хелперами, `/etc/csqtt`, sysctl-файлы и unit;
3. кладёт бинарник **атомарно** и включает службу;
4. запускает `csqtt`, ждёт health-check (состояние systemd, живой PID, интерфейс
   `csqtt1`, TCP-порт панели, стабильность) и при провале **автоматически
   откатывается**.

## Обновление и откат

```sh
# 3. обновление бинарника (unit/хелперы приводятся к текущему виду):
sudo bash server-install.sh update \
  --binary /path/csqtt-server-linux-amd64 \
  --sha256-file /path/csqtt-server-linux-amd64.sha256 --yes

# 4. статус (только чтение):
sudo bash server-install.sh status

# 5. проверка установленного файла и здоровья:
sudo bash server-install.sh verify --sha256 6bb29d0e…9d35

# 6. точный ручной откат к последней резервной копии:
sudo bash server-install.sh rollback --yes
sudo bash server-install.sh rollback --backup /var/lib/csqtt-deploy/<...> --yes

# 7. удаление unit/хелперов/бинарника (конфигурация сохраняется):
sudo bash server-install.sh uninstall --yes
```

Если сервер уже развёрнут и нужно заменить **только бинарник**, без изменения
unit и хелперов, используйте `server-deploy.sh`
([README](../server-deploy/README.md)).

`--dry-run` (`-n`) применим к `preflight`, `install`, `update`, `rollback`,
`uninstall`.

## Границы инструмента

- **Не читает, не печатает и не передаёт секреты**: каталог `/etc/csqtt` при
  резервном копировании только упаковывается как есть.
- **Не подписывает** бинарник и **не присваивает** версию — проверяет SHA-256.
- **Хелперы** `network-up.sh` (forwarding/NAT/firewall/sysctl, семейство
  `10.66.67.0/24`) и `tun-recover.sh` повторяют официальный `deploy.sh` и
  настраиваются под интерфейс `csqtt1` и порты `46000`/`46002`.
- Версию ядра и строку «2.5.1» инструмент не выставляет.

## Коды возврата (контракт автоматизации)

| Код | Значение |
|---|---|
| `0` | успех |
| `2` | ошибка использования / отмена |
| `20` | предварительная проверка не пройдена |
| `30` | установка/health не удались, автоматический откат выполнен |
| `31` | установка и откат не удались |
| `40` | уже выполняется другой запуск |
| `50` | внутренняя ошибка |

## Маркеры stdout

- `CSQTT_SERVER_INSTALL_PREFLIGHT_OK|…` / `…_PREFLIGHT_FAILED|…`
- `CSQTT_SERVER_INSTALL_DRY_RUN|…`
- `CSQTT_SERVER_INSTALL_OK|…|sha256`
- `CSQTT_SERVER_INSTALL_UP_TO_DATE|…|sha256`
- `CSQTT_SERVER_INSTALL_ROLLED_BACK|…` / `…_ROLLBACK_FAILED|…`
- `CSQTT_SERVER_INSTALL_STATUS|…|state`
- `CSQTT_SERVER_INSTALL_VERIFY_OK|…` / `…_VERIFY_FAILED|…`
- `CSQTT_SERVER_INSTALL_UNINSTALLED|…`

Сообщения людей идут в stderr; маркеры — в stdout.

## Ключевые параметры

`--binary` (ELF), `--sha256` / `--sha256-file`, `--service` (`csqtt`),
`--target` (`/usr/local/bin/csqtt`), `--lib-dir` (`/usr/local/lib/csqtt`),
`--config-dir` (`/etc/csqtt`), `--unit` (`/etc/systemd/system/csqtt.service`),
`--iface` (`csqtt1`), `--peer-port` (`46000`), `--web-port` (`46002`),
`--sysctl-dir` (`/etc/sysctl.d`), `--health-cmd`, `--backup-root`
(`/var/lib/csqtt-deploy`), `--stability-seconds`, `--health-timeout`,
`--no-backup-config`, `--restore-config`, `--yes`, `--force`.

## Честный статус

- **Выполнено локально:** на временной файловой системе — PASS=54/FAIL=0 (без
  внешних бинарников) и PASS=58/FAIL=0 (с настоящими бинарниками обоих вариантов
  2.1.9 и 2.5.1, включая проверку SHA-256).
- **Исторически проверено на сервере:** последовательная установка 2.1.9 и 2.5.1, здоровье службы и ответ веб-панели.
- **Не проверено живым прогоном:** новое меню загрузки, реальный откат и клиентский трафик.
- Проверки текущей версии установщика локальные; подключение к рабочему VPS при подготовке меню не выполнялось.
