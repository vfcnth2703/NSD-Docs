#!/bin/bash

# ============================================
# SMB HealthCheck - Автоматический установщик
# С выбором ресурсов для мониторинга
# Пароль SMTP вшит в конфиг
# Исправлена проверка монтирования для WSL2
# ============================================

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Директория установки
INSTALL_DIR="/opt/smb-healthcheck"
LOG_DIR="$INSTALL_DIR/logs"
BIN_DIR="$INSTALL_DIR/bin"
ETC_DIR="$INSTALL_DIR/etc"

# Пароль SMTP (вшит в инсталлятор)
SMTP_PASSWORD="FstG3#EMx"

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}   SMB HealthCheck - Установка${NC}"
echo -e "${BLUE}   Директория: $INSTALL_DIR${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Проверка прав
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}Ошибка: Не запускайте скрипт от root${NC}"
    exit 1
fi

# Список всех возможных ресурсов
AVAILABLE_RESOURCES=(
    "fserver|/mnt/fserver|//192.168.150.192/files"
    "Synology|/mnt/Synology05/FTP|//Synology05/FTP"
    "ASCN_Volgograd|/mnt/ftp|//ftp/ftp/ascnvolgograd"
)

# Выбор ресурсов
echo -e "${CYAN}Доступные ресурсы для мониторинга:${NC}"
echo ""

for i in "${!AVAILABLE_RESOURCES[@]}"; do
    IFS='|' read -r name mount remote <<< "${AVAILABLE_RESOURCES[$i]}"
    echo "  $((i+1)). $name"
    echo "     Путь: $mount"
    echo "     Удаленный ресурс: $remote"
    echo ""
done

echo -e "${YELLOW}Выберите ресурсы для мониторинга (через пробел)${NC}"
echo "Пример: 1 2 3 - все ресурсы"
echo "Пример: 1 2 - только fserver и Synology"
echo -e "${YELLOW}Если просто нажать Enter - будут выбраны все ресурсы${NC}"
read -p "Ваш выбор: " SELECTION

# Обработка выбора
SELECTED_RESOURCES=()
if [ -z "$SELECTION" ]; then
    SELECTED_RESOURCES=("${AVAILABLE_RESOURCES[@]}")
    echo -e "${GREEN}Выбраны все ресурсы${NC}"
else
    for num in $SELECTION; do
        if [ "$num" -ge 1 ] && [ "$num" -le "${#AVAILABLE_RESOURCES[@]}" ]; then
            SELECTED_RESOURCES+=("${AVAILABLE_RESOURCES[$((num-1))]}")
        else
            echo -e "${RED}Неверный номер: $num${NC}"
        fi
    done
fi

echo ""
echo -e "${GREEN}Выбрано ресурсов: ${#SELECTED_RESOURCES[@]}${NC}"
for item in "${SELECTED_RESOURCES[@]}"; do
    IFS='|' read -r name mount remote <<< "$item"
    echo "  ✓ $name ($mount)"
done
echo ""

# Запрос email для уведомлений
echo -e "${YELLOW}Настройка уведомлений${NC}"
echo "Введите email для получения уведомлений"
echo -e "${YELLOW}Можно указать несколько адресов через запятую${NC}"
echo "Пример: admin@company.ru,tech@company.ru,dev@company.ru"
echo -e "${YELLOW}Если не нужны уведомления - просто нажмите Enter${NC}"
read -p "Email: " NOTIFY_EMAIL

echo ""
echo -e "${GREEN}Начинаю установку...${NC}"
echo ""

# ОЧИСТКА FSTAB ОТ ДУБЛИКАТОВ
echo -e "${BLUE}[1/7] Очистка /etc/fstab от дубликатов...${NC}"

# Создаем резервную копию
sudo cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)

# Удаляем старые записи
for item in "${AVAILABLE_RESOURCES[@]}"; do
    IFS='|' read -r name mount remote <<< "$item"
    sudo sed -i "\#${mount}#d" /etc/fstab 2>/dev/null || true
done
sudo sed -i '/# SMB ресурсы для выгрузки файлов/d' /etc/fstab

# Добавляем выбранные ресурсы в fstab
echo -e "${GREEN}Добавление записей в /etc/fstab...${NC}"

# Добавляем заголовок
echo -e "\n# SMB ресурсы для выгрузки файлов (добавлено SMB HealthCheck)" | sudo tee -a /etc/fstab

