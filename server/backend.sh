#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# CSQTT server install — установка серверной части CSQTT «с нуля» на чистый
# Linux + systemd, обновление, проверка и точный откат.
#
# Схема повторяет официальный deploy.sh community-архива:
#   * бинарник /usr/local/bin/csqtt (ELF, проверяется по SHA-256);
#   * служба systemd «csqtt» с ExecStartPre-хелперами;
#   * каталог конфигурации /etc/csqtt;
#   * интерфейс csqtt1, UDP-порт peer 46000, TCP-порт панели 46002;
#   * helper-скрипты network-up.sh (forwarding/NAT/firewall/sysctl) и
#     tun-recover.sh (освобождение простаивающего TUN и UDP-порта);
#   * sysctl-настройки /etc/sysctl.d/99-csqtt*.conf;
#   * health-check и автоматический откат при провале.
#
# Границы:
#   * Секреты существующей конфигурации не читаются и не печатаются.
#     Новые web-данные создаются в env 0600 и показываются только терминалу.
#     Остальная конфигурация:
#     каталог конфигурации копируется/восстанавливается как есть.
#   * Замена только бинарника в уже развёрнутом окружении — server-deploy.sh;
#     здесь `update` дополнительно приводит unit и хелперы к текущему виду.
#   * Версию ядра/строку «2.5.1» инструмент не присваивает — фиксирует SHA-256
#     конкретного входного бинарника.
#
# Лицензия серверного бинарника — PolyForm Noncommercial 1.0.0; инструмент её
# не заменяет и Required Notice не удаляет.

set -Eeuo pipefail

readonly TOOL_NAME="csqtt-server-install"
readonly TOOL_VERSION="1.0"

# Коды возврата (стабильный контракт для автоматизации).
readonly EX_OK=0
readonly EX_USAGE=2
readonly EX_PREFLIGHT=20
readonly EX_ACTIVATION=30        # установка/health-check не удались; откат выполнен
readonly EX_ROLLBACK_FAILED=31   # откат не удался
readonly EX_LOCKED=40
readonly EX_FOREIGN=41           # чужой процесс/непонятное владение: блокировка
readonly EX_INTERNAL=50

# Значения по умолчанию. Экземпляр по умолчанию — stock-имена CSQTT; явный
# --instance NAME переключает весь namespace: unit, бинарник, каталоги, iface,
# порты, подсеть, netfilter-комментарий и имена sysctl-файлов.
INSTANCE=""
readonly DEFAULT_INSTANCE="csqtt"
SERVICE=""
TARGET_BIN=""
LIB_DIR=""
CONFIG_DIR=""
UNIT_PATH=""
IFACE=""
PEER_PORT=""
WEB_PORT=""
LE_HTTP_PORT="${CSQTT_INSTALL_LE_PORT:-80}"
SYSCTL_DIR="${CSQTT_INSTALL_SYSCTL_DIR:-/etc/sysctl.d}"
RUNTIME_DIR=""
BACKUP_ROOT=""
STATE_DIR="${CSQTT_INSTALL_STATE_DIR:-}"
SYSCTL_BIN="${CSQTT_INSTALL_SYSCTL:-sysctl}"
SYSTEMCTL_BIN="${CSQTT_INSTALL_SYSTEMCTL:-systemctl}"
IP_BIN="${CSQTT_INSTALL_IP:-ip}"
IPTABLES_BIN="${CSQTT_INSTALL_IPTABLES:-iptables}"
SS_BIN="${CSQTT_INSTALL_SS:-ss}"

SUBNET=""
SUBNET6=""
readonly XT_WAIT="5"
IPT_COMMENT=""

ENV_FILE=""
CANDIDATE=""
EXPECTED_SHA=""
SHA_FILE=""
HEALTH_CMD=""
BACKUP_DIR=""
ACTION=""

# Флаги изоляции экземпляра. Значения по умолчанию — прежнее серверное
# поведение: NAT/firewall через network-up.sh и web-панель включены.
TUN_ADDR=""
SUBNET_OVERRIDE=""
DESIRED=""
NO_NAT=0
NO_WEB=0

STABILITY_SECONDS="${CSQTT_INSTALL_STABILITY_SECONDS:-4}"
HEALTH_TIMEOUT="${CSQTT_INSTALL_HEALTH_TIMEOUT:-30}"

YES=0
FORCE=0
DRY_RUN=0
BACKUP_CONFIG=1
RESTORE_CONFIG=0

LOG_FILE=""
LOCK_FILE=""
LOCK_DIR=""
LOCK_DIR_HELD=""
LOCK_GATE=""
LOCK_GATE_HELD=""
LOCK_TOKEN=""
NEW_WEB_CREDENTIALS=0
GENERATE_WEB_CREDENTIALS=0
NEW_WEB_USER=""
NEW_WEB_PASS=""

log() {
	local msg="$*"
	printf '%s\n' "$msg" >&2
	if [ -n "$LOG_FILE" ]; then
		printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$msg" >>"$LOG_FILE" 2>/dev/null || true
	fi
}
ok() { log "[OK] $*"; }
warn() { log "[ВНИМАНИЕ] $*"; }
err() { log "[ОШИБКА] $*"; }
step() { log "==> $*"; }
die() {
	local msg="$1" code="${2:-$EX_INTERNAL}"
	err "$msg"
	exit "$code"
}
# Маркеры — только в stdout, без секретов (сообщения идут в stderr).
emit() { printf '%s\n' "$1"; }

# --- namespace экземпляра -------------------------------------------------

# Строка, которую старый stock-cleanup удаляет по подстроке. Наш side-тег не
# должен содержать ни одну из них, иначе чужая очистка снимет наши правила.
stock_tags() {
	for t in CSQTT_MANAGED CSQTT_MIRRORED CSQTT_TPROXY CSQTT_LOCAL_SOCKS CSQTT_SOCKS CSQTT_CASCADE_NO_QUIC; do
		printf '%s\n' "$t"
	done
}

instance_is_valid() {
	local name="$1" up tag stock
	[ -n "$name" ] && [ "${#name}" -le 15 ] || return 1
	case "$name" in [a-z]*) ;; *) return 1 ;; esac
	case "$name" in *[!a-z0-9-]*) return 1 ;; esac
	up=$(printf '%s' "$name" | tr 'a-z' 'A-Z')
	tag="${up}_MANAGED"
	while IFS= read -r stock; do
		case "$tag" in *"$stock"*) return 1 ;; esac
	done <<EOF
$(stock_tags)
EOF
	return 0
}

# Предварительный проход до parse_args: остальные значения по умолчанию зависят
# от имени экземпляра.
detect_instance_arg() {
	local take=0 a
	for a in "$@"; do
		if [ "$take" -eq 1 ]; then
			INSTANCE="$a"
			take=0
			continue
		fi
		case "$a" in
		--instance) take=1 ;;
		--instance=*) INSTANCE="${a#--instance=}" ;;
		esac
	done
}

apply_defaults() {
	local inst="${INSTANCE:-$DEFAULT_INSTANCE}"
	if [ "$inst" = "$DEFAULT_INSTANCE" ]; then
		INSTANCE="$DEFAULT_INSTANCE"
		SERVICE="${CSQTT_INSTALL_SERVICE:-csqtt}"
		TARGET_BIN="${CSQTT_INSTALL_BIN:-/usr/local/bin/csqtt}"
		LIB_DIR="${CSQTT_INSTALL_LIB:-/usr/local/lib/csqtt}"
		CONFIG_DIR="${CSQTT_INSTALL_CONFIG_DIR:-/etc/csqtt}"
		UNIT_PATH="${CSQTT_INSTALL_UNIT:-/etc/systemd/system/csqtt.service}"
		IFACE="${CSQTT_INSTALL_IFACE:-csqtt1}"
		PEER_PORT="${CSQTT_INSTALL_PEER_PORT:-46000}"
		WEB_PORT="${CSQTT_INSTALL_WEB_PORT:-46002}"
		RUNTIME_DIR="${CSQTT_INSTALL_RUNTIME_DIR:-/run/csqtt}"
		BACKUP_ROOT="${CSQTT_INSTALL_BACKUP_ROOT:-/var/lib/csqtt-deploy}"
		SUBNET="10.66.67.0/24"
		SUBNET6="fd66:67::/64"
		IPT_COMMENT="csqtt-server"
		TUN_ADDR=""
		return 0
	fi
	if ! instance_is_valid "$inst"; then
		die "--instance: нужно 1-15 символов a-z/0-9/'-', с буквы, без stock-подстроки CSQTT_* (получено: $inst)" "$EX_USAGE"
	fi
	INSTANCE="$inst"
	SERVICE="${CSQTT_INSTALL_SERVICE:-$inst}"
	# Как в donor deploy.sh: side-бинарник живёт в своём lib-каталоге.
	TARGET_BIN="${CSQTT_INSTALL_BIN:-/usr/local/lib/$inst/$inst}"
	LIB_DIR="${CSQTT_INSTALL_LIB:-/usr/local/lib/$inst}"
	CONFIG_DIR="${CSQTT_INSTALL_CONFIG_DIR:-/etc/$inst}"
	UNIT_PATH="${CSQTT_INSTALL_UNIT:-/etc/systemd/system/$inst.service}"
	IFACE="${CSQTT_INSTALL_IFACE:-$inst}"
	PEER_PORT="${CSQTT_INSTALL_PEER_PORT:-46100}"
	WEB_PORT="${CSQTT_INSTALL_WEB_PORT:-46102}"
	RUNTIME_DIR="${CSQTT_INSTALL_RUNTIME_DIR:-/run/$inst}"
	BACKUP_ROOT="${CSQTT_INSTALL_BACKUP_ROOT:-/var/lib/$inst-deploy}"
	SUBNET="10.66.68.0/24"
	SUBNET6="fd66:68::/64"
	IPT_COMMENT="${inst}-server"
	TUN_ADDR="10.66.68.1/24"
}

validate_ipv4() {
	local ip="$1" IFS=. o
	case "$ip" in '' | *[!0-9.]*) return 1 ;; esac
	# shellcheck disable=SC2086
	set -- $ip
	[ $# -eq 4 ] || return 1
	for o in "$@"; do
		[ -n "$o" ] || return 1
		[ "$o" -le 255 ] || return 1
	done
	return 0
}

# Согласовать --tun-addr/--subnet с правилами, которые пишет installer и
# принимает бинарник (только /24; адрес сервера вне клиентского пула .2-.250).
configure_network() {
	local ip mask last oct3
	if [ -n "$SUBNET_OVERRIDE" ]; then
		case "$SUBNET_OVERRIDE" in
		*/*) ;;
		*) die "--subnet: ожидается CIDR /24, получено: $SUBNET_OVERRIDE" "$EX_USAGE" ;;
		esac
		[ "${SUBNET_OVERRIDE##*/}" = "24" ] || die "--subnet: поддерживается только /24" "$EX_USAGE"
		validate_ipv4 "${SUBNET_OVERRIDE%/*}" || die "--subnet: некорректный IPv4: $SUBNET_OVERRIDE" "$EX_USAGE"
		SUBNET="$SUBNET_OVERRIDE"
		oct3="${SUBNET_OVERRIDE#*.*.}"
		oct3="${oct3%%.*}"
		SUBNET6="fd66:${oct3}::/64"
	fi
	[ -n "$TUN_ADDR" ] || return 0
	case "$TUN_ADDR" in
	*/*)
		ip="${TUN_ADDR%/*}"
		mask="${TUN_ADDR##*/}"
		;;
	*)
		ip="$TUN_ADDR"
		mask="24"
		;;
	esac
	[ "$mask" = "24" ] || die "--tun-addr: поддерживается только /24 (получено /$mask)" "$EX_USAGE"
	validate_ipv4 "$ip" || die "--tun-addr: некорректный IPv4: $ip" "$EX_USAGE"
	last="${ip##*.}"
	{ [ "$last" -lt 2 ] || [ "$last" -gt 250 ]; } ||
		die "--tun-addr: адрес сервера не должен быть в клиентском пуле .2-.250 (получено $ip)" "$EX_USAGE"
	oct3="${ip#*.*.}"
	oct3="${oct3%%.*}"
	if [ -z "$SUBNET_OVERRIDE" ]; then
		SUBNET="${ip%.*}.0/24"
		SUBNET6="fd66:${oct3}::/64"
	fi
	TUN_ADDR="$ip/24"
}

