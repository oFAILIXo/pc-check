#Requires -Version 5.1
<#
.SYNOPSIS
    Wartung & Reparatur für Morpheus (v2.4, #54 bis #57): fester Katalog, Prozess-Runner, Ausführung mit Journal.

.DESCRIPTION
    Wird per Dot-Source geladen (pc-check-gui.ps1, Job `wartung`). Definiert die Funktionen aus
    docs/gui-architektur.md, Abschnitt 18 (2.4) und 17 (Systempfade). Regeln:
    - Fester Katalog: Der Browser schickt nur eine Werkzeug-Id, ein Laufwerk aus der Serverliste und winget-Paket-Ids.
    - Programme nur mit vollem Pfad aus System32 (Get-MorpheusSystemProgramm, Systempfade.ps1, Abschnitt 17), winget über
      Get-MorpheusWingetPfad; nie über PATH oder Umgebungsvariablen. Lässt sich ein Pfad nicht auflösen, startet nichts.
    - winget-Updates laufen ohne Adminrechte (2.5, #67) über Invoke-MorpheusWingetBenutzer (WingetBenutzer.ps1).
    - Vor jeder Reparatur ein geprüfter Wiederherstellungspunkt (Safety.ps1); fehlt er, startet nichts ('punkt-fehlt').
    - Jeder Lauf steht vor dem Start im Journal ('begonnen'), danach mit Ergebnis. Kein Rückgängig.
    - Alle Seiteneffekte (Prozess, Punkt, Laufwerke, Start ohne Adminrechte, winget-Pfad, Uhr) laufen über
      $script:MorpheusWartungImpl (Tests ersetzen die Einträge).
    - Fortschritt nur über Write-Information, einzige Pipeline-Ausgabe ist das Ergebnis.
    - Kein Add-Type mit C#-Code. Kein /ResetBase, kein chkdsk /f.
#>

# Abhängigkeiten aus dem gleichen Ordner laden, falls ihre Funktionen fehlen
if (-not (Get-Command -Name PcCheckSafetyEnsureRestorePoint -ErrorAction SilentlyContinue)) {
    $__wSafety = Join-Path $PSScriptRoot 'Safety.ps1'
    if (Test-Path -LiteralPath $__wSafety -PathType Leaf) { . $__wSafety }
}
if (-not (Get-Command -Name Format-MorpheusWartungZeile -ErrorAction SilentlyContinue)) {
    $__wAusw = Join-Path $PSScriptRoot 'WartungAuswertung.ps1'
    if (Test-Path -LiteralPath $__wAusw -PathType Leaf) { . $__wAusw }
}
if (-not (Get-Command -Name Get-MorpheusSystemProgramm -CommandType Function -ErrorAction SilentlyContinue)) {
    $__wSysPfade = Join-Path $PSScriptRoot 'Systempfade.ps1'
    if (Test-Path -LiteralPath $__wSysPfade -PathType Leaf) { . $__wSysPfade }
}
if (-not (Get-Command -Name Get-MorpheusWingetPfad -ErrorAction SilentlyContinue)) {
    $__wWinget = Join-Path $PSScriptRoot 'Winget.ps1'
    if (Test-Path -LiteralPath $__wWinget -PathType Leaf) { . $__wWinget }
}

# Argumentvorlage von winget (Anzeige und Rückfall, falls Winget.ps1 fehlt)
$script:MorpheusWartungWingetArgs = 'upgrade --id {ID} --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'

function MorpheusWartungEintrag {
    param($Gruppe, $Schritt, $Klasse, $Titel, $Erklaerung, $Programm, $Argumente, $Anzeige, $Abbruch, $Parameter, $ZeitlimitSek, $Dauer, [bool]$Internet = $false, $Hinweis = $null, [string]$Kodierung = 'oem', $Bericht = $null)
    @{
        Gruppe = $Gruppe; Schritt = $Schritt; Klasse = $Klasse; Titel = $Titel; Erklaerung = $Erklaerung
        Programm = $Programm; Argumente = $Argumente; Anzeige = $Anzeige; Abbruch = $Abbruch; Parameter = $Parameter
        ZeitlimitSek = $ZeitlimitSek; Dauer = $Dauer; Internet = $Internet; Hinweis = $Hinweis; Kodierung = $Kodierung; Bericht = $Bericht
    }
}

$script:MorpheusWartungKatalog = [ordered]@{}
$script:MorpheusWartungKatalog['wiederherstellung.punkt'] = MorpheusWartungEintrag 'Wiederherstellung' 1 'wartung' 'Wiederherstellungspunkt jetzt anlegen' 'Legt einen Windows-Wiederherstellungspunkt an und prüft, dass er wirklich existiert.' $null '' "Checkpoint-Computer -Description 'Morpheus: von Hand angelegt' -RestorePointType MODIFY_SETTINGS" 'nein' $null $null 'etwa 10 Sekunden' $false 'Windows legt innerhalb von 24 Stunden höchstens einen Punkt an (24-Stunden-Sperre).'
$script:MorpheusWartungKatalog['dism.checkhealth'] = MorpheusWartungEintrag 'Systemdateien' 1 'diagnose' 'DISM: Komponentenspeicher schnell prüfen' 'Prüft schnell, ob Windows eine Beschädigung des Komponentenspeichers bereits vermerkt hat. Ändert nichts.' 'Dism.exe' '/Online /Cleanup-Image /CheckHealth' 'Dism.exe /Online /Cleanup-Image /CheckHealth' 'sofort' $null 600 'unter 1 Minute' $false $null
$script:MorpheusWartungKatalog['dism.scanhealth'] = MorpheusWartungEintrag 'Systemdateien' 2 'diagnose' 'DISM: Komponentenspeicher gründlich prüfen' 'Durchsucht den Komponentenspeicher von Windows nach Beschädigungen. Ändert nichts.' 'Dism.exe' '/Online /Cleanup-Image /ScanHealth' 'Dism.exe /Online /Cleanup-Image /ScanHealth' 'sofort' $null 3600 '5 bis 20 Minuten' $false $null
$script:MorpheusWartungKatalog['dism.restorehealth'] = MorpheusWartungEintrag 'Systemdateien' 3 'reparatur' 'DISM: Komponentenspeicher reparieren' 'Repariert den Komponentenspeicher von Windows mit Dateien von Windows Update.' 'Dism.exe' '/Online /Cleanup-Image /RestoreHealth' 'Dism.exe /Online /Cleanup-Image /RestoreHealth' 'nein' $null 7200 '5 bis 30 Minuten' $true 'Nicht unterbrechen: Microsoft rät davon ab. Der Fortschritt bleibt zeitweise bei 20 oder 62 Prozent stehen.'
$script:MorpheusWartungKatalog['sfc.scannow'] = MorpheusWartungEintrag 'Systemdateien' 4 'reparatur' 'SFC: Systemdateien prüfen und reparieren' 'Prüft die geschützten Windows-Systemdateien und ersetzt beschädigte aus dem Komponentenspeicher.' 'sfc.exe' '/scannow' 'sfc.exe /scannow' 'nein' $null 3600 '5 bis 20 Minuten' $false 'Nicht unterbrechen. Am besten erst nach DISM RestoreHealth ausführen.'
$script:MorpheusWartungKatalog['dism.analyze'] = MorpheusWartungEintrag 'Komponentenspeicher' 1 'diagnose' 'DISM: Komponentenspeicher analysieren' 'Zeigt die Größe des Komponentenspeichers (WinSxS) und ob eine Bereinigung sinnvoll ist. Ändert nichts.' 'Dism.exe' '/Online /Cleanup-Image /AnalyzeComponentStore' 'Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore' 'sofort' $null 1800 '1 bis 5 Minuten' $false $null
$script:MorpheusWartungKatalog['dism.cleanup'] = MorpheusWartungEintrag 'Komponentenspeicher' 2 'reparatur' 'DISM: Komponentenspeicher bereinigen' 'Entfernt veraltete Windows-Komponenten aus dem Komponentenspeicher und gibt Speicherplatz frei.' 'Dism.exe' '/Online /Cleanup-Image /StartComponentCleanup' 'Dism.exe /Online /Cleanup-Image /StartComponentCleanup' 'nein' $null 7200 '5 bis 30 Minuten' $false 'Nicht unterbrechen. Morpheus verwendet kein /ResetBase; Updates lassen sich danach weiter deinstallieren.'
$script:MorpheusWartungKatalog['chkdsk.scan'] = MorpheusWartungEintrag 'Diagnose' 1 'diagnose' 'Datenträger prüfen (nur lesen)' 'Sucht auf dem gewählten Laufwerk online nach Dateisystemfehlern. Repariert nichts.' 'chkdsk.exe' '{LW} /scan' 'chkdsk.exe <LW> /scan' 'sofort' 'laufwerk' 3600 '5 bis 60 Minuten' $false $null
$script:MorpheusWartungKatalog['perfmon.rel'] = MorpheusWartungEintrag 'Diagnose' 2 'diagnose' 'Zuverlässigkeitsverlauf öffnen' 'Zeigt in Windows, wann Programme oder Windows abgestürzt sind. Öffnet sich ohne Adminrechte.' $null '' 'perfmon /rel' 'nein' $null $null 'sofort' $false $null
$script:MorpheusWartungKatalog['dns.flush'] = MorpheusWartungEintrag 'Wartung' 1 'wartung' 'DNS-Zwischenspeicher leeren' 'Löscht die zwischengespeicherten Internetadressen. Hilft, wenn Webseiten nicht mehr gefunden werden.' 'ipconfig.exe' '/flushdns' 'ipconfig.exe /flushdns' 'nein' $null 60 'wenige Sekunden' $false $null
$script:MorpheusWartungKatalog['trim'] = MorpheusWartungEintrag 'Wartung' 2 'wartung' 'SSD optimieren (TRIM)' 'Meldet der SSD, welche Speicherbereiche frei sind. Das hält sie schnell. Es werden keine Dateien verändert.' 'defrag.exe' '{LW} /L' 'defrag.exe <LW> /L' 'sofort' 'ssd' 1800 '1 bis 5 Minuten' $false $null
$script:MorpheusWartungKatalog['zeit.resync'] = MorpheusWartungEintrag 'Wartung' 3 'wartung' 'Uhrzeit neu synchronisieren' 'Gleicht die Windows-Uhr mit dem Zeitserver ab.' 'w32tm.exe' '/resync' 'w32tm.exe /resync' 'nein' $null 120 'wenige Sekunden' $true $null
$script:MorpheusWartungKatalog['powercfg.energy'] = MorpheusWartungEintrag 'Energieberichte' 1 'diagnose' 'Energiebericht erstellen' 'Misst 60 Sekunden lang, was den Energieverbrauch erhöht, und erstellt einen Bericht.' 'powercfg.exe' '/energy /output {BERICHT} /duration 60' 'powercfg.exe /energy /output <Bericht> /duration 60' 'sofort' $null 240 'etwa 1 Minute' $false 'Während der Messung den PC nicht benutzen und Programme schließen.' 'oem' 'energy'
$script:MorpheusWartungKatalog['powercfg.akku'] = MorpheusWartungEintrag 'Energieberichte' 2 'diagnose' 'Akkubericht erstellen' 'Erstellt einen Bericht über Kapazität und Verschleiß des Akkus. Nur bei Notebooks sinnvoll.' 'powercfg.exe' '/batteryreport /output {BERICHT}' 'powercfg.exe /batteryreport /output <Bericht>' 'nein' $null 120 'wenige Sekunden' $false $null 'oem' 'akku'
$script:MorpheusWartungKatalog['powercfg.schlaf'] = MorpheusWartungEintrag 'Energieberichte' 3 'diagnose' 'Schlafstudie erstellen' 'Zeigt, was den PC im Standby geweckt oder Strom verbraucht hat. Braucht Modern Standby.' 'powercfg.exe' '/sleepstudy /output {BERICHT}' 'powercfg.exe /sleepstudy /output <Bericht>' 'nein' $null 120 'wenige Sekunden' $false $null 'oem' 'schlaf'
$script:MorpheusWartungKatalog['winget.upgrade'] = MorpheusWartungEintrag 'Programme' 1 'reparatur' 'Programme mit winget aktualisieren' 'Aktualisiert die ausgewählten Programme mit dem Windows-Paketmanager winget aus den Herstellerquellen. winget läuft dabei ohne Adminrechte; braucht ein Programm Adminrechte, fragt Windows selbst nach.' 'winget' $script:MorpheusWartungWingetArgs 'winget upgrade --id <Paket-Id> --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity' 'nach-paket' 'ids' 1800 'je Programm 1 bis 10 Minuten' $true 'Programme vorher schließen. Ein Programm-Update lässt sich nicht zurücknehmen. Fragt Windows nach Adminrechten, den angezeigten Herausgeber prüfen.' 'utf8'

# Standard-Implementierungen (Tests ersetzen die Einträge)
if (-not $script:MorpheusWartungImpl) {
    $script:MorpheusWartungImpl = @{
        Prozess    = {
            param($Datei, $Argumente, $Kodierung, $AbbruchDatei, $ZeitlimitSek, $Zeile)
            $p = @{ Datei = $Datei; Argumente = [string]$Argumente; Kodierung = [string]$Kodierung; ZeitlimitSek = [int]$ZeitlimitSek }
            if ($AbbruchDatei) { $p.AbbruchDatei = [string]$AbbruchDatei }
            if ($Zeile) { $p.Zeile = $Zeile }
            Invoke-MorpheusWartungProzess @p
        }
        Punkt      = { param($Beschreibung, $JobStart) PcCheckSafetyEnsureRestorePoint -Description $Beschreibung -JobStart $JobStart }
        Laufwerke  = { Get-MorpheusWartungLaufwerke }
        Ohne       = { param($Datei, $Argumente) Start-Process -FilePath $Datei -ArgumentList $Argumente | Out-Null }
        WingetPfad = { Get-MorpheusWingetPfad }
        # winget ohne Adminrechte (2.5, #67): fehlt WingetBenutzer.ps1, startet nichts (kein Rückfall auf Adminrechte)
        WingetBenutzer = {
            param($Datei, $Argumente, $ZeitlimitSek, $Zeile)
            if (-not (Get-Command -Name Invoke-MorpheusWingetBenutzer -CommandType Function -ErrorAction SilentlyContinue)) { throw 'gui\lib\WingetBenutzer.ps1 fehlt; winget wird nicht mit Adminrechten gestartet.' }
            Invoke-MorpheusWingetBenutzer -WingetPfad $Datei -Argumente $Argumente -ZeitlimitSek $ZeitlimitSek -Zeile $Zeile
        }
        Jetzt      = { Get-Date }
    }
}

#region Hilfsfunktionen (privat)

function MorpheusWartungLog {
    param([string]$Text)
    Write-Information -MessageData ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text) -InformationAction Continue
}

# Voller Pfad des Programms (winget über Impl: $null wenn nicht sicher gefunden; System32-Programme: wirft, wenn es fehlt)
function MorpheusWartungProgrammPfad {
    param([string]$Programm)
    if ($Programm -ceq 'winget') {
        $w = & $script:MorpheusWartungImpl.WingetPfad
        if ($null -ne $w -and $w.pfad) { return [string]$w.pfad }
        return $null
    }
    Get-MorpheusSystemProgramm $Programm
}

function MorpheusWartungVorlage {
    param([string]$Vorlage, [string]$Laufwerk, [string]$Id, [string]$Bericht)
    $lw = if ($Laufwerk) { $Laufwerk } else { '<LW>' }
    $paket = if ($Id) { $Id } else { '<Paket-Id>' }
    $ber = if ($Bericht) { $Bericht } else { '<Bericht>' }
    $t = $Vorlage.Replace('{LW}', $lw).Replace('{ID}', $paket)
    $t.Replace('{BERICHT}', ('"' + $ber + '"'))
}

# Argumentzeile im Katalogeintrag (winget über Winget.ps1, sonst Vorlage)
function MorpheusWartungArgumente {
    param([string]$Werkzeug, [string]$Laufwerk, [string]$Id, [string]$Bericht)
    $k = $script:MorpheusWartungKatalog[$Werkzeug]
    if (($Werkzeug -ceq 'winget.upgrade') -and $Id -and (Get-Command -Name Get-MorpheusWingetUpgradeArgumente -ErrorAction SilentlyContinue)) {
        return [string](Get-MorpheusWingetUpgradeArgumente -Id $Id)
    }
    MorpheusWartungVorlage -Vorlage $k.Argumente -Laufwerk $Laufwerk -Id $Id -Bericht $Bericht
}

function MorpheusWartungKurz {
    param([string]$Text, [int]$Max = 500)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    $Text.Substring(0, $Max - 1) + '…'
}

# Zusammenfassung der Ausgabe; ohne Auswertungsdatei Rückfall auf den Exit-Code
function MorpheusWartungZusammenfassen {
    param([string]$Werkzeug, [string]$Text, $ExitCode)
    $z = $null
    if (Get-Command -Name Get-MorpheusWartungZusammenfassung -ErrorAction SilentlyContinue) {
        try { $z = Get-MorpheusWartungZusammenfassung -Werkzeug $Werkzeug -Text $Text -ExitCode $ExitCode } catch { $z = $null }
    }
    if ($null -eq $z) {
        if ($ExitCode -eq 0) { $z = @{ ergebnis = 'unbekannt'; text = 'Beendet mit Code 0, Ausgabe nicht eindeutig'; empfehlung = $null; details = @() } }
        else { $z = @{ ergebnis = 'fehler'; text = ('Beendet mit Code {0}' -f $ExitCode); empfehlung = $null; details = @() } }
    }
    [ordered]@{
        ergebnis   = [string]$z.ergebnis
        text       = [string]$z.text
        empfehlung = $(if ($null -ne $z.empfehlung) { [string]$z.empfehlung } else { $null })
        details    = @($z.details)
    }
}

function MorpheusWartungKurzfassung {
    param($Zusammenfassung, $ExitCode, $DauerSek)
    if (Get-Command -Name Get-MorpheusWartungKurzfassung -ErrorAction SilentlyContinue) {
        try { return (MorpheusWartungKurz ([string](Get-MorpheusWartungKurzfassung -Zusammenfassung $Zusammenfassung -ExitCode $ExitCode -DauerSek $DauerSek))) } catch { }
    }
    MorpheusWartungKurz ([string]$Zusammenfassung.text)
}

function MorpheusWartungBereinigeZeile {
    param([string]$Text)
    if (Get-Command -Name Format-MorpheusWartungZeile -ErrorAction SilentlyContinue) { return [string](Format-MorpheusWartungZeile -Text $Text) }
    $t = ([string]$Text) -replace '[\x00-\x08\x0B-\x1F\x7F]', ''
    MorpheusWartungKurz $t.Trim()
}

#region Journal

function MorpheusWartungJournalBeginn {
    param([string]$DataRoot, $Jetzt, [string]$Art, [string]$Aktion, [string]$Titel, $Variante, $Punkt, [string]$Befehl, [bool]$OhnePunkt, [string]$Status = 'begonnen', $ExitCode = $null)
    $id = PcCheckSafetyNewEntryId $DataRoot
    $e = [ordered]@{
        id                      = $id
        zeit                    = ([datetime]$Jetzt).ToString('s')
        art                     = $Art
        aktion                  = $Aktion
        titel                   = $Titel
        variante                = $Variante
        vorher                  = $null
        nachher                 = $null
        wiederherstellungspunkt = $Punkt
        status                  = $Status
        bezug                   = $null
        meldung                 = ''
        benutzer                = $env:USERNAME
        befehl                  = $Befehl
        dauerSek                = $null
        exitCode                = $ExitCode
        umkehrbar               = $false
        ohnePunkt               = $OhnePunkt
    }
    PcCheckSafetyAddEntry $DataRoot $e
    $id
}

function MorpheusWartungJournalEnde {
    param([string]$DataRoot, [string]$Id, [string]$Status, [string]$Meldung, $DauerSek, $ExitCode)
    PcCheckSafetyUpdateEntry $DataRoot $Id @{ status = $Status; meldung = (MorpheusWartungKurz $Meldung); dauerSek = $DauerSek; exitCode = $ExitCode }
}

#endregion

#region Runner-Helfer

# Beendet den Prozessbaum (taskkill aus System32), dann Kill()
function MorpheusWartungBeenden {
    param($Prozess)
    try {
        $tk = Get-MorpheusSystemProgramm 'taskkill.exe'
        $null = & $tk /PID $Prozess.Id /T /F 2>&1
    } catch { }
    try { if (-not $Prozess.HasExited) { $Prozess.Kill() } } catch { }
}

function MorpheusWartungNeuerStrom {
    param($Strom, [string]$Kodierung)
    @{ Strom = $Strom; Puffer = (New-Object byte[] 16384); Task = $null; Decoder = $null; Erster = $true; Kodierung = $Kodierung; Rest = ''; Ende = $false }
}

# Eine fertige Zeile: an den Aufrufer und (ausser Fortschrittszeilen) in den Gesamttext.
# Gesamttext = Kopf (erste 64 KB) + Ringpuffer ueber die letzten 192 KB; dazwischen steht bei Kuerzung eine Hinweiszeile.
function MorpheusWartungZeileAus {
    param($Z, [string]$Zeile)
    if ([string]::IsNullOrWhiteSpace($Zeile)) { return }
    $istFortschritt = $false
    if ($Z.HatFortschritt) { try { $istFortschritt = ($null -ne (Get-MorpheusWartungFortschritt -Zeile $Zeile)) } catch { } }
    if (-not $istFortschritt) {
        if ((-not $Z.KopfVoll) -and (($Z.Text.Length + $Zeile.Length + 1) -le $Z.KopfMax)) {
            [void]$Z.Text.Append($Zeile).Append("`n")
        } else {
            $Z.KopfVoll = $true
            $Z.Ring.Enqueue($Zeile)
            $Z.RingLen += ($Zeile.Length + 1)
            while (($Z.RingLen -gt $Z.RingMax) -and ($Z.Ring.Count -gt 1)) {
                $alt = [string]$Z.Ring.Dequeue()
                $Z.RingLen -= ($alt.Length + 1)
                $Z.Gekuerzt = $true
            }
        }
    }
    if ($Z.Zeile) { try { [void](& $Z.Zeile $Zeile) } catch { } }
}

function MorpheusWartungGesamttext {
    param($Z)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($Z.Text.ToString())
    if ($Z.Gekuerzt) { [void]$sb.Append([string][char]0x2026).Append(' (Ausgabe gekürzt) ').Append([string][char]0x2026).Append("`n") }
    foreach ($r in $Z.Ring) { [void]$sb.Append($r).Append("`n") }
    return $sb.ToString()
}

# Bytes eines Chunks -> Zeilen
function MorpheusWartungChunk {
    param($S, [int]$N, $Z)
    $offset = 0
    if ($S.Erster) {
        $S.Erster = $false
        if ($S.Kodierung -ceq 'utf8') {
            $enc = New-Object System.Text.UTF8Encoding($false)
        } else {
            $utf16 = $false
            if (($N -ge 2) -and ($S.Puffer[0] -eq 0xFF) -and ($S.Puffer[1] -eq 0xFE)) {
                $utf16 = $true
                $offset = 2
            } elseif ($N -ge 2) {
                $nullen = 0
                $paare = [int][math]::Floor($N / 2)
                for ($i = 1; $i -lt $N; $i += 2) { if ($S.Puffer[$i] -eq 0) { $nullen++ } }
                if (($nullen / $paare) -ge 0.3) { $utf16 = $true }
            }
            if ($utf16) { $enc = [Text.Encoding]::Unicode }
            else { $enc = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
        }
        $S.Decoder = $enc.GetDecoder()
    }
    $chars = New-Object char[] (($N * 2) + 8)
    $len = $S.Decoder.GetChars($S.Puffer, $offset, ($N - $offset), $chars, 0)
    $text = New-Object System.String($chars, 0, $len)
    if ($S.Rest.Length -eq 0 -and $text.Length -gt 0 -and $text[0] -eq [char]0xFEFF -and (-not $S.Bom)) { $text = $text.Substring(1) }
    $S.Bom = $true
    $teile = @(($S.Rest + $text) -split '[\r\n]')
    for ($i = 0; $i -lt ($teile.Count - 1); $i++) { MorpheusWartungZeileAus $Z $teile[$i] }
    $S.Rest = [string]$teile[$teile.Count - 1]
    if ($S.Rest.Length -gt 65536) { MorpheusWartungZeileAus $Z $S.Rest; $S.Rest = '' }
}

#endregion

#endregion

function Invoke-MorpheusWartungProzess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Datei,
        [string]$Argumente = '',
        [ValidateSet('oem', 'utf8')][string]$Kodierung = 'oem',
        [string]$AbbruchDatei,
        [int]$ZeitlimitSek = 0,
        [scriptblock]$Zeile
    )
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Datei
    $psi.Arguments = $Argumente
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $z = @{
        Text = (New-Object System.Text.StringBuilder); KopfMax = 65536; KopfVoll = $false
        Ring = (New-Object System.Collections.Queue); RingLen = 0; RingMax = 196608
        Gekuerzt = $false; Zeile = $Zeile
        HatFortschritt = [bool](Get-Command -Name Get-MorpheusWartungFortschritt -ErrorAction SilentlyContinue)
    }
    $exitGesehen = $null
    $abgebrochen = $false
    $zeitueberschritten = $false
    $beendetBei = $null
    $exit = $null
    try {
        [void]$proc.Start()
        try { $proc.StandardInput.Close() } catch { }
        $streams = @((MorpheusWartungNeuerStrom $proc.StandardOutput.BaseStream $Kodierung), (MorpheusWartungNeuerStrom $proc.StandardError.BaseStream $Kodierung))
        foreach ($s in $streams) { $s.Task = $s.Strom.ReadAsync($s.Puffer, 0, $s.Puffer.Length) }
        while ($true) {
            $offen = @($streams | Where-Object { -not $_.Ende })
            if ($offen.Count -gt 0) {
                $tasks = [Threading.Tasks.Task[]]@($offen | ForEach-Object { $_.Task })
                [void][Threading.Tasks.Task]::WaitAny($tasks, 200)
                foreach ($s in $offen) {
                    if (-not $s.Task.IsCompleted) { continue }
                    $n = 0
                    if (-not ($s.Task.IsFaulted -or $s.Task.IsCanceled)) { $n = [int]$s.Task.Result }
                    if ($n -le 0) {
                        $s.Ende = $true
                        if ($s.Rest.Length -gt 0) { MorpheusWartungZeileAus $z $s.Rest; $s.Rest = '' }
                    } else {
                        MorpheusWartungChunk $s $n $z
                        $s.Task = $s.Strom.ReadAsync($s.Puffer, 0, $s.Puffer.Length)
                    }
                }
            } elseif ($proc.WaitForExit(200)) {
                break
            }
            # Prozess beendet, aber ein Enkelprozess haelt die Pipes offen: noch hoechstens 2 s den Rest einsammeln,
            # dann weiter (der Prozessbaum bleibt bewusst unangetastet)
            if ($proc.HasExited) {
                if ($null -eq $exitGesehen) { $exitGesehen = $sw.Elapsed.TotalSeconds }
                elseif (($sw.Elapsed.TotalSeconds - $exitGesehen) -gt 2) { break }
            }
            if ($null -eq $beendetBei) {
                if ($AbbruchDatei -and (Test-Path -LiteralPath $AbbruchDatei)) {
                    $abgebrochen = $true
                } elseif (($ZeitlimitSek -gt 0) -and ($sw.Elapsed.TotalSeconds -ge $ZeitlimitSek)) {
                    $zeitueberschritten = $true
                }
                if ($abgebrochen -or $zeitueberschritten) {
                    MorpheusWartungBeenden $proc
                    $beendetBei = $sw.Elapsed.TotalSeconds
                }
            } elseif (($sw.Elapsed.TotalSeconds - $beendetBei) -gt 5) {
                break
            }
        }
        [void]$proc.WaitForExit(5000)
        if ($proc.HasExited) { $exit = [int]$proc.ExitCode } else { $exit = -1 }
        foreach ($s in $streams) { if ($s.Rest.Length -gt 0) { MorpheusWartungZeileAus $z $s.Rest; $s.Rest = '' } }
    } finally {
        try { if (-not $proc.HasExited) { MorpheusWartungBeenden $proc } } catch { }
        $proc.Dispose()
    }
    [pscustomobject]@{
        exitCode           = $exit
        text               = (MorpheusWartungGesamttext $z)
        abgebrochen        = $abgebrochen
        zeitueberschritten = $zeitueberschritten
        dauerSek           = [int][math]::Round($sw.Elapsed.TotalSeconds)
    }
}

