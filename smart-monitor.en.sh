#!/usr/bin/env bash
#
# smart-monitor.en.sh — Interactive SMART and self-test checker
#
# Checks drives (SATA, NVMe, SAS/SCSI, USB) using smartctl, starts short or
# extended self-tests, shows progress with a progress bar and a remaining-time
# estimate, and summarises the drive's condition in plain language.
#
# Requires: bash, smartmontools (smartctl), util-linux (lsblk), root privileges
#
# Behaviour:
#   - lists all drives via lsblk (parsed with a regex, never with eval)
#   - detects the transport (nvme / sata / usb / scsi / other)
#   - works out the right -d arguments for smartctl automatically
#   - uses the controller node on NVMe (/dev/nvme0 instead of /dev/nvme0n1)
#   - attaches to an already running self-test instead of disturbing it
#
# Exit codes:
#   0 = healthy / display only
#   1 = suspicious or heavily worn
#   2 = critical (SMART FAILED)
#   3 = usage error / missing prerequisites
#
# License: MIT

set -u
set -o pipefail
export LC_ALL=C

PROGNAME="${0##*/}"
VERSION="1.1.0"

# --- Constants ---------------------------------------------------------------

POLL_INTERVAL=10        # seconds between two progress queries
STARTUP_INTERVAL=3      # query interval while the test is still spinning up
START_GRACE=20          # seconds to wait for the test to actually start
BAR_WIDTH=30            # width of the progress bar

# Largest number we use in bash arithmetic without risking an overflow (int64).
NUM_MAX=999999999999999999

EXIT_OK=0
EXIT_WARN=1
EXIT_CRIT=2
EXIT_USAGE=3

# --- Global state ------------------------------------------------------------

RESULT_CODE=$EXIT_OK
WATCH_ABORT=0

OPT_DEVICE=""
OPT_ACTION=""

SMARTCTL_BIN=""
SMART_TARGET=""
SMART_INFO=""
declare -a SMART_ARGS=()

declare -a DISK_DEV=()
declare -a DISK_SIZE=()
declare -a DISK_MODEL=()
declare -a DISK_TRAN=()

sel_dev=""
sel_size=""
sel_model=""
sel_tran=""
sel_proto=""
sel_family=""

# --- Output helpers ----------------------------------------------------------

