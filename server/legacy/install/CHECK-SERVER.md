# Установка и проверка двух серверных вариантов

Команды ниже — для **Linux x86-64 с systemd**, выполняются из корня
распакованного Release, где рядом лежат `server-install.sh`, `server-deploy.sh`
и каталог `server/`. На OpenWrt их выполнять нельзя.

Перед изменением действующего сервера сохраните приватную копию конфигурации,
бинарника, unit и сетевого состояния. Не публикуйте её. Существующий device_id
и учётные данные сохраняются; отсутствие этих данных требует отдельной
первоначальной настройки. Две установки ниже — альтернативы, не команда
выполнять обе подряд. При проверке обеих версий сначала согласуйте итоговую.

## Проверка загруженного комплекта

```sh
sha256sum -c SHA256SUMS
(cd server && sha256sum -c csqtt-server-linux-amd64-2.1.9.sha256)
(cd server && sha256sum -c csqtt-server-linux-amd64-2.5.1.sha256)
```

## Вариант 1 — сервер 2.1.9

```sh
sudo bash server-install.sh preflight \
  --binary ./server/csqtt-server-linux-amd64-2.1.9 \
  --sha256-file ./server/csqtt-server-linux-amd64-2.1.9.sha256
sudo bash server-install.sh install \
  --binary ./server/csqtt-server-linux-amd64-2.1.9 \
  --sha256-file ./server/csqtt-server-linux-amd64-2.1.9.sha256 --yes
sudo bash server-install.sh verify \
  --sha256 9740816075518c9d1d09524db0a9abb48a73b554a8dba6963f40b800ce65f9d3
```

## Вариант 2 — сервер 2.5.1

```sh
sudo bash server-install.sh preflight \
  --binary ./server/csqtt-server-linux-amd64-2.5.1 \
  --sha256-file ./server/csqtt-server-linux-amd64-2.5.1.sha256
sudo bash server-install.sh install \
  --binary ./server/csqtt-server-linux-amd64-2.5.1 \
  --sha256-file ./server/csqtt-server-linux-amd64-2.5.1.sha256 --yes
sudo bash server-install.sh verify \
  --sha256 6bb29d0ea9ac47fcbd11d118022b9dba6dc309dc121491d73e6208db60cb9d35
```

В конце успешной установки напечатаны HTTPS-адрес, логин и пароль панели.
Сохраните их приватно. Общего пароля `admin/admin` нет; при новой установке
обе строки генерируются. Данные записаны в `/etc/csqtt/csqtt.env` (`0600`) и
не меняются при перезапуске/обновлении. SHA-256 бинарника — не пароль.

```sh
# Показать сохранённый вход без перезапуска (новый установщик):
sudo bash server-install.sh credentials
```

Если сервер установлен прежним скриптом без постоянного входа, в согласованное
окно повторите установку той же версии новым скриптом: потребуется один
перезапуск, конфигурация и клиентские пароли сохраняются. Старый несохранённый
случайный пароль веб-панели заменится постоянным.

## Проверка после установки

```sh
sudo bash server-install.sh status
systemctl show csqtt --property=ActiveState,SubState,MainPID,NRestarts
ip link show csqtt1
sudo ss -lunp 'sport = :46000'
sudo ss -lntp 'sport = :46002'
```

Проверьте повторно через минуту: PID стабилен, число NRestarts не растёт.
Порты указаны для штатной схемы; на изменённой конфигурации сверяйте фактические.
Запущенная служба и открытые порты ещё не подтверждают трафик через туннель:
нужны подключение отдельного клиента и полезный запрос через его туннель.
Это отдельная клиентская проверка, не автоматический VK-опрос установщика.

## Обновление без замены окружения

Для уже установленной службы используйте `server-deploy.sh update` с выбранным
бинарником и соответствующим `--sha256-file`, как в примерах выше.
Смена версии может менять формат конфигурации: перед переходом сделайте копию,
не считайте обратную совместимость доказанной только успешным запуском.

## Откат

Используйте путь резервной копии, выданный соответствующим установщиком:

```sh
sudo bash server-install.sh rollback --backup /var/lib/csqtt-deploy/ИМЯ-КОПИИ --yes
# Если меняли только бинарник через server-deploy.sh:
sudo bash server-deploy.sh rollback --backup /var/lib/csqtt-deploy/ИМЯ-КОПИИ --yes
```

При первоначальной установке, когда прежней службы не было, откат не означает
запуск предыдущего сервера. Для восстановления мигрировавшей конфигурации
сверьте документацию параметра `--restore-config` и нужную приватную копию.
