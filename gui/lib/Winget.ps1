#Requires -Version 5.1
<#
.SYNOPSIS
    winget für Morpheus (v2.4, #57): sicherer Pfad, Liste parsen, Kategorien, Upgrade-Argumente, Exit-Codes.

.DESCRIPTION
    Wird per Dot-Source geladen (pc-check.ps1, Wartung.ps1, Job `updatesuche`). Vertrag: docs/gui-architektur.md Abschnitt 18 (2.4) und 17 (Systempfade).
    - winget wird NIE über PATH gesucht (der App-Alias in %LOCALAPPDATA%\Microsoft\WindowsApps ist vom Benutzer
      beschreibbar). Get-MorpheusWingetPfad ist nur eine Hülle um Get-MorpheusWinget (Systempfade.ps1, Abschnitt 17.4),
      das Paket, Ordner, Reparse Point und Microsoft-Signatur prüft.
    - $script:MorpheusWingetImpl: Ausfuehren, ArpNamen, Appx. Tests ersetzen die Einträge. Der winget-Fund wird in
      Tests über $script:MorpheusPfadImpl (Systempfade.ps1) nachgestellt.
    - Exit-Codes nach winget-cli doc\windows\package-manager\winget\returnCodes.md (APPINSTALLER_CLI_ERROR_*, geprüft
      gegen https://github.com/microsoft/winget-cli, Stand 10/2026); unbekannte Codes werden mit Dezimal- und Hexwert gemeldet.
    - Fortschritt nur über Write-Information, einzige Pipeline-Ausgabe ist das Ergebnis.
    - Updates installieren nur über Invoke-MorpheusWingetBenutzer (WingetBenutzer.ps1, 2.5): winget läuft dabei ohne
      Adminrechte. Seit 2.5.0 (Test C) auch die Update-Suche; Morpheus startet winget nie mit Adminrechten.
#>

# Sichere Pfade (winget-Suche) aus Systempfade.ps1, falls ihre Funktionen fehlen
if (-not (Get-Command -Name Get-MorpheusWinget -CommandType Function -ErrorAction SilentlyContinue)) {
    $__gSysPfade = Join-Path $PSScriptRoot 'Systempfade.ps1'
    if (Test-Path -LiteralPath $__gSysPfade -PathType Leaf) { . $__gSysPfade }
}
# winget ohne Adminrechte (2.5, #67) aus WingetBenutzer.ps1
if (-not (Get-Command -Name Invoke-MorpheusWingetBenutzer -CommandType Function -ErrorAction SilentlyContinue)) {
    $__gBenutzer = Join-Path $PSScriptRoot 'WingetBenutzer.ps1'
    if (Test-Path -LiteralPath $__gBenutzer -PathType Leaf) { . $__gBenutzer }
}

if (-not $script:MorpheusWingetImpl) {
    $script:MorpheusWingetImpl = @{
        # Auch die Suche läuft ohne Adminrechte (2.5.0, Test C): Mit Adminrechten aktualisierte winget die Paketquelle aus
        # Morpheus' Temp-Ordner (nur Administratoren). Solange der Ordner bestand, scheiterte winget ohne Adminrechte
        # mit 0x80070005 (Access is denied).
        Ausfuehren = {
            param($Pfad, $Argumente, $ZeitlimitMs)
            if (-not (Get-Command -Name Invoke-MorpheusWingetBenutzer -CommandType Function -ErrorAction SilentlyContinue)) { throw 'gui\lib\WingetBenutzer.ps1 fehlt; winget wird nicht mit Adminrechten gestartet.' }
            $r = Invoke-MorpheusWingetBenutzer -WingetPfad $Pfad -Argumente $Argumente -ZeitlimitSek ([int][math]::Ceiling([int]$ZeitlimitMs / 1000))
            [pscustomobject]@{ text = [string]$r.text; fehlerText = [string]$r.fehler; exitCode = $r.exitCode; zeitueberschritten = [bool]$r.zeitueberschritten }
        }
        ArpNamen   = {
            @(foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*') {
                    Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object DisplayName | ForEach-Object { ([string]$_.DisplayName).Trim() }
                })
        }
        Appx       = { param($Id) [bool](Get-AppxPackage -Name $Id -ErrorAction SilentlyContinue) }
    }
}

# Dünne Hülle um Get-MorpheusWinget (gui\lib\Systempfade.ps1, Abschnitt 17.4): Rückgabe { pfad; grund }.
# Die gesamte Prüfung (Paket, Ordner, Reparse Point, Signatur) liegt dort; nie ein Rückgriff auf PATH.
function Get-MorpheusWingetPfad {
    [CmdletBinding()]
    param()
    if (-not (Get-Command -Name Get-MorpheusWinget -CommandType Function -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ pfad = $null; grund = 'gui\lib\Systempfade.ps1 fehlt' }
    }
    try {
        $w = Get-MorpheusWinget
        if ($w -and $w.Pfad) { return [pscustomobject]@{ pfad = [string]$w.Pfad; grund = $null } }
        $g = 'winget (App-Installer) wurde nicht gefunden.'
        if ($w -and $w.Grund) { $g = [string]$w.Grund }
        [pscustomobject]@{ pfad = $null; grund = $g }
    }
    catch {
        [pscustomobject]@{ pfad = $null; grund = ('winget konnte nicht geprüft werden: ' + $_.Exception.Message) }
    }
}

function ConvertFrom-MorpheusWingetListe {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { $Text = '' }
    # Fortschrittsanzeigen arbeiten mit \r; pro Zeile zählt nur der Teil nach dem letzten \r (ohne das CR des Zeilenendes).
    $lines = @($Text -split "`n" | ForEach-Object { $_.TrimEnd("`r").Split("`r")[-1] } | Where-Object { $_.Trim() })
    $sep = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^-{10,}') { $sep = $i; break } }
    if ($sep -lt 1) {
        $status = if ($Text -match 'No installed package|Keine installierten|No available upgrade|Keine verfügbaren') { 'keine' } else { 'unlesbar' }
        return [pscustomobject]@{ status = $status; zeilen = @() }
    }
    $starts = @([regex]::Matches($lines[$sep - 1], '\S+') | ForEach-Object Index)
    $rows = @(for ($i = $sep + 1; $i -lt $lines.Count; $i++) {
            $l = $lines[$i]
            if ($l -match '^\d+ \D') { break }
            $cols = for ($c = 0; $c -lt $starts.Count; $c++) {
                $s = $starts[$c]
                $e = if ($c + 1 -lt $starts.Count) { [Math]::Min($starts[$c + 1], $l.Length) } else { $l.Length }
                if ($s -lt $e) { $l.Substring($s, $e - $s).Trim() } else { '' }
            }
            [pscustomobject][ordered]@{ Name = [string]$cols[0]; Id = [string]$cols[1]; Installiert = [string]$cols[2]; Verfuegbar = [string]$cols[3] }
        })
    [pscustomobject]@{ status = 'ok'; zeilen = $rows }
}

# Ordnet ein winget-Update ein. Der Update-Dialog bietet nur Kategorie 'Programm' an:
# Spiele und Launcher sowie Programme mit eigener Update-Funktion aktualisieren sich selbst.
function Get-MorpheusUpdateKategorie {
    [CmdletBinding()]
    param([string]$Id, [string]$Name)
    $gamePublishers = 'Blizzard|ElectronicArts|EpicGames|Valve|Ubisoft|RockstarGames|CloudImperiumGames|GOG|Amazon\.Games|RiotGames|Wargaming|Paradox|Bethesda|Mojang|Roblox|Overwolf|BattlestateGames|Microsoft\.Xbox|Microsoft\.GamingApp'
    if ($Id -match "^($gamePublishers)\." -or $Name -match 'Launcher|Game') { return 'Spiel/Launcher' }
    # Vial meldet keine Version und würde bei jedem Lauf neu installiert
    if ($Id -in 'Autodesk.Fusion', 'Microsoft.Edge', 'Microsoft.Teams', 'Microsoft.Outlook', 'Microsoft.VisualStudioCode', 'Vial.Vial') { return 'aktualisiert sich selbst' }
    'Programm'
}

function Get-MorpheusWingetUpdates {
    [CmdletBinding()]
    param([string]$Text, [switch]$Fortschritt)
    $jetzt = { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }
    # Fortschritt nur mit -Fortschritt (GUI-Job) erzwingen; sonst steuert der Aufrufer über -InformationAction.
    $info = {
        param($t)
        $zeile = '[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $t
        if ($Fortschritt) { Write-Information $zeile -InformationAction Continue } else { Write-Information $zeile }
    }
    $res = [ordered]@{ status = 'fehler'; stand = (& $jetzt); zeilen = @(); fehler = $null; exitCode = $null }
    try {
        $fehlerText = ''
        if (-not $PSBoundParameters.ContainsKey('Text')) {
            $p = Get-MorpheusWingetPfad
            if (-not $p.pfad) { $res.fehler = [string]$p.grund; return [pscustomobject]$res }
            & $info 'winget sucht nach Updates ...'
            $Text = ''
            for ($versuch = 1; ($versuch -le 2) -and (-not ([string]$Text).Trim()); $versuch++) {
                $r = & $script:MorpheusWingetImpl.Ausfuehren $p.pfad 'upgrade --source winget --include-unknown --disable-interactivity' 180000
                if ($r.zeitueberschritten) {
                    $res.status = 'zeitlimit'
                    $res.fehler = 'winget hat nicht innerhalb von 3 Minuten geantwortet'
                    return [pscustomobject]$res
                }
                $Text = [string]$r.text
                $fehlerText = [string]$r.fehlerText
                $res.exitCode = $r.exitCode
            }
        }
        $res.stand = (& $jetzt)
        $liste = ConvertFrom-MorpheusWingetListe -Text $Text
        if ($liste.status -ne 'ok') {
            $res.status = $liste.status
            if ($liste.status -eq 'unlesbar') {
                $zl = @($Text -split "`n" | ForEach-Object { $_.TrimEnd("`r").Split("`r")[-1] } | Where-Object { $_.Trim() } | Select-Object -Last 2)
                $res.fehler = "Ausgabe nicht auswertbar (Exit-Code $($res.exitCode)): " + ((@($zl) + $fehlerText.Trim() | Where-Object { $_ }) -join ' ')
            }
            return [pscustomobject]$res
        }
        # Abgleich mit der Programmliste von Windows: winget führt in seinem Index teils Programme, die längst deinstalliert sind.
        $arp = @(& $script:MorpheusWingetImpl.ArpNamen)
        $rows = @(foreach ($r in $liste.zeilen) {
                # winget kürzt auch die Id-Spalte mit einem Auslassungszeichen; solche Zeilen sind nicht auswählbar.
                $cat = if (-not (Test-MorpheusWingetId -Id $r.Id)) { 'Id gekürzt' } else { Get-MorpheusUpdateKategorie -Id $r.Id -Name $r.Name }
                if ($cat -eq 'Programm') {
                    $name = $r.Name.TrimEnd([char]0x2026, '.', ' ')
                    $inst = [bool]($arp | Where-Object { $_ -like "$name*" } | Select-Object -First 1)
                    if (-not $inst) { $inst = [bool](& $script:MorpheusWingetImpl.Appx $r.Id) }
                    if (-not $inst) { $cat = 'nicht mehr installiert' }
                }
                $r | Add-Member -NotePropertyName Kategorie -NotePropertyValue $cat -PassThru
            })
        $res.status = 'ok'
        $res.zeilen = $rows
        & $info ('{0} Updates gefunden' -f $rows.Count)
    }
    catch {
        $res.status = 'fehler'
        $res.fehler = $_.Exception.Message
    }
    [pscustomobject]$res
}

function Test-MorpheusWingetId {
    [CmdletBinding()]
    param($Id)
    if ($Id -isnot [string]) { return $false }
    [bool]($Id -cmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$')
}

function Get-MorpheusWingetUpgradeArgumente {
    [CmdletBinding()]
    param($Id)
    if (-not (Test-MorpheusWingetId -Id $Id)) { throw 'Ungültige winget-Paket-Id.' }
    "upgrade --id $Id --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
}

function Get-MorpheusWingetErgebnis {
    [CmdletBinding()]
    param([long]$ExitCode)
    $e = { param($s, $t) [pscustomobject]@{ status = $s; text = $t } }
    if ($ExitCode -eq 0) { return (& $e 'aktualisiert' 'Aktualisiert.') }
    [uint32]$u = [uint32]($ExitCode -band 0xFFFFFFFFL)
    switch ([BitConverter]::ToInt32([BitConverter]::GetBytes($u), 0)) {
        0x8A150101 { return (& $e 'laeuft-noch' 'Das Programm läuft noch und muss geschlossen werden.') }
        0x8A150006 { return (& $e 'fehlgeschlagen' 'Der Installer konnte nicht gestartet werden (z. B. Windows-Abfrage nach Adminrechten abgelehnt).') }
        0x8A150111 { return (& $e 'laeuft-noch' 'Das Programm wird gerade von einer Anwendung verwendet und muss geschlossen werden.') }
        0x8A150103 { return (& $e 'laeuft-noch' 'Eine Datei des Programms ist in Benutzung; das Programm muss geschlossen werden.') }
        0x8A150109 { return (& $e 'neustart' 'Aktualisiert; ein Neustart ist nötig, um die Installation abzuschließen.') }
        0x8A15010A { return (& $e 'neustart' 'Ein Neustart ist nötig, bevor die Installation fortgesetzt werden kann.') }
        0x8A15010B { return (& $e 'neustart' 'Der Installer hat einen Neustart eingeleitet.') }
        0x8A15002B { return (& $e 'kein-update' 'Es ist kein anwendbares Update vorhanden.') }
        0x8A15010D { return (& $e 'kein-update' 'Das Programm ist bereits installiert.') }
        0x8A15010E { return (& $e 'kein-update' 'Eine neuere Version ist bereits installiert.') }
        0x8A150114 { return (& $e 'fehlgeschlagen' 'Der Installer unterstützt kein Upgrade der vorhandenen Installation; eine manuelle Neuinstallation ist nötig.') }
        0x8A150108 { return (& $e 'fehlgeschlagen' 'Unbestimmter Installationsfehler; der Hersteller-Support kann helfen.') }
        0x8A150110 { return (& $e 'fehlgeschlagen' 'Die Abhängigkeiten des Programms konnten nicht installiert werden.') }
        0x8A150112 { return (& $e 'fehlgeschlagen' 'Dem Installer wurde ein ungültiger Parameter übergeben.') }
        0x8A150113 { return (& $e 'fehlgeschlagen' 'Dieses System wird vom Programm nicht unterstützt.') }
        0x8A150115 { return (& $e 'fehlgeschlagen' 'Der Installer des Programms hat einen eigenen Fehler gemeldet.') }
        0x8A150102 { return (& $e 'fehlgeschlagen' 'Es läuft bereits eine andere Installation. Später erneut versuchen.') }
        0x8A150104 { return (& $e 'fehlgeschlagen' 'Eine benötigte Abhängigkeit fehlt.') }
        0x8A150105 { return (& $e 'fehlgeschlagen' 'Nicht genug freier Speicherplatz.') }
        0x8A150106 { return (& $e 'fehlgeschlagen' 'Nicht genug Arbeitsspeicher für die Installation.') }
        0x8A150107 { return (& $e 'fehlgeschlagen' 'Keine Netzwerkverbindung für die Installation.') }
        0x8A15010C { return (& $e 'fehlgeschlagen' 'Die Installation wurde abgebrochen.') }
        0x8A15010F { return (& $e 'fehlgeschlagen' 'Eine Richtlinie blockiert die Installation.') }
        0x8A150010 { return (& $e 'fehlgeschlagen' 'Für dieses System ist kein passender Installer vorhanden.') }
        0x8A150011 { return (& $e 'fehlgeschlagen' 'Die Prüfsumme (Hash) der heruntergeladenen Datei stimmt nicht; die Installation wurde aus Sicherheitsgründen abgebrochen.') }
    }
    & $e 'fehlgeschlagen' ('winget-Fehlercode {0} (0x{1:X8})' -f $ExitCode, $u)
}
