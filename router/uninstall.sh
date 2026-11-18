#!/bin/sh
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

uninstall_router() (
    set -eu
    umask 077
    # Compatibility entry point. No dependency on deleted Release assets.
    url=https://raw.githubusercontent.com/starkugz/csqtt-openwrt/4446b976825a421eb9d59d2296b726aa41c22cb4/router/install.sh
    sha=7ef72d89458a3b040e06628a0ac56d8491dd3fddadb08f14b9678ceb2cbdd90a
    file=$(mktemp)
    trap 'rm -f -- "$file"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if command -v wget >/dev/null 2>&1 && wget -T 30 -qO "$file" "$url"; then
        :
    elif command -v curl >/dev/null 2>&1; then
        curl -fLsS --connect-timeout 15 --max-time 60 -o "$file" "$url"
    else
        printf 'Не удалось скачать установщик удаления.\n' >&2
        exit 1
    fi
    printf '%s  %s\n' "$sha" "$file" | sha256sum -c -
    if [ "$#" -eq 0 ]; then set -- uninstall --menu; else set -- uninstall "$@"; fi
    if [ -t 0 ]; then
        sh "$file" "$@"
    elif ( : </dev/tty ) 2>/dev/null; then
        sh "$file" "$@" </dev/tty
    else
        sh "$file" "$@"
    fi
)
uninstall_router "$@"