function Get-MorpheusWartungWerkzeuge {
    [CmdletBinding()]
    param()
    $liste = New-Object System.Collections.ArrayList
    foreach ($id in $script:MorpheusWartungKatalog.Keys) {
        $k = $script:MorpheusWartungKatalog[$id]
        [void]$liste.Add([pscustomobject][ordered]@{
                id         = [string]$id
                gruppe     = $k.Gruppe
                schritt    = $k.Schritt
                klasse     = $k.Klasse
                titel      = $k.Titel
                erklaerung = $k.Erklaerung
                befehl     = $k.Anzeige
                dauer      = $k.Dauer
                abbruch    = $k.Abbruch
                parameter  = $k.Parameter
                punkt      = ($k.Klasse -ceq 'reparatur')
                internet   = [bool]$k.Internet
                hinweis    = $k.Hinweis
                bericht    = ($null -ne $k.Bericht)
            })
    }
    $liste.ToArray()
}

# Feste Laufwerke mit Bezeichnung und SSD-Erkennung (unbekannt = $null)
function Get-MorpheusWartungLaufwerke {
    [CmdletBinding()]
    param()
    $liste = New-Object System.Collections.ArrayList
    $platten = @()
    try { $platten = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop) } catch { }
    foreach ($d in $platten) {
        $lw = [string]$d.DeviceID
        if ($lw -cnotmatch '^[A-Z]:$') { continue }
        $ssd = $null
        try {
            $disk = Get-Partition -DriveLetter $lw.Substring(0, 1) -ErrorAction Stop | Get-Disk -ErrorAction Stop | Select-Object -First 1
            $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$disk.Number } | Select-Object -First 1
            if ($pd) {
                $mt = [string]$pd.MediaType
                if ($mt -eq 'SSD') { $ssd = $true } elseif ($mt -eq 'HDD') { $ssd = $false }
            }
        } catch { $ssd = $null }
        $name = if ([string]$d.VolumeName) { [string]$d.VolumeName } else { 'Lokaler Datenträger' }
        [void]$liste.Add([pscustomobject][ordered]@{ laufwerk = $lw; bezeichnung = $name; ssd = $ssd })
    }
    $liste.ToArray()
}

