#!/usr/bin/env bash
# find_fragment.sh — Test different fragment configurations

set -euo pipefail

######################## Logger ####################################

if command -v tput >/dev/null; then
  NONE=$(tput sgr0)
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  CYAN=$(tput setaf 6)
else
  NONE=$'\033[0m'
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  CYAN=$'\033[36m'
fi

log() {
  local lvl=$1
  shift

  local colour=$NONE

  case $lvl in
    info) colour=$CYAN ;;
    warn) colour=$YELLOW ;;
    error) colour=$RED ;;
    success) colour=$GREEN ;;
  esac

  printf '%s[%s] %-7s%s %s\n' \
    "$colour" \
    "$(date '+%H:%M:%S')" \
    "$(echo "$lvl" | tr a-z A-Z)" \
    "$NONE" \
    "$*"
}

######################## Tunables ####################################

# Coarse search values only
VALUES=(3 5 8 13 21 34 55 89 144 233 377)

PACKET_OPTIONS=("tlshello" "1-1" "1-3" "1-5")

TEST_URL="https://www.google.com/generate_204"

TEST_DURATION=2
REQUESTS_PER_TEST=3

SOCKS_PORT=1080

MAX_CANDIDATES=120
TOP_CANDIDATES=8

######################## Config ####################################

V2RAY_CONFIG=""
V2RAY_BINARY=""

######################## Read Config ####################################

while true; do
  read -rp "Enter path to your v2ray config file: " CONFIG_PATH

  if [[ -f "$CONFIG_PATH" ]]; then
    V2RAY_CONFIG="$CONFIG_PATH"
    break
  fi

  log error "File not found"
done

BACKUP_CONFIG="${V2RAY_CONFIG}.backup.$(date +%s)"
cp "$V2RAY_CONFIG" "$BACKUP_CONFIG"

######################## Detect Binary ####################################

if grep -q '"xhttp"' "$V2RAY_CONFIG" 2>/dev/null; then
  command -v xray >/dev/null || {
    log error "XHTTP requires Xray"
    exit 1
  }

  V2RAY_BINARY="xray"
else
  if command -v xray >/dev/null; then
    V2RAY_BINARY="xray"
  elif command -v v2ray >/dev/null; then
    V2RAY_BINARY="v2ray"
  else
    log error "Neither xray nor v2ray found"
    exit 1
  fi
fi

log info "Using binary: $V2RAY_BINARY"

######################## Results ####################################

RESULTS_DIR="./output/fragment"
mkdir -p "$RESULTS_DIR"

RESULTS_FILE="$RESULTS_DIR/results-$(date +%F-%H%M%S).txt"

printf "%-15s %-15s %-10s %-10s %-12s %-10s\n" \
  "Interval" "Length" "Packets" "Success" "Latency" "Score" \
  > "$RESULTS_FILE"

######################## Helpers ####################################

