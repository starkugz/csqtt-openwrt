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
#   * Доступ веб-панели хранится в root-only EnvironmentFile. После успеха
#     адрес/логин/пароль выводятся пользователю, но не в install.log/argv.
#     Остальная конфигурация копируется/восстанавливается как есть.
#   * Замена только бинарника в уже развёрнутом окружении — server-deploy.sh;
#     здесь `update` дополнительно приводит unit и хелперы к текущему виду.
#   * Версию ядра/строку «2.5.1» инструмент не присваивает — фиксирует SHA-256
#     конкретного входного бинарника.
#
# Лицензия серверного бинарника — PolyForm Noncommercial 1.0.0; инструмент её
# не заменяет и Required Notice не удаляет.

set -Eeuo pipefail

readonly TOOL_NAME="csqtt-server-install"
readonly TOOL_VERSION="1.2"

# Коды возврата (стабильный контракт для автоматизации).
readonly EX_OK=0
readonly EX_USAGE=2
readonly EX_PREFLIGHT=20
readonly EX_ACTIVATION=30        # установка/health-check не удались; откат выполнен
readonly EX_ROLLBACK_FAILED=31   # откат не удался
readonly EX_LOCKED=40
readonly EX_INTERNAL=50

# Подтверждённые значения по умолчанию — из официального deploy.sh.
SERVICE="${CSQTT_INSTALL_SERVICE:-csqtt}"
TARGET_BIN="${CSQTT_INSTALL_BIN:-/usr/local/bin/csqtt}"
LIB_DIR="${CSQTT_INSTALL_LIB:-/usr/local/lib/csqtt}"
CONFIG_DIR="${CSQTT_INSTALL_CONFIG_DIR:-/etc/csqtt}"
UNIT_PATH="${CSQTT_INSTALL_UNIT:-/etc/systemd/system/csqtt.service}"
IFACE="${CSQTT_INSTALL_IFACE:-csqtt1}"
PEER_PORT="${CSQTT_INSTALL_PEER_PORT:-46000}"
WEB_PORT="${CSQTT_INSTALL_WEB_PORT:-46002}"
PEER_PORT_EXPLICIT=0
WEB_PORT_EXPLICIT=0
[ -z "${CSQTT_INSTALL_PEER_PORT+x}" ] || PEER_PORT_EXPLICIT=1
[ -z "${CSQTT_INSTALL_WEB_PORT+x}" ] || WEB_PORT_EXPLICIT=1
CURRENT_PEER_PORT=""
CURRENT_WEB_PORT=""
INTERACTIVE_PORTS=0
LE_HTTP_PORT="${CSQTT_INSTALL_LE_PORT:-80}"
SYSCTL_DIR="${CSQTT_INSTALL_SYSCTL_DIR:-/etc/sysctl.d}"
RUNTIME_DIR="${CSQTT_INSTALL_RUNTIME_DIR:-/run/csqtt}"
BACKUP_ROOT="${CSQTT_INSTALL_BACKUP_ROOT:-/var/lib/csqtt-deploy}"
STATE_DIR="${CSQTT_INSTALL_STATE_DIR:-}"
SYSCTL_BIN="${CSQTT_INSTALL_SYSCTL:-sysctl}"
SYSTEMCTL_BIN="${CSQTT_INSTALL_SYSTEMCTL:-systemctl}"
IP_BIN="${CSQTT_INSTALL_IP:-ip}"
IPTABLES_BIN="${CSQTT_INSTALL_IPTABLES:-iptables}"
SS_BIN="${CSQTT_INSTALL_SS:-ss}"

readonly SUBNET="10.66.67.0/24"
readonly SUBNET6="fd66:67::/64"
readonly XT_WAIT="5"
readonly IPT_COMMENT="csqtt-server"

ENV_FILE=""
CANDIDATE=""
EXPECTED_SHA=""
SHA_FILE=""
HEALTH_CMD=""
BACKUP_DIR=""
ACTION=""

STABILITY_SECONDS="${CSQTT_INSTALL_STABILITY_SECONDS:-4}"
HEALTH_TIMEOUT="${CSQTT_INSTALL_HEALTH_TIMEOUT:-30}"

YES=0
FORCE=0
DRY_RUN=0
BACKUP_CONFIG=1
RESTORE_CONFIG=0

LOG_FILE=""
LOCK_FILE=""

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

