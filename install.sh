#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
install_csqtt() (
    set -eu
    umask 077
    legacy_download=0
    base=https://raw.githubusercontent.com/starkugz/csqtt-openwrt/b1ef8086d4f11d6e1fccc6c1226fb51fb8b2cd65
    if [ -f /etc/openwrt_release ]; then
        installer=router/install.sh
        sha=46ffcf38f3a44929ae0e573553b82ba1ac3aa14b25dee46fb84faf2a7adf0b10
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
        sha=df29d3f7a3ec68e0df7909048ebf8aa4ad0f99d694f8dfc74f8c74e149e273f9
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
