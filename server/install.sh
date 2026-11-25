#!/bin/sh
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
set -eu
umask 077

die() { printf '%s\n' "$*" >&2; exit 1; }

case "${1:---menu}" in
    -h|--help)
        printf '%s\n' 'sh install-server.sh [--menu | 2.1.9 | 2.5.3 | uninstall] [--yes] [--dry-run]'
        exit 0 ;;
    --menu)
        [ "$#" -eq 0 ] || shift
        while :; do
            printf '\nСервер CSQTT (VPS)\n  1. Установить сервер 2.1.9\n  2. Установить сервер 2.5.3\n  3. Удалить службу с сохранением данных\n  0. Отмена\nВыберите [0–3] ' >&2
            read -r choice </dev/tty || die 'Для запуска без терминала укажите версию или uninstall.'
            case "$choice" in
                1) version=2.1.9; break ;;
                2) version=2.5.3; break ;;
                3) version=uninstall; break ;;
                0) exit 0 ;;
            esac
        done ;;
    2.1.9|2.5.3|uninstall) version=$1; shift ;;
    *) die 'Укажите --menu, 2.1.9, 2.5.3 или uninstall.' ;;
esac

[ "$(uname -s)" = Linux ] || die 'Серверный комплект предназначен для Linux с systemd.'
binary=
case "$(uname -s):$(uname -m):$version" in
    Linux:*:uninstall) ;;
    Linux:x86_64:2.1.9)
        binary=csqtt-server-linux-amd64-2.1.9
        binary_sha=9740816075518c9d1d09524db0a9abb48a73b554a8dba6963f40b800ce65f9d3 ;;
    Linux:x86_64:2.5.3)
        binary=csqtt-linux-amd64
        binary_sha=9cc65301ef4c4301a6e6bfa112096579176b27cc0e7dd8a9a0a0e6503ccacd7d ;;
    Linux:aarch64:2.5.3)
        binary=csqtt-linux-arm64
        binary_sha=599e26477d74e2979632fda09a17dc13256f78d133953f00a8b49b5c2055f88b ;;
    Linux:armv7l:2.5.3)
        binary=csqtt-linux-armv7
        binary_sha=9c2c6ec767572d7acac9d8f8a327684bbf52acaa030e4e8f6fc96a9156ca05a1 ;;
    *) die 'Для выбранной версии и архитектуры нет серверного пакета.' ;;
esac

# Проверяем инструменты до загрузки файлов; пакеты и службы здесь не меняем.
missing=
require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        missing="${missing}${missing:+, }$1"
    fi
}
for tool in bash curl sha256sum; do require_tool "$tool"; done
if [ "$version" != uninstall ]; then
    require_tool "${CSQTT_INSTALL_SYSTEMCTL:-systemctl}"
    require_tool "${CSQTT_INSTALL_IP:-ip}"
    require_tool "${CSQTT_INSTALL_SS:-ss}"
    require_tool "${CSQTT_INSTALL_SYSCTL:-sysctl}"
    for tool in python3 tar od; do require_tool "$tool"; done
    no_nat=0
    for arg in "$@"; do [ "$arg" != --no-nat ] || no_nat=1; done
    if [ "$no_nat" -eq 0 ]; then require_tool "${CSQTT_INSTALL_IPTABLES:-iptables}"; fi
fi
if [ -n "$missing" ]; then
    printf 'Не хватает обязательных утилит: %s. Файлы не скачивались, служба не менялась.\n' "$missing" >&2
    printf '%s\n' 'Debian/Ubuntu, от root: apt-get update && apt-get install -y bash curl ca-certificates coreutils python3 tar procps iproute2 iptables' >&2
    printf '%s\n' 'Для другой системы установите соответствующие пакеты её менеджером. Требуется Linux с systemd и /dev/net/tun. Затем повторите команду.' >&2
    exit 66
fi

base=https://raw.githubusercontent.com/starkugz/csqtt-openwrt/b7afa632a97e0d79aa7ee581ee4e698c87fd945f/server/v2.5.3
backend=server-install.sh
backend_sha=0ee60a65f602dca23030c28b984fdd9accc2006bd3a13e4899cb5ec085341a85
source_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -f -- "$work/$backend"; if [ -n "$binary" ]; then rm -f -- "$work/$binary"; fi; rmdir -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stage_asset() {
    if [ -f "$source_dir/$1" ]; then
        cp -- "$source_dir/$1" "$work/$1"
    else
        curl --fail --silent --show-error --location --proto '=https' \
            --proto-redir '=https' --connect-timeout 15 --max-time 180 \
            --output "$work/$1" "$(if [ "$1" = "$backend" ]; then
                printf '%s' 'https://raw.githubusercontent.com/starkugz/csqtt-openwrt/a47cd82d2aac47d2e2306affe486ccc8d85a7110/server/backend.sh'
            else
                printf '%s' "$base/$1"
            fi)"
    fi
    printf '%s  %s\n' "$2" "$work/$1" | sha256sum -c - >&2
}

stage_asset "$backend" "$backend_sha"
if [ "$version" = uninstall ]; then
    bash "$work/$backend" uninstall "$@"
    exit
fi
stage_asset "$binary" "$binary_sha"
bash "$work/$backend" install --binary "$work/$binary" --sha256 "$binary_sha" "$@"