# $null = gültig, sonst deutscher Fehlertext (rein). winget.upgrade und perfmon.rel haben eigene Wege.
function Test-MorpheusWartungAuftrag {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Werkzeug,
        [AllowNull()][AllowEmptyString()][string]$Laufwerk,
        $Laufwerke
    )
    if ([string]::IsNullOrEmpty($Werkzeug)) { return 'Es wurde kein Werkzeug angegeben.' }
    if (-not (@($script:MorpheusWartungKatalog.Keys) -ccontains $Werkzeug)) { return 'Dieses Werkzeug ist unbekannt.' }
    if ($Werkzeug -ceq 'winget.upgrade') { return 'Programme werden über die Update-Liste aktualisiert, nicht über dieses Werkzeug.' }
    if ($Werkzeug -ceq 'perfmon.rel') { return 'Der Zuverlässigkeitsverlauf wird über seinen eigenen Knopf geöffnet.' }
    $par = $script:MorpheusWartungKatalog[$Werkzeug].Parameter
    $braucht = (($par -ceq 'laufwerk') -or ($par -ceq 'ssd'))
    if (-not $braucht) {
        if (-not [string]::IsNullOrEmpty($Laufwerk)) { return 'Für dieses Werkzeug darf kein Laufwerk angegeben werden.' }
        return $null
    }
    if ([string]::IsNullOrEmpty($Laufwerk)) { return 'Für dieses Werkzeug muss ein Laufwerk gewählt werden.' }
    if ($Laufwerk -cnotmatch '^[A-Z]:$') { return 'Das Laufwerk ist ungültig. Erwartet wird ein Buchstabe mit Doppelpunkt, zum Beispiel C:.' }
    $treffer = @(@($Laufwerke) | Where-Object { ($null -ne $_) -and ([string]$_.laufwerk -ceq $Laufwerk) })
    if ($treffer.Count -eq 0) { return 'Dieses Laufwerk steht nicht in der Liste der festen Laufwerke.' }
    if (($par -ceq 'ssd') -and ($treffer[0].ssd -ne $true)) { return 'TRIM ist nur für Laufwerke sinnvoll, die als SSD erkannt wurden.' }
    $null
}

