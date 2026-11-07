# Расширенные настройки и возможности

Для тех, кому нужно настроить CSQTT подробнее. Назначение страниц панели — в
[панели LuCI](luci.md).

## Возможности

- Хранить несколько сохранённых серверов и переключаться между ними: выбор по
  приоритету или вручную, переключение на резервный сервер при сбое
  (`failover`), возврат обратно (`failback`), пауза перед повторной попыткой
  (`cooldown`) и повторные подключения.
- Проверять подключение (health-check) по `transport` / `data` / `both`, с
  порогами и интервалом проверки.
- Авторизоваться в VK в режимах `vkcalls` (VK-хеши и ссылки `vk.com/call/join`),
  `auto_js` (по токену VK) и `auto_api` (ядро само создаёт звонки по токену).
- Задавать каналы с учётом ядра: 2.1.9 — группы по 9, максимум 126;
  2.5.1 — группы по 10, максимум 100. Обфускация — `audio` / `video`,
  дополнительно `unified` для 2.5.1; TURN — `udp` / `tcp_tls`.
- Проходить CAPTCHA (встроенный решатель и локальная страница для телефона в
  той же сети — Web Helper).
- Проверять доступ через `csqtt0` активным запросом к выбранной цели.

## Настройки (UCI `/etc/config/csqtt`)

### Глобальные (`config csqtt 'main'`)

| UCI | Тип | Дефолт | Влияние |
|---|---|---|---|
| `enabled` | bool | `0` | Служба/автозапуск туннеля |
| `ifname` | `csqtt<0..999>` | `csqtt0` | TUN-интерфейс единственного экземпляра |
| `core_version` | `auto\|2.1.9\|2.5.0` | `auto` | совместимость старых схем; в схеме 3 версия задаётся в профиле |
| `persistent_tun` | bool | `0` | постоянный `csqtt0` при выключенной службе |
| `selection_mode` | `priority\|manual` | `priority` | выбор профиля |
| `active_profile` | section id | `''` | активный профиль (для `manual`) |
| `failover` | bool | `1` | автоматическое переключение |
| `failback` | bool | `0` | автоматический возврат |
| `health_interval` | u64 сек | `5` | период health-тика |
| `fail_threshold` | u32 | `3` | неудач до unhealthy |
| `success_threshold` | u32 | `2` | успехов до восстановления |
| `cooldown` | u64 сек | `60` | пауза после отказа |
| `reconnect_delay` | u64 сек | `5` | пауза между попытками |
| `failback_stable_time` | u64 сек | `60` | стабильность перед failback |
| `health_mode` | `transport\|data\|both` | `both` | сигналы здоровья |
| `health_target` | `host[:port]` или URL | `''` | доп. цель проверки через `csqtt0` |
| `captcha_policy` | `failover\|wait` | `failover` | поведение при CAPTCHA_REQUIRED |
| `log_level` | `error\|warn\|info\|debug` | `info` | детализация лога |
| `log_file` | path | `/var/log/csqtt.log` | файл журнала |
| `log_size_kb` | u64 KiB | `512` | порог ротации |

> `log_level` — ровно `error|warn|info|debug` (без `trace`). CSQTT **не**
> меняет системный DNS OpenWrt/dnsmasq.

### Параметры профиля (`config server '<id>'`, схема 3)

Новые установки используют `main.schema_version=3`: настройки профилей
независимы и не наследуются из `main`. В каждом профиле задаются
`core_version`, `workers`, `obfs`, `srtp_mode`, `turn_transport`, `vk_hash_mode`,
`vk_auth_mode`, `vk`, `vk_js_token`, `device_id`, `captcha_mode`, `fingerprint`,
`client_ids`, пароль, а также `tun_address`, `tun_mtu`, `dns`. Пустые поля
пароля, VK-хеша, VK-токена и идентификатора сохраняют прежние значения.

Для схемы 1/2 сначала обновляются ядро и панель, затем применяется
`/usr/libexec/csqtt/migrate-profile-settings.sh --apply` (или кнопка переноса в
панели). Скрипт копирует действующие настройки в каждый профиль, делает
резервную копию `0600` и выставляет схему 3. Без `--apply` — только проверка.

## Управление из CLI

```sh
csqtt status             # 0 подключён / 1 нет / 2 служба не запущена
csqtt doctor             # read-only диагностика: конфиг, TUN, peer, rp_filter
csqtt doctor --pre-launch
csqtt profile list
csqtt profile use <id>
csqtt profile import 'csqtt://connect?...' --commit
csqtt log tail -n 50 -f
csqtt version            # версия движка
```

Без подкоманды `csqtt` работает в ручном режиме прямых флагов. Полный список —
`csqtt --help`.

## Типовые операции без LuCI

```sh
# включить службу и автозапуск:
uci set csqtt.main.enabled='1'
uci commit csqtt
service csqtt enable
service csqtt start

# выбрать ядро конкретного профиля (ID возьмите из csqtt profile list):
csqtt profile set myserver core_version 2.5.0
csqtt profile use myserver
service csqtt restart

# постоянный csqtt0:
uci set csqtt.main.persistent_tun='1'
uci commit csqtt
service csqtt reload
```

## Воркеры и обфускация

- `workers` — `9..126`; значения нормализуются к ближайшему кратному 9
  (максимум 126).
- `obfs` — `audio`, `video` или `unified` (последний только для 2.5.1); TURN — `udp` или `tcp_tls`.
- При периодических тайм-аутах подбирайте `obfs` и `workers` по рекомендации
  владельца сервера.
