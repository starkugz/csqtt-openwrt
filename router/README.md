# CSQTT для OpenWrt

```sh
f=$(mktemp) &&
wget -T 30 -O "$f" https://raw.githubusercontent.com/starkugz/csqtt-openwrt/refs/heads/main/install.sh &&
[ -s "$f" ] && ash "$f"
```

Меню предлагает панель, выбранное ядро или комплект. Архитектура и линия OpenWrt определяются автоматически. Пакеты APK/IPK находятся в [релизе v2.5.3](https://github.com/starkugz/csqtt-openwrt/releases/tag/v2.5.3). Подробности — [инструкция](../docs/v2.5/install.md).