usage() {
	cat >&2 <<EOF
$TOOL_NAME $TOOL_VERSION — установка сервера CSQTT с нуля, обновление и откат
(Linux + systemd).

Использование:
  $TOOL_NAME <действие> [параметры]

Действия:
  preflight   Проверка окружения и входного бинарника без изменений (dry-run).
  install     Развёртывание сервера с нуля: unit, хелперы, каталог, sysctl, запуск.
  update      Обновление бинарника и приведение unit/хелперов к текущему виду.
  status      Понятный статус без изменений (только чтение).
  credentials Показать сохранённые адрес/логин/пароль панели (только root).
  verify      Проверка службы, здоровья и (необязательно) хеша установленного файла.
  rollback    Точный ручной откат к резервной копии (по умолчанию — последней).
  uninstall   Остановка и удаление unit/хелперов/бинарника (конфигурация сохраняется).

Основные параметры:
  --binary PATH         Входной серверный бинарник (ELF).
  --sha256 HEX          Ожидаемая SHA-256 входного бинарника (обязательна, если нет
                        --sha256-file).
  --sha256-file PATH    Файл с ожидаемой SHA-256 (берётся первый хеш).
  --service NAME        Имя службы systemd (по умолчанию: $SERVICE).
  --target PATH         Путь бинарника (по умолчанию: $TARGET_BIN).
  --lib-dir PATH        Каталог хелперов (по умолчанию: $LIB_DIR).
  --config-dir PATH     Каталог конфигурации (по умолчанию: $CONFIG_DIR).
  --unit PATH           Файл unit (по умолчанию: $UNIT_PATH).
  --iface NAME          Интерфейс (по умолчанию: $IFACE).
  --peer-port N         UDP-порт peer (по умолчанию: $PEER_PORT).
  --web-port N          TCP-порт панели (0 — не проверять; по умолчанию: $WEB_PORT).
  --interactive-ports  Спросить порты через терминал (также для preflight).
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

После успешной установки доступ панели показывается в терминале и сохраняется
в $ENV_FILE (0600). В журнал/аргументы пароль не попадает. При обновлении
существующие данные сохраняются. Резервные копии: каталоги 0700, файлы 0600.
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

valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
reserved_port() { case "$1" in 80 | 46001 | 46003 | 46004) return 0 ;; *) return 1 ;; esac; }

# Только наш явный ExecStart, без исполнения unit/конфигурации.
load_installed_ports() {
	local ports
	[ -f "$UNIT_PATH" ] || return 0
	ports=$(python3 - "$UNIT_PATH" "$TARGET_BIN" <<'PYPORT'
import re, sys
from pathlib import Path
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith('ExecStart=' + sys.argv[2] + ' '):
        peer = re.search(r'(?:^|\s)--listen\s+0\.0\.0\.0:([0-9]{1,5})(?:\s|$)', line)
        web = re.search(r'(?:^|\s)--web-port\s+([0-9]{1,5})(?:\s|$)', line)
        if peer and web:
            print(peer[1], web[1])
        break
PYPORT
	) || return 0
	[ -n "$ports" ] || return 0
	read -r CURRENT_PEER_PORT CURRENT_WEB_PORT <<<"$ports"
	[ "$PEER_PORT_EXPLICIT" -eq 1 ] || PEER_PORT="$CURRENT_PEER_PORT"
	[ "$WEB_PORT_EXPLICIT" -eq 1 ] || WEB_PORT="$CURRENT_WEB_PORT"
}

