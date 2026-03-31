#!/bin/bash
#===============================================================================
# wp-toolkit-login-button-sync.sh v1.2
#
# แก้ปัญหา: ปุ่ม Login ใน WP Toolkit ไม่ sync password
#           เมื่อเปลี่ยน User/Password ใน WordPress dashboard
#
# สาเหตุ:  WP Toolkit เก็บสำเนา password แยก — ไม่มี sync กลับจาก WordPress
#           เปลี่ยน password ใน WP dashboard → WP Toolkit ยังเก็บ password เก่า
#           → ปุ่ม Login ใช้ password เก่า → login ไม่ได้
#
# รองรับ 2 path structures:
#   - /home/USERNAME/DOMAIN/
#   - /home/USERNAME/public_html/DOMAIN/
#
# อ่าน addon domains จาก /etc/userdomains + /etc/trueuserdomains
#
# Install:
#   curl -sL https://raw.githubusercontent.com/AnonymousVS/WP-Toolkit-Login-Button-Sync/main/wp-toolkit-login-button-sync.sh -o /usr/local/sbin/wp-toolkit-login-button-sync.sh && chmod +x /usr/local/sbin/wp-toolkit-login-button-sync.sh && echo "✓ Installed"
#
# Usage:
#   wp-toolkit-login-button-sync.sh check                       # ตรวจสอบทั้งหมด
#   wp-toolkit-login-button-sync.sh check --user y2026m02sv01   # เฉพาะ user
#   wp-toolkit-login-button-sync.sh fix                         # แก้ไขทั้งหมด (ถาม confirm)
#   wp-toolkit-login-button-sync.sh fix --yes                   # แก้ไขทั้งหมด (ไม่ถาม, สำหรับ cron)
#   wp-toolkit-login-button-sync.sh fix --user y2026m02sv01     # เฉพาะ user
#   wp-toolkit-login-button-sync.sh fix --dry-run               # ทดสอบก่อน
#   wp-toolkit-login-button-sync.sh setup-cron                  # ตั้ง cron รันทุกวัน ตี 4
#
# GitHub: https://github.com/AnonymousVS/WP-Toolkit-Login-Button-Sync
# Author: AnonymousVS
#===============================================================================

set -uo pipefail