for item in "${SELECTED_RESOURCES[@]}"; do
    IFS='|' read -r name mount remote <<< "$item"
    
    # Определяем учетные данные для каждого ресурса
    if [[ "$name" == "fserver" ]]; then
        creds="domain=servplus.ru,username=Naumen,password=P!w^%DWh4e"
    elif [[ "$name" == "Synology" ]]; then
        creds="domain=servplus.ru,username=Naumen,password=P!w^%DWh4e"
    elif [[ "$name" == "ASCN_Volgograd" ]]; then
        creds="domain=servplus.ru,username=d.zezin,password=H&733jVu5"
    fi
    
    echo "$remote  $mount  cifs  $creds,iocharset=utf8,file_mode=0777,dir_mode=0777 0 0" | sudo tee -a /etc/fstab
done

# Шаг 2: Создание структуры директорий
echo -e "${BLUE}[2/7] Создание структуры директорий...${NC}"
sudo mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$BIN_DIR" "$ETC_DIR"
sudo chown -R $(whoami):$(whoami) "$INSTALL_DIR"

# Шаг 3: Установка пакетов
echo -e "${BLUE}[3/7] Установка необходимых пакетов...${NC}"
sudo apt update -qq
sudo apt install -y cifs-utils

# Шаг 4: Создание точек монтирования
echo -e "${BLUE}[4/7] Создание точек монтирования...${NC}"
for item in "${SELECTED_RESOURCES[@]}"; do
    IFS='|' read -r name mount remote <<< "$item"
    sudo mkdir -p "$mount"
    echo "  Создана: $mount"
done

# Шаг 5: Создание основного скрипта
echo -e "${BLUE}[5/7] Создание скрипта мониторинга...${NC}"

# Формируем список MOUNT_POINTS для скрипта
MOUNT_POINTS_LIST=""
for item in "${SELECTED_RESOURCES[@]}"; do
    IFS='|' read -r name mount remote <<< "$item"
    MOUNT_POINTS_LIST="$MOUNT_POINTS_LIST    \"$name|$mount\"\n"
done

cat > "$BIN_DIR/smb_healthcheck.sh" << 'MAINSCRIPT'
#!/bin/bash

# === КОНФИГУРАЦИЯ ===
INSTALL_DIR="/opt/smb-healthcheck"
LOG_DIR="$INSTALL_DIR/logs"
CONFIG_FILE="$INSTALL_DIR/etc/config.env"

# Загрузка конфигурации
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Список точек монтирования
MOUNT_POINTS=(
MOUNT_POINTS_PLACEHOLDER
)

# Настройки по умолчанию
LOG_FILE="${LOG_FILE:-$LOG_DIR/healthcheck.log}"
NOTIFY_TO="${NOTIFY_TO:-}"
LAST_ERROR_FILE="$LOG_DIR/last_error"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Специальная проверка монтирования для WSL2
is_mounted() {
    local mount_point="$1"
    
    # Проверка через /proc/mounts (наиболее надежно в WSL2)
    if grep -q " $mount_point " /proc/mounts 2>/dev/null; then
        return 0
    fi
    
    # Проверка через mount команду
    if mount | grep -q " $mount_point "; then
        return 0
    fi
    
    # Проверка: можем ли мы прочитать директорию
    if [ -d "$mount_point" ] && [ -r "$mount_point" ]; then
        # Проверяем, что это не пустая директория (признак смонтированной шары)
        if ls -la "$mount_point" 2>/dev/null | grep -q "total 0\|^d"; then
            return 0
        fi
    fi
    
    return 1
}

send_notification() {
    local resource="$1"
    local error_msg="$2"
    
    if [ -z "$NOTIFY_TO" ] || [ ! -f "$INSTALL_DIR/bin/send_alert.sh" ]; then
        return
    fi
    
    if [ -f "$LAST_ERROR_FILE" ]; then
        local last_time=$(cat "$LAST_ERROR_FILE")
        local current_time=$(date +%s)
        if [ $((current_time - last_time)) -lt 1800 ]; then
            return
        fi
    fi
    
    date +%s > "$LAST_ERROR_FILE"
    
    local subject="SMB Alert: $resource"
    local body="Время: $(date '+%Y-%m-%d %H:%M:%S')
Ресурс: $resource
Ошибка: $error_msg

Проверка: $INSTALL_DIR/bin/smb_healthcheck.sh status
Лог: tail -20 $LOG_FILE"
    
    "$INSTALL_DIR/bin/send_alert.sh" "$NOTIFY_TO" "$subject" "$body" 2>/dev/null
    log "Уведомление отправлено на $NOTIFY_TO"
}

mount_point() {
    local name="$1"
    local mount="$2"
    
    log "Монтирую $name: $mount"
    
    if [ ! -d "$mount" ]; then
        sudo mkdir -p "$mount"
    fi
    
    if is_mounted "$mount"; then
        log "  $name уже примонтирован"
        return 0
    fi
    
    if sudo mount "$mount" 2>/dev/null; then
        log "  ✓ $name смонтирован успешно"
        return 0
    else
        log "  ✗ ОШИБКА: не удалось смонтировать $name"
        send_notification "$name" "Не удалось смонтировать $mount"
        return 1
    fi
}

mount_all() {
    log "========== НАЧАЛО МОНТИРОВАНИЯ =========="
    for item in "${MOUNT_POINTS[@]}"; do
        IFS='|' read -r name mount <<< "$item"
        mount_point "$name" "$mount"
    done
    log "========== МОНТИРОВАНИЕ ЗАВЕРШЕНО =========="
}

check_all() {
    log "=== ПРОВЕРКА ==="
    local all_ok=true
    
    for item in "${MOUNT_POINTS[@]}"; do
        IFS='|' read -r name mount <<< "$item"
        
        if is_mounted "$mount"; then
            log "✓ $name: OK"
            echo "✓ $name: OK"
        else
            log "✗ $name: FAIL"
            echo "✗ $name: FAIL"
            all_ok=false
        fi
    done
    
    if [ "$all_ok" = true ]; then
        log "ИТОГ: Все ресурсы примонтированы"
    else
        log "ИТОГ: Некоторые ресурсы НЕ примонтированы"
    fi
}

ensure_all() {
    log "========== ЗАПУСК ensure: $(date '+%Y-%m-%d %H:%M:%S') =========="
    
    for item in "${MOUNT_POINTS[@]}"; do
        IFS='|' read -r name mount <<< "$item"
        if ! is_mounted "$mount"; then
            log "$name: требует монтирования"
            mount_point "$name" "$mount"
        fi
    done
    
    echo ""
    check_all
    log "========== ЗАВЕРШЕНИЕ ensure =========="
}

show_status() {
    echo ""
    echo "=== СТАТУС РЕСУРСОВ $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo ""
    for item in "${MOUNT_POINTS[@]}"; do
        IFS='|' read -r name mount <<< "$item"
        echo "$name: $mount"
        if is_mounted "$mount"; then
            echo "  ✓ ПРИМОНТИРОВАН"
            # Пробуем получить реальный размер через df, но в WSL2 может не работать
            df_output=$(df -h "$mount" 2>/dev/null | tail -1)
            if echo "$df_output" | grep -q "^none"; then
                # В WSL2 df показывает none, пробуем через mount
                mount_info=$(mount | grep " $mount ")
                if [ -n "$mount_info" ]; then
                    echo "  Смонтирован: $(echo $mount_info | awk '{print $1}')"
                fi
            else
                echo "$df_output" | awk '{print "  Размер: " $2 "\n  Использовано: " $3 "\n  Доступно: " $4}'
            fi
        else
            echo "  ✗ НЕ ПРИМОНТИРОВАН"
        fi
        echo ""
    done
}

case "${1:-check}" in
    check)   check_all ;;
    mount)   mount_all; check_all ;;
    ensure)  ensure_all ;;
    status)  show_status ;;
    *)
        echo "Использование: $0 {check|mount|ensure|status}"
        ;;
esac
MAINSCRIPT

# Вставляем список MOUNT_POINTS
TMP_SCRIPT=$(mktemp)
cat "$BIN_DIR/smb_healthcheck.sh" > "$TMP_SCRIPT"
sed -i "/MOUNT_POINTS_PLACEHOLDER/r /dev/stdin" "$TMP_SCRIPT" <<< "$MOUNT_POINTS_LIST"
sed -i '/MOUNT_POINTS_PLACEHOLDER/d' "$TMP_SCRIPT"
mv "$TMP_SCRIPT" "$BIN_DIR/smb_healthcheck.sh"

chmod +x "$BIN_DIR/smb_healthcheck.sh"

# Шаг 6: Создание скрипта отправки писем
echo -e "${BLUE}[6/7] Создание скрипта отправки писем...${NC}"
cat > "$BIN_DIR/send_alert.sh" << 'SENDALERT'
#!/bin/bash

INSTALL_DIR="/opt/smb-healthcheck"
CONFIG_FILE="$INSTALL_DIR/etc/config.env"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

readonly SMTP_HOST="${SMTP_HOST:-smtp.lancloud.ru}"
readonly SMTP_PORT="${SMTP_PORT:-587}"
readonly SMTP_USER="${SMTP_USER:-superset@ascn.ru}"
readonly SMTP_FROM="${SMTP_FROM:-superset@ascn.ru}"
readonly SMTP_PASSWORD="${SMTP_PASSWORD:-}"
readonly LOG_FILE="$INSTALL_DIR/logs/send_alert.log"

RAW_TO="${1:-}"
SUBJECT="${2:-Без темы}"
BODY="${3:-Без текста}"

TO=$(echo "$RAW_TO" | tr ' ' ',')

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

if [ -z "$TO" ]; then
    log "ERROR: не указан получатель"
    exit 1
fi

if [ -z "$SMTP_PASSWORD" ]; then
    log "ERROR: не задан пароль SMTP_PASSWORD в конфиге"
    exit 1
fi

if [ ! -x "/usr/bin/sendemail" ]; then
    log "ERROR: sendemail не установлен"
    exit 1
fi

log "SEND: to=$TO, subject=$SUBJECT"

OUTPUT=$(/usr/bin/sendemail \
  -f "$SMTP_FROM" \
  -t "$TO" \
  -s "${SMTP_HOST}:${SMTP_PORT}" \
  -xu "$SMTP_USER" \
  -xp "$SMTP_PASSWORD" \
  -u "$SUBJECT" \
  -m "$BODY" \
  -o tls=yes \
  -o fqdn=ascn.ru \
  -o message-charset=utf-8 \
  2>&1) || true

if echo "$OUTPUT" | grep -qi "success\|queued\|sent"; then
    log "SUCCESS: Письмо отправлено"
    exit 0
else
    log "ERROR: $OUTPUT"
    exit 1
fi
SENDALERT

chmod +x "$BIN_DIR/send_alert.sh"

# Шаг 7: Создание конфигурации
echo -e "${BLUE}[7/7] Создание конфигурации...${NC}"

cat > "$ETC_DIR/config.env" << CONFIG
# SMB HealthCheck Configuration
# Created: $(date)

# Email для уведомлений (можно несколько через запятую)
NOTIFY_TO="$NOTIFY_EMAIL"

# SMTP настройки (пароль хранится здесь же)
SMTP_HOST="smtp.lancloud.ru"
SMTP_PORT="587"
SMTP_USER="superset@ascn.ru"
SMTP_FROM="superset@ascn.ru"
SMTP_PASSWORD="$SMTP_PASSWORD"
CONFIG

chmod 600 "$ETC_DIR/config.env"

# Создание симлинков
echo -e "${BLUE}Создание символических ссылок...${NC}"
sudo ln -sf "$BIN_DIR/smb_healthcheck.sh" /usr/local/bin/smb_healthcheck
sudo ln -sf "$BIN_DIR/send_alert.sh" /usr/local/bin/send_alert

# Настройка cron
echo -e "${BLUE}Настройка автоматического запуска...${NC}"
(sudo crontab -l 2>/dev/null | grep -v "smb_healthcheck" | grep -v "MAILTO" || true) | sudo crontab -
(sudo crontab -l 2>/dev/null; echo "MAILTO=\"\"") | sudo crontab -
(sudo crontab -l 2>/dev/null; echo "*/5 * * * * $BIN_DIR/smb_healthcheck.sh ensure >> $LOG_DIR/cron.log 2>&1") | sudo crontab -
(sudo crontab -l 2>/dev/null; echo "@reboot $BIN_DIR/smb_healthcheck.sh ensure >> $LOG_DIR/reboot.log 2>&1") | sudo crontab -

# Первое монтирование
echo -e "${BLUE}Первое монтирование ресурсов...${NC}"
$BIN_DIR/smb_healthcheck.sh mount > /dev/null 2>&1

# Установка sendemail если нужны уведомления
if [ -n "$NOTIFY_EMAIL" ]; then
    sudo apt install -y sendemail
fi

# Финальный вывод
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "${YELLOW}Отслеживаемые ресурсы:${NC}"
for item in "${SELECTED_RESOURCES[@]}"; do
    IFS='|' read -r name mount remote <<< "$item"
    echo "  ✓ $name ($mount)"
done
echo ""
echo -e "${YELLOW}Управление:${NC}"
echo "  smb_healthcheck status     - детальный статус"
echo "  smb_healthcheck check      - быстрая проверка"
echo "  smb_healthcheck mount      - смонтировать всё"
echo "  smb_healthcheck ensure     - проверить и восстановить"
echo ""
echo -e "${YELLOW}Логи:${NC}"
echo "  tail -f $LOG_DIR/healthcheck.log"
echo ""
echo -e "${YELLOW}Конфигурация:${NC}"
echo "  nano $ETC_DIR/config.env"
echo ""

# Проверка статуса
echo -e "${YELLOW}Текущий статус:${NC}"
$BIN_DIR/smb_healthcheck.sh check