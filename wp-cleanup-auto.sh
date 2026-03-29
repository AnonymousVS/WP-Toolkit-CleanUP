cat > /root/wp-cleanup-auto.sh << 'ENDOFSCRIPT'
#!/bin/bash
# WP-Toolkit-CleanUP by AnonymousVS
# https://github.com/AnonymousVS/WP-Toolkit-CleanUP

FLAG=".wp-cleanup-done"
LOG="/var/log/wp-cleanup.log"
PARALLEL_JOBS=8

chmod +x "$0"

if ! crontab -l 2>/dev/null | grep -q "wp-cleanup-auto.sh"; then
  (crontab -l 2>/dev/null; echo "0 1 * * * /usr/bin/flock -n /tmp/wp-cleanup.lock /root/wp-cleanup-auto.sh") | crontab -
  echo "Cron added: runs daily at 01:00"
fi

if [ ! -f /etc/logrotate.d/wp-cleanup ]; then
  cat > /etc/logrotate.d/wp-cleanup << 'EOF'
/var/log/wp-cleanup.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
}
EOF
  echo "Logrotate configured"
fi

spinner() {
  local pid=$1
  local delay=0.1
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    local count=0
    [ -f "$LOG" ] && count=$(grep -c "Cleaned:" "$LOG" 2>/dev/null || echo 0)
    printf "\r${frames[$i]} Processing... cleaned: %s sites" "$count"
    i=$(( (i+1) % ${#frames[@]} ))
    sleep $delay
  done
  local total=0
  [ -f "$LOG" ] && total=$(grep -c "Cleaned:" "$LOG" 2>/dev/null || echo 0)
  printf "\r✅ Done! Total cleaned: %s sites\n" "$total"
}

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === START ===" >> "$LOG"

cleanup_site() {
  local WP_PATH="$1"
  local FLAG="$2"
  local LOG="$3"

  wp plugin delete akismet hello \
    --path="$WP_PATH" --allow-root --quiet \
    --skip-plugins --skip-themes 2>/dev/null

  wp theme delete \
    twentytwentythree twentytwentyfour twentytwentytwo twentytwentyone twentytwenty \
    --path="$WP_PATH" --allow-root --quiet \
    --skip-plugins --skip-themes 2>/dev/null

  wp config set CORE_UPGRADE_SKIP_NEW_BUNDLED true \
    --raw --path="$WP_PATH" --allow-root --quiet \
    --skip-plugins --skip-themes 2>/dev/null

  touch "$WP_PATH/$FLAG"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaned: $WP_PATH" >> "$LOG"
}

export -f cleanup_site

(
  find /home*/*/public_html -maxdepth 3 -name "wp-config.php" 2>/dev/null \
    | while read cfg; do
        WP_PATH=$(dirname "$cfg")
        [ -f "$WP_PATH/$FLAG" ] && continue
        echo "$WP_PATH"
      done \
    | xargs -P "$PARALLEL_JOBS" -I{} bash -c \
      'cleanup_site "$@"' _ {} "$FLAG" "$LOG"
) &

CLEANUP_PID=$!
spinner $CLEANUP_PID
wait $CLEANUP_PID

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === DONE ===" >> "$LOG"
ENDOFSCRIPT

chmod +x /root/wp-cleanup-auto.sh
