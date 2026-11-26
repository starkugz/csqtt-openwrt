#!/bin/sh
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# [051] Установщик CSQTT для OpenWrt: единственное ядро 2.5.3 и отдельная
# панель CSQTT 2.5. Панель и ядро обновляются независимо, профили,
# секреты и device_id в /etc/config/csqtt сохраняются.
#
# Режимы (--set): core | panel | both. Действия: install, update, check,
# inventory, status, verify, rollback, uninstall, help.
#
# [057] Основное ядро — 2.5.3. Ядро 2.1.9 ставится только по явному выбору
# (--core-version 2.1.9 или пункт меню) и только когда в выпуске есть пакет
# для точной линии OpenWrt и архитектуры; пункты меню 2.1.9 иначе скрыты.
#
# Конфигурация выпуска — единая: переменные CSQTT_RELEASE_OWNER,
# CSQTT_RELEASE_REPO, CSQTT_RELEASE_TAG из окружения или файла
# installer-release.conf рядом со скриптом. Если набор не задан полностью,
# выпуск честно BLOCKED (код 60): URL не выдумывается.
#
# [063] Если owner/repo заданы, а тег пуст, точный тег последнего
# опубликованного (не draft/prerelease) выпуска читается из GitHub API
# (/releases/latest) и дальше используются только точные URL
# /releases/download/<тег>/: строка "latest" как тег по-прежнему отвергается.
# CSQTT_RELEASE_DISCOVER=0 отключает это чтение (тег обязан быть в конфиге).
# CSQTT_RELEASE_BASE_URL — явное зеркало/локальный стенд для проверок.
#
# Менеджер пакетов определяется по факту: opkg => .ipk, apk => .apk.
# Оба или ни одного — отказ без fallback. Архитектура берётся у менеджера
# (opkg print-architecture / apk --print-arch), фиксированного списка нет.
# Серия OpenWrt читается из /etc/openwrt_release: если в выпуске есть
# имена с -openwrt-<серия>-, выбирается файл своей серии (так разведены
# стабильный Filogic 25.12 и Snapshot с одинаковыми ABI и форматом).
#
# Ничего не запускает загруженные данные как код: пакеты проверяются по
# SHA256SUMS из выпуска и передаются менеджеру пакетов.
#
# Коды возврата:
#   0  успех / проверка пройдена; установка без профиля или с выключенным
#      подключением — тоже 0 с маркером NEEDS_SETUP (пакеты установлены,
#      настройка нужна позже) и с прежним маркером OK для LuCI
#   2  ошибка аргументов или нужен --set/--yes
#   20 ошибка до изменений (манифест, SHA, ABI, зависимости, место, выпуск)
#   30 проверка после установки не прошла; прежнее состояние восстановлено
#      либо возврат неполный (RESTORE_INCOMPLETE) и нужно ручное решение
#   31 восстановить/удалить не удалось — нужна ручная команда
#   32 пакеты установлены, но служба/интерфейс не поднялись (не OK и не откат)
#   40 занято другим запуском
#   60 выпуск BLOCKED: не заданы owner/repo/tag
#
# Локальные проверки: openwrt/tests/installer-051/run.sh (CSQTT_ROOT, mocks).
set -u

CORE_VERSION=2.5.3
CORE_PACKAGE=csqtt-core-2.5.3
PANEL_PACKAGE=luci-app-csqtt
CORE_BRANCH=""

EX_OK=0
EX_USAGE=2
EX_PREFLIGHT=20
EX_RECOVERED=30
EX_FAILED=31
# [AUDIT BUG-02] Пакеты установлены, но служба не поднялась. Это не откат
# (файлы и конфигурация на месте) и не успех: вызывающий обязан показать
# отдельное состояние и не считать установку рабочей.
EX_SERVICE=32
EX_BUSY=40
EX_BLOCKED=60

# Запас сверх установленного размера: временные файлы распаковки, права,
# журналы. Не заменяет проверку памяти процесса ядра, только место на overlay.
SPACE_RESERVE_KB=${CSQTT_SPACE_RESERVE_KB:-3072}
case "$SPACE_RESERVE_KB" in '' | *[!0-9]*) SPACE_RESERVE_KB=3072 ;; esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=${CSQTT_ROOT:-}
CONFIG="$ROOT/etc/config/csqtt"
INITD="$ROOT/etc/init.d/csqtt"
STATE_DIR=${CSQTT_INSTALLER_STATE_DIR:-$ROOT/etc/csqtt-installer}
TMPBASE=${CSQTT_TMPDIR:-${ROOT:+$ROOT/tmp}}
[ -n "$TMPBASE" ] || TMPBASE=/tmp
WORK="$TMPBASE/csqtt-installer.$$"
LOCK="$TMPBASE/csqtt-installer.lock"

ACTION=""
INSTALL_SET=""
DRY_RUN=0
ASSUME_YES=0
PURGE=0
MENU=0
NO_RESTART=0
KEEP_STOPPED=0
BACKUP_ARG=""
RELEASE_CONF="${CSQTT_INSTALLER_RELEASE_CONF:-$SCRIPT_DIR/installer-release.conf}"
# [063/2] Привязка установки к завершённой проверке: панель передаёт точный
# тег, имя файла, SHA-256 и версию, которые были показаны пользователю.
# Пустые значения — обычный путь с выбором по манифесту.
PIN_TAG=""
PIN_NAME=""
PIN_SHA256=""
PIN_VERSION=""
PLAN_FILE="${CSQTT_INSTALLER_PLAN_FILE:-}"

SERIES=""
SERIES_LINE=""
PM=""
PKG_EXT=""
ARCH=""
HAVE_OPKG=0
HAVE_APK=0
BASE_URL=""
RELEASE_READY=0
RELEASE_STATE=""
API_JSON=""
OWNER=""
REPO=""
TAG=""
BACKUP=""
CFG_SHA_BEFORE=""
CFG_PRESENT_BEFORE=0
RESTORE_INCOMPLETE=""
LOCKED=0

log() { printf '[+] %s\n' "$*"; }
info() { printf '[i] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
err() { printf '[x] %s\n' "$*" >&2; }
step() { printf '\n== %s ==\n' "$*"; }
ok() { printf '  OK   %s\n' "$*"; }
emit() { printf 'CSQTT_INSTALLER_%s\n' "$*"; }

die() {
	err "$1"
	emit "FAILED|$2|$1"
	exit "$2"
}

cleanup() {
	if [ "$LOCKED" -eq 1 ]; then
		# [r38] внутри блокировки лежит pid: rmdir не удаляет непустой каталог
		# и оставлял бы ложную занятость после каждого запуска.
		rm -rf "$LOCK" 2>/dev/null || true
		LOCKED=0
	fi
	rm -rf "$WORK"
	rm -f "$TMPBASE/csqtt-release.$$.json" 2>/dev/null || true
	rm -f "$TMPBASE/csqtt-notes.$$.json" 2>/dev/null || true
}

# [r38] SIGTERM/SIGINT должны завершать установщик, а не только очищать
# временные файлы: прежний trap возвращал управление, `timeout` ждал дальше,
# и задание обновления оставалось «выполняется» навсегда.
on_exit() {
	_oe_rc=$?
	cleanup
	exit "$_oe_rc"
}
on_signal() {
	cleanup
	exit "$1"
}
trap on_exit EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

usage() {
	cat <<'EOF'
Использование: install-csqtt.sh [ДЕЙСТВИЕ] [параметры]

Действия:
  install      установить выбранные компоненты (по умолчанию)
  update       обновить выбранные уже установленные компоненты
  check        только чтение: что опубликовано и подходит ли этой системе
  inventory    только чтение: менеджер, arch, версии, конфигурация
  status       состояние установленных компонентов (только чтение)
  verify       проверить установленные компоненты (только чтение)
  rollback     восстановить снимок файлов и /etc/config/csqtt
  uninstall    удалить выбранные компоненты; конфигурация сохраняется
  help         эта справка

Параметры:
  --set core|panel|both  состав операции (обязателен без --menu)
  --core-version 2.1.9|2.5.3
                         явно выбрать ветку ядра для check/install/update/
                         uninstall (с --set core|both); для uninstall удаляется
                         только выбранное ядро, без флага — оба
  --menu                 интерактивный выбор состава (нужен TTY):
                           1) ядро 2.5.3 и панель
                           2) только ядро 2.5.3
                           3) только панель
                           4) ядро 2.1.9 и панель   — только если для этой
                           5) только ядро 2.1.9        линии есть пакет
                           6) удалить (для install/update/uninstall)
  --yes, -y              не запрашивать подтверждение
  --dry-run              проверить и показать план, ничего не менять
  --purge                при uninstall удалить /etc/config/csqtt и состояние
  --no-restart           не перезапускать службу после изменения
  --keep-stopped         остановить службу перед удалением и оставить её
                         остановленной (postrm не поднимет оставшееся ядро)
  --release-conf PATH    файл конфигурации выпуска
  --backup DIR           снимок для rollback (по умолчанию последний)
  --help, -h             эта справка

Привязка к проверке (install/update, один компонент):
  --pin-tag TAG          точный тег проверенного выпуска (latest не бывает)
  --pin-name FILE        имя проверенного пакета из SHA256SUMS
  --pin-sha256 HEX       SHA-256 проверенного пакета
  --pin-version VER      полная версия из метаданных проверенного пакета
  Если файл исчез или SHA/версия изменились — установка отклоняется с
  маркером ARTIFACT_CHANGED и просьбой повторить проверку.

Конфигурация выпуска (окружение или installer-release.conf):
  CSQTT_RELEASE_OWNER, CSQTT_RELEASE_REPO, CSQTT_RELEASE_TAG
  CSQTT_RELEASE_BASE_URL — явное зеркало (иначе GitHub Releases)
  CSQTT_RELEASE_API_BASE — API выпусков (по умолчанию https://api.github.com)
  CSQTT_RELEASE_DISCOVER — 1 (по умолчанию): без тега взять последний
                            опубликованный выпуск; 0 — только явный тег
  CSQTT_INSTALLER_NOTES_FILE — куда сохранить JSON выпуска для заметок
  CSQTT_INSTALLER_PLAN_FILE — куда сохранить результат проверки (план установки)
  CSQTT_ROOT — корень OpenWrt (только для офлайн-проверок)
  CSQTT_INSTALLER_STATE_DIR — каталог снимков состояния
  CSQTT_FETCH_BUDGET — общий предел загрузки в секундах (60; 0 — без общего
                             предела, но каждая попытка ограничена 45 с)
  CSQTT_FETCH_ATTEMPTS — попыток на загрузчик, 1–3 (2)
  CSQTT_FETCH_SKIP — не использовать перечисленные загрузчики (диагностика)
  CSQTT_INSTALLER_READY_TIMEOUT — ограниченное ожидание службы/TUN, с (30)

Без owner/repo/tag выпуск BLOCKED (код 60); URL не выдумывается, строка
latest как тег не принимается. Оба менеджера пакетов или ни одного —
отказ (код 20), без fallback. Панель и ядро обновляются независимо.
EOF
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		install | update | check | inventory | status | verify | rollback | uninstall | help)
			ACTION="$1"
			;;
		remove) ACTION="uninstall" ;;
		--set)
			[ "$#" -ge 2 ] || die "для --set нужно core|panel|both" "$EX_USAGE"
			INSTALL_SET="$2"
			shift
			;;
		--set=*) INSTALL_SET=${1#--set=} ;;
		--core-version)
			[ "$#" -ge 2 ] || die "для --core-version нужна версия" "$EX_USAGE"
			CORE_BRANCH="$2"
			shift
			;;
		--yes | -y) ASSUME_YES=1 ;;
		--dry-run) DRY_RUN=1 ;;
		--purge) PURGE=1 ;;
		--menu) MENU=1 ;;
		--no-restart) NO_RESTART=1 ;;
		--keep-stopped) KEEP_STOPPED=1 ;;
		--release-conf)
			[ "$#" -ge 2 ] || die "для --release-conf нужен путь" "$EX_USAGE"
			RELEASE_CONF="$2"
			shift
			;;
		--release-conf=*) RELEASE_CONF=${1#--release-conf=} ;;
		--backup)
			[ "$#" -ge 2 ] || die "для --backup нужен каталог" "$EX_USAGE"
			BACKUP_ARG="$2"
			shift
			;;
		--backup=*) BACKUP_ARG=${1#--backup=} ;;
		--pin-tag)
			[ "$#" -ge 2 ] || die "для --pin-tag нужен тег" "$EX_USAGE"
			PIN_TAG="$2"
			shift
			;;
		--pin-tag=*) PIN_TAG=${1#--pin-tag=} ;;
		--pin-name)
			[ "$#" -ge 2 ] || die "для --pin-name нужно имя файла" "$EX_USAGE"
			PIN_NAME="$2"
			shift
			;;
		--pin-name=*) PIN_NAME=${1#--pin-name=} ;;
		--pin-sha256)
			[ "$#" -ge 2 ] || die "для --pin-sha256 нужен SHA-256" "$EX_USAGE"
			PIN_SHA256="$2"
			shift
			;;
		--pin-sha256=*) PIN_SHA256=${1#--pin-sha256=} ;;
		--pin-version)
			[ "$#" -ge 2 ] || die "для --pin-version нужна версия" "$EX_USAGE"
			PIN_VERSION="$2"
			shift
			;;
		--pin-version=*) PIN_VERSION=${1#--pin-version=} ;;
		--help | -h) ACTION="help" ;;
		*) die "неизвестный аргумент: $1 (см. --help)" "$EX_USAGE" ;;
		esac
		shift
	done
	[ -n "$ACTION" ] || ACTION="install"
}

# --- менеджер пакетов и архитектура ---------------------------------------

probe_pm() {
	HAVE_OPKG=0
	HAVE_APK=0
	command -v opkg >/dev/null 2>&1 && HAVE_OPKG=1
	command -v apk >/dev/null 2>&1 && HAVE_APK=1
}

opkg_arch() {
	# [AUDIT BUG-08] Выбирается архитектура с максимальным числовым
	# приоритетом, а не первая строка вывода: на MIPS `print-architecture`
	# может начинаться с `mipsel_24kc_24kf 5`, тогда как пакет выпуска
	# собран для `mipsel_24kc 10`. При равном приоритете остаётся первая.
	opkg print-architecture 2>/dev/null |
		awk '$1=="arch" && $2!="all" && $2!="noarch" {
			p = $3 + 0
			if (name == "" || p > best) { best = p; name = $2 }
		} END { if (name != "") print name }'
}

apk_arch() {
	# [055/r10] Файлы выпуска названы архитектурой пакетов OpenWrt
	# (aarch64_cortex-a53), а `apk --print-arch` отдаёт архитектуру CPU
	# (aarch64). Совпадение по имени пакета требует первой.
	if [ -r "$ROOT/etc/apk/arch" ]; then
		awk 'NF{print $1; exit}' "$ROOT/etc/apk/arch"
		return
	fi
	apk --print-arch 2>/dev/null | awk 'NF{print $1; exit}'
}

# Серия OpenWrt из /etc/openwrt_release: 24.10/25.12 (стабильные) или snapshot.
# Нужна, чтобы Filogic 25.12 и Filogic Snapshot с одинаковыми ABI/форматом не
# путались: оба пакета лежат в одном выпуске, различаясь сегментом
# -openwrt-<серия>- в имени файла.
detect_series() {
	SERIES=""
	[ -r "$ROOT/etc/openwrt_release" ] || return 0
	SERIES=$(sed -n "s/^DISTRIB_RELEASE=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}\$/\1/p" \
		"$ROOT/etc/openwrt_release" | head -n1)
	case "$SERIES" in
	*SNAPSHOT* | *snapshot*) SERIES=snapshot ;;
	esac
	case "$SERIES" in
	'' | *[!0-9A-Za-z._-]*) SERIES="" ;;
	esac
	# Линия выпуска (25.12.5 -> 25.12): пакет той же линии подходит и после
	# минорного обновления OpenWrt, пока ABI/формат совпадают.
	SERIES_LINE=""
	case "$SERIES" in
	*.*) SERIES_LINE=${SERIES%.*} ;;
	esac
	[ -n "$SERIES" ] && info "серия OpenWrt: $SERIES"
	return 0
}

detect_pm_soft() {
	probe_pm
	if [ "$HAVE_OPKG" -eq 1 ] && [ "$HAVE_APK" -eq 0 ]; then
		PM="opkg"
		PKG_EXT="ipk"
		ARCH=$(opkg_arch)
	elif [ "$HAVE_APK" -eq 1 ] && [ "$HAVE_OPKG" -eq 0 ]; then
		PM="apk"
		PKG_EXT="apk"
		ARCH=$(apk_arch)
	else
		PM="none"
		PKG_EXT=""
		ARCH=""
	fi
}

detect_pm() {
	probe_pm
	if [ "$HAVE_OPKG" -eq 1 ] && [ "$HAVE_APK" -eq 1 ]; then
		die "найдены и opkg, и apk: формат выпуска неоднозначен, fallback запрещён" "$EX_PREFLIGHT"
	fi
	if [ "$HAVE_OPKG" -eq 0 ] && [ "$HAVE_APK" -eq 0 ]; then
		die "не найден ни opkg, ни apk: это не OpenWrt или менеджер недоступен" "$EX_PREFLIGHT"
	fi
	if [ "$HAVE_OPKG" -eq 1 ]; then
		PM="opkg"
		PKG_EXT="ipk"
		ARCH=$(opkg_arch)
	else
		PM="apk"
		PKG_EXT="apk"
		ARCH=$(apk_arch)
	fi
	[ -n "$ARCH" ] || die "не удалось определить архитектуру пакетов ($PM)" "$EX_PREFLIGHT"
	case "$ARCH" in
	*[!A-Za-z0-9_.-]*) die "некорректная архитектура пакетов: $ARCH" "$EX_PREFLIGHT" ;;
	esac
	info "менеджер пакетов: $PM (.$PKG_EXT), архитектура: $ARCH"
}

# --- конфигурация выпуска --------------------------------------------------

release_url() {
	[ -n "$BASE_URL" ] && return 0
	[ -n "$OWNER" ] && [ -n "$REPO" ] && [ -n "$TAG" ] || return 1
	BASE_URL="https://github.com/$OWNER/$REPO/releases/download/$TAG"
}

# [063] Точный тег последнего опубликованного выпуска (не draft/prerelease).
# API только читает; пакеты потом качаются по точному тегу, а не по latest.
# DISCOVER_STATE: api_unreachable (сеть/API) | not_published (404/нет тега).
discover_release_tag() {
	DISCOVER_STATE=""
	_dt_json="$TMPBASE/csqtt-release.$$.json"
	mkdir -p "$TMPBASE" 2>/dev/null || true
	fetch "${API_BASE}/repos/$OWNER/$REPO/releases/latest" "$_dt_json"
	_dt_rc=$?
	if [ "$_dt_rc" -ne 0 ]; then
		# Подтверждённый HTTP-ответ (FETCH_ERR=http): выпуска нет или он
		# скрыт. Иначе сеть/API недоступны; тело 4xx может содержать message.
		_dt_body=""
		[ -s "$_dt_json" ] && _dt_body=$(cat "$_dt_json" 2>/dev/null || true)
		case "$_dt_rc" in
		8 | 22) DISCOVER_STATE=not_published ;;
		*)
			if [ "$FETCH_ERR" = "http" ]; then
				DISCOVER_STATE=not_published
			else
				case "$_dt_body" in
				*'"Not Found"'* | *'"message"'*) DISCOVER_STATE=not_published ;;
				*) DISCOVER_STATE=api_unreachable ;;
				esac
			fi
			;;
		esac
		rm -f "$_dt_json"
		return 1
	fi
	if [ ! -s "$_dt_json" ]; then
		rm -f "$_dt_json"
		DISCOVER_STATE=not_published
		return 1
	fi
	_dt_tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_dt_json" | head -n1)
	case "$_dt_tag" in
	'' | *[!A-Za-z0-9._/-]*)
		rm -f "$_dt_json"
		DISCOVER_STATE=not_published
		return 1
		;;
	esac
	TAG="$_dt_tag"
	API_JSON="$_dt_json"
	return 0
}

