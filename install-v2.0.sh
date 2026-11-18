#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
install_csqtt_20() (
    set -eu
    umask 077
    [ -f /etc/openwrt_release ] || { printf 'Этот установщик предназначен для роутера OpenWrt.\n' >&2; exit 2; }
    url=https://raw.githubusercontent.com/starkugz/csqtt-openwrt/8df734abe166e62a13f039b3ddf1027d361b920e/install.sh
    sha=145a9d24bfe2d2b7cfaf10f2ca9f16ba5f4f0f400aaf5e5cfef63d9d47d9f791
    file=$(mktemp)
    trap 'rm -f "$file"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if command -v wget >/dev/null 2>&1 && wget -T 30 -qO "$file" "$url"; then
        :
    elif command -v curl >/dev/null 2>&1; then
        curl -fLsS --connect-timeout 15 --max-time 60 -o "$file" "$url"
    else
        printf 'Не удалось скачать установщик CSQTT 2.0.\n' >&2
        exit 1
    fi
    printf '%s  %s\n' "$sha" "$file" | sha256sum -c -
    sh "$file" --release v2.0 "$@"
)
install_csqtt_20 "$@"