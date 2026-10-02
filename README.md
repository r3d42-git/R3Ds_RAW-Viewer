# RAW Viewer

Native, non-destructive macOS photo viewer for camera RAW, JPEG, HEIC, PNG and TIFF files.

## Fotoindex und Vorschaubilder

Beim ersten Start fragt RAW Viewer nach einem Cache-Ordner. Dort werden ausschließlich
der SQLite-Fotoindex und erzeugte Vorschaubilder gespeichert; Originalfotos bleiben
unverändert. Ein Ordner auf einer lokalen SSD bietet die beste Leistung.

Bekannte Ordner werden sofort aus dem Index angezeigt und anschließend im Hintergrund
auf Änderungen geprüft. Unveränderte Dateien behalten ihre bereits gelesenen
Metadaten. Die Einstellungen erlauben einen anderen Cache-Speicherort, eine
Größenbegrenzung sowie das Löschen der Vorschaubilder oder den Neuaufbau des Index.

Nach dem Einlesen erzeugt die App zuerst die sichtbaren und anschließend alle übrigen
Vorschaubilder des ausgewählten Ordners im Hintergrund. Der Grid-Kopf zeigt Prüfung,
Fortschritt, Abschluss und gegebenenfalls fehlgeschlagene Vorschaubilder an.

## Mehrfachauswahl und Export

Im Raster und in der Blocksatzansicht ersetzt ein einfacher Klick die Auswahl. Mit
**⌘-Klick** lassen sich einzelne Fotos ergänzen oder entfernen, **⇧-Klick** markiert
einen zusammenhängenden Bereich, **⌘A** alle sichtbaren Fotos und **Esc** hebt die
Auswahl auf. Die Anzahl der markierten Fotos steht im Grid-Kopf.

Drehen, Zurücksetzen und Exportieren wirken über Toolbar, Menü und Kontextmenü auf
die gesamte Auswahl. Für mehrere Fotos fragt RAW Viewer einmal nach einem Zielordner,
zeigt den Fortschritt im Grid-Kopf und überschreibt keine vorhandenen Dateien:
Namenskollisionen erhalten automatisch eine laufende Nummer.

## Non-destruktive Ausrichtung

Ausgewählte Fotos lassen sich über die Einzelbild-Toolbar, das Kontextmenü oder das
Menü **Bild** in 90-Grad-Schritten nach links und rechts drehen. Die Korrektur wird im
SQLite-Katalog gespeichert und auf Grid, Blocksatz und Einzelbild angewendet, ohne die
Originalpixel oder den 1024-Pixel-Vorschaucache zu verändern. **Ausrichtung zurücksetzen**
stellt den Zustand vor der ersten RAW-Viewer-Korrektur wieder her.

Bei proprietären Kamera-RAWs schreibt RAW Viewer die korrigierte TIFF-Orientierung
zusätzlich sofort und atomar in das zugehörige XMP-Sidecar. Vorhandene Lightroom-Felder
und Schlagwörter bleiben erhalten. DNG, JPEG, HEIC, PNG und TIFF bleiben katalogbasiert,
damit ihre Originaldateien nicht für eine Metadatenänderung neu geschrieben werden.
Falls ein Sidecar nicht sicher aktualisiert werden kann, bleibt die Katalogkorrektur
aktiv und der XMP-Abgleich kann im Kontextmenü wiederholt werden.

JPEG-, PNG- und TIFF-Exporte rechnen die Drehung in die neue Bilddatei ein. Der
Originalexport bleibt bytegenau und nimmt bei proprietären RAWs das vorhandene
XMP-Sidecar neben die Kopie mit; ein bestehendes Ziel-Sidecar wird nicht still
überschrieben.

## Lokale Fotoanalyse mit LM Studio