# ==============================================================================
# Configuration
# ==============================================================================
SCRIPT_NAME="wp-toolkit-login-button-sync.sh"
SCRIPT_PATH="/usr/local/sbin/${SCRIPT_NAME}"
WPTK="/usr/local/bin/wp-toolkit"
USERDOMAINS="/etc/userdomains"
TRUEUSERDOMAINS="/etc/trueuserdomains"
LOG_DIR="/var/log/wp-toolkit-sync"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/sync-${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/report-${TIMESTAMP}.txt"
CRON_SCHEDULE="0 4 * * *"
CRON_CMD="${SCRIPT_PATH} fix --yes >> ${LOG_DIR}/daily.log 2>&1"
SLEEP_BETWEEN=0.2
START_TIME=$(date +%s)

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2m'; N='\033[0m'

# Spinner
SPIN_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
SPIN_PID=""

# Counters
declare -i TOTAL=0 NEED_SYNC=0 ALREADY_OK=0 NO_WP=0 BROKEN=0
declare -i FIXED=0 FIX_FAILED=0 SKIPPED=0

# Options
DRY_RUN=false
FILTER_USER=""
COMMAND=""
AUTO_YES=false

# ==============================================================================
# Usage
# ==============================================================================
usage() {
    cat << EOF

WP Toolkit Login Button Sync — แก้ปุ่ม Login ใน WP Toolkit ไม่ sync password

Usage: ${SCRIPT_NAME} <COMMAND> [OPTIONS]

COMMANDS:
  check       ตรวจสอบทุก addon domain ว่าปุ่ม Login sync อยู่หรือไม่
  fix         แก้ไข — sync password ให้ปุ่ม Login ใช้ได้
  setup-cron  ตั้ง cron รันทุกวัน ตี 4 อัตโนมัติ
  remove-cron ลบ cron ออก

OPTIONS:
  --user <cpanel_user>   เฉพาะ cPanel user ที่ระบุ
  --dry-run              ทดสอบก่อน ไม่เปลี่ยนจริง
  --yes                  ไม่ถาม confirm (สำหรับ cron)
  --help                 แสดงข้อความนี้

EOF
    exit 0
}

# ==============================================================================
# Spinner
# ==============================================================================
spinner_start() {
    local msg="$1"
    {
        local i=0
        while true; do
            local char="${SPIN_CHARS:i%${#SPIN_CHARS}:1}"
            printf "\r  ${C}%s${N} %s" "$char" "$msg"
            sleep 0.1
            ((i++))
        done
    } &
    SPIN_PID=$!
    disown "$SPIN_PID" 2>/dev/null
}

spinner_stop() {
    if [[ -n "$SPIN_PID" ]] && kill -0 "$SPIN_PID" 2>/dev/null; then
        kill "$SPIN_PID" 2>/dev/null
        wait "$SPIN_PID" 2>/dev/null
    fi
    SPIN_PID=""
    printf "\r  ${G}[✓]${N} "
}

elapsed() {
    local now=$(date +%s)
    local diff=$((now - START_TIME))
    local min=$((diff / 60))
    local sec=$((diff % 60))
    (( min > 0 )) && echo "${min}m${sec}s" || echo "${sec}s"
}

progress() {
    local current=$1 total=$2 domain=$3 status=$4
    local pct=0
    (( total > 0 )) && pct=$(( current * 100 / total ))
    local bar=""
    local i
    local filled=$(( pct * 25 / 100 ))
    local empty=$(( 25 - filled ))
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    printf "\r  ${C}[%3d%%]${N} %s %d/%d ${DIM}%s${N}  %-35s %s    " \
        "$pct" "$bar" "$current" "$total" "$(elapsed)" "$domain" "$status"
}

# ==============================================================================
# Logging
# ==============================================================================
log() {
    local lvl="$1"; shift
    echo "$(date '+%H:%M:%S') [${lvl}] $*" >> "$LOG_FILE"
}

# ==============================================================================
# Pre-checks
# ==============================================================================
check_requirements() {
    [[ $EUID -ne 0 ]] && { echo -e "${R}Error: ต้องรัน root${N}"; exit 1; }
    [[ ! -x "$WPTK" ]] && { echo -e "${R}Error: ไม่พบ ${WPTK}${N}"; exit 1; }
    [[ ! -f "$USERDOMAINS" ]] && { echo -e "${R}Error: ไม่พบ ${USERDOMAINS}${N}"; exit 1; }
    [[ ! -f "$TRUEUSERDOMAINS" ]] && { echo -e "${R}Error: ไม่พบ ${TRUEUSERDOMAINS}${N}"; exit 1; }
    mkdir -p "$LOG_DIR"
}

check_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${R}Error: ต้องรัน root${N}"; exit 1; }
    mkdir -p "$LOG_DIR"
}

# ==============================================================================
# Build WP Toolkit instance index
# ใช้ domain จาก URL ใน --list (เรียกครั้งเดียว เร็วมาก)
# ไม่ต้องเรียก --info ทีละ instance อีก
# ==============================================================================
declare -A WPTK_DOMAIN_TO_ID=()

build_wptk_index() {
    spinner_start "กำลังโหลด WP Toolkit instances..."

    local count=0
    while IFS= read -r line; do
        local id url domain
        id=$(echo "$line" | awk '{print $1}')
        [[ -z "$id" || ! "$id" =~ ^[0-9]+$ ]] && continue

        url=$(echo "$line" | awk '{print $2}')
        [[ -z "$url" ]] && continue

        domain=$(echo "$url" | sed 's|https\?://||;s|/.*||;s|:.*||')
        [[ -n "$domain" ]] && WPTK_DOMAIN_TO_ID["$domain"]="$id"

        ((count++))
    done < <($WPTK --list 2>/dev/null | awk 'NR>1')

    spinner_stop
    echo "โหลด WP Toolkit instances: ${C}${count}${N} ${DIM}($(elapsed))${N}"
    echo ""
}

# ==============================================================================
# Get addon domains จาก /etc/userdomains
# ==============================================================================
get_addon_domains() {
    declare -A main_domains=()
    while IFS=': ' read -r domain user rest; do
        domain=$(echo "$domain" | tr -d '[:space:]')
        user=$(echo "$user" | tr -d '[:space:]')
        [[ -n "$domain" && -n "$user" ]] && main_domains["$domain"]="$user"
    done < "$TRUEUSERDOMAINS"

    while IFS=': ' read -r domain user rest; do
        domain=$(echo "$domain" | tr -d '[:space:]')
        user=$(echo "$user" | tr -d '[:space:]')

        [[ -z "$domain" || -z "$user" ]] && continue
        [[ "$user" == "nobody" ]] && continue
        [[ "$domain" == "*" ]] && continue
        [[ "$domain" == *".cp:"* ]] && continue
        [[ -n "${main_domains[$domain]:-}" ]] && continue

        local is_cpanel_sub=false
        for main_dom in "${!main_domains[@]}"; do
            [[ "$domain" == *".${main_dom}" ]] && { is_cpanel_sub=true; break; }
        done
        $is_cpanel_sub && continue

        [[ -n "$FILTER_USER" && "$user" != "$FILTER_USER" ]] && continue

        echo "${domain} ${user}"
    done < "$USERDOMAINS"
}

# ==============================================================================
# หา WordPress document root (2 path structures)
# ==============================================================================
find_wp_root() {
    local user="$1" domain="$2"
    local p="/home/${user}/${domain}"
    [[ -f "${p}/wp-config.php" ]] && { echo "$p"; return 0; }
    p="/home/${user}/public_html/${domain}"
    [[ -f "${p}/wp-config.php" ]] && { echo "$p"; return 0; }
    return 1
}

# ==============================================================================
# หา WP Toolkit instance ID จาก domain
# ==============================================================================
find_wptk_instance() {
    local domain="$1"
    local id="${WPTK_DOMAIN_TO_ID[$domain]:-}"
    [[ -n "$id" ]] && { echo "$id"; return 0; }
    id="${WPTK_DOMAIN_TO_ID[www.${domain}]:-}"
    [[ -n "$id" ]] && { echo "$id"; return 0; }
    return 1
}

# ==============================================================================
# ตรวจ Login status: 0=OK, 1=NEED_SYNC, 2=BROKEN
# ==============================================================================
check_login_status() {
    local instance_id="$1"
    local info
    info=$($WPTK --info -instance-id "$instance_id" 2>&1) || return 2
    echo "$info" | grep -qi "broken\|error\|failed" && return 2

    local admin_check
    admin_check=$($WPTK --wp-cli -instance-id "$instance_id" -- user list \
        --role=administrator --fields=ID,user_login --format=csv 2>&1) || return 2

    local admin_count
    admin_count=$(echo "$admin_check" | grep -c "," 2>/dev/null || echo 0)
    [[ $admin_count -eq 0 ]] && return 2

    echo "$info" | grep -qi "administrator.*password\|password.*stored\|credentials" && return 0
    return 1
}

# ==============================================================================
# Sync password
# ==============================================================================
sync_instance_password() {
    local instance_id="$1"
    local result

    result=$($WPTK --setup -instance-id "$instance_id" -generate-admin-password 2>&1)
    [[ $? -eq 0 ]] && { echo "OK"; return 0; }

    local admin_login
    admin_login=$($WPTK --wp-cli -instance-id "$instance_id" -- user list \
        --role=administrator --field=user_login 2>/dev/null | head -1 | tr -d '[:space:]')

    if [[ -n "$admin_login" ]]; then
        result=$($WPTK --setup -instance-id "$instance_id" \
            -generate-admin-password -admin-login "$admin_login" 2>&1)
        [[ $? -eq 0 ]] && { echo "OK (admin: ${admin_login})"; return 0; }
    fi

    echo "FAILED: ${result}"
    return 1
}

# ==============================================================================
# COMMAND: setup-cron
# ==============================================================================
cmd_setup_cron() {
    echo ""
    echo -e "${C}══════════════════════════════════════════════════════════════════${N}"
    echo -e "${C}  Setup Cron — รันทุกวัน ตี 4${N}"
    echo -e "${C}══════════════════════════════════════════════════════════════════${N}"
    echo ""

    if [[ ! -f "$SCRIPT_PATH" ]]; then
        spinner_start "Copy script ไป ${SCRIPT_PATH}..."
        cp "$(readlink -f "$0")" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        spinner_stop
        echo "Copy สำเร็จ"
        echo ""
    fi

    spinner_start "ตั้ง cron job..."
    (crontab -l 2>/dev/null | grep -v "wp-toolkit-login-button-sync"; echo "${CRON_SCHEDULE} ${CRON_CMD}") | crontab -
    spinner_stop

    if crontab -l 2>/dev/null | grep -q "wp-toolkit-login-button-sync"; then
        echo "Cron ตั้งเรียบร้อย"
        echo ""
        echo -e "  Schedule:  ${W}ทุกวัน ตี 4:00${N}"
        echo -e "  Command:   ${DIM}${SCRIPT_PATH} fix --yes${N}"
        echo -e "  Log:       ${DIM}${LOG_DIR}/daily.log${N}"
        echo ""
        echo -e "  ${DIM}ตรวจสอบ: crontab -l | grep wp-toolkit${N}"
        echo -e "  ${DIM}ลบ cron: ${SCRIPT_NAME} remove-cron${N}"
    else
        echo -e "${R}ตั้ง cron ไม่สำเร็จ${N}"
    fi
    echo ""
}

# ==============================================================================
# COMMAND: remove-cron
# ==============================================================================
cmd_remove_cron() {
    echo ""
    spinner_start "ลบ cron..."
    (crontab -l 2>/dev/null | grep -v "wp-toolkit-login-button-sync") | crontab -
    spinner_stop
    if ! crontab -l 2>/dev/null | grep -q "wp-toolkit-login-button-sync"; then
        echo "Cron ถูกลบเรียบร้อย"
    else
        echo -e "${R}ลบ cron ไม่สำเร็จ${N}"
    fi
    echo ""
}

# ==============================================================================
# COMMAND: check
# ==============================================================================
cmd_check() {
    echo ""
    echo -e "${C}══════════════════════════════════════════════════════════════════${N}"
    echo -e "${C}  WP Toolkit Login Button Sync — CHECK${N}"
    echo -e "${C}══════════════════════════════════════════════════════════════════${N}"
    echo ""
    [[ -n "$FILTER_USER" ]] && echo -e "  Filter: ${C}${FILTER_USER}${N}" && echo ""

    build_wptk_index

    spinner_start "กำลังอ่าน addon domains..."
    local domains=()
    while IFS=' ' read -r domain user; do
        domains+=("${domain}|${user}")
    done < <(get_addon_domains)
    TOTAL=${#domains[@]}
    spinner_stop
    echo "พบ ${C}${TOTAL}${N} addon domains ${DIM}($(elapsed))${N}"
    echo ""

    [[ $TOTAL -eq 0 ]] && { echo -e "  ${Y}ไม่พบ addon domain${N}"; return; }

    {
        echo "WP Toolkit Login Button Sync Report — $(date)"
        echo "Server: $(hostname)"
        [[ -n "$FILTER_USER" ]] && echo "Filter: ${FILTER_USER}"
        echo "============================================================"
        printf "%-35s %-18s %-8s %-12s %s\n" "DOMAIN" "USER" "WPT_ID" "STATUS" "PATH"
    } > "$REPORT_FILE"

    local n=0
    for entry in "${domains[@]}"; do
        IFS='|' read -r domain user <<< "$entry"
        ((n++))

        local wp_root
        wp_root=$(find_wp_root "$user" "$domain")
        if [[ -z "$wp_root" ]]; then
            progress $n $TOTAL "$domain" "${DIM}no-wp${N}     "
            printf "%-35s %-18s %-8s %-12s %s\n" "$domain" "$user" "-" "NO_WP" "-" >> "$REPORT_FILE"
            ((NO_WP++)); continue
        fi

        local instance_id
        instance_id=$(find_wptk_instance "$domain") || instance_id=""
        if [[ -z "$instance_id" ]]; then
            progress $n $TOTAL "$domain" "${DIM}no-wptk${N}   "
            printf "%-35s %-18s %-8s %-12s %s\n" "$domain" "$user" "-" "NO_WPTK" "$wp_root" >> "$REPORT_FILE"
            ((NO_WP++)); continue
        fi

        check_login_status "$instance_id"
        case $? in
            0) progress $n $TOTAL "$domain" "${G}ok${N}        "
               printf "%-35s %-18s %-8s %-12s %s\n" "$domain" "$user" "$instance_id" "OK" "$wp_root" >> "$REPORT_FILE"
               ((ALREADY_OK++)) ;;
            1) progress $n $TOTAL "$domain" "${Y}need-sync${N} "
               printf "%-35s %-18s %-8s %-12s %s\n" "$domain" "$user" "$instance_id" "NEED_SYNC" "$wp_root" >> "$REPORT_FILE"
               ((NEED_SYNC++)) ;;
            2) progress $n $TOTAL "$domain" "${R}broken${N}    "
               printf "%-35s %-18s %-8s %-12s %s\n" "$domain" "$user" "$instance_id" "BROKEN" "$wp_root" >> "$REPORT_FILE"
               ((BROKEN++)) ;;
        esac
        sleep "$SLEEP_BETWEEN"
    done

    printf "\r%100s\r" ""
    print_check_summary
}

