#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# wget -T 30 -qO- https://raw.githubusercontent.com/starkugz/csqtt-openwrt/main/install.sh | ash

install_csqtt() (
    set -eu
    umask 077
    if [ -f /etc/openwrt_release ]; then
        installer=router/install.sh
        sha=e61764d504c75f9b1f13fa104cd26bd9c9dce564f3b36a8c3b1523c3f60a3fbc
        platform=OpenWrt
        [ "$#" -gt 0 ] || set -- install --menu
    else
        installer=server/install.sh
        sha=c0966fb549c137ce86274bdf3b6c3555154f51d44f745e55921f6635e02e78d7
        platform=VPS
        [ "$#" -gt 0 ] || set -- --menu
    fi
    work=$(mktemp -d)
    trap 'rm -f "$work/install-router.sh"; rmdir "$work"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf 'CSQTT — загрузка установщика %s…\n' "$platform"
    if command -v wget >/dev/null 2>&1 &&
       wget -T 30 -qO "$work/install-router.sh" "https://raw.githubusercontent.com/starkugz/csqtt-openwrt/main/$installer"; then
        :
    elif command -v curl >/dev/null 2>&1; then
        curl -fLsS --connect-timeout 15 --max-time 60 -o "$work/install-router.sh" "https://raw.githubusercontent.com/starkugz/csqtt-openwrt/main/$installer"
    else
        printf 'Не удалось скачать установщик. Проверьте доступ к GitHub.\n' >&2
        exit 1
    fi
    printf '%s  %s\n' "$sha" "$work/install-router.sh" | sha256sum -c -
    if [ -t 0 ]; then
        sh "$work/install-router.sh" "$@"
    elif ( : </dev/tty ) 2>/dev/null; then
        sh "$work/install-router.sh" "$@" </dev/tty
    else
        printf 'Откройте SSH-терминал роутера для выбора установки.\n' >&2
        exit 2
    fi
)

install_csqtt "$@"
