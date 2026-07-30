#!/usr/bin/env bash

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/sys-health-monitor.conf}"

DISK_PATH="${DISK_PATH:-/}"
DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-80}"
MEMORY_WARN_PERCENT="${MEMORY_WARN_PERCENT:-80}"
CPU_WARN_PERCENT="${CPU_WARN_PERCENT:-90}"
NGINX_SERVICE="${NGINX_SERVICE:-nginx}"
SSH_SERVICE="${SSH_SERVICE:-ssh}"
NGINX_PORT="${NGINX_PORT:-80}"
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
LOG_FILE="${LOG_FILE:-/var/log/sys_health.log}"
STATE_DIR="${STATE_DIR:-/var/lib/sys-health-monitor}"
DASHBOARD_FILE="${DASHBOARD_FILE:-/var/www/html/status.html}"

if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

umask 027
mkdir -p "$STATE_DIR"

declare -a CHECK_NAMES=()
declare -a CHECK_STATUSES=()
declare -a CHECK_MESSAGES=()

log_message() {
    local level="$1"
    local message="$2"
    printf '%s [%s] %s\n' "$(date --iso-8601=seconds)" "$level" "$message" >> "$LOG_FILE"
}

slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-'
}

publish_notification() {
    local subject="$1"
    local message="$2"

    if [[ -z "$SNS_TOPIC_ARN" ]]; then
        log_message "INFO" "SNS notification skipped because SNS_TOPIC_ARN is not configured"
        return 0
    fi

    if ! command -v aws >/dev/null 2>&1; then
        log_message "ERROR" "SNS notification failed because the AWS CLI is unavailable"
        return 1
    fi

    if aws sns publish \
        --region "$AWS_REGION" \
        --topic-arn "$SNS_TOPIC_ARN" \
        --subject "$subject" \
        --message "$message" >/dev/null; then
        log_message "INFO" "SNS notification published: $subject"
    else
        log_message "ERROR" "SNS notification could not be published: $subject"
        return 1
    fi
}

handle_state_transition() {
    local check_name="$1"
    local status="$2"
    local message="$3"
    local state_file previous_state

    state_file="$STATE_DIR/$(slugify "$check_name").state"
    previous_state=""
    [[ -r "$state_file" ]] && previous_state="$(<"$state_file")"

    if [[ "$status" == "WARNING" && "$previous_state" != "WARNING" ]]; then
        publish_notification "Linux Monitor Alert: $check_name" "$message" || true
    elif [[ "$status" == "OK" && "$previous_state" == "WARNING" ]]; then
        publish_notification "Linux Monitor Recovery: $check_name" "$message" || true
    fi

    printf '%s\n' "$status" > "$state_file"
}

record_result() {
    local check_name="$1"
    local status="$2"
    local message="$3"

    CHECK_NAMES+=("$check_name")
    CHECK_STATUSES+=("$status")
    CHECK_MESSAGES+=("$message")
    log_message "$status" "$check_name: $message"
    handle_state_transition "$check_name" "$status" "$message"
}

check_disk() {
    local usage
    usage="$(df -P "$DISK_PATH" | awk 'NR == 2 {gsub("%", "", $5); print $5}')"

    if [[ ! "$usage" =~ ^[0-9]+$ ]]; then
        record_result "Disk usage" "WARNING" "Unable to read disk usage for $DISK_PATH"
    elif (( usage >= DISK_WARN_PERCENT )); then
        record_result "Disk usage" "WARNING" "$DISK_PATH is ${usage}% used; threshold is ${DISK_WARN_PERCENT}%"
    else
        record_result "Disk usage" "OK" "$DISK_PATH is ${usage}% used"
    fi
}

check_memory() {
    local total available used_percent
    total="$(free -m | awk 'NR == 2 {print $2}')"
    available="$(free -m | awk 'NR == 2 {print $7}')"

    if [[ ! "$total" =~ ^[0-9]+$ || ! "$available" =~ ^[0-9]+$ || "$total" -eq 0 ]]; then
        record_result "Memory usage" "WARNING" "Unable to calculate available memory"
        return
    fi

    used_percent=$(( (total - available) * 100 / total ))
    if (( used_percent >= MEMORY_WARN_PERCENT )); then
        record_result "Memory usage" "WARNING" "Memory is ${used_percent}% used based on available memory; threshold is ${MEMORY_WARN_PERCENT}%"
    else
        record_result "Memory usage" "OK" "Memory is ${used_percent}% used based on available memory"
    fi
}