err()  { printf 'Error: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }
warn() { printf 'Note: %s\n' "$*"; }

usage() {
  cat <<EOF
$PROGNAME $VERSION — SMART health and self-tests for storage devices

Usage:
  sudo $PROGNAME [options]

Options:
  -d, --device DEVICE  Pick a drive directly (e.g. /dev/sda, /dev/nvme0n1)
  -a, --action N       Pick an action directly:
                         1 = show full SMART data
                         2 = short self-test
                         3 = extended self-test
                         4 = summary only (no test)
                         5 = abort a running self-test
  -h, --help           Show this help
  -V, --version        Show the version

When -d and -a are given together the script runs without any prompts, which
makes it suitable for cron jobs and other scripts.

Exit codes:
  0  healthy or display only
  1  suspicious / heavily worn
  2  critical (SMART FAILED)
  3  usage error or missing prerequisites

Examples:
  sudo $PROGNAME
  sudo $PROGNAME -d /dev/sda -a 4
  sudo $PROGNAME --device /dev/nvme0n1 --action 2
EOF
}

# Raises the result code but never lowers it.
escalate() {
  local code="$1"
  if (( code > RESULT_CODE )); then
    RESULT_CODE=$code
  fi
  return 0
}

# --- General helpers ---------------------------------------------------------

is_int() { [[ ${1-} =~ ^[0-9]+$ ]]; }

lower() { printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]'; }

trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Removes leading zeros so that (( )) does not read the value as octal.
strip_zeros() {
  local s="${1-}"
  while [[ ${#s} -gt 1 && ${s:0:1} == "0" ]]; do
    s="${s:1}"
  done
  printf '%s' "$s"
}

# Turns smartctl values into a plain decimal number.
# Handles hex ("0x04"), units ("35 Celsius"), percentages ("5%") and thousands
# separators ("1,234"). Returns an empty string when nothing can be read.
num_value() {
  local v="${1-}" hex n
  v="${v//[[:space:],]/}"

  if [[ $v =~ ^0[xX]([0-9a-fA-F]+)$ ]]; then
    hex="$(strip_zeros "${BASH_REMATCH[1]}")"
    if (( ${#hex} > 15 )); then
      printf '%s' "$NUM_MAX"
    else
      printf '%d' "$((16#$hex))"
    fi
    return 0
  fi

  n=$(grep -oE '[0-9]+' <<<"$v" | head -n1 || true)
  [[ -n ${n:-} ]] || { printf ''; return 0; }

  n="$(strip_zeros "$n")"
  # Very large raw values would overflow 64-bit arithmetic and could turn
  # negative. We cap them instead.
  if (( ${#n} > 18 )); then
    printf '%s' "$NUM_MAX"
  else
    printf '%s' "$n"
  fi
}

# Return the number in $1, or $2 (default 0) if it cannot be read.
num_or() {
  local n
  n="$(num_value "${1-}")"
  if is_int "$n"; then
    printf '%s' "$n"
  else
    printf '%s' "${2:-0}"
  fi
}

human_duration() {
  local s=${1:-0}
  if ! is_int "$s"; then
    printf '-'
    return 0
  fi

  local h=$((s / 3600))
  local m=$(((s % 3600) / 60))
  local sec=$((s % 60))

  if (( h > 0 )); then
    printf '%dh %02dm %02ds' "$h" "$m" "$sec"
  elif (( m > 0 )); then
    printf '%dm %02ds' "$m" "$sec"
  else
    printf '%ds' "$sec"
  fi
}

bar_for_percent() {
  local pct=${1:-0}
  local width=${2:-30}
  local bar="" i filled empty

  is_int "$pct" || pct=0
  (( pct < 0   )) && pct=0
  (( pct > 100 )) && pct=100

  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))

  for (( i = 0; i < filled; i++ )); do bar+='#'; done
  for (( i = 0; i < empty;  i++ )); do bar+='-'; done

  printf '[%s]' "$bar"
}

# --- smartctl plumbing -------------------------------------------------------

# smartctl returns a bitmask, not a classic success status:
#   bit 0 = command line was wrong
#   bit 1 = device could not be opened
#   bit 2 = a single SMART command failed
#   bit 3..7 = health findings (DISK FAILING, error log entries, ...)
# Only bit 0 and bit 1 are real failures. Everything else is valid output that
# we actually want to evaluate.
smart_exec() {
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  [[ -n $out ]] && printf '%s\n' "$out"
  (( (rc & 3) == 0 ))
}

# Map an NVMe namespace to its controller node:
# /dev/nvme0n1 -> /dev/nvme0
smart_target() {
  local dev="$1"
  case "$dev" in
    /dev/nvme*n[0-9]*) printf '%s' "${dev%%n[0-9]*}" ;;
    *)                 printf '%s' "$dev" ;;
  esac
}

# Determines target and -d arguments for the selected device exactly once.
# Sets the global variables SMART_TARGET, SMART_ARGS and SMART_INFO.
#
# "-d sat,12" deliberately comes before "-d scsi": SCSI access works with
# almost every USB enclosure but yields no ATA values, so sat,12 would never
# get its turn after it.
resolve_smart_access() {
  local dev="$1" try out
  local -a candidates=("" "-d sat" "-d sat,12" "-d nvme" "-d scsi" "-d ata")
  local -a extra=()

  SMART_TARGET="$(smart_target "$dev")"
  SMART_ARGS=()
  SMART_INFO=""

  for try in "${candidates[@]}"; do
    extra=()
    [[ -n $try ]] && read -r -a extra <<<"$try"

    if (( ${#extra[@]} > 0 )); then
      out="$(smart_exec "$SMARTCTL_BIN" "${extra[@]}" -i "$SMART_TARGET" 2>&1)" || continue
      SMART_ARGS=("${extra[@]}")
    else
      out="$(smart_exec "$SMARTCTL_BIN" -i "$SMART_TARGET" 2>&1)" || continue
      SMART_ARGS=()
    fi
    SMART_INFO="$out"
    return 0
  done

  return 1
}

# Calls smartctl for the resolved device.
smartctl_dev() {
  if (( ${#SMART_ARGS[@]} > 0 )); then
    smart_exec "$SMARTCTL_BIN" "${SMART_ARGS[@]}" "$@" "$SMART_TARGET"
  else
    smart_exec "$SMARTCTL_BIN" "$@" "$SMART_TARGET"
  fi
}

# Classify the transport from the device name and lsblk's TRAN column.
device_proto() {
  local dev="$1" tran
  tran="$(lower "${2-}")"

  case "$dev" in
    /dev/nvme*) printf 'nvme'; return 0 ;;
  esac

  case "$tran" in
    sata|ata|""|"-")   printf 'sata' ;;
    usb)               printf 'usb' ;;
    sas|scsi|iscsi|fc) printf 'scsi' ;;
    virtio|mmc)        printf 'other' ;;
    *)                 printf 'sata' ;;
  esac
}

# There are three parser families for progress and attribute handling.
parser_family() {
  case "$1" in
    nvme) printf 'nvme' ;;
    scsi) printf 'scsi' ;;
    *)    printf 'ata' ;;
  esac
}

# Determines the parser family from what "smartctl -i" answers.
# That is more reliable than the device name and lsblk's TRAN: an NVMe SSD in a
# USB enclosure, or a SAS drive without a TRAN value, would otherwise be read
# with the wrong parser. The transport only decides when the output gives
# nothing away.
detect_family() {
  local info="$1" proto="$2"

  if grep -qE '^(NVMe Version|Model Number):' <<<"$info"; then
    printf 'nvme'
  elif grep -qE '^(Device Model|ATA Version is|SATA Version is):' <<<"$info"; then
    printf 'ata'
  elif grep -qE '^(Vendor|Product):' <<<"$info"; then
    printf 'scsi'
  else
    parser_family "$proto"
  fi
}

# --- Prerequisites -----------------------------------------------------------

check_requirements() {
  local candidate

  if (( EUID != 0 )); then
    err "SMART access needs root privileges. Please run with sudo."
    exit $EXIT_USAGE
  fi

  for candidate in "$(command -v smartctl 2>/dev/null || true)" \
                   /usr/sbin/smartctl /sbin/smartctl /usr/local/sbin/smartctl; do
    if [[ -n ${candidate:-} && -x "$candidate" ]]; then
      SMARTCTL_BIN="$candidate"
      break
    fi
  done

  if [[ -z $SMARTCTL_BIN ]]; then
    err "smartctl was not found. Please install smartmontools (e.g. apt install smartmontools)."
    exit $EXIT_USAGE
  fi

  if ! command -v lsblk >/dev/null 2>&1; then
    err "lsblk was not found. Please install util-linux."
    exit $EXIT_USAGE
  fi
}

# --- Device selection --------------------------------------------------------

# lsblk -P returns KEY="VALUE" pairs. We parse them with a regex instead of
# eval so that model names coming from firmware cannot execute code.
collect_disks() {
  local line rest dev size model tran
  local -A lsb=()

  DISK_DEV=(); DISK_SIZE=(); DISK_MODEL=(); DISK_TRAN=()

  while IFS= read -r line; do
    [[ -n $line ]] || continue

    lsb=()
    rest="$line"
    while [[ $rest =~ ([A-Z_]+)=\"([^\"]*)\"(.*) ]]; do
      lsb["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
      rest="${BASH_REMATCH[3]}"
    done

    [[ ${lsb[TYPE]:-} == "disk" ]] || continue
    [[ -n ${lsb[NAME]:-} ]] || continue
    # zram is a drive in RAM, 0B is usually an empty card reader. Neither has
    # SMART, they would only make the list longer.
    [[ ${lsb[NAME]} == zram* || ${lsb[SIZE]:-} == "0B" ]] && continue

    dev="/dev/${lsb[NAME]}"
    size="${lsb[SIZE]:-}"
    model="${lsb[MODEL]:-}"
    tran="${lsb[TRAN]:-}"

    [[ -z $model ]] && model="Unknown model"
    [[ -z $tran  ]] && tran="-"

    DISK_DEV+=("$dev")
    DISK_SIZE+=("$size")
    DISK_MODEL+=("$model")
    DISK_TRAN+=("$tran")
  done < <(lsblk -dn -P -o NAME,SIZE,MODEL,TRAN,TYPE 2>/dev/null)
}

print_disks() {
  local i
  echo
  info "Available drives:"
  echo
  for i in "${!DISK_DEV[@]}"; do
    printf '  %d) %-12s %-32.32s %-8s %s\n' \
      "$(( i + 1 ))" "${DISK_SIZE[$i]}" "${DISK_MODEL[$i]}" "${DISK_TRAN[$i]}" "${DISK_DEV[$i]}"
  done
  echo
}

# Reuses model/size from the lsblk listing if the device appears there.
adopt_metadata() {
  local dev="$1" i
  sel_size="-"
  sel_model="Unknown model"
  sel_tran="-"

  for i in "${!DISK_DEV[@]}"; do
    if [[ ${DISK_DEV[$i]} == "$dev" ]]; then
      sel_size="${DISK_SIZE[$i]}"
      sel_model="${DISK_MODEL[$i]}"
      sel_tran="${DISK_TRAN[$i]}"
      return 0
    fi
  done
  return 0
}

select_device() {
  local selected

  collect_disks

  if [[ -n $OPT_DEVICE ]]; then
    if [[ ! -b $OPT_DEVICE && ! -c $OPT_DEVICE ]]; then
      err "$OPT_DEVICE is not an existing block device."
      exit $EXIT_USAGE
    fi
    # Resolve symlinks such as /dev/disk/by-id/... Otherwise neither the lsblk
    # data nor the mapping to the NVMe controller node would match.
    sel_dev="$(readlink -f -- "$OPT_DEVICE" 2>/dev/null || true)"
    [[ -n $sel_dev ]] || sel_dev="$OPT_DEVICE"
    adopt_metadata "$sel_dev"
    return 0
  fi

  if (( ${#DISK_DEV[@]} == 0 )); then
    err "No drives found."
    exit $EXIT_USAGE
  fi

  print_disks

  if (( ${#DISK_DEV[@]} == 1 )); then
    selected=1
    info "Only one drive present, selecting it automatically."
  else
    while true; do
      read -rp "Select the number of the drive: " selected || {
        echo; err "Aborted (no input)."; exit $EXIT_USAGE
      }
      if is_int "$selected" && (( selected >= 1 && selected <= ${#DISK_DEV[@]} )); then
        break
      fi
      echo "Invalid choice."
    done
  fi

  sel_dev="${DISK_DEV[$(( selected - 1 ))]}"
  adopt_metadata "$sel_dev"
}

select_action() {
  if [[ -n $OPT_ACTION ]]; then
    return 0
  fi

  info "What would you like to do?"
  info "  1) show full SMART data"
  info "  2) short self-test"
  info "  3) extended self-test"
  info "  4) summary only (no test)"
  info "  5) abort a running self-test"
  echo

  while true; do
    read -rp "Choice (1/2/3/4/5): " OPT_ACTION || {
      echo; err "Aborted (no input)."; exit $EXIT_USAGE
    }
    case "$OPT_ACTION" in
      1|2|3|4|5) break ;;
      *) echo "Invalid choice." ;;
    esac
  done
}

# --- Self-test support -------------------------------------------------------

selftest_supported() {
  local family="$1" out

  case "$family" in
    nvme)
      # On NVMe the self-test capability shows up either in the capabilities
      # or in the info output, depending on the smartctl version.
      out="$(smartctl_dev -c 2>/dev/null || true)"
      out+=$'\n'"$(smartctl_dev -i 2>/dev/null || true)"
      grep -qiE 'Self[-_ ]?Test' <<<"$out"
      ;;
    scsi)
      # SCSI has no capabilities output. Without a self-test log there are
      # usually no self-tests either.
      out="$(smartctl_dev -l selftest 2>/dev/null || true)"
      ! grep -qiE 'does not support Self[- ]?Test' <<<"$out"
      ;;
    *)
      out="$(smartctl_dev -c 2>/dev/null || true)"
      grep -qiE 'Short self-test routine' <<<"$out"
      ;;
  esac
}

# --- Progress / test duration ------------------------------------------------

# Careful: smartctl breaks the line between the test name and the polling time:
#   Short self-test routine
#   recommended polling time:        (   2) minutes.
# Grepping for the phrase as a whole therefore never matches anything.
recommended_minutes() {
  local mode="$1" family="$2" out key val

  if [[ $family == "scsi" ]]; then
    # SCSI only states the duration of the extended test, in seconds and in
    # the self-test log: "Long (extended) Self-test duration: 6000 seconds".
    [[ $mode == "long" ]] || { printf ''; return 0; }
    out="$(smartctl_dev -l selftest 2>/dev/null || true)"
    val=$(grep -oiE 'Long \(extended\).*duration:[[:space:]]*[0-9]+' <<<"$out" \
          | grep -oE '[0-9]+$' | head -n1 || true)
    is_int "$val" && printf '%s' "$(( (val + 59) / 60 ))"
    return 0
  fi

  out="$(smartctl_dev -c 2>/dev/null || true)"

  case "$mode" in
    short) key='Short self-test routine' ;;
    long)  key='Extended self-test routine' ;;
    *)     printf ''; return 0 ;;
  esac

  val=$(awk -v k="$key" '
    index($0, k) { found = 1 }
    found && /[Rr]ecommended polling time/ {
      if (match($0, /\([[:space:]]*[0-9]+\)/)) {
        s = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", s)
        print s
        exit
      }
    }' <<<"$out" || true)

  printf '%s' "${val:-}"
}

# Running state and progress come from ONE smartctl query. Two separate calls
# per round would wake up spinning disks needlessly and double the polling.
#
# Careful: "Self-test execution status" and "completed" also appear in the
# output when nothing is running; when idle, NVMe explicitly reports
# "No self-test in progress". No yes/no check may rely on those words alone.
POLL_RUNNING=0
POLL_PCT=""

poll_selftest_state() {
  local family="$1" out status rem pct

  POLL_RUNNING=0
  POLL_PCT=""

  case "$family" in
    nvme)
      out="$(smartctl_dev -l selftest 2>/dev/null || true)"
      status="$(grep -iE 'Self-test status' <<<"$out" | head -n1 || true)"

      pct=$(grep -oiE '[0-9]+%[[:space:]]*completed' <<<"$status" \
            | grep -oE '[0-9]+' | head -n1 || true)
      is_int "$pct" && POLL_PCT="$pct"

      if [[ -n $status ]] && ! grep -qiE 'no self-test in progress' <<<"$status"; then
        if grep -qiE 'in progress|[0-9]+%[[:space:]]*completed' <<<"$status"; then
          POLL_RUNNING=1
        fi
      fi
      ;;
    scsi)
      # SCSI/SAS: "-c" tells us nothing here. Running state and (depending on
      # the drive) progress live in the self-test log; the running test is the
      # topmost entry, marked "Self test in progress ...".
      out="$(smartctl_dev -l selftest 2>/dev/null || true)"

      rem=$(grep -oE '[0-9]+% of test remaining' <<<"$out" | grep -oE '^[0-9]+' | head -n1 || true)
      is_int "$rem" && POLL_PCT=$(( 100 - rem ))

      if [[ -n $POLL_PCT ]] || grep -qiE 'in progress' <<<"$(last_selftest_line "$out")"; then
        POLL_RUNNING=1
      fi
      ;;
    *)
      out="$(smartctl_dev -c 2>/dev/null || true)"

      # Typically: "90% of test remaining"
      rem=$(grep -oE '[0-9]+% of test remaining' <<<"$out" | grep -oE '^[0-9]+' | head -n1 || true)
      is_int "$rem" && POLL_PCT=$(( 100 - rem ))

      if grep -qiE '% of test remaining|Self-test routine in progress' <<<"$out"; then
        POLL_RUNNING=1
      fi
      ;;
  esac

  return 0
}

selftest_is_running() {
  poll_selftest_state "$1"
  (( POLL_RUNNING == 1 ))
}

# Kind of an already running test (short / long), as far as the self-test log
# gives it away. Prints nothing when it does not.
running_test_mode() {
  local out line
  out="$(smartctl_dev -l selftest 2>/dev/null || true)"
  line="$(grep -iE 'in progress' <<<"$out" | grep -viE 'no self-test in progress' | head -n1 || true)"
  case "$(lower "$line")" in
    *short*)           printf 'short' ;;
    *extended*|*long*) printf 'long' ;;
  esac
  return 0
}

# --- Remaining time from measured progress -----------------------------------
#
# Firmware reports progress in steps: ATA in 10 % steps, NVMe in 1 % steps.
# ATA also reports "90% of test remaining" right after the start. Simply
# extrapolating "elapsed time / percent" therefore yields a remaining time of
# a few minutes at the start of a test that takes hours, and that figure then
# keeps growing until the next step.
#
# So progress is only measured between step changes: from the anchor (test
# start, or the first observed change for a test we attached to) to the most
# recent change. Between two changes the remaining time counts down, but never
# drops below the value that will apply once the next step is reached.
PROG_PREV=""
PROG_STEP=0
PROG_T0=""
PROG_P0=""
PROG_T1=""
PROG_P1=""

# $1 = reported percentage, $2 = now, $3 = test start (empty for a test we
# attached to, whose real start time we do not know)
progress_track() {
  local pct="$1" now="$2" start="$3"

  if [[ -z $PROG_PREV ]]; then
    PROG_PREV=$pct
    if [[ -n $start ]]; then
      PROG_T0=$start
      PROG_P0=$pct
    fi
  elif (( pct > PROG_PREV )); then
    PROG_STEP=$(( pct - PROG_PREV ))
    PROG_PREV=$pct
    if [[ -z $PROG_T0 ]]; then
      PROG_T0=$now
      PROG_P0=$pct
    else
      PROG_T1=$now
      PROG_P1=$pct
    fi
  fi
  return 0
}

# Prints the remaining time in seconds, or nothing while no step change has
# been measured yet.
progress_remaining() {
  local now="$1" span gained rem floor

  [[ -n $PROG_T1 ]] || return 0
  span=$(( PROG_T1 - PROG_T0 ))
  gained=$(( PROG_P1 - PROG_P0 ))
  (( span > 0 && gained > 0 )) || return 0

  rem=$(( (100 - PROG_P1) * span / gained - (now - PROG_T1) ))
  floor=$(( (100 - PROG_P1 - PROG_STEP) * span / gained ))
  (( rem < floor )) && rem=$floor
  (( rem < 0 )) && rem=0
  printf '%s' "$rem"
}

abort_selftest() {
  local family="$1"

  echo
  if ! selftest_is_running "$family"; then
    info "There is currently no self-test running on $SMART_TARGET."
    return 0
  fi

  info "Aborting the running self-test on $SMART_TARGET ..."
  echo
  if smartctl_dev -X; then
    echo
    info "Abort requested."
  else
    err "The abort could not be carried out."
    return 1
  fi
}

# --- Start and watch a self-test ---------------------------------------------

start_selftest() {
  local mode="$1" family="$2"
  local start_ts now elapsed pct remaining est_total est_min rem_txt
  local running=0 seen_running=0 attached=0 interval line last_pct=-1
  local is_tty=0 max_pct=0 idle_polls=0 track_start="" running_mode result=""

  [[ -t 1 ]] && is_tty=1

  echo
  printf 'Self-test (%s) on %s\n' "$mode" "$SMART_TARGET"
  echo

  if ! selftest_supported "$family"; then
    warn "The drive does not report self-test support. Trying to start it anyway."
    echo
  fi

  if selftest_is_running "$family"; then
    # The running test may be of a different kind than the one requested.
    # The vendor estimate has to follow the kind that is actually running.
    running_mode="$(running_test_mode)"
    [[ -n $running_mode ]] && mode="$running_mode"
    warn "A self-test ($mode) is already running. No new one is started; the running one is watched."
    attached=1
    seen_running=1
    echo
  else
    if ! smartctl_dev -t "$mode"; then
      err "The test could not be started."
      return 1
    fi
  fi

  start_ts=$(date +%s)
  est_min="$(recommended_minutes "$mode" "$family")"
  est_total=0
  is_int "$est_min" && est_total=$(( est_min * 60 ))
  (( attached )) || track_start=$start_ts

  PROG_PREV=""; PROG_STEP=0; PROG_T0=""; PROG_P0=""; PROG_T1=""; PROG_P1=""

  echo
  info "Polling progress. Ctrl+C only stops the display; the test keeps running."
  echo

  WATCH_ABORT=0
  trap 'WATCH_ABORT=1' INT

  while true; do
    poll_selftest_state "$family"
    running=$POLL_RUNNING
    pct="$POLL_PCT"

    now=$(date +%s)
    elapsed=$(( now - start_ts ))

    if (( running == 1 )); then
      seen_running=1
      idle_polls=0
    else
      idle_polls=$(( idle_polls + 1 ))
    fi

    line=""
    if (( running == 0 && seen_running == 1 )); then
      # Either the test has finished, or a single query went wrong. The
      # display stays as it is until the next query confirms it.
      :
    elif is_int "$pct"; then
      progress_track "$pct" "$now" "$track_start"

      remaining=""
      if (( pct >= 100 )); then
        remaining=0
      else
        remaining="$(progress_remaining "$now")"
        if [[ -z $remaining ]] && (( est_total > 0 )); then
          # No step change measured yet: fall back to the vendor figure.
          if (( attached )); then
            # For a test we attached to we do not know the real start
            # time, only the reported progress.
            remaining=$(( est_total * (100 - pct) / 100 ))
          elif (( elapsed < est_total )); then
            remaining=$(( est_total - elapsed ))
          fi
        fi
      fi

      rem_txt="-"
      [[ -n $remaining ]] && rem_txt="$(human_duration "$remaining")"

      line=$(printf '%s %3d%%  elapsed: %s  remaining: %s' \
        "$(bar_for_percent "$pct" "$BAR_WIDTH")" "$pct" \
        "$(human_duration "$elapsed")" "$rem_txt")
    elif (( est_total > 0 && elapsed < est_total )); then
      # No measured progress: extrapolate the vendor estimate instead.
      # The bar must never jump backwards while doing so.
      pct=$(( elapsed * 100 / est_total ))
      (( pct < max_pct )) && pct=$max_pct
      line=$(printf '%s ~%3d%%  elapsed: %s  remaining: %s' \
        "$(bar_for_percent "$pct" "$BAR_WIDTH")" "$pct" \
        "$(human_duration "$elapsed")" "$(human_duration $(( est_total - elapsed )))")
    else
      pct=-1
      line=$(printf '%s  ---  elapsed: %s  remaining: -' \
        "$(bar_for_percent 0 "$BAR_WIDTH")" "$(human_duration "$elapsed")")
    fi

    is_int "$pct" && (( pct > max_pct )) && max_pct=$pct

    if [[ -z $line ]]; then
      :
    elif (( is_tty )); then
      printf '\r\033[K%s' "$line"
    elif [[ $pct != "$last_pct" ]]; then
      # Without a terminal, one status line per query would just be noise.
      printf '%s\n' "$line"
      last_pct="$pct"
    fi

    (( WATCH_ABORT )) && break

    if (( running == 0 )); then
      # Only stop once two queries in a row see no test any more, or when
      # the test is still not running after the start-up grace period.
      if (( seen_running == 1 && idle_polls >= 2 )); then
        break
      fi
      if (( seen_running == 0 && elapsed >= START_GRACE )); then
        break
      fi
    fi

    if (( seen_running && running )); then
      interval=$POLL_INTERVAL
    else
      interval=$STARTUP_INTERVAL
    fi
    sleep "$interval"

    (( WATCH_ABORT )) && break
  done

  trap - INT

  if (( WATCH_ABORT == 0 && seen_running == 1 )); then
    # How did the test end? An abort or a read failure must not end with a
    # full bar.
    result="$(selftest_line_status "$(last_selftest_line "$(smartctl_dev -l selftest 2>/dev/null || true)")")"

    if [[ $result == "ok" || $result == "unknown" ]]; then
      line=$(printf '%s %3d%%  elapsed: %s  remaining: %s' \
        "$(bar_for_percent 100 "$BAR_WIDTH")" 100 "$(human_duration "$elapsed")" "0s")
      if (( is_tty )); then
        printf '\r\033[K%s' "$line"
      else
        printf '%s\n' "$line"
      fi
    fi
  fi

  (( is_tty )) && echo
  echo

  if (( WATCH_ABORT )); then
    info "Display stopped. The test keeps running in the background."
  elif (( seen_running == 0 )); then
    warn "No running self-test was detected. Either it finished immediately or the drive does not support it."
  elif [[ $result == "failed" ]]; then
    warn "The test has ended, but not without errors. See the self-test log below for details."
  elif [[ $result == "aborted" ]]; then
    warn "The test was aborted before it finished."
  else
    info "Test finished."
  fi

  return 0
}

# --- Evaluation --------------------------------------------------------------

show_full_smart() {
  echo
  smartctl_dev -x || true
}

# Reads one attribute from the table produced by "smartctl -A".
# The column position is taken from the header line because smartctl prints a
# different number of columns depending on the output format ("old" or "brief").
ata_field() {
  local name="$1" col="$2" text="$3"
  awk -v name="$name" -v col="$col" '
    /ATTRIBUTE_NAME/ {
      idx = 0
      for (i = 1; i <= NF; i++) if ($i == col) idx = i
      next
    }
    idx > 0 && $2 == name { print $idx; exit }
  ' <<<"$text"
}

ata_raw() { ata_field "$1" "RAW_VALUE" "$2"; }
ata_val() { ata_field "$1" "VALUE"     "$2"; }

# Lists attributes that are currently below their vendor threshold
# (WHEN_FAILED = FAILING_NOW, or FAIL = NOW in the "brief" format).
# $1 = "pre" for pre-fail attributes (failure predictors), "old" for old-age.
ata_failing_now() {
  local want="$1" text="$2"
  awk -v want="$want" '
    /ATTRIBUTE_NAME/ {
      wf = ty = fa = fl = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "WHEN_FAILED") wf = i
        if ($i == "TYPE")        ty = i
        if ($i == "FAIL")        fa = i
        if ($i == "FLAGS")       fl = i
      }
      next
    }
    (wf && ty && $wf == "FAILING_NOW") || (fa && fl && $fa == "NOW") {
      pre = wf ? ($ty == "Pre-fail") : (substr($fl, 1, 1) == "P")
      if ((want == "pre") == pre) { printf "%s%s", sep, $2; sep = ", " }
    }
  ' <<<"$text"
}

nvme_field() {
  local key="$1" text="$2" val
  val=$(grep -iE "^${key}:" <<<"$text" | head -n1 | cut -d: -f2- || true)
  trim "$val"
}

# Evaluates the output of "smartctl -H".
health_state_from() {
  local out="$1"

  if grep -qiE '^SMART overall-health self-assessment test result:[[:space:]]*PASSED' <<<"$out"; then
    printf 'PASSED'; return 0
  fi
  if grep -qiE '^SMART Health Status:[[:space:]]*OK' <<<"$out"; then
    printf 'PASSED'; return 0
  fi
  if grep -qiE '^SMART overall-health self-assessment test result:[[:space:]]*FAILED' <<<"$out"; then
    printf 'FAILED'; return 0
  fi
  if grep -qiE '^SMART Health Status:.*(FAIL|BAD)' <<<"$out"; then
    printf 'FAILED'; return 0
  fi
  if grep -qiE 'FAILING_NOW' <<<"$out"; then
    printf 'FAILED'; return 0
  fi

  printf 'UNKNOWN'
}

# Strips smartctl's version/copyright preamble from an output block.
strip_banner() {
  awk '
    !started && (/^smartctl [0-9]/ || /^Copyright \(C\)/ || /^[[:space:]]*$/) { next }
    { started = 1; print }
  ' <<<"${1-}"
}

# Fetches the most recent entry from the self-test log (ATA and NVMe).
last_selftest_line() {
  local out="$1"
  awk '
    /^#[[:space:]]*[0-9]+/ { print; exit }
    /^[[:space:]]*[0-9]+[[:space:]]+(Short|Extended|Conveyance|Vendor)/ { print; exit }
  ' <<<"$out"
}

# Classifies a self-test log entry:
#   ok      = finished without error
#   failed  = ended with an error (read failure, failed segment ...)
#   aborted = aborted or interrupted, says nothing about the drive
#   unknown = no entry, or the test is still "in progress"
selftest_line_status() {
  local line="$1"

  if [[ -z $line ]]; then
    printf 'unknown'
  elif grep -qiE 'without error' <<<"$line"; then
    printf 'ok'
  elif grep -qiE 'in progress' <<<"$line"; then
    printf 'unknown'
  elif grep -qiE 'abort|interrupt' <<<"$line"; then
    printf 'aborted'
  elif grep -qiE 'fail|error' <<<"$line"; then
    printf 'failed'
  else
    # e.g. SCSI: plain "Completed"
    printf 'ok'
  fi
}

# Short description of a selftest_line_status value for the key values list.
selftest_status_text() {
  case "$1" in
    ok)      printf 'no errors' ;;
    failed)  printf 'ended with an error' ;;
    aborted) printf 'aborted' ;;
    *)       printf 'unknown' ;;
  esac
}

summary_nvme() {
  local health_state="$1" attrs="$2" st_status="${3:-unknown}"
  local temp pct_used spare spare_thr crit media_err poh
  local verdict message

  temp="$(nvme_field 'Temperature' "$attrs")"
  pct_used="$(nvme_field 'Percentage Used' "$attrs")"
  spare="$(nvme_field 'Available Spare' "$attrs")"
  spare_thr="$(nvme_field 'Available Spare Threshold' "$attrs")"
  crit="$(nvme_field 'Critical Warning' "$attrs")"
  media_err="$(nvme_field 'Media and Data Integrity Errors' "$attrs")"
  poh="$(nvme_field 'Power On Hours' "$attrs")"

  if [[ $health_state == "FAILED" ]]; then
    verdict="Critical"
    message="SMART reports a clear failure. Back up immediately and replace the drive."
    escalate $EXIT_CRIT
  elif [[ -n $spare_thr ]] && (( $(num_or "$spare_thr" 0) > 0 )) \
    && (( $(num_or "$spare" 100) <= $(num_or "$spare_thr" 0) )); then
    verdict="Critical"
    message="Spare blocks have dropped to or below the vendor threshold. Back up now."
    escalate $EXIT_CRIT
  elif (( $(num_or "$crit" 0) > 0 )); then
    verdict="Suspicious"
    message="The NVMe reports a critical warning. Keep an eye on this drive and back it up soon."
    escalate $EXIT_WARN
  elif [[ $st_status == "failed" ]]; then
    verdict="Suspicious"
    message="The most recent self-test did not finish without errors. Make a backup and keep an eye on the drive."
    escalate $EXIT_WARN
  elif (( $(num_or "$pct_used" 0) >= 90 )); then
    verdict="Worn"
    message="The SSD has used up a lot of its rated life. It still works, but the end is approaching."
    escalate $EXIT_WARN
  elif (( $(num_or "$media_err" 0) > 0 )); then
    verdict="Suspicious"
    message="Media/data integrity errors were counted. A backup is a good idea even though the drive still works."
    escalate $EXIT_WARN
  elif [[ $health_state == "UNKNOWN" && -z $temp$pct_used$spare$crit$media_err$poh ]]; then
    # $attrs itself is never empty: smartctl always prints its banner.
    verdict="Unknown"
    message="No SMART values could be read. The condition cannot be judged."
    escalate $EXIT_WARN
  else
    verdict="Healthy"
    message="The drive currently looks healthy and unremarkable."
  fi

  echo
  printf 'Condition: %s\n' "$verdict"
  echo "$message"
  echo
  echo "Key values:"
  echo "- SMART health: ${health_state}"
  [[ $st_status != "unknown" ]] && echo "- Latest self-test: $(selftest_status_text "$st_status")"
  [[ -n $temp      ]] && echo "- Temperature: ${temp}"
  [[ -n $pct_used  ]] && echo "- Wear (percentage used): ${pct_used}"
  [[ -n $spare     ]] && echo "- Available spare: ${spare}"
  [[ -n $spare_thr ]] && echo "- Spare threshold: ${spare_thr}"
  [[ -n $crit      ]] && echo "- Critical warning: ${crit}"
  [[ -n $media_err ]] && echo "- Media/data errors: ${media_err}"
  [[ -n $poh       ]] && echo "- Power-on hours: ${poh}"
  return 0
}

