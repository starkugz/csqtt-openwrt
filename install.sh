#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
install_csqtt() (
    set -eu
    umask 077
    base=https://raw.githubusercontent.com/starkugz/csqtt-openwrt/b9198e211ece25f1c7671cb6b869250c02c6a9cc
    if [ -f /etc/openwrt_release ]; then
        installer=router/install.sh
        sha=2d2b5a704726f334ec281621c8d45c067fe2a09e612849ffd8790521d7a639cc
        platform=OpenWrt
        case "${1:---menu}" in
            --menu) [ "$#" -eq 0 ] || shift; set -- install --menu "$@" ;;
            2.5) shift; set -- install --set panel "$@" ;;
            2.0)
                shift
                base=https://github.com/starkugz/csqtt-openwrt/releases/download/v2.0
                installer=install-csqtt.sh
                sha=94dc5af61df134841c7b148af4876ca7d0ee80ff19b520e773bd5ca2bc4e8a7d
                export CSQTT_VERSION=v2.0
                set -- --set panel "$@"
                ;;
        esac
    else
        installer=server/install.sh
        sha=03d7956de0c81bbef253f23d4a48efecc59b8f529797db50618d60dbfffcc26c
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
       wget -T 30 -qO "$work/installer.sh" "$base/$installer"; then
        :
    elif command -v curl >/dev/null 2>&1; then
        curl -fLsS --connect-timeout 15 --max-time 60 -o "$work/installer.sh" "$base/$installer"
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
        printf 'Откройте SSH-терминал для выбора установки.
' >&2
        exit 2
    fi
)
install_csqtt "$@"
