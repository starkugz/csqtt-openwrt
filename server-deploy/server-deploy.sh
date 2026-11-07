#!/usr/bin/env bash
# CSQTT server deploy — безопасные установка/обновление/проверка/откат серверного
# бинарника CSQTT на подтверждённой платформе (Linux x86-64/arm64, systemd).
#
# Назначение: атомарно заменить серверный бинарник в уже развёрнутом окружении
# CSQTT (служба systemd + конфигурация из официального deploy.sh), сделав
# резервную копию прежнего бинарника и конфигурации, проверить запуск и
# работоспособность, а при провале — автоматически вернуть прежнее состояние.
# Ручной откат — отдельная точная команда `rollback`.
#
# Границы:
#   * Инструмент НЕ разворачивает окружение CSQTT с нуля (NAT/firewall/sysctl/
#     сертификаты/юнит/конфигурацию создаёт официальный deploy.sh). Он работает с
#     уже существующей службой systemd и заменяет только бинарник.
#   * Инструмент не читает и не печатает секреты конфигурации (только копирует
#     каталог конфигурации с сохранением прав).
#   * Никакого фиктивного контроля версии/здоровья: проверяются реальные признаки
#     (состояние systemd, живой PID, интерфейс, TCP-порт панели, необязательная
#     внешняя команда здоровья).
#
# Лицензия серверного бинарника — PolyForm Noncommercial 1.0.0 (см. NOTICE
# серверной поставки). Этот скрипт её не заменяет и
# Required Notice не удаляет.

set -Eeuo pipefail

readonly TOOL_NAME="csqtt-server-deploy"
readonly TOOL_VERSION="1.0"

# Коды возврата (стабильный контракт для автоматизации).
readonly EX_OK=0
readonly EX_USAGE=2
readonly EX_PREFLIGHT=20
readonly EX_ACTIVATION=30        # установка/health-check не удались; откат выполнен
readonly EX_ROLLBACK_FAILED=31   # откат не удался
readonly EX_LOCKED=40
readonly EX_INTERNAL=50

# Подтверждённые значения по умолчанию — из официального deploy.sh.
SERVICE="${CSQTT_SERVER_SERVICE:-csqtt}"
TARGET_BIN="${CSQTT_SERVER_BIN:-/usr/local/bin/csqtt}"
CONFIG_DIR="${CSQTT_SERVER_CONFIG_DIR:-/etc/csqtt}"
UNIT_PATH="${CSQTT_SERVER_UNIT:-}"
IFACE="${CSQTT_SERVER_IFACE:-csqtt1}"
WEB_PORT="${CSQTT_SERVER_WEB_PORT:-46002}"
BACKUP_ROOT="${CSQTT_SERVER_BACKUP_ROOT:-/var/lib/csqtt-deploy}"
STATE_DIR="${CSQTT_SERVER_STATE_DIR:-}"
SYSTEMCTL_BIN="${CSQTT_SERVER_SYSTEMCTL:-systemctl}"
IP_BIN="${CSQTT_SERVER_IP:-ip}"

CANDIDATE=""
EXPECTED_SHA=""
SHA_FILE=""
HEALTH_CMD=""
BACKUP_DIR=""
ACTION=""

STABILITY_SECONDS="${CSQTT_SERVER_STABILITY_SECONDS:-4}"
HEALTH_TIMEOUT="${CSQTT_SERVER_HEALTH_TIMEOUT:-30}"

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
# Маркеры — только в stdout, без секретов (консольные сообщения идут в stderr).
emit() { printf '%s\n' "$1"; }

usage() {
	cat >&2 <<EOF
$TOOL_NAME $TOOL_VERSION — установка, обновление, проверка и откат серверного
бинарника CSQTT (Linux + systemd).

Использование:
  $TOOL_NAME <действие> [параметры]

Действия:
  preflight   Проверка окружения и входного бинарника без изменений (dry-run).
  install     Первая укладка бинарника в существующее окружение CSQTT.
  update      Обновление уже установленного серверного бинарника.
  status      Понятный статус без изменений (только чтение).
  verify      Проверка службы, здоровья и (необязательно) хеша установленного файла.
  rollback    Точный ручной откат к резервной копии (по умолчанию — последней).

Основные параметры:
  --binary PATH         Входной серверный бинарник (ELF).
  --sha256 HEX          Ожидаемая SHA-256 входного бинарника (обязательна, если нет
                        --sha256-file).
  --sha256-file PATH    Файл с ожидаемой SHA-256 (берётся первый хеш).
  --service NAME        Имя службы systemd (по умолчанию: $SERVICE).
  --target PATH         Путь установленного бинарника (по умолчанию: $TARGET_BIN).
  --config-dir PATH     Каталог конфигурации (по умолчанию: $CONFIG_DIR).
  --unit PATH           Файл unit (иначе проверяется через systemctl cat).
  --iface NAME          Интерфейс для health-check (пустая строка — не проверять).
  --web-port N          TCP-порт панели для health-check (0 — не проверять).
  --health-cmd CMD      Дополнительная внешняя проверка здоровья (exit 0 = здоров).
  --backup-root PATH    Корень резервных копий (по умолчанию: $BACKUP_ROOT).
  --state-dir PATH      Каталог состояния/журнала (по умолчанию: <backup-root>/state).
  --backup DIR          Каталог резервной копии для rollback/verify.
  --stability-seconds N Окно стабильности после запуска (по умолчанию: $STABILITY_SECONDS).
  --health-timeout N    Бюджет ожидания health-check, с (по умолчанию: $HEALTH_TIMEOUT).
  --backup-config       Копировать каталог конфигурации в резервную копию (по умолчанию).
  --no-backup-config    Не копировать каталог конфигурации.
  --restore-config      При rollback восстановить и конфигурацию из копии.
  --dry-run, -n         Показать план без изменений.
  --yes, -y             Не спрашивать подтверждение.
  --force               Выполнить замену, даже если хеш уже совпадает.
  --help, -h            Эта справка.

Секреты (пароли, токены, ключи) не читаются, не печатаются и не передаются в
аргументах. Резервные копии создаются с правами 0700, файлы — 0600.
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
		err "не найден systemd/systemctl ($SYSTEMCTL_BIN) — подтверждённая схема требует systemd"
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

	# Ожидаемая контрольная сумма — обязательна (подпись недоступна; см. инструкцию).
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

	if [ -n "$UNIT_PATH" ]; then
		if [ ! -f "$UNIT_PATH" ]; then
			err "не найден файл unit: $UNIT_PATH"
			fail=1
		fi
	else
		if ! "$SYSTEMCTL_BIN" cat "$SERVICE" >/dev/null 2>&1; then
			err "служба '$SERVICE' не найдена (systemctl cat). Сначала выполните официальный deploy.sh install."
			fail=1
		fi
	fi

	if [ ! -d "$(dirname "$TARGET_BIN")" ]; then
		err "нет каталога для установки бинарника: $(dirname "$TARGET_BIN")"
		fail=1
	fi

	if [ ! -d "$CONFIG_DIR" ]; then
		warn "каталог конфигурации отсутствует: $CONFIG_DIR (проверьте, что окружение CSQTT развёрнуто)"
	fi

	return "$fail"
}

# --- состояние и блокировка -----------------------------------------------

