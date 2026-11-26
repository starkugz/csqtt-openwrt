[![Поддержать проект · USDT](https://img.shields.io/badge/%D0%9F%D0%BE%D0%B4%D0%B4%D0%B5%D1%80%D0%B6%D0%B0%D1%82%D1%8C%20%D0%BF%D1%80%D0%BE%D0%B5%D0%BA%D1%82-USDT-e83e8c?style=for-the-badge&logo=tether&logoColor=white)](https://github.com/starkugz/csqtt-openwrt/blob/main/docs/common/support.md)

| Сеть | Адрес USDT |
|---|---|
| <img src="https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ton/info/logo.png" width="18" height="18" alt="TON"> TON | `UQBnHRqEArYe9Bcr9IEnowbUIMbqhqFXaazyexZ526-UFmFq` |
| <img src="https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/tron/info/logo.png" width="18" height="18" alt="Tron / TRC-20"> Tron / TRC-20 | `TPRwuz9935hxvKWHDoaP8ZLNA4zxj5N9kH` |
| <img src="https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/info/logo.png" width="18" height="18" alt="Ethereum / ERC-20"> Ethereum / ERC-20 | `0x7AF71AE59473950C35Cbbe0C5bdE1EA2F0760AdF` |
| <img src="https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/solana/info/logo.png" width="18" height="18" alt="Solana / SPL"> Solana / SPL | `4QAEDtzTnX57vah1cG7j7XTAqei6j1opZw9Kb5LLH9bH` |

# CSQTT для OpenWrt

[![Release](https://img.shields.io/github/v/release/starkugz/csqtt-openwrt?label=release&color=2583e9)](https://github.com/starkugz/csqtt-openwrt/releases/latest)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10%20%7C%2025.12-00a6c4)](docs/v2.5/install.md#пакеты-openwrt)
[![Architectures](https://img.shields.io/badge/CPU-AArch64%20%7C%20ARMv7%20%7C%20x86--64%20%7C%20MIPSel-6366f1)](docs/v2.5/install.md#пакеты-openwrt)
[![License](https://img.shields.io/badge/License-PolyForm%20Noncommercial-80a820)](LICENSE)

Туннель CSQTT для OpenWrt с панелью LuCI. Клиентские ядра **2.5.3** и **2.1.9**,
панель **CSQTT 2.5**. Настройка серверов, управление подключением и обновления в LuCI.

## Роутер OpenWrt

Выполните по SSH от root. В каждом меню можно выбрать панель, нужное ядро или комплект.

**Текущий комплект: панель CSQTT 2.5 и ядра 2.1.9 / 2.5.3.**

```sh
(
  f=$(mktemp) || exit 1
  trap 'rm -f "$f"' EXIT
  url=https://raw.githubusercontent.com/starkugz/csqtt-openwrt/refs/heads/main/install.sh
  if { curl -fsSL --connect-timeout 15 --max-time 60 -o "$f" "$url" && [ -s "$f" ]; } ||
     { : >"$f"; wget -T 30 -O "$f" "$url" && [ -s "$f" ]; } ||
     { : >"$f"; uclient-fetch -T 30 -O "$f" "$url" && [ -s "$f" ]; }; then
    ash "$f"
  else
    printf '%s\n' 'Не удалось скачать установщик CSQTT.' >&2
    exit 1
  fi
)
```

[Инструкция 2.5](docs/v2.5/README.md).

## Сервер Linux / VPS

Выполните от root на Linux с systemd. Установщик предложит подходящую версию сервера.

```sh
curl -fsSL https://raw.githubusercontent.com/starkugz/csqtt-openwrt/main/install.sh | sh
```

Если вы вошли обычным пользователем и используете `sudo`, замените `| sh` на `| sudo sh`.

[Инструкция OpenWrt](docs/v2.5/install.md) ·
[Инструкция VPS](docs/v2.5/server.md) ·
[Все инструкции](docs/README.md) ·
[Пакеты APK/IPK](https://github.com/starkugz/csqtt-openwrt/releases/latest)

Исходный проект — amurcanov. Интеграция OpenWrt и панель — starkugz.
[Лицензия](LICENSE) · [Уведомления](NOTICE.md)