# Секретный desired-файл: только обычный файл 0600, содержимое не читается и не
# печатается. Отсутствие допустимо (панель создаст его позже), каталог — нет.
check_desired_file() {
	local f="$DESIRED" dir mode
	[ -n "$f" ] || return 0
	case "$f" in
	*[[:space:]]*) err "--desired: путь не должен содержать пробелов"; return 1 ;;
	/*) ;;
	*) err "--desired: нужен абсолютный путь"; return 1 ;;
	esac
	dir=$(dirname "$f")
	if [ ! -d "$dir" ]; then
		case "$dir" in
		"$CONFIG_DIR" | "$CONFIG_DIR"/*) ;;
		*)
			err "--desired: каталог не существует: $dir"
			return 1
			;;
		esac
	fi
	[ -e "$f" ] || return 0
	if [ ! -f "$f" ]; then
		err "--desired: должен быть обычным файлом: $f"
		return 1
	fi
	mode=$(stat -c '%a' -- "$f" 2>/dev/null || echo "")
	if [ "$mode" != "600" ]; then
		err "--desired: требуются права 0600 (сейчас: ${mode:-неизвестно})"
		return 1
	fi
	return 0
}

finalize_paths() {
	[ -n "$STATE_DIR" ] || STATE_DIR="$BACKUP_ROOT/state"
	[ -n "$ENV_FILE" ] || ENV_FILE="$CONFIG_DIR/$INSTANCE.env"
	SYSCTL_FORWARD_FILE="$SYSCTL_DIR/99-$INSTANCE.conf"
	SYSCTL_UDP_FILE="$SYSCTL_DIR/99-$INSTANCE-udp-buffers.conf"
}

usage() {
	cat >&2 <<EOF
$TOOL_NAME $TOOL_VERSION — установка сервера CSQTT с нуля, обновление и откат
(Linux + systemd).

Использование:
  $TOOL_NAME <действие> [параметры]

Действия:
  inventory   Только чтение: canonical/side/foreign/residue и владение портом.
  preflight   Проверка окружения и входного бинарника без изменений (dry-run).
  install     Развёртывание сервера с нуля: unit, хелперы, каталог, sysctl, запуск.
  update      Обновление бинарника и приведение unit/хелперов к текущему виду.
  status      Понятный статус без изменений (только чтение).
  verify      Проверка службы, здоровья и (необязательно) хеша установленного файла.
  rollback    Точный ручной откат к резервной копии (по умолчанию — последней).
  uninstall   Остановка и удаление unit/хелперов/бинарника (конфигурация сохраняется).

Основные параметры:
  --binary PATH         Входной серверный бинарник (ELF).
  --sha256 HEX          Ожидаемая SHA-256 входного бинарника (обязательна, если нет
                        --sha256-file).
  --sha256-file PATH    Файл с ожидаемой SHA-256 (берётся первый хеш).
  --service NAME        Имя службы systemd (по умолчанию: $SERVICE).
  --instance NAME       Имя экземпляра (csqtt — stock; side, например csqtt25).
                        Переключает unit, пути, iface, порты, подсеть, теги и
                        sysctl-имена; по умолчанию — прежнее поведение.
  --target PATH         Путь бинарника (по умолчанию: $TARGET_BIN).
  --lib-dir PATH        Каталог хелперов (по умолчанию: $LIB_DIR).
  --config-dir PATH     Каталог конфигурации (по умолчанию: $CONFIG_DIR).
  --unit PATH           Файл unit (по умолчанию: $UNIT_PATH).
  --iface NAME          Интерфейс (по умолчанию: $IFACE).
  --peer-port N         UDP-порт peer (по умолчанию: $PEER_PORT).
  --web-port N          TCP-порт панели (0 — не проверять; по умолчанию: $WEB_PORT).
  --no-web              Headless: не запускать web-панель и не проверять веб-порт.
  --tun-addr CIDR       Адрес шлюза TUN /24 (по умолчанию: stock 10.66.67.1/24;
                        для side — 10.66.68.1/24). Из него выводится подсеть.
  --subnet CIDR         Подсеть firewall/NAT /24 (по умолчанию: $SUBNET).
  --no-nat              Узел сам владеет forwarding/NAT/firewall: installer не
                        пишет network-up.sh и sysctl, бинарник получает --no-nat.
  --desired PATH        Секретный desired-passwords JSON (только файл 0600).
  --sysctl-dir PATH     Каталог sysctl-файлов (по умолчанию: $SYSCTL_DIR).
  --health-cmd CMD      Дополнительная внешняя проверка здоровья (exit 0 = здоров).
  --backup-root PATH    Корень резервных копий (по умолчанию: $BACKUP_ROOT).
  --state-dir PATH      Каталог состояния/журнала (по умолчанию: <backup-root>/state).
  --backup DIR          Каталог резервной копии для rollback/verify.
  --stability-seconds N Окно стабильности после запуска (по умолчанию: $STABILITY_SECONDS).
  --health-timeout N    Бюджет ожидания health-check, с (по умолчанию: $HEALTH_TIMEOUT).
  --no-backup-config    Не копировать каталог конфигурации.
  --restore-config      При rollback восстановить и конфигурацию из копии.
  --dry-run, -n         Показать план без изменений.
  --yes, -y             Не спрашивать подтверждение.
  --force               Выполнить установку, даже если хеш уже совпадает.
  --help, -h            Эта справка.

Секреты существующей конфигурации не выводятся. При новой установке web-логин
и пароль сохраняются в env-файле 0600 и показываются только в терминале.
В журнал установщика и аргументы процесса они не передаются.
Резервные копии создаются с правами 0700, файлы — 0600.
Смена версии сервера (2.1.9 ↔ 2.5.3) поверх установленной не поддерживается:
сначала удалите установленную версию CSQTT (uninstall сохраняет данные),
затем установите нужную. Автоматической миграции базы нет.
EOF
}

# --- утилиты --------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

sha256_of() {
	if have sha256sum; then
		sha256sum -- "$1" | awk '{print $1}'
	elif have shasum; then
		shasum -a 256 -- "$1" | awk '{print $1}'
	else
		return 1
	fi
}

# Читает e_machine (byte order little-endian) из ELF-заголовка.
elf_machine() {
	local f="$1" bytes b0 b1
	[ -f "$f" ] || return 1
	bytes=$(od -An -tx1 -j18 -N2 -- "$f" 2>/dev/null | tr -d ' \n')
	[ "${#bytes}" -eq 4 ] || return 1
	b0="${bytes:0:2}"
	b1="${bytes:2:2}"
	printf '%d\n' "0x${b1}${b0}"
}

elf_magic_ok() {
	local f="$1" magic
	[ -f "$f" ] || return 1
	magic=$(head -c4 -- "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
	[ "$magic" = "7f454c46" ]
}

host_machine() {
	case "$(uname -m)" in
	x86_64 | amd64) printf '62' ;;   # EM_X86_64
	aarch64 | arm64) printf '183' ;; # EM_AARCH64
	armv7l | armv7 | armhf) printf '40' ;; # EM_ARM
	*) printf '0' ;;
	esac
}

machine_name() {
	case "$1" in
	62) printf 'x86-64' ;;
	183) printf 'arm64' ;;
	40) printf 'armv7' ;;
	*) printf 'неизвестно(%s)' "$1" ;;
	esac
}

tcp_open() {
	local host="$1" port="$2"
	(exec 3<>"/dev/tcp/${host}/${port}") >/dev/null 2>&1
}

sd_is_active() { "$SYSTEMCTL_BIN" is-active "$SERVICE" >/dev/null 2>&1; }
sd_show() { "$SYSTEMCTL_BIN" show -p "$1" --value "$SERVICE" 2>/dev/null || true; }

# --- read-only inventory и ownership --------------------------------------
# Категории: canonical (свои файлы), side (другие экземпляры), foreign
# (чужой процесс/файл) и residue (свой остаток без службы). Ничего не меняет.

port_listener_seen() {
	have "$SS_BIN" || return 1
	"$SS_BIN" -H -lun "sport = :$PEER_PORT" 2>/dev/null | grep -q .
}

port_listener_pids() {
	have "$SS_BIN" || return 0
	"$SS_BIN" -H -lunp "sport = :$PEER_PORT" 2>/dev/null |
		sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -un
}

pid_belongs_to_instance() {
	local pid="$1" exe cmd
	[ -r "/proc/$pid/cmdline" ] || return 1
	exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
	case "$exe" in
	"$TARGET_BIN" | "$TARGET_BIN (deleted)" | "$LIB_DIR"/* | "$LIB_DIR/"*" (deleted)") return 0 ;;
	esac
	cmd=$({ tr '\0' ' ' <"/proc/$pid/cmdline"; } 2>/dev/null || true)
	case " $cmd " in
	*" $TARGET_BIN "* | *" --config-dir $CONFIG_DIR "*) return 0 ;;
	esac
	return 1
}

inventory_scan() {
	local d base unit_bin pid other
	INV_CANONICAL=""
	INV_SIDE=""
	INV_FOREIGN=""
	INV_RESIDUE=""

	[ -f "$TARGET_BIN" ] && INV_CANONICAL="${INV_CANONICAL}bin "
	[ -f "$UNIT_PATH" ] && INV_CANONICAL="${INV_CANONICAL}unit "
	[ -f "$LIB_DIR/tun-recover.sh" ] && INV_CANONICAL="${INV_CANONICAL}lib "
	[ -d "$CONFIG_DIR" ] && INV_CANONICAL="${INV_CANONICAL}config "
	sd_is_active && INV_CANONICAL="${INV_CANONICAL}service "

	# Другие экземпляры CSQTT в соседних каталогах/unit-файлах.
	base=$(basename "$LIB_DIR")
	if [ -d "$(dirname "$LIB_DIR")" ]; then
		for d in "$(dirname "$LIB_DIR")"/csqtt*; do
			[ -d "$d" ] || continue
			[ "$(basename "$d")" = "$base" ] && continue
			INV_SIDE="${INV_SIDE}${d} "
		done
	fi

	# Чужой unit по нашему пути (ExecStart указывает не на наш бинарник).
	if [ -f "$UNIT_PATH" ]; then
		unit_bin=$(awk -F= '/^ExecStart=/{print $2; exit}' "$UNIT_PATH" 2>/dev/null | awk '{print $1}')
		if [ -n "$unit_bin" ] && [ "$unit_bin" != "$TARGET_BIN" ]; then
			INV_FOREIGN="${INV_FOREIGN}unit:$UNIT_PATH->$unit_bin "
		fi
	fi
	if [ -e "$TARGET_BIN" ] && [ ! -f "$TARGET_BIN" ]; then
		INV_FOREIGN="${INV_FOREIGN}target:$TARGET_BIN "
	fi

	# Порт peer: без видимого PID владение неизвестно — это тоже блокировка.
	if port_listener_seen; then
		for pid in $(port_listener_pids); do
			if pid_belongs_to_instance "$pid"; then
				INV_CANONICAL="${INV_CANONICAL}peer:$pid "
			else
				INV_FOREIGN="${INV_FOREIGN}peer:$PEER_PORT/pid:$pid "
			fi
		done
		if [ -z "$(port_listener_pids)" ]; then
			INV_FOREIGN="${INV_FOREIGN}peer:$PEER_PORT/unknown-pid "
		fi
	fi

	# Свой остаток: файлы есть, а службы/unit нет.
	other=""
	[ -f "$TARGET_BIN" ] && other="${other}bin "
	[ -f "$LIB_DIR/tun-recover.sh" ] && other="${other}lib "
	if [ -n "$other" ] && { [ ! -f "$UNIT_PATH" ] || ! sd_is_active; }; then
		INV_RESIDUE="$other"
	fi
}

guard_ownership() {
	inventory_scan
	if [ -n "$INV_FOREIGN" ]; then
		err "чужой процесс или непонятное владение: ${INV_FOREIGN% }"
		err "изменения не вносились; installer не завершает и не убивает чужие процессы"
		return 1
	fi
	return 0
}

# TCP-порт панели проверяем до записи файлов и остановки службы.
check_web_port() {
    local listeners pids pid
    [ "$NO_WEB" -eq 0 ] && [ "${WEB_PORT:-0}" != 0 ] || return 0
    if ! listeners=$("$SS_BIN" -H -ltnp "sport = :$WEB_PORT" 2>/dev/null); then
        err "не удалось проверить TCP/$WEB_PORT через ss; установка остановлена"
        return 1
    fi
    [ -n "$listeners" ] || return 0
    pids=$(printf '%s\n' "$listeners" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -un || true)
    if [ -z "$pids" ]; then
        err "TCP/$WEB_PORT занят, владелец неизвестен; выберите другой --web-port"
        FOREIGN_BLOCK=1
        return 1
    fi
    for pid in $pids; do
        if ! pid_belongs_to_instance "$pid"; then
            err "TCP/$WEB_PORT занят чужим процессом (PID $pid); выберите другой --web-port"
            FOREIGN_BLOCK=1
            return 1
        fi
    done
}

# --- предварительная проверка --------------------------------------------

legacy_server_selected() {
    local file="${CANDIDATE:-$TARGET_BIN}"
    [ -f "$file" ] || return 1
    # Exact published original 2.1.9 payload: its CLI has no extended flags.
    [ "$(sha256_of "$file")" = 9740816075518c9d1d09524db0a9abb48a73b554a8dba6963f40b800ce65f9d3 ]
}

# Установленный сервер — опубликованный 2.1.9. Семейство определяется по
# точному SHA полезной нагрузки; локально пересобранный 2.1.9 вне области.
installed_is_legacy() {
    [ -f "$TARGET_BIN" ] || return 1
    [ "$(sha256_of "$TARGET_BIN")" = 9740816075518c9d1d09524db0a9abb48a73b554a8dba6963f40b800ce65f9d3 ]
}

# Ближайший существующий каталог (для df по ещё не созданным путям). Только
# чтение; ничего не создаёт.
existing_ancestor_dir() {
    local p="$1"
    while [ ! -d "$p" ]; do
        case "$p" in
        / | . | '') printf '/\n'; return 0 ;;
        esac
        p=$(dirname "$p")
    done
    printf '%s\n' "$p"
}

# Свободное место: требование по умолчанию 64 МиБ плюс размер входного
# бинарника на каждом участвующем каталоге. Проверка только читает (df -Pk) и
# выполняется до блокировки/записи. CSQTT_INSTALL_MIN_FREE_KB — явный порог для
# небольших VPS и изолированных тестов.
check_free_space() {
    local need_kb="${CSQTT_INSTALL_MIN_FREE_KB:-65536}" cand_kb=0 dir avail seen=" " parent
    case "$need_kb" in
    '' | *[!0-9]*) err "CSQTT_INSTALL_MIN_FREE_KB: ожидается целое число KiB"; return 1 ;;
    esac
    if [ -n "$CANDIDATE" ] && [ -f "$CANDIDATE" ]; then
        cand_kb=$((($(wc -c <"$CANDIDATE" 2>/dev/null || printf '0') + 1023) / 1024))
    fi
    need_kb=$((need_kb + cand_kb))
    for parent in "$(dirname "$TARGET_BIN")" "$LIB_DIR" "$CONFIG_DIR" \
        "$(dirname "$UNIT_PATH")" "$SYSCTL_DIR" "$RUNTIME_DIR" \
        "$BACKUP_ROOT" "${STATE_DIR:-$BACKUP_ROOT/state}"; do
        dir=$(existing_ancestor_dir "$parent")
        case "$seen" in *" $dir "*) continue ;; esac
        seen="$seen$dir "
        if ! have df; then
            err "не найдена команда df — невозможно проверить свободное место"
            return 1
        fi
        avail=$(df -Pk "$dir" 2>/dev/null | awk 'END{print $4}' || true)
        case "$avail" in
        '' | *[!0-9]*)
            err "не удалось определить свободное место для $dir (df -Pk)"
            return 1
            ;;
        esac
        if [ "$avail" -lt "$need_kb" ]; then
            err "недостаточно свободного места в $dir: доступно $((avail / 1024)) МиБ, нужно не менее $((need_kb / 1024)) МиБ (включая бинарник и резервную копию)"
            return 1
        fi
    done
    return 0
}

preflight_check() {
	local fail=0 hm cm magic sha actual installed_legacy cand_legacy
	FOREIGN_BLOCK=0

	if [ "$(uname -s)" != "Linux" ]; then
		err "поддерживается только Linux, текущая ОС: $(uname -s)"
		fail=1
	fi

	hm=$(host_machine)
	if [ "$hm" = "0" ]; then
		err "неподдерживаемая архитектура хоста: $(uname -m)"
		fail=1
	fi

	if ! have "$SYSTEMCTL_BIN"; then
		err "не найден systemd/systemctl ($SYSTEMCTL_BIN) — схема требует systemd"
		fail=1
	fi

	if ! have "$IP_BIN"; then
		err "не найден ip ($IP_BIN) — нужен для хелперов и health-check"
		fail=1
	fi

	if [ "$NO_NAT" -eq 0 ] && ! have "$IPTABLES_BIN"; then
		err "не найден $IPTABLES_BIN — установите iptables до запуска установки"
		fail=1
	fi
	for cmd in python3 tar od sysctl "$SS_BIN"; do
		if ! have "$cmd"; then err "не найдена обязательная команда $cmd"; fail=1; fi
	done

	if ! check_free_space; then
		fail=1
	fi

	if ! check_desired_file; then
		fail=1
	fi

	if [ -z "$CANDIDATE" ]; then
		err "не задан входной бинарник (--binary PATH)"
		fail=1
	elif [ ! -f "$CANDIDATE" ]; then
		err "входной бинарник не найден: $CANDIDATE"
		fail=1
	else
		if ! elf_magic_ok "$CANDIDATE"; then
			err "входной файл не является ELF: $CANDIDATE"
			fail=1
		else
			cm=$(elf_machine "$CANDIDATE" || true)
			if [ -z "$cm" ] || [ "$cm" != "$hm" ]; then
				err "архитектура бинарника ($(machine_name "${cm:-0}")) не совпадает с хостом ($(machine_name "$hm"))"
				fail=1
			fi
		fi
	fi

	# Ожидаемая контрольная сумма обязательна (подпись недоступна).
	if [ -z "$EXPECTED_SHA" ] && [ -n "$SHA_FILE" ]; then
		if [ -f "$SHA_FILE" ]; then
			EXPECTED_SHA=$(awk 'NF{print $1; exit}' "$SHA_FILE" 2>/dev/null || true)
		else
			err "файл с контрольной суммой не найден: $SHA_FILE"
			fail=1
		fi
	fi
	if [ -z "$EXPECTED_SHA" ]; then
		err "не задана ожидаемая SHA-256 (--sha256 HEX или --sha256-file PATH)"
		fail=1
	fi

	if [ -f "$CANDIDATE" ] && [ -n "$EXPECTED_SHA" ]; then
		sha=$(sha256_of "$CANDIDATE" || true)
		actual="${sha,,}"
		if [ "$actual" != "${EXPECTED_SHA,,}" ]; then
			err "несовпадение SHA-256: ожидалось ${EXPECTED_SHA,,}, получено ${actual:-<не удалось вычислить>}"
			fail=1
		fi
	fi

    if legacy_server_selected; then
        if [ "$INSTANCE" != csqtt ] || [ "$IFACE" != csqtt1 ] || { [ -n "$TUN_ADDR" ] && [ "$TUN_ADDR" != 10.66.67.1/24 ]; } || [ "$SUBNET" != 10.66.67.0/24 ] || [ "$NO_NAT" -ne 0 ] || [ "$NO_WEB" -ne 0 ] || [ -n "$DESIRED" ]; then
            err "Оригинальный сервер 2.1.9 не поддерживает --instance/--iface/--tun-addr/--no-nat/--no-web/--desired. Нужны стандартный экземпляр csqtt, csqtt1 и 10.66.67.1/24; версия автоматически не заменяется"
            fail=1
        fi
    fi

    # Смена версии поверх установленной отклоняется до резерва, записи файлов и
    # остановки службы: серверы 2.1.9 и 2.5.3 устанавливаются отдельно, база
    # автоматически не мигрирует. Повторная установка той же версии разрешена.
    if [ -f "$TARGET_BIN" ] && [ -f "$CANDIDATE" ]; then
        installed_legacy=0
        cand_legacy=0
        installed_is_legacy && installed_legacy=1
        legacy_server_selected && cand_legacy=1
        if [ "$installed_legacy" -ne "$cand_legacy" ]; then
            err "Смена версии CSQTT поверх установленной не поддерживается. Сначала удалите установленную версию CSQTT, затем установите нужную. Файлы и служба не изменялись."
            fail=1
        fi
    fi
	if ! check_web_port; then fail=1; fi

	# Чужой процесс на UDP-порту peer или непонятное владение — блокировка.
	# Свой прежний процесс допустим: служба будет перезапущена, tun-recover
	# освободит только свой порт.
	if ! guard_ownership; then
		FOREIGN_BLOCK=1
		fail=1
	fi
	if ! "$SS_BIN" -H -lun "sport = :$PEER_PORT" >/dev/null 2>&1; then
		err "не удалось проверить UDP/$PEER_PORT через ss"
		fail=1
	fi
	if [ "$fail" -eq 0 ]; then
		ok "Порты проверены: UDP/$PEER_PORT; TCP/$WEB_PORT (если web включён). Чужих слушателей нет"
	fi

	return "$fail"
}

# --- состояние и блокировка ----------------------------------------------

ensure_state() {
	mkdir -p "$STATE_DIR"
	chmod 0700 "$STATE_DIR" 2>/dev/null || true
	if [ -z "$LOG_FILE" ]; then
		LOG_FILE="$STATE_DIR/install.log"
		[ -e "$LOG_FILE" ] || : >"$LOG_FILE"
		chmod 0600 "$LOG_FILE" 2>/dev/null || true
	fi
}

take_lock() {
	ensure_state
	LOCK_FILE="$STATE_DIR/lock"
	# flock есть не на каждой минимальной системе. Используем оба механизма,
	# когда flock доступен: flock сериализует новые запуски, mkdir-блокировка
	# остаётся видимой для систем без flock (совместимость режимов).
	# CSQTT_NO_FLOCK=1 заставляет только mkdir-путь (изолированные тесты).
	if [ "${CSQTT_NO_FLOCK:-0}" != "1" ] && command -v flock >/dev/null 2>&1; then
		exec 9>"$LOCK_FILE"
		if ! flock -n 9 2>/dev/null; then
			die "другой запуск $TOOL_NAME уже выполняется ($LOCK_FILE)" "$EX_LOCKED"
		fi
	fi
	acquire_mkdir_lock
}

# Владелец блокировки: PID, время старта процесса (поле 22 /proc/PID/stat) и
# boot_id. Одного PID недостаточно: он может быть переиспользован. Запись
# владельца создаётся атомарно (owner.tmp → owner) внутри каталога блокировки.
_lock_boot_id() {
	cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
}

_lock_proc_start() {
	local pid="$1" rest
	case "$pid" in '' | *[!0-9]*) return 1 ;; esac
	[ -r "/proc/$pid/stat" ] || return 1
	rest=$(sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null) || return 1
	printf '%s\n' "$rest" | awk '{print $20}'
}

_lock_owner_write() { # каталог, токен
	local dir="$1" token="$2" tmp="$1/owner.tmp.$$"
	{
		printf 'pid=%s\n' "$$"
		printf 'start=%s\n' "$(_lock_proc_start "$$" || true)"
		printf 'boot=%s\n' "$(_lock_boot_id)"
		printf 'token=%s\n' "$token"
	} >"$tmp" 2>/dev/null && mv -f -- "$tmp" "$dir/owner" 2>/dev/null && return 0
	rm -f -- "$tmp" 2>/dev/null || true
	return 1
}

_lock_owner_field() { # каталог, ключ
	[ -f "$1/owner" ] || return 0
	awk -F= -v k="$2" '$1==k {print substr($0, index($0, "=") + 1); exit}' "$1/owner" 2>/dev/null || true
}

# Живой ли владелец каталога. Старый формат (только lock.d/pid) поддерживается:
# живой PID считается владельцем, мёртвый — устаревшей блокировкой.
_lock_owner_alive() {
	local pid start boot cur_start cur_boot
	pid=$(_lock_owner_field "$1" pid)
	if [ -z "$pid" ] && [ -f "$1/pid" ]; then
		pid=$(cat "$1/pid" 2>/dev/null || true)
	fi
	case "$pid" in '' | *[!0-9]*) return 1 ;; esac
	[ "$pid" -gt 1 ] || return 1
	kill -0 "$pid" 2>/dev/null || return 1
	start=$(_lock_owner_field "$1" start)
	[ -n "$start" ] || return 0
	cur_start=$(_lock_proc_start "$pid" || true)
	[ "$cur_start" = "$start" ] || return 1
	boot=$(_lock_owner_field "$1" boot)
	if [ -n "$boot" ]; then
		cur_boot=$(_lock_boot_id)
		[ -z "$cur_boot" ] || [ "$boot" = "$cur_boot" ] || return 1
	fi
	return 0
}

# Короткий gate-мьютекс сериализует создание lock.d и удаление устаревшей
# блокировки: окно «каталог уже есть, владелец ещё не записан» не наблюдаемо
# другими запусками. Gate держится миллисекунды; ожидание ограничено.
_lock_gate_acquire() {
	local i=0
	while ! mkdir "$LOCK_GATE" 2>/dev/null; do
		if _lock_owner_alive "$LOCK_GATE"; then
			[ "$i" -lt 100 ] || die "другой запуск $TOOL_NAME удерживает $LOCK_GATE" "$EX_LOCKED"
		elif [ "$i" -ge 10 ]; then
			# gate без живого владельца (обрыв между mkdir и записью).
			rm -rf -- "$LOCK_GATE" 2>/dev/null || true
		fi
		sleep 0.1
		i=$((i + 1))
		[ "$i" -le 120 ] || die "не удалось занять $LOCK_GATE" "$EX_LOCKED"
	done
	LOCK_GATE_HELD=1
	if ! _lock_owner_write "$LOCK_GATE" "$LOCK_TOKEN"; then
		rm -rf -- "$LOCK_GATE" 2>/dev/null || true
		LOCK_GATE_HELD=""
		die "не удалось записать владельца $LOCK_GATE" "$EX_LOCKED"
	fi
}

_lock_gate_release() {
	[ -n "${LOCK_GATE_HELD:-}" ] || return 0
	if [ "$(_lock_owner_field "$LOCK_GATE" token)" = "$LOCK_TOKEN" ]; then
		rm -rf -- "$LOCK_GATE" 2>/dev/null || true
	fi
	LOCK_GATE_HELD=""
}

acquire_mkdir_lock() {
	local _owner _waited
	LOCK_DIR="$STATE_DIR/lock.d"
	LOCK_GATE="$STATE_DIR/lock.gate"
	LOCK_TOKEN=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)
	[ "${#LOCK_TOKEN}" -eq 32 ] || die "не удалось создать токен блокировки" "$EX_LOCKED"

	_lock_gate_acquire
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		# Каталог мог только что создать процесс прежней версии (окно между
		# mkdir и записью owner/pid). Коротко ждём владельца: сносить чужую
		# активную блокировку нельзя. Пустой каталог после настоящего обрыва
		# остаётся устаревшим и перехватывается после этого ограниченного окна.
		_waited=0
		while [ ! -e "$LOCK_DIR/owner" ] && [ ! -e "$LOCK_DIR/pid" ]; do
			[ "$_waited" -lt 20 ] || break
			sleep 0.1
			_waited=$((_waited + 1))
			[ -d "$LOCK_DIR" ] || break
		done
		if _lock_owner_alive "$LOCK_DIR"; then
			_owner=$(_lock_owner_field "$LOCK_DIR" pid)
			[ -n "$_owner" ] || _owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
			_lock_gate_release
			die "другой запуск $TOOL_NAME уже выполняется (pid ${_owner:-unknown}, $LOCK_DIR)" \
				"$EX_LOCKED"
		fi
		# Устаревшая блокировка: под gate других создателей нет.
		rm -rf -- "$LOCK_DIR" 2>/dev/null || true
		if ! mkdir "$LOCK_DIR" 2>/dev/null; then
			_lock_gate_release
			die "не удалось создать блокировку $LOCK_DIR" "$EX_LOCKED"
		fi
	fi
	if ! _lock_owner_write "$LOCK_DIR" "$LOCK_TOKEN"; then
		rm -rf -- "$LOCK_DIR" 2>/dev/null || true
		_lock_gate_release
		die "не удалось записать владельца $LOCK_DIR" "$EX_LOCKED"
	fi
	LOCK_DIR_HELD="$LOCK_DIR"
	_lock_gate_release
	trap 'release_mkdir_lock' EXIT
	trap 'release_mkdir_lock; exit 130' INT
	trap 'release_mkdir_lock; exit 143' TERM
}

release_mkdir_lock() {
	_lock_gate_release
	[ -n "${LOCK_DIR_HELD:-}" ] || return 0
	# Удаляем только собственную блокировку: token должен совпасть.
	if [ "$(_lock_owner_field "$LOCK_DIR_HELD" token)" = "$LOCK_TOKEN" ]; then
		rm -rf -- "$LOCK_DIR_HELD" 2>/dev/null || true
	fi
	LOCK_DIR_HELD=""
}

confirm() {
	local prompt="$1" ans
	if [ "$YES" -eq 1 ]; then
		return 0
	fi
	if [ ! -t 0 ]; then
		die "нет терминала для подтверждения; используйте --yes" "$EX_USAGE"
	fi
	printf '%s [y/N]: ' "$prompt" >&2
	read -r ans || ans=""
	case "$ans" in
	y | Y | yes | YES) return 0 ;;
	*) die "отменено пользователем" "$EX_USAGE" ;;
	esac
}

# --- хелперы службы -------------------------------------------------------

network_helper_content() {
	cat <<NETEOF
#!/bin/sh
# CSQTT network helper: $INSTANCE. up — forwarding/NAT/firewall; down — снять
# только правила этого экземпляра (по его netfilter-комментарию).
set -eu
PEER_PORT="$PEER_PORT"
WEB_PORT="$WEB_PORT"
LE_HTTP_PORT="$LE_HTTP_PORT"
CSQTT_IFACE="$IFACE"
IPT_COMMENT="$IPT_COMMENT"
SUBNET="$SUBNET"
SUBNET6="$SUBNET6"
XT_WAIT="$XT_WAIT"
CSQTT_RUNTIME_DIR="$RUNTIME_DIR"
NETWORK_READY_FILE="$RUNTIME_DIR/network-ready"
MODE="\${1:-up}"

command -v ip >/dev/null 2>&1 || exit 20
command -v iptables >/dev/null 2>&1 || exit 21

ipt() { iptables -w "\$XT_WAIT" "\$@"; }

is_ignored_wan_interface() {
    ignored_iface="\${1%%@*}"
    case "\$ignored_iface" in
        ""|lo|"\$CSQTT_IFACE"|csqtp*|tun*|tap*|wg*|warp*|Warp*|WARP*|CloudflareWARP*|tailscale*|zt*|docker*|br-*|veth*|cni*|flannel*|virbr*|podman*|kube*|dummy*|ifb*)
            return 0
            ;;
    esac
    return 1
}

detect_wan_interface() {
    fallback=""
    for iface in \$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") {print \$(i+1); break}}'); do
        iface="\${iface%%@*}"
        [ -n "\$iface" ] || continue
        [ -n "\$fallback" ] || fallback="\$iface"
        if ! is_ignored_wan_interface "\$iface" && ip link show "\$iface" >/dev/null 2>&1; then
            echo "\$iface"
            return 0
        fi
    done
    for iface in \$(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/@.*/, "", \$2); print \$2}'); do
        iface="\${iface%%@*}"
        [ -n "\$iface" ] || continue
        [ -n "\$fallback" ] || fallback="\$iface"
        if ! is_ignored_wan_interface "\$iface" && ip link show "\$iface" >/dev/null 2>&1; then
            echo "\$iface"
            return 0
        fi
    done
    for iface in \$(ls /sys/class/net/ 2>/dev/null || true); do
        iface="\${iface%%@*}"
        [ -n "\$iface" ] || continue
        [ "\$iface" = "lo" ] && continue
        [ -n "\$fallback" ] || fallback="\$iface"
        if ! is_ignored_wan_interface "\$iface" && ip link show "\$iface" >/dev/null 2>&1; then
            echo "\$iface"
            return 0
        fi
    done
    [ -n "\$fallback" ] && echo "\$fallback"
}

