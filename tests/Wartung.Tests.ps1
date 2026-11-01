#Requires -Version 5.1
# Pester-3.4-Tests für gui\lib\Wartung.ps1.
# Ruft nie echte Werkzeuge auf (DISM, SFC, chkdsk, winget, defrag, powercfg, w32tm, ipconfig, Wiederherstellungspunkt):
# Prozess, Punkt, Ohne, WingetPfad und Jetzt sind Attrappen. Der Prozess-Runner wird nur mit cmd.exe /c echo und ping 127.0.0.1 getestet.
# Ausführen: Invoke-Pester tests\Wartung.Tests.ps1

. (Join-Path $PSScriptRoot '..\gui\lib\Wartung.ps1')

# Attrappen für die Funktionen aus WartungAuswertung.ps1 und Winget.ps1, falls diese Dateien (noch) fehlen
if (-not (Get-Command -Name Format-MorpheusWartungZeile -ErrorAction SilentlyContinue)) {
    function Format-MorpheusWartungZeile { param([string]$Text) ($Text -replace '[\x00-\x08\x0B-\x1F]', '').Trim() }
}
if (-not (Get-Command -Name Get-MorpheusWartungFortschritt -ErrorAction SilentlyContinue)) {
    function Get-MorpheusWartungFortschritt {
        param([string]$Zeile)
        $m = [regex]::Match($Zeile, '(\d+(?:[.,]\d+)?)\s*%')
        if ($m.Success) { return [double]($m.Groups[1].Value -replace ',', '.') }
        $null
    }
}
if (-not (Get-Command -Name Get-MorpheusWartungZusammenfassung -ErrorAction SilentlyContinue)) {
    function Get-MorpheusWartungZusammenfassung {
        param([string]$Werkzeug, [string]$Text, $ExitCode)
        if ($ExitCode -eq 0) { return @{ ergebnis = 'ok'; text = 'In Ordnung.'; empfehlung = $null; details = @() } }
        @{ ergebnis = 'fehler'; text = ('Fehler, Code {0}' -f $ExitCode); empfehlung = $null; details = @() }
    }
}
if (-not (Get-Command -Name Get-MorpheusWartungKurzfassung -ErrorAction SilentlyContinue)) {
    function Get-MorpheusWartungKurzfassung { param($Zusammenfassung, $ExitCode, $DauerSek) [string]$Zusammenfassung.text }
}
if (-not (Get-Command -Name Test-MorpheusWingetId -ErrorAction SilentlyContinue)) {
    function Test-MorpheusWingetId { param([string]$Id) $Id -cmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$' }
}
if (-not (Get-Command -Name Get-MorpheusWingetUpgradeArgumente -ErrorAction SilentlyContinue)) {
    function Get-MorpheusWingetUpgradeArgumente {
        param([string]$Id)
        "upgrade --id $Id --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
    }
}
if (-not (Get-Command -Name Get-MorpheusWingetErgebnis -ErrorAction SilentlyContinue)) {
    function Get-MorpheusWingetErgebnis {
        param($ExitCode)
        if ($ExitCode -eq 0) { return @{ status = 'aktualisiert'; text = 'Das Programm wurde aktualisiert.' } }
        @{ status = 'fehlgeschlagen'; text = ('winget endete mit Code {0}.' -f $ExitCode) }
    }
}

$script:CmdExe = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
# Standard-Eintrag WingetBenutzer (vor dem Ersetzen durch Attrappen) für den Test „kein Rückfall“
$script:WartungImplWingetBenutzerEcht = $script:MorpheusWartungImpl.WingetBenutzer

# Attrappen für Prozess, Punkt, Ohne, WingetPfad, Jetzt
function Set-FakeWartung {
    $script:Aufrufe = New-Object System.Collections.ArrayList
    $script:PunktAufrufe = New-Object System.Collections.ArrayList
    $script:OhneAufrufe = New-Object System.Collections.ArrayList
    $script:PunktFehler = $null
    $script:ProzessZeilen = @('Zeile eins', 'Zeile zwei')
    $script:ProzessExit = 0
    $script:ProzessAbgebrochen = $false
    $script:ProzessZeit = $false
    $script:ProzessWerfen = $null
    $script:ProzessHook = $null
    $script:WingetPfad = 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.0_x64__8wekyb3d8bbwe\winget.exe'
    $script:WingetGrund = 'winget fehlt.'
    $script:BenutzerFehler = $null
    $script:MorpheusWartungImpl = @{
        # winget ohne Adminrechte (2.5): gleiche Steuervariablen wie Prozess, Aufruf mit Benutzer = $true
        WingetBenutzer = {
            param($Datei, $Argumente, $ZeitlimitSek, $Zeile)
            [void]$script:Aufrufe.Add([pscustomobject]@{ Datei = $Datei; Argumente = $Argumente; Kodierung = $null; AbbruchDatei = $null; ZeitlimitSek = $ZeitlimitSek; Benutzer = $true })
            if ($script:ProzessWerfen) { throw $script:ProzessWerfen }
            if ($script:ProzessHook) { & $script:ProzessHook $script:Aufrufe.Count $Argumente }
            foreach ($z in @($script:ProzessZeilen)) { if ($Zeile) { & $Zeile $z } }
            $ex = $script:ProzessExit
            if ($script:BenutzerFehler) { $ex = $null }
            [pscustomobject]@{ exitCode = $ex; text = (@($script:ProzessZeilen) -join "`n"); abgebrochen = $false; zeitueberschritten = $script:ProzessZeit; dauerSek = 7; benutzerkontext = $true; fehler = $script:BenutzerFehler }
        }
        Prozess    = {
            param($Datei, $Argumente, $Kodierung, $AbbruchDatei, $ZeitlimitSek, $Zeile)
            [void]$script:Aufrufe.Add([pscustomobject]@{ Datei = $Datei; Argumente = $Argumente; Kodierung = $Kodierung; AbbruchDatei = $AbbruchDatei; ZeitlimitSek = $ZeitlimitSek; Benutzer = $false })
            if ($script:ProzessWerfen) { throw $script:ProzessWerfen }
            if ($script:ProzessHook) { & $script:ProzessHook $script:Aufrufe.Count $Argumente }
            foreach ($z in @($script:ProzessZeilen)) { if ($Zeile) { & $Zeile $z } }
            [pscustomobject]@{ exitCode = $script:ProzessExit; text = (@($script:ProzessZeilen) -join "`n"); abgebrochen = $script:ProzessAbgebrochen; zeitueberschritten = $script:ProzessZeit; dauerSek = 7 }
        }
        Punkt      = {
            param($Beschreibung, $JobStart)
            [void]$script:PunktAufrufe.Add($Beschreibung)
            if ($script:PunktFehler) { throw $script:PunktFehler }
            @{ seq = 58; zeit = '2026-10-26T15:30:12' }
        }
        Laufwerke  = { , @() }
        Ohne       = { param($Datei, $Argumente) [void]$script:OhneAufrufe.Add(@($Datei, $Argumente)) }
        WingetPfad = { @{ pfad = $script:WingetPfad; grund = $script:WingetGrund } }
        Jetzt      = { Get-Date }
    }
}

function Get-TestJournal { param($Root) $p = Join-Path $Root 'changes\journal.json'; if (Test-Path -LiteralPath $p) { $o = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($p)); @($o) } else { @() } }

