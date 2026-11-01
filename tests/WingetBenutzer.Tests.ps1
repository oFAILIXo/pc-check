#Requires -Version 5.1
# Pester-3.4-Tests für gui\lib\WingetBenutzer.ps1 (2.5, #67: winget ohne Adminrechte).
# Kein echtes winget und keine Aufgabenplanung: Starten wird ersetzt. Entweder schreibt ein Hilfsprozess
# (powershell.exe -NoProfile) feste Zeilen in die Pipe, oder conhost/cmd laufen echt mit ping 127.0.0.1 bzw. findstr.
# Ausführen: Invoke-Pester tests\WingetBenutzer.Tests.ps1

. (Join-Path $PSScriptRoot '..\gui\lib\Systempfade.ps1')
. (Join-Path $PSScriptRoot '..\gui\lib\WingetBenutzer.ps1')

$script:Sys = [Environment]::SystemDirectory
$script:Ping = Join-Path $script:Sys 'PING.EXE'
$script:FindStr = Join-Path $script:Sys 'findstr.exe'
$script:PsExe = Join-Path $script:Sys 'WindowsPowerShell\v1.0\powershell.exe'
$script:ImplEcht = @{} + $script:MorpheusWingetBenutzerImpl

# Hilfsprozess: verbindet sich mit der Pipe aus den Argumenten und schreibt $script:KlientZeilen, wartet dann $script:KlientWarteMs
function Start-TestKlient {
    param([string]$Argumente)
    $pipe = [regex]::Match($Argumente, 'pipe\\(Morpheus-winget-[0-9a-f]{32})').Groups[1].Value
    $zeilen = @($script:KlientZeilen | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ','
    $code = @"
`$c = New-Object IO.Pipes.NamedPipeClientStream('.', '$pipe', [IO.Pipes.PipeDirection]::Out)
`$c.Connect(15000)
`$w = New-Object IO.StreamWriter(`$c, (New-Object Text.UTF8Encoding `$false))
`$w.AutoFlush = `$true
foreach (`$l in @($zeilen)) { `$w.WriteLine(`$l) }
Start-Sleep -Milliseconds $($script:KlientWarteMs)
`$w.Dispose()
"@
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsExe
    $psi.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [Diagnostics.Process]::Start($psi)
}

function Set-TestImpl {
    param([ValidateSet('klient', 'echt', 'nichts')][string]$Modus)
    $script:Modus = $Modus
    $script:StartAufrufe = New-Object System.Collections.ArrayList
    $script:Beendet = 0
    $script:Entfernt = 0
    $script:StartWirft = $null
    $script:MorpheusWingetBenutzerImpl = @{
        Benutzer  = $script:ImplEcht.Benutzer
        Starten   = {
            param($Programm, $Argumente, $Benutzer, $ZeitlimitSek, $Ordner)
            [void]$script:StartAufrufe.Add([pscustomobject]@{ Programm = $Programm; Argumente = $Argumente; Benutzer = $Benutzer; Ordner = $Ordner })
            if ($script:StartWirft) { throw $script:StartWirft }
            $p = $null
            if ($script:Modus -eq 'klient') { $p = Start-TestKlient -Argumente $Argumente }
            elseif ($script:Modus -eq 'echt') {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $Programm
                $psi.Arguments = $Argumente
                $psi.WorkingDirectory = $Ordner
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $p = [Diagnostics.Process]::Start($psi)
            } else {
                # startet nichts, was sich verbindet: Prozess endet sofort
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = Join-Path $script:Sys 'whoami.exe'
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.RedirectStandardOutput = $true
                $p = [Diagnostics.Process]::Start($psi)
            }
            [pscustomobject]@{ P = $p }
        }
        Laeuft    = { param($H) -not $H.P.HasExited }
        Beenden   = { param($H) $script:Beendet++; try { $H.P.Kill() } catch { } }
        Entfernen = { param($H) $script:Entfernt++ }
    }
}

Describe 'Test-MorpheusWingetBenutzerAufruf' {
    It 'nimmt einen vollen Programmpfad und winget-Argumente an' {
        Test-MorpheusWingetBenutzerAufruf -Programm $script:Ping -Argumente 'upgrade --id Demo.App --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity' | Should BeNullOrEmpty
        Test-MorpheusWingetBenutzerAufruf -Programm $script:Ping -Argumente '' | Should BeNullOrEmpty
    }
    foreach ($p in 'PING.EXE', '\PING.EXE', 'C:PING.EXE', 'C:\Windows\System32\..\System32\PING.EXE', 'C:\a"b\x.exe', 'C:\a&b\x.exe', 'C:\a%b%\x.exe', 'C:\a!b!\x.exe', 'C:\a(b)\x.exe', 'C:\x\x.cmd', 'C:\gibt\es\nicht\winget.exe') {
        It ('lehnt Programm ab: ' + $p) {
            Test-MorpheusWingetBenutzerAufruf -Programm $p -Argumente '' | Should Not BeNullOrEmpty
        }
    }
    foreach ($a in 'a & calc', 'a | b', 'a > b', 'a < b', 'a ^ b', '%PATH%', '!x!', '"x"', "a`nb", 'a/b', 'a;b', 'a(b)') {
        It ('lehnt Argumente ab: ' + ($a -replace "`n", '\n')) {
            Test-MorpheusWingetBenutzerAufruf -Programm $script:Ping -Argumente $a | Should Not BeNullOrEmpty
        }
    }
}