check_cpu() {
    local load_one cores normalized_percent
    load_one="$(awk '{print $1}' /proc/loadavg)"
    cores="$(nproc)"
    normalized_percent="$(awk -v load="$load_one" -v cpu="$cores" 'BEGIN {printf "%.0f", (load / cpu) * 100}')"

    if [[ ! "$normalized_percent" =~ ^[0-9]+$ ]]; then
        record_result "CPU load" "WARNING" "Unable to calculate normalized CPU load"
    elif (( normalized_percent >= CPU_WARN_PERCENT )); then
        record_result "CPU load" "WARNING" "One-minute load is $load_one across $cores CPU(s), approximately ${normalized_percent}% normalized load"
    else
        record_result "CPU load" "OK" "One-minute load is $load_one across $cores CPU(s), approximately ${normalized_percent}% normalized load"
    fi
}

port_is_listening() {
    local port="$1"
    ss -ltnH | awk -v target=":${port}" '$4 ~ target"$" {found=1} END {exit !found}'
}

check_nginx() {
    if ! systemctl is-active --quiet "$NGINX_SERVICE"; then
        record_result "Nginx service" "WARNING" "$NGINX_SERVICE is not active"
    elif ! port_is_listening "$NGINX_PORT"; then
        record_result "Nginx service" "WARNING" "$NGINX_SERVICE is active but TCP port $NGINX_PORT is not listening"
    else
        record_result "Nginx service" "OK" "$NGINX_SERVICE is active and TCP port $NGINX_PORT is listening"
    fi
}

check_ssh() {
    if systemctl is-active --quiet "$SSH_SERVICE"; then
        record_result "SSH service" "OK" "$SSH_SERVICE is active"
    else
        record_result "SSH service" "WARNING" "$SSH_SERVICE is not active"
    fi
}

html_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    printf '%s' "$value"
}

write_dashboard() {
    local temporary_file overall_status overall_class index status css_class
    temporary_file="$STATE_DIR/status.html.tmp"
    overall_status="HEALTHY"
    overall_class="ok"

    for status in "${CHECK_STATUSES[@]}"; do
        if [[ "$status" == "WARNING" ]]; then
            overall_status="ATTENTION REQUIRED"
            overall_class="warning"
            break
        fi
    done

    {
        cat <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="300">
  <title>Linux Server Health</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 2rem; background: #f4f7fb; color: #172033; }
    main { max-width: 900px; margin: auto; }
    .banner, .check { border-radius: 8px; padding: 1rem; margin-bottom: 1rem; }
    .banner { color: white; }
    .check { background: white; border-left: 6px solid; box-shadow: 0 2px 8px rgba(0,0,0,.08); }
    .ok { background: #16794b; }
    .warning { background: #b42318; }
    .check.ok { background: white; border-color: #16794b; }
    .check.warning { background: white; border-color: #b42318; }
    .status { font-weight: 700; }
    footer { color: #5b6472; font-size: .9rem; }
  </style>
</head>
<body>
<main>
  <div class="banner $overall_class">
    <h1>Linux Server Health: $overall_status</h1>
    <p>Last updated: $(date --iso-8601=seconds)</p>
  </div>
EOF

        for index in "${!CHECK_NAMES[@]}"; do
            status="${CHECK_STATUSES[$index]}"
            css_class="ok"
            [[ "$status" == "WARNING" ]] && css_class="warning"
            printf '  <section class="check %s"><h2>%s</h2><p class="status">%s</p><p>%s</p></section>\n' \
                "$css_class" \
                "$(html_escape "${CHECK_NAMES[$index]}")" \
                "$status" \
                "$(html_escape "${CHECK_MESSAGES[$index]}")"
        done

        cat <<'EOF'
  <footer>Generated by the Linux Server Health Monitoring Toolkit.</footer>
</main>
</body>
</html>
EOF
    } > "$temporary_file"

    install -m 0644 "$temporary_file" "$DASHBOARD_FILE"
    rm -f "$temporary_file"
}

main() {
    local final_exit=0 status

    log_message "INFO" "Health monitoring run started"
    check_disk
    check_memory
    check_cpu
    check_nginx
    check_ssh
    write_dashboard

    for status in "${CHECK_STATUSES[@]}"; do
        [[ "$status" == "WARNING" ]] && final_exit=1
    done

    log_message "INFO" "Health monitoring run completed with exit code $final_exit"
    return "$final_exit"
}

main "$@"