range_mid() {
  local a=${1%-*}
  local b=${1#*-}
  echo $(((a + b) / 2))
}

score_formula() {
  local success=$1
  local latency=$2
  local speed=$3

  local latency_score=0

  if [[ $latency -gt 0 ]]; then
    latency_score=$((100 - latency / 20))

    if [[ $latency_score -lt 0 ]]; then
      latency_score=0
    fi
  fi

  if [[ $speed -gt 100 ]]; then
    speed=100
  fi

  echo "$(echo \
    "scale=2;
    (($success * $success) * 0.0065)
    + ($latency_score * 0.25)
    + ($speed * 0.10)" | bc)"
}

######################## Candidate Generation ####################################

generate_candidates() {
  local candidates=()

  for i in "${VALUES[@]}"; do
    for j in "${VALUES[@]}"; do

      # interval should generally exceed length
      if [[ $i -lt $j ]]; then
        continue
      fi

      ratio=$((i / j))

      # prune unrealistic ratios
      if [[ $ratio -lt 1 || $ratio -gt 8 ]]; then
        continue
      fi

      # prune giant configs
      if [[ $((i * j)) -gt 20000 ]]; then
        continue
      fi

      interval="${j}-${i}"

      len_min=$((j / 2))
      [[ $len_min -lt 1 ]] && len_min=1

      length="${len_min}-${j}"

      for packet in "${PACKET_OPTIONS[@]}"; do
        candidates+=("${interval}|${length}|${packet}")
      done
    done
  done

  printf '%s\n' "${candidates[@]}" | shuf | head -n "$MAX_CANDIDATES"
}

######################## Test ####################################

test_config() {
  local interval=$1
  local length=$2
  local packets=$3

  log info "Testing interval=$interval length=$length packets=$packets" >&2

  python3 py/fragment.py \
    "$V2RAY_CONFIG" \
    "$interval" \
    "$length" \
    "$packets"

  pkill -f "$V2RAY_BINARY" 2>/dev/null || true
  sleep 0.5

  local logfile
  logfile=$(mktemp)

  $V2RAY_BINARY run -c "$V2RAY_CONFIG" \
    > "$logfile" 2>&1 &

  sleep 2

  if ! pgrep -f "$V2RAY_BINARY.*$V2RAY_CONFIG" >/dev/null; then

    log warn "startup failed" >&2

    rm -f "$logfile"

    echo "0"
    return
  fi

  rm -f "$logfile"

  local success=0
  local total_latency=0
  local total_speed=0

  for _ in $(seq 1 $REQUESTS_PER_TEST); do

    local start
    start=$(date +%s%N)

    if curl \
      -x socks5h://127.0.0.1:$SOCKS_PORT \
      --max-time "$TEST_DURATION" \
      --silent \
      --output /dev/null \
      "$TEST_URL"; then

      local end
      end=$(date +%s%N)

      local latency=$(((end - start) / 1000000))

      success=$((success + 1))
      total_latency=$((total_latency + latency))

      speed=$(curl \
        -x socks5h://127.0.0.1:$SOCKS_PORT \
        --max-time "$TEST_DURATION" \
        --silent \
        --output /dev/null \
        --write-out "%{speed_download}" \
        "https://speed.cloudflare.com/__down?bytes=65536" \
        2>/dev/null || echo 0)

      total_speed=$(echo "$total_speed + $speed" | bc)

    else

      # early rejection
      if [[ $success -eq 0 ]]; then
        break
      fi
    fi
  done

  pkill -f "$V2RAY_BINARY" 2>/dev/null || true

  if [[ $success -eq 0 ]]; then
    echo "0"
    return
  fi

  local success_rate=$((success * 100 / REQUESTS_PER_TEST))
  local avg_latency=$((total_latency / success))
  local avg_speed

  avg_speed=$(echo \
    "scale=2;
    $total_speed / $success / 1024" | bc)

  local score

  score=$(score_formula \
    "$success_rate" \
    "$avg_latency" \
    "${avg_speed%.*}")

  printf "%-15s %-15s %-10s %-10s %-12s %-10s\n" \
    "$interval" \
    "$length" \
    "$packets" \
    "${success_rate}%" \
    "${avg_latency}ms" \
    "$score" \
    >> "$RESULTS_FILE"

  log success \
    "success=${success_rate}% latency=${avg_latency}ms score=$score" >&2

  echo "$(echo "$score * 100" | cut -d. -f1)"
}

######################## Main ####################################

BEST_SCORE=0
BEST_CONFIG=""

mapfile -t CONFIGS < <(generate_candidates)

TOTAL=${#CONFIGS[@]}
log info "Generated $TOTAL smart candidates"

CURRENT=0
break_loop=0

trap 'log warn "Interrupted"; break_loop=1' SIGINT

for cfg in "${CONFIGS[@]}"; do
  [[ $break_loop -eq 1 ]] && break

  CURRENT=$((CURRENT + 1))
  IFS='|' read -r interval length packets <<< "$cfg"

  echo
  log info "[$CURRENT/$TOTAL]"

  score=$(test_config \
    "$interval" \
    "$length" \
    "$packets")

  score=${score:-0}

  if [[ $score -gt $BEST_SCORE ]]; then
    BEST_SCORE=$score
    BEST_CONFIG="$cfg"

    log success \
      "new best: $cfg score=$(echo "scale=2; $score / 100" | bc)"
  fi
done

######################## Restore ####################################

cp "$BACKUP_CONFIG" "$V2RAY_CONFIG"
rm -f "$BACKUP_CONFIG"

######################## Summary ####################################

echo
echo "=========================================================="

log success "Finished"

echo
log info "Best config:"
echo "  $BEST_CONFIG"

echo
log info "Score:"
echo "  $(echo "scale=2; $BEST_SCORE / 100" | bc)"

echo
log info "Results:"
echo "  $RESULTS_FILE"

echo