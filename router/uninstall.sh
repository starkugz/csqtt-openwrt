#!/bin/sh
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
set -eu
umask 077
file=$(mktemp)
trap 'rm -f -- "$file"' EXIT
url=https://github.com/starkugz/csqtt-openwrt/releases/download/v2.5.3/install-router.sh
wget -q -O "$file" "$url"
printf '%s  %s\n' f8a69518e2df17b369ff373215fa8ead81c41286c841ab55b7746f924940c337 "$file" | sha256sum -c -
sh "$file" uninstall --set both "$@"