load_release() {
	if [ -f "$RELEASE_CONF" ]; then
		# shellcheck disable=SC1090
		. "$RELEASE_CONF"
		info "конфигурация выпуска: $RELEASE_CONF"
	fi
	OWNER=${CSQTT_RELEASE_OWNER:-}
	REPO=${CSQTT_RELEASE_REPO:-}
	TAG=${CSQTT_RELEASE_TAG:-}
	BASE_URL=${CSQTT_RELEASE_BASE_URL:-}
	API_BASE=${CSQTT_RELEASE_API_BASE:-https://api.github.com}
	RELEASE_READY=0
	RELEASE_STATE=""
	# [063/2] Установка привязана к проверенному выпуску: /releases/latest не
	# запрашивается, тег берётся ровно из подтверждения. Так смена latest между
	# проверкой и установкой не подменяет выбранную версию.
	if [ -n "$PIN_TAG" ]; then
		TAG="$PIN_TAG"
		if [ -n "$BASE_URL" ]; then
			RELEASE_READY=1
			RELEASE_STATE=ok
			return 0
		fi
		[ -n "$OWNER" ] && [ -n "$REPO" ] || return 0
		if release_url; then
			RELEASE_READY=1
			RELEASE_STATE=ok
		fi
		return 0
	fi
	[ -n "$TAG" ] && [ "$TAG" = "latest" ] && {
		TAG=""
		warn "tag=latest не запрашивается: укажите точный тег выпуска"
	}
	if [ -n "$BASE_URL" ]; then
		RELEASE_READY=1
		RELEASE_STATE=ok
		return 0
	fi
	[ -n "$OWNER" ] && [ -n "$REPO" ] || return 0
	if [ -z "$TAG" ] && [ "${CSQTT_RELEASE_DISCOVER:-1}" != "0" ]; then
		if discover_release_tag; then
			info "опубликованный выпуск: $TAG (GitHub API)"
		else
			RELEASE_STATE=$DISCOVER_STATE
		fi
	fi
	if [ -n "$TAG" ]; then
		release_url || true
		RELEASE_READY=1
		RELEASE_STATE=ok
	fi
	return 0
}

require_release() {
	load_release
	if [ "$RELEASE_READY" -eq 1 ]; then
		info "выпуск: ${BASE_URL}"
		return 0
	fi
	case "$RELEASE_STATE" in
	not_published)
		err "опубликованный выпуск не найден: ${OWNER:--}/${REPO:--} (GitHub Releases)"
		emit "RELEASE_NOT_PUBLISHED|owner:${OWNER:--}|repo:${REPO:--}"
		exit "$EX_BLOCKED"
		;;
	api_unreachable)
		err "не удалось проверить выпуски ${OWNER:--}/${REPO:--}: GitHub API недоступен (сеть/прокси)"
		emit "CHECK_FAILED|stage:release_api|reason:network"
		exit "$EX_PREFLIGHT"
		;;
	esac
	err "релиз BLOCKED: не заданы owner/repo/tag (окружение или $RELEASE_CONF)"
	err "укажите CSQTT_RELEASE_OWNER, CSQTT_RELEASE_REPO, CSQTT_RELEASE_TAG; URL не выдумывается"
	emit "RELEASE_BLOCKED|owner:${OWNER:--}|repo:${REPO:--}|tag:${TAG:--}"
	exit "$EX_BLOCKED"
}

# --- сеть ------------------------------------------------------------------

# [D1] Загрузчик. Минимальные требования: один из uclient-fetch, wget
# (BusyBox/GNU) или curl; опции -t/--tries не используются, потому что на
# штатном OpenWrt /usr/bin/wget — симлинк на uclient-fetch, который их не
# понимает. Тайм-ауты (-T/--connect-timeout/--max-time) и проверка TLS
# сохраняются. Результат попытки классифицируется в FETCH_ERR:
#   http    — сервер ответил HTTP-ошибкой (4xx/5xx), код не выдумывается;
#   tls     — не прошла проверка сертификата/рукопожатие;
#   network — нет связи, DNS или тайм-аут;
#   nodl    — нет ни одного инструмента скачивания.
# Пустой FETCH_ERR при успехе. Ни одна неудача не выдаётся за HTTP 404.
FETCH_ERR=""
FETCH_DETAIL=""

# Подтверждённый код HTTP из текста ошибки (BusyBox/GNU wget, uclient-fetch).
fetch_http_code() { # MSG -> 404|403|5xx|пусто
	printf '%s\n' "$1" |
		grep -oE '(HTTP/[0-9.]+|HTTP error|[Ee]rror|ERROR|server returned)[^0-9]{0,6}[45][0-9][0-9]' 2>/dev/null |
		grep -oE '[45][0-9][0-9]' | head -n 1
}

fetch_classify() { # TOOL RC MESSAGE
	_kind=""
	case "$1:$2" in
	uclient-fetch:8 | wget:8 | curl:22) _kind=http ;;
	uclient-fetch:5 | curl:35 | curl:51 | curl:58 | curl:59 | curl:60) _kind=tls ;;
	uclient-fetch:4 | uclient-fetch:6 | uclient-fetch:7 | curl:6 | curl:7 | curl:28) _kind=network ;;
	*:124 | *:137) _kind=network ;;
	*)
		case "$3" in
		*"HTTP error"* | *"HTTP/"*" 4"* | *"HTTP/"*" 5"* | *"ERROR 4"* | *"ERROR 5"* | *"server returned"*)
			_kind=http
			;;
		*[Cc]ertificate* | *SSL* | *TLS*) _kind=tls ;;
		*) _kind=network ;;
		esac
		;;
	esac
	# Подтверждённый ответ сервера информативнее сетевой ошибки другой
	# попытки: не понижаем http/tls до network. Код ответа сохраняется, даже
	# если http уже был подтверждён предыдущей попыткой.
	if [ "$_kind" = http ]; then
		_code=$(fetch_http_code "$3")
		[ -n "$_code" ] && [ -z "$FETCH_DETAIL" ] && FETCH_DETAIL=$_code
	fi
	case "$FETCH_ERR:$_kind" in
	http:*) return 0 ;;
	*:http | *:tls) FETCH_ERR=$_kind ;;
	nodl:*) FETCH_ERR=$_kind ;;
	*:network) [ -n "$FETCH_ERR" ] || FETCH_ERR=network ;;
	*) FETCH_ERR=$_kind ;;
	esac
	return 0
}

fetch_try() { # fetch_try TOOL CAP ARGS...
	_fetch_tool=$1
	_fetch_cap=$2
	shift 2
	: >"$FETCH_ERRFILE" 2>/dev/null || true
	fetch_hard_cap "$_fetch_cap" "$@" 2>"$FETCH_ERRFILE"
	_fetch_rc=$?
	[ "$_fetch_rc" -eq 0 ] && return 0
	_fetch_msg=""
	[ -s "$FETCH_ERRFILE" ] && _fetch_msg=$(tr '\n' ' ' <"$FETCH_ERRFILE" 2>/dev/null || true)
	fetch_classify "$_fetch_tool" "$_fetch_rc" "$_fetch_msg"
	return "$_fetch_rc"
}

# Тот же бинарник под другим именем (например, /usr/bin/wget — симлинк на
# uclient-fetch) не является независимой альтернативой: повторять им загрузку
# бессмысленно, результат будет тот же.
fetch_tool_id() { # fetch_tool_id TOOL -> путь бинарника
	_fti_path=$(command -v "$1" 2>/dev/null) || return 1
	[ -n "$_fti_path" ] || return 1
	_fti_real=$(readlink -f "$_fti_path" 2>/dev/null) || _fti_real=""
	[ -n "$_fti_real" ] || _fti_real=$_fti_path
	printf '%s\n' "$_fti_real"
}

# Повторы только для сетевого сбоя и пустого ответа: подтверждённый HTTP/TLS
# ответ повторять незачем. Число попыток ограничено (1–3).
fetch_attempts() {
	_fa=${CSQTT_FETCH_ATTEMPTS:-2}
	case "$_fa" in '' | *[!0-9]*) _fa=2 ;; esac
	[ "$_fa" -ge 1 ] || _fa=1
	[ "$_fa" -le 3 ] || _fa=3
	printf '%s\n' "$_fa"
}

# Жёсткий предел одной попытки: -T/--max-time самого загрузчика не спасают,
# если зависла резолвинг-функция. timeout есть не везде (BusyBox без -k),
# поэтому поддержка проверяется один раз; без неё остаются штатные тайм-ауты.
# Предел передаётся вызывающим: он не больше доли общего бюджета и остатка.
fetch_hard_cap() { # fetch_hard_cap SECONDS CMD...
	_fhc=$1
	shift
	case "$_fhc" in '' | *[!0-9]*) _fhc=45 ;; esac
	[ "$_fhc" -ge 1 ] || _fhc=1
	if command -v timeout >/dev/null 2>&1 &&
		[ "$(timeout -k 1 1 printf '%s' csqtt-timeout-ok 2>/dev/null)" = csqtt-timeout-ok ]; then
		timeout -k 2 "$_fhc" "$@"
	else
		"$@"
	fi
}

fetch_hard() { # fetch_hard CMD... (совместимость: прежний предел 45 с)
	fetch_hard_cap 45 "$@"
}

fetch_expired() {
	[ "${_FETCH_STOP:-0}" -gt 0 ] || return 1
	_now=$(date +%s 2>/dev/null) || return 1
	[ -n "$_now" ] || return 1
	[ "$_now" -ge "$_FETCH_STOP" ]
}

# Остаток общего бюджета в секундах (0 — не задан или уже истёк).
fetch_remaining() {
	[ "${_FETCH_STOP:-0}" -gt 0 ] || {
		printf '%s\n' 0
		return 0
	}
	_now=$(date +%s 2>/dev/null) || _now=0
	[ "$_now" -gt 0 ] || {
		printf '%s\n' 0
		return 0
	}
	_left=$((_FETCH_STOP - _now))
	[ "$_left" -gt 0 ] && printf '%s\n' "$_left" || printf '%s\n' 0
}

# Краткий прогресс только для человека: в stderr и только на терминале или по
# явному CSQTT_INSTALLER_PROGRESS=1. Машинный stdout (маркеры RPC) не трогаем;
# URL не печатаем — в нём могут быть параметры выпуска.
fetch_progress() {
	if [ "${CSQTT_INSTALLER_PROGRESS:-0}" = "1" ] || [ -t 2 ]; then
		printf '[i] %s\n' "$*" >&2
	fi
}

fetch_tool_kind() { # fetch_tool_kind TOOL -> http|tls|network|empty
	case "$1" in
	curl) printf '%s' "$_fk_curl" ;;
	wget) printf '%s' "$_fk_wget" ;;
	uclient-fetch) printf '%s' "$_fk_uclient" ;;
	esac
}

fetch_tool_kind_set() { # fetch_tool_kind_set TOOL KIND
	case "$1" in
	curl) _fk_curl=$2 ;;
	wget) _fk_wget=$2 ;;
	uclient-fetch) _fk_uclient=$2 ;;
	esac
}

# Одна попытка конкретным инструментом с пределом CAP. Успех — только
# непустой файл: rc=0 без тела не считается загрузкой.
fetch_once() { # fetch_once TOOL CAP URL OUT [HEADER]
	_fon_tool=$1
	_fon_url=$3
	_fon_out=$4
	rm -f "$_fon_out" 2>/dev/null || true
	: >"$_fon_out" 2>/dev/null || true
	_fon_cap=$2
	_fon_ct=15
	[ "$_fon_ct" -gt "$_fon_cap" ] && _fon_ct=$_fon_cap
	[ "$_fon_ct" -ge 1 ] || _fon_ct=1
	shift 4
	if [ -n "${1:-}" ]; then
		set -- "--header=$1"
	else
		set --
	fi
	case "$_fon_tool" in
	curl)
		fetch_try curl "$_fon_cap" curl -fsSL \
			--connect-timeout "$_fon_ct" --max-time "$_fon_cap" "$@" "$_fon_url" -o "$_fon_out"
		;;
	wget)
		fetch_try wget "$_fon_cap" wget -T "$_fon_cap" "$@" -O "$_fon_out" "$_fon_url"
		;;
	uclient-fetch)
		fetch_try uclient-fetch "$_fon_cap" uclient-fetch -T "$_fon_cap" "$@" -O "$_fon_out" "$_fon_url"
		;;
	*)
		return 127
		;;
	esac
	_fon_rc=$?
	if [ "$_fon_rc" -eq 0 ]; then
		[ -s "$_fon_out" ] && return 0
		case "$FETCH_ERR" in
		http | tls) ;;
		*) FETCH_ERR=empty ;;
		esac
		return 1
	fi
	return "$_fon_rc"
}

# Порядок: curl первым (на устройстве он скачал манифест, когда uclient-fetch
# исчерпал свой тайм-аут), затем wget, затем uclient-fetch. Сначала по одной
# попытке каждым РАЗНЫМ бинарником, и только потом повторы сетевых сбоев:
# общий бюджет не отдаётся первому инструменту целиком.
fetch() { # fetch URL OUT [HEADER]
	FETCH_ERR=""
	FETCH_DETAIL=""
	FETCH_BUDGET=0
	_FETCH_SEEN=""
	_FETCH_BUDGET_HIT=0
	_fetch_rc=127
	mkdir -p "$TMPBASE" 2>/dev/null || true
	FETCH_ERRFILE="$TMPBASE/.csqtt-fetch.$$"
	_attempts=$(fetch_attempts)
	# Общий бюджет времени: меню не должно «висеть» на трёх загрузчиках с
	# повторами. 0 отключает ограничение (только для диагностики). Явно
	# слишком малый бюджет честно исчерпывается, а не обходится.
	_budget=${CSQTT_FETCH_BUDGET:-60}
	case "$_budget" in '' | *[!0-9]*) _budget=60 ;; esac
	FETCH_BUDGET=$_budget
	_start=0
	_FETCH_STOP=0
	if [ "$_budget" -gt 0 ]; then
		_start=$(date +%s 2>/dev/null) || _start=0
		[ "$_start" -gt 0 ] && _FETCH_STOP=$((_start + _budget))
	fi
	_fk_curl=""
	_fk_wget=""
	_fk_uclient=""
	_skip=" ${CSQTT_FETCH_SKIP:-} "
	_tools=""
	_n=0
	for _t in curl wget uclient-fetch; do
		case "$_skip" in *" $_t "*) continue ;; esac
		command -v "$_t" >/dev/null 2>&1 || continue
		_tid=$(fetch_tool_id "$_t" 2>/dev/null) || _tid=""
		if [ -n "$_tid" ]; then
			case " $_FETCH_SEEN " in
			*" $_tid "*)
				fetch_progress "загрузка: $_t — тот же бинарник, что уже проверен; пропуск"
				continue
				;;
			esac
			_FETCH_SEEN="$_FETCH_SEEN $_tid"
		fi
		_tools="$_tools $_t"
		_n=$((_n + 1))
	done
	if [ "$_n" -eq 0 ]; then
		FETCH_ERR=nodl
		return 127
	fi
	_share=0
	if [ "$_budget" -gt 0 ]; then
		_share=$((_budget / _n))
		[ "$_share" -ge 3 ] || _share=3
	fi
	# Без общего предела (CSQTT_FETCH_BUDGET=0) попытка всё равно не может
	# быть бесконечной: зависший DNS/сокет не должен держать меню вечно.
	# 45 с — прежний штатный предел одной попытки (fetch_hard).
	_attempt_cap=45
	_try_no=0
	_total=$((_n * _attempts))
	_round=1
	while [ "$_round" -le "$_attempts" ]; do
		for _t in $_tools; do
			if [ "$_round" -gt 1 ]; then
				_k=$(fetch_tool_kind "$_t")
				case "$_k" in network | empty) ;; *) continue ;; esac
			fi
			if fetch_expired; then
				_FETCH_BUDGET_HIT=1
				break
			fi
			if [ "$_budget" -gt 0 ]; then
				_cap=$_share
				if [ "$_FETCH_STOP" -gt 0 ]; then
					_rem=$(fetch_remaining)
					if [ "$_rem" -lt 1 ]; then
						_FETCH_BUDGET_HIT=1
						break
					fi
					[ "$_cap" -gt 0 ] && [ "$_rem" -lt "$_cap" ] && _cap=$_rem
				fi
			else
				_cap=$_attempt_cap
			fi
			[ "$_cap" -ge 1 ] || _cap=1
			_try_no=$((_try_no + 1))
			fetch_progress "загрузка: $_t, попытка $_try_no из $_total (предел ${_cap} с)"
			fetch_once "$_t" "$_cap" "$1" "$2" "${3:-}"
			_fetch_rc=$?
			if [ "$_fetch_rc" -eq 0 ]; then
				rm -f "$FETCH_ERRFILE"
				fetch_progress "загрузка: $_t — успех"
				return 0
			fi
			fetch_tool_kind_set "$_t" "${FETCH_ERR:-network}"
			fetch_progress "загрузка: $_t не удалась (${FETCH_ERR:-network}); пробую альтернативу"
		done
		[ "$_FETCH_BUDGET_HIT" -eq 1 ] && break
		_round=$((_round + 1))
	done
	rm -f "$2" "$FETCH_ERRFILE"
	case "$FETCH_ERR" in
	http | tls | empty | nodl) ;;
	*) [ "$_FETCH_BUDGET_HIT" -eq 1 ] && FETCH_ERR=budget ;;
	esac
	return "${_fetch_rc:-1}"
}

# Человекочитаемая причина отказа загрузки по виду и подтверждённому коду.
fetch_reason_text() { # KIND [DETAIL]
	case "$1" in
	http) printf 'сервер вернул ошибку HTTP%s' "${2:+ $2}" ;;
	tls) printf 'не пройдена проверка TLS/сертификата' ;;
	nodl) printf 'нет инструмента скачивания (curl, wget или uclient-fetch)' ;;
	empty) printf 'сервер вернул пустой ответ (файл не записан)' ;;
	budget) printf 'исчерпан общий бюджет загрузки (%s с)' "${FETCH_BUDGET:-60}" ;;
	*) printf 'нет соединения с сервером (сеть, DNS или тайм-аут)' ;;
	esac
}

# Человекочитаемая причина отказа текущего fetch (для сообщений и маркеров).
fetch_fail_hint() {
	fetch_reason_text "$FETCH_ERR" "$FETCH_DETAIL"
}

asset_download_url() {
	case "$BASE_URL" in
	https://github.com/*/releases/download/*) printf '%s/%s?csqtt=%s-%s\n' "$BASE_URL" "$1" "$(date +%s)" "$$" ;;
	*) printf '%s/%s\n' "$BASE_URL" "$1" ;;
	esac
}