WAN_IFACE=""
WAN_IP=""
if [ "\$MODE" = "down" ]; then
    WAN_IFACE=\$(detect_wan_interface || true)
    if [ -z "\$WAN_IFACE" ]; then
        WAN_IFACE=\$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") {print \$(i+1); break}}')
    fi
    if [ -n "\$WAN_IFACE" ]; then
        WAN_IP=\$(ip -4 -o addr show dev "\$WAN_IFACE" scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n 1)
    fi
    del() { ipt -D "\$@" 2>/dev/null || true; }
    del -t mangle FORWARD -s "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu
    del -t mangle FORWARD -d "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu
    del -t nat POSTROUTING -s "\$SUBNET" ! -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE
    if [ -n "\$WAN_IFACE" ]; then
        del -t nat POSTROUTING -s "\$SUBNET" -o "\$WAN_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE
        [ -n "\$WAN_IP" ] && del -t nat POSTROUTING -s "\$SUBNET" -o "\$WAN_IFACE" -m comment --comment "\$IPT_COMMENT" -j SNAT --to-source "\$WAN_IP"
    fi
    del FORWARD -i "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
    del FORWARD -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
    del INPUT -i "\$CSQTT_IFACE" -s "\$SUBNET" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
    del INPUT -p tcp --dport "\$LE_HTTP_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
    [ "\$WEB_PORT" != "0" ] && del INPUT -p tcp --dport "\$WEB_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
    del INPUT -p udp --dport "\$PEER_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
    if command -v ip6tables >/dev/null 2>&1 && ip -6 route show default 2>/dev/null | grep -q .; then
        ip6t() { ip6tables -w "\$XT_WAIT" "\$@"; }
        del6() { ip6t -D "\$@" 2>/dev/null || true; }
        del6 -t mangle FORWARD -s "\$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu
        del6 -t mangle FORWARD -d "\$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu
        del6 -t nat POSTROUTING -s "\$SUBNET6" ! -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE
        del6 FORWARD -i "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
        del6 FORWARD -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
    fi
    exit 0
