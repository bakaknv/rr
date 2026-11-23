#!/bin/sh
#
# ont-reboot.sh — вход в веб-интерфейс оптического терминала (Realtek SDK)
#                 и перезагрузка терминала.
#
# Требуется ТОЛЬКО curl. Скрипт написан под BusyBox ash (/bin/sh) на роутере:
#   НЕТ bash, openssl, python, base64, od, mktemp, массивов и =~.
#
# Как это работает
#   Терминал не проверяет пароль напрямую. Страница логина делает:
#     1. hash = PHP_CRYPT_MD5(пароль, "$1$")  -> md5crypt с ПУСТОЙ солью
#     2. encodePassword = base64(hash)
#     3. postSecurityFlag = 16-битная контрольная сумма строки полей формы
#     4. поле password не отправляется (в браузере оно disabled)
#
#   Тело POST зависит от пароля, поэтому значение не хранится в скрипте.
#   Задай его в /etc/ont.env (файл не коммитить):
#
#     ONT_HOST=192.168.0.1
#     ONT_USER=admin
#     ONT_ENCODE_PASSWORD=<URL-encoded base64(md5crypt(пароль, пустая соль))>
#     ONT_SECURITY_FLAG=29858
#
#   Порядок полей в POST обязан совпадать с порядком в DOM:
#     challenge, username, save, encodePassword, submit-url, postSecurityFlag
#   При ином порядке терминал отвечает HTTP 400.
#
# Использование
#   ./ont-reboot.sh
#   ONT_HOST=192.168.0.1 ./ont-reboot.sh      # другой адрес терминала
#
# Терминал держит только ОДНУ сессию на учётную запись: если слот занят
# (открыт браузер с веб-интерфейсом), вход вернёт отказ — закройте его.

[ -f /etc/ont.env ] && . /etc/ont.env

HOST="${ONT_HOST:-192.168.0.1}"
USER_NAME="${ONT_USER:-admin}"
SECURITY_FLAG="${ONT_SECURITY_FLAG:-29858}"
ENCODE_PASSWORD="${ONT_ENCODE_PASSWORD:?set ONT_ENCODE_PASSWORD in /etc/ont.env}"

BASE="http://${HOST}"
LOGIN_URL="${BASE}/admin/login.asp"
FORM_URL="${BASE}/boaform/admin/formLogin"
REBOOT_URL="${BASE}/boaform/admin/formReboot"

HDR=/tmp/.ont_hdr
BODY=/tmp/.ont_body
PAGE=/tmp/.ont_page

POST_BODY="challenge=&username=${USER_NAME}&save=%D0%90%D0%B2%D1%82%D0%BE%D1%80%D0%B8%D0%B7%D0%BE%D0%B2%D0%B0%D1%82%D1%8C%D1%81%D1%8F&encodePassword=${ENCODE_PASSWORD}&submit-url=%2Fadmin%2Flogin.asp&postSecurityFlag=${SECURITY_FLAG}"

cleanup() { rm -f "$HDR" "$BODY" "$PAGE"; }
trap cleanup EXIT INT TERM

printf 'ONT %s: вход и перезагрузка\n' "$HOST"

# --- 1. Проверяем, что терминал отдаёт форму входа -----------------------
if ! curl -s -o "$PAGE" --connect-timeout 10 --max-time 20 "$LOGIN_URL"; then
    printf 'ОШИБКА: терминал %s недоступен\n' "$HOST" >&2
    exit 1
fi
if ! grep -q 'name="challenge"' "$PAGE" 2>/dev/null; then
    printf 'ОШИБКА: форма входа не получена (уже авторизованы или разметка изменилась)\n' >&2
    exit 1
fi
printf '  форма входа получена\n'

# --- 2. Авторизация --------------------------------------------------------
# curl падает на обрыве соединения — это норма, поэтому || true.
curl -s -D "$HDR" -o "$BODY" -X POST "$FORM_URL" \
     -H 'Content-Type: application/x-www-form-urlencoded' \
     -H "Referer: ${LOGIN_URL}" \
     --data-raw "$POST_BODY" \
     --connect-timeout 10 --max-time 25 >/dev/null 2>&1 || true

if grep -q 'уже вош' "$BODY" 2>/dev/null; then
    printf 'ОШИБКА: слот сессии занят другим клиентом.\n' >&2
    printf '       Терминал держит только одну сессию — закройте веб-интерфейс в браузере.\n' >&2
    exit 1
fi
if grep -q 'ОШИБКА' "$BODY" 2>/dev/null; then
    printf 'ОШИБКА: терминал отклонил авторизацию\n' >&2
    exit 1
fi

SID=$(sed -n 's/.*sessionid=\([0-9a-f][0-9a-f]*\).*/\1/p' "$HDR" 2>/dev/null | tail -n 1)
if [ -z "$SID" ]; then
    printf 'ОШИБКА: сессия не получена (терминал не выдал Set-Cookie)\n' >&2
    exit 1
fi
printf '  сессия получена: %s\n' "$SID"

# --- 3. Перезагрузка -------------------------------------------------------
# Терминал отдаёт страницу с отсчётом и тут же рвёт соединение — curl
# из-за этого завершается с ошибкой, это ожидаемо.
curl -s -o /tmp/.ont_rb -X POST "$REBOOT_URL" \
     -H 'Content-Type: application/x-www-form-urlencoded' \
     -H "Cookie: sessionid=${SID}" \
     -H "Referer: ${BASE}/admin/reboot.asp" \
     --data-raw 'postSecurityFlag=65535' \
     --connect-timeout 10 --max-time 20 >/dev/null 2>&1 || true
rm -f /tmp/.ont_rb

printf '\nГотово: авторизация выполнена, терминал перезагружается.\n'
