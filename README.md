# smart-monitor

Interaktiver SMART-Checker für SATA, NVMe, SAS und USB — mit Selbsttests, Fortschrittsanzeige und einer Zustandsbewertung in Klartext.

Interactive SMART checker for SATA, NVMe, SAS and USB drives — with self-tests, live progress and a plain-language health verdict.

**[🇩🇪 Deutsch](#deutsch) · [🇬🇧 English](#english)**

---

## Deutsch

### Worum geht es

`smart-monitor` ist ein Bash-Skript, das die SMART-Daten eines Datenträgers ausliest, auf Wunsch einen kurzen oder erweiterten Selbsttest startet und den Fortschritt live anzeigt. Am Ende steht keine Attributtabelle, die man erst interpretieren muss, sondern ein Satz wie „Zustand: Auffällig — es gibt auffällige Speicherblöcke".

Es gibt zwei identische Fassungen:

| Datei | Sprache der Ausgabe |
|---|---|
| `smart-monitor.de.sh` | Deutsch |
| `smart-monitor.en.sh` | Englisch |

Die Logik ist in beiden Dateien Zeile für Zeile dieselbe, nur die Texte und Kommentare unterscheiden sich.

### Funktionen

- **Automatische Geräteerkennung** über `lsblk`, mit Transport (SATA, NVMe, USB, SAS, virtio)
- **Automatische Ermittlung der smartctl-Parameter** — probiert der Reihe nach `-d sat`, `-d sat,12`, `-d nvme`, `-d scsi`, `-d ata`, bis das Gerät antwortet
- **Auswertung nach dem, was tatsächlich antwortet** — ob ATA, NVMe oder SCSI, entscheidet die Antwort von `smartctl -i`, nicht der Gerätename. NVMe-SSDs in USB-Gehäusen und Pfade wie `/dev/disk/by-id/…` werden dadurch richtig ausgewertet
- **NVMe-korrekt**: Tests und Logs laufen gegen den Controller-Knoten (`/dev/nvme0`), nicht gegen den Namespace (`/dev/nvme0n1`)
- **SAS-tauglich**: Grown Defect List, Verschleiß von SAS-SSDs, Selbsttest-Fortschritt und Abbruch werden ausgewertet bzw. unterstützt
- **Fortschrittsbalken mit Restzeitschätzung** — gemessen zwischen den Fortschrittsstufen der Firmware, bis zur ersten Stufe aus der Herstellerangabe (`recommended polling time`)
- **Hängt sich an bereits laufende Tests an**, statt sie zu stören oder zu scheitern
- **Klartext-Bewertung** statt Rohwerten, mit passendem Exitcode für die Weiterverarbeitung
- **Nicht-interaktiver Modus** über `-d` und `-a` — geeignet für Cron und systemd
- **Kein `eval`**: die `lsblk`-Ausgabe wird per Regex geparst, damit Modellnamen aus der Firmware keinen Code ausführen können
- Sauber unter `shellcheck`, ohne eine einzige Ausnahme

### Voraussetzungen

- `bash` (Version 4 oder neuer)
- `smartmontools` (liefert `smartctl`)
- `util-linux` (liefert `lsblk`)
- root-Rechte — SMART-Kommandos gehen direkt an die Firmware

```bash
# Debian / Ubuntu
sudo apt install smartmontools util-linux

# Fedora / RHEL
sudo dnf install smartmontools util-linux

# Arch
sudo pacman -S smartmontools util-linux
```

### Installation

```bash
git clone https://github.com/bluhtsturm/smart-monitor.git
cd smart-monitor
chmod +x smart-monitor.de.sh smart-monitor.en.sh

# optional systemweit installieren
sudo install -m 755 smart-monitor.de.sh /usr/local/bin/smart-monitor
```

### Verwendung

Interaktiv — das Skript listet alle Datenträger auf und fragt nach:

```bash
sudo ./smart-monitor.de.sh
```

Nicht-interaktiv, wenn Gerät und Aktion feststehen:

```bash
sudo ./smart-monitor.de.sh -d /dev/sda -a 4          # nur Zusammenfassung
sudo ./smart-monitor.de.sh -d /dev/nvme0n1 -a 2      # kurzer Selbsttest
sudo ./smart-monitor.de.sh --device /dev/sdb --action 3
```

Alle Optionen:

| Option | Bedeutung |
|---|---|
| `-d`, `--device GERÄT` | Datenträger direkt wählen, z. B. `/dev/sda` |
| `-a`, `--action N` | Aktion 1–5 direkt wählen |
| `-h`, `--help` | Hilfe anzeigen |
| `-V`, `--version` | Version anzeigen |

### Die fünf Aktionen

| Nr. | Aktion | Beschreibung |
|---|---|---|
| 1 | Komplette SMART-Daten | Rohausgabe von `smartctl -x`, für die Detailanalyse |
| 2 | Kurzer Selbsttest | Dauert typisch 1–3 Minuten, prüft Elektronik und Stichproben |
| 3 | Erweiterter Selbsttest | Liest die gesamte Oberfläche, bei HDDs mehrere Stunden |
| 4 | Nur Zusammenfassung | Liest Werte aus, startet nichts — der Standard für Cronjobs |
| 5 | Laufenden Test abbrechen | Schickt `smartctl -X` |

Selbsttests sind **lesend und ungefährlich**. Der Datenträger bleibt währenddessen normal benutzbar, der Test läuft in der Firmware und wird bei Zugriffen kurz pausiert. Bei einem erweiterten Test auf einer stark genutzten Platte kann sich die Laufzeit dadurch deutlich verlängern.

`Strg+C` beendet nur die Anzeige. Der Test läuft in der Firmware weiter — später einfach mit Aktion 4 nachsehen oder mit Aktion 5 abbrechen.

### Exitcodes

| Code | Bedeutung |
|---|---|
| `0` | Unauffällig, oder es wurden nur Daten angezeigt |
| `1` | Auffällig, stark abgenutzt oder nicht auswertbar |
| `2` | Kritisch — SMART meldet einen Fehler oder die Reserve ist erschöpft |
| `3` | Nutzungsfehler, fehlende Rechte oder fehlende Programme |

### Wie die Bewertung zustande kommt

**SATA (ATA-Attribute)**

| Zustand | Auslöser | Code |
|---|---|---|
| Kritisch | `smartctl -H` meldet FAILED oder ein Pre-fail-Attribut steht auf `FAILING_NOW` | 2 |
| Auffällig | `Reallocated_Sector_Ct`, `Reallocated_Event_Count`, `Current_Pending_Sector` oder `Offline_Uncorrectable` größer als 0 | 1 |
| Auffällig | Der jüngste Selbsttest ist mit einem Fehler beendet worden | 1 |
| Auffällig | Ein Old_age-Attribut steht auf `FAILING_NOW` (z. B. Temperatur gerade über der Schwelle) | 1 |
| Stark genutzt | Normalisierter Wert von `Wear_Leveling_Count`, `Percent_Lifetime_Remain`, `Media_Wearout_Indicator` oder `SSD_Life_Left` unter 20 | 1 |
| Unbekannt | Weder Health-Status noch Attributtabelle lesbar | 1 |
| Unauffällig | keiner der obigen Fälle | 0 |

**NVMe**

| Zustand | Auslöser | Code |
|---|---|---|
| Kritisch | `smartctl -H` meldet FAILED, **oder** `Available Spare` liegt auf/unter `Available Spare Threshold` | 2 |
| Auffällig | `Critical Warning` ungleich 0 | 1 |
| Auffällig | Der jüngste Selbsttest ist mit einem Fehler beendet worden | 1 |
| Abgenutzt | `Percentage Used` ab 90 % | 1 |
| Auffällig | `Media and Data Integrity Errors` größer als 0 | 1 |
| Unbekannt | keine Werte lesbar | 1 |
| Unauffällig | keiner der obigen Fälle | 0 |

**SAS / SCSI**

| Zustand | Auslöser | Code |
|---|---|---|
| Kritisch | `SMART Health Status` meldet eine drohende Störung (`… FAILURE …`, `BAD`) | 2 |
| Auffällig | `SMART Health Status` meldet eine Warnung (`WARNING - …`, z. B. Temperaturschwelle überschritten) | 1 |
| Auffällig | `Elements in grown defect list` größer als 0 — das Gegenstück zu den Reallocated Sectors | 1 |
| Auffällig | Der jüngste Selbsttest ist mit einem Fehler beendet worden | 1 |
| Abgenutzt | `Percentage used endurance indicator` ab 90 % (nur SAS-SSDs) | 1 |
| Unbekannt | keine Werte lesbar | 1 |
| Unauffällig | keiner der obigen Fälle | 0 |

Der jüngste Eintrag im Selbsttest-Log fließt in die Bewertung ein: Endet er mit einem Fehler (z. B. „Completed: read failure"), lautet der Zustand mindestens „Auffällig" und der Exitcode mindestens 1. Ein abgebrochener oder unterbrochener Test zählt nicht als Fehler. In der Werteliste steht das Ergebnis als „Letzter Selbsttest".

Wichtig: die Restlebensdauer steht im **normalisierten** Wert (Spalte `VALUE`), nicht im Rohwert. `Wear_Leveling_Count` mit Rohwert 201 und VALUE 94 heißt: 94 % Restlebensdauer, nicht 201 von irgendwas. Das ist eine der häufigsten Fehlinterpretationen von SMART-Daten.

### Automatisierung

Tägliche Zustandsprüfung per Cron, mit Meldung nur im Problemfall:

```cron
30 6 * * * root /usr/local/bin/smart-monitor -d /dev/sda -a 4 > /var/log/smart-sda.log 2>&1 || mail -s "SMART-Warnung sda" root < /var/log/smart-sda.log
```

Die Logdatei liegt bewusst nicht unter `/tmp`: Einen festen Dateinamen dort kann jeder Nutzer vorab als Symlink anlegen, und der Cronjob würde dann als root die verlinkte Datei überschreiben.

Wöchentlicher erweiterter Test als systemd-Timer:

```ini
# /etc/systemd/system/smart-longtest@.service
[Unit]
Description=Erweiterter SMART-Selbsttest für %I

[Service]
Type=oneshot
ExecStart=/usr/local/bin/smart-monitor -d /dev/%I -a 3
TimeoutStartSec=infinity
```

```ini
# /etc/systemd/system/smart-longtest@.timer
[Unit]
Description=Wöchentlicher erweiterter SMART-Test für %I

[Timer]
OnCalendar=Sun 03:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now smart-longtest@sda.timer
```

Alternativ den Test entkoppeln: nachts mit Aktion 3 starten, die Anzeige nach kurzer Zeit beenden und am nächsten Morgen mit Aktion 4 das Ergebnis abholen.

Für dauerhafte Überwachung im Hintergrund ist der Daemon `smartd` aus demselben Paket die passendere Wahl. Dieses Skript ist für den Blick von Hand und für gezielte Prüfläufe gedacht.

### Bekannte Einschränkungen

- **USB-Gehäuse** reichen SMART-Kommandos oft nur teilweise durch. Das Skript warnt, versucht es aber trotzdem. Wenn nichts geht, hilft manchmal ein manuelles `smartctl -d sat -a /dev/sdX` oder `-d usbjmicron`.
- **Hardware-RAID-Controller** verstecken die einzelnen Platten. Dafür braucht es gerätespezifische Parameter wie `-d megaraid,N` oder `-d cciss,N`, die das Skript nicht automatisch durchprobiert.
- **SAS/SCSI-Platten** liefern keine ATA-Attributtabelle. Ausgewertet werden Health-Status, Grown Defect List, Temperatur, Betriebsstunden und bei SSDs der Verschleiß. Die Fehlerzähler (`smartctl -l error`) fließen nicht in die Bewertung ein.
- **Virtuelle Datenträger** (virtio, mmc) haben in der Regel gar keine SMART-Daten.
- Die Restzeitschätzung ist eine Schätzung. ATA-Laufwerke melden den Fortschritt nur in 10-%-Stufen; eine gemessene Restzeit gibt es deshalb erst nach der ersten Stufe, vorher gilt die Herstellerangabe. Die ist oft großzügig gerundet.

### Fehlerbehebung

| Meldung | Ursache und Abhilfe |
|---|---|
| `SMART-Zugriff benötigt root-Rechte` | Mit `sudo` starten |
| `smartctl wurde nicht gefunden` | `smartmontools` installieren; auf manchen Systemen liegt es in `/usr/sbin` und ist für normale Nutzer nicht im PATH |
| `smartctl kann … nicht ansprechen` | Kein Zugriff über die üblichen Transportarten. Manuell testen: `sudo smartctl -i -d sat /dev/sdX` |
| `Es wurde kein laufender Selbsttest erkannt` | Das Laufwerk hat den Test entweder sofort beendet oder unterstützt keine Selbsttests (typisch bei USB und virtuellen Platten) |
| Keine Attributwerte in der Zusammenfassung | Wahrscheinlich ein USB-Gehäuse, das SMART nicht durchreicht. Aktion 1 zeigt, was tatsächlich geliefert wird |

### Entwicklung

```bash
shellcheck -s bash smart-monitor.de.sh smart-monitor.en.sh
bash -n smart-monitor.de.sh
```

Beide Dateien sind bewusst logisch identisch. Wer eine ändert, sollte die andere mitziehen; ein Strukturvergleich, der Kommentare und Zeichenketten ausblendet, macht Abweichungen sichtbar:

```bash
norm() { sed -e '/^usage() {/,/^}/d' \
             -e 's/#.*$//' -e "s/'[^']*'/S/g" -e 's/"[^"]*"/S/g' \
             -e 's/[[:space:]]\+/ /g' "$1" | grep -v '^ *$'; }
diff <(norm smart-monitor.de.sh) <(norm smart-monitor.en.sh)
```

### Versionen

**1.2.0**

- Bewertung: „Unbekannt" greift jetzt wirklich, wenn nichts lesbar ist (vorher: „Unauffällig" mit Exitcode 0)
- Bewertung: `FAILING_NOW` wird auch erkannt, wenn `smartctl -H` PASSED meldet
- Bewertung: ein fehlgeschlagener jüngster Selbsttest ist Teil des Zustands, nicht nur ein Hinweis darunter
- Bewertung: SAS/SCSI mit Health-Warnungen, Grown Defect List, Verschleiß, Temperatur und Betriebsstunden
- Erkennung: ATA, NVMe oder SCSI nach der Antwort von `smartctl -i`; `/dev/disk/by-id/…` wird aufgelöst
- Erkennung: `-d sat,12` wird vor `-d scsi` probiert; zram und leere Kartenleser fehlen in der Auswahlliste
- Selbsttest: Restzeit gemessen zwischen den Fortschrittsstufen, statt anfangs um ein Vielfaches zu niedrig
- Selbsttest: Fortschritt und Abbruch bei SAS; Art eines bereits laufenden Tests wird übernommen
- Selbsttest: eine einzelne fehlgeschlagene Abfrage beendet die Anzeige nicht mehr; abgebrochene oder fehlerhafte Tests enden nicht mit 100 %
- CI-Workflow liegt jetzt unter `.github/workflows/` und läuft damit tatsächlich

### Lizenz

MIT — siehe [LICENSE](LICENSE).

---

## English

### What this is

`smart-monitor` is a Bash script that reads a drive's SMART data, optionally starts a short or extended self-test, and shows the progress live. What you get at the end is not an attribute table you still have to interpret, but a sentence like "Condition: Suspicious — there are problem blocks".

There are two identical versions:

| File | Output language |
|---|---|
| `smart-monitor.de.sh` | German |
| `smart-monitor.en.sh` | English |

The logic is line-for-line the same in both files; only the messages and comments differ.

### Features

- **Automatic device discovery** via `lsblk`, including transport (SATA, NVMe, USB, SAS, virtio)
- **Automatic smartctl parameter detection** — tries `-d sat`, `-d sat,12`, `-d nvme`, `-d scsi`, `-d ata` in turn until the device answers
- **Evaluated by what actually answers** — whether ATA, NVMe or SCSI is decided by the `smartctl -i` response, not the device name. NVMe SSDs in USB enclosures and paths such as `/dev/disk/by-id/…` are therefore evaluated correctly
- **NVMe done right**: tests and logs target the controller node (`/dev/nvme0`), not the namespace (`/dev/nvme0n1`)
- **SAS-aware**: grown defect list, SAS SSD wear, self-test progress and aborting are evaluated or supported
- **Progress bar with a remaining-time estimate**, measured between the firmware's progress steps and taken from the vendor's `recommended polling time` until the first step
- **Attaches to an already running test** instead of disturbing it or failing
- **Plain-language verdict** instead of raw values, with a matching exit code for further processing
- **Non-interactive mode** via `-d` and `-a` — suitable for cron and systemd
- **No `eval`**: `lsblk` output is parsed with a regex so that firmware-supplied model names cannot execute code
- Clean under `shellcheck`, without a single suppression

### Requirements

- `bash` (version 4 or newer)
- `smartmontools` (provides `smartctl`)
- `util-linux` (provides `lsblk`)
- root privileges — SMART commands talk straight to the firmware

```bash
# Debian / Ubuntu
sudo apt install smartmontools util-linux

# Fedora / RHEL
sudo dnf install smartmontools util-linux

# Arch
sudo pacman -S smartmontools util-linux
```

### Installation

```bash
git clone https://github.com/bluhtsturm/smart-monitor.git
cd smart-monitor
chmod +x smart-monitor.de.sh smart-monitor.en.sh

# optional: install system-wide
sudo install -m 755 smart-monitor.en.sh /usr/local/bin/smart-monitor
```

### Usage

Interactive — the script lists every drive and asks:

```bash
sudo ./smart-monitor.en.sh
```

Non-interactive, when the device and action are already known:

```bash
sudo ./smart-monitor.en.sh -d /dev/sda -a 4          # summary only
sudo ./smart-monitor.en.sh -d /dev/nvme0n1 -a 2      # short self-test
sudo ./smart-monitor.en.sh --device /dev/sdb --action 3
```

All options:

| Option | Meaning |
|---|---|
| `-d`, `--device DEVICE` | Pick the drive directly, e.g. `/dev/sda` |
| `-a`, `--action N` | Pick action 1–5 directly |
| `-h`, `--help` | Show help |
| `-V`, `--version` | Show version |

### The five actions

| No. | Action | Description |
|---|---|---|
| 1 | Full SMART data | Raw `smartctl -x` output, for detailed analysis |
| 2 | Short self-test | Typically 1–3 minutes; checks electronics and samples the surface |
| 3 | Extended self-test | Reads the entire surface; several hours on hard drives |
| 4 | Summary only | Reads values, starts nothing — the default choice for cron jobs |
| 5 | Abort a running test | Sends `smartctl -X` |

Self-tests are **read-only and harmless**. The drive stays usable while one runs: the test lives in the firmware and is paused briefly whenever the host needs the drive. On a busy disk this can stretch an extended test considerably.

`Ctrl+C` only stops the display. The test keeps running in the firmware — check back later with action 4, or cancel it with action 5.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Healthy, or data was only displayed |
| `1` | Suspicious, heavily worn, or not readable |
| `2` | Critical — SMART reports a failure or the spare pool is exhausted |
| `3` | Usage error, missing privileges or missing programs |

### How the verdict is reached

**SATA (ATA attributes)**

| Verdict | Trigger | Code |
|---|---|---|
| Critical | `smartctl -H` reports FAILED, or a pre-fail attribute is `FAILING_NOW` | 2 |
| Suspicious | `Reallocated_Sector_Ct`, `Reallocated_Event_Count`, `Current_Pending_Sector` or `Offline_Uncorrectable` greater than 0 | 1 |
| Suspicious | The most recent self-test ended with an error | 1 |
| Suspicious | An old-age attribute is `FAILING_NOW` (e.g. temperature currently above its limit) | 1 |
| Heavily used | Normalised value of `Wear_Leveling_Count`, `Percent_Lifetime_Remain`, `Media_Wearout_Indicator` or `SSD_Life_Left` below 20 | 1 |
| Unknown | Neither health status nor attribute table readable | 1 |
| Healthy | None of the above | 0 |

**NVMe**

| Verdict | Trigger | Code |
|---|---|---|
| Critical | `smartctl -H` reports FAILED, **or** `Available Spare` is at/below `Available Spare Threshold` | 2 |
| Suspicious | `Critical Warning` other than 0 | 1 |
| Suspicious | The most recent self-test ended with an error | 1 |
| Worn | `Percentage Used` at 90 % or higher | 1 |
| Suspicious | `Media and Data Integrity Errors` greater than 0 | 1 |
| Unknown | No values readable | 1 |
| Healthy | None of the above | 0 |

**SAS / SCSI**

| Verdict | Trigger | Code |
|---|---|---|
| Critical | `SMART Health Status` reports an impending failure (`… FAILURE …`, `BAD`) | 2 |
| Suspicious | `SMART Health Status` reports a warning (`WARNING - …`, e.g. temperature threshold exceeded) | 1 |
| Suspicious | `Elements in grown defect list` greater than 0 — the counterpart of reallocated sectors | 1 |
| Suspicious | The most recent self-test ended with an error | 1 |
| Worn | `Percentage used endurance indicator` at 90 % or higher (SAS SSDs only) | 1 |
| Unknown | No values readable | 1 |
| Healthy | None of the above | 0 |

The most recent self-test log entry is part of the verdict: if it ended with an error (e.g. "Completed: read failure"), the condition is at least "Suspicious" and the exit code at least 1. An aborted or interrupted test does not count as an error. The key values list shows the result as "Latest self-test".

One thing worth knowing: remaining life lives in the **normalised** value (the `VALUE` column), not in the raw value. `Wear_Leveling_Count` with raw value 201 and VALUE 94 means 94 % life left, not 201 of anything. This is one of the most common misreadings of SMART data.

### Automation

Daily health check via cron, reporting only when something is wrong:

```cron
30 6 * * * root /usr/local/bin/smart-monitor -d /dev/sda -a 4 > /var/log/smart-sda.log 2>&1 || mail -s "SMART warning sda" root < /var/log/smart-sda.log
```

The log file deliberately does not live in `/tmp`: any user can create a fixed file name there in advance as a symlink, and the cron job would then overwrite the link target as root.

Weekly extended test as a systemd timer:

```ini
# /etc/systemd/system/smart-longtest@.service
[Unit]
Description=Extended SMART self-test for %I

[Service]
Type=oneshot
ExecStart=/usr/local/bin/smart-monitor -d /dev/%I -a 3
TimeoutStartSec=infinity
```

```ini
# /etc/systemd/system/smart-longtest@.timer
[Unit]
Description=Weekly extended SMART test for %I

[Timer]
OnCalendar=Sun 03:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now smart-longtest@sda.timer
```

Alternatively, decouple the two halves: start the test at night with action 3, stop watching after a moment, and pick up the result the next morning with action 4.

For continuous background monitoring, the `smartd` daemon from the same package is the better fit. This script is meant for looking by hand and for deliberate test runs.

### Known limitations

- **USB enclosures** frequently pass SMART commands through only partially. The script warns but still tries. When nothing works, a manual `smartctl -d sat -a /dev/sdX` or `-d usbjmicron` sometimes helps.
- **Hardware RAID controllers** hide the individual disks. They need device-specific parameters such as `-d megaraid,N` or `-d cciss,N`, which the script does not try automatically.
- **SAS/SCSI drives** do not expose an ATA attribute table. What gets evaluated is the health status, the grown defect list, temperature, power-on hours and, on SSDs, wear. The error counters (`smartctl -l error`) are not part of the verdict.
- **Virtual drives** (virtio, mmc) usually have no SMART data at all.
- The remaining-time figure is an estimate. ATA drives report progress in 10 % steps only, so a measured figure is available after the first step; until then the vendor figure applies, and that is often generously rounded.

### Troubleshooting

| Message | Cause and remedy |
|---|---|
| `SMART access needs root privileges` | Run it with `sudo` |
| `smartctl was not found` | Install `smartmontools`; on some systems it lives in `/usr/sbin` and is not in a normal user's PATH |
| `smartctl cannot talk to …` | No access via the usual transports. Test by hand: `sudo smartctl -i -d sat /dev/sdX` |
| `No running self-test was detected` | The drive either finished the test instantly or does not support self-tests (common with USB and virtual disks) |
| No attribute values in the summary | Most likely a USB enclosure that does not pass SMART through. Action 1 shows what is actually returned |

### Development

```bash
shellcheck -s bash smart-monitor.de.sh smart-monitor.en.sh
bash -n smart-monitor.de.sh
```

The two files are deliberately identical in logic. Change one and you should change the other; a structural comparison that masks comments and string literals makes any drift visible:

```bash
norm() { sed -e '/^usage() {/,/^}/d' \
             -e 's/#.*$//' -e "s/'[^']*'/S/g" -e 's/"[^"]*"/S/g' \
             -e 's/[[:space:]]\+/ /g' "$1" | grep -v '^ *$'; }
diff <(norm smart-monitor.de.sh) <(norm smart-monitor.en.sh)
```

### Versions

**1.2.0**

- Verdict: "Unknown" now really applies when nothing is readable (previously: "Healthy" with exit code 0)
- Verdict: `FAILING_NOW` is detected even when `smartctl -H` reports PASSED
- Verdict: a failed most recent self-test is part of the condition, not just a note below it
- Verdict: SAS/SCSI with health warnings, grown defect list, wear, temperature and power-on hours
- Detection: ATA, NVMe or SCSI is decided by the `smartctl -i` response; `/dev/disk/by-id/…` is resolved
- Detection: `-d sat,12` is tried before `-d scsi`; zram and empty card readers are left out of the selection list
- Self-test: remaining time measured between progress steps instead of being far too low at the start
- Self-test: progress and aborting on SAS; the kind of an already running test is picked up
- Self-test: a single failed query no longer ends the display; aborted or failed tests no longer end at 100 %
- The CI workflow now lives in `.github/workflows/` and therefore actually runs

### License

MIT — see [LICENSE](LICENSE).
