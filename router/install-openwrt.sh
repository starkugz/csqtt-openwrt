#!/bin/sh
case "${1:---menu}" in
2.0) ;;
*)
    choice=${1:---menu}
    [ "$#" -eq 0 ] || shift
    case "$choice" in
      --menu) set -- install --menu "$@" ;;
      2.5) set -- install --set panel "$@" ;;
      *) echo "Использование: install-openwrt.sh [--menu|2.0|2.5]" >&2; exit 2 ;;
    esac
    f=$(mktemp) || exit 1
    trap 'rm -f "$f"' EXIT
    wget -T 30 -qO "$f" https://raw.githubusercontent.com/starkugz/csqtt-openwrt/main/install.sh || exit 1
    printf '%s  %s
' 'b2c16d0f51a3dc28bdce07e815c1b7ac1e002d5f4d454c3ecd10b81df2690ebc' "$f" | sha256sum -c - || exit 1
    sh "$f" "$@"
    exit $?
    ;;
esac
#!/bin/sh
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
set -eu
umask 077

choice=${1:---menu}
case "$choice" in
    2.0)
        tag=v2.0
        installer=install-csqtt.sh
        sha=94dc5af61df134841c7b148af4876ca7d0ee80ff19b520e773bd5ca2bc4e8a7d
        ;;
    2.5|--menu)
        tag=v2.5.3
        installer=install-router.sh
        sha=f8a69518e2df17b369ff373215fa8ead81c41286c841ab55b7746f924940c337
        ;;
    *)
        printf 'Использование: sh install-openwrt.sh [--menu | 2.0 | 2.5] [--yes] [--dry-run]\n' >&2
        exit 2
        ;;
esac
[ "$#" -eq 0 ] || shift
for option do
    case "$option" in
        --yes|--dry-run) ;;
        *) printf 'Неизвестный параметр: %s\n' "$option" >&2; exit 2 ;;
    esac
done

component=panel
if [ "$choice" = --menu ]; then
    [ -t 0 ] || { printf 'Меню нужно запускать в интерактивном SSH-терминале.\n' >&2; exit 2; }
    while :; do
        printf '\nCSQTT для OpenWrt\n  1. Ядро 2.5.3 и панель CSQTT 2.5\n  2. Только ядро 2.5.3\n  3. Только панель CSQTT 2.5\n  0. Отмена\nВыберите [0–3] ' >&2
        read -r selected || exit 1
        case "$selected" in
            1) component=both; break ;;
            2) component=core; break ;;
            3) component=panel; break ;;
            0) exit 0 ;;
        esac
    done
fi

work=$(mktemp -d)
trap 'rm -f -- "$work/$installer" "$work/uclient-fetch"; rmdir -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CSQTT_ORIGINAL_UCLIENT=$(command -v uclient-fetch || :)
export CSQTT_ORIGINAL_UCLIENT

# The pinned installers prefer uclient-fetch. Keep the fallback local to
# these child processes and use the same transport for their release assets.
cat >"$work/uclient-fetch" <<'SH'
#!/bin/sh
[ "$#" -eq 4 ] && [ "$1" = -q ] && [ "$2" = -O ] || exit 2
out=$3
url=$4
if command -v wget >/dev/null 2>&1 && wget -T 30 -qO "$out" "$url" && [ -s "$out" ]; then
    exit 0
fi
if command -v curl >/dev/null 2>&1 && curl -fLsS --connect-timeout 15 --max-time 60 "$url" -o "$out" && [ -s "$out" ]; then
    exit 0
fi
if [ -n "$CSQTT_ORIGINAL_UCLIENT" ] && command -v timeout >/dev/null 2>&1 &&
    timeout 20 "$CSQTT_ORIGINAL_UCLIENT" -q -O "$out" "$url" && [ -s "$out" ]; then
    exit 0
fi
rm -f -- "$out"
printf 'Не удалось скачать %s\n' "$url" >&2
exit 1
SH
chmod 700 "$work/uclient-fetch"

base=https://github.com/starkugz/csqtt-openwrt/releases/download/$tag
"$work/uclient-fetch" -q -O "$work/$installer" "$base/$installer"
printf '%s  %s\n' "$sha" "$work/$installer" | sha256sum -c -

PATH="$work:$PATH"
export PATH
case "$choice" in
    2.0|2.5) printf 'Выбрана установка только панели CSQTT %s из %s.\n' "$choice" "$tag" ;;
esac
case "$choice" in
    2.0) CSQTT_VERSION="$tag" sh "$work/$installer" --set panel "$@" ;;
    2.5|--menu) CSQTT_RELEASE_BASE_URL="$base" sh "$work/$installer" install --set "$component" "$@" ;;
esac