# ==============================================================================
# COMMAND: fix
# ==============================================================================
cmd_fix() {
    echo ""
    echo -e "${C}══════════════════════════════════════════════════════════════════${N}"
    echo -e "${C}  WP Toolkit Login Button Sync — FIX${N}"
    echo -e "${C}══════════════════════════════════════════════════════════════════${N}"
    echo ""
    $DRY_RUN && echo -e "  ${Y}*** DRY RUN ***${N}" && echo ""
    [[ -n "$FILTER_USER" ]] && echo -e "  Filter: ${C}${FILTER_USER}${N}" && echo ""

    build_wptk_index

    spinner_start "กำลังอ่าน addon domains..."
    local domains=()
    while IFS=' ' read -r domain user; do
        domains+=("${domain}|${user}")
    done < <(get_addon_domains)
    TOTAL=${#domains[@]}
    spinner_stop
    echo "พบ ${C}${TOTAL}${N} addon domains ${DIM}($(elapsed))${N}"
    echo ""

    [[ $TOTAL -eq 0 ]] && { echo -e "  ${Y}ไม่พบ addon domain${N}"; return; }

    if ! $DRY_RUN && ! $AUTO_YES; then
        echo -e "  ${Y}จะตรวจแต่ละ site — เฉพาะที่ต้อง sync เท่านั้นจะถูกแก้${N}"
        echo ""
        read -p "  ดำเนินการ? (y/N): " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "  ยกเลิก"; return; }
        echo ""
    fi

    {
        echo "WP Toolkit Login Button Sync Fix Report — $(date)"
        echo "Dry Run: ${DRY_RUN}"
        echo "============================================================"
        printf "%-35s %-18s %-8s %-12s %s\n" "DOMAIN" "USER" "WPT_ID" "ACTION" "RESULT"
    } > "$REPORT_FILE"

    local n=0
    for entry in "${domains[@]}"; do
        IFS='|' read -r domain user <<< "$entry"
        ((n++))

        local wp_root
        wp_root=$(find_wp_root "$user" "$domain")
        if [[ -z "$wp_root" ]]; then
            progress $n $TOTAL "$domain" "${DIM}skip${N}      "
            printf "%-35s %-18s %-8s %-12s %s\n" "$domain" "$user" "-" "SKIP" "no WordPress" >> "$REPORT_FILE"
            ((SKIPPED++)); continue
        fi

        local instance_id
        instance_id=$(find_wptk_instance "$domain") || instance_id=""
        if [[ -z "$instance_id" ]]; then
            progress $n $TOTAL "$domain" "${DIM}skip${N}      "
            printf "%-35s %-18s %-8s %-12s %s\n" "$domain" "$user" "-" "SKIP" "not in WP Toolkit" >> "$REPORT_FILE"
            ((SKIPPED++)); continue
        fi

        check_login_status "$instance_id"
        local status=$?

        if [[ $status -eq 0 ]]; then
            progress $n $TOTAL "$domain" "${G}ok${N}        "
            printf "%-35s %-18s %-8s %-12s %s\n" "$domain" "$user" "$instance_id" "ALREADY_OK" "-" >> "$REPORT_FILE"
            ((ALREADY_OK++))
        elif $DRY_RUN; then
            local label="[DRY]sync"
            [[ $status -eq 2 ]] && label="[DRY]broken"
            progress $n $TOTAL "$domain" "${Y}${label}${N}  "
            printf "%-35s %-18s %-8s %-12s %s\n" "$domain" "$user" "$instance_id" "$label" "-" >> "$REPORT_FILE"
            [[ $status -eq 1 ]] && ((NEED_SYNC++))
            [[ $status -eq 2 ]] && ((BROKEN++))
        else
            progress $n $TOTAL "$domain" "${Y}syncing...${N}"
            local result
            result=$(sync_instance_password "$instance_id")
            if [[ "$result" == OK* ]]; then
                progress $n $TOTAL "$domain" "${G}fixed ✓${N}   "
                printf "%-35s %-18s %-8s %-12s %s\n" "$domain" "$user" "$instance_id" "FIXED" "$result" >> "$REPORT_FILE"
                ((FIXED++))
            else
                progress $n $TOTAL "$domain" "${R}failed ✗${N}  "
                printf "%-35s %-18s %-8s %-12s %s\n" "$domain" "$user" "$instance_id" "FAILED" "$result" >> "$REPORT_FILE"
                ((FIX_FAILED++))
            fi
        fi

        sleep "$SLEEP_BETWEEN"
    done

    printf "\r%100s\r" ""
    print_fix_summary
}