summary_ata() {
  local health_state="$1" attrs="$2" st_status="${3:-unknown}"
  local realloc realloc_ev pending uncorr temp wear poh wear_num
  local failing_pre failing_old has_table=0
  local verdict message

  realloc="$(ata_raw Reallocated_Sector_Ct "$attrs")"
  realloc_ev="$(ata_raw Reallocated_Event_Count "$attrs")"
  pending="$(ata_raw Current_Pending_Sector "$attrs")"
  uncorr="$(ata_raw Offline_Uncorrectable "$attrs")"
  poh="$(ata_raw Power_On_Hours "$attrs")"
  temp="$(ata_raw Temperature_Celsius "$attrs")"
  [[ -z $temp ]] && temp="$(ata_raw Airflow_Temperature_Cel "$attrs")"

  # Remaining life lives in the NORMALISED value (VALUE column), not the raw one.
  wear="$(ata_val Wear_Leveling_Count "$attrs")"
  [[ -z $wear ]] && wear="$(ata_val Percent_Lifetime_Remain "$attrs")"
  [[ -z $wear ]] && wear="$(ata_val Media_Wearout_Indicator "$attrs")"
  [[ -z $wear ]] && wear="$(ata_val SSD_Life_Left "$attrs")"
  wear_num="$(num_value "$wear")"

  # smartctl -H still reports PASSED while only old-age attributes or single
  # values are below their threshold. So check the table itself as well.
  failing_pre="$(ata_failing_now pre "$attrs")"
  failing_old="$(ata_failing_now old "$attrs")"
  grep -q 'ATTRIBUTE_NAME' <<<"$attrs" && has_table=1

  if [[ $health_state == "FAILED" ]]; then
    verdict="Critical"
    message="SMART reports a clear failure. Back up immediately and replace the drive."
    escalate $EXIT_CRIT
  elif [[ -n $failing_pre ]]; then
    verdict="Critical"
    message="A failure predictor is below its vendor threshold (${failing_pre}). Back up immediately and replace the drive."
    escalate $EXIT_CRIT
  elif (( $(num_or "$realloc" 0)    > 0 )) \
    || (( $(num_or "$realloc_ev" 0) > 0 )) \
    || (( $(num_or "$pending" 0)    > 0 )) \
    || (( $(num_or "$uncorr" 0)     > 0 )); then
    verdict="Suspicious"
    message="There are problem blocks. Not a total loss yet, but a backup and closer monitoring are advisable."
    escalate $EXIT_WARN
  elif [[ $st_status == "failed" ]]; then
    verdict="Suspicious"
    message="The most recent self-test did not finish without errors. Make a backup and keep an eye on the drive."
    escalate $EXIT_WARN
  elif [[ -n $failing_old ]]; then
    verdict="Suspicious"
    message="An old-age value is currently below its vendor threshold (${failing_old}). Check the cause; a backup is advisable."
    escalate $EXIT_WARN
  elif is_int "$wear_num" && (( wear_num < 20 )); then
    verdict="Heavily used"
    message="Remaining life is below 20 percent. The drive still works, but a replacement should be planned."
    escalate $EXIT_WARN
  elif [[ $health_state == "UNKNOWN" ]] && (( has_table == 0 )); then
    # $attrs itself is never empty: smartctl always prints its banner.
    verdict="Unknown"
    message="No SMART values could be read. The condition cannot be judged."
    escalate $EXIT_WARN
  else
    verdict="Healthy"
    message="The drive currently looks healthy and unremarkable."
  fi

  echo
  printf 'Condition: %s\n' "$verdict"
  echo "$message"
  echo
  echo "Key values:"
  echo "- SMART health: ${health_state}"
  [[ $st_status != "unknown" ]] && echo "- Latest self-test: $(selftest_status_text "$st_status")"
  [[ -n $temp       ]] && echo "- Temperature: ${temp} °C"
  [[ -n $poh        ]] && echo "- Power-on hours: ${poh}"
  [[ -n $wear_num   ]] && echo "- Remaining life (normalised): ${wear_num} %"
  [[ -n $realloc    ]] && echo "- Reallocated sectors: ${realloc}"
  [[ -n $realloc_ev ]] && echo "- Reallocated events: ${realloc_ev}"
  [[ -n $pending    ]] && echo "- Pending sectors: ${pending}"
  [[ -n $uncorr     ]] && echo "- Uncorrectable: ${uncorr}"
  return 0
}

