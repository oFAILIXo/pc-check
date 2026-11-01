#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only Sicherheits- und Performance-Prüfung für Windows 11.

.DESCRIPTION
    Liest Einstellungen, Zustände und Ereignisprotokolle aus und schreibt einen Bericht
    als Markdown und JSON nach reports\. Die Prüfung ändert keine Einstellungen.

    Erst nach dem fertigen Bericht fragt das Script, ob verfügbare Programm-Updates (winget)
    installiert werden sollen. Ohne ausdrückliche Auswahl passiert nichts; abschaltbar mit -NoUpdatePrompt.

    Nebenwirkungen, die nichts am System verstellen:
    - secedit exportiert die lokale Sicherheitsrichtlinie in eine Temp-Datei, die sofort gelöscht wird.
    - Add-Type kompiliert eine kleine Hilfsklasse zum Auslesen der Bildwiederholraten.
    - Die Windows-Update-Suche, winget und die UPnP-Abfrage gehen ins Netz bzw. zum Router
      (abschaltbar mit -SkipUpdateSearch / -SkipWinget).

    - Die Speicherauswertung zählt alle Dateien der festen Laufwerke auf (nur Größen, keine Inhalte;
      abschaltbar mit -SkipSpeicher).

    - Die Sysinternals-Prüfungen (Autoruns, Sigcheck) laufen nur, wenn die Werkzeuge in Morpheus unter
      Werkzeuge eingerichtet und geprüft sind; sonst werden sie übersprungen. Es gehen keine Daten ins Netz
      (kein VirusTotal). Abschaltbar mit -SkipSysinternals.

    Für den vollen Umfang in einer Admin-PowerShell starten.

.PARAMETER OutputDir
    Zielordner für den Bericht. Standard: reports\ neben dem Script.

.PARAMETER EventDays
    Wie viele Tage die Ereignisprotokolle zurück ausgewertet werden. Standard: 14.

.PARAMETER AcceptedFile
    Liste bewusst gewollter Befunde. Standard: accepted.psd1 neben dem Script.
    Passende Warnungen erscheinen im Bericht als "Akzeptiert" statt als Handlungsbedarf.

.PARAMETER SkipSpeicher
    Größte Speicherverbraucher je Laufwerk nicht berechnen; spart je nach Laufwerken 1–3 Minuten.

.PARAMETER SkipSysinternals
    Autoruns- und Sigcheck-Prüfungen (Sysinternals) nicht ausführen; sie dauern je 1–3 Minuten.

.PARAMETER SpielOrdnerFile
    Selbst eingetragene Spiele-Ordner (GUI: Werkzeuge > Spiele-Ordner), nur gelesen.
    Standard: state\spielordner.json neben dem Berichtsordner (OutputDir).

.PARAMETER NoUpdatePrompt
    Keine Nachfrage nach Programm-Updates am Ende (rein lesender Lauf).

.PARAMETER CompareWith
    JSON-Bericht, mit dem verglichen wird. Standard: der jüngste vorhandene Bericht im Zielordner.

.PARAMETER NoOpen
    HTML-Bericht am Ende nicht automatisch im Browser öffnen.

.PARAMETER Profil
    Nutzungsprofil, nach dem Empfehlungen gewichtet werden: Gaming, Office oder Laptop.
    Standard Auto: Laptop, wenn ein Akku vorhanden ist; Gaming bei eigener Grafikkarte; sonst Office.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\pc-check.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$AcceptedFile,
    [ValidateRange(1, 90)][int]$EventDays = 14,
    [switch]$SkipUpdateSearch,
    [switch]$SkipWinget,
    [switch]$SkipSpeicher,
    [switch]$SkipSysinternals,
    [string]$SpielOrdnerFile,
    [switch]$NoUpdatePrompt,
    [string]$CompareWith,
    [switch]$NoOpen,
    [ValidateSet('Auto', 'Gaming', 'Office', 'Laptop')][string]$Profil = 'Auto'
)
# Sicherheit (2.3.3): Module nur aus System32 und Program Files laden, nie aus Benutzerordnern (gui\lib\Systempfade.ps1).
# Als erste Anweisung, damit vorher nichts automatisch geladen wird; Kindprozesse und Jobs erben den Wert.
$env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
# Für Anzeige und Prüfungen: PATH und Temp-Ordner des Benutzers, bevor sie unten bzw. in Set-MorpheusTempPfad ersetzt werden.
# Nur Rückfall: Läuft der Scan als Job der GUI, sind beide schon gehärtet geerbt; die echten Werte kommen unten aus der
# Registry (Get-MorpheusBenutzerTemp, Get-MorpheusBenutzerPath).
$script:BenutzerPath = $env:PATH
$script:BenutzerTemp = $env:TEMP
# Kindprozesse (Jobs, Scan, winget, Windows-Programme): PATH nur Systemordner, keine .NET-Profiler-Variablen aus der
# Benutzerumgebung (HKCU\Environment), über die sich eine DLL in jeden .NET-Prozess laden ließe (2.3.3, N6)
$env:PATH = [Environment]::SystemDirectory + ';' + [Environment]::GetFolderPath('Windows') + ';' + [Environment]::SystemDirectory + '\Wbem;' + [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0'
foreach ($morpheusVar in @([Environment]::GetEnvironmentVariables().Keys)) { if ([string]$morpheusVar -match '^(COR_|CORECLR_|COMPlus_|DOTNET_)') { [Environment]::SetEnvironmentVariable([string]$morpheusVar, $null) } }

$ScriptVersion = '2.5.0'
# Anzeigename (Dateien und Repos heißen weiter pc-check)
$ProductName = 'Morpheus'
$ProductTagline = 'PC Check-up'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Windows-Programme nur mit vollem Pfad aus System32 (über die Windows-API, nicht über PATH oder %SystemRoot%)
$script:Sys32 = [Environment]::SystemDirectory
if (-not $OutputDir) { $OutputDir = Join-Path $PSScriptRoot 'reports' }
if (-not $AcceptedFile) { $AcceptedFile = Join-Path $PSScriptRoot 'accepted.psd1' }
if (-not $SpielOrdnerFile) { $SpielOrdnerFile = Join-Path (Split-Path -Parent $OutputDir) 'state\spielordner.json' }

$script:Findings = New-Object System.Collections.Generic.List[object]
$script:Tables = [ordered]@{}
$script:TableChecks = [ordered]@{}   # Tabellentitel -> Prüfung, aus der die Tabelle stammt (für Links in der GUI)
$script:Area = ''
$script:Category = ''
$script:CheckName = ''
$script:Since = (Get-Date).AddDays(-$EventDays)
$script:Speicher = $null
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:SigCache = @{}
$startedAt = Get-Date

#region Hilfsfunktionen

# Status: CRIT/WARN = Handlungsbedarf, TIPP = lohnende Optimierung (wird aus INFO abgeleitet, siehe Tipps in pc-check.hilfe.psd1),
# INFO = reine Information, ACK = akzeptiert, OK, SKIP = nicht geprüft.
function Add-Finding {
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('OK', 'INFO', 'WARN', 'CRIT', 'SKIP')][string]$Status,
        [Parameter(Position = 1)][string]$Value = '',
        [Parameter(Position = 2)][string]$Recommendation = '',
        [string]$Check = $script:CheckName
    )
    $script:Findings.Add([pscustomobject][ordered]@{
            Area           = $script:Area
            Category       = $script:Category
            Check          = $Check
            Status         = $Status
            Value          = $Value
            Recommendation = $Recommendation
            OriginalStatus = ''
            Note           = ''
            Effort         = ''
            Benefit        = ''
            Risk           = ''
            Steps          = @()
            Command        = ''
        })
}

function Add-Table {
    param([Parameter(Mandatory)][string]$Title, [object[]]$Rows)
    $script:Tables[$Title] = @($Rows | Where-Object { $null -ne $_ })
    if ($script:CheckName) { $script:TableChecks[$Title] = $script:CheckName }
}

function Start-Section {
    param([string]$Area, [string]$Category)
    $script:Area = $Area
    $script:Category = $Category
    Write-Host "`n[$Area] $Category" -ForegroundColor Cyan
}

function Invoke-Check {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Script, [switch]$NeedsAdmin)
    $script:CheckName = $Name
    if ($NeedsAdmin -and -not $script:IsAdmin) {
        Add-Finding SKIP 'Nur mit Adminrechten prüfbar'
        return
    }
    Write-Host "  - $Name"
    try { & $Script }
    catch { Add-Finding SKIP ('Fehler: ' + $_.Exception.Message) }
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    # Das Komma verhindert, dass REG_BINARY/REG_MULTI_SZ in der Pipeline in Einzelwerte zerfallen.
    try { , (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

# Native Programme: stderr verwerfen, ohne dass $ErrorActionPreference = 'Stop' zuschlägt.
function Invoke-Native {
    param([string]$File, [string[]]$Arguments)
    # Nie über PATH auflösen (2.3.3): ein Programm gleichen Namens in einem Benutzerordner liefe sonst mit Adminrechten
    if ($File -notmatch '^[A-Za-z]:\\') { throw "Programm ohne vollen Pfad: $File" }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { , @(& $File @Arguments 2>$null | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $old }
}

function Get-RecentEvents {
    param([Parameter(Mandatory)][hashtable]$Filter, [int]$Max = 1000, [switch]$AllTime)
    $f = $Filter.Clone()
    if (-not $AllTime) { $f['StartTime'] = $script:Since }
    try { Get-WinEvent -FilterHashtable $f -MaxEvents $Max -ErrorAction Stop }
    catch {
        if ($_.FullyQualifiedErrorId -match '^NoMatching(Events|Logs|Providers)Found') { return }
        throw
    }
}

function Get-EventData {
    param($EventRecord)
    $h = @{}
    $xml = [xml]$EventRecord.ToXml()
    foreach ($d in @($xml.Event.EventData.Data)) {
        if ($d -and $d.Name) { $h[$d.Name] = $d.'#text' }
    }
    $h
}

function Format-Date {
    param($Date)
    if ($Date) { ([datetime]$Date).ToString('yyyy-MM-dd HH:mm') } else { '' }
}

function Format-Size {
    param($Bytes)
    if ($null -eq $Bytes) { return '' }
    $b = [double]$Bytes
    if ($b -ge 1TB) { '{0:N2} TB' -f ($b / 1TB) }
    elseif ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) }
    else { '{0:N0} KB' -f ($b / 1KB) }
}

function Get-FolderSize {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $m = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
    [pscustomobject]@{ Bytes = [double]$m.Sum; Files = $m.Count }
}

# Ausführbare Datei aus einer Befehlszeile (Dienst, Autostart, Aufgabe) herauslösen.
function Get-ExePath {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    try {
        $c = Expand-MorpheusUmgebung $CommandLine.Trim()
        if ($c.StartsWith('"')) {
            $end = $c.IndexOf('"', 1)
            $p = if ($end -gt 1) { $c.Substring(1, $end - 1) } else { $c.Trim('"') }
        }
        elseif ($c -match '^(.+?\.(exe|com|sys|dll|bat|cmd|ps1|vbs|js|lnk))(\s|,|$)') { $p = $Matches[1] }
        else { $p = ($c -split '\s+')[0] }
        if ($p -match '^\\\?\?\\') { $p = $p.Substring(4) }
        if ($p -match '^\\SystemRoot\\') { $p = $env:SystemRoot + $p.Substring(11) }
        if ($p -match '^(System32|SysWOW64)\\') { $p = Join-Path $env:SystemRoot $p }
        if (-not [IO.Path]::IsPathRooted($p)) {
            foreach ($dir in "$env:SystemRoot\System32", $env:SystemRoot) {
                $cand = Join-Path $dir $p
                if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
                if (Test-Path -LiteralPath "$cand.exe" -PathType Leaf) { return "$cand.exe" }
            }
        }
        $p
    }
    catch { $CommandLine }
}

function Get-FileSignatureInfo {
    param([string]$Path)
    if (-not $Path) { return [pscustomobject]@{ Path = ''; Exists = $false; Status = 'Unbekannt'; Signer = ''; Company = '' } }
    if ($script:SigCache.ContainsKey($Path)) { return $script:SigCache[$Path] }
    $info = [pscustomobject]@{ Path = $Path; Exists = $false; Status = 'Datei fehlt'; Signer = ''; Company = '' }
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $info.Exists = $true
            $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
            $info.Status = [string]$sig.Status
            if ($sig.SignerCertificate) { $info.Signer = $sig.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) }
            $info.Company = [string](Get-Item -LiteralPath $Path -Force).VersionInfo.CompanyName
        }
    }
    catch { $info.Status = 'Nicht prüfbar' }
    $script:SigCache[$Path] = $info
    $info
}

function Test-UserWritablePath {
    param([string]$Path)
    $Path -match '\\(AppData|Temp|Downloads|Users\\Public)\\'
}

function Get-PowerSetting {
    param([string]$Sub, [string]$Setting, [switch]$Hidden)
    $mode = if ($Hidden) { '/qh' } else { '/q' }
    $out = (Invoke-Native "$script:Sys32\powercfg.exe" @($mode, 'SCHEME_CURRENT', $Sub, $Setting)) -join "`n"
    $hex = @([regex]::Matches($out, '0x([0-9a-fA-F]{8})') | ForEach-Object { [Convert]::ToInt64($_.Groups[1].Value, 16) })
    if ($hex.Count -ge 2) { [pscustomobject]@{ AC = $hex[-2]; DC = $hex[-1] } }
}

function ConvertTo-LooseVersion {
    param([string]$Text)
    if ($Text -match '(\d+)(\.(\d+))?(\.(\d+))?') { [version]('{0}.{1}.{2}' -f [int]$Matches[1], [int]$Matches[3], [int]$Matches[5]) }
}

function Resolve-ExtensionName {
    param($Manifest, [string]$Dir)
    $name = [string]$Manifest.name
    if ($name -match '^__MSG_(.+)__$') {
        $key = $Matches[1]
        foreach ($loc in @('de', 'en', 'en_US', [string]$Manifest.default_locale)) {
            if (-not $loc) { continue }
            $f = Join-Path $Dir "_locales\$loc\messages.json"
            if (-not (Test-Path -LiteralPath $f)) { continue }
            try { $msgs = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            $prop = $msgs.PSObject.Properties | Where-Object { $_.Name -ieq $key } | Select-Object -First 1
            if ($prop) { return [string]$prop.Value.message }
        }
    }
    $name
}

# Liefert den Paketordner der Store-App (MSIX), aus der das Script gestartet wurde, sonst $null.
# Solche Apps virtualisieren Teile von HKCU für alle Prozesse, die sie starten, auch mit Adminrechten.
# GetCurrentPackageFullName erkennt das nicht (die Kindprozesse haben keine Paket-Identität), daher die Elternkette.
function Get-PackagedAncestor {
    $child = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 25 -and $child; $i++) {
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($child.ParentProcessId)" -ErrorAction SilentlyContinue
        # Elternprozess muss älter sein als das Kind, sonst ist die Prozess-ID schon neu vergeben
        if (-not $parent -or $parent.CreationDate -gt $child.CreationDate) { break }
        if ([string]$parent.ExecutablePath -match '\\WindowsApps\\([^\\]+)\\') { return $Matches[1] }
        $child = $parent
    }
    $null
}

# Bewertet eine einzelne Defender-Ausnahme: 'CRIT', 'WARN' oder $null (unauffällig).
function Get-ExclusionRisk {
    param([ValidateSet('Pfad', 'Prozess', 'Endung')][string]$Type, [string]$Value)
    $v = (Expand-MorpheusUmgebung $Value).Trim().TrimEnd('\')
    switch ($Type) {
        'Pfad' {
            # Ganze Laufwerke, System- und Benutzerwurzeln sowie typische Ablageorte für Schadcode
            if ($v -match '^[A-Za-z]:$' -or
                $v -match '^[A-Za-z]:\\(Users|Windows|Program Files( \(x86\))?|ProgramData)$' -or
                $v -match '^[A-Za-z]:\\Users\\[^\\]+$' -or
                $v -match '\\(Temp|Downloads|Desktop|AppData|AppData\\(Local|Roaming|Local\\Temp))$') { return 'CRIT' }
            if ((Test-UserWritablePath "$v\") -or $v -match '[*?]') { return 'WARN' }
        }
        'Prozess' {
            $name = [IO.Path]::GetFileName($v)
            # Alles, was diese Programme starten, bliebe ungescannt
            if ($name -in 'powershell.exe', 'pwsh.exe', 'cmd.exe', 'wscript.exe', 'cscript.exe', 'mshta.exe', 'rundll32.exe', 'regsvr32.exe', 'msiexec.exe', 'explorer.exe', 'svchost.exe') { return 'CRIT' }
            if ($name -in 'node.exe', 'python.exe', 'pythonw.exe', 'java.exe', 'javaw.exe', 'dotnet.exe', 'git.exe', 'bash.exe', 'wsl.exe') { return 'WARN' }
            if (Test-UserWritablePath $v) { return 'WARN' }
        }
        'Endung' {
            if ($v.TrimStart('*', '.') -in 'exe', 'dll', 'sys', 'scr', 'com', 'msi', 'lnk', 'ps1', 'psm1', 'bat', 'cmd', 'js', 'jse', 'vbs', 'vbe', 'wsf', 'hta', 'jar', 'py') { return 'CRIT' }
        }
    }
    $null
}

# Laufwerkstyp zu einem Laufwerksbuchstaben, z. B. 'NVMe-SSD', 'SATA-SSD', 'HDD'
function Get-DriveKind {
    param([string]$Letter)
    $Letter = $Letter.TrimEnd(':', '\')
    if (-not $script:DriveKindCache) { $script:DriveKindCache = @{} }
    if ($script:DriveKindCache.ContainsKey($Letter)) { return $script:DriveKindCache[$Letter] }
    $kind = 'unbekannt'
    try {
        $num = (Get-Partition -DriveLetter $Letter -ErrorAction Stop | Get-Disk -ErrorAction Stop).Number
        $pd = Get-PhysicalDisk | Where-Object { [string]$_.DeviceId -eq [string]$num } | Select-Object -First 1
        if ($pd) {
            $media = [string]$pd.MediaType
            $kind = if ($media -eq 'HDD') { 'HDD' } elseif ([string]$pd.BusType -eq 'NVMe') { 'NVMe-SSD' } elseif ($media -eq 'SSD') { "$($pd.BusType)-SSD" } else { "$($pd.BusType)" }
        }
    }
    catch {}
    $script:DriveKindCache[$Letter] = $kind
    $kind
}

# Bibliotheken (Speicherverbraucher, Spieleliste, Datensicherung): Dot-Source auf Skriptebene, damit die Funktionen sichtbar sind
$script:SpeicherLib = $false
$script:SicherungLib = $false
$speicherLibPfad = Join-Path $PSScriptRoot 'gui\lib\Speicher.ps1'
if (Test-Path -LiteralPath $speicherLibPfad) { . $speicherLibPfad; $script:SpeicherLib = $true }
$script:WingetLib = $false
$wingetLibPfad = Join-Path $PSScriptRoot 'gui\lib\Winget.ps1'
if (Test-Path -LiteralPath $wingetLibPfad) { . $wingetLibPfad; $script:WingetLib = $true }
$sicherungLibPfad = Join-Path $PSScriptRoot 'gui\lib\Sicherung.ps1'
if (Test-Path -LiteralPath $sicherungLibPfad) { . $sicherungLibPfad; $script:SicherungLib = $true }
# Akzeptanzliste: früh einlesen, weil die Sigcheck-Prüfung die Datei-Regeln (je SHA256) braucht
$script:AkzeptanzLib = $false
$akzeptanzLibPfad = Join-Path $PSScriptRoot 'gui\lib\Akzeptanz.ps1'
if (Test-Path -LiteralPath $akzeptanzLibPfad) {
    try { . $akzeptanzLibPfad; $script:AkzeptanzLib = [bool](Get-Command Read-MorpheusAkzeptanz -CommandType Function -ErrorAction SilentlyContinue) }
    catch { $script:AkzeptanzLib = $false }
}
$script:AkzeptanzRegeln = @()
if (Test-Path -LiteralPath $AcceptedFile) {
    try {
        if ($script:AkzeptanzLib) { $script:AkzeptanzRegeln = @(Read-MorpheusAkzeptanz -Datei $AcceptedFile | Where-Object { $_ }) }
        else { $script:AkzeptanzRegeln = @((Import-PowerShellDataFile -LiteralPath $AcceptedFile).Accepted | Where-Object { $_ }) }
    }
    catch { Write-Warning "Akzeptanzliste nicht lesbar: $($_.Exception.Message)" }
}
# Sysinternals (Autoruns, Sigcheck): Bibliotheken nur laden, nichts ausführen; die Werkzeuge starten ausschließlich über Invoke-MorpheusSysWerkzeug
$script:SysLib = $false
$script:SysDataRoot = $null
$sysInstallPfad = Join-Path $PSScriptRoot 'gui\lib\Install.ps1'
$sysAuswertungPfad = Join-Path $PSScriptRoot 'gui\lib\SysinternalsAuswertung.ps1'
$sysLibPfad = Join-Path $PSScriptRoot 'gui\lib\Sysinternals.ps1'
if ((Test-Path -LiteralPath $sysInstallPfad) -and (Test-Path -LiteralPath $sysAuswertungPfad) -and (Test-Path -LiteralPath $sysLibPfad)) {
    try {
        . $sysInstallPfad
        . $sysAuswertungPfad
        . $sysLibPfad
        $sysFunktionen = @('Invoke-MorpheusSysWerkzeug', 'Get-MorpheusSysStand', 'ConvertFrom-MorpheusAutorunsCsv', 'ConvertFrom-MorpheusSigcheckCsv', 'Get-MorpheusAutorunsSignaturBefund', 'Get-MorpheusAutorunsPfadBefund', 'Get-MorpheusAutorunsTabelle', 'Get-MorpheusSystemdateienBefund', 'Get-MorpheusSigcheckTabelle', 'Test-MorpheusSysKopf', 'Get-MorpheusSysZustimmung')
        $script:SysLib = (@($sysFunktionen | Where-Object { Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue }).Count -eq $sysFunktionen.Count)
    }
    catch { $script:SysLib = $false }
}
# Datenordner (enthält tools\): normal der Elternordner von $OutputDir (GUI-Scan). Fehlt dort tools\ (Scan aus der Befehlszeile ohne GUI),
# aber der Standard-Datenordner (C:\ProgramData\Morpheus) hat einen, wird dieser verwendet.
try {
    $sysAusgabe = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
    $script:SysDataRoot = [IO.Path]::GetFullPath((Split-Path -Parent $sysAusgabe))
    if (-not (Test-Path -LiteralPath (Join-Path $script:SysDataRoot 'tools') -PathType Container) -and (Get-Command MorpheusDefaultDataDir -CommandType Function -ErrorAction SilentlyContinue)) {
        $sysStandard = MorpheusDefaultDataDir
        if (Test-Path -LiteralPath (Join-Path $sysStandard 'tools') -PathType Container) { $script:SysDataRoot = $sysStandard }
    }
}
catch { $script:SysDataRoot = Split-Path -Parent $OutputDir }
# Sichere Pfade (2.3.3): winget-Auflösung und TEMP im gesicherten Datenordner. Add-Type kompiliert in %TEMP% und lädt die DLL
# danach, secedit schreibt die Richtlinie dorthin; im Temp-Ordner des Benutzers könnte ein Benutzerprogramm beides austauschen.
$script:PfadLib = $false
$pfadLibPfad = Join-Path $PSScriptRoot 'gui\lib\Systempfade.ps1'
if (Test-Path -LiteralPath $pfadLibPfad) {
    try {
        . $pfadLibPfad
        $script:PfadLib = $true
        if ($script:IsAdmin) {
            $tempNeu = $null
            if ($script:SysDataRoot) { $tempNeu = Set-MorpheusTempPfad -DataRoot $script:SysDataRoot }
            if (-not $tempNeu) { Write-Warning 'Der Datenordner ist nicht gesichert: Temporäre Dateien (secedit, Add-Type) bleiben im Temp-Ordner des Benutzers. Sicherer ist der Start über die installierte Fassung.' }
        }
    }
    catch { $script:PfadLib = $false }
}
if ($script:PfadLib) {
    try { $script:BenutzerTemp = Get-MorpheusBenutzerTemp } catch { }
    try { $script:BenutzerPath = Get-MorpheusBenutzerPath } catch { }
}
else {
    # Ohne Bibliothek wie vor 2.3.3 (dann gilt ohnehin noch der Temp-Ordner des Benutzers)
    function Expand-MorpheusUmgebung { param([AllowNull()][string]$Text) if (-not $Text) { return $Text }; [Environment]::ExpandEnvironmentVariables($Text) }
}
$script:SysAufgaben = $null       # Aufgabenpfad (klein) -> läuft mit erhöhten Rechten
$script:Autoruns = $null          # Ergebnis des einen Autoruns-Laufs (auch im Fehlerfall)
$script:AutorunsEintraege = $null
$script:SigcheckCache = $null

# Gemeinsame Statuslogik der Sysinternals-Prüfungen. Liefert das Ergebnis von Invoke-MorpheusSysWerkzeug,
# wenn es verwertbar ist; sonst wird der passende Befund geschrieben und $null geliefert.
function Resolve-SysErgebnis {
    param($Ergebnis, [string]$Titel, [string]$Art)
    if (-not $Ergebnis) { Add-Finding SKIP 'Fehler: keine Antwort vom Werkzeug'; return $null }
    if ($Ergebnis.nichtEingerichtet) { Add-Finding SKIP 'Sysinternals nicht eingerichtet: in Morpheus unter Werkzeuge herunterladen'; return $null }
    if ($Ergebnis.nichtVertrauenswuerdig) { Add-Finding WARN ("$Titel nicht ausgeführt: " + $Ergebnis.fehler) 'Unter Werkzeuge neu herunterladen; bleibt die Meldung, die Datei nicht verwenden.'; return $null }
    if (-not $Ergebnis.ok) { Add-Finding SKIP ('Fehler: ' + $Ergebnis.fehler); return $null }
    if ($Art -and -not (Test-MorpheusSysKopf -Text $Ergebnis.text -Art $Art)) { Add-Finding SKIP "Fehler: Die Ausgabe von $Titel ist nicht lesbar (keine CSV-Kopfzeile)."; return $null }
    $Ergebnis
}

# Aufgaben mit erhöhten Rechten (SYSTEM, Dienstkonten oder RunLevel Highest), einmal gebaut: Schlüssel = Pfad klein mit führendem \
function Get-SysAufgaben {
    if ($null -ne $script:SysAufgaben) { return $script:SysAufgaben }
    $tabelle = @{}
    try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            $uid = [string]$t.Principal.UserId
            $hoch = ($uid -match '(^|\\)(SYSTEM|LOCAL SERVICE|LOKALER DIENST|NETWORK SERVICE|NETZWERKDIENST)$') -or ($uid -match '^S-1-5-(18|19|20)$') -or ([string]$t.Principal.RunLevel -eq 'Highest')
            $tabelle[(([string]$t.TaskPath + [string]$t.TaskName).ToLowerInvariant())] = [bool]$hoch
        }
    }
    catch { $tabelle = @{} }
    $script:SysAufgaben = $tabelle
    $tabelle
}

function Test-SysVorabAus {
    if ($SkipSysinternals) { Add-Finding SKIP 'Übersprungen (-SkipSysinternals)'; return $true }
    if (-not $script:SysLib) { Add-Finding SKIP 'gui\lib\Sysinternals.ps1 fehlt'; return $true }
    $false
}

# Fortschrittszeile nur, wenn das Werkzeug wirklich läuft (eingerichtet und Zustimmung vorhanden)
function Write-SysFortschritt {
    param([string]$Text, [string]$Exe)
    $bereit = $true
    try {
        # billig: nur Dateiexistenz und Zustimmung, kein Hashen/Signaturprüfen
        if (-not (Test-Path -LiteralPath (Join-Path $script:SysDataRoot "tools\$Exe") -PathType Leaf)) { $bereit = $false }
        elseif (-not (Get-MorpheusSysZustimmung -DataRoot $script:SysDataRoot).akzeptiert) { $bereit = $false }
    }
    catch { }
    if ($bereit) { Write-Host $Text -ForegroundColor DarkGray }
}

function Get-SysAutoruns {
    if (Test-SysVorabAus) { return $null }
    if (-not $script:Autoruns) {
        Write-SysFortschritt '    Autoruns läuft, das dauert 1–3 Minuten …' 'autorunsc64.exe'
        try { $script:Autoruns = Invoke-MorpheusSysWerkzeug -DataRoot $script:SysDataRoot -Auftrag autostarts }
        catch { $script:Autoruns = [pscustomobject]@{ ok = $false; fehler = $_.Exception.Message; nichtVertrauenswuerdig = $false; nichtEingerichtet = $false; text = '' } }
    }
    $r = Resolve-SysErgebnis $script:Autoruns 'Autoruns' 'autoruns'
    if (-not $r) { return $null }
    if ($null -eq $script:AutorunsEintraege) { $script:AutorunsEintraege = @(ConvertFrom-MorpheusAutorunsCsv -Text $r.text) }
    , $script:AutorunsEintraege
}

# Bewertet die unsignierten Systemdateien: SHA256 je Datei, Abgleich mit den Datei-Regeln der Akzeptanzliste.
# -Hash ist überschreibbar (Test); Fehler beim Hashen → '' (dann nie akzeptiert).
function Get-SysSigcheckBewertung {
    param($System32, $Treiber, $Regeln = @(), [scriptblock]$Hash)
    if ($null -eq $Hash) { $Hash = { param($Pfad) (Get-FileHash -LiteralPath $Pfad -Algorithm SHA256 -ErrorAction Stop).Hash } }
    $kannFinden = [bool](Get-Command Find-MorpheusAkzeptanzDatei -CommandType Function -ErrorAction SilentlyContinue)
    $regeln = @($Regeln | Where-Object { $_ })
    $zeilen = New-Object System.Collections.Generic.List[object]
    $akzeptiert = @{}
    foreach ($z in @(Get-MorpheusSigcheckTabelle -System32 $System32 -Treiber $Treiber)) {
        $h = ''
        try { $h = ([string](& $Hash $z.Pfad)).ToLowerInvariant() } catch { $h = '' }
        if ($h -notmatch '^[0-9a-f]{64}$') { $h = '' }
        $grund = ''
        if ($kannFinden -and $h -and $regeln.Count) {
            $r = Find-MorpheusAkzeptanzDatei -Regeln $regeln -Pfad $z.Pfad -Sha256 $h
            if ($r) { $grund = [string]$r.reason; if (-not $grund) { $grund = [string]$r.Reason }; if (-not $grund) { $grund = 'akzeptiert' }; $akzeptiert[([string]$z.Pfad).ToLowerInvariant()] = $true }
        }
        $o = [ordered]@{}
        foreach ($pr in $z.PSObject.Properties) { $o[$pr.Name] = $pr.Value }
        $o['Sha256'] = $h
        $o['Akzeptiert'] = $grund
        $zeilen.Add([pscustomobject]$o)
    }
    $offen32 = @($System32 | Where-Object { $_ -and -not $akzeptiert.ContainsKey(([string]$_.Pfad).ToLowerInvariant()) })
    $offenTr = @($Treiber | Where-Object { $_ -and -not $akzeptiert.ContainsKey(([string]$_.Pfad).ToLowerInvariant()) })
    $k = $akzeptiert.Count
    $b = Get-MorpheusSystemdateienBefund -System32 $offen32 -Treiber $offenTr
    $status = [string]$b.status; $wert = [string]$b.wert; $empf = [string]$b.empfehlung; $note = ''
    if ($k -gt 0 -and $status -eq 'OK') {
        $voll = Get-MorpheusSystemdateienBefund -System32 $System32 -Treiber $Treiber
        $status = 'ACK'; $wert = [string]$voll.wert; $empf = [string]$voll.empfehlung
        $note = if ($k -eq 1) { '1 Datei akzeptiert (je SHA256)' } else { "$k Dateien akzeptiert (je SHA256)" }
    }
    elseif ($k -gt 0) { $wert += "; $k akzeptiert" }
    [pscustomobject]@{ Tabelle = $zeilen.ToArray(); Status = $status; Wert = $wert; Empfehlung = $empf; Note = $note; Akzeptiert = $k }
}

function Get-SysSigcheck {
    if (Test-SysVorabAus) { return $null }
    if (-not $script:SigcheckCache) {
        Write-SysFortschritt '    Sigcheck läuft, das dauert 1–3 Minuten …' 'sigcheck64.exe'
        $cache = [ordered]@{}
        foreach ($auftrag in 'system32', 'treiber') {
            try { $cache[$auftrag] = Invoke-MorpheusSysWerkzeug -DataRoot $script:SysDataRoot -Auftrag $auftrag }
            catch { $cache[$auftrag] = [pscustomobject]@{ ok = $false; fehler = $_.Exception.Message; nichtVertrauenswuerdig = $false; nichtEingerichtet = $false; text = '' } }
            if (-not $cache[$auftrag].ok) { break }
        }
        $script:SigcheckCache = $cache
    }
    $teile = [ordered]@{}
    foreach ($auftrag in 'system32', 'treiber') {
        $r = Resolve-SysErgebnis $script:SigcheckCache[$auftrag] 'Sigcheck' 'sigcheck'
        if (-not $r) { return $null }
        $teile[$auftrag] = @(ConvertFrom-MorpheusSigcheckCsv -Text $r.text)
    }
    $teile
}
# Selbst eingetragene Spiele-Ordner (nur gelesen; Read-MorpheusSpielordner lässt nur lokale Pfade durch)
$script:SpielOrdner = @()
if ($script:SpeicherLib) { try { $script:SpielOrdner = @(Read-MorpheusSpielordner -Datei $SpielOrdnerFile) } catch { } }

# Bekannt harmlose Einträge in Ereignisprotokollen: Muster -> kurze Begründung für den Bericht.
$script:KnownHarmless = @{
    # Dienstfehler (Name oder Anzeigename des Dienstes)
    ServiceErrors   = [ordered]@{
        '^dam$'                    = 'Desktop Activity Moderator: nur für Laptops mit Modern Standby, auf Desktops normal'
        '^Steam Client Service$'   = 'startet nur bei Bedarf und meldet sonst einen Fehler'
        '^(edgeupdate|MicrosoftEdgeElevationService|GoogleUpdater)' = 'Update-Dienst, startet nur bei Bedarf'
        '^(gupdate|gupdatem)$'     = 'Update-Dienst, startet nur bei Bedarf'
    }
    # Code Integrity: DLLs von Overlays/Aufnahme-Tools, die Windows aus geschützten Systemprozessen fernhält
    CodeIntegrity   = 'nvspcap64\.dll|NvCamera|nvd3dumx|RTSSHooks|GameOverlayRenderer|DiscordHook|graphics-hook|obs-vulkan|igdumd|amdxx|atiu'
    # PowerShell-Skriptblöcke: Aufruf von pc-check selbst und automatisch erzeugte Modul-Exporte
    # pc-check selbst (auch per Umgebungsvariable gestartet) und der PowerShell-Wrapper von Claude Code
    PowerShell      = 'pc-check\.ps1|\$env:PCCHECK\b|^\s*-Function .* -Alias|^\s*function Write-Result\(\$Json\) \{ \[System\.Convert\]::ToBase64String|^\s*try \{ \$PSDefaultParameterValues\[''Out-File:Encoding''\] = ''utf8'' \} catch \{\}'
}
# Browser-Berechtigung für alle Webseiten (nicht: *://*.reddit.com/*)
$script:AllSitesPattern = '^<all_urls>$|^(\*|https?|wss?)://\*/'

$displayCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class PcCheckDisplay
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplaySettings(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);

    public class Mode
    {
        public string Device;
        public string Adapter;
        public string Monitor;
        public int Width;
        public int Height;
        public int Hz;
        public int MaxHzAtResolution;
        public int MaxHz;
    }

    public static List<Mode> Get()
    {
        var result = new List<Mode>();
        for (uint i = 0; i < 16; i++)
        {
            var dd = new DISPLAY_DEVICE();
            dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
            if ((dd.StateFlags & 1) == 0) continue;
            var cur = new DEVMODE();
            cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(dd.DeviceName, -1, ref cur)) continue;
            var mon = new DISPLAY_DEVICE();
            mon.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            string monName = EnumDisplayDevices(dd.DeviceName, 0, ref mon, 0) ? mon.DeviceString : "";
            var m = new Mode { Device = dd.DeviceName, Adapter = dd.DeviceString, Monitor = monName, Width = cur.dmPelsWidth, Height = cur.dmPelsHeight, Hz = cur.dmDisplayFrequency };
            var mode = new DEVMODE();
            mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            for (int n = 0; EnumDisplaySettings(dd.DeviceName, n, ref mode); n++)
            {
                if (mode.dmDisplayFrequency > m.MaxHz) m.MaxHz = mode.dmDisplayFrequency;
                if (mode.dmPelsWidth == cur.dmPelsWidth && mode.dmPelsHeight == cur.dmPelsHeight && mode.dmDisplayFrequency > m.MaxHzAtResolution) m.MaxHzAtResolution = mode.dmDisplayFrequency;
            }
            result.Add(m);
        }
        return result;
    }
}
'@

#endregion

Write-Host "$ProductName - $ProductTagline $ScriptVersion  |  Admin: $($script:IsAdmin)  |  Ereignisse: letzte $EventDays Tage" -ForegroundColor Green
if (-not $script:IsAdmin) { Write-Warning 'Ohne Adminrechte fehlen einige Prüfungen. Für den vollen Umfang als Administrator starten.' }
$script:PackagedFrom = Get-PackagedAncestor
if ($script:PackagedFrom) { Write-Warning "Gestartet aus der Store-App $($script:PackagedFrom): Ergebnisse unter HKCU können von der echten Registry abweichen. Für verlässliche Ergebnisse aus einer normalen Konsole starten." }