fi

[ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
[ -w /proc/sys/net/ipv6/conf/all/forwarding ] && echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true
[ -w /proc/sys/net/ipv4/conf/all/rp_filter ] && echo 2 > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || true
[ -w /proc/sys/net/ipv4/conf/default/rp_filter ] && echo 2 > /proc/sys/net/ipv4/conf/default/rp_filter 2>/dev/null || true
[ -w /proc/sys/net/ipv4/tcp_notsent_lowat ] && echo 131072 > /proc/sys/net/ipv4/tcp_notsent_lowat 2>/dev/null || true

network_waited=0
while [ "\$network_waited" -lt 90 ]; do
    candidate_iface=\$(detect_wan_interface || true)
    if [ -n "\$candidate_iface" ] && ip link show "\$candidate_iface" >/dev/null 2>&1 && \\
       ip -o -4 route show default 2>/dev/null | grep -q .; then
        WAN_IFACE="\$candidate_iface"
        break
    fi
    network_waited=\$((network_waited + 1))
    sleep 1
done
[ -n "\$WAN_IFACE" ] || exit 22
[ -w "/proc/sys/net/ipv4/conf/\$WAN_IFACE/rp_filter" ] && echo 2 > "/proc/sys/net/ipv4/conf/\$WAN_IFACE/rp_filter" 2>/dev/null || true
[ -w "/proc/sys/net/ipv4/conf/\$CSQTT_IFACE/rp_filter" ] && echo 2 > "/proc/sys/net/ipv4/conf/\$CSQTT_IFACE/rp_filter" 2>/dev/null || true

# Для /32 сетей с onlink-шлюзом обеспечиваем явный host route к шлюзу.
gw=\$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if(\$i=="via") {print \$(i+1); break}}')
if [ -n "\$gw" ]; then
    ip route replace "\$gw" dev "\$WAN_IFACE" scope link 2>/dev/null || true
