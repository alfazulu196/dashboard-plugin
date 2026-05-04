#!/bin/bash

# --- Modular Dashboard for XFCE Generic Monitor ---

# Устанавливаем локаль для чисел, чтобы избежать проблем с printf
export LC_NUMERIC="C"

# Абсолютный путь к директории, где лежит скрипт
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
CONFIG_FILE="$SCRIPT_DIR/dashboard.json"

# Временные файлы для хранения состояний
CPU_STATE_FILE="/tmp/dashboard_cpu_state"
JOURNAL_STATE_FILE="/tmp/dashboard_journal_state"
AUTH_STATE_FILE="/tmp/dashboard_auth_state"
AUTH_NOTIFY_STATE_FILE="/tmp/dashboard_auth_notify_ts"

# Явное указание переменных окружения для GUI-приложений
export DISPLAY=:0
export XAUTHORITY=$HOME/.Xauthority

# --- Widget Functions ---
widget_cpu() {
    if [ ! -f "$CPU_STATE_FILE" ]; then grep 'cpu ' /proc/stat > "$CPU_STATE_FILE"; fi
    CPU_PREV=$(cat "$CPU_STATE_FILE"); grep 'cpu ' /proc/stat > "$CPU_STATE_FILE"; CPU_CURRENT=$(cat "$CPU_STATE_FILE")
    read -r _ user_prev nice_prev system_prev idle_prev iowait_prev irq_prev softirq_prev steal_prev guest_prev guest_nice_prev <<< "$CPU_PREV"
    read -r _ user_curr nice_curr system_curr idle_curr iowait_curr irq_curr softirq_curr steal_curr guest_curr guest_nice_curr <<< "$CPU_CURRENT"
    TOTAL_PREV=$((user_prev+nice_prev+system_prev+idle_prev+iowait_prev+irq_prev+softirq_prev+steal_prev+guest_prev+guest_nice_prev))
    TOTAL_CURR=$((user_curr+nice_curr+system_curr+idle_curr+iowait_curr+irq_curr+softirq_curr+steal_curr+guest_curr+guest_nice_curr))
    IDLE_PREV=$idle_prev; IDLE_CURR=$idle_curr
    TOTAL_DIFF=$((TOTAL_CURR - TOTAL_PREV)); IDLE_DIFF=$((IDLE_CURR - IDLE_PREV))
    if [ "$TOTAL_DIFF" -eq 0 ]; then echo "0"; return; fi
    CPU_USAGE=$((100 * (TOTAL_DIFF - IDLE_DIFF) / TOTAL_DIFF)); echo "$CPU_USAGE"
}
widget_memory_detailed() {
    local mem_info=$(free -h | grep Mem | awk '{print $3"/"$2}')
    local swap_info=$(free -h | grep Swap | awk '{print $3"/"$2}')
    printf "RAM: %s | Swap: %s" "$mem_info" "$swap_info"
}
widget_disk() { df -h / | awk 'NR==2{print $5}' | sed 's/%//'; }
widget_load() { cat /proc/loadavg | awk '{print $1}'; }
widget_top_process() {
    ps -eo comm,%cpu --no-headers --sort=-%cpu | grep -v "ps" | head -n 1
}
widget_cpu_temp() {
    if ! command -v sensors &> /dev/null; then echo "-1"; return; fi
    local temp=$(sensors | grep 'Core 0:' | awk '{print $3}' | sed 's/+//;s/°C//')
    if [ -z "$temp" ]; then temp=$(sensors | grep 'temp1:' | awk '{print $2}' | sed 's/+//;s/°C//'); fi
    if [ -z "$temp" ]; then echo "-1"; else echo "$temp"; fi
}
widget_uptime() {
    local uptime_str=$(uptime -p | sed -e 's/up //; s/ days, /d /; s/ day, /d /; s/ hours, /h /; s/ hour, /h /; s/ minutes/m/; s/ minute/m/')
    printf "Uptime: %s" "$uptime_str"
}
widget_journal_errors() {
    if ! command -v journalctl &> /dev/null; then echo "0"; return; fi
    local now_ts=$(date +%s%N)
    if [ ! -f "$JOURNAL_STATE_FILE" ]; then echo "$now_ts" > "$JOURNAL_STATE_FILE"; fi
    local last_seen_ts=$(cat "$JOURNAL_STATE_FILE")
    local new_errors_json=$(journalctl -p 3 --since "1 hour ago" --no-pager -o json)
    if [ -z "$new_errors_json" ] || ! echo "$new_errors_json" | jq . >/dev/null 2>&1; then
        echo "0"; return
    fi
    local result=$(echo "$new_errors_json" | jq --argjson last_ts "$last_seen_ts" ' . as $all | ($all | map(select((.__REALTIME_TIMESTAMP | tonumber) > $last_ts))) as $new_entries | { count: ($new_entries | length), latest_ts: ([$all[].__REALTIME_TIMESTAMP] | map(tonumber) | max // $last_ts) } ')
    local new_error_count=$(echo "$result" | jq '.count')
    local latest_ts=$(echo "$result" | jq '.latest_ts')
    if [ "$latest_ts" != "null" ] && (( $(echo "$latest_ts > $last_seen_ts" | bc -l) )); then echo "$latest_ts" > "$JOURNAL_STATE_FILE"; fi
    echo "$new_error_count"
}
widget_auth_failures() {
    local AUTH_LOG_FILE="/var/log/auth.log"
    if [ ! -r "$AUTH_LOG_FILE" ]; then echo "0"; return; fi
    local now_ts=$(date +%s)
    if [ ! -f "$AUTH_STATE_FILE" ]; then echo "$now_ts" > "$AUTH_STATE_FILE"; fi
    local last_seen_ts=$(cat "$AUTH_STATE_FILE")
    local failed_logins=$(grep "Failed password" "$AUTH_LOG_FILE")
    if [ -z "$failed_logins" ]; then echo "0"; return; fi
    local new_failure_count=0
    local latest_ts=0
    while read -r line; do
        local line_ts=$(date --date="$(echo "$line" | awk '{print $1" "$2" "$3}')" +%s)
        if [ "$line_ts" -gt "$last_seen_ts" ]; then
            new_failure_count=$((new_failure_count + 1))
            if [ "$line_ts" -gt "$latest_ts" ]; then latest_ts=$line_ts; fi
        fi
    done <<< "$failed_logins"
    if [ "$latest_ts" -gt "0" ]; then echo "$latest_ts" > "$AUTH_STATE_FILE"; fi
    echo "$new_failure_count"
}

