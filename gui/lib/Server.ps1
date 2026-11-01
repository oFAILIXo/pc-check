# pc-check GUI: lokaler HTTP-Server (Routing, Sicherheitsprüfungen, Jobs).
# Wird von pc-check-gui.ps1 per Dot-Source im Script-Scope geladen. Vertrag: docs/gui-architektur.md (Abschnitte 3-6, 11).
# Windows PowerShell 5.1. Der Server nimmt nur Aktions-IDs entgegen, nie Befehle oder Pfade (Abschnitt 4.6).

$script:GuiReportRx = '^pc-check_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}\.(json|html|md)\z'
# Wartungsberichte (Abschnitt 18.3): vom Job erzeugte HTML-Dateien in reports\, nur zum Anzeigen im iframe
$script:GuiWartungReportRx = '^morpheus-(energy|akku|schlaf)_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.html\z'
$script:GuiCsp = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"
$script:GuiReportCsp = "default-src 'self'; script-src 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"
$script:GuiMaxBody = 262144
$script:GuiJobKeepMinutes = 30

#region Hilfsfunktionen

function Write-GuiLog {
    param([string]$Text)
    try {
        $dir = Join-Path $script:Gui.DataRoot 'state'
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $p = Join-Path $dir 'gui.log'
        if ((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p).Length -gt 2MB)) {
            Move-Item -LiteralPath $p -Destination ($p + '.1') -Force
        }
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $Text + "`r`n"
        [IO.File]::AppendAllText($p, $line, (New-Object Text.UTF8Encoding $false))
    }
    catch { }
}

function Stop-GuiRequest {
    # Bricht die aktuelle Anfrage mit Status und Nutzertext ab (wird im Handler gefangen).
    param([int]$Status, [string]$Message)
    $ex = New-Object System.Exception $Message
    $ex.Data['status'] = $Status
    throw $ex
}

function Test-GuiFn {
    param([string[]]$Name)
    foreach ($n in $Name) {
        if (-not (Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue)) { return $false }
    }
    return $true
}

function Get-GuiReadOnlyMessage {
    $why = [string]$script:Gui.ReadOnlyReason
    if (-not $why) { $why = 'Morpheus läuft im Nur-Lesen-Modus.' }
    $why + ' Änderungen, „Rückgängig“ und Scans sind gesperrt (ein Scan würde Code aus einem ungesicherten Ordner mit Administratorrechten ausführen). Starte Morpheus über das Startmenü bzw. C:\Program Files\Morpheus\pc-check-gui.cmd.'
}

function Assert-GuiWritable {
    # Ändernde Endpunkte und der Scan: im Nur-Lesen-Modus immer 403
    if ($script:Gui.ReadOnly) { Stop-GuiRequest 403 (Get-GuiReadOnlyMessage) }
}

function Get-GuiDnWert {
    # Wert aus Zustandsobjekt (Hashtable/OrderedDictionary oder Objekt) von Get-MorpheusDatenordnerZustand
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] } else { return $null } }
    $pr = $Obj.PSObject.Properties[$Name]
    if ($pr) { return $pr.Value }
    return $null
}

function Get-GuiReparaturInfo {
    # state\datenordner-reparatur.json (18.10). Vorhanden = Datei existiert; Zeit = $null, wenn sie nicht lesbar ist.
    $info = @{ Vorhanden = $false; Zeit = $null }
    $p = Join-Path ([string]$script:Gui.DataRoot) 'state\datenordner-reparatur.json'
    try {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $info }
        $info.Vorhanden = $true
        $j = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8))
        $info.Zeit = ConvertTo-GuiLokaleZeit ([string]$j.zeit)
    }
    catch { }
    return $info
}

