# Свой сервер CSQTT на VPS

Серверная часть CSQTT устанавливается на арендованный сервер (VPS) **отдельно**
от роутерной панели. Как и клиентских ядер, серверных вариантов **два**: 2.1.9
(официальный релиз upstream) и 2.5.1 (база 2.5.0 + community-патч). Они разного
происхождения и **не переключаются автоматически**; одновременно две версии на
одном сервере не запускаются — работает ровно одна.

> **Все команды этой страницы выполняются на VPS по SSH.** Для роутера они не
> подходят; команды для роутера — в [установке](install.md).

## Установка через меню

Выполняйте на VPS от `root`. В поставке есть два готовых бинарника для
Linux **x86-64**; ARM-серверы этим меню не поддерживаются.
Сначала установите зависимости (Ubuntu/Debian):

```sh
apt-get update
apt-get install -y ca-certificates curl python3 iproute2 iptables procps tar coreutils
curl -fL --connect-timeout 15 --max-time 60 -o /tmp/csqtt-server-menu.sh \
  https://raw.githubusercontent.com/starkugz/csqtt-openwrt/v2.0/install-server.sh \
  && bash /tmp/csqtt-server-menu.sh --menu
```

Меню: **сервер 2.1.9 / сервер 2.5.1 / удалить CSQTT / отмена**.
Удаление сохраняет конфигурацию, базу, сертификаты и резервные копии;
3X-UI и другие службы не удаляются. Созданные ранее сетевые правила и
значения sysctl не восстанавливаются автоматически до состояния до установки.

Без меню (версию выбираете явно):

```sh
bash /tmp/csqtt-server-menu.sh 2.1.9
bash /tmp/csqtt-server-menu.sh 2.5.1
bash /tmp/csqtt-server-menu.sh uninstall
```

Из распакованной локальной поставки:

```sh
sudo bash ./install-server.sh --local-dir . --menu
```

Меню проверяет серверный бинарник по закреплённой SHA-256, а backend — по
`SHA256SUMS` того же выпуска. HTTPS и SHA-256 защищают загрузку от повреждения;
контрольные суммы из одного выпуска не заменяют независимую цифровую подпись.
Установщик, SHA256SUMS и бинарники должны относиться к одному выпуску `v2.0`.

### Проверка после установки через меню

Меню удаляет временные загрузки после завершения. Для проверки установленной
службы повторно скачивать установщик не нужно:

```sh
sudo systemctl is-active csqtt
sudo systemctl show csqtt -p MainPID -p SubState -p NRestarts
sudo sha256sum /usr/local/bin/csqtt
ip link show csqtt1
sudo ss -H -lun 'sport = :46000'
sudo ss -H -ltn 'sport = :46002'
```

Ожидаются `active`, `SubState=running`, живой MainPID, интерфейс и оба порта.
Сверьте SHA-256 с выбранной версией ниже. Это проверка установки сервера;
подключение клиента и полезный трафик проверяются отдельно. Не публикуйте
адрес панели, секретный путь, учётные данные и полные журналы.

### Ручные команды для скачанного комплекта

Команды ниже выполняются **из каталога Release-2.0**, где лежит `server-install.sh`.
При одиночном скачивании добавьте этот файл из того же выпуска и проверьте
его по `SHA256SUMS`. Для включённых бинарников извлечение Android APK не требуется:

```sh
sudo bash server-install.sh preflight --binary ./server/csqtt-server-linux-amd64-2.5.1 \
  --sha256 6bb29d0ea9ac47fcbd11d118022b9dba6dc309dc121491d73e6208db60cb9d35
sudo bash server-install.sh status
sudo bash server-install.sh verify
```

Панель сервера доступна по адресу и секретному пути, созданным сервером.
Сохраните данные доступа приватно; готовность службы не доказывает прохождение
клиентского трафика. Доступность портов также зависит от внешнего firewall VPS.

## Проверенная схема

| Параметр | Значение |
|---|---|
| ОС | Linux (Ubuntu/Debian), **systemd** |
| Архитектура | x86-64 (проверено; arm64 принимается, если совпадает с хостом) |
| Служба systemd | `csqtt` |
| Бинарник | `/usr/local/bin/csqtt` |
| Хелперы | `/usr/local/lib/csqtt/network-up.sh`, `tun-recover.sh` |
| Каталог конфигурации | `/etc/csqtt` |
| Интерфейс | `csqtt1` |
| UDP-порт peer | `46000/udp` |
| TCP-порт панели | `46002/tcp` |
| sysctl | `/etc/sysctl.d/99-csqtt.conf`, `99-csqtt-udp-buffers.conf` |

Нужны: `systemd` и `TUN`, свободный порт **80/TCP** (для сертификата
Let's Encrypt), права **root**.

## Два серверных варианта

| Вариант | Источник | Файл | SHA-256 |
|---|---|---|---|
| **Сервер 2.1.9** | официальный закреплённый релиз `amurcanov/csqtt` v2.1.9 | `csqtt-linux-amd64` из APK | `97408160…f9d3` |
| **Сервер 2.5.1** | база CSQTT 2.5.0 + community-патч `01` | `csqtt-server-linux-amd64` | `6bb29d0e…9d35` |

Оба варианта устанавливаются **одними и теми же инструментами**
([`server-install.sh`](../server-install/README.md) — с нуля, обновление, откат;
[`server-deploy.sh`](../server-deploy/README.md) — замена бинарника): инструмент
не присваивает версию, а фиксирует SHA-256 конкретного входного файла. Откат —
штатный для обоих.

## Установка сервера CSQTT 2.1.9 (официальный релиз)

Источник — **официальный закреплённый** релиз upstream; отдельная сборка из
исходников **не требуется**. Проверено локально: SHA-256 всего APK и
извлечённого бинарника совпадают с закреплёнными, бинарник — ELF x86-64,
statically linked, target `x86_64-unknown-linux-musl`, wire-ревизия
`CSQTT-WIRE-3`.

| Свойство | Значение |
|---|---|
| Релиз | `https://github.com/amurcanov/csqtt/releases/tag/v2.1.9` |
| APK | `https://github.com/amurcanov/csqtt/releases/download/v2.1.9/CSQTT-universal.apk` |
| SHA-256 всего APK | `49771d60a53d731452f3301e53dbe6bdee9142876e6b295dbf88f59f0b5aaf82` |
| Серверный ассет | `assets/csqtt-linux-amd64` (9 917 072 Б) |
| SHA-256 ассета | `9740816075518c9d1d09524db0a9abb48a73b554a8dba6963f40b800ce65f9d3` |
| Архитектура | ELF x86-64, statically linked, stripped (`x86_64-unknown-linux-musl`) |
| Wire-протокол | `CSQTT-WIRE-3` (`--protocol-revision`) |
| Лицензия | PolyForm Noncommercial 1.0.0 |

Получение проверенного бинарника (команды выполнены и проверены; нужен
`python3`, как и установщику):

```sh
curl -fL -o CSQTT-universal.apk \
  https://github.com/amurcanov/csqtt/releases/download/v2.1.9/CSQTT-universal.apk
printf '%s  %s\n' \
  49771d60a53d731452f3301e53dbe6bdee9142876e6b295dbf88f59f0b5aaf82 CSQTT-universal.apk \
  | sha256sum -c -
python3 - <<'PY'
import hashlib, zipfile
with zipfile.ZipFile('CSQTT-universal.apk') as z:
    data = z.read('assets/csqtt-linux-amd64')
want = '9740816075518c9d1d09524db0a9abb48a73b554a8dba6963f40b800ce65f9d3'
assert hashlib.sha256(data).hexdigest() == want, 'SHA-256 не совпала'
open('csqtt-server-linux-amd64', 'wb').write(data)
print('OK: csqtt-server-linux-amd64')
PY
```

Архитектуры arm64 (`8 351 856` Б, `fe83c478…`) и armv7 (`7 668 416` Б,
`3f85a5d9…`) — в том же APK как `assets/csqtt-linux-arm64` и
`assets/csqtt-linux-armv7`.

Установка, проверка и откат:

```sh
sudo bash server-install.sh preflight --binary ./csqtt-server-linux-amd64 \
  --sha256 9740816075518c9d1d09524db0a9abb48a73b554a8dba6963f40b800ce65f9d3
sudo bash server-install.sh install --binary ./csqtt-server-linux-amd64 \
  --sha256 9740816075518c9d1d09524db0a9abb48a73b554a8dba6963f40b800ce65f9d3 --yes
sudo bash server-install.sh rollback --yes
```

## Установка сервера CSQTT 2.5.1 (база 2.5.0 + community-патч 01)

Публичное «Сервер 2.5.1» — **ярлык**, как «Ядро 2.5.1» у клиента. Происхождение —
база **CSQTT 2.5.0** (commit `fd936ef0…`) + community-патч сервера `01`
(`0001-server-downlink-pin-limit`, `rust-server/tun_device.rs`). Сам бинарник
печатает `CSQTT Server 2.5.0`: это **отображение**, а не новая версия
wire-протокола.

| Свойство | Значение |
|---|---|
| Происхождение | `amurcanov/csqtt` v2.5.0 (`fd936ef0…`) + community-патч сервера `01` |
| Файл | `csqtt-server-linux-amd64` |
| SHA-256 | `6bb29d0ea9ac47fcbd11d118022b9dba6dc309dc121491d73e6208db60cb9d35` |
| Архитектура | ELF x86-64, statically linked (musl), stripped |
| Лицензия | PolyForm Noncommercial 1.0.0 |

Совместимость с клиентским ядром 2.5.0:

- **по анализу wire-протокола — совместимо**: ревизия `CSQTT-WIRE-3`, как у
  клиента 2.5.0;
- **клиентская совместимость живыми проверками не подтверждена**: установка,
  health-check и веб-панель сервера проверены, но сессия клиента 2.5.0 и
  полезный трафик через неё в этом окне не проверялись.

Установка и откат — те же инструменты с SHA-256 этого варианта:

```sh
sudo bash server-install.sh install --binary ./server/csqtt-server-linux-amd64-2.5.1 \
  --sha256 6bb29d0ea9ac47fcbd11d118022b9dba6dc309dc121491d73e6208db60cb9d35 --yes
sudo bash server-install.sh rollback --yes
```

> **Лицензия:** оба варианта поставляются по PolyForm Noncommercial 1.0.0.
> Сохранены лицензия, авторство и все Required Notice. Подробности —
> [NOTICE.md](../NOTICE.md).

## Выбор портов

В терминале без `--yes` установщик спрашивает **порт туннеля UDP** и **порт
панели TCP**. Enter оставляет предложенный номер: при новой установке это
`46000` и `46002`, при обновлении — значения текущей службы. Если порт занят,
предлагается свободный вариант; без вашего подтверждения он не выбирается.
Чужие службы не останавливаются. SSH-порт установщик не меняет.

Можно задать оба значения явно в новом `install-server.sh` из комплекта:

```sh
sudo bash ./install-server.sh 2.5.1 --peer-port 47000 --web-port 47002 --yes
```

Проверяются диапазон `1–65535`, служебные номера, совпадение ролей и занятость
по нужному протоколу, включая IPv6. Свой сокет текущей службы допускается при
обновлении; неизвестный владелец или ошибка `ss` блокируют установку. Перед
изменениями порты проверяются ещё раз. Проверка не резервирует порт навсегда:
при последующей гонке запуска действует health-check/откат.

Выбранные значения передаются серверу, его хелперам и итоговому адресу панели.
Повторное обновление без параметров не сбрасывает их на стандартные.
При изменении UDP-порта обновите данные подключения клиентов. Без `--yes`
нужен доступный терминал; для автоматизации задавайте параметры явно.

## Как войти в панель после установки

После успешной установки **обеих серверных версий** скрипт показывает:

```text
Доступ к веб-панели CSQTT
Адрес панели: https://<IP_СЕРВЕРА>:46002/
Логин: <сгенерированный логин>
Пароль: <сгенерированный пароль>
```

При новой установке логин и пароль случайные; общего пароля `admin/admin` нет.
Откройте указанный HTTPS-адрес. Если напечатан `<IP_СЕРВЕРА>`, замените его
публичным адресом VPS. При самоподписанном сертификате возможно предупреждение
браузера. Для входа извне TCP-порт панели должен быть доступен.

Данные сохраняются в `/etc/csqtt/csqtt.env` (`0600`, только root), не меняются
при перезапуске/обновлении и не попадают в журнал установщика. Существующие
настроенные доступы сохраняются. Пароль показывается в терминале: не
публикуйте этот экран. SHA-256 в строке `CSQTT_SERVER_INSTALL_OK` — контрольная
сумма бинарника, **не пароль и не VK-хеш**.

Сохранённые данные можно повторно посмотреть без перезапуска службы:

```sh
# Из каталога, куда скачан новый server-install.sh:
sudo bash server-install.sh credentials
```

Если старый установщик уже поставил сервер, но показал только SHA-256,
повторите исходную команду установки нужной версии **новым** установщиком
(или выберите ту же версию в меню `install-server.sh`). Он сохранит
конфигурацию/клиентские пароли, настроит постоянный вход и выполнит один
перезапуск. Прежний несохранённый случайный пароль панели при этом заменится.
При нестандартной установке сохраняйте свои `--config-dir`/`--web-port`.

## Установка с нуля — `server-install.sh`

Установку «с нуля» выполняет [`server-install.sh`](../server-install/README.md).
Он повторяет схему официального `deploy.sh` из серверного архива community:
создаёт `systemd`-unit `csqtt`, хелперы `network-up.sh`/`tun-recover.sh`,
каталог `/etc/csqtt`, файлы `sysctl`, выполняет health-check и при провале
**автоматически откатывается**.

```sh
# 1. dry-run (ничего не меняет): проверка ОС, ELF, SHA-256 и окружения.
sudo bash server-install.sh preflight \
  --binary /path/csqtt-server-linux-amd64 \
  --sha256 <SHA-256 файла>

# 2. установка с нуля (unit, хелперы, sysctl, запуск, health-check):
sudo bash server-install.sh install \
  --binary /path/csqtt-server-linux-amd64 \
  --sha256 <SHA-256 файла> --yes

# 3. обновление бинарника (unit/хелперы приводятся к текущему виду):
sudo bash server-install.sh update \
  --binary /path/csqtt-server-linux-amd64 \
  --sha256-file /path/csqtt-server-linux-amd64.sha256 --yes

# 4. статус (только чтение), проверка установленного файла и здоровья:
sudo bash server-install.sh status
sudo bash server-install.sh verify --sha256 <SHA-256 файла>

# 5. точный ручной откат к последней резервной копии:
sudo bash server-install.sh rollback --yes
sudo bash server-install.sh rollback --backup /var/lib/csqtt-deploy/<...> --yes

# 6. удаление unit/хелперов/бинарника (конфигурация сохраняется):
sudo bash server-install.sh uninstall --yes
```

Подробности, коды возврата и маркеры — в
[`../server-install/README.md`](../server-install/README.md).

## Обновление и откат — `server-deploy.sh`

Если сервер уже развёрнут (служба `csqtt` установлена) и нужно заменить
**только бинарник**, без изменения unit и хелперов, используйте
[`server-deploy.sh`](../server-deploy/README.md). Он проверяет
ОС/архитектуру/ELF и обязательный SHA-256, делает резервную копию, перезапускает
только службу `csqtt`, выполняет health-check и при провале **автоматически
откатывается**.

> Для полной установки, обновления «под ключ» (с приведением unit и хелперов к
> текущему виду) и точного отката используйте `server-install.sh` выше.

```sh
# 1. dry-run (ничего не меняет):
sudo bash server-deploy.sh preflight \
  --binary /path/csqtt-server-linux-amd64 \
  --sha256 <SHA-256 файла> --dry-run

# 2. первая укладка в уже развёрнутое окружение:
sudo bash server-deploy.sh install \
  --binary /path/csqtt-server-linux-amd64 \
  --sha256 <SHA-256 файла> --yes

# 3. обновление:
sudo bash server-deploy.sh update \
  --binary /path/csqtt-server-linux-amd64 \
  --sha256-file /path/csqtt-server-linux-amd64.sha256 --yes

# 4. статус (только чтение):
sudo bash server-deploy.sh status

# 5. проверка установленного файла и здоровья:
sudo bash server-deploy.sh verify --sha256 <SHA-256 файла>

# 6. точный ручной откат:
sudo bash server-deploy.sh rollback --yes
sudo bash server-deploy.sh rollback --backup /var/lib/csqtt-deploy/<...> --yes
```

`--dry-run` (`-n`) применим к `preflight`, `install`, `update`, `rollback`.

### Границы инструмента

- **Не разворачивает** CSQTT с нуля — работает только по факту установленной
  службы.
- **Не трогает** firewall/NAT/`sysctl`/порты/3X-UI.
- **Не читает, не печатает и не передаёт секреты**: каталог конфигурации при
  резервном копировании только упаковывается как есть.
- Версию ядра (`2.1.9`/`2.5.0`) и строку «2.5.1» инструмент **не присваивает** —
  фиксирует SHA-256 конкретного входного файла.

### Коды возврата (контракт автоматизации)

| Код | Значение |
|---|---|
| `0` | успех |
| `2` | ошибка использования / отмена |
| `20` | предварительная проверка не пройдена |
| `30` | установка/health не удались, автоматический откат выполнен |
| `31` | установка и откат не удались |
| `40` | уже выполняется другой запуск |
| `50` | внутренняя ошибка |

### Ключевые параметры

`--binary` (ELF), `--sha256` / `--sha256-file`, `--service` (`csqtt`),
`--target` (`/usr/local/bin/csqtt`), `--config-dir` (`/etc/csqtt`), `--iface`
(`csqtt1`), `--web-port` (`46002`), `--health-cmd`, `--backup-root`
(`/var/lib/csqtt-deploy`), `--stability-seconds`, `--health-timeout`,
`--no-backup-config`, `--restore-config`, `--yes`, `--force`.

Полное описание, маркеры stdout и коды — в
[`../server-deploy/README.md`](../server-deploy/README.md).

## Статус проверки (честно)

- **Выполнено локально:**
  - закреплённый артефакт **сервера 2.1.9**: скачан APK, SHA-256 всего APK и
    извлечённого `assets/csqtt-linux-amd64` совпали с закреплёнными; ELF x86-64,
    static musl, `--protocol-revision` = `CSQTT-WIRE-3` (живой сервер не
    запускался).
  - `server-install.sh` (с нуля, обновление, откат, `status`, `verify`,
    `uninstall`, `dry-run`) на временной файловой системе с фиктивными
    `systemctl`/`ip`/`iptables`/`ss`/`sysctl`; плюс с настоящими бинарниками
    обоих вариантов (ELF x86-64 + SHA-256).
  - `server-deploy.sh` (замена бинарника) — на временной файловой системе, плюс
    SHA-256 обоих вариантов.
- **Живая установка:** в согласованном окне последовательно установлены оба варианта; SHA, служба и порты проверены, итоговый сервер 2.5.1. Панель по сохранённому секретному пути отвечает 200; 3X-UI и учётные данные сохранены. Реальный откат, внешний сертификат и клиентский трафик не проверялись.

## Серверные бинарники

В Release включены `server/csqtt-server-linux-amd64-2.1.9` и
`server/csqtt-server-linux-amd64-2.5.1`, их `.sha256`, LICENSE и NOTICE.md.
Все исполняемые файлы покрыты общим SHA256SUMS. Бинарники в этом комплекте —
только Linux x86-64; наличие arm64 в официальном APK не означает его включения.

Для установки из Release используйте [команды проверки и установки](../server-install/CHECK-SERVER.md).
Описанное выше извлечение официального 2.1.9 из APK остаётся альтернативным способом.