$script:OS = Get-CimInstance Win32_OperatingSystem
$script:CS = Get-CimInstance Win32_ComputerSystem
$script:CV = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$script:Services = @(Get-CimInstance Win32_Service)
$script:Profile = $Profil
$script:ProfileAuto = $false
if ($Profil -eq 'Auto') {
    $script:ProfileAuto = $true
    $hasBattery = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    $hasDgpu = [bool](Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA|AMD|Radeon|Arc' })
    $script:Profile = if ($hasBattery) { 'Laptop' } elseif ($hasDgpu) { 'Gaming' } else { 'Office' }
}
Write-Host "Profil: $($script:Profile)$(if ($script:ProfileAuto) { ' (automatisch erkannt, ändern mit -Profil)' })" -ForegroundColor Green
$script:Features = @()
$script:DeviceGuard = $null
$script:SecureBoot = $false
$script:AutostartRows = @()
$script:ThirdPartyServices = @()
$script:WingetUpdates = @()

#region Sicherheit: System & Updates

Start-Section 'Sicherheit' 'System & Updates'

Invoke-Check 'Ausführungsumgebung' {
    if ($script:PackagedFrom) { Add-Finding WARN "Gestartet aus der Store-App $($script:PackagedFrom)" 'Store-Apps virtualisieren Teile der Registry (HKCU) für alle Prozesse, die sie starten, auch mit Adminrechten. Ergebnisse und Änderungen unter HKCU können daher abweichen. Für verlässliche Ergebnisse aus einer normalen Konsole (Git Bash, Windows Terminal) starten.' }
    else { Add-Finding OK 'Normale Konsole, kein Store-App-Container' }
}

Invoke-Check 'Windows-Version' {
    $cv = $script:CV
    $build = '{0}.{1}' -f $cv.CurrentBuildNumber, $cv.UBR
    $ver = [string]$cv.DisplayVersion
    $uptime = (Get-Date) - $script:OS.LastBootUpTime
    Add-Table 'System' @([pscustomobject][ordered]@{
            Computer     = $env:COMPUTERNAME
            Edition      = $script:OS.Caption
            Version      = $ver
            Build        = $build
            Installiert  = Format-Date $script:OS.InstallDate
            LetzterStart = Format-Date $script:OS.LastBootUpTime
            Laufzeit     = '{0} Tage {1} Std.' -f $uptime.Days, $uptime.Hours
            Hersteller   = $script:CS.Manufacturer
            Modell       = $script:CS.Model
        })
    # Supportende Home/Pro
    $endOfService = @{ '22H2' = '2024-10-08'; '23H2' = '2025-11-11'; '24H2' = '2026-10-13'; '25H2' = '2027-10-12' }
    if ($endOfService.ContainsKey($ver)) {
        $end = [datetime]$endOfService[$ver]
        $days = ($end - (Get-Date)).Days
        $value = "Windows 11 $ver, Build $build, Support bis $($end.ToString('yyyy-MM-dd'))"
        if ($days -lt 0) { Add-Finding CRIT $value 'Diese Version bekommt keine Sicherheitsupdates mehr: Funktionsupdate auf die aktuelle Windows-11-Version installieren.' }
        elseif ($days -lt 90) { Add-Finding WARN $value 'Support endet bald: Funktionsupdate einplanen.' }
        else { Add-Finding OK $value }
    }
    else { Add-Finding INFO "Windows $ver, Build $build" 'Supportende manuell prüfen.' }
}

Invoke-Check 'Windows-Aktivierung' {
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" | Select-Object -First 1
    if (-not $lic) { Add-Finding WARN 'Kein Produktschlüssel gefunden' 'Aktivierung unter Einstellungen > System > Aktivierung prüfen.'; return }
    $states = @{ 0 = 'Nicht lizenziert'; 1 = 'Aktiviert'; 2 = 'Kulanzzeit'; 3 = 'Kulanzzeit (Hardwareänderung)'; 4 = 'Nicht original'; 5 = 'Benachrichtigungsmodus'; 6 = 'Verlängerte Kulanzzeit' }
    $state = $states[[int]$lic.LicenseStatus]
    if ($lic.LicenseStatus -eq 1) { Add-Finding OK "$state ($($lic.Name))" }
    else { Add-Finding WARN "$state ($($lic.Name))" 'Windows aktivieren; nicht aktivierte Systeme sind oft mit fragwürdigen Aktivierungstools behandelt.' }
}

Invoke-Check 'Windows Update: Verlauf' {
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $total = $searcher.GetTotalHistoryCount()
    $history = @()
    # Defender-Signaturen kommen mehrmals täglich und verdrängen sonst alles andere aus dem Verlauf.
    if ($total -gt 0) { $history = @($searcher.QueryHistory(0, $total) | Where-Object { $_.Title -and $_.Title -notmatch 'KB2267602|Security Intelligence|Sicherheitsinformationen' }) }
    $results = @{ 0 = 'Nicht gestartet'; 1 = 'Läuft'; 2 = 'Erfolgreich'; 3 = 'Mit Fehlern'; 4 = 'Fehlgeschlagen'; 5 = 'Abgebrochen' }
    $rows = foreach ($h in ($history | Select-Object -First 40)) {
        [pscustomobject][ordered]@{ Datum = Format-Date $h.Date.ToLocalTime(); Ergebnis = $results[[int]$h.ResultCode]; Titel = $h.Title }
    }
    Add-Table 'Windows Update: letzte Installationen (ohne Defender-Signaturen)' $rows
    # Seit 2025 heißen die Monatsupdates "JJJJ-MM Security Update (KB…)", vorher "Kumulatives Update".
    $cu = $history | Where-Object {
        $_.ResultCode -eq 2 -and $_.Title -notmatch '\.NET' -and
        $_.Title -match '^\d{4}-\d{2} (Security Update|Sicherheitsupdate|Cumulative Update|Kumulatives Update)|Kumulatives Update für Windows|Cumulative Update for Windows'
    } | Sort-Object Date -Descending | Select-Object -First 1
    if ($cu) {
        $age = ((Get-Date).ToUniversalTime() - $cu.Date).Days
        $value = "Letztes kumulatives Update vor $age Tagen: $($cu.Title)"
        if ($age -gt 60) { Add-Finding CRIT $value 'Windows Update ausführen: seit über zwei Monaten fehlen Sicherheitsupdates.' }
        elseif ($age -gt 40) { Add-Finding WARN $value 'Windows Update ausführen, der letzte Patchday wurde nicht installiert.' }
        else { Add-Finding OK $value }
    }
    else { Add-Finding WARN 'Kein erfolgreiches kumulatives Update im Verlauf gefunden' 'Windows Update manuell prüfen.' }
    $failed = @($history | Where-Object { $_.ResultCode -eq 4 -and $_.Date -gt (Get-Date).AddDays(-30) })
    if ($failed.Count) {
        Add-Finding WARN ('{0} fehlgeschlagene Installationen in 30 Tagen: {1}' -f $failed.Count, (($failed | Select-Object -ExpandProperty Title -Unique | Select-Object -First 3) -join '; ')) `
            'Fehlgeschlagene Updates erneut versuchen, sonst Problembehandlung für Windows Update.' -Check 'Windows Update: Fehler'
    }
}

if ($SkipUpdateSearch) {
    $script:CheckName = 'Windows Update: ausstehend'
    Add-Finding SKIP 'Übersprungen (-SkipUpdateSearch)'
}
else {
    Invoke-Check 'Windows Update: ausstehend' {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $res = $searcher.Search('IsInstalled=0 and IsHidden=0')
        $ups = @(for ($i = 0; $i -lt $res.Updates.Count; $i++) { $res.Updates.Item($i) })
        $rows = foreach ($u in $ups) {
            [pscustomobject][ordered]@{
                Titel          = $u.Title
                Schweregrad    = [string]$u.MsrcSeverity
                Typ            = $(if ($u.Type -eq 2) { 'Treiber' } else { 'Software' })
                Heruntergladen = [bool]$u.IsDownloaded
            }
        }
        Add-Table 'Windows Update: ausstehend' $rows
        # Defender-Signaturen holt Defender mehrmals täglich selbst; ein gerade fälliges ist kein Handlungsbedarf.
        $sigPattern = 'KB2267602|Security Intelligence|Sicherheitsinformationen'
        $sw = @($ups | Where-Object { $_.Type -ne 2 -and $_.Title -notmatch $sigPattern })
        $other = @($ups | Where-Object { $_.Type -eq 2 -or $_.Title -match $sigPattern } | ForEach-Object { $(if ($_.Type -eq 2) { 'Treiber' } else { 'Defender-Signaturen' }) } | Select-Object -Unique)
        if (-not $ups.Count) { Add-Finding OK 'Keine ausstehenden Updates' }
        elseif ($sw | Where-Object { $_.MsrcSeverity -eq 'Critical' }) { Add-Finding CRIT "$($sw.Count) ausstehende Updates, darunter kritische" 'Windows Update jetzt ausführen.' }
        elseif ($sw.Count) { Add-Finding WARN "$($sw.Count) ausstehende Updates" 'Windows Update ausführen.' }
        else { Add-Finding INFO "Nur optional bzw. automatisch: $($other -join ', ')" 'Defender lädt Signaturen selbst; optionale Treiber nur bei Problemen installieren, Grafiktreiber besser direkt vom Hersteller.' }
    }
}

Invoke-Check 'Neustart ausstehend' {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'Komponentenwartung' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
    if ($reasons) { Add-Finding WARN ('Neustart erforderlich: ' + ($reasons -join ', ')) 'PC neu starten, damit installierte Updates wirksam werden.' }
    else { Add-Finding OK 'Kein Neustart ausstehend' }
}

Invoke-Check 'Windows Update: Einstellungen' {
    $blocked = @(); $notes = @()
    if ((Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate') -eq 1) { $blocked += 'Automatische Updates per Richtlinie abgeschaltet' }
    $wu = $script:Services | Where-Object Name -EQ 'wuauserv'
    if ($wu.StartMode -eq 'Disabled') { $blocked += 'Dienst wuauserv deaktiviert' }
    $wuPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    foreach ($n in 'DeferFeatureUpdatesPeriodInDays', 'DeferQualityUpdatesPeriodInDays', 'TargetReleaseVersionInfo', 'ProductVersion') {
        $v = Get-RegValue $wuPol $n
        if ($null -ne $v) { $notes += "$n = $v" }
    }
    $paused = $null
    $pause = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'PauseUpdatesExpiryTime'
    if ($pause) {
        try {
            $p = [datetime]::Parse($pause, [Globalization.CultureInfo]::InvariantCulture)
            if ($p -gt (Get-Date)) { $paused = $p }
        }
        catch {}
    }
    if ($blocked) { Add-Finding CRIT ($blocked -join '; ') 'Automatische Updates wieder zulassen (Tweak-Tools setzen solche Sperren gern).' }
    elseif ($paused) { Add-Finding WARN "Updates pausiert bis $($paused.ToString('yyyy-MM-dd'))" 'Pause beenden, sobald möglich.' }
    elseif ($notes) { Add-Finding INFO ('Richtlinien: ' + ($notes -join '; ')) }
    else { Add-Finding OK 'Automatische Updates aktiv, nicht pausiert' }
}

#endregion

#region Sicherheit: Virenschutz

Start-Section 'Sicherheit' 'Virenschutz'

Invoke-Check 'Registrierte Schutzprogramme' {
    $av = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct)
    $rows = foreach ($a in $av) {
        $hex = '{0:X6}' -f [int]$a.productState
        [pscustomobject][ordered]@{
            Produkt    = $a.displayName
            Aktiv      = ($hex.Substring(2, 2) -in '10', '11')
            Signaturen = $(if ($hex.Substring(4, 2) -eq '00') { 'aktuell' } else { 'veraltet' })
            Pfad       = $a.pathToSignedReportingExe
        }
    }
    Add-Table 'Virenschutzprogramme (Sicherheitscenter)' $rows
    $active = @($rows | Where-Object Aktiv)
    if (-not $active) { Add-Finding CRIT 'Kein aktiver Virenschutz registriert' 'Microsoft Defender einschalten.' }
    elseif ($active.Count -gt 1) { Add-Finding WARN ('Mehrere aktive Virenscanner: ' + (($active | ForEach-Object Produkt) -join ', ')) 'Nur einen Echtzeit-Scanner betreiben; zwei bremsen sich gegenseitig und das System.' }
    else { Add-Finding OK "Aktiv: $($active[0].Produkt), Signaturen $($active[0].Signaturen)" }
}

Invoke-Check 'Microsoft Defender: Status' {
    $s = Get-MpComputerStatus
    Add-Table 'Microsoft Defender' @([pscustomobject][ordered]@{
            Modus                 = [string]$s.AMRunningMode
            Echtzeitschutz        = $s.RealTimeProtectionEnabled
            Verhaltensueberwachung = $s.BehaviorMonitorEnabled
            DownloadPruefung      = $s.IoavProtectionEnabled
            Netzwerkinspektion    = $s.NISEnabled
            Manipulationsschutz   = $s.IsTamperProtected
            Signaturen            = Format-Date $s.AntivirusSignatureLastUpdated
            SchnellscanAlterTage  = $s.QuickScanAge
            VollscanAlterTage     = $s.FullScanAge
            Engine                = $s.AMEngineVersion
            Plattform             = $s.AMProductVersion
        })
    if ($s.AMRunningMode -and $s.AMRunningMode -ne 'Normal') {
        Add-Finding INFO "Defender im Modus '$($s.AMRunningMode)'" 'Erwartet, wenn ein anderer Virenscanner aktiv ist.'
        return
    }
    $off = @()
    if (-not $s.AntivirusEnabled) { $off += 'Virenschutz' }
    if (-not $s.RealTimeProtectionEnabled) { $off += 'Echtzeitschutz' }
    if (-not $s.BehaviorMonitorEnabled) { $off += 'Verhaltensüberwachung' }
    if (-not $s.IoavProtectionEnabled) { $off += 'Download-Prüfung' }
    if (-not $s.OnAccessProtectionEnabled) { $off += 'Zugriffsschutz' }
    if ($off) { Add-Finding CRIT ('Abgeschaltet: ' + ($off -join ', ')) 'Schutzkomponenten in Windows-Sicherheit wieder einschalten.' }
    else { Add-Finding OK 'Echtzeit-, Verhaltens- und Download-Schutz aktiv' }

    if ($s.IsTamperProtected) { Add-Finding OK 'An' -Check 'Defender: Manipulationsschutz' }
    else { Add-Finding WARN 'Aus' 'Windows-Sicherheit > Viren- & Bedrohungsschutz > Einstellungen verwalten > Manipulationsschutz einschalten.' -Check 'Defender: Manipulationsschutz' }

    $age = [int]$s.AntivirusSignatureAge
    $value = "Stand $(Format-Date $s.AntivirusSignatureLastUpdated) ($age Tage)"
    if ($age -gt 7) { Add-Finding CRIT $value 'Signaturen veraltet: Windows Update bzw. Defender-Update prüfen.' -Check 'Defender: Signaturen' }
    elseif ($age -gt 1) { Add-Finding WARN $value 'Signaturen sollten täglich aktualisiert werden.' -Check 'Defender: Signaturen' }
    else { Add-Finding OK $value -Check 'Defender: Signaturen' }

    if ([int]$s.QuickScanAge -gt 14) { Add-Finding INFO "Letzter Schnellscan vor $($s.QuickScanAge) Tagen" 'Defender scannt normalerweise in der Wartungszeit; läuft der PC dann nie, gelegentlich manuell scannen.' -Check 'Defender: Scans' }
}

Invoke-Check 'Microsoft Defender: Einstellungen' {
    $p = Get-MpPreference
    $notes = @(); $warn = @()
    switch ([int]$p.PUAProtection) {
        1 { }
        2 { $warn += 'PUA-Schutz nur im Überwachungsmodus' }
        default { $warn += 'Blockieren potenziell unerwünschter Apps (PUA) aus' }
    }
    if ([int]$p.MAPSReporting -eq 0) { $warn += 'Cloudbasierter Schutz aus' }
    if ([int]$p.SubmitSamplesConsent -eq 2) { $notes += 'Automatische Beispielübermittlung aus' }
    if ([int]$p.EnableNetworkProtection -ne 1) { $notes += 'Netzwerkschutz aus' }
    if ([int]$p.EnableControlledFolderAccess -ne 1) { $notes += 'Überwachter Ordnerzugriff (Ransomware-Schutz) aus' }
    if ($warn) { Add-Finding WARN (($warn + $notes) -join '; ') 'Windows-Sicherheit > App- & Browsersteuerung > Zuverlässigkeitsbasierter Schutz: PUA blockieren einschalten; cloudbasierten Schutz aktivieren.' }
    elseif ($notes) { Add-Finding INFO ($notes -join '; ') 'Netzwerkschutz blockiert bekannte Schad-Domains in allen Programmen (Set-MpPreference -EnableNetworkProtection Enabled). Überwachter Ordnerzugriff schützt vor Ransomware, meldet aber bei Spielen/Tools gelegentlich Fehlalarme.' }
    else { Add-Finding OK 'PUA-Schutz, Cloud-Schutz, Netzwerkschutz und Ordnerschutz aktiv' }

    # Regeln zur Verringerung der Angriffsfläche (ASR)
    $asrNames = @{
        '56a863a9-875e-4185-98a7-b882c64b5ce5' = 'Missbrauch anfälliger signierter Treiber blockieren'
        '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2' = 'Diebstahl von Anmeldedaten aus LSASS blockieren'
        'd4f940ab-401b-4efc-aadc-ad5f3c50688a' = 'Office: untergeordnete Prozesse blockieren'
        '3b576869-a4ec-4529-8536-b80a7769e899' = 'Office: ausführbare Inhalte erstellen blockieren'
        '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84' = 'Office: Code-Injektion blockieren'
        '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b' = 'Office-Makros: Win32-API-Aufrufe blockieren'
        '26190899-1602-49e8-8b27-eb1d0a1ce869' = 'Office-Kommunikations-Apps: untergeordnete Prozesse blockieren'
        '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c' = 'Adobe Reader: untergeordnete Prozesse blockieren'
        'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550' = 'Ausführbare Inhalte aus E-Mails blockieren'
        '01443614-cd74-433a-b99e-2ecdc07bfc25' = 'Unbekannte ausführbare Dateien blockieren (Verbreitung/Alter)'
        '5beb7efe-fd9a-4556-801d-275e5ffc04cc' = 'Verschleierte Skripte blockieren'
        'd3e037e1-3eb8-44c8-a917-57927947596d' = 'JS/VBS starten heruntergeladene Programme: blockieren'
        'e6db77e5-3df2-4cf1-b95a-636979351e5b' = 'Persistenz über WMI-Ereignisse blockieren'
        'd1e49aac-8f56-4280-b9ba-993a6d77406c' = 'Prozesse aus PsExec/WMI blockieren'
        'b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4' = 'Unsignierte Prozesse von USB blockieren'
        'c1db55ab-c21a-4637-bb3f-a12568109d35' = 'Erweiterter Ransomware-Schutz'
        '33ddedf1-c6e0-47cb-833e-de6133960387' = 'Neustart in abgesicherten Modus blockieren'
        'c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb' = 'Kopierte/getarnte Systemtools blockieren'
        'a8f5898e-1dc8-49a9-9878-85004b8a61e6' = 'Webshell-Erstellung auf Servern blockieren'
    }
    $actNames = @{ 0 = 'Aus'; 1 = 'Blockieren'; 2 = 'Überwachen'; 5 = 'Nicht konfiguriert'; 6 = 'Warnen' }
    $ids = @($p.AttackSurfaceReductionRules_Ids | Where-Object { $_ })
    $acts = @($p.AttackSurfaceReductionRules_Actions)
    $asrRows = for ($i = 0; $i -lt $ids.Count; $i++) {
        $name = $asrNames[$ids[$i].ToLower()]
        if (-not $name) { $name = $ids[$i] }
        [pscustomobject][ordered]@{ Regel = $name; Aktion = $actNames[[int]$acts[$i]] }
    }
    Add-Table 'Defender: ASR-Regeln' $asrRows
    $activeAsr = @($asrRows | Where-Object { $_.Aktion -in 'Blockieren', 'Warnen' })
    if ($activeAsr.Count) { Add-Finding OK "$($activeAsr.Count) Regeln aktiv" -Check 'Defender: ASR-Regeln' }
    else {
        Add-Finding INFO 'Keine Regeln zur Verringerung der Angriffsfläche aktiv' `
            'Ohne Nebenwirkungen für Gaming/Entwicklung: "Missbrauch anfälliger signierter Treiber blockieren" und "Diebstahl von Anmeldedaten aus LSASS blockieren" (Add-MpPreference -AttackSurfaceReductionRules_Ids <GUID> -AttackSurfaceReductionRules_Actions Enabled).' `
            -Check 'Defender: ASR-Regeln'
    }

    # Ausnahmen
    $excl = @()
    $excl += @($p.ExclusionPath | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Typ = 'Pfad'; Wert = $_ } })
    $excl += @($p.ExclusionProcess | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Typ = 'Prozess'; Wert = $_ } })
    $excl += @($p.ExclusionExtension | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Typ = 'Endung'; Wert = $_ } })
    if ($excl | Where-Object { $_.Wert -like 'N/A*' }) {
        Add-Finding SKIP 'Ausnahmen nur mit Adminrechten lesbar' -Check 'Defender: Ausnahmen'
    }
    else {
        $exclRows = foreach ($e in $excl) {
            [pscustomobject][ordered]@{ Typ = $e.Typ; Wert = $e.Wert; Risiko = [string](Get-ExclusionRisk -Type $e.Typ -Value $e.Wert) }
        }
        Add-Table 'Defender: Ausnahmen' $exclRows
        $crit = @($exclRows | Where-Object Risiko -EQ 'CRIT')
        $warn = @($exclRows | Where-Object Risiko -EQ 'WARN')
        $rec = 'Ausnahmen so eng wie möglich fassen (einzelne Ordner statt Laufwerke/Benutzerordner, keine Skript-Interpreter). Für Entwicklungsordner besser ein Dev Drive nutzen.'
        if ($crit) { Add-Finding CRIT ('Gefährliche Ausnahmen: ' + (($crit | ForEach-Object { "$($_.Typ) $($_.Wert)" }) -join '; ')) $rec -Check 'Defender: Ausnahmen' }
        elseif ($warn) { Add-Finding WARN ('Riskante Ausnahmen: ' + (($warn | ForEach-Object { "$($_.Typ) $($_.Wert)" }) -join '; ')) $rec -Check 'Defender: Ausnahmen' }
        elseif ($exclRows) { Add-Finding INFO "$(@($exclRows).Count) Ausnahmen, keine auffälligen (Liste im Anhang)" -Check 'Defender: Ausnahmen' }
        else { Add-Finding OK 'Keine Ausnahmen' -Check 'Defender: Ausnahmen' }
    }
}

Invoke-Check 'Microsoft Defender: Funde' {
    $threats = @(Get-MpThreat -ErrorAction SilentlyContinue)
    $names = @{}
    foreach ($t in $threats) { $names[[string]$t.ThreatID] = $t.ThreatName }
    $det = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $script:Since })
    $rows = foreach ($d in $det) {
        [pscustomobject][ordered]@{
            Zeit      = Format-Date $d.InitialDetectionTime
            Bedrohung = $names[[string]$d.ThreatID]
            Prozess   = $d.ProcessName
            Erfolg    = $d.ActionSuccess
            Dateien   = (@($d.Resources) | Select-Object -First 3) -join '; '
        }
    }
    Add-Table 'Defender: Funde im Zeitraum' $rows
    $active = @($threats | Where-Object IsActive)
    if ($active) { Add-Finding CRIT ('Aktive Bedrohung: ' + (($active | ForEach-Object ThreatName) -join ', ')) 'Vollständigen Scan und Microsoft-Defender-Offlinescan ausführen.' }
    elseif ($det) { Add-Finding WARN ("$($det.Count) Funde in $EventDays Tagen: " + ((@($rows | ForEach-Object Bedrohung | Select-Object -Unique)) -join ', ')) 'Herkunft der Funde prüfen (Liste im Anhang).' }
    else { Add-Finding OK "Keine Funde in $EventDays Tagen" }
}

#endregion

#region Sicherheit: Firewall & Netzwerk

Start-Section 'Sicherheit' 'Firewall & Netzwerk'

Invoke-Check 'Firewall-Profile' {
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
    $rows = foreach ($fp in $profiles) {
        [pscustomobject][ordered]@{ Profil = $fp.Name; Aktiv = [string]$fp.Enabled; Eingehend = [string]$fp.DefaultInboundAction; Ausgehend = [string]$fp.DefaultOutboundAction; Benachrichtigen = [string]$fp.NotifyOnListen }
    }
    Add-Table 'Firewall-Profile' $rows
    $thirdParty = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct -ErrorAction SilentlyContinue | ForEach-Object displayName)
    $off = @($rows | Where-Object { $_.Aktiv -ne 'True' } | ForEach-Object Profil)
    $open = @($rows | Where-Object { $_.Eingehend -eq 'Allow' } | ForEach-Object Profil)
    if ($off -and -not $thirdParty) { Add-Finding CRIT ('Firewall aus für: ' + ($off -join ', ')) 'Windows-Firewall für alle Profile einschalten.' }
    elseif ($open) { Add-Finding CRIT ('Eingehend standardmäßig erlaubt: ' + ($open -join ', ')) 'Standardaktion für eingehende Verbindungen auf Blockieren setzen.' }
    elseif ($off) { Add-Finding INFO ("Windows-Firewall aus, stattdessen: " + ($thirdParty -join ', ')) }
    else { Add-Finding OK 'Alle Profile aktiv, eingehend blockiert' }
}

Invoke-Check 'Netzwerkprofile' {
    $rows = foreach ($n in @(Get-NetConnectionProfile)) {
        [pscustomobject][ordered]@{ Netzwerk = $n.Name; Adapter = $n.InterfaceAlias; Kategorie = [string]$n.NetworkCategory; IPv4 = [string]$n.IPv4Connectivity }
    }
    Add-Table 'Netzwerkprofile' $rows
    Add-Finding INFO (($rows | ForEach-Object { "$($_.Adapter): $($_.Kategorie)" }) -join '; ') 'Im eigenen Heimnetz ist "Privat" in Ordnung; in fremden Netzen immer "Öffentlich".'
}

Invoke-Check 'Firewall: eigene Eingangsregeln' {
    $rules = @(Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow)
    $custom = @($rules | Where-Object { -not $_.Group -or $_.Group -notlike '@*' })
    $rows = foreach ($r in $custom) {
        $app = ($r | Get-NetFirewallApplicationFilter).Program
        $pf = $r | Get-NetFirewallPortFilter
        $af = $r | Get-NetFirewallAddressFilter
        [pscustomobject][ordered]@{
            Name      = $r.DisplayName
            Profil    = [string]$r.Profile
            Programm  = $app
            Protokoll = [string]$pf.Protocol
            Ports     = (@($pf.LocalPort) -join ',')
            Remote    = (@($af.RemoteAddress) -join ',')
        }
    }
    Add-Table 'Firewall: eigene Eingangsregeln (Zulassen)' $rows
    $open = @($rows | Where-Object { $_.Profil -match 'Public|Any' -and $_.Remote -eq 'Any' })
    $publicNow = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { [string]$_.NetworkCategory -eq 'Public' }).Count -gt 0
    if ($open) {
        $apps = @($open | ForEach-Object { if ($_.Programm -and $_.Programm -ne 'Any') { [IO.Path]::GetFileName($_.Programm) } else { $_.Name } } | Select-Object -Unique)
        Add-Finding WARN ('{0} von {1} eigenen Regeln ({2} Programme) erlauben eingehende Verbindungen im Profil Öffentlich von überall{3}' -f $open.Count, @($rows).Count, $apps.Count, $(if ($publicNow) { '; dein Netzwerk ist aktuell als Öffentlich eingestuft, die Regeln greifen also' } else { '' })) `
            'Regeln alter/deinstallierter Spiele entfernen und die übrigen auf das Profil Privat beschränken (Liste im Anhang). Spiele brauchen eingehende Verbindungen meist nur für Host/P2P-Funktionen.'
    }
    else { Add-Finding OK "$(@($rows).Count) eigene Regeln, keine im Profil Öffentlich offen" }
}

Invoke-Check 'Offene Netzwerkports' {
    $procNames = @{}
    Get-Process | ForEach-Object { $procNames[$_.Id] = $_.ProcessName }
    $svcByPid = @{}
    $script:Services | Where-Object { $_.ProcessId } | Group-Object ProcessId | ForEach-Object { $svcByPid[[int]$_.Name] = (($_.Group | ForEach-Object Name) -join ',') }
    $isRemote = { param($a) $a -notmatch '^(127\.|::1$)' }
    $tcp = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { & $isRemote $_.LocalAddress })
    $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { (& $isRemote $_.LocalAddress) -and $_.LocalPort -lt 49152 })
    $rows = @()
    foreach ($set in @(@{ Proto = 'TCP'; Items = $tcp }, @{ Proto = 'UDP'; Items = $udp })) {
        $rows += foreach ($g in ($set.Items | Group-Object LocalPort, OwningProcess)) {
            $first = $g.Group[0]
            $procId = [int]$first.OwningProcess
            [pscustomobject][ordered]@{
                Protokoll = $set.Proto
                Port      = [int]$first.LocalPort
                Adressen  = (($g.Group | ForEach-Object LocalAddress | Select-Object -Unique) -join ', ')
                Prozess   = $procNames[$procId]
                Dienste   = $svcByPid[$procId]
                PID       = $procId
            }
        }
    }
    $rows = @($rows | Sort-Object Protokoll, Port)
    Add-Table 'Offene Netzwerkports (nicht nur lokal)' $rows
    $risky = @{ 21 = 'FTP'; 22 = 'SSH'; 23 = 'Telnet'; 80 = 'HTTP'; 443 = 'HTTPS'; 1433 = 'SQL Server'; 3306 = 'MySQL'; 3389 = 'RDP'; 5432 = 'PostgreSQL'; 5900 = 'VNC'; 5985 = 'WinRM'; 5986 = 'WinRM'; 6379 = 'Redis'; 8080 = 'HTTP-Alt'; 9200 = 'Elasticsearch'; 11434 = 'Ollama'; 27017 = 'MongoDB' }
    $winProcs = 'svchost', 'lsass', 'wininit', 'services', 'spoolsv', 'System'
    $tcpRows = @($rows | Where-Object Protokoll -EQ 'TCP')
    $hits = @($tcpRows | Where-Object { $risky.ContainsKey($_.Port) } | ForEach-Object { "$($_.Port)/$($risky[$_.Port]) ($($_.Prozess))" })
    $other = @($tcpRows | Where-Object {
            -not $risky.ContainsKey($_.Port) -and -not ($_.Prozess -in $winProcs -and ($_.Port -in 135, 139, 445, 5040, 7680 -or $_.Port -ge 49664))
        } | ForEach-Object { "$($_.Port) ($($_.Prozess))" })
    if ($hits) { Add-Finding WARN ('Dienste lauschen im Netzwerk: ' + ($hits -join ', ')) 'Prüfen, ob diese Dienste von anderen Geräten erreichbar sein müssen; sonst nur auf 127.0.0.1 binden oder beenden.' }
    elseif ($other) { Add-Finding INFO ('Weitere offene TCP-Ports: ' + ($other -join ', ')) 'Zuordnung im Anhang prüfen; die Windows-Firewall blockiert sie, solange keine Zulassen-Regel existiert.' }
    else { Add-Finding OK 'Nur Windows-Standardports offen' }
}

Invoke-Check 'Router-Portweiterleitungen (UPnP)' {
    $job = Start-Job -ScriptBlock {
        # Modulpfad auch im Kindprozess begrenzen (2.3.3)
        $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
        $nat = New-Object -ComObject HNetCfg.NATUPnP
        $col = $nat.StaticPortMappingCollection
        if ($null -eq $col) { return 'NODATA' }
        foreach ($m in $col) {
            [pscustomobject]@{ Extern = $m.ExternalPort; Protokoll = $m.Protocol; Intern = $m.InternalPort; Ziel = $m.InternalClient; Beschreibung = $m.Description; Aktiv = $m.Enabled }
        }
    }
    if (-not (Wait-Job $job -Timeout 30)) {
        Stop-Job $job; Remove-Job $job -Force
        Add-Finding SKIP 'Keine Antwort vom Router (Zeitüberschreitung)'
        return
    }
    $res = @(Receive-Job $job -ErrorAction SilentlyContinue)
    Remove-Job $job -Force
    $maps = @($res | Where-Object { $_ -isnot [string] } | Select-Object Extern, Protokoll, Intern, Ziel, Beschreibung, Aktiv)
    if (-not $maps) { Add-Finding OK 'Keine UPnP-Portweiterleitungen sichtbar (oder UPnP am Router aus)'; return }
    Add-Table 'Router-Portweiterleitungen (UPnP)' $maps
    $myIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object IPAddress)
    $mine = @($maps | Where-Object { $_.Ziel -in $myIps })
    if ($mine) { Add-Finding WARN ('Aus dem Internet auf diesen PC weitergeleitet: ' + (($mine | ForEach-Object { "$($_.Extern)/$($_.Protokoll) $($_.Beschreibung)" }) -join '; ')) 'Prüfen, ob die Programme noch genutzt werden; UPnP am Router abschalten, wenn kein Spiel/Programm es braucht.' }
    else { Add-Finding INFO "$($maps.Count) Weiterleitungen zu anderen Geräten im Netz" 'UPnP am Router abschalten, wenn nicht benötigt.' }
}

Invoke-Check 'SMB-Konfiguration' {
    $issues = @(); $notes = @()
    $srv = $null; $cli = $null
    try { $srv = Get-SmbServerConfiguration -ErrorAction Stop } catch {}
    try { $cli = Get-SmbClientConfiguration -ErrorAction Stop } catch {}
    if ($srv) {
        if ($srv.EnableSMB1Protocol) { $issues += 'SMBv1-Server aktiv' }
        if (-not $srv.RequireSecuritySignature) { $notes += 'Server erzwingt keine SMB-Signierung' }
    }
    else { $notes += 'Serverkonfiguration nicht lesbar' }
    $mrx = 'HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10'
    if ((Test-Path $mrx) -and (Get-RegValue $mrx 'Start') -ne 4) { $issues += 'SMBv1-Client aktiv' }
    if ($cli) {
        if ($cli.EnableInsecureGuestLogons) { $issues += 'Unsichere Gastanmeldungen erlaubt' }
        if (-not $cli.RequireSecuritySignature) { $notes += 'Client erzwingt keine SMB-Signierung' }
    }
    if ($issues -match 'SMBv1') { Add-Finding CRIT (($issues + $notes) -join '; ') 'SMBv1 deinstallieren (Windows-Features > SMB 1.0/CIFS). Alte NAS ggf. auf SMB2/3 umstellen.' }
    elseif ($issues) { Add-Finding WARN (($issues + $notes) -join '; ') 'Unsichere Gastanmeldungen abschalten; NAS-Freigaben mit Benutzer/Kennwort einbinden.' }
    elseif ($notes) { Add-Finding INFO ($notes -join '; ') }
    else { Add-Finding OK 'Kein SMBv1, Signierung erzwungen, keine Gastanmeldungen' }
}

Invoke-Check 'Freigaben' {
    $shares = @(Get-CimInstance Win32_Share | Where-Object { $_.Name -notmatch '\$$' })
    if (-not $shares) { Add-Finding OK 'Keine Benutzerfreigaben'; return }
    $everyone = ([Security.Principal.SecurityIdentifier]'S-1-1-0').Translate([Security.Principal.NTAccount]).Value
    $rows = foreach ($s in $shares) {
        $access = ''
        try { $access = ((Get-SmbShareAccess -Name $s.Name -ErrorAction Stop | ForEach-Object { "$($_.AccountName): $($_.AccessRight)" }) -join '; ') } catch {}
        [pscustomobject][ordered]@{ Name = $s.Name; Pfad = $s.Path; Zugriff = $access }
    }
    Add-Table 'Freigaben' $rows
    $open = @($rows | Where-Object { $_.Zugriff -match ([regex]::Escape($everyone) + ': (Full|Change)') })
    if ($open) { Add-Finding WARN ('Schreibzugriff für Jeder: ' + (($open | ForEach-Object Name) -join ', ')) 'Freigaberechte auf bestimmte Benutzer beschränken.' }
    else { Add-Finding INFO ('Freigaben: ' + (($rows | ForEach-Object { "$($_.Name) ($($_.Pfad))" }) -join ', ')) 'Nicht mehr benötigte Freigaben entfernen.' }
}

Invoke-Check 'LLMNR / NetBIOS' {
    $llmnr = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast'
    $nbNames = @{ 0 = 'Standard (DHCP)'; 1 = 'an'; 2 = 'aus' }
    $nb = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | ForEach-Object { '{0}: {1}' -f $_.Description, $nbNames[[int]$_.TcpipNetbiosOptions] })
    $value = 'LLMNR ' + $(if ($llmnr -eq 0) { 'aus' } else { 'an (Standard)' }) + '; NetBIOS: ' + ($nb -join '; ')
    if ($llmnr -eq 0) { Add-Finding OK $value }
    else { Add-Finding INFO $value 'Im eigenen Heimnetz geringes Risiko. In fremden Netzen lassen sich über LLMNR/NetBIOS Anmelde-Hashes abgreifen; abschaltbar per Gruppenrichtlinie (DNS-Client > Multicastnamensauflösung deaktivieren).' }
}

