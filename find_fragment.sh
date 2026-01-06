#!/usr/bin/env bash
# find_fragment.sh — Test different fragment configurations

set -euo pipefail

######################## Color Logger ####################################
if command -v tput >/dev/null; then
  NONE=$(tput sgr0);   RED=$(tput setaf 1);  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3); CYAN=$(tput setaf 6); GRAY=$(tput setaf 7)
else
  NONE=$'\033[0m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; CYAN=$'\033[36m'; GRAY=$'\033[37m'
fi

log() {
  local lvl=$1; shift
  local ts=$(date '+%F %T')
  local colour=$NONE
  case $lvl in
    info) colour=$CYAN;;
    warn) colour=$YELLOW;;
    error) colour=$RED;;
    success) colour=$GREEN;;
  esac
  printf '%s%s %-7s%s : %s\n' "$colour" "$ts" "$(echo "$lvl" | tr '[:lower:]' '[:upper:]')" "$NONE" "$*"
}

######################## Fibonacci Generator ####################################
# Fibonacci numbers: 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233...
FIBONACCI=(1 2 3 5 8 13 21 34 55 89 144 233)

######################## Configuration ####################################
V2RAY_CONFIG=""
V2RAY_BINARY=""
TEST_URL="https://www.google.com"
TEST_DURATION=10  # seconds to test each configuration
SOCKS_PORT=1080
RESULTS_FILE=""

######################## Get V2Ray Config ####################################
while true; do
  read -p "Enter path to your v2ray config file: " CONFIG_PATH
  if [[ -f "$CONFIG_PATH" ]]; then
    V2RAY_CONFIG="$CONFIG_PATH"
    break
  else
    log error "File not found: $CONFIG_PATH"
  fi
done

# Create backup of original config
BACKUP_CONFIG="${V2RAY_CONFIG}.backup-$(date +%s)"
cp "$V2RAY_CONFIG" "$BACKUP_CONFIG"
log info "Backed up config to: $BACKUP_CONFIG"

######################## Find V2Ray Binary ####################################
# Check if config uses xhttp (requires Xray)
CONFIG_USES_XHTTP=false
if grep -q '"xhttp"' "$V2RAY_CONFIG" 2>/dev/null || grep -q '"network".*:.*"xhttp"' "$V2RAY_CONFIG" 2>/dev/null; then
  CONFIG_USES_XHTTP=true
  log info "Config uses XHTTP protocol - Xray is required"
fi

# Prefer Xray if config uses XHTTP, otherwise check both
if [[ "$CONFIG_USES_XHTTP" == true ]]; then
  if command -v xray >/dev/null 2>&1; then
    V2RAY_BINARY="xray"
  elif [[ -f /usr/local/bin/xray ]]; then
    V2RAY_BINARY="/usr/local/bin/xray"
  else
    log error "XHTTP protocol requires Xray, but it's not found in PATH"
    log error "Install Xray: brew install xray"
    log error "Or add Xray to your PATH"
    exit 1
  fi
else
  # Standard detection (prefer v2ray for non-XHTTP configs)
  if command -v v2ray >/dev/null 2>&1; then
    V2RAY_BINARY="v2ray"
  elif command -v xray >/dev/null 2>&1; then
    V2RAY_BINARY="xray"
    log info "Using Xray instead of V2Ray"
  elif [[ -f /usr/local/bin/v2ray ]]; then
    V2RAY_BINARY="/usr/local/bin/v2ray"
  elif [[ -f /usr/local/bin/xray ]]; then
    V2RAY_BINARY="/usr/local/bin/xray"
    log info "Using Xray instead of V2Ray"
  else
    log error "V2Ray or Xray binary not found. Please install v2ray or xray first."
    exit 1
  fi
fi

log info "Using binary: $V2RAY_BINARY"

######################## Setup Results ####################################
RESULTS_DIR="$(pwd)/fragment-test-results"
mkdir -p "$RESULTS_DIR"
RESULTS_FILE="$RESULTS_DIR/results-$(date +%F-%H%M%S).txt"

echo "# Fragment Configuration Test Results" > "$RESULTS_FILE"
echo "# Test Date: $(date)" >> "$RESULTS_FILE"
echo "# Original Config: $V2RAY_CONFIG" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"
printf "%-15s %-15s %-12s %-12s %-12s %-12s %s\n" \
  "Interval" "Length" "Packets" "Success" "Avg Speed" "Avg Latency" "Score" >> "$RESULTS_FILE"
echo "--------------------------------------------------------------------------------" >> "$RESULTS_FILE"

######################## Test Function ####################################
test_fragment_config() {
  local interval=$1
  local length=$2
  local packets=$3
  
  log info "Testing: interval=$interval, length=$length, packets=$packets" >&2
  
  # Update config with new fragment settings
  python3 py/fragment.py "$V2RAY_CONFIG" "$interval" "$length" "$packets"

  # Kill any existing v2ray/xray processes first
  pkill -f "$V2RAY_BINARY" 2>/dev/null || true
  sleep 1
  
  # Start v2ray with new config and capture output for debugging
  local v2ray_log=$(mktemp)
  $V2RAY_BINARY run -c "$V2RAY_CONFIG" > "$v2ray_log" 2>&1 &
  local v2ray_pid=$!
  
  # Wait for v2ray to start and check if it's actually running
  sleep 5
  
  # Check if the process or any v2ray/xray is running (might fork/daemonize)
  if ! pgrep -f "$V2RAY_BINARY.*$V2RAY_CONFIG" >/dev/null 2>&1; then
    local error_log=$(cat "$v2ray_log" 2>/dev/null)
    
    # Check for XHTTP protocol error
    if echo "$error_log" | grep -q "unknown transport protocol: xhttp"; then
      log error "XHTTP protocol requires Xray, not V2Ray!" >&2
      log error "Install Xray: brew install xray" >&2
      log error "Then restart this script and it will detect Xray automatically" >&2
      rm -f "$v2ray_log"
      exit 1
    fi
    
    log error "V2Ray/Xray failed to start with this configuration" >&2
    log error "Check log: $(echo "$error_log" | head -5 | tr '\n' ' ')" >&2
    printf "%-15s %-15s %-12s %-12s %-12s %-12s %s\n" \
      "$interval" "$length" "$packets" "FAILED" "0KB/s" "0ms" "0.00" >> "$RESULTS_FILE"
    rm -f "$v2ray_log"
    echo "0"
    return 0
  fi
  rm -f "$v2ray_log"
  
  # Test connection
  local success_count=0
  local total_tests=5
  local total_time=0
  local total_speed=0
  
  for i in $(seq 1 $total_tests); do
    # Test with curl through SOCKS proxy
    local start_time=$(date +%s%N)
    if curl -x socks5h://127.0.0.1:$SOCKS_PORT \
            --max-time 10 \
            --silent \
            --output /dev/null \
            --write-out "%{http_code}" \
            "$TEST_URL" 2>/dev/null | grep -q "200"; then
      local end_time=$(date +%s%N)
      local duration=$(( (end_time - start_time) / 1000000 ))  # Convert to ms
      total_time=$((total_time + duration))
      success_count=$((success_count + 1))
      
      # Download speed test (download 1MB)
      local speed=$(curl -x socks5h://127.0.0.1:$SOCKS_PORT \
                         --max-time 10 \
                         --silent \
                         --output /dev/null \
                         --write-out "%{speed_download}" \
                         "https://speed.cloudflare.com/__down?bytes=1048576" 2>/dev/null || echo "0")
      total_speed=$(echo "$total_speed + $speed" | bc)
    fi
    sleep 1
  done
  
  # Stop v2ray
  pkill -f "$V2RAY_BINARY" 2>/dev/null || true
  sleep 2
  
  # Calculate metrics
  local success_rate=$((success_count * 100 / total_tests))
  local avg_latency=0
  local avg_speed=0
  
  if [[ $success_count -gt 0 ]]; then
    avg_latency=$((total_time / success_count))
    avg_speed=$(echo "scale=2; $total_speed / $success_count / 1024" | bc)  # KB/s
  fi
  
  # Calculate score (higher is better)
  # Score = (success_rate * 0.5) + (speed_normalized * 0.3) + (latency_score * 0.2)
  local speed_normalized=$avg_speed
  if (( $(echo "$speed_normalized > 100" | bc -l) )); then
    speed_normalized=100
  fi
  
  local latency_score=0
  if [[ $avg_latency -gt 0 ]] && [[ $avg_latency -lt 10000 ]]; then
    latency_score=$(echo "scale=2; 100 - ($avg_latency / 100)" | bc)
    if (( $(echo "$latency_score < 0" | bc -l) )); then
      latency_score=0
    fi
  fi
  
  local score=$(echo "scale=2; ($success_rate * 0.5) + ($speed_normalized * 0.3) + ($latency_score * 0.2)" | bc)
  
  # Log results
  printf "%-15s %-15s %-12s %-12s %-12s %-12s %.2f\n" \
    "$interval" "$length" "$packets" "${success_rate}%" "${avg_speed}KB/s" "${avg_latency}ms" "$score" \
    >> "$RESULTS_FILE"
  
  if [[ $success_rate -gt 0 ]]; then
    log success "Success: ${success_rate}%, Speed: ${avg_speed}KB/s, Latency: ${avg_latency}ms, Score: $score" >&2
  else
    log error "All tests failed for this configuration" >&2
  fi
  
  # Return score (multiply by 100 to avoid floating point in bash)
  echo "$(echo "$score * 100" | bc | cut -d. -f1)"
}

