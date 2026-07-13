#!/bin/bash

# List of hosts to monitor (space-separated)
HOSTS=("google.com" "naver.com" "github.com" "example.com")

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to clear screen and print header
display_status() {
    clear
    echo "======================================================"
    echo "  Host Status Monitor (Port 80) - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "======================================================"
    printf "%-20s | %-10s | %-10s\n" "HOST" "STATUS" "HTTP CODE"
    echo "------------------------------------------------------"

    for host in "${HOSTS[@]}"; do
        # curl options:
        # -s: silent mode, -o /dev/null: discard body output, -w: specify output format, --connect-timeout: 2 second timeout
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://$host")

        if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 301 ] || [ "$http_code" -eq 302 ]; then
            status_text="${GREEN}ONLINE${NC}"
        else
            status_text="${RED}OFFLINE${NC}"
        fi

        printf "%-20s | %-20b | %-10s\n" "$host" "$status_text" "$http_code"
    done
    echo "======================================================"
    echo "Press [CTRL+C] to stop."
}

# Infinite loop (update every 2 seconds)
while true; do
    display_status
    sleep 2
done