Unter **Einstellungen → KI-Analyse** lassen sich die Basisadresse eines lokalen oder
entfernten LM-Studio-Servers und die ID eines installierten Vision-Modells hinterlegen.
RAW Viewer prüft den Server beim Start. Eine lokale Instanz kann über die mit LM Studio
gelieferte `lms`-CLI im Hintergrund gestartet werden; ein entfernter Server muss bereits
als Dienst laufen.

Mit **Aktueller Ordner → fehlende Fotos analysieren** werden alle noch nicht bearbeiteten Fotos des aktuellen
Ordners nacheinander analysiert. Die Ordneraktion umfasst den ausgewählten Ordner und
alle seine Unterordner, nicht automatisch den gesamten Fotobestand. Vor dem Start zeigt
eine Bestätigung den genauen Ordner und die Anzahl der ausstehenden Fotos. Die Analyse
kann abgebrochen und später fortgesetzt werden. Die App lädt das gewählte Modell bei
Bedarf und entlädt es nach Abschluss wieder, sofern sie es selbst geladen hat. Schlagwörter,
Bildbeschreibung, Modell und Analysezeit werden im SQLite-Index des Cache-Ordners
gespeichert. Die Originalfotos bleiben unverändert.

Mit **Aktueller Ordner → Schlagwörter für alle Fotos neu erzeugen** lässt sich die
KI-Analyse für den aktuellen Ordner samt Unterordnern vollständig wiederholen. Erfolgreiche
Ergebnisse ersetzen die gespeicherten Schlagwörter und Beschreibungen im Cache; XMP-Dateien
werden erst nach einer ausdrücklichen Bestätigung geschrieben. Nach einer vollständig
erfolgreichen KI-Verschlagwortung fragt RAW Viewer, ob die XMP-Dateien jetzt erzeugt
werden sollen; mit **Später** bleiben die Fotos unverändert und der Export kann weiter
über die separate XMP-Aktion erfolgen.

Beim Laden verwendet RAW Viewer automatisch ein auf präzise Fotoanalyse abgestimmtes
Profil: 16.384 Kontext-Tokens, Temperature 0,1, Top P 0,8, Top K 20, Min P 0,
Repeat Penalty 1,0 und höchstens 2.048 Ausgabetokens. Samplingwerte werden bei jeder
Analyse an LM Studio übermittelt, da sie nicht Teil des Modell-Ladevorgangs sind.

Über **Aktueller Ordner → XMP-Sidecars aktualisieren** lassen sich die gespeicherten
Schlagwörter zusätzlich in portable `.xmp`-Dateien neben proprietären Kamera-RAWs wie
CR3, NEF, ARW oder RAF schreiben. Vorhandene XMP-Dateien werden eingelesen und nur um
fehlende Schlagwörter ergänzt; Lightroom-Einstellungen und manuelle Metadaten bleiben
erhalten. DNG sowie JPEG, HEIC, PNG und TIFF werden nicht über externe Sidecars geändert,
weil Lightroom Metadaten bei diesen Formaten üblicherweise in der Bilddatei erwartet.
Der Exportstatus liegt im SQLite-Index, sodass nach Abbruch oder Neustart nur noch
ausstehende beziehungsweise neu analysierte Fotos verarbeitet werden.

## Frühere Personendaten

Die experimentelle Gesichtserkennung und manuelle Personenzuordnung sind nicht mehr
Bestandteil von RAW Viewer. Falls ein älterer Katalog noch biometrische Einträge enthält,
können diese unter **Einstellungen → Cache → Alte Personendaten löschen** entfernt werden.

Die Schlagwörter erscheinen neben den Metadaten in der linken Informationsfläche. Das
Suchfeld findet Dateinamen, Dateitypen, Schlagwörter und Bildbeschreibungen. Für die
Netzwerknutzung sollte LM Studio 0.4 oder neuer auf dem Rack-Rechner als dauerhaft
laufender Dienst eingerichtet und nur in einem vertrauenswürdigen Netz freigegeben
werden.

## Build and run

```sh
./script/build_and_run.sh
```

Build, bundle and verify without launching:

```sh
./script/build_and_run.sh --build
```

Run the integrated test suite:

```sh
./script/build_and_run.sh --test
```

The build script requires a complete Xcode installation selected through
`xcode-select`. It uses Xcode's active Swift compiler and macOS SDK without a
project-specific SDK override. The current verified setup (2026-09-15) is
macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4 and the macOS 27.0 SDK
on Apple silicon. The minimum deployment target remains macOS 15.0.

The macOS 27 compatibility check passed the release build, all 25 integrated
checks, app launch and local bundle signature verification. A UI smoke test
confirmed the existing photo library, JPEG display and metadata, and the
Blocksatz → F → single photo → G → Blocksatz navigation.

Additional user acceptance testing confirmed successful RAW display with files
from two Canon and two Sony cameras, and successful live AI analysis with
LM Studio. The user also confirmed that the update check correctly reports
that no update is available. The update installation flow could not be tested
because no newer update is available. This check does not constitute a
notarized release.

The generated app bundle is written to `dist/RAW Viewer.app`.

## Zertifiziertes macOS-Release

Offizielle Releases werden lokal mit der Developer ID signiert, von Apple
notarisiert, mit dem Notarisierungsticket versehen und erst nach den unabhängigen
Signatur-, Gatekeeper- und Archivprüfungen veröffentlicht. Zertifikat und
Notarisierungszugang bleiben im macOS-Schlüsselbund; GitHub erhält keine Apple-Secrets.

Voraussetzungen:

- eine gültige `Developer ID Application`-Identität im Schlüsselbund
- das gültige `notarytool`-Schlüsselbundprofil `RAW-Viewer-notary`

Release lokal erstellen:

```sh
./script/release.sh 0.6.4
```

Die an `release.sh` übergebene Versionsnummer wird dabei in die erzeugte App
übernommen; der Updater vergleicht genau diese Versionsnummer mit dem GitHub-Release.

Veröffentlichung zunächst ohne Änderungen an Git oder GitHub prüfen:

```sh
./script/publish_release.sh --dry-run 0.6.4
```

Danach veröffentlicht derselbe Befehl ohne `--dry-run` den bereits geprüften
ZIP-Download als Tag und GitHub-Release. Das fertige Archiv liegt unter
`dist/RAW-Viewer-<Version>-macOS-arm64.zip`.

### Lizenzstand für v0.6.4

Ab v0.6.4 steht RAW Viewer unter **GPL-3.0-or-later**. Die vollständige GPLv3
steht in `LICENSE`; das App-Paket enthält `LICENSE`, `LICENSING.md` und den
historischen MIT-Text `LICENSE-MIT`. Frühere veröffentlichte Versionen behalten
ihre MIT-Lizenz. Der Release- und der Publish-Pfad prüfen die Lizenzdateien im
jeweils tatsächlich verpackten App-Bundle.

## Softwareupdates in der App

RAW Viewer prüft beim Start im Hintergrund das neueste stabile GitHub-Release; über
**RAW Viewer → Nach Updates suchen …** kann die Prüfung jederzeit wiederholt werden.
Ist eine neuere Version verfügbar, wird sie erst nach Bestätigung geladen. Vor dem
Ersetzen der laufenden App prüft RAW Viewer die von GitHub gelieferte SHA-256-Prüfsumme,
Bundle-ID und Developer-ID-Signatur. Erst nach einer zweiten Bestätigung beendet sich die
App, installiert die geprüfte Version am bisherigen App-Standort und startet sie neu.

## Lizenz

RAW Viewer steht ab v0.6.4 unter [GPL-3.0-or-later](LICENSE). Die frühere MIT-Lizenz und der Copyright-Hinweis bleiben in [LICENSE-MIT](LICENSE-MIT) erhalten; frühere Releases behalten ihre jeweilige Lizenz.
