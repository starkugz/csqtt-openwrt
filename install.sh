#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
install_csqtt() (
    set -eu
    umask 077
    base=https://raw.githubusercontent.com/starkugz/csqtt-openwrt/3be75dd05d6e258e6e98ee46cdebb3f015b4df4e
    if [ -f /etc/openwrt_release ]; then
        installer=router/install.sh
        url=$base/$installer
        sha=c41e6fb7ecf667e8ffb8cb06356d5904e7b852d2d4ca049a6560495db2e61cb3
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
        url=https://raw.githubusercontent.com/starkugz/csqtt-openwrt/d1c1fd2861b07c510fdb98dcb434fb03090cbfa4/server/install.sh
        sha=b7fd760fd2ba01479aa8746c4e62321e23314dc8238346463e4cd44b1cfe049f
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
       wget -T 30 -qO "$work/installer.sh" "$url"; then
        :
    elif command -v curl >/dev/null 2>&1; then
        curl -fLsS --connect-timeout 15 --max-time 60 -o "$work/installer.sh" "$url"
    else
        printf 'Не удалось скачать установщик. Проверьте доступ к GitHub.
' >&2
        exit 1
    fi
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