friendly_summary() {
  local family="$1"
  local health_output health_state attrs selftest_log st_status

  health_output="$(smartctl_dev -H 2>/dev/null || true)"
  health_state="$(health_state_from "$health_output")"

  attrs="$(smartctl_dev -A 2>/dev/null || true)"

  # A failed self-test belongs in the verdict itself. Otherwise
  # "Condition: Healthy" would sit right above a read failure in the log.
  selftest_log="$(smartctl_dev -l selftest 2>/dev/null || true)"
  st_status="$(selftest_line_status "$(last_selftest_line "$selftest_log")")"

  if [[ $family == "nvme" ]]; then
    summary_nvme "$health_state" "$attrs" "$st_status"
  else
    summary_ata "$health_state" "$attrs" "$st_status"
  fi

  echo
  echo "Latest self-test log:"
  selftest_log="$(strip_banner "$selftest_log")"
  if [[ -n $selftest_log ]]; then
    printf '%s\n' "$selftest_log"
  else
    echo "(no self-test log available)"
  fi
  return 0
}

# --- Arguments ---------------------------------------------------------------

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)    usage; exit $EXIT_OK ;;
      -V|--version) printf '%s %s\n' "$PROGNAME" "$VERSION"; exit $EXIT_OK ;;
      -d|--device)
        (( $# >= 2 )) || { err "$1 needs a device as its argument."; exit $EXIT_USAGE; }
        OPT_DEVICE="$2"; shift 2 ;;
      -a|--action)
        (( $# >= 2 )) || { err "$1 needs a number from 1 to 5."; exit $EXIT_USAGE; }
        case "$2" in
          1|2|3|4|5) OPT_ACTION="$2" ;;
          *) err "Invalid action: $2 (allowed: 1 to 5)"; exit $EXIT_USAGE ;;
        esac
        shift 2 ;;
      --) shift; break ;;
      -*) err "Unknown option: $1"; echo >&2; usage >&2; exit $EXIT_USAGE ;;
      *)  err "Unexpected argument: $1"; exit $EXIT_USAGE ;;
    esac
  done
}

