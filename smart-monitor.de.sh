#!/usr/bin/env bash
#
# smart-monitor.de.sh — Interaktiver SMART- und Selbsttest-Checker
#
# Prüft Datenträger (SATA, NVMe, SAS/SCSI, USB) mit smartctl, startet kurze
# oder erweiterte Selbsttests, zeigt den Fortschritt mit Fortschrittsbalken
# und Restzeitschätzung an und fasst den Zustand in verständlicher Sprache
# zusammen.
#
# Benötigt: bash, smartmontools (smartctl), util-linux (lsblk), root-Rechte
#
# Verhalten:
#   - listet alle Datenträger über lsblk auf (Parsing per Regex, kein eval)
#   - erkennt den Transport (nvme / sata / usb / scsi / sonstiges)
#   - ermittelt automatisch die passenden -d-Argumente für smartctl
#   - nutzt bei NVMe den Controller-Knoten (/dev/nvme0 statt /dev/nvme0n1)
#   - hängt sich an einen bereits laufenden Selbsttest an, statt ihn zu stören
#
# Exitcodes:
#   0 = unauffällig / reine Anzeige
#   1 = auffällig oder stark abgenutzt
#   2 = kritisch (SMART FAILED)
#   3 = Nutzungsfehler / fehlende Voraussetzungen
#
# Lizenz: MIT

set -u
set -o pipefail
export LC_ALL=C

PROGNAME="${0##*/}"
VERSION="1.1.0"

# --- Konstanten --------------------------------------------------------------

POLL_INTERVAL=10        # Sekunden zwischen zwei Fortschrittsabfragen
STARTUP_INTERVAL=3      # Abfrageintervall, solange der Test noch anläuft
START_GRACE=20          # Sekunden, die auf das Anlaufen des Tests gewartet wird
BAR_WIDTH=30            # Breite des Fortschrittsbalkens

# Größte Zahl, die wir in bash-Arithmetik gefahrlos benutzen (int64-sicher).
NUM_MAX=999999999999999999

EXIT_OK=0
EXIT_WARN=1
EXIT_CRIT=2
EXIT_USAGE=3

# --- Globale Zustände --------------------------------------------------------

RESULT_CODE=$EXIT_OK
WATCH_ABORT=0

OPT_DEVICE=""
OPT_ACTION=""

SMARTCTL_BIN=""
SMART_TARGET=""
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

# --- Ausgabe-Helfer ----------------------------------------------------------

err()  { printf 'Fehler: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }
warn() { printf 'Hinweis: %s\n' "$*"; }

usage() {
  cat <<EOF
$PROGNAME $VERSION — SMART-Zustand und Selbsttests für Datenträger

Aufruf:
  sudo $PROGNAME [Optionen]

Optionen:
  -d, --device GERÄT   Datenträger direkt wählen (z. B. /dev/sda, /dev/nvme0n1)
  -a, --action N       Aktion direkt wählen:
                         1 = komplette SMART-Daten anzeigen
                         2 = kurzer Selbsttest
                         3 = erweiterter Selbsttest
                         4 = nur Zusammenfassung (ohne Test)
                         5 = laufenden Selbsttest abbrechen
  -h, --help           Diese Hilfe anzeigen
  -V, --version        Version anzeigen

Werden -d und -a gemeinsam angegeben, läuft das Skript ohne Rückfragen und
eignet sich damit für Cronjobs oder Skripte.

Exitcodes:
  0  unauffällig oder reine Anzeige
  1  auffällig / stark abgenutzt
  2  kritisch (SMART FAILED)
  3  Nutzungsfehler oder fehlende Voraussetzungen

Beispiele:
  sudo $PROGNAME
  sudo $PROGNAME -d /dev/sda -a 4
  sudo $PROGNAME --device /dev/nvme0n1 --action 2
EOF
}

# Hebt den Ergebniscode an, senkt ihn aber nie ab.
escalate() {
  local code="$1"
  if (( code > RESULT_CODE )); then
    RESULT_CODE=$code
  fi
  return 0
}

# --- Allgemeine Helfer -------------------------------------------------------

is_int() { [[ ${1-} =~ ^[0-9]+$ ]]; }

lower() { printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]'; }

trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Entfernt führende Nullen, damit (( )) den Wert nicht als Oktalzahl liest.
strip_zeros() {
  local s="${1-}"
  while [[ ${#s} -gt 1 && ${s:0:1} == "0" ]]; do
    s="${s:1}"
  done
  printf '%s' "$s"
}

# Wandelt smartctl-Werte in eine reine Dezimalzahl um.
# Beherrscht Hex ("0x04"), Einheiten ("35 Celsius"), Prozent ("5%")
# und Tausendertrenner ("1,234"). Gibt bei Unlesbarkeit einen leeren String aus.
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
  # Sehr große Rohwerte würden die 64-Bit-Arithmetik überlaufen lassen und
  # könnten dadurch negativ werden. Wir deckeln sie stattdessen.
  if (( ${#n} > 18 )); then
    printf '%s' "$NUM_MAX"
  else
    printf '%s' "$n"
  fi
}

# Zahl aus $1 holen, bei Unlesbarkeit $2 (Default 0) liefern.
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

# --- smartctl-Anbindung ------------------------------------------------------

# smartctl liefert eine Bitmaske zurück, keinen klassischen Erfolgsstatus:
#   Bit 0 = Kommandozeile fehlerhaft
#   Bit 1 = Gerät konnte nicht geöffnet werden
#   Bit 2 = einzelnes SMART-Kommando fehlgeschlagen
#   Bit 3..7 = Zustandsbefunde (DISK FAILING, Fehlerlog-Einträge usw.)
# Nur Bit 0 und Bit 1 sind echte Fehlschläge. Alles andere ist eine gültige
# Ausgabe, die wir auswerten wollen.
smart_exec() {
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  [[ -n $out ]] && printf '%s\n' "$out"
  (( (rc & 3) == 0 ))
}

# NVMe-Namespace auf den Controller-Knoten abbilden:
# /dev/nvme0n1 -> /dev/nvme0
smart_target() {
  local dev="$1"
  case "$dev" in
    /dev/nvme*n[0-9]*) printf '%s' "${dev%%n[0-9]*}" ;;
    *)                 printf '%s' "$dev" ;;
  esac
}

# Ermittelt einmalig Ziel und -d-Argumente für das gewählte Gerät.
# Setzt die globalen Variablen SMART_TARGET und SMART_ARGS.
resolve_smart_access() {
  local dev="$1" try
  local -a candidates=("" "-d sat" "-d nvme" "-d scsi" "-d sat,12" "-d ata")
  local -a extra=()

  SMART_TARGET="$(smart_target "$dev")"
  SMART_ARGS=()

  for try in "${candidates[@]}"; do
    extra=()
    [[ -n $try ]] && read -r -a extra <<<"$try"

    if (( ${#extra[@]} > 0 )); then
      if smart_exec "$SMARTCTL_BIN" "${extra[@]}" -i "$SMART_TARGET" >/dev/null 2>&1; then
        SMART_ARGS=("${extra[@]}")
        return 0
      fi
    else
      if smart_exec "$SMARTCTL_BIN" -i "$SMART_TARGET" >/dev/null 2>&1; then
        SMART_ARGS=()
        return 0
      fi
    fi
  done

  return 1
}

# Ruft smartctl für das aufgelöste Gerät auf.
smartctl_dev() {
  if (( ${#SMART_ARGS[@]} > 0 )); then
    smart_exec "$SMARTCTL_BIN" "${SMART_ARGS[@]}" "$@" "$SMART_TARGET"
  else
    smart_exec "$SMARTCTL_BIN" "$@" "$SMART_TARGET"
  fi
}

# Transport-Einordnung anhand von Gerätename und lsblk-TRAN.
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

# Für Fortschritt und Attributauswertung gibt es nur zwei Parser-Familien.
parser_family() {
  case "$1" in
    nvme) printf 'nvme' ;;
    *)    printf 'ata' ;;
  esac
}

# --- Voraussetzungen ---------------------------------------------------------

check_requirements() {
  local candidate

  if (( EUID != 0 )); then
    err "SMART-Zugriff benötigt root-Rechte. Bitte mit sudo starten."
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
    err "smartctl wurde nicht gefunden. Bitte smartmontools installieren (z. B. apt install smartmontools)."
    exit $EXIT_USAGE
  fi

  if ! command -v lsblk >/dev/null 2>&1; then
    err "lsblk wurde nicht gefunden. Bitte util-linux installieren."
    exit $EXIT_USAGE
  fi
}

# --- Geräteauswahl -----------------------------------------------------------

# lsblk -P liefert KEY="VALUE"-Paare. Wir parsen sie per Regex statt per eval,
# damit Modellnamen aus der Firmware keinen Code ausführen können.
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

    dev="/dev/${lsb[NAME]}"
    size="${lsb[SIZE]:-}"
    model="${lsb[MODEL]:-}"
    tran="${lsb[TRAN]:-}"

    [[ -z $model ]] && model="Unbekanntes Modell"
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
  info "Verfügbare Datenträger:"
  echo
  for i in "${!DISK_DEV[@]}"; do
    printf '  %d) %-12s %-32.32s %-8s %s\n' \
      "$(( i + 1 ))" "${DISK_SIZE[$i]}" "${DISK_MODEL[$i]}" "${DISK_TRAN[$i]}" "${DISK_DEV[$i]}"
  done
  echo
}

# Übernimmt Modell/Größe aus der lsblk-Liste, falls das Gerät dort vorkommt.
adopt_metadata() {
  local dev="$1" i
  sel_size="-"
  sel_model="Unbekanntes Modell"
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
      err "$OPT_DEVICE ist kein vorhandenes Blockgerät."
      exit $EXIT_USAGE
    fi
    sel_dev="$OPT_DEVICE"
    adopt_metadata "$sel_dev"
    return 0
  fi

  if (( ${#DISK_DEV[@]} == 0 )); then
    err "Keine Datenträger gefunden."
    exit $EXIT_USAGE
  fi

  print_disks

  if (( ${#DISK_DEV[@]} == 1 )); then
    selected=1
    info "Nur ein Datenträger vorhanden, wird automatisch gewählt."
  else
    while true; do
      read -rp "Nummer des Datenträgers auswählen: " selected || {
        echo; err "Abbruch (keine Eingabe)."; exit $EXIT_USAGE
      }
      if is_int "$selected" && (( selected >= 1 && selected <= ${#DISK_DEV[@]} )); then
        break
      fi
      echo "Ungültige Auswahl."
    done
  fi

  sel_dev="${DISK_DEV[$(( selected - 1 ))]}"
  adopt_metadata "$sel_dev"
}

select_action() {
  if [[ -n $OPT_ACTION ]]; then
    return 0
  fi

  info "Was soll gemacht werden?"
  info "  1) komplette SMART-Daten anzeigen"
  info "  2) kurzer Selbsttest"
  info "  3) erweiterter Selbsttest"
  info "  4) nur Zusammenfassung (ohne Test)"
  info "  5) laufenden Selbsttest abbrechen"
  echo

  while true; do
    read -rp "Auswahl (1/2/3/4/5): " OPT_ACTION || {
      echo; err "Abbruch (keine Eingabe)."; exit $EXIT_USAGE
    }
    case "$OPT_ACTION" in
      1|2|3|4|5) break ;;
      *) echo "Ungültige Auswahl." ;;
    esac
  done
}

# --- Selbsttest-Unterstützung ------------------------------------------------

selftest_supported() {
  local family="$1" out

  out="$(smartctl_dev -c 2>/dev/null || true)"

  case "$family" in
    nvme)
      # Bei NVMe steht die Self-Test-Fähigkeit je nach smartctl-Version in
      # der Capabilities- oder in der Info-Ausgabe.
      out+=$'\n'"$(smartctl_dev -i 2>/dev/null || true)"
      grep -qiE 'Self[-_ ]?Test' <<<"$out"
      ;;
    *)
      grep -qiE 'Short self-test routine' <<<"$out"
      ;;
  esac
}

# --- Fortschritt / Testdauer -------------------------------------------------

# Achtung: smartctl bricht die Zeile zwischen Testnamen und Polling-Zeit um:
#   Short self-test routine
#   recommended polling time:        (   2) minutes.
# Ein Grep auf die zusammenhängende Phrase findet daher nie etwas.
recommended_minutes() {
  local mode="$1" out key val

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

# Laufzustand und Fortschritt werden aus EINER smartctl-Abfrage gewonnen.
# Zwei getrennte Aufrufe pro Durchlauf würden Festplatten unnötig oft
# aufwecken und die Abfrage verdoppeln.
#
# Wichtig: "Self-test execution status" und "completed" stehen auch dann in der
# Ausgabe, wenn nichts läuft; NVMe meldet im Ruhezustand ausdrücklich
# "No self-test in progress". Darauf darf keine Ja/Nein-Prüfung aufbauen.
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
    *)
      out="$(smartctl_dev -c 2>/dev/null || true)"

      # Typisch: "90% of test remaining"
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

abort_selftest() {
  local family="$1"

  echo
  if ! selftest_is_running "$family"; then
    info "Auf $SMART_TARGET läuft derzeit kein Selbsttest."
    return 0
  fi

  info "Laufender Selbsttest auf $SMART_TARGET wird abgebrochen ..."
  echo
  if smartctl_dev -X; then
    echo
    info "Abbruch angefordert."
  else
    err "Der Abbruch konnte nicht durchgeführt werden."
    return 1
  fi
}

# --- Selbsttest starten und beobachten ---------------------------------------

start_selftest() {
  local mode="$1" family="$2"
  local start_ts now elapsed pct remaining est_total est_min rem_txt
  local running=0 seen_running=0 attached=0 interval line last_pct=-1
  local is_tty=0 max_pct=0

  [[ -t 1 ]] && is_tty=1

  echo
  printf 'Selbsttest (%s) auf %s\n' "$mode" "$SMART_TARGET"
  echo

  if ! selftest_supported "$family"; then
    warn "Das Laufwerk meldet keine Selbsttest-Unterstützung. Der Start wird trotzdem versucht."
    echo
  fi

  if selftest_is_running "$family"; then
    warn "Es läuft bereits ein Selbsttest. Es wird kein neuer gestartet, der laufende wird beobachtet."
    attached=1
    seen_running=1
    echo
  else
    if ! smartctl_dev -t "$mode"; then
      err "Der Test konnte nicht gestartet werden."
      return 1
    fi
  fi

  start_ts=$(date +%s)
  est_min="$(recommended_minutes "$mode")"
  est_total=0
  is_int "$est_min" && est_total=$(( est_min * 60 ))

  echo
  info "Fortschritt wird abgefragt. Strg+C beendet nur die Anzeige, der Test läuft weiter."
  echo

  WATCH_ABORT=0
  trap 'WATCH_ABORT=1' INT

  while true; do
    poll_selftest_state "$family"
    running=$POLL_RUNNING
    pct="$POLL_PCT"
    (( running == 1 )) && seen_running=1

    now=$(date +%s)
    elapsed=$(( now - start_ts ))

    remaining=""
    if is_int "$pct"; then
      if (( pct >= 100 )); then
        remaining=0
      elif (( attached == 0 && pct > 0 && elapsed >= 15 )); then
        # Gemessener Fortschritt hochgerechnet. Erst ab etwas Laufzeit
        # sinnvoll, vorher schwankt die Schätzung extrem.
        remaining=$(( elapsed * 100 / pct - elapsed ))
      elif (( est_total > 0 )); then
        # Bei einem übernommenen Test kennen wir den echten Startzeitpunkt
        # nicht; dann trägt nur die Herstellerschätzung.
        remaining=$(( est_total * (100 - pct) / 100 ))
      fi

      [[ -n $remaining ]] && (( remaining < 0 )) && remaining=0

      rem_txt="-"
      [[ -n $remaining ]] && rem_txt="$(human_duration "$remaining")"

      line=$(printf '%s %3d%%  vergangen: %s  verbleibend: %s' \
        "$(bar_for_percent "$pct" "$BAR_WIDTH")" "$pct" \
        "$(human_duration "$elapsed")" "$rem_txt")
    elif (( est_total > 0 && elapsed < est_total )); then
      # Kein gemessener Fortschritt: Herstellerschätzung hochrechnen.
      # Der Balken darf dabei nie zurückspringen.
      pct=$(( elapsed * 100 / est_total ))
      (( pct < max_pct )) && pct=$max_pct
      line=$(printf '%s ~%3d%%  vergangen: %s  verbleibend: %s' \
        "$(bar_for_percent "$pct" "$BAR_WIDTH")" "$pct" \
        "$(human_duration "$elapsed")" "$(human_duration $(( est_total - elapsed )))")
    else
      pct=-1
      line=$(printf '%s  ---  vergangen: %s  verbleibend: -' \
        "$(bar_for_percent 0 "$BAR_WIDTH")" "$(human_duration "$elapsed")")
    fi

    is_int "$pct" && (( pct > max_pct )) && max_pct=$pct

    if (( is_tty )); then
      printf '\r\033[K%s' "$line"
    elif [[ $pct != "$last_pct" ]]; then
      # Ohne Terminal wäre eine Statuszeile pro Abfrage nur Rauschen.
      printf '%s\n' "$line"
      last_pct="$pct"
    fi

    (( WATCH_ABORT )) && break

    if (( running == 0 )); then
      # Erst abbrechen, wenn der Test wirklich lief oder die Anlaufzeit vorbei ist.
      if (( seen_running == 1 || elapsed >= START_GRACE )); then
        break
      fi
    fi

    if (( seen_running )); then
      interval=$POLL_INTERVAL
    else
      interval=$STARTUP_INTERVAL
    fi
    sleep "$interval"

    (( WATCH_ABORT )) && break
  done

  trap - INT

  if (( WATCH_ABORT == 0 && seen_running == 1 )); then
    # Der Test ist durchgelaufen: Balken sauber auf 100 % schließen.
    line=$(printf '%s %3d%%  vergangen: %s  verbleibend: %s' \
      "$(bar_for_percent 100 "$BAR_WIDTH")" 100 "$(human_duration "$elapsed")" "0s")
    if (( is_tty )); then
      printf '\r\033[K%s' "$line"
    else
      printf '%s\n' "$line"
    fi
  fi

  (( is_tty )) && echo
  echo

  if (( WATCH_ABORT )); then
    info "Anzeige abgebrochen. Der Test läuft im Hintergrund weiter."
  elif (( seen_running == 0 )); then
    warn "Es wurde kein laufender Selbsttest erkannt. Entweder war er sofort fertig oder das Laufwerk unterstützt ihn nicht."
  else
    info "Test abgeschlossen."
  fi

  return 0
}

# --- Auswertung --------------------------------------------------------------

show_full_smart() {
  echo
  smartctl_dev -x || true
}

# Liest ein Attribut aus der Tabelle von "smartctl -A".
# Die Spaltenposition wird aus der Kopfzeile bestimmt, weil smartctl je nach
# Ausgabeformat ("old" oder "brief") unterschiedlich viele Spalten druckt.
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

nvme_field() {
  local key="$1" text="$2" val
  val=$(grep -iE "^${key}:" <<<"$text" | head -n1 | cut -d: -f2- || true)
  trim "$val"
}

# Wertet die Ausgabe von "smartctl -H" aus.
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

  printf 'UNBEKANNT'
}

# Entfernt den Versions-/Copyright-Vorspann von smartctl aus einer Ausgabe.
strip_banner() {
  awk '
    !started && (/^smartctl [0-9]/ || /^Copyright \(C\)/ || /^[[:space:]]*$/) { next }
    { started = 1; print }
  ' <<<"${1-}"
}

# Holt den jüngsten Eintrag aus dem Selbsttest-Log (ATA und NVMe).
last_selftest_line() {
  local out="$1"
  awk '
    /^#[[:space:]]*[0-9]+/ { print; exit }
    /^[[:space:]]*[0-9]+[[:space:]]+(Short|Extended|Conveyance|Vendor)/ { print; exit }
  ' <<<"$out"
}

# 0 = in Ordnung oder unbestimmt, 1 = der letzte Test ist fehlgeschlagen
selftest_line_ok() {
  local line="$1"
  [[ -n $line ]] || return 0
  grep -qiE 'without error|Completed[[:space:]]*$' <<<"$line" && return 0
  grep -qiE 'in progress|Aborted|Interrupted|Self-test routine in progress' <<<"$line" && return 0
  grep -qiE 'failure|failed|error|unknown failure' <<<"$line" && return 1
  return 0
}

summary_nvme() {
  local health_state="$1" attrs="$2"
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
    verdict="Kritisch"
    message="SMART meldet einen klaren Fehler. Bitte sofort sichern und das Laufwerk ersetzen."
    escalate $EXIT_CRIT
  elif [[ -n $spare_thr ]] && (( $(num_or "$spare_thr" 0) > 0 )) \
    && (( $(num_or "$spare" 100) <= $(num_or "$spare_thr" 0) )); then
    verdict="Kritisch"
    message="Die Reserveblöcke sind auf oder unter die Herstellerschwelle gefallen. Sofort sichern."
    escalate $EXIT_CRIT
  elif (( $(num_or "$crit" 0) > 0 )); then
    verdict="Auffällig"
    message="Die NVMe meldet eine kritische Warnung. Das Laufwerk sollte beobachtet und zeitnah gesichert werden."
    escalate $EXIT_WARN
  elif (( $(num_or "$pct_used" 0) >= 90 )); then
    verdict="Abgenutzt"
    message="Die SSD hat schon viel Lebensdauer verbraucht. Sie läuft noch, aber das Ende rückt näher."
    escalate $EXIT_WARN
  elif (( $(num_or "$media_err" 0) > 0 )); then
    verdict="Auffällig"
    message="Es wurden Medien-/Datenfehler gezählt. Ein Backup ist sinnvoll, auch wenn das Laufwerk noch arbeiten kann."
    escalate $EXIT_WARN
  elif [[ $health_state == "UNBEKANNT" && -z $attrs ]]; then
    verdict="Unbekannt"
    message="Es konnten keine SMART-Werte gelesen werden. Der Zustand lässt sich nicht beurteilen."
    escalate $EXIT_WARN
  else
    verdict="Unauffällig"
    message="Das Laufwerk wirkt aktuell gesund und unauffällig."
  fi

  echo
  printf 'Zustand: %s\n' "$verdict"
  echo "$message"
  echo
  echo "Wichtige Werte:"
  echo "- SMART-Health: ${health_state}"
  [[ -n $temp      ]] && echo "- Temperatur: ${temp}"
  [[ -n $pct_used  ]] && echo "- Verschleiß (Percentage Used): ${pct_used}"
  [[ -n $spare     ]] && echo "- Verbleibende Reserve: ${spare}"
  [[ -n $spare_thr ]] && echo "- Reserve-Schwelle: ${spare_thr}"
  [[ -n $crit      ]] && echo "- Kritische Warnung: ${crit}"
  [[ -n $media_err ]] && echo "- Media-/Datenfehler: ${media_err}"
  [[ -n $poh       ]] && echo "- Betriebsstunden: ${poh}"
  return 0
}

summary_ata() {
  local health_state="$1" attrs="$2"
  local realloc realloc_ev pending uncorr temp wear poh wear_num
  local verdict message

  realloc="$(ata_raw Reallocated_Sector_Ct "$attrs")"
  realloc_ev="$(ata_raw Reallocated_Event_Count "$attrs")"
  pending="$(ata_raw Current_Pending_Sector "$attrs")"
  uncorr="$(ata_raw Offline_Uncorrectable "$attrs")"
  poh="$(ata_raw Power_On_Hours "$attrs")"
  temp="$(ata_raw Temperature_Celsius "$attrs")"
  [[ -z $temp ]] && temp="$(ata_raw Airflow_Temperature_Cel "$attrs")"

  # Restlebensdauer steht im NORMALISIERTEN Wert (Spalte VALUE), nicht im Rohwert.
  wear="$(ata_val Wear_Leveling_Count "$attrs")"
  [[ -z $wear ]] && wear="$(ata_val Percent_Lifetime_Remain "$attrs")"
  [[ -z $wear ]] && wear="$(ata_val Media_Wearout_Indicator "$attrs")"
  [[ -z $wear ]] && wear="$(ata_val SSD_Life_Left "$attrs")"
  wear_num="$(num_value "$wear")"

  if [[ $health_state == "FAILED" ]]; then
    verdict="Kritisch"
    message="SMART meldet einen klaren Fehler. Bitte sofort sichern und das Laufwerk ersetzen."
    escalate $EXIT_CRIT
  elif (( $(num_or "$realloc" 0)    > 0 )) \
    || (( $(num_or "$realloc_ev" 0) > 0 )) \
    || (( $(num_or "$pending" 0)    > 0 )) \
    || (( $(num_or "$uncorr" 0)     > 0 )); then
    verdict="Auffällig"
    message="Es gibt auffällige Speicherblöcke. Noch kein Totalschaden, aber Backup und Kontrolle sind ratsam."
    escalate $EXIT_WARN
  elif is_int "$wear_num" && (( wear_num < 20 )); then
    verdict="Stark genutzt"
    message="Die Restlebensdauer liegt unter 20 Prozent. Das Laufwerk ist noch nutzbar, Ersatz sollte eingeplant werden."
    escalate $EXIT_WARN
  elif [[ $health_state == "UNBEKANNT" && -z $attrs ]]; then
    verdict="Unbekannt"
    message="Es konnten keine SMART-Werte gelesen werden. Der Zustand lässt sich nicht beurteilen."
    escalate $EXIT_WARN
  else
    verdict="Unauffällig"
    message="Das Laufwerk wirkt aktuell gesund und unauffällig."
  fi

  echo
  printf 'Zustand: %s\n' "$verdict"
  echo "$message"
  echo
  echo "Wichtige Werte:"
  echo "- SMART-Health: ${health_state}"
  [[ -n $temp       ]] && echo "- Temperatur: ${temp} °C"
  [[ -n $poh        ]] && echo "- Betriebsstunden: ${poh}"
  [[ -n $wear_num   ]] && echo "- Restlebensdauer (normalisiert): ${wear_num} %"
  [[ -n $realloc    ]] && echo "- Reallocated Sectors: ${realloc}"
  [[ -n $realloc_ev ]] && echo "- Reallocated Events: ${realloc_ev}"
  [[ -n $pending    ]] && echo "- Pending Sectors: ${pending}"
  [[ -n $uncorr     ]] && echo "- Uncorrectable: ${uncorr}"
  return 0
}

friendly_summary() {
  local family="$1"
  local health_output health_state attrs selftest_log last_line

  health_output="$(smartctl_dev -H 2>/dev/null || true)"
  health_state="$(health_state_from "$health_output")"

  attrs="$(smartctl_dev -A 2>/dev/null || true)"

  if [[ $family == "nvme" ]]; then
    summary_nvme "$health_state" "$attrs"
  else
    summary_ata "$health_state" "$attrs"
  fi

  selftest_log="$(smartctl_dev -l selftest 2>/dev/null || true)"
  last_line="$(last_selftest_line "$selftest_log")"

  if [[ -n $last_line ]] && ! selftest_line_ok "$last_line"; then
    escalate $EXIT_WARN
    echo
    warn "Der jüngste Selbsttest wurde nicht fehlerfrei beendet."
  fi

  echo
  echo "Letztes Selbsttest-Log:"
  selftest_log="$(strip_banner "$selftest_log")"
  if [[ -n $selftest_log ]]; then
    printf '%s\n' "$selftest_log"
  else
    echo "(kein Selbsttest-Log verfügbar)"
  fi
  return 0
}

# --- Argumente ---------------------------------------------------------------

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)    usage; exit $EXIT_OK ;;
      -V|--version) printf '%s %s\n' "$PROGNAME" "$VERSION"; exit $EXIT_OK ;;
      -d|--device)
        (( $# >= 2 )) || { err "$1 benötigt ein Gerät als Argument."; exit $EXIT_USAGE; }
        OPT_DEVICE="$2"; shift 2 ;;
      -a|--action)
        (( $# >= 2 )) || { err "$1 benötigt eine Zahl von 1 bis 5."; exit $EXIT_USAGE; }
        case "$2" in
          1|2|3|4|5) OPT_ACTION="$2" ;;
          *) err "Ungültige Aktion: $2 (erlaubt: 1 bis 5)"; exit $EXIT_USAGE ;;
        esac
        shift 2 ;;
      --) shift; break ;;
      -*) err "Unbekannte Option: $1"; echo >&2; usage >&2; exit $EXIT_USAGE ;;
      *)  err "Unerwartetes Argument: $1"; exit $EXIT_USAGE ;;
    esac
  done
}

# --- Hauptlogik --------------------------------------------------------------

main() {
  parse_args "$@"
  check_requirements
  select_device

  sel_proto="$(device_proto "$sel_dev" "$sel_tran")"
  sel_family="$(parser_family "$sel_proto")"

  if ! resolve_smart_access "$sel_dev"; then
    err "smartctl kann $(smart_target "$sel_dev") nicht ansprechen (auch nicht mit -d sat/nvme/scsi)."
    exit $EXIT_USAGE
  fi

  echo
  printf 'Ausgewählt:  %s  %s  %s  (%s)\n' "$sel_dev" "$sel_size" "$sel_model" "$sel_tran"
  printf 'SMART-Ziel:  %s\n' "$SMART_TARGET"
  printf 'Erkannt als: %s\n' "$sel_proto"

  case "$sel_proto" in
    usb)
      echo
      warn "USB-Gehäuse leiten SMART-Kommandos oft nur unvollständig durch. Selbsttests können scheitern oder falsche Werte liefern."
      ;;
    other)
      echo
      warn "Für diesen Transporttyp sind SMART-Daten in der Regel nicht verfügbar."
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