# Ergebnis und Log-Zeilen eines Aufrufs trennen
function Invoke-Wartung {
    param([hashtable]$Args1)
    $alle = @(Invoke-MorpheusWartung @Args1 -InformationAction Continue 6>&1)
    $script:Log = @($alle | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
    $erg = @($alle | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
    $script:Anzahl = $erg.Count
    $erg[0]
}

Describe 'Katalog' {
    $ids = @('wiederherstellung.punkt', 'dism.checkhealth', 'dism.scanhealth', 'dism.restorehealth', 'sfc.scannow', 'dism.analyze', 'dism.cleanup', 'chkdsk.scan', 'perfmon.rel', 'dns.flush', 'trim', 'zeit.resync', 'powercfg.energy', 'powercfg.akku', 'powercfg.schlaf', 'winget.upgrade')

    It 'enthält genau die 16 Ids in Tabellenreihenfolge' {
        @($script:MorpheusWartungKatalog.Keys).Count | Should Be 16
        (@($script:MorpheusWartungKatalog.Keys) -join ',') | Should Be ($ids -join ',')
    }
    It 'hat bei jedem Eintrag alle Felder' {
        foreach ($id in $ids) {
            $k = $script:MorpheusWartungKatalog[$id]
            foreach ($f in 'Gruppe', 'Schritt', 'Klasse', 'Titel', 'Erklaerung', 'Programm', 'Argumente', 'Anzeige', 'Abbruch', 'Parameter', 'ZeitlimitSek', 'Dauer', 'Internet', 'Hinweis', 'Kodierung', 'Bericht') {
                $k.ContainsKey($f) | Should Be $true
            }
            ([string]$k.Titel).Length | Should BeGreaterThan 3
            ([string]$k.Erklaerung).Length | Should BeGreaterThan 10
            ([string]$k.Anzeige).Length | Should BeGreaterThan 3
            @('diagnose', 'wartung', 'reparatur') -contains $k.Klasse | Should Be $true
            @('sofort', 'nach-paket', 'nein') -contains $k.Abbruch | Should Be $true
            @('oem', 'utf8') -contains $k.Kodierung | Should Be $true
        }
    }
    It 'verwendet in den Argumenten nur {LW}, {BERICHT} und {ID}' {
        foreach ($id in $ids) {
            foreach ($m in [regex]::Matches([string]$script:MorpheusWartungKatalog[$id].Argumente, '\{[^}]*\}')) {
                @('{LW}', '{BERICHT}', '{ID}') -contains $m.Value | Should Be $true
            }
        }
    }
    It 'enthält weder ResetBase noch chkdsk /f' {
        foreach ($id in $ids) {
            $t = [string]$script:MorpheusWartungKatalog[$id].Argumente + ' ' + [string]$script:MorpheusWartungKatalog[$id].Anzeige
            $t | Should Not Match 'ResetBase'
        }
        $c = $script:MorpheusWartungKatalog['chkdsk.scan']
        $c.Argumente | Should Be '{LW} /scan'
        $c.Argumente | Should Not Match '/f\b'
    }
    It 'Klasse reparatur entspricht Punkt' {
        foreach ($w in @((Get-MorpheusWartungWerkzeuge))) {
            $w.punkt | Should Be ($w.klasse -ceq 'reparatur')
        }
        (@(Get-MorpheusWartungWerkzeuge) | Where-Object { $_.punkt } | ForEach-Object { $_.id }) -join ',' | Should Be 'dism.restorehealth,sfc.scannow,dism.cleanup,winget.upgrade'
    }
    It 'Abbruch nein bei restorehealth, cleanup und sfc' {
        foreach ($id in 'dism.restorehealth', 'dism.cleanup', 'sfc.scannow') { $script:MorpheusWartungKatalog[$id].Abbruch | Should Be 'nein' }
        $script:MorpheusWartungKatalog['winget.upgrade'].Abbruch | Should Be 'nach-paket'
    }
    It 'nur winget nutzt utf8, nur winget und restorehealth brauchen Internet' {
        foreach ($id in $ids) {
            $script:MorpheusWartungKatalog[$id].Kodierung | Should Be $(if ($id -ceq 'winget.upgrade') { 'utf8' } else { 'oem' })
        }
        $script:MorpheusWartungKatalog['dism.restorehealth'].Internet | Should Be $true
        $script:MorpheusWartungKatalog['winget.upgrade'].Internet | Should Be $true
    }
    It 'Get-MorpheusWartungWerkzeuge liefert öffentliche Objekte' {
        $w = @(Get-MorpheusWartungWerkzeuge)
        $w.Count | Should Be 16
        $c = $w | Where-Object { $_.id -ceq 'chkdsk.scan' }
        $c.parameter | Should Be 'laufwerk'
        $c.befehl | Should Be 'chkdsk.exe <LW> /scan'
        ($w | Where-Object { $_.id -ceq 'powercfg.energy' }).bericht | Should Be $true
        ($w | Where-Object { $_.id -ceq 'dns.flush' }).bericht | Should Be $false
    }
}

Describe 'Get-MorpheusWartungBefehl' {
    BeforeEach { Set-FakeWartung }
    It 'nutzt den System32-Pfad aus Get-MorpheusSystemProgramm' {
        $sys = [Environment]::GetFolderPath('System')
        (Get-MorpheusWartungBefehl -Werkzeug 'dism.restorehealth') | Should Be ((Join-Path $sys 'Dism.exe') + ' /Online /Cleanup-Image /RestoreHealth')
        (Get-MorpheusWartungBefehl -Werkzeug 'chkdsk.scan' -Laufwerk 'D:') | Should Be ((Join-Path $sys 'chkdsk.exe') + ' D: /scan')
        (Get-MorpheusWartungBefehl -Werkzeug 'dism.restorehealth') | Should Be ((Get-MorpheusSystemProgramm 'Dism.exe') + ' /Online /Cleanup-Image /RestoreHealth')
    }
    It 'setzt den Berichtspfad in Anführungszeichen' {
        (Get-MorpheusWartungBefehl -Werkzeug 'powercfg.akku' -Bericht 'C:\x y\a.html') | Should Match '/batteryreport /output "C:\\x y\\a.html"$'
    }
    It 'winget: Pfad aus der Impl und Paket-Id' {
        $b = Get-MorpheusWartungBefehl -Werkzeug 'winget.upgrade' -Id 'Demo.App'
        $b | Should Match 'winget\.exe'
        $b | Should Match '--id Demo\.App '
    }
    It 'wirft bei unbekanntem Werkzeug' {
        { Get-MorpheusWartungBefehl -Werkzeug 'nope' } | Should Throw
    }
}

Describe 'Test-MorpheusWartungAuftrag' {
    $lw = @(
        [pscustomobject]@{ laufwerk = 'C:'; bezeichnung = 'System'; ssd = $true },
        [pscustomobject]@{ laufwerk = 'D:'; bezeichnung = 'Daten'; ssd = $false },
        [pscustomobject]@{ laufwerk = 'E:'; bezeichnung = 'Unbekannt'; ssd = $null }
    )
    It 'akzeptiert gültige Aufträge' {
        Test-MorpheusWartungAuftrag -Werkzeug 'dism.checkhealth' -Laufwerk '' -Laufwerke $lw | Should BeNullOrEmpty
        Test-MorpheusWartungAuftrag -Werkzeug 'dns.flush' -Laufwerk $null -Laufwerke $lw | Should BeNullOrEmpty
        Test-MorpheusWartungAuftrag -Werkzeug 'chkdsk.scan' -Laufwerk 'D:' -Laufwerke $lw | Should BeNullOrEmpty
        Test-MorpheusWartungAuftrag -Werkzeug 'trim' -Laufwerk 'C:' -Laufwerke $lw | Should BeNullOrEmpty
        Test-MorpheusWartungAuftrag -Werkzeug 'wiederherstellung.punkt' -Laufwerk '' -Laufwerke $lw | Should BeNullOrEmpty
    }
    It 'lehnt unbekannte Ids und falsche Schreibweise ab' {
        Test-MorpheusWartungAuftrag -Werkzeug 'nope' -Laufwerk '' -Laufwerke $lw | Should Not BeNullOrEmpty
        Test-MorpheusWartungAuftrag -Werkzeug 'DISM.checkhealth' -Laufwerk '' -Laufwerke $lw | Should Not BeNullOrEmpty
        Test-MorpheusWartungAuftrag -Werkzeug '' -Laufwerk '' -Laufwerke $lw | Should Not BeNullOrEmpty
    }
    It 'lehnt winget.upgrade und perfmon.rel ab' {
        Test-MorpheusWartungAuftrag -Werkzeug 'winget.upgrade' -Laufwerk '' -Laufwerke $lw | Should Not BeNullOrEmpty
        Test-MorpheusWartungAuftrag -Werkzeug 'perfmon.rel' -Laufwerk '' -Laufwerke $lw | Should Not BeNullOrEmpty
    }
    It 'prüft das Laufwerk' {
        Test-MorpheusWartungAuftrag -Werkzeug 'chkdsk.scan' -Laufwerk '' -Laufwerke $lw | Should Not BeNullOrEmpty
        Test-MorpheusWartungAuftrag -Werkzeug 'dns.flush' -Laufwerk 'C:' -Laufwerke $lw | Should Not BeNullOrEmpty
        Test-MorpheusWartungAuftrag -Werkzeug 'chkdsk.scan' -Laufwerk 'Z:' -Laufwerke $lw | Should Not BeNullOrEmpty
        Test-MorpheusWartungAuftrag -Werkzeug 'chkdsk.scan' -Laufwerk 'C:\' -Laufwerke $lw | Should Not BeNullOrEmpty
        Test-MorpheusWartungAuftrag -Werkzeug 'chkdsk.scan' -Laufwerk 'c:' -Laufwerke $lw | Should Not BeNullOrEmpty
        Test-MorpheusWartungAuftrag -Werkzeug 'chkdsk.scan' -Laufwerk 'C: /f' -Laufwerke $lw | Should Not BeNullOrEmpty
    }
    It 'TRIM nur für erkannte SSDs' {
        Test-MorpheusWartungAuftrag -Werkzeug 'trim' -Laufwerk 'D:' -Laufwerke $lw | Should Not BeNullOrEmpty
        Test-MorpheusWartungAuftrag -Werkzeug 'trim' -Laufwerk 'E:' -Laufwerke $lw | Should Not BeNullOrEmpty
        Test-MorpheusWartungAuftrag -Werkzeug 'trim' -Laufwerk 'C:' -Laufwerke @() | Should Not BeNullOrEmpty
    }
}

Describe 'Get-MorpheusWartungBerichte' {
    It 'listet nur Musternamen, neueste zuerst, höchstens 20' {
        $root = Join-Path $TestDrive 'berichte'
        $dir = Join-Path $root 'reports'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($n in 'morpheus-energy_2026-10-26_153012.html', 'morpheus-akku_2026-10-27_080000.html', 'morpheus-schlaf_2026-10-25_010101.html', 'morpheus-evil_2026-10-26_153012.html', 'andere.html', 'morpheus-energy_2026-10-26_153012.html.txt') {
            Set-Content -LiteralPath (Join-Path $dir $n) -Value 'x'
        }
        $l = @(Get-MorpheusWartungBerichte -DataRoot $root)
        $l.Count | Should Be 3
        $l[0].name | Should Be 'morpheus-akku_2026-10-27_080000.html'
        $l[0].art | Should Be 'akku'
        $l[0].zeit | Should Be '2026-10-27T08:00:00'
        $l[2].art | Should Be 'schlaf'
        for ($i = 0; $i -lt 25; $i++) { Set-Content -LiteralPath (Join-Path $dir ('morpheus-energy_2026-09-{0:00}_100000.html' -f ($i + 1))) -Value 'x' }
        @(Get-MorpheusWartungBerichte -DataRoot $root).Count | Should Be 20
    }
    It 'liefert ohne Ordner ein leeres Array' {
        @(Get-MorpheusWartungBerichte -DataRoot (Join-Path $TestDrive 'nichts')).Count | Should Be 0
    }
}

Describe 'Invoke-MorpheusWartung: Argumente' {
    BeforeEach { Set-FakeWartung; $script:dr = Join-Path $TestDrive ('d' + [guid]::NewGuid().ToString('N')) }
    It 'wirft bei falschen Argumenten' {
        { Invoke-MorpheusWartung -DataRoot $script:dr -Werkzeug 'nope' } | Should Throw
        { Invoke-MorpheusWartung -DataRoot $script:dr -Werkzeug 'chkdsk.scan' } | Should Throw
        { Invoke-MorpheusWartung -DataRoot $script:dr -Werkzeug 'chkdsk.scan' -Laufwerk 'c:' } | Should Throw
        { Invoke-MorpheusWartung -DataRoot $script:dr -Werkzeug 'dns.flush' -Laufwerk 'C:' } | Should Throw
        { Invoke-MorpheusWartung -DataRoot $script:dr -Werkzeug 'winget.upgrade' } | Should Throw
        { Invoke-MorpheusWartung -DataRoot $script:dr -Werkzeug 'winget.upgrade' -Pakete @(@{ id = 'a b; calc'; name = 'x'; von = '1'; auf = '2' }) } | Should Throw
        $script:Aufrufe.Count | Should Be 0
    }
}

Describe 'Invoke-MorpheusWartung: Programmpfad nicht auflösbar' {
    BeforeEach { Set-FakeWartung; $script:dr = Join-Path $TestDrive ('d' + [guid]::NewGuid().ToString('N')) }
    It 'Programm nicht auflösbar (Get-MorpheusSystemProgramm wirft) -> fehlgeschlagen, nichts gestartet, kein Journal' {
        Mock Get-MorpheusSystemProgramm { throw 'Das Windows-Programm fehlt.' }
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'dism.checkhealth' }
        $r.status | Should Be 'fehlgeschlagen'
        $r.meldung | Should Match 'nichts gestartet'
        $r.meldung | Should Match 'fehlt'
        $script:Aufrufe.Count | Should Be 0
        $script:PunktAufrufe.Count | Should Be 0
        @(Get-TestJournal $script:dr).Count | Should Be 0
    }
}

Describe 'Invoke-MorpheusWartung: Prozess-Werkzeuge' {
    BeforeEach { Set-FakeWartung; $script:dr = Join-Path $TestDrive ('d' + [guid]::NewGuid().ToString('N')) }

    It 'diagnose: ohne Punkt, Journal begonnen -> erledigt mit allen Feldern' {
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'dism.checkhealth' }
        $script:Anzahl | Should Be 1
        $r.status | Should Be 'erledigt'
        $r.werkzeug | Should Be 'dism.checkhealth'
        $r.klasse | Should Be 'diagnose'
        $r.exitCode | Should Be 0
        $r.dauerSek | Should Be 7
        $r.punkt | Should BeNullOrEmpty
        $r.ohnePunkt | Should Be $false
        $r.zusammenfassung.ergebnis | Should Not BeNullOrEmpty
        $script:PunktAufrufe.Count | Should Be 0
        $script:Aufrufe.Count | Should Be 1
        $script:Aufrufe[0].Datei | Should Be (Join-Path ([Environment]::GetFolderPath('System')) 'Dism.exe')
        $script:Aufrufe[0].Argumente | Should Be '/Online /Cleanup-Image /CheckHealth'
        $script:Aufrufe[0].Kodierung | Should Be 'oem'
        $script:Aufrufe[0].ZeitlimitSek | Should Be 600
        $j = @(Get-TestJournal $script:dr)
        $j.Count | Should Be 1
        $j[0].art | Should Be 'wartung'
        $j[0].aktion | Should Be 'dism.checkhealth'
        $j[0].status | Should Be 'erledigt'
        $j[0].umkehrbar | Should Be $false
        $j[0].exitCode | Should Be 0
        $j[0].dauerSek | Should Be 7
        $j[0].befehl | Should Be $r.befehl
        $j[0].ohnePunkt | Should Be $false
        $j[0].id | Should Be $r.journal
        $j[0].meldung.Length | Should BeLessThan 501
        $script:Log -contains 'x' | Should Be $false
        (@($script:Log | Where-Object { $_ -match '^\[\d\d:\d\d:\d\d\] Starte: ' })).Count | Should Be 1
        (@($script:Log | Where-Object { $_ -match '\] Ergebnis: ' })).Count | Should Be 1
        (@($script:Log | Where-Object { $_ -match '\] Zeile eins$' })).Count | Should Be 1
    }

    It 'reparatur: Punkt vor dem Start, Journal enthält den Punkt, umkehrbar false' {
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'dism.restorehealth' }
        $r.status | Should Be 'erledigt'
        $r.punkt.seq | Should Be 58
        $script:PunktAufrufe.Count | Should Be 1
        $script:PunktAufrufe[0] | Should Be 'Morpheus: vor DISM: Komponentenspeicher reparieren'
        $script:Aufrufe.Count | Should Be 1
        $script:Aufrufe[0].ZeitlimitSek | Should Be 7200
        $j = @(Get-TestJournal $script:dr)
        $j.Count | Should Be 1
        $j[0].wiederherstellungspunkt.seq | Should Be 58
        $j[0].umkehrbar | Should Be $false
        $j[0].titel | Should Be 'DISM: Komponentenspeicher reparieren'
    }

    It 'Punktbeschreibung hat höchstens 64 Zeichen' {
        $script:MorpheusWartungKatalog['dism.cleanup'].Titel = ('Lang ' * 30)
        try { $null = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'dism.cleanup' } }
        finally { $script:MorpheusWartungKatalog['dism.cleanup'].Titel = 'DISM: Komponentenspeicher bereinigen' }
        $script:PunktAufrufe[0].Length | Should BeLessThan 65
    }

    It 'reparatur: Punkt fehlt -> punkt-fehlt, nichts gestartet, kein Journal' {
        $script:PunktFehler = 'Es konnte kein Wiederherstellungspunkt angelegt werden. Befehl: Enable-ComputerRestore'
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'sfc.scannow' }
        $r.status | Should Be 'punkt-fehlt'
        $r.meldung | Should Match 'Enable-ComputerRestore'
        $script:Aufrufe.Count | Should Be 0
        @(Get-TestJournal $script:dr).Count | Should Be 0
    }

    It 'OhnePunkt: kein Punktaufruf, Log-Zeile, ohnePunkt im Ergebnis und Journal' {
        $script:PunktFehler = 'sollte nie aufgerufen werden'
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'sfc.scannow'; OhnePunkt = $true }
        $r.status | Should Be 'erledigt'
        $r.ohnePunkt | Should Be $true
        $script:PunktAufrufe.Count | Should Be 0
        $script:Aufrufe.Count | Should Be 1
        (@($script:Log | Where-Object { $_ -match 'Ohne Wiederherstellungspunkt \(vom Nutzer bestätigt\)' })).Count | Should Be 1
        @(Get-TestJournal $script:dr)[0].ohnePunkt | Should Be $true
    }

    It 'Fehler-Exitcode -> fehlgeschlagen, Journal fehlgeschlagen' {
        $script:ProzessExit = 1
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'dism.scanhealth' }
        $r.status | Should Be 'fehlgeschlagen'
        $r.exitCode | Should Be 1
        @(Get-TestJournal $script:dr)[0].status | Should Be 'fehlgeschlagen'
    }

    It 'abgebrochen -> status abgebrochen, Journal abgebrochen' {
        $script:ProzessAbgebrochen = $true
        $script:ProzessExit = 1
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'dism.scanhealth' }
        $r.status | Should Be 'abgebrochen'
        @(Get-TestJournal $script:dr)[0].status | Should Be 'abgebrochen'
    }

    It 'Zeitüberschreitung -> zeitueberschreitung, Journal fehlgeschlagen' {
        $script:ProzessZeit = $true
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'dns.flush' }
        $r.status | Should Be 'zeitueberschreitung'
        $r.zusammenfassung.ergebnis | Should Be 'fehler'
        @(Get-TestJournal $script:dr)[0].status | Should Be 'fehlgeschlagen'
    }

    It 'Prozess nicht startbar -> fehlgeschlagen mit Meldung, wirft nicht' {
        $script:ProzessWerfen = 'Die Datei wurde nicht gefunden.'
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'dns.flush' }
        $r.status | Should Be 'fehlgeschlagen'
        $r.meldung | Should Match 'nicht gefunden'
        @(Get-TestJournal $script:dr)[0].status | Should Be 'fehlgeschlagen'
    }

    It 'Laufwerk landet im Befehl und im Journal als Variante' {
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'chkdsk.scan'; Laufwerk = 'D:' }
        $r.laufwerk | Should Be 'D:'
        $script:Aufrufe[0].Argumente | Should Be 'D: /scan'
        $r.befehl | Should Match 'chkdsk\.exe D: /scan$'
        @(Get-TestJournal $script:dr)[0].variante | Should Be 'D:'
    }

    It 'powercfg: Berichtspfad unter reports, Ergebnis nennt den Dateinamen, wenn die Datei existiert' {
        $script:ProzessHook = {
            param($n, $argz)
            $m = [regex]::Match($argz, '/output "([^"]+)"')
            Set-Content -LiteralPath $m.Groups[1].Value -Value '<html></html>'
        }
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'powercfg.energy' }
        $r.bericht | Should Match '^morpheus-energy_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.html$'
        Test-Path -LiteralPath (Join-Path (Join-Path $script:dr 'reports') $r.bericht) | Should Be $true
        $script:Aufrufe[0].Argumente | Should Match '^/energy /output "[^"]+morpheus-energy_[^"]+\.html" /duration 60$'
        $script:Aufrufe[0].Argumente.Contains((Join-Path $script:dr 'reports')) | Should Be $true
        $script:Aufrufe[0].ZeitlimitSek | Should Be 240
    }

    It 'powercfg: ohne erzeugte Datei ist bericht null' {
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'powercfg.akku' }
        $r.bericht | Should BeNullOrEmpty
        $script:Aufrufe[0].Argumente | Should Match '^/batteryreport /output "[^"]+morpheus-akku_'
    }

    It 'Abbruch-Flag-Datei wird am Ende entfernt und an den Prozess gereicht' {
        $flag = Join-Path $TestDrive 'flag1.txt'
        Set-Content -LiteralPath $flag -Value 'x'
        $script:ProzessAbgebrochen = $true
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'dism.scanhealth'; AbbruchDatei = $flag }
        $r.status | Should Be 'abgebrochen'
        $script:Aufrufe[0].AbbruchDatei | Should Be $flag
        Test-Path -LiteralPath $flag | Should Be $false
    }

    It 'begrenzt die Log-Zeilen auf 4000 plus Kürzungshinweis' {
        $script:ProzessZeilen = @(1..4500 | ForEach-Object { "Ausgabe $_" })
        $null = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'dns.flush' }
        (@($script:Log | Where-Object { $_ -match '\] Ausgabe ' })).Count | Should Be 4000
        (@($script:Log | Where-Object { $_ -match 'weitere Ausgabe gekürzt' })).Count | Should Be 1
    }

    It 'drosselt Fortschrittszeilen auf Sprünge von mindestens 10 Prozentpunkten' {
        $script:ProzessZeilen = @(0..100 | ForEach-Object { '[==== {0}.0% ]' -f $_ }) + @('', '   ')
        $null = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'dns.flush' }
        $fort = @($script:Log | Where-Object { $_ -match '\[=+ ' })
        $fort.Count | Should BeLessThan 15
        $fort.Count | Should BeGreaterThan 9
        ($fort[$fort.Count - 1]) | Should Match '100\.0%'
    }
}