function ConvertTo-GuiLokaleZeit {
    # 'yyyy-MM-ddTHH:mm:ss' (auch mit Bruchteil) -> [datetime] oder $null
    param([string]$Text)
    try {
        return [datetime]::ParseExact($Text, [string[]]@('yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-ddTHH:mm:ss.FFFFFFF'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
    }
    catch { return $null }
}

function Assert-GuiFn {
    # Fehlt eine Safety-Funktion, antwortet der Endpunkt mit 501.
    param([string[]]$Name)
    if (-not (Test-GuiFn $Name)) { Stop-GuiRequest 501 'Diese Funktion ist noch nicht verfügbar (Safety.ps1 bzw. Defender.ps1 fehlt oder ist unvollständig).' }
}

function New-GuiSecret {
    # 32 Zufallsbytes als base64url (für Token, Startcode und Lesemarken)
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Test-GuiTokenEqual {
    # Vergleich in konstanter Zeit (unabhängig davon, wo sich die Werte unterscheiden).
    param([string]$A, [string]$B)
    $x = [Text.Encoding]::UTF8.GetBytes([string]$A)
    $y = [Text.Encoding]::UTF8.GetBytes([string]$B)
    $d = [int]($x.Length -bxor $y.Length)
    $n = [Math]::Max($x.Length, $y.Length)
    for ($i = 0; $i -lt $n; $i++) {
        $xi = 0; if ($i -lt $x.Length) { $xi = [int]$x[$i] }
        $yi = 0; if ($i -lt $y.Length) { $yi = [int]$y[$i] }
        $d = $d -bor ($xi -bxor $yi)
    }
    return ($d -eq 0)
}

function Send-GuiBytes {
    param($Res, [int]$Status, [string]$ContentType, [byte[]]$Bytes, [string]$Csp)
    $script:Gui.Status = $Status
    if (-not $Csp) { $Csp = $script:GuiCsp }
    $Res.StatusCode = $Status
    $Res.ContentType = $ContentType
    $Res.Headers.Set('Content-Security-Policy', $Csp)
    $Res.Headers.Set('X-Content-Type-Options', 'nosniff')
    $Res.Headers.Set('Referrer-Policy', 'no-referrer')
    $Res.Headers.Set('Cache-Control', 'no-store')
    if ($Status -eq 405) { $Res.Headers.Set('Allow', 'GET, POST') }
    $Res.ContentLength64 = $Bytes.Length
    if ($Bytes.Length -gt 0) { $Res.OutputStream.Write($Bytes, 0, $Bytes.Length) }
}

function Send-GuiJson {
    param($Res, [int]$Status, $Object)
    $json = ConvertTo-Json -InputObject $Object -Depth 8 -Compress
    Send-GuiBytes $Res $Status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

function Read-GuiBody {
    # Liest den JSON-Body (max. 256 KB). Leerer Body ergibt ein leeres Objekt.
    param($Req)
    if (-not $Req.HasEntityBody) { return [pscustomobject]@{} }
    if ($Req.ContentLength64 -gt $script:GuiMaxBody) { Stop-GuiRequest 413 'Anfrage zu groß.' }
    $sr = New-Object IO.StreamReader($Req.InputStream, [Text.Encoding]::UTF8)
    try {
        $buf = New-Object char[] 4096
        $sb = New-Object Text.StringBuilder
        while (($n = $sr.Read($buf, 0, $buf.Length)) -gt 0) {
            [void]$sb.Append($buf, 0, $n)
            if ($sb.Length -gt $script:GuiMaxBody) { Stop-GuiRequest 413 'Anfrage zu groß.' }
        }
        $text = $sb.ToString()
    }
    finally { $sr.Dispose() }
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    try { $obj = $text | ConvertFrom-Json -ErrorAction Stop }
    catch { Stop-GuiRequest 400 'Ungültiges JSON.' }
    if ($null -eq $obj) { return [pscustomobject]@{} }
    return $obj
}

function Get-GuiProp {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-GuiPropRaw {
    # Wie Get-GuiProp, aber ohne Auflösen von Arrays: ["C:"] bleibt ein Array und wird nicht zu "C:".
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return ,$p.Value }
    return $null
}

function Resolve-GuiReportPath {
    # Nur Dateinamen im festen Muster, aufgelöst im Ordner reports\ (Regex + GetFullPath + Präfix-Prüfung).
    # Zusätzlich (nur html): Wartungsberichte morpheus-(energy|akku|schlaf)_..., case-sensitive.
    param([string]$FileName, [string]$Ext)
    $wartung = ($Ext -ceq 'html') -and ($FileName -cmatch $script:GuiWartungReportRx)
    if (-not $wartung) {
        if ($FileName -notmatch $script:GuiReportRx) { return $null }
        if ([IO.Path]::GetExtension($FileName).TrimStart('.').ToLowerInvariant() -ne $Ext) { return $null }
    }
    $dir = [IO.Path]::GetFullPath((Join-Path $script:Gui.DataRoot 'reports')).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath((Join-Path $dir $FileName))
    if (-not $full.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
    return $full
}

$script:GuiSigcheckTitel = 'Unsignierte Systemdateien (Sigcheck)'
$script:GuiSigcheckCheck = 'Systemdateien: Signaturen (Sigcheck)'
# Wurzel für erlaubte Dateien; Tests überschreiben sie (Standard: %SystemRoot%\System32)
$script:GuiSystem32Root = $null

function Read-GuiReportJson {
    # Liest einen Bericht (voller Pfad aus Resolve-GuiReportPath) als Objekt.
    param([string]$Full)
    $bytes = [IO.File]::ReadAllBytes($Full)
    $start = 0
    if (($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)) { $start = 3 }
    $text = [Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
    try { return ($text | ConvertFrom-Json -ErrorAction Stop) }
    catch { Stop-GuiRequest 400 'Der Bericht ist nicht lesbar.' }
}

function Resolve-GuiBerichtDatei {
    # Prüft den Berichtsnamen (nur Dateiname im festen Muster) und liefert den vollen Pfad der JSON-Datei.
    param($Bericht)
    if (($Bericht -isnot [string]) -or ($Bericht -cnotmatch $script:GuiReportRx)) { Stop-GuiRequest 400 'bericht ist kein gültiger Berichtsname.' }
    $full = Resolve-GuiReportPath $Bericht 'json'
    if (-not $full) { Stop-GuiRequest 404 'Bericht nicht gefunden.' }
    return $full
}

function Get-GuiDateiSha256 {
    param([string]$Pfad)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $fs = New-Object IO.FileStream($Pfad, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { $hash = $sha.ComputeHash($fs) } finally { $fs.Dispose() }
    }
    finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Resolve-GuiSigcheckDatei {
    # Liefert { pfad; sha256 } einer Datei aus der Sigcheck-Tabelle des Berichts oder bricht mit 400/404/409 ab (Abschnitt 16.3).
    param($Bericht, $Pfad)
    $berichtFull = Resolve-GuiBerichtDatei $Bericht
    if (($Pfad -isnot [string]) -or ($Pfad.Length -lt 4) -or ($Pfad.Length -gt 260) -or ($Pfad -match '[\x00-\x1f\x7f]')) { Stop-GuiRequest 400 'pfad ist ungültig.' }
    if (($Pfad -split '[\\/]') -contains '..') { Stop-GuiRequest 400 'pfad ist ungültig.' }
    $wurzel = $script:GuiSystem32Root
    if (-not $wurzel) { $wurzel = [Environment]::SystemDirectory }
    try {
        $wurzel = [IO.Path]::GetFullPath($wurzel).TrimEnd('\') + '\'
        $full = [IO.Path]::GetFullPath($Pfad)
    }
    catch { Stop-GuiRequest 400 'pfad ist ungültig.' }
    if (-not $full.StartsWith($wurzel, [StringComparison]::OrdinalIgnoreCase)) { Stop-GuiRequest 400 'Es sind nur Dateien aus dem Windows-Ordner System32 erlaubt.' }
    $bericht = Read-GuiReportJson $berichtFull
    $tabelle = Get-GuiProp (Get-GuiProp $bericht 'Data') $script:GuiSigcheckTitel
    $zeile = $null
    foreach ($z in @($tabelle)) {
        $zp = Get-GuiProp $z 'Pfad'
        if (($zp -is [string]) -and ($zp -ieq $Pfad)) { $zeile = $z; break }
    }
    if (-not $zeile) { Stop-GuiRequest 404 'Die Datei steht nicht in der Sigcheck-Tabelle dieses Berichts.' }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Stop-GuiRequest 404 'Die Datei gibt es nicht mehr.' }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-GuiRequest 400 'Verknüpfungen (Reparse Points) sind nicht erlaubt.' }
    $soll = Get-GuiProp $zeile 'Sha256'
    if (($soll -isnot [string]) -or ($soll -cnotmatch '^[0-9a-f]{64}$')) { Stop-GuiRequest 409 'Der Bericht enthält keinen Hash zu dieser Datei. Bitte neu scannen.' }
    try { $ist = Get-GuiDateiSha256 $full }
    catch { Stop-GuiRequest 409 'Die Datei lässt sich nicht lesen.' }
    if ($ist -cne $soll) { Stop-GuiRequest 409 'Die Datei hat sich seit dem Scan geändert. Bitte neu scannen.' }
    return [ordered]@{ pfad = $full; sha256 = $ist }
}

function Get-GuiReportList {
    # Liest je Bericht nur Meta und zählt die Befunde (pro Datei nach Name + Änderungszeit gecacht).
    $dir = Join-Path $script:Gui.DataRoot 'reports'
    $files = @(Get-ChildItem -LiteralPath $dir -Filter 'pc-check_*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $script:GuiReportRx })
    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($f in $files) {
        $seen[$f.Name] = $true
        $stamp = '{0}-{1}' -f $f.LastWriteTimeUtc.Ticks, $f.Length
        $c = $script:Gui.ReportCache[$f.Name]
        if ($c -and $c.Stamp -eq $stamp) { $list.Add($c.Info); continue }
        try {
            $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $ser.MaxJsonLength = [int]::MaxValue
            $ser.RecursionLimit = 500
            $obj = $ser.DeserializeObject([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
            $meta = $obj['Meta']
            $counts = [ordered]@{ CRIT = 0; WARN = 0; TIPP = 0; ACK = 0; INFO = 0; OK = 0; SKIP = 0 }
            foreach ($fd in $obj['Findings']) {
                $s = [string]$fd['Status']
                if ($counts.Contains($s)) { $counts[$s] = [int]$counts[$s] + 1 }
            }
            $info = [ordered]@{
                name     = $f.BaseName
                created  = [string]$meta['Erstellt']
                version  = [string]$meta['Version']
                admin    = [bool]$meta['Admin']
                profil   = [string]$meta['Profil']
                computer = [string]$meta['Computer']
                hasHtml  = (Test-Path -LiteralPath (Join-Path $dir ($f.BaseName + '.html')) -PathType Leaf)
                counts   = $counts
            }
            $script:Gui.ReportCache[$f.Name] = @{ Stamp = $stamp; Info = $info }
            $list.Add($info)
        }
        catch { Write-GuiLog ("Bericht nicht lesbar: {0}: {1}" -f $f.Name, $_.Exception.Message) }
    }
    foreach ($k in @($script:Gui.ReportCache.Keys)) { if (-not $seen.ContainsKey($k)) { $script:Gui.ReportCache.Remove($k) } }
    return @($list | Sort-Object { $_.created } -Descending)
}

function Get-GuiHelp {
    $p = Join-Path $script:Gui.Root 'pc-check.hilfe.psd1'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Stop-GuiRequest 404 'pc-check.hilfe.psd1 nicht gefunden.' }
    $stamp = (Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks
    if ($script:Gui.HelpCache -and $script:Gui.HelpCache.Stamp -eq $stamp) { return $script:Gui.HelpCache.Data }
    $data = Import-PowerShellDataFile -LiteralPath $p
    $script:Gui.HelpCache = @{ Stamp = $stamp; Data = $data }
    return $data
}

function Save-GuiTextAtomic {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, $null) }
    else { Move-Item -LiteralPath $tmp -Destination $Path -Force }
}

#endregion

#region Eigene Spiele-Ordner (Abschnitt 14.8)

$script:GuiSpielordnerPlattformen = @('Steam', 'Epic', 'GOG', 'EA', 'Ubisoft', 'Xbox', 'Andere')

function Get-GuiSpielordnerFehler {
    # Prüft einen Eintrag { plattform, pfad }. Gibt den Grund als Text zurück oder $null, wenn alles passt.
    # -NurSyntax: ohne Zugriff auf das Dateisystem (für das Lesen; ein getrenntes Laufwerk soll den Eintrag nicht löschen).
    param($Eintrag, [switch]$NurSyntax)
    if (($null -eq $Eintrag) -or ($Eintrag -isnot [pscustomobject])) { return 'Der Eintrag muss ein Objekt mit plattform und pfad sein.' }
    $pl = Get-GuiProp $Eintrag 'plattform'
    $pf = Get-GuiProp $Eintrag 'pfad'
    if (($pl -isnot [string]) -or ($script:GuiSpielordnerPlattformen -cnotcontains $pl)) { return 'Unbekannte Plattform. Erlaubt: ' + ($script:GuiSpielordnerPlattformen -join ', ') + '.' }
    if (($pf -isnot [string]) -or ($pf.Length -eq 0)) { return 'Der Pfad fehlt.' }
    if ($pf.Length -gt 260) { return 'Der Pfad ist länger als 260 Zeichen.' }
    if ($pf -cnotmatch '^[A-Za-z]:\\') { return 'Der Pfad muss mit einem Laufwerk beginnen, z. B. F:\Games.' }
    if ($pf -match '[\x00-\x1f"<>|*?]') { return 'Der Pfad enthält ungültige Zeichen.' }
    $norm = Get-GuiSpielordnerPfadNorm $pf
    $rest = $norm.Substring(3)
    if ($rest.Length -gt 0) {
        if ($rest.Contains(':')) { return 'Der Pfad enthält ungültige Zeichen.' }
        foreach ($seg in ($rest -split '\\')) {
            if (($seg -eq '.') -or ($seg -eq '..')) { return 'Der Pfad darf kein . oder .. enthalten.' }
            if ($seg.Length -eq 0) { return 'Der Pfad enthält einen leeren Ordnernamen.' }
        }
    }
    if ($NurSyntax) { return $null }
    if (-not (Test-Path -LiteralPath $norm -PathType Container)) { return 'Der Ordner existiert nicht.' }
    try {
        if ((Get-Item -LiteralPath $norm -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { return 'Der Ordner ist ein Link (Junction oder Symlink) und wird nicht verwendet.' }
    }
    catch { return 'Der Ordner ist nicht lesbar.' }
    return $null
}

function Get-GuiSpielordnerPfadNorm {
    # / zu \, abschließendes \ weg (außer bei X:\)
    param([string]$Pfad)
    $p = $Pfad.Replace('/', '\')
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\') }
    if ($p -match '^[A-Za-z]:$') { $p += '\' }
    return $p
}

function Test-GuiSpielordnerEintraege {
    # Prüft die Liste für POST /api/spielordner; Fehler -> 400 "Eintrag N (<pfad>): <Grund>".
    # Rückgabe: bereinigtes Array von { plattform, pfad } (normalisiert, doppelte Pfade nur einmal).
    param($Eintraege)
    if (($null -eq $Eintraege) -or ($Eintraege -isnot [array])) { Stop-GuiRequest 400 'eintraege muss ein Array sein.' }
    $liste = @($Eintraege)
    if ($liste.Count -gt 50) { Stop-GuiRequest 400 'Höchstens 50 Einträge erlaubt.' }
    $clean = @()
    $gesehen = @{}
    $n = 0
    foreach ($e in $liste) {
        $n++
        $fehler = Get-GuiSpielordnerFehler $e
        if ($fehler) {
            $zeigen = ''
            $pf = Get-GuiProp $e 'pfad'
            if ($pf -is [string]) { $zeigen = $pf -replace '[\x00-\x1f]', '?'; if ($zeigen.Length -gt 80) { $zeigen = $zeigen.Substring(0, 80) + '…' } }
            Stop-GuiRequest 400 ("Eintrag {0} ({1}): {2}" -f $n, $zeigen, $fehler)
        }
        $norm = Get-GuiSpielordnerPfadNorm ([string]$e.pfad)
        $k = $norm.ToLowerInvariant()
        if ($gesehen.ContainsKey($k)) { continue }
        $gesehen[$k] = $true
        $clean += [pscustomobject][ordered]@{ plattform = [string]$e.plattform; pfad = $norm }
    }
    return @($clean)
}

function Read-GuiSpielordner {
    # Liest state\spielordner.json tolerant (fehlend/leer/kaputt = @()), behält nur Einträge, die die Syntaxprüfung bestehen.
    param([string]$Datei)
    $clean = @()
    try {
        if (-not (Test-Path -LiteralPath $Datei -PathType Leaf)) { return @() }
        $text = [IO.File]::ReadAllText($Datei, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($text)) { return @() }
        $gesehen = @{}
        foreach ($e in @($text | ConvertFrom-Json -ErrorAction Stop | ForEach-Object { $_ })) {
            if ($clean.Count -ge 50) { break }
            if (Get-GuiSpielordnerFehler $e -NurSyntax) { continue }
            $norm = Get-GuiSpielordnerPfadNorm ([string]$e.pfad)
            $k = $norm.ToLowerInvariant()
            if ($gesehen.ContainsKey($k)) { continue }
            $gesehen[$k] = $true
            $clean += [pscustomobject][ordered]@{ plattform = [string]$e.plattform; pfad = $norm }
        }
    }
    catch { return @() }
    return @($clean)
}

#endregion

#region Jobs

$script:GuiJobScripts = @{
    refresh = {
        param($Root, $Safety)
        # Modulpfad im Job-Prozess begrenzen (2.3.3, wie in pc-check-gui.ps1)
        $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
        . $Safety
        Write-Information -MessageData "[$(Get-Date -Format HH:mm:ss)] Zustände der Anpassungen lesen" -InformationAction Continue
        $cat = @(Get-PcCheckCatalog -Root $Root)
        Get-PcCheckActionStates -Root $Root -Catalog $cat
    }
    # Code kommt aus $Root, Daten (Journal) aus $DataRoot
    run     = {
        param($Root, $Safety, $Ids, $Variante, $DataRoot)
        # Modulpfad im Job-Prozess begrenzen (2.3.3, wie in pc-check-gui.ps1)
        $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
        . $Safety
        if ($Variante) { Invoke-PcCheckChange -Root $Root -DataRoot $DataRoot -Ids $Ids -Variante $Variante }
        else { Invoke-PcCheckChange -Root $Root -DataRoot $DataRoot -Ids $Ids }
    }
    undo    = {
        param($Root, $Safety, $EntryId, $Force, $DataRoot, $VorReparatur)
        # Modulpfad im Job-Prozess begrenzen (2.3.3, wie in pc-check-gui.ps1)
        $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
        . $Safety
        $u = @{ Root = $Root; DataRoot = $DataRoot; EntryId = $EntryId }
        if ($Force) { $u['Force'] = $true }
        if ($VorReparatur -eq $true) { $u['VorReparaturBestaetigt'] = $true }
        Undo-PcCheckChange @u
    }
    scan    = {
        param($Root, $ScanArgs, $DataRoot)
        # Modulpfad im Job-Prozess begrenzen (2.3.3, wie in pc-check-gui.ps1)
        $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
        $t0 = Get-Date
        $ps1 = Join-Path $Root 'pc-check.ps1'
        if (-not (Test-Path -LiteralPath $ps1)) { throw 'pc-check.ps1 wurde nicht gefunden.' }
        Write-Information -MessageData "[$(Get-Date -Format HH:mm:ss)] Scan gestartet" -InformationAction Continue
        $al = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ps1) + @($ScanArgs)
        & ([Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\powershell.exe') @al 2>&1 | ForEach-Object {
            $s = ("$_").TrimEnd()
            if ($s.Trim()) { Write-Information -MessageData "[$(Get-Date -Format HH:mm:ss)] $s" -InformationAction Continue }
        }
        $code = $LASTEXITCODE
        if ($code -ne 0) { throw "Der Scan wurde mit Fehlercode $code beendet." }
        $neu = Get-ChildItem -LiteralPath (Join-Path $DataRoot 'reports') -Filter 'pc-check_*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $t0.AddSeconds(-5) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $name = $null; if ($neu) { $name = $neu.BaseName }
        [pscustomobject]@{ exitCode = $code; bericht = $name }
    }
    # Speicherverbraucher und Spiele zählen; Cache atomar nach state\speicher.json (Save-GuiTextAtomic gibt es im Job nicht)
    speicher = {
        param($Root, $DataRoot)
        # Modulpfad im Job-Prozess begrenzen (2.3.3, wie in pc-check-gui.ps1)
        $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
        $lib = Join-Path $Root 'gui\lib\Speicher.ps1'
        if (-not (Test-Path -LiteralPath $lib -PathType Leaf)) { throw 'gui\lib\Speicher.ps1 wurde nicht gefunden.' }
        . $lib
        $manuell = @(Read-MorpheusSpielordner -Datei (Join-Path $DataRoot 'state\spielordner.json'))
        $x = Get-MorpheusSpeicher -Manuell $manuell -Fortschritt { param($Text) Write-Information -MessageData "[$(Get-Date -Format HH:mm:ss)] $Text" -InformationAction Continue }
        $json = ConvertTo-Json -InputObject $x -Depth 8 -Compress
        $p = Join-Path $DataRoot 'state\speicher.json'
        $dir = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $tmp = $p + '.tmp'
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
        if (Test-Path -LiteralPath $p) { [IO.File]::Replace($tmp, $p, $null) }
        else { Move-Item -LiteralPath $tmp -Destination $p -Force }
        [pscustomobject]@{ stand = $x.stand }
    }
    defender = {
        param($Root, $DefenderPath, $Art, $Pfad)
        # Modulpfad im Job-Prozess begrenzen (2.3.3, wie in pc-check-gui.ps1)
        $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
        . $DefenderPath
        if ($Art -ceq 'datei') { Invoke-MorpheusDefenderAktion -Art $Art -Pfad $Pfad }
        else { Invoke-MorpheusDefenderAktion -Art $Art }
    }
    # Wartung & Reparatur und winget-Updates (Abschnitt 18.5). Pakete kommen als JSON-Text, weil Start-Job Objekte serialisiert.
    wartung = {
        param($Root, $SafetyPath, $WartungPath, $DataRoot, $Werkzeug, $Laufwerk, $PaketeJson, $OhnePunkt, $AbbruchDatei)
        $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
        . $SafetyPath
        . $WartungPath
        $pakete = $null
        if ($PaketeJson) {
            $pakete = @(ConvertFrom-Json -InputObject ([string]$PaketeJson) | ForEach-Object { $_ } | ForEach-Object {
                    [pscustomobject]@{ id = [string]$_.id; name = [string]$_.name; von = [string]$_.von; auf = [string]$_.auf }
                })
            if ($pakete.Count -eq 0) { $pakete = $null }
        }
        $a = @{ Root = $Root; DataRoot = $DataRoot; Werkzeug = $Werkzeug }
        if ($Laufwerk) { $a['Laufwerk'] = $Laufwerk }
        if ($null -ne $pakete) { $a['Pakete'] = $pakete }
        if (($OhnePunkt -is [bool]) -and $OhnePunkt) { $a['OhnePunkt'] = $true }
        if ($AbbruchDatei) { $a['AbbruchDatei'] = $AbbruchDatei }
        Invoke-MorpheusWartung @a
    }
    updatesuche = {
        param($Root, $WingetLibPath)
        $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
        . $WingetLibPath
        Get-MorpheusWingetUpdates -Fortschritt
    }
    sysinternals = {
        param($Root, $SysPath, $DataRoot)
        # Modulpfad im Job-Prozess begrenzen (2.3.3, wie in pc-check-gui.ps1)
        $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
        . $SysPath
        # Die Zustimmung wird erst hier gespeichert, also nach der Windows-Bestätigung
        $null = Set-MorpheusSysZustimmung -DataRoot $DataRoot -Akzeptiert $true
        Install-MorpheusSysWerkzeuge -DataRoot $DataRoot
    }
}

function Format-GuiDialogWert {
    # Werte aus Berichten/Eingaben für den Windows-Bestätigungsdialog: keine Steuer- und Bidi-Zeichen, gekürzt.
    param([AllowNull()]$Text, [int]$Max = 200)
    $s = [string]$Text
    # Auch NEL, unsichtbare Richtungsmarken (ALM, LRM, RLM) und Nullbreite-Zeichen (2.4, Sicherheitspr\u00FCfung W3)
    $s = [regex]::Replace($s, '[\u0000-\u001F\u007F\u0085\u061C\u200B-\u200F\u2028\u2029\u202A-\u202E\u2066-\u2069\uFEFF]', ' ')
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max) + [string][char]0x2026 }
    return $s
}

function Confirm-GuiElevated {
    # Bestätigung durch ein Windows-Dialogfenster DIESES (Admin-)Prozesses. Windows verhindert per UIPI, dass Programme
    # ohne Adminrechte in dieses Fenster klicken oder tippen. Ein Schadprogramm, das das Edge-Fenster fernsteuert oder das
    # Token aus dessen Speicher liest, kann eine Änderung also anstoßen, aber nicht bestätigen.
    param([string]$Text)
    if (-not ('MorpheusUi.Native' -as [type])) {
        Add-Type -Namespace MorpheusUi -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);'
    }
    # MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2 (Nein vorbelegt) | MB_SYSTEMMODAL | MB_SETFOREGROUND | MB_TOPMOST
    $r = [MorpheusUi.Native]::MessageBoxW([IntPtr]::Zero, $Text, 'Morpheus – Änderung bestätigen', 0x00051124)
    return ($r -eq 6)
}

function Start-GuiJob {
    # Extra: zusätzliche Felder des Job-Records (z. B. Werkzeug, Abbruch, AbbruchDatei bei 'wartung')
    param([string]$Art, [object[]]$JobArgs, [bool]$Mutating, [string]$Confirm, [hashtable]$Extra)
    # Verteidigung in der Tiefe: Im Nur-Lesen-Modus startet kein ändernder Job und kein Scan, egal wer fragt
    if ($script:Gui.ReadOnly -and ($Art -in 'run', 'undo', 'scan', 'speicher', 'defender', 'sysinternals', 'wartung', 'updatesuche')) { Stop-GuiRequest 403 (Get-GuiReadOnlyMessage) }
    if ($Art -in 'run', 'undo', 'defender', 'sysinternals', 'wartung') {
        if (-not $Confirm) { Stop-GuiRequest 500 'Interner Fehler: Bestätigungstext fehlt.' }
        Write-GuiLog "Warte auf Bestätigung im Windows-Dialog ($Art)"
        $ok = Confirm-GuiElevated $Confirm
        # Während der Dialog offen war, stand die Hauptschleife: Heartbeat-Uhr neu starten, sonst endet der Server danach
        $script:Gui.LastHeartbeat = Get-Date
        if (-not $ok) {
            Write-GuiLog "Im Windows-Dialog abgelehnt ($Art)"
            Stop-GuiRequest 403 'Im Windows-Bestätigungsdialog abgelehnt. Es wurde nichts geändert.'
        }
    }
    $job = Start-Job -ScriptBlock $script:GuiJobScripts[$Art] -ArgumentList $JobArgs
    $id = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
    $rec = @{
        Id = $id; Art = $Art; Job = $job; Status = 'running'; Mutating = $Mutating
        Log = (New-Object System.Collections.Generic.List[string])
        Seen = @{ Information = 0; Warning = 0; Error = 0 }
        Started = Get-Date; Finished = $null; Ergebnis = $null
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $rec[[string]$k] = $Extra[$k] } }
    $script:Gui.Jobs[$id] = $rec
    Write-GuiLog "Job $id gestartet ($Art)"
    return $id
}

function Get-GuiJobStreamLines {
    param($Rec)
    $cj = $null
    if ($Rec.Job.ChildJobs.Count -gt 0) { $cj = $Rec.Job.ChildJobs[0] }
    if (-not $cj) { return }
    foreach ($stream in 'Information', 'Warning', 'Error') {
        $col = $cj.$stream
        for ($i = [int]$Rec.Seen[$stream]; $i -lt $col.Count; $i++) {
            $item = $col[$i]
            if ($stream -eq 'Information') { $text = [string]$item.MessageData }
            elseif ($stream -eq 'Warning') { $text = '[' + (Get-Date -Format HH:mm:ss) + '] WARNUNG: ' + [string]$item.Message }
            else { $text = '[' + (Get-Date -Format HH:mm:ss) + '] FEHLER: ' + [string]$item }
            $Rec.Log.Add($text)
        }
        $Rec.Seen[$stream] = $col.Count
    }
}

function Remove-GuiJobNoise {
    # Receive-Job hängt PSComputerName/RunspaceId/PSShowComputerName an; die gehören nicht ins Ergebnis.
    param($Item)
    $noise = 'PSComputerName', 'RunspaceId', 'PSShowComputerName'
    if ($Item -is [System.Collections.IDictionary]) { foreach ($n in $noise) { if ($Item.Contains($n)) { $Item.Remove($n) } }; return $Item }
    if (($Item -is [psobject]) -and ($Item -isnot [string]) -and $Item.PSObject.Properties['RunspaceId']) { return ($Item | Select-Object -Property * -ExcludeProperty $noise) }
    return $Item
}
function Get-GuiErgebnisWert {
    # Feld aus einem Job-Ergebnis (Hashtable oder Objekt)
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] }; return $null }
    return (Get-GuiProp $Obj $Name)
}

function Complete-GuiJob {
    # Nacharbeit nach Ende eines Jobs (Abschnitt 18.5): Freigabe nach 'punkt-fehlt', Ergebnis der winget-Suche merken,
    # Abbruch-Flag-Datei von wartung entfernen. Fehler hier dürfen den Job nicht ändern.
    param($Rec)
    try {
        $g = $script:Gui
        if ($Rec.Art -eq 'wartung') {
            if ($Rec.Status -eq 'done') {
                $st = Get-GuiErgebnisWert $Rec.Ergebnis 'status'
                $wz = [string](Get-GuiErgebnisWert $Rec.Ergebnis 'werkzeug')
                if ((-not $wz) -and $Rec.ContainsKey('Werkzeug')) { $wz = [string]$Rec.Werkzeug }
                if (($st -is [string]) -and ($st -ceq 'punkt-fehlt') -and $wz) {
                    if ($null -eq $g.PunktFehlt) { $g.PunktFehlt = @{} }
                    $pids = $null
                    if ($Rec.ContainsKey('Ids') -and $Rec.Ids) { $pids = @($Rec.Ids | ForEach-Object { [string]$_ }) }
                    $g.PunktFehlt[$wz] = @{ Zeit = (Get-Date); Ids = $pids }
                }
            }
            if ($Rec.ContainsKey('AbbruchDatei') -and $Rec.AbbruchDatei) {
                try { if (Test-Path -LiteralPath $Rec.AbbruchDatei -PathType Leaf) { Remove-Item -LiteralPath $Rec.AbbruchDatei -Force -ErrorAction SilentlyContinue } } catch { }
            }
        }
        elseif ($Rec.Art -eq 'updatesuche') {
            if ($Rec.Status -eq 'done') {
                $erg = $Rec.Ergebnis
                $liste = New-Object System.Collections.Generic.List[object]
                foreach ($z in @(Get-GuiErgebnisWert $erg 'zeilen')) {
                    if ($null -eq $z) { continue }
                    $liste.Add([pscustomobject][ordered]@{
                            id          = [string](Get-GuiErgebnisWert $z 'Id')
                            name        = [string](Get-GuiErgebnisWert $z 'Name')
                            installiert = [string](Get-GuiErgebnisWert $z 'Installiert')
                            verfuegbar  = [string](Get-GuiErgebnisWert $z 'Verfuegbar')
                            kategorie   = [string](Get-GuiErgebnisWert $z 'Kategorie')
                        })
                }
                $stand = Get-GuiErgebnisWert $erg 'stand'
                if ($stand -is [datetime]) { $stand = $stand.ToString('yyyy-MM-ddTHH:mm:ss') }
                if (($null -eq $stand) -or ("$stand" -eq '')) { $stand = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }
                $fehler = Get-GuiErgebnisWert $erg 'fehler'
                if ($null -ne $fehler) { $fehler = [string]$fehler; if ($fehler -eq '') { $fehler = $null } }
                $g.Updates = @{ stand = [string]$stand; liste = @($liste.ToArray()); fehler = $fehler }
            }
            else {
                $alt = $g.Updates
                $liste = @(); $stand = $null
                if ($alt) { $liste = @($alt.liste); $stand = $alt.stand }
                $g.Updates = @{ stand = $stand; liste = $liste; fehler = [string](Get-GuiErgebnisWert $Rec.Ergebnis 'error') }
            }
        }
    }
    catch { Write-GuiLog ("Job {0} Nacharbeit fehlgeschlagen: {1}" -f $Rec.Id, $_.Exception.Message) }
}

function Update-GuiJobs {
    foreach ($rec in @($script:Gui.Jobs.Values)) {
        if ($rec.Status -eq 'running') {
            try {
                Get-GuiJobStreamLines $rec
                $state = $rec.Job.State
                if ($state -in 'Completed', 'Failed', 'Stopped') {
                    $reason = $null
                    if (($rec.Job.ChildJobs.Count -gt 0) -and $rec.Job.ChildJobs[0].JobStateInfo.Reason) { $reason = $rec.Job.ChildJobs[0].JobStateInfo.Reason.Message }
                    $out = @(Receive-Job -Job $rec.Job -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -InformationAction SilentlyContinue)
                    $out = @($out | ForEach-Object { Remove-GuiJobNoise $_ })
                    if ($state -eq 'Completed') {
                        $rec.Status = 'done'
                        # speicher/defender: wie die anderen Arten das letzte Objekt (Ausgabe ist je nur ein Objekt)
                        if ($rec.Art -eq 'run') { $rec.Ergebnis = @($out) }
                        elseif ($out.Count -gt 0) { $rec.Ergebnis = $out[$out.Count - 1] }
                        if (($rec.Art -eq 'refresh') -and ($rec.Ergebnis -is [System.Collections.IDictionary])) { $script:Gui.ActionStates = $rec.Ergebnis }
                    }
                    else {
                        $rec.Status = 'failed'
                        if (-not $reason) { $reason = 'Der Job wurde abgebrochen.' }
                        $rec.Ergebnis = [ordered]@{ error = $reason }
                        $rec.Log.Add('[' + (Get-Date -Format HH:mm:ss) + '] FEHLER: ' + $reason)
                    }
                    $rec.Finished = Get-Date
                    Remove-Job -Job $rec.Job -Force -ErrorAction SilentlyContinue
                    $rec.Job = $null
                    Complete-GuiJob $rec
                    Write-GuiLog ("Job {0} beendet ({1}): {2}" -f $rec.Id, $rec.Art, $rec.Status)
                }
            }
            catch {
                $rec.Status = 'failed'; $rec.Finished = Get-Date
                $rec.Ergebnis = [ordered]@{ error = $_.Exception.Message }
                Write-GuiLog ("Job {0} Auswertung fehlgeschlagen: {1}" -f $rec.Id, $_.Exception.Message)
                Complete-GuiJob $rec
            }
        }
        elseif ($rec.Finished -and (((Get-Date) - $rec.Finished).TotalMinutes -gt $script:GuiJobKeepMinutes)) {
            $script:Gui.Jobs.Remove($rec.Id)
        }
    }
}

function Get-GuiRunningJobs {
    param([switch]$MutatingOnly)
    return @($script:Gui.Jobs.Values | Where-Object { ($_.Status -eq 'running') -and ((-not $MutatingOnly) -or $_.Mutating) })
}

function Get-GuiRunningDefenderJob {
    return @($script:Gui.Jobs.Values | Where-Object { ($_.Status -eq 'running') -and ($_.Art -eq 'defender') }) | Select-Object -First 1
}

function Get-GuiRunningScanJob {
    return @($script:Gui.Jobs.Values | Where-Object { ($_.Status -eq 'running') -and ($_.Art -eq 'scan') }) | Select-Object -First 1
}

function Get-GuiRunningSysJob {
    return @($script:Gui.Jobs.Values | Where-Object { ($_.Status -eq 'running') -and ($_.Art -eq 'sysinternals') }) | Select-Object -First 1
}

#endregion

#region Wartung & Reparatur, Updates (Abschnitt 18)

$script:GuiPunktFreigabeMinuten = 15
$script:GuiLaufwerkeCacheSek = 60

function Get-GuiRunningWartungJob {
    return @($script:Gui.Jobs.Values | Where-Object { ($_.Status -eq 'running') -and ($_.Art -eq 'wartung') }) | Select-Object -First 1
}

function Get-GuiRunningUpdateSucheJob {
    return @($script:Gui.Jobs.Values | Where-Object { ($_.Status -eq 'running') -and ($_.Art -eq 'updatesuche') }) | Select-Object -First 1
}

function Get-GuiWartungDir {
    return (Join-Path (Join-Path $script:Gui.DataRoot 'state') 'wartung')
}

function Initialize-GuiWartungDir {
    # Ordner für die Abbruch-Flag-Dateien anlegen; Reste früherer Sitzungen löschen.
    try {
        $dir = Get-GuiWartungDir
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.flag' -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    catch { Write-GuiLog ('Wartungsordner: ' + $_.Exception.Message) }
}

function New-GuiAbbruchDatei {
    # Voller Pfad einer neuen Flag-Datei (die Datei selbst entsteht erst beim Abbrechen). Der Name wird nie an den Client gegeben.
    $dir = Get-GuiWartungDir
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    return (Join-Path $dir ('abbruch-' + (New-GuiSecret).Substring(0, 16) + '.flag'))
}

function Get-GuiWartungLaufwerke {
    # Feste Laufwerke aus dem Server-Cache (60 s). Nur diese Liste gilt für die Prüfung der Eingabe.
    $g = $script:Gui
    $c = $g.WartungLaufwerke
    if ($c -and $c.Zeit -and (((Get-Date) - $c.Zeit).TotalSeconds -lt $script:GuiLaufwerkeCacheSek)) { return @($c.Liste) }
    $liste = @()
    try { $liste = @(Get-MorpheusWartungLaufwerke) }
    catch { Write-GuiLog ('Laufwerke: ' + $_.Exception.Message) }
    $g.WartungLaufwerke = @{ Zeit = (Get-Date); Liste = $liste }
    return @($liste)
}

function Test-GuiPunktFreigabe {
    # true, wenn dieses Werkzeug in den letzten 15 Minuten mit 'punkt-fehlt' endete.
    # Mit -MitIds muss die (sortierte) Id-Menge exakt der des gescheiterten Laufs entsprechen (winget.upgrade: gleiche Paketauswahl).
    param([string]$Werkzeug, [string[]]$Ids, [switch]$MitIds)
    $p = $script:Gui.PunktFehlt
    if (($null -eq $p) -or (-not $p.ContainsKey($Werkzeug))) { return $false }
    $e = $p[$Werkzeug]
    $zeit = $e
    $gespeichert = $null
    if ($e -is [System.Collections.IDictionary]) { $zeit = $e['Zeit']; $gespeichert = $e['Ids'] }
    if ($zeit -isnot [datetime]) { return $false }
    if ((((Get-Date) - $zeit).TotalMinutes) -ge $script:GuiPunktFreigabeMinuten) { return $false }
    if ($MitIds) {
        if ($null -eq $gespeichert) { return $false }
        $a = @($gespeichert | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
        $b = @($Ids | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
        if ($a.Count -ne $b.Count) { return $false }
        for ($k = 0; $k -lt $a.Count; $k++) { if ($a[$k] -cne $b[$k]) { return $false } }
    }
    return $true
}

function Get-GuiPunktFehlt {
    $ids = @()
    $p = $script:Gui.PunktFehlt
    if ($p) { $ids = @($p.Keys | Where-Object { Test-GuiPunktFreigabe ([string]$_) } | Sort-Object | ForEach-Object { [string]$_ }) }
    return $ids
}

function Assert-GuiWartungFrei {
    # 409-Sperren vor dem Start (Abschnitt 18.5)
    # Alle wartung-Jobs gelten als ändernd (Mutating), auch Diagnose: Auch sie schreiben ins Journal, und das Journal wird ohne Sperre
    # gelesen/geschrieben. Darum blockieren laufende ändernde Jobs jeden Start, und ein Diagnose-Lauf blockiert run/undo.
    param([bool]$Aendernd = $true)
    if (Get-GuiRunningWartungJob) { Stop-GuiRequest 409 'Es läuft bereits ein Wartungswerkzeug.' }
    if ($Aendernd -and ((Get-GuiRunningJobs -MutatingOnly).Count -gt 0)) { Stop-GuiRequest 409 'Es läuft bereits eine Änderung.' }
    $g = $script:Gui
    if ($g.Offline -and ($g.Offline.Status -eq 'countdown')) { Stop-GuiRequest 409 'Es läuft bereits ein Offline-Scan-Countdown.' }
}

function Get-GuiOhnePunkt {
    # Liest ohnePunkt aus dem Body (nur genau Boolean, sonst 400)
    param($Body)
    $v = Get-GuiPropRaw $Body 'ohnePunkt'
    if ($null -eq $v) { return $false }
    if ($v -isnot [bool]) { Stop-GuiRequest 400 'ohnePunkt muss true oder false sein.' }
    return $v
}

function Assert-GuiOhnePunkt {
    # ohnePunkt nur bei Klasse reparatur und frischer Freigabe nach 'punkt-fehlt'
    # Bei winget.upgrade zusätzlich nur für dieselbe Paketauswahl (-Ids)
    param([string]$Klasse, [string]$Werkzeug, [string[]]$Ids)
    $frei = $false
    if ($Klasse -ceq 'reparatur') {
        if ($PSBoundParameters.ContainsKey('Ids')) { $frei = Test-GuiPunktFreigabe $Werkzeug -Ids $Ids -MitIds }
        else { $frei = Test-GuiPunktFreigabe $Werkzeug }
    }
    if (-not $frei) {
        Stop-GuiRequest 400 'Ohne Wiederherstellungspunkt geht es nur, nachdem Windows eben keinen anlegen konnte.'
    }
}

function New-GuiWartungDialogText {
    # Bestätigungstext (Abschnitt 18.5). Titel/Befehl/Erklärung stammen aus dem Katalog, das Laufwerk wurde geprüft.
    param($Werkzeug, [string]$Laufwerk, [bool]$OhnePunkt)
    $befehl = [string]$Werkzeug.befehl
    if ($Laufwerk) { $befehl = $befehl.Replace('<LW>', $Laufwerk) }
    $t = "Morpheus-Werkzeug mit Administratorrechten starten?`n`n" + (Format-GuiDialogWert $Werkzeug.titel 200) + "`nBefehl: " + (Format-GuiDialogWert $befehl 300)
    if ($Werkzeug.klasse -ceq 'diagnose') { $t += "`n`nDieses Werkzeug liest nur und ändert nichts." }
    elseif ($Werkzeug.klasse -ceq 'wartung') { $t += "`n`nHarmlose Wartung: " + (Format-GuiDialogWert $Werkzeug.erklaerung 400) }
    else {
        $t += "`n`nNICHT UMKEHRBAR: Das Ergebnis lässt sich nicht unter 'Änderungen' zurücknehmen."
        if ($OhnePunkt) { $t += "`n`nACHTUNG: OHNE Wiederherstellungspunkt. Windows konnte eben keinen anlegen. Fortfahren nur, wenn du das bewusst so willst." }
        else { $t += " Vorher legt Morpheus einen Wiederherstellungspunkt an und prüft ihn; fehlt er, startet nichts." }
    }
    $t += "`n`nHast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'."
    return $t
}

function Get-GuiWartungWerkzeug {
    # Katalogeintrag (öffentliches Objekt) zur Id oder $null
    param([string]$Id)
    foreach ($w in @(Get-MorpheusWartungWerkzeuge)) { if ([string]$w.id -ceq $Id) { return $w } }
    return $null
}

function Invoke-GuiWartungStart {
    param($Body)
    Assert-GuiWritable
    Assert-GuiFn 'Get-MorpheusWartungWerkzeuge', 'Get-MorpheusWartungLaufwerke', 'Test-MorpheusWartungAuftrag'
    $g = $script:Gui
    $wz = Get-GuiPropRaw $Body 'werkzeug'
    if (($wz -isnot [string]) -or ($wz -cnotmatch '^[a-z0-9.-]{1,40}\z')) { Stop-GuiRequest 400 'werkzeug ist ungültig.' }
    $lw = Get-GuiPropRaw $Body 'laufwerk'
    if (($null -ne $lw) -and (($lw -isnot [string]) -or ($lw.Length -gt 10))) { Stop-GuiRequest 400 'laufwerk ist ungültig.' }
    $op = Get-GuiOhnePunkt $Body
    # Programm-Updates laufen nur über /api/updates/installieren, die Zuverlässigkeitsansicht hat eine eigene Route
    if (@('winget.upgrade', 'perfmon.rel') -ccontains $wz) { Stop-GuiRequest 400 'Dieses Werkzeug lässt sich hier nicht starten.' }
    $prm = @{ Werkzeug = $wz; Laufwerke = @(Get-GuiWartungLaufwerke) }
    if ($null -ne $lw) { $prm['Laufwerk'] = $lw }
    $fehler = Test-MorpheusWartungAuftrag @prm
    if ($fehler) { Stop-GuiRequest 400 ([string]$fehler) }
    $w = Get-GuiWartungWerkzeug $wz
    if (-not $w) { Stop-GuiRequest 400 'Unbekanntes Werkzeug.' }
    Assert-GuiWartungFrei $true
    if ($op) { Assert-GuiOhnePunkt ([string]$w.klasse) $wz }
    $text = New-GuiWartungDialogText $w $lw $op
    $flag = New-GuiAbbruchDatei
    $extra = @{ Werkzeug = $wz; Abbruch = [string]$w.abbruch; AbbruchDatei = $flag }
    $id = Start-GuiJob 'wartung' @($g.Root, $g.SafetyPath, $g.WartungPath, $g.DataRoot, $wz, $lw, $null, $op, $flag) $true $text $extra
    if ($op -and $g.PunktFehlt) { $g.PunktFehlt.Remove($wz) }
    return $id
}

function Invoke-GuiUpdatesInstall {
    param($Body)
    Assert-GuiWritable
    Assert-GuiFn 'Get-MorpheusWartungWerkzeuge'
    $g = $script:Gui
    $idsProp = $null
    if ($Body) { $idsProp = $Body.PSObject.Properties['ids'] }
    $ids = $null
    if ($idsProp) { $ids = $idsProp.Value }
    if (($null -eq $ids) -or ($ids -isnot [array])) { Stop-GuiRequest 400 'ids muss ein Array sein.' }
    $ids = @($ids)
    if (($ids.Count -lt 1) -or ($ids.Count -gt 30)) { Stop-GuiRequest 400 'Es sind 1 bis 30 Programme erlaubt.' }
    $op = Get-GuiOhnePunkt $Body
    $liste = @()
    if ($g.Updates) { $liste = @($g.Updates.liste) }
    $gewaehlt = New-Object System.Collections.Generic.List[object]
    $gesehen = New-Object System.Collections.Generic.List[string]
    foreach ($i in $ids) {
        if (($i -isnot [string]) -or ($i.Length -lt 1) -or ($i.Length -gt 128)) { Stop-GuiRequest 400 'Ungültige Programm-Id.' }
        if ($gesehen.Contains($i)) { Stop-GuiRequest 400 'Eine Programm-Id steht doppelt in der Liste.' }
        $gesehen.Add($i)
        $idOk = $false
        if (Test-GuiFn 'Test-MorpheusWingetId') { $idOk = [bool](Test-MorpheusWingetId -Id $i) }
        else { $idOk = ($i -cmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$') }
        if (-not $idOk) { Stop-GuiRequest 400 'Die Programm-Id ist unvollständig oder ungültig (von winget gekürzt). Bitte über winget selbst aktualisieren.' }
        $treffer = $null
        foreach ($u in $liste) { if (([string]$u.id -ceq $i) -and ([string]$u.kategorie -ceq 'Programm')) { $treffer = $u; break } }
        if (-not $treffer) { Stop-GuiRequest 400 'Dieses Programm steht nicht in der letzten Updatesuche oder lässt sich hier nicht aktualisieren.' }
        $gewaehlt.Add($treffer)
    }
    $w = Get-GuiWartungWerkzeug 'winget.upgrade'
    $klasse = 'reparatur'; $abbruch = 'nach-paket'
    if ($w) { $klasse = [string]$w.klasse; $abbruch = [string]$w.abbruch }
    Assert-GuiWartungFrei $true
    if (Get-GuiRunningUpdateSucheJob) { Stop-GuiRequest 409 'Die Suche nach Updates läuft noch. Bitte warten, bis sie fertig ist.' }
    $idsSortiert = @($gesehen.ToArray() | Sort-Object -CaseSensitive)
    if ($op) { Assert-GuiOhnePunkt $klasse 'winget.upgrade' $idsSortiert }
    $zeilen = foreach ($u in $gewaehlt) {
        '• ' + (Format-GuiDialogWert $u.name 80) + ': ' + (Format-GuiDialogWert $u.installiert 80) + ' → ' + (Format-GuiDialogWert $u.verfuegbar 80)
    }
    $text = "Diese Programme mit winget aktualisieren?`n`n" + (@($zeilen) -join "`n") + "`n`nProgramm-Updates lassen sich nicht über 'Änderungen' zurücknehmen. "
    if ($op) { $text += "`n`nACHTUNG: OHNE Wiederherstellungspunkt. Windows konnte eben keinen anlegen. Fortfahren nur, wenn du das bewusst so willst. " }
    else { $text += 'Vorher wird ein Wiederherstellungspunkt angelegt. ' }
    $text += "winget lädt aus den Herstellerquellen und nimmt die Lizenzbedingungen der Pakete an.`n`nwinget läuft ohne Adminrechte. Braucht ein Programm Adminrechte, fragt Windows danach selbst; dort den Herausgeber prüfen.`n`nHast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'."
    # Pakete kommen aus der Liste des Servers, nie aus dem Body
    $pakete = @(foreach ($u in $gewaehlt) { [pscustomobject][ordered]@{ id = [string]$u.id; name = [string]$u.name; von = [string]$u.installiert; auf = [string]$u.verfuegbar } })
    $json = ConvertTo-Json -InputObject @($pakete) -Compress
    $flag = New-GuiAbbruchDatei
    $extra = @{ Werkzeug = 'winget.upgrade'; Abbruch = $abbruch; AbbruchDatei = $flag; Ids = $idsSortiert }
    $id = Start-GuiJob 'wartung' @($g.Root, $g.SafetyPath, $g.WartungPath, $g.DataRoot, 'winget.upgrade', $null, $json, $op, $flag) $true $text $extra
    if ($op -and $g.PunktFehlt) { $g.PunktFehlt.Remove('winget.upgrade') }
    return $id
}

#endregion

#region Offline-Scan (Countdown)

function Get-GuiOfflineState {
    # Zustand für die API: status keiner|countdown|abgebrochen|gestartet|fehler, rest = ganze Sekunden (nur im Countdown)
    $o = $script:Gui.Offline
    if ($null -eq $o) { return [ordered]@{ status = 'keiner'; rest = 0; meldung = '' } }
    $rest = 0
    if ($o.Status -eq 'countdown') { $rest = [Math]::Max(0, [int][Math]::Ceiling(($o.Ende - (Get-Date)).TotalSeconds)) }
    return [ordered]@{ status = [string]$o.Status; rest = $rest; meldung = [string]$o.Meldung }
}

function Set-GuiOfflineState {
    param([string]$Status, [string]$Meldung)
    $script:Gui.Offline.Status = $Status
    $script:Gui.Offline.Meldung = $Meldung
    Write-GuiLog ("Offline-Scan: {0} {1}" -f $Status, $Meldung)
}

function Assert-GuiOfflineErlaubt {
    # Der Offline-Scan startet den PC neu: nie während eines Wartungswerkzeugs oder einer Änderung
    if ((Get-GuiRunningWartungJob) -or ((Get-GuiRunningJobs -MutatingOnly).Count -gt 0)) {
        Stop-GuiRequest 409 'Während ein Wartungswerkzeug oder eine Änderung läuft, ist der Offline-Scan gesperrt (der PC würde neu starten).'
    }
}

function Invoke-GuiOfflineStart {
    # Status steht VOR dem Aufruf auf 'gestartet', damit nichts ein zweites Mal auslöst.
    Set-GuiOfflineState 'gestartet' 'Der Offline-Scan wird gestartet, der PC startet neu.'
    try { Start-MorpheusDefenderOffline }
    catch { Set-GuiOfflineState 'fehler' ('Der Offline-Scan konnte nicht gestartet werden: ' + $_.Exception.Message) }
}

function Update-GuiOffline {
    # Wird bei jedem Durchlauf der Hauptschleife aufgerufen und blockiert nie. EdgeCount -1 = unbekannt (kein Abbruch).
    param([int]$EdgeCount = -1)
    $o = $script:Gui.Offline
    if (($null -eq $o) -or ($o.Status -ne 'countdown')) { return }
    $now = Get-Date
    if (($now - $o.LetzterAbruf).TotalSeconds -gt 3) { Set-GuiOfflineState 'abgebrochen' 'Abgebrochen: Das Morpheus-Fenster antwortet nicht mehr.'; return }
    if ($EdgeCount -eq 0) { Set-GuiOfflineState 'abgebrochen' 'Abgebrochen: Das Morpheus-Fenster wurde geschlossen.'; return }
    if ($now -ge $o.Ende) { Invoke-GuiOfflineStart }
}

#endregion

#region Live-Werte (Hintergrund-Runspace)

# Der Scriptblock läuft in einem eigenen Runspace (kein Job, kein Prozess) und schreibt in die synchronisierte
# Hashtable $State: Snap = letzter Schnappschuss, LastRequest = letzter /api/live-Abruf, Stop = Beenden-Signal.
# Gesammelt wird nur, solange in den letzten 20 s abgefragt wurde. Jede Quelle hat ihr eigenes try/catch.
$script:GuiLiveScript = {
    param($State)
    $ErrorActionPreference = 'Stop'
    $cpuCount = 1
    try { $cpuCount = [int]([Environment]::ProcessorCount); if ($cpuCount -lt 1) { $cpuCount = 1 } } catch { }
    $prevCpu = $null; $prevTime = $null   # für die CPU-Zeit-Differenzen der Top-Prozesse
    $histCpu = New-Object System.Collections.Generic.List[double]
    $histRam = New-Object System.Collections.Generic.List[double]
    $histGpu = New-Object System.Collections.Generic.List[double]
    $driveTypes = $null; $typesDone = $false   # Laufwerksbuchstabe -> SSD/HDD/? (einmal ermittelt)
    $smiPath = $null; $smiChecked = $false
    $prevRx = $null; $prevTx = $null; $prevT = $null; $prevAdapter = $null
    $adCache = $null; $cycle = 0

    while (-not $State.Stop) {
        # Schlafen, wenn niemand zuschaut
        if ((([datetime]::Now) - $State.LastRequest).TotalSeconds -gt 20) {
            $prevRx = $null; $prevTx = $null; $prevT = $null   # Raten nach Pause nicht über die Lücke mitteln
            Start-Sleep -Milliseconds 500
            continue
        }
        $t0 = [datetime]::Now
        $cycle++

        # --- CPU ---
        $cpu = $null
        try {
            $p = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
            if ($p) { $cpu = [Math]::Round([double]@($p)[0].PercentProcessorTime, 1) }
        } catch { $cpu = $null }

        # --- RAM ---
        $ram = $null
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem
            $totKB = [double]$os.TotalVisibleMemorySize; $freeKB = [double]$os.FreePhysicalMemory
            $usedKB = $totKB - $freeKB
            $ram = [ordered]@{
                usedPct = [int][Math]::Round(100 * $usedKB / $totKB)
                usedGB  = [Math]::Round($usedKB / 1MB, 1)
                totalGB = [Math]::Round($totKB / 1MB, 1)
            }
        } catch { $ram = $null }

        # --- GPU (nur NVIDIA, nvidia-smi mit Timeout) ---
        $gpu = $null
        try {
            if (-not $smiChecked) {
                $smiChecked = $true
                # Nur aus System32 bzw. Program Files, nie über PATH (2.3.3)
                foreach ($cand in @((Join-Path ([Environment]::SystemDirectory) 'nvidia-smi.exe'), (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'))) {
                    if (Test-Path -LiteralPath $cand -PathType Leaf) { $smiPath = $cand; break }
                }
            }
            if ($smiPath) {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $smiPath
                $psi.Arguments = '--query-gpu=name,utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits'
                $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                try {
                    $outTask = $proc.StandardOutput.ReadToEndAsync()
                    if ($proc.WaitForExit(3000)) {
                        $line = ([string]$outTask.Result -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                        $f = @($line -split ',' | ForEach-Object { $_.Trim() })
                        if ($f.Count -ge 5) {
                            $mu = [double]$f[3]; $mt = [double]$f[4]
                            $memPct = 0; if ($mt -gt 0) { $memPct = [int][Math]::Round(100 * $mu / $mt) }
                            $gpu = [ordered]@{ name = $f[0]; util = [int]$f[1]; temp = [int]$f[2]; memUsedPct = $memPct }
                        }
                    }
                    else { try { $proc.Kill() } catch { } }
                }
                finally { $proc.Dispose() }
            }
        } catch { $gpu = $null }

        # --- Netzwerk: verbundener physischer Adapter mit Standardroute ---
        $net = $null
        try {
            # Adapter nur alle 10 Zyklen (~20 s) neu bestimmen, das ist der langsame Teil
            if (($null -eq $adCache) -or ($cycle % 10 -eq 0)) {
                $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object { $_.RouteMetric + $_.InterfaceMetric }
                $adCache = $null
                foreach ($r in $route) {
                    $a = Get-NetAdapter -InterfaceIndex $r.InterfaceIndex -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
                    if ($a) { $adCache = $a; break }
                }
            }
            $ad = $adCache
            if ($ad) {
                $st = Get-NetAdapterStatistics -Name $ad.Name -ErrorAction Stop
                $now = [datetime]::Now
                $rxKB = 0.0; $txKB = 0.0
                if (($null -ne $prevT) -and ($prevAdapter -eq $ad.Name)) {
                    $dt = ($now - $prevT).TotalSeconds
                    if ($dt -gt 0.2) {
                        $rxKB = [Math]::Max(0.0, ([double]$st.ReceivedBytes - $prevRx) / 1KB / $dt)
                        $txKB = [Math]::Max(0.0, ([double]$st.SentBytes - $prevTx) / 1KB / $dt)
                    }
                }
                $prevRx = [double]$st.ReceivedBytes; $prevTx = [double]$st.SentBytes; $prevT = $now; $prevAdapter = $ad.Name
                $mbps = $null
                if ($ad.LinkSpeed -match '^\s*([0-9.,]+)\s*(Gbps|Mbps|Kbps|bps)') {
                    $v = [double]($Matches[1] -replace ',', '.')
                    switch ($Matches[2]) { 'Gbps' { $v = $v * 1000 } 'Kbps' { $v = $v / 1000 } 'bps' { $v = $v / 1000000 } }
                    $mbps = [Math]::Round($v)
                }
                $net = [ordered]@{ adapter = [string]$ad.Name; linkMbps = $mbps; rxKBs = [Math]::Round($rxKB, 1); txKBs = [Math]::Round($txKB, 1) }
            }
        } catch { $net = $null }

        # --- Top-3-Prozesse nach CPU ---
        $top = $null
        try {
            # CPU-Zeit-Differenzen aus Get-Process: deutlich günstiger als die WMI-Klasse PerfProc_Process,
            # die bei jedem Abruf fast einen ganzen Kern belegt hat
            $nowCpu = @{}; $nowTime = Get-Date
            foreach ($pr in @(Get-Process -ErrorAction SilentlyContinue)) { if ($null -ne $pr.CPU) { $nowCpu[$pr.Id] = @($pr.ProcessName, [double]$pr.CPU) } }
            if ($prevCpu) {
                $secs = ($nowTime - $prevTime).TotalSeconds
                $sum = @{}
                foreach ($k in $nowCpu.Keys) {
                    if (-not $prevCpu.ContainsKey($k)) { continue }
                    $d = $nowCpu[$k][1] - $prevCpu[$k][1]
                    if ($d -le 0) { continue }
                    $n = $nowCpu[$k][0]
                    if (-not $sum.ContainsKey($n)) { $sum[$n] = 0.0 }
                    $sum[$n] += $d
                }
                $top = @($sum.GetEnumerator() | Sort-Object { $_.Value } -Descending | Select-Object -First 3 |
                        ForEach-Object { [ordered]@{ name = [string]$_.Key; cpu = [Math]::Round(100 * [double]$_.Value / $secs / $cpuCount, 1) } })
            }
            $prevCpu = $nowCpu; $prevTime = $nowTime
        } catch { $top = $null }

        # --- Laufwerke (Typ einmal ermitteln und cachen) ---
        $drives = $null
        try {
            if ($null -eq $driveTypes) { $driveTypes = @{} }   # Typen werden nach dem ersten Schnappschuss nachgeladen
            $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
                    $sz = [double]$_.Size; $fr = [double]$_.FreeSpace
                    $ty = $driveTypes[[string]$_.DeviceID]; if (-not $ty) { $ty = '?' }
                    $pct = 0; if ($sz -gt 0) { $pct = [int][Math]::Round(100 * $fr / $sz) }
                    [ordered]@{ letter = [string]$_.DeviceID; label = [string]$_.VolumeName; type = $ty; freePct = $pct
                        freeGB = [Math]::Round($fr / 1GB, 1); sizeGB = [Math]::Round($sz / 1GB, 1) }
                })
        } catch { $drives = $null }

        # --- Verlauf (Ringpuffer, 30 Werte = 60 s) ---
        if ($null -ne $cpu) { $histCpu.Add($cpu); if ($histCpu.Count -gt 30) { $histCpu.RemoveAt(0) } }
        if ($null -ne $ram) { $histRam.Add([double]$ram.usedPct); if ($histRam.Count -gt 30) { $histRam.RemoveAt(0) } }
        if ($null -ne $gpu) { $histGpu.Add([double]$gpu.util); if ($histGpu.Count -gt 30) { $histGpu.RemoveAt(0) } }

        $State.Snap = [ordered]@{
            stand  = $t0.ToString('yyyy-MM-ddTHH:mm:ss')
            cpu    = $cpu
            ram    = $ram
            gpu    = $gpu
            net    = $net
            top    = $top
            drives = $drives
            verlauf = [ordered]@{ cpu = [double[]]$histCpu.ToArray(); ram = [double[]]$histRam.ToArray(); gpu = [double[]]$histGpu.ToArray() }
        }

        # Laufwerkstypen einmalig nachladen (langsam, deshalb erst nach dem ersten Schnappschuss) und danach cachen
        if (-not $typesDone) {
            $typesDone = $true
            try {
                $pds = @(Get-PhysicalDisk -ErrorAction Stop)
                foreach ($part in @(Get-Partition -ErrorAction Stop | Where-Object { $_.DriveLetter })) {
                    $pd = $pds | Where-Object { [string]$_.DeviceId -eq [string]$part.DiskNumber } | Select-Object -First 1
                    $ty = '?'
                    if ($pd) { if ($pd.MediaType -eq 'SSD') { $ty = 'SSD' } elseif ($pd.MediaType -eq 'HDD') { $ty = 'HDD' } }
                    $driveTypes[([string]$part.DriveLetter).ToUpperInvariant() + ':'] = $ty
                }
            } catch { }
        }

        # 2 s Takt (abzüglich Sammeldauer), in kleinen Schritten, damit Stop schnell greift
        $wait = 2000 - [int](([datetime]::Now) - $t0).TotalMilliseconds
        while (($wait -gt 0) -and (-not $State.Stop)) { $s = [Math]::Min(250, $wait); Start-Sleep -Milliseconds $s; $wait -= $s }
    }
}

function Start-GuiLive {
    # Startet den Sammel-Runspace (schläft, bis /api/live abgefragt wird).
    $state = [hashtable]::Synchronized(@{ Snap = $null; LastRequest = [datetime]::MinValue; Stop = $false })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:GuiLiveScript.ToString()).AddArgument($state)
    $handle = $ps.BeginInvoke()
    $script:Gui.Live = @{ State = $state; Runspace = $rs; PS = $ps; Handle = $handle }
}

function Stop-GuiLive {
    # Beendet den Runspace sauber und gibt ihn frei.
    $l = $script:Gui.Live
    if (-not $l) { return }
    $script:Gui.Live = $null
    try { $l.State.Stop = $true } catch { }
    try { [void]$l.Handle.AsyncWaitHandle.WaitOne(3000) } catch { }
    try { $l.PS.Stop() } catch { }
    try { $l.PS.Dispose() } catch { }
    try { $l.Runspace.Close(); $l.Runspace.Dispose() } catch { }
}

#endregion

#region Anfragen

function Send-GuiStatic {
    param($Res, [string]$RelPath)
    $guiDir = [IO.Path]::GetFullPath((Join-Path $script:Gui.Root 'gui')).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath((Join-Path $guiDir $RelPath))
    if ((-not $full.StartsWith($guiDir, [StringComparison]::OrdinalIgnoreCase)) -or (-not (Test-Path -LiteralPath $full -PathType Leaf))) {
        Stop-GuiRequest 404 'Nicht gefunden.'
    }
    $types = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
        '.json' = 'application/json; charset=utf-8'; '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.ico' = 'image/x-icon' }
    $ct = $types[[IO.Path]::GetExtension($full).ToLowerInvariant()]
    if (-not $ct) { $ct = 'application/octet-stream' }
    Send-GuiBytes $Res 200 $ct ([IO.File]::ReadAllBytes($full))
}

function Invoke-GuiScanStart {
    param($Body)
    Assert-GuiWritable
    if (Get-GuiRunningSysJob) { Stop-GuiRequest 409 'Die Sysinternals-Werkzeuge werden gerade eingerichtet. Bitte warten, bis das fertig ist, und den Scan dann starten.' }
    $profil = 'Auto'
    $p = Get-GuiProp $Body 'profil'
    if ($null -ne $p) {
        $match = @('Auto', 'Gaming', 'Office', 'Laptop') | Where-Object { ($p -is [string]) -and ($_ -ieq $p) }
        if (-not $match) { Stop-GuiRequest 400 'Unbekanntes Profil. Erlaubt: Auto, Gaming, Office, Laptop.' }
        $profil = [string]$match
    }
    $days = 14
    $d = Get-GuiProp $Body 'eventDays'
    if ($null -ne $d) {
        if (-not (($d -is [int]) -or ($d -is [long]) -or ($d -is [double]))) { Stop-GuiRequest 400 'eventDays muss eine Zahl von 1 bis 90 sein.' }
        if (($d -ne [Math]::Floor($d)) -or ($d -lt 1) -or ($d -gt 90)) { Stop-GuiRequest 400 'eventDays muss eine ganze Zahl von 1 bis 90 sein.' }
        $days = [int]$d
    }
    $flags = @{}
    foreach ($n in 'skipWinget', 'skipUpdateSearch', 'skipSpeicher', 'skipSysinternals') {
        $v = Get-GuiProp $Body $n
        if ($null -eq $v) { $flags[$n] = $false }
        elseif ($v -is [bool]) { $flags[$n] = $v }
        else { Stop-GuiRequest 400 "$n muss true oder false sein." }
    }
    if (@($script:Gui.Jobs.Values | Where-Object { ($_.Status -eq 'running') -and ($_.Art -eq 'scan') }).Count -gt 0) {
        Stop-GuiRequest 409 'Es läuft bereits ein Scan.'
    }
    # Berichte und Akzeptanzliste liegen im Datenordner, nicht neben dem Code
    $a = @('-NoUpdatePrompt', '-NoOpen', '-Profil', $profil, '-EventDays', [string]$days,
        '-OutputDir', (Join-Path $script:Gui.DataRoot 'reports'), '-AcceptedFile', (Join-Path $script:Gui.DataRoot 'accepted.psd1'))
    if ($flags['skipWinget']) { $a += '-SkipWinget' }
    if ($flags['skipUpdateSearch']) { $a += '-SkipUpdateSearch' }
    if ($flags['skipSpeicher']) { $a += '-SkipSpeicher' }
    if ($flags['skipSysinternals']) { $a += '-SkipSysinternals' }
    return (Start-GuiJob 'scan' @($script:Gui.Root, [string[]]$a, $script:Gui.DataRoot) $false)
}

function Invoke-GuiActionRun {
    param($Body)
    Assert-GuiWritable
    Assert-GuiFn 'Get-PcCheckCatalog', 'Invoke-PcCheckChange'
    $rawIds = Get-GuiProp $Body 'ids'
    if ($null -eq $rawIds) { Stop-GuiRequest 400 'ids fehlt.' }
    $ids = @($rawIds)
    if ($ids.Count -eq 0) { Stop-GuiRequest 400 'ids ist leer.' }
    $clean = New-Object System.Collections.Generic.List[string]
    foreach ($i in $ids) {
        if (($i -isnot [string]) -or ($i -cnotmatch '^[a-z0-9.-]{1,80}\z')) { Stop-GuiRequest 400 'Ungültige Aktions-ID.' }
        $act = $script:Gui.Catalog | Where-Object { $_.Id -ceq $i } | Select-Object -First 1
        if (-not $act) { Stop-GuiRequest 400 "Unbekannte Aktions-ID: $i" }
        if (-not $clean.Contains($i)) { $clean.Add($i) }
    }
    $variante = $null
    $v = Get-GuiProp $Body 'variante'
    if (($null -ne $v) -and ("$v" -ne '')) {
        if ($v -isnot [string]) { Stop-GuiRequest 400 'Ungültige Variante.' }
        if ($clean.Count -ne 1) { Stop-GuiRequest 400 'Eine Variante ist nur bei genau einer Aktion möglich.' }
        $act = $script:Gui.Catalog | Where-Object { $_.Id -ceq $clean[0] } | Select-Object -First 1
        if (-not (@($act.Varianten) -ccontains $v)) { Stop-GuiRequest 400 'Unbekannte Variante.' }
        $variante = $v
    }
    if ((Get-GuiRunningJobs -MutatingOnly).Count -gt 0) { Stop-GuiRequest 409 'Es läuft bereits eine Änderung.' }
    $lines = foreach ($cid in $clean) {
        $a = $script:Gui.Catalog | Where-Object { $_.Id -ceq $cid } | Select-Object -First 1
        $t = '• ' + [string]$a.Titel
        if ($variante) { $t += " ($variante)" }
        if ($a.Neustart -eq $true) { $t += ' – Neustart nötig' }
        $t
    }
    $text = "Folgende Änderung(en) mit Administratorrechten ausführen?`n`n" + ($lines -join "`n") +
        "`n`nVorher wird ein Wiederherstellungspunkt angelegt. Jede Änderung lässt sich unter 'Änderungen' zurücknehmen." +
        "`n`nHast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'."
    return (Start-GuiJob 'run' @($script:Gui.Root, $script:Gui.SafetyPath, [string[]]$clean.ToArray(), $variante, $script:Gui.DataRoot) $true $text)
}

function Invoke-GuiRoute {
    param($Req, $Res, [string]$Method, [string]$Path)
    $g = $script:Gui

    # --- statische Dateien (ohne Token) ---
    if (($Path -notlike '/api/*') -and ($Path -notlike '/report/*')) {
        if ($Method -ne 'GET') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        if (($Path -eq '/') -or ($Path -eq '/index.html')) { Send-GuiStatic $Res 'index.html'; return }
        if ($Path -in '/app.js', '/app.css') { Send-GuiStatic $Res $Path.TrimStart('/'); return }
        # Bilder: nur feste Namensform aus gui\assets\ (Regex + Präfix-Prüfung in Send-GuiStatic), ohne Token (keine Daten)
        if ($Path -cmatch '^/assets/([a-z0-9-]+\.(png|svg|jpg))\z') { Send-GuiStatic $Res ('assets\' + $Matches[1]); return }
        if ($Path -eq '/favicon.ico') { Send-GuiStatic $Res 'assets\morpheus-icon.png'; return }
        if ($Path -cmatch '^/dev/[A-Za-z0-9._-]+\z') { Send-GuiStatic $Res $Path.TrimStart('/'); return }
        Stop-GuiRequest 404 'Nicht gefunden.'
    }

    # --- Einmal-Code gegen Token tauschen (ohne Token) ---
    # Edge bekommt nur diesen Code in der Befehlszeile (für alle Benutzerprozesse lesbar), nie das Token.
    # Jeder Versuch verbraucht den Code: Wer mitliest und zuerst tauscht, lässt die GUI sichtbar scheitern.
    if ($Path -eq '/api/session/claim') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        if ([string]$Req.ContentType -notmatch '^\s*application/json\s*(;|\z)') { Stop-GuiRequest 415 'Content-Type muss application/json sein.' }
        $code = Get-GuiProp (Read-GuiBody $Req) 'code'
        $ok = ($null -ne $g.BootCode) -and ((Get-Date) -lt $g.BootExpires) -and ($code -is [string]) -and (Test-GuiTokenEqual $code $g.BootCode)
        $g.BootCode = $null
        if (-not $ok) {
            Write-GuiLog 'WARNUNG: Startcode ungültig oder bereits verbraucht.'
            Stop-GuiRequest 403 'Der Startcode ist ungültig oder wurde bereits verwendet. Bitte die GUI neu starten.'
        }
        Send-GuiJson $Res 200 ([ordered]@{ token = $g.Token })
        return
    }

    # --- Berichte als HTML (iframe) mit einmaliger Lesemarke statt Token ---
    # Das Script im Bericht kann seine eigene Adresse lesen; dort darf deshalb nie das Token stehen.
    if ($Path -cmatch '^/report/([^/]+)\z') {
        if ($Method -ne 'GET') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $name = $Matches[1]
        $k = [string]$Req.QueryString['k']
        $t = $null
        if ($k -and $g.Tickets.ContainsKey($k)) { $t = $g.Tickets[$k]; $g.Tickets.Remove($k) }
        if ((-not $t) -or ($t.Name -cne $name) -or ((Get-Date) -gt $t.Expires)) { Stop-GuiRequest 401 'Lesemarke fehlt, ist abgelaufen oder wurde schon benutzt.' }
        $full = Resolve-GuiReportPath $name 'html'
        if (-not $full) { Stop-GuiRequest 404 'Bericht nicht gefunden.' }
        Send-GuiBytes $Res 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($full)) $script:GuiReportCsp
        return
    }

    # --- Token (Abschnitt 4.3) ---
    $tok = $Req.Headers['X-PcCheck-Token']
    if ((-not $tok) -or (-not (Test-GuiTokenEqual $tok $g.Token))) { Stop-GuiRequest 401 'Token fehlt oder ist ungültig.' }

    # --- POST nur mit JSON ---
    $body = $null
    if ($Method -eq 'POST') {
        $ct = [string]$Req.ContentType
        if ($ct -notmatch '^\s*application/json\s*(;|\z)') { Stop-GuiRequest 415 'Content-Type muss application/json sein.' }
        $body = Read-GuiBody $Req
    }

    $isGet = ($Method -eq 'GET')

    if ($Path -eq '/api/session') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $safety = $null
        if (Test-GuiFn 'Get-PcCheckSafetyStatus') { try { $safety = Get-PcCheckSafetyStatus -Root $g.Root -DataRoot $g.DataRoot } catch { Write-GuiLog ('Safety-Status: ' + $_.Exception.Message) } }
        $profil = $null
        $rl = @(Get-GuiReportList)
        if ($rl.Count -gt 0) { $profil = $rl[0].profil }
        # Datenordner-Reparatur (18.10): Zustand nur, wenn der Server mit reparierbarem Datenordner gestartet wurde
        $dn = $null
        $dd = $g.Datenordner
        if ($dd) {
            $dz = $dd.Zustand
            $dn = [ordered]@{ zustand = [string](Get-GuiDnWert $dz 'zustand'); konten = @(Get-GuiDnWert $dz 'konten'); objekte = [int](Get-GuiDnWert $dz 'objekte')
                pfad = [string]$dd.Pfad; repariert = [bool]$dd.Repariert }
        }
        # Zeitpunkt einer Reparatur nur, solange sie weniger als 7 Tage zurückliegt (Hinweis "Bitte prüfen, ob alle Einträge von dir stammen")
        $repZeit = $null
        $ri = Get-GuiReparaturInfo
        if ($ri.Zeit -and ($ri.Zeit -gt (Get-Date).AddDays(-7))) { $repZeit = $ri.Zeit.ToString('yyyy-MM-ddTHH:mm:ss') }
        Send-GuiJson $Res 200 ([ordered]@{ version = $g.Version; pc = $env:COMPUTERNAME; admin = $g.Admin; profil = $profil; safety = $safety
                readOnly = [bool]$g.ReadOnly; readOnlyReason = $(if ($g.ReadOnly) { [string]$g.ReadOnlyReason } else { $null }); dataRoot = $g.DataRoot
                datenordner = $dn; reparaturZeit = $repZeit })
        return
    }
    if ($Path -eq '/api/report-ticket') {
        # Einmalige Lesemarke (60 s) für genau einen Original-Bericht im iframe
        if ($isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $name = Get-GuiProp $body 'name'
        if (($name -isnot [string]) -or (-not (Resolve-GuiReportPath $name 'html'))) { Stop-GuiRequest 404 'Bericht nicht gefunden.' }
        $now = Get-Date
        foreach ($key in @($g.Tickets.Keys)) { if ($g.Tickets[$key].Expires -lt $now) { $g.Tickets.Remove($key) } }
        $k = New-GuiSecret
        $g.Tickets[$k] = @{ Name = $name; Expires = $now.AddSeconds(60) }
        Send-GuiJson $Res 200 ([ordered]@{ ticket = $k })
        return
    }
    if ($Path -eq '/api/reports') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Send-GuiJson $Res 200 @(Get-GuiReportList)
        return
    }
    if ($Path -cmatch '^/api/reports/([^/]+)\z') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $full = Resolve-GuiReportPath $Matches[1] 'json'
        if (-not $full) { Stop-GuiRequest 404 'Bericht nicht gefunden.' }
        $bytes = [IO.File]::ReadAllBytes($full)
        if (($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)) { $bytes = $bytes[3..($bytes.Length - 1)] }
        Send-GuiBytes $Res 200 'application/json; charset=utf-8' $bytes
        return
    }
    if ($Path -eq '/api/help') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Send-GuiJson $Res 200 (Get-GuiHelp)
        return
    }
    if ($Path -eq '/api/actions') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiFn 'Get-PcCheckCatalog', 'ConvertTo-PublicAction'
        $st = $g.ActionStates
        $list = @(foreach ($a in $g.Catalog) { $s = $null; if ($st) { $s = $st[$a.Id] }; ConvertTo-PublicAction -Action $a -State $s })
        Send-GuiJson $Res 200 $list
        return
    }
    if ($Path -eq '/api/actions/refresh') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiFn 'Get-PcCheckCatalog', 'Get-PcCheckActionStates'
        $running = @($g.Jobs.Values | Where-Object { ($_.Status -eq 'running') -and ($_.Art -eq 'refresh') })
        if ($running.Count -gt 0) { Send-GuiJson $Res 200 ([ordered]@{ jobId = $running[0].Id }); return }
        $id = Start-GuiJob 'refresh' @($g.Root, $g.SafetyPath) $false
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -eq '/api/actions/run') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $id = Invoke-GuiActionRun $body
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -cmatch '^/api/journal/([^/]+)/undo\z') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        Assert-GuiFn 'Get-PcCheckJournal', 'Undo-PcCheckChange'
        $eid = $Matches[1]
        if ($eid -cnotmatch '^[A-Za-z0-9-]{1,40}\z') { Stop-GuiRequest 400 'Ungültige Journal-ID.' }
        $entry = @(Get-PcCheckJournal -Root $g.Root -DataRoot $g.DataRoot) | Where-Object { [string]$_.id -ceq $eid } | Select-Object -First 1
        if (-not $entry) { Stop-GuiRequest 404 'Journal-Eintrag nicht gefunden.' }
        if ([string]$entry.art -cne 'ausfuehren') { Stop-GuiRequest 400 'Für diesen Eintrag gibt es kein Rückgängig.' }
        $force = $false
        $f = Get-GuiProp $body 'force'
        if ($null -ne $f) { if ($f -is [bool]) { $force = $f } else { Stop-GuiRequest 400 'force muss true oder false sein.' } }
        # Eintrag aus der Zeit vor einer Datenordner-Reparatur (18.10): ausdrückliche Bestätigung nötig. Unlesbare Zeiten gelten als älter.
        $vorRep = $false
        # Gleiche Regel wie in Undo-PcCheckChange (Safety.ps1): Id in "eintraege", nicht die fälschbare Zeit (nur altes Format).
        $ri = Get-GuiReparaturInfo
        if ($ri.Vorhanden) {
            if (Test-GuiFn 'Test-PcCheckVorReparatur') { $vorRep = [bool](Test-PcCheckVorReparatur -DataRoot ([string]$g.DataRoot) -Eintrag $entry) }
            else { $vorRep = $true }   # ohne die gemeinsame Regel: im Zweifel gesperrt
        }
        if ($vorRep) {
            $vr = Get-GuiProp $body 'vorReparatur'
            if (($vr -isnot [bool]) -or (-not $vr)) {
                Stop-GuiRequest 409 'Dieser Eintrag stammt aus der Zeit vor der Reparatur des Datenordners. Prüfe in den Änderungen, ob du diese Änderung selbst vorgenommen hast, und bestätige das ausdrücklich.'
            }
        }
        if ((Get-GuiRunningJobs -MutatingOnly).Count -gt 0) { Stop-GuiRequest 409 'Es läuft bereits eine Änderung.' }
        $text = "Diese Änderung mit Administratorrechten zurücknehmen?`n`n• " + [string]$entry.titel + ' (vom ' + ([string]$entry.zeit).Replace('T', ' ') + ')' +
            $(if ($force) { "`n`nAchtung: Der Zustand wurde inzwischen anders geändert; auch diese spätere Änderung wird überschrieben." } else { '' }) +
            $(if ($vorRep) { "`n`nDieser Eintrag stammt aus der Zeit, in der der Datenordner ungeschützt war. Prüfe in 'Änderungen', ob du diese Änderung selbst vorgenommen hast." } else { '' }) +
            "`n`nVorher wird ein Wiederherstellungspunkt angelegt.`n`nHast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'."
        $id = Start-GuiJob 'undo' @($g.Root, $g.SafetyPath, $eid, $force, $g.DataRoot, $vorRep) $true $text
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -eq '/api/journal') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiFn 'Get-PcCheckJournal'
        Send-GuiJson $Res 200 @(Get-PcCheckJournal -Root $g.Root -DataRoot $g.DataRoot)
        return
    }
    if ($Path -eq '/api/restorepoints') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiFn 'Get-PcCheckRestorePoints'
        Send-GuiJson $Res 200 @(Get-PcCheckRestorePoints)
        return
    }
    if ($Path -eq '/api/scan') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $id = Invoke-GuiScanStart $body
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -cmatch '^/api/jobs/([^/]+)\z') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Update-GuiJobs
        $rec = $g.Jobs[$Matches[1]]
        if (-not $rec) { Stop-GuiRequest 404 'Job nicht gefunden (oder älter als 30 Minuten).' }
        $from = 0
        $fq = $Req.QueryString['from']
        if ($fq -and ($fq -cmatch '^[0-9]{1,9}\z')) { $from = [int]$fq }
        $total = $rec.Log.Count
        if ($from -gt $total) { $from = $total }
        $lines = @()
        if ($total -gt $from) { $lines = @($rec.Log.GetRange($from, $total - $from)) }
        $erg = $null
        if ($rec.Status -ne 'running') { $erg = $rec.Ergebnis }
        Send-GuiJson $Res 200 ([ordered]@{ id = $rec.Id; art = $rec.Art; status = $rec.Status; log = $lines; next = $total; ergebnis = $erg })
        return
    }
    if ($Path -eq '/api/checklist') {
        $cp = Join-Path $g.DataRoot 'state\checklist.json'
        if ($isGet) {
            $text = '{}'
            if (Test-Path -LiteralPath $cp -PathType Leaf) { $text = [IO.File]::ReadAllText($cp, [Text.Encoding]::UTF8); if ([string]::IsNullOrWhiteSpace($text)) { $text = '{}' } }
            Send-GuiBytes $Res 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($text))
            return
        }
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        if (($body -isnot [pscustomobject]) -or (@($body.PSObject.Properties).Count -gt 500)) { Stop-GuiRequest 400 'Die Checkliste muss ein Objekt sein.' }
        $clean = [ordered]@{}
        foreach ($p in $body.PSObject.Properties) {
            $key = [string]$p.Name
            if (($key.Length -eq 0) -or ($key.Length -gt 200) -or ($key -match '[\x00-\x1f]')) { Stop-GuiRequest 400 'Ungültiger Name in der Checkliste.' }
            $e = $p.Value
            $state = Get-GuiProp $e 'state'
            if (($e -isnot [pscustomobject]) -or (@('done', 'later') -cnotcontains $state)) { Stop-GuiRequest 400 "Ungültiger Eintrag: $key (state muss done oder later sein)." }
            $date = Get-GuiProp $e 'date'; $rep = Get-GuiProp $e 'report'
            if ((($null -ne $date) -and ($date -isnot [string])) -or (($null -ne $rep) -and ($rep -isnot [string]))) { Stop-GuiRequest 400 "Ungültiger Eintrag: $key" }
            if ((([string]$date).Length -gt 64) -or (([string]$rep).Length -gt 200)) { Stop-GuiRequest 400 "Eintrag zu lang: $key" }
            $clean[$key] = [ordered]@{ state = [string]$state; date = [string]$date; report = [string]$rep }
        }
        $json = ConvertTo-Json -InputObject $clean -Depth 4 -Compress
        Save-GuiTextAtomic $cp $json
        Send-GuiBytes $Res 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
        return
    }
    if ($Path -eq '/api/speicher') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $sp = Join-Path $g.DataRoot 'state\speicher.json'
        $bytes = $null
        if (Test-Path -LiteralPath $sp -PathType Leaf) {
            if ((Get-Item -LiteralPath $sp).Length -gt 20MB) { Write-GuiLog 'speicher.json ist größer als 20 MB und wird ignoriert.' }
            else {
                $bytes = [IO.File]::ReadAllBytes($sp)
                if (($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)) { $bytes = $bytes[3..($bytes.Length - 1)] }
                if ($bytes.Length -lt 2) { $bytes = $null }
            }
        }
        if ($null -eq $bytes) { Send-GuiJson $Res 200 ([ordered]@{ stand = $null }); return }
        Send-GuiBytes $Res 200 'application/json; charset=utf-8' $bytes
        return
    }
    if ($Path -eq '/api/speicher/refresh') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        $running = @($g.Jobs.Values | Where-Object { ($_.Status -eq 'running') -and ($_.Art -eq 'speicher') })
        if ($running.Count -gt 0) { Send-GuiJson $Res 200 ([ordered]@{ jobId = $running[0].Id }); return }
        $id = Start-GuiJob 'speicher' @($g.Root, $g.DataRoot) $false
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -eq '/api/spielordner') {
        $sf = Join-Path $g.DataRoot 'state\spielordner.json'
        if ($isGet) {
            # ConvertTo-Json -InputObject (in Send-GuiJson) liefert auch bei 0/1 Einträgen ein Array
            Send-GuiJson $Res 200 @(Read-GuiSpielordner $sf)
            return
        }
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        # Direkt aus der Eigenschaft lesen: Get-GuiProp würde leere/einelementige Arrays in der Pipeline auflösen
        $ein = $null
        $einProp = $body.PSObject.Properties['eintraege']
        if ($einProp) { $ein = $einProp.Value }
        $clean = @(Test-GuiSpielordnerEintraege $ein)
        Save-GuiTextAtomic $sf (ConvertTo-Json -InputObject $clean -Depth 4 -Compress)
        Write-GuiLog ("Spiele-Ordner gespeichert ({0} Einträge)" -f $clean.Count)
        Send-GuiJson $Res 200 $clean
        return
    }
    if ($Path -eq '/api/defender') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $stand = $null
        if (Test-GuiFn 'Get-MorpheusDefenderStand') {
            try { $stand = Get-MorpheusDefenderStand } catch { $stand = [ordered]@{ fehler = $_.Exception.Message } }
        }
        else { $stand = [ordered]@{ fehler = 'Die Defender-Werkzeuge sind nicht verfügbar (gui\lib\Defender.ps1 fehlt).' } }
        $lj = Get-GuiRunningDefenderJob
        $laufend = $null; if ($lj) { $laufend = $lj.Id }
        Send-GuiJson $Res 200 ([ordered]@{ stand = $stand; laufend = $laufend; offline = (Get-GuiOfflineState) })
        return
    }
    if ($Path -eq '/api/defender/run') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        Assert-GuiFn 'Get-MorpheusDefenderStand', 'Invoke-MorpheusDefenderAktion'
        $art = Get-GuiProp $body 'art'
        if (($art -isnot [string]) -or (@('signaturen', 'schnellscan') -cnotcontains $art)) { Stop-GuiRequest 400 'art muss signaturen oder schnellscan sein.' }
        if (Get-GuiRunningDefenderJob) { Stop-GuiRequest 409 'Es läuft bereits eine Defender-Aufgabe.' }
        if (($g.Offline -and ($g.Offline.Status -eq 'countdown'))) { Stop-GuiRequest 409 'Es läuft bereits ein Offline-Scan-Countdown.' }
        if ($art -ceq 'signaturen') {
            $text = "Microsoft Defender: Virensignaturen jetzt aktualisieren?`n`nEs werden keine Einstellungen geändert.`n`nHast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'."
        }
        else {
            $text = "Microsoft Defender: Schnellscan jetzt starten?`n`nDer Scan dauert meist einige Minuten. Funde zeigt Morpheus nur an; Quarantäne und Entfernen bleiben in Windows-Sicherheit.`n`nHast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'."
        }
        $id = Start-GuiJob 'defender' @($g.Root, $g.DefenderPath, $art) $false $text
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -eq '/api/defender/datei') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        Assert-GuiFn 'Get-MorpheusDefenderStand', 'Invoke-MorpheusDefenderAktion'
        $dat = Resolve-GuiSigcheckDatei (Get-GuiProp $body 'bericht') (Get-GuiProp $body 'pfad')
        if (Get-GuiRunningDefenderJob) { Stop-GuiRequest 409 'Es läuft bereits eine Defender-Aufgabe.' }
        if (($g.Offline -and ($g.Offline.Status -eq 'countdown'))) { Stop-GuiRequest 409 'Es läuft bereits ein Offline-Scan-Countdown.' }
        $text = "Microsoft Defender: Diese Datei jetzt prüfen?`n`n" + (Format-GuiDialogWert $dat.pfad 260) + "`n`nDefender wendet bei einem Fund seine üblichen Maßnahmen an (z. B. Quarantäne); das kann bei Treibern Folgen haben. Morpheus ändert selbst keine Einstellungen.`n`nHast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'."
        $id = Start-GuiJob 'defender' @($g.Root, $g.DefenderPath, 'datei', $dat.pfad) $false $text
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -eq '/api/akzeptanz') {
        $akzDatei = Join-Path $g.DataRoot 'accepted.psd1'
        if ($isGet) {
            Assert-GuiFn 'Read-MorpheusAkzeptanz'
            try { $regeln = @(Read-MorpheusAkzeptanz -Datei $akzDatei) }
            catch { Stop-GuiRequest 500 ('Die Akzeptanzliste ist nicht lesbar: ' + $_.Exception.Message) }
            Send-GuiJson $Res 200 ([ordered]@{ regeln = $regeln; datei = $akzDatei; bearbeitbar = (-not [bool]$g.ReadOnly) })
            return
        }
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        Assert-GuiFn 'Read-MorpheusAkzeptanz', 'Add-MorpheusAkzeptanz', 'Add-MorpheusAkzeptanzHistorie', 'Test-MorpheusAkzeptanzRegel'
        $art = Get-GuiProp $body 'art'
        if (($art -isnot [string]) -or (@('befund', 'datei') -cnotcontains $art)) { Stop-GuiRequest 400 'art muss befund oder datei sein.' }
        $begr = Get-GuiProp $body 'begruendung'
        if (($begr -isnot [string]) -or ($begr.Length -gt 1000)) { Stop-GuiRequest 400 'begruendung muss ein Text sein.' }
        $bis = Get-GuiProp $body 'bis'
        if (($null -ne $bis) -and (($bis -isnot [string]) -or ($bis.Length -gt 20))) { Stop-GuiRequest 400 'bis muss ein Datum als Text sein.' }
        $regel = @{ Reason = $begr }
        if (-not [string]::IsNullOrWhiteSpace($bis)) { $regel['Until'] = $bis }
        if ($art -ceq 'befund') {
            $chk = Get-GuiProp $body 'check'
            if (($chk -isnot [string]) -or ($chk.Length -lt 1) -or ($chk.Length -gt 200)) { Stop-GuiRequest 400 'check muss ein Text mit 1 bis 200 Zeichen sein.' }
            if ($chk -ceq $script:GuiSigcheckCheck) { Stop-GuiRequest 400 'Diese Prüfung wird je Datei akzeptiert, nicht als Ganzes.' }
            $bfull = Resolve-GuiBerichtDatei (Get-GuiProp $body 'bericht')
            $bericht = Read-GuiReportJson $bfull
            $treffer = $null
            foreach ($fd in @(Get-GuiProp $bericht 'Findings')) {
                if ($null -eq $fd) { continue }
                $fc = Get-GuiProp $fd 'Check'
                if (($fc -isnot [string]) -or ($fc -cne $chk)) { continue }
                $st = [string](Get-GuiProp $fd 'Status')
                if ($st -ceq 'ACK') { $st = [string](Get-GuiProp $fd 'OriginalStatus') }
                if (@('CRIT', 'WARN', 'TIPP', 'INFO') -ccontains $st) { $treffer = $fd; break }
            }
            if (-not $treffer) { Stop-GuiRequest 404 'Diesen Befund gibt es in diesem Bericht nicht (oder er lässt sich nicht akzeptieren).' }
            $wert = [string](Get-GuiProp $treffer 'Value')
            $regel['Check'] = [Management.Automation.WildcardPattern]::Escape($chk)
            $regel['Match'] = '^' + [regex]::Escape($wert) + '$'
            $was = 'Prüfung: ' + (Format-GuiDialogWert $chk 200) + "`nBefund: " + (Format-GuiDialogWert $wert 300) + "`nGilt nur, solange der Befund genau so lautet."
        }
        else {
            $dat = Resolve-GuiSigcheckDatei (Get-GuiProp $body 'bericht') (Get-GuiProp $body 'pfad')
            $regel['Check'] = $script:GuiSigcheckCheck
            $regel['Datei'] = $dat.pfad
            $regel['Sha256'] = $dat.sha256
            $was = 'Datei: ' + (Format-GuiDialogWert $dat.pfad 260)
        }
        $ablauf = 'unbegrenzt'; if ($regel.ContainsKey('Until')) { $ablauf = Format-GuiDialogWert $regel['Until'] 20 }
        # Prüfen VOR dem Windows-Dialog
        $fehl = Test-MorpheusAkzeptanzRegel -Datei $akzDatei -Regel $regel
        if ($fehl) {
            $code = 400; if ([string]$fehl -match 'bereits akzeptiert') { $code = 409 }
            Stop-GuiRequest $code ([string]$fehl)
        }
        $text = "In die Akzeptanzliste aufnehmen?`n`n" + $was + "`nBegründung: " + (Format-GuiDialogWert $begr 300) + "`nGilt bis: " + $ablauf + "`n`nAkzeptierte Befunde zählen ab dem nächsten Scan nicht mehr als Warnung.`n`nHast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'."
        Write-GuiLog 'Warte auf Bestätigung im Windows-Dialog (Akzeptieren)'
        $ok = Confirm-GuiElevated $text
        $g.LastHeartbeat = Get-Date
        if (-not $ok) {
            Write-GuiLog 'Im Windows-Dialog abgelehnt (Akzeptieren)'
            Stop-GuiRequest 403 'Im Windows-Bestätigungsdialog abgelehnt. Es wurde nichts geändert.'
        }
        try { $neu = Add-MorpheusAkzeptanz -Datei $akzDatei -Regel $regel }
        catch { Stop-GuiRequest 500 ('Die Akzeptanzliste konnte nicht gespeichert werden: ' + $_.Exception.Message) }
        try { Add-MorpheusAkzeptanzHistorie -Datei (Join-Path $g.DataRoot 'state\akzeptanz-historie.json') -Art 'akzeptiert' -Regel $neu -Benutzer ([Environment]::UserName) }
        catch { Write-GuiLog ('Akzeptanz-Historie: ' + $_.Exception.Message) }
        Write-GuiLog 'Akzeptanzregel hinzugefügt'
        $regelnNeu = @()
        try { $regelnNeu = @(Read-MorpheusAkzeptanz -Datei $akzDatei) } catch { Write-GuiLog ('Akzeptanzliste nach dem Speichern nicht lesbar: ' + $_.Exception.Message) }
        Send-GuiJson $Res 200 ([ordered]@{ regel = $neu; regeln = $regelnNeu })
        return
    }
    if ($Path -cmatch '^/api/akzeptanz/([^/]+)/entfernen\z') {
        $rid = $Matches[1]
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        Assert-GuiFn 'Read-MorpheusAkzeptanz', 'Remove-MorpheusAkzeptanz', 'Add-MorpheusAkzeptanzHistorie', 'Get-MorpheusAkzeptanzRegel'
        if ($rid -cnotmatch '^h?[0-9a-f]{8,11}\z') { Stop-GuiRequest 400 'Ungültige Regel-Id.' }
        $akzDatei = Join-Path $g.DataRoot 'accepted.psd1'
        $alteRegel = Get-MorpheusAkzeptanzRegel -Datei $akzDatei -Id $rid
        if (-not $alteRegel) { Stop-GuiRequest 404 'Diese Regel gibt es nicht (mehr).' }
        $was = 'Prüfung: ' + (Format-GuiDialogWert (Get-GuiProp $alteRegel 'check') 200)
        $rd = [string](Get-GuiProp $alteRegel 'datei')
        $rm = [string](Get-GuiProp $alteRegel 'match')
        if ($rd) { $was += "`nDatei: " + (Format-GuiDialogWert $rd 260) }
        elseif ($rm) { $was += "`nBefundmuster: " + (Format-GuiDialogWert $rm 200) }
        $was += "`nBegründung: " + (Format-GuiDialogWert (Get-GuiProp $alteRegel 'reason') 300)
        $text = "Diese Regel aus der Akzeptanzliste entfernen (Id " + $rid + ")?`n`n" + $was + "`n`nDie Warnung kommt ab dem nächsten Scan zurück.`n`nHast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'."
        Write-GuiLog 'Warte auf Bestätigung im Windows-Dialog (Akzeptanz zurücknehmen)'
        $ok = Confirm-GuiElevated $text
        $g.LastHeartbeat = Get-Date
        if (-not $ok) {
            Write-GuiLog 'Im Windows-Dialog abgelehnt (Akzeptanz zurücknehmen)'
            Stop-GuiRequest 403 'Im Windows-Bestätigungsdialog abgelehnt. Es wurde nichts geändert.'
        }
        try { $alt = Remove-MorpheusAkzeptanz -Datei $akzDatei -Id $rid }
        catch { Stop-GuiRequest 500 ('Die Akzeptanzliste konnte nicht gespeichert werden: ' + $_.Exception.Message) }
        try { Add-MorpheusAkzeptanzHistorie -Datei (Join-Path $g.DataRoot 'state\akzeptanz-historie.json') -Art 'zurueckgenommen' -Regel $alt -Benutzer ([Environment]::UserName) }
        catch { Write-GuiLog ('Akzeptanz-Historie: ' + $_.Exception.Message) }
        Write-GuiLog 'Akzeptanzregel entfernt'
        $regelnNeu = @()
        try { $regelnNeu = @(Read-MorpheusAkzeptanz -Datei $akzDatei) } catch { Write-GuiLog ('Akzeptanzliste nach dem Entfernen nicht lesbar: ' + $_.Exception.Message) }
        Send-GuiJson $Res 200 ([ordered]@{ regeln = $regelnNeu })
        return
    }
    if ($Path -eq '/api/defender/offline') {
        if ($isGet) {
            if ($g.Offline) { $g.Offline.LetzterAbruf = Get-Date }
            Send-GuiJson $Res 200 (Get-GuiOfflineState)
            return
        }
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        Assert-GuiFn 'Start-MorpheusDefenderOffline'
        $b = Get-GuiProp $body 'bestaetigt'
        if (($b -isnot [bool]) -or (-not $b)) { Stop-GuiRequest 400 'Bitte zuerst bestätigen, dass alles gespeichert ist.' }
        if (Get-GuiRunningDefenderJob) { Stop-GuiRequest 409 'Es läuft bereits eine Defender-Aufgabe.' }
        if (($g.Offline -and ($g.Offline.Status -eq 'countdown'))) { Stop-GuiRequest 409 'Der Countdown läuft bereits.' }
        Assert-GuiOfflineErlaubt
        $text = "Microsoft Defender Offline-Scan starten?`n`nDer PC startet nach 15 Sekunden neu und wird ca. 15 Minuten lang offline gescannt. Vorher alles speichern.`n`nDu kannst den Countdown in Morpheus noch abbrechen. Hast du das gerade nicht selbst angeklickt, wähle 'Nein'."
        Write-GuiLog 'Warte auf Bestätigung im Windows-Dialog (Offline-Scan)'
        $ok = Confirm-GuiElevated $text
        $g.LastHeartbeat = Get-Date
        if (-not $ok) {
            Write-GuiLog 'Im Windows-Dialog abgelehnt (Offline-Scan)'
            Stop-GuiRequest 403 'Im Windows-Bestätigungsdialog abgelehnt. Es wurde nichts gestartet.'
        }
        $g.Offline = @{ Status = 'countdown'; Ende = (Get-Date).AddSeconds(15); LetzterAbruf = (Get-Date); Meldung = '' }
        Write-GuiLog 'Offline-Scan: Countdown gestartet (15 s)'
        Send-GuiJson $Res 200 (Get-GuiOfflineState)
        return
    }
    if ($Path -eq '/api/defender/offline/abbrechen') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        if ($g.Offline -and ($g.Offline.Status -eq 'countdown')) { Set-GuiOfflineState 'abgebrochen' 'Abgebrochen. Der PC startet nicht neu.' }
        Send-GuiJson $Res 200 (Get-GuiOfflineState)
        return
    }
    if ($Path -eq '/api/defender/offline/jetzt') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        if ((-not $g.Offline) -or ($g.Offline.Status -ne 'countdown')) { Stop-GuiRequest 409 'Es läuft kein Countdown.' }
        Assert-GuiOfflineErlaubt
        Invoke-GuiOfflineStart
        Send-GuiJson $Res 200 (Get-GuiOfflineState)
        return
    }
    if ($Path -eq '/api/wartung') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiFn 'Get-MorpheusWartungWerkzeuge', 'Get-MorpheusWartungLaufwerke'
        $safety = $null
        if (Test-GuiFn 'Get-PcCheckSafetyStatus') { try { $safety = Get-PcCheckSafetyStatus -Root $g.Root -DataRoot $g.DataRoot } catch { Write-GuiLog ('Safety-Status: ' + $_.Exception.Message) } }
        $berichte = @()
        if (Test-GuiFn 'Get-MorpheusWartungBerichte') { try { $berichte = @(Get-MorpheusWartungBerichte -DataRoot $g.DataRoot) } catch { Write-GuiLog ('Wartungsberichte: ' + $_.Exception.Message) } }
        $lj = Get-GuiRunningWartungJob
        $laufend = $null
        if ($lj) { $laufend = [ordered]@{ jobId = [string]$lj.Id; werkzeug = [string]$lj.Werkzeug; abbruch = [string]$lj.Abbruch } }
        Send-GuiJson $Res 200 ([ordered]@{ werkzeuge = @(Get-MorpheusWartungWerkzeuge); laufwerke = @(Get-GuiWartungLaufwerke); berichte = @($berichte)
                laufend = $laufend; punktFehlt = @(Get-GuiPunktFehlt); safety = $safety })
        return
    }
    if ($Path -eq '/api/wartung/start') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $id = Invoke-GuiWartungStart $body
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -eq '/api/wartung/abbrechen') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $jid = Get-GuiPropRaw $body 'jobId'
        if (($jid -isnot [string]) -or ($jid -cnotmatch '^[0-9a-f]{8}\z')) { Stop-GuiRequest 400 'jobId ist ungültig.' }
        $rec = $g.Jobs[$jid]
        if ((-not $rec) -or ($rec.Art -ne 'wartung') -or ($rec.Status -ne 'running')) { Stop-GuiRequest 409 'Dieses Wartungswerkzeug läuft nicht (mehr).' }
        if ((@('sofort', 'nach-paket') -cnotcontains [string]$rec.Abbruch) -or (-not $rec.AbbruchDatei)) { Stop-GuiRequest 409 'Dieses Werkzeug lässt sich nicht sicher abbrechen.' }
        try {
            $dir = Split-Path -Parent $rec.AbbruchDatei
            if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            [IO.File]::WriteAllBytes($rec.AbbruchDatei, [byte[]]@())
        }
        catch { Stop-GuiRequest 500 ('Der Abbruch konnte nicht angefordert werden: ' + $_.Exception.Message) }
        Write-GuiLog ("Abbruch angefordert (Job {0})" -f $jid)
        $meld = 'Abbruch angefordert. Das Werkzeug wird beendet.'
        if ([string]$rec.Abbruch -ceq 'nach-paket') { $meld = 'Abbruch angefordert. Morpheus hört nach dem aktuellen Programm auf.' }
        Send-GuiJson $Res 200 ([ordered]@{ ok = $true; meldung = $meld })
        return
    }
    if ($Path -eq '/api/wartung/zuverlaessigkeit') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        # Startet nur eine Ansicht ohne Adminrechte, ändert nichts: kein Windows-Dialog (Abschnitt 18.3.2)
        Assert-GuiFn 'Start-MorpheusZuverlaessigkeit'
        try { $zr = Start-MorpheusZuverlaessigkeit }
        catch { Stop-GuiRequest 500 ('Der Zuverlässigkeitsverlauf konnte nicht geöffnet werden: ' + $_.Exception.Message) }
        $zok = $false; $zm = ''
        if ($null -ne $zr) { $zok = [bool](Get-GuiErgebnisWert $zr 'ok'); $zm = [string](Get-GuiErgebnisWert $zr 'meldung') }
        Send-GuiJson $Res 200 ([ordered]@{ ok = $zok; meldung = $zm })
        return
    }
    if ($Path -eq '/api/updates') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $u = $g.Updates
        $stand = $null; $liste = @(); $fehler = $null
        if ($u) { $stand = $u.stand; $liste = @($u.liste); $fehler = $u.fehler }
        $sj = Get-GuiRunningUpdateSucheJob
        $suche = $null; if ($sj) { $suche = [string]$sj.Id }
        $laufend = $null
        $lj = Get-GuiRunningWartungJob
        if ($lj -and ([string]$lj.Werkzeug -ceq 'winget.upgrade')) { $laufend = [string]$lj.Id }
        $wl = $null
        if ($lj -and $lj.ContainsKey('Werkzeug')) { $wl = [string]$lj.Werkzeug }
        Send-GuiJson $Res 200 ([ordered]@{ stand = $stand; liste = @($liste); fehler = $fehler; suche = $suche; laufend = $laufend; punktFehlt = (Test-GuiPunktFreigabe 'winget.upgrade'); wartungLaeuft = $wl })
        return
    }
    if ($Path -eq '/api/updates/suchen') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        Assert-GuiFn 'Get-MorpheusWingetUpdates'
        $sj = Get-GuiRunningUpdateSucheJob
        if ($sj) { Send-GuiJson $Res 200 ([ordered]@{ jobId = [string]$sj.Id }); return }
        # Während Programm-Updates keine Suche: winget würde sich selbst blockieren (Sicherheitsprüfung W4)
        $wj = Get-GuiRunningWartungJob
        if ($wj -and ($wj.ContainsKey('Werkzeug')) -and ([string]$wj.Werkzeug -ceq 'winget.upgrade')) { Stop-GuiRequest 409 'Es werden gerade Programme aktualisiert. Bitte warten, bis das fertig ist.' }
        $id = Start-GuiJob 'updatesuche' @($g.Root, $g.WingetPath) $false
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -eq '/api/updates/installieren') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $id = Invoke-GuiUpdatesInstall $body
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -eq '/api/sysinternals') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $stand = $null
        if (Test-GuiFn 'Get-MorpheusSysStand') {
            try { $stand = Get-MorpheusSysStand -DataRoot $g.DataRoot } catch { $stand = [ordered]@{ fehler = $_.Exception.Message } }
        }
        else { $stand = [ordered]@{ fehler = 'Die Sysinternals-Werkzeuge sind nicht verfügbar (gui\lib\Sysinternals.ps1 fehlt).' } }
        $lj = Get-GuiRunningSysJob
        $laufend = $null; if ($lj) { $laufend = $lj.Id }
        $antwort = [ordered]@{}
        if ($stand -is [System.Collections.IDictionary]) { foreach ($k in $stand.Keys) { $antwort[[string]$k] = $stand[$k] } }
        elseif ($null -ne $stand) { foreach ($pr in $stand.PSObject.Properties) { $antwort[[string]$pr.Name] = $pr.Value } }
        $antwort['laufend'] = $laufend
        Send-GuiJson $Res 200 $antwort
        return
    }
    if ($Path -eq '/api/sysinternals/install') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        $eula = Get-GuiProp $body 'eulaAkzeptiert'
        if (($eula -isnot [bool]) -or (-not $eula)) { Stop-GuiRequest 400 'Bitte zuerst die Lizenzbedingungen annehmen.' }
        Assert-GuiFn 'Get-MorpheusSysStand', 'Set-MorpheusSysZustimmung', 'Install-MorpheusSysWerkzeuge'
        if (Get-GuiRunningSysJob) { Stop-GuiRequest 409 'Es läuft bereits eine Sysinternals-Aufgabe.' }
        if (Get-GuiRunningScanJob) { Stop-GuiRequest 409 'Während eines Scans nicht möglich. Bitte warten, bis der Scan fertig ist.' }
        $ordner = Join-Path $g.DataRoot 'tools'
        $text = 'Sysinternals-Werkzeuge Autoruns und Sigcheck von download.sysinternals.com (Microsoft) herunterladen?' + "`n`n" +
            'Du nimmst damit die Sysinternals-Lizenzbedingungen an. Die Dateien landen in ' + $ordner + ' und werden vor jedem Start auf eine gültige Microsoft-Signatur geprüft.' + "`n`n" +
            'Hast du das gerade nicht selbst in Morpheus angeklickt, wähle ''Nein''.'
        Write-GuiLog 'Sysinternals: Download angefordert'
        $id = Start-GuiJob 'sysinternals' @($g.Root, $g.SysinternalsPath, $g.DataRoot) $false $text
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -eq '/api/sysinternals/entfernen') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        Assert-GuiFn 'Get-MorpheusSysStand', 'Remove-MorpheusSysWerkzeuge'
        if (Get-GuiRunningSysJob) { Stop-GuiRequest 409 'Es läuft bereits eine Sysinternals-Aufgabe.' }
        if (Get-GuiRunningScanJob) { Stop-GuiRequest 409 'Während eines Scans nicht möglich. Bitte warten, bis der Scan fertig ist.' }
        $ordner = Join-Path $g.DataRoot 'tools'
        $text = 'Sysinternals-Werkzeuge (Autoruns, Sigcheck) aus ' + $ordner + ' entfernen und die Lizenz-Zustimmung zurücknehmen?' + "`n`n" +
            'Hast du das gerade nicht selbst in Morpheus angeklickt, wähle ''Nein''.'
        Write-GuiLog 'Warte auf Bestätigung im Windows-Dialog (Sysinternals entfernen)'
        $ok = Confirm-GuiElevated $text
        $g.LastHeartbeat = Get-Date
        if (-not $ok) {
            Write-GuiLog 'Im Windows-Dialog abgelehnt (Sysinternals entfernen)'
            Stop-GuiRequest 403 'Im Windows-Bestätigungsdialog abgelehnt. Es wurde nichts entfernt.'
        }
        $stand = Remove-MorpheusSysWerkzeuge -DataRoot $g.DataRoot
        Write-GuiLog 'Sysinternals-Werkzeuge entfernt'
        Send-GuiJson $Res 200 $stand
        return
    }
    if ($Path -eq '/api/sysinternals/eula') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $name = [string]$Req.QueryString['name']
        if (@('autorunsc', 'sigcheck') -cnotcontains $name) { Stop-GuiRequest 400 'name muss autorunsc oder sigcheck sein.' }
        Assert-GuiFn 'Get-MorpheusSysEula'
        $etext = Get-MorpheusSysEula -DataRoot $g.DataRoot -Name $name
        Send-GuiJson $Res 200 ([ordered]@{ name = $name; text = $etext })
        return
    }
    if ($Path -eq '/api/live') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        # Abruf weckt den Sammel-Runspace; geantwortet wird sofort mit dem letzten Schnappschuss
        $snap = $null
        if ($g.Live) { $g.Live.State.LastRequest = [datetime]::Now; $snap = $g.Live.State.Snap }
        if ($null -eq $snap) { $snap = [ordered]@{ stand = $null } }
        Send-GuiJson $Res 200 $snap
        return
    }
    if ($Path -eq '/api/heartbeat') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $g.LastHeartbeat = Get-Date; $g.HeartbeatSeen = $true
        Send-GuiJson $Res 200 ([ordered]@{ ok = $true })
        return
    }
    if ($Path -eq '/api/datenordner/reparieren') {
        # Einzige ändernde Route, die im Nur-Lesen-Modus erlaubt ist (18.10): kein Assert-GuiWritable, dafür genau diese Bedingung.
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $art = Get-GuiPropRaw $body 'art'
        if (($art -isnot [string]) -or (($art -cne 'reparieren') -and ($art -cne 'neu'))) { Stop-GuiRequest 400 "art muss 'reparieren' oder 'neu' sein." }
        $dd = $g.Datenordner
        $dz = $null
        if ($dd) { $dz = $dd.Zustand }
        if ((-not $dd) -or (-not $dz) -or ([string](Get-GuiDnWert $dz 'zustand') -cne 'reparierbar') -or (-not $dd.Pfad)) { Stop-GuiRequest 409 'Der Datenordner wurde beim Start nicht als reparierbar gemeldet.' }
        if ($dd.Repariert) { Stop-GuiRequest 409 'Der Datenordner wurde bereits repariert. Bitte Morpheus beenden und über das Startmenü neu starten.' }
        if (-not $g.Admin) { Stop-GuiRequest 403 'Der Datenordner lässt sich nur mit Administratorrechten reparieren.' }
        if ($art -ceq 'reparieren') { Assert-GuiFn 'Repair-MorpheusDatenordner' } else { Assert-GuiFn 'Initialize-MorpheusDataDir' }
        # Confirm-GuiElevated kompiliert beim ersten Aufruf C# per Add-Type (DLL in %TEMP%). Ohne gesicherten Temp-Ordner
        # (pc-check-gui.ps1 legt ihn für den reparierbaren Zustand an) könnte ein Benutzerprogramm die DLL austauschen.
        if (-not $g.TempSicher) { Stop-GuiRequest 409 'Kein gesicherter Temp-Ordner; Reparatur nicht möglich.' }
        # Restrisiko: Ein vor der Reparatur geöffnetes Ordner-Handle mit WRITE_DAC bleibt über die Reparatur hinaus gültig.
        # Erst der Neustart von Morpheus prüft den Datenordner erneut (deshalb "bitte neu starten" nach jeder Reparatur).
        $pfad = [string]$dd.Pfad
        $kontenText = ''
        foreach ($k in @(Get-GuiDnWert $dz 'konten')) {
            $kn = Format-GuiDialogWert (Get-GuiDnWert $k 'name') 80
            $rr = Format-GuiDialogWert (Get-GuiDnWert $k 'rechte') 20
            $kontenText += "`n• " + $kn + $(if ($rr) { ' (' + $rr + ')' } else { '' })
        }
        if (-not $kontenText) { $kontenText = "`n• (keine Konten genannt)" }
        if ($art -ceq 'reparieren') {
            $wasText = 'Es werden die zusätzlichen Rechte entfernt. Die Ordner temp und tools sowie der Zustand werden gelöscht und neu angelegt; Änderungsjournal, Akzeptanzliste und Checkliste werden neu geschrieben, die Berichte bleiben.'
            $titel = 'reparieren'
        }
        else {
            $wasText = 'Der Ordner wird beiseitegelegt und leer neu angelegt. Journal, Akzeptanzliste, Checkliste und Berichte liegen dann nur noch im beiseitegelegten Ordner.'
            $titel = 'neu anlegen'
        }
        $text = "Den Datenordner von Morpheus mit Administratorrechten $titel?`n`nOrdner: " + (Format-GuiDialogWert $pfad 200) +
            "`n`nZusätzliche Rechte für:" + $kontenText + "`n`n" + $wasText + "`n`nHast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'."
        Write-GuiLog "Warte auf Bestätigung im Windows-Dialog (Datenordner $art)"
        $ok = Confirm-GuiElevated $text
        # Während der Dialog offen war, stand die Hauptschleife: Heartbeat-Uhr neu starten
        $g.LastHeartbeat = Get-Date
        if (-not $ok) {
            Write-GuiLog "Im Windows-Dialog abgelehnt (Datenordner $art)"
            Stop-GuiRequest 403 'Im Windows-Bestätigungsdialog abgelehnt. Es wurde nichts geändert.'
        }
        $neustart = ' Morpheus bitte beenden und über das Startmenü neu starten.'
        $meldung = $null; $zustandNeu = 'ok'
        try {
            if ($art -ceq 'reparieren') {
                $r = Repair-MorpheusDatenordner -Path $pfad -InformationAction SilentlyContinue
                $meldung = [string](Get-GuiDnWert $r 'meldung')
                $zn = [string](Get-GuiDnWert $r 'zustand'); if ($zn) { $zustandNeu = $zn }
                if (-not $meldung) { $meldung = 'Die Rechte des Datenordners wurden repariert.' }
            }
            else {
                [void](Initialize-MorpheusDataDir -Path $pfad -Beiseite -InformationAction SilentlyContinue)
                $meldung = 'Der alte Datenordner wurde beiseitegelegt und ein leerer neuer angelegt.'
            }
        }
        catch {
            Write-GuiLog ("Datenordner $art fehlgeschlagen: " + $_.Exception.Message)
            $g.LastHeartbeat = Get-Date
            Stop-GuiRequest 500 ("Der Datenordner ließ sich nicht $titel" + ': ' + $_.Exception.Message)
        }
        $g.LastHeartbeat = Get-Date
        $dd.Repariert = $true
        Write-GuiLog "Datenordner $art erfolgreich (Zustand: $zustandNeu)"
        Send-GuiJson $Res 200 ([ordered]@{ ok = $true; meldung = ($meldung.TrimEnd() + $neustart); zustand = $zustandNeu })
        return
    }
    if ($Path -eq '/api/shutdown') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $g.Stop = $true
        Send-GuiJson $Res 200 ([ordered]@{ ok = $true })
        return
    }
    Stop-GuiRequest 404 'Nicht gefunden.'
}

function Invoke-GuiRequest {
    # Behandelt genau eine Anfrage. Jeder Fehler wird zu einer JSON-Antwort, nie zum Absturz.
    param($Ctx)
    $req = $Ctx.Request; $res = $Ctx.Response
    $g = $script:Gui
    $g.Status = 0
    $method = '?'; $logPath = '?'
    try {
        $method = [string]$req.HttpMethod
        $raw = [string]$req.RawUrl
        $q = $raw.IndexOf('?')
        $rawPath = $raw; if ($q -ge 0) { $rawPath = $raw.Substring(0, $q) }
        $logPath = (($rawPath -replace '[\x00-\x1f]', '?'))
        if ($logPath.Length -gt 200) { $logPath = $logPath.Substring(0, 200) }

        # 2. Host-Prüfung gegen DNS-Rebinding
        if ([string]$req.Headers['Host'] -cne $g.HostHeader) { Stop-GuiRequest 403 'Ungültiger Host.' }
        # 4. Origin
        $origin = $req.Headers['Origin']
        if (($null -ne $origin) -and ($origin -cne $g.Origin)) { Stop-GuiRequest 403 'Ungültiger Origin.' }
        # Methoden: OPTIONS und alles außer GET/POST -> 405, nie CORS-Header
        if ($method -notin 'GET', 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }

        try { $path = [Uri]::UnescapeDataString($rawPath) } catch { Stop-GuiRequest 400 'Ungültiger Pfad.' }
        if (($path -notmatch '^/') -or ($path -match '[\x00-\x1f\\]') -or (($path -split '/') -contains '..') -or (($path -split '/') -contains '.')) {
            Stop-GuiRequest 403 'Ungültiger Pfad.'
        }
        Invoke-GuiRoute $req $res $method $path
    }
    catch {
        $st = 500; $msg = 'Interner Fehler im Server.'
        if ($_.Exception.Data.Contains('status')) { $st = [int]$_.Exception.Data['status']; $msg = $_.Exception.Message }
        else { Write-GuiLog ("FEHLER bei {0} {1}: {2}" -f $method, $logPath, $_.Exception.Message) }
        try { Send-GuiJson $res $st ([ordered]@{ error = $msg }) } catch { }
    }
    finally {
        try { $res.Close() } catch { }
        Write-GuiLog ("{0} {1} {2}" -f $method, $logPath, $g.Status)
    }
}

#endregion

#region Start und Hauptschleife

function Initialize-GuiServer {
    # Root = Codeordner (Katalog, Hilfe, Oberfläche), DataRoot = Daten (reports, changes, state, accepted.psd1; Standard: Root).
    # ReadOnly: Ändern, Rückgängig und Scan sind gesperrt (403), weil der Codeordner nicht gesichert ist.
    param([string]$Root, [int]$Port, [string]$Token, [string]$BootCode, [string]$SafetyPath,
        [string]$DataRoot, [switch]$ReadOnly, [string]$ReadOnlyReason, [string]$DefenderPath, [string]$SysinternalsPath,
        [string]$WartungPath, [string]$WingetPath, $DatenordnerZustand, [string]$DatenordnerPfad, [switch]$TempSicher)
    if (-not $DataRoot) { $DataRoot = $Root }
    Add-Type -AssemblyName System.Web.Extensions
    $version = ''
    try {
        $m = [regex]::Match([IO.File]::ReadAllText((Join-Path $Root 'pc-check.ps1')), '\$ScriptVersion\s*=\s*''([^'']+)''')
        if ($m.Success) { $version = $m.Groups[1].Value }
    }
    catch { }
    $script:Gui = @{
        Root = $Root; DataRoot = $DataRoot; ReadOnly = [bool]$ReadOnly; ReadOnlyReason = $ReadOnlyReason
        Port = $Port; Token = $Token; SafetyPath = $SafetyPath
        DefenderPath = $DefenderPath; SysinternalsPath = $SysinternalsPath; Offline = $null
        WartungPath = $WartungPath; WingetPath = $WingetPath; PunktFehlt = @{}; Updates = $null; WartungLaufwerke = $null
        BootCode = $BootCode; BootExpires = (Get-Date).AddMinutes(2); Tickets = @{}
        Origin = "http://127.0.0.1:$Port"; HostHeader = "127.0.0.1:$Port"
        Admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Version = $version
        TempSicher = [bool]$TempSicher
        Datenordner = $(if ($DatenordnerZustand) { @{ Zustand = $DatenordnerZustand; Pfad = $DatenordnerPfad; Repariert = $false } } else { $null })
        Jobs = @{}; ReportCache = @{}; HelpCache = $null; ActionStates = @{}; Catalog = @()
        Stop = $false; Status = 0; LastHeartbeat = Get-Date; HeartbeatSeen = $false; Listener = $null; Live = $null
    }
    Initialize-GuiWartungDir
    try { Start-GuiLive } catch { Write-GuiLog ('Live-Runspace nicht startbar: ' + $_.Exception.Message) }
    if (Test-GuiFn 'Get-PcCheckCatalog') {
        try { $script:Gui.Catalog = @(Get-PcCheckCatalog -Root $Root) }
        catch { Write-GuiLog ('Katalog nicht ladbar: ' + $_.Exception.Message) }
    }
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://127.0.0.1:$Port/")
    $l.Start()
    $script:Gui.Listener = $l
    Write-GuiLog "Server gestartet auf Port $Port (Admin: $($script:Gui.Admin), NurLesen: $($script:Gui.ReadOnly), Daten: $DataRoot, Katalog: $($script:Gui.Catalog.Count) Aktionen, Safety: $(Test-GuiFn 'Invoke-PcCheckChange'))"
}

function Test-GuiServerEnde {
    # Reine Entscheidung, ob der Server enden soll. Gibt $null (weiter) oder den Grund zurück.
    # Edge drosselt bzw. friert ein Hintergrundfenster nach 2-3 Minuten ein (Intensive Wake-up Throttling,
    # Effizienzmodus); dann bleibt der Heartbeat aus, obwohl das Fenster noch da ist. Mit Edge-Profil ist deshalb
    # die Prozesserkennung maßgeblich. Der Heartbeat ist Rückfall für den Standardbrowser bzw. für den Fall,
    # dass die Prozesserkennung (CIM) dauerhaft ausfällt.
    param(
        [bool]$EdgeProfil, [bool]$EdgeGesehen, [int]$EdgeAnzahl = -1,
        [datetime]$LetzteEdgeZaehlung = [datetime]::MinValue,
        [datetime]$LetzterHeartbeat, [bool]$HeartbeatGesehen, [bool]$Busy,
        [datetime]$Jetzt = (Get-Date), [int]$TimeoutSek = 600
    )
    if ($Busy) { return $null }
    if ($EdgeProfil) {
        if (($EdgeAnzahl -eq 0) -and $EdgeGesehen) { return 'Fenster geschlossen' }
        # Zählung zuletzt vor mehr als 60 s gelungen (oder nie), oder Edge-Prozesse mit unserem Profil nie gesehen
        # (Edge startete nicht bzw. die Erkennung findet das Profil nicht): dann zählt der Heartbeat, sonst liefe der
        # Server ohne Fenster endlos weiter
        $zaehlungAlt = (($Jetzt - $LetzteEdgeZaehlung).TotalSeconds -gt 60)
        if (($zaehlungAlt -or (-not $EdgeGesehen)) -and (($Jetzt - $LetzterHeartbeat).TotalSeconds -gt $TimeoutSek)) { return 'Kein Heartbeat mehr' }
        return $null
    }
    if ($HeartbeatGesehen -and (($Jetzt - $LetzterHeartbeat).TotalSeconds -gt $TimeoutSek)) { return 'Kein Heartbeat mehr' }
    return $null
}