# --- Main --------------------------------------------------------------------

main() {
  parse_args "$@"
  check_requirements
  select_device

  sel_proto="$(device_proto "$sel_dev" "$sel_tran")"

  if ! resolve_smart_access "$sel_dev"; then
    err "smartctl cannot talk to $(smart_target "$sel_dev") (not even with -d sat/nvme/scsi)."
    exit $EXIT_USAGE
  fi

  # What actually answers counts for more than the device name. "sata" is only
  # the default for devices without a TRAN value and gets corrected then.
  sel_family="$(detect_family "$SMART_INFO" "$sel_proto")"
  if [[ $sel_proto == "sata" && $sel_family != "ata" ]]; then
    sel_proto="$sel_family"
  fi

  echo
  printf 'Selected:     %s  %s  %s  (%s)\n' "$sel_dev" "$sel_size" "$sel_model" "$sel_tran"
  printf 'SMART target: %s\n' "$SMART_TARGET"
  printf 'Detected as:  %s\n' "$sel_proto"

  case "$sel_proto" in
    usb)
      echo
      warn "USB enclosures often pass SMART commands through only partially. Self-tests may fail or report wrong values."
      ;;
    other)
      echo
      warn "SMART data is usually not available for this transport type."
      ;;
  esac
  echo

  select_action

  case "$OPT_ACTION" in
    1) show_full_smart ;;
    2) start_selftest short "$sel_family" || exit $EXIT_USAGE
       friendly_summary "$sel_family" ;;
    3) start_selftest long "$sel_family" || exit $EXIT_USAGE
       friendly_summary "$sel_family" ;;
    4) friendly_summary "$sel_family" ;;
    5) abort_selftest "$sel_family" || exit $EXIT_USAGE ;;
  esac

  exit "$RESULT_CODE"
}

main "$@"
