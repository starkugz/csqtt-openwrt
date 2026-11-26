# CSQTT для OpenWrt

```sh
(
  f=$(mktemp) || exit 1
  trap 'rm -f "$f"' EXIT
  url=https://raw.githubusercontent.com/starkugz/csqtt-openwrt/refs/heads/main/install.sh
  if { curl -fsSL --connect-timeout 15 --max-time 60 -o "$f" "$url" && [ -s "$f" ]; } ||
     { : >"$f"; wget -T 30 -O "$f" "$url" && [ -s "$f" ]; } ||
     { : >"$f"; uclient-fetch -T 30 -O "$f" "$url" && [ -s "$f" ]; }; then
    ash "$f"
  else
    printf '%s\n' 'Не удалось скачать установщик CSQTT.' >&2
    exit 1
  fi
)
```

Меню предлагает панель, выбранное ядро или комплект. Архитектура и линия OpenWrt определяются автоматически. Пакеты APK/IPK находятся в [релизе v2.5.3](https://github.com/starkugz/csqtt-openwrt/releases/tag/v2.5.3). Подробности — [инструкция](../docs/v2.5/install.md).