# Genaue Befehlszeile mit vollem Programmpfad (für Log und Journal)
function Get-MorpheusWartungBefehl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Werkzeug,
        [string]$Laufwerk,
        [string]$Id,
        [string]$Bericht
    )
    if (-not (@($script:MorpheusWartungKatalog.Keys) -ccontains $Werkzeug)) { throw "Unbekanntes Werkzeug '$Werkzeug'." }
    $k = $script:MorpheusWartungKatalog[$Werkzeug]
    if ($null -eq $k.Programm) { return [string]$k.Anzeige }
    # Nur Anzeige: Lässt sich der Pfad nicht auflösen, steht der Programmname da (gestartet wird dann nichts)
    $pfad = $null
    try { $pfad = MorpheusWartungProgrammPfad $k.Programm } catch { $pfad = $null }
    if (-not $pfad) { $pfad = [string]$k.Programm }
    $args1 = MorpheusWartungArgumente -Werkzeug $Werkzeug -Laufwerk $Laufwerk -Id $Id -Bericht $Bericht
    if ($pfad -match '\s') { $pfad = '"' + $pfad + '"' }
    ($pfad + ' ' + $args1).Trim()
}

# Vorhandene Berichte (nur Musternamen, neueste zuerst, höchstens 20)
function Get-MorpheusWartungBerichte {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DataRoot)
    $dir = Join-Path $DataRoot 'reports'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    $titel = @{ energy = 'Energiebericht'; akku = 'Akkubericht'; schlaf = 'Schlafstudie' }
    $liste = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($f.Name, '^morpheus-(energy|akku|schlaf)_([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})\.html\z')
        if (-not $m.Success) { continue }
        $zeit = $f.LastWriteTime
        try { $zeit = [datetime]::ParseExact(($m.Groups[2].Value + ' ' + $m.Groups[3].Value + ':' + $m.Groups[4].Value + ':' + $m.Groups[5].Value), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) } catch { }
        $art = $m.Groups[1].Value
        [void]$liste.Add([pscustomobject][ordered]@{ name = $f.Name; art = $art; titel = $titel[$art]; zeit = $zeit.ToString('s') })
    }
    @(@($liste | Sort-Object -Property @{ Expression = { $_.zeit }; Descending = $true }, @{ Expression = { $_.name }; Descending = $true } | Select-Object -First 20))
}