Describe 'Invoke-MorpheusWartung: Wiederherstellungspunkt-Knopf' {
    BeforeEach { Set-FakeWartung; $script:dr = Join-Path $TestDrive ('d' + [guid]::NewGuid().ToString('N')) }
    It 'Erfolg: Punkt, Journal erledigt, kein Prozess' {
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'wiederherstellung.punkt' }
        $r.status | Should Be 'erledigt'
        $r.zusammenfassung.ergebnis | Should Be 'ok'
        $r.zusammenfassung.text | Should Be 'Wiederherstellungspunkt #58 angelegt und geprüft.'
        $r.punkt.seq | Should Be 58
        $script:PunktAufrufe[0] | Should Be 'Morpheus: von Hand angelegt'
        $script:Aufrufe.Count | Should Be 0
        $j = @(Get-TestJournal $script:dr)
        $j.Count | Should Be 1
        $j[0].art | Should Be 'wartung'
        $j[0].aktion | Should Be 'wiederherstellung.punkt'
        $j[0].status | Should Be 'erledigt'
        $j[0].wiederherstellungspunkt.seq | Should Be 58
        $j[0].umkehrbar | Should Be $false
        $j[0].exitCode | Should BeNullOrEmpty
        $j[0].befehl | Should Match 'Checkpoint-Computer'
    }
    It 'Fehler: fehlgeschlagen mit Meldung, Empfehlung, kein Journal' {
        $script:PunktFehler = 'Es konnte kein Punkt angelegt werden. Zur Behebung: Befehl X'
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'wiederherstellung.punkt' }
        $r.status | Should Be 'fehlgeschlagen'
        $r.meldung | Should Match 'Befehl X'
        $r.zusammenfassung.ergebnis | Should Be 'fehler'
        $r.zusammenfassung.empfehlung | Should Match '24-Stunden-Sperre'
        @(Get-TestJournal $script:dr).Count | Should Be 0
    }
}