# --- Shared Formatting Function ---
format_widget_output() {
    local type=$1; local raw_value=$2; local widget_json=$3
    case $type in
        cpu) printf "CPU: %.0f%%" "$raw_value" ;;
        memory_detailed) widget_memory_detailed ;;
        disk) printf "Disk: %s%%" "$raw_value" ;;
        load) printf "Load: %s" "$raw_value" ;;
        top_process) echo "$raw_value" | awk '{printf "Top: %s (%.0f%%)", $1, $2}' ;;
        uptime) widget_uptime ;;
        cpu_temp)
            if (( $(echo "$raw_value < 0" | bc -l) )); then echo "Temp: N/A"; else
                local formatted_temp=$(printf "Temp: %.0f°C" "$raw_value")
                local warn_threshold=$(echo "$widget_json" | jq -r '.thresholds.warning // 999')
                local crit_threshold=$(echo "$widget_json" | jq -r '.thresholds.critical // 999')
                local color=""
                if (( $(echo "$raw_value >= $crit_threshold" | bc -l) )); then color="red";
                elif (( $(echo "$raw_value >= $warn_threshold" | bc -l) )); then color="orange"; fi
                if [ -n "$color" ]; then echo "<span color='$color'>$formatted_temp</span>"; else echo "$formatted_temp"; fi
            fi ;;
        journal_errors) printf "New Errors: %s" "$raw_value" ;;
        auth_failures) printf "Auth Fails: %s" "$raw_value" ;;
        *) echo "Неизвестный виджет: $type" ;;
    esac
}

# --- Click Action Logic ---
if [ "$1" == "click" ]; then
    if ! command -v notify-send &> /dev/null; then exit 1; fi
    report_parts_click=()
    for widget_json in $(jq -c '.widgets[]' "$CONFIG_FILE"); do
        type=$(echo "$widget_json" | jq -r '.type')
        icon=$(echo "$widget_json" | jq -r '.icon // ""')
        if [ -n "$icon" ]; then icon="$icon "; fi
        
        raw_value=""
        case $type in
            cpu) raw_value=$(widget_cpu) ;;
            memory_detailed) raw_value=$(widget_memory_detailed) ;;
            disk) raw_value=$(widget_disk) ;;
            load) raw_value=$(widget_load) ;;
            top_process) raw_value=$(widget_top_process) ;;
            cpu_temp) raw_value=$(widget_cpu_temp) ;;
            uptime) raw_value=$(widget_uptime) ;;
            journal_errors) raw_value=$(widget_journal_errors) ;;
            auth_failures) raw_value=$(widget_auth_failures) ;;
        esac

        formatted_output=$(format_widget_output "$type" "$raw_value" "$widget_json")
        
        if [ "$type" == "journal_errors" ] && [ "$raw_value" -gt 0 ]; then
            report_parts_click+=("${icon}Новых критических ошибок: $raw_value")
            report_parts_click+=("--- Последние ошибки ---")
            error_messages=$(journalctl -p 3 --since "1 hour ago" --no-pager --output=cat --lines=5)
            report_parts_click+=("$error_messages")
        elif [ "$type" == "auth_failures" ] && [ "$raw_value" -gt 0 ]; then
            report_parts_click+=("${icon}Новых неудачных входов: $raw_value")
            report_parts_click+=("--- Последние попытки ---")
            fail_messages=$(grep "Failed password" /var/log/auth.log | tail -n 5)
            report_parts_click+=("$fail_messages")
        else
            report_parts_click+=("$icon$(echo "$formatted_output" | sed 's/<[^>]*>//g')")
        fi
    done
    notify_message=$(IFS=$'
'; echo "${report_parts_click[*]}")
    notify-send "Dashboard Report" "$notify_message"
    exit 0
fi

# --- Main Logic (Display) ---
if [ ! -f "$CONFIG_FILE" ]; then
    echo "<txt>Ошибка: dashboard.json не найден</txt>"; exit 1;
fi
output_parts=()
for widget_json in $(jq -c '.widgets[]' "$CONFIG_FILE"); do
    type=$(echo "$widget_json" | jq -r '.type')
    icon=$(echo "$widget_json" | jq -r '.icon // ""')
    if [ -n "$icon" ]; then icon="$icon "; fi
    
    # This dynamic call is problematic, using a case statement instead
    raw_value=""
    case $type in
        cpu) raw_value=$(widget_cpu) ;;
        memory_detailed) raw_value="N/A" ;; # handled by formatter
        disk) raw_value=$(widget_disk) ;;
        load) raw_value=$(widget_load) ;;
        top_process) raw_value=$(widget_top_process) ;;
        cpu_temp) raw_value=$(widget_cpu_temp) ;;
        uptime) raw_value="N/A" ;; # handled by formatter
        journal_errors) raw_value=$(widget_journal_errors) ;;
        auth_failures) raw_value=$(widget_auth_failures) ;;
    esac

    formatted_output=$(format_widget_output "$type" "$raw_value" "$widget_json")

    # Check for critical alerts (for auth_failures)
    if [ "$type" == "auth_failures" ]; then
        alert_enabled=$(echo "$widget_json" | jq -r '.alert_on_threshold // false')
        crit_threshold=$(echo "$widget_json" | jq -r '.thresholds.critical // 999999')
        
        if [ "$alert_enabled" = "true" ] && [ "$raw_value" -ge "$crit_threshold" ]; then
            if command -v notify-send &> /dev/null; then
                NOTIFY_STATE_FILE="/tmp/dashboard_auth_notify_ts"
                last_notify_ts=0
                if [ -f "$NOTIFY_STATE_FILE" ]; then last_notify_ts=$(cat "$NOTIFY_STATE_FILE"); fi
                current_ts=$(date +%s)
                
                if [ $((current_ts - last_notify_ts)) -ge 300 ]; then
                    notify-send --urgency=critical "КРИТИЧЕСКОЕ ПРЕДУПРЕЖДЕНИЕ: Неудачные входы!" "Обнаружено $raw_value новых неудачных попыток входа, порог: $crit_threshold."
                    echo "$current_ts" > "$NOTIFY_STATE_FILE"
                fi
            fi
        fi
    fi
    
    output_parts+=("$icon$formatted_output")
done

tooltip_content=""
first_item=true
for item in "${output_parts[@]}"; do
    if [ "$first_item" = false ]; then tooltip_content+="&#x0A;"; fi
    tooltip_content+="$item"; first_item=false
done

# XML Output for panel
echo "<img>/usr/share/icons/gnome/24x24/apps/utilities-system-monitor.png</img>"
echo "<tool>$tooltip_content</tool>"
echo "<txt></txt>"
echo "<click>$SCRIPT_DIR/dashboard.sh click</click>"

exit 0