function Start-GuiServerLoop {
    # EdgeProfil: --user-data-dir des App-Fensters oder $null. Gibt den Grund des Endes zurück.
    # Edge startet sich ohne Adminrechte neu, der gestartete Prozess endet also sofort. Deshalb zählen
    # alle msedge-Prozesse mit diesem Profil: Waren welche da und sind alle weg, ist das Fenster zu.
    # Der Heartbeat ist großzügig (10 Minuten), weil Edge Hintergrundfenster drosselt (siehe Test-GuiServerEnde).
    param([string]$EdgeProfile, [int]$HeartbeatTimeoutSec = 600)
    $g = $script:Gui
    $edgeStart = Get-Date
    $edgeSeen = $false
    $edgeCheck = [datetime]::MinValue
    $edgeLastOk = [datetime]::MinValue
    $edgeCount = -1
    $reason = ''
    $task = $null
    while (-not $g.Stop) {
        try {
            if ($null -eq $task) { $task = $g.Listener.GetContextAsync() }
            if ($task.Wait(500)) {
                $ctx = $task.Result; $task = $null
                Invoke-GuiRequest $ctx
            }
        }
        catch {
            $task = $null
            Write-GuiLog ('Schleife: ' + $_.Exception.Message)
            Start-Sleep -Milliseconds 200
        }
        try { Update-GuiJobs } catch { Write-GuiLog ('Update-GuiJobs: ' + $_.Exception.Message) }

        if ($g.Stop) { $reason = 'Beenden angefordert'; break }
        $busy = (Get-GuiRunningJobs).Count -gt 0
        # Edge-Ende: alle 3 s (im Offline-Countdown jede Sekunde) die Prozesse mit unserem Profil zählen
        $edgeInterval = 3
        $countdown = ($g.Offline -and ($g.Offline.Status -eq 'countdown'))
        if ($countdown) { $edgeInterval = 1 }
        $count = -1
        if ($EdgeProfile -and (((Get-Date) - $edgeCheck).TotalSeconds -ge $edgeInterval)) {
            $edgeCheck = Get-Date
            try {
                $count = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
                        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($EdgeProfile, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count
            } catch { }
            if ($count -ge 0) { $edgeLastOk = Get-Date }
            if ($count -gt 0) { $edgeSeen = $true }
            $edgeCount = $count
        }
        # Offline-Countdown (zählt nicht als busy): Abbruch oder Auslösen, ohne zu blockieren
        try { Update-GuiOffline -EdgeCount $count } catch { Write-GuiLog ('Update-GuiOffline: ' + $_.Exception.Message) }
        # Ende: Edge-Prozesse (maßgeblich) bzw. Heartbeat (Rückfall), nie während Jobs laufen
        $ende = Test-GuiServerEnde -EdgeProfil ([bool]$EdgeProfile) -EdgeGesehen $edgeSeen -EdgeAnzahl $edgeCount `
            -LetzteEdgeZaehlung $edgeLastOk -LetzterHeartbeat $g.LastHeartbeat -HeartbeatGesehen ([bool]$g.HeartbeatSeen) `
            -Busy $busy -Jetzt (Get-Date) -TimeoutSek $HeartbeatTimeoutSec
        if ($ende) { $reason = $ende; break }
    }
    if (-not $reason) { $reason = 'Beenden angefordert' }
    # Ein noch laufender Countdown wird nie ausgelöst, sondern abgebrochen
    if ($g.Offline -and ($g.Offline.Status -eq 'countdown')) { Set-GuiOfflineState 'abgebrochen' 'Abgebrochen: Morpheus wurde beendet.' }

    # laufende Jobs abwarten
    $warned = $false
    while ((Get-GuiRunningJobs).Count -gt 0) {
        if (-not $warned) { Write-Host ("Warte auf {0} laufende(n) Job(s) ..." -f (Get-GuiRunningJobs).Count); $warned = $true }
        Start-Sleep -Milliseconds 500
        Update-GuiJobs
    }
    try { $g.Listener.Stop(); $g.Listener.Close() } catch { }
    try { Stop-GuiLive } catch { }
    Write-GuiLog "Server beendet ($reason)"
    return $reason
}

#endregion