fi

if ip link show "\$CSQTT_IFACE" >/dev/null 2>&1; then
    ip link set dev "\$CSQTT_IFACE" txqueuelen 1000 2>/dev/null || true
fi

ipt -C INPUT -p udp --dport "\$PEER_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -p udp --dport "\$PEER_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
if [ "\$WEB_PORT" != "0" ]; then
    ipt -C INPUT -p tcp --dport "\$WEB_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -p tcp --dport "\$WEB_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
fi
ipt -C INPUT -p tcp --dport "\$LE_HTTP_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -p tcp --dport "\$LE_HTTP_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -C INPUT -i "\$CSQTT_IFACE" -s "\$SUBNET" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -i "\$CSQTT_IFACE" -s "\$SUBNET" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ipt -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ipt -C FORWARD -i "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I FORWARD -i "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -C FORWARD -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I FORWARD -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -t nat -C POSTROUTING -s "\$SUBNET" -o "\$WAN_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE 2>/dev/null || ipt -t nat -A POSTROUTING -s "\$SUBNET" -o "\$WAN_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE || true
ipt -t nat -C POSTROUTING -s "\$SUBNET" ! -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE 2>/dev/null || ipt -t nat -A POSTROUTING -s "\$SUBNET" ! -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE
WAN_IP="\$(ip -4 -o addr show dev "\$WAN_IFACE" scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n 1)"
if [ -n "\$WAN_IP" ]; then
    ipt -t nat -C POSTROUTING -s "\$SUBNET" -o "\$WAN_IFACE" -m comment --comment "\$IPT_COMMENT" -j SNAT --to-source "\$WAN_IP" 2>/dev/null || \\
    ipt -t nat -I POSTROUTING 1 -s "\$SUBNET" -o "\$WAN_IFACE" -m comment --comment "\$IPT_COMMENT" -j SNAT --to-source "\$WAN_IP" 2>/dev/null || true
fi
ipt -t mangle -C FORWARD -s "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ipt -t mangle -I FORWARD -s "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu
ipt -t mangle -C FORWARD -d "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ipt -t mangle -I FORWARD -d "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu

if command -v ip6tables >/dev/null 2>&1 && ip -6 route show default 2>/dev/null | grep -q .; then
    ip6t() { ip6tables -w "\$XT_WAIT" "\$@"; }
    ip6t -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ip6t -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ip6t -C FORWARD -i "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ip6t -I FORWARD -i "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
    ip6t -C FORWARD -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ip6t -I FORWARD -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
    ip6t -t nat -C POSTROUTING -s "\$SUBNET6" ! -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE 2>/dev/null || ip6t -t nat -A POSTROUTING -s "\$SUBNET6" ! -o "\$CSQTT_IFACE" -m comment --comment "\$IPT_COMMENT" -j MASQUERADE || true
    ip6t -t mangle -C FORWARD -s "\$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6t -t mangle -I FORWARD -s "\$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    ip6t -t mangle -C FORWARD -d "\$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6t -t mangle -I FORWARD -d "\$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi
umask 077
mkdir -p "\$CSQTT_RUNTIME_DIR"
: > "\$NETWORK_READY_FILE"
NETEOF
}

