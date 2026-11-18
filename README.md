# CSQTT для OpenWrt

CSQTT подключает роутер OpenWrt к серверу CSQTT. Дополнительная панель LuCI позволяет управлять серверами и подключением через веб-интерфейс роутера.

## Основные возможности

- Импорт ссылок `csqtt://`, ручное добавление серверов и выбор активного профиля в LuCI.
- Управление службой, просмотр трафика и журнала, ручная проверка доступа через туннель.
- Клиентское ядро 2.5.3 с настраиваемым транспортом. Gooby можно отдельно включить для TURN TCP/TLS.

## Установка из GitHub

### Роутер OpenWrt

Выполните по SSH от `root`. В меню можно выбрать ядро с панелью,
только ядро или только панель. Пакеты подбираются по версии OpenWrt
и архитектуре роутера.

```sh
wget -T 30 -qO- https://raw.githubusercontent.com/starkugz/csqtt-openwrt/main/install.sh | ash
```

Для загрузки публичных пакетов аккаунт GitHub не нужен. Установщик проверяет
SHA-256 скачанных пакетов. Для OpenWrt 24.10.8 используется `opkg` (IPK),
для 25.12.5 — `apk` (APK). Перед обновлением сохраните резервную копию настроек.

**MediaTek MT7621 (`ramips/mt7621`, `mipsel_24kc`).** При ручной установке
скачайте только нужные пакеты своей линии.

| OpenWrt | Ядро | Панель LuCI |
|---|---|---|
| 24.10.8 / `opkg` | [IPK](https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/csqtt-core-2.5.3-openwrt-24.10.8-ramips-mt7621-mipsel_24kc.ipk) | [IPK](https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/luci-app-csqtt-2.5-openwrt-24.10.8-all.ipk) |
| 25.12.5 / `apk` | [APK](https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/csqtt-core-2.5.3-openwrt-25.12.5-ramips-mt7621-mipsel_24kc.apk) | [APK](https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/luci-app-csqtt-2.5-openwrt-25.12.5-all.apk) |

Ручная установка и полный список платформ приведены в
[инструкции для OpenWrt](docs/install-v2.5.3.md). Перед ручной установкой сверьте скачанные файлы с
[`SHA256SUMS`](https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/SHA256SUMS).

### Только панель LuCI

Выполните на роутере по SSH от `root`. Выберите версию панели под уже
установленное ядро. Каждая команда устанавливает только выбранную панель.

**Панель 2.5** из выпуска `v2.5.3`:

```sh
f=$(mktemp) && wget -qO "$f" https://raw.githubusercontent.com/starkugz/csqtt-openwrt/main/router/install-openwrt.sh && sh "$f" 2.5
```

**Панель 2.0** из выпуска `v2.0`:

```sh
f=$(mktemp) && wget -qO "$f" https://raw.githubusercontent.com/starkugz/csqtt-openwrt/main/router/install-openwrt.sh && sh "$f" 2.0
```

Добавьте `--dry-run` после номера версии, чтобы посмотреть план установки.

### Сервер Linux / VPS

Выполните по SSH на VPS от `root` для открытия меню выбора сервера.

```sh
curl -fsSL https://raw.githubusercontent.com/starkugz/csqtt-openwrt/main/install.sh | sudo sh
```

Требования и настройка после запуска описаны в
[инструкции для VPS](docs/server-v2.5.3.md).

Команды установки предыдущих версий и список изменений доступны в [архиве выпусков](https://github.com/starkugz/csqtt-openwrt/releases).

## После установки

Во вкладке **Серверы** импортируйте ссылку `csqtt://…` или добавьте сервер
вручную. Включите сервер и службу, затем на странице **Статус** запустите
CSQTT и проверьте туннель. Если подключение не появилось, откройте
**Журнал** и **CAPTCHA** или выполните `/etc/init.d/csqtt doctor` по SSH.

В README каждого выпуска описаны ручная установка, проверка свободного
места, обновление и восстановление.

## Совместимость с прокси-клиентами

CSQTT поднимает интерфейс `csqtt0`. В SSClash/Mihomo или другом прокси-клиенте
можно использовать его как выход для выбранного трафика. Правила направления
трафика задаются на роутере. Установка CSQTT сохраняет существующие настройки
WAN, DNS, маршрутов и firewall.

## Если что-то не работает

| Симптом | Что проверить |
|---|---|
| Не скачиваются пакеты или `SHA256SUMS` | Проверьте доступ к GitHub с самого роутера и повторите команду из раздела установки. |
| Нет пакета для устройства | Сверьте точную версию OpenWrt и архитектуру со [списком платформ](docs/install-v2.5.3.md#пакеты-openwrt). |
| Не хватает места | Проверьте `df -h /overlay /tmp`. Для MT7621 требования приведены в [инструкции для OpenWrt](docs/install-v2.5.3.md#mt7621). |
| Служба запущена, но туннель не работает | Проверьте активный профиль, вкладки **Журнал** и **CAPTCHA**, затем выполните команды ниже. |

```sh
/etc/init.d/csqtt status
/etc/init.d/csqtt doctor
```

## Лицензия

Исходный проект CSQTT — **amurcanov**. Интеграция OpenWrt и панель — **starkugz**. Условия использования и сведения об авторах приведены в [LICENSE](LICENSE) и [NOTICE.md](NOTICE.md).

## Разделы репозитория

- [OpenWrt](router/) — установка на роутер.
- [Сервер VPS](server/) — установка и бинарники Linux.
- [Инструкции](docs/README.md) — настройка и решение проблем.
