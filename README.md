[![Поддержать проект · USDT](https://img.shields.io/badge/%D0%9F%D0%BE%D0%B4%D0%B4%D0%B5%D1%80%D0%B6%D0%B0%D1%82%D1%8C%20%D0%BF%D1%80%D0%BE%D0%B5%D0%BA%D1%82-USDT-e83e8c?style=for-the-badge&logo=tether&logoColor=white)](https://github.com/starkugz/csqtt-openwrt/blob/main/docs/support.md)

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
