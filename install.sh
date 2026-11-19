#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
install_csqtt() (
    set -eu
    umask 077
    legacy_download=0
    base=https://raw.githubusercontent.com/starkugz/csqtt-openwrt/a28f5e1f3253b730ea4fc81855587a40789b8946
    if [ -f /etc/openwrt_release ]; then
        installer=router/install.sh
        sha=7ef72d89458a3b040e06628a0ac56d8491dd3fddadb08f14b9678ceb2cbdd90a
        platform=OpenWrt
        case "${1:---menu}" in
            --menu) [ "$#" -eq 0 ] || shift; set -- install --menu "$@" ;;
            2.5) shift; set -- install --set panel "$@" ;;
            --release)
                [ "$#" -ge 2 ] || { printf 'Укажите выпуск: --release v2.0 или --release v2.5.3\n' >&2; exit 2; }
                release=$2
                shift 2
                case "$release" in
                    v2.0|2.0)
                        base=https://github.com/starkugz/csqtt-openwrt/releases/download/v2.0
                        installer=install-csqtt.sh
                        sha=94dc5af61df134841c7b148af4876ca7d0ee80ff19b520e773bd5ca2bc4e8a7d
                        legacy_download=1
                        export CSQTT_VERSION=v2.0
                        [ "$#" -gt 0 ] || set -- --menu
                        ;;
                    v2.5.3|2.5.3)
                        [ "$#" -gt 0 ] || set -- install --menu
                        ;;
                    *) printf 'Неизвестный выпуск: %s. Доступны v2.0 и v2.5.3.\n' "$release" >&2; exit 2 ;;
                esac
                ;;
            2.0)
                shift
                base=https://github.com/starkugz/csqtt-openwrt/releases/download/v2.0
                installer=install-csqtt.sh
                sha=94dc5af61df134841c7b148af4876ca7d0ee80ff19b520e773bd5ca2bc4e8a7d
                legacy_download=1
                export CSQTT_VERSION=v2.0
                set -- --set panel "$@"
                ;;
        esac
    else
        installer=server/install.sh
        sha=3a5cd8a91dc99b2b14c3bd372ea3e560315fb51152e4be6ece1fae84bbd09c75
        platform=VPS
        [ "$#" -gt 0 ] || set -- --menu
    fi
    work=$(mktemp -d)
    trap 'rm -f "$work/installer.sh" "$work/uclient-fetch"; rmdir "$work"' EXIT
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
    # Старый установщик выбирает uclient-fetch без резервного транспорта.
    # Подмена действует только для дочернего установщика выпуска 2.0.
    if [ "$legacy_download" -eq 1 ]; then
        cat >"$work/uclient-fetch" <<'LEGACY_FETCH'
#!/bin/sh
[ "$#" -eq 4 ] && [ "$1" = -q ] && [ "$2" = -O ] || exit 2
out=$3
url=$4
if command -v wget >/dev/null 2>&1 && wget -T 30 -qO "$out" "$url"; then
    [ -s "$out" ] && exit 0
fi
if command -v curl >/dev/null 2>&1 &&
   curl -fLsS --connect-timeout 15 --max-time 60 -o "$out" "$url"; then
    [ -s "$out" ] && exit 0
fi
rm -f "$out"
exit 1
LEGACY_FETCH
        chmod 700 "$work/uclient-fetch"
        PATH="$work:$PATH"
        export PATH
    fi
    if [ -t 0 ]; then
        sh "$work/installer.sh" "$@"
    elif ( : </dev/tty ) 2>/dev/null; then
        sh "$work/installer.sh" "$@" </dev/tty
    else
        sh "$work/installer.sh" "$@"
    fi
)
install_csqtt "$@"
