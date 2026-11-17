# CSQTT для OpenWrt

CSQTT подключает роутер OpenWrt к серверу CSQTT. Дополнительная панель LuCI позволяет управлять серверами и подключением через веб-интерфейс роутера.

## Установка

### Роутер OpenWrt

Выполните по SSH от `root`. Установщик подберёт пакеты по версии OpenWrt
и архитектуре и предложит установить ядро и панель.

```sh
f=$(mktemp) && wget -qO "$f" https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/install-router.sh && sh "$f"
```

Для одного компонента укажите `install --set core` или `install --set panel`
после `sh "$f"`. Ручная установка и список архитектур приведены в
[инструкции для OpenWrt](https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/README.md).

**MediaTek MT7621 (`ramips/mt7621`, `mipsel_24kc`).** При ручной установке
скачайте только нужные пакеты своей линии.

| OpenWrt | Ядро | Панель LuCI |
|---|---|---|
| 24.10.8 / `opkg` | [IPK](https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/csqtt-core-2.5.3-openwrt-24.10.8-ramips-mt7621-mipsel_24kc.ipk) | [IPK](https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/luci-app-csqtt-2.5-openwrt-24.10.8-all.ipk) |
| 25.12.5 / `apk` | [APK](https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/csqtt-core-2.5.3-openwrt-25.12.5-ramips-mt7621-mipsel_24kc.apk) | [APK](https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/luci-app-csqtt-2.5-openwrt-25.12.5-all.apk) |

Перед ручной установкой сверьте скачанные файлы с
[`SHA256SUMS`](https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/SHA256SUMS).

### Сервер Linux / VPS

Выполните по SSH на VPS от `root` для открытия меню выбора сервера.

```sh
f=$(mktemp) && curl -fLsS -o "$f" https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/install-server.sh && sh "$f" --menu
```

Требования и настройка после запуска описаны в
[инструкции для VPS](https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/SERVER-README.md).

Команды установки предыдущих версий и список изменений доступны в [архиве выпусков](https://github.com/starkugz/csqtt-openwrt/releases).

## После установки

Во вкладке **Серверы** импортируйте ссылку `csqtt://…` или добавьте сервер
вручную. Включите сервер и службу, затем на странице **Статус** запустите
CSQTT и проверьте туннель. Если подключение не появилось, откройте
**Журнал** и **CAPTCHA** или выполните `/etc/init.d/csqtt doctor` по SSH.

В README каждого выпуска описаны ручная установка, проверка свободного
места, обновление и восстановление.

## Как идёт трафик

CSQTT поднимает интерфейс `csqtt0`. Чтобы направить через него трафик, настройте прокси или маршрутизацию на роутере. Установка CSQTT сохраняет существующие настройки WAN, DNS, маршрутов и firewall.

## Лицензия

Исходный проект CSQTT — **amurcanov**. Интеграция OpenWrt и панель — **starkugz**. Условия использования и сведения об авторах приведены в [LICENSE](LICENSE) и [NOTICE.md](NOTICE.md).