# Zuverlässigkeitsverlauf: Explorer startet die Ansicht in der Sitzung des Benutzers (ohne Adminrechte)
function Start-MorpheusZuverlaessigkeit {
    [CmdletBinding()]
    param()
    try {
        $explorer = Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe'
        & $script:MorpheusWartungImpl.Ohne $explorer 'shell:::{BB64F8A7-BEE7-4E1A-AB8D-7D8273F7FDB6}\pageReliabilityView'
        [pscustomobject]@{ ok = $true; meldung = 'Der Zuverlässigkeitsverlauf wird geöffnet.' }
    } catch {
        [pscustomobject]@{ ok = $false; meldung = ('Der Zuverlässigkeitsverlauf ließ sich nicht öffnen: ' + $_.Exception.Message + ' Alternative: Win + R, dann perfmon /rel.') }
    }
}

#region Ablauf (privat)

# Wiederherstellungspunkt-Knopf
function MorpheusWartungLaufPunkt {
    param($Res, $Ctx, $K)
    $beschr = 'Morpheus: von Hand angelegt'
    try {
        $pt = & $script:MorpheusWartungImpl.Punkt $beschr $Ctx.Start
    } catch {
        $Res.status = 'fehlgeschlagen'
        $Res.meldung = $_.Exception.Message
        $Res.zusammenfassung = [ordered]@{ ergebnis = 'fehler'; text = (MorpheusWartungKurz $_.Exception.Message); empfehlung = 'Bei aktiver 24-Stunden-Sperre: siehe README, Abschnitt 24-Stunden-Sperre.'; details = @() }
        return
    }
    $Res.punkt = $pt
    $Res.status = 'erledigt'
    $text = 'Wiederherstellungspunkt #{0} angelegt und geprüft.' -f $pt.seq
    $Res.meldung = $text
    $Res.zusammenfassung = [ordered]@{ ergebnis = 'ok'; text = $text; empfehlung = $null; details = @() }
    try {
        $id = MorpheusWartungJournalBeginn -DataRoot $Ctx.DataRoot -Jetzt $Ctx.Start -Art 'wartung' -Aktion $Res.werkzeug -Titel $Res.titel -Variante $null -Punkt $pt -Befehl $K.Anzeige -OhnePunkt $false -Status 'erledigt'
        $Res.journal = $id
        PcCheckSafetyUpdateEntry $Ctx.DataRoot $id @{ meldung = $text }
    } catch {
        $Res.meldung = $text + ' Das Journal ließ sich nicht schreiben: ' + $_.Exception.Message
    }
}