######################## Main Testing Loop ####################################
log info "Generating all test configurations..."

BEST_SCORE=0
BEST_CONFIG=""

# Packet options to test
PACKET_OPTIONS=("1-1" "1-3" "tlshello")

# Generate interval ranges from Fibonacci (e.g., "1-2", "2-3", "3-5", "5-8", etc.)
INTERVAL_RANGES=()
for i in $(seq 0 $((${#FIBONACCI[@]} - 2))); do
  for j in $(seq $((i + 1)) $((${#FIBONACCI[@]} - 1))); do
    INTERVAL_RANGES+=("${FIBONACCI[$i]}-${FIBONACCI[$j]}")
  done
done

# Generate length ranges from Fibonacci
LENGTH_RANGES=()
for i in $(seq 0 $((${#FIBONACCI[@]} - 2))); do
  for j in $(seq $((i + 1)) $((${#FIBONACCI[@]} - 1))); do
    LENGTH_RANGES+=("${FIBONACCI[$i]}-${FIBONACCI[$j]}")
  done
done

# Generate all test combinations
TEST_CONFIGS=()
for interval in "${INTERVAL_RANGES[@]}"; do
  for length in "${LENGTH_RANGES[@]}"; do
    for packets in "${PACKET_OPTIONS[@]}"; do
      TEST_CONFIGS+=("$interval|$length|$packets")
    done
  done
done

TOTAL_TESTS=${#TEST_CONFIGS[@]}
log info "Generated $TOTAL_TESTS test configurations"

# Shuffle the test configurations for random sampling
log info "Shuffling test order for random sampling..."
SHUFFLED_CONFIGS=()
if command -v shuf >/dev/null 2>&1; then
  # Use shuf command if available
  while IFS= read -r line; do
    SHUFFLED_CONFIGS+=("$line")
  done < <(printf '%s\n' "${TEST_CONFIGS[@]}" | shuf)
else
  # Simple shuffle algorithm if shuf is not available
  SHUFFLED_CONFIGS=("${TEST_CONFIGS[@]}")
  for ((i=${#SHUFFLED_CONFIGS[@]}-1; i>0; i--)); do
    j=$((RANDOM % (i+1)))
    # Swap elements
    temp="${SHUFFLED_CONFIGS[i]}"
    SHUFFLED_CONFIGS[i]="${SHUFFLED_CONFIGS[j]}"
    SHUFFLED_CONFIGS[j]="$temp"
  done
fi

log info "Starting fragment configuration tests..."
log info "Tests are randomized - stopping early will still give diverse results"
log info "This may take a while..."
log info "Press CTRL+C to stop testing and see results from completed tests"

# Setup graceful shutdown on CTRL+C
INTERRUPTED=false
trap 'INTERRUPTED=true; log warn "Interrupt received. Will stop after current test..."' SIGINT

CURRENT_TEST=0

for config in "${SHUFFLED_CONFIGS[@]}"; do
  # Check if interrupted by CTRL+C
  if [[ "$INTERRUPTED" == true ]]; then
    log info "Stopping tests early due to interrupt"
    break
  fi
  
  CURRENT_TEST=$((CURRENT_TEST + 1))
  
  # Parse config
  interval=$(echo "$config" | cut -d'|' -f1)
  length=$(echo "$config" | cut -d'|' -f2)
  packets=$(echo "$config" | cut -d'|' -f3)
  
  echo ""
  log info "Progress: ${CURRENT_TEST}/${TOTAL_TESTS}"
  
  score=$(test_fragment_config "$interval" "$length" "$packets") || true
  
  if [[ $score -gt $BEST_SCORE ]]; then
    BEST_SCORE=$score
    BEST_CONFIG="interval=$interval, length=$length, packets=$packets"
    log success "New best configuration found! Score: $(echo "scale=2; $score / 100" | bc)"
  fi
  
  # Small delay between tests (allow interrupt during sleep)
  sleep 2 || true
done

# Disable trap after loop
trap - SIGINT

######################## Restore Original Config ####################################
cp "$BACKUP_CONFIG" "$V2RAY_CONFIG" && rm "$BACKUP_CONFIG"
log info "Restored original config"

######################## Summary ####################################
echo ""
echo "================================================================================"
log success "Testing Complete!"
echo "================================================================================"
echo ""
log info "Best Configuration:"
echo "  $BEST_CONFIG"
echo "  Score: $(echo "scale=2; $BEST_SCORE / 100" | bc)"
echo ""
log info "Detailed results saved to: $RESULTS_FILE"
echo ""
log info "To apply the best configuration, update your v2ray config fragment settings:"
echo "  ${CYAN}$BEST_CONFIG${NONE}"
echo ""

exit 0
