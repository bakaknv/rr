# RR / RouteRich router scripts

Набор скриптов для роутеров RouteRich на OpenWrt:

- подбор лучших Cloudflare WARP-эндпоинтов и замена endpoint'ов у интерфейсов
  AmneziaWG по задержке YouTube;
- cron-обёртка с логом только последнего запуска;
- синхронизация экземпляров `internet-detector` с текущими интерфейсами
  `rrws_*` (рестарт интерфейса, если через него не проходит интернет);
- перезагрузка ONT через веб-интерфейс и цикл «ONT → роутер».

## Состав

```
warp/rrws-7best          основной скрипт: скан WARP, выбор лучших endpoint'ов
warp/rrws-7best-cron     cron-обёртка: последний лог, запуск раз в 30 минут
warp/rrws-detector-sync  синхронизация internet-detector с интерфейсами rrws_*

ont/ont-reboot.sh        логин в ONT и перезагрузка терминала
ont/ont-cycle.sh         перезагрузка ONT, ожидание, перезагрузка OpenWrt

config/                  примеры crontab, sysupgrade и keep.d
```

## Требования

- OpenWrt 24.10 / 25.x, BusyBox ash;
- `luci-app-rrws` и `/usr/bin/rrws` (движок warpscout);
- `jq`, `curl`, `flock`, `awg`, `uci`;
- `luci-app-internet-detector` — для `rrws-detector-sync`.

## WARP: установка

```sh
scp warp/rrws-7best warp/rrws-7best-cron root@ROUTER:/usr/bin/
ssh root@ROUTER 'chmod +x /usr/bin/rrws-7best /usr/bin/rrws-7best-cron'
```

Первый запуск — предпросмотр, ничего не меняет:

```sh
/usr/bin/rrws-7best --dry-run
```

Применить:

```sh
/usr/bin/rrws-7best --apply
```

По умолчанию скрипт сам находит все интерфейсы `rrws_created=1` с именем
`rrws_*`; отдельно указывать количество не нужно. Основные опции:

```
--apply              записать новые endpoint'ы
--dry-run            только показать план (по умолчанию)
--sample N           адресов на подсеть (по умолчанию 20)
--verbose            показывать прогресс скана без TTY
--from-json FILE     использовать готовый JSON вместо нового скана
--pure-latency       сортировать только по GET-RTT YouTube
--no-exclude-dme     не исключать узел DME
```

Логи и отчёты: `/root/rrws-7best/`.

## WARP: cron

```cron
*/30 * * * * /usr/bin/rrws-7best-cron
```

Обёртка пишет вывод в `cron.log.tmp.<pid>` и заменяет
`/root/rrws-7best/cron.log` только после завершения. В логе всегда остаётся
только последний запуск. Прогресс скана в cron-лог не попадает.

## internet-detector: синхронизация

```sh
scp warp/rrws-detector-sync root@ROUTER:/usr/bin/
ssh root@ROUTER 'chmod +x /usr/bin/rrws-detector-sync && /usr/bin/rrws-detector-sync'
```

Скрипт создаёт по одному экземпляру `internet-detector` на каждый текущий
`rrws_*` интерфейс:

- HTTP-проверка `https://www.google.com` через `curl --interface`;
- при обрыве — перезапуск этого же интерфейса;
- остальные модули (reboot, LED, user scripts, public IP) выключены;
- главный экземпляр `internet` не трогается.

После добавления/удаления интерфейсов `rrws_*` просто запусти скрипт снова.

## Сохранение при sysupgrade

Добавь в `/etc/sysupgrade.conf`:

```conf
/usr/bin/rrws-7best
/usr/bin/rrws-7best-cron
/usr/bin/rrws-detector-sync
/root/ont-reboot.sh
/root/ont-cycle.sh
```

Для ONT можно дополнительно положить `config/keep.d-ont-cycle` в
`/lib/upgrade/keep.d/ont-cycle`.

## ONT

`ont-reboot.sh` требует `ONT_ENCODE_PASSWORD` — URL-encoded base64 от
`md5crypt(пароль, пустая соль)`. Секрет хранится **вне репозитория**:

```sh
cat >/etc/ont.env <<'EOF'
ONT_HOST=192.168.0.1
ONT_USER=admin
ONT_ENCODE_PASSWORD=CHANGE_ME
ONT_SECURITY_FLAG=29858
EOF
chmod 600 /etc/ont.env
```

```sh
scp ont/ont-reboot.sh ont/ont-cycle.sh root@ROUTER:/root/
ssh root@ROUTER 'chmod +x /root/ont-reboot.sh /root/ont-cycle.sh'
```

Проверка без перезагрузки роутера:

```sh
DRY_RUN=1 /root/ont-cycle.sh
```

## Безопасность

Не коммитить:

- `/etc/ont.env` и любые хеши/пароли ONT;
- `/etc/rrws-account.json` (ключи WARP);
- `/etc/config/network`, `/etc/config/internet-detector` с локальными адресами;
- логи и бэкапы из `/root/rrws-7best/`.

В репозитории лежат только скрипты и примеры конфигов без секретов.