# Zeilen-Callback mit Drosselung (Fortschritt: Sprung >= 10 Punkte; höchstens 4000 Zeilen)
function MorpheusWartungNeuerZeilenLogger {
    param([int]$Max = 4000)
    $script:MorpheusWartungLogZustand = @{ N = 0; Letzter = -1000.0; Gekuerzt = $false; Max = $Max }
    $block = {
        param($Text)
        $z = MorpheusWartungBereinigeZeile $Text
        if ([string]::IsNullOrWhiteSpace($z)) { return }
        $p = $null
        if (Get-Command -Name Get-MorpheusWartungFortschritt -ErrorAction SilentlyContinue) { $p = Get-MorpheusWartungFortschritt -Zeile $z }
        if ($null -ne $p) {
            $p = [double]$p
            $zeigen = (($p -ge 100) -and ($script:MorpheusWartungLogZustand.Letzter -lt 100)) -or (($p - $script:MorpheusWartungLogZustand.Letzter) -ge 10) -or ($p -lt $script:MorpheusWartungLogZustand.Letzter)
            if (-not $zeigen) { return }
            $script:MorpheusWartungLogZustand.Letzter = $p
        }
        if ($script:MorpheusWartungLogZustand.N -ge $script:MorpheusWartungLogZustand.Max) {
            if (-not $script:MorpheusWartungLogZustand.Gekuerzt) { $script:MorpheusWartungLogZustand.Gekuerzt = $true; MorpheusWartungLog '… weitere Ausgabe gekürzt' }
            return
        }
        $script:MorpheusWartungLogZustand.N++
        MorpheusWartungLog $z
    }
    @{ Block = $block }
}

# Wiederherstellungspunkt vor einer Reparatur. Rückgabe: $true = weiter
function MorpheusWartungVorPunkt {
    param($Res, $Ctx, $K, [bool]$OhnePunkt)
    if ($OhnePunkt) {
        $Res.ohnePunkt = $true
        MorpheusWartungLog 'Ohne Wiederherstellungspunkt (vom Nutzer bestätigt)'
        return $true
    }
    $beschr = MorpheusWartungKurz ('Morpheus: vor ' + $K.Titel) 64
    try {
        $Res.punkt = & $script:MorpheusWartungImpl.Punkt $beschr $Ctx.Start
    } catch {
        $Res.status = 'punkt-fehlt'
        $Res.meldung = $_.Exception.Message
        return $false
    }
    $true
}