Invoke-Check 'Proxy und Hosts-Datei' {
    $is = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $proxy = @()
    if ((Get-RegValue $is 'ProxyEnable') -eq 1) { $proxy += "Benutzer-Proxy $(Get-RegValue $is 'ProxyServer')" }
    $pac = Get-RegValue $is 'AutoConfigURL'
    if ($pac) { $proxy += "Proxy-Skript $pac" }
    $winhttp = (Invoke-Native "$script:Sys32\netsh.exe" @('winhttp', 'show', 'proxy')) -join ' '
    if ($winhttp -and $winhttp -notmatch 'Direkt|Direct') { $proxy += 'WinHTTP-Proxy: ' + ($winhttp -replace '\s+', ' ').Trim() }

    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $entries = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    Add-Table 'Hosts-Datei (aktive Einträge)' @($entries | Select-Object -First 200 | ForEach-Object { [pscustomobject]@{ Eintrag = $_ } })
    $blocked = @($entries | Where-Object { $_ -match 'update|defender|smartscreen|wdcp|wd\.microsoft|mp\.microsoft|delivery\.mp' })

    if ($blocked) { Add-Finding WARN "Hosts-Datei sperrt Update-/Defender-Adressen ($($blocked.Count) Einträge)" 'Einträge stammen meist von "Anti-Telemetrie"-Tools und verhindern Updates bzw. Cloud-Schutz: entfernen.' }
    elseif ($proxy) { Add-Finding WARN ('Proxy aktiv: ' + ($proxy -join '; ')) 'Prüfen, ob gewollt: Schadsoftware leitet Verkehr gern über einen Proxy um.' }
    elseif ($entries) { Add-Finding INFO "Kein Proxy; Hosts-Datei mit $($entries.Count) eigenen Einträgen (Anhang)" }
    else { Add-Finding OK 'Kein Proxy, Hosts-Datei unverändert' }
}

Invoke-Check 'DNS-Server' {
    $rows = foreach ($a in @(Get-NetAdapter | Where-Object Status -EQ 'Up')) {
        $d = Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        [pscustomobject][ordered]@{ Adapter = $a.Name; DNS = (@($d.ServerAddresses) -join ', ') }
    }
    Add-Table 'DNS-Server' $rows
    Add-Finding INFO (($rows | ForEach-Object { "$($_.Adapter): $($_.DNS)" }) -join '; ') 'Unerwartete DNS-Server (nicht Router/Provider/bekannter Anbieter) können auf eine Manipulation hinweisen.'
}

#endregion

#region Sicherheit: Konten & Anmeldung

Start-Section 'Sicherheit' 'Konten & Anmeldung'

Invoke-Check 'Lokale Benutzerkonten' {
    $users = @(Get-LocalUser)
    $rows = foreach ($u in $users) {
        [pscustomobject][ordered]@{
            Name            = $u.Name
            Aktiv           = $u.Enabled
            Typ             = [string]$u.PrincipalSource
            KennwortPflicht = $u.PasswordRequired
            KennwortGesetzt = Format-Date $u.PasswordLastSet
            LetzteAnmeldung = Format-Date $u.LastLogon
            SID             = $u.SID.Value
        }
    }
    Add-Table 'Lokale Benutzerkonten' $rows
    $crit = @(); $warn = @()
    $admin = $users | Where-Object { $_.SID.Value -like '*-500' }
    if ($admin.Enabled) { $warn += "Eingebautes Administratorkonto '$($admin.Name)' aktiv" }
    $guest = $users | Where-Object { $_.SID.Value -like '*-501' }
    if ($guest.Enabled) { $crit += "Gastkonto '$($guest.Name)' aktiv" }
    $noPw = @($users | Where-Object { $_.Enabled -and -not $_.PasswordRequired -and [string]$_.PrincipalSource -ne 'MicrosoftAccount' -and $_.SID.Value -notlike '*-50?' })
    if ($noPw) { $warn += 'Konten ohne Kennwortpflicht: ' + (($noPw | ForEach-Object Name) -join ', ') }
    $enabled = @($users | Where-Object Enabled)
    if ($crit) { Add-Finding CRIT (($crit + $warn) -join '; ') 'Gastkonto deaktivieren.' }
    elseif ($warn) { Add-Finding WARN ($warn -join '; ') 'Eingebautes Administratorkonto deaktivieren; jedes Konto mit Kennwort/PIN schützen.' }
    else { Add-Finding OK "$($enabled.Count) aktive Konten: $(($enabled | ForEach-Object Name) -join ', ')" }
}