Describe 'Get-MorpheusWingetBenutzerBefehl' {
    $pipe = 'Morpheus-winget-' + ('0' * 32)
    It 'conhost --headless mit cmd /d /v:on /s /c, Programm aus dem Arbeitsordner, Umleitung in die Pipe und Exit-Marke' {
        $b = Get-MorpheusWingetBenutzerBefehl -WingetPfad $script:Ping -Argumente '-n 1 127.0.0.1' -Pipe $pipe
        $b.Programm | Should Be (Join-Path $script:Sys 'conhost.exe')
        $b.Argumente | Should Be ('--headless "' + (Join-Path $script:Sys 'cmd.exe') + '" /d /v:on /s /c "(.\PING.EXE -n 1 127.0.0.1 & echo MORPHEUS-EXIT:!errorlevel!) > \\.\pipe\' + $pipe + ' 2>&1"')
        $b.Ordner | Should Be $script:Sys
    }
    It 'Programmname mit Leerzeichen wird abgelehnt' {
        Test-MorpheusWingetBenutzerAufruf -Programm 'C:\Windows\System32\PING X.EXE' -Argumente '' | Should Match 'Programmname'
    }
    It 'lehnt ungültige Pipe-Namen ab' {
        { Get-MorpheusWingetBenutzerBefehl -WingetPfad $script:Ping -Pipe 'x & calc' } | Should Throw
        { Get-MorpheusWingetBenutzerBefehl -WingetPfad $script:Ping -Pipe ('Morpheus-winget-' + ('A' * 32)) } | Should Throw
    }
    It 'lehnt ungültige Argumente ab' {
        { Get-MorpheusWingetBenutzerBefehl -WingetPfad $script:Ping -Argumente 'a & b' -Pipe $pipe } | Should Throw
    }
}

Describe 'New-MorpheusWingetBenutzerPipe' {
    It 'Rechte: Administratoren und SYSTEM voll, der Benutzer ohne Rechteänderung, sonst niemand' {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $name = 'Morpheus-winget-' + [guid]::NewGuid().ToString('N')
        $s = New-MorpheusWingetBenutzerPipe -Name $name -Sid $sid
        try {
            $regeln = @($s.GetAccessControl().GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
            $regeln.Count | Should Be 3
            $erwartet = (@('S-1-5-18', 'S-1-5-32-544', $sid) | Sort-Object) -join ','
            (@($regeln | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) -join ',') | Should Be $erwartet
            $u = $regeln | Where-Object { $_.IdentityReference.Value -eq $sid }
            ($u.PipeAccessRights -band [IO.Pipes.PipeAccessRights]::ChangePermissions) | Should Be 0
            ($u.PipeAccessRights -band [IO.Pipes.PipeAccessRights]::TakeOwnership) | Should Be 0
            @($regeln | Where-Object { $_.AccessControlType -ne 'Allow' }).Count | Should Be 0
        } finally { $s.Dispose() }
    }
    It 'lehnt eine ungültige SID ab' {
        { New-MorpheusWingetBenutzerPipe -Name ('Morpheus-winget-' + [guid]::NewGuid().ToString('N')) -Sid 'S-1-5-21)(A;;FA;;;WD' } | Should Throw
    }
}

Describe 'Format-MorpheusWingetBenutzerZeile' {
    It 'entfernt ANSI-Farbcodes, Steuer-, Bidi- und unsichtbare Zeichen' {
        Format-MorpheusWingetBenutzerZeile ([string][char]27 + '[32mGrün' + [char]27 + '[0m') | Should Be 'Grün'
        Format-MorpheusWingetBenutzerZeile ('a' + [char]0x202E + 'b' + [char]0x200B + 'c' + [char]0x0085 + [char]7) | Should Be 'abc'
    }
    It 'kürzt auf 500 Zeichen' {
        (Format-MorpheusWingetBenutzerZeile ('x' * 900)).Length | Should Be 500
    }
    It '$null ergibt leeren Text' {
        Format-MorpheusWingetBenutzerZeile $null | Should Be ''
    }
}

Describe 'Invoke-MorpheusWingetBenutzer (Hilfsprozess statt Aufgabenplanung)' {
    AfterEach { $script:MorpheusWingetBenutzerImpl = @{} + $script:ImplEcht }

    It 'liest Zeilen, Exit-Marke als letzte Zeile ergibt den Exit-Code; Aufgabe wird entfernt' {
        Set-TestImpl 'klient'
        $script:KlientZeilen = @('Gefunden Demo App [Demo.App]', ([string][char]27 + '[1mInstalliert'), 'MORPHEUS-EXIT:-1978334975')
        $script:KlientWarteMs = 0
        $script:Gesehen = New-Object System.Collections.ArrayList
        $r = Invoke-MorpheusWingetBenutzer -WingetPfad $script:Ping -Argumente 'upgrade --id Demo.App' -ZeitlimitSek 60 -Zeile { param($z) [void]$script:Gesehen.Add($z) }
        $r.fehler | Should BeNullOrEmpty
        $r.exitCode | Should Be -1978334975
        $r.benutzerkontext | Should Be $true
        (@($script:Gesehen) -join '|') | Should Be 'Gefunden Demo App [Demo.App]|Installiert'
        $r.text | Should Not Match 'MORPHEUS-EXIT'
        $script:Entfernt | Should Be 1
        $script:StartAufrufe.Count | Should Be 1
        $script:StartAufrufe[0].Programm | Should Be (Join-Path $script:Sys 'conhost.exe')
        $script:StartAufrufe[0].Benutzer.Sid | Should Be ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    }
    It 'Exit-Marke nicht als letzte Zeile: kein Exit-Code, Grund gesetzt' {
        Set-TestImpl 'klient'
        $script:KlientZeilen = @('MORPHEUS-EXIT:0', 'danach noch Text')
        $script:KlientWarteMs = 0
        $r = Invoke-MorpheusWingetBenutzer -WingetPfad $script:Ping -ZeitlimitSek 60
        $r.exitCode | Should BeNullOrEmpty
        $r.fehler | Should Match 'kein Ergebnis'
    }
    It 'ohne Exit-Marke: kein Exit-Code, Grund gesetzt' {
        Set-TestImpl 'klient'
        $script:KlientZeilen = @('nur Ausgabe')
        $script:KlientWarteMs = 0
        $r = Invoke-MorpheusWingetBenutzer -WingetPfad $script:Ping -ZeitlimitSek 60
        $r.exitCode | Should BeNullOrEmpty
        $r.fehler | Should Not BeNullOrEmpty
        $r.text | Should Be 'nur Ausgabe'
    }
    It 'Zeitlimit: Prozess wird beendet, zeitueberschritten, Aufgabe entfernt' {
        Set-TestImpl 'klient'
        $script:KlientZeilen = @('läuft lange')
        $script:KlientWarteMs = 30000
        $r = Invoke-MorpheusWingetBenutzer -WingetPfad $script:Ping -ZeitlimitSek 4
        $r.zeitueberschritten | Should Be $true
        $r.exitCode | Should BeNullOrEmpty
        $script:Beendet | Should BeGreaterThan 0
        $script:Entfernt | Should Be 1
    }
    It 'Start wirft: Grund nennt die Aufgabenplanung, kein Entfernen nötig' {
        Set-TestImpl 'klient'
        $script:StartWirft = 'Zugriff verweigert'
        $r = Invoke-MorpheusWingetBenutzer -WingetPfad $script:Ping -ZeitlimitSek 60
        $r.exitCode | Should BeNullOrEmpty
        $r.fehler | Should Match 'Aufgabenplanung'
        $r.fehler | Should Match 'Zugriff verweigert'
        $script:Entfernt | Should Be 0
    }
    It 'Prozess endet ohne Verbindung: Grund gesetzt, kein Hängen' {
        Set-TestImpl 'nichts'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-MorpheusWingetBenutzer -WingetPfad $script:Ping -ZeitlimitSek 60 -VerbindungSek 30
        $sw.Elapsed.TotalSeconds | Should BeLessThan 20
        $r.exitCode | Should BeNullOrEmpty
        $r.fehler | Should Match 'endete'
        $script:Entfernt | Should Be 1
    }
    It 'ungültige Argumente: wirft, ohne etwas zu starten' {
        Set-TestImpl 'klient'
        { Invoke-MorpheusWingetBenutzer -WingetPfad $script:Ping -Argumente 'a & calc' } | Should Throw
        $script:StartAufrufe.Count | Should Be 0
    }
}

Describe 'Invoke-MorpheusWingetBenutzer (echtes conhost und cmd, harmlose Programme)' {
    AfterEach { $script:MorpheusWingetBenutzerImpl = @{} + $script:ImplEcht }

    It 'ping 127.0.0.1: Ausgabe kommt an, Exit-Code 0' {
        Set-TestImpl 'echt'
        $r = Invoke-MorpheusWingetBenutzer -WingetPfad $script:Ping -Argumente '-n 1 127.0.0.1' -ZeitlimitSek 60
        $r.fehler | Should BeNullOrEmpty
        $r.exitCode | Should Be 0
        $r.text | Should Match '127\.0\.0\.1'
    }
    It 'Programm in einem Ordner mit Leerzeichen (wie Program Files\WindowsApps): Ausgabe kommt an (Test C, 01.11.2026)' {
        Set-TestImpl 'echt'
        $ordner = Join-Path $TestDrive 'Program Files\Demo App'
        [void](New-Item -ItemType Directory -Path $ordner -Force)
        $exe = Join-Path $ordner 'PING.EXE'
        Copy-Item -LiteralPath $script:Ping -Destination $exe
        $r = Invoke-MorpheusWingetBenutzer -WingetPfad $exe -Argumente '-n 1 127.0.0.1' -ZeitlimitSek 60
        $r.fehler | Should BeNullOrEmpty
        $r.exitCode | Should Be 0
        $script:StartAufrufe[0].Ordner | Should Be $ordner
    }
    It 'findstr auf fehlende Datei: Fehlerausgabe kommt an, Exit-Code 1' {
        Set-TestImpl 'echt'
        $r = Invoke-MorpheusWingetBenutzer -WingetPfad $script:FindStr -Argumente 'xyz nichtvorhanden-morpheus.txt' -ZeitlimitSek 60
        $r.exitCode | Should Be 1
        $r.text | Should Match 'nichtvorhanden-morpheus'
    }
}

Describe 'Echte Aufgaben-Implementierung (statisch, ohne Aufgabenplanung)' {
    $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\gui\lib\WingetBenutzer.ps1'))
    It 'InteractiveToken (3) und RunLevel LUA (0), nie Highest' {
        $text | Should Match '\$def\.Principal\.LogonType = 3'
        $text | Should Match '\$def\.Principal\.RunLevel = 0'
        $text | Should Not Match 'RunLevel = 1'
    }
    It 'Rechte der Aufgabe nur für Administratoren und SYSTEM, Benutzer nur lesen' {
        $text | Should Match ([regex]::Escape("'D:P(A;;FA;;;BA)(A;;FA;;;SY)(A;;FR;;;'"))
    }
    It 'kein Rückfall auf einen Start mit Adminrechten (kein Start-Process, kein Process.Start, kein &-Aufruf von winget)' {
        $text | Should Not Match 'Start-Process'
        $text | Should Not Match 'Diagnostics\.Process\]::Start'
        $text | Should Not Match '&\s*\$WingetPfad'
    }
}