# Alle Werkzeuge mit genau einem Prozess
function MorpheusWartungLaufProzess {
    param($Res, $Ctx, $K, [string]$Laufwerk, [bool]$OhnePunkt)
    $werkzeug = $Res.werkzeug
    $bericht = $null
    $berichtPfad = $null
    if ($K.Bericht) {
        $dir = Join-Path $Ctx.DataRoot 'reports'
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $bericht = 'morpheus-{0}_{1}.html' -f $K.Bericht, $Ctx.Start.ToString('yyyy-MM-dd_HHmmss')
        $berichtPfad = Join-Path $dir $bericht
    }
    try { $datei = MorpheusWartungProgrammPfad $K.Programm }
    catch {
        $Res.status = 'fehlgeschlagen'
        $Res.meldung = 'Das Windows-Programm ließ sich nicht sicher auflösen, deshalb wurde nichts gestartet: ' + $_.Exception.Message
        return
    }
    $argz = MorpheusWartungArgumente -Werkzeug $werkzeug -Laufwerk $Laufwerk -Bericht $berichtPfad
    $befehl = ('"' + $datei + '" ' + $argz).Trim()
    if ($datei -notmatch '\s') { $befehl = ($datei + ' ' + $argz).Trim() }
    $Res.befehl = $befehl

    if ($K.Klasse -ceq 'reparatur') {
        if (-not (MorpheusWartungVorPunkt $Res $Ctx $K $OhnePunkt)) { return }
    }

    # Journal vor dem Start; ist es nicht schreibbar, startet nichts
    try {
        $jid = MorpheusWartungJournalBeginn -DataRoot $Ctx.DataRoot -Jetzt $Ctx.Start -Art 'wartung' -Aktion $werkzeug -Titel $K.Titel -Variante $(if ($Laufwerk) { $Laufwerk } else { $null }) -Punkt $Res.punkt -Befehl $befehl -OhnePunkt $Res.ohnePunkt
    } catch {
        $Res.status = 'fehlgeschlagen'
        $Res.meldung = 'Das Änderungsjournal ließ sich nicht schreiben, deshalb wurde nichts gestartet: ' + $_.Exception.Message
        return
    }
    $Res.journal = $jid

    MorpheusWartungLog ('Starte: ' + $befehl)
    $logger = MorpheusWartungNeuerZeilenLogger
    $r = $null
    try {
        $r = & $script:MorpheusWartungImpl.Prozess $datei $argz $K.Kodierung $Ctx.AbbruchDatei $K.ZeitlimitSek $logger.Block
    } catch {
        $Res.status = 'fehlgeschlagen'
        $Res.meldung = 'Das Programm ließ sich nicht starten oder lesen: ' + $_.Exception.Message
        $Res.zusammenfassung = [ordered]@{ ergebnis = 'fehler'; text = (MorpheusWartungKurz $Res.meldung); empfehlung = $null; details = @() }
        try { MorpheusWartungJournalEnde $Ctx.DataRoot $jid 'fehlgeschlagen' $Res.meldung 0 $null } catch { }
        return
    }

    $Res.exitCode = $r.exitCode
    $Res.dauerSek = $r.dauerSek
    if ($r.abgebrochen) {
        $Res.status = 'abgebrochen'
        $Res.zusammenfassung = [ordered]@{ ergebnis = 'unbekannt'; text = 'Vom Nutzer abgebrochen.'; empfehlung = $null; details = @() }
    } elseif ($r.zeitueberschritten) {
        $Res.status = 'zeitueberschreitung'
        $Res.zusammenfassung = [ordered]@{ ergebnis = 'fehler'; text = ('Das Zeitlimit von {0} Minuten wurde überschritten; das Werkzeug wurde beendet.' -f [int][math]::Ceiling($K.ZeitlimitSek / 60)); empfehlung = $null; details = @() }
    } else {
        $Res.zusammenfassung = MorpheusWartungZusammenfassen $werkzeug $r.text $r.exitCode
        $Res.status = $(if ($Res.zusammenfassung.ergebnis -ceq 'fehler') { 'fehlgeschlagen' } else { 'erledigt' })
    }
    MorpheusWartungLog ('Ergebnis: ' + $Res.zusammenfassung.text)
    $Res.meldung = MorpheusWartungKurzfassung $Res.zusammenfassung $r.exitCode $r.dauerSek
    $jstatus = switch ($Res.status) { 'erledigt' { 'erledigt' } 'abgebrochen' { 'abgebrochen' } default { 'fehlgeschlagen' } }
    try { MorpheusWartungJournalEnde $Ctx.DataRoot $jid $jstatus $Res.meldung $r.dauerSek $r.exitCode } catch { $Res.meldung += ' (Journal nicht aktualisiert: ' + $_.Exception.Message + ')' }

    if ($berichtPfad -and (Test-Path -LiteralPath $berichtPfad -PathType Leaf)) { $Res.bericht = $bericht }
}

