#!/bin/sh
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Совместимый алиас: скачивает закреплённый main/install.sh, проверяет его
# SHA-256 и передаёт управление ему. Ядро 2.5.3 и панель ставит сам install.sh;
# здесь только разбор аргументов и транспорт.
set -eu
umask 077

url=https://raw.githubusercontent.com/starkugz/csqtt-openwrt/main/install.sh
sha=1623bac4b1970c9dffc0116e4f35407a9301611923be2d81f205dce96b19be72

usage() {
    cat <<'EOF'
Использование: sh install-openwrt.sh [ОПЦИЯ] [--yes|-y] [--dry-run]
  (без опции), --menu   меню ядра 2.5.3 / панели CSQTT 2.5
  2.5                   установка только панели CSQTT 2.5 (ядро — через --menu)
  -h, --help            эта справка
Остальные параметры передаются install.sh без изменений.
EOF
}

choice=${1:---menu}
[ "$#" -eq 0 ] || shift
case "$choice" in
    -h|--help) usage; exit 0 ;;
    --menu|2.5) ;;
    *)
        printf 'Неизвестный параметр: %s\n' "$choice" >&2
        usage >&2
        exit 2
        ;;
esac
case "$choice" in
    --menu) set -- install --menu "$@" ;;
    2.5) set -- install --set panel "$@" ;;
esac

work=$(mktemp -d) || exit 1
installer=$work/install.sh
trap 'rm -f "$installer"; rmdir "$work" 2>/dev/null || :' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'CSQTT — загрузка install.sh…\n' >&2
if command -v wget >/dev/null 2>&1 && wget -T 30 -qO "$installer" "$url"; then
    :
elif command -v curl >/dev/null 2>&1 &&
     curl -fLsS --connect-timeout 15 --max-time 60 -o "$installer" "$url"; then
    :
elif command -v uclient-fetch >/dev/null 2>&1 &&
     uclient-fetch -q -O "$installer" "$url"; then
    :
else
    rm -f "$installer"
    printf 'Не удалось скачать %s\n' "$url" >&2
    exit 1
fi
[ -s "$installer" ] || { printf 'Пустой ответ: %s\n' "$url" >&2; exit 1; }

printf '%s  %s\n' "$sha" "$installer" | sha256sum -c - >/dev/null ||
    { printf 'Не совпал SHA-256 %s\n' "$url" >&2; exit 1; }

sh "$installer" "$@"
exit $?