Describe 'Invoke-MorpheusWartung: winget' {
    BeforeEach {
        Set-FakeWartung
        $script:dr = Join-Path $TestDrive ('d' + [guid]::NewGuid().ToString('N'))
        $script:pak = @(
            @{ id = 'Demo.App'; name = 'Demo App'; von = '1.0'; auf = '1.1' },
            [pscustomobject]@{ id = 'Other.Tool'; name = 'Other Tool'; von = '2.0'; auf = '2.5' }
        )
    }
    It 'zwei Pakete: zwei Journal-Einträge art update, Punkt einmal' {
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'winget.upgrade'; Pakete = $script:pak }
        $r.status | Should Be 'erledigt'
        @($r.pakete).Count | Should Be 2
        $r.pakete[0].id | Should Be 'Demo.App'
        $r.pakete[0].status | Should Be 'aktualisiert'
        $r.pakete[1].id | Should Be 'Other.Tool'
        $script:PunktAufrufe.Count | Should Be 1
        $script:PunktAufrufe[0] | Should Be 'Morpheus: vor Programme mit winget aktualisieren'
        $script:Aufrufe.Count | Should Be 2
        $script:Aufrufe[0].Datei | Should Be $script:WingetPfad
        $script:Aufrufe[0].Argumente | Should Match '--id Demo\.App '
        $script:Aufrufe[1].Argumente | Should Match '--id Other\.Tool '
        $script:Aufrufe[0].Benutzer | Should Be $true
        $script:Aufrufe[1].Benutzer | Should Be $true
        $script:Aufrufe[0].ZeitlimitSek | Should Be 1800
        $j = @(Get-TestJournal $script:dr)
        $j.Count | Should Be 2
        $j[0].art | Should Be 'update'
        $j[0].aktion | Should Be 'winget.upgrade'
        $j[0].titel | Should Be 'Update: Demo App 1.0 → 1.1'
        $j[0].variante | Should Be 'Demo.App'
        $j[0].status | Should Be 'erledigt'
        $j[0].umkehrbar | Should Be $false
        $j[0].wiederherstellungspunkt.seq | Should Be 58
        $j[1].variante | Should Be 'Other.Tool'
        (@($script:Log | Where-Object { $_ -match 'Paket 1/2: Demo App \(1\.0 → 1\.1\)' })).Count | Should Be 1
        (@($script:Log | Where-Object { $_ -match 'Paket 2/2: Other Tool \(2\.0 → 2\.5\)' })).Count | Should Be 1
    }
    It 'ohne sicheren winget-Pfad: fehlgeschlagen, nichts gestartet, kein Punkt' {
        $script:WingetPfad = $null
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'winget.upgrade'; Pakete = $script:pak }
        $r.status | Should Be 'fehlgeschlagen'
        $r.meldung | Should Be 'winget fehlt.'
        $script:Aufrufe.Count | Should Be 0
        $script:PunktAufrufe.Count | Should Be 0
        @(Get-TestJournal $script:dr).Count | Should Be 0
    }
    It 'Punkt fehlt: punkt-fehlt, nichts gestartet' {
        $script:PunktFehler = 'kein Punkt'
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'winget.upgrade'; Pakete = $script:pak }
        $r.status | Should Be 'punkt-fehlt'
        $script:Aufrufe.Count | Should Be 0
        @(Get-TestJournal $script:dr).Count | Should Be 0
    }
    It 'Abbruch zwischen Paketen: zweites nicht gestartet, Flag am Ende entfernt' {
        $flag = Join-Path $TestDrive 'flag2.txt'
        $script:flagPfad = $flag
        $script:ProzessHook = { param($n, $argz) Set-Content -LiteralPath $script:flagPfad -Value 'x' }
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'winget.upgrade'; Pakete = $script:pak; AbbruchDatei = $flag }
        $r.status | Should Be 'abgebrochen'
        $script:Aufrufe.Count | Should Be 1
        $r.pakete[0].status | Should Be 'aktualisiert'
        $r.pakete[1].status | Should Be 'abgebrochen'
        @(Get-TestJournal $script:dr).Count | Should Be 1
        Test-Path -LiteralPath $flag | Should Be $false
    }
    It 'ein fehlgeschlagenes Paket: Gesamtstatus fehlgeschlagen, das andere läuft weiter' {
        $script:ProzessHook = { param($n, $argz) if ($n -eq 1) { $script:ProzessExit = 5 } else { $script:ProzessExit = 0 } }
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'winget.upgrade'; Pakete = $script:pak }
        $r.status | Should Be 'fehlgeschlagen'
        $r.pakete[0].status | Should Be 'fehlgeschlagen'
        $r.pakete[1].status | Should Be 'aktualisiert'
        $j = @(Get-TestJournal $script:dr)
        $j[0].status | Should Be 'fehlgeschlagen'
        $j[1].status | Should Be 'erledigt'
    }
    It 'Programm läuft noch: zählt als nicht aktualisiert, Journal fehlgeschlagen' {
        # 0x8A150101 = APPINSTALLER_CLI_ERROR_INSTALL_PACKAGE_IN_USE
        $script:ProzessHook = { param($n, $argz) if ($n -eq 1) { $script:ProzessExit = [int]0x8A150101 } else { $script:ProzessExit = 0 } }
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'winget.upgrade'; Pakete = $script:pak }
        $r.pakete[0].status | Should Be 'laeuft-noch'
        $r.status | Should Be 'fehlgeschlagen'
        $r.zusammenfassung.text | Should Match '1 von 2 Programmen erledigt, 1 nicht aktualisiert'
        $j = @(Get-TestJournal $script:dr)
        $j[0].status | Should Be 'fehlgeschlagen'
        $j[1].status | Should Be 'erledigt'
    }
    It 'OhnePunkt: kein Punktaufruf' {
        $script:PunktFehler = 'nie'
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'winget.upgrade'; Pakete = $script:pak; OhnePunkt = $true }
        $r.status | Should Be 'erledigt'
        $r.ohnePunkt | Should Be $true
        @(Get-TestJournal $script:dr)[0].ohnePunkt | Should Be $true
    }
}

