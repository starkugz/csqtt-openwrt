#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
install_csqtt() (
    set -eu
    umask 077
    base=https://raw.githubusercontent.com/starkugz/csqtt-openwrt/5197c9a7f5657aa29823091fddeb7e1cc3d8a49b
    if [ -f /etc/openwrt_release ]; then
        installer=router/install.sh
        url=$base/$installer
        sha=670bb0696cafccdbff5ab1da47604ae0535ed894302921d5e5a35d7fb65c0ed7
        platform=OpenWrt
        case "${1:---menu}" in
            --menu) [ "$#" -eq 0 ] || shift; set -- install --menu "$@" ;;
            2.5) shift; set -- install --set panel "$@" ;;
            --release)
                [ "$#" -ge 2 ] || { printf 'Укажите выпуск: --release v2.5.3\n' >&2; exit 2; }
                release=$2
                shift 2
                case "$release" in
                    v2.5.3|2.5.3)
                        [ "$#" -gt 0 ] || set -- install --menu
                        ;;
                    *) printf 'Неизвестный выпуск: %s. Доступен v2.5.3.\n' "$release" >&2; exit 2 ;;
                esac
                ;;
            2.0) printf 'Панель 2.0 больше не поставляется. Используйте меню текущего выпуска.\n' >&2; exit 2 ;;
        esac
    else
        installer=server/install.sh
        url=https://raw.githubusercontent.com/starkugz/csqtt-openwrt/b398d63aed74ae7a528a2eb2d5e4696383281f06/server/install.sh
        sha=916ce8b3bf533ddfbb2d9c8bfabc7a4c6647bbbc41fdbadc3aceb6cfa27a7d91
        platform=VPS
        [ "$#" -gt 0 ] || set -- --menu
    fi
    work=$(mktemp -d)
    trap 'rm -f "$work/installer.sh"; rmdir "$work"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf 'CSQTT — загрузка установщика %s…
' "$platform"
    if command -v wget >/dev/null 2>&1 &&
       wget -T 30 -qO "$work/installer.sh" "$url" &&
       [ -s "$work/installer.sh" ]; then
        :
    elif command -v curl >/dev/null 2>&1; then
        curl -fLsS --connect-timeout 15 --max-time 60 -o "$work/installer.sh" "$url"
    else
        printf 'Не удалось скачать установщик. Проверьте доступ к GitHub.
' >&2
        exit 1
    fi
    [ -s "$work/installer.sh" ] || { printf '%s\n' 'Установщик не скачан или пуст.' >&2; exit 1; }
    printf '%s  %s
' "$sha" "$work/installer.sh" | sha256sum -c -
    if [ -t 0 ]; then
        sh "$work/installer.sh" "$@"
    elif ( : </dev/tty ) 2>/dev/null; then
        sh "$work/installer.sh" "$@" </dev/tty
    else
        sh "$work/installer.sh" "$@"
    fi
)
install_csqtt "$@"