fetch_release_asset() { # fetch_release_asset NAME OUT
	if fetch "$(asset_download_url "$1")" "$2"; then
		return 0
	fi
	case "$FETCH_ERR" in network | budget | empty) ;; *) return 1 ;; esac
	# A configured mirror must remain authoritative.
	[ "$BASE_URL" = "https://github.com/$OWNER/$REPO/releases/download/$TAG" ] &&
		[ "$API_BASE" = https://api.github.com ] &&
		command -v jsonfilter >/dev/null 2>&1 || return 1
	case "$1" in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac

	_fra_index="$WORK/github-assets.json"
	_fra_api="$API_BASE/repos/$OWNER/$REPO/releases"
	fetch_progress "загрузка: пробую официальный API GitHub для $1"
	if [ ! -s "$_fra_index" ]; then
		CSQTT_FETCH_ATTEMPTS=1 fetch "$_fra_api/tags/$TAG" "$_fra_index" || return 1
	fi
	_fra_expr="@.assets[@.name=\"$1\"]"
	_fra_id=$(jsonfilter -i "$_fra_index" -e "$_fra_expr.id" 2>/dev/null)
	case "$_fra_id" in '' | *[!0-9]*) FETCH_ERR=empty; return 1 ;; esac
	_fra_digest=$(jsonfilter -i "$_fra_index" -e "$_fra_expr.digest" 2>/dev/null)
	_fra_hash=${_fra_digest#sha256:}
	case "$_fra_hash" in '' | *[!0-9a-f]*) FETCH_ERR=empty; return 1 ;; esac
	[ "$_fra_hash" != "$_fra_digest" ] && [ "${#_fra_hash}" -eq 64 ] ||
		{ FETCH_ERR=empty; return 1; }
	CSQTT_FETCH_ATTEMPTS=1 fetch "$_fra_api/assets/$_fra_id?csqtt=$(date +%s)-$$" "$2" \
		"Accept: application/octet-stream" || return 1
	if [ "$(sha256sum "$2" | awk '{print $1}')" != "$_fra_hash" ]; then
		rm -f "$2"
		FETCH_ERR=empty
		return 1
	fi
}

fetch_manifest() {
	[ -d "$WORK" ] || mkdir -p "$WORK"
	if ! fetch_release_asset SHA256SUMS "$WORK/SHA256SUMS"; then
		die "не удалось загрузить SHA256SUMS из $BASE_URL: $(fetch_fail_hint); изменения не вносились" "$EX_PREFLIGHT"
	fi
	[ -s "$WORK/SHA256SUMS" ] || die "SHA256SUMS пуст; выпуск неполный, изменения не вносились" "$EX_PREFLIGHT"
}

escape_re() { # escape_re STRING -> RE_ESC (достаточно точек для имён пакетов/arch)
	RE_ESC=$(printf '%s' "$1" | sed 's/[.]/[.]/g')
}

pick_asset() { # pick_asset REGEX -> "hash name" | AMBIGUOUS
	awk -v pat="$1" -v ser="$SERIES" -v line="$SERIES_LINE" '
		NF >= 2 {
			name = $2
			sub(/^\*/, "", name)
			sub(/^\.\//, "", name)
			if (name !~ pat) next
			if (ser != "" && index(name, "-openwrt-" ser "-") > 0) {
				exact = $1 " " name
				nexact++
				next
			}
			if (line != "" && index(name, "-openwrt-" line ".") > 0) {
				lmatch = $1 " " name
				nline++
				next
			}
			# A package explicitly named for another OpenWrt line is not generic.
			if (ser != "" && index(name, "-openwrt-") > 0) next
			gen = $1 " " name
			ngen++
		}
		END {
			if (nexact == 1) { print exact; exit 0 }
			if (nexact > 1) { print "AMBIGUOUS"; exit 0 }
			if (nline == 1) { print lmatch; exit 0 }
			if (nline > 1) { print "AMBIGUOUS"; exit 0 }
			if (ngen == 1) { print gen; exit 0 }
			if (ngen > 1) { print "AMBIGUOUS"; exit 0 }
		}' "$WORK/SHA256SUMS"
}

select_core() {
	escape_re "$CORE_PACKAGE"
	_core_re=$RE_ESC
	_core_short=$(pick_asset "^${_core_re}[_-]${ARCH_RE}[.]${PKG_EXT}\$")
	[ -n "$_core_short" ] || _core_short=$(pick_asset "^${_core_re}[_-].*[_-]${ARCH_RE}[.]${PKG_EXT}\$")
	if [ "$_core_short" = "AMBIGUOUS" ]; then
		die "в SHA256SUMS несколько ядер для $ARCH (.$PKG_EXT, серия ${SERIES:-не определена}); укажите BASE_URL нужной серии или выпуск с уникальными именами" "$EX_PREFLIGHT"
	fi
	SELECTED_CORE="$_core_short"
}

select_panel() {
	escape_re "$PANEL_PACKAGE"
	_panel_re=$RE_ESC
	_panel=$(pick_asset "^${_panel_re}[_-]all[.]${PKG_EXT}\$")
	[ -n "$_panel" ] || _panel=$(pick_asset "^${_panel_re}[_-].*[_-]all[.]${PKG_EXT}\$")
	if [ "$_panel" = "AMBIGUOUS" ]; then
		die "в SHA256SUMS несколько панелей (.$PKG_EXT, серия ${SERIES:-не определена}); укажите BASE_URL нужной серии или выпуск с уникальными именами" "$EX_PREFLIGHT"
	fi
	SELECTED_PANEL="$_panel"
}

download_asset() { # download_asset "hash name" component
	_dl_hash=${1%% *}
	_dl_name=${1#* }
	case "$_dl_name" in
	*/* | "" | . | ..) die "недопустимое имя файла в SHA256SUMS: $_dl_name" "$EX_PREFLIGHT" ;;
	esac
	if ! fetch_release_asset "$_dl_name" "$WORK/$_dl_name"; then
		_dl_hint=$(fetch_fail_hint)
		if [ -n "$PIN_NAME" ]; then
			emit "ARTIFACT_CHANGED|reason:unavailable|component:$INSTALL_SET|name:$_dl_name|fetch:${FETCH_ERR:-network}"
			die "проверенный файл $_dl_name недоступен: $_dl_hint; повторите проверку обновлений" "$EX_PREFLIGHT"
		fi
		die "не удалось скачать $_dl_name: $_dl_hint; изменения не вносились" "$EX_PREFLIGHT"
	fi
	if [ ! -s "$WORK/$_dl_name" ]; then
		if [ -n "$PIN_NAME" ]; then
			emit "ARTIFACT_CHANGED|reason:empty|component:$INSTALL_SET|name:$_dl_name"
			die "проверенный файл $_dl_name пуст; повторите проверку обновлений" "$EX_PREFLIGHT"
		fi
		die "файл $_dl_name пуст; изменения не вносились" "$EX_PREFLIGHT"
	fi
	_dl_got=$(sha256sum "$WORK/$_dl_name" | awk '{print $1}')
	if [ "$_dl_got" != "$_dl_hash" ]; then
		if [ -n "$PIN_NAME" ]; then
			emit "ARTIFACT_CHANGED|reason:sha256|component:$INSTALL_SET|name:$_dl_name|expected:$_dl_hash|got:$_dl_got"
			die "SHA-256 проверенного файла $_dl_name изменился; повторите проверку обновлений" "$EX_PREFLIGHT"
		fi
		die "SHA-256 не совпадает для $_dl_name (повреждённый или обрезанный файл); изменения не вносились" "$EX_PREFLIGHT"
	fi
	ok "$2: $_dl_name (SHA-256 совпал)"
}

# --- привязка к результату проверки ---------------------------------------

# SHA-256 конкретного имени из манифеста выпуска (пусто — файла нет).
manifest_sha_of() {
	awk -v n="$1" 'NF >= 2 {
		name = $2
		sub(/^\*/, "", name)
		sub(/^\.\//, "", name)
		if (name == n) { print $1; exit }
	}' "$WORK/SHA256SUMS"
}

# Проверка argv привязки. Все четыре значения обязательны вместе и должны
# соответствовать выбранному компоненту: иначе это не подтверждение панели.
validate_pins() {
	[ -n "$PIN_TAG$PIN_NAME$PIN_SHA256$PIN_VERSION" ] || return 0
	[ -n "$PIN_TAG" ] && [ -n "$PIN_NAME" ] && [ -n "$PIN_SHA256" ] && [ -n "$PIN_VERSION" ] ||
		die "--pin-tag/--pin-name/--pin-sha256/--pin-version задаются вместе" "$EX_USAGE"
	case "$PIN_TAG" in
	'' | *[!A-Za-z0-9._/-]*) die "некорректный --pin-tag: $PIN_TAG" "$EX_USAGE" ;;
	esac
	case "$PIN_SHA256" in
	*[!0-9a-f]*) die "некорректный --pin-sha256 (нужен lowercase hex)" "$EX_USAGE" ;;
	esac
	[ "${#PIN_SHA256}" -eq 64 ] || die "некорректный --pin-sha256 (нужно 64 символа)" "$EX_USAGE"
	case "$PIN_VERSION" in
	'' | *[!A-Za-z0-9._+~:-]*) die "некорректный --pin-version: $PIN_VERSION" "$EX_USAGE" ;;
	esac
	case "$PIN_NAME" in
	'' | */* | . | ..) die "некорректный --pin-name: $PIN_NAME" "$EX_USAGE" ;;
	esac
	case "$INSTALL_SET" in
	core)
		case "$PIN_NAME" in
		"${CORE_PACKAGE}"[_-]*"${ARCH}.${PKG_EXT}") ;;
		*) die "--pin-name не является ядром $CORE_PACKAGE для $ARCH (.$PKG_EXT): $PIN_NAME" "$EX_USAGE" ;;
		esac
		;;
	panel)
		case "$PIN_NAME" in
		"${PANEL_PACKAGE}"[_-]*[_-]"all.${PKG_EXT}") ;;
		*) die "--pin-name не является панелью $PANEL_PACKAGE (all, .$PKG_EXT): $PIN_NAME" "$EX_USAGE" ;;
		esac
		;;
	*)
		die "--pin-* допустимы только с --set core|panel" "$EX_USAGE"
		;;
	esac
}

# Выбранный файл обязан совпадать с проверенным по имени и SHA-256. Отличия —
# это не сетевая ошибка и не «нет пакета»: выпуск изменился, нужна новая
# проверка (маркер ARTIFACT_CHANGED).
pin_asset() { # pin_asset LABEL
	_pa_sha=$(manifest_sha_of "$PIN_NAME")
	if [ -z "$_pa_sha" ]; then
		emit "ARTIFACT_CHANGED|reason:missing|component:$INSTALL_SET|name:$PIN_NAME"
		die "проверенный файл $1 ($PIN_NAME) исчез из выпуска; повторите проверку обновлений" "$EX_PREFLIGHT"
	fi
	if [ "$_pa_sha" != "$PIN_SHA256" ]; then
		emit "ARTIFACT_CHANGED|reason:sha256|component:$INSTALL_SET|name:$PIN_NAME|expected:$PIN_SHA256|got:$_pa_sha"
		die "SHA-256 проверенного файла $1 изменился; повторите проверку обновлений" "$EX_PREFLIGHT"
	fi
	PIN_ASSET="$_pa_sha $PIN_NAME"
}

# Версия внутри скачанного пакета должна совпасть с показанной пользователю.
verify_pinned_pkg() { # verify_pinned_pkg NAME
	[ -n "$PIN_VERSION" ] || return 0
	_vp_ver=$(pkg_version_of_file "$WORK/$1")
	if [ "$_vp_ver" != "$PIN_VERSION" ]; then
		emit "ARTIFACT_CHANGED|reason:version|component:$INSTALL_SET|name:$1|expected:$PIN_VERSION|got:${_vp_ver:--}"
		die "версия проверенного пакета $1 ($_vp_ver) не совпадает с подтверждённой ($PIN_VERSION); повторите проверку обновлений" "$EX_PREFLIGHT"
	fi
}

# --- проверка выпуска без изменений (check) --------------------------------

# Полная пакетная версия из метаданных скачанного файла (ipk -> control,
# apk -> adbdump). Проверенный по SHA файл читается локально, код не
# исполняется. Пусто — версия не определена (формат/утилита недоступны).
pkg_version_of_file() {
	_pv_file=$1
	_pv=""
	if [ "$PKG_EXT" = "apk" ]; then
		if command -v apk >/dev/null 2>&1; then
			_pv=$(apk adbdump --allow-untrusted "$_pv_file" 2>/dev/null |
				sed -n 's/^[[:space:]]*version:[[:space:]]*//p' | head -n1)
			[ -n "$_pv" ] || _pv=$(apk adbdump "$_pv_file" 2>/dev/null |
				sed -n 's/^[[:space:]]*version:[[:space:]]*//p' | head -n1)
		fi
	else
		_pv=$(tar -xzOf "$_pv_file" ./control.tar.gz 2>/dev/null |
			tar -xzOf - ./control 2>/dev/null |
			sed -n 's/^Version:[[:space:]]*//p' | head -n1)
		[ -n "$_pv" ] || _pv=$(tar -xzOf "$_pv_file" ./control.tar.gz 2>/dev/null |
			tar -xzOf - control 2>/dev/null |
			sed -n 's/^Version:[[:space:]]*//p' | head -n1)
		if [ -z "$_pv" ] && command -v ar >/dev/null 2>&1; then
			_pv=$(ar p "$_pv_file" control.tar.gz 2>/dev/null |
				tar -xzOf - ./control 2>/dev/null |
				sed -n 's/^Version:[[:space:]]*//p' | head -n1)
		fi
	fi
	# Маркеры выпуска разделены `|`: версия с таким символом недопустима.
	case "$_pv" in
	*[!A-Za-z0-9._+~:-]*) _pv="" ;;
	esac
	printf '%s' "$_pv"
}

# Сравнение полных пакетных версий (2.5.3-r1, 2.5-r4): основа по числовым
# компонентам, затем ревизия -rN. Печатает 1 (A новее), 0 (равны), -1 (старее).
ver_cmp() {
	awk -v a="$1" -v b="$2" '
	function norm(s, out,   n, i, p) {
		n = split(s, p, /[._+~:-]/);
		out = 0;
		for (i = 1; i <= 4; i++)
			out = out * 100000 + (p[i] ~ /^[0-9]+$/ ? p[i] + 0 : 0);
		return out;
	}
	BEGIN {
		sa = split(a, ra, "-r");
		sb = split(b, rb, "-r");
		ba = norm(ra[1]);
		bb = norm(rb[1]);
		if (ba != bb) { print (ba > bb ? 1 : -1); exit }
		na = (sa > 1 && ra[2] ~ /^[0-9]+$/) ? ra[2] + 0 : 0;
		nb = (sb > 1 && rb[2] ~ /^[0-9]+$/) ? rb[2] + 0 : 0;
		if (na != nb) { print (na > nb ? 1 : -1); exit }
		print 0;
	}'
}

# Скачивание asset'а для проверки: та же проверка SHA/пустоты, что и при
# установке, но без die — причина уходит в CHECK_ERR для отдельного маркера.
check_download() { # "hash name" -> 0; CHECK_ERR/CHECK_ERR_NAME
	CHECK_ERR=""
	CHECK_ERR_NAME=""
	CHECK_FETCH_ERR=""
	_cd_hash=${1%% *}
	_cd_name=${1#* }
	case "$_cd_name" in
	*/* | "" | . | ..)
		CHECK_ERR=name
		CHECK_ERR_NAME="$_cd_name"
		return 1
		;;
	esac
	if ! fetch "$BASE_URL/$_cd_name" "$WORK/$_cd_name"; then
		# Пустое тело — отдельная причина: сеть могла быть доступна.
		if [ "$FETCH_ERR" = empty ]; then
			CHECK_ERR=empty
		else
			CHECK_ERR=download
			CHECK_FETCH_ERR=${FETCH_ERR:-network}
		fi
		CHECK_ERR_NAME="$_cd_name"
		return 1
	fi
	if [ ! -s "$WORK/$_cd_name" ]; then
		CHECK_ERR=empty
		CHECK_ERR_NAME="$_cd_name"
		return 1
	fi
	_cd_got=$(sha256sum "$WORK/$_cd_name" | awk '{print $1}')
	if [ "$_cd_got" != "$_cd_hash" ]; then
		CHECK_ERR=sha
		CHECK_ERR_NAME="$_cd_name"
		return 1
	fi
	return 0
}

# Результат проверки для панели: точный тег и по каждому проверенному
# компоненту имя/SHA-256/версия. Пишется только при успешной проверке
# (_check_bad=0) и только в разрешённом виде: значения ограничены наборами
# символов, чтобы JSON нельзя было сломать именем из манифеста.
write_plan() {
	[ -n "$PLAN_FILE" ] || return 0
	_wp_now=$(date +%s 2>/dev/null || true)
	case "$_wp_now" in '' | *[!0-9]*) _wp_now=0 ;; esac
	_wp_tag=$TAG
	case "$_wp_tag" in *[!A-Za-z0-9._/-]*) _wp_tag="" ;; esac
	_wp_dir=$(dirname "$PLAN_FILE" 2>/dev/null || printf '.')
	mkdir -p "$_wp_dir" 2>/dev/null || true
	_wp_tmp="$PLAN_FILE.tmp.$$"
	if ! printf '{"tag":"%s","checked":%s,"components":{%s}}\n' \
		"$_wp_tag" "$_wp_now" "${_plan_parts#,}" >"$_wp_tmp" 2>/dev/null; then
		rm -f "$_wp_tmp" 2>/dev/null || true
		warn "не удалось сохранить результат проверки: $PLAN_FILE"
		return 0
	fi
	chmod 0644 "$_wp_tmp" 2>/dev/null || true
	mv -f "$_wp_tmp" "$PLAN_FILE" 2>/dev/null || {
		rm -f "$_wp_tmp" 2>/dev/null || true
		warn "не удалось сохранить результат проверки: $PLAN_FILE"
	}
	return 0
}

# --- состояние пакетов -----------------------------------------------------

installed_version_of() {
	_iv_pkg=$1
	if [ "$PM" = "apk" ]; then
		apk list --installed 2>/dev/null |
			sed -n "s/^${_iv_pkg}-\([0-9][^ ]*\) .*/\1/p" | head -n1
	else
		opkg list-installed 2>/dev/null |
			sed -n "s/^${_iv_pkg} - \([0-9][^ ]*\).*/\1/p" | head -n1
	fi
}

# [AUDIT BUG-03] Путь к базе пакетного менеджера. Откат одних файлов оставлял
# в базе новую версию: следующий `opkg install`/`apk add` считал бы пакет
# актуальным, хотя на диске лежат файлы прежней версии.
pm_db_path() {
	if [ -n "${CSQTT_PM_DB:-}" ]; then
		printf '%s' "$CSQTT_PM_DB"
	elif [ "$PM" = "apk" ]; then
		printf '%s' "${ROOT%/}/lib/apk/db/installed"
	else
		printf '%s' "${ROOT%/}/usr/lib/opkg/status"
	fi
}

# Переписать версию установленного пакета в базе PM. Форматы различаются:
# opkg status — абзацы «Package:/Version:», apk installed — «P:/V:».
# Отсутствие записи — ошибка: иначе откат молча оставил бы чужую версию.
pm_db_set_version() { # pm_db_set_version PKG VERSION
	_pv_pkg=$1
	_pv_ver=$2
	_pv_db=$(pm_db_path)
	[ -f "$_pv_db" ] || return 1
	_pv_tmp="$_pv_db.csqtt.$$"
	if [ "$PM" = "apk" ]; then
		awk -v pkg="$_pv_pkg" -v ver="$_pv_ver" '
			BEGIN { RS = ""; FS = "\n"; OFS = "\n"; ORS = "\n\n" }
			{
				hit = 0
				for (i = 1; i <= NF; i++)
					if ($i == "P:" pkg) hit = 1
				if (hit) {
					for (i = 1; i <= NF; i++)
						if ($i ~ /^V:/) $i = "V:" ver
					done++
				}
				print
			}
			END { exit done ? 0 : 1 }
		' "$_pv_db" >"$_pv_tmp" || {
			rm -f "$_pv_tmp" 2>/dev/null || true
			return 1
		}
	else
		awk -v pkg="$_pv_pkg" -v ver="$_pv_ver" '
			BEGIN { RS = ""; FS = "\n"; OFS = "\n"; ORS = "\n\n" }
			{
				hit = 0
				for (i = 1; i <= NF; i++)
					if ($i == "Package: " pkg) hit = 1
				if (hit) {
					for (i = 1; i <= NF; i++)
						if ($i ~ /^Version:/) $i = "Version: " ver
					done++
				}
				print
			}
			END { exit done ? 0 : 1 }
		' "$_pv_db" >"$_pv_tmp" || {
			rm -f "$_pv_tmp" 2>/dev/null || true
			return 1
		}
	fi
	# Копия базы до правки — для ручного разбора, если откат прервётся.
	cp -p "$_pv_db" "$_pv_db.csqtt-rollback" 2>/dev/null || true
	mv -f "$_pv_tmp" "$_pv_db" || {
		rm -f "$_pv_tmp" 2>/dev/null || true
		return 1
	}
	return 0
}

dep_ok() {
	if [ "$PM" = "apk" ]; then
		apk info -e "$1" >/dev/null 2>&1
	else
		opkg list-installed 2>/dev/null | grep -q "^$1 - "
	fi
}

pkg_files() {
	if [ "$PM" = "apk" ]; then
		apk info -L "$1" 2>/dev/null
	else
		opkg files "$1" 2>/dev/null
	fi
}

# Локальные пакеты уже скачаны и проверены по SHA256, сеть здесь не нужна.
# Без --no-network apk открывает индексы репозиториев (wget на
# downloads.openwrt.org) и при перехваченном/недоступном WAN висит без
# ограничения времени: живая транзакция 055 встала именно на этом. С
# --no-network зависимости разрешаются из установленной базы, а реально
# отсутствующая зависимость даёт быстрый отказ вместо зависания.
pm_dry_run() {
	if [ "$PM" = "apk" ]; then
		apk --no-network --allow-untrusted --force-non-repository add --simulate "$@" >/dev/null 2>&1
	else
		opkg install --noaction "$@" >/dev/null 2>&1
	fi
}

pm_install() {
	if [ "$PM" = "apk" ]; then
		apk --no-network --allow-untrusted --force-non-repository add "$@"
	else
		opkg install --force-downgrade --force-reinstall "$@"
	fi
}

pm_remove() {
	if [ "$PM" = "apk" ]; then
		apk del "$1"
	else
		opkg remove "$1"
	fi
}

pm_dry_run_selected() {
	set --
	for _pds_f in $FILES; do
		set -- "$@" "$WORK/$_pds_f"
	done
	pm_dry_run "$@"
}

pm_install_selected() {
	set --
	for _pis_f in $FILES; do
		set -- "$@" "$WORK/$_pis_f"
	done
	pm_install "$@"
}

# --- проверка свободного места --------------------------------------------

# Установленный размер пакета в КиБ. Точное значение берётся из метаданных:
# ipk -> control.tar.gz/Installed-Size (байты), apk -> `apk adbdump` /
# installed-size. Если метаданные недоступны (старый формат, локальный
# mock), консервативно считаем 3× сжатого файла.
pkg_installed_kb() {
	_pik_f=$1
	[ -f "$_pik_f" ] || { printf '0'; return 0; }
	_pik_b=""
	if [ "$PKG_EXT" = "apk" ]; then
		_pik_b=$(apk adbdump "$_pik_f" 2>/dev/null |
			sed -n 's/^[[:space:]]*installed-size:[[:space:]]*//p' | head -n1)
	else
		_pik_b=$(tar -xzOf "$_pik_f" ./control.tar.gz 2>/dev/null |
			tar -xzOf - ./control 2>/dev/null |
			sed -n 's/^Installed-Size:[[:space:]]*//p' | head -n1)
		[ -n "$_pik_b" ] || _pik_b=$(tar -xzOf "$_pik_f" ./control.tar.gz 2>/dev/null |
			tar -xzOf - control 2>/dev/null |
			sed -n 's/^Installed-Size:[[:space:]]*//p' | head -n1)
		# Старый ar-контейнер ipk (не формат OpenWrt 24.10, но встречается).
		if [ -z "$_pik_b" ] && command -v ar >/dev/null 2>&1; then
			_pik_b=$(ar p "$_pik_f" control.tar.gz 2>/dev/null |
				tar -xzOf - ./control 2>/dev/null |
				sed -n 's/^Installed-Size:[[:space:]]*//p' | head -n1)
		fi
	fi
	case "$_pik_b" in
	"" | *[!0-9]*)
		_pik_bytes=$(wc -c <"$_pik_f" 2>/dev/null || printf '0')
		case "$_pik_bytes" in '' | *[!0-9]*) _pik_bytes=0 ;; esac
		printf '%s' $(( (_pik_bytes * 3 + 1023) / 1024 ))
		;;
	*) printf '%s' $(( (_pik_b + 1023) / 1024 )) ;;
	esac
}

# Свободное место установки: overlay, иначе корень. Пусто — df недоступен.
avail_kb() {
	_ak_target=${CSQTT_SPACE_TARGET:-$ROOT/overlay}
	[ -d "$_ak_target" ] || _ak_target=/
	_ak_kb=$(df -Pk "$_ak_target" 2>/dev/null | awk 'NR==2 { print $4 }')
	case "$_ak_kb" in
	"" | *[!0-9]*) _ak_kb=$(df -k "$_ak_target" 2>/dev/null | awk 'NR==2 { print $4 }') ;;
	esac
	case "$_ak_kb" in
	"" | *[!0-9]*) printf '' ;;
	*) printf '%s' "$_ak_kb" ;;
	esac
}

# Проверка до установки: на MT7621 с малым /overlay ядро 2.5.3 (~23 МиБ
# installed) не помещается. Отказ понятный и без частичных изменений.
space_preflight() {
	_sp_need=0
	for _sp_name in $FILES; do
		_sp_size=$(pkg_installed_kb "$WORK/$_sp_name")
		case "$_sp_size" in '' | *[!0-9]*) _sp_size=0 ;; esac
		_sp_need=$((_sp_need + _sp_size))
	done
	# При обновлении старая копия ещё занимает overlay, пока файлы не
	# заменены: резервируем место под старую и новую копии.
	[ "$_ci_mode" = "update" ] && _sp_need=$((_sp_need * 2))
	_sp_need=$((_sp_need + SPACE_RESERVE_KB))
	_sp_avail=$(avail_kb)
	if [ -z "$_sp_avail" ]; then
		warn "не удалось определить свободное место; проверка места пропущена"
		return 0
	fi
	if [ "$_sp_avail" -lt "$_sp_need" ]; then
		die "недостаточно места в /overlay для $INSTALL_SET: нужно около $(( (_sp_need + 1023) / 1024 )) МиБ, свободно $(( _sp_avail / 1024 )) МиБ; освободите место и повторите. Изменения не вносились." "$EX_PREFLIGHT"
	fi
	ok "места достаточно: нужно около $(( (_sp_need + 1023) / 1024 )) МиБ, свободно $(( _sp_avail / 1024 )) МиБ"
}

config_sha() {
	[ -f "$CONFIG" ] || {
		printf '%s' "-"
		return 0
	}
	sha256sum "$CONFIG" | awk '{print $1}'
}

service_enabled() {
	for _se_f in "$ROOT"/etc/rc.d/S*csqtt; do
		[ -e "$_se_f" ] || [ -L "$_se_f" ] || continue
		return 0
	done
	return 1
}

# Работаем на реальном корне (не офлайн CSQTT_ROOT). Проверки службы,
# ubus и интерфейса имеют смысл только там. CSQTT_INSTALLER_LIVE_RUNTIME=1 —
# только для тестов: позволяет изолированно проверить саму логику.
live_runtime() {
	[ -z "$ROOT" ] || [ "${CSQTT_INSTALLER_LIVE_RUNTIME:-0}" = "1" ]
}

# Каталог сетевых интерфейсов (переопределяется тестом).
net_sys_dir() {
	printf '%s' "${CSQTT_INSTALLER_NET_DIR:-/sys/class/net}"
}

# Запущена ли служба сейчас. Нужно снимку: откат обязан вернуть не только файлы,
# но и работающий движок (иначе после неудачной установки служба остаётся
# остановленной, как её остановил postinst нового ядра). В офлайн-корне и там,
# где ubus недоступен, ответ — «нет»: перезапускать нечего.
service_running() {
	live_runtime || return 1
	command -v ubus >/dev/null 2>&1 || return 1
	ubus -t 2 call service list '{"name":"csqtt"}' 2>/dev/null | grep -q '"running": true'
}

restart_service() {
	[ "$NO_RESTART" -eq 1 ] && {
		info "перезапуск службы пропущен (--no-restart)"
		return 0
	}
	# [058/r34] --keep-stopped: удаление работающего/последнего ядра не должно
	# поднимать службу ни здесь, ни в postrm.
	[ "$KEEP_STOPPED" -eq 1 ] && {
		info "служба оставлена остановленной (--keep-stopped)"
		return 0
	}
	if [ -x "$INITD" ]; then
		if "$INITD" restart >/dev/null 2>&1; then
			ok "служба перезапущена"
			return 0
		fi
		# [AUDIT BUG-02] Сбой перезапуска — не «предупреждение с кодом 0»:
		# вызывающий обязан увидеть неуспех и не выдавать установку за рабочую.
		warn "служба не перезапустилась; проверьте вручную: $INITD restart"
		return 1
	else
		info "init-скрипт отсутствует: перезапуск не требуется"
		return 0
	fi
}

stop_service() {
	[ "$NO_RESTART" -eq 1 ] && [ "$KEEP_STOPPED" -eq 0 ] && return 0
	[ -x "$INITD" ] || return 0
	"$INITD" stop >/dev/null 2>&1 || true
}

# --- снимки и откат --------------------------------------------------------

ensure_state() {
	mkdir -p "$STATE_DIR/backups"
	chmod 0700 "$STATE_DIR" "$STATE_DIR/backups" 2>/dev/null || true
}

take_lock() {
	[ "$LOCKED" -eq 1 ] && return 0
	mkdir -p "$TMPBASE"
	if mkdir "$LOCK" 2>/dev/null; then
		LOCKED=1
		printf '%s\n' "$$" >"$LOCK/pid" 2>/dev/null || true
		return 0
	fi
	# [r38] timeout -k может завершить установщик сигналом KILL: trap не
	# выполнится, каталог блокировки останется. Блокировка мёртвого
	# процесса не должна запрещать повторную проверку. Живой pid — занято;
	# запись без pid снимается только после 2 минут, чтобы не отобрать
	# блокировку у параллельного живого запуска прежней версии.
	_old_pid=""
	[ -f "$LOCK/pid" ] && _old_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
	case "$_old_pid" in
	'' | *[!0-9]*) _old_pid="" ;;
	esac
	if [ -n "$_old_pid" ] && [ -d "/proc/$_old_pid" ]; then
		die "другой запуск установщика уже выполняется ($LOCK)" "$EX_BUSY"
	fi
	if [ -z "$_old_pid" ] &&
		[ -z "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
		die "другой запуск установщика уже выполняется ($LOCK)" "$EX_BUSY"
	fi
	rm -rf "$LOCK" 2>/dev/null || true
	if mkdir "$LOCK" 2>/dev/null; then
		LOCKED=1
		printf '%s\n' "$$" >"$LOCK/pid" 2>/dev/null || true
		return 0
	fi
	die "другой запуск установщика уже выполняется ($LOCK)" "$EX_BUSY"
}

copy_pkg_files() { # copy_pkg_files PKG DIR
	_cpf_pkg=$1
	_cpf_dir=$2
	_cpf_root=${ROOT%/}
	[ -n "$_cpf_root" ] || _cpf_root=""
	mkdir -p "$_cpf_dir"
	: >"$_cpf_dir/files.list"
	pkg_files "$_cpf_pkg" | while IFS= read -r _cpf_f; do
		[ -n "$_cpf_f" ] || continue
		case "$_cpf_f" in
		/*) ;;
		*) continue ;;
		esac
		[ -f "$_cpf_root$_cpf_f" ] || [ -L "$_cpf_root$_cpf_f" ] || continue
		_cpf_dst="$_cpf_dir/files$_cpf_f"
		mkdir -p "$(dirname "$_cpf_dst")"
		cp -pP "$_cpf_root$_cpf_f" "$_cpf_dst" 2>/dev/null || return 1
		printf '%s\n' "$_cpf_f" >>"$_cpf_dir/files.list"
	done
}

make_backup() { # make_backup ACTION -> dir
	_mb_action=$1
	_mb_ts=$(date '+%Y%m%d-%H%M%S') || return 1
	_mb_dir="$STATE_DIR/backups/${_mb_ts}-${_mb_action}-$$"
	# [AUDIT BUG-06] Снимок — обязательный шаг: любая ошибка записи должна
	# вернуть неуспех, иначе вызывающий продолжит без возможности отката.
	mkdir -p "$_mb_dir/files" || return 1
	chmod 0700 "$_mb_dir" 2>/dev/null || true
	printf '%s\n' "$_mb_ts" >"$_mb_dir/timestamp" || return 1
	printf '%s\n' "$_mb_action" >"$_mb_dir/action" || return 1
	printf '%s\n' "$PM" >"$_mb_dir/pm" || return 1
	printf '%s\n' "$PKG_EXT" >"$_mb_dir/pkg_ext" || return 1
	printf '%s\n' "$ARCH" >"$_mb_dir/arch" || return 1
	printf '%s\n' "$CORE_PACKAGE" >"$_mb_dir/core_package" || return 1
	printf '%s\n' "$PANEL_PACKAGE" >"$_mb_dir/panel_package" || return 1
	installed_version_of "$CORE_PACKAGE" >"$_mb_dir/core_version" || return 1
	installed_version_of "$PANEL_PACKAGE" >"$_mb_dir/panel_version" || return 1
	[ -n "$(cat "$_mb_dir/core_version")" ] && echo yes >"$_mb_dir/core_present" || echo no >"$_mb_dir/core_present"
	[ -n "$(cat "$_mb_dir/panel_version")" ] && echo yes >"$_mb_dir/panel_present" || echo no >"$_mb_dir/panel_present"
	if [ -f "$CONFIG" ]; then
		echo yes >"$_mb_dir/config_present" || return 1
		cp -p "$CONFIG" "$_mb_dir/config.csqtt" || return 1
		chmod 0600 "$_mb_dir/config.csqtt" 2>/dev/null || true
		config_sha >"$_mb_dir/config.sha256" || return 1
		_mb_mode=$(stat -c '%a' "$CONFIG" 2>/dev/null || true)
		printf '%s\n' "${_mb_mode:-600}" >"$_mb_dir/config_mode" || return 1
	else
		echo no >"$_mb_dir/config_present" || return 1
	fi
	if service_enabled; then echo yes >"$_mb_dir/service_enabled" || return 1; else echo no >"$_mb_dir/service_enabled" || return 1; fi
	if service_running; then echo yes >"$_mb_dir/service_running" || return 1; else echo no >"$_mb_dir/service_running" || return 1; fi
	# Активное ядро до операции: откат возвращает общие точки входа именно к
	# нему, а не к «лучшему установленному» (после неудачной установки набор
	# мог измениться). Пусто — точек входа ещё нет.
	_mb_active=$(cat "$ROOT/usr/lib/csqtt/active" 2>/dev/null || true)
	printf '%s\n' "$_mb_active" >"$_mb_dir/active_core" || return 1
	if [ -s "$_mb_dir/core_version" ] && [ -n "$(cat "$_mb_dir/core_version")" ]; then
		copy_pkg_files "$CORE_PACKAGE" "$_mb_dir/core" || return 1
	fi
	if [ -s "$_mb_dir/panel_version" ] && [ -n "$(cat "$_mb_dir/panel_version")" ]; then
		copy_pkg_files "$PANEL_PACKAGE" "$_mb_dir/panel" || return 1
	fi
	chmod 0700 "$_mb_dir" "$_mb_dir/core" "$_mb_dir/panel" 2>/dev/null || true
	printf '%s\n' "$_mb_dir"
}

# Конфигурации до операции не было, а postinst создал шаблон. Фиксируем его
# SHA-256 сразу после установки: откат удалит файл, только если он не изменён
# с этого момента. Секретов в снимке нет — только хеш и права.
note_created_config() { # note_created_config BACKUP_DIR
	[ "$CFG_PRESENT_BEFORE" -eq 0 ] || return 0
	[ -f "$CONFIG" ] || return 0
	printf 'yes\n' >"$1/config_created" 2>/dev/null || return 1
	_ncc_sha=$(config_sha) || return 1
	printf '%s\n' "$_ncc_sha" >"$1/config_created.sha256" 2>/dev/null || return 1
	_ncc_mode=$(stat -c '%a' "$CONFIG" 2>/dev/null || true)
	printf '%s\n' "${_ncc_mode:-600}" >"$1/config_created.mode" 2>/dev/null || true
	return 0
}

remove_new_files() { # remove_new_files PKG OLD_LIST
	_rnf_pkg=$1
	_rnf_old=$2
	_rnf_root=${ROOT%/}
	[ -f "$_rnf_old" ] || return 0
	pkg_files "$_rnf_pkg" | while IFS= read -r _rnf_f; do
		[ -n "$_rnf_f" ] || continue
		case "$_rnf_f" in /*) ;; *) continue ;; esac
		grep -Fxq "$_rnf_f" "$_rnf_old" && continue
		rm -f "$_rnf_root$_rnf_f" 2>/dev/null || true
		prune_own_dirs "$(dirname "$_rnf_root$_rnf_f")"
	done
}

# Только собственные пустые каталоги пакета: rmdir не трогает непустые
# каталоги и чужие данные (оставшееся ядро, панель, другие пакеты).
prune_own_dirs() { # prune_own_dirs PATH
	_pod_p=${1%/}
	_pod_root=${ROOT%/}
	[ -n "$_pod_p" ] || return 0
	case "$_pod_p" in
	"$_pod_root/usr/lib/csqtt" | "$_pod_root/usr/lib/csqtt/"* | \
	"$_pod_root/usr/libexec/csqtt" | "$_pod_root/usr/libexec/csqtt/"* | \
	"$_pod_root/www/luci-static/resources/view/csqtt" | "$_pod_root/www/luci-static/resources/view/csqtt/"*)
		;;
	*) return 0 ;;
	esac
	while [ "$_pod_p" != "$_pod_root" ] && [ "$_pod_p" != "/" ] && [ -n "$_pod_p" ]; do
		rmdir "$_pod_p" 2>/dev/null || return 0
		_pod_p=$(dirname "$_pod_p")
	done
}

restore_files() { # restore_files BACKUP_PKG_DIR [LABEL]
	_rs_dir=$1
	_rs_label=${2:-files}
	_rs_root=${ROOT%/}
	[ -d "$_rs_dir/files" ] || return 0
	[ -f "$_rs_dir/files.list" ] || return 0
	while IFS= read -r _rs_f; do
		[ -n "$_rs_f" ] || continue
		_rs_src="$_rs_dir/files$_rs_f"
		[ -f "$_rs_src" ] || [ -L "$_rs_src" ] || {
			err "откат: в снимке $_rs_label нет файла $_rs_f"
			return 1
		}
		mkdir -p "$(dirname "$_rs_root$_rs_f")" || {
			err "откат: не удалось создать каталог для $_rs_f"
			return 1
		}
		rm -f "$_rs_root$_rs_f" || {
			err "откат: не удалось удалить текущий $_rs_f"
			return 1
		}
		cp -pP "$_rs_src" "$_rs_root$_rs_f" || {
			err "откат: не удалось вернуть файл $_rs_f"
			return 1
		}
	done <"$_rs_dir/files.list"
}

# [AUDIT BUG-03] Вернуть версии компонентов в базе PM. Вызывается после
# восстановления файлов; для компонентов, которых до операции не было,
# restore_snapshot уже удалил запись через pm_remove.
restore_pm_versions() { # restore_pm_versions BACKUP_DIR
	_rpm_b=$1
	_rpm_fail=0
	for _rpm_name in core panel; do
		_rpm_present=$(cat "$_rpm_b/${_rpm_name}_present" 2>/dev/null || echo no)
		_rpm_ver=$(cat "$_rpm_b/${_rpm_name}_version" 2>/dev/null || true)
		case "$_rpm_name" in
		core) _rpm_pkg=$CORE_PACKAGE ;;
		panel) _rpm_pkg=$PANEL_PACKAGE ;;
		esac
		[ "$_rpm_present" = "yes" ] || continue
		[ -n "$_rpm_ver" ] || continue
		if ! pm_db_set_version "$_rpm_pkg" "$_rpm_ver"; then
			err "откат: не удалось вернуть версию $_rpm_pkg ($_rpm_ver) в базе $PM"
			_rpm_fail=1
		fi
	done
	return "$_rpm_fail"
}

restore_snapshot() { # restore_snapshot BACKUP_DIR
	_rss_b=$1
	RESTORE_INCOMPLETE=""
	[ -d "$_rss_b" ] || {
		err "откат: снимок $_rss_b не найден"
		return 1
	}
	_rss_pm=$(cat "$_rss_b/pm" 2>/dev/null || echo "$PM")
	if [ -d "$_rss_b/core" ]; then
		remove_new_files "$CORE_PACKAGE" "$_rss_b/core/files.list"
	fi
	if [ -d "$_rss_b/panel" ]; then
		remove_new_files "$PANEL_PACKAGE" "$_rss_b/panel/files.list"
	fi
	if [ "$(cat "$_rss_b/core_present" 2>/dev/null || echo no)" = "no" ] &&
		[ -n "$(installed_version_of "$CORE_PACKAGE")" ]; then
		pm_remove "$CORE_PACKAGE" >/dev/null 2>&1 || true
	fi
	if [ "$(cat "$_rss_b/panel_present" 2>/dev/null || echo no)" = "no" ] &&
		[ -n "$(installed_version_of "$PANEL_PACKAGE")" ]; then
		pm_remove "$PANEL_PACKAGE" >/dev/null 2>&1 || true
	fi
	if [ -d "$_rss_b/core" ]; then restore_files "$_rss_b/core" "ядра" || return 1; fi
	if [ -d "$_rss_b/panel" ]; then restore_files "$_rss_b/panel" "панели" || return 1; fi
	if [ "$(cat "$_rss_b/config_present" 2>/dev/null || echo no)" = "yes" ]; then
		[ -f "$_rss_b/config.csqtt" ] || {
			err "откат: в снимке нет /etc/config/csqtt"
			return 1
		}
		mkdir -p "$(dirname "$CONFIG")" || return 1
		cp -p "$_rss_b/config.csqtt" "$CONFIG" || {
			err "откат: не удалось вернуть $CONFIG"
			return 1
		}
		_rss_mode=$(cat "$_rss_b/config_mode" 2>/dev/null || true)
		case "$_rss_mode" in
		[0-7][0-7][0-7] | [0-7][0-7][0-7][0-7]) ;;
		*) _rss_mode=600 ;;
		esac
		chmod "$_rss_mode" "$CONFIG" 2>/dev/null || true
		[ "$(config_sha)" = "$(cat "$_rss_b/config.sha256" 2>/dev/null || echo -)" ] || {
			err "откат: SHA-256 $CONFIG не совпал со снимком"
			return 1
		}
	else
		# Конфигурации до операции не было. Удаляется только созданный этой
		# операцией и не изменённый после создания шаблон. Изменённый файл не
		# наш: он сохраняется, а возврат честно помечается неполным.
		if [ -f "$CONFIG" ]; then
			_rss_created=$(cat "$_rss_b/config_created" 2>/dev/null || echo no)
			_rss_csha=$(cat "$_rss_b/config_created.sha256" 2>/dev/null || true)
			if [ "$_rss_created" = "yes" ] && [ -n "$_rss_csha" ] &&
				[ "$(config_sha)" = "$_rss_csha" ]; then
				if rm -f "$CONFIG" 2>/dev/null; then
					info "откат: созданный установкой неизменённый $CONFIG удалён"
				else
					RESTORE_INCOMPLETE="не удалось удалить созданный установкой $CONFIG"
					warn "откат: $RESTORE_INCOMPLETE; нужно ручное решение"
				fi
			else
				RESTORE_INCOMPLETE="созданный установкой $CONFIG изменён после создания и сохранён"
				warn "откат: $RESTORE_INCOMPLETE; нужно ручное решение"
			fi
		fi
	fi
	if [ -f "$_rss_b/keep_core253" ]; then
		activate_core253 || {
			err "откат: не удалось вернуть управляющий слой 2.5.3"
			return 1
		}
	fi
	# [AUDIT BUG-03] База PM возвращается вместе с файлами. Иначе версия в
	# opkg/apk остаётся новой и следующий install считает пакет актуальным.
	restore_pm_versions "$_rss_b" || return 1
	# Возврат общих точек входа к ядру, активному до операции. Файлы ядра уже
	# восстановлены; без активации /usr/bin/csqtt и /etc/init.d/csqtt могли бы
	# указывать на неудачно установленное ядро, а служба — остаться
	# остановленной (её останавливает postinst нового ядра).
	_rss_active=$(cat "$_rss_b/active_core" 2>/dev/null || true)
	if [ -n "$_rss_active" ] &&
	   [ -x "$ROOT/usr/lib/csqtt/core-$_rss_active/activate.sh" ]; then
		CSQTT_INSTALL_ROOT="$ROOT" \
			sh "$ROOT/usr/lib/csqtt/core-$_rss_active/activate.sh" install "$_rss_active" \
			|| {
				err "откат: активатор ядра $_rss_active завершился ошибкой"
				return 1
			}
		[ "$(cat "$ROOT/usr/lib/csqtt/active" 2>/dev/null || true)" = "$_rss_active" ] \
			|| {
				err "откат: активное ядро не вернулось к $_rss_active"
				return 1
			}
	fi
	if [ "$(cat "$_rss_b/service_running" 2>/dev/null || echo no)" = "yes" ]; then
		restart_service
	fi
	return 0
}

restored_file_matches() { # restored_file_matches SNAPSHOT_FILE RESTORED_FILE
	if [ -L "$1" ]; then
		[ -L "$2" ] && [ "$(readlink "$1")" = "$(readlink "$2")" ]
	else
		[ -f "$2" ] && [ ! -L "$2" ] && cmp -s "$1" "$2"
	fi
}

verify_restored() { # verify_restored BACKUP_DIR
	_vr_b=$1
	if [ "$(cat "$_vr_b/config_present" 2>/dev/null || echo no)" = "yes" ]; then
		[ "$(config_sha)" = "$(cat "$_vr_b/config.sha256" 2>/dev/null || echo -)" ] || {
			err "конфигурация не совпадает со снимком"
			return 1
		}
	fi
	if [ "$(cat "$_vr_b/core_present" 2>/dev/null || echo no)" = "yes" ]; then
		# [AUDIT BUG-03] Проверяется не только файл, но и версия в базе PM:
		# иначе «откат выполнен» при новой версии в opkg/apk — ложный успех.
		_vr_ver=$(cat "$_vr_b/core_version" 2>/dev/null || true)
		[ "$(installed_version_of "$CORE_PACKAGE")" = "$_vr_ver" ] || {
			err "после отката версия ядра в базе $PM не совпадает со снимком: ожидалась '$_vr_ver', получена '$(installed_version_of "$CORE_PACKAGE")'"
			return 1
		}
		[ -d "$_vr_b/core" ] && [ -f "$_vr_b/core/files.list" ] || {
			err "снимок файлов ядра отсутствует"
			return 1
		}
		while IFS= read -r _vr_f; do
			[ -n "$_vr_f" ] || continue
			restored_file_matches "$_vr_b/core/files$_vr_f" "${ROOT%/}$_vr_f" || {
				err "после отката файл ядра отличается от снимка: $_vr_f"
				return 1
			}
		done <"$_vr_b/core/files.list"
	else
		_vr_now=$(installed_version_of "$CORE_PACKAGE")
		[ -z "$_vr_now" ] || {
			err "после отката ядро $CORE_PACKAGE всё ещё числится установленным ($_vr_now)"
			return 1
		}
	fi
	if [ "$(cat "$_vr_b/panel_present" 2>/dev/null || echo no)" = "yes" ]; then
		_vr_ver=$(cat "$_vr_b/panel_version" 2>/dev/null || true)
		[ "$(installed_version_of "$PANEL_PACKAGE")" = "$_vr_ver" ] || {
			err "после отката версия панели в базе $PM не совпадает со снимком: ожидалась '$_vr_ver', получена '$(installed_version_of "$PANEL_PACKAGE")'"
			return 1
		}
		[ -d "$_vr_b/panel" ] && [ -f "$_vr_b/panel/files.list" ] || {
			err "снимок файлов панели отсутствует"
			return 1
		}
		while IFS= read -r _vr_f; do
			[ -n "$_vr_f" ] || continue
			restored_file_matches "$_vr_b/panel/files$_vr_f" "${ROOT%/}$_vr_f" || {
				err "после отката файл панели отличается от снимка: $_vr_f"
				return 1
			}
		done <"$_vr_b/panel/files.list"
	else
		_vr_now=$(installed_version_of "$PANEL_PACKAGE")
		[ -z "$_vr_now" ] || {
			err "после отката панель $PANEL_PACKAGE всё ещё числится установленной ($_vr_now)"
			return 1
		}
	fi
	return 0
}

# Согласованность базы PM с восстановленными файлами: 0 — согласовано,
# 1 — расхождение, 2 — проверить невозможно (нет менеджера/запроса).
# Предупреждение выводится только по 1/2, а не после каждого исправного отката.
pm_db_consistent() { # pm_db_consistent BACKUP_DIR
	_pdc_b=$1
	if [ "$PM" = "apk" ]; then
		command -v apk >/dev/null 2>&1 || return 2
		apk list --installed >/dev/null 2>&1 || return 2
	else
		command -v opkg >/dev/null 2>&1 || return 2
		opkg list-installed >/dev/null 2>&1 || return 2
	fi
	_pdc_fail=0
	for _pdc_name in core panel; do
		case "$_pdc_name" in
		core) _pdc_pkg=$CORE_PACKAGE ;;
		panel) _pdc_pkg=$PANEL_PACKAGE ;;
		esac
		_pdc_present=$(cat "$_pdc_b/${_pdc_name}_present" 2>/dev/null || echo no)
		_pdc_ver=$(cat "$_pdc_b/${_pdc_name}_version" 2>/dev/null || true)
		_pdc_now=$(installed_version_of "$_pdc_pkg")
		if [ "$_pdc_present" = "yes" ]; then
			[ "$_pdc_now" = "$_pdc_ver" ] || _pdc_fail=1
		else
			[ -z "$_pdc_now" ] || _pdc_fail=1
		fi
	done
	[ "$_pdc_fail" -eq 0 ]
}

# --- проверка состояния ----------------------------------------------------

# --- фактическое состояние конфигурации и готовность службы -----------------
#
# [2026-11-25] Установка без профиля — не отказ: пакет создаёт шаблон с
# enabled=0, транспорт не запускается, csqtt0 не появляется. Решение
# принимается по конфигурации и фактическому состоянию процесса, а не только
# по active_profile: при priority-выборе пригоден любой включённый профиль,
# при manual — active_profile и его enabled. Ошибка чтения конфигурации —
# отдельное состояние, она не превращается в «профиля нет, всё хорошо».

# Разбор подмножества UCI, достаточного для решения. Неизвестная строка или
# недопустимое значение 0/1 — ошибка конфигурации (демон тоже её отвергнет).
cfg_scan() { # cfg_scan FILE
	awk '
	function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
	function unquote(s,    q) {
		s = trim(s)
		if (s == "") return s
		q = substr(s, 1, 1)
		if (q == SQ || q == "\"") {
			if (length(s) < 2 || substr(s, length(s), 1) != q) { bad = 1; return s }
			s = substr(s, 2, length(s) - 2)
		}
		return s
	}
	function bool_state(v,    w) {
		if (v == "") return 0
		w = tolower(v)
		if (w == "0" || w == "false" || w == "off" || w == "no") return 0
		if (w == "1" || w == "true" || w == "on" || w == "yes") return 1
		return 2
	}
	BEGIN {
		SQ = sprintf("%c", 39)
		cur = ""; curname = ""; nserver = 0; bad = 0
		men = "0"; mmode = "priority"; mact = ""; mif = ""
	}
	{
		line = $0
		sub(/\r$/, "", line)
		if (line ~ /^[ \t]*$/) next
		if (line ~ /^[ \t]*#/) next
		if (line ~ /^[ \t]*config[ \t]+/) {
			s = line
			sub(/^[ \t]*config[ \t]+/, "", s)
			ctype = s
			sub(/[ \t].*$/, "", ctype)
			cname = ""
			if (s ~ /[ \t]/) {
				cname = s
				sub(/^[^ \t]+[ \t]+/, "", cname)
				cname = unquote(cname)
			}
			cur = ctype
			curname = cname
			if (ctype == "csqtt" && cname == "") bad = 1
			if (ctype == "server") {
				if (cname == "") bad = 1
				nserver++
				sid[nserver] = cname
				sen[nserver] = "1"
			}
			next
		}
		if (line ~ /^[ \t]*option[ \t]+/) {
			s = line
			sub(/^[ \t]*option[ \t]+/, "", s)
			if (s !~ /[ \t]/) { bad = 1; next }
			key = s
			sub(/[ \t].*$/, "", key)
			val = s
			sub(/^[^ \t]+[ \t]+/, "", val)
			val = unquote(val)
			if (cur == "csqtt" && curname == "main") {
				if (key == "enabled") men = val
				else if (key == "selection_mode") mmode = val
				else if (key == "active_profile") mact = val
				else if (key == "ifname") mif = val
			} else if (cur == "server" && nserver > 0 && key == "enabled") {
				sen[nserver] = val
			}
			next
		}
		if (line ~ /^[ \t]*list[ \t]+/) next
		bad = 1
	}
	END {
		mode = tolower(mmode)
		if (mode != "" && mode != "priority" && mode != "manual") bad = 1
		en = bool_state(men)
		if (en == 2) bad = 1
		usable = 0
		if (en == 1) {
			if (mode == "manual") {
				for (i = 1; i <= nserver; i++) {
					sb = bool_state(sen[i])
					if (sb == 2) bad = 1
					if (sid[i] == mact && sb == 1) usable = 1
				}
			} else {
				for (i = 1; i <= nserver; i++) {
					sb = bool_state(sen[i])
					if (sb == 2) bad = 1
					if (sb == 1) usable = 1
				}
			}
		}
		if (bad) { print "parse_error=1"; exit 0 }
		printf "enabled=%d mode=%s ifname=%s servers=%d usable=%d parse_error=0\n", \
			en, (mode == "manual" ? "manual" : "priority"), \
			(mif == "" ? "csqtt0" : mif), nserver, usable
	}
	' "$1" 2>/dev/null
}

# CFG_STATE: absent | disabled | no_profile | ready | error
# CFG_STATE_TEXT — короткая причина без секретов.
CFG_STATE=""
CFG_STATE_TEXT=""
CFG_ENABLED=0
CFG_MODE=priority
CFG_IFNAME=csqtt0
CFG_USABLE=0

config_state() {
	CFG_STATE=""
	CFG_STATE_TEXT=""
	CFG_ENABLED=0
	CFG_MODE=priority
	CFG_IFNAME=csqtt0
	CFG_USABLE=0
	if [ ! -e "$CONFIG" ]; then
		CFG_STATE=absent
		CFG_STATE_TEXT="конфигурация не создана"
		return 0
	fi
	if [ ! -f "$CONFIG" ] || [ ! -r "$CONFIG" ]; then
		CFG_STATE=error
		CFG_STATE_TEXT="файл недоступен для чтения"
		return 0
	fi
	_cs_line=$(cfg_scan "$CONFIG") || {
		CFG_STATE=error
		CFG_STATE_TEXT="файл не прочитан"
		return 0
	}
	case "$_cs_line" in
	*parse_error=1*)
		CFG_STATE=error
		CFG_STATE_TEXT="синтаксис UCI не разобран"
		return 0
		;;
	esac
	CFG_ENABLED=$(printf '%s\n' "$_cs_line" | sed -n 's/.*enabled=\([0-9]*\).*/\1/p')
	CFG_MODE=$(printf '%s\n' "$_cs_line" | sed -n 's/.*mode=\([a-z]*\).*/\1/p')
	CFG_IFNAME=$(printf '%s\n' "$_cs_line" | sed -n 's/.*ifname=\([^ ]*\).*/\1/p')
	CFG_USABLE=$(printf '%s\n' "$_cs_line" | sed -n 's/.*usable=\([0-9]*\).*/\1/p')
	case "$CFG_IFNAME" in
	'' | *[!A-Za-z0-9_.-]*)
		CFG_STATE=error
		CFG_STATE_TEXT="недопустимое имя интерфейса"
		return 0
		;;
	esac
	[ ${#CFG_IFNAME} -le 15 ] || {
		CFG_STATE=error
		CFG_STATE_TEXT="слишком длинное имя интерфейса"
		return 0
	}
	case "$CFG_ENABLED" in
	0)
		CFG_STATE=disabled
		CFG_STATE_TEXT="подключение выключено (main.enabled=0)"
		;;
	1)
		if [ "$CFG_USABLE" = "1" ]; then
			CFG_STATE=ready
			CFG_STATE_TEXT="включённый профиль есть (${CFG_MODE})"
		else
			CFG_STATE=no_profile
			CFG_STATE_TEXT="нет включённого профиля"
		fi
		;;
	*)
		CFG_STATE=error
		CFG_STATE_TEXT="не удалось определить main.enabled"
		;;
	esac
	return 0
}

status_file() {
	if [ -n "${CSQTT_INSTALLER_STATUS_FILE:-}" ]; then
		printf '%s' "$CSQTT_INSTALLER_STATUS_FILE"
	elif [ -n "$ROOT" ]; then
		printf '%s' "${ROOT%/}/var/run/csqtt/status.json"
	else
		printf '%s' /var/run/csqtt/status.json
	fi
}

status_daemon_pid() {
	_sdp_f=$(status_file)
	[ -r "$_sdp_f" ] || return 1
	sed -n 's/.*"daemon_pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_sdp_f" 2>/dev/null | head -n 1
}

status_daemon_state() {
	_sds_f=$(status_file)
	[ -r "$_sds_f" ] || return 1
	sed -n 's/.*"daemon_state"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p' "$_sds_f" 2>/dev/null | head -n 1
}