# ==============================================================================
# Summaries
# ==============================================================================
print_check_summary() {
    echo ""
    echo -e "${C}══════════════════════════════════════════════════════════════════${N}"
    echo -e "${C}  CHECK RESULTS                                 ${DIM}elapsed: $(elapsed)${N}"
    echo -e "${C}══════════════════════════════════════════════════════════════════${N}"
    echo ""
    echo -e "  Total addon domains:   ${W}${TOTAL}${N}"
    echo ""
    echo -e "  ${G}✓${N} OK (synced):          ${G}${ALREADY_OK}${N}"
    echo -e "  ${Y}!${N} Need sync:            ${Y}${NEED_SYNC}${N}"
    echo -e "  ${R}✗${N} Broken/Error:         ${R}${BROKEN}${N}"
    echo -e "  ${C}→${N} No WordPress/Toolkit: ${C}${NO_WP}${N}"
    echo ""
    if [[ $NEED_SYNC -gt 0 ]]; then
        echo -e "  ${Y}→ มี ${NEED_SYNC} site ที่ต้อง sync${N}"
        echo -e "  ${Y}  รัน: ${SCRIPT_NAME} fix${N}"
        echo ""
    fi
    echo -e "  ${DIM}Report: ${REPORT_FILE}${N}"
    echo ""
}