Describe 'Start-MorpheusZuverlaessigkeit' {
    BeforeEach { Set-FakeWartung }
    It 'startet den Explorer mit dem festen Argument über Impl Ohne' {
        $r = Start-MorpheusZuverlaessigkeit
        $r.ok | Should Be $true
        $script:OhneAufrufe.Count | Should Be 1
        $script:OhneAufrufe[0][0] | Should Be (Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe')
        $script:OhneAufrufe[0][1] | Should Be 'shell:::{BB64F8A7-BEE7-4E1A-AB8D-7D8273F7FDB6}\pageReliabilityView'
    }
    It 'meldet einen Fehler ohne zu werfen' {
        $script:MorpheusWartungImpl.Ohne = { param($Datei, $Argumente) throw 'kaputt' }
        $r = Start-MorpheusZuverlaessigkeit
        $r.ok | Should Be $false
        $r.meldung | Should Match 'perfmon /rel'
    }
}

Describe 'Dekodierung im Runner (ohne Prozess)' {
    function New-TestStrom { param($Bytes, $Kod) $s = MorpheusWartungNeuerStrom $null $Kod; [Array]::Copy($Bytes, $s.Puffer, $Bytes.Length); $s }
    function New-TestZ { @{ Text = (New-Object System.Text.StringBuilder); KopfMax = 65536; KopfVoll = $false; Ring = (New-Object System.Collections.Queue); RingLen = 0; RingMax = 196608; Gekuerzt = $false; Zeile = $script:Sammler; HatFortschritt = $true } }
    BeforeEach { $script:gesammelt = New-Object System.Collections.ArrayList; $script:Sammler = { param($t) [void]$script:gesammelt.Add($t) } }

    It 'erkennt UTF-16LE mit BOM' {
        $b = [byte[]](@(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes("Hallo`r`nWelt`r`n"))
        $s = New-TestStrom $b 'oem'; $z = New-TestZ
        MorpheusWartungChunk $s $b.Length $z
        ($script:gesammelt -join '|') | Should Be 'Hallo|Welt'
    }
    It 'erkennt UTF-16LE ohne BOM an den Nullbytes' {
        $b = [Text.Encoding]::Unicode.GetBytes("Fortschritt 45%`r`nFertig`r`n")
        $s = New-TestStrom $b 'oem'; $z = New-TestZ
        MorpheusWartungChunk $s $b.Length $z
        ($script:gesammelt -join '|') | Should Be 'Fortschritt 45%|Fertig'
    }
    It 'utf8: Mehrbyte-Zeichen über Chunk-Grenzen und unvollständige Zeile am Ende' {
        $alle = [Text.Encoding]::UTF8.GetBytes("Grüße äöü`nNeu")
        $teil1 = $alle[0..3]    # trennt das ü in der Mitte
        $teil2 = $alle[4..($alle.Length - 1)]
        $s = New-TestStrom ([byte[]]$teil1) 'utf8'; $z = New-TestZ
        MorpheusWartungChunk $s $teil1.Length $z
        [Array]::Copy([byte[]]$teil2, $s.Puffer, $teil2.Length)
        MorpheusWartungChunk $s $teil2.Length $z
        ($script:gesammelt -join '|') | Should Be 'Grüße äöü'
        $s.Rest | Should Be 'Neu'
    }
    It 'utf8: BOM am Anfang wird entfernt, leere Zeilen werden verworfen' {
        $b = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("A`r`n`r`n`rB`n"))
        $s = New-TestStrom $b 'utf8'; $z = New-TestZ
        MorpheusWartungChunk $s $b.Length $z
        ($script:gesammelt -join '|') | Should Be 'A|B'
    }
}

Describe 'Ausgabe-Puffer (Kopf + Ende)' {
    BeforeEach { $script:gesammelt = New-Object System.Collections.ArrayList; $script:Sammler = { param($t) [void]$script:gesammelt.Add($t) } }
    function New-PufferZ { @{ Text = (New-Object System.Text.StringBuilder); KopfMax = 65536; KopfVoll = $false; Ring = (New-Object System.Collections.Queue); RingLen = 0; RingMax = 196608; Gekuerzt = $false; Zeile = $script:Sammler; HatFortschritt = $true } }

    It '600 KB Ausgabe: Schlusszeile bleibt erhalten, Text hoechstens etwa 260 KB, Kopf bleibt, Kuerzungshinweis steht dazwischen' {
        $z = New-PufferZ
        $fuell = 'x' * 98
        MorpheusWartungZeileAus $z 'ERSTE ZEILE'
        for ($i = 0; $i -lt 6000; $i++) { MorpheusWartungZeileAus $z ('Zeile {0} {1}' -f $i, $fuell) }
        MorpheusWartungZeileAus $z 'SCHLUSSZEILE: Vorgang erfolgreich abgeschlossen'
        $t = MorpheusWartungGesamttext $z
        $t.Contains('SCHLUSSZEILE: Vorgang erfolgreich abgeschlossen') | Should Be $true
        $t.StartsWith('ERSTE ZEILE') | Should Be $true
        $t.Contains('(Ausgabe gekürzt)') | Should Be $true
        $t.Length | Should BeLessThan 270000
        $script:gesammelt.Count | Should Be 6002
    }
    It 'kurze Ausgabe wird nicht gekuerzt' {
        $z = New-PufferZ
        MorpheusWartungZeileAus $z 'A'; MorpheusWartungZeileAus $z 'B'
        (MorpheusWartungGesamttext $z) | Should Be "A`nB`n"
    }
    It 'Fortschrittszeilen gehen an den Callback, aber nicht in den Text' {
        $z = New-PufferZ
        MorpheusWartungZeileAus $z 'Start'
        MorpheusWartungZeileAus $z 'Verification 45% complete.'
        MorpheusWartungZeileAus $z 'Progress: 123 of 421312 done; Stage:  29%; Total:  14%; ETA:   0:00:20'
        MorpheusWartungZeileAus $z 'Ende'
        (MorpheusWartungGesamttext $z) | Should Be "Start`nEnde`n"
        $script:gesammelt.Count | Should Be 4
    }
}
Describe 'Invoke-MorpheusWartungProzess (echte, harmlose Prozesse)' {
    BeforeEach { $script:gesammelt = New-Object System.Collections.ArrayList }

    It 'liefert Zeilen, Text und Exit-Code' {
        $r = Invoke-MorpheusWartungProzess -Datei $script:CmdExe -Argumente '/c echo eins&echo zwei&exit /b 3' -Zeile { param($t) [void]$script:gesammelt.Add($t) }
        $r.exitCode | Should Be 3
        $r.abgebrochen | Should Be $false
        $r.zeitueberschritten | Should Be $false
        ($script:gesammelt -join '|') | Should Be 'eins|zwei'
        ($r.text -split "`n" | Where-Object { $_ }) -join '|' | Should Be 'eins|zwei'
    }
    It 'liest auch stderr' {
        $r = Invoke-MorpheusWartungProzess -Datei $script:CmdExe -Argumente '/c echo aus&echo fehler 1>&2'
        $r.exitCode | Should Be 0
        $r.text | Should Match 'aus'
        $r.text | Should Match 'fehler'
    }
    It 'utf8 wird als UTF-8 gelesen' {
        $r = Invoke-MorpheusWartungProzess -Datei $script:CmdExe -Argumente '/c echo OK' -Kodierung utf8
        $r.text.Trim() | Should Be 'OK'
    }
    It 'wirft bei nicht startbarem Programm' {
        { Invoke-MorpheusWartungProzess -Datei (Join-Path $TestDrive 'gibtsnicht.exe') -Argumente '' } | Should Throw
    }
    It 'Abbruch über die Flag-Datei beendet den Prozessbaum schnell' {
        $flag = Join-Path $TestDrive 'abbruch.flag'
        Set-Content -LiteralPath $flag -Value 'x'
        $vor = Get-Date
        $r = Invoke-MorpheusWartungProzess -Datei $script:CmdExe -Argumente '/c ping -n 30 127.0.0.1' -AbbruchDatei $flag
        ((Get-Date) - $vor).TotalSeconds | Should BeLessThan 15
        $r.abgebrochen | Should Be $true
        $r.zeitueberschritten | Should Be $false
        Start-Sleep -Milliseconds 500
        @(Get-Process -Name ping -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -ge $vor.AddSeconds(-1) }).Count | Should Be 0
    }
    It 'Abbruch während des Laufs (Flag nach etwa 1 Sekunde)' {
        $flag = Join-Path $TestDrive 'abbruch2.flag'
        $vor = Get-Date
        $zeile = { param($t) if (-not (Test-Path -LiteralPath $script:flag2)) { Set-Content -LiteralPath $script:flag2 -Value 'x' } }
        $script:flag2 = $flag
        $r = Invoke-MorpheusWartungProzess -Datei $script:CmdExe -Argumente '/c ping -n 30 127.0.0.1' -AbbruchDatei $flag -Zeile $zeile
        ((Get-Date) - $vor).TotalSeconds | Should BeLessThan 15
        $r.abgebrochen | Should Be $true
        Start-Sleep -Milliseconds 500
        @(Get-Process -Name ping -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -ge $vor.AddSeconds(-1) }).Count | Should Be 0
    }
    It 'kehrt nach Prozessende zurueck, auch wenn ein Enkelprozess die Pipes offen haelt' {
        $vor = Get-Date
        $r = Invoke-MorpheusWartungProzess -Datei $script:CmdExe -Argumente '/c start "" /b ping -n 8 127.0.0.1 >nul & echo fertig' -ZeitlimitSek 30
        $dauer = ((Get-Date) - $vor).TotalSeconds
        try {
            $dauer | Should BeLessThan 5
            $r.exitCode | Should Be 0
            $r.zeitueberschritten | Should Be $false
            $r.text | Should Match 'fertig'
        } finally {
            # uebrig gebliebenen ping-Enkel (nur diesen Test) beenden
            $reste = @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'ping\s+-n\s+8\s+127\.0\.0\.1' })
            foreach ($p in $reste) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
            Start-Sleep -Milliseconds 500
            @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'ping\s+-n\s+8\s+127\.0\.0\.1' }).Count | Should Be 0
        }
    }
    It 'Zeitlimit beendet den Prozess' {
        $vor = Get-Date
        $r = Invoke-MorpheusWartungProzess -Datei $script:CmdExe -Argumente '/c ping -n 30 127.0.0.1' -ZeitlimitSek 1
        ((Get-Date) - $vor).TotalSeconds | Should BeLessThan 15
        $r.zeitueberschritten | Should Be $true
        $r.abgebrochen | Should Be $false
        Start-Sleep -Milliseconds 500
        @(Get-Process -Name ping -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -ge $vor.AddSeconds(-1) }).Count | Should Be 0
    }
}