# Базовая линия снимается ДО перезапуска: интерфейс и status.json нового
# процесса нельзя сравнивать с состоянием, которое уже включает результат
# этого перезапуска. Иначе TUN, созданный во время restart, выглядел бы
# «существовавшим ранее» и установка ложно откатывалась.
_RW_CAPTURED=0
_RW_MODE=verify
_RW_PRE_IF=0
_RW_PRE_PID=""
_RW_NAME=csqtt0

readiness_capture() {
	_RW_MODE=restart
	config_state
	[ -n "$CFG_IFNAME" ] && _RW_NAME=$CFG_IFNAME
	_rwc_dir=$(net_sys_dir)
	_RW_PRE_IF=0
	[ -e "$_rwc_dir/$_RW_NAME" ] && _RW_PRE_IF=1
	_RW_PRE_PID=$(status_daemon_pid 2>/dev/null || true)
	_RW_CAPTURED=1
}

# Готовность интерфейса должна принадлежать НОВОМУ процессу. Старый csqtt0
# (persistent_tun=1 переживает Stop/Start) и устаревший status.json убитого
# процесса доказательством не являются. После перезапуска принять можно только
# новый daemon_pid или вновь появившийся интерфейс. При обычной проверке
# установленной системы (режим verify) достаточно живого daemon_pid или
# существующего интерфейса: перезапуска не было, доказывать новизну нечего.
# Причина отказа сохраняется в _RW_WHY.
readiness_proof() {
	_rp_pid=$(status_daemon_pid 2>/dev/null || true)
	_rp_state=$(status_daemon_state 2>/dev/null || true)
	if [ -n "$_rp_pid" ]; then
		if ! kill -0 "$_rp_pid" 2>/dev/null; then
			_RW_WHY="status.json указывает на несуществующий процесс $_rp_pid (устаревший статус)"
			return 1
		fi
		if [ "$_RW_MODE" = restart ] && [ -n "$_RW_PRE_PID" ] && [ "$_rp_pid" = "$_RW_PRE_PID" ]; then
			_RW_WHY="status.json принадлежит прежнему процессу $_rp_pid"
			return 1
		fi
		case "$_rp_state" in
		disabled | stopped | stopping)
			_RW_WHY="служба в состоянии ${_rp_state:-unknown} при включённом подключении"
			return 1
			;;
		esac
		return 0
	fi
	if [ -r "$(status_file)" ]; then
		_RW_WHY="в status.json нет daemon_pid: свежесть процесса не доказана"
		return 1
	fi
	if [ "$_RW_MODE" != restart ] || [ "$_RW_PRE_IF" -eq 0 ]; then
		return 0
	fi
	_RW_WHY="интерфейс $_RW_NAME существовал до перезапуска, а status.json не подтверждает новый процесс"
	return 1
}

# Ограниченное ожидание готовности. Никакого безусловного sleep: опрос
# прекращается сразу при подтверждении. 30 с по умолчанию обоснованы фактами:
# рабочий профиль занимал ~6 с от старта службы до TUN, status.json пишется
# раз в 5 с; пяти секунд не хватало даже обновлению. Предел можно уменьшить
# для проверок через CSQTT_INSTALLER_READY_TIMEOUT.
readiness_wait() {
	_rw_to=${CSQTT_INSTALLER_READY_TIMEOUT:-30}
	case "$_rw_to" in '' | *[!0-9]*) _rw_to=30 ;; esac
	_rw_dir=$(net_sys_dir)
	if [ "$_RW_CAPTURED" -eq 1 ]; then
		_RW_NAME=${_RW_NAME:-$CFG_IFNAME}
	else
		# Вызывающий не снимал базу до перезапуска: это обычная проверка.
		_RW_MODE=verify
		[ -n "$CFG_IFNAME" ] && _RW_NAME=$CFG_IFNAME
		_RW_PRE_IF=0
		[ -e "$_rw_dir/$_RW_NAME" ] && _RW_PRE_IF=1
		_RW_PRE_PID=$(status_daemon_pid 2>/dev/null || true)
	fi
	_RW_WHY=""
	_rw_start=$(date +%s 2>/dev/null) || _rw_start=0
	_rw_deadline=$((_rw_start + _rw_to))
	_rw_svc=0
	while :; do
		service_running && _rw_svc=1
		if [ "$_rw_svc" -eq 1 ] && [ -e "$_rw_dir/$_RW_NAME" ]; then
			if readiness_proof; then
				_RW_CAPTURED=0
				return 0
			fi
		fi
		_rw_now=$(date +%s 2>/dev/null) || _rw_now=0
		[ "$_rw_now" -lt "$_rw_deadline" ] || break
		sleep 0.5 2>/dev/null || sleep 1
	done
	_RW_CAPTURED=0
	if [ "$_rw_svc" -ne 1 ]; then
		err "служба csqtt не запущена (ubus не подтвердил running) за ${_rw_to} с"
	elif [ ! -e "$_rw_dir/$_RW_NAME" ]; then
		err "интерфейс $_RW_NAME не создан за ${_rw_to} с ($_rw_dir/$_RW_NAME)"
	else
		err "готовность не подтверждена за ${_rw_to} с: ${_RW_WHY:-причина не определена}"
	fi
	return 1
}

# Итог проверки: ready | needs_setup | failed (в STATE_RESULT). needs_setup —
# успешная установка без профиля/с выключенным подключением: это не отказ и не
# повод откатывать исправно установленные пакеты. failed — реальный отказ.
STATE_RESULT="ready"
STATE_DETAIL=""

state_check() { # state_check SET
	_sc_set=$1
	_sc_fail=0
	STATE_RESULT=ready
	STATE_DETAIL=""
	if [ "$_sc_set" = "core" ] || [ "$_sc_set" = "both" ]; then
		_sc_v=$(installed_version_of "$CORE_PACKAGE")
		case "$_sc_v" in
		"$CORE_VERSION" | "$CORE_VERSION"-*) ;;
		*)
			err "ядро $CORE_PACKAGE: ожидалась версия $CORE_VERSION, установлена '${_sc_v:-нет}'"
			_sc_fail=1
			;;
		esac
		[ -f "$ROOT/usr/bin/csqtt-$CORE_VERSION" ] || {
			err "нет /usr/bin/csqtt-$CORE_VERSION"
			_sc_fail=1
		}
		[ "$CORE_VERSION" != 2.5.3 ] || [ -f "$ROOT/usr/lib/csqtt/core-2.5.3/bin/csqtt-control" ] || {
			err "нет управляющего слоя /usr/lib/csqtt/core-2.5.3/bin/csqtt-control"
			_sc_fail=1
		}
		dep_ok kmod-tun || {
			err "не установлена зависимость kmod-tun"
			_sc_fail=1
		}
	fi
	if [ "$_sc_set" = "panel" ] || [ "$_sc_set" = "both" ]; then
		_sc_v=$(installed_version_of "$PANEL_PACKAGE")
		[ -n "$_sc_v" ] || {
			err "панель $PANEL_PACKAGE не установлена"
			_sc_fail=1
		}
		[ -f "$ROOT/usr/share/luci/menu.d/luci-app-csqtt.json" ] || {
			err "нет файла меню LuCI панели"
			_sc_fail=1
		}
		for _sc_d in luci-base rpcd-mod-ucode ucode-mod-socket coreutils-timeout; do
			dep_ok "$_sc_d" || {
				err "не установлена зависимость панели: $_sc_d"
				_sc_fail=1
			}
		done
	fi
	if [ "$CFG_PRESENT_BEFORE" -eq 1 ] && [ "$(config_sha)" != "$CFG_SHA_BEFORE" ]; then
		err "SHA-256 /etc/config/csqtt изменился: профили/секреты/device_id должны сохраняться"
		_sc_fail=1
	fi
	# Служба и интерфейс проверяются только для ядра на живом корне. Панель
	# сама транспорт не поднимает, поэтому для неё runtime-проверка не нужна.
	if live_runtime && { [ "$_sc_set" = "core" ] || [ "$_sc_set" = "both" ]; }; then
		config_state
		case "$CFG_STATE" in
		error)
			err "конфигурация /etc/config/csqtt не читается: $CFG_STATE_TEXT; состояние подключения проверить нельзя"
			_sc_fail=1
			;;
		absent)
			STATE_RESULT=needs_setup
			STATE_DETAIL="конфигурация не создана"
			info "конфигурация ещё не создана: установка без профиля, настройка нужна позже (needs_setup)"
			;;
		disabled)
			STATE_RESULT=needs_setup
			STATE_DETAIL="$CFG_STATE_TEXT"
			info "подключение выключено в конфигурации: транспорт не запускается (needs_setup)"
			;;
		no_profile)
			STATE_RESULT=needs_setup
			STATE_DETAIL="$CFG_STATE_TEXT"
			info "включённого профиля нет: служба запущена без транспорта (needs_setup)"
			;;
		ready)
			if [ "$NO_RESTART" -eq 1 ]; then
				ok "проверка запуска пропущена: --no-restart"
			elif readiness_wait; then
				STATE_RESULT=ready
			else
				_sc_fail=1
			fi
			;;
		esac
	elif ! live_runtime; then
		info "проверки службы и csqtt0 пропущены: офлайн-корень (SKIP)"
	fi
	[ "$_sc_fail" -eq 0 ]
}

# --- выбор состава ---------------------------------------------------------

# [057/063] Наличие ядра 2.1.9 для точной линии OpenWrt, архитектуры и формата
# пакетов. Меню показывает пункты 2.1.9 только после подтверждения по
# SHA256SUMS выпуска: без сети, без выпуска или без подходящего файла пункты
# скрыты, а установка 2.5.3/панели остаётся доступной.
# CORE219_AVAILABLE: 1 — пакет подтверждён, 0 — подтверждённое отсутствие,
# -1 — проверить не удалось (причина в CORE219_REASON). Сетевой отказ больше
# не выдаётся за отсутствие пакета.
CORE219_AVAILABLE=-1
CORE219_REASON=""
CORE219_FETCH_ERR=""
CORE219_FETCH_DETAIL=""

# Похож ли файл на SHA256SUMS: хотя бы одна строка «<64 hex> <имя>».
manifest_has_digest() { # manifest_has_digest FILE
	awk 'NF >= 2 {
		h = $1
		sub(/\*$/, "", h)
		if (length(h) == 64 && h ~ /^[0-9a-fA-F]+$/) { ok = 1; exit }
	} END { exit ok ? 0 : 1 }' "$1"
}

core219_reason_text() { # core219_reason_text REASON
	case "$1" in
	unconfigured) printf 'выпуск не настроен (owner/repo/tag или BASE_URL)' ;;
	api_unreachable) printf 'GitHub API недоступен: сеть, DNS, прокси или тайм-аут' ;;
	not_published) printf 'опубликованный выпуск не найден (404 или нет релиза)' ;;
	no_pm) printf 'не найден opkg или apk: формат пакетов неизвестен' ;;
	no_arch) printf 'не удалось определить архитектуру пакетов' ;;
	no_tmpdir) printf 'нет доступа к временному каталогу %s' "${TMPBASE:-/tmp}" ;;
	fetch) printf 'не удалось загрузить SHA256SUMS: %s' "$(fetch_reason_text "$CORE219_FETCH_ERR" "$CORE219_FETCH_DETAIL")" ;;
	manifest_empty) printf 'SHA256SUMS пуст' ;;
	manifest_invalid) printf 'ответ не похож на SHA256SUMS (возможно, отдан HTML/JSON)' ;;
	ambiguous) printf 'в SHA256SUMS несколько пакетов 2.1.9 для этой архитектуры' ;;
	absent) printf 'в выпуске нет пакета 2.1.9 для этой линии, архитектуры и формата' ;;
	*) printf 'причина не определена' ;;
	esac
}

probe_core219() {
	CORE219_AVAILABLE=-1
	CORE219_REASON=""
	CORE219_FETCH_ERR=""
	CORE219_FETCH_DETAIL=""
	detect_pm_soft
	detect_series
	load_release >/dev/null 2>&1 || true
	if [ "$RELEASE_READY" -ne 1 ]; then
		case "$RELEASE_STATE" in
		api_unreachable) CORE219_REASON=api_unreachable ;;
		not_published) CORE219_REASON=not_published ;;
		*) CORE219_REASON=unconfigured ;;
		esac
		return 0
	fi
	[ -n "$PKG_EXT" ] || { CORE219_REASON=no_pm; return 0; }
	case "$ARCH" in '' | *[!A-Za-z0-9_.-]*) CORE219_REASON=no_arch; return 0 ;; esac
	mkdir -p "$WORK" 2>/dev/null || { CORE219_REASON=no_tmpdir; return 0; }
	if ! fetch_release_asset SHA256SUMS "$WORK/SHA256SUMS" >/dev/null; then
		CORE219_FETCH_ERR=$FETCH_ERR
		CORE219_FETCH_DETAIL=$FETCH_DETAIL
		CORE219_REASON=fetch
		return 0
	fi
	[ -s "$WORK/SHA256SUMS" ] || { CORE219_REASON=manifest_empty; return 0; }
	manifest_has_digest "$WORK/SHA256SUMS" || { CORE219_REASON=manifest_invalid; return 0; }
	# Манифест подтверждён. «0» (пакета точно нет) ставится только после того,
	# как поиск действительно не нашёл файла: неоднозначность — это -1, а не
	# отсутствие, иначе меню сообщало бы «нет пакета» при двух кандидатах.
	ARCH_RE=$(printf '%s' "$ARCH" | sed 's/[][\\.^$*+?(){}|/]/\\&/g')
	escape_re csqtt-core-2.1.9
	_c219=$(pick_asset "^${RE_ESC}[_-]${ARCH_RE}[.]${PKG_EXT}\$")
	[ -n "$_c219" ] || _c219=$(pick_asset "^${RE_ESC}[_-].*[_-]${ARCH_RE}[.]${PKG_EXT}\$")
	case "$_c219" in
	AMBIGUOUS) CORE219_REASON=ambiguous; return 0 ;;
	'')
		CORE219_AVAILABLE=0
		CORE219_REASON=absent
		return 0
		;;
	esac
	CORE219_AVAILABLE=1
	CORE219_REASON=found
	# Найденный тег запоминается, чтобы require_release не спрашивал API снова.
	[ -n "$TAG" ] && CSQTT_RELEASE_TAG=$TAG
	return 0
}

menu_remove_select() {
	printf '\nУдаление компонентов CSQTT\n' >&2
	printf '  1) только панель CSQTT\n' >&2
	printf '  2) только ядро 2.5.3\n' >&2
	printf '  3) только ядро 2.1.9\n' >&2
	printf '  4) оба ядра (панель останется)\n' >&2
	printf '  5) панель и все ядра\n' >&2
	printf '\nКонфигурация и профили сохраняются.\n' >&2
	printf '  0) отмена\n\nЧто удалить > ' >&2
	read -r _remove_ans || _remove_ans=""
	ACTION=uninstall
	CORE_BRANCH=""
	CORE_VERSION=2.5.3
	CORE_PACKAGE=csqtt-core-2.5.3
	case "$_remove_ans" in
	0) exit 0 ;;
	1) INSTALL_SET=panel ;;
	2) INSTALL_SET=core; CORE_BRANCH=2.5.3 ;;
	3) INSTALL_SET=core; CORE_BRANCH=2.1.9 ;;
	4) INSTALL_SET=core ;;
	5) INSTALL_SET=both ;;
	*) die "неизвестный выбор удаления: $_remove_ans" "$EX_USAGE" ;;
	esac
}

menu_select() {
	[ -t 0 ] || die "для --menu нужен TTY; без TTY укажите --set core|panel|both" "$EX_USAGE"
	if [ "$ACTION" = uninstall ]; then
		detect_pm_soft
		menu_remove_select
		return 0
	fi
	_menu_color=""
	_menu_reset=""
	if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
		_menu_color=$(printf '\033[1;36m')
		_menu_reset=$(printf '\033[0m')
	fi
	# Ручной повтор проверки 2.1.9: только по явному вводу, не более двух раз,
	# без автоматического опроса сети.
	_menu_retries=0
	while :; do
		printf '\n%sCSQTT для OpenWrt%s\n' "$_menu_color" "$_menu_reset" >&2
		printf 'Проверка доступных компонентов…\n' >&2
		probe_core219
		printf '%s · %s · %s\n\n' "${SERIES:-OpenWrt}" "${ARCH:-архитектура не определена}" "${PKG_EXT:-пакеты}" >&2
		printf 'На устройстве:\n' >&2
		for _mi_pkg in csqtt-core-2.5.3 csqtt-core-2.1.9 "$PANEL_PACKAGE"; do
			_mi_ver=$(installed_version_of "$_mi_pkg")
			case "$_mi_pkg" in
			csqtt-core-*) _mi_label="Ядро ${_mi_pkg#csqtt-core-}" ;;
			*) _mi_label="Панель CSQTT" ;;
			esac
			if [ -n "$_mi_ver" ]; then
				printf '  %s: уже установлено (%s)\n' "$_mi_label" "${_mi_ver%-r*}" >&2
			else
				printf '  %s: не установлено\n' "$_mi_label" >&2
			fi
		done
		printf 'Установленные компоненты будут проверены на обновление.\n\n' >&2
		printf '%sВыберите состав:%s\n' "$_menu_color" "$_menu_reset" >&2
		printf '  1) ядро 2.5.3 и панель\n' >&2
		printf '  2) только ядро 2.5.3\n' >&2
		printf '  3) только панель\n' >&2
		_menu_del=0
		_menu_can_retry=0
		if [ "$CORE219_AVAILABLE" -eq 1 ]; then
			printf '  4) ядро 2.1.9 и панель\n' >&2
			printf '  5) только ядро 2.1.9\n' >&2
			_menu_del=6
		elif [ "$CORE219_AVAILABLE" -eq 0 ]; then
			info "пункты ядра 2.1.9 скрыты: для ${SERIES:-этой линии}/${ARCH:-этой архитектуры} (${PKG_EXT:-формат}) в выпуске нет пакета"
			_menu_del=4
		else
			# Причина называется точно: сеть, отсутствие выпуска, нечитаемый
			# манифест и подтверждённое отсутствие пакета — разные состояния.
			warn "доступность ядра 2.1.9 не проверена: $(core219_reason_text "$CORE219_REASON")"
			_menu_del=4
			# Повтор помогает только при временной причине. Неоднозначность
			# манифеста, отсутствие менеджера пакетов или архитектуры от
			# повтора не изменятся — не предлагаем заведомо бесполезное.
			case "$CORE219_REASON" in
			fetch | manifest_empty | manifest_invalid | api_unreachable)
				if [ "$_menu_retries" -lt 2 ]; then
					_menu_can_retry=1
					printf '  r) повторить проверку доступности 2.1.9 (осталось попыток: %s)\n' "$((2 - _menu_retries))" >&2
				else
					printf '  Лимит повторов проверки исчерпан: повторите запуск позже.\n' >&2
				fi
				;;
			*)
				printf '  Повтор не поможет: причина не сетевая — устраните её и запустите установщик снова.\n' >&2
				;;
			esac
		fi
		case "$ACTION" in
		install | update) printf '  %s) удалить компоненты…\n' "$_menu_del" >&2 ;;
		esac
		printf '\n  0) отмена\n\n' >&2
		printf 'Ваш выбор > ' >&2
		read -r _menu_ans || _menu_ans=""
		case "$_menu_ans" in
		0) exit 0 ;;
		r | R | retry | п)
			[ "$_menu_can_retry" -eq 1 ] || die "повтор проверки доступности 2.1.9 сейчас недоступен (лимит или уже подтверждённый результат)" "$EX_USAGE"
			_menu_retries=$((_menu_retries + 1))
			continue
			;;
		1)
			INSTALL_SET="both"
			CORE_BRANCH=2.5.3
			CORE_VERSION=2.5.3
			CORE_PACKAGE=csqtt-core-2.5.3
			;;
		2)
			INSTALL_SET="core"
			CORE_BRANCH=2.5.3
			CORE_VERSION=2.5.3
			CORE_PACKAGE=csqtt-core-2.5.3
			;;
		3) INSTALL_SET="panel"; CORE_BRANCH="" ;;
		"$_menu_del")
			case "$ACTION" in
			install | update)
				menu_remove_select
				;;
			*) die "для удаления запустите uninstall --set both" "$EX_USAGE" ;;
			esac
			;;
		4)
			[ "$CORE219_AVAILABLE" -eq 1 ] || die "ядро 2.1.9 недоступно для этой платформы (нет пакета в выпуске)" "$EX_USAGE"
			INSTALL_SET="both"
			CORE_BRANCH=2.1.9
			;;
		5)
			[ "$CORE219_AVAILABLE" -eq 1 ] || die "ядро 2.1.9 недоступно для этой платформы (нет пакета в выпуске)" "$EX_USAGE"
			INSTALL_SET="core"
			CORE_BRANCH=2.1.9
			;;
		*) die "неизвестный выбор: $_menu_ans" "$EX_USAGE" ;;
		esac
		break
	done
}