tun_recovery_helper_content() {
	cat <<RECOVEREOF
#!/bin/sh
set -eu
CSQTT_IFACE="$IFACE"
PEER_PORT="$PEER_PORT"
CSQTT_CONFIG_DIR="$CONFIG_DIR"
CSQTT_BIN="$TARGET_BIN"
CSQTT_LIB_DIR="$LIB_DIR"

peer_port_is_busy() {
    ss -H -lun "sport = :\$PEER_PORT" 2>/dev/null | grep -q .
}

peer_port_pids() {
    ss -H -lunp "sport = :\$PEER_PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -un || true
}

csqtt_process_is_owned() {
    pid="\$1"
    [ -r "/proc/\$pid/cmdline" ] || return 1
    executable="\$(readlink "/proc/\$pid/exe" 2>/dev/null || true)"
    case "\$executable" in
        \$CSQTT_BIN|"\$CSQTT_BIN (deleted)"|\$CSQTT_LIB_DIR/*|"\$CSQTT_LIB_DIR/"*" (deleted)") return 0 ;;
    esac
    command_line="\$({ tr '\\0' ' ' < "/proc/\$pid/cmdline"; } 2>/dev/null || true)"
    case " \$command_line " in
        *" --config-dir \$CSQTT_CONFIG_DIR "*|*" \$CSQTT_BIN "*) return 0 ;;
        *) return 1 ;;
    esac
}

release_owned_peer_port() {
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        peer_port_is_busy || return 0
        pids="\$(peer_port_pids)"
        if [ -z "\$pids" ]; then
            echo "[CSQTT] UDP/\$PEER_PORT is occupied by a runtime without visible PID" >&2
            ss -H -lunp "sport = :\$PEER_PORT" >&2 || true
            return 24
        fi
        for pid in \$pids; do
            if csqtt_process_is_owned "\$pid"; then
                if [ "\$attempt" -le 2 ]; then
                    echo "[CSQTT] UDP/\$PEER_PORT runtime PID \$pid; terminating" >&2
                    kill -TERM "\$pid" 2>/dev/null || true
                else
                    echo "[CSQTT] UDP/\$PEER_PORT runtime PID \$pid; killing" >&2
                    kill -KILL "\$pid" 2>/dev/null || true
                fi
            fi
        done
        sleep 0.2
    done
    echo "[CSQTT] UDP/\$PEER_PORT did not release" >&2
    ss -H -lunp "sport = :\$PEER_PORT" >&2 || true
    return 24
}

release_owned_peer_port || exit \$?

if ! ip link show "\$CSQTT_IFACE" >/dev/null 2>&1; then
    exit 0
fi

echo "[CSQTT] stale TUN interface \$CSQTT_IFACE detected; recovering runtime" >&2
for attempt in 1 2 3 4; do
    timeout 2 ip link del "\$CSQTT_IFACE" >/dev/null 2>&1 || true
    if ! ip link show "\$CSQTT_IFACE" >/dev/null 2>&1; then
        echo "[CSQTT] stale TUN interface \$CSQTT_IFACE removed" >&2
        exit 0
    fi
    sleep 0.2
done

ip -d link show "\$CSQTT_IFACE" >&2 || true
echo "[CSQTT] unable to release TUN interface \$CSQTT_IFACE" >&2
exit 23
RECOVEREOF
}

sysctl_content_forwarding() {
	cat <<SYSCTLEOF
# CSQTT: пересылка IPv4/IPv6 и ослабленный rp_filter для схемы сервера.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
SYSCTLEOF
}

sysctl_content_udp_buffers() {
	cat <<SYSCTLEOF
# CSQTT: увеличенные буферы приёма/передачи UDP для peer-трафика.
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.ipv4.tcp_notsent_lowat = 131072
SYSCTLEOF
}

unit_content() {
	local start="ExecStart=$TARGET_BIN --listen 0.0.0.0:$PEER_PORT --config-dir $CONFIG_DIR" legacy=0
    legacy_server_selected && legacy=1
	if [ "$NO_WEB" -eq 1 ]; then
		start="$start --no-web"
	else
		start="$start --web-port $WEB_PORT"
	fi
	if [ "$INSTANCE" != "$DEFAULT_INSTANCE" ]; then
		start="$start --instance $INSTANCE"
	fi
	if [ "$IFACE" != "csqtt1" ]; then
		start="$start --iface $IFACE"
	fi
	if [ -n "$TUN_ADDR" ] && [ "$legacy" -eq 0 ]; then
		start="$start --tun-addr $TUN_ADDR"
	fi
	if [ "$NO_NAT" -eq 1 ]; then
		start="$start --no-nat"
	fi
	if [ -n "$DESIRED" ]; then
		start="$start --desired $DESIRED"
	fi
	cat <<UNITEOF
[Unit]
Description=CSQTT VPN Server ($INSTANCE)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
EnvironmentFile=-$ENV_FILE
Environment=CSQTT_SERVICE_MANAGER=systemd
UNITEOF
	# no-nat: installer не ставит network-up.sh, поэтому и ExecStartPre его не
	# содержит — сетевые настройки остаются владельцу узла.
	if [ "$NO_NAT" -eq 0 ]; then
		printf 'ExecStartPre=%s/network-up.sh\n' "$LIB_DIR"
	fi
	cat <<UNITEOF
ExecStartPre=$LIB_DIR/tun-recover.sh
$start
Restart=on-failure
RestartSec=3
KillMode=control-group
# [BUG-05] Хелпер ожидания WAN ждёт не дольше 90 с (ExecStartPre).
# TimeoutStartSec обязан быть больше этого ожидания плюс запуск tun-recover,
# иначе systemd убивает helper раньше сети и юнит уходит в failed на медленном
# WAN.
TimeoutStartSec=100
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
}

write_file_atomic() { # путь, права, содержимое(stdin)
	local path="$1" mode="$2" tmp
	tmp="$(dirname "$path")/.csqtt-install.$$.tmp"
	# Функция вызывается в condition-контексте (`|| return 1`), где set -e не
	# действует, поэтому каждый шаг проверяем явно: сбой записи/прав не должен
	# превращаться в пустой или частичный файл, замаскированный успешным mv.
	cat >"$tmp" || { rm -f -- "$tmp" 2>/dev/null || true; return 1; }
	chmod "$mode" "$tmp" || { rm -f -- "$tmp" 2>/dev/null || true; return 1; }
	mv -f -- "$tmp" "$path" || { rm -f -- "$tmp" 2>/dev/null || true; return 1; }
}

prepare_new_web_credentials() {
	[ "$GENERATE_WEB_CREDENTIALS" -eq 1 ] || return 0
	[ ! -e "$ENV_FILE" ] || return 0
	mkdir -p "$(dirname "$ENV_FILE")" 2>/dev/null || return 1
	chmod 0700 "$(dirname "$ENV_FILE")" 2>/dev/null || true
	NEW_WEB_USER=$(python3 -c 'import secrets; print("csqtt_" + secrets.token_hex(4))') || return 1
	NEW_WEB_PASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))') || return 1
	printf 'CSQTT_WEB_USER=%s\nCSQTT_WEB_PASS=%s\n' "$NEW_WEB_USER" "$NEW_WEB_PASS" |
		write_file_atomic "$ENV_FILE" 0600 || return 1
	NEW_WEB_CREDENTIALS=1
}

show_web_access() {
    local panel_host
    [ "$NO_WEB" -eq 0 ] || return 0
    if [ "$NEW_WEB_CREDENTIALS" -eq 1 ]; then
        # Direct terminal output only: never pass credentials to log()/emit().
        if [ -t 2 ]; then
            panel_host=$("$IP_BIN" -o -4 addr show scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/");print a[1]}') || panel_host=''
            panel_host=${panel_host:-<IP-VPS>}
            printf '\nВход в веб-панель: https://%s:%s/\nЛогин: %s\nПароль: %s\n' "$panel_host" "$WEB_PORT" "$NEW_WEB_USER" "$NEW_WEB_PASS" >&2
            printf '%s\n' 'Если VPS за NAT, используйте внешний адрес и проброшенный порт.' >&2
        fi
        ok "Новые данные входа сохранены в $ENV_FILE (0600); в журнал установщика не записаны"
    else
        ok "Настройки существующей конфигурации не заменялись; данные входа не выводятся"
    fi
}

install_service_files() {
	step "Укладка бинарника, хелперов и unit"
	mkdir -p "$(dirname "$TARGET_BIN")" "$LIB_DIR" "$CONFIG_DIR" "$SYSCTL_DIR" "$(dirname "$UNIT_PATH")" "$RUNTIME_DIR" || {
		err "не удалось создать каталоги установки"
		return 1
	}
	chmod 0755 "$(dirname "$TARGET_BIN")" "$LIB_DIR" 2>/dev/null || true
	chmod 0700 "$CONFIG_DIR" 2>/dev/null || true
	if [ -n "$DESIRED" ]; then
		mkdir -p "$(dirname "$DESIRED")" || return 1
	fi

	# Бинарник: атомарная замена.
	write_file_atomic "$TARGET_BIN" 0755 <"$CANDIDATE" || return 1

	tun_recovery_helper_content | write_file_atomic "$LIB_DIR/tun-recover.sh" 0755 || return 1
	if [ "$NO_NAT" -eq 0 ]; then
		network_helper_content | write_file_atomic "$LIB_DIR/network-up.sh" 0755 || return 1
	else
		# no-nat: хелпер не нужен; убираем возможный остаток от прежней NAT-установки.
		rm -f -- "$LIB_DIR/network-up.sh" || return 1
	fi

	if [ "$NO_NAT" -eq 0 ]; then
		sysctl_content_forwarding | write_file_atomic "$SYSCTL_FORWARD_FILE" 0644 || return 1
		sysctl_content_udp_buffers | write_file_atomic "$SYSCTL_UDP_FILE" 0644 || return 1
	else
		# no-nat: никаких host-wide sysctl от этого экземпляра.
		rm -f -- "$SYSCTL_FORWARD_FILE" "$SYSCTL_UDP_FILE" || return 1
	fi

	unit_content | write_file_atomic "$UNIT_PATH" 0644 || return 1

	# Применяем sysctl на живой системе (мягко), только если экземпляр владеет NAT.
	if [ "$NO_NAT" -eq 0 ] && have "$SYSCTL_BIN"; then
		"$SYSCTL_BIN" -p "$SYSCTL_FORWARD_FILE" >/dev/null 2>&1 || warn "не удалось применить sysctl CSQTT forwarding"
		"$SYSCTL_BIN" -p "$SYSCTL_UDP_FILE" >/dev/null 2>&1 || warn "не удалось применить sysctl CSQTT UDP"
	fi

	"$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || {
		err "systemctl daemon-reload завершился ошибкой"
		return 1
	}
	"$SYSTEMCTL_BIN" enable "$SERVICE" >/dev/null 2>&1 || warn "systemctl enable $SERVICE не удался"
	return 0
}

remove_service_files() {
	step "Удаление unit, хелперов и бинарника"
	"$SYSTEMCTL_BIN" stop "$SERVICE" >/dev/null 2>&1 || true
	"$SYSTEMCTL_BIN" disable "$SERVICE" >/dev/null 2>&1 || true
	# Снимаем только правила своего namespace (network-up.sh down); под no-nat
	# правил этого экземпляра нет вовсе.
	if [ "$NO_NAT" -eq 0 ] && [ -x "$LIB_DIR/network-up.sh" ]; then
		"$LIB_DIR/network-up.sh" down >/dev/null 2>&1 || warn "не удалось снять netfilter-правила $IPT_COMMENT"
	fi
	rm -f -- "$UNIT_PATH" "$TARGET_BIN" \
		"$LIB_DIR/network-up.sh" "$LIB_DIR/tun-recover.sh" \
		"$SYSCTL_FORWARD_FILE" "$SYSCTL_UDP_FILE"
	rmdir "$LIB_DIR" 2>/dev/null || true
	"$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
}

# --- резервное копирование и замена ---------------------------------------

make_backup() {
	local action="$1" ts dir
	ts=$(date '+%Y%m%d-%H%M%S')
	dir="$BACKUP_ROOT/${ts}-${action}-$$"
	mkdir -p "$dir"
	chmod 0700 "$dir"

	printf '%s\n' "$ts" >"$dir/timestamp"
	printf '%s\n' "$action" >"$dir/action"
	printf '%s\n' "$SERVICE" >"$dir/service"
	printf '%s\n' "$IFACE" >"$dir/iface"
	printf '%s\n' "$WEB_PORT" >"$dir/web_port"
	printf '%s\n' "$CONFIG_DIR" >"$dir/config_dir"
	printf '%s\n' "$TARGET_BIN" >"$dir/target_bin"
	printf '%s\n' "$UNIT_PATH" >"$dir/unit_path"
	printf '%s\n' "$LIB_DIR" >"$dir/lib_dir"
	printf '%s\n' "$PEER_PORT" >"$dir/peer_port"
	printf '%s\n' "$INSTANCE" >"$dir/instance"
	printf '%s\n' "$NO_NAT" >"$dir/no_nat"
	printf '%s\n' "$NO_WEB" >"$dir/no_web"
	printf '%s\n' "$SUBNET" >"$dir/subnet"
	printf '%s\n' "$IPT_COMMENT" >"$dir/ipt_comment"
	printf '%s\n' "$TUN_ADDR" >"$dir/tun_addr"
	printf '%s\n' "$DESIRED" >"$dir/desired"
	chmod 0600 "$dir"/timestamp "$dir"/action "$dir"/service \
		"$dir"/iface "$dir"/web_port "$dir"/config_dir "$dir"/target_bin \
		"$dir"/unit_path "$dir"/lib_dir "$dir"/peer_port \
		"$dir"/instance "$dir"/no_nat "$dir"/no_web "$dir"/subnet \
		"$dir"/ipt_comment "$dir"/tun_addr "$dir"/desired 2>/dev/null || true

	# Наличие управляемых файлов до изменения (для точного отката с нуля).
	_manifest_present "$TARGET_BIN" >"$dir/binary_present"
	_manifest_present "$UNIT_PATH" >"$dir/unit_present"
	_manifest_present "$LIB_DIR/network-up.sh" >"$dir/network_helper_present"
	_manifest_present "$LIB_DIR/tun-recover.sh" >"$dir/tun_helper_present"
	_manifest_present "$SYSCTL_FORWARD_FILE" >"$dir/sysctl_forward_present"
	_manifest_present "$SYSCTL_UDP_FILE" >"$dir/sysctl_udp_present"
	chmod 0600 "$dir"/binary_present "$dir"/unit_present \
		"$dir"/network_helper_present "$dir"/tun_helper_present \
		"$dir"/sysctl_forward_present "$dir"/sysctl_udp_present 2>/dev/null || true

	if [ -f "$TARGET_BIN" ]; then
		cp -p -- "$TARGET_BIN" "$dir/previous-binary"
		chmod 0700 "$dir/previous-binary" 2>/dev/null || true
		sha256_of "$TARGET_BIN" >"$dir/previous-sha256" 2>/dev/null || echo unknown >"$dir/previous-sha256"
	fi
	for f in "$UNIT_PATH:$dir/previous-unit" "$LIB_DIR/network-up.sh:$dir/previous-network-up.sh" "$LIB_DIR/tun-recover.sh:$dir/previous-tun-recover.sh" \
		"$SYSCTL_FORWARD_FILE:$dir/previous-sysctl-forward.conf" "$SYSCTL_UDP_FILE:$dir/previous-sysctl-udp.conf"; do
		src="${f%%:*}"
		dst="${f#*:}"
		[ -f "$src" ] && cp -p -- "$src" "$dst" || true
	done
	chmod 0600 "$dir"/previous-sha256 "$dir"/previous-unit \
		"$dir"/previous-network-up.sh "$dir"/previous-tun-recover.sh \
		"$dir"/previous-sysctl-forward.conf "$dir"/previous-sysctl-udp.conf 2>/dev/null || true

	if [ "$BACKUP_CONFIG" -eq 1 ] && [ -d "$CONFIG_DIR" ]; then
		if tar -C "$(dirname "$CONFIG_DIR")" -czf "$dir/config.tar.gz" "$(basename "$CONFIG_DIR")" 2>/dev/null; then
			chmod 0600 "$dir/config.tar.gz" 2>/dev/null || true
		else
			warn "не удалось создать резервную копию конфигурации (продолжаю)"
			rm -f -- "$dir/config.tar.gz"
		fi
	fi

	printf '%s\n' "$dir"
}

_manifest_present() { [ -e "$1" ] && printf 'yes\n' || printf 'no\n'; }

# Подготовка восстановления конфигурации: резерв распаковывается во временный
# каталог, поэтому повреждённый архив не затрагивает текущую конфигурацию.
# Печатает путь к распакованному каталогу; ошибка — код 1.
restore_config_prepare() {
	local bdir="$1" tmp base
	base=$(basename "$CONFIG_DIR")
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/csqtt-restore.XXXXXX" 2>/dev/null) || return 1
	if ! tar -C "$tmp" -xzf "$bdir/config.tar.gz" 2>/dev/null; then
		rm -rf -- "$tmp"
		return 1
	fi
	if [ ! -d "$tmp/$base" ]; then
		rm -rf -- "$tmp"
		return 1
	fi
	printf '%s\n' "$tmp/$base"
}

# Атомарная замена каталога конфигурации подготовленной копией. Возвращает
# каталог целиком, поэтому удалённые после резерва файлы тоже восстанавливаются,
# а появившийся после резерва мусор уходит. При сбое старый каталог остаётся.
replace_config_dir() {
	local src="$1" old
	old="$(dirname "$CONFIG_DIR")/.$(basename "$CONFIG_DIR").rollback.$$"
	rm -rf -- "$old"
	if [ -e "$CONFIG_DIR" ] && ! mv -- "$CONFIG_DIR" "$old"; then
		return 1
	fi
	if mv -- "$src" "$CONFIG_DIR"; then
		rm -rf -- "$old"
		return 0
	fi
	[ -e "$old" ] && mv -- "$old" "$CONFIG_DIR"
	return 1
}

# Восстановление состояния из резервной копии.
# 0 — успех; 2 — файлы восстановлены, но служба не запущена (неполный откат);
# 3 — конфигурация не восстановлена, служба не перезапускалась.
rollback_to_backup() {
	local bdir="$1" restore_config="$2" had prepared

	had=$(cat "$bdir/binary_present" 2>/dev/null || echo no)

	# Прежнего бинарника не было (установка «с нуля»): возвращаем состояние
	# «нет службы» — останавливаем её и убираем созданные unit/хелперы/sysctl, не
	# выдавая это за успешный запуск.
	if [ "$had" != "yes" ]; then
		"$SYSTEMCTL_BIN" stop "$SERVICE" >/dev/null 2>&1 || true
		rm -f -- "$TARGET_BIN"
		# Всё остальное возвращаем по манифесту: если файл был до установки —
		# восстанавливаем, иначе удаляем. Чужой namespace не затрагивается.
		had=$(cat "$bdir/unit_present" 2>/dev/null || echo no)
		if [ "$had" = "yes" ] && [ -f "$bdir/previous-unit" ]; then
			install -m 0644 -- "$bdir/previous-unit" "$UNIT_PATH"
		else
			rm -f -- "$UNIT_PATH"
		fi
		had=$(cat "$bdir/network_helper_present" 2>/dev/null || echo no)
		if [ "$had" = "yes" ] && [ -f "$bdir/previous-network-up.sh" ]; then
			install -m 0755 -- "$bdir/previous-network-up.sh" "$LIB_DIR/network-up.sh"
		else
			rm -f -- "$LIB_DIR/network-up.sh"
		fi
		had=$(cat "$bdir/tun_helper_present" 2>/dev/null || echo no)
		if [ "$had" = "yes" ] && [ -f "$bdir/previous-tun-recover.sh" ]; then
			install -m 0755 -- "$bdir/previous-tun-recover.sh" "$LIB_DIR/tun-recover.sh"
		else
			rm -f -- "$LIB_DIR/tun-recover.sh"
		fi
		had=$(cat "$bdir/sysctl_forward_present" 2>/dev/null || echo no)
		if [ "$had" = "yes" ] && [ -f "$bdir/previous-sysctl-forward.conf" ]; then
			install -m 0644 -- "$bdir/previous-sysctl-forward.conf" "$SYSCTL_FORWARD_FILE"
		else
			rm -f -- "$SYSCTL_FORWARD_FILE"
		fi
		had=$(cat "$bdir/sysctl_udp_present" 2>/dev/null || echo no)
		if [ "$had" = "yes" ] && [ -f "$bdir/previous-sysctl-udp.conf" ]; then
			install -m 0644 -- "$bdir/previous-sysctl-udp.conf" "$SYSCTL_UDP_FILE"
		else
			rm -f -- "$SYSCTL_UDP_FILE"
		fi
		"$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
		return 0
	fi

	install -m 0755 -- "$bdir/previous-binary" "$TARGET_BIN"

	# Unit, хелперы и sysctl возвращаем к прежнему состоянию (или удаляем, если
	# их не было). Чужие файлы/правила не затрагиваются.
	had=$(cat "$bdir/unit_present" 2>/dev/null || echo no)
	if [ "$had" = "yes" ] && [ -f "$bdir/previous-unit" ]; then
		install -m 0644 -- "$bdir/previous-unit" "$UNIT_PATH"
	else
		rm -f -- "$UNIT_PATH"
	fi
	had=$(cat "$bdir/network_helper_present" 2>/dev/null || echo no)
	if [ "$had" = "yes" ] && [ -f "$bdir/previous-network-up.sh" ]; then
		install -m 0755 -- "$bdir/previous-network-up.sh" "$LIB_DIR/network-up.sh"
	else
		rm -f -- "$LIB_DIR/network-up.sh"
	fi
	had=$(cat "$bdir/tun_helper_present" 2>/dev/null || echo no)
	if [ "$had" = "yes" ] && [ -f "$bdir/previous-tun-recover.sh" ]; then
		install -m 0755 -- "$bdir/previous-tun-recover.sh" "$LIB_DIR/tun-recover.sh"
	else
		rm -f -- "$LIB_DIR/tun-recover.sh"
	fi
	had=$(cat "$bdir/sysctl_forward_present" 2>/dev/null || echo no)
	if [ "$had" = "yes" ] && [ -f "$bdir/previous-sysctl-forward.conf" ]; then
		install -m 0644 -- "$bdir/previous-sysctl-forward.conf" "$SYSCTL_FORWARD_FILE"
	else
		rm -f -- "$SYSCTL_FORWARD_FILE"
	fi
	had=$(cat "$bdir/sysctl_udp_present" 2>/dev/null || echo no)
	if [ "$had" = "yes" ] && [ -f "$bdir/previous-sysctl-udp.conf" ]; then
		install -m 0644 -- "$bdir/previous-sysctl-udp.conf" "$SYSCTL_UDP_FILE"
	else
		rm -f -- "$SYSCTL_UDP_FILE"
	fi

	# Конфигурация восстанавливается только по явному флагу и только если она
	# была в резерве. Сначала распаковка во временный каталог: при повреждённом
	# архиве текущая конфигурация и работающая служба не затрагиваются.
	prepared=""
	if [ "$restore_config" -eq 1 ]; then
		if [ ! -f "$bdir/config.tar.gz" ]; then
			err "в резерве $bdir нет config.tar.gz (копия создана с --no-backup-config); конфигурация не восстановлена"
			return 3
		fi
		if ! prepared=$(restore_config_prepare "$bdir"); then
			err "не удалось прочитать резерв конфигурации $bdir/config.tar.gz; текущая конфигурация и служба не изменялись"
			return 3
		fi
		"$SYSTEMCTL_BIN" stop "$SERVICE" >/dev/null 2>&1 || true
		if ! replace_config_dir "$prepared"; then
			rm -rf -- "$(dirname "$prepared")"
			err "служба остановлена, но заменить $CONFIG_DIR восстановленной копией не удалось; файлы службы уже восстановлены"
			return 3
		fi
		rm -rf -- "$(dirname "$prepared")"
	fi

	"$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
	if ! "$SYSTEMCTL_BIN" restart "$SERVICE" >/dev/null 2>&1; then
		err "файлы восстановлены, но службу $SERVICE запустить не удалось"
		return 2
	fi
	if ! wait_health; then
		err "файлы восстановлены, но служба $SERVICE не прошла health-check"
		return 2
	fi
	return 0
}

# --- health-check ---------------------------------------------------------

health_once() {
	local active sub pid
	active=$("$SYSTEMCTL_BIN" is-active "$SERVICE" 2>/dev/null || true)
	[ "$active" = "active" ] || return 1

	sub=$("$SYSTEMCTL_BIN" show -p SubState --value "$SERVICE" 2>/dev/null || true)
	[ "$sub" = "running" ] || return 1

	pid=$("$SYSTEMCTL_BIN" show -p MainPID --value "$SERVICE" 2>/dev/null || true)
	case "$pid" in '' | *[!0-9]*) return 1 ;; esac
	[ "$pid" -gt 1 ] || return 1
	kill -0 "$pid" 2>/dev/null || return 1

	if [ -n "$IFACE" ] && have "$IP_BIN"; then
		"$IP_BIN" link show "$IFACE" >/dev/null 2>&1 || return 1
	fi

	case "${WEB_PORT:-0}" in
	'' | 0) ;;
	*)
		if [ "$NO_WEB" -eq 0 ]; then
			tcp_open 127.0.0.1 "$WEB_PORT" || return 1
		fi
		;;
	esac

	if [ -n "$HEALTH_CMD" ]; then
		bash -c "$HEALTH_CMD" >/dev/null 2>&1 || return 1
	fi
	return 0
}

wait_health() {
	local deadline nr_before nr_after
	deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
	while [ "$(date +%s)" -lt "$deadline" ]; do
		if health_once; then
			break
		fi
		sleep 1
	done
	health_once || return 1

	nr_before=$(sd_show NRestarts)
	case "$nr_before" in '' | *[!0-9]*) nr_before=0 ;; esac
	sleep "$STABILITY_SECONDS"
	health_once || return 1
	nr_after=$(sd_show NRestarts)
	case "$nr_after" in '' | *[!0-9]*) nr_after=0 ;; esac
	[ "$nr_after" -le "$nr_before" ] || return 1
	return 0
}

record_current() {
	local bdir="$1" sha="$2"
	printf '%s\n' "$bdir" >"$STATE_DIR/last-backup"
	printf '%s\n' "$sha" >"$STATE_DIR/installed-sha256"
	chmod 0600 "$STATE_DIR/last-backup" "$STATE_DIR/installed-sha256" 2>/dev/null || true
}

backup_dirs() {
	local d
	[ -d "$BACKUP_ROOT" ] || return 0
	for d in "$BACKUP_ROOT"/*; do
		if [ -d "$d" ] && [ -f "$d/timestamp" ]; then
			printf '%s\n' "$d"
		fi
	done
}

# --- действия -------------------------------------------------------------

cmd_inventory() {
	inventory_scan
	echo "Inventory серверного развёртывания CSQTT ($INSTANCE, только чтение)" >&2
	printf '  canonical: %s\n' "${INV_CANONICAL:--}" >&2
	printf '  side:      %s\n' "${INV_SIDE:--}" >&2
	printf '  foreign:   %s\n' "${INV_FOREIGN:--}" >&2
	printf '  residue:   %s\n' "${INV_RESIDUE:--}" >&2
	echo "  Порт peer: UDP/$PEER_PORT; служба: $SERVICE" >&2
	emit "CSQTT_SERVER_INSTALL_INVENTORY|canonical:${INV_CANONICAL:--}|side:${INV_SIDE:--}|foreign:${INV_FOREIGN:--}|residue:${INV_RESIDUE:--}"
	return 0
}

cmd_preflight() {
	step "Предварительная проверка (без изменений)"
	step "Действие: $ACTION; хост: $(uname -s)/$(uname -m); служба: $SERVICE; экземпляр: $INSTANCE"
	if preflight_check; then
		ok "Проверка пройдена: окружение и входной бинарник совместимы"
		ok "План: установить $TARGET_BIN, unit $UNIT_PATH, хелперы в $LIB_DIR"
		ok "Интерфейс $IFACE, UDP/$PEER_PORT, TCP/$WEB_PORT; подсеть $SUBNET; конфигурация $CONFIG_DIR"
		if [ "$NO_NAT" -eq 1 ]; then
			ok "no-nat: network-up.sh и sysctl этого экземпляра не устанавливаются"
		fi
		if [ "$NO_WEB" -eq 1 ]; then
			ok "no-web: web-панель и проверка веб-порта отключены"
		fi
		if [ -n "$DESIRED" ] && [ ! -e "$DESIRED" ]; then
			warn "desired-файл ещё не создан: $DESIRED (нужен обычный файл 0600)"
		fi
		emit "CSQTT_SERVER_INSTALL_PREFLIGHT_OK|$SERVICE"
		return 0
	fi
	err "Предварительная проверка не пройдена; изменения не вносились"
	emit "CSQTT_SERVER_INSTALL_PREFLIGHT_FAILED|$SERVICE"
	if [ "$FOREIGN_BLOCK" -eq 1 ]; then
		return "$EX_FOREIGN"
	fi
	return "$EX_PREFLIGHT"
}

auto_rollback() {
	local bdir="$1" reason="${2:-health-check не пройден}" rc=0
	warn "$reason — автоматический откат к предыдущему состоянию"
	rollback_to_backup "$bdir" 0 || rc=$?
	case "$rc" in
	0)
		if [ "$NEW_WEB_CREDENTIALS" -eq 1 ]; then rm -f -- "$ENV_FILE"; fi
		ok "Предыдущее состояние восстановлено: $bdir"
		emit "CSQTT_SERVER_INSTALL_ROLLED_BACK|$bdir"
		exit "$EX_ACTIVATION"
		;;
	2)
		err "Неполный откат: файлы возвращены из $bdir, но служба $SERVICE не запущена."
		err "Причина запуска видна в: $SYSTEMCTL_BIN status $SERVICE; после устранения повторите:"
		err "  $TOOL_NAME rollback --backup $bdir"
		emit "CSQTT_SERVER_INSTALL_ROLLBACK_PARTIAL|$bdir"
		exit "$EX_ROLLBACK_FAILED"
		;;
	*)
		if [ "$NEW_WEB_CREDENTIALS" -eq 1 ]; then rm -f -- "$ENV_FILE"; fi
		err "Автоматический откат не удался: прежнее состояние не восстановлено, служба не перезапускалась."
		err "Точная команда ручного отката:"
		err "  $TOOL_NAME rollback --backup $bdir"
		emit "CSQTT_SERVER_INSTALL_ROLLBACK_FAILED|$bdir"
		exit "$EX_ROLLBACK_FAILED"
		;;
	esac
}

layout_matches() {
	[ -f "$UNIT_PATH" ] && unit_content | cmp -s - "$UNIT_PATH" || return 1
	[ -x "$LIB_DIR/tun-recover.sh" ] || return 1
	if [ "$NO_NAT" -eq 0 ]; then
		[ -x "$LIB_DIR/network-up.sh" ] || return 1
		[ -f "$SYSCTL_FORWARD_FILE" ] && [ -f "$SYSCTL_UDP_FILE" ] || return 1
	else
		[ ! -e "$LIB_DIR/network-up.sh" ] || return 1
		[ ! -e "$SYSCTL_FORWARD_FILE" ] && [ ! -e "$SYSCTL_UDP_FILE" ] || return 1
	fi
	return 0
}

cmd_install() {
	local mode="$1" cand_sha bdir
	step "Предварительная проверка"
	if ! preflight_check; then
		if [ "$FOREIGN_BLOCK" -eq 1 ]; then
			die "установка остановлена: чужой процесс/непонятное владение; изменения не вносились" "$EX_FOREIGN"
		fi
		die "предварительная проверка не пройдена; изменения не вносились" "$EX_PREFLIGHT"
	fi

	if [ "$mode" = "update" ] && [ ! -e "$TARGET_BIN" ]; then
		die "update: $TARGET_BIN не найден; для первой установки используйте install" "$EX_PREFLIGHT"
	fi

	cand_sha=$(sha256_of "$CANDIDATE")
	if [ -f "$TARGET_BIN" ] && [ "$(sha256_of "$TARGET_BIN")" = "$cand_sha" ] && \
		layout_matches && health_once; then
		if [ "$FORCE" -ne 1 ]; then
			ok "Кандидат уже установлен (SHA-256 совпадает, unit совпадает), служба здорова — изменений не требуется"
			emit "CSQTT_SERVER_INSTALL_UP_TO_DATE|$SERVICE|$cand_sha"
			return 0
		fi
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		ok "dry-run: изменения не вносились"
		emit "CSQTT_SERVER_INSTALL_DRY_RUN|$SERVICE"
		return 0
	fi

	confirm "Установить/обновить сервер CSQTT ($SERVICE) и запустить службу?"

	take_lock
    if [ "$NO_WEB" -eq 0 ] && [ ! -e "$TARGET_BIN" ] && [ ! -e "$CONFIG_DIR" ]; then
        GENERATE_WEB_CREDENTIALS=1
    fi
	bdir=$(make_backup "$mode")
	step "Резервная копия создана: $bdir"

	if ! prepare_new_web_credentials; then
		err "не удалось создать новые web-данные (env 0600)"
		auto_rollback "$bdir" "не удалось создать новые web-данные"
	fi
	# Ошибка укладки файлов приводит к точному откату, а не к частичной установке.
	if ! install_service_files; then
		err "не удалось разложить файлы службы"
		auto_rollback "$bdir" "ошибка укладки файлов службы"
	fi

	step "Запуск службы $SERVICE"
	if ! "$SYSTEMCTL_BIN" restart "$SERVICE" >/dev/null 2>&1; then
		err "systemctl restart $SERVICE завершился ошибкой"
		auto_rollback "$bdir" "служба не запустилась"
	fi

	step "Проверка запуска и здоровья"
	if wait_health; then
		record_current "$bdir" "$cand_sha"
		show_web_access
		ok "Установка завершена: служба активна, проверки пройдены"
		ok "Откат при необходимости: $TOOL_NAME rollback --backup $bdir"
		emit "CSQTT_SERVER_INSTALL_OK|$SERVICE|$cand_sha"
		return 0
	fi
	auto_rollback "$bdir"
}

cmd_status() {
	local installed_sha="-" bdir="-" n=0 latest="-" active sub pid
	echo "Статус серверного развёртывания CSQTT ($TOOL_NAME)" >&2
	printf '  Экземпляр: %s (no-nat=%s, no-web=%s)\n' "$INSTANCE" "$NO_NAT" "$NO_WEB" >&2
	echo "  Служба systemd: $SERVICE" >&2
	active=$("$SYSTEMCTL_BIN" is-active "$SERVICE" 2>/dev/null || true)
	sub=$(sd_show SubState)
	pid=$(sd_show MainPID)
	printf '  Состояние: %s/%s, MainPID=%s\n' "${active:-unknown}" "${sub:-unknown}" "${pid:-0}" >&2

	if [ -f "$TARGET_BIN" ]; then
		installed_sha=$(sha256_of "$TARGET_BIN" 2>/dev/null || echo unknown)
	fi
	printf '  Бинарник: %s (sha256 %s)\n' "$TARGET_BIN" "$installed_sha" >&2
	printf '  Unit: %s (%s)\n' "$UNIT_PATH" "$([ -f "$UNIT_PATH" ] && echo present || echo absent)" >&2
	printf '  Хелперы: %s (%s)\n' "$LIB_DIR" "$([ -f "$LIB_DIR/network-up.sh" ] && [ -f "$LIB_DIR/tun-recover.sh" ] && echo present || echo absent)" >&2

	if [ -n "$IFACE" ] && have "$IP_BIN"; then
		if "$IP_BIN" link show "$IFACE" >/dev/null 2>&1; then
			echo "  Интерфейс $IFACE: присутствует" >&2
		else
			echo "  Интерфейс $IFACE: отсутствует" >&2
		fi
	fi
	case "${WEB_PORT:-0}" in
	'' | 0) echo "  Веб-порт: проверка отключена" >&2 ;;
	*)
		if [ "$NO_WEB" -eq 1 ]; then
			echo "  Веб-порт: отключён (--no-web)" >&2
		elif tcp_open 127.0.0.1 "$WEB_PORT"; then
			echo "  Веб-порт $WEB_PORT: слушается" >&2
		else
			echo "  Веб-порт $WEB_PORT: не отвечает" >&2
		fi
		;;
	esac

	if [ -n "$STATE_DIR" ] && [ -f "$STATE_DIR/last-backup" ]; then
		bdir=$(cat "$STATE_DIR/last-backup" 2>/dev/null || echo -)
	fi
	echo "  Последняя установка: $bdir" >&2

	if [ -d "$BACKUP_ROOT" ]; then
		n=$(backup_dirs | wc -l | tr -d ' ')
		latest=$(backup_dirs | sort | tail -n1)
		[ -n "$latest" ] || latest="-"
	fi
	printf '  Резервных копий: %s; последняя: %s\n' "$n" "$latest" >&2
	echo "  Ручной откат: $TOOL_NAME rollback --backup <каталог>" >&2
	emit "CSQTT_SERVER_INSTALL_STATUS|$SERVICE|${active:-unknown}"
}

cmd_verify() {
	local fail=0 installed=""
	step "Проверка без изменений"
	if ! sd_is_active; then
		err "служба $SERVICE не активна"
		fail=1
	fi
	if [ -n "$EXPECTED_SHA" ] && [ -f "$TARGET_BIN" ]; then
		installed=$(sha256_of "$TARGET_BIN" 2>/dev/null || true)
		if [ "${installed,,}" != "${EXPECTED_SHA,,}" ]; then
			err "SHA-256 установленного бинарника не совпадает с ожидаемой"
			fail=1
		fi
	fi
	if ! health_once; then
		err "health-check не пройден"
		fail=1
	fi
	if [ "$fail" -eq 0 ]; then
		ok "Проверка пройдена"
		emit "CSQTT_SERVER_INSTALL_VERIFY_OK|$SERVICE"
		return 0
	fi
	emit "CSQTT_SERVER_INSTALL_VERIFY_FAILED|$SERVICE"
	return "$EX_PREFLIGHT"
}

cmd_rollback() {
	local bdir="$1" safety now rc=0
	[ -n "$bdir" ] || die "не указан каталог резервной копии (--backup DIR)" "$EX_USAGE"
	[ -d "$bdir" ] || die "каталог резервной копии не найден: $bdir" "$EX_USAGE"

	guard_ownership || die "откат остановлен: чужой процесс/непонятное владение" "$EX_FOREIGN"

	if [ "$DRY_RUN" -eq 1 ]; then
		ok "dry-run: откат не выполнялся; будет использована копия $bdir"
		emit "CSQTT_SERVER_INSTALL_DRY_RUN|rollback"
		return 0
	fi

	confirm "Восстановить состояние из $bdir и перезапустить $SERVICE?"

	take_lock
	safety=$(make_backup "pre-rollback")
	step "Текущее состояние сохранено: $safety"
	rollback_to_backup "$bdir" "$RESTORE_CONFIG" || rc=$?
	if [ "$rc" -eq 0 ]; then
		now=$(sha256_of "$TARGET_BIN" 2>/dev/null || echo removed)
		record_current "$safety" "$now"
		ok "Откат выполнен"
		emit "CSQTT_SERVER_INSTALL_ROLLED_BACK|$bdir"
		return 0
	fi
	if [ "$rc" -eq 2 ]; then
		die "неполный откат: файлы восстановлены из $bdir, но служба $SERVICE не запущена; текущее состояние сохранено в $safety" "$EX_ROLLBACK_FAILED"
	fi
	die "откат прерван: конфигурация не восстановлена из $bdir, служба не перезапускалась; текущее состояние сохранено в $safety" "$EX_ROLLBACK_FAILED"
}

cmd_uninstall() {
	local keep="$CONFIG_DIR" family db kept=""
	guard_ownership || die "удаление остановлено: чужой процесс/непонятное владение" "$EX_FOREIGN"
	if [ "$DRY_RUN" -eq 1 ]; then
		ok "dry-run: будут удалены $UNIT_PATH, хелперы $LIB_DIR, бинарник $TARGET_BIN"
		ok "Конфигурация сохраняется: $keep"
		emit "CSQTT_SERVER_INSTALL_DRY_RUN|uninstall"
		return 0
	fi
	# Версию снимаем до удаления бинарника, чтобы объяснить судьбу данных.
	if installed_is_legacy; then
		family="2.1.9"
	elif [ -f "$TARGET_BIN" ]; then
		family="2.5.3 (или другая сборка)"
	else
		family="неизвестна"
	fi
	confirm "Остановить службу $SERVICE и удалить unit/хелперы/бинарник (конфигурация сохранится)?"
	take_lock
	remove_service_files
	ok "Служба $SERVICE остановлена, unit/хелперы/бинарник удалены"
	ok "Конфигурация сохранена: $keep"
	for db in "$keep/csqtt.db" "$keep"/*.db; do
		[ -f "$db" ] || continue
		kept="$db"
		break
	done
	if [ -n "$kept" ]; then
		warn "В $keep осталась база: $kept (снятая версия: $family)."
		warn "Совместимость этих данных с другой версией сервера не подтверждена; автоматическая миграция не выполняется."
		warn "Для чистой установки отдельно решите, что делать с этими данными: сохранить для текущей версии или убрать вручную."
		emit "CSQTT_SERVER_UNINSTALL_DATA_KEPT|$kept"
	fi
	emit "CSQTT_SERVER_INSTALL_UNINSTALLED|$SERVICE"
}

# --- разбор аргументов ----------------------------------------------------

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		help | -h | --help) ACTION="help"; shift ;;
		--binary) CANDIDATE="${2:-}"; shift 2 ;;
		--sha256) EXPECTED_SHA="${2:-}"; shift 2 ;;
		--sha256-file) SHA_FILE="${2:-}"; shift 2 ;;
		--service) SERVICE="${2:-}"; shift 2 ;;
		--instance) INSTANCE="${2:-}"; shift 2 ;;
		--target) TARGET_BIN="${2:-}"; shift 2 ;;
		--lib-dir) LIB_DIR="${2:-}"; shift 2 ;;
		--config-dir) CONFIG_DIR="${2:-}"; shift 2 ;;
		--unit) UNIT_PATH="${2:-}"; shift 2 ;;
		--iface) IFACE="${2:-}"; shift 2 ;;
		--peer-port) PEER_PORT="${2:-}"; shift 2 ;;
		--web-port) WEB_PORT="${2:-}"; shift 2 ;;
		--no-web) NO_WEB=1; shift ;;
		--tun-addr) TUN_ADDR="${2:-}"; shift 2 ;;
		--subnet) SUBNET_OVERRIDE="${2:-}"; shift 2 ;;
		--no-nat) NO_NAT=1; shift ;;
		--desired) DESIRED="${2:-}"; shift 2 ;;
		--sysctl-dir) SYSCTL_DIR="${2:-}"; shift 2 ;;
		--health-cmd) HEALTH_CMD="${2:-}"; shift 2 ;;
		--backup-root) BACKUP_ROOT="${2:-}"; shift 2 ;;
		--state-dir) STATE_DIR="${2:-}"; shift 2 ;;
		--backup) BACKUP_DIR="${2:-}"; shift 2 ;;
		--stability-seconds) STABILITY_SECONDS="${2:-}"; shift 2 ;;
		--health-timeout) HEALTH_TIMEOUT="${2:-}"; shift 2 ;;
		--backup-config) BACKUP_CONFIG=1; shift ;;
		--no-backup-config) BACKUP_CONFIG=0; shift ;;
		--restore-config) RESTORE_CONFIG=1; shift ;;
		--dry-run | -n) DRY_RUN=1; shift ;;
		--yes | -y) YES=1; shift ;;
		--force) FORCE=1; shift ;;
		--) shift; break ;;
		-*) die "неизвестный параметр: $1" "$EX_USAGE" ;;
		*)
			if [ -z "$ACTION" ]; then
				ACTION="$1"
			else
				die "лишний аргумент: $1" "$EX_USAGE"
			fi
			shift
			;;
		esac
	done
}

main() {
	detect_instance_arg "$@"
	apply_defaults
	parse_args "$@"
	configure_network
	finalize_paths

	case "${ACTION:-help}" in
	help) usage; exit "$EX_OK" ;;
	inventory) cmd_inventory ;;
	preflight) cmd_preflight ;;
	install) cmd_install install ;;
	update) cmd_install update ;;
	status) cmd_status ;;
	verify) cmd_verify ;;
	rollback)
		local bdir="$BACKUP_DIR"
		if [ -z "$bdir" ] && [ -f "$STATE_DIR/last-backup" ]; then
			bdir=$(cat "$STATE_DIR/last-backup" 2>/dev/null || true)
		fi
		cmd_rollback "$bdir"
		;;
	uninstall) cmd_uninstall ;;
	*) usage; die "неизвестное действие: ${ACTION}" "$EX_USAGE" ;;
	esac
}

main "$@"