# winget ohne Adminrechte (2.5, #67, G3): Attrappe WingetBenutzer, kein echtes winget, keine Aufgabenplanung
Describe 'Invoke-MorpheusWartung: winget ohne Adminrechte' {
    BeforeEach {
        Set-FakeWartung
        $script:dr = Join-Path $TestDrive ('d' + [guid]::NewGuid().ToString('N'))
        $script:pak = @(
            @{ id = 'Demo.App'; name = 'Demo App'; von = '1.0'; auf = '1.1' },
            [pscustomobject]@{ id = 'Other.Tool'; name = 'Other Tool'; von = '2.0'; auf = '2.5' }
        )
    }
    It 'alle Pakete laufen über WingetBenutzer, nie über den Admin-Runner; Feld benutzerkontext und Hinweis' {
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'winget.upgrade'; Pakete = $script:pak }
        $r.status | Should Be 'erledigt'
        $r.benutzerkontext | Should Be $true
        $script:Aufrufe.Count | Should Be 2
        @($script:Aufrufe | Where-Object { -not $_.Benutzer }).Count | Should Be 0
        (@($r.zusammenfassung.details) -contains 'winget lief ohne Adminrechte (Benutzerkontext).') | Should Be $true
        (@($script:Log | Where-Object { $_ -like '*winget läuft ohne Adminrechte*' })).Count | Should Be 1
        (@($script:Log | Where-Object { $_ -like '*WinGet-Ordner*' })).Count | Should Be 0
    }
    It 'kein Ergebnis aus dem Benutzerkontext: Paket fehlgeschlagen mit Grund, Journal fehlgeschlagen' {
        $script:BenutzerFehler = 'Die Aufgabe ohne Adminrechte endete, bevor winget Ausgaben geschickt hat.'
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'winget.upgrade'; Pakete = $script:pak }
        $r.status | Should Be 'fehlgeschlagen'
        $r.pakete[0].status | Should Be 'fehlgeschlagen'
        $r.pakete[0].text | Should Be $script:BenutzerFehler
        $r.pakete[0].exitCode | Should BeNullOrEmpty
        @(Get-TestJournal $script:dr)[0].status | Should Be 'fehlgeschlagen'
    }
    It 'Start wirft: Paket fehlgeschlagen, das nächste wird trotzdem versucht' {
        $script:ProzessHook = { param($n, $argz) if ($n -eq 1) { throw 'Aufgabenplanung nicht erreichbar' } }
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'winget.upgrade'; Pakete = $script:pak }
        $r.pakete[0].status | Should Be 'fehlgeschlagen'
        $r.pakete[0].text | Should Match 'Aufgabenplanung nicht erreichbar'
        $r.pakete[1].status | Should Be 'aktualisiert'
    }
    It 'Zeitlimit: Paket fehlgeschlagen' {
        $script:ProzessZeit = $true
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'winget.upgrade'; Pakete = @($script:pak[0]) }
        $r.pakete[0].status | Should Be 'fehlgeschlagen'
        $r.pakete[0].text | Should Match 'Zeitlimit'
    }
    It 'Standard-Eintrag ohne WingetBenutzer.ps1: wirft statt winget mit Adminrechten zu starten' {
        $echt = $script:WartungImplWingetBenutzerEcht
        $echt | Should Not BeNullOrEmpty
        $text = $echt.ToString()
        $text | Should Match 'Invoke-MorpheusWingetBenutzer'
        $text | Should Match 'throw'
        $text | Should Not Match 'Invoke-MorpheusWartungProzess'
    }
    It 'Punkt fehlt: nichts gestartet' {
        $script:PunktFehler = 'kein Punkt'
        $r = Invoke-Wartung @{ DataRoot = $script:dr; Werkzeug = 'winget.upgrade'; Pakete = $script:pak }
        $r.status | Should Be 'punkt-fehlt'
        $script:Aufrufe.Count | Should Be 0
    }
}

Describe 'Wartung.ps1 nutzt keine Option-(c)-Funktionen mehr' {
    It 'kein Initialize-/Test-MorpheusWingetOrdner und kein Feld wingetOrdner' {
        $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\gui\lib\Wartung.ps1'))
        $text | Should Not Match 'MorpheusWingetOrdner'
        $text | Should Not Match 'wingetOrdner'
    }
}