Invoke-Check 'Administratorgruppe' {
    try { $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object Name) }
    catch {
        $group = ([Security.Principal.SecurityIdentifier]'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
        $members = @(([ADSI]"WinNT://$env:COMPUTERNAME/$group,group").Invoke('Members') | ForEach-Object { $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null) })
    }
    Add-Table 'Administratoren' @($members | ForEach-Object { [pscustomobject]@{ Mitglied = $_ } })
    $tokenGroups = (Invoke-Native "$script:Sys32\whoami.exe" @('/groups', '/fo', 'csv', '/nh')) -join "`n"
    $meIsAdmin = $tokenGroups -match '"S-1-5-32-544"'
    $value = "$($members.Count) Mitglieder: $($members -join ', ')"
    if ($members.Count -gt 2) { Add-Finding WARN $value 'Nicht mehr benötigte Administratorkonten entfernen.' }
    elseif ($meIsAdmin) { Add-Finding INFO "$value. Das angemeldete Konto ($env:USERNAME) ist Administrator." 'Am sichersten: Standardkonto für den Alltag, Admin-Konto nur für Installationen. Mindestens UAC nie abschalten.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Kennwort- und Sperrrichtlinie' -NeedsAdmin {
    $tmp = Join-Path $env:TEMP ('pc-check-secpol-{0}.inf' -f [guid]::NewGuid())
    $cfg = @{}
    try {
        Invoke-Native "$script:Sys32\secedit.exe" @('/export', '/cfg', $tmp, '/areas', 'SECURITYPOLICY', '/quiet') | Out-Null
        Get-Content -LiteralPath $tmp | ForEach-Object { if ($_ -match '^\s*([^=;\[]+?)\s*=\s*(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() } }
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    $keys = 'MinimumPasswordLength', 'PasswordComplexity', 'MaximumPasswordAge', 'PasswordHistorySize', 'LockoutBadCount', 'LockoutDuration', 'ResetLockoutCount', 'ClearTextPassword', 'LSAAnonymousNameLookup', 'EnableGuestAccount', 'EnableAdminAccount'
    Add-Table 'Lokale Sicherheitsrichtlinie' @($keys | ForEach-Object { [pscustomobject]@{ Einstellung = $_; Wert = $cfg[$_] } })
    $lockout = [int]$cfg['LockoutBadCount']
    $minLen = [int]$cfg['MinimumPasswordLength']
    if ($cfg['ClearTextPassword'] -eq '1') { Add-Finding CRIT 'Kennwörter werden mit umkehrbarer Verschlüsselung gespeichert' 'ClearTextPassword in der lokalen Sicherheitsrichtlinie deaktivieren.' }
    elseif ($lockout -eq 0) { Add-Finding WARN "Keine Kontosperre bei falschen Kennwörtern (Mindestlänge $minLen)" 'Kontosperrungsschwelle setzen, z. B. net accounts /lockoutthreshold:10 /lockoutduration:10 /lockoutwindow:10 (Windows-Standard bei Neuinstallation).' }
    else { Add-Finding OK "Sperre nach $lockout Fehlversuchen für $($cfg['LockoutDuration']) Min.; Mindestlänge $minLen" }
}

Invoke-Check 'Automatische Anmeldung' {
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if (Get-RegValue $wl 'DefaultPassword') { Add-Finding CRIT 'Kennwort im Klartext in der Registry (Winlogon\DefaultPassword)' 'Wert löschen; für Autologon Sysinternals Autologon verwenden (speichert verschlüsselt).' }
    elseif ((Get-RegValue $wl 'AutoAdminLogon') -eq '1') { Add-Finding WARN 'Automatische Anmeldung aktiv' 'Jeder mit Zugang zum PC ist nach dem Einschalten angemeldet.' }
    else { Add-Finding OK 'Aus' }
}

Invoke-Check 'Bildschirmsperre' {
    $d = 'HKCU:\Control Panel\Desktop'
    $inact = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'InactivityTimeoutSecs'
    $ssOn = (Get-RegValue $d 'ScreenSaveActive') -eq '1' -and (Get-RegValue $d 'ScreenSaverIsSecure') -eq '1' -and (Get-RegValue $d 'SCRNSAVE.EXE')
    $timeout = [int](Get-RegValue $d 'ScreenSaveTimeOut')
    $dynLock = (Get-RegValue 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' 'EnableGoodbye') -eq 1
    if ($inact -gt 0) { Add-Finding OK "Sperre nach $([int]($inact / 60)) Min. Inaktivität (Richtlinie)" }
    elseif ($ssOn) { Add-Finding OK "Bildschirmschoner mit Sperre nach $([int]($timeout / 60)) Min." }
    elseif ($dynLock) { Add-Finding OK 'Dynamische Sperre aktiv' }
    else { Add-Finding INFO 'Keine automatische Sperre bei Inaktivität' 'Für einen Heim-PC optional: beim Weggehen Win+L, oder Sperre per Bildschirmschoner-Einstellung.' }
}

#endregion

#region Sicherheit: Systemhärtung

Start-Section 'Sicherheit' 'Systemhärtung'

Invoke-Check 'Benutzerkontensteuerung (UAC)' {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $lua = Get-RegValue $k 'EnableLUA'
    $cpba = Get-RegValue $k 'ConsentPromptBehaviorAdmin'
    $sd = Get-RegValue $k 'PromptOnSecureDesktop'
    $apm = Get-RegValue $k 'TypeOfAdminApprovalMode'
    $levels = @{ 0 = 'ohne Nachfrage'; 1 = 'Kennwort (sicherer Desktop)'; 2 = 'immer benachrichtigen'; 3 = 'Kennwort'; 4 = 'Zustimmung'; 5 = 'Standard' }
    if ($lua -eq 0) { Add-Finding CRIT 'UAC vollständig deaktiviert' 'UAC wieder einschalten (EnableLUA = 1), sonst läuft jedes Programm mit vollen Rechten.' }
    elseif ($cpba -eq 0) { Add-Finding CRIT 'Adminrechte werden ohne Nachfrage erteilt' 'UAC-Regler mindestens auf Standard stellen.' }
    elseif ($sd -eq 0) { Add-Finding WARN 'UAC-Abfrage nicht auf dem sicheren Desktop' 'Schieberegler auf Standard: Schadprogramme können die Abfrage sonst fernsteuern.' }
    else { Add-Finding OK ("Aktiv, Stufe: $($levels[[int]$cpba])" + $(if ($apm -eq 2) { ', Administratorschutz an' } else { '' })) }
}

Invoke-Check 'Kernisolierung (VBS / Speicherintegrität)' {
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard
    $script:DeviceGuard = $dg
    $vbs = @{ 0 = 'aus'; 1 = 'konfiguriert, läuft nicht'; 2 = 'läuft' }[[int]$dg.VirtualizationBasedSecurityStatus]
    $running = @($dg.SecurityServicesRunning)
    $hvci = $running -contains 2
    $mbec = @($dg.AvailableSecurityProperties) -contains 7
    $value = "VBS $vbs, Speicherintegrität $(if ($hvci) { 'an' } else { 'aus' }), MBEC $(if ($mbec) { 'vorhanden' } else { 'fehlt' })"
    if ($hvci) { Add-Finding OK $value }
    else { Add-Finding WARN $value 'Windows-Sicherheit > Gerätesicherheit > Kernisolierung > Speicherintegrität einschalten (blockiert manipulierte und anfällige Treiber). Leistungsabwägung siehe Performance-Teil.' }
}

Invoke-Check 'LSA-Schutz' {
    $ppl = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL'
    if ($ppl -in 1, 2) { Add-Finding OK "An (RunAsPPL = $ppl)" }
    else { Add-Finding WARN 'Aus' 'Windows-Sicherheit > Gerätesicherheit > Kernisolierung > Schutz der lokalen Sicherheitsautorität einschalten (erschwert das Auslesen von Anmeldedaten).' }
}

Invoke-Check 'Treiber-Sperrliste und Smart App Control' {
    $bl = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' 'VulnerableDriverBlocklistEnable'
    $sac = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' 'VerifiedAndReputablePolicyState'
    $sacText = @{ 0 = 'aus'; 1 = 'an'; 2 = 'Evaluierung' }[[int]$sac]
    $value = 'Sperrliste für anfällige Treiber ' + $(if ($bl -eq 0) { 'aus' } else { 'an' }) + "; Smart App Control $sacText"
    if ($bl -eq 0) { Add-Finding WARN $value 'Windows-Sicherheit > Gerätesicherheit > Kernisolierung > Microsoft-Sperrliste für anfällige Treiber einschalten.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'SmartScreen' {
    $exp = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled'
    $pol = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen'
    $edgePol = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'SmartScreenEnabled'
    $off = @()
    if ($exp -eq 'Off' -or $pol -eq 0) { $off += 'Apps und Dateien' }
    if ($edgePol -eq 0) { $off += 'Edge (Richtlinie)' }
    if ($off) { Add-Finding WARN ('SmartScreen aus für: ' + ($off -join ', ')) 'Windows-Sicherheit > App- & Browsersteuerung > Zuverlässigkeitsbasierter Schutz: SmartScreen einschalten.' }
    else { Add-Finding OK 'Nicht abgeschaltet' }
}

Invoke-Check 'Exploit-Schutz (systemweit)' {
    $m = Get-ProcessMitigation -System
    $vals = [ordered]@{ 'DEP' = $m.Dep.Enable; 'ASLR Bottom-up' = $m.Aslr.BottomUp; 'ASLR hohe Entropie' = $m.Aslr.HighEntropy; 'CFG' = $m.Cfg.Enable; 'SEHOP' = $m.SEHOP.Enable }
    $off = @($vals.Keys | Where-Object { "$($vals[$_])" -eq 'OFF' })
    if ($off) { Add-Finding WARN ('Abgeschaltet: ' + ($off -join ', ')) 'Windows-Sicherheit > App- & Browsersteuerung > Exploit-Schutz: Systemeinstellungen auf Standard zurücksetzen.' }
    else { Add-Finding OK 'DEP, ASLR, CFG und SEHOP auf Standard' }
}

Invoke-Check 'Spectre/Meltdown-Schutz' {
    $mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $o = Get-RegValue $mm 'FeatureSettingsOverride'
    $mask = Get-RegValue $mm 'FeatureSettingsOverrideMask'
    if ($null -eq $o) { Add-Finding OK 'Windows-Standard (Abschwächungen aktiv)' }
    elseif (([int]$o -band 3) -ne 0) { Add-Finding CRIT "Abschwächungen per Registry deaktiviert (FeatureSettingsOverride = $o)" 'Typischer "Performance-Tweak": Werte FeatureSettingsOverride und FeatureSettingsOverrideMask löschen. Der Leistungsgewinn ist auf aktuellen CPUs klein, die Lücken sind real.' }
    else { Add-Finding INFO "Angepasst: FeatureSettingsOverride = $o, Mask = $mask (zusätzliche Abschwächungen)" }
}

Invoke-Check 'CPU-Microcode' {
    $k = 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0'
    # REG_BINARY mit 8 Byte (Revision in den oberen 4) oder 4 Byte, je nach Windows-Version
    $fmt = {
        param($b)
        if ($b -is [byte[]] -and $b.Length -ge 8) { '0x{0:X}' -f [BitConverter]::ToUInt32($b, 4) }
        elseif ($b -is [byte[]] -and $b.Length -ge 4) { '0x{0:X}' -f [BitConverter]::ToUInt32($b, 0) }
        else { 'unbekannt' }
    }
    $cur = & $fmt (Get-RegValue $k 'Update Revision')
    $prev = & $fmt (Get-RegValue $k 'Previous Update Revision')
    Add-Finding INFO "Aktiv: $cur, vom BIOS geladen: $prev" 'Windows lädt neueren Microcode selbst nach; ein aktuelles BIOS bringt ihn bereits beim Start mit.'
}

Invoke-Check 'PowerShell-Sicherheit' {
    $lm = [string](Get-ExecutionPolicy -Scope LocalMachine)
    $cu = [string](Get-ExecutionPolicy -Scope CurrentUser)
    $sbl = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' 'EnableScriptBlockLogging'
    $value = "Ausführungsrichtlinie LocalMachine = $lm, CurrentUser = $cu; Skriptblock-Protokollierung " + $(if ($sbl -eq 1) { 'an' } else { 'Standard' })
    if ($lm -in 'Unrestricted', 'Bypass' -or $cu -in 'Unrestricted', 'Bypass') { Add-Finding WARN $value 'Set-ExecutionPolicy RemoteSigned -Scope CurrentUser reicht für eigene Skripte; Unrestricted/Bypass lässt heruntergeladene Skripte ohne Warnung laufen.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Veraltete Anmeldeverfahren und Protokolle' {
    $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $crit = @(); $warn = @()
    if ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' 'UseLogonCredential') -eq 1) { $crit += 'WDigest hält Klartext-Kennwörter im Speicher' }
    $lm = Get-RegValue $lsa 'LmCompatibilityLevel'
    if ($null -ne $lm -and $lm -lt 3) { $warn += "LmCompatibilityLevel = $lm (LM/NTLMv1 erlaubt)" }
    if ((Get-RegValue $lsa 'NoLMHash') -eq 0) { $warn += 'LM-Hashes werden gespeichert' }
    if ((Get-RegValue $lsa 'RestrictAnonymousSAM') -eq 0) { $warn += 'Anonyme Aufzählung von Konten erlaubt' }
    foreach ($proto in 'SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1') {
        foreach ($side in 'Client', 'Server') {
            $e = Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$proto\$side" 'Enabled'
            if ($null -ne $e -and $e -ne 0) { $warn += "$proto ($side) ausdrücklich aktiviert" }
        }
    }
    if ($crit) { Add-Finding CRIT (($crit + $warn) -join '; ') 'Wert UseLogonCredential löschen bzw. auf 0 setzen.' }
    elseif ($warn) { Add-Finding WARN ($warn -join '; ') 'Werte auf Windows-Standard zurücksetzen.' }
    else { Add-Finding OK 'WDigest aus, NTLMv2, keine alten SSL/TLS-Versionen erzwungen' }
}

Invoke-Check 'Optionale Windows-Features' -NeedsAdmin {
    $feat = @(Get-WindowsOptionalFeature -Online | Where-Object State -EQ 'Enabled' | Sort-Object FeatureName)
    $script:Features = @($feat | ForEach-Object FeatureName)
    Add-Table 'Aktivierte optionale Features' @($feat | ForEach-Object { [pscustomobject]@{ Feature = $_.FeatureName } })
    $risky = [ordered]@{
        'SMB1Protocol'                     = 'SMBv1'
        'MicrosoftWindowsPowerShellV2Root' = 'PowerShell 2.0'
        'TelnetClient'                     = 'Telnet-Client'
        'TFTP'                             = 'TFTP-Client'
        'SimpleTCP'                        = 'Einfache TCP/IP-Dienste'
        'IIS-WebServerRole'                = 'IIS-Webserver'
        'Internet-Explorer-Optional-amd64' = 'Internet Explorer'
    }
    $found = @($risky.Keys | Where-Object { $_ -in $script:Features } | ForEach-Object { $risky[$_] })
    if ($found -contains 'SMBv1') { Add-Finding CRIT ('Aktiv: ' + ($found -join ', ')) 'SMBv1 und andere Alt-Features unter "Windows-Features aktivieren oder deaktivieren" abwählen.' }
    elseif ($found) { Add-Finding WARN ('Aktiv: ' + ($found -join ', ')) 'Nicht benötigte Alt-Features unter "Windows-Features aktivieren oder deaktivieren" abwählen.' }
    else { Add-Finding OK "$($feat.Count) Features aktiv, keine veralteten" }
}

Invoke-Check 'Entwicklermodus und sudo' {
    $dev = (Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowDevelopmentWithoutDevLicense') -eq 1
    $sudo = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' 'Enabled'
    $sudoText = @{ 0 = 'aus'; 1 = 'neues Fenster'; 2 = 'Eingabe gesperrt'; 3 = 'inline' }[[int]$sudo]
    $value = 'Entwicklermodus ' + $(if ($dev) { 'an' } else { 'aus' }) + "; sudo $sudoText"
    if ($sudo -eq 3) { Add-Finding INFO $value 'sudo im Modus "inline" ist laut Microsoft der unsicherste; "neues Fenster" genügt meist.' }
    else { Add-Finding INFO $value }
}
Invoke-Check 'Systemdateien: Signaturen (Sigcheck)' -NeedsAdmin {
    $s = Get-SysSigcheck
    if ($null -eq $s) { return }
    $b = Get-SysSigcheckBewertung -System32 $s['system32'] -Treiber $s['treiber'] -Regeln $script:AkzeptanzRegeln
    Add-Table 'Unsignierte Systemdateien (Sigcheck)' @($b.Tabelle)
    if ($b.Status -eq 'ACK') {
        # Alle unsignierten Dateien sind je SHA256 akzeptiert: als WARN anlegen und gleich auf ACK setzen (wie die allgemeine Akzeptanz)
        Add-Finding WARN $b.Wert $b.Empfehlung
        $f = $script:Findings[$script:Findings.Count - 1]
        $f.Status = 'ACK'; $f.OriginalStatus = 'WARN'; $f.Note = $b.Note
    }
    else { Add-Finding $b.Status $b.Wert $b.Empfehlung }
}

#endregion

#region Sicherheit: Verschlüsselung & Firmware

Start-Section 'Sicherheit' 'Verschlüsselung & Firmware'

Invoke-Check 'Secure Boot' {
    $fw = $env:firmware_type
    $sb = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
    if ($script:IsAdmin) { try { $sb = [int](Confirm-SecureBootUEFI) } catch {} }
    $script:SecureBoot = ($sb -eq 1)
    if ($fw -and $fw -ne 'UEFI') { Add-Finding WARN "Firmware-Modus $fw" 'Auf UEFI umstellen (mbr2gpt), Voraussetzung für Secure Boot.' }
    elseif ($sb -eq 1) { Add-Finding OK 'UEFI, Secure Boot an' }
    else { Add-Finding WARN 'UEFI, Secure Boot aus' 'Im BIOS Secure Boot einschalten (CSM aus). Schützt vor Bootkits; Anti-Cheat-Systeme wie Vanguard oder Javelin setzen es zunehmend voraus.' }
}

Invoke-Check 'Secure-Boot-Zertifikate 2023' -NeedsAdmin {
    if (-not $script:SecureBoot) { Add-Finding INFO 'Secure Boot aus, Zertifikatsstand nicht relevant'; return }
    $db = [Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI -Name db).Bytes)
    $kek = [Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI -Name KEK).Bytes)
    $has = [ordered]@{
        'Windows UEFI CA 2023 (db)'               = $db -match 'Windows UEFI CA 2023'
        'Microsoft UEFI CA 2023 (db)'             = $db -match 'Microsoft UEFI CA 2023'
        'Microsoft Corporation KEK 2K CA 2023 (KEK)' = $kek -match 'KEK 2K CA 2023'
    }
    $status = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing' 'UEFICA2023Status'
    Add-Table 'Secure-Boot-Zertifikate' @($has.Keys | ForEach-Object { [pscustomobject]@{ Zertifikat = $_; Vorhanden = $has[$_] } })
    $missing = @($has.Keys | Where-Object { -not $has[$_] })
    $value = $(if ($missing) { 'Fehlt: ' + ($missing -join ', ') } else { 'Alle 2023er-Zertifikate vorhanden' }) + $(if ($status) { "; Update-Status: $status" } else { '' })
    if ($missing) { Add-Finding WARN $value 'Die Secure-Boot-Zertifikate von 2011 sind 2026 abgelaufen. Windows Update spielt die 2023er-Zertifikate ein; hängt das, BIOS-Update vom Mainboard-Hersteller prüfen.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'TPM' -NeedsAdmin {
    $t = Get-Tpm
    $spec = [string](Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm -ErrorAction SilentlyContinue).SpecVersion
    $value = "Vorhanden: $($t.TpmPresent), bereit: $($t.TpmReady), Version $(($spec -split ',')[0]), Hersteller $($t.ManufacturerIdTxt)"
    if (-not $t.TpmPresent) { Add-Finding WARN 'Kein TPM gefunden' 'Intel PTT im BIOS einschalten.' }
    elseif (-not $t.TpmReady) { Add-Finding WARN $value 'TPM ist nicht einsatzbereit: tpm.msc prüfen.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'BitLocker' {
    $osOn = $false; $recovery = $true
    if ($script:IsAdmin) {
        $vols = @(Get-BitLockerVolume)
        $rows = foreach ($v in $vols) {
            [pscustomobject][ordered]@{
                Laufwerk    = $v.MountPoint
                Typ         = [string]$v.VolumeType
                Status      = [string]$v.VolumeStatus
                Schutz      = [string]$v.ProtectionStatus
                Verfahren   = [string]$v.EncryptionMethod
                Schutzarten = ((@($v.KeyProtector) | ForEach-Object { [string]$_.KeyProtectorType }) -join ', ')
            }
        }
        Add-Table 'BitLocker' $rows
        $os = $rows | Where-Object Typ -EQ 'OperatingSystem' | Select-Object -First 1
        $osOn = $os.Schutz -eq 'On'
        $recovery = $os.Schutzarten -match 'RecoveryPassword'
    }
    else {
        $v = (New-Object -ComObject Shell.Application).NameSpace("$($env:SystemDrive)\").Self.ExtendedProperty('System.Volume.BitLockerProtection')
        $osOn = $v -in 1, 3, 5
    }
    if ($osOn -and -not $recovery) { Add-Finding WARN 'Systemlaufwerk verschlüsselt, aber ohne Wiederherstellungskennwort' 'Wiederherstellungskennwort hinzufügen und sicher ablegen.' }
    elseif ($osOn) { Add-Finding OK 'Systemlaufwerk verschlüsselt' }
    else { Add-Finding WARN 'Systemlaufwerk nicht verschlüsselt' 'BitLocker mit TPM einschalten und den Wiederherstellungsschlüssel sicher ablegen (Microsoft-Konto oder Ausdruck). Schützt bei Diebstahl, Reparatur und Entsorgung der SSD; Leistungseinbuße auf NVMe meist gering.' }
}

Invoke-Check 'BIOS/UEFI-Version' {
    $b = Get-CimInstance Win32_BIOS
    $bb = Get-CimInstance Win32_BaseBoard
    $age = ((Get-Date) - $b.ReleaseDate).Days
    $value = "$($bb.Manufacturer) $($bb.Product), BIOS $($b.SMBIOSBIOSVersion) vom $((Get-Date $b.ReleaseDate).ToString('yyyy-MM-dd'))"
    if ($age -gt 3 * 365) { Add-Finding INFO $value 'Beim Hersteller nach neuerer BIOS-Version sehen (CPU-Microcode, Intel-ME-Fixes, Secure-Boot-Zertifikate). Achtung: Ein BIOS-Update setzt die OC-Einstellungen zurück, vorher Profil sichern.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Wiederherstellung' -NeedsAdmin {
    $re = (Invoke-Native "$script:Sys32\reagentc.exe" @('/info')) -join "`n"
    $reOn = $re -cmatch '\b(Enabled|Aktiviert)\b'
    $rp = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue)
    $last = $rp | Sort-Object SequenceNumber | Select-Object -Last 1
    $lastText = if ($last) { ' (letzter ' + [Management.ManagementDateTimeConverter]::ToDateTime($last.CreationTime).ToString('yyyy-MM-dd') + ')' } else { '' }
    # Computerschutz an? (wie die Aktion system.wiederherstellung). Fehlende Punkte allein heißen NICHT „aus“:
    # Windows löscht Punkte auch selbst, wenn der Speicher dafür zu klein ist (volsnap-Ereignis 33).
    $sr = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $interval = (Get-ItemProperty -LiteralPath $sr -Name RPSessionInterval -ErrorAction SilentlyContinue).RPSessionInterval
    $disSR = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name DisableSR -ErrorAction SilentlyContinue).DisableSR
    $schutzAn = ($interval -eq 1) -and ($disSR -ne 1)
    # Speichergrenze der Schattenkopien auf C: (nur mit Adminrechten lesbar); UInt64.MaxValue = unbegrenzt
    $maxText = ''; $klein = $false
    try {
        $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter='$($env:SystemDrive)'" -ErrorAction Stop
        $ss = @(Get-CimInstance Win32_ShadowStorage -ErrorAction Stop | Where-Object { $_.Volume.DeviceID -eq $vol.DeviceID }) | Select-Object -First 1
        if ($ss) {
            if ([uint64]$ss.MaxSpace -eq [uint64]::MaxValue) { $maxText = 'unbegrenzt' }
            else {
                $pct = [Math]::Round(100 * [double]$ss.MaxSpace / [double]$vol.Capacity, 1)
                $maxText = '{0} ({1} %)' -f (Format-Size ([double]$ss.MaxSpace)), $pct
                # Ein Punkt belegt oft 1–4 GB: unter 5 % bzw. 8 GB verdrängen neue Punkte die alten schnell
                $klein = ($pct -lt 5) -or ([double]$ss.MaxSpace -lt 8GB)
            }
        }
    }
    catch { }
    $geloescht = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'volsnap'; Id = 33; StartTime = $script:Since } -ErrorAction SilentlyContinue).Count
    $value = 'Windows RE ' + $(if ($reOn) { 'an' } else { 'aus' }) + '; Computerschutz ' + $env:SystemDrive + ' ' + $(if ($schutzAn) { 'an' } else { 'aus' }) +
        $(if ($maxText) { ", Speicher max $maxText" } else { '' }) + "; Wiederherstellungspunkte: $($rp.Count)$lastText" +
        $(if ($geloescht) { "; von Windows gelöscht: $geloescht in $EventDays Tagen" } else { '' })
    if (-not $reOn) { Add-Finding WARN $value 'Wiederherstellungsumgebung einschalten: reagentc /enable.' }
    elseif (-not $schutzAn) { Add-Finding INFO $value 'Systemschutz für C: einschalten: hilfreich vor Treiber- und OC-Experimenten.' }
    elseif ($klein) {
        # Point-in-time restore (Windows 11) setzt die VSS-Grenze bei jedem Start auf seine eigene Einstellung (Standard 2 %)
        $pitr = $null
        try { $pitr = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Setup\' -TaskName 'PITRTask' -ErrorAction Stop } catch { }
        if ($pitr -and ([string]$pitr.State -ne 'Disabled')) {
            Add-Finding WARN ($value + '; Speicher zu klein, verwaltet von Point-in-time restore') 'Windows löscht ältere Wiederherstellungspunkte, sobald der Speicher voll ist, und setzt die Grenze bei jedem Start auf die Einstellung von Point-in-time restore zurück. Einstellungen > System > Wiederherstellung > Point-in-time restore > Anzeigen oder bearbeiten: Regler auf etwa 10 %.'
        }
        else { Add-Finding WARN ($value + '; Speicher zu klein') 'Windows löscht ältere Wiederherstellungspunkte, sobald der Speicher voll ist. Speicher auf etwa 10 % vergrößern, damit Punkte vor Änderungen erhalten bleiben.' }
    }
    elseif (-not $rp) { Add-Finding OK ($value + ' (Morpheus legt vor jeder Änderung einen an)') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Datensicherung' {
    if (-not $script:SicherungLib) { Add-Finding SKIP 'gui\lib\Sicherung.ps1 fehlt'; return }
    # Get-MorpheusSicherung ermittelt die Adminrechte selbst und reicht sie an das Systemabbild weiter
    $e = @(Get-MorpheusSicherung)
    $rows = foreach ($x in $e) {
        $letzte = ''
        if ($x.letzteSicherung) { try { $letzte = ([datetime]$x.letzteSicherung).ToString('yyyy-MM-dd HH:mm') } catch { $letzte = '' } }
        $ziel = [string]$x.ziel
        if ($x.PSObject.Properties['ordner'] -and @($x.ordner).Count) { $ziel = (@($x.ordner) -join ', ') }
        [pscustomobject][ordered]@{ Art = [string]$x.art; Gefunden = [bool]$x.gefunden; Aktiv = [bool]$x.aktiv; Ziel = $ziel; LetzteSicherung = $letzte; Hinweis = [string]$x.hinweis }
    }
    Add-Table 'Datensicherung' @($rows)
    $b = Get-MorpheusSicherungBewertung -Eintraege $e
    Add-Finding $b.status $b.wert $b.empfehlung
}

#endregion

#region Sicherheit: Fernzugriff & Dienste

Start-Section 'Sicherheit' 'Fernzugriff & Dienste'

Invoke-Check 'Remotedesktop' {
    $ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $deny = Get-RegValue $ts 'fDenyTSConnections'
    $nla = Get-RegValue "$ts\WinStations\RDP-Tcp" 'UserAuthentication'
    $port = Get-RegValue "$ts\WinStations\RDP-Tcp" 'PortNumber'
    # Eine Gruppenrichtlinie hat Vorrang vor der Einstellung in den Systemeigenschaften
    $ra = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' 'fAllowToGetHelp'
    if ($null -eq $ra) { $ra = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' }
    if ($deny -eq 0 -and $nla -ne 1) { Add-Finding CRIT "RDP an (Port $port) ohne Authentifizierung auf Netzwerkebene" 'Remotedesktop ausschalten (Einstellungen > System > Remotedesktop).' }
    elseif ($deny -eq 0) { Add-Finding WARN "RDP an (Port $port)" 'Wenn du Remotedesktop nicht bewusst nutzt: Einstellungen > System > Remotedesktop ausschalten. Sonst in accepted.psd1 eintragen.' }
    else { Add-Finding OK 'Aus' }
    if ($ra -eq 1) { Add-Finding INFO 'Remoteunterstützung erlaubt' 'Wenn nicht genutzt: Systemeigenschaften > Remote > Remoteunterstützungsverbindungen nicht zulassen.' -Check 'Remoteunterstützung' }
    else { Add-Finding OK 'Nicht erlaubt' -Check 'Remoteunterstützung' }
}

Invoke-Check 'Fernzugriffsdienste und -programme' {
    $svcCheck = [ordered]@{ WinRM = 'WinRM'; sshd = 'OpenSSH-Server'; RemoteRegistry = 'Remoteregistrierung'; TlntSvr = 'Telnet-Server'; SNMP = 'SNMP'; FTPSVC = 'FTP-Server'; W3SVC = 'IIS-Webserver' }
    $active = foreach ($n in $svcCheck.Keys) {
        $s = $script:Services | Where-Object Name -EQ $n
        if ($s -and ($s.State -eq 'Running' -or $s.StartMode -eq 'Auto')) { "$($svcCheck[$n]) ($($s.State), $($s.StartMode))" }
    }
    $toolPattern = 'TeamViewer|AnyDesk|RustDesk|Parsec|Splashtop|VNC|LogMeIn|ScreenConnect|ConnectWise|Radmin|Ammyy|Supremo|NoMachine|nxservice|chromoting|remoting_host|Sunshine|Zoho Assist|DWService|MeshAgent|HopToDesk|rutserv|Dameware|BeyondTrust|Bomgar|GoToAssist|Atera|NinjaRMM|Kaseya|Tailscale|ZeroTier|ngrok'
    $tools = @($script:Services | Where-Object { $_.Name -match $toolPattern -or $_.DisplayName -match $toolPattern -or $_.PathName -match $toolPattern } | ForEach-Object { "$($_.DisplayName) ($($_.State))" })
    $tools += @(Get-Process | Where-Object { $_.ProcessName -match $toolPattern } | ForEach-Object { "Prozess $($_.ProcessName)" } | Select-Object -Unique)
    $all = @($active) + $tools
    if ($all) { Add-Finding WARN ('Gefunden: ' + ($all -join '; ')) 'Prüfen, ob du das nutzt; sonst deinstallieren bzw. Dienst deaktivieren. Ungenutzte Fernwartung ist ein häufiger Einfallsweg.' }
    else { Add-Finding OK 'Keine Fernwartungsdienste oder -programme aktiv' }
}

Invoke-Check 'Dienste von Drittanbietern' {
    $rows = foreach ($s in $script:Services) {
        $exe = Get-ExePath $s.PathName
        if (-not $exe) { continue }
        $sig = Get-FileSignatureInfo $exe
        if ($sig.Signer -like 'Microsoft*') { continue }
        [pscustomobject][ordered]@{
            Name      = $s.Name
            Anzeige   = $s.DisplayName
            Status    = $s.State
            Start     = $s.StartMode
            Konto     = $s.StartName
            Signatur  = $sig.Status
            Signierer = $sig.Signer
            Pfad      = $exe
        }
    }
    $rows = @($rows)
    $script:ThirdPartyServices = $rows
    Add-Table 'Dienste von Drittanbietern' $rows
    $bad = @($rows | Where-Object { $_.Signatur -notin 'Valid', 'Datei fehlt' })
    $auto = @($rows | Where-Object Start -EQ 'Auto')
    if ($bad) { Add-Finding WARN ('Ohne gültige Signatur: ' + (($bad | ForEach-Object { "$($_.Name) ($($_.Signatur))" }) -join ', ')) 'Herkunft der Dienste prüfen (Pfad im Anhang).' }
    else { Add-Finding OK "$($rows.Count) Drittanbieter-Dienste ($($auto.Count) mit Autostart), alle gültig signiert" }
}

Invoke-Check 'Dienstpfade und Berechtigungen' {
    $unquoted = foreach ($s in $script:Services) {
        $p = [string]$s.PathName
        if (-not $p -or $p -match '^\s*"' -or $p -notmatch '^\s*([A-Za-z]:\\[^"]*?\.exe)') { continue }
        $exe = $Matches[1]
        if ($exe -match ' ' -and $exe -notmatch '^[A-Za-z]:\\Windows\\') { "$($s.Name): $p" }
    }
    $weakSids = 'S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-4'
    # WriteData/AddFile, AppendData/AddSubdirectory, ChangePermissions, TakeOwnership, GENERIC_WRITE, GENERIC_ALL
    $writeMask = 0x2 -bor 0x4 -bor 0x40000 -bor 0x80000 -bor 0x40000000 -bor 0x10000000
    $weak = foreach ($s in $script:ThirdPartyServices) {
        foreach ($target in @($s.Pfad, (Split-Path -Parent $s.Pfad))) {
            if (-not $target -or -not (Test-Path -LiteralPath $target)) { continue }
            try { $acl = Get-Acl -LiteralPath $target } catch { continue }
            foreach ($ace in $acl.Access) {
                if ([string]$ace.AccessControlType -ne 'Allow') { continue }
                if ($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
                try { $sid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
                if ($sid -in $weakSids -and ([int64]$ace.FileSystemRights -band $writeMask)) {
                    "$($s.Name): $target ($($ace.IdentityReference.Value))"
                    break
                }
            }
        }
    }
    $weak = @($weak | Select-Object -Unique)
    Add-Table 'Dienste: ungeschützte Pfade und schreibbare Ordner' @(@($unquoted | ForEach-Object { [pscustomobject]@{ Art = 'Pfad ohne Anführungszeichen'; Eintrag = $_ } }) + @($weak | ForEach-Object { [pscustomobject]@{ Art = 'Für Benutzer schreibbar'; Eintrag = $_ } }))
    if ($weak) { Add-Finding WARN ("$($weak.Count) Dienst-Programme/-Ordner für normale Benutzer schreibbar: " + (($weak | Select-Object -First 5) -join '; ')) 'Darüber kann sich Schadsoftware Systemrechte verschaffen. Programm aktualisieren/neu installieren oder Ordnerrechte korrigieren.' }
    elseif ($unquoted) { Add-Finding WARN ("Dienstpfade mit Leerzeichen ohne Anführungszeichen: " + ($unquoted -join '; ')) 'Programm aktualisieren; der Hersteller muss den Pfad in Anführungszeichen setzen.' }
    else { Add-Finding OK 'Keine angreifbaren Dienstpfade' }
}

Invoke-Check 'Treiber: bekannt anfällige und unsignierte' {
    $vulnerable = 'gdrv.sys', 'gdrv2.sys', 'gdrv3.sys', 'RTCore64.sys', 'RTCore32.sys', 'WinRing0x64.sys', 'WinRing0.sys', 'AsIO.sys', 'AsIO2.sys', 'AsIO3.sys', 'AsUpIO.sys',
    'AsrDrv10.sys', 'AsrDrv101.sys', 'AsrDrv103.sys', 'NTIOLib_X64.sys', 'NTIOLib.sys', 'EneIo64.sys', 'EneTechIo64.sys', 'cpuz141_x64.sys', 'iqvw64e.sys', 'dbutil_2_3.sys',
    'DBUtilDrv2.sys', 'Capcom.sys', 'atillk64.sys', 'HwRwDrv.sys', 'PhyMemx64.sys', 'speedfan.sys', 'inpoutx64.sys', 'GLCKIO2.sys', 'BS_RCIO64.sys', 'MsIo64.sys',
    'AODDriver2.sys', 'mhyprot2.sys', 'ALSysIO64.sys', 'ATSZIO64.sys', 'TfSysMon.sys', 'zam64.sys', 'LHA.sys',
    'GVCIDrv64.sys', 'GVCIDrv.sys', 'GPCIDrv64.sys', 'GPCIDrv.sys'
    $drv = @(Get-CimInstance Win32_SystemDriver)
    $driverDir = Join-Path $env:SystemRoot 'System32\drivers'
    # Version mit ausgeben, damit eine gepatchte Version gezielt in accepted.psd1 akzeptiert werden kann.
    $fileVersion = { param($p) try { (([string](Get-Item -LiteralPath $p -ErrorAction Stop).VersionInfo.FileVersion) -split ' ')[0] } catch { '' } }
    $found = foreach ($n in $vulnerable) {
        $svc = @($drv | Where-Object { [IO.Path]::GetFileName([string]$_.PathName) -ieq $n })
        $file = Test-Path -LiteralPath (Join-Path $driverDir $n)
        if ($svc -or $file) {
            $path = $(if ($svc) { (Get-ExePath $svc[0].PathName) } else { Join-Path $driverDir $n })
            [pscustomobject][ordered]@{
                Treiber = $n
                Version = & $fileVersion $path
                Status  = $(if ($svc | Where-Object State -EQ 'Running') { 'geladen' } else { 'vorhanden' })
                Dienst  = (($svc | ForEach-Object Name) -join ', ')
                Pfad    = $path
            }
        }
    }
    $found = @($found)
    # Manche Tools installieren ihren Treiber nur kurz und entfernen ihn wieder: über die Dienst-Installationsereignisse nachweisen.
    $transient = @(Get-RecentEvents @{ LogName = 'System'; Id = 7045; ProviderName = 'Service Control Manager' } -Max 500 | ForEach-Object {
            $img = Get-ExePath (Get-EventData $_)['ImagePath']
            $leaf = try { [IO.Path]::GetFileName($img) } catch { '' }
            if ($leaf -and $leaf -in $vulnerable -and $leaf -notin $found.Treiber) { [pscustomobject]@{ Treiber = $leaf; Pfad = $img } }
        } | Group-Object Treiber | ForEach-Object {
            $path = $_.Group[0].Pfad
            $exists = Test-Path -LiteralPath $path
            [pscustomobject][ordered]@{
                Treiber = $_.Name
                Version = & $fileVersion $path
                Status  = $(if ($exists) { 'geladen' } else { 'entfernt' })
                Dienst  = "$($_.Count)x installiert in $EventDays Tagen" + $(if (-not $exists) { ', Datei inzwischen gelöscht' } else { '' })
                Pfad    = $path
            }
        })
    $found = @($found) + $transient
    $third = foreach ($d in ($drv | Where-Object State -EQ 'Running')) {
        $p = Get-ExePath $d.PathName
        # Ohne ImagePath lädt Windows den Treiber aus dem Standardpfad (z. B. UCPD, UnionFS)
        if (-not $p) { $p = Join-Path $env:SystemRoot "System32\drivers\$($d.Name).sys" }
        $sig = Get-FileSignatureInfo $p
        if ($sig.Signer -like 'Microsoft*' -and $sig.Status -eq 'Valid') { continue }
        [pscustomobject][ordered]@{ Name = $d.Name; Anzeige = $d.DisplayName; Signatur = $sig.Status; Signierer = $sig.Signer; Hersteller = $sig.Company; Pfad = $p }
    }
    $third = @($third)
    Add-Table 'Treiber: bekannt anfällige' $found
    Add-Table 'Treiber: geladene Drittanbieter-Treiber' $third
    $unsigned = @($third | Where-Object { $_.Signatur -notin 'Valid', 'Datei fehlt' })
    $loaded = @($found | Where-Object Status -EQ 'geladen')
    $rest = @($found | Where-Object Status -EQ 'vorhanden' | ForEach-Object { "$($_.Treiber) ($($_.Status))" })
    # Nur kurz installierte und wieder gelöschte Treiber sind kein Befund mehr, nur eine Spur im Protokoll
    $gone = @($found | Where-Object Status -EQ 'entfernt' | ForEach-Object Treiber)
    $goneText = if ($gone) { "; früher installiert, inzwischen entfernt: $($gone -join ', ')" } else { '' }
    if ($loaded) { Add-Finding WARN ('Geladen: ' + (($loaded | ForEach-Object { "$($_.Treiber) $($_.Version) ($($_.Dienst))" }) -join ', ') + $(if ($rest) { '; außerdem: ' + ($rest -join ', ') } else { '' })) 'Treiber dieser Art (direkter Hardwarezugriff) wurden schon oft von Schadsoftware und Cheats missbraucht. Zugehöriges Tool (RGB/OC/Monitoring) aktuell halten oder deinstallieren; Speicherintegrität blockiert bekannt unsichere Versionen.' }
    elseif ($rest) { Add-Finding INFO ('Nicht geladen: ' + ($rest -join ', ') + $goneText) 'Reste alter Tools; zugehöriges Programm deinstallieren.' }
    elseif ($unsigned) { Add-Finding WARN ('Ohne gültige Signatur geladen: ' + (($unsigned | ForEach-Object Name) -join ', ') + $goneText) 'Herkunft prüfen.' }
    else { Add-Finding OK "Keine bekannt anfälligen Treiber; $($third.Count) Drittanbieter-Treiber geladen (Anhang)$goneText" }
}

#endregion

#region Sicherheit: Autostart & Persistenz

Start-Section 'Sicherheit' 'Autostart & Persistenz'

Invoke-Check 'Autostart-Einträge' {
    $runKeys = @(
        @{ Ort = 'HKLM Run'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        @{ Ort = 'HKLM Run (32 Bit)'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
        @{ Ort = 'HKCU Run'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        @{ Ort = 'HKLM RunOnce'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = $null }
        @{ Ort = 'HKCU RunOnce'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = $null }
    )
    $rows = New-Object System.Collections.Generic.List[object]
    $isEnabled = {
        param($ApprovedKey, $Name)
        if (-not $ApprovedKey) { return $true }
        $b = Get-RegValue $ApprovedKey $Name
        -not ($b -is [byte[]] -and $b.Length -gt 0 -and ($b[0] % 2) -eq 1)
    }
    foreach ($rk in $runKeys) {
        if (-not (Test-Path $rk.Path)) { continue }
        $key = Get-Item -LiteralPath $rk.Path
        foreach ($n in $key.GetValueNames()) {
            if (-not $n) { continue }
            $cmd = [string]$key.GetValue($n)
            $sig = Get-FileSignatureInfo (Get-ExePath $cmd)
            $rows.Add([pscustomobject][ordered]@{ Ort = $rk.Ort; Name = $n; Aktiv = (& $isEnabled $rk.Approved $n); Signatur = $sig.Status; Signierer = $sig.Signer; Befehl = $cmd })
        }
    }
    $shell = New-Object -ComObject WScript.Shell
    $folders = @(
        @{ Ort = 'Autostart-Ordner (Benutzer)'; Path = [Environment]::GetFolderPath('Startup'); Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
        @{ Ort = 'Autostart-Ordner (alle)'; Path = [Environment]::GetFolderPath('CommonStartup'); Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    )
    foreach ($f in $folders) {
        foreach ($file in @(Get-ChildItem -LiteralPath $f.Path -File -Force -ErrorAction SilentlyContinue | Where-Object Name -NE 'desktop.ini')) {
            $target = $file.FullName
            if ($file.Extension -eq '.lnk') { try { $target = $shell.CreateShortcut($file.FullName).TargetPath } catch {} }
            $sig = Get-FileSignatureInfo $target
            $rows.Add([pscustomobject][ordered]@{ Ort = $f.Ort; Name = $file.Name; Aktiv = (& $isEnabled $f.Approved $file.Name); Signatur = $sig.Status; Signierer = $sig.Signer; Befehl = $target })
        }
    }
    $script:AutostartRows = $rows.ToArray()
    Add-Table 'Autostart-Einträge' $rows
    $sus = @($rows | Where-Object { $_.Aktiv -and $_.Signatur -notin 'Valid', 'Datei fehlt' -and (Test-UserWritablePath $_.Befehl) })
    $unsigned = @($rows | Where-Object { $_.Aktiv -and $_.Signatur -notin 'Valid', 'Datei fehlt' })
    $activeCount = @($rows | Where-Object Aktiv).Count
    if ($sus) { Add-Finding WARN ('Unsignierte Programme aus Benutzerordnern im Autostart: ' + (($sus | ForEach-Object Name) -join ', ')) 'Einträge prüfen (Anhang); typisches Muster von Schadsoftware, aber auch kleiner Tools.' }
    elseif ($unsigned) { Add-Finding INFO ("$activeCount aktive Einträge, davon ohne gültige Signatur: " + (($unsigned | ForEach-Object Name) -join ', ')) 'Einträge im Anhang prüfen.' }
    else { Add-Finding OK "$activeCount aktive Einträge, alle signiert" }
}

Invoke-Check 'Autostarts: Signaturen (Autoruns)' -NeedsAdmin {
    $e = Get-SysAutoruns
    if ($null -eq $e) { return }
    $aufgaben = Get-SysAufgaben
    Add-Table 'Autostarts (Autoruns, ohne Microsoft)' @(Get-MorpheusAutorunsTabelle -Eintraege $e -Aufgaben $aufgaben)
    $b = Get-MorpheusAutorunsSignaturBefund -Eintraege $e -Aufgaben $aufgaben
    Add-Finding $b.status $b.wert $b.empfehlung
}

Invoke-Check 'Autostarts: beschreibbare Pfade (Autoruns)' -NeedsAdmin {
    # Nicht vertrauenswürdiges Werkzeug nur einmal als Warnung zählen (bei der Signatur-Prüfung)
    if ($script:Autoruns -and $script:Autoruns.nichtVertrauenswuerdig) { Add-Finding SKIP 'Autoruns nicht ausgeführt (siehe Autostarts: Signaturen)'; return }
    $e = Get-SysAutoruns
    if ($null -eq $e) { return }
    $b = Get-MorpheusAutorunsPfadBefund -Eintraege $e -Aufgaben (Get-SysAufgaben)
    Add-Finding $b.status $b.wert $b.empfehlung
}
Invoke-Check 'Systemnahe Autostarts (Winlogon, IFEO, AppInit)' {
    $issues = @()
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $shellValue = Get-RegValue $wl 'Shell'
    if ($shellValue -and $shellValue -notmatch '^\s*explorer\.exe\s*$') { $issues += "Winlogon Shell = $shellValue" }
    $ui = [string](Get-RegValue $wl 'Userinit')
    if ($ui -and $ui.TrimEnd(', ') -notmatch '^[A-Za-z]:\\Windows\\system32\\userinit\.exe$') { $issues += "Winlogon Userinit = $ui" }
    $hkcuShell = Get-RegValue 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' 'Shell'
    if ($hkcuShell) { $issues += "Benutzer-Shell = $hkcuShell" }
    $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    foreach ($k in @(Get-ChildItem -LiteralPath $ifeo -ErrorAction SilentlyContinue)) {
        $dbg = $k.GetValue('Debugger')
        if ($dbg) { $issues += "Debugger für $($k.PSChildName): $dbg" }
    }
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Windows') {
        $dll = Get-RegValue $k 'AppInit_DLLs'
        if ($dll -and (Get-RegValue $k 'LoadAppInit_DLLs') -eq 1) { $issues += "AppInit_DLLs = $dll" }
    }
    $boot = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'BootExecute') -join ' '
    if ($boot -and $boot -notmatch '^\s*autocheck autochk \*\s*$') { $issues += "BootExecute = $boot" }
    if ($issues) { Add-Finding WARN ($issues -join '; ') 'Einträge prüfen: Ein "Debugger" für taskmgr.exe stammt z. B. von Process Explorer; alles Unbekannte ist ein starkes Warnzeichen.' }
    else { Add-Finding OK 'Shell, Userinit, IFEO und AppInit unverändert' }
}

Invoke-Check 'Geplante Aufgaben' {
    $tasks = @(Get-ScheduledTask)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($t in $tasks) {
        $isMs = $t.TaskPath -like '\Microsoft\*'
        foreach ($a in @($t.Actions)) {
            $exeRaw = (Expand-MorpheusUmgebung ([string]$a.Execute)).Trim().Trim('"')
            $arg = [string]$a.Arguments
            if (-not $exeRaw) {
                if (-not $isMs) { $rows.Add([pscustomobject][ordered]@{ Aufgabe = "$($t.TaskPath)$($t.TaskName)"; Status = [string]$t.State; Konto = $t.Principal.UserId; Admin = ([string]$t.Principal.RunLevel -eq 'Highest'); Signierer = ''; Auffaellig = ''; Befehl = "COM-Handler $($a.ClassId)" }) }
                continue
            }
            $exe = Get-ExePath "`"$exeRaw`""
            $userPath = Test-UserWritablePath $exe
            if ($isMs -and -not $userPath) { continue }
            $sig = Get-FileSignatureInfo $exe
            $flags = @()
            if ($isMs -and $userPath) { $flags += 'Microsoft-Ordner, aber Programm im Benutzerordner' }
            elseif ($userPath -and $sig.Status -ne 'Valid') { $flags += 'unsigniert im Benutzerordner' }
            if ("$exeRaw $arg" -match '(?i)-enc(odedcommand)?\s|frombase64string|downloadstring|downloadfile|invoke-webrequest|\biwr\b|\biex\b|invoke-expression|-w(indowstyle)?\s+h(idden)?\b|mshta|regsvr32.+/i:http|bitsadmin|certutil.+-urlcache') { $flags += 'verdächtige Befehlszeile' }
            $rows.Add([pscustomobject][ordered]@{
                    Aufgabe    = "$($t.TaskPath)$($t.TaskName)"
                    Status     = [string]$t.State
                    Konto      = $t.Principal.UserId
                    Admin      = ([string]$t.Principal.RunLevel -eq 'Highest')
                    Signierer  = $sig.Signer
                    Auffaellig = ($flags -join ', ')
                    Befehl     = ("$exe $arg").Trim()
                })
        }
    }
    Add-Table 'Geplante Aufgaben (Drittanbieter und auffällige)' $rows
    $sus = @($rows | Where-Object { $_.Auffaellig -and $_.Status -ne 'Disabled' })
    if ($sus) { Add-Finding WARN ("$($sus.Count) auffällige Aufgaben: " + (($sus | Select-Object -First 5 | ForEach-Object { "$($_.Aufgabe) ($($_.Auffaellig))" }) -join '; ')) 'Aufgaben im Anhang prüfen; versteckte PowerShell-Befehle und unsignierte Programme aus Benutzerordnern sind typische Schadsoftware-Muster.' }
    else { Add-Finding OK "$($rows.Count) Drittanbieter-Aufgaben, keine auffälligen" }
}

Invoke-Check 'WMI-Ereignisabonnements' -NeedsAdmin {
    $cons = @(Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer -ErrorAction SilentlyContinue)
    $rows = foreach ($c in $cons) {
        [pscustomobject][ordered]@{ Name = $c.Name; Typ = $c.CimClass.CimClassName; Inhalt = (@($c.CommandLineTemplate, $c.ScriptText, $c.ExecutablePath) | Where-Object { $_ } | Select-Object -First 1) }
    }
    Add-Table 'WMI-Ereignisabonnements' $rows
    $sus = @($rows | Where-Object { $_.Typ -in 'CommandLineEventConsumer', 'ActiveScriptEventConsumer' })
    if ($sus) { Add-Finding WARN ('Ausführende WMI-Abonnements: ' + (($sus | ForEach-Object Name) -join ', ')) 'Unbekannte Einträge sind ein starkes Warnzeichen (dateilose Schadsoftware). Inhalt im Anhang prüfen.' }
    else { Add-Finding OK "$($cons.Count) Abonnements, keine ausführenden" }
}

Invoke-Check 'Laufende Programme (Signatur und Ort)' {
    # Path ist eine Skript-Eigenschaft und wird erst beim Zugriff gelesen: einmal festhalten, sonst fehlt er bei kurzlebigen Prozessen.
    $procs = @(Get-Process | ForEach-Object { [pscustomobject]@{ ProcessName = $_.ProcessName; Path = $_.Path } } | Where-Object Path | Group-Object Path | ForEach-Object { $_.Group[0] })
    $rows = foreach ($p in $procs) {
        # Store-Apps sind über ihr Paket signiert, nicht per Authenticode an der einzelnen Datei.
        if ($p.Path -like "$env:SystemRoot\*" -or $p.Path -like "$env:ProgramFiles\WindowsApps\*") { continue }
        $sig = Get-FileSignatureInfo $p.Path
        if ($sig.Status -eq 'Valid') { continue }
        [pscustomobject][ordered]@{ Prozess = $p.ProcessName; Signatur = $sig.Status; Hersteller = $sig.Company; Benutzerordner = (Test-UserWritablePath $p.Path); Pfad = $p.Path }
    }
    $rows = @($rows)
    Add-Table 'Laufende Programme ohne gültige Signatur' $rows
    $sus = @($rows | Where-Object Benutzerordner)
    if ($sus) { Add-Finding WARN ('Unsignierte Programme aus Benutzerordnern aktiv: ' + (($sus | ForEach-Object Prozess | Select-Object -Unique) -join ', ')) 'Herkunft prüfen (Pfad im Anhang).' }
    elseif ($rows) { Add-Finding INFO ('Ohne gültige Signatur: ' + (($rows | ForEach-Object Prozess | Select-Object -Unique) -join ', ')) 'Meist kleine Tools oder Spiele; Herkunft kurz prüfen.' }
    else { Add-Finding OK "$($procs.Count) Programme, alle gültig signiert" }
}

Invoke-Check 'Browser-Erweiterungen' {
    $rows = New-Object System.Collections.Generic.List[object]
    $chromium = [ordered]@{
        'Chrome'  = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        'Edge'    = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
        'Brave'   = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
        'Vivaldi' = "$env:LOCALAPPDATA\Vivaldi\User Data"
        'Opera'   = "$env:APPDATA\Opera Software\Opera Stable"
    }
    foreach ($b in $chromium.Keys) {
        $root = $chromium[$b]
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $profiles = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Extensions') })
        if (Test-Path -LiteralPath (Join-Path $root 'Extensions')) { $profiles += Get-Item -LiteralPath $root }
        foreach ($prof in $profiles) {
            foreach ($ext in @(Get-ChildItem -LiteralPath (Join-Path $prof.FullName 'Extensions') -Directory -ErrorAction SilentlyContinue)) {
                if ($ext.Name -eq 'Temp') { continue }
                $verDir = Get-ChildItem -LiteralPath $ext.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
                if (-not $verDir) { continue }
                $mf = Join-Path $verDir.FullName 'manifest.json'
                if (-not (Test-Path -LiteralPath $mf)) { continue }
                try { $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
                $perms = @(@($m.permissions) + @($m.host_permissions) | Where-Object { $_ -is [string] })
                # Vollzugriff aus allen Berechtigungen bestimmen (Manifest V3: host_permissions, dazu Content-Scripts), nicht aus der gekürzten Anzeige
                $hosts = @($perms) + @($m.content_scripts | ForEach-Object { $_.matches } | Where-Object { $_ -is [string] })
                $rows.Add([pscustomobject][ordered]@{
                        Browser        = $b
                        Profil         = $prof.Name
                        Name           = Resolve-ExtensionName $m $verDir.FullName
                        Version        = $m.version
                        ID             = $ext.Name
                        Vollzugriff    = [bool]($hosts | Where-Object { $_ -match $script:AllSitesPattern })
                        Berechtigungen = (($perms | Select-Object -First 8) -join ', ')
                    })
            }
        }
    }
    $ffRoot = "$env:APPDATA\Mozilla\Firefox\Profiles"
    foreach ($prof in @(Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue)) {
        $f = Join-Path $prof.FullName 'extensions.json'
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try { $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        foreach ($a in @($j.addons | Where-Object { $_.location -eq 'app-profile' })) {
            $origins = @($a.userPermissions.origins | Where-Object { $_ -is [string] })
            $rows.Add([pscustomobject][ordered]@{ Browser = 'Firefox'; Profil = $prof.Name; Name = $a.defaultLocale.name; Version = $a.version; ID = $a.id; Vollzugriff = [bool]($origins | Where-Object { $_ -match $script:AllSitesPattern }); Berechtigungen = ((@($a.userPermissions.permissions) + $origins | Select-Object -First 8) -join ', ') })
        }
    }
    Add-Table 'Browser-Erweiterungen' $rows
    $broad = @($rows | Where-Object Vollzugriff)
    $broadNames = @($broad | ForEach-Object Name | Select-Object -Unique)
    if ($rows.Count) { Add-Finding INFO ("$($rows.Count) Erweiterungen, davon $($broad.Count) mit Zugriff auf alle Webseiten" + $(if ($broadNames) { ': ' + ($broadNames -join ', ') } else { '' })) 'Liste im Anhang durchgehen und alles entfernen, was du nicht kennst oder nicht nutzt. Erweiterungen mit Vollzugriff können Passwörter und Sitzungen mitlesen; bei Werbeblockern und Passwortmanagern ist das technisch nötig.' }
    else { Add-Finding OK 'Keine Erweiterungen gefunden' }
}

#endregion

#region Sicherheit: Software

Start-Section 'Sicherheit' 'Software'

Invoke-Check 'Installierte Programme' {
    $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $apps = foreach ($p in $paths) {
        Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 -and -not $_.ParentKeyName } |
            ForEach-Object {
                $date = [string]$_.InstallDate
                [pscustomobject][ordered]@{
                    Name        = ([string]$_.DisplayName).Trim()
                    Version     = [string]$_.DisplayVersion
                    Hersteller  = [string]$_.Publisher
                    Installiert = $(if ($date -match '^(\d{4})(\d{2})(\d{2})$') { "$($Matches[1])-$($Matches[2])-$($Matches[3])" } else { '' })
                    Bereich     = $(if ($p -like 'HKCU*') { 'Benutzer' } else { 'System' })
                }
            }
    }
    $apps = @($apps | Sort-Object Name, Version -Unique)
    Add-Table 'Installierte Programme' $apps

    $eol = @(
        @{ Pattern = '^Adobe Flash'; Text = 'Adobe Flash (seit 2020 ohne Support)' }
        @{ Pattern = '^Microsoft Silverlight'; Text = 'Silverlight (seit 2021 ohne Support)' }
        @{ Pattern = '^QuickTime'; Text = 'QuickTime für Windows (seit 2016 ohne Support)' }
        @{ Pattern = '^Python 2\.'; Text = 'Python 2 (seit 2020 ohne Support)' }
        @{ Pattern = '^Python 3\.[0-9]\.'; Text = 'Python 3.9 oder älter (ohne Support)' }
        @{ Pattern = 'Microsoft Office.*(2007|2010|2013|2016|2019)'; Text = 'Office 2019 oder älter (ohne Support, 2016/2019 seit 14.10.2025)' }
        @{ Pattern = '^Java(\(TM\))? [67]\b'; Text = 'Java 6/7' }
    )
    $minVersions = @(
        @{ Pattern = '^WinRAR'; Min = '7.13'; Text = 'WinRAR vor 7.13 (aktiv ausgenutzte Lücke CVE-2025-8088)' }
        @{ Pattern = '^7-Zip'; Min = '25.0'; Text = '7-Zip vor 25.00 (Lücken CVE-2025-0411 / CVE-2025-11001)' }
        @{ Pattern = '^Node\.js'; Min = '22.0'; Text = 'Node.js vor 22 (ohne Support)' }
    )
    $hits = @()
    foreach ($a in $apps) {
        foreach ($r in $eol) { if ($a.Name -match $r.Pattern) { $hits += "$($a.Name) $($a.Version): $($r.Text)" } }
        foreach ($r in $minVersions) {
            if ($a.Name -match $r.Pattern) {
                $v = ConvertTo-LooseVersion $a.Version
                if ($v -and $v -lt (ConvertTo-LooseVersion $r.Min)) { $hits += "$($a.Name) $($a.Version): $($r.Text)" }
            }
        }
    }
    $hits = @($hits | Select-Object -Unique)
    if ($hits) { Add-Finding WARN ($hits -join '; ') 'Aktualisieren oder deinstallieren.' }
    else { Add-Finding OK "$($apps.Count) Programme, keine bekannten Altversionen gefunden" }
}

if ($SkipWinget) {
    $script:CheckName = 'Software-Updates (winget)'
    Add-Finding SKIP 'Übersprungen (-SkipWinget)'
}
else {
    Invoke-Check 'Software-Updates (winget)' {
        # winget nur aus dem signierten App-Installationsprogramm unter Program Files\WindowsApps, nie über PATH (2.3.3)
        if (-not $script:PfadLib) { Add-Finding SKIP 'winget nicht geprüft: gui\lib\Systempfade.ps1 fehlt'; return }
        if (-not $script:WingetLib) { Add-Finding SKIP 'gui\lib\Winget.ps1 fehlt'; return }
        $wgInfo = Get-MorpheusWinget
        if (-not $wgInfo.Pfad) { Add-Finding SKIP ('winget nicht gefunden: ' + $wgInfo.Grund) 'Morpheus startet winget nur aus dem signierten App-Installationsprogramm unter C:\Program Files\WindowsApps, nie über PATH. Abhilfe: App-Installer im Microsoft Store aktualisieren.'; return }
        $wu = Get-MorpheusWingetUpdates -InformationAction SilentlyContinue
        switch ($wu.status) {
            'zeitlimit' { Add-Finding SKIP 'winget hat nicht innerhalb von 3 Minuten geantwortet'; return }
            'fehler' { Add-Finding SKIP ('winget-Abfrage fehlgeschlagen: ' + $wu.fehler); return }
            'unlesbar' { Add-Finding SKIP $wu.fehler; return }
            'keine' { Add-Finding OK 'Alle über winget erkannten Programme aktuell'; return }
        }
        $rows = @($wu.zeilen)
        $script:WingetUpdates = $rows
        Add-Table 'Verfügbare Software-Updates (winget)' $rows
        $manual = @($rows | Where-Object Kategorie -EQ 'Programm')
        $other = @($rows | Where-Object Kategorie -NE 'Programm')
        if ($manual.Count) { Add-Finding WARN "$($manual.Count) Programme mit verfügbaren Updates: $((($manual | Select-Object -First 8 | ForEach-Object Name) -join ', '))" 'In Morpheus unter Werkzeuge > Programme aktualisieren auswählen und installieren (oder am Ende des Konsolen-Laufs).' }
        elseif ($other.Count) { Add-Finding INFO "Nur Spiele/Launcher bzw. selbstaktualisierende Programme offen ($($other.Count)): $((($other | ForEach-Object Name) -join ', '))" 'Aktualisieren sich beim nächsten Start selbst.' }
        else { Add-Finding OK 'Alle über winget erkannten Programme aktuell' }
    }
}

#endregion

#region Sicherheit: Ereignisse

Start-Section 'Sicherheit' 'Ereignisse'

$script:LocalAddressPattern = '^(-|::1|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|fe80:|::ffff:(127|10|192\.168)\.|0\.0\.0\.0|$)'

Invoke-Check 'Fehlgeschlagene Anmeldungen' -NeedsAdmin {
    $ev = @(Get-RecentEvents @{ LogName = 'Security'; Id = 4625 } -Max 2000)
    $rows = foreach ($e in $ev) {
        $d = Get-EventData $e
        [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Konto = "$($d['TargetDomainName'])\$($d['TargetUserName'])"; Anmeldetyp = $d['LogonType']; Quelle = $d['IpAddress']; Prozess = $d['ProcessName']; Status = $d['SubStatus'] }
    }
    $rows = @($rows)
    Add-Table 'Fehlgeschlagene Anmeldungen' @($rows | Select-Object -First 100)
    $ext = @($rows | Where-Object { $_.Quelle -notmatch $script:LocalAddressPattern })
    # Anmeldetyp 3 = Netzwerk (Freigaben), 10 = Remotedesktop; 2/7/11 = Eingabe direkt am PC bzw. in einer App
    $net = @($rows | Where-Object { $_.Anmeldetyp -in '3', '10' })
    $local = @($rows | Where-Object { $_.Anmeldetyp -notin '3', '10' })
    $byProc = { param($list) ($list | Group-Object { if ($_.Prozess -and $_.Prozess -ne '-') { [IO.Path]::GetFileName($_.Prozess) } else { "Konto $($_.Konto)" } } | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ', ' }
    if ($ext) { Add-Finding CRIT ("$($ext.Count) Fehlversuche von externen Adressen: " + (($ext | ForEach-Object Quelle | Select-Object -Unique -First 5) -join ', ')) 'Prüfen, welcher Dienst aus dem Internet erreichbar ist (RDP/SMB/SSH) und Router-Portweiterleitungen schließen.' }
    elseif ($net.Count -gt 20) { Add-Finding WARN "$($net.Count) Fehlversuche über das Netzwerk in $EventDays Tagen: $(& $byProc $net)" 'Ursache prüfen (gespeichertes altes Kennwort auf einem anderen Gerät, z. B. NAS-Verbindung, oder Angriff im lokalen Netz).' }
    elseif ($net) { Add-Finding INFO ("$($net.Count) Fehlversuche über das Netzwerk: $(& $byProc $net)" + $(if ($local) { "; außerdem $($local.Count) lokale Fehleingaben" } else { '' })) }
    elseif ($local) { Add-Finding OK "Keine übers Netzwerk; $($local.Count) lokale Fehleingaben (Kennwort/PIN am PC oder in einer App: $(& $byProc $local))" }
    else { Add-Finding OK "Keine in $EventDays Tagen" }
}

Invoke-Check 'Netzwerk- und RDP-Anmeldungen' -NeedsAdmin {
    $ms = [int64]((Get-Date) - $script:Since).TotalMilliseconds
    $query = {
        param($type, $max)
        $xp = "*[System[(EventID=4624) and TimeCreated[timediff(@SystemTime) <= $ms]] and EventData[Data[@Name='LogonType']='$type']]"
        try { Get-WinEvent -LogName Security -FilterXPath $xp -MaxEvents $max -ErrorAction Stop }
        catch { if ($_.FullyQualifiedErrorId -notmatch '^NoMatchingEventsFound') { throw } }
    }
    $rdp = @(& $query 10 500)
    $net = @(& $query 3 3000)
    $toRow = { param($e) $d = Get-EventData $e; [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Typ = $d['LogonType']; Konto = "$($d['TargetDomainName'])\$($d['TargetUserName'])"; Quelle = $d['IpAddress'] } }
    $rdpRows = @($rdp | ForEach-Object { & $toRow $_ })
    $extRows = @($net | ForEach-Object { & $toRow $_ } | Where-Object { $_.Quelle -notmatch $script:LocalAddressPattern })
    Add-Table 'Remote-Anmeldungen (RDP und externe Netzwerkanmeldungen)' @($rdpRows + $extRows | Select-Object -First 100)
    if ($extRows) { Add-Finding CRIT ("$($extRows.Count) Netzwerkanmeldungen von externen Adressen: " + (($extRows | ForEach-Object Quelle | Select-Object -Unique -First 5) -join ', ')) 'Sofort prüfen, wer sich angemeldet hat; Kennwort ändern, Portweiterleitungen schließen.' }
    elseif ($rdpRows) { Add-Finding WARN ("$($rdpRows.Count) RDP-Anmeldungen von: " + (($rdpRows | ForEach-Object Quelle | Select-Object -Unique) -join ', ')) 'Prüfen, ob diese Anmeldungen von dir stammen; unbekannte Quellen sind ein starkes Warnzeichen.' }
    else { Add-Finding OK 'Keine RDP- oder externen Netzwerkanmeldungen' }
}

Invoke-Check 'Konto- und Gruppenänderungen' -NeedsAdmin {
    $names = @{ 4720 = 'Konto erstellt'; 4722 = 'Konto aktiviert'; 4724 = 'Kennwort zurückgesetzt'; 4726 = 'Konto gelöscht'; 4728 = 'Zu globaler Gruppe hinzugefügt'; 4732 = 'Zu lokaler Gruppe hinzugefügt'; 4738 = 'Konto geändert'; 4756 = 'Zu universeller Gruppe hinzugefügt'; 4781 = 'Konto umbenannt' }
    $ev = @(Get-RecentEvents @{ LogName = 'Security'; Id = [int[]]$names.Keys } -Max 300)
    $rows = foreach ($e in $ev) {
        $d = Get-EventData $e
        $member = $d['MemberName']
        if ((-not $member -or $member -eq '-') -and $d['MemberSid']) {
            try { $member = ([Security.Principal.SecurityIdentifier]$d['MemberSid']).Translate([Security.Principal.NTAccount]).Value } catch { $member = $d['MemberSid'] }
        }
        [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Ereignis = $names[$e.Id]; Ziel = $d['TargetUserName']; Mitglied = $member; Durch = $d['SubjectUserName'] }
    }
    $rows = @($rows)
    Add-Table 'Konto- und Gruppenänderungen' $rows
    $groupAdds = @($rows | Where-Object { $_.Ereignis -like 'Zu *' })
    # "Konto geändert" durch das Computerkonto (Name endet auf $) macht Windows selbst, z. B. beim Abgleich mit dem Microsoft-Konto
    $routine = @($rows | Where-Object { $_.Ereignis -eq 'Konto geändert' -and $_.Durch -match '\$$' })
    $other = @($rows | Where-Object { $_ -notin $routine })
    $otherText = ($other | Group-Object Ereignis | ForEach-Object { "$($_.Count)x $($_.Name)" }) -join ', '
    if ($groupAdds) { Add-Finding WARN ('Gruppenmitgliedschaften geändert: ' + (($groupAdds | ForEach-Object { "$($_.Mitglied) -> $($_.Ziel)" }) -join '; ')) 'Prüfen, ob du das selbst warst (z. B. durch eine Software-Installation).' }
    elseif ($other) { Add-Finding INFO ("$otherText (Anhang)" + $(if ($routine) { "; dazu $($routine.Count) Routine-Änderungen durch Windows" } else { '' })) 'Prüfen, ob du die Konten selbst angelegt, gelöscht oder geändert hast (auch Programme legen eigene Konten an).' }
    elseif ($routine) { Add-Finding OK "Nur $($routine.Count) Routine-Änderungen durch Windows selbst" }
    else { Add-Finding OK "Keine in $EventDays Tagen" }
}

Invoke-Check 'Gelöschte Ereignisprotokolle' {
    $ev = @(Get-RecentEvents @{ LogName = 'System'; Id = 104; ProviderName = 'Microsoft-Windows-Eventlog' })
    if ($script:IsAdmin) { $ev += @(Get-RecentEvents @{ LogName = 'Security'; Id = 1102 }) }
    if ($ev) { Add-Finding WARN ("$($ev.Count)x geleert, zuletzt $(Format-Date ($ev | Sort-Object TimeCreated | Select-Object -Last 1).TimeCreated)") 'Wenn nicht von dir oder einem Aufräum-Tool: Angreifer verwischen so ihre Spuren.' }
    else { Add-Finding OK "Nicht geleert in $EventDays Tagen" }
}

Invoke-Check 'Neu installierte Dienste' {
    $ev = @(Get-RecentEvents @{ LogName = 'System'; Id = 7045; ProviderName = 'Service Control Manager' } -Max 500)
    # Je Dienst eine Zeile: Manche Programme (z. B. NVIDIA FrameView) installieren ihren Treiber bei jedem Start neu
    $rows = @($ev | Group-Object { (Get-EventData $_)['ServiceName'] } | ForEach-Object {
            $d = Get-EventData $_.Group[0]
            $sig = Get-FileSignatureInfo (Get-ExePath $d['ImagePath'])
            [pscustomobject][ordered]@{ Zuletzt = Format-Date $_.Group[0].TimeCreated; Dienst = $_.Name; Anzahl = $_.Count; Signatur = $sig.Status; Signierer = $sig.Signer; Datei = $d['ImagePath'] }
        } | Sort-Object Zuletzt -Descending)
    Add-Table 'Neu installierte Dienste' $rows
    $bad = @($rows | Where-Object { $_.Signatur -notin 'Valid', 'Datei fehlt' })
    $signers = ($rows | Where-Object Signierer | Group-Object Signierer | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object Name) -join ', '
    $value = "$($rows.Count) Dienste ($($ev.Count) Installationen), alle gültig signiert" + $(if ($signers) { " ($signers …)" } else { '' })
    if ($bad) { Add-Finding WARN ('Neue Dienste ohne gültige Signatur: ' + (($bad | ForEach-Object Dienst) -join ', ')) 'Herkunft prüfen (Pfad im Anhang).' }
    elseif ($rows) { Add-Finding OK $value }
    else { Add-Finding OK "Keine in $EventDays Tagen" }
}

Invoke-Check 'Defender-Ereignisse' {
    $log = 'Microsoft-Windows-Windows Defender/Operational'
    $det = @(Get-RecentEvents @{ LogName = $log; Id = 1116, 1117 } -Max 200)
    $off = @(Get-RecentEvents @{ LogName = $log; Id = 5001, 5010, 5012 } -Max 50)
    $cfg = @(Get-RecentEvents @{ LogName = $log; Id = 5007 } -Max 300)
    $exclAdded = @($cfg | Where-Object { (Get-EventData $_)['New Value'] -match 'Exclusions' })
    $rows = foreach ($e in $det) {
        $d = Get-EventData $e
        [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Ereignis = $e.Id; Bedrohung = $d['Threat Name']; Pfad = $d['Path']; Aktion = $d['Action Name'] }
    }
    Add-Table 'Defender-Ereignisse: Erkennungen' $rows
    $issues = @()
    if ($off) { $issues += "Schutz $($off.Count)x abgeschaltet" }
    if ($exclAdded) { $issues += "Ausnahmen $($exclAdded.Count)x geändert" }
    if ($det) { $issues += "$($det.Count) Erkennungsereignisse: " + ((@($rows) | ForEach-Object Bedrohung | Select-Object -Unique -First 5) -join ', ') }
    if ($issues) { Add-Finding WARN ($issues -join '; ') 'Prüfen, ob du das selbst warst; Schadsoftware schaltet Defender gern ab oder trägt Ausnahmen ein.' }
    else { Add-Finding OK "Keine Erkennungen, Abschaltungen oder neuen Ausnahmen ($($cfg.Count) sonstige Konfigurationsänderungen)" }
}

Invoke-Check 'Auffällige PowerShell-Skripte' {
    # Ereignisse ab Script-Start stammen vom Prüflauf selbst (z. B. beim Laden der CIM-Module).
    $ev = @(Get-RecentEvents @{ LogName = 'Microsoft-Windows-PowerShell/Operational'; Id = 4104; Level = 3 } -Max 500 | Where-Object { $_.TimeCreated -lt $startedAt })
    $rows = foreach ($e in $ev) {
        $d = Get-EventData $e
        if ($d['Path'] -and $d['Path'] -eq $PSCommandPath) { continue }
        $text = ([string]$d['ScriptBlockText']) -replace '\s+', ' '
        # Automatisch generierte Wrapper der CIM-Module (NetSecurity, ScheduledTasks …) sind harmlos.
        if ($text -match '__cmdletization|Cmdletization\.MethodParameter|\$script:MyModule') { continue }
        if ($text -match $script:KnownHarmless.PowerShell) { continue }
        [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Pfad = $d['Path']; Auszug = $text.Substring(0, [Math]::Min(200, $text.Length)) }
    }
    $rows = @($rows)
    Add-Table 'Auffällige PowerShell-Skriptblöcke' @($rows | Select-Object -First 50)
    if ($rows) { Add-Finding INFO "$($rows.Count) Skriptblöcke von Windows als verdächtig protokolliert" 'Auszüge im Anhang prüfen; oft harmlos (Installer, Admin-Skripte).' }
    else { Add-Finding OK "Keine in $EventDays Tagen" }
}

Invoke-Check 'Neue Firewall-Regeln' {
    $ev = @(Get-RecentEvents @{ LogName = 'Microsoft-Windows-Windows Firewall With Advanced Security/Firewall'; Id = 2004, 2097 } -Max 300)
    $rows = foreach ($e in $ev) {
        $d = Get-EventData $e
        [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Regel = $d['RuleName']; Richtung = $(if ($d['Direction'] -eq '1') { 'Eingehend' } else { 'Ausgehend' }); Programm = $d['ApplicationPath']; Durch = $d['ModifyingApplication'] }
    }
    $rows = @($rows)
    Add-Table 'Neue Firewall-Regeln' @($rows | Select-Object -First 100)
    # Regeln, die der Windows-Firewalldienst (svchost) selbst anlegt, stammen von App-Installationen und -Updates aus dem Store bzw. von Windows
    $byWindows = @($rows | Where-Object { [string]$_.Durch -match '\\(svchost|MsMpEng)\.exe$' -or -not $_.Durch })
    $inbound = @($rows | Where-Object { $_.Richtung -eq 'Eingehend' -and $_ -notin $byWindows })
    $tools = ($inbound | ForEach-Object { [IO.Path]::GetFileName([string]$_.Durch) } | Select-Object -Unique -First 5) -join ', '
    if ($inbound) { Add-Finding INFO "$($inbound.Count) neue eingehende Regeln durch Programme ($tools); dazu $($byWindows.Count) von Windows selbst" 'Prüfen, ob du die Programme kennst und die Regeln brauchst (Liste im Anhang).' }
    elseif ($rows) { Add-Finding OK "$($rows.Count) neue Regeln, alle von Windows selbst (App-Installationen und -Updates)" }
    else { Add-Finding OK "Keine neuen eingehenden Regeln in $EventDays Tagen" }
}

Invoke-Check 'Blockierte Treiber/Dateien (Code Integrity)' {
    $ev = @(Get-RecentEvents @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3033, 3077 } -Max 300)
    $rows = @($ev | Group-Object { (([string]$_.Message) -split "`n")[0].Trim() } | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object {
            [pscustomobject][ordered]@{ Anzahl = $_.Count; Einordnung = $(if ($_.Name -match $script:KnownHarmless.CodeIntegrity) { 'bekannt harmlos (Overlay-/Aufnahme-DLL)' } else { '' }); Meldung = $_.Name }
        })
    Add-Table 'Code Integrity: blockierte Dateien' $rows
    $unknown = @($rows | Where-Object { -not $_.Einordnung })
    $unknownCount = ($unknown | Measure-Object Anzahl -Sum).Sum
    if ($unknown) { Add-Finding INFO "$unknownCount Blockierungen ungeklärter Herkunft (insgesamt $($ev.Count))" 'Meist harmlos (z. B. nicht signierte DLLs in Spielen); bei Treibern prüfen, welches Tool betroffen ist (Anhang).' }
    elseif ($ev) { Add-Finding OK "$($ev.Count) Blockierungen, alle bekannt harmlos (Overlay-/Aufnahme-DLLs, die Windows aus Systemprozessen fernhält)" }
    else { Add-Finding OK "Keine in $EventDays Tagen" }
}

#endregion

#region Performance: Hardware

Start-Section 'Performance' 'Hardware'

Invoke-Check 'Prozessor' {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $maxPerf = 0
    for ($i = 0; $i -lt 3; $i++) {
        $pi = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'"
        $maxPerf = [Math]::Max($maxPerf, [int]$pi.PercentProcessorPerformance)
        Start-Sleep -Milliseconds 300
    }
    $mhz = [int]($cpu.MaxClockSpeed * $maxPerf / 100)
    Add-Finding INFO "$($cpu.Name.Trim()): $($cpu.NumberOfCores) Kerne / $($cpu.NumberOfLogicalProcessors) Threads, Basistakt $($cpu.MaxClockSpeed) MHz, gemessen bis $mhz MHz"
}

Invoke-Check 'Arbeitsspeicher' {
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $rows = foreach ($m in $mods) {
        [pscustomobject][ordered]@{ Steckplatz = $m.DeviceLocator; Bank = $m.BankLabel; Groesse = Format-Size $m.Capacity; SpezTakt = $m.Speed; AktTakt = $m.ConfiguredClockSpeed; Hersteller = $m.Manufacturer; Modell = ([string]$m.PartNumber).Trim() }
    }
    Add-Table 'RAM-Module' $rows
    $total = ($mods | Measure-Object Capacity -Sum).Sum
    $cfg = ($mods | Measure-Object ConfiguredClockSpeed -Minimum).Minimum
    $channels = @($mods | ForEach-Object { if ("$($_.DeviceLocator)" -match 'Channel\s*([A-D])') { $Matches[1] } } | Select-Object -Unique)
    $value = "$(Format-Size $total) in $($mods.Count) Modulen, $cfg MT/s" + $(if ($channels) { ", Kanäle: $($channels -join ', ')" } else { '' })
    if ($mods.Count -eq 1) { Add-Finding WARN "$value (Single-Channel)" 'Ein zweites, gleiches Modul aktiviert Dual-Channel; das bringt in CPU-lastigen Spielen deutlich mehr FPS.' }
    elseif ($channels.Count -eq 1) { Add-Finding WARN "$value (beide Module im selben Kanal)" 'Module laut Handbuch in A2 und B2 stecken.' }
    elseif ($cfg -le 2133) { Add-Finding WARN "$value (JEDEC-Standardtakt)" 'XMP-Profil im BIOS aktivieren.' }
    elseif ($cfg -le 2666) { Add-Finding INFO "$value (Intel-Spezifikation)" 'Wenn das Kit mehr kann (Modellnummer/Aufkleber), XMP aktivieren.' }
    else { Add-Finding OK "$value (XMP/OC aktiv)" }
}

Invoke-Check 'Grafikkarte und Treiber' {
    $gpus = @(Get-CimInstance Win32_VideoController)
    $rows = foreach ($g in $gpus) {
        $nv = ''
        if ($g.Name -match 'NVIDIA' -and $g.DriverVersion -match '^\d+\.\d+\.(\d+)\.(\d+)$') { $digits = $Matches[1] + $Matches[2]; $nv = $digits.Substring($digits.Length - 5).Insert(3, '.') }
        [pscustomobject][ordered]@{ Name = $g.Name; Treiber = $g.DriverVersion; NvidiaVersion = $nv; Datum = Format-Date $g.DriverDate; Aufloesung = "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)"; Hz = $g.CurrentRefreshRate; Status = $g.Status }
    }
    Add-Table 'Grafikkarten' $rows
    $dgpu = @($gpus | Where-Object { $_.Name -match 'NVIDIA|AMD|Radeon|Arc' })
    if (-not $dgpu) { Add-Finding INFO ('Nur integrierte Grafik: ' + (($gpus | ForEach-Object Name) -join ', ')); return }
    foreach ($g in $dgpu) {
        $age = ((Get-Date) - $g.DriverDate).Days
        $row = $rows | Where-Object Name -EQ $g.Name | Select-Object -First 1
        $value = "$($g.Name), Treiber $(if ($row.NvidiaVersion) { $row.NvidiaVersion } else { $g.DriverVersion }) vom $((Get-Date $g.DriverDate).ToString('yyyy-MM-dd')) ($age Tage)"
        if ($age -gt 180) { Add-Finding WARN $value 'Aktuellen Treiber direkt vom Hersteller installieren (Spieleoptimierungen und Sicherheitsfixes).' }
        elseif ($age -gt 90) { Add-Finding INFO $value 'Neuere Treiberversion prüfen.' }
        else { Add-Finding OK $value }
    }
}

Invoke-Check 'Bildschirme und Bildwiederholrate' {
    if (-not ('PcCheckDisplay' -as [type])) { Add-Type -TypeDefinition $displayCode -Language CSharp }
    $mons = @([PcCheckDisplay]::Get())
    $names = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue | ForEach-Object { -join (@($_.UserFriendlyName) | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ }) })
    $rows = foreach ($m in $mons) {
        [pscustomobject][ordered]@{ Anzeige = $m.Device; Grafik = $m.Adapter; Monitor = $m.Monitor; Aufloesung = "$($m.Width)x$($m.Height)"; AktuellHz = $m.Hz; MaxHzBeiAufloesung = $m.MaxHzAtResolution; MaxHz = $m.MaxHz }
    }
    Add-Table 'Bildschirme' $rows
    $slow = @($mons | Where-Object { $_.MaxHzAtResolution -gt $_.Hz + 1 })
    $nameText = if ($names) { ' (' + ($names -join ', ') + ')' } else { '' }
    if ($slow) { Add-Finding WARN ((($slow | ForEach-Object { "$($_.Device) ($($_.Width)x$($_.Height)) läuft mit $($_.Hz) Hz, kann $($_.MaxHzAtResolution) Hz" }) -join '; ') + $nameText) 'Einstellungen > System > Anzeige > Erweiterte Anzeige > Bildwiederholrate auf das Maximum stellen (bei Problemen DisplayPort-Kabel nutzen).' }
    else { Add-Finding OK ((($mons | ForEach-Object { "$($_.Width)x$($_.Height) @ $($_.Hz) Hz" }) -join '; ') + $nameText) }
}

Invoke-Check 'Geräte mit Problemen' {
    $bad = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
    $rows = foreach ($d in $bad) { [pscustomobject][ordered]@{ Geraet = $d.Name; Code = $d.ConfigManagerErrorCode; Klasse = $d.PNPClass; ID = $d.DeviceID } }
    Add-Table 'Geräte mit Problemen' $rows
    $real = @($bad | Where-Object { $_.ConfigManagerErrorCode -ne 22 })
    if ($real) { Add-Finding WARN (($real | ForEach-Object { "$($_.Name) (Code $($_.ConfigManagerErrorCode))" }) -join '; ') 'Im Geräte-Manager Treiber installieren oder aktualisieren.' }
    elseif ($bad) { Add-Finding INFO ("Deaktiviert: " + (($bad | ForEach-Object Name) -join ', ')) }
    else { Add-Finding OK 'Keine' }
}

Invoke-Check 'Wichtige Treiber' {
    $drv = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceClass -in 'DISPLAY', 'NET', 'SCSIADAPTER', 'HDC', 'MEDIA', 'SYSTEM', 'USB' -and $_.DeviceName -and $_.DriverProviderName -and $_.DriverProviderName -notmatch '^Microsoft' })
    $rows = @($drv | Sort-Object DeviceClass, DeviceName -Unique | ForEach-Object {
            [pscustomobject][ordered]@{ Klasse = $_.DeviceClass; Geraet = $_.DeviceName; Version = $_.DriverVersion; Datum = $(if ($_.DriverDate) { (Get-Date $_.DriverDate).ToString('yyyy-MM-dd') } else { '' }); Anbieter = $_.DriverProviderName }
        })
    Add-Table 'Herstellertreiber' $rows
    $me = $rows | Where-Object { $_.Geraet -match 'Management Engine|MEI' } | Select-Object -First 1
    $meText = if ($me) { "; Intel ME-Treiber $($me.Version) vom $($me.Datum)" } else { '' }
    Add-Finding INFO "$($rows.Count) Herstellertreiber (Anhang)$meText" 'Chipsatz-, Netzwerk- und Audiotreiber gelegentlich mit der Supportseite des Mainboard- bzw. PC-Herstellers abgleichen.'
}

#endregion

#region Performance: Laufwerke & Speicherplatz

Start-Section 'Performance' 'Laufwerke & Speicherplatz'

Invoke-Check 'Laufwerke (Typ und Zustand)' {
    $sysNum = $null
    try { $sysNum = (Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') | Get-Disk).Number } catch {}
    $pd = @(Get-PhysicalDisk)
    $rows = foreach ($d in $pd) {
        $rel = $null
        if ($script:IsAdmin) { try { $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {} }
        [pscustomobject][ordered]@{
            Nr          = $d.DeviceId
            Name        = $d.FriendlyName
            Typ         = [string]$d.MediaType
            Bus         = [string]$d.BusType
            Groesse     = Format-Size $d.Size
            Zustand     = [string]$d.HealthStatus
            System      = ([string]$d.DeviceId -eq [string]$sysNum)
            Temperatur  = $rel.Temperature
            Verschleiss = $rel.Wear
            Stunden     = $rel.PowerOnHours
            Lesefehler  = $rel.ReadErrorsUncorrected
        }
    }
    $rows = @($rows)
    Add-Table 'Physische Laufwerke' $rows
    $sys = $rows | Where-Object System | Select-Object -First 1
    $unhealthy = @($rows | Where-Object { $_.Zustand -ne 'Healthy' })
    $worn = @($rows | Where-Object { $_.Verschleiss -ge 80 })
    $hdds = @($rows | Where-Object Typ -EQ 'HDD')
    if ($unhealthy) { Add-Finding CRIT ('Laufwerk meldet Fehler: ' + (($unhealthy | ForEach-Object { "$($_.Name) ($($_.Zustand))" }) -join ', ')) 'Sofort Datensicherung machen und Laufwerk ersetzen.' }
    elseif ($worn) { Add-Finding WARN ('Hoher Verschleiß: ' + (($worn | ForEach-Object { "$($_.Name) $($_.Verschleiss) %" }) -join ', ')) 'Austausch einplanen, Datensicherung aktuell halten.' }
    elseif ($sys.Typ -eq 'HDD') { Add-Finding CRIT "Windows liegt auf einer Festplatte (HDD): $($sys.Name)" 'Größter Leistungshebel überhaupt: Windows auf eine SSD/NVMe umziehen.' }
    elseif ($sys.Bus -eq 'SATA') { Add-Finding INFO "Windows auf SATA-SSD: $($sys.Name)" 'NVMe im M.2-Slot lädt schneller; im Spielealltag meist kaum spürbar.' }
    else { Add-Finding OK ("Windows auf $($sys.Bus)-$($sys.Typ): $($sys.Name)" + $(if ($hdds) { "; HDDs: $(($hdds | ForEach-Object Name) -join ', ')" } else { '' })) }
    if ($hdds -and $sys.Typ -ne 'HDD') { Add-Finding INFO ('Festplatten im System: ' + (($hdds | ForEach-Object Name) -join ', ')) 'Spiele von HDD laden deutlich langsamer und können beim Nachladen ruckeln; HDDs eher für Daten/Backups nutzen.' -Check 'Festplatten (HDD)' }
}

Invoke-Check 'Freier Speicherplatz' {
    $vols = @(Get-Volume | Where-Object { $_.DriveLetter -and [string]$_.DriveType -eq 'Fixed' -and $_.Size -gt 0 })
    $rows = foreach ($v in $vols) {
        [pscustomobject][ordered]@{ Laufwerk = "$($v.DriveLetter):"; Name = $v.FileSystemLabel; Dateisystem = $v.FileSystem; Groesse = Format-Size $v.Size; Frei = Format-Size $v.SizeRemaining; FreiProzent = [int](100 * $v.SizeRemaining / $v.Size) }
    }
    $rows = @($rows)
    Add-Table 'Laufwerke (Volumes)' $rows
    $sys = $rows | Where-Object Laufwerk -EQ $env:SystemDrive
    $low = @($rows | Where-Object { $_.FreiProzent -lt 10 -and $_.Laufwerk -ne $env:SystemDrive })
    $summary = ($rows | ForEach-Object { "$($_.Laufwerk) $($_.FreiProzent) % frei" }) -join ', '
    if ($sys.FreiProzent -lt 10) { Add-Finding CRIT $summary 'Auf C: Platz schaffen: Windows und SSDs werden mit wenig freiem Platz langsamer, Updates scheitern.' }
    elseif ($sys.FreiProzent -lt 15 -or $low) { Add-Finding WARN $summary 'Mindestens 15–20 % frei lassen.' }
    else { Add-Finding OK $summary }
}

if ($SkipSpeicher) {
    $script:CheckName = 'Größte Speicherverbraucher'
    Add-Finding SKIP 'Übersprungen (-SkipSpeicher)'
}
else {
    Invoke-Check 'Größte Speicherverbraucher' {
        if (-not $script:SpeicherLib) { Add-Finding SKIP 'gui\lib\Speicher.ps1 fehlt'; return }
        $script:Speicher = Get-MorpheusSpeicher -Manuell $script:SpielOrdner -Fortschritt { param($Text) if ($Text -match '^[A-Z]: |^Spiele') { Write-Host "      $Text" -ForegroundColor DarkGray } }
        $ordnerRows = New-Object System.Collections.Generic.List[object]
        $dateiRows = New-Object System.Collections.Generic.List[object]
        $parts = New-Object System.Collections.Generic.List[string]
        $skipped = 0
        foreach ($d in @($script:Speicher.laufwerke)) {
            if ($d.fehler) { $parts.Add("$($d.laufwerk) nicht lesbar"); continue }
            $skipped += [int]$d.uebersprungen
            foreach ($o in @($d.ordner)) {
                $ordnerRows.Add([pscustomobject][ordered]@{ Laufwerk = $d.laufwerk; Pfad = $o.pfad; Groesse = Format-Size ([double]$o.bytes); Bytes = [double]$o.bytes })
            }
            foreach ($f in @($d.dateien)) {
                $dateiRows.Add([pscustomobject][ordered]@{ Laufwerk = $d.laufwerk; Pfad = $f.pfad; Groesse = Format-Size ([double]$f.bytes); Bytes = [double]$f.bytes; Windows = [bool]$f.windows })
            }
            $top = @($d.ordner) | Select-Object -First 1
            if ($top) { $parts.Add("$($d.laufwerk) $($top.pfad) ($(Format-Size ([double]$top.bytes)))") }
        }
        Add-Table 'Speicherverbraucher: Ordner' $ordnerRows.ToArray()
        Add-Table 'Speicherverbraucher: Dateien' $dateiRows.ToArray()
        $value = $parts -join '; '
        if ($skipped -gt 0) { $value += " ($skipped Ordner ohne Zugriff übersprungen)" }
        Add-Finding INFO $value 'Die größten Ordner und Dateien je Laufwerk stehen in der GUI beim Laufwerk in der Statusleiste und im Anhang. Systemdateien wie pagefile.sys nicht löschen.'
    }
}

Invoke-Check 'TRIM und Laufwerksoptimierung' {
    $out = (Invoke-Native "$script:Sys32\fsutil.exe" @('behavior', 'query', 'DisableDeleteNotify')) -join ' '
    $trim = if ($out -match 'NTFS DisableDeleteNotify\s*=\s*(\d)') { [int]$Matches[1] } else { $null }
    $task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue
    $last = if ($task) { (Get-ScheduledTaskInfo -InputObject $task -ErrorAction SilentlyContinue).LastRunTime } else { $null }
    $value = 'TRIM ' + $(switch ($trim) { 0 { 'an' } 1 { 'aus' } default { 'unbekannt' } }) + '; geplante Optimierung ' + $(if ($task) { [string]$task.State } else { 'nicht gefunden' }) + $(if ($last) { ", zuletzt $(Format-Date $last)" } else { '' })
    if ($trim -eq 1) { Add-Finding WARN $value 'TRIM einschalten: fsutil behavior set DisableDeleteNotify 0 (Admin).' }
    elseif ($task -and [string]$task.State -eq 'Disabled') { Add-Finding WARN $value 'SSDs brauchen den regelmäßigen ReTrim: "Laufwerke optimieren" > geplante Optimierung einschalten.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Auslagerungsdatei' {
    $use = @(Get-CimInstance Win32_PageFileUsage)
    $mode = if ($script:CS.AutomaticManagedPagefile) { 'systemverwaltet' } else { 'manuell' }
    if (-not $use) { Add-Finding WARN 'Keine Auslagerungsdatei' 'Systemverwaltete Größe wieder einschalten: Ohne Auslagerungsdatei stürzen Spiele und IDEs bei vollem RAM ab, statt nur langsamer zu werden.'; return }
    $value = "$mode; " + (($use | ForEach-Object { "$($_.Name) $($_.AllocatedBaseSize) MB, Spitze $($_.PeakUsage) MB" }) -join '; ')
    $tight = @($use | Where-Object { $_.PeakUsage -gt 0.8 * $_.AllocatedBaseSize })
    if ($tight -and -not $script:CS.AutomaticManagedPagefile) { Add-Finding WARN $value 'Auslagerungsdatei war fast voll: auf "systemverwaltet" stellen.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Schnellstart und Ruhezustand' {
    $hb = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
    $hib = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
    $hf = Get-Item -LiteralPath "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction SilentlyContinue
    $value = 'Schnellstart ' + $(if ($hb -eq 1) { 'an' } else { 'aus' }) + '; Ruhezustand ' + $(if ($hib -eq 0) { 'aus' } else { 'an' }) + $(if ($hf) { "; hiberfil.sys $(Format-Size $hf.Length)" } else { '' })
    if ($hb -eq 1) { Add-Finding INFO $value 'Mit NVMe spart der Schnellstart kaum Zeit, aber "Herunterfahren" ist dann kein echter Neustart (Treiber, Updates und BIOS/OC-Änderungen greifen erst nach "Neu starten"). Bei Problemen ausschalten.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Temporäre Dateien und Caches' {
    $targets = [ordered]@{
        'Benutzer-Temp'              = $script:BenutzerTemp
        'Windows-Temp'               = "$env:SystemRoot\Temp"
        'Update-Downloads'           = "$env:SystemRoot\SoftwareDistribution\Download"
        'Absturzabbilder (Programme)' = "$env:LOCALAPPDATA\CrashDumps"
        'Minidumps (Bluescreens)'    = "$env:SystemRoot\Minidump"
        'Shader-Cache DirectX'       = "$env:LOCALAPPDATA\D3DSCache"
        'Shader-Cache NVIDIA'        = "$env:LOCALAPPDATA\NVIDIA\DXCache"
    }
    $rows = foreach ($k in $targets.Keys) {
        $s = Get-FolderSize $targets[$k]
        if ($s) { [pscustomobject][ordered]@{ Ort = $k; Groesse = Format-Size $s.Bytes; Bytes = $s.Bytes; Dateien = $s.Files; Pfad = $targets[$k] } }
    }
    $dump = Get-Item -LiteralPath "$env:SystemRoot\MEMORY.DMP" -Force -ErrorAction SilentlyContinue
    if ($dump) { $rows = @($rows) + [pscustomobject][ordered]@{ Ort = 'Speicherabbild MEMORY.DMP'; Groesse = Format-Size $dump.Length; Bytes = [double]$dump.Length; Dateien = 1; Pfad = $dump.FullName } }
    $rows = @($rows)
    Add-Table 'Temporäre Dateien und Caches' @($rows | Select-Object Ort, Groesse, Dateien, Pfad)
    $junk = ($rows | Where-Object { $_.Ort -notlike 'Shader*' } | Measure-Object Bytes -Sum).Sum
    $sense = (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01') -eq 1
    $value = "Aufräumbar ca. $(Format-Size $junk); Speicheroptimierung " + $(if ($sense) { 'an' } else { 'aus' })
    if ($junk -gt 5GB) { Add-Finding INFO $value 'Datenträgerbereinigung bzw. Einstellungen > System > Speicher > Bereinigungsempfehlungen nutzen. Shader-Caches nicht löschen (sonst Ruckler beim nächsten Spielstart).' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Dev Drive (Entwicklung)' {
    $refs = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'ReFS' })
    if ($refs) {
        $detail = foreach ($v in $refs) { "$($v.DriveLetter): " + (((Invoke-Native "$script:Sys32\fsutil.exe" @('devdrv', 'query', "$($v.DriveLetter):")) | Where-Object { $_.Trim() } | Select-Object -First 1)) }
        Add-Finding OK ('ReFS-Volumes: ' + ($detail -join '; '))
    }
    else {
        # Nur relevant, wenn auf dem PC entwickelt wird
        # Nur nachsehen, ob die Programme im PATH des Benutzers liegen; gestartet wird nichts (PATH des Prozesses ist begrenzt)
        $devOrdner = @(([string]$script:BenutzerPath) -split ';' | Where-Object { $_.Trim() })
        $dev = @('git.exe', 'node.exe', 'python.exe', 'dotnet.exe', 'cargo.exe', 'go.exe', 'java.exe' | Where-Object {
                $n = $_
                foreach ($d in $devOrdner) { try { if ([IO.File]::Exists([IO.Path]::Combine($d.Trim(), $n))) { return $true } } catch { } }
                $false
            } | ForEach-Object { $_ -replace '\.exe$' })
        if ($dev) { Add-Finding INFO "Kein Dev Drive vorhanden (Entwicklungswerkzeuge gefunden: $($dev -join ', '))" 'Für Repos, node_modules und Build-Ordner ein Dev Drive anlegen (Einstellungen > System > Speicher > Datenträger und Volumes). ReFS plus Defender-Leistungsmodus beschleunigt git, npm und Builds spürbar, ohne den Virenschutz abzuschalten.' }
        else { Add-Finding OK 'Kein Dev Drive, keine Entwicklungswerkzeuge gefunden (nicht nötig)' }
    }
}

#endregion

#region Performance: Energie

Start-Section 'Performance' 'Energie'

Invoke-Check 'Energieplan' {
    $act = (Invoke-Native "$script:Sys32\powercfg.exe" @('/getactivescheme')) -join ' '
    $guid = if ($act -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $Matches[1].ToLower() }
    $name = if ($act -match '\(([^)]+)\)\s*\*?\s*$') { $Matches[1] } else { $guid }
    $plans = @((Invoke-Native "$script:Sys32\powercfg.exe" @('/list')) | Where-Object { $_ -match '[0-9a-fA-F]{8}-' } | ForEach-Object { [pscustomobject]@{ Plan = $_.Trim() } })
    Add-Table 'Energiepläne' $plans
    $highPerf = $guid -in '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c', 'e9a42b02-d5df-448d-aa00-03f14749eb61' -or $name -match 'Ultimat|High performance|Höchstleistung'
    if ($script:Profile -eq 'Laptop') {
        if ($highPerf) { Add-Finding WARN "Aktiv: $name" 'Auf einem Laptop leert "Höchstleistung" den Akku schnell und heizt das Gerät auf. "Ausbalanciert" wählen; für Spiele am Netzteil reicht der Energiemodus "Beste Leistung" (Einstellungen > System > Netzbetrieb und Akku).' }
        else { Add-Finding OK "Aktiv: $name" }
        return
    }
    switch ($guid) {
        'a1841308-3541-4fab-bc81-f71556f20b4a' { Add-Finding WARN "Aktiv: $name" 'Für einen Desktop "Ausbalanciert" oder einen Plan mit voller Leistung wählen; "Energiesparmodus" drosselt die CPU.' }
        '381b4222-f694-41f0-9685-ff5bb260df2e' { Add-Finding OK "Aktiv: $name (mit aktuellem Windows meist ausreichend)" }
        default { Add-Finding OK "Aktiv: $name" }
    }
}

Invoke-Check 'Prozessor-Energieeinstellungen' {
    $min = Get-PowerSetting SUB_PROCESSOR PROCTHROTTLEMIN
    $max = Get-PowerSetting SUB_PROCESSOR PROCTHROTTLEMAX
    $boost = Get-PowerSetting SUB_PROCESSOR PERFBOOSTMODE -Hidden
    $park = Get-PowerSetting SUB_PROCESSOR CPMINCORES -Hidden
    $boostNames = @{ 0 = 'deaktiviert'; 1 = 'aktiviert'; 2 = 'aggressiv'; 3 = 'effizient aktiviert'; 4 = 'effizient aggressiv'; 5 = 'aggressiv bei Garantie'; 6 = 'effizient aggressiv bei Garantie' }
    $value = "Netzbetrieb: min. $($min.AC) %, max. $($max.AC) %" + $(if ($boost) { ", Turbo-Modus $($boostNames[[int]$boost.AC])" } else { '' }) + $(if ($park) { ", Kernparken min. $($park.AC) %" } else { '' })
    if ($max -and $max.AC -lt 100) { Add-Finding WARN $value 'Maximalen Prozessorzustand im Energieplan auf 100 % setzen, sonst bremst Windows die CPU.' }
    elseif ($boost -and $boost.AC -eq 0) { Add-Finding WARN $value 'Turbo ist im Energieplan abgeschaltet: Prozessor-Leistungssteigerungsmodus auf "Aktiviert" stellen.' }
    elseif ($min -and $min.AC -ge 100 -and $script:Profile -eq 'Laptop') { Add-Finding WARN $value 'Mindestzustand 100 % hält die CPU dauerhaft auf vollem Takt: kostet Akku und Lautstärke. Einen Plan mit niedrigem Mindestzustand nutzen (z. B. "Ausbalanciert").' }
    elseif ($min -and $min.AC -ge 100) { Add-Finding INFO $value 'CPU taktet im Leerlauf nicht herunter: bringt im Spiel kaum etwas, erhöht aber Verbrauch und Temperatur. Besser: ein Plan, der unter Last voll taktet und im Leerlauf heruntertaktet (Anleitung unter „So geht''s“).' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Weitere Energiesparfunktionen' {
    $usb = Get-PowerSetting '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    $aspm = Get-PowerSetting SUB_PCIEXPRESS ASPM
    $sleep = Get-PowerSetting SUB_SLEEP STANDBYIDLE
    $aspmNames = @{ 0 = 'aus'; 1 = 'mittel'; 2 = 'maximal' }
    $value = 'USB-Energiesparen ' + $(if ($usb) { @{ 0 = 'aus'; 1 = 'an' }[[int]$usb.AC] } else { 'unbekannt' }) +
    '; PCIe-Verbindungsenergieverwaltung ' + $(if ($aspm) { $aspmNames[[int]$aspm.AC] } else { 'unbekannt' }) +
    '; Energiesparmodus nach ' + $(if ($sleep) { if ($sleep.AC -eq 0) { 'nie' } else { "$([int]($sleep.AC / 60)) Min." } } else { 'unbekannt' })
    if ($aspm -and $aspm.AC -eq 2) { Add-Finding INFO $value 'Maximale PCIe-Energieverwaltung kann bei manchen Grafikkarten/NVMe Mikroruckler verursachen; bei Problemen auf "aus" stellen.' }
    else { Add-Finding OK $value }
}

#endregion

#region Performance: Gaming & Grafik

Start-Section 'Performance' 'Gaming & Grafik'

Invoke-Check 'Spielmodus' {
    $gm = Get-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    if ($gm -eq 0) { Add-Finding INFO 'Aus' 'Einstellungen > Spielen > Spielmodus einschalten: priorisiert das Spiel und verhindert Update-Neustarts währenddessen.' }
    else { Add-Finding OK 'An' }
}

Invoke-Check 'Hardwarebeschleunigte GPU-Planung (HAGS)' {
    $h = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    switch ($h) {
        2 { Add-Finding OK 'An' }
        1 { Add-Finding INFO 'Aus' 'Mit aktueller NVIDIA-/AMD-Karte meist einschalten (Voraussetzung für DLSS Frame Generation); bei Rucklern testweise wieder aus.' }
        default { Add-Finding INFO 'Windows-Standard (nicht gesetzt)' 'Einstellungen > System > Anzeige > Grafik > Standardgrafikeinstellungen prüfen.' }
    }
}

Invoke-Check 'Hintergrundaufzeichnung (Game DVR)' {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'
    if ((Get-RegValue $k 'HistoricalCaptureEnabled') -eq 1) { Add-Finding WARN 'Läuft dauerhaft mit' 'Einstellungen > Spielen > Aufnahmen > "Aufzeichnen, was passiert ist" ausschalten, wenn nicht genutzt (kostet FPS und VRAM).' }
    else { Add-Finding OK 'Aus' }
}

Invoke-Check 'Optimierungen für Spiele im Fenstermodus' {
    $s = [string](Get-RegValue 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings')
    $swap = if ($s -match 'SwapEffectUpgradeEnable=(\d)') { $Matches[1] } else { $null }
    $vrr = if ($s -match 'VRROptimizeEnable=(\d)') { $Matches[1] } else { $null }
    $value = 'Fenstermodus-Optimierung ' + $(if ($swap -eq '0') { 'aus' } elseif ($swap -eq '1') { 'an' } else { 'Standard' }) + '; VRR-Optimierung ' + $(if ($vrr -eq '0') { 'aus' } elseif ($vrr -eq '1') { 'an' } else { 'Standard' })
    if ($swap -eq '0') { Add-Finding INFO $value 'Einstellungen > System > Anzeige > Grafik > Erweiterte Grafikeinstellungen: "Optimierungen für Spiele im Fenstermodus" einschalten (geringere Latenz in randlosen Fenstern).' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Mausbeschleunigung' {
    if ((Get-RegValue 'HKCU:\Control Panel\Mouse' 'MouseSpeed') -eq '1') { Add-Finding INFO 'Zeigerbeschleunigung an' 'Für Shooter meist aus ("Zeigerpräzision verbessern" deaktivieren), damit Mausbewegungen 1:1 umgesetzt werden.' }
    else { Add-Finding OK 'Aus' }
}

Invoke-Check 'Overlays und Hintergrund-Tools' {
    $patterns = [ordered]@{
        'Discord'                                    = '^Discord$'
        'Steam-Overlay'                              = '^GameOverlayUI'
        'NVIDIA App/Overlay'                         = '^(NVIDIA Overlay|NVIDIA app|nvcontainer)$'
        'MSI Afterburner/RTSS'                       = '^(MSIAfterburner|RTSS)$'
        'Xbox Game Bar'                              = '^(GameBar|XboxGameBarWidgets)$'
        'OBS'                                        = '^obs64$'
        'Gigabyte-Tools (RGB Fusion/EasyTune/SIV)'   = '(RGBFusion|EasyTune|SIV|AppCenter|GCC|AorusEngine|GigabyteControlCenter)'
        'Corsair iCUE'                               = '^iCUE'
        'Razer Synapse'                              = '^Razer'
        'Logitech G HUB'                             = '^lghub'
        'SignalRGB/OpenRGB'                          = '^(SignalRgb|OpenRGB)'
        'Overwolf'                                   = '^Overwolf'
        'Wallpaper Engine'                           = '^wallpaper(32|64)$'
    }
    $names = @(Get-Process | ForEach-Object ProcessName | Select-Object -Unique)
    $found = @($patterns.Keys | Where-Object { $pat = $patterns[$_]; $names | Where-Object { $_ -match $pat } })
    if ($found) { Add-Finding INFO ('Aktiv: ' + ($found -join ', ')) 'Jedes Overlay und RGB-Tool kostet etwas CPU und kann Frametime-Spitzen verursachen; nur behalten, was du wirklich nutzt.' }
    else { Add-Finding OK 'Keine bekannten Overlays/Tools aktiv' }
}

Invoke-Check 'Virtualisierung und Spieleleistung' {
    $dg = $script:DeviceGuard
    $vbsOn = $dg -and [int]$dg.VirtualizationBasedSecurityStatus -eq 2
    $hvci = $dg -and (@($dg.SecurityServicesRunning) -contains 2)
    $mbec = $dg -and (@($dg.AvailableSecurityProperties) -contains 7)
    $virt = @('Microsoft-Hyper-V-All', 'VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux', 'Containers-DisposableClientVM', 'HypervisorPlatform' | Where-Object { $_ -in $script:Features })
    $value = "Hypervisor aktiv: $($script:CS.HypervisorPresent); VBS: $(if ($vbsOn) { 'läuft' } else { 'aus' }); Speicherintegrität: $(if ($hvci) { 'an' } else { 'aus' }); MBEC: $(if ($mbec) { 'ja' } else { 'nein' })" + $(if ($virt) { '; Features: ' + ($virt -join ', ') } else { '' })
    Add-Finding INFO $value 'Speicherintegrität kostet auf CPUs mit MBEC (Intel ab 7. Generation, AMD ab Zen 2) typischerweise nur wenige Prozent FPS. Empfehlung: anlassen; nur für Benchmark-Vergleiche testweise aus. WSL2/Docker brauchen den Hypervisor ohnehin.'
}

Invoke-Check 'Resizable BAR und PCIe-Anbindung' {
    # nvidia-smi nur aus System32 bzw. Program Files, nie über PATH (2.3.3)
    $smi = $null
    foreach ($cand in @((Join-Path $script:Sys32 'nvidia-smi.exe'), (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'))) {
        if (Test-Path -LiteralPath $cand -PathType Leaf) { $smi = [pscustomobject]@{ Source = $cand }; break }
    }
    if (-not $smi) {
        if (Get-CimInstance Win32_VideoController | Where-Object Name -Match 'NVIDIA') { Add-Finding SKIP 'nvidia-smi nicht gefunden (wird mit dem NVIDIA-Treiber installiert)' }
        else { Add-Finding SKIP 'Nur bei NVIDIA-Grafikkarten auslesbar (AMD: Adrenalin > Leistung > Tuning > Smart Access Memory)' }
        return
    }
    $q = (Invoke-Native $smi.Source @('-q', '-i', '0')) -join "`n"
    $num = { param($pattern) if ($q -match $pattern) { [int]$Matches[1] } else { $null } }
    $gpuName = if ($q -match 'Product Name\s+:\s+(.+)') { $Matches[1].Trim() } else { 'NVIDIA-GPU' }
    $bar1 = & $num 'BAR1 Memory Usage\s+Total\s+:\s+(\d+)\s*MiB'
    $vram = & $num 'FB Memory Usage\s+Total\s+:\s+(\d+)\s*MiB'
    $genMax = & $num 'PCIe Generation\s+Max\s+:\s+(\d+)'
    $devMax = & $num 'Device Max\s+:\s+(\d+)'
    $hostMax = & $num 'Host Max\s+:\s+(\d+)'
    $width = & $num 'Link Width\s+Max\s+:\s+(\d+)x'
    if ($null -eq $bar1) { Add-Finding SKIP 'Ausgabe von nvidia-smi nicht auswertbar'; return }
    Add-Table 'Grafikkarte: Anbindung (nvidia-smi)' @([pscustomobject][ordered]@{ GPU = $gpuName; GrafikspeicherMiB = $vram; BAR1MiB = $bar1; PCIeGenMax = $genMax; KarteKann = $devMax; MainboardKann = $hostMax; Lanes = $width })
    # Ohne Resizable BAR ist das Fenster der CPU auf den Grafikspeicher 256 MiB groß, mit ReBAR so groß wie der Grafikspeicher
    $rebar = $bar1 -gt 1024
    $link = "PCIe $genMax.0 x$width" + $(if ($devMax -and $hostMax -and $devMax -gt $hostMax) { " (Karte kann $devMax.0, Mainboard $hostMax.0; kaum spürbar)" } else { '' })
    $value = "${gpuName}: Resizable BAR $(if ($rebar) { 'an' } else { 'aus' }) (Fenster $bar1 MiB); $link"
    if ($width -and $width -lt 16) { Add-Finding INFO $value "Die Karte läuft mit $width Lanes. Bei Karten, die nur x8 haben (z. B. RTX 4060/5060), ist das normal; sonst prüfen, ob sie im obersten x16-Steckplatz steckt und ob ein M.2-Laufwerk Lanes abzweigt (Handbuch)." }
    elseif (-not $rebar) { Add-Finding INFO $value 'Resizable BAR im BIOS einschalten: "Above 4G Decoding" und "Re-Size BAR Support" (CSM muss aus sein). Bringt je nach Spiel 0–10 % mehr FPS; fehlt die Option, ein BIOS-Update prüfen.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Spielebibliotheken' {
    # Tabelle der installierten Spiele zuerst, damit die frühen return der bisherigen Auswertung sie nicht verhindern
    $spiele = @()
    if ($script:Speicher) { $spiele = @($script:Speicher.spiele) }
    elseif ($script:SpeicherLib) {
        try { $spiele = @(Get-MorpheusSpiele -Manuell $script:SpielOrdner) } catch { $spiele = @() }
    }
    $spieleRows = foreach ($g in ($spiele | Where-Object { $null -ne $_ } | Sort-Object { [double]$_.bytes } -Descending)) {
        $zuletzt = ''
        if ($g.zuletztGespielt) { try { $zuletzt = ([datetime]$g.zuletztGespielt).ToString('yyyy-MM-dd HH:mm') } catch { $zuletzt = '' } }
        [pscustomobject][ordered]@{
            Plattform       = [string]$g.plattform
            Name            = [string]$g.name
            Laufwerk        = [string]$g.laufwerk
            Groesse         = Format-Size ([double]$g.bytes)
            Bytes           = [double]$g.bytes
            ZuletztGespielt = $zuletzt
            Pfad            = [string]$g.pfad
            Hinweis         = $(if ($g.groesseUnsicher) { 'Größe eingeschränkt lesbar' } else { '' })
        }
    }
    Add-Table 'Installierte Spiele' @($spieleRows)
    $libs = New-Object System.Collections.Generic.List[object]
    $addLib = { param($Launcher, $Path, $Games, $Bytes) if ($Path -and (Test-Path -LiteralPath $Path)) { $libs.Add([pscustomobject]@{ Launcher = $Launcher; Pfad = $Path; Spiele = $Games; Bytes = $Bytes }) } }
    # Steam: libraryfolders.vdf listet alle Bibliotheken, appmanifest_*.acf je Spiel mit Größe
    $steam = Get-RegValue 'HKCU:\Software\Valve\Steam' 'SteamPath'
    $vdf = if ($steam) { Join-Path ($steam -replace '/', '\') 'steamapps\libraryfolders.vdf' }
    if ($vdf -and (Test-Path -LiteralPath $vdf)) {
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $p = $m.Groups[1].Value -replace '\\\\', '\'
            $acf = @(Get-ChildItem -LiteralPath (Join-Path $p 'steamapps') -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue)
            $bytes = 0
            foreach ($a in $acf) { if ((Get-Content -LiteralPath $a.FullName -Raw) -match '"SizeOnDisk"\s+"(\d+)"') { $bytes += [double]$Matches[1] } }
            & $addLib 'Steam' $p $acf.Count $bytes
        }
    }
    # Epic: ein Manifest je Spiel
    $epic = @(Get-ChildItem -LiteralPath "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests" -Filter '*.item' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object InstallLocation)
    foreach ($g in ($epic | Group-Object { Split-Path -Parent $_.InstallLocation })) { & $addLib 'Epic' $g.Name $g.Count ([double]($g.Group | Measure-Object InstallSize -Sum).Sum) }
    # GOG und Ubisoft: Installationsordner je Spiel in der Registry
    $regGames = @(
        @{ Launcher = 'GOG'; Key = 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games\*'; Value = 'path' }
        @{ Launcher = 'Ubisoft'; Key = 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs\*'; Value = 'InstallDir' }
    )
    foreach ($r in $regGames) {
        $paths = @(Get-ItemProperty $r.Key -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.($r.Value) } | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') -replace '/', '\' })
        foreach ($g in ($paths | Group-Object { Split-Path -Parent $_ })) { & $addLib $r.Launcher $g.Name $g.Count 0 }
    }
    # Xbox-App: Laufwerke mit Spielebibliothek haben eine Datei .GamingRoot im Stammverzeichnis
    foreach ($v in @(Get-Volume | Where-Object { $_.DriveLetter -and [string]$_.DriveType -eq 'Fixed' })) {
        $root = "$($v.DriveLetter):\"
        if (Test-Path -LiteralPath (Join-Path $root '.GamingRoot')) {
            $dir = Join-Path $root 'XboxGames'
            & $addLib 'Xbox' $dir @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Where-Object Name -NE 'GameSave').Count 0
        }
    }
    if (-not $libs.Count) { Add-Finding OK 'Keine Spielebibliotheken gefunden (Steam, Epic, GOG, Ubisoft, Xbox)'; return }

    $vols = @{}
    Get-Volume | Where-Object DriveLetter | ForEach-Object { $vols[[string]$_.DriveLetter] = $_ }
    $rows = foreach ($l in $libs) {
        $letter = $l.Pfad.Substring(0, 1).ToUpper()
        $v = $vols[$letter]
        [pscustomobject][ordered]@{
            Launcher    = $l.Launcher
            Pfad        = $l.Pfad
            Laufwerk    = "${letter}:"
            Typ         = Get-DriveKind $letter
            Spiele      = $l.Spiele
            Groesse     = $(if ($l.Bytes) { Format-Size $l.Bytes } else { '' })
            FreiProzent = $(if ($v -and $v.Size) { [int](100 * $v.SizeRemaining / $v.Size) } else { $null })
            Frei        = $(if ($v) { Format-Size $v.SizeRemaining } else { '' })
        }
    }
    $rows = @($rows | Where-Object Spiele)
    Add-Table 'Spielebibliotheken' $rows
    if (-not $rows) { Add-Finding OK 'Spielebibliotheken gefunden, aber keine installierten Spiele'; return }
    $drives = @($rows | Group-Object Laufwerk | ForEach-Object {
            $f = $_.Group[0]
            [pscustomobject]@{ Laufwerk = $_.Name; Typ = $f.Typ; FreiProzent = $f.FreiProzent; Frei = $f.Frei; Spiele = ($_.Group | Measure-Object Spiele -Sum).Sum; Quellen = (($_.Group | Group-Object Launcher | ForEach-Object { "$($_.Name) $(($_.Group | Measure-Object Spiele -Sum).Sum)" }) -join ', ') }
        } | Sort-Object Spiele -Descending)
    $summary = ($drives | ForEach-Object { "$($_.Laufwerk) $($_.Typ), $($_.FreiProzent) % frei: $($_.Quellen)" }) -join '; '
    $hdd = @($drives | Where-Object Typ -EQ 'HDD')
    $full = @($drives | Where-Object { $null -ne $_.FreiProzent -and $_.FreiProzent -lt 20 })
    # Ziel für umzuziehende Spiele: SSD mit dem meisten freien Platz, NVMe bevorzugt
    $target = @(Get-Volume | Where-Object { $_.DriveLetter -and [string]$_.DriveType -eq 'Fixed' -and $_.Size -gt 100GB } | ForEach-Object {
            [pscustomobject]@{ Laufwerk = "$($_.DriveLetter):"; Typ = Get-DriveKind $_.DriveLetter; Frei = $_.SizeRemaining }
        } | Where-Object { $_.Typ -like '*SSD' -and $_.Laufwerk -notin $full.Laufwerk } | Sort-Object { $_.Typ -ne 'NVMe-SSD' }, { - $_.Frei } | Select-Object -First 1)
    $targetText = if ($target) { " Platz bietet z. B. $($target[0].Laufwerk) ($($target[0].Typ), $(Format-Size $target[0].Frei) frei)." } else { '' }
    $move = ' Umziehen ohne Neuinstallation: Steam > Spiel > Eigenschaften > Installierte Dateien > Installationsordner verschieben; Epic/Xbox bieten "Verschieben" in der Bibliothek.'
    if (@($full | Where-Object { $_.FreiProzent -lt 10 })) { Add-Finding WARN $summary ("Spielelaufwerk fast voll: SSDs werden beim Schreiben (Patches, Shader-Caches) deutlich langsamer, Updates können scheitern. Nicht mehr gespielte Spiele deinstallieren oder umziehen.$targetText$move") }
    elseif ($hdd -or $full) {
        $why = @()
        if ($hdd) { $why += "Spiele auf Festplatte ($(($hdd | ForEach-Object Laufwerk) -join ', ')): längere Ladezeiten und Nachlade-Ruckler; aktuelle Spiele setzen eine SSD voraus." }
        if ($full) { $why += "Wenig Platz auf $(($full | ForEach-Object { "$($_.Laufwerk) ($($_.FreiProzent) %)" }) -join ', '): unter 15–20 % frei werden SSDs beim Schreiben langsamer." }
        Add-Finding INFO $summary (($why -join ' ') + $targetText + $move)
    }
    else { Add-Finding OK $summary }
}

Invoke-Check 'Netzwerkkarte: Energiesparfunktionen' {
    $ad = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and [string]$_.PhysicalMediaType -match '802\.3' })
    if (-not $ad) { Add-Finding OK 'Kein kabelgebundener Adapter aktiv'; return }
    # Energiesparfunktionen, die beim Aufwachen der Verbindung kurze Latenzspitzen verursachen können
    $saving = [ordered]@{ '*EEE' = 'Energy Efficient Ethernet'; 'EEELinkAdvertisement' = 'Energy Efficient Ethernet'; '*GreenEthernet' = 'Green Ethernet'; 'EnableGreenEthernet' = 'Green Ethernet'; 'AdvancedEEE' = 'Advanced EEE'; 'ULPMode' = 'Ultra Low Power Mode'; 'PowerSavingMode' = 'Power Saving Mode' }
    $hits = foreach ($a in $ad) {
        foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue | Where-Object { $_.RegistryKeyword -in $saving.Keys })) {
            if ("$(@($p.RegistryValue)[0])" -ne '0') { [pscustomobject]@{ Adapter = $a.Name; Name = $p.DisplayName; Keyword = $p.RegistryKeyword } }
        }
    }
    $hits = @($hits)
    if (-not $hits) { Add-Finding OK ((($ad | ForEach-Object Name) -join ', ') + ': keine Energiesparfunktionen aktiv'); return }
    Add-Finding INFO ('Aktiv: ' + (($hits | ForEach-Object { "$($_.Adapter): $($_.Name)" }) -join ', ')) 'Für Online-Spiele ausschalten: Diese Funktionen legen die Verbindung in Ruhephasen schlafen und können beim Aufwachen kurze Latenzspitzen verursachen. Kostet am Desktop nur wenige Watt.'
    $script:Findings[$script:Findings.Count - 1].Command = (($hits | ForEach-Object { "Set-NetAdapterAdvancedProperty -Name '$($_.Adapter)' -RegistryKeyword '$($_.Keyword)' -RegistryValue 0" }) -join "`n")
}

#endregion

#region Performance: Auslastung

Start-Section 'Performance' 'Auslastung'

Invoke-Check 'CPU-Last (Stichprobe 5 s)' {
    $n = [Environment]::ProcessorCount
    $t0 = @{}
    Get-Process | ForEach-Object { if ($null -ne $_.CPU) { $t0[$_.Id] = $_.CPU } }
    $start = Get-Date
    $samples = for ($i = 0; $i -lt 5; $i++) {
        Start-Sleep -Seconds 1
        [int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
    }
    $elapsed = ((Get-Date) - $start).TotalSeconds
    # Eigene Last herausrechnen: dieses Script und die aufrufende GUI (Elternprozesse bis zu 3 Ebenen)
    $own = @($PID)
    try {
        $id = $PID
        for ($i = 0; $i -lt 3; $i++) {
            $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop).ParentProcessId
            $pp = Get-Process -Id $parent -ErrorAction Stop
            if ($pp.ProcessName -notin 'powershell', 'pwsh', 'cmd') { break }
            $own += $parent; $id = $parent
        }
    }
    catch { }
    $ownShare = 0
    foreach ($p in @(Get-Process -Id $own -ErrorAction SilentlyContinue)) {
        if ($t0.ContainsKey($p.Id) -and $null -ne $p.CPU) { $ownShare += ($p.CPU - $t0[$p.Id]) / $elapsed / $n * 100 }
    }
    $rows = @(Get-Process | Where-Object { ($own -notcontains $_.Id) -and $t0.ContainsKey($_.Id) -and $null -ne $_.CPU } | ForEach-Object {
            [pscustomobject][ordered]@{ Prozess = $_.ProcessName; PID = $_.Id; CPU = [Math]::Round(($_.CPU - $t0[$_.Id]) / $elapsed / $n * 100, 1) }
        } | Where-Object CPU -GT 0 | Sort-Object CPU -Descending | Select-Object -First 15)
    Add-Table 'Top-Prozesse nach CPU (%, Stichprobe)' $rows
    $avg = [int][Math]::Max(0, (($samples | Measure-Object -Average).Average) - $ownShare)
    $top = ($rows | Select-Object -First 3 | ForEach-Object { "$($_.Prozess) $($_.CPU) %" }) -join ', '
    if ($avg -gt 25) { Add-Finding WARN "Durchschnitt $avg % ($top)" 'Hohe Grundlast ohne Spiel: Verursacher im Anhang prüfen (Messung läuft parallel zum Script).' }
    elseif ($avg -gt 10) { Add-Finding INFO "Durchschnitt $avg % ($top)" 'Leicht erhöhte Grundlast; der Prüflauf selbst trägt dazu bei.' }
    else { Add-Finding OK "Durchschnitt $avg % ($top)" }
}

Invoke-Check 'RAM-Auslastung' {
    $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $totalBytes = [double]$script:CS.TotalPhysicalMemory
    $usedPct = [int](100 * (1 - [double]$mem.AvailableBytes / $totalBytes))
    $commitPct = [int](100 * [double]$mem.CommittedBytes / [double]$mem.CommitLimit)
    $rows = @(Get-Process | Group-Object ProcessName | ForEach-Object {
            [pscustomobject][ordered]@{ Prozess = $_.Name; Anzahl = $_.Count; PrivatMB = [int](($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB); ArbeitssatzMB = [int](($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }
        } | Sort-Object PrivatMB -Descending | Select-Object -First 15)
    Add-Table 'Top-Prozesse nach Arbeitsspeicher' $rows
    $top = ($rows | Select-Object -First 3 | ForEach-Object { "$($_.Prozess) $(Format-Size ($_.PrivatMB * 1MB))" }) -join ', '
    $value = "$usedPct % von $(Format-Size $totalBytes) belegt; Commit $commitPct % von $(Format-Size $mem.CommitLimit); größte: $top"
    if ($usedPct -gt 85) { Add-Finding WARN $value 'Schon ohne Spiel fast voll: Hintergrundprogramme schließen oder RAM aufrüsten.' }
    elseif ($usedPct -gt 70) { Add-Finding INFO $value 'Für Gaming plus Browser/IDE/WSL wird es eng; 32 GB wären ein sinnvolles Upgrade.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Speicherkomprimierung' -NeedsAdmin {
    $mm = Get-MMAgent
    Add-Finding INFO ('Speicherkomprimierung ' + $(if ($mm.MemoryCompression) { 'an' } else { 'aus' }) + '; Page Combining ' + $(if ($mm.PageCombining) { 'an' } else { 'aus' })) 'Bei 16 GB anlassen: komprimiert selten genutzten Speicher, statt auf die SSD auszulagern.'
}

Invoke-Check 'Autostart-Umfang' {
    $active = @($script:AutostartRows | Where-Object Aktiv)
    $autoSvc = @($script:ThirdPartyServices | Where-Object Start -EQ 'Auto')
    $value = "$($active.Count) aktive Autostart-Programme, $($autoSvc.Count) Drittanbieter-Dienste mit Autostart"
    if ($active.Count -gt 15) { Add-Finding WARN $value 'Task-Manager > Autostart-Apps: alles deaktivieren, was nicht sofort nach dem Anmelden laufen muss.' }
    elseif ($active.Count -gt 8) { Add-Finding INFO $value 'Autostart-Liste im Anhang durchgehen.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Laufzeit seit Neustart' {
    $up = (Get-Date) - $script:OS.LastBootUpTime
    $value = "$($up.Days) Tage $($up.Hours) Std."
    if ($up.Days -gt 14) { Add-Finding INFO $value 'Gelegentlich neu starten (nicht nur herunterfahren, falls Schnellstart an ist): gibt Speicher frei und schließt Updates ab.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Netzwerkverbindung' {
    $ad = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -EQ 'Up')
    $rows = foreach ($a in $ad) {
        [pscustomobject][ordered]@{ Name = $a.Name; Beschreibung = $a.InterfaceDescription; Geschwindigkeit = $a.LinkSpeed; Medium = [string]$a.PhysicalMediaType; Treiber = $a.DriverVersion; Datum = $a.DriverDate }
    }
    Add-Table 'Netzwerkadapter' $rows
    $keywords = '*EEE', 'EEELinkAdvertisement', '*GreenEthernet', 'EnableGreenEthernet', '*InterruptModeration', '*FlowControl', '*SpeedDuplex', 'ULPMode', '*JumboPacket'
    $adv = foreach ($a in $ad) {
        Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue | Where-Object { $_.RegistryKeyword -in $keywords } |
            ForEach-Object { [pscustomobject][ordered]@{ Adapter = $a.Name; Einstellung = $_.DisplayName; Wert = $_.DisplayValue } }
    }
    Add-Table 'Netzwerkadapter: Energiespar- und Leistungseinstellungen' $adv
    $wired = @($ad | Where-Object { [string]$_.PhysicalMediaType -match '802\.3' })
    $slow = @($wired | Where-Object { $_.ReceiveLinkSpeed -lt 1e9 })
    if ($slow) { Add-Finding WARN ('LAN nur mit ' + (($slow | ForEach-Object { "$($_.Name) $($_.LinkSpeed)" }) -join ', ')) 'Kabel (mind. Cat5e) und Router-/Switch-Port prüfen; Gigabit sollte möglich sein.' }
    elseif ($wired) { Add-Finding OK (($wired | ForEach-Object { "$($_.Name): $($_.LinkSpeed)" }) -join ', ') }
    elseif ($ad) { Add-Finding INFO ('Nur WLAN: ' + (($ad | ForEach-Object { "$($_.Name) $($_.LinkSpeed)" }) -join ', ')) 'Für Online-Spiele ist ein LAN-Kabel stabiler (weniger Latenzschwankungen).' }
    else { Add-Finding INFO 'Kein aktiver physischer Adapter gefunden' }
}

#endregion

#region Performance: Stabilität

Start-Section 'Performance' 'Stabilität'

Invoke-Check 'Hardwarefehler (WHEA)' {
    $ev = @(Get-RecentEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger' } -Max 500)
    $byId = $ev | Group-Object Id | ForEach-Object { "ID $($_.Name): $($_.Count)x" }
    Add-Table 'WHEA-Ereignisse' @($ev | Select-Object -First 50 | ForEach-Object { [pscustomobject][ordered]@{ Zeit = Format-Date $_.TimeCreated; ID = $_.Id; Meldung = ((([string]$_.Message) -split "`n")[0]).Trim() } })
    $fatal = @($ev | Where-Object { $_.Id -in 1, 18, 20 })
    $corrected = @($ev | Where-Object { $_.Id -in 19, 47 })
    $pcie = @($ev | Where-Object { $_.Id -eq 17 })
    $rec = 'Typisches Zeichen für zu knappen OC/RAM-Takt: Spannungen (Vcore, VCCSA/VCCIO) bzw. Takt anpassen und mit OCCT, y-cruncher oder TestMem5 testen.'
    if ($fatal) { Add-Finding CRIT ("$($fatal.Count) schwere Hardwarefehler (" + ($byId -join ', ') + ')') $rec }
    elseif ($corrected) { Add-Finding WARN ("$($corrected.Count) korrigierte CPU/RAM-Fehler (" + ($byId -join ', ') + ')') $rec }
    elseif ($pcie) { Add-Finding INFO "$($pcie.Count) korrigierte PCIe-Fehler" 'Meist harmlos; bei vielen Meldungen Grafikkarte/NVMe-Sitz und PCIe-Einstellungen im BIOS prüfen.' }
    else { Add-Finding OK "Keine WHEA-Fehler in $EventDays Tagen" }
}

Invoke-Check 'Abstürze und unerwartete Neustarts' {
    $kp = @(Get-RecentEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41 } -Max 100)
    $bc = @(Get-RecentEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 } -Max 100)
    $rows = @()
    $rows += foreach ($e in $kp) { $d = Get-EventData $e; [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Art = 'Unerwarteter Neustart (Kernel-Power 41)'; Code = $(if ([int64]$d['BugcheckCode']) { '0x{0:X}' -f [int64]$d['BugcheckCode'] } else { '' }) } }
    $rows += foreach ($e in $bc) { $d = Get-EventData $e; [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Art = 'Bluescreen'; Code = (([string]$d['param1']) -split ' ')[0] } }
    $dumps = @(Get-ChildItem -LiteralPath "$env:SystemRoot\Minidump" -Filter *.dmp -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    Add-Table 'Abstürze und unerwartete Neustarts' @($rows | Sort-Object Zeit -Descending)
    Add-Table 'Minidumps' @($dumps | Select-Object -First 20 | ForEach-Object { [pscustomobject]@{ Datei = $_.Name; Datum = Format-Date $_.LastWriteTime } })
    $codes = @($rows | Where-Object Code | ForEach-Object Code | Select-Object -Unique)
    $value = "$($kp.Count) unerwartete Neustarts, $($bc.Count) Bluescreens in $EventDays Tagen" + $(if ($codes) { " (Codes: $($codes -join ', '))" } else { '' }) + "; $($dumps.Count) Minidumps insgesamt"
    if ($kp -or $bc) { Add-Finding WARN $value 'Bei Codes wie 0x124, 0x101, 0x50, 0x1A oder 0x3B deutet das oft auf instabilen OC/RAM-Takt. Kernel-Power 41 ohne Code entsteht auch durch Reset-Taste oder Stromausfall.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Grafiktreiber-Abstürze' {
    $tdr = @(Get-RecentEvents @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101 } -Max 100)
    $nv = @(Get-RecentEvents @{ LogName = 'System'; ProviderName = 'nvlddmkm'; Level = 1, 2 } -Max 100)
    if ($tdr -or $nv.Count -gt 3) { Add-Finding WARN "$($tdr.Count) Treiber-Zurücksetzungen (TDR), $($nv.Count) NVIDIA-Treiberfehler" 'Treiber sauber neu installieren (DDU), GPU-OC/Undervolt testweise zurücknehmen, Netzteil/Stromkabel prüfen.' }
    elseif ($nv) { Add-Finding INFO "$($nv.Count) NVIDIA-Treiberfehler, keine Zurücksetzungen" 'Vereinzelt harmlos; bei Häufung Treiber neu installieren.' }
    else { Add-Finding OK "Keine in $EventDays Tagen" }
}

Invoke-Check 'Leistungsdrosselung durch Firmware' {
    $ev = @(Get-RecentEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37 } -Max 500)
    if ($ev.Count -gt 10) { Add-Finding WARN "$($ev.Count) Meldungen: Firmware begrenzt den CPU-Takt" 'Temperaturen und Leistungslimits prüfen (HWiNFO: "Thermal Throttling", "Power Limit Exceeded"); BIOS-Limits PL1/PL2/IccMax und Kühlung kontrollieren.' }
    elseif ($ev) { Add-Finding INFO "$($ev.Count) Meldungen: Firmware begrenzt den CPU-Takt" 'Vereinzelt meist harmlos; bei Leistungseinbrüchen Temperaturen prüfen.' }
    else { Add-Finding OK "Keine in $EventDays Tagen" }
}

Invoke-Check 'Programmabstürze' {
    $crash = @(Get-RecentEvents @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000 } -Max 500)
    $hang = @(Get-RecentEvents @{ LogName = 'Application'; ProviderName = 'Application Hang'; Id = 1002 } -Max 200)
    $all = @($crash | ForEach-Object { [pscustomobject]@{ App = [string]$_.Properties[0].Value; Art = 'Absturz' } }) + @($hang | ForEach-Object { [pscustomobject]@{ App = [string]$_.Properties[0].Value; Art = 'Hänger' } })
    $rows = @($all | Group-Object App | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
            [pscustomobject][ordered]@{ Programm = $_.Name; Abstuerze = @($_.Group | Where-Object Art -EQ 'Absturz').Count; Haenger = @($_.Group | Where-Object Art -EQ 'Hänger').Count }
        })
    Add-Table 'Programmabstürze' $rows
    $top = ($rows | Select-Object -First 3 | ForEach-Object { "$($_.Programm) ($($_.Abstuerze + $_.Haenger))" }) -join ', '
    if ($all.Count -gt 20) { Add-Finding WARN "$($crash.Count) Abstürze, $($hang.Count) Hänger: $top" 'Häufig betroffene Programme aktualisieren; viele unterschiedliche Programme gleichzeitig deuten eher auf RAM/OC-Instabilität.' }
    elseif ($all) { Add-Finding INFO "$($crash.Count) Abstürze, $($hang.Count) Hänger: $top" }
    else { Add-Finding OK "Keine in $EventDays Tagen" }
}

Invoke-Check 'Dienstfehler' {
    $ev = @(Get-RecentEvents @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7000, 7001, 7009, 7011, 7022, 7023, 7024, 7026, 7031, 7034, 7038, 7043 } -Max 500)
    # Bei 7009/7011 (Zeitüberschreitung) steht zuerst die Wartezeit, dann der Dienst.
    $rows = @($ev | Group-Object { ([string]$_.Properties[$(if ($_.Id -in 7009, 7011) { 1 } else { 0 })].Value).Trim() } | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
            $n = $_.Name
            $note = ''
            foreach ($p in $script:KnownHarmless.ServiceErrors.Keys) { if ($n -match $p) { $note = 'bekannt harmlos: ' + $script:KnownHarmless.ServiceErrors[$p]; break } }
            # Gibt es den Dienst nicht mehr, stammen die Fehler aus der Zeit vor der Deinstallation
            if (-not $note -and -not ($script:Services | Where-Object { $_.Name -eq $n -or $_.DisplayName -eq $n })) { $note = 'Dienst existiert nicht mehr (Fehler von vor der Deinstallation)' }
            [pscustomobject][ordered]@{ Dienst = $n; Anzahl = $_.Count; Einordnung = $note }
        })
    Add-Table 'Dienstfehler' $rows
    $open = @($rows | Where-Object { -not $_.Einordnung })
    $explained = ($rows | Where-Object Einordnung | Measure-Object Anzahl -Sum).Sum
    $explainedText = if ($explained) { "; $explained weitere bekannt harmlos bzw. von entfernten Diensten" } else { '' }
    if ($open) { Add-Finding INFO ("$(($open | Measure-Object Anzahl -Sum).Sum) Fehler: " + (($open | Select-Object -First 3 | ForEach-Object { "$($_.Dienst) ($($_.Anzahl))" }) -join ', ') + $explainedText) 'Wiederkehrende Fehler eines Dienstes deuten auf Reste deinstallierter Software oder Treiberprobleme. Einzelne Fehler beim Start oder nach Updates sind normal.' }
    elseif ($ev) { Add-Finding OK "$($ev.Count) Fehler, alle bekannt harmlos bzw. von inzwischen entfernten Diensten (Anhang)" }
    else { Add-Finding OK "Keine in $EventDays Tagen" }
}

Invoke-Check 'Datenträgerfehler' {
    $sets = @(
        @{ ProviderName = 'disk'; Id = 7, 11, 51, 153 }
        @{ ProviderName = 'Ntfs'; Id = 55, 137, 140 }
        @{ ProviderName = 'Microsoft-Windows-Ntfs'; Id = 55, 137, 140 }
        @{ ProviderName = 'stornvme'; Id = 11 }
        @{ ProviderName = 'storahci'; Id = 129 }
    )
    $ev = @()
    foreach ($s in $sets) { $ev += @(Get-RecentEvents (@{ LogName = 'System' } + $s) -Max 200) }
    $summary = @($ev | Group-Object { "$($_.ProviderName) $($_.Id)" } | ForEach-Object { "$($_.Name): $($_.Count)x" })
    if ($ev) { Add-Finding WARN ($summary -join ', ') 'Hinweise auf Datenträger- oder Kabelprobleme: SMART-Werte prüfen (CrystalDiskInfo), Datensicherung aktuell halten, SATA-Kabel tauschen.' }
    else { Add-Finding OK "Keine in $EventDays Tagen" }
}

Invoke-Check 'Startdauer' {
    $log = 'Microsoft-Windows-Diagnostics-Performance/Operational'
    $boots = @(Get-RecentEvents @{ LogName = $log; Id = 100 } -Max 5 -AllTime)
    if (-not $boots) { Add-Finding SKIP 'Keine Startmessungen vorhanden'; return }
    $rows = foreach ($e in $boots) {
        $d = Get-EventData $e
        [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; GesamtSek = [Math]::Round([int]$d['BootTime'] / 1000, 1); HauptpfadSek = [Math]::Round([int]$d['MainPathBootTime'] / 1000, 1); NachAnmeldungSek = [Math]::Round([int]$d['BootPostBootTime'] / 1000, 1) }
    }
    $rows = @($rows)
    Add-Table 'Startdauer (letzte Messungen)' $rows
    # Startbremsen nur aus dem Auswertungszeitraum, sonst tauchen längst behobene Ursachen auf
    $slow = @(Get-RecentEvents @{ LogName = $log; Id = 101, 102, 103, 106, 109 } -Max 50)
    $slowRows = @($slow | ForEach-Object {
            $d = Get-EventData $_
            [pscustomobject][ordered]@{ Zeit = Format-Date $_.TimeCreated; Art = @{ 101 = 'Programm'; 102 = 'Treiber'; 103 = 'Dienst'; 106 = 'Hintergrund'; 109 = 'Gerät' }[$_.Id]; Name = $(if ($d['FriendlyName']) { $d['FriendlyName'] } else { $d['Name'] }); VerzoegerungMs = [int]$d['DegradationTime'] }
        } | Sort-Object VerzoegerungMs -Descending | Select-Object -First 15)
    Add-Table 'Startbremsen' $slowRows
    $avgMain = [Math]::Round(($rows | Measure-Object HauptpfadSek -Average).Average, 1)
    $avgPost = [Math]::Round(($rows | Measure-Object NachAnmeldungSek -Average).Average, 1)
    $topSlow = ($slowRows | Select-Object -First 3 | ForEach-Object { "$($_.Name) (+$([int]($_.VerzoegerungMs / 1000)) s)" }) -join ', '
    $value = "Bis Desktop Ø $avgMain s, danach bis Leerlauf Ø $avgPost s" + $(if ($topSlow) { "; Bremsen: $topSlow" } else { '' })
    if ($avgMain -gt 40) { Add-Finding WARN $value 'Startbremsen im Anhang prüfen und Autostart ausdünnen.' }
    else { Add-Finding OK $value }
}

Invoke-Check 'Zuverlässigkeitsindex' {
    $r = Get-CimInstance Win32_ReliabilityStabilityMetrics -ErrorAction Stop | Sort-Object TimeGenerated -Descending | Select-Object -First 1
    if (-not $r) { Add-Finding SKIP 'Keine Daten (Aufgabe RacTask deaktiviert?)'; return }
    $idx = [Math]::Round($r.SystemStabilityIndex, 1)
    if ($idx -lt 5) { Add-Finding WARN "$idx von 10" 'Zuverlässigkeitsverlauf (perfmon /rel) ansehen: zeigt, welche Abstürze den Wert drücken.' }
    elseif ($idx -lt 8) { Add-Finding INFO "$idx von 10" 'Zuverlässigkeitsverlauf (perfmon /rel) ansehen.' }
    else { Add-Finding OK "$idx von 10" }
}

#endregion

#region Tipps und Anleitungen

# Aus pc-check.hilfe.psd1: Erklärungen für den HTML-Bericht und je Prüfung Aufwand/Nutzen/Risiko plus Anleitung.
# Ein Hinweis mit passendem Tipp-Eintrag wird zum Tipp (lohnende Optimierung); ohne Eintrag bleibt er reine Information.
$script:Help = $null
$helpFile = Join-Path $PSScriptRoot 'pc-check.hilfe.psd1'
if (Test-Path -LiteralPath $helpFile) {
    try { $script:Help = Import-PowerShellDataFile -LiteralPath $helpFile } catch { Write-Warning "Hilfetexte nicht lesbar: $($_.Exception.Message)" }
}
$script:LevelValue = @{ gering = 1; mittel = 2; hoch = 3 }

# Reihenfolge der Tipps: Nutzen zählt doppelt, Aufwand und Risiko ziehen ab.
function Get-TipScore {
    param($F)
    if (-not $F.Benefit) { return -99 }
    $lv = $script:LevelValue
    2 * $lv[$F.Benefit] - $lv[$F.Effort] - ($lv[$F.Risk] - 1)
}

if ($script:Help -and $script:Help.Tipps) {
    foreach ($f in $script:Findings) {
        if ($f.Status -notin 'CRIT', 'WARN', 'INFO') { continue }
        $t = @($script:Help.Tipps[$f.Check]) | Where-Object { $_ -and (-not $_.Match -or $f.Value -match $_.Match) } | Select-Object -First 1
        if (-not $t) { continue }
        $f.Steps = @($t.Schritte | Where-Object { $_ })
        if (-not $f.Command -and $t.Befehl) { $f.Command = [string]$t.Befehl }
        # Reine Durchsicht (NurAnleitung) bleibt ein Hinweis, ebenso Tipps für ein anderes Profil
        if ($f.Status -eq 'INFO' -and ($t.NurAnleitung -or ($t.Profile -and $script:Profile -notin @($t.Profile)))) { continue }
        $f.Effort = [string]$t.Aufwand
        $f.Benefit = [string]$t.Nutzen
        $f.Risk = [string]$t.Risiko
        if ($f.Status -eq 'INFO') { $f.Status = 'TIPP' }
    }
}

#endregion

#region Akzeptierte Abweichungen

# Eine Regel greift nur, wenn Prüfung (Wildcards erlaubt) und Muster auf den Befund passen.
# Ändert sich der Befund (z. B. ein weiteres Programm kommt hinzu), passt das Muster nicht mehr und die Warnung kehrt zurück.
# Die Regeln wurden früh eingelesen ($script:AkzeptanzRegeln); Regeln mit Datei gelten nur für Datei-Zeilen (Sigcheck-Prüfung).
$acceptRules = @($script:AkzeptanzRegeln)
foreach ($f in $script:Findings) {
    if ($f.Status -notin 'CRIT', 'WARN', 'TIPP', 'INFO') { continue }
    foreach ($r in $acceptRules) {
        if ($r.Datei) { continue }
        if ($f.Check -notlike $r.Check) { continue }
        if ($r.Match -and $f.Value -notmatch $r.Match) { continue }
        # Unlesbares Ablaufdatum (z. B. von Hand '31.12.2027') gilt als abgelaufen: Die Warnung kommt zurück, statt dass die Schleife abbricht
        $untilDate = $null
        if ($r.Until) { $tmpDate = [datetime]::MinValue; if ([datetime]::TryParseExact([string]$r.Until, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$tmpDate)) { $untilDate = $tmpDate } else { $untilDate = [datetime]::MinValue } }
        if ($r.Until -and ($untilDate -lt (Get-Date).Date)) {
            if ($untilDate -eq [datetime]::MinValue) { $f.Note = "Akzeptanz ignoriert, Ablaufdatum '$($r.Until)' unlesbar (Format JJJJ-MM-TT): $($r.Reason)" }
            else { $f.Note = "Akzeptanz abgelaufen am $($r.Until): $($r.Reason)" }
            continue
        }
        $f.OriginalStatus = $f.Status
        $f.Status = 'ACK'
        $f.Note = $r.Reason + $(if ($r.Until) { " (gilt bis $($r.Until))" } else { '' })
        break
    }
}

#endregion

#region Bericht

$duration = (Get-Date) - $startedAt
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$mdPath = Join-Path $OutputDir "pc-check_$stamp.md"
$jsonPath = Join-Path $OutputDir "pc-check_$stamp.json"

$label = @{ CRIT = '🔴 Kritisch'; WARN = '🟠 Warnung'; TIPP = '💡 Tipp'; ACK = '✅ Akzeptiert'; INFO = '🔵 Hinweis'; OK = '🟢 OK'; SKIP = '⚪ Nicht geprüft' }
$rank = @{ CRIT = 0; WARN = 1; TIPP = 2; INFO = 3; ACK = 4; SKIP = 5; OK = 6 }
$tips = @($script:Findings | Where-Object Status -EQ 'TIPP' | Sort-Object { - (Get-TipScore $_) }, Area, Category)

function ConvertTo-MdCell {
    param($Text)
    if ($null -eq $Text) { return '' }
    (([string]$Text) -replace '\|', '\|' -replace '[\r\n]+', ' ').Trim()
}

function ConvertTo-MdTable {
    param([object[]]$Rows, [int]$Max = 150)
    $Rows = @($Rows | Where-Object { $null -ne $_ })
    if (-not $Rows.Count) { return "_keine Einträge_`n" }
    $cols = @($Rows[0].PSObject.Properties | ForEach-Object Name)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('| ' + ($cols -join ' | ') + ' |')
    [void]$sb.AppendLine('|' + (($cols | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($r in ($Rows | Select-Object -First $Max)) {
        [void]$sb.AppendLine('| ' + (($cols | ForEach-Object { ConvertTo-MdCell $r.$_ }) -join ' | ') + ' |')
    }
    if ($Rows.Count -gt $Max) { [void]$sb.AppendLine("`n_… $($Rows.Count - $Max) weitere Einträge im JSON-Bericht_") }
    $sb.ToString()
}

# Vergleich mit dem vorigen Bericht: geänderte Prüfergebnisse und neue/verschwundene Einträge in den Bestandslisten.
# Läuft vor dem Schreiben des neuen Berichts, damit er nicht mit sich selbst verglichen wird.
$changes = $null
$prevFile = if ($CompareWith) { Get-Item -LiteralPath $CompareWith -ErrorAction SilentlyContinue }
else { Get-ChildItem -LiteralPath $OutputDir -Filter 'pc-check_*.json' -ErrorAction SilentlyContinue | Where-Object FullName -NE $jsonPath | Sort-Object LastWriteTime | Select-Object -Last 1 }
if ($prevFile) {
    try {
        $prev = Get-Content -LiteralPath $prevFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $old = @{}
        foreach ($f in @($prev.Findings)) { $old["$($f.Category)|$($f.Check)"] = $f }
        $seen = @{}
        $statusRows = New-Object System.Collections.Generic.List[object]
        foreach ($f in $script:Findings) {
            $k = "$($f.Category)|$($f.Check)"
            $seen[$k] = $true
            $o = $old[$k]
            # Hinweis und Tipp sind derselbe Befund, nur anders eingeordnet (Berichte vor 1.5.0 kennen keinen Tipp)
            $same = $o -and (($o.Status -eq $f.Status) -or ((@($o.Status, $f.Status) | Where-Object { $_ -in 'INFO', 'TIPP' }).Count -eq 2 -and $o.Value -eq $f.Value))
            if (-not $o) { $statusRows.Add([pscustomobject][ordered]@{ 'Prüfung' = $f.Check; Vorher = 'neue Prüfung'; Jetzt = $label[$f.Status]; Befund = $f.Value }) }
            elseif (-not $same) { $statusRows.Add([pscustomobject][ordered]@{ 'Prüfung' = $f.Check; Vorher = $label[$o.Status]; Jetzt = $label[$f.Status]; Befund = $f.Value }) }
        }
        foreach ($k in $old.Keys) {
            if (-not $seen.ContainsKey($k)) { $statusRows.Add([pscustomobject][ordered]@{ 'Prüfung' = $old[$k].Check; Vorher = $label[$old[$k].Status]; Jetzt = 'entfällt'; Befund = $old[$k].Value }) }
        }
        # Bestandslisten mit stabilem Schlüssel je Eintrag
        $inventories = [ordered]@{
            'Dienste von Drittanbietern'                       = { "$($_.Name) ($($_.Anzeige))" }
            'Treiber: geladene Drittanbieter-Treiber'          = { "$($_.Name) ($($_.Pfad))" }
            'Autostart-Einträge'                               = { "$($_.Ort): $($_.Name)" }
            'Autostarts (Autoruns, ohne Microsoft)'            = { "$($_.Kategorie): $($_.Eintrag)" }
            'Geplante Aufgaben (Drittanbieter und auffällige)' = { $_.Aufgabe }
            'Firewall: eigene Eingangsregeln (Zulassen)'       = { "$($_.Name) ($(if ($_.Programm) { $_.Programm } else { 'ohne Programm' }))" }
            'Unsignierte Systemdateien (Sigcheck)'             = { "$($_.Ordner): $($_.Datei)" }
            'Installierte Programme'                           = { "$($_.Name) $($_.Version)".Trim() }
            'Browser-Erweiterungen'                            = { "$($_.Browser): $($_.Name)" }
            'Lokale Benutzerkonten'                            = { $_.Name }
            'Administratoren'                                  = { $_.Mitglied }
            # Dynamische Ports (ab 49152) wählen Windows-Dienste bei jedem Start neu; sie wären reines Rauschen
            'Offene Netzwerkports (nicht nur lokal)'           = { if ([int]$_.Port -lt 49152) { "$($_.Protokoll) $($_.Port) ($($_.Prozess))" } }
        }
        $prevTitles = @($prev.Data.PSObject.Properties | ForEach-Object Name)
        $inventory = [ordered]@{}
        foreach ($title in $inventories.Keys) {
            if (-not $script:Tables.Contains($title) -or $title -notin $prevTitles) { continue }
            $keyOf = $inventories[$title]
            $now = @($script:Tables[$title] | ForEach-Object $keyOf | Where-Object { $_ } | Sort-Object -Unique)
            $before = @($prev.Data.$title | ForEach-Object $keyOf | Where-Object { $_ } | Sort-Object -Unique)
            $added = @($now | Where-Object { $_ -notin $before })
            $removed = @($before | Where-Object { $_ -notin $now })
            if ($added -or $removed) { $inventory[$title] = [ordered]@{ Neu = $added; Entfernt = $removed } }
        }
        $changes = [ordered]@{ VerglichenMit = $prevFile.Name; Erstellt = $prev.Meta.Erstellt; AdminVorher = [bool]$prev.Meta.Admin; Status = $statusRows.ToArray(); Bestand = $inventory }
    }
    catch { Write-Warning "Vergleich mit $($prevFile.Name) nicht möglich: $($_.Exception.Message)" }
}

# Verlauf über die bisherigen Berichte: einige Kennzahlen je Lauf für kleine Diagramme im HTML-Bericht
function Get-HistoryPoint {
    param($Erstellt, $Findings, $Data)
    $boot = @($Data.'Startdauer (letzte Messungen)' | Where-Object { $_ } | ForEach-Object { [double]$_.HauptpfadSek })
    $rel = $Findings | Where-Object Check -EQ 'Zuverlässigkeitsindex' | Select-Object -First 1
    $sysVol = @($Data.'Laufwerke (Volumes)' | Where-Object { $_.Laufwerk -eq $env:SystemDrive }) | Select-Object -First 1
    [pscustomobject][ordered]@{
        Datum    = [datetime]$Erstellt
        StartSek = $(if ($boot) { [Math]::Round(($boot | Measure-Object -Average).Average, 1) } else { $null })
        Index    = $(if ($rel -and $rel.Value -match '^([\d.,]+) von') { [double]($Matches[1] -replace ',', '.') } else { $null })
        FreiC    = $(if ($sysVol) { [double]$sysVol.FreiProzent } else { $null })
        Probleme = @($Findings | Where-Object { $_.Status -in 'CRIT', 'WARN' }).Count
    }
}
$history = New-Object System.Collections.Generic.List[object]
foreach ($hf in @(Get-ChildItem -LiteralPath $OutputDir -Filter 'pc-check_*.json' -ErrorAction SilentlyContinue | Where-Object FullName -NE $jsonPath | Sort-Object LastWriteTime | Select-Object -Last 11)) {
    try {
        $hj = Get-Content -LiteralPath $hf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $history.Add((Get-HistoryPoint ([datetime]::Parse($hj.Meta.Erstellt, [Globalization.CultureInfo]::InvariantCulture)) @($hj.Findings) $hj.Data))
    }
    catch { Write-Verbose "Verlauf: $($hf.Name) nicht lesbar" }
}
$history.Add((Get-HistoryPoint (Get-Date) $script:Findings.ToArray() ([pscustomobject]$script:Tables)))

$md = New-Object System.Text.StringBuilder
function W { param([string]$Line = '') [void]$md.AppendLine($Line) }

W "# $ProductName – $($ProductTagline): $env:COMPUTERNAME"
W ''
W "- Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm') (Dauer $([int]$duration.TotalSeconds) s)"
W "- Script-Version $ScriptVersion, PowerShell $($PSVersionTable.PSVersion)"
W ('- Adminrechte: ' + $(if ($script:IsAdmin) { 'ja' } else { 'nein, einige Prüfungen fehlen' }))
W "- Ereigniszeitraum: letzte $EventDays Tage"
W "- Profil: $($script:Profile)$(if ($script:ProfileAuto) { ' (automatisch erkannt)' })"
W "- Akzeptanzliste: $(if (Test-Path -LiteralPath $AcceptedFile) { "$AcceptedFile ($($acceptRules.Count) Regeln)" } else { 'keine (Vorlage zum Anlegen: accepted.example.psd1)' })"
W ''
W '## Zusammenfassung'
W ''
W '| Bereich | 🔴 Kritisch | 🟠 Warnung | 💡 Tipp | ✅ Akzeptiert | 🔵 Hinweis | 🟢 OK | ⚪ Nicht geprüft |'
W '|---|---|---|---|---|---|---|---|'
foreach ($area in 'Sicherheit', 'Performance') {
    $f = @($script:Findings | Where-Object Area -EQ $area)
    $c = foreach ($s in 'CRIT', 'WARN', 'TIPP', 'ACK', 'INFO', 'OK', 'SKIP') { @($f | Where-Object Status -EQ $s).Count }
    W "| $area | $($c -join ' | ') |"
}
W ''
W '## Handlungsbedarf'
W ''
$todo = @($script:Findings | Where-Object { $_.Status -in 'CRIT', 'WARN' } | Sort-Object { $rank[$_.Status] }, Area, Category)
if ($todo) {
    W '| Status | Bereich | Prüfung | Befund | Empfehlung |'
    W '|---|---|---|---|---|'
    foreach ($f in $todo) { W "| $($label[$f.Status]) | $($f.Area) / $($f.Category) | $(ConvertTo-MdCell $f.Check) | $(ConvertTo-MdCell $f.Value) | $(ConvertTo-MdCell $f.Recommendation) |" }
}
else { W '_Keine Warnungen oder kritischen Befunde._' }
W ''
W '## Tipps (lohnendste zuerst)'
W ''
if ($tips) {
    W '| Prüfung | Befund | Empfehlung | Nutzen | Aufwand | Risiko |'
    W '|---|---|---|---|---|---|'
    foreach ($f in $tips) { W "| $(ConvertTo-MdCell $f.Check) | $(ConvertTo-MdCell $f.Value) | $(ConvertTo-MdCell $f.Recommendation) | $($f.Benefit) | $($f.Effort) | $($f.Risk) |" }
}
else { W '_Keine._' }
W ''
W '## Akzeptierte Abweichungen'
W ''
$accepted = @($script:Findings | Where-Object Status -EQ 'ACK')
if ($accepted) {
    W '| Ursprünglich | Prüfung | Befund | Begründung |'
    W '|---|---|---|---|'
    foreach ($f in $accepted) { W "| $($label[$f.OriginalStatus]) | $(ConvertTo-MdCell $f.Check) | $(ConvertTo-MdCell $f.Value) | $(ConvertTo-MdCell $f.Note) |" }
}
else { W '_Keine._' }
$expired = @($script:Findings | Where-Object { $_.Note -like 'Akzeptanz abgelaufen*' })
if ($expired) { W ''; W ('Abgelaufene Akzeptanzen (wieder als Befund gemeldet): ' + (($expired | ForEach-Object Check) -join ', ')) }
W ''
W '## Änderungen seit dem letzten Lauf'
W ''
if (-not $changes) { W '_Kein vorheriger Bericht zum Vergleich gefunden._' }
else {
    $adminNote = if ($changes.AdminVorher -ne [bool]$script:IsAdmin) { " **Achtung:** Der vorige Lauf hatte $(if ($changes.AdminVorher) { '' } else { 'keine ' })Adminrechte, ein Teil der Unterschiede kann daher stammen." } else { '' }
    W "Verglichen mit ``$($changes.VerglichenMit)`` (erstellt $($changes.Erstellt)).$adminNote"
    W ''
    if ($changes.Status.Count) { W '### Geänderte Prüfergebnisse'; W ''; W (ConvertTo-MdTable $changes.Status) }
    foreach ($t in $changes.Bestand.Keys) {
        W "### $t"
        W ''
        foreach ($x in ($changes.Bestand[$t].Neu | Select-Object -First 40)) { W "- ➕ $(ConvertTo-MdCell $x)" }
        foreach ($x in ($changes.Bestand[$t].Entfernt | Select-Object -First 40)) { W "- ➖ $(ConvertTo-MdCell $x)" }
        $more = @($changes.Bestand[$t].Neu).Count + @($changes.Bestand[$t].Entfernt).Count - 80
        if ($more -gt 0) { W "- _… weitere im JSON-Bericht_" }
        W ''
    }
    if (-not $changes.Status.Count -and -not $changes.Bestand.Count) { W '_Keine Änderungen._' }
}
W ''
W '## Alle Prüfungen'
foreach ($area in 'Sicherheit', 'Performance') {
    W ''
    W "### $area"
    foreach ($cat in @($script:Findings | Where-Object Area -EQ $area | ForEach-Object Category | Select-Object -Unique)) {
        W ''
        W "#### $cat"
        W ''
        W '| Status | Prüfung | Befund | Empfehlung | Anmerkung |'
        W '|---|---|---|---|---|'
        foreach ($f in ($script:Findings | Where-Object { $_.Area -eq $area -and $_.Category -eq $cat })) {
            $how = if (@($f.Steps).Count) { ' So geht''s: ' + ((@($f.Steps) | ForEach-Object -Begin { $n = 0 } -Process { $n++; "$n. $_" }) -join ' ') } else { '' }
            if ($f.Command) { $how += " Befehl (Admin-PowerShell): ``$($f.Command -replace "`n", '; ')``" }
            W "| $($label[$f.Status]) | $(ConvertTo-MdCell $f.Check) | $(ConvertTo-MdCell $f.Value) | $(ConvertTo-MdCell ($f.Recommendation + $how)) | $(ConvertTo-MdCell $f.Note) |"
        }
    }
}
W ''
W '## Anhang: Rohdaten'
foreach ($title in $script:Tables.Keys) {
    W ''
    W "### $title"
    W ''
    W (ConvertTo-MdTable $script:Tables[$title])
}

$md.ToString() | Out-File -LiteralPath $mdPath -Encoding utf8
[ordered]@{
    Meta     = [ordered]@{ Computer = $env:COMPUTERNAME; Erstellt = (Get-Date).ToString('s'); Version = $ScriptVersion; Admin = $script:IsAdmin; EventDays = $EventDays; DauerSek = [int]$duration.TotalSeconds; StoreAppContainer = $script:PackagedFrom; Profil = $script:Profile }
    Findings = $script:Findings
    Changes  = $changes
    Data     = $script:Tables
    DataChecks = $script:TableChecks
    Speicher = $script:Speicher
} | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $jsonPath -Encoding utf8

Write-Host ''
Write-Host 'Ergebnis' -ForegroundColor Green
$colors = @{ CRIT = 'Red'; WARN = 'Yellow'; TIPP = 'Magenta'; ACK = 'DarkGreen'; INFO = 'Cyan'; OK = 'Green'; SKIP = 'Gray' }
$names = @{ CRIT = 'Kritisch'; WARN = 'Warnung'; TIPP = 'Tipp'; ACK = 'Akzeptiert'; INFO = 'Hinweis'; OK = 'OK'; SKIP = 'Nicht geprüft' }
foreach ($s in 'CRIT', 'WARN', 'TIPP', 'ACK', 'INFO', 'OK', 'SKIP') {
    Write-Host ('  {0,-14} {1}' -f $names[$s], @($script:Findings | Where-Object Status -EQ $s).Count) -ForegroundColor $colors[$s]
}
if ($changes) {
    $added = 0; $removed = 0
    foreach ($t in $changes.Bestand.Keys) { $added += @($changes.Bestand[$t].Neu).Count; $removed += @($changes.Bestand[$t].Entfernt).Count }
    Write-Host ''
    Write-Host ("Seit dem letzten Lauf ({0}): {1} geänderte Prüfergebnisse, {2} neue und {3} entfernte Einträge (Details im Bericht)" -f $changes.Erstellt, $changes.Status.Count, $added, $removed) -ForegroundColor Cyan
}
Write-Host ''
Write-Host "Bericht: $mdPath"
Write-Host "Daten:   $jsonPath"

#endregion


#region HTML-Bericht (Solarized Dark, eigenständig ohne Internetzugriff)

$updateResults = $null   # $null = Dialog nicht gezeigt, leer = nichts ausgewählt (für den HTML-Bericht)
# Nur fragen bzw. öffnen, wenn jemand an der Konsole sitzt (nicht bei umgeleiteter Eingabe oder -NonInteractive)
$interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-NonI' })

function ConvertTo-HtmlText { param($Text) [System.Net.WebUtility]::HtmlEncode([string]$Text) }

# Für die KI-Kopiervorlage: PC- und Benutzernamen, IP-/MAC-Adressen, SIDs und E-Mail-Adressen entfernen
function Protect-Text {
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = $Text -replace [regex]::Escape($env:COMPUTERNAME), '<PC>'
    if ($env:USERNAME.Length -ge 3) { $t = $t -replace [regex]::Escape($env:USERNAME), '<Benutzer>' }
    $t = $t -replace '[\w.+-]+@[\w-]+\.[\w.-]+', '<E-Mail>'
    $t = $t -replace 'S-1-5-21-[\d-]+', '<SID>'
    $t = $t -replace '(?i)\b([0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b', '<MAC>'
    $t = $t -replace '\b(?:\d{1,3}\.){3}\d{1,3}\b', '<IP>'
    $t = $t -replace '(?i)\bfe80:[0-9a-f:%]*|\b[0-9a-f]{4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f:]+', '<IPv6>'
    $t
}

function Write-HtmlReport {
    param([Parameter(Mandatory)][string]$Path)

    $help = $script:Help
    $statusName = @{ CRIT = 'Kritisch'; WARN = 'Warnung'; TIPP = 'Tipp'; ACK = 'Akzeptiert'; INFO = 'Hinweis'; OK = 'OK'; SKIP = 'Nicht geprüft' }
    $order = 'CRIT', 'WARN', 'TIPP', 'ACK', 'INFO', 'OK', 'SKIP'
    # ToArray statt @(): @() auf eine List[object] wirft in Windows PowerShell 5.1 "Argument types do not match"
    $findings = $script:Findings.ToArray()
    $count = @{}
    foreach ($s in $order) { $count[$s] = @($findings | Where-Object Status -EQ $s).Count }

    $sb = New-Object System.Text.StringBuilder
    function A([string]$Line) { [void]$sb.AppendLine($Line) }
    function HEnc($Text) { ConvertTo-HtmlText $Text }

    # Infotext (Was/Warum/Wann harmlos) zu einer Prüfung, sonst Erklärung der Kategorie
    function Get-Tip([string]$Check, [string]$Category) {
        if (-not $help) { return '' }
        $e = $help.Pruefungen[$Check]
        if ($e) { return "<b>Was wird geprüft?</b> $(HEnc $e.Was)<br><b>Warum wichtig?</b> $(HEnc $e.Warum)<br><b>Wann ist eine Warnung harmlos?</b> $(HEnc $e.Harmlos)" }
        if ($help.Kategorien[$Category]) { return HEnc $help.Kategorien[$Category] }
        ''
    }
    function Get-InfoButton([string]$TipHtml) {
        if (-not $TipHtml) { return '' }
        "<button type=`"button`" class=`"info`" aria-label=`"Erklärung`" aria-expanded=`"false`">i</button><span class=`"tip`" role=`"tooltip`">$TipHtml</span>"
    }
    # Nutzen/Aufwand/Risiko als kleine Kennzeichen
    function Get-Levels($F) {
        if (-not $F.Benefit) { return '' }
        $p = foreach ($x in @(@('Nutzen', $F.Benefit, 'n'), @('Aufwand', $F.Effort, 'a'), @('Risiko', $F.Risk, 'r'))) { if ($x[1]) { "<span class=`"lv lv-$($x[2])-$($x[1])`">$($x[0]): $($x[1])</span>" } }
        "<div class=`"levels`">$($p -join '')</div>"
    }
    # Aufklappbare Anleitung: Klickweg und optional Befehl zum Kopieren
    function Get-HowTo($F) {
        $steps = @($F.Steps)
        if (-not $steps.Count -and -not $F.Command) { return '' }
        $h = '<details class="how"><summary>So geht''s</summary>'
        if ($steps.Count) { $h += '<ol>' + (($steps | ForEach-Object { "<li>$(HEnc $_)</li>" }) -join '') + '</ol>' }
        if ($F.Command) { $h += "<div class=`"cmd`"><div class=`"cmd-head`">Befehl für eine Administrator-PowerShell <button type=`"button`" class=`"copy`">Kopieren</button></div><pre>$(HEnc $F.Command)</pre></div>" }
        $h + '</details>'
    }
    function Get-Row($F, [string]$Id, [switch]$Summary) {
        $note = ''
        if ($F.Status -eq 'ACK') { $note = "<div class=`"note`">Ursprünglich: $(HEnc $statusName[$F.OriginalStatus]) · $(HEnc $F.Note)</div>" }
        elseif ($F.Note) { $note = "<div class=`"note`">$(HEnc $F.Note)</div>" }
        $text = (HEnc ("$($F.Check) $($F.Value) $($F.Recommendation) $($F.Category)".ToLower()))
        $cls = if ($Summary) { 'row summary' } else { 'row' }
        $idAttr = if ($Summary) { '' } else { " id=`"$Id`"" }
        $check = if ($Summary) { "<a href=`"#$Id`">$(HEnc $F.Check)</a>" } else { HEnc $F.Check }
        $hint = if ($Summary) { '<div class="cat-hint">' + (HEnc $F.Area) + ' · ' + (HEnc $F.Category) + '</div>' } else { '' }
        $infoBtn = Get-InfoButton (Get-Tip $F.Check $F.Category)
        $todo = if (-not $Summary -and $F.Status -in 'CRIT', 'WARN', 'TIPP') { '<div class="todo"><button type="button" data-mark="done" title="Als erledigt markieren; der nächste Lauf zeigt, ob es wirklich behoben ist">✔ erledigt</button><button type="button" data-mark="later" title="Für später vormerken">⏱ später</button></div>' } else { '' }
        "<div class=`"$cls s-$($F.Status)`"$idAttr data-status=`"$($F.Status)`" data-check=`"$(HEnc $F.Check)`" data-text=`"$text`">" +
        "<div class=`"c-status`"><span class=`"badge b-$($F.Status)`">$($statusName[$F.Status])</span>$todo</div>" +
        "<div class=`"c-check`">$check$infoBtn$hint</div>" +
        "<div class=`"c-value`">$(HEnc $F.Value)$note</div>" +
        "<div class=`"c-rec`">$(HEnc $F.Recommendation)$(Get-Levels $F)$(if (-not $Summary) { Get-HowTo $F })</div></div>"
    }
    # Kleines Liniendiagramm (SVG) für den Verlauf
    function Get-Chart([string]$Title, [string]$Prop, [string]$Unit, [string]$Better) {
        $pts = @($history | Where-Object { $null -ne $_.$Prop })
        if ($pts.Count -lt 2) { return '' }
        $w = 300; $h = 90; $padX = 8; $padY = 14
        $vals = @($pts | ForEach-Object { [double]$_.$Prop })
        $min = ($vals | Measure-Object -Minimum).Minimum; $max = ($vals | Measure-Object -Maximum).Maximum
        if ($max -eq $min) { $max = $min + 1 }
        $xy = for ($i = 0; $i -lt $pts.Count; $i++) {
            $x = $padX + ($w - 2 * $padX) * $i / ($pts.Count - 1)
            $y = $padY + ($h - 2 * $padY) * (1 - ($vals[$i] - $min) / ($max - $min))
            [pscustomobject]@{ X = [Math]::Round($x, 1); Y = [Math]::Round($y, 1); V = $vals[$i]; D = $pts[$i].Datum.ToString('dd.MM.yy') }
        }
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $line = ($xy | ForEach-Object { $_.X.ToString($inv) + ',' + $_.Y.ToString($inv) }) -join ' '
        $dots = ($xy | ForEach-Object { "<circle cx=`"$($_.X.ToString($inv))`" cy=`"$($_.Y.ToString($inv))`" r=`"3`"><title>$($_.D): $($_.V) $Unit</title></circle>" }) -join ''
        $first = $vals[0]; $last = $vals[-1]
        $trend = if ($last -eq $first) { 'gleich' } elseif (($last -lt $first) -eq ($Better -eq 'low')) { 'besser' } else { 'schlechter' }
        $trendCls = @{ gleich = 'muted'; besser = 'add'; schlechter = 'rem' }[$trend]
        "<div class=`"chart`"><div class=`"chart-head`"><span>$(HEnc $Title)</span><span class=`"$trendCls`">$last $Unit · $trend</span></div>" +
        "<svg viewBox=`"0 0 $w $h`" role=`"img`" aria-label=`"$(HEnc $Title)`"><polyline points=`"$line`"/>$dots</svg>" +
        "<div class=`"chart-foot`"><span>$($xy[0].D)</span><span>$($xy[-1].D)</span></div></div>"
    }
    function Get-Table($Rows, [int]$Max = 300) {
        $Rows = @($Rows | Where-Object { $null -ne $_ })
        if (-not $Rows.Count) { return '<p class="muted">Keine Einträge.</p>' }
        $cols = @($Rows[0].PSObject.Properties | ForEach-Object Name)
        $t = New-Object System.Text.StringBuilder
        [void]$t.Append('<div class="tablewrap"><table><thead><tr>')
        foreach ($c in $cols) { [void]$t.Append("<th>$(HEnc $c)</th>") }
        [void]$t.Append('</tr></thead><tbody>')
        foreach ($r in ($Rows | Select-Object -First $Max)) {
            [void]$t.Append('<tr>')
            foreach ($c in $cols) { [void]$t.Append("<td>$(HEnc $r.$c)</td>") }
            [void]$t.Append('</tr>')
        }
        [void]$t.Append('</tbody></table></div>')
        if ($Rows.Count -gt $Max) { [void]$t.Append("<p class=`"muted`">… $($Rows.Count - $Max) weitere Einträge im JSON-Bericht.</p>") }
        $t.ToString()
    }

    # Ampel und die nächsten Schritte (Sicherheit vor Performance, Kritisch vor Warnung)
    if ($count.CRIT) { $amp = 'red'; $ampTitle = 'Kritische Punkte gefunden'; $ampSub = 'Bitte zuerst die rot markierten Punkte beheben.' }
    elseif ($count.WARN) { $amp = 'yellow'; $ampTitle = 'Einige Punkte prüfen'; $ampSub = 'Nichts Akutes, aber die orangefarbenen Punkte solltest du dir ansehen.' }
    else { $amp = 'green'; $ampTitle = 'Alles in Ordnung'; $ampSub = $(if ($count.TIPP) { "Keine Warnungen. $($count.TIPP) Tipps zeigen, was sich noch lohnt." } else { 'Keine Warnungen.' }) }
    $ids = @{}
    for ($i = 0; $i -lt $findings.Count; $i++) { $ids["$($findings[$i].Category)|$($findings[$i].Check)"] = "p$i" }
    $todo = @($findings | Where-Object { $_.Status -in 'CRIT', 'WARN' } | Sort-Object { $rank[$_.Status] }, { if ($_.Area -eq 'Sicherheit') { 0 } else { 1 } }, Category)

    # Gaming-Check nur im Profil Gaming
    $gamingChecks = 'Bildschirme und Bildwiederholrate', 'Grafikkarte und Treiber', 'Resizable BAR und PCIe-Anbindung', 'Arbeitsspeicher', 'Prozessor-Energieeinstellungen', 'Energieplan',
    'Spielebibliotheken', 'Spielmodus', 'Hardwarebeschleunigte GPU-Planung (HAGS)', 'Hintergrundaufzeichnung (Game DVR)', 'Optimierungen für Spiele im Fenstermodus',
    'Overlays und Hintergrund-Tools', 'Mausbeschleunigung', 'Netzwerkverbindung', 'Netzwerkkarte: Energiesparfunktionen', 'Virtualisierung und Spieleleistung'
    $gamingRows = if ($script:Profile -eq 'Gaming') { @($gamingChecks | ForEach-Object { $c = $_; $findings | Where-Object Check -EQ $c | Select-Object -First 1 } | Where-Object { $_ }) } else { @() }
    $charts = (Get-Chart 'Probleme (Kritisch + Warnung)' 'Probleme' '' 'low') + (Get-Chart 'Startdauer bis Desktop' 'StartSek' 's' 'low') +
    (Get-Chart 'Zuverlässigkeitsindex' 'Index' 'von 10' 'high') + (Get-Chart "Freier Platz auf $env:SystemDrive" 'FreiC' '%' 'high')

    # Anonymisierte Kopiervorlage für einen KI-Assistenten
    $ki = New-Object System.Text.StringBuilder
    [void]$ki.AppendLine('Ich habe meinen Windows-PC mit dem Prüfscript Morpheus (pc-check) untersucht. Bitte erkläre mir die folgenden Befunde verständlich,')
    [void]$ki.AppendLine('bewerte, wie dringend sie sind, und sag mir Schritt für Schritt, was ich tun sollte. Frag nach, wenn dir Angaben fehlen.')
    [void]$ki.AppendLine('')
    [void]$ki.AppendLine("System: $($script:OS.Caption), Version $($script:CV.DisplayVersion); $ProductName $ScriptVersion; Adminrechte: $(if ($script:IsAdmin) { 'ja' } else { 'nein' })")
    [void]$ki.AppendLine("Nutzung: $($script:Profile)")
    [void]$ki.AppendLine("Übersicht: $($count.CRIT) kritisch, $($count.WARN) Warnungen, $($count.TIPP) Tipps, $($count.ACK) akzeptiert, $($count.INFO) Hinweise, $($count.OK) OK")
    foreach ($s in 'CRIT', 'WARN', 'TIPP', 'ACK', 'INFO') {
        $list = @($findings | Where-Object Status -EQ $s)
        if (-not $list) { continue }
        [void]$ki.AppendLine('')
        [void]$ki.AppendLine("== $($statusName[$s]) ==")
        foreach ($f in $list) {
            [void]$ki.AppendLine("- [$($f.Area) / $($f.Category)] $($f.Check): $(Protect-Text $f.Value)")
            if ($f.Recommendation) { [void]$ki.AppendLine("  Empfehlung des Scripts: $(Protect-Text $f.Recommendation)") }
            if ($s -eq 'ACK') { [void]$ki.AppendLine("  Von mir bewusst akzeptiert: $(Protect-Text $f.Note)") }
        }
    }

    $css = @'
:root{--b03:#002b36;--b02:#073642;--b01:#586e75;--b00:#657b83;--b0:#839496;--b1:#93a1a1;--b2:#eee8d5;--b3:#fdf6e3;--yellow:#b58900;--orange:#cb4b16;--red:#dc322f;--magenta:#d33682;--violet:#6c71c4;--blue:#268bd2;--cyan:#2aa198;--green:#859900;--line:#0d4a57}
*{box-sizing:border-box}html{scroll-behavior:smooth}
body{margin:0;background:var(--b03);color:var(--b0);font:15px/1.55 "Segoe UI",system-ui,-apple-system,sans-serif}
a{color:var(--blue);text-decoration:none}a:hover{text-decoration:underline}
h1,h2,h3{color:var(--b1);font-weight:600;margin:0}
h2{font-size:20px;margin:28px 0 12px;padding-bottom:6px;border-bottom:1px solid var(--line)}
.muted{color:var(--b01)}
header.top{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:12px;padding:18px 28px;background:var(--b02);border-bottom:1px solid var(--line)}
header.top h1{font-size:24px;letter-spacing:.5px}header.top h1 span{color:var(--cyan)}
.meta{color:var(--b01);font-size:13px;margin-top:2px}
.btn,button.btn{background:var(--b03);color:var(--b1);border:1px solid var(--b01);border-radius:6px;padding:7px 12px;font:inherit;font-size:14px;cursor:pointer}
.btn:hover{border-color:var(--cyan);color:var(--cyan);text-decoration:none}
.hero{display:flex;flex-wrap:wrap;gap:16px;padding:20px 28px 0}
.ampel{flex:1 1 320px;display:flex;align-items:center;gap:16px;background:var(--b02);border-radius:10px;padding:18px 20px;border-left:6px solid}
.ampel .dot{width:34px;height:34px;border-radius:50%;flex:none}
.amp-red{border-color:var(--red)}.amp-red .dot{background:var(--red);box-shadow:0 0 18px var(--red)}
.amp-yellow{border-color:var(--orange)}.amp-yellow .dot{background:var(--orange);box-shadow:0 0 18px var(--orange)}
.amp-green{border-color:var(--green)}.amp-green .dot{background:var(--green);box-shadow:0 0 18px var(--green)}
.amp-title{color:var(--b1);font-size:19px;font-weight:600}.amp-sub{font-size:14px}
.counters{flex:2 1 520px;display:grid;grid-template-columns:repeat(7,1fr);gap:8px}
.counter{background:var(--b02);border:0;border-top:4px solid;border-radius:8px;padding:10px 6px;color:var(--b0);font:inherit;cursor:pointer;text-align:center}
.counter:hover{background:#0a4250}.counter .n{display:block;font-size:24px;font-weight:600;color:var(--b1)}.counter .l{font-size:12px}
.c-CRIT{border-color:var(--red)}.c-WARN{border-color:var(--orange)}.c-TIPP{border-color:var(--magenta)}.c-ACK{border-color:var(--violet)}.c-INFO{border-color:var(--blue)}.c-OK{border-color:var(--green)}.c-SKIP{border-color:var(--b01)}
.layout{display:grid;grid-template-columns:230px 1fr;gap:24px;padding:0 28px 40px}
nav.side{position:sticky;top:64px;align-self:start;max-height:calc(100vh - 80px);overflow:auto;padding-top:24px;font-size:14px}
nav.side a{display:flex;justify-content:space-between;color:var(--b0);padding:3px 8px;border-radius:5px}
nav.side a:hover{background:var(--b02);color:var(--b1);text-decoration:none}
nav.side .grp{color:var(--b1);font-weight:600;margin:12px 0 4px 8px}
nav.side .cnt{font-size:11px;background:var(--orange);color:var(--b3);border-radius:8px;padding:0 6px;align-self:center}
.toolbar{position:sticky;top:0;z-index:15;display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;background:var(--b03);padding:12px 28px;border-bottom:1px solid var(--line)}
.filters{display:flex;flex-wrap:wrap;gap:6px}
.filters button{background:var(--b02);color:var(--b0);border:1px solid var(--line);border-radius:16px;padding:4px 12px;font:inherit;font-size:13px;cursor:pointer}
.filters button.active{background:var(--cyan);border-color:var(--cyan);color:var(--b03);font-weight:600}
#search{flex:0 1 320px;background:var(--b02);border:1px solid var(--line);border-radius:6px;color:var(--b1);padding:6px 10px;font:inherit}
#search:focus{outline:none;border-color:var(--cyan)}
.card{background:var(--b02);border-radius:10px;padding:14px 18px;margin-bottom:12px}
ol.steps{margin:0;padding-left:22px}ol.steps li{margin:8px 0}ol.steps .rec{font-size:14px;color:var(--b0)}
.row{display:grid;grid-template-columns:110px minmax(180px,1fr) minmax(220px,1.6fr) minmax(220px,1.6fr);gap:14px;padding:10px 14px;border-left:4px solid transparent;border-bottom:1px solid var(--line);background:var(--b02)}
.row:target{outline:2px solid var(--cyan)}.row.flash{animation:flash 1.6s}
@keyframes flash{0%{background:#0f5566}100%{background:var(--b02)}}
.s-CRIT{border-left-color:var(--red)}.s-WARN{border-left-color:var(--orange)}.s-TIPP{border-left-color:var(--magenta)}.s-ACK{border-left-color:var(--violet)}.s-INFO{border-left-color:var(--blue)}.s-OK{border-left-color:var(--green)}.s-SKIP{border-left-color:var(--b01)}
.c-check{color:var(--b1);font-weight:600;position:relative}.c-value{word-break:break-word}.c-rec{color:var(--b0);font-size:14px}
.cat-hint{font-weight:400;font-size:12px;color:var(--b01)}
.note{margin-top:4px;font-size:13px;color:var(--violet)}
.badge{display:inline-block;padding:2px 9px;border-radius:10px;font-size:12px;font-weight:600;white-space:nowrap;color:var(--b3)}
.b-CRIT{background:var(--red)}.b-WARN{background:var(--orange)}.b-TIPP{background:var(--magenta)}.b-ACK{background:var(--violet)}.b-INFO{background:var(--blue)}.b-OK{background:var(--green)}.b-SKIP{background:var(--b01)}
.levels{margin-top:6px;display:flex;flex-wrap:wrap;gap:4px}
.lv{font-size:11px;border-radius:8px;padding:1px 7px;background:var(--b03);border:1px solid var(--line);color:var(--b0)}
.lv-n-hoch,.lv-a-gering,.lv-r-gering{color:var(--green)}.lv-n-mittel{color:var(--cyan)}.lv-a-mittel,.lv-r-mittel{color:var(--yellow)}.lv-a-hoch{color:var(--orange)}.lv-r-hoch{color:var(--red)}
details.how{margin-top:6px}details.how>summary{cursor:pointer;color:var(--cyan);font-size:13px}
details.how ol{margin:6px 0;padding-left:20px;font-size:13.5px;color:var(--b1)}
.cmd{margin-top:6px;border:1px solid var(--line);border-radius:6px;overflow:hidden}
.cmd-head{display:flex;justify-content:space-between;align-items:center;gap:8px;font-size:12px;background:#0a3f4b;padding:4px 8px;color:var(--b1)}
.cmd pre{margin:0;padding:8px;font:12.5px Consolas,monospace;white-space:pre-wrap;word-break:break-all;color:var(--b2);background:var(--b03)}
button.copy{background:transparent;border:1px solid var(--b01);color:var(--b1);border-radius:4px;font:inherit;font-size:12px;padding:1px 8px;cursor:pointer}
.todo{display:flex;flex-direction:column;gap:4px;margin-top:8px}
.todo button{background:transparent;border:1px solid var(--line);color:var(--b01);border-radius:5px;font:inherit;font-size:11.5px;padding:1px 6px;cursor:pointer;text-align:left}
.todo button:hover{color:var(--b1);border-color:var(--b01)}.todo button.on{background:var(--cyan);color:var(--b03);border-color:var(--cyan)}
.row.m-done{opacity:.65}.mark-note{font-size:12px;color:var(--cyan);margin-top:4px}
.gaming{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:8px}
.g-item{background:var(--b03);border:1px solid var(--line);border-left:4px solid;border-radius:6px;padding:8px 10px;font-size:13.5px}
.g-item a{color:var(--b1);font-weight:600}.g-item .v{color:var(--b0);font-size:12.5px;margin-top:2px;word-break:break-word}
.charts{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:10px}
.chart{background:var(--b03);border:1px solid var(--line);border-radius:8px;padding:8px 10px}
.chart-head,.chart-foot{display:flex;justify-content:space-between;font-size:12.5px}.chart-head{color:var(--b1)}.chart-foot{color:var(--b01);font-size:11px}
.chart svg{width:100%;height:90px}.chart polyline{fill:none;stroke:var(--cyan);stroke-width:2}.chart circle{fill:var(--b2)}
ul.checklist{margin:4px 0 0;padding-left:20px}ul.checklist li{margin:4px 0}
ol.steps .levels{display:inline-flex;margin:0 0 0 6px;vertical-align:1px}
details.cat{margin-bottom:10px;border-radius:10px;overflow:visible}
details.cat>summary{list-style:none;cursor:pointer;display:flex;align-items:center;gap:10px;background:#0a3f4b;padding:10px 14px;border-radius:10px 10px 0 0;color:var(--b1);font-weight:600;position:relative}
details.cat:not([open])>summary{border-radius:10px}
details.cat>summary::before{content:"▸";color:var(--cyan);transition:transform .15s}details.cat[open]>summary::before{transform:rotate(90deg)}
details.cat>summary::-webkit-details-marker{display:none}
.mini{margin-left:auto;display:flex;gap:4px}.mini .badge{font-size:11px;padding:1px 7px}
.info{display:inline-flex;align-items:center;justify-content:center;width:18px;height:18px;margin-left:7px;border-radius:50%;border:1px solid var(--cyan);background:transparent;color:var(--cyan);font:italic 700 12px Georgia,serif;cursor:pointer;vertical-align:1px;padding:0}
.info:hover,.info[aria-expanded="true"]{background:var(--cyan);color:var(--b03)}
.tip{display:none;position:absolute;left:0;top:calc(100% + 8px);z-index:30;width:min(420px,85vw);background:var(--b2);color:var(--b03);border-radius:8px;padding:12px 14px;font-weight:400;font-size:13.5px;line-height:1.5;box-shadow:0 8px 24px rgba(0,0,0,.5);cursor:default}
.tip::before{content:"";position:absolute;top:-7px;left:14px;border:7px solid transparent;border-top:0;border-bottom-color:var(--b2)}
.tip.open{display:block}.tip b{color:var(--b02)}
.tablewrap{overflow:auto;max-height:520px;border:1px solid var(--line);border-radius:6px}
table{border-collapse:collapse;width:100%;font-size:13px}
th{position:sticky;top:0;background:#0a3f4b;color:var(--b1);text-align:left;padding:6px 8px}
td{padding:5px 8px;border-top:1px solid var(--line);vertical-align:top;word-break:break-word}
tr:nth-child(even) td{background:#05313b}
details.raw{margin:6px 0}details.raw>summary{cursor:pointer;color:var(--b1);padding:4px 0}
ul.chg{margin:4px 0 12px;padding-left:20px}.add{color:var(--green)}.rem{color:var(--red)}
.guide p,.guide li{max-width:900px}.guide .badge{margin-right:6px}
#ki-text{position:absolute;left:-9999px}
.hide{display:none!important}
footer{padding:16px 28px 30px;color:var(--b01);font-size:12px;border-top:1px solid var(--line)}
@media (max-width:1000px){.layout{grid-template-columns:1fr}nav.side{display:none}.counters{grid-template-columns:repeat(3,1fr)}}
@media (max-width:760px){.row{grid-template-columns:1fr;gap:4px}}
@media print{.toolbar,nav.side,.info,header .actions{display:none}body{background:#fff;color:#000}}
'@

    $js = @'
(function () {
  var rows = Array.prototype.slice.call(document.querySelectorAll('details.cat .row'));
  var mode = 'all', term = '';
  function apply() {
    rows.forEach(function (r) {
      var s = r.getAttribute('data-status');
      var ok = mode === 'all' || (mode === 'problem' ? (s === 'CRIT' || s === 'WARN') : s === mode);
      if (ok && term) ok = r.getAttribute('data-text').indexOf(term) >= 0;
      r.classList.toggle('hide', !ok);
    });
    document.querySelectorAll('details.cat').forEach(function (c) {
      var vis = c.querySelectorAll('.row:not(.hide)').length;
      c.classList.toggle('hide', vis === 0);
      if ((term || mode !== 'all') && vis) c.open = true;
    });
    document.querySelectorAll('.filters [data-filter]').forEach(function (b) { b.classList.toggle('active', b.getAttribute('data-filter') === mode); });
    var empty = document.getElementById('empty');
    if (empty) empty.classList.toggle('hide', rows.some(function (r) { return !r.classList.contains('hide'); }));
  }
  document.querySelectorAll('[data-filter]').forEach(function (b) {
    b.addEventListener('click', function () {
      mode = b.getAttribute('data-filter'); apply();
      if (b.classList.contains('counter')) document.getElementById('pruefungen').scrollIntoView();
    });
  });
  document.getElementById('search').addEventListener('input', function (e) { term = e.target.value.trim().toLowerCase(); apply(); });

  // Sprechblasen an den i-Symbolen
  function closeTips(except) {
    document.querySelectorAll('.tip.open').forEach(function (t) {
      if (t !== except) { t.classList.remove('open'); t.previousElementSibling.setAttribute('aria-expanded', 'false'); }
    });
  }
  document.addEventListener('click', function (e) {
    var btn = e.target.closest ? e.target.closest('.info') : null;
    if (e.target.closest && e.target.closest('.tip')) { e.preventDefault(); return; }
    if (!btn) { closeTips(null); return; }
    e.preventDefault(); e.stopPropagation();
    var tip = btn.nextElementSibling, open = !tip.classList.contains('open');
    closeTips(tip);
    tip.classList.toggle('open', open);
    btn.setAttribute('aria-expanded', open ? 'true' : 'false');
  });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeTips(null); });

  // Sprung zu einer Prüfung: Filter zurücksetzen, Kategorie öffnen, Zeile hervorheben
  function reveal(id) {
    var r = document.getElementById(id);
    if (!r) return;
    if (r.classList.contains('hide')) { mode = 'all'; term = ''; document.getElementById('search').value = ''; apply(); }
    var d = r.closest('details'); if (d) d.open = true;
    r.scrollIntoView({ block: 'center' });
    r.classList.remove('flash'); void r.offsetWidth; r.classList.add('flash');
  }
  document.querySelectorAll('a[href^="#p"]').forEach(function (a) {
    a.addEventListener('click', function (e) { e.preventDefault(); reveal(a.getAttribute('href').substring(1)); });
  });

  // Anonymisierte Kopiervorlage für ChatGPT/Claude
  var kb = document.getElementById('btn-ki');
  kb.addEventListener('click', function () {
    var ta = document.getElementById('ki-text'), label = kb.textContent;
    function done(ok) {
      kb.textContent = ok ? '✔ Kopiert – jetzt in ChatGPT oder Claude einfügen' : 'Kopieren nicht möglich';
      setTimeout(function () { kb.textContent = label; }, 4000);
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(ta.value).then(function () { done(true); }, function () { ta.select(); done(document.execCommand('copy')); });
    } else { ta.select(); done(document.execCommand('copy')); }
  });

  // Befehle aus "So geht's" kopieren
  document.querySelectorAll('button.copy').forEach(function (b) {
    b.addEventListener('click', function () {
      var pre = b.closest('.cmd').querySelector('pre'), label = b.textContent;
      function done(ok) { b.textContent = ok ? '✔ Kopiert' : 'Nicht möglich'; setTimeout(function () { b.textContent = label; }, 2500); }
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(pre.textContent).then(function () { done(true); }, function () { done(false); });
      else done(false);
    });
  });

  // Checkliste: Markierungen bleiben im Browser gespeichert (je PC) und werden mit jedem neuen Bericht abgeglichen
  var store = null, key = 'pc-check:' + document.body.getAttribute('data-pc'), created = document.body.getAttribute('data-created');
  try { store = window.localStorage; store.getItem(key); } catch (e) { store = null; }
  var marks = {};
  if (store) { try { marks = JSON.parse(store.getItem(key) || '{}') || {}; } catch (e) { marks = {}; } }
  function save() { if (store) { try { store.setItem(key, JSON.stringify(marks)); } catch (e) {} } }
  var byCheck = {};
  rows.forEach(function (r) { byCheck[r.getAttribute('data-check')] = r; });
  function li(list, text, cls, id) {
    var e = document.createElement('li');
    if (id) { var a = document.createElement('a'); a.href = '#' + id; a.textContent = text; a.addEventListener('click', function (ev) { ev.preventDefault(); reveal(id); }); e.appendChild(a); }
    else e.textContent = text;
    if (cls) { var s = document.createElement('span'); s.className = 'muted'; s.textContent = ' – ' + cls; e.appendChild(s); }
    list.appendChild(e);
  }
  function render() {
    rows.forEach(function (r) {
      var m = marks[r.getAttribute('data-check')];
      r.classList.toggle('m-done', !!(m && m.state === 'done'));
      r.querySelectorAll('.todo button').forEach(function (b) { b.classList.toggle('on', !!(m && m.state === b.getAttribute('data-mark'))); });
    });
    var groups = { pending: [], open: [], fixed: [], later: [] };
    Object.keys(marks).forEach(function (c) {
      var m = marks[c], r = byCheck[c], s = r ? r.getAttribute('data-status') : 'OK';
      var still = s === 'CRIT' || s === 'WARN' || s === 'TIPP';
      var g = m.state === 'later' ? (still ? 'later' : 'fixed') : (!still ? 'fixed' : (m.report === created ? 'pending' : 'open'));
      groups[g].push({ c: c, id: r ? r.id : '', d: m.date });
    });
    var box = document.getElementById('checklist-body');
    if (!box) return;
    box.innerHTML = '';
    var titles = { open: 'Als erledigt markiert, aber weiterhin gemeldet', fixed: 'Behoben (bestätigt durch diesen Bericht)', pending: 'Als erledigt markiert (der nächste Lauf bestätigt es)', later: 'Für später vorgemerkt' };
    var any = false;
    ['open', 'fixed', 'pending', 'later'].forEach(function (g) {
      if (!groups[g].length) return;
      any = true;
      var h = document.createElement('h3'); h.textContent = titles[g]; h.className = g === 'open' ? 'rem' : (g === 'fixed' ? 'add' : '');
      var ul = document.createElement('ul'); ul.className = 'checklist';
      groups[g].forEach(function (x) { li(ul, x.c, 'markiert am ' + x.d, x.id); });
      box.appendChild(h); box.appendChild(ul);
    });
    if (!any) box.innerHTML = '<p class="muted">Noch nichts markiert. Bei Warnungen und Tipps kannst du „✔ erledigt“ oder „⏱ später“ anklicken.</p>';
    if (!store) box.innerHTML += '<p class="muted">Dein Browser erlaubt hier keine Speicherung; Markierungen gehen beim Schließen verloren.</p>';
  }
  document.querySelectorAll('.todo button').forEach(function (b) {
    b.addEventListener('click', function () {
      var c = b.closest('.row').getAttribute('data-check'), st = b.getAttribute('data-mark');
      if (marks[c] && marks[c].state === st) delete marks[c];
      else marks[c] = { state: st, date: new Date().toLocaleDateString('de-DE'), report: created };
      save(); render();
    });
  });
  var reset = document.getElementById('checklist-reset');
  if (reset) reset.addEventListener('click', function () { if (confirm('Alle Markierungen für diesen PC löschen?')) { marks = {}; save(); render(); } });
  render();
})();
'@

    $title = "$ProductName · $env:COMPUTERNAME · $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    A '<!DOCTYPE html>'
    A '<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
    A "<title>$(HEnc $title)</title><style>$css</style></head><body data-pc=`"$(HEnc $env:COMPUTERNAME)`" data-created=`"$(Get-Date -Format 's')`">"

    # Kopf
    A '<header class="top"><div>'
    A "<h1>$ProductName <span>$ProductTagline</span></h1>"
    A ("<div class=`"meta`">{0} · {1} · Version {2} · Adminrechte: {3} · Dauer {4} s · Ereignisse der letzten {5} Tage · Profil {6}</div>" -f (HEnc $env:COMPUTERNAME), (Get-Date -Format 'dd.MM.yyyy HH:mm'), $ScriptVersion, $(if ($script:IsAdmin) { 'ja' } else { 'nein (einige Prüfungen fehlen)' }), [int]$duration.TotalSeconds, $EventDays, $(if ($script:ProfileAuto) { "$($script:Profile) (automatisch)" } else { $script:Profile }))
    A '</div><div class="actions"><button type="button" class="btn" id="btn-ki" title="Kopiert die Befunde ohne PC-Namen, Benutzernamen und Adressen in die Zwischenablage">🤖 Für KI-Assistent kopieren</button> <a class="btn" href="#anleitung">📖 So liest du den Bericht</a></div></header>'

    # Ampel und Zähler
    A "<section class=`"hero`"><div class=`"ampel amp-$amp`"><span class=`"dot`"></span><div><div class=`"amp-title`">$ampTitle</div><div class=`"amp-sub`">$ampSub</div></div></div>"
    A '<div class="counters">'
    foreach ($s in $order) { A "<button type=`"button`" class=`"counter c-$s`" data-filter=`"$s`" title=`"Nur diese anzeigen`"><span class=`"n`">$($count[$s])</span><span class=`"l`">$($statusName[$s])</span></button>" }
    A '</div></section>'

    # Werkzeugleiste
    A '<div class="toolbar"><div class="filters">'
    A '<button type="button" data-filter="all" class="active">Alle</button><button type="button" data-filter="problem">Probleme</button><button type="button" data-filter="TIPP">Tipps</button><button type="button" data-filter="INFO">Hinweise</button><button type="button" data-filter="ACK">Akzeptiert</button><button type="button" data-filter="OK">OK</button><button type="button" data-filter="SKIP">Nicht geprüft</button>'
    A '</div><input id="search" type="search" placeholder="Prüfungen durchsuchen …" aria-label="Prüfungen durchsuchen"></div>'

    # Navigation
    $cats = @($findings | ForEach-Object { "$($_.Area)|$($_.Category)" } | Select-Object -Unique)
    A '<div class="layout"><nav class="side">'
    A '<a href="#schritte">Nächste Schritte</a>'
    A '<a href="#checkliste">Meine Checkliste</a>'
    if ($gamingRows) { A '<a href="#gaming">Gaming-Check</a>' }
    if ($charts) { A '<a href="#verlauf">Verlauf</a>' }
    if ($changes) { A '<a href="#aenderungen">Änderungen</a>' }
    if ($count.ACK) { A "<a href=`"#akzeptiert`">Akzeptiert <span class=`"cnt`" style=`"background:var(--violet)`">$($count.ACK)</span></a>" }
    if ($null -ne $updateResults) { A '<a href="#updates">Updates nach dem Lauf</a>' }
    $lastArea = ''
    for ($i = 0; $i -lt $cats.Count; $i++) {
        $area, $cat = $cats[$i] -split '\|', 2
        if ($area -ne $lastArea) { A "<div class=`"grp`">$(HEnc $area)</div>"; $lastArea = $area }
        $prob = @($findings | Where-Object { $_.Area -eq $area -and $_.Category -eq $cat -and $_.Status -in 'CRIT', 'WARN' }).Count
        $cnt = if ($prob) { '<span class="cnt">' + $prob + '</span>' } else { '' }
        A "<a href=`"#cat$i`">$(HEnc $cat)$cnt</a>"
    }
    A '<div class="grp">Mehr</div><a href="#rohdaten">Rohdaten</a><a href="#anleitung">Anleitung</a></nav><main>'

    # Nächste Schritte
    A '<h2 id="schritte">Die nächsten Schritte</h2>'
    if ($todo) {
        A '<div class="card"><ol class="steps">'
        foreach ($f in ($todo | Select-Object -First 3)) {
            A "<li><span class=`"badge b-$($f.Status)`">$($statusName[$f.Status])</span> <a href=`"#$($ids["$($f.Category)|$($f.Check)"])`">$(HEnc $f.Check)</a><div class=`"rec`">$(HEnc $f.Recommendation)</div></li>"
        }
        A '</ol>'
        # Typografische Anführungszeichen nur in einfach gequoteten Strings (in "…" beenden sie in PS 5.1 den String)
        if ($todo.Count -gt 3) { A ('<p class="muted">Insgesamt {0} Punkte mit Handlungsbedarf; alle zeigt der Filter „Probleme“.</p>' -f $todo.Count) }
        A '</div>'
    }
    else { A '<div class="card">Kein Handlungsbedarf. 🎉</div>' }
    if ($tips) {
        A '<div class="card"><h3 style="margin-bottom:6px">Lohnende Tipps</h3><p class="muted" style="margin:0 0 4px">Optional, sortiert nach Nutzen im Verhältnis zu Aufwand und Risiko. Die Anleitung steht jeweils unter „So geht''s“.</p><ol class="steps">'
        foreach ($f in ($tips | Select-Object -First 5)) {
            A "<li><a href=`"#$($ids["$($f.Category)|$($f.Check)"])`">$(HEnc $f.Check)</a>$(Get-Levels $f)<div class=`"rec`">$(HEnc $f.Recommendation)</div></li>"
        }
        A '</ol>'
        if ($tips.Count -gt 5) { A ('<p class="muted">Insgesamt {0} Tipps; alle zeigt der Filter „Tipps“.</p>' -f $tips.Count) }
        A '</div>'
    }

    # Checkliste (wird im Browser aus den gespeicherten Markierungen aufgebaut)
    A '<h2 id="checkliste">Meine Checkliste</h2><div class="card"><div id="checklist-body"><p class="muted">Lädt …</p></div>'
    A '<p class="muted" style="margin-bottom:0">Markierungen speichert dein Browser für diesen PC. Öffnest du den nächsten Bericht im selben Browser, siehst du hier, was wirklich behoben ist. <button type="button" class="copy" id="checklist-reset">Markierungen löschen</button></p></div>'

    # Gaming-Check: die spielerelevanten Prüfungen auf einen Blick
    if ($gamingRows) {
        A '<h2 id="gaming">Gaming-Check</h2><div class="card"><div class="gaming">'
        foreach ($f in $gamingRows) {
            $col = @{ CRIT = 'var(--red)'; WARN = 'var(--orange)'; TIPP = 'var(--magenta)'; ACK = 'var(--violet)'; INFO = 'var(--blue)'; OK = 'var(--green)'; SKIP = 'var(--b01)' }[$f.Status]
            A "<div class=`"g-item`" style=`"border-left-color:$col`"><span class=`"badge b-$($f.Status)`">$($statusName[$f.Status])</span> <a href=`"#$($ids["$($f.Category)|$($f.Check)"])`">$(HEnc $f.Check)</a><div class=`"v`">$(HEnc $f.Value)</div></div>"
        }
        A '</div></div>'
    }

    # Verlauf über die bisherigen Läufe
    if ($charts) {
        A "<h2 id=`"verlauf`">Verlauf</h2><div class=`"card`"><p class=`"muted`" style=`"margin-top:0`">Die letzten $($history.Count) Läufe. Punkte mit der Maus berühren für Datum und Wert.</p><div class=`"charts`">$charts</div></div>"
    }

    # Änderungen seit dem letzten Lauf
    if ($changes) {
        A '<h2 id="aenderungen">Änderungen seit dem letzten Lauf</h2><div class="card">'
        $adminNote = if ($changes.AdminVorher -ne [bool]$script:IsAdmin) { " <b>Achtung:</b> Der vorige Lauf hatte $(if ($changes.AdminVorher) { '' } else { 'keine ' })Adminrechte, ein Teil der Unterschiede kann daher stammen." } else { '' }
        $prevDate = try { ([datetime]::Parse($changes.Erstellt, [Globalization.CultureInfo]::InvariantCulture)).ToString('dd.MM.yyyy HH:mm') } catch { $changes.Erstellt }
        A "<p class=`"muted`">Verglichen mit dem Bericht vom $(HEnc $prevDate).$adminNote</p>"
        if ($changes.Status.Count) {
            A '<h3>Geänderte Prüfergebnisse</h3>'
            A (Get-Table $changes.Status)
        }
        foreach ($t in $changes.Bestand.Keys) {
            A "<h3>$(HEnc $t)</h3><ul class=`"chg`">"
            foreach ($x in @($changes.Bestand[$t].Neu)) { A "<li class=`"add`">➕ $(HEnc $x)</li>" }
            foreach ($x in @($changes.Bestand[$t].Entfernt)) { A "<li class=`"rem`">➖ $(HEnc $x)</li>" }
            A '</ul>'
        }
        if (-not $changes.Status.Count -and -not $changes.Bestand.Count) { A '<p>Keine Änderungen.</p>' }
        A '</div>'
    }

    # Akzeptierte Abweichungen
    $acc = @($findings | Where-Object Status -EQ 'ACK')
    if ($acc) {
        A '<h2 id="akzeptiert">Akzeptierte Abweichungen</h2>'
        foreach ($f in $acc) { A (Get-Row $f $ids["$($f.Category)|$($f.Check)"] -Summary) }
    }

    # Update-Dialog
    if ($null -ne $updateResults) {
        A '<h2 id="updates">Updates nach dem Lauf</h2>'
        if (@($updateResults).Count) { A (Get-Table $updateResults) } else { A '<div class="card">Keine Updates ausgewählt.</div>' }
    }

    # Alle Prüfungen nach Bereich und Kategorie
    A '<h2 id="pruefungen">Alle Prüfungen</h2><p id="empty" class="card hide">Keine Prüfung passt zu Filter und Suche.</p>'
    $lastArea = ''
    for ($i = 0; $i -lt $cats.Count; $i++) {
        $area, $cat = $cats[$i] -split '\|', 2
        if ($area -ne $lastArea) { A "<h3 style=`"margin:18px 0 8px`">$(HEnc $area)</h3>"; $lastArea = $area }
        $list = @($findings | Where-Object { $_.Area -eq $area -and $_.Category -eq $cat })
        $mini = foreach ($s in $order) { $n = @($list | Where-Object Status -EQ $s).Count; if ($n -and $s -ne 'OK') { "<span class=`"badge b-$s`">$n $($statusName[$s])</span>" } }
        $okN = @($list | Where-Object Status -EQ 'OK').Count
        if ($okN) { $mini = @($mini) + "<span class=`"badge b-OK`">$okN OK</span>" }
        $catTip = if ($help -and $help.Kategorien[$cat]) { Get-InfoButton (HEnc $help.Kategorien[$cat]) } else { '' }
        $open = if (@($list | Where-Object { $_.Status -in 'CRIT', 'WARN', 'TIPP' }).Count) { ' open' } else { '' }
        A "<details class=`"cat`" id=`"cat$i`"$open><summary>$(HEnc $cat)$catTip<span class=`"mini`">$($mini -join '')</span></summary>"
        foreach ($f in $list) { A (Get-Row $f $ids["$($f.Category)|$($f.Check)"]) }
        A '</details>'
    }

    # Rohdaten
    A '<h2 id="rohdaten">Rohdaten</h2><p class="muted">Die Detailtabellen hinter den Prüfungen. Zum Aufklappen anklicken.</p>'
    foreach ($title in $script:Tables.Keys) {
        $rowsT = @($script:Tables[$title])
        A "<details class=`"raw`"><summary>$(HEnc $title) <span class=`"muted`">($($rowsT.Count))</span></summary>$(Get-Table $rowsT)</details>"
    }

    # Anleitung
    A '<h2 id="anleitung">So liest du den Bericht</h2><div class="card guide">'
    A '<p>pc-check prüft Sicherheit und Leistung deines PCs und bewertet jeden Punkt mit einem Status. Die Prüfung ändert nichts am System.</p><ul>'
    foreach ($s in $order) {
        $txt = if ($help -and $help.Status[$s]) { $help.Status[$s] } else { $statusName[$s] }
        A "<li><span class=`"badge b-$s`">$($statusName[$s])</span>$(HEnc $txt)</li>"
    }
    A '</ul><h3>So gehst du vor</h3><ol>'
    A '<li>Oben zeigt die <b>Ampel</b> den Gesamtzustand, darunter stehen <b>die nächsten Schritte</b>, also die wichtigsten Punkte zuerst, und die <b>lohnendsten Tipps</b>.</li>'
    A '<li>Jeder Tipp trägt drei Kennzeichen: <b>Nutzen</b> (was es bringt), <b>Aufwand</b> (wie lange es dauert) und <b>Risiko</b> (was schiefgehen kann). Unter <b>„So geht''s“</b> steht der Weg durch die Einstellungen, oft mit einem Befehl zum Kopieren.</li>'
    A '<li>Mit <b>„✔ erledigt“</b> und <b>„⏱ später“</b> baust du dir eine <b>Checkliste</b>. Öffnest du den nächsten Bericht im selben Browser, zeigt sie, was wirklich behoben ist.</li>'
    A "<li>Die Empfehlungen richten sich nach dem <b>Profil</b> (hier: $(HEnc $script:Profile)). Passt es nicht, das Script mit <code>-Profil Gaming</code>, <code>Office</code> oder <code>Laptop</code> starten.</li>"
    A '<li>Klicke auf das <b>i-Symbol</b> neben einer Prüfung: Die Sprechblase erklärt, was geprüft wird, warum es wichtig ist und <b>wann eine Warnung harmlos ist</b>.</li>'
    A '<li>Ist eine Warnung bei dir bewusst so gewollt (z. B. ein Fernwartungsprogramm, das du nutzt), trag sie in <code>accepted.psd1</code> ein (Vorlage: <code>accepted.example.psd1</code>). Dann erscheint sie künftig als „Akzeptiert“.</li>'
    A '<li>Mit <b>Filter</b> und <b>Suche</b> oben blendest du alles aus, was gerade nicht interessiert. Ein Klick auf eine Zahl bei der Ampel filtert nach diesem Status.</li>'
    A '<li>Unsicher? Mit <b>„Für KI-Assistent kopieren“</b> kommen die Befunde ohne PC-Namen, Benutzernamen und Adressen in die Zwischenablage, zum Einfügen in ChatGPT oder Claude. Lies den Text vor dem Einfügen kurz durch.</li>'
    A '<li>Vor Änderungen an BIOS, Treibern, BitLocker oder Sicherheitsfunktionen im Zweifel lieber jemanden fragen, der sich auskennt.</li>'
    A '</ol><p class="muted">Der Bericht enthält viele Details deines PCs. Gib ihn nicht unbedacht weiter.</p></div>'

    A "</main></div><footer>$ProductName – $ProductTagline $ScriptVersion · erstellt $(Get-Date -Format 'dd.MM.yyyy HH:mm') · Markdown- und JSON-Fassung liegen im selben Ordner.</footer>"
    A "<textarea id=`"ki-text`" readonly aria-hidden=`"true`">$(HEnc $ki.ToString())</textarea>"
    A "<script>$js</script></body></html>"

    [IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
}

$htmlPath = [IO.Path]::ChangeExtension($mdPath, '.html')
try {
    Write-HtmlReport -Path $htmlPath
    Write-Host "HTML:    $htmlPath" -ForegroundColor Green
    # Über den Explorer öffnen: so startet der Browser ohne Adminrechte, auch wenn pc-check als Admin läuft
    if (-not $NoOpen -and $interactive) { Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe') -ArgumentList "`"$htmlPath`"" }
}
catch { Write-Warning "HTML-Bericht konnte nicht erstellt werden: $($_.Exception.Message)" }

#endregion

#region Update-Dialog (nach dem Bericht, nur mit ausdrücklicher Auswahl)

$candidates = @($script:WingetUpdates | Where-Object Kategorie -EQ 'Programm')
if (-not $NoUpdatePrompt -and $interactive -and $candidates.Count) {
    Write-Host ''
    Write-Host 'Für diese Programme gibt es Updates:' -ForegroundColor Yellow
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ('  [{0}] {1}  {2} -> {3}' -f ($i + 1), $candidates[$i].Name, $candidates[$i].Installiert, $candidates[$i].Verfuegbar)
    }
    $skipped = @($script:WingetUpdates | Where-Object Kategorie -NE 'Programm')
    if ($skipped) { Write-Host ("  Nicht angeboten: " + (($skipped | ForEach-Object { "$($_.Name) ($($_.Kategorie))" }) -join ', ')) -ForegroundColor DarkGray }
    Write-Host '  winget lädt aus den Herstellerquellen und akzeptiert dabei die Lizenzbedingungen der Pakete.' -ForegroundColor DarkGray
    $answer = Read-Host 'Welche aktualisieren? Nummern (z. B. 1,3), a = alle, Enter = keine'

    $selected = @()
    if ($answer -match '^\s*a\s*$') { $selected = $candidates }
    elseif ($answer.Trim()) {
        # Doppelte über die Nummer entfernen (Select-Object -Unique taugt für Objekte ohne Textdarstellung nicht)
        $picked = @()
        foreach ($tok in ($answer -split '[,;\s]+' | Where-Object { $_ })) {
            if ($tok -match '^\d+$' -and [int]$tok -ge 1 -and [int]$tok -le $candidates.Count) { if ([int]$tok -notin $picked) { $picked += [int]$tok } }
            else { Write-Host "  Ignoriert: '$tok'" -ForegroundColor DarkGray }
        }
        $selected = @($picked | ForEach-Object { $candidates[$_ - 1] })
    }

    $results = @()
    if ($selected) {
        # Pfad neu prüfen (zwischen Scan und Auswahl kann Zeit vergehen), nie über PATH (2.3.3)
        $wg = $null
        if ($script:PfadLib) { $wg = (Get-MorpheusWinget).Pfad }
        if (-not $wg) {
            Write-Host '  winget wurde nicht im signierten App-Installationsprogramm gefunden; es wird nichts aktualisiert.' -ForegroundColor Yellow
            foreach ($u in $selected) { $results += [pscustomobject][ordered]@{ Programm = $u.Name; Von = $u.Installiert; Auf = $u.Verfuegbar; Ergebnis = 'nicht aktualisiert (winget nicht gefunden)' } }
            $selected = @()
        }
        # Von winget gekürzte oder ungültige Ids nicht übergeben (2.4)
        elseif ($script:WingetLib) { $selected = @($selected | Where-Object { Test-MorpheusWingetId -Id $_.Id }) }
        # winget läuft ohne Adminrechte (2.5, #67, G3); ohne WingetBenutzer.ps1 wird nichts aktualisiert (kein Rückfall)
        if ($selected -and -not (Get-Command -Name Invoke-MorpheusWingetBenutzer -CommandType Function -ErrorAction SilentlyContinue)) {
            Write-Host '  gui\lib\WingetBenutzer.ps1 fehlt; winget wird nicht mit Adminrechten gestartet, es wird nichts aktualisiert.' -ForegroundColor Yellow
            foreach ($u in $selected) { $results += [pscustomobject][ordered]@{ Programm = $u.Name; Von = $u.Installiert; Auf = $u.Verfuegbar; Ergebnis = 'nicht aktualisiert (WingetBenutzer.ps1 fehlt)' } }
            $selected = @()
        }
        $wgGelaufen = [bool]$selected
        if ($selected) {
            Write-Host '  winget läuft ohne Adminrechte. Braucht ein Programm Adminrechte, fragt Windows selbst nach: dort den Herausgeber prüfen.' -ForegroundColor DarkGray
        }
        foreach ($u in $selected) {
            while ($true) {
                Write-Host "`n=== Aktualisiere $($u.Name) ($($u.Installiert) -> $($u.Verfuegbar))" -ForegroundColor Cyan
                $wr = Invoke-MorpheusWingetBenutzer -WingetPfad $wg -Argumente (Get-MorpheusWingetUpgradeArgumente -Id $u.Id) -Zeile { param($z) Write-Host ('  ' + $z) }
                if ($wr.zeitueberschritten) { $result = 'fehlgeschlagen (Zeitlimit überschritten)'; break }
                if ($null -eq $wr.exitCode) { $result = 'fehlgeschlagen ({0})' -f $wr.fehler; break }
                $code = $wr.exitCode
                if ($code -eq 0) { $result = 'aktualisiert'; break }
                # 0x8A150006: Installer abgebrochen, meist weil das Programm noch läuft
                if ((Get-MorpheusWingetErgebnis -ExitCode $code).status -eq 'laeuft-noch') {
                    Write-Host '  Der Installer hat abgebrochen, meist weil das Programm noch läuft (bei Git: Git-Bash-Fenster schließen).' -ForegroundColor Yellow
                    if ((Read-Host '  Programm schließen und erneut versuchen? (j/n)') -match '^\s*j') { continue }
                    $result = 'abgebrochen (Programm lief noch)'
                }
                else { $result = 'fehlgeschlagen (Code {0})' -f $code }
                break
            }
            Write-Host "  -> $result" -ForegroundColor $(if ($result -eq 'aktualisiert') { 'Green' } else { 'Red' })
            $results += [pscustomobject][ordered]@{ Programm = $u.Name; Von = $u.Installiert; Auf = $u.Verfuegbar; Ergebnis = $result }
        }
    }
    else { Write-Host '  Keine Updates ausgewählt.' }
    $updateResults = @($results)

    # Ergebnis an den Bericht anhängen
    $lines = @('', "## Updates nach dem Lauf ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))", '')
    if ($results) {
        $lines += (ConvertTo-MdTable $results)
        if ($wgGelaufen) { $lines += ''; $lines += 'winget lief ohne Adminrechte (Benutzerkontext).' }
    }
    else { $lines += '_Keine Updates ausgewählt._' }
    [IO.File]::AppendAllText($mdPath, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))
    try { Write-HtmlReport -Path $htmlPath } catch { Write-Warning "HTML-Bericht konnte nicht aktualisiert werden: $($_.Exception.Message)" }
    Write-Host "`nUpdate-Ergebnis an den Bericht angehängt (im Browser mit F5 neu laden)." -ForegroundColor Green
}

#endregion