resolve_set() {
	case "$INSTALL_SET" in
	core | panel | both) ;;
	"") die "не задан состав: --set core|panel|both (или --menu)" "$EX_USAGE" ;;
	*) die "неизвестный состав: $INSTALL_SET (core|panel|both)" "$EX_USAGE" ;;
	esac
}

confirm() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	[ -t 0 ] || die "нет терминала для подтверждения; используйте --yes" "$EX_USAGE"
	printf '%s [y/N]: ' "$1" >&2
	read -r _c_ans || _c_ans=""
	_c_ans=$(printf '%s' "$_c_ans" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	case "$_c_ans" in
	y | Y | yes | YES) return 0 ;;
	*) die "отменено пользователем" "$EX_USAGE" ;;
	esac
}

# --- действия --------------------------------------------------------------

# [063] check: только чтение. Ничего не устанавливает и не меняет состояние:
# сравнивает полные пакетные версии установленного и опубликованного пакета
# для этой линии OpenWrt/архитектуры/формата. Маркеры CHECK*/RELEASE_*
# разбирает панель; отсутствие подходящего пакета, ненастроенный выпуск,
# неопубликованный выпуск и ошибка сети различаются отдельными маркерами.
cmd_check() {
	resolve_set
	detect_pm_soft
	detect_series
	load_release
	emit "CHECK_BEGIN|set:$INSTALL_SET|pm:${PM:-none}|ext:${PKG_EXT:--}|arch:${ARCH:-unknown}|series:${SERIES:--}|line:${SERIES_LINE:--}"

	# Заметки выпуска — JSON GitHub API, если панель попросила сохранить его.
	if [ -n "$API_JSON" ] && [ -f "$API_JSON" ] && [ -n "${CSQTT_INSTALLER_NOTES_FILE:-}" ]; then
		if mkdir -p "$(dirname "$CSQTT_INSTALLER_NOTES_FILE")" 2>/dev/null &&
			cp "$API_JSON" "$CSQTT_INSTALLER_NOTES_FILE" 2>/dev/null; then
			chmod 0644 "$CSQTT_INSTALLER_NOTES_FILE" 2>/dev/null || true
		else
			warn "не удалось сохранить заметки выпуска: $CSQTT_INSTALLER_NOTES_FILE"
		fi
	fi
	# Явный тег: /releases/latest не запрашивался, поэтому заметки берутся по
	# точному тегу. Сеть/API недоступны — это не ошибка проверки: панель
	# покажет версии без заметок.
	if [ -z "$API_JSON" ] && [ -n "${CSQTT_INSTALLER_NOTES_FILE:-}" ] &&
		[ -n "$OWNER" ] && [ -n "$REPO" ] && [ -n "$TAG" ] &&
		[ "${CSQTT_RELEASE_DISCOVER:-1}" != "0" ]; then
		_nt_json="$TMPBASE/csqtt-notes.$$.json"
		mkdir -p "$TMPBASE" 2>/dev/null || true
		if fetch "${API_BASE}/repos/$OWNER/$REPO/releases/tags/$TAG" "$_nt_json" &&
			[ -s "$_nt_json" ]; then
			if mkdir -p "$(dirname "$CSQTT_INSTALLER_NOTES_FILE")" 2>/dev/null &&
				cp "$_nt_json" "$CSQTT_INSTALLER_NOTES_FILE" 2>/dev/null; then
				chmod 0644 "$CSQTT_INSTALLER_NOTES_FILE" 2>/dev/null || true
			fi
			API_JSON="$_nt_json"
		else
			rm -f "$_nt_json"
		fi
	fi

	if [ "$RELEASE_READY" -ne 1 ]; then
		case "$RELEASE_STATE" in
		not_published)
			err "опубликованный выпуск не найден: ${OWNER:--}/${REPO:--} (GitHub Releases)"
			emit "RELEASE_NOT_PUBLISHED|owner:${OWNER:--}|repo:${REPO:--}"
			exit "$EX_BLOCKED"
			;;
		api_unreachable)
			err "не удалось проверить выпуски ${OWNER:--}/${REPO:--}: GitHub API недоступен (сеть/прокси)"
			emit "CHECK_FAILED|stage:release_api|reason:network"
			exit "$EX_PREFLIGHT"
			;;
		esac
		err "проверка невозможна: не заданы owner/repo/tag (окружение или $RELEASE_CONF)"
		emit "RELEASE_BLOCKED|owner:${OWNER:--}|repo:${REPO:--}|tag:${TAG:--}"
		exit "$EX_BLOCKED"
	fi
	emit "CHECK_RELEASE|owner:${OWNER:--}|repo:${REPO:--}|tag:${TAG:--}|url:$BASE_URL"
	info "выпуск: $BASE_URL"

	if [ "$PM" = "none" ] || [ -z "$ARCH" ] || [ -z "$PKG_EXT" ]; then
		err "менеджер пакетов и архитектура не определены (opkg/apk)"
		emit "CHECK_FAILED|stage:package_manager|reason:${PM:-none}"
		exit "$EX_PREFLIGHT"
	fi

	mkdir -p "$WORK"
	if ! fetch_release_asset SHA256SUMS "$WORK/SHA256SUMS"; then
		err "не удалось загрузить SHA256SUMS из $BASE_URL: $(fetch_fail_hint)"
		emit "CHECK_FAILED|stage:manifest|reason:${FETCH_ERR:-network}"
		exit "$EX_PREFLIGHT"
	fi
	if [ ! -s "$WORK/SHA256SUMS" ]; then
		err "SHA256SUMS пуст: выпуск неполный"
		emit "CHECK_FAILED|stage:manifest|reason:empty"
		exit "$EX_PREFLIGHT"
	fi

	ARCH_RE=$(printf '%s' "$ARCH" | sed 's/[][\\.^$*+?(){}|/]/\\&/g')
	_check_bad=0
	_check_summary=""
	_plan_parts=""
	for _cc in core panel; do
		case "$INSTALL_SET" in
		core) [ "$_cc" = panel ] && continue ;;
		panel) [ "$_cc" = core ] && continue ;;
		esac
		if [ "$_cc" = core ]; then
			escape_re "$CORE_PACKAGE"
			_cc_sel=$(pick_asset "^${RE_ESC}[_-]${ARCH_RE}[.]${PKG_EXT}\$")
			[ -n "$_cc_sel" ] || _cc_sel=$(pick_asset "^${RE_ESC}[_-].*[_-]${ARCH_RE}[.]${PKG_EXT}\$")
			_cc_inst=$(installed_version_of "$CORE_PACKAGE")
		else
			escape_re "$PANEL_PACKAGE"
			_cc_sel=$(pick_asset "^${RE_ESC}[_-]all[.]${PKG_EXT}\$")
			[ -n "$_cc_sel" ] || _cc_sel=$(pick_asset "^${RE_ESC}[_-].*[_-]all[.]${PKG_EXT}\$")
			_cc_inst=$(installed_version_of "$PANEL_PACKAGE")
		fi
		if [ "$_cc_sel" = "AMBIGUOUS" ]; then
			emit "CHECK|component:$_cc|installed:${_cc_inst:--}|state:ambiguous|ext:$PKG_EXT|series:${SERIES:--}"
			_check_bad=1
			_check_summary="$_check_summary $_cc:ambiguous"
			continue
		fi
		if [ -z "$_cc_sel" ]; then
			emit "CHECK|component:$_cc|installed:${_cc_inst:--}|state:no_package|arch:$ARCH|ext:$PKG_EXT|series:${SERIES:--}"
			_check_bad=1
			_check_summary="$_check_summary $_cc:no_package"
			continue
		fi
		if ! check_download "$_cc_sel"; then
			_if_hint=""
			[ "$CHECK_ERR" = download ] && _if_hint=": $(fetch_fail_hint)"
			err "не удалось получить $CHECK_ERR_NAME ($CHECK_ERR)$_if_hint"
			emit "CHECK_FAILED|stage:download|reason:$CHECK_ERR|name:$CHECK_ERR_NAME${CHECK_FETCH_ERR:+|fetch:$CHECK_FETCH_ERR}"
			_check_bad=1
			_check_summary="$_check_summary $_cc:download_$CHECK_ERR"
			continue
		fi
		_cc_name=$(printf '%s' "$_cc_sel" | awk '{print $2}')
		_cc_sha=$(printf '%s' "$_cc_sel" | awk '{print $1}')
		_cc_bytes=$(wc -c <"$WORK/$_cc_name" | awk '{print $1}')
		_cc_avail=$(pkg_version_of_file "$WORK/$_cc_name")
		if [ -z "$_cc_avail" ]; then
			_cc_state=unknown
		elif [ -z "$_cc_inst" ]; then
			_cc_state=not_installed
		else
			case "$(ver_cmp "$_cc_avail" "$_cc_inst")" in
			1) _cc_state=update ;;
			0) _cc_state=current ;;
			*) _cc_state=downgrade ;;
			esac
		fi
		emit "CHECK|component:$_cc|installed:${_cc_inst:--}|available:${_cc_avail:--}|state:$_cc_state|name:$_cc_name|sha256:$_cc_sha|bytes:${_cc_bytes:-0}"
		_plan_ok=1
		case "$_cc_name" in '' | *[!A-Za-z0-9._+~-]*) _plan_ok=0 ;; esac
		case "$_cc_sha" in *[!0-9a-f]*) _plan_ok=0 ;; esac
		case "$_cc_avail" in '' | *[!A-Za-z0-9._+~:-]*) _plan_ok=0 ;; esac
		case "$_cc_bytes" in '' | *[!0-9]*) _cc_bytes=0 ;; esac
		if [ "$_plan_ok" -eq 1 ]; then
			_plan_parts="$_plan_parts,\"$_cc\":{\"name\":\"$_cc_name\",\"sha256\":\"$_cc_sha\",\"available\":\"$_cc_avail\",\"state\":\"$_cc_state\",\"bytes\":$_cc_bytes}"
		fi
		_check_summary="$_check_summary $_cc:$_cc_state"
	done
	emit "CHECK_DONE|set:$INSTALL_SET|components:${_check_summary# }|bad:$_check_bad"
	[ "$_check_bad" -eq 0 ] && write_plan
	[ "$_check_bad" -eq 0 ] || exit "$EX_PREFLIGHT"
	return 0
}

cmd_inventory() {
	detect_pm_soft
	echo "Inventory установки CSQTT для OpenWrt (только чтение)" >&2
	printf '  Менеджер: %s%s; архитектура: %s\n' "$PM" "$([ -n "$PKG_EXT" ] && echo " (.$PKG_EXT)")" "${ARCH:-неизвестна}" >&2
	printf '  opkg: %s; apk: %s\n' "$HAVE_OPKG" "$HAVE_APK" >&2
	load_release
	printf '  Выпуск: %s\n' "$([ "$RELEASE_READY" -eq 1 ] && echo "$BASE_URL" || echo 'BLOCKED (owner/repo/tag не заданы)')" >&2
	printf '  Ядро: %s; установлено: %s\n' "$CORE_VERSION" "$(installed_version_of "$CORE_PACKAGE" 2>/dev/null || true)" >&2
	printf '  Панель: установлено: %s\n' "$(installed_version_of "$PANEL_PACKAGE" 2>/dev/null || true)" >&2
	printf '  /etc/config/csqtt: %s\n' "$([ -f "$CONFIG" ] && echo есть || echo нет)" >&2
	printf '  Служба включена: %s\n' "$(service_enabled && echo да || echo нет)" >&2
	emit "INVENTORY|pm:${PM:-none}|ext:${PKG_EXT:--}|arch:${ARCH:-unknown}|core:$(installed_version_of "$CORE_PACKAGE" 2>/dev/null || true)|panel:$(installed_version_of "$PANEL_PACKAGE" 2>/dev/null || true)|config:$([ -f "$CONFIG" ] && echo yes || echo no)|service:$(service_enabled && echo yes || echo no)"
	return 0
}

cmd_status() {
	detect_pm_soft
	echo "Статус установки CSQTT для OpenWrt" >&2
	printf '  Менеджер: %s (.%s), архитектура: %s\n' "$PM" "${PKG_EXT:--}" "${ARCH:-?}" >&2
	printf '  Ядро %s: %s\n' "$CORE_VERSION" "$(installed_version_of "$CORE_PACKAGE" 2>/dev/null || echo не установлено)" >&2
	printf '  Панель: %s\n' "$(installed_version_of "$PANEL_PACKAGE" 2>/dev/null || echo не установлена)" >&2
	printf '  Конфигурация: %s\n' "$([ -f "$CONFIG" ] && echo есть || echo нет)" >&2
	printf '  Служба включена: %s\n' "$(service_enabled && echo да || echo нет)" >&2
	printf '  Последний снимок: %s\n' "$(cat "$STATE_DIR/last-backup" 2>/dev/null || echo -)" >&2
	emit "STATUS|core:$(installed_version_of "$CORE_PACKAGE" 2>/dev/null || true)|panel:$(installed_version_of "$PANEL_PACKAGE" 2>/dev/null || true)"
	return 0
}

cmd_verify() {
	resolve_set
	detect_pm
	CFG_PRESENT_BEFORE=0
	[ -f "$CONFIG" ] && CFG_PRESENT_BEFORE=1
	CFG_SHA_BEFORE=$(config_sha)
	step "Проверка без изменений"
	if state_check "$INSTALL_SET"; then
		if [ "$STATE_RESULT" = "needs_setup" ]; then
			info "компоненты установлены, но требуется настройка: ${STATE_DETAIL:-профиль не задан}"
			emit "VERIFY_OK|$INSTALL_SET"
			emit "NEEDS_SETUP|$INSTALL_SET|${STATE_DETAIL:-profile}"
			return 0
		fi
		ok "Проверка пройдена: $INSTALL_SET"
		emit "VERIFY_OK|$INSTALL_SET"
		return 0
	fi
	err "Проверка не пройдена; изменения не вносились"
	emit "VERIFY_FAILED|$INSTALL_SET"
	return "$EX_PREFLIGHT"
}

activate_core253() {
	_ac_helper=/usr/lib/csqtt/core-2.5.3/activate.sh
	_ac_controller=/usr/lib/csqtt/core-2.5.3/bin/csqtt-control
	# The legacy engine runs in the controller provided by the 2.1.9 package.
	# Its activation helper also supports previously released 2.5.3 packages.
	if [ -f "$ROOT/usr/lib/csqtt/core-2.1.9/owns-controller" ]; then
		_ac_helper=/usr/lib/csqtt/core-2.1.9/activate.sh
		_ac_controller=/usr/lib/csqtt/core-2.1.9/bin/csqtt-control
	fi
	CSQTT_INSTALL_ROOT="$ROOT" sh "$ROOT$_ac_helper" install 2.5.3 &&
		[ "$(cat "$ROOT/usr/lib/csqtt/active" 2>/dev/null)" = 2.5.3 ] &&
		[ "$(readlink "$ROOT/usr/bin/csqtt" 2>/dev/null)" = "$_ac_controller" ]
}

# [058] Подготовка зависимостей внешней обёрткой (короткая установка).
# Короткий install-router.sh не знает состав до интерактивного меню, поэтому
# подготовка выполняется здесь: состав и менеджер пакетов уже определены, но
# никаких изменений ещё не было. Хук получает точный набор (только ядро не
# тянет LuCI) и либо готовит пакеты, либо отказывает кодом 66 — тогда
# установщик завершается успешно и ничего не меняет.
dep_prepare() {
	[ -n "${CSQTT_DEP_HOOK:-}" ] || return 0
	[ -f "$CSQTT_DEP_HOOK" ] ||
		die "не найден хук зависимостей: $CSQTT_DEP_HOOK" "$EX_PREFLIGHT"
	_dp_rc=0
	CSQTT_DEP_SET=$INSTALL_SET CSQTT_DEP_PM=${PM:-none} \
		CSQTT_DEP_ACTION=$_ci_mode CSQTT_DEP_CORE=$CORE_PACKAGE CSQTT_DEP_ARCH=$ARCH \
		sh "$CSQTT_DEP_HOOK" || _dp_rc=$?
	case "$_dp_rc" in
	0) return 0 ;;
	66)
		ok "установка отменена до изменений; зависимости не добавлены"
		return 66
		;;
	*)
		die "подготовка зависимостей не удалась (код $_dp_rc); проверьте сообщения восстановления" \
			"$EX_PREFLIGHT"
		;;
	esac
}

