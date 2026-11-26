#!/bin/sh
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
set -eu
umask 077

# [058] Короткая установка: скачивает проверенный установщик и вызывает его.
# Зависимости OpenWrt готовятся не здесь, а хуком из самого установщика: при
# `--menu` состав известен только после выбора, и «только ядро» не должно
# тянуть LuCI. Хук получает точный набор и либо ставит недостающие пакеты,
# либо отказывается (код 66) — тогда на устройстве ничего не меняется.
run_installer() {
    PATH="$work/compat:$PATH" CSQTT_RELEASE_OWNER=starkugz CSQTT_RELEASE_REPO=csqtt-openwrt \
        CSQTT_RELEASE_TAG=v2.5.3 CSQTT_RELEASE_BASE_URL="$base" \
        CSQTT_DEP_HOOK="$work/dep-hook.sh" \
        CSQTT_DEP_STATE="$work/dep-state" \
        CSQTT_DEP_CACHE="$work/apk-cache" \
        CSQTT_DEP_YES="$assume_yes" \
        sh "$work/install-csqtt.sh" "$@"
}

# OpenWrt wget may be uclient-fetch and have no GNU -t/--tries option.
# Scope the adapter to this child run; installed files and system wget stay intact.
write_wget_compat() {
    CSQTT_COMPAT_WGET=$(command -v wget)
    export CSQTT_COMPAT_WGET
    mkdir -p "$work/compat"
    cat >"$work/compat/wget" <<'WGET'
#!/bin/sh
set -eu
real=${CSQTT_COMPAT_WGET:?}
remaining=$#
while [ "$remaining" -gt 0 ]; do
    case "$1" in
        -t|--tries)
            [ "$remaining" -ge 2 ] || exit 2
            shift 2
            remaining=$((remaining - 2))
            ;;
        -t[0-9]*|--tries=*)
            shift
            remaining=$((remaining - 1))
            ;;
        *)
            arg=$1
            shift
            set -- "$@" "$arg"
            remaining=$((remaining - 1))
            ;;
    esac
done
if "$real" "$@"; then
    exit 0
else
    rc=$?
    case "$*" in
        *https://github.com/*/releases/download/*)
            printf 'Не удалось скачать файл выпуска с GitHub. Доступ к raw.githubusercontent.com не гарантирует доступ к github.com. Проверьте доступ к GitHub через текущую сеть и повторите установку.\n' >&2
            ;;
    esac
    exit "$rc"
fi
WGET
    chmod 0700 "$work/compat/wget"
}

# Хук зависимостей для apk: opkg разрешает зависимости сам, там хук молчит.
# Список добавленных пакетов пишется в CSQTT_DEP_STATE до `apk add`, чтобы
# cleanup снял их при любом неуспешном завершении (отмена самого установщика,
# нехватка места, отказ менеджера).
write_dep_hook() {
    cat >"$work/dep-hook.sh" <<'HOOK'
#!/bin/sh
set -u
state=${CSQTT_DEP_STATE:?}
cache=${CSQTT_DEP_CACHE:?}
yes=${CSQTT_DEP_YES:-0}
set_name=${CSQTT_DEP_SET:?}
pm=${CSQTT_DEP_PM:-none}
root=${CSQTT_ROOT:-}
[ "$pm" = apk ] || exit 0
case "$set_name" in
core) required="kmod-tun" ;;
panel) required="luci-base rpcd-mod-ucode ucode-mod-socket coreutils-timeout" ;;
both) required="kmod-tun luci-base rpcd-mod-ucode ucode-mod-socket coreutils-timeout" ;;
*) exit 0 ;;
esac
if [ "$set_name" != panel ] && printf '%s\n' "${CSQTT_DEP_ARCH:-$(cat "$root/etc/apk/arch" 2>/dev/null)}" | grep -q '^mipsel'; then
	required="$required libgcc1"
fi
missing=
for dep in $required; do
	apk info -e "$dep" >/dev/null 2>&1 || missing="$missing $dep"
done
missing=${missing# }
[ -n "$missing" ] || exit 0
if [ "$yes" -ne 1 ]; then
	printf 'Для установки CSQTT нужны пакеты OpenWrt: %s\n' "$missing" >&2
	printf 'Добавить их? Система изменится только этими пакетами [y/N] ' >&2
	read -r answer || exit 1
	case "$answer" in y | Y | yes | YES) ;; *) exit 66 ;; esac
fi
mkdir -p "$cache"
apk --cache-dir "$cache" update >&2 || exit 1
LC_ALL=C apk --cache-dir "$cache" add --simulate $missing >"$cache/plan" 2>&1 || {
	cat "$cache/plan" >&2
	exit 1
}
if grep -Ei 'upgrading|downgrading|purging|removing|replacing|reinstalling' "$cache/plan" >&2; then
	printf 'Установка зависимостей потребовала бы изменить установленные пакеты OpenWrt.\n' >&2
	exit 1
fi
# shellcheck disable=SC2086
printf '%s\n' $missing >"$state"
# shellcheck disable=SC2086
apk --cache-dir "$cache" add $missing
HOOK
}

cleanup() {
    rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ] && [ -s "$work/dep-state" ]; then
        # Снимаются только пакеты, добавленные этим запуском и записанные в
        # состояние; уже установленные до попытки не трогаются.
        set --
        while IFS= read -r dep; do
            [ -n "$dep" ] || continue
            if apk info -e "$dep" >/dev/null 2>&1; then set -- "$@" "$dep"; fi
        done <"$work/dep-state"
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
    sha=381a58e47eea9574b6030f28aaa78d187ccce57186d59a35de78d9bcbf760b76
    assume_yes=0
    for arg in "$@"; do
        case "$arg" in
            --yes | -y) assume_yes=1 ;;
        esac
    done
    work=$(mktemp -d)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    installer_url="https://raw.githubusercontent.com/starkugz/csqtt-openwrt/cdb49dfc24fffb12eda63022dcb330d670cfc1bb/router/install-csqtt.sh"
    if ! wget -T 30 -O "$work/install-csqtt.sh" "$installer_url" ||
       [ ! -s "$work/install-csqtt.sh" ]; then
        rm -f "$work/install-csqtt.sh"
        curl -fLsS --connect-timeout 15 --max-time 60 -o "$work/install-csqtt.sh" "$installer_url"
    fi
    [ -s "$work/install-csqtt.sh" ] || { printf '%s\n' 'Установщик OpenWrt не скачан или пуст.' >&2; exit 1; }
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
    write_dep_hook
    write_wget_compat
    run_installer "$@"
}

install_router "$@"
