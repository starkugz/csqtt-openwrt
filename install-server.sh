#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# VPS entry point. Backend and selected binary are verified before execution.
set -euo pipefail
umask 077
die() { printf '[x] %s\n' "$*" >&2; exit 2; }
action=''; yes=0; dry=0; menu=0
peer_port=''; web_port=''
local_dir=${CSQTT_SERVER_LOCAL_DIR:-}
version=${CSQTT_VERSION:-v2.0}
repo=starkugz/csqtt-openwrt
while (($#)); do
 case "$1" in
  2.1.9|2.5.1|uninstall) [[ -z $action ]] || die 'выберите одно действие'; action=$1 ;;
  --menu) menu=1 ;;
  --yes|-y) yes=1 ;;
  --dry-run) dry=1 ;;
  --peer-port|--web-port)
   opt=$1; (($#>=2)) || die "нужно значение $opt"
   [[ $2 =~ ^[0-9]{1,5}$ ]] && ((10#$2>=1 && 10#$2<=65535)) || die 'порт должен быть числом 1–65535'
   if [[ $opt == --peer-port ]]; then peer_port=$((10#$2)); else web_port=$((10#$2)); fi
   shift ;;
  --local-dir) (($#>=2)) || die 'нужен каталог'; local_dir=$2; shift ;;
  --help|-h)
   printf '%s\n' 'bash install-server.sh [--menu | 2.1.9 | 2.5.1 | uninstall] [--yes] [--dry-run]' \
    '  --peer-port N / --web-port N: порты туннеля UDP / панели TCP.' \
    '  Без --yes незаданные порты спрашиваются в терминале; --yes сохраняет прежние или стандартные.' \
    '  --local-dir DIR: проверенный локальный комплект Release (без скачивания).' \
    '  CSQTT_VERSION: тег выпуска, по умолчанию v2.0.' \
    'Удаление сохраняет конфигурацию, базу, сертификаты и резервные копии.'
   exit 0 ;;
  *) die "неизвестный аргумент: $1" ;;
 esac
 shift
done
if [[ -z $action || $menu == 1 ]]; then
 if [[ $menu != 1 && ! -t 0 ]]; then die 'для неинтерактивного запуска укажите версию или uninstall'; fi
 if ! (: </dev/tty) 2>/dev/null; then die 'нет терминала: укажите 2.1.9, 2.5.1 или uninstall'; fi
 while :; do
  printf '\nСервер CSQTT (VPS):\n  1. Установить сервер 2.1.9 с веб-панелью\n  2. Установить сервер 2.5.1 с веб-панелью\n  3. Удалить службу и файлы CSQTT (данные сохранить)\n  0. Отмена\nВыберите [0–3]: ' >&2
  read -r choice </dev/tty || die 'выбор отменён'
  case "$choice" in 1) action=2.1.9;; 2) action=2.5.1;; 3) action=uninstall;; 0) exit 0;; *) continue;; esac
  break
 done
fi
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'этот комплект предназначен для Linux x86-64 с systemd'
[[ $EUID == 0 ]] || die 'запустите от root (sudo bash install-server.sh)'
[[ $version =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'неверный тег выпуска'
for cmd in sha256sum awk mktemp; do command -v "$cmd" >/dev/null || die "не найдена команда $cmd"; done
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -z $local_dir && -f $script_dir/SHA256SUMS ]]; then local_dir=$script_dir; fi
if [[ -n $local_dir ]]; then
 [[ -d $local_dir ]] || die 'локальный каталог не найден'
 local_dir=$(cd -- "$local_dir" && pwd)
else
 command -v curl >/dev/null || die 'нужен curl: apt-get install ca-certificates curl'
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/csqtt-server-download.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
fetch() {
 local name=$1 dest=$2
 mkdir -p -- "$(dirname -- "$dest")"
 if [[ -n $local_dir ]]; then
  [[ -f $local_dir/$name ]] || die "нет файла $name в локальном комплекте"
  cp -- "$local_dir/$name" "$dest"
 else
  # GitHub Release assets are flat; local server/ layout is preserved only on disk.
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
   --connect-timeout 15 --max-time 180 --retry 2 \
   "https://github.com/$repo/releases/download/$version/${name##*/}" -o "$dest" || die "не удалось скачать $name из выпуска $version"
 fi
}
fetch SHA256SUMS "$work/SHA256SUMS"
verified_fetch() {
 local name=$1 hash count got
 hash=$(awk -v n="$name" '{p=$2;sub(/^\*/,"",p);sub(/^\.\//,"",p);if(p==n)print $1}' "$work/SHA256SUMS")
 count=$(printf '%s\n' "$hash" | wc -l)
 [[ $count == 1 && $hash =~ ^[a-fA-F0-9]{64}$ ]] || die "нет однозначной SHA-256 для $name"
 fetch "$name" "$work/$name"
 got=$(sha256sum "$work/$name"); got=${got%% *}
 [[ ${got,,} == "${hash,,}" ]] || die "SHA-256 не совпала: $name"
}
verified_fetch server-install.sh
args=()
((dry==0)) || args+=(--dry-run)
((yes==0)) || args+=(--yes)
[[ -z $peer_port ]] || args+=(--peer-port "$peer_port")
[[ -z $web_port ]] || args+=(--web-port "$web_port")
if [[ $action == uninstall ]]; then
 # No global package removal, firewall flush or unrelated service restart.
 bash "$work/server-install.sh" uninstall "${args[@]}"
else
 binary="server/csqtt-server-linux-amd64-$action"
 verified_fetch "$binary"
 case "$action" in
  2.1.9) pinned=9740816075518c9d1d09524db0a9abb48a73b554a8dba6963f40b800ce65f9d3 ;;
  2.5.1) pinned=6bb29d0ea9ac47fcbd11d118022b9dba6dc309dc121491d73e6208db60cb9d35 ;;
 esac
 got=$(sha256sum "$work/$binary"); [[ ${got%% *} == "$pinned" ]] || die 'бинарник не соответствует закреплённому серверному варианту'
 printf 'Выбран сервер %s. Существующая конфигурация сохраняется.\n' "$action"
 bash "$work/server-install.sh" install --binary "$work/$binary" --sha256 "$pinned" "${args[@]}"
fi