ensure_state() {
	mkdir -p "$STATE_DIR"
	chmod 0700 "$STATE_DIR" 2>/dev/null || true
	if [ -z "$LOG_FILE" ]; then
		LOG_FILE="$STATE_DIR/deploy.log"
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
		die "нет терминала для подтверждения; используйте --yes" "$EX_USAGE"
	fi
	printf '%s [y/N]: ' "$prompt" >&2
	read -r ans || ans=""
	case "$ans" in
	y | Y | yes | YES) return 0 ;;
	*) die "отменено пользователем" "$EX_USAGE" ;;
	esac
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
	chmod 0600 "$dir"/timestamp "$dir"/action "$dir"/service \
		"$dir"/iface "$dir"/web_port "$dir"/config_dir "$dir"/target_bin 2>/dev/null || true

	if [ -f "$TARGET_BIN" ]; then
		cp -p -- "$TARGET_BIN" "$dir/previous-binary"
		chmod 0700 "$dir/previous-binary" 2>/dev/null || true
		printf 'yes\n' >"$dir/previous_present"
		sha256_of "$TARGET_BIN" >"$dir/previous-sha256" 2>/dev/null || echo unknown >"$dir/previous-sha256"
	else
		printf 'no\n' >"$dir/previous_present"
	fi
	chmod 0600 "$dir/previous_present" "$dir/previous-sha256" 2>/dev/null || true

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

