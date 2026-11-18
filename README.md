<details>
<summary>Поддержать проект</summary>

Помочь разработчику можно переводом USDT в выбранной сети.

| Сеть | Адрес USDT |
|---|---|
| <img src="https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ton/info/logo.png" width="18" height="18" alt="TON"> TON | `UQBnHRqEArYe9Bcr9IEnowbUIMbqhqFXaazyexZ526-UFmFq` |
| <img src="https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/tron/info/logo.png" width="18" height="18" alt="Tron / TRC-20"> Tron / TRC-20 | `TPRwuz9935hxvKWHDoaP8ZLNA4zxj5N9kH` |
| <img src="https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/info/logo.png" width="18" height="18" alt="Ethereum / ERC-20"> Ethereum / ERC-20 | `0x7AF71AE59473950C35Cbbe0C5bdE1EA2F0760AdF` |
| <img src="https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/solana/info/logo.png" width="18" height="18" alt="Solana / SPL"> Solana / SPL | `4QAEDtzTnX57vah1cG7j7XTAqei6j1opZw9Kb5LLH9bH` |

</details>

# CSQTT для OpenWrt

[![Release](https://img.shields.io/github/v/release/starkugz/csqtt-openwrt?label=release&color=2583e9)](https://github.com/starkugz/csqtt-openwrt/releases/latest)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10%20%7C%2025.12-00a6c4)](docs/install-v2.5.3.md#пакеты-openwrt)
[![Architectures](https://img.shields.io/badge/CPU-AArch64%20%7C%20ARMv7%20%7C%20x86--64%20%7C%20MIPSel-6366f1)](docs/install-v2.5.3.md#пакеты-openwrt)
[![License](https://img.shields.io/badge/License-PolyForm%20Noncommercial-80a820)](LICENSE)

Туннель CSQTT для OpenWrt с панелью LuCI. Клиентские ядра **2.5.3** и **2.1.9**,
панель **CSQTT 2.5**. Настройка серверов, управление подключением и обновления в LuCI.

## Роутер OpenWrt

Выполните по SSH от root. В меню выберите панель, ядро или комплект.

```sh
wget -T 30 -qO- https://raw.githubusercontent.com/starkugz/csqtt-openwrt/main/install.sh | ash
```

## Сервер Linux / VPS

Выполните на Linux с systemd. Установщик предложит подходящую версию сервера.

```sh
curl -fsSL https://raw.githubusercontent.com/starkugz/csqtt-openwrt/main/install.sh | sudo sh
```

[Инструкция OpenWrt](docs/install-v2.5.3.md) ·
[Инструкция VPS](docs/server-v2.5.3.md) ·
[Все инструкции](docs/README.md) ·
[Пакеты APK/IPK](https://github.com/starkugz/csqtt-openwrt/releases/latest)

Исходный проект — amurcanov. Интеграция OpenWrt и панель — starkugz.
[Лицензия](LICENSE) · [Уведомления](NOTICE.md)
