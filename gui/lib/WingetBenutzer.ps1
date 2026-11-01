#Requires -Version 5.1
<#
.SYNOPSIS
    winget ohne Adminrechte (v2.5, #67, Befund G3/W11, Option a): Start im Benutzerkontext über eine geplante Einmal-Aufgabe.

.DESCRIPTION
    Wird per Dot-Source geladen (Winget.ps1 lädt die Datei mit). Vertrag: docs/gui-architektur.md Abschnitt 19.
    Warum: winget legt Installer in <Temp>\WinGet ab und gibt den Ordner dem Benutzer frei. Liefe winget mit Adminrechten,
    könnte ein Programm mit Benutzerrechten den Installer zwischen Hashprüfung und Start austauschen und bekäme Adminrechte.
    Ablauf je Paket:
    - Der Admin-Prozess legt eine Named Pipe an (Rechte: Administratoren und SYSTEM voll, der angemeldete Benutzer nur
      Schreiben/Verbinden) und eine geplante Einmal-Aufgabe im Stamm der Aufgabenplanung:
      Anmeldung InteractiveToken, RunLevel LUA (gefiltertes Token, ohne Adminrechte), Rechte der Aufgabe per SDDL.
    - Die Aufgabe startet conhost.exe --headless (kein Fenster) mit cmd.exe /d /v:on /s /c "(.\winget.exe … & echo MORPHEUS-EXIT:!errorlevel!) > \\.\pipe\… 2>&1".
      conhost und cmd mit vollem Pfad aus System32 (Windows-API). winget läuft als .\winget.exe im Arbeitsordner der Aufgabe,
      dem Paketordner aus Get-MorpheusWinget: conhost --headless zerlegt innere Anführungszeichen, ein Pfad mit Leerzeichen
      („Program Files“) in der Befehlszeile kam nie bei cmd an (Test C, 01.11.2026).
    - Der Admin-Prozess liest die Ausgabe zeilenweise aus der Pipe, die letzte Zeile ist die Exit-Marke. Danach wird die
      Aufgabe gelöscht. Es gibt nie einen Rückfall auf winget mit Adminrechten.
    Sicherheit des Rückkanals: Ein Programm mit Benutzerrechten kann sich mit der Pipe verbinden bzw. die eigenen Prozesse
    des Benutzers beeinflussen und damit Ausgabe und Exit-Code fälschen. Das betrifft nur die Anzeige und das Protokoll;
    der Admin-Prozess liest keine Datei aus Benutzerordnern, startet nichts aufgrund der Ausgabe und gibt nichts frei.
    Installer, die Adminrechte brauchen, fordern sie selbst über die Benutzerkontensteuerung an (Herausgeber sichtbar).
    Seiteneffekte (Benutzer, Aufgabe starten, Zustand, Beenden, Entfernen) laufen über $script:MorpheusWingetBenutzerImpl;
    Tests ersetzen Starten durch einen direkten Start ohne Aufgabenplanung.
#>

$script:WbAufgabePraefix = 'Morpheus-winget-'
$script:WbExitMarke = 'MORPHEUS-EXIT:'

#region Aufgabenplanung (privat)

# Startet die Einmal-Aufgabe. Rückgabe: Handle { Ordner, Aufgabe, Name, Sddl }
function MorpheusWingetBenutzerAufgabeStarten {
    param([string]$Programm, [string]$Argumente, $Benutzer, [int]$ZeitlimitSek, [string]$Arbeitsordner)
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $ordner = $svc.GetFolder('\')
    # Reste früherer Läufe (z. B. nach einem Absturz) entfernen, laufende Aufgaben bleiben
    foreach ($alt in @($ordner.GetTasks(1))) {
        try {
            if (([string]$alt.Name).StartsWith($script:WbAufgabePraefix, [StringComparison]::Ordinal) -and ($alt.State -ne 4)) { $ordner.DeleteTask([string]$alt.Name, 0) }
        } catch { }
    }
    $def = $svc.NewTask(0)
    $def.RegistrationInfo.Description = 'Morpheus: winget-Update ohne Adminrechte. Wird nach dem Lauf automatisch gelöscht.'
    $def.Principal.UserId = [string]$Benutzer.Name
    $def.Principal.LogonType = 3
    $def.Principal.RunLevel = 0
    $s = $def.Settings
    $s.Enabled = $true
    $s.Hidden = $true
    $s.StartWhenAvailable = $false
    $s.DisallowStartIfOnBatteries = $false
    $s.StopIfGoingOnBatteries = $false
    $s.MultipleInstances = 2
    $s.ExecutionTimeLimit = 'PT{0}M' -f ([int][math]::Ceiling(($ZeitlimitSek + 120) / 60))
    $a = $def.Actions.Create(0)
    $a.Path = $Programm
    $a.Arguments = $Argumente
    $a.WorkingDirectory = $Arbeitsordner
    $name = $script:WbAufgabePraefix + [guid]::NewGuid().ToString('N')
    # Nur Administratoren und SYSTEM dürfen die Aufgabe ändern; der Benutzer darf sie lesen.
    # Ohne Adminrechte (Entwicklungsmodus -NoElevate) lehnt Windows diese Rechte ab: dann die Standardrechte.
    $sddl = 'D:P(A;;FA;;;BA)(A;;FA;;;SY)(A;;FR;;;' + [string]$Benutzer.Sid + ')'
    $admin = $false
    try { $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
    $aufgabe = $null
    try {
        if (-not $admin) { throw 'ohne Adminrechte keine eigenen Rechte' }
        $aufgabe = $ordner.RegisterTaskDefinition($name, $def, 6, $null, $null, 3, $sddl)
    }
    catch {
        # Neuer Name: Windows kann die Aufgabe trotz Fehler angelegt haben, dann mit Rechten, die nur Administratoren erlauben
        $sddl = $null
        $name = $script:WbAufgabePraefix + [guid]::NewGuid().ToString('N')
        $aufgabe = $ordner.RegisterTaskDefinition($name, $def, 6, $null, $null, 3, $null)
    }
    try { [void]$aufgabe.Run($null) }
    catch {
        try { $ordner.DeleteTask($name, 0) } catch { }
        throw
    }
    [pscustomobject]@{ Ordner = $ordner; Aufgabe = $aufgabe; Name = $name; Sddl = $sddl }
}

# 2 = in der Warteschlange, 4 = läuft
function MorpheusWingetBenutzerAufgabeLaeuft {
    param($H)
    $st = [int]$H.Aufgabe.State
    (($st -eq 2) -or ($st -eq 4))
}

# Beendet den Prozessbaum der Aufgabe (taskkill aus System32), dann die Aufgabe selbst
function MorpheusWingetBenutzerAufgabeBeenden {
    param($H)
    try {
        $tk = Get-MorpheusSystemProgramm 'taskkill.exe'
        foreach ($inst in @($H.Aufgabe.GetInstances(0))) {
            $ep = [int]$inst.EnginePID
            if ($ep -gt 0) { $null = & $tk /PID $ep /T /F 2>&1 }
        }
    } catch { }
    try { $H.Aufgabe.Stop(0) } catch { }
}

function MorpheusWingetBenutzerAufgabeEntfernen {
    param($H)
    $H.Ordner.DeleteTask([string]$H.Name, 0)
}

#endregion

if (-not $script:MorpheusWingetBenutzerImpl) {
    $script:MorpheusWingetBenutzerImpl = @{
        # Der angemeldete Benutzer: dasselbe Konto wie der Admin-Prozess (geteiltes Token), aber ohne Adminrechte
        Benutzer  = {
            $i = [Security.Principal.WindowsIdentity]::GetCurrent()
            [pscustomobject]@{ Name = [string]$i.Name; Sid = [string]$i.User.Value }
        }
        Starten   = { param($Programm, $Argumente, $Benutzer, $ZeitlimitSek, $Ordner) MorpheusWingetBenutzerAufgabeStarten -Programm $Programm -Argumente $Argumente -Benutzer $Benutzer -ZeitlimitSek $ZeitlimitSek -Arbeitsordner $Ordner }
        Laeuft    = { param($H) MorpheusWingetBenutzerAufgabeLaeuft $H }
        Beenden   = { param($H) MorpheusWingetBenutzerAufgabeBeenden $H }
        Entfernen = { param($H) MorpheusWingetBenutzerAufgabeEntfernen $H }
    }
}

# $null = gültig, sonst deutscher Fehlertext. Nichts davon darf cmd.exe als Steuerzeichen deuten.
function Test-MorpheusWingetBenutzerAufruf {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Programm, [AllowNull()][AllowEmptyString()][string]$Argumente)
    if ([string]::IsNullOrEmpty($Programm)) { return 'Es wurde kein Programm angegeben.' }
    if ($Programm -notmatch '^[A-Za-z]:\\[^"%!^&|<>()\r\n]+\.exe\z') { return 'Der Programmpfad ist ungültig.' }
    if ($Programm -match '\\\.\.?(\\|\z)') { return 'Der Programmpfad ist ungültig.' }
    # Der Dateiname steht ohne Anführungszeichen in der Befehlszeile (.\winget.exe)
    if ([IO.Path]::GetFileName($Programm) -cnotmatch '^[A-Za-z0-9._\-]+\z') { return 'Der Programmname ist ungültig.' }
    if (-not [IO.File]::Exists($Programm)) { return "Das Programm $Programm wurde nicht gefunden." }
    if ($null -eq $Argumente) { $Argumente = '' }
    if ($Argumente -cnotmatch '^[A-Za-z0-9 ._+\-]*\z') { return 'Die Argumente enthalten unzulässige Zeichen.' }
    $null
}

# Befehlszeile für die Aufgabe: conhost --headless startet cmd ohne Fenster; cmd leitet alles in die Pipe um.
# winget wird als .\<Name> aus dem Arbeitsordner gestartet (immer der Arbeitsordner, nie PATH), ohne innere Anführungszeichen.
function Get-MorpheusWingetBenutzerBefehl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WingetPfad, [AllowEmptyString()][string]$Argumente = '', [Parameter(Mandatory)][string]$Pipe)
    $grund = Test-MorpheusWingetBenutzerAufruf -Programm $WingetPfad -Argumente $Argumente
    if ($grund) { throw $grund }
    if ($Pipe -cnotmatch '^Morpheus-winget-[0-9a-f]{32}\z') { throw 'Ungültiger Pipe-Name.' }
    $sys = [Environment]::SystemDirectory
    $aufruf = '.\' + [IO.Path]::GetFileName($WingetPfad)
    if ($Argumente) { $aufruf += ' ' + $Argumente }
    $innen = '(' + $aufruf + ' & echo ' + $script:WbExitMarke + '!errorlevel!) > \\.\pipe\' + $Pipe + ' 2>&1'
    [pscustomobject]@{
        Programm  = (Join-Path $sys 'conhost.exe')
        Argumente = ('--headless "' + (Join-Path $sys 'cmd.exe') + '" /d /v:on /s /c "' + $innen + '"')
        Ordner    = [IO.Path]::GetDirectoryName($WingetPfad)
    }
}

# Pipe nur zum Lesen (Server). Der Benutzer darf sich verbinden und schreiben, sonst niemand außer Administratoren und SYSTEM.
function New-MorpheusWingetBenutzerPipe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Sid)
    if ($Sid -cnotmatch '^S-1-[0-9]+(-[0-9]+)+\z') { throw 'Ungültige SID.' }
    $ps = New-Object IO.Pipes.PipeSecurity
    $erlaubt = [Security.AccessControl.AccessControlType]::Allow
    foreach ($s in 'S-1-5-32-544', 'S-1-5-18') {
        $ps.AddAccessRule((New-Object IO.Pipes.PipeAccessRule((New-Object Security.Principal.SecurityIdentifier $s), [IO.Pipes.PipeAccessRights]::FullControl, $erlaubt)))
    }
    # cmd öffnet die Pipe wie eine Datei mit GENERIC_WRITE; das schließt bei Pipes CreateNewInstance ein (bei höchstens einer Instanz wirkungslos)
    $recht = [IO.Pipes.PipeAccessRights]'ReadWrite, CreateNewInstance, ReadPermissions, Synchronize'
    $ps.AddAccessRule((New-Object IO.Pipes.PipeAccessRule((New-Object Security.Principal.SecurityIdentifier $Sid), $recht, $erlaubt)))
    New-Object IO.Pipes.NamedPipeServerStream($Name, [IO.Pipes.PipeDirection]::In, 1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous, 65536, 65536, $ps)
}