print_fix_summary() {
    echo ""
    echo -e "${C}══════════════════════════════════════════════════════════════════${N}"
    echo -e "${C}  FIX RESULTS                                   ${DIM}elapsed: $(elapsed)${N}"
    echo -e "${C}══════════════════════════════════════════════════════════════════${N}"
    echo ""
    echo -e "  Total addon domains:   ${W}${TOTAL}${N}"
    echo ""
    echo -e "  ${G}✓${N} Already OK:           ${G}${ALREADY_OK}${N}"
    echo -e "  ${G}✓${N} Fixed:                ${G}${FIXED}${N}"
    $DRY_RUN && echo -e "  ${Y}!${N} Would sync (dry-run): ${Y}${NEED_SYNC}${N}"
    echo -e "  ${R}✗${N} Fix failed:           ${R}${FIX_FAILED}${N}"
    echo -e "  ${R}✗${N} Broken:               ${R}${BROKEN}${N}"
    echo -e "  ${C}→${N} Skipped:              ${C}${SKIPPED}${N}"
    echo ""
    if [[ $FIXED -gt 0 ]]; then
        echo -e "  ${G}✓ ปุ่ม Login ใช้ได้แล้ว ${FIXED} sites${N}"
        echo ""
    fi
    if $DRY_RUN && [[ $NEED_SYNC -gt 0 ]]; then
        echo -e "  ${Y}→ รัน: ${SCRIPT_NAME} fix${N}"
        echo ""
    fi
    if [[ $FIX_FAILED -gt 0 ]]; then
        echo -e "  ${R}! ${FIX_FAILED} site fix ไม่สำเร็จ — ดูใน report${N}"
        echo ""
    fi
    echo -e "  ${DIM}Report: ${REPORT_FILE}${N}"
    echo ""
}

# ==============================================================================
# Parse Arguments
# ==============================================================================
COMMAND="${1:-}"
[[ -z "$COMMAND" || "$COMMAND" == "--help" || "$COMMAND" == "-h" ]] && usage
shift || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true; shift ;;
        --yes)        AUTO_YES=true; shift ;;
        --user)       FILTER_USER="$2"; shift 2 ;;
        --help|-h)    usage ;;
        *)            echo -e "${R}Unknown: $1${N}"; exit 1 ;;
    esac
done

# ==============================================================================
# Main
# ==============================================================================
case "$COMMAND" in
    setup-cron)   check_root; cmd_setup_cron ;;
    remove-cron)  check_root; cmd_remove_cron ;;
    check)        check_requirements; cmd_check ;;
    fix)          check_requirements; cmd_fix ;;
    *)            echo -e "${R}Unknown command: ${COMMAND}${N}"; usage ;;
esac
