#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# wget -T 30 -qO- https://raw.githubusercontent.com/starkugz/csqtt-openwrt/main/install.sh | ash

install_csqtt() (
    set -eu
    umask 077
    if [ -f /etc/openwrt_release ]; then
        installer=install-router.sh
        sha=937451cbb04c9c5c4f659da10a08c4631ef898f77d4d0a80c01bc6c49f95e65a
        platform=OpenWrt
        [ "$#" -gt 0 ] || set -- install --menu
    else
        installer=install-server.sh
        sha=72c47678c36e367696634dbe3bc9c6d95f53c73286140a94e5293106b1d0eb7e
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
