#!/bin/sh
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
set -eu
umask 077

run_installer() {
    CSQTT_RELEASE_OWNER=starkugz CSQTT_RELEASE_REPO=csqtt-openwrt \
        CSQTT_RELEASE_TAG=v2.5.3 CSQTT_RELEASE_BASE_URL="$base" \
        sh "$work/install-csqtt.sh" "$@"
}

prepare_dependencies() {
    case "${1:-}" in
        install|update) shift ;;
        *) return 0 ;;
    esac
    component=
    assume_yes=0
    menu=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --set) [ "$#" -ge 2 ] || return 0; component=$2; shift ;;
            --set=*) component=${1#--set=} ;;
            --menu) menu=1 ;;
            --yes|-y) assume_yes=1 ;;
            *) return 0 ;;
        esac
        shift
    done
    command -v apk >/dev/null 2>&1 || return 0
    if [ "$menu" -eq 1 ]; then
        # Меню выбирает состав внутри установщика, а `apk --no-network` не
        # доставляет зависимости: заранее берётся общий набор ядра и панели и
        # показывается пользователю. Уже установленные пакеты не добавляются.
        component=both
    fi

    set --
    case "$component" in
        core) set -- kmod-tun ;;
        panel) set -- luci-base rpcd-mod-ucode ucode-mod-socket coreutils-timeout ;;
        both) set -- kmod-tun luci-base rpcd-mod-ucode ucode-mod-socket coreutils-timeout ;;
        *) return 0 ;;
    esac
    if [ "$component" != panel ] && grep -q '^mipsel' /etc/apk/arch 2>/dev/null; then
        set -- "$@" libgcc1
    fi
    required="$*"
    set --
    for dep in $required; do
        apk info -e "$dep" >/dev/null 2>&1 || set -- "$@" "$dep"
    done
    [ "$#" -gt 0 ] || return 0
    run_installer check --set "$component"
    if [ "$assume_yes" -eq 0 ]; then
        printf 'Продолжить установку CSQTT? Будут добавлены зависимости OpenWrt (%s) [y/N] ' "$*" >&2
        read -r answer || exit 1
        case "$answer" in y|Y|yes|YES) ;; *) exit 0 ;; esac
    fi
    mkdir "$work/apk-cache"
    apk --cache-dir "$work/apk-cache" update
    LC_ALL=C apk --cache-dir "$work/apk-cache" add --simulate "$@" >"$work/apk-plan" 2>&1 || {
        cat "$work/apk-plan" >&2
        return 1
    }
    if grep -Ei 'upgrading|downgrading|purging|removing|replacing|reinstalling' "$work/apk-plan" >&2; then
        printf 'Установка зависимостей требует изменения установленных пакетов OpenWrt.\n' >&2
        return 1
    fi
    added_dependencies="$*"
    apk --cache-dir "$work/apk-cache" add "$@"
}

cleanup() {
    rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ] && [ -n "$added_dependencies" ]; then
        # Only packages absent before this attempt may be removed.
        set --
        for dep in $added_dependencies; do
            if apk info -e "$dep" >/dev/null 2>&1; then set -- "$@" "$dep"; fi
        done
        if [ "$#" -gt 0 ]; then
            apk --no-network del "$@" ||
                printf 'Не удалось удалить добавленные зависимости OpenWrt.\n' >&2
        fi
    fi
    rm -rf -- "$work"
    exit "$rc"
}

install_router() {
    base=${CSQTT_RELEASE_BASE_URL:-https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3}
    sha=8e25652812fea2554f6c27a1ae75628ad470b5557ff3ba56a6a78e905dc571cd
    work=$(mktemp -d)
    added_dependencies=
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    wget -T 30 -O "$work/install-csqtt.sh" "https://raw.githubusercontent.com/starkugz/csqtt-openwrt/88c4139636a3ab4081b48c17bec28d1417748b0d/router/install-csqtt.sh"
    printf '%s  %s\n' "$sha" "$work/install-csqtt.sh" | sha256sum -c -

    if [ "$#" -eq 0 ]; then
        # Интерактивный терминал получает меню состава; конвейер
        # (`wget -O - ... | sh`) остаётся неинтерактивным и ставит оба
        # компонента, как и раньше.
        if [ -t 0 ]; then
            set -- install --menu
        else
            set -- install --set both
        fi
    fi
    prepare_dependencies "$@"
    if [ -n "$added_dependencies" ]; then
        run_installer "$@" --yes
    else
        run_installer "$@"
    fi
}

install_router "$@"