cmd_install() { # cmd_install install|update
	_ci_mode=$1
	resolve_set
	require_release
	detect_pm
	detect_series

	validate_pins
	take_lock
	keep_core253=0
	if [ "$CORE_VERSION" = 2.1.9 ] && [ -n "$(installed_version_of csqtt-core-2.5.3)" ]; then
		[ -r "$ROOT/usr/lib/csqtt/core-2.5.3/activate.sh" ] &&
			[ -x "$ROOT/usr/lib/csqtt/core-2.5.3/bin/csqtt-control" ] ||
			die "у установленного 2.5.3 нет полного управляющего слоя; установка отменена" "$EX_PREFLIGHT"
		keep_core253=1
	fi
	fetch_manifest
	ARCH_RE=$(printf '%s' "$ARCH" | sed 's/[][\\.^$*+?(){}|/]/\\&/g')
	SELECTED_CORE=""
	SELECTED_PANEL=""
	FILES=""
	if [ "$INSTALL_SET" = "core" ] || [ "$INSTALL_SET" = "both" ]; then
		if [ -n "$PIN_NAME" ]; then
			[ "$INSTALL_SET" = "core" ] || die "--pin-* несовместимы с --set both: привязка только к одному компоненту" "$EX_USAGE"
			pin_asset "ядро"
			SELECTED_CORE="$PIN_ASSET"
		else
			select_core
		fi
		[ -n "$SELECTED_CORE" ] || die "в SHA256SUMS нет ядра $CORE_PACKAGE для архитектуры $ARCH (.$PKG_EXT); неверный ABI или неполный выпуск" "$EX_PREFLIGHT"
		download_asset "$SELECTED_CORE" "ядро"
		[ -n "$PIN_NAME" ] && verify_pinned_pkg "$PIN_NAME"
		FILES="$FILES $(printf '%s' "$SELECTED_CORE" | awk '{print $2}')"
	fi
	if [ "$INSTALL_SET" = "panel" ] || [ "$INSTALL_SET" = "both" ]; then
		if [ -n "$PIN_NAME" ]; then
			[ "$INSTALL_SET" = "panel" ] || die "--pin-* несовместимы с --set both: привязка только к одному компоненту" "$EX_USAGE"
			pin_asset "панель"
			SELECTED_PANEL="$PIN_ASSET"
		else
			select_panel
		fi
		[ -n "$SELECTED_PANEL" ] || die "в SHA256SUMS нет панели $PANEL_PACKAGE (all) для .$PKG_EXT; неполный выпуск" "$EX_PREFLIGHT"
		download_asset "$SELECTED_PANEL" "панель"
		[ -n "$PIN_NAME" ] && verify_pinned_pkg "$PIN_NAME"
		FILES="$FILES $(printf '%s' "$SELECTED_PANEL" | awk '{print $2}')"
	fi

	if [ "$_ci_mode" = "update" ]; then
		if [ "$INSTALL_SET" = "core" ] && [ -z "$(installed_version_of "$CORE_PACKAGE")" ]; then
			die "update: ядро $CORE_PACKAGE не установлено; для первой установки используйте install" "$EX_PREFLIGHT"
		fi
		if [ "$INSTALL_SET" = "panel" ] && [ -z "$(installed_version_of "$PANEL_PACKAGE")" ]; then
			die "update: панель $PANEL_PACKAGE не установлена; для первой установки используйте install" "$EX_PREFLIGHT"
		fi
	fi

	# В интерактивном меню актуальный компонент не переустанавливается.
	# Прямой install сохраняет прежнюю семантику восстановления пакета.
	if [ "$MENU" -eq 1 ]; then
		_ci_pending=""
		_ci_effective=""
		for _ci_file in $FILES; do
			case "$_ci_file" in
			luci-app-*) _ci_pkg=$PANEL_PACKAGE; _ci_label="панель" ;;
			*) _ci_pkg=$CORE_PACKAGE; _ci_label="ядро" ;;
			esac
			_ci_inst=$(installed_version_of "$_ci_pkg")
			_ci_avail=$(pkg_version_of_file "$WORK/$_ci_file")
			if [ -n "$_ci_inst" ] && [ -n "$_ci_avail" ]; then
				case "$(ver_cmp "$_ci_avail" "$_ci_inst")" in
				0)
					ok "$_ci_label: актуальная версия уже установлена"
					case "$_ci_pkg" in
					"$PANEL_PACKAGE") SELECTED_PANEL="" ;;
					*) SELECTED_CORE="" ;;
					esac
					continue ;;
				1) ok "$_ci_label: доступно обновление" ;;
				*) die "$_ci_label: установленная версия новее выпуска; автоматическое понижение отменено" "$EX_PREFLIGHT" ;;
				esac
			else
				ok "$_ci_label: требуется установка"
			fi
			_ci_pending="$_ci_pending $_ci_file"
			case "$_ci_pkg" in
			"$PANEL_PACKAGE") _ci_part=panel ;;
			*) _ci_part=core ;;
			esac
			if [ -z "$_ci_effective" ]; then _ci_effective=$_ci_part; else _ci_effective=both; fi
		done
		FILES=$_ci_pending
		if [ -z "$FILES" ]; then
			ok "Всё уже установлено; обновление не требуется"
			if [ "$DRY_RUN" -eq 1 ]; then emit "DRY_RUN|$INSTALL_SET"; else emit "CURRENT|$INSTALL_SET"; fi
			return 0
		fi
		# Только обновление панели не должно перезапускать актуальное ядро.
		[ "$DRY_RUN" -eq 1 ] || INSTALL_SET=$_ci_effective
	fi

	step "Проверка свободного места"
	space_preflight

	# Зависимости добавляются после проверки файлов, SHA, версий и места.
	if [ "$DRY_RUN" -eq 0 ] && ! dep_prepare; then
		return 0
	fi

	step "Проверка совместимости набора ($PM)"
	if ! pm_dry_run_selected; then
		die "сухой прогон $PM отверг набор (неверный ABI, зависимости или версия); изменения не вносились" "$EX_PREFLIGHT"
	fi
	ok "набор разрешается без изменений"

	step "План"
	[ -n "$SELECTED_CORE" ] && ok "ядро: $(printf '%s' "$SELECTED_CORE" | awk '{print $2}')"
	[ -n "$SELECTED_PANEL" ] && ok "панель: $(printf '%s' "$SELECTED_PANEL" | awk '{print $2}')"
	ok "состав: $INSTALL_SET; конфигурация /etc/config/csqtt сохраняется"

	if [ "$DRY_RUN" -eq 1 ]; then
		ok "dry-run: изменения не вносились"
		emit "DRY_RUN|$INSTALL_SET"
		return 0
	fi

	confirm "Установить/обновить CSQTT ($INSTALL_SET) и перезапустить службу при необходимости?"

	ensure_state
	CFG_PRESENT_BEFORE=0
	[ -f "$CONFIG" ] && CFG_PRESENT_BEFORE=1
	CFG_SHA_BEFORE=$(config_sha)
	BACKUP=$(make_backup "$_ci_mode") || die "не удалось создать снимок для отката; изменения не вносились" "$EX_FAILED"
	step "Снимок состояния: $BACKUP"
	printf '%s\n' "$BACKUP" >"$STATE_DIR/last-backup"
	if [ "$INSTALL_SET" != panel ] && [ "$CORE_VERSION" = 2.5.3 ] &&
	   [ -n "$(installed_version_of "$CORE_PACKAGE")" ] &&
	   [ -f "$ROOT/usr/lib/csqtt/core-2.1.9/owns-controller" ]; then
		keep_core253=1
	fi
	[ "$keep_core253" -eq 0 ] || : >"$BACKUP/keep_core253"

	# shellcheck disable=SC2086
	_pm_ok=0
	if pm_install_selected; then
		_pm_ok=1
	fi
	if [ "$_pm_ok" -eq 1 ] && [ "$keep_core253" -eq 1 ]; then
		activate_core253 || _pm_ok=0
	fi
	# Шаблон, созданный postinst, фиксируется сразу после установки. Откат
	# вправе удалить только его и только если он не изменился после этого.
	note_created_config "$BACKUP" ||
		warn "не удалось зафиксировать созданную конфигурацию; откат не будет её удалять"
	if [ "$_pm_ok" -eq 0 ]; then
		err "$PM не установил набор или не удалось восстановить управляющий слой 2.5.3"
		if restore_snapshot "$BACKUP" && verify_restored "$BACKUP"; then
			if [ -n "$RESTORE_INCOMPLETE" ]; then
				warn "пакеты восстановлены, но возврат неполный: $RESTORE_INCOMPLETE"
				warn "снимок сохранён: $BACKUP; требуется ручное решение"
				emit "RESTORE_INCOMPLETE|$BACKUP|$RESTORE_INCOMPLETE"
				exit "$EX_RECOVERED"
			fi
			pm_db_consistent "$BACKUP"
			case "$?" in
			0) ;;
			1) warn "обнаружено расхождение базы $PM с восстановленными файлами; проверьте: $PM list-installed" ;;
			*) warn "не удалось проверить согласованность базы $PM с файлами; проверьте вручную" ;;
			esac
			warn "прежнее состояние восстановлено из $BACKUP"
			emit "ROLLED_BACK|$BACKUP"
			exit "$EX_RECOVERED"
		fi
		die "установка и восстановление не удались; ручной откат: $0 rollback --backup $BACKUP" "$EX_FAILED"
	fi

	_ci_service_failed=0
	if [ "$INSTALL_SET" != panel ]; then
		readiness_capture
		restart_service || _ci_service_failed=1
	fi
	if [ "$_ci_service_failed" -eq 1 ]; then
		# [AUDIT BUG-02] Не «OK» и не откат: пакеты и конфигурация на месте,
		# но движок не работает. Отдельный код и маркер для вызывающего.
		err "пакеты установлены, но служба не запустилась; конфигурация и снимок $BACKUP сохранены"
		emit "INSTALLED_SERVICE_FAILED|$INSTALL_SET"
		exit "$EX_SERVICE"
	fi

	step "Проверка после установки"
	if state_check "$INSTALL_SET"; then
		if [ "$STATE_RESULT" = "needs_setup" ]; then
			ok "Установка завершена: $INSTALL_SET (требуется настройка)"
			ok "Снимок для отката: $BACKUP"
			if [ "$CFG_PRESENT_BEFORE" -eq 0 ] || [ "$CFG_STATE" != "disabled" ]; then
				log "Установлено. Добавьте сервер и включите подключение"
			else
				log "Установлено. Подключение выключено; включите его после добавления сервера."
			fi
			emit "OK|$INSTALL_SET"
			emit "NEEDS_SETUP|$INSTALL_SET|${STATE_DETAIL:-profile}"
			return 0
		fi
		ok "Установка завершена: $INSTALL_SET"
		ok "Снимок для отката: $BACKUP"
		emit "OK|$INSTALL_SET"
		return 0
	fi

	err "проверка после установки не пройдена"
	if restore_snapshot "$BACKUP" && verify_restored "$BACKUP"; then
		if [ -n "$RESTORE_INCOMPLETE" ]; then
			warn "пакеты и версии восстановлены, но возврат неполный: $RESTORE_INCOMPLETE"
			warn "снимок сохранён: $BACKUP; требуется ручное решение"
			emit "RESTORE_INCOMPLETE|$BACKUP|$RESTORE_INCOMPLETE"
			exit "$EX_RECOVERED"
		fi
		pm_db_consistent "$BACKUP"
		case "$?" in
		0) ;;
		1) warn "обнаружено расхождение базы $PM с восстановленными файлами; проверьте: $PM list-installed" ;;
		*) warn "не удалось проверить согласованность базы $PM с файлами; проверьте вручную" ;;
		esac
		warn "прежнее состояние восстановлено: $BACKUP"
		emit "ROLLED_BACK|$BACKUP"
		exit "$EX_RECOVERED"
	fi
	die "откат не удался; ручная команда: $0 rollback --backup $BACKUP" "$EX_FAILED"
}

cmd_rollback() {
	detect_pm
	_rb_dir=$BACKUP_ARG
	[ -n "$_rb_dir" ] || _rb_dir=$(cat "$STATE_DIR/last-backup" 2>/dev/null || true)
	[ -n "$_rb_dir" ] || die "не указан снимок: --backup DIR (нет и last-backup)" "$EX_USAGE"
	[ -d "$_rb_dir" ] || die "каталог снимка не найден: $_rb_dir" "$EX_USAGE"
	case "$(cat "$_rb_dir/core_package" 2>/dev/null || true)" in
	csqtt-core-2.1.9) CORE_PACKAGE=csqtt-core-2.1.9 ;;
	esac
	if [ "$DRY_RUN" -eq 1 ]; then
		ok "dry-run: будет восстановлен снимок $_rb_dir"
		emit "DRY_RUN|rollback"
		return 0
	fi
	confirm "Восстановить файлы и /etc/config/csqtt из $_rb_dir?"
	take_lock
	stop_service
	if restore_snapshot "$_rb_dir" && verify_restored "$_rb_dir"; then
		if [ -n "$RESTORE_INCOMPLETE" ]; then
			warn "откат неполный: $RESTORE_INCOMPLETE"
			warn "снимок сохранён: $_rb_dir; требуется ручное решение"
			emit "RESTORE_INCOMPLETE|$_rb_dir|$RESTORE_INCOMPLETE"
			return "$EX_RECOVERED"
		fi
		pm_db_consistent "$_rb_dir"
		case "$?" in
		0) ;;
		1) warn "обнаружено расхождение базы $PM с восстановленными файлами; проверьте: $PM list-installed" ;;
		*) warn "не удалось проверить согласованность базы $PM с файлами; проверьте вручную" ;;
		esac
		ok "Откат выполнен: $_rb_dir"
		emit "ROLLED_BACK|$_rb_dir"
		return 0
	fi
	die "откат не удался; снимок сохранён: $_rb_dir" "$EX_FAILED"
}

cmd_uninstall() {
	resolve_set
	detect_pm
	if [ "$PURGE" -eq 1 ] && [ "$INSTALL_SET" = "panel" ]; then
		die "--purge с --set panel удалил бы /etc/config/csqtt при установленном ядре; используйте --set both или сначала удалите ядро" "$EX_USAGE"
	fi
	_ui_cores="csqtt-core-2.1.9 csqtt-core-2.5.3"
	[ -z "$CORE_BRANCH" ] || _ui_cores=$CORE_PACKAGE
	_ui_selected=""
	if [ "$INSTALL_SET" = panel ] || [ "$INSTALL_SET" = both ]; then
		_ui_selected=$PANEL_PACKAGE
	fi
	if [ "$INSTALL_SET" = core ] || [ "$INSTALL_SET" = both ]; then
		_ui_selected="$_ui_selected $_ui_cores"
	fi
	# [AUDIT BUG-04] --purge удаляет общий /etc/config/csqtt (профили, секреты,
	# device_id). Если после удаления выбранного набора остаются другие
	# компоненты, конфиг им ещё нужен: блокируем до изменений.
	if [ "$PURGE" -eq 1 ]; then
		_ui_left=""
		for _ui_lp in csqtt-core-2.1.9 csqtt-core-2.5.3 "$PANEL_PACKAGE"; do
			case " $_ui_selected " in *" $_ui_lp "*) continue ;; esac
			[ -z "$(installed_version_of "$_ui_lp")" ] || _ui_left="$_ui_left $_ui_lp"
		done
		if [ -n "$_ui_left" ]; then
			die "--purge удалил бы общий /etc/config/csqtt, но остаются компоненты:${_ui_left}; удалите их вместе (--set both) или выполните удаление без --purge" "$EX_USAGE"
		fi
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		ok "dry-run: будут удалены: $_ui_selected"
		ok "конфигурация /etc/config/csqtt сохраняется$([ "$PURGE" -eq 1 ] && echo ' (--purge: будет удалена)')"
		emit "DRY_RUN|uninstall|$INSTALL_SET"
		return 0
	fi
	take_lock
	_ui_present=0
	for _ui_pkg in $_ui_selected; do
		[ -z "$(installed_version_of "$_ui_pkg")" ] || _ui_present=1
	done
	if [ "$_ui_present" -eq 0 ] && [ "$PURGE" -eq 0 ]; then
		ok "Выбранные компоненты уже отсутствуют; изменений не требуется"
		emit "UNINSTALLED|$INSTALL_SET"
		return 0
	fi
	confirm "Удалить $_ui_selected? Конфигурация сохраняется, если не указан --purge."
	ensure_state
	# [AUDIT BUG-06] Снимок обязателен и для удаления: без него нет отката.
	# Прежний `|| true` продолжал удаление без копии.
	BACKUP=$(make_backup "uninstall") ||
		die "не удалось создать снимок для отката; удаление отменено, изменения не вносились" "$EX_FAILED"
	printf '%s\n' "$BACKUP" >"$STATE_DIR/last-backup"
	# Служба работала до удаления? Тогда оставшееся ядро должно снова её
	# поднять: postrm останавливает службу, а пользователь ждёт рабочий движок.
	_ui_was_running=0
	if [ "$INSTALL_SET" != panel ] && service_running; then _ui_was_running=1; fi
	[ "$INSTALL_SET" = panel ] || stop_service
	_ui_fail=0
	if [ "$INSTALL_SET" = "panel" ] || [ "$INSTALL_SET" = "both" ]; then
		if [ -n "$(installed_version_of "$PANEL_PACKAGE")" ]; then
			pm_remove "$PANEL_PACKAGE" || _ui_fail=1
		fi
	fi
	if [ "$INSTALL_SET" = "core" ] || [ "$INSTALL_SET" = "both" ]; then
		# [057] Явный --core-version 2.1.9 удаляет только это ядро; без него
		# (меню или обычный --set core) удаляются оба возможных ядра, чтобы
		# установленное ядро не осталось незамеченным.
		for _ui_cp in $_ui_cores; do
			[ -n "$(installed_version_of "$_ui_cp")" ] || continue
			pm_remove "$_ui_cp" || _ui_fail=1
		done
	fi
	[ "$_ui_fail" -eq 0 ] || die "удаление завершилось ошибкой $PM; конфигурация не тронута" "$EX_FAILED"
	if [ "$INSTALL_SET" = "panel" ] || [ "$INSTALL_SET" = "both" ]; then
		[ -z "$(installed_version_of "$PANEL_PACKAGE")" ] || {
			err "панель $PANEL_PACKAGE всё ещё числится установленной"
			_ui_fail=1
		}
	fi
	if [ "$INSTALL_SET" = "core" ] || [ "$INSTALL_SET" = "both" ]; then
		for _ui_cp in $_ui_cores; do
			[ -z "$(installed_version_of "$_ui_cp")" ] || {
				err "ядро $_ui_cp всё ещё числится установленным"
				_ui_fail=1
			}
		done
	fi
	[ "$_ui_fail" -eq 0 ] || die "проверка удаления не пройдена; конфигурация не тронута" "$EX_FAILED"
	# [057] Удаление одного ядра не должно оставлять службу остановленной:
	# postrm остановил её, а общие точки входа переключились на оставшееся
	# ядро. Перезапускаем только если ядро действительно осталось; после
	# удаления последнего ядра службы нет — это правильное состояние.
	if [ "$_ui_was_running" -eq 1 ] &&
	   { [ -x "$ROOT/usr/lib/csqtt/core-2.1.9/etc/init.d/csqtt" ] ||
	     [ -x "$ROOT/usr/lib/csqtt/core-2.5.3/etc/init.d/csqtt" ]; }; then
		restart_service
	fi
	if [ "$PURGE" -eq 1 ]; then
		rm -f "$CONFIG"
		rm -rf "$STATE_DIR"
		ok "конфигурация и состояние удалены (--purge)"
	else
		ok "конфигурация сохранена: $CONFIG"
	fi
	emit "UNINSTALLED|$INSTALL_SET"
	return 0
}

main() {
	parse_args "$@"
	if [ "$KEEP_STOPPED" -eq 1 ] && [ "$ACTION" != uninstall ]; then
		die "--keep-stopped поддерживается только для uninstall" "$EX_USAGE"
	fi
	case "$ACTION:$MENU" in
		install:1|update:1|check:1|uninstall:1) menu_select ;;
	esac
	if [ -n "$CORE_BRANCH" ]; then
		case "$CORE_BRANCH" in
		2.1.9 | 2.5.3) ;;
		*) die "--core-version поддерживает 2.1.9|2.5.3 (получено: $CORE_BRANCH)" "$EX_USAGE" ;;
		esac
		case "$ACTION:$INSTALL_SET" in
		check:core | check:both | install:core | install:both | update:core | update:both | uninstall:core | uninstall:both) ;;
		*) die "--core-version $CORE_BRANCH поддерживается только для check/install/update/uninstall --set core|both" "$EX_USAGE" ;;
		esac
		case "$CORE_BRANCH" in
		2.1.9)
			CORE_VERSION=2.1.9
			CORE_PACKAGE=csqtt-core-2.1.9
			;;
		2.5.3)
			CORE_VERSION=2.5.3
			CORE_PACKAGE=csqtt-core-2.5.3
			;;
		esac
	fi
	case "$ACTION" in
	help) usage; exit "$EX_OK" ;;
	esac
	case "$ACTION" in
	inventory) cmd_inventory ;;
	status) cmd_status ;;
	verify) cmd_verify ;;
	check) cmd_check ;;
	install) cmd_install install ;;
	update) cmd_install update ;;
	rollback) cmd_rollback ;;
	uninstall) cmd_uninstall ;;
	*)
		usage >&2
		die "неизвестное действие: $ACTION" "$EX_USAGE"
		;;
	esac
}

main "$@"
