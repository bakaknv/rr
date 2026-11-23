#!/bin/sh
#
# ont-cycle.sh — перезагрузка ONT, ожидание подъёма ONT, перезагрузка OpenWrt.
#
# Схема: ONT (192.168.0.1) <- WiFi 2.4 ГГц (phy0-sta0) <- OpenWrt.
# Скрипт перезагрузки ONT: /root/ont-reboot.sh
#
# Использование:
#   /root/ont-cycle.sh
#   DRY_RUN=1 /root/ont-cycle.sh                  # без перезагрузки роутера
#   UP_TIMEOUT=600 DOWN_TIMEOUT=60 /root/ont-cycle.sh
#
# Запуск в фоне, чтобы обрыв SSH при перезагрузке роутера не убил скрипт:
#   nohup /root/ont-cycle.sh > /tmp/ont-cycle.log 2>&1 &

set -u

ONT_HOST="${ONT_HOST:-192.168.0.1}"
ONT_SCRIPT="${ONT_SCRIPT:-/root/ont-reboot.sh}"
STA_IF="${STA_IF:-phy0-sta0}"
DOWN_TIMEOUT="${DOWN_TIMEOUT:-120}"
UP_TIMEOUT="${UP_TIMEOUT:-300}"
DRY_RUN="${DRY_RUN:-0}"

TMP_OUT=/tmp/.ont_cycle_out

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
now() { date +%s; }

ont_ping() { ping -c 1 -W 1 -q "$ONT_HOST" >/dev/null 2>&1; }
sta_has_ip() { ip -4 addr show dev "$STA_IF" 2>/dev/null | grep -q 'inet '; }

cleanup() { rm -f "$TMP_OUT"; }
trap cleanup EXIT INT TERM

# --- 0. Проверки -----------------------------------------------------------
if [ ! -x "$ONT_SCRIPT" ]; then
    log "ОШИБКА: $ONT_SCRIPT не найден или не исполняемый"
    exit 1
fi
if ! ip link show dev "$STA_IF" >/dev/null 2>&1; then
    log "ОШИБКА: нет интерфейса $STA_IF — WiFi-клиент к ONT не поднят"
    exit 1
fi

# --- 1. Перезагрузка ONT ---------------------------------------------------
log "ONT $ONT_HOST: запускаю $ONT_SCRIPT"
if ! "$ONT_SCRIPT" > "$TMP_OUT" 2>&1; then
    sed 's/^/  /' "$TMP_OUT"
    log "ОШИБКА: $ONT_SCRIPT завершился с ошибкой, ONT не перезагружен"
    exit 1
fi
sed 's/^/  /' "$TMP_OUT"

# --- 2. Ждём, пока ONT пропадёт (чтобы не принять старое состояние за новое)
log "ONT: жду потери связи (до ${DOWN_TIMEOUT}s)"
start=$(now)
down=0
while :; do
    if ! ont_ping; then
        down=1
        break
    fi
    [ $(( $(now) - start )) -ge "$DOWN_TIMEOUT" ] && break
    sleep 2
done
if [ "$down" = 1 ]; then
    log "ONT: связь потеряна — терминал ушёл в перезагрузку"
else
    log "ONT: связь не пропала за ${DOWN_TIMEOUT}s — считаю, что терминал перезагрузился слишком быстро"
fi

# --- 3. Ждём подъёма ONT ---------------------------------------------------
log "ONT: жду подъёма (до ${UP_TIMEOUT}s)"
start=$(now)
last_tick=0
up=0
while :; do
    if ont_ping; then
        up=1
        break
    fi
    elapsed=$(( $(now) - start ))
    [ "$elapsed" -ge "$UP_TIMEOUT" ] && break
    if [ $((elapsed / 15)) -gt "$last_tick" ]; then
        last_tick=$((elapsed / 15))
        log "ONT: пока не отвечает (${elapsed}s)"
    fi
    sleep 2
done

if [ "$up" != 1 ]; then
    log "ОШИБКА: ONT не поднялся за ${UP_TIMEOUT}s — OpenWrt НЕ перезагружаю"
    exit 1
fi

if ! sta_has_ip; then
    log "ВНИМАНИЕ: ONT отвечает, но у $STA_IF нет IPv4 — перезагружаю, после ребута DHCP выдаст адрес заново"
fi
log "ONT: поднялся ($(( $(now) - start ))s)"

# --- 4. Перезагрузка OpenWrt -----------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
    log "DRY_RUN=1: перезагрузка OpenWrt пропущена"
    exit 0
fi

log "OpenWrt: перезагружаюсь"
sync
reboot