function MorpheusWartungLaufWinget {
    param($Res, $Ctx, $K, $Pakete, [bool]$OhnePunkt)
    $w = $null
    try { $w = & $script:MorpheusWartungImpl.WingetPfad } catch { $w = @{ pfad = $null; grund = ('winget ließ sich nicht prüfen: ' + $_.Exception.Message) } }
    if ($null -eq $w -or -not $w.pfad) {
        $Res.status = 'fehlgeschlagen'
        $Res.meldung = $(if ($w -and $w.grund) { [string]$w.grund } else { 'winget wurde nicht gefunden oder ist nicht vertrauenswürdig.' })
        return
    }
    $datei = [string]$w.pfad
    if (-not (MorpheusWartungVorPunkt $Res $Ctx $K $OhnePunkt)) { return }

    # winget läuft ohne Adminrechte (2.5, #67, G3): Installer, die Adminrechte brauchen, fragen selbst per Windows-Abfrage
    $Res.benutzerkontext = $true
    MorpheusWartungLog 'winget läuft ohne Adminrechte. Braucht ein Programm Adminrechte, fragt Windows selbst nach: Herausgeber prüfen.'

    $abgebrochen = $false
    $n = @($Pakete).Count
    $i = 0
    $erstes = $null
    $gesamt = 0
    $ok = 0
    $fehler = 0
    foreach ($p in @($Pakete)) {
        $i++
        $eintrag = [ordered]@{ id = [string]$p.id; name = [string]$p.name; von = [string]$p.von; auf = [string]$p.auf; status = 'abgebrochen'; exitCode = $null; dauerSek = 0; text = '' }
        $Res.pakete += , $eintrag
        if ($abgebrochen -or ($Ctx.AbbruchDatei -and (Test-Path -LiteralPath $Ctx.AbbruchDatei))) {
            $abgebrochen = $true
            $eintrag.text = 'Nicht gestartet (abgebrochen).'
            continue
        }
        $argz = MorpheusWartungArgumente -Werkzeug 'winget.upgrade' -Id $eintrag.id
        $befehl = ($datei + ' ' + $argz).Trim()
        if ($datei -match '\s') { $befehl = ('"' + $datei + '" ' + $argz).Trim() }
        $titel = 'Update: {0} {1} → {2}' -f $eintrag.name, $eintrag.von, $eintrag.auf
        $jid = $null
        try {
            $jid = MorpheusWartungJournalBeginn -DataRoot $Ctx.DataRoot -Jetzt $Ctx.Start -Art 'update' -Aktion 'winget.upgrade' -Titel $titel -Variante $eintrag.id -Punkt $Res.punkt -Befehl $befehl -OhnePunkt $Res.ohnePunkt
        } catch {
            $eintrag.status = 'fehlgeschlagen'
            $eintrag.text = 'Das Änderungsjournal ließ sich nicht schreiben, deshalb wurde nichts gestartet: ' + $_.Exception.Message
            $fehler++
            continue
        }
        if (-not $erstes) { $erstes = $jid }
        MorpheusWartungLog ('Paket {0}/{1}: {2} ({3} → {4})' -f $i, $n, $eintrag.name, $eintrag.von, $eintrag.auf)
        MorpheusWartungLog ('Starte: ' + $befehl)
        $logger = MorpheusWartungNeuerZeilenLogger
        $r = $null
        try {
            $r = & $script:MorpheusWartungImpl.WingetBenutzer $datei $argz $K.ZeitlimitSek $logger.Block
        } catch {
            $eintrag.status = 'fehlgeschlagen'
            $eintrag.text = 'Das Programm ließ sich nicht starten oder lesen: ' + $_.Exception.Message
            $fehler++
            try { MorpheusWartungJournalEnde $Ctx.DataRoot $jid 'fehlgeschlagen' $eintrag.text 0 $null } catch { }
            continue
        }
        $eintrag.exitCode = $r.exitCode
        $eintrag.dauerSek = $r.dauerSek
        $gesamt += [int]$r.dauerSek
        if ($r.zeitueberschritten) {
            $eintrag.status = 'fehlgeschlagen'
            $eintrag.text = 'Zeitlimit überschritten; winget wurde beendet.'
        } elseif ($null -eq $r.exitCode) {
            $eintrag.status = 'fehlgeschlagen'
            $eintrag.text = $(if ($r.fehler) { [string]$r.fehler } else { 'winget hat kein Ergebnis gemeldet.' })
        } else {
            $e = $null
            if (Get-Command -Name Get-MorpheusWingetErgebnis -ErrorAction SilentlyContinue) { try { $e = Get-MorpheusWingetErgebnis -ExitCode $r.exitCode } catch { $e = $null } }
            if ($null -eq $e) {
                if ($r.exitCode -eq 0) { $e = @{ status = 'aktualisiert'; text = 'Das Programm wurde aktualisiert.' } }
                else { $e = @{ status = 'fehlgeschlagen'; text = ('winget endete mit Code {0}.' -f $r.exitCode) } }
            }
            $eintrag.status = [string]$e.status
            $eintrag.text = [string]$e.text
        }
        # 'laeuft-noch': nichts aktualisiert, zählt wie ein Fehlschlag (erneut versuchen)
        $nichtAktualisiert = (@('fehlgeschlagen', 'laeuft-noch') -ccontains $eintrag.status)
        if ($nichtAktualisiert) { $fehler++ } else { $ok++ }
        MorpheusWartungLog ('Ergebnis: {0}: {1}' -f $eintrag.name, $eintrag.text)
        $js = $(if ($nichtAktualisiert) { 'fehlgeschlagen' } else { 'erledigt' })
        try { MorpheusWartungJournalEnde $Ctx.DataRoot $jid $js $eintrag.text $r.dauerSek $r.exitCode } catch { }
    }
    $Res.journal = $erstes
    $Res.dauerSek = $gesamt
    $nichtGestartet = @($Res.pakete | Where-Object { $_.status -ceq 'abgebrochen' }).Count
    if ($abgebrochen) { $Res.status = 'abgebrochen' }
    elseif ($fehler -gt 0) { $Res.status = 'fehlgeschlagen' }
    else { $Res.status = 'erledigt' }
    $text = '{0} von {1} Programmen erledigt, {2} nicht aktualisiert.' -f $ok, $n, $fehler
    if ($nichtGestartet -gt 0) { $text += " $nichtGestartet nicht gestartet (abgebrochen)." }
    $erg = $(if ($fehler -gt 0) { 'problem' } elseif ($abgebrochen) { 'unbekannt' } else { 'ok' })
    $details = @('winget lief ohne Adminrechte (Benutzerkontext).')
    $Res.zusammenfassung = [ordered]@{ ergebnis = $erg; text = $text; empfehlung = $null; details = @($details) }
    $Res.meldung = $text
    MorpheusWartungLog ('Ergebnis: ' + $text)
}

#endregion

function Invoke-MorpheusWartung {
    [CmdletBinding()]
    param(
        [string]$Root,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Werkzeug,
        [string]$Laufwerk,
        $Pakete,
        [switch]$OhnePunkt,
        [string]$AbbruchDatei
    )
    # --- Argumente prüfen (wirft) ---
    if (-not (@($script:MorpheusWartungKatalog.Keys) -ccontains $Werkzeug)) { throw "Unbekanntes Werkzeug '$Werkzeug'." }
    $k = $script:MorpheusWartungKatalog[$Werkzeug]
    $par = $k.Parameter
    if (($par -ceq 'laufwerk') -or ($par -ceq 'ssd')) {
        if ($Laufwerk -cnotmatch '^[A-Z]:$') { throw 'Für dieses Werkzeug muss ein gültiges Laufwerk wie C: angegeben werden.' }
    } elseif (-not [string]::IsNullOrEmpty($Laufwerk)) {
        throw 'Für dieses Werkzeug darf kein Laufwerk angegeben werden.'
    }
    $paketListe = @()
    if ($Werkzeug -ceq 'winget.upgrade') {
        $paketListe = @($Pakete | Where-Object { $null -ne $_ })
        if (($paketListe.Count -lt 1) -or ($paketListe.Count -gt 30)) { throw 'Für winget müssen 1 bis 30 Programme angegeben werden.' }
        foreach ($p in $paketListe) {
            $pid1 = [string]$p.id
            $gueltig = $false
            if (Get-Command -Name Test-MorpheusWingetId -ErrorAction SilentlyContinue) { $gueltig = [bool](Test-MorpheusWingetId -Id $pid1) }
            else { $gueltig = ($pid1 -cmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$') }
            if (-not $gueltig) { throw "Die Paket-Id '$pid1' ist ungültig." }
        }
    } elseif ($null -ne $Pakete -and @($Pakete).Count -gt 0) {
        throw 'Für dieses Werkzeug dürfen keine Programme angegeben werden.'
    }

    $jetzt = & $script:MorpheusWartungImpl.Jetzt
    $ctx = @{ Root = $Root; DataRoot = $DataRoot; Start = [datetime]$jetzt; AbbruchDatei = $AbbruchDatei }
    $res = [ordered]@{
        werkzeug = $Werkzeug; titel = $k.Titel; klasse = $k.Klasse; status = 'fehlgeschlagen'
        befehl = $k.Anzeige; laufwerk = $(if ($Laufwerk) { $Laufwerk } else { $null })
        exitCode = $null; dauerSek = 0; zusammenfassung = $null; punkt = $null; ohnePunkt = $false
        meldung = ''; bericht = $null; journal = $null; pakete = @(); benutzerkontext = $false
    }
    try {
        if ($Werkzeug -ceq 'wiederherstellung.punkt') {
            MorpheusWartungLaufPunkt $res $ctx $k
        } elseif ($Werkzeug -ceq 'winget.upgrade') {
            MorpheusWartungLaufWinget $res $ctx $k $paketListe ([bool]$OhnePunkt)
        } else {
            MorpheusWartungLaufProzess $res $ctx $k $Laufwerk ([bool]$OhnePunkt)
        }
    } catch {
        $res.status = 'fehlgeschlagen'
        $res.meldung = 'Unerwarteter Fehler: ' + $_.Exception.Message
    } finally {
        if ($AbbruchDatei -and (Test-Path -LiteralPath $AbbruchDatei)) { Remove-Item -LiteralPath $AbbruchDatei -Force -ErrorAction SilentlyContinue }
    }
    [pscustomobject]$res
}