# 0: чужой/неизвестный сокет; 1: свободно или только MainPID этой службы;
# 2: проверить не удалось. ss читает обе семьи адресов, без остановки процессов.
port_conflict() {
	local proto="$1" port="$2" sockets pid pids one option socket_pid
	[ "$proto" != tcp ] || option=-ltnp
	[ "$proto" != udp ] || option=-uanp
	have "$SS_BIN" || return 2
	sockets=$("$SS_BIN" "$option" "sport = :$port" 2>/dev/null) || return 2
	[ -n "$sockets" ] || return 1
	pid=$(sd_show MainPID)
	[[ $pid =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && sd_is_active || return 0
	while IFS= read -r one; do
		pids=$(grep -oE 'pid=[0-9]+' <<<"$one" | cut -d= -f2 || true)
		[ -n "$pids" ] || return 0
		while IFS= read -r socket_pid; do
			[ "$socket_pid" = "$pid" ] || return 0
		done <<<"$pids"
	done <<<"$sockets"
	return 1
}

suggest_port() {
	local proto="$1" candidate="$2" other="$3" n rc
	for ((n=0; n<64; n++)); do
		candidate=$((candidate + 1))
		[ "$candidate" -le 65535 ] || candidate=1024
		if [ "$candidate" = "$other" ] || reserved_port "$candidate"; then continue; fi
		if port_conflict "$proto" "$candidate"; then rc=0; else rc=$?; fi
		if [ "$rc" -eq 1 ]; then printf '%s\n' "$candidate"; return 0; fi
		[ "$rc" -ne 2 ] || return 1
	done
	return 1
}

check_port_selection() {
	local fail=0 proto port rc suggestion
	if ! valid_port "$PEER_PORT"; then
		err "порт туннеля должен быть числом 1–65535"; return 1
	fi
	# Значение WEB=0 оставлено для прежнего CLI: отключить web health-check.
	if [ "$WEB_PORT" != 0 ] && ! valid_port "$WEB_PORT"; then
		err "порт панели должен быть числом 1–65535"; return 1
	fi
	PEER_PORT=$((10#$PEER_PORT))
	[ "$WEB_PORT" = 0 ] || WEB_PORT=$((10#$WEB_PORT))
	if [ "$PEER_PORT" = "$WEB_PORT" ] || reserved_port "$PEER_PORT" || reserved_port "$WEB_PORT"; then
		err "выберите разные порты, кроме служебных 80/46001/46003/46004"; return 1
	fi
	for proto in udp tcp; do
		if [ "$proto" = udp ]; then port="$PEER_PORT"; else port="$WEB_PORT"; fi
		[ "$port" != 0 ] || continue
		if port_conflict "$proto" "$port"; then rc=0; else rc=$?; fi
		case "$rc" in
		0)
			err "$proto/$port занят посторонним процессом или владелец не определён; чужие службы не останавливаются"
			suggestion=$(suggest_port "$proto" "$port" "$([ "$proto" = udp ] && echo "$WEB_PORT" || echo "$PEER_PORT")" || true)
			[ -z "$suggestion" ] || warn "свободный вариант: $proto/$suggestion (требуется ваш выбор)"
			fail=1 ;;
		1) : ;;
		*) err "не удалось проверить $proto/$port через ss; установка остановлена"; fail=1 ;;
		esac
	done
	return "$fail"
}

choose_ports_interactive() {
	local proto label chosen default explicit other raw rc suggestion
	(: </dev/tty) 2>/dev/null || die "для выбора портов нужен терминал; задайте --peer-port/--web-port" "$EX_USAGE"
	for proto in udp tcp; do
		if [ "$proto" = udp ]; then
			label='Порт туннеля (UDP)'; default="$PEER_PORT"; explicit="$PEER_PORT_EXPLICIT"; other="$WEB_PORT"
		else
			label='Порт панели (TCP)'; default="$WEB_PORT"; explicit="$WEB_PORT_EXPLICIT"; other="$PEER_PORT"
		fi
		[ "$explicit" -eq 0 ] || continue
		while :; do
			printf '%s [%s]: ' "$label" "$default" >/dev/tty
			IFS= read -r raw </dev/tty || die "выбор портов отменён" "$EX_USAGE"
			chosen="${raw:-$default}"
			if ! valid_port "$chosen"; then printf 'Введите число 1–65535.\n' >/dev/tty; continue; fi
			chosen=$((10#$chosen))
			if [ "$chosen" = "$other" ] || reserved_port "$chosen"; then
				printf 'Этот номер выбран для другой роли или зарезервирован CSQTT.\n' >/dev/tty; continue
			fi
			if port_conflict "$proto" "$chosen"; then rc=0; else rc=$?; fi
			if [ "$rc" -eq 2 ]; then die "не удалось проверить свободные порты через ss" "$EX_PREFLIGHT"; fi
			if [ "$rc" -eq 0 ]; then
				printf '%s/%s занят. ' "$proto" "$chosen" >/dev/tty
				suggestion=$(suggest_port "$proto" "$chosen" "$other" || true)
				if [ -n "$suggestion" ]; then default="$suggestion"; printf 'Свободный вариант: %s; Enter подтверждает его.\n' "$default" >/dev/tty
				else printf 'Укажите другой номер.\n' >/dev/tty; fi
				continue
			fi
			if [ "$proto" = udp ]; then PEER_PORT="$chosen"; else WEB_PORT="$chosen"; fi
			break
		done
	done
	printf 'Выбраны порты: туннель UDP/%s, панель TCP/%s.\n' "$PEER_PORT" "$WEB_PORT" >&2
}

# --- предварительная проверка --------------------------------------------

preflight_check() {
	local fail=0 hm cm magic sha actual

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

	if ! have "$IPTABLES_BIN"; then
		err "не найден $IPTABLES_BIN — установите iptables до запуска установки"
		fail=1
	fi
	for cmd in python3 tar od sysctl; do
		if ! have "$cmd"; then err "не найдена обязательная команда $cmd"; fail=1; fi
	done

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

	check_port_selection || fail=1
	if [ -L "$ENV_FILE" ] || { [ -e "$ENV_FILE" ] && [ ! -f "$ENV_FILE" ]; }; then
		err "файл доступа должен быть обычным файлом, не ссылкой: $ENV_FILE"
		fail=1
	fi
	# Не подменять неявно пароль, заданный в нестандартном unit.
	if [ -f "$UNIT_PATH" ] && grep -Eq -- 'CSQTT_WEB_(USER|PASS)=|--web-(user|pass)(=|[[:space:]])' "$UNIT_PATH"; then
		err "в unit уже заданы данные панели; перенесите их в $ENV_FILE перед update"
		fail=1
	fi

	return "$fail"
}

# Отдельный процесс: не source/eval и не секретные параметры Python/команд.
# ensure печатает только changed/unchanged; show предназначен владельцу терминала.
admin_credentials() {
	local mode="$1" addresses=""
	if [ "$mode" = show ]; then
		addresses=$("$IP_BIN" -o addr show scope global 2>/dev/null || true)
	fi
	python3 - "$mode" "$ENV_FILE" "$WEB_PORT" "$addresses" "$PEER_PORT" <<'PYADMIN'
import ipaddress
import os
import re
import secrets
import stat
import sys
import tempfile
from urllib.parse import quote

mode, filename, port, addresses, peer_port = sys.argv[1:]
keys = {"CSQTT_WEB_USER", "CSQTT_WEB_PASS", "CSQTT_WEB_SECRET_PATH", "CSQTT_PUBLIC_IP"}

def value(raw):
    raw = raw.strip()
    if not raw:
        return ""
    if raw.startswith("'"):
        if not raw.endswith("'") or "'" in raw[1:-1]:
            raise ValueError()
        result = raw[1:-1]
    elif raw.startswith('"'):
        if not raw.endswith('"'):
            raise ValueError()
        result = re.sub(r'\\([\\"`$])', r'\1', raw[1:-1])
        if '"' in re.sub(r'\\.', '', raw[1:-1]):
            raise ValueError()
    else:
        if any(c in raw for c in "\\\"'"):
            raise ValueError()
        result = raw
    if any(ord(c) < 32 or ord(c) == 127 for c in result):
        raise ValueError()
    return result

try:
    os.umask(0o077)
    exists = os.path.lexists(filename)
    old = ""
    metadata = None
    if exists:
        metadata = os.lstat(filename)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid():
            raise ValueError()
        fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, encoding="utf-8") as source:
            old = source.read()
    values = {}
    for line in old.splitlines():
        match = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$', line)
        if match and match[1] in keys:
            values[match[1]] = value(match[2])
    ready = bool(values.get("CSQTT_WEB_USER") and values.get("CSQTT_WEB_PASS"))
    private = metadata is not None and not metadata.st_mode & 0o077
    if mode == "check":
        sys.exit(0 if ready and private else 1)
    if mode == "ensure":
        additions = []
        if not values.get("CSQTT_WEB_USER"):
            # A previously configured password used the server's default login.
            username = "admin" if values.get("CSQTT_WEB_PASS") else "csqtt_" + secrets.token_hex(4)
            additions.append("CSQTT_WEB_USER=" + username)
        if not values.get("CSQTT_WEB_PASS"):
            additions.append("CSQTT_WEB_PASS=" + secrets.token_urlsafe(24))
        if additions:
            parent = os.path.dirname(filename)
            os.makedirs(parent, mode=0o700, exist_ok=True)
            fd, temporary = tempfile.mkstemp(prefix=".csqtt-access-", dir=parent)
            try:
                with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as output:
                    output.write(old)
                    if old and not old.endswith("\n"):
                        output.write("\n")
                    output.write("\n".join(additions) + "\n")
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(temporary, filename)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        else:
            os.chmod(filename, 0o600)
        print("changed" if additions or not private else "unchanged")
    elif mode == "show":
        if not ready or not private:
            print("Постоянные данные входа ещё не настроены; повторите install/update новым установщиком.", file=sys.stderr)
            sys.exit(1)
        host = values.get("CSQTT_PUBLIC_IP", "")
        if host:
            try:
                parsed = ipaddress.ip_address(host)
                host = "[" + host + "]" if parsed.version == 6 else host
            except ValueError:
                if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?', host):
                    host = ""
        if not host:
            for candidate in re.findall(r'\binet6?\s+([^/\s]+)/', addresses):
                parsed = ipaddress.ip_address(candidate)
                if parsed.is_global:
                    host = "[" + candidate + "]" if parsed.version == 6 else candidate
                    break
        host = host or "<IP_СЕРВЕРА>"
        prefix = values.get("CSQTT_WEB_SECRET_PATH", "").strip("/")
        suffix = quote(prefix, safe="/") + "/" if prefix else ""
        print("\nДоступ к веб-панели CSQTT")
        print("Адрес панели: https://" + host + ":" + port + "/" + suffix)
        print("Порт туннеля (UDP): " + peer_port)
        print("Логин: " + values["CSQTT_WEB_USER"])
        print("Пароль: " + values["CSQTT_WEB_PASS"])
        print("Сохраните эти данные. Пароль не меняется при перезапуске/обновлении.")
        print("Файл доступа (только root): " + filename)
        print("Если указан <IP_СЕРВЕРА>, замените его адресом VPS. Возможен самоподписанный HTTPS-сертификат.")
    else:
        raise ValueError()
except (OSError, UnicodeError, ValueError):
    print("Не удалось безопасно обработать файл доступа панели; проверьте права и формат CSQTT_WEB_USER/CSQTT_WEB_PASS. Содержимое не выводится.", file=sys.stderr)
    sys.exit(1)
PYADMIN
}

show_admin_credentials() {
	# Никогда не вызывать через log(): пароль не должен попасть в install.log.
	admin_credentials show || warn "Данные входа не показаны; проверьте защищённый файл $ENV_FILE"
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
	exec 9>"$LOCK_FILE"
	if ! flock -n 9 2>/dev/null; then
		die "другой запуск $TOOL_NAME уже выполняется ($LOCK_FILE)" "$EX_LOCKED"
	fi
}

confirm() {
	local prompt="$1" ans
	if [ "$YES" -eq 1 ]; then
		return 0
	fi
	if [ ! -t 0 ]; then
		if (: </dev/tty) 2>/dev/null; then
			printf '%s [y/N]: ' "$prompt" >/dev/tty
			read -r ans </dev/tty || ans=""
		else
			die "нет терминала для подтверждения; используйте --yes" "$EX_USAGE"
		fi
	else
		printf '%s [y/N]: ' "$prompt" >&2
		read -r ans || ans=""
	fi
	case "$ans" in
	y | Y | yes | YES) return 0 ;;
	*) die "отменено пользователем" "$EX_USAGE" ;;
	esac
}

# --- хелперы службы -------------------------------------------------------

network_helper_content() {
	cat <<NETEOF
#!/bin/sh
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

command -v ip >/dev/null 2>&1 || exit 20
command -v iptables >/dev/null 2>&1 || exit 21
[ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
[ -w /proc/sys/net/ipv6/conf/all/forwarding ] && echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true
[ -w /proc/sys/net/ipv4/conf/all/rp_filter ] && echo 2 > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || true
[ -w /proc/sys/net/ipv4/conf/default/rp_filter ] && echo 2 > /proc/sys/net/ipv4/conf/default/rp_filter 2>/dev/null || true
[ -w /proc/sys/net/ipv4/tcp_notsent_lowat ] && echo 131072 > /proc/sys/net/ipv4/tcp_notsent_lowat 2>/dev/null || true

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

ipt() { iptables -w "\$XT_WAIT" "\$@"; }
ipt -C INPUT -p udp --dport "\$PEER_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -p udp --dport "\$PEER_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
ipt -C INPUT -p tcp --dport "\$WEB_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -p tcp --dport "\$WEB_PORT" -m comment --comment "\$IPT_COMMENT" -j ACCEPT
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
        \$CSQTT_BIN|"\$CSQTT_BIN (deleted)"|/usr/local/lib/csqtt/*|'/usr/local/lib/csqtt/'*' (deleted)') return 0 ;;
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
	cat <<UNITEOF
[Unit]
Description=CSQTT VPN Server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
EnvironmentFile=-$ENV_FILE
Environment=CSQTT_SERVICE_MANAGER=systemd
ExecStartPre=$LIB_DIR/network-up.sh
ExecStartPre=$LIB_DIR/tun-recover.sh
ExecStart=$TARGET_BIN --listen 0.0.0.0:$PEER_PORT --web-port $WEB_PORT --config-dir $CONFIG_DIR
Restart=on-failure
RestartSec=3
KillMode=control-group
TimeoutStartSec=30
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
}

write_file_atomic() { # путь, права, содержимое(stdin)
	local path="$1" mode="$2" tmp
	tmp="$(dirname "$path")/.csqtt-install.$$.tmp"
	cat >"$tmp"
	chmod "$mode" "$tmp"
	mv -f -- "$tmp" "$path"
}

install_service_files() {
	step "Укладка бинарника, хелперов и unit"
	mkdir -p "$(dirname "$TARGET_BIN")" "$LIB_DIR" "$CONFIG_DIR" "$SYSCTL_DIR" "$(dirname "$UNIT_PATH")" "$RUNTIME_DIR"
	chmod 0755 "$(dirname "$TARGET_BIN")" "$LIB_DIR" 2>/dev/null || true
	chmod 0700 "$CONFIG_DIR" 2>/dev/null || true

	# Бинарник: атомарная замена.
	write_file_atomic "$TARGET_BIN" 0755 <"$CANDIDATE"

	network_helper_content | write_file_atomic "$LIB_DIR/network-up.sh" 0755
	tun_recovery_helper_content | write_file_atomic "$LIB_DIR/tun-recover.sh" 0755

	sysctl_content_forwarding | write_file_atomic "$SYSCTL_DIR/99-csqtt.conf" 0644
	sysctl_content_udp_buffers | write_file_atomic "$SYSCTL_DIR/99-csqtt-udp-buffers.conf" 0644

	unit_content | write_file_atomic "$UNIT_PATH" 0644

	# Применяем sysctl на живой системе (мягко).
	if have "$SYSCTL_BIN"; then
		"$SYSCTL_BIN" -p "$SYSCTL_DIR/99-csqtt.conf" >/dev/null 2>&1 || warn "не удалось применить sysctl CSQTT forwarding"
		"$SYSCTL_BIN" -p "$SYSCTL_DIR/99-csqtt-udp-buffers.conf" >/dev/null 2>&1 || warn "не удалось применить sysctl CSQTT UDP"
	fi

	"$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || die "systemctl daemon-reload завершился ошибкой" "$EX_INTERNAL"
	"$SYSTEMCTL_BIN" enable "$SERVICE" >/dev/null 2>&1 || warn "systemctl enable $SERVICE не удался"
}

remove_service_files() {
	step "Удаление unit, хелперов и бинарника"
	"$SYSTEMCTL_BIN" stop "$SERVICE" >/dev/null 2>&1 || true
	"$SYSTEMCTL_BIN" disable "$SERVICE" >/dev/null 2>&1 || true
	rm -f -- "$UNIT_PATH" "$TARGET_BIN" \
		"$LIB_DIR/network-up.sh" "$LIB_DIR/tun-recover.sh" \
		"$SYSCTL_DIR/99-csqtt.conf" "$SYSCTL_DIR/99-csqtt-udp-buffers.conf"
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
	printf '%s\n' "${CURRENT_WEB_PORT:-$WEB_PORT}" >"$dir/web_port"
	printf '%s\n' "$CONFIG_DIR" >"$dir/config_dir"
	printf '%s\n' "$TARGET_BIN" >"$dir/target_bin"
	printf '%s\n' "$UNIT_PATH" >"$dir/unit_path"
	printf '%s\n' "$LIB_DIR" >"$dir/lib_dir"
	printf '%s\n' "${CURRENT_PEER_PORT:-$PEER_PORT}" >"$dir/peer_port"
	chmod 0600 "$dir"/timestamp "$dir"/action "$dir"/service \
		"$dir"/iface "$dir"/web_port "$dir"/config_dir "$dir"/target_bin \
		"$dir"/unit_path "$dir"/lib_dir "$dir"/peer_port 2>/dev/null || true

	# Наличие управляемых файлов до изменения (для точного отката с нуля).
	_manifest_present "$TARGET_BIN" >"$dir/binary_present"
	_manifest_present "$UNIT_PATH" >"$dir/unit_present"
	_manifest_present "$LIB_DIR/network-up.sh" >"$dir/network_helper_present"
	_manifest_present "$LIB_DIR/tun-recover.sh" >"$dir/tun_helper_present"
	chmod 0600 "$dir"/binary_present "$dir"/unit_present \
		"$dir"/network_helper_present "$dir"/tun_helper_present 2>/dev/null || true
	# Доступы откатываются всегда, даже с --no-backup-config.
	_manifest_present "$ENV_FILE" >"$dir/admin_env_present"
	chmod 0600 "$dir/admin_env_present"
	if [ -f "$ENV_FILE" ]; then
		cp -- "$ENV_FILE" "$dir/previous-admin.env"
		chmod 0600 "$dir/previous-admin.env"
	fi

	if [ -f "$TARGET_BIN" ]; then
		cp -p -- "$TARGET_BIN" "$dir/previous-binary"
		chmod 0700 "$dir/previous-binary" 2>/dev/null || true
		sha256_of "$TARGET_BIN" >"$dir/previous-sha256" 2>/dev/null || echo unknown >"$dir/previous-sha256"
	fi
	for f in "$UNIT_PATH:$dir/previous-unit" "$LIB_DIR/network-up.sh:$dir/previous-network-up.sh" "$LIB_DIR/tun-recover.sh:$dir/previous-tun-recover.sh"; do
		src="${f%%:*}"
		dst="${f#*:}"
		[ -f "$src" ] && cp -p -- "$src" "$dst" || true
	done
	chmod 0600 "$dir"/previous-sha256 "$dir"/previous-unit \
		"$dir"/previous-network-up.sh "$dir"/previous-tun-recover.sh 2>/dev/null || true

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

# Восстановление состояния из резервной копии. Успех — код возврата 0.
rollback_to_backup() {
	local bdir="$1" restore_config="$2" had
	if [ -f "$bdir/admin_env_present" ]; then
		if [ "$(cat "$bdir/admin_env_present")" = yes ]; then
			install -m 0600 -- "$bdir/previous-admin.env" "$ENV_FILE" || return 1
		else
			rm -f -- "$ENV_FILE" || return 1
		fi
	fi
	# Health-check отката должен использовать прежние, а не новые порты.
	[ ! -f "$bdir/peer_port" ] || PEER_PORT=$(cat "$bdir/peer_port")
	[ ! -f "$bdir/web_port" ] || WEB_PORT=$(cat "$bdir/web_port")

	had=$(cat "$bdir/binary_present" 2>/dev/null || echo no)

	# Прежнего бинарника не было (установка «с нуля»): возвращаем состояние
	# «нет службы» — останавливаем её и убираем созданные unit/хелперы, не выдавая
	# это за успешный запуск.
	if [ "$had" != "yes" ]; then
		rm -f -- "$TARGET_BIN" "$UNIT_PATH" \
			"$LIB_DIR/network-up.sh" "$LIB_DIR/tun-recover.sh"
		"$SYSTEMCTL_BIN" stop "$SERVICE" >/dev/null 2>&1 || true
		"$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
		return 0
	fi

	install -m 0755 -- "$bdir/previous-binary" "$TARGET_BIN"

	# Unit и хелперы возвращаем к прежнему состоянию (или удаляем, если их не было).
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

	if [ "$restore_config" = "yes" ] && [ -f "$bdir/config.tar.gz" ]; then
		tar -C "$(dirname "$CONFIG_DIR")" -xzf "$bdir/config.tar.gz" || return 1
	fi

	"$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
	"$SYSTEMCTL_BIN" restart "$SERVICE" >/dev/null 2>&1 || return 1
	wait_health
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
		tcp_open 127.0.0.1 "$WEB_PORT" || return 1
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

cmd_preflight() {
	step "Предварительная проверка (без изменений)"
	step "Действие: $ACTION; хост: $(uname -s)/$(uname -m); служба: $SERVICE"
	if preflight_check; then
		ok "Проверка пройдена: окружение и входной бинарник совместимы"
		ok "План: установить $TARGET_BIN, unit $UNIT_PATH, хелперы в $LIB_DIR"
		ok "Интерфейс $IFACE, UDP/$PEER_PORT, TCP/$WEB_PORT; конфигурация $CONFIG_DIR"
		emit "CSQTT_SERVER_INSTALL_PREFLIGHT_OK|$SERVICE"
		return 0
	fi
	err "Предварительная проверка не пройдена; изменения не вносились"
	emit "CSQTT_SERVER_INSTALL_PREFLIGHT_FAILED|$SERVICE"
	return "$EX_PREFLIGHT"
}

auto_rollback() {
	local bdir="$1"
	warn "health-check не пройден — автоматический откат к предыдущему состоянию"
	if rollback_to_backup "$bdir" no; then
		ok "Предыдущее состояние восстановлено: $bdir"
		emit "CSQTT_SERVER_INSTALL_ROLLED_BACK|$bdir"
		exit "$EX_ACTIVATION"
	fi
	err "Автоматический откат не удался. Точная команда ручного отката:"
	err "  $TOOL_NAME rollback --backup $bdir"
	emit "CSQTT_SERVER_INSTALL_ROLLBACK_FAILED|$bdir"
	exit "$EX_ROLLBACK_FAILED"
}

cmd_install() {
	local mode="$1" cand_sha bdir
	step "Предварительная проверка"
	preflight_check || die "предварительная проверка не пройдена; изменения не вносились" "$EX_PREFLIGHT"

	if [ "$mode" = "update" ] && [ ! -e "$TARGET_BIN" ]; then
		die "update: $TARGET_BIN не найден; для первой установки используйте install" "$EX_PREFLIGHT"
	fi

	cand_sha=$(sha256_of "$CANDIDATE")
	if [ -f "$TARGET_BIN" ] && [ "$(sha256_of "$TARGET_BIN")" = "$cand_sha" ] && \
		[ -f "$UNIT_PATH" ] && [ "$PEER_PORT" = "$CURRENT_PEER_PORT" ] && \
		[ "$WEB_PORT" = "$CURRENT_WEB_PORT" ] && admin_credentials check && health_once; then
		if [ "$FORCE" -ne 1 ]; then
			ok "Кандидат уже установлен (SHA-256 совпадает), служба здорова — изменений не требуется"
			emit "CSQTT_SERVER_INSTALL_UP_TO_DATE|$SERVICE|$cand_sha"
			show_admin_credentials
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
	check_port_selection || die "порты изменились перед установкой; повторите выбор" "$EX_PREFLIGHT"
	bdir=$(make_backup "$mode")
	step "Резервная копия создана: $bdir"
	if ! admin_credentials ensure >/dev/null; then
		err "Не удалось подготовить постоянный доступ панели"
		auto_rollback "$bdir"
	fi

	install_service_files

	step "Запуск службы $SERVICE"
	if ! "$SYSTEMCTL_BIN" restart "$SERVICE" >/dev/null 2>&1; then
		err "systemctl restart $SERVICE завершился ошибкой"
		auto_rollback "$bdir"
	fi

	step "Проверка запуска и здоровья"
	if wait_health; then
		record_current "$bdir" "$cand_sha"
		ok "Установка завершена: служба активна, проверки пройдены"
		ok "Откат при необходимости: $TOOL_NAME rollback --backup $bdir"
		emit "CSQTT_SERVER_INSTALL_OK|$SERVICE|$cand_sha"
		show_admin_credentials
		return 0
	fi
	auto_rollback "$bdir"
}

cmd_status() {
	local installed_sha="-" bdir="-" n=0 latest="-" active sub pid
	echo "Статус серверного развёртывания CSQTT ($TOOL_NAME)" >&2
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
		if tcp_open 127.0.0.1 "$WEB_PORT"; then
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
	local bdir="$1" safety now
	[ -n "$bdir" ] || die "не указан каталог резервной копии (--backup DIR)" "$EX_USAGE"
	[ -d "$bdir" ] || die "каталог резервной копии не найден: $bdir" "$EX_USAGE"

	if [ "$DRY_RUN" -eq 1 ]; then
		ok "dry-run: откат не выполнялся; будет использована копия $bdir"
		emit "CSQTT_SERVER_INSTALL_DRY_RUN|rollback"
		return 0
	fi

	confirm "Восстановить состояние из $bdir и перезапустить $SERVICE?"

	take_lock
	safety=$(make_backup "pre-rollback")
	step "Текущее состояние сохранено: $safety"
	if rollback_to_backup "$bdir" "$RESTORE_CONFIG"; then
		now=$(sha256_of "$TARGET_BIN" 2>/dev/null || echo removed)
		record_current "$safety" "$now"
		ok "Откат выполнен"
		emit "CSQTT_SERVER_INSTALL_ROLLED_BACK|$bdir"
		return 0
	fi
	die "откат не удался; текущее состояние сохранено в $safety" "$EX_ROLLBACK_FAILED"
}

cmd_uninstall() {
	local keep="$CONFIG_DIR"
	if [ "$DRY_RUN" -eq 1 ]; then
		ok "dry-run: будут удалены $UNIT_PATH, хелперы $LIB_DIR, бинарник $TARGET_BIN"
		ok "Конфигурация сохраняется: $keep"
		emit "CSQTT_SERVER_INSTALL_DRY_RUN|uninstall"
		return 0
	fi
	confirm "Остановить службу $SERVICE и удалить unit/хелперы/бинарник (конфигурация сохранится)?"
	take_lock
	remove_service_files
	ok "Служба $SERVICE остановлена, unit/хелперы/бинарник удалены"
	ok "Конфигурация сохранена: $keep"
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
		--target) TARGET_BIN="${2:-}"; shift 2 ;;
		--lib-dir) LIB_DIR="${2:-}"; shift 2 ;;
		--config-dir) CONFIG_DIR="${2:-}"; shift 2 ;;
		--unit) UNIT_PATH="${2:-}"; shift 2 ;;
		--iface) IFACE="${2:-}"; shift 2 ;;
		--peer-port) PEER_PORT="${2:-}"; PEER_PORT_EXPLICIT=1; shift 2 ;;
		--web-port) WEB_PORT="${2:-}"; WEB_PORT_EXPLICIT=1; shift 2 ;;
		--interactive-ports) INTERACTIVE_PORTS=1; shift ;;
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
	parse_args "$@"
	[ -n "$STATE_DIR" ] || STATE_DIR="$BACKUP_ROOT/state"
	[ -n "$ENV_FILE" ] || ENV_FILE="$CONFIG_DIR/csqtt.env"
	load_installed_ports
	case "$ACTION" in
	install | update)
		if [ "$YES" -eq 0 ] && (: </dev/tty) 2>/dev/null; then INTERACTIVE_PORTS=1; fi
		;;
	esac
	if [ "$INTERACTIVE_PORTS" -eq 1 ]; then choose_ports_interactive; fi

	case "${ACTION:-help}" in
	help) usage; exit "$EX_OK" ;;
	preflight) cmd_preflight ;;
	install) cmd_install install ;;
	update) cmd_install update ;;
	status) cmd_status ;;
	credentials)
		[ "$(id -u)" -eq 0 ] || die "данные входа доступны только root (sudo)" "$EX_USAGE"
		admin_credentials show
		;;
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