# Ausgabezeile ohne Steuer-, Bidi- und unsichtbare Zeichen und ohne ANSI-Farbcodes, höchstens 500 Zeichen
function Format-MorpheusWingetBenutzerZeile {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    $t = $Text -replace '\x1B\[[0-9;?]*[A-Za-z]', ''
    $t = $t -replace '[\x00-\x08\x0B-\x1F\x7F\u0085\u061C\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]', ''
    $t = $t.Trim()
    if ($t.Length -gt 500) { $t = $t.Substring(0, 499) + [string][char]0x2026 }
    $t
}

<#
.SYNOPSIS
    Führt winget ohne Adminrechte aus und liefert { exitCode, text, abgebrochen, zeitueberschritten, dauerSek, benutzerkontext, fehler }.
.DESCRIPTION
    exitCode ist $null, wenn winget kein Ergebnis gemeldet hat; fehler nennt dann den Grund. Zeile bekommt jede
    bereinigte Ausgabezeile (ohne die Exit-Marke). Wirft nur bei ungültigen Argumenten.
#>
function Invoke-MorpheusWingetBenutzer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WingetPfad,
        [AllowEmptyString()][string]$Argumente = '',
        [int]$ZeitlimitSek = 1800,
        [scriptblock]$Zeile,
        [int]$VerbindungSek = 60
    )
    $grund = Test-MorpheusWingetBenutzerAufruf -Programm $WingetPfad -Argumente $Argumente
    if ($grund) { throw $grund }
    $res = [ordered]@{ exitCode = $null; text = ''; abgebrochen = $false; zeitueberschritten = $false; dauerSek = 0; benutzerkontext = $true; fehler = $null }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $zeilen = New-Object System.Collections.Generic.List[string]
    $marke = $null
    $server = $null
    $handle = $null
    try {
        $benutzer = & $script:MorpheusWingetBenutzerImpl.Benutzer
        $pipe = $script:WbAufgabePraefix + [guid]::NewGuid().ToString('N')
        $server = New-MorpheusWingetBenutzerPipe -Name $pipe -Sid ([string]$benutzer.Sid)
        $befehl = Get-MorpheusWingetBenutzerBefehl -WingetPfad $WingetPfad -Argumente $Argumente -Pipe $pipe
        try { $handle = & $script:MorpheusWingetBenutzerImpl.Starten $befehl.Programm $befehl.Argumente $benutzer $ZeitlimitSek $befehl.Ordner }
        catch {
            $res.fehler = 'winget ließ sich nicht ohne Adminrechte starten (Aufgabenplanung): ' + $_.Exception.Message
        }

        # Auf die Verbindung warten. Endet die Aufgabe vorher, ist cmd gescheitert (z. B. Pipe belegt).
        $verbunden = $false
        if ($null -ne $handle) { $ar = $server.BeginWaitForConnection($null, $null) }
        while ($null -ne $handle) {
            if ($ar.AsyncWaitHandle.WaitOne(250)) { $server.EndWaitForConnection($ar); $verbunden = $true; break }
            if ($sw.Elapsed.TotalSeconds -ge $VerbindungSek) { $res.fehler = 'winget hat sich im Benutzerkontext nicht gemeldet.'; break }
            if (($sw.Elapsed.TotalSeconds -gt 5) -and (-not (& $script:MorpheusWingetBenutzerImpl.Laeuft $handle))) {
                $res.fehler = 'Die Aufgabe ohne Adminrechte endete, bevor winget Ausgaben geschickt hat.'
                break
            }
        }

        if ($verbunden) {
            $leser = New-Object IO.StreamReader($server, (New-Object Text.UTF8Encoding $false), $false, 4096)
            $t = $leser.ReadLineAsync()
            while ($true) {
                $fertig = $false
                try { $fertig = $t.Wait(250) } catch { break }
                if ($fertig) {
                    $roh = $t.Result
                    if ($null -eq $roh) { break }
                    $z = Format-MorpheusWingetBenutzerZeile $roh
                    if ($z -cmatch ('^' + [regex]::Escape($script:WbExitMarke) + '(-?[0-9]{1,11})\z')) {
                        $marke = [long]$Matches[1]
                    } elseif ($z) {
                        # Nur die letzte Zeile zählt als Ergebnis
                        $marke = $null
                        $zeilen.Add($z)
                        if ($zeilen.Count -gt 400) { $zeilen.RemoveAt(0) }
                        if ($Zeile) { try { [void](& $Zeile $z) } catch { } }
                    }
                    $t = $leser.ReadLineAsync()
                    continue
                }
                if (($ZeitlimitSek -gt 0) -and ($sw.Elapsed.TotalSeconds -ge $ZeitlimitSek)) {
                    $res.zeitueberschritten = $true
                    try { & $script:MorpheusWingetBenutzerImpl.Beenden $handle } catch { }
                    break
                }
            }
        }

        # Die Aufgabe endet kurz nach der Pipe; höchstens 10 s warten, dann beenden
        if (($null -ne $handle) -and (-not $res.zeitueberschritten)) {
            $ende = $sw.Elapsed.TotalSeconds + 10
            while (($sw.Elapsed.TotalSeconds -lt $ende) -and (& $script:MorpheusWingetBenutzerImpl.Laeuft $handle)) { Start-Sleep -Milliseconds 200 }
            if (& $script:MorpheusWingetBenutzerImpl.Laeuft $handle) { try { & $script:MorpheusWingetBenutzerImpl.Beenden $handle } catch { } }
        }
        if ($null -ne $marke) {
            # Werte über 32 Bit (z. B. 0x8A150006 als vorzeichenlose Zahl) bleiben erhalten; Get-MorpheusWingetErgebnis maskiert
            $res.exitCode = $marke
        } elseif ((-not $res.fehler) -and (-not $res.zeitueberschritten)) {
            $res.fehler = 'winget hat kein Ergebnis gemeldet.'
        }
    }
    catch {
        if (-not $res.fehler) { $res.fehler = 'winget ohne Adminrechte: ' + $_.Exception.Message }
    }
    finally {
        if ($null -ne $handle) {
            try { if (& $script:MorpheusWingetBenutzerImpl.Laeuft $handle) { & $script:MorpheusWingetBenutzerImpl.Beenden $handle } } catch { }
            try { & $script:MorpheusWingetBenutzerImpl.Entfernen $handle } catch { }
        }
        if ($null -ne $server) { try { $server.Dispose() } catch { } }
        $res.dauerSek = [int][math]::Round($sw.Elapsed.TotalSeconds)
        $res.text = ($zeilen -join "`n")
    }
    [pscustomobject]$res
}