# Атомарная замена бинарника: временный файл в том же каталоге + mv (rename).
put_binary() {
	local src="$1" tmp
	tmp="$(dirname "$TARGET_BIN")/.csqtt-deploy.$$.tmp"
	install -m 0755 -- "$src" "$tmp"
	if [ -e "$TARGET_BIN" ]; then
		chown --reference="$TARGET_BIN" "$tmp" 2>/dev/null || true
	fi
	mv -f -- "$tmp" "$TARGET_BIN"
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

# Печатает только каталоги резервных копий (с файлом timestamp), не служебный state.
backup_dirs() {
	local d
	[ -d "$BACKUP_ROOT" ] || return 0
	for d in "$BACKUP_ROOT"/*; do
		if [ -d "$d" ] && [ -f "$d/timestamp" ]; then
			printf '%s\n' "$d"
		fi
	done
}

# Восстановление состояния из резервной копии. echo об успехе через код возврата.
rollback_to_backup() {
	local bdir="$1" restore_config="$2" prev_present
	prev_present=$(cat "$bdir/previous_present" 2>/dev/null || echo no)

	if [ "$prev_present" = "yes" ] && [ -f "$bdir/previous-binary" ]; then
		put_binary "$bdir/previous-binary"
	else
		# Прежнего бинарника не было (первая установка) — возвращаем состояние «нет
		# бинарника» и останавливаем службу, не выдавая это за успешный запуск.
		rm -f -- "$TARGET_BIN"
		"$SYSTEMCTL_BIN" stop "$SERVICE" >/dev/null 2>&1 || true
		return 0
	fi

	if [ "$restore_config" = "yes" ] && [ -f "$bdir/config.tar.gz" ]; then
		tar -C "$(dirname "$CONFIG_DIR")" -xzf "$bdir/config.tar.gz" || return 1
	fi

	"$SYSTEMCTL_BIN" restart "$SERVICE" >/dev/null 2>&1 || return 1
	wait_health
}

# --- действия -------------------------------------------------------------

cmd_preflight() {
	step "Предварительная проверка (без изменений)"
	step "Действие: $ACTION; хост: $(uname -s)/$(uname -m); служба: $SERVICE"
	if preflight_check; then
		ok "Проверка пройдена: окружение и входной бинарник совместимы"
		ok "План: заменить $TARGET_BIN на $CANDIDATE, перезапустить $SERVICE, проверить здоровье"
		ok "Резервные копии: $BACKUP_ROOT; конфигурация: $([ "$BACKUP_CONFIG" -eq 1 ] && echo 'копируется' || echo 'не копируется')"
		emit "CSQTT_SERVER_PREFLIGHT_OK|$SERVICE"
		return 0
	fi
	err "Предварительная проверка не пройдена; изменения не вносились"
	emit "CSQTT_SERVER_PREFLIGHT_FAILED|$SERVICE"
	return "$EX_PREFLIGHT"
}

auto_rollback() {
	local bdir="$1"
	warn "health-check не пройден — автоматический откат к предыдущему состоянию"
	if rollback_to_backup "$bdir" no; then
		ok "Предыдущее состояние восстановлено: $bdir"
		emit "CSQTT_SERVER_ROLLED_BACK|$bdir"
		exit "$EX_ACTIVATION"
	fi
	err "Автоматический откат не удался. Точная команда ручного отката:"
	err "  $TOOL_NAME rollback --backup $bdir"
	emit "CSQTT_SERVER_ROLLBACK_FAILED|$bdir"
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
	if [ -f "$TARGET_BIN" ] && [ "$(sha256_of "$TARGET_BIN")" = "$cand_sha" ] && health_once; then
		if [ "$FORCE" -ne 1 ]; then
			ok "Кандидат уже установлен (SHA-256 совпадает), служба здорова — изменений не требуется"
			emit "CSQTT_SERVER_UP_TO_DATE|$SERVICE|$cand_sha"
			return 0
		fi
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		ok "dry-run: изменения не вносились"
		emit "CSQTT_SERVER_DRY_RUN|$SERVICE"
		return 0
	fi

	confirm "Заменить $TARGET_BIN на кандидат и перезапустить $SERVICE?"

	take_lock
	bdir=$(make_backup "$mode")
	step "Резервная копия создана: $bdir"

	step "Атомарная замена бинарника"
	put_binary "$CANDIDATE"

	step "Перезапуск службы $SERVICE"
	if ! "$SYSTEMCTL_BIN" restart "$SERVICE" >/dev/null 2>&1; then
		err "systemctl restart $SERVICE завершился ошибкой"
		auto_rollback "$bdir"
	fi

	step "Проверка запуска и здоровья"
	if wait_health; then
		record_current "$bdir" "$cand_sha"
		ok "Установка завершена: служба активна, проверки пройдены"
		ok "Откат при необходимости: $TOOL_NAME rollback --backup $bdir"
		emit "CSQTT_SERVER_DEPLOY_OK|$SERVICE|$cand_sha"
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
	emit "CSQTT_SERVER_STATUS|$SERVICE|${active:-unknown}"
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
		emit "CSQTT_SERVER_VERIFY_OK|$SERVICE"
		return 0
	fi
	emit "CSQTT_SERVER_VERIFY_FAILED|$SERVICE"
	return "$EX_PREFLIGHT"
}

cmd_rollback() {
	local bdir="$1" safety
	[ -n "$bdir" ] || die "не указан каталог резервной копии (--backup DIR)" "$EX_USAGE"
	[ -d "$bdir" ] || die "каталог резервной копии не найден: $bdir" "$EX_USAGE"

	if [ "$DRY_RUN" -eq 1 ]; then
		ok "dry-run: откат не выполнялся; будет использована копия $bdir"
		emit "CSQTT_SERVER_DRY_RUN|rollback"
		return 0
	fi

	confirm "Восстановить состояние из $bdir и перезапустить $SERVICE?"

	take_lock
	safety=$(make_backup "pre-rollback")
	step "Текущее состояние сохранено: $safety"
	if rollback_to_backup "$bdir" "$RESTORE_CONFIG"; then
		local now
		now=$(sha256_of "$TARGET_BIN" 2>/dev/null || echo removed)
		record_current "$safety" "$now"
		ok "Откат выполнен"
		emit "CSQTT_SERVER_ROLLED_BACK|$bdir"
		return 0
	fi
	die "откат не удался; текущее состояние сохранено в $safety" "$EX_ROLLBACK_FAILED"
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
		--config-dir) CONFIG_DIR="${2:-}"; shift 2 ;;
		--unit) UNIT_PATH="${2:-}"; shift 2 ;;
		--iface) IFACE="${2:-}"; shift 2 ;;
		--web-port) WEB_PORT="${2:-}"; shift 2 ;;
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

	case "${ACTION:-help}" in
	help) usage; exit "$EX_OK" ;;
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
	*) usage; die "неизвестное действие: ${ACTION}" "$EX_USAGE" ;;
	esac
}

main "$@"
