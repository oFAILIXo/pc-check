#Requires -Version 5.1
<#
.SYNOPSIS
    Aktionskatalog der pc-check-GUI (T3): Einstellungen, die auf Knopfdruck geändert und exakt zurückgenommen werden können.

.DESCRIPTION
    Die Datei gibt ein Array von Hashtables zurück (Schema: docs\gui-architektur.md, Abschnitt 8).
    Der Katalog wird per `& $file` geladen. Die Scriptblöcke laufen später in einem anderen
    Scope bzw. Prozess (Start-Job) und sind deshalb vollständig in sich geschlossen: keine Hilfsfunktionen
    und keine Variablen auf Dateiebene, gemeinsame Teile stehen bewusst in jedem Block.

    Regeln für alle Aktionen:
    - Lesen ändert nichts und liefert { Aktiv; Wert; Zustand }. Zustand reicht zum exakten Wiederherstellen.
    - Registry: Ein Wert, der vorher nicht existierte, steht als $null im Zustand; Rückgängig löscht ihn dann.
      Legt Ausführen einen Schlüssel neu an, merkt sich der Zustand das (SchluesselVorhanden = $false), und
      Rückgängig entfernt nur diesen eigenen, leeren Schlüssel. Der Datentyp bleibt erhalten.
    - Ausfuehren und Rueckgaengig sind idempotent, mit -ErrorAction Stop und ohne Ausgabe auf der Pipeline.
    - HKCU-Aktionen prüfen in Voraussetzung, dass der Prozess unter dem angemeldeten Benutzer läuft.
#>

@(
    #region Sicherheit: Defender

    @{
        Id          = 'defender.netzwerkschutz'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Microsoft Defender: Einstellungen'
        Titel       = 'Netzwerkschutz einschalten'
        Erklaerung  = 'Blockiert in allen Programmen Verbindungen zu bekannten Phishing- und Schadsoftware-Servern. Im Alltag merkst du nichts, höchstens wird eine unseriöse Webseite gesperrt.'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = 'Set-MpPreference -EnableNetworkProtection Enabled'
            Rueckgaengig = 'Set-MpPreference -EnableNetworkProtection <vorher>   # Disabled, Enabled oder AuditMode, je nach altem Wert'
            Erklaerung   = @(
                'Set-MpPreference ändert eine Einstellung von Microsoft Defender.',
                '-EnableNetworkProtection Enabled schaltet den Netzwerkschutz scharf (AuditMode würde nur protokollieren, Disabled ist aus).',
                'Beim Rückgängigmachen wird der alte Wert (aus, an oder nur protokollieren) wieder gesetzt.'
            )
        }
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return 'Administratorrechte fehlen.' }
            try { $s = Get-MpComputerStatus -ErrorAction Stop } catch { return 'Microsoft Defender ist nicht abrufbar: ' + $_.Exception.Message }
            if ($s.AMRunningMode -and $s.AMRunningMode -ne 'Normal') { return "Defender läuft im Modus '$($s.AMRunningMode)'; vermutlich ist ein Virenschutz eines anderen Anbieters aktiv." }
            if (-not $s.AntivirusEnabled) { return 'Der Defender-Virenschutz ist aus; vermutlich ist ein Virenschutz eines anderen Anbieters aktiv.' }
        }
        Lesen = {
            try { $v = [int](Get-MpPreference -ErrorAction Stop).EnableNetworkProtection }
            catch { return [pscustomobject]@{ Aktiv = $false; Wert = 'Defender nicht lesbar: ' + $_.Exception.Message; Zustand = $null } }
            $namen = @{ 0 = 'aus'; 1 = 'an'; 2 = 'nur protokollieren' }
            [pscustomobject]@{ Aktiv = ($v -eq 1); Wert = [string]$namen[$v]; Zustand = $v }
        }
        Ausfuehren = {
            param($Variante)
            Set-MpPreference -EnableNetworkProtection Enabled -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            $namen = @{ 0 = 'Disabled'; 1 = 'Enabled'; 2 = 'AuditMode' }
            $modus = $namen[[int]$Vorher]
            if (-not $modus) { throw "Unbekannter Netzwerkschutz-Wert '$Vorher'." }
            Set-MpPreference -EnableNetworkProtection $modus -ErrorAction Stop | Out-Null
        }
    },

    @{
        Id          = 'defender.pua'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Microsoft Defender: Einstellungen'
        Titel       = 'Schutz vor unerwünschten Apps (PUA) einschalten'
        Erklaerung  = 'Defender blockiert dann Adware, Zusatzsoftware in Installern und ähnliche unerwünschte Programme. Selten wird dabei auch ein harmloses Hilfsprogramm gesperrt.'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = 'Set-MpPreference -PUAProtection Enabled'
            Rueckgaengig = 'Set-MpPreference -PUAProtection <vorher>   # Disabled, Enabled oder AuditMode, je nach altem Wert'
            Erklaerung   = @(
                'Set-MpPreference ändert eine Einstellung von Microsoft Defender.',
                '-PUAProtection Enabled blockiert potenziell unerwünschte Anwendungen (AuditMode würde nur melden, Disabled ist aus).',
                'Beim Rückgängigmachen wird der alte Wert wieder gesetzt.'
            )
        }
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return 'Administratorrechte fehlen.' }
            try { $s = Get-MpComputerStatus -ErrorAction Stop } catch { return 'Microsoft Defender ist nicht abrufbar: ' + $_.Exception.Message }
            if ($s.AMRunningMode -and $s.AMRunningMode -ne 'Normal') { return "Defender läuft im Modus '$($s.AMRunningMode)'; vermutlich ist ein Virenschutz eines anderen Anbieters aktiv." }
            if (-not $s.AntivirusEnabled) { return 'Der Defender-Virenschutz ist aus; vermutlich ist ein Virenschutz eines anderen Anbieters aktiv.' }
        }
        Lesen = {
            try { $v = [int](Get-MpPreference -ErrorAction Stop).PUAProtection }
            catch { return [pscustomobject]@{ Aktiv = $false; Wert = 'Defender nicht lesbar: ' + $_.Exception.Message; Zustand = $null } }
            $namen = @{ 0 = 'aus'; 1 = 'an (blockieren)'; 2 = 'nur protokollieren' }
            [pscustomobject]@{ Aktiv = ($v -eq 1); Wert = [string]$namen[$v]; Zustand = $v }
        }
        Ausfuehren = {
            param($Variante)
            Set-MpPreference -PUAProtection Enabled -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            $namen = @{ 0 = 'Disabled'; 1 = 'Enabled'; 2 = 'AuditMode' }
            $modus = $namen[[int]$Vorher]
            if (-not $modus) { throw "Unbekannter PUA-Wert '$Vorher'." }
            Set-MpPreference -PUAProtection $modus -ErrorAction Stop | Out-Null
        }
    },

    @{
        Id          = 'defender.asr-basis'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Microsoft Defender: Einstellungen'
        Titel       = 'Zwei Angriffsflächen-Regeln (Treiber-Missbrauch, LSASS) aktivieren'
        Erklaerung  = 'Verhindert, dass Schadsoftware bekannte anfällige Treiber missbraucht oder Anmeldedaten aus dem LSASS-Prozess stiehlt. Sehr alte Hersteller-Treiber (z. B. mancher Übertaktungs-Tools) können dadurch gesperrt werden; "Nur protokollieren" ist zum Testen ohne Sperre.'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'mittel'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = @('Blockieren', 'Nur protokollieren')
        Befehle     = @{
            Ausfuehren   = "Add-MpPreference -AttackSurfaceReductionRules_Ids '56a863a9-875e-4185-98a7-b882c64b5ce5' -AttackSurfaceReductionRules_Actions <variante>`nAdd-MpPreference -AttackSurfaceReductionRules_Ids '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2' -AttackSurfaceReductionRules_Actions <variante>   # <variante>: Blockieren = Enabled, Nur protokollieren = AuditMode; nur für Regeln, die noch nicht auf Blockieren/Protokollieren stehen"
            Rueckgaengig = "Add-MpPreference -AttackSurfaceReductionRules_Ids <regel> -AttackSurfaceReductionRules_Actions <alter Modus>   # war die Regel vorher gesetzt`nRemove-MpPreference -AttackSurfaceReductionRules_Ids <regel>   # war die Regel vorher nicht gesetzt"
            Erklaerung   = @(
                'Add-MpPreference fügt eine Regel zur Verringerung der Angriffsfläche (ASR) hinzu bzw. ändert ihren Modus.',
                '56a863a9-… = Missbrauch anfälliger signierter Treiber blockieren; 9e6c4e1f-… = Diebstahl von Anmeldedaten aus LSASS blockieren.',
                '-AttackSurfaceReductionRules_Actions: Enabled = blockieren, AuditMode = nur protokollieren.',
                'Remove-MpPreference entfernt eine Regel wieder; so ist sie danach genau so "nicht gesetzt" wie vorher.'
            )
        }
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return 'Administratorrechte fehlen.' }
            try { $s = Get-MpComputerStatus -ErrorAction Stop } catch { return 'Microsoft Defender ist nicht abrufbar: ' + $_.Exception.Message }
            if ($s.AMRunningMode -and $s.AMRunningMode -ne 'Normal') { return "Defender läuft im Modus '$($s.AMRunningMode)'; vermutlich ist ein Virenschutz eines anderen Anbieters aktiv." }
            if (-not $s.AntivirusEnabled) { return 'Der Defender-Virenschutz ist aus; vermutlich ist ein Virenschutz eines anderen Anbieters aktiv.' }
            if (-not $s.RealTimeProtectionEnabled) { return 'Der Echtzeitschutz ist aus; die Regeln wirken nur bei eingeschaltetem Echtzeitschutz.' }
        }
        Lesen = {
            $regelIds = @('56a863a9-875e-4185-98a7-b882c64b5ce5', '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2')
            $kurz = @('Treiber-Missbrauch', 'LSASS-Schutz')
            try { $p = Get-MpPreference -ErrorAction Stop }
            catch { return [pscustomobject]@{ Aktiv = $false; Wert = 'Defender nicht lesbar: ' + $_.Exception.Message; Zustand = $null } }
            $vid = @($p.AttackSurfaceReductionRules_Ids | ForEach-Object { ([string]$_).ToLower() })
            $vac = @($p.AttackSurfaceReductionRules_Actions)
            $namen = @{ 0 = 'aus'; 1 = 'Blockieren'; 2 = 'Nur protokollieren'; 5 = 'nicht konfiguriert'; 6 = 'Warnen' }
            $regeln = @(for ($i = 0; $i -lt $regelIds.Count; $i++) {
                    $idx = [array]::IndexOf($vid, $regelIds[$i])
                    $akt = $null
                    if ($idx -ge 0 -and $idx -lt $vac.Count) { $akt = [int]$vac[$idx] }
                    [ordered]@{ Id = $regelIds[$i]; Aktion = $akt }
                })
            $aktiv = $true
            $texte = @()
            for ($i = 0; $i -lt $regeln.Count; $i++) {
                $a = $regeln[$i].Aktion
                if ($a -ne 1 -and $a -ne 2) { $aktiv = $false }
                if ($null -eq $a) { $t = 'nicht gesetzt' } else { $t = [string]$namen[$a]; if (-not $t) { $t = "Wert $a" } }
                $texte += ('{0}: {1}' -f $kurz[$i], $t)
            }
            [pscustomobject]@{ Aktiv = $aktiv; Wert = ($texte -join '; '); Zustand = [ordered]@{ Regeln = $regeln } }
        }
        Ausfuehren = {
            param($Variante)
            $modus = switch ($Variante) {
                'Blockieren' { 'Enabled' }
                'Nur protokollieren' { 'AuditMode' }
                default { throw "Ungültige Variante '$Variante'." }
            }
            $regelIds = @('56a863a9-875e-4185-98a7-b882c64b5ce5', '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2')
            $p = Get-MpPreference -ErrorAction Stop
            $vid = @($p.AttackSurfaceReductionRules_Ids | ForEach-Object { ([string]$_).ToLower() })
            $vac = @($p.AttackSurfaceReductionRules_Actions)
            foreach ($id in $regelIds) {
                $idx = [array]::IndexOf($vid, $id)
                # Eine Regel, die schon blockiert oder protokolliert, bleibt unverändert (kein Herabstufen)
                if ($idx -ge 0 -and $idx -lt $vac.Count -and ([int]$vac[$idx] -eq 1 -or [int]$vac[$idx] -eq 2)) { continue }
                Add-MpPreference -AttackSurfaceReductionRules_Ids $id -AttackSurfaceReductionRules_Actions $modus -ErrorAction Stop | Out-Null
            }
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            $namen = @{ 0 = 'Disabled'; 1 = 'Enabled'; 2 = 'AuditMode'; 5 = 'NotConfigured'; 6 = 'Warn' }
            foreach ($r in @($Vorher.Regeln)) {
                $id = ([string]$r.Id).ToLower()
                $p = Get-MpPreference -ErrorAction Stop
                $vid = @($p.AttackSurfaceReductionRules_Ids | ForEach-Object { ([string]$_).ToLower() })
                $vac = @($p.AttackSurfaceReductionRules_Actions)
                $idx = [array]::IndexOf($vid, $id)
                if ($null -eq $r.Aktion) {
                    # Regel war vorher nicht gesetzt: wieder entfernen
                    if ($idx -ge 0) { Remove-MpPreference -AttackSurfaceReductionRules_Ids $id -ErrorAction Stop | Out-Null }
                    continue
                }
                $modus = $namen[[int]$r.Aktion]
                if (-not $modus) { throw "Unbekannter ASR-Modus '$($r.Aktion)'." }
                if ($idx -ge 0 -and $idx -lt $vac.Count -and [int]$vac[$idx] -eq [int]$r.Aktion) { continue }
                Add-MpPreference -AttackSurfaceReductionRules_Ids $id -AttackSurfaceReductionRules_Actions $modus -ErrorAction Stop | Out-Null
            }
        }
    },

    #endregion

    #region Sicherheit: Fernzugriff und Netzwerk

    @{
        Id          = 'fernzugriff.remoteunterstuetzung'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Remotedesktop'
        Titel       = 'Remoteunterstützung ausschalten'
        Erklaerung  = 'Niemand kann sich mehr per "Remoteunterstützung" (Einladung zur Fernhilfe) auf deinen PC verbinden. Das merkst du nur, wenn du diese Funktion bewusst nutzt.'
        Nutzen      = 'gering'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = "New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' -Name 'fAllowToGetHelp' -PropertyType DWord -Value 0 -Force"
            Rueckgaengig = "New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' -Name 'fAllowToGetHelp' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path '…' -Name 'fAllowToGetHelp'"
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force).',
                'fAllowToGetHelp ist die Einstellung "Remoteunterstützungsverbindungen mit diesem Computer zulassen"; 0 = nicht zulassen, 1 = zulassen.',
                '-PropertyType DWord ist der Registry-Datentyp (32-Bit-Zahl).',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht den Wert, wenn er vorher nicht existierte.'
            )
        }
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return 'Administratorrechte fehlen.' }
            $pol = $null
            try { $pol = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fAllowToGetHelp' -ErrorAction Stop).fAllowToGetHelp } catch { }
            if ($null -ne $pol) { return 'Eine Gruppenrichtlinie legt die Remoteunterstützung fest; die Einstellung hier hätte keine Wirkung.' }
        }
        Lesen = {
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'; $name = 'fAllowToGetHelp'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            $pol = $null
            try { $pol = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name $name -ErrorAction Stop).$name } catch { }
            $wirksam = $wert
            if ($null -ne $pol) { $wirksam = $pol }
            if ($wirksam -eq 0) { $text = 'nicht erlaubt' } elseif ($null -eq $wirksam) { $text = 'nicht gesetzt (Windows-Standard: erlaubt)' } else { $text = 'erlaubt' }
            if ($null -ne $pol) { $text += ' (per Richtlinie)' }
            [pscustomobject]@{ Aktiv = ($wirksam -eq 0); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'; $name = 'fAllowToGetHelp'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'; $name = 'fAllowToGetHelp'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    @{
        Id          = 'fernzugriff.rdp'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Remotedesktop'
        Titel       = 'Remotedesktop (RDP) ausschalten'
        Erklaerung  = 'Niemand kann sich mehr per Remotedesktop auf diesen PC verbinden; das schließt eine häufig angegriffene Tür. Wenn du den PC von unterwegs oder von einem anderen Rechner per RDP bedienst, funktioniert das danach nicht mehr.'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'mittel'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = "New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -PropertyType DWord -Value 1 -Force"
            Rueckgaengig = "New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path '…' -Name 'fDenyTSConnections'"
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force).',
                'fDenyTSConnections ist der Schalter hinter "Remotedesktop" in den Einstellungen; 1 = Verbindungen verweigern, 0 = erlauben.',
                '-PropertyType DWord ist der Registry-Datentyp (32-Bit-Zahl).',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht den Wert, wenn er vorher nicht existierte.'
            )
        }
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return 'Administratorrechte fehlen.' }
            $pol = $null
            try { $pol = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fDenyTSConnections' -ErrorAction Stop).fDenyTSConnections } catch { }
            if ($null -ne $pol) { return 'Eine Gruppenrichtlinie legt den Remotedesktop fest; die Einstellung hier hätte keine Wirkung.' }
        }
        Lesen = {
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'; $name = 'fDenyTSConnections'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            $pol = $null
            try { $pol = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name $name -ErrorAction Stop).$name } catch { }
            $wirksam = $wert
            if ($null -ne $pol) { $wirksam = $pol }
            if ($wirksam -eq 1) { $text = 'aus' } elseif ($null -eq $wirksam) { $text = 'nicht gesetzt' } else { $text = 'an' }
            if ($null -ne $pol) { $text += ' (per Richtlinie)' }
            [pscustomobject]@{ Aktiv = ($wirksam -eq 1); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'; $name = 'fDenyTSConnections'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'; $name = 'fDenyTSConnections'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    @{
        Id          = 'netz.llmnr'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'LLMNR / NetBIOS'
        Titel       = 'LLMNR (Namensauflösung per Rundruf) ausschalten'
        Erklaerung  = 'LLMNR ist ein altes Verfahren, mit dem Rechner im Netz Namen per Rundruf auflösen; in fremden Netzen lassen sich darüber Anmelde-Hashes abgreifen. Im Heimnetz merkst du nichts, höchstens werden Geräte ohne eigenen DNS-Eintrag nicht mehr über ihren Namen gefunden.'
        Nutzen      = 'gering'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = "New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Force   # nur falls der Schlüssel fehlt`nNew-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name 'EnableMulticast' -PropertyType DWord -Value 0 -Force"
            Rueckgaengig = "New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name 'EnableMulticast' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path '…' -Name 'EnableMulticast'; hat Ausführen den Schlüssel neu angelegt, wird der leere Schlüssel mit Remove-Item entfernt"
            Erklaerung   = @(
                'New-Item legt den Richtlinien-Schlüssel an, falls er noch nicht existiert.',
                'New-ItemProperty setzt den Wert EnableMulticast in der Richtlinie "Multicastnamensauflösung deaktivieren" des DNS-Clients; 0 = LLMNR aus.',
                '-PropertyType DWord ist der Registry-Datentyp (32-Bit-Zahl).',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht Wert und (nur den selbst angelegten, leeren) Schlüssel.'
            )
        }
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return 'Administratorrechte fehlen.' }
        }
        Lesen = {
            $pfad = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'; $name = 'EnableMulticast'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            if ($wert -eq 0) { $text = 'aus (Richtlinie)' } elseif ($null -eq $wert) { $text = 'an (Standard)' } else { $text = 'an (Richtlinie)' }
            [pscustomobject]@{ Aktiv = ($wert -eq 0); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'; $name = 'EnableMulticast'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            $pfad = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'; $name = 'EnableMulticast'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    #endregion

    #region System und Härtung

    @{
        Id          = 'system.wiederherstellung'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Wiederherstellung'
        Titel       = 'Computerschutz (Wiederherstellungspunkte) auf dem Systemlaufwerk einschalten'
        Erklaerung  = 'Schaltet die Systemwiederherstellung ein, damit vor Änderungen Wiederherstellungspunkte angelegt werden können; diese Aktion selbst legt noch keinen Punkt an. ACHTUNG: Das Rückgängigmachen (Ausschalten) löscht ALLE vorhandenen Wiederherstellungspunkte des Laufwerks unwiderruflich.'
        Nutzen      = 'hoch'
        Aufwand     = 'gering'
        Risiko      = 'mittel'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        OhneWiederherstellungspunkt = $true
        Befehle     = @{
            Ausfuehren   = "Enable-ComputerRestore -Drive `"`$env:SystemDrive\`""
            Rueckgaengig = "Disable-ComputerRestore -Drive `"`$env:SystemDrive\`"   # ACHTUNG: löscht alle Wiederherstellungspunkte dieses Laufwerks"
            Erklaerung   = @(
                'Enable-ComputerRestore schaltet den Computerschutz (Systemwiederherstellung) für das angegebene Laufwerk ein.',
                '$env:SystemDrive ist das Systemlaufwerk (meist C:); der Backslash macht daraus den Laufwerksstamm (C:\).',
                'Disable-ComputerRestore schaltet den Schutz wieder aus und löscht dabei alle vorhandenen Wiederherstellungspunkte dieses Laufwerks; sie lassen sich nicht zurückholen.'
            )
        }
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return 'Administratorrechte fehlen.' }
            $dis = $null
            try { $dis = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name 'DisableSR' -ErrorAction Stop).DisableSR } catch { }
            if ($dis -eq 1) { return 'Der Computerschutz ist per Gruppenrichtlinie abgeschaltet (DisableSR = 1).' }
        }
        Lesen = {
            $laufwerk = ([IO.Path]::GetPathRoot([Environment]::SystemDirectory).TrimEnd('\'))
            if (-not $laufwerk) { $laufwerk = 'C:' }
            $intervall = $null; $dis = $null
            try { $intervall = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'RPSessionInterval' -ErrorAction Stop).RPSessionInterval } catch { }
            try { $dis = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name 'DisableSR' -ErrorAction Stop).DisableSR } catch { }
            $an = (($intervall -eq 1) -and ($dis -ne 1))
            if ($an) { $text = "an für $laufwerk" } elseif ($dis -eq 1) { $text = 'aus (per Richtlinie)' } else { $text = "aus für $laufwerk" }
            [pscustomobject]@{ Aktiv = $an; Wert = $text; Zustand = [ordered]@{ Eingeschaltet = $an; Laufwerk = ($laufwerk + '\') } }
        }
        Ausfuehren = {
            param($Variante)
            $laufwerk = ([IO.Path]::GetPathRoot([Environment]::SystemDirectory).TrimEnd('\'))
            if (-not $laufwerk) { $laufwerk = 'C:' }
            Enable-ComputerRestore -Drive ($laufwerk + '\') -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            # War der Schutz schon vorher an, gab es nichts zurückzunehmen; ausgeschaltet wird nur, was diese Aktion eingeschaltet hat
            if ($Vorher.Eingeschaltet -eq $true) { return }
            $laufwerk = [string]$Vorher.Laufwerk
            if (-not $laufwerk) { $laufwerk = ([IO.Path]::GetPathRoot([Environment]::SystemDirectory).TrimEnd('\')) + '\' }
            Disable-ComputerRestore -Drive $laufwerk -ErrorAction Stop | Out-Null
        }
    },

    @{
        Id          = 'system.wiederherstellung-speicher'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Wiederherstellung'
        Titel       = 'Speicher für Wiederherstellungspunkte auf 10 % vergrößern'
        Erklaerung  = 'Ist der Speicher für Wiederherstellungspunkte zu klein, löscht Windows ältere Punkte, sobald ein neuer entsteht – oft schon nach Stunden. Mit 10 % des Systemlaufwerks bleiben mehrere Punkte erhalten. Belegt wird der Platz erst, wenn Punkte entstehen.'
        Nutzen      = 'hoch'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = "vssadmin resize shadowstorage /for=`$env:SystemDrive /on=`$env:SystemDrive /maxsize=10%"
            Rueckgaengig = "vssadmin resize shadowstorage /for=`$env:SystemDrive /on=`$env:SystemDrive /maxsize=<alter Wert in MB bzw. UNBOUNDED>   # ist der alte Wert kleiner, löscht Windows dabei ältere Punkte"
            Erklaerung   = @(
                'vssadmin resize shadowstorage ändert, wie viel Platz Schattenkopien (daraus bestehen Wiederherstellungspunkte) auf dem Laufwerk belegen dürfen.',
                '/for und /on: das Systemlaufwerk (meist C:); /maxsize=10% erlaubt bis zu 10 % der Laufwerksgröße.',
                'Rückgängig setzt die alte Grenze wieder. Ist sie kleiner als der belegte Platz, löscht Windows dabei die ältesten Punkte.',
                'Ist „Point-in-time restore“ von Windows 11 aktiv, setzt Windows die Grenze bei jedem Start auf dessen Einstellung zurück (Standard 2 %). Dann ändert Morpheus nichts und nennt den Weg über die Einstellungen.'
            )
        }
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return 'Administratorrechte fehlen.' }
            # Point-in-time restore (Windows 11, seit 26100/26200.8737): „The maximum VSS limit equals the maximum usage
            # configuration for point-in-time restore“ (learn.microsoft.com/windows/configuration/point-in-time-restore).
            # Lokal nur über die Einstellungen oder MDM (Recovery-CSP) änderbar; vssadmin hielte nur bis zum nächsten Start.
            $pitr = $null
            try { $pitr = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Setup\' -TaskName 'PITRTask' -ErrorAction Stop } catch { }
            if ($pitr -and ([string]$pitr.State -ne 'Disabled')) {
                return 'Windows verwaltet die Grenze über „Point-in-time restore“ und setzt sie bei jedem Start zurück. Bitte selbst einstellen: Einstellungen > System > Wiederherstellung > Point-in-time restore > Anzeigen oder bearbeiten, Regler auf etwa 10 %. Ist Point-in-time restore dort aus: sysdm.cpl > Computerschutz > Konfigurieren > Max. Belegung.'
            }
            $iv = $null; $dis = $null
            try { $iv = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'RPSessionInterval' -ErrorAction Stop).RPSessionInterval } catch { }
            try { $dis = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name 'DisableSR' -ErrorAction Stop).DisableSR } catch { }
            if (($iv -ne 1) -or ($dis -eq 1)) { return 'Der Computerschutz ist aus; zuerst „Computerschutz einschalten“ ausführen.' }
        }
        Lesen = {
            $lw = ([IO.Path]::GetPathRoot([Environment]::SystemDirectory).TrimEnd('\'))
            if (-not $lw) { $lw = 'C:' }
            try {
                $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter='$lw'" -ErrorAction Stop
                $ss = @(Get-CimInstance Win32_ShadowStorage -ErrorAction Stop | Where-Object { $_.Volume.DeviceID -eq $vol.DeviceID }) | Select-Object -First 1
            }
            catch { return [pscustomobject]@{ Aktiv = $false; Wert = 'nur mit Administratorrechten lesbar'; Zustand = [ordered]@{ Laufwerk = $lw; Max = $null } } }
            if (-not $ss) { return [pscustomobject]@{ Aktiv = $false; Wert = "für $lw noch kein Speicher eingerichtet"; Zustand = [ordered]@{ Laufwerk = $lw; Max = $null } } }
            $max = [uint64]$ss.MaxSpace
            if ($max -eq [uint64]::MaxValue) {
                return [pscustomobject]@{ Aktiv = $true; Wert = 'unbegrenzt'; Zustand = [ordered]@{ Laufwerk = $lw; Max = 'UNBOUNDED' } }
            }
            $pct = [Math]::Round(100 * [double]$max / [double]$vol.Capacity, 1)
            $wert = 'max {0:N1} GB ({1} %)' -f ([double]$max / 1GB), $pct
            $pitr = $null
            try { $pitr = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Setup\' -TaskName 'PITRTask' -ErrorAction Stop } catch { }
            if ($pitr -and ([string]$pitr.State -ne 'Disabled')) { $wert += ', verwaltet von Point-in-time restore (Einstellungen > System > Wiederherstellung)' }
            # Ziel erreicht ab 8 % (die Aktion setzt 10 %). Der Zustand zählt in ganzen MB: Windows speichert die Grenze
            # gerundet, bytegenau würde die Kontrolle nach dem Rückgängigmachen fälschlich abweichen.
            [pscustomobject]@{ Aktiv = ($pct -ge 8); Wert = $wert; Zustand = [ordered]@{ Laufwerk = $lw; Max = ('{0}MB' -f [Math]::Floor([double]$max / 1MB)) } }
        }
        Ausfuehren = {
            param($Variante)
            $lw = ([IO.Path]::GetPathRoot([Environment]::SystemDirectory).TrimEnd('\'))
            if (-not $lw) { $lw = 'C:' }
            $out = & (Join-Path ([Environment]::SystemDirectory) 'vssadmin.exe') resize shadowstorage "/for=$lw" "/on=$lw" '/maxsize=10%' 2>&1
            if ($LASTEXITCODE -ne 0) { throw ("vssadmin endete mit Code $($LASTEXITCODE): " + (($out | Out-String).Trim())) }
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            if ($null -eq $Vorher.Max) { throw 'Vorher war kein Speicher eingerichtet; eine Zuordnung lässt sich auf Windows-Desktops nicht entfernen. Bitte die Grenze unter sysdm.cpl > Computerschutz selbst einstellen.' }
            $lw = [string]$Vorher.Laufwerk
            if ($lw -notmatch '^[A-Za-z]:$') { throw "Ungültiges Laufwerk '$lw' im Vorher-Zustand." }
            $max = [string]$Vorher.Max
            if ($max -ne 'UNBOUNDED') {
                if ($max -notmatch '^(\d{1,12})MB$') { throw "Ungültige Speichergrenze '$max' im Vorher-Zustand." }
                if ([int64]$Matches[1] -lt 320) { $max = '320MB' }   # vssadmin verlangt mindestens 320 MB
            }
            $out = & (Join-Path ([Environment]::SystemDirectory) 'vssadmin.exe') resize shadowstorage "/for=$lw" "/on=$lw" "/maxsize=$max" 2>&1
            if ($LASTEXITCODE -ne 0) { throw ("vssadmin endete mit Code $($LASTEXITCODE): " + (($out | Out-String).Trim())) }
        }
    },

    @{
        Id          = 'system.schnellstart'
        Kategorie   = 'Leistung'
        Pruefung    = 'Schnellstart und Ruhezustand'
        Titel       = 'Schnellstart ausschalten'
        Erklaerung  = '"Herunterfahren" fährt Windows dann wirklich komplett herunter, sodass Treiber-, Update- und BIOS-Änderungen sicher greifen. Der Start dauert mit einer NVMe-SSD kaum merklich länger; der Ruhezustand bleibt unberührt.'
        Nutzen      = 'gering'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = "New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -PropertyType DWord -Value 0 -Force"
            Rueckgaengig = "New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path '…' -Name 'HiberbootEnabled'"
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force).',
                'HiberbootEnabled ist der Schalter "Schnellstart aktivieren" aus den Energieoptionen; 0 = aus, 1 = an. Die Hibernate-Datei und der Ruhezustand bleiben unverändert (bewusst kein "powercfg /hibernate off").',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht den Wert, wenn er vorher nicht existierte.'
            )
        }
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return 'Administratorrechte fehlen.' }
            $pol = $null
            try { $pol = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'HiberbootEnabled' -ErrorAction Stop).HiberbootEnabled } catch { }
            if ($null -ne $pol) { return 'Eine Gruppenrichtlinie legt den Schnellstart fest; die Einstellung hier hätte keine Wirkung.' }
        }
        Lesen = {
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; $name = 'HiberbootEnabled'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            # Wie in der Prüfung: alles außer 1 gilt als "aus"
            if ($wert -eq 1) { $text = 'an' } elseif ($null -eq $wert) { $text = 'aus (Wert nicht gesetzt)' } else { $text = 'aus' }
            [pscustomobject]@{ Aktiv = ($wert -ne 1); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; $name = 'HiberbootEnabled'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; $name = 'HiberbootEnabled'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    @{
        Id          = 'haertung.lsa'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'LSA-Schutz'
        Titel       = 'LSA-Schutz einschalten (ohne UEFI-Sperre)'
        Erklaerung  = 'Schützt den Windows-Prozess, der Anmeldedaten verwaltet, vor dem Auslesen durch Schadsoftware. Wirkt erst nach einem Neustart; sehr selten verweigern ältere Anmelde-Zusatzprogramme danach den Dienst. Es wird bewusst die Variante ohne UEFI-Sperre (Wert 2) gesetzt, damit sie sich jederzeit wieder ausschalten lässt.'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'mittel'
        Neustart    = $true
        Bereich     = 'System'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = "New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -PropertyType DWord -Value 2 -Force"
            Rueckgaengig = "New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path '…' -Name 'RunAsPPL'"
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force).',
                'RunAsPPL steuert, ob die lokale Sicherheitsautorität (lsass.exe) als geschützter Prozess startet. 2 = an ohne UEFI-Sperre (rücknehmbar), 1 = an mit UEFI-Sperre (würde sich nicht per Registry zurücknehmen lassen und wird deshalb nicht verwendet).',
                'Die Änderung wirkt erst nach einem Neustart.',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht den Wert, wenn er vorher nicht existierte (ebenfalls erst nach Neustart wirksam).'
            )
        }
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return 'Administratorrechte fehlen.' }
            if ([Environment]::OSVersion.Version.Build -lt 22621) { return 'Der rücknehmbare LSA-Schutz (RunAsPPL = 2) braucht Windows 11 22H2 oder neuer.' }
        }
        Lesen = {
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; $name = 'RunAsPPL'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            if ($wert -eq 1) { $text = 'an (mit UEFI-Sperre)' } elseif ($wert -eq 2) { $text = 'an' } elseif ($null -eq $wert) { $text = 'aus (Wert nicht gesetzt)' } else { $text = "aus (RunAsPPL = $wert)" }
            [pscustomobject]@{ Aktiv = ($wert -eq 1 -or $wert -eq 2); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; $name = 'RunAsPPL'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 2 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; $name = 'RunAsPPL'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    @{
        Id          = 'haertung.treibersperrliste'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Treiber-Sperrliste und Smart App Control'
        Titel       = 'Microsoft-Sperrliste für anfällige Treiber einschalten'
        Erklaerung  = 'Windows lädt dann keine Treiber mehr, die Microsoft als missbrauchbar eingestuft hat. Wirkt nach einem Neustart; sehr alte Treiber von Hardware-Tools (z. B. mancher Übertaktungs- oder Lüfter-Software) können dadurch gesperrt werden.'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'mittel'
        Neustart    = $true
        Bereich     = 'System'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = "New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' -Name 'VulnerableDriverBlocklistEnable' -PropertyType DWord -Value 1 -Force"
            Rueckgaengig = "New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' -Name 'VulnerableDriverBlocklistEnable' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path '…' -Name 'VulnerableDriverBlocklistEnable'"
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force).',
                'VulnerableDriverBlocklistEnable schaltet die Microsoft-Sperrliste für anfällige Treiber ein (1) oder aus (0).',
                'Die Änderung wirkt erst nach einem Neustart.',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht den Wert, wenn er vorher nicht existierte.'
            )
        }
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return 'Administratorrechte fehlen.' }
        }
        Lesen = {
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'; $name = 'VulnerableDriverBlocklistEnable'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            # Wie in der Prüfung: nur ein ausdrückliches 0 bedeutet "aus"; ohne Wert gilt der Windows-Standard (an)
            if ($wert -eq 0) { $text = 'aus' } elseif ($null -eq $wert) { $text = 'an (Windows-Standard)' } else { $text = 'an' }
            [pscustomobject]@{ Aktiv = ($wert -ne 0); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'; $name = 'VulnerableDriverBlocklistEnable'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'; $name = 'VulnerableDriverBlocklistEnable'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    #endregion

    #region Leistung: Energie

    @{
        Id          = 'energie.aspm'
        Kategorie   = 'Leistung'
        Pruefung    = 'Weitere Energiesparfunktionen'
        Titel       = 'PCIe-Energieverwaltung (ASPM) im aktiven Energieplan ausschalten'
        Erklaerung  = 'Grafikkarte und NVMe-SSD schalten ihre PCIe-Verbindung dann nie in einen Schlafzustand, was bei manchen Systemen Mikroruckler vermeidet. Der Verbrauch steigt minimal; auf einem Laptop im Akkubetrieb kostet es etwas Laufzeit.'
        Nutzen      = 'gering'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = "powercfg /setacvalueindex <aktiver Plan> 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0`npowercfg /setdcvalueindex <aktiver Plan> 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0`npowercfg /setactive SCHEME_CURRENT"
            Rueckgaengig = "powercfg /setacvalueindex <damaliger Plan> 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 <alter AC-Wert>`npowercfg /setdcvalueindex <damaliger Plan> 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 <alter DC-Wert>`npowercfg /setactive SCHEME_CURRENT"
            Erklaerung   = @(
                'powercfg ändert Einstellungen der Energiepläne. /setacvalueindex gilt im Netzbetrieb (AC), /setdcvalueindex im Akkubetrieb (DC).',
                '501a4d13-… ist die Gruppe "PCI Express", ee12f906-… die Einstellung "Verbindungszustand-Energieverwaltung" (ASPM); 0 = aus, 1 = mittel, 2 = maximal sparen.',
                '/setactive SCHEME_CURRENT wendet den aktuellen Plan neu an, damit die Änderung sofort gilt.',
                'Rückgängig setzt in genau dem Plan, der damals aktiv war, die alten Werte (AC und DC) zurück.'
            )
        }
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return 'Administratorrechte fehlen.' }
            $akt = (& (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /getactivescheme) -join ' '
            if ($akt -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return 'Der aktive Energieplan ließ sich nicht ermitteln.' }
            $out = (& (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /qh $Matches[1] '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5') -join "`n"
            if (@([regex]::Matches($out, '0x([0-9a-fA-F]{8})')).Count -lt 2) { return 'Der aktive Energieplan enthält die PCIe-Einstellung nicht.' }
        }
        Lesen = {
            $teil = '501a4d13-42af-4429-9fd1-a8218c268e20'; $einst = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
            $akt = (& (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /getactivescheme) -join ' '
            if ($akt -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                return [pscustomobject]@{ Aktiv = $false; Wert = 'Aktiver Energieplan nicht lesbar'; Zustand = $null }
            }
            $plan = $Matches[1].ToLower()
            $planName = $plan
            if ($akt -match '\((.+)\)\s*\*?\s*$') { $planName = $Matches[1] }
            $out = (& (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /qh $plan $teil $einst) -join "`n"
            $hex = @([regex]::Matches($out, '0x([0-9a-fA-F]{8})') | ForEach-Object { [Convert]::ToInt64($_.Groups[1].Value, 16) })
            if ($hex.Count -lt 2) {
                return [pscustomobject]@{ Aktiv = $false; Wert = "Plan '$planName' enthält die PCIe-Einstellung nicht"; Zustand = $null }
            }
            $ac = [int]$hex[-2]; $dc = [int]$hex[-1]
            $namen = @{ 0 = 'aus'; 1 = 'mittel'; 2 = 'maximal' }
            $text = "Plan '{0}': Netz {1}, Akku {2}" -f $planName, $(if ($namen.ContainsKey($ac)) { $namen[$ac] } else { $ac }), $(if ($namen.ContainsKey($dc)) { $namen[$dc] } else { $dc })
            [pscustomobject]@{ Aktiv = ($ac -eq 0 -and $dc -eq 0); Wert = $text; Zustand = [ordered]@{ Plan = $plan; AC = $ac; DC = $dc } }
        }
        Ausfuehren = {
            param($Variante)
            $teil = '501a4d13-42af-4429-9fd1-a8218c268e20'; $einst = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
            $akt = (& (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /getactivescheme) -join ' '
            if ($akt -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { throw 'Der aktive Energieplan ließ sich nicht ermitteln.' }
            $plan = $Matches[1].ToLower()
            & (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /setacvalueindex $plan $teil $einst 0 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "powercfg /setacvalueindex endete mit Code $LASTEXITCODE." }
            & (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /setdcvalueindex $plan $teil $einst 0 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "powercfg /setdcvalueindex endete mit Code $LASTEXITCODE." }
            & (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /setactive SCHEME_CURRENT | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "powercfg /setactive endete mit Code $LASTEXITCODE." }
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            $teil = '501a4d13-42af-4429-9fd1-a8218c268e20'; $einst = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
            $plan = ([string]$Vorher.Plan).ToLower()
            if ($plan -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw "Ungültiger Energieplan '$plan' im Vorher-Zustand." }
            & (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /setacvalueindex $plan $teil $einst ([int]$Vorher.AC) | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "powercfg /setacvalueindex endete mit Code $LASTEXITCODE." }
            & (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /setdcvalueindex $plan $teil $einst ([int]$Vorher.DC) | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "powercfg /setdcvalueindex endete mit Code $LASTEXITCODE." }
            & (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /setactive SCHEME_CURRENT | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "powercfg /setactive endete mit Code $LASTEXITCODE." }
        }
    },

    #endregion

    #region Gaming

    @{
        Id          = 'gaming.spielmodus'
        Kategorie   = 'Gaming'
        Pruefung    = 'Spielmodus'
        Titel       = 'Windows-Spielmodus einschalten'
        Erklaerung  = 'Windows priorisiert dann das laufende Spiel und startet während des Spielens keine Update-Neustarts oder Treiberinstallationen. Der Effekt auf die FPS ist klein; bei Problemen in einzelnen Spielen lässt er sich wieder ausschalten.'
        Nutzen      = 'gering'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'Benutzer'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = "New-ItemProperty -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -PropertyType DWord -Value 1 -Force   # legt den Schlüssel vorher an, falls er fehlt"
            Rueckgaengig = "New-ItemProperty -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path '…' -Name 'AutoGameModeEnabled'"
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force).',
                'HKCU gilt nur für den angemeldeten Benutzer. AutoGameModeEnabled ist der Schalter "Spielmodus" (1 = an, 0 = aus).',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht den Wert (und einen selbst angelegten, leeren Schlüssel), wenn er vorher nicht existierte.'
            )
        }
        Voraussetzung = {
            try {
                $besitzer = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction Stop).User })
            } catch { return 'Der angemeldete Benutzer ließ sich nicht ermitteln: ' + $_.Exception.Message }
            if (-not $besitzer) { return 'Es läuft kein Explorer; ein angemeldeter Benutzer ist nicht erkennbar.' }
            if ($besitzer -notcontains $env:USERNAME) { return "Das Programm läuft als '$env:USERNAME', angemeldet ist aber '$((($besitzer | Select-Object -Unique) -join ', '))'. Die Einstellung würde den falschen Benutzer treffen." }
        }
        Lesen = {
            $pfad = 'HKCU:\Software\Microsoft\GameBar'; $name = 'AutoGameModeEnabled'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            # Wie in der Prüfung: nur ein ausdrückliches 0 bedeutet "aus"; ohne Wert gilt der Windows-Standard (an)
            if ($wert -eq 0) { $text = 'aus' } elseif ($null -eq $wert) { $text = 'an (Windows-Standard)' } else { $text = 'an' }
            [pscustomobject]@{ Aktiv = ($wert -ne 0); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKCU:\Software\Microsoft\GameBar'; $name = 'AutoGameModeEnabled'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            $pfad = 'HKCU:\Software\Microsoft\GameBar'; $name = 'AutoGameModeEnabled'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    @{
        Id          = 'gaming.hags'
        Kategorie   = 'Gaming'
        Pruefung    = 'Hardwarebeschleunigte GPU-Planung (HAGS)'
        Titel       = 'Hardwarebeschleunigte GPU-Planung (HAGS) einschalten'
        Erklaerung  = 'Die Grafikkarte verwaltet ihren Speicher dann selbst, was die Latenz senken kann und für DLSS Frame Generation nötig ist. Wirkt erst nach einem Neustart; bei Rucklern in einzelnen Spielen lässt es sich wieder ausschalten.'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'mittel'
        Neustart    = $true
        Bereich     = 'System'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = "New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -PropertyType DWord -Value 2 -Force"
            Rueckgaengig = "New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path '…' -Name 'HwSchMode'"
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force).',
                'HwSchMode ist der Schalter hinter "Hardwarebeschleunigte GPU-Planung" (Einstellungen > System > Anzeige > Grafik); 2 = an, 1 = aus.',
                'Die Änderung wirkt erst nach einem Neustart.',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht den Wert, wenn er vorher nicht existierte.'
            )
        }
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return 'Administratorrechte fehlen.' }
            # Nur anbieten, wenn Windows die Einstellung für diese Grafikkarte selbst angelegt hat (Treiber unterstützt HAGS)
            $h = $null
            try { $h = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -ErrorAction Stop).HwSchMode } catch { }
            if ($h -ne 1 -and $h -ne 2) { return 'Windows hat für diese Grafikkarte keine HAGS-Einstellung angelegt; bitte unter Einstellungen > System > Anzeige > Grafik prüfen, ob sie angeboten wird.' }
        }
        Lesen = {
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; $name = 'HwSchMode'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            if ($wert -eq 2) { $text = 'an' } elseif ($wert -eq 1) { $text = 'aus' } elseif ($null -eq $wert) { $text = 'Windows-Standard (nicht gesetzt)' } else { $text = "unbekannt (HwSchMode = $wert)" }
            [pscustomobject]@{ Aktiv = ($wert -eq 2); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; $name = 'HwSchMode'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 2 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; $name = 'HwSchMode'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    @{
        Id          = 'gaming.gamedvr'
        Kategorie   = 'Gaming'
        Pruefung    = 'Hintergrundaufzeichnung (Game DVR)'
        Titel       = 'Hintergrundaufnahme (Game DVR) ausschalten'
        Erklaerung  = 'Windows schneidet dann nicht mehr ständig die letzten Spielminuten mit, was FPS und Grafikspeicher spart. Aufnahmen per Xbox Game Bar (z. B. "Letzte 30 Sekunden speichern") gehen danach nicht mehr.'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'Benutzer'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = "New-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -PropertyType DWord -Value 0 -Force`nNew-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -PropertyType DWord -Value 0 -Force`nNew-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'HistoricalCaptureEnabled' -PropertyType DWord -Value 0 -Force   # fehlende Schlüssel werden vorher angelegt"
            Rueckgaengig = "New-ItemProperty -Path <Schlüssel> -Name <Wert> -PropertyType DWord -Value <vorher> -Force   # für alle drei Werte; existierte ein Wert vorher nicht: Remove-ItemProperty -Path <Schlüssel> -Name <Wert>"
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force). HKCU gilt nur für den angemeldeten Benutzer.',
                'GameDVR_Enabled (System\GameConfigStore) und AppCaptureEnabled sind die Hauptschalter für die Spielaufnahme der Game Bar; 0 = aus.',
                'HistoricalCaptureEnabled ist der Schalter "Aufzeichnen, was passiert ist" (Hintergrundaufnahme); 0 = aus. Genau diesen Wert wertet die Prüfung aus.',
                'Rückgängig stellt jeden der drei Werte einzeln wieder her bzw. löscht ihn, wenn er vorher nicht existierte.'
            )
        }
        Voraussetzung = {
            try {
                $besitzer = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction Stop).User })
            } catch { return 'Der angemeldete Benutzer ließ sich nicht ermitteln: ' + $_.Exception.Message }
            if (-not $besitzer) { return 'Es läuft kein Explorer; ein angemeldeter Benutzer ist nicht erkennbar.' }
            if ($besitzer -notcontains $env:USERNAME) { return "Das Programm läuft als '$env:USERNAME', angemeldet ist aber '$((($besitzer | Select-Object -Unique) -join ', '))'. Die Einstellung würde den falschen Benutzer treffen." }
        }
        Lesen = {
            $ziele = @(
                @{ Pfad = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled' },
                @{ Pfad = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled' },
                @{ Pfad = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'HistoricalCaptureEnabled' }
            )
            $werte = @(foreach ($z in $ziele) {
                    $schluessel = Test-Path -LiteralPath $z.Pfad
                    $wert = $null; $typ = $null
                    if ($schluessel) {
                        $k = Get-Item -LiteralPath $z.Pfad -ErrorAction Stop
                        if ($k.GetValueNames() -contains $z.Name) { $wert = $k.GetValue($z.Name); $typ = $k.GetValueKind($z.Name).ToString() }
                    }
                    [ordered]@{ Pfad = $z.Pfad; Name = $z.Name; Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel }
                })
            $alleAus = $true
            foreach ($w in $werte) { if ($w.Wert -ne 0) { $alleAus = $false } }
            $an = @($werte | Where-Object { $_.Wert -eq 1 })
            if ($alleAus) { $text = 'aus' } elseif ($an.Count -gt 0) { $text = 'an (' + (($an | ForEach-Object { $_.Name }) -join ', ') + ')' } else { $text = 'teilweise nicht gesetzt' }
            [pscustomobject]@{ Aktiv = $alleAus; Wert = $text; Zustand = [ordered]@{ Werte = $werte } }
        }
        Ausfuehren = {
            param($Variante)
            $ziele = @(
                @{ Pfad = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled' },
                @{ Pfad = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled' },
                @{ Pfad = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'HistoricalCaptureEnabled' }
            )
            foreach ($z in $ziele) {
                if (-not (Test-Path -LiteralPath $z.Pfad)) { New-Item -Path $z.Pfad -Force -ErrorAction Stop | Out-Null }
                New-ItemProperty -LiteralPath $z.Pfad -Name $z.Name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
            }
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            foreach ($v in @($Vorher.Werte)) {
                $pfad = [string]$v.Pfad; $name = [string]$v.Name
                if ($null -eq $v.Wert) {
                    if (Test-Path -LiteralPath $pfad) {
                        if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                        if ($v.SchluesselVorhanden -eq $false) {
                            $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                            if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                        }
                    }
                } else {
                    if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                    $wert = $v.Wert
                    if ($v.Typ -eq 'DWord') { $wert = [int]$wert }
                    New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $v.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
                }
            }
        }
    },

    @{
        Id          = 'gaming.maus'
        Kategorie   = 'Gaming'
        Pruefung    = 'Mausbeschleunigung'
        Titel       = 'Mausbeschleunigung ausschalten'
        Erklaerung  = 'Die Maus bewegt den Zeiger dann immer proportional zur Handbewegung ("Zeigerpräzision verbessern" aus), was vor allem in Shootern ein gleichmäßigeres Zielen ergibt. Die Umstellung braucht ein Ab- und Anmelden und fühlt sich anfangs ungewohnt an.'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'Benutzer'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = "New-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed' -PropertyType String -Value '0' -Force`nNew-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold1' -PropertyType String -Value '0' -Force`nNew-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold2' -PropertyType String -Value '0' -Force"
            Rueckgaengig = "New-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name <Wert> -PropertyType String -Value '<vorher>' -Force   # für alle drei Werte; existierte ein Wert vorher nicht: Remove-ItemProperty -Path '…' -Name <Wert>"
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force). HKCU gilt nur für den angemeldeten Benutzer.',
                'MouseSpeed, MouseThreshold1 und MouseThreshold2 sind die drei Werte hinter "Zeigerpräzision verbessern"; alle drei auf "0" bedeutet: keine Beschleunigung.',
                '-PropertyType String: Diese Werte sind Text (REG_SZ), keine Zahlen.',
                'Windows liest die Werte erst nach dem nächsten Ab-/Anmelden. Rückgängig stellt jeden der drei Werte einzeln wieder her.'
            )
        }
        Voraussetzung = {
            try {
                $besitzer = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction Stop).User })
            } catch { return 'Der angemeldete Benutzer ließ sich nicht ermitteln: ' + $_.Exception.Message }
            if (-not $besitzer) { return 'Es läuft kein Explorer; ein angemeldeter Benutzer ist nicht erkennbar.' }
            if ($besitzer -notcontains $env:USERNAME) { return "Das Programm läuft als '$env:USERNAME', angemeldet ist aber '$((($besitzer | Select-Object -Unique) -join ', '))'. Die Einstellung würde den falschen Benutzer treffen." }
        }
        Lesen = {
            $pfad = 'HKCU:\Control Panel\Mouse'
            $namen = @('MouseSpeed', 'MouseThreshold1', 'MouseThreshold2')
            $schluessel = Test-Path -LiteralPath $pfad
            $werte = @(foreach ($n in $namen) {
                    $wert = $null; $typ = $null
                    if ($schluessel) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.GetValueNames() -contains $n) { $wert = $k.GetValue($n); $typ = $k.GetValueKind($n).ToString() }
                    }
                    [ordered]@{ Pfad = $pfad; Name = $n; Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel }
                })
            $alleNull = $true
            foreach ($w in $werte) { if ([string]$w.Wert -ne '0') { $alleNull = $false } }
            $speed = $werte[0].Wert
            if ($alleNull) { $text = 'Zeigerbeschleunigung aus' } elseif ([string]$speed -eq '0') { $text = 'Zeigerbeschleunigung aus (Schwellenwerte noch nicht 0)' } else { $text = "Zeigerbeschleunigung an (MouseSpeed = $speed)" }
            [pscustomobject]@{ Aktiv = $alleNull; Wert = $text; Zustand = [ordered]@{ Werte = $werte } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKCU:\Control Panel\Mouse'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            foreach ($n in @('MouseSpeed', 'MouseThreshold1', 'MouseThreshold2')) {
                New-ItemProperty -LiteralPath $pfad -Name $n -PropertyType String -Value '0' -Force -ErrorAction Stop | Out-Null
            }
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            foreach ($v in @($Vorher.Werte)) {
                $pfad = [string]$v.Pfad; $name = [string]$v.Name
                if ($null -eq $v.Wert) {
                    if (Test-Path -LiteralPath $pfad) {
                        if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                        if ($v.SchluesselVorhanden -eq $false) {
                            $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                            if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                        }
                    }
                } else {
                    if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                    $wert = $v.Wert
                    if ($v.Typ -eq 'DWord') { $wert = [int]$wert }
                    New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $v.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
                }
            }
        }
    },

    @{
        Id          = 'netz.eee'
        Kategorie   = 'Gaming'
        Pruefung    = 'Netzwerkkarte: Energiesparfunktionen'
        Titel       = 'Energiesparfunktionen der LAN-Karte ausschalten'
        Erklaerung  = 'Schaltet Energy Efficient Ethernet, Green Ethernet und ähnliche Schlafmodi der verbundenen Kabel-Netzwerkkarte aus, die in Online-Spielen kurze Latenzspitzen verursachen können. Dabei startet die Netzwerkkarte kurz neu, die Verbindung ist für einige Sekunden weg.'
        Nutzen      = 'gering'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Befehle     = @{
            Ausfuehren   = "Set-NetAdapterAdvancedProperty -Name '<Adapter>' -RegistryKeyword '<Schlüsselwort>' -RegistryValue '0' -NoRestart   # für jede aktive Energiesparfunktion (*EEE, EEELinkAdvertisement, *GreenEthernet, EnableGreenEthernet, AdvancedEEE, ULPMode, PowerSavingMode)`nRestart-NetAdapter -Name '<Adapter>'"
            Rueckgaengig = "Set-NetAdapterAdvancedProperty -Name '<Adapter>' -RegistryKeyword '<Schlüsselwort>' -RegistryValue '<vorher>' -NoRestart   # für jede geänderte Funktion`nRestart-NetAdapter -Name '<Adapter>'"
            Erklaerung   = @(
                'Set-NetAdapterAdvancedProperty ändert eine erweiterte Treibereinstellung der Netzwerkkarte, hier über ihr Registry-Schlüsselwort (-RegistryKeyword).',
                'Die Schlüsselwörter stehen für Energy Efficient Ethernet, Green Ethernet, Advanced EEE, Ultra Low Power Mode und Power Saving Mode; 0 = aus. Es werden nur Funktionen geändert, die vorhanden und noch nicht aus sind, und nur bei verbundenen, kabelgebundenen Adaptern.',
                '-NoRestart verschiebt den Neustart des Adapters ans Ende, damit er nur einmal pro Adapter erfolgt.',
                'Restart-NetAdapter startet die Netzwerkkarte neu, damit die Einstellung wirkt; die Verbindung ist kurz unterbrochen.',
                'Rückgängig setzt jede geänderte Funktion auf ihren alten Wert zurück.'
            )
        }
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return 'Administratorrechte fehlen.' }
            if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) { return 'Die Netzwerk-Cmdlets (NetAdapter) sind nicht verfügbar.' }
            $ad = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and [string]$_.PhysicalMediaType -match '802\.3' })
            if (-not $ad) { return 'Es ist kein kabelgebundener Netzwerkadapter verbunden.' }
        }
        Lesen = {
            if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{ Aktiv = $false; Wert = 'Netzwerk-Cmdlets nicht verfügbar'; Zustand = $null }
            }
            $schluessel = @('*EEE', 'EEELinkAdvertisement', '*GreenEthernet', 'EnableGreenEthernet', 'AdvancedEEE', 'ULPMode', 'PowerSavingMode')
            $ad = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and [string]$_.PhysicalMediaType -match '802\.3' } | Sort-Object Name)
            $eintraege = @(foreach ($a in $ad) {
                    foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue | Where-Object { $_.RegistryKeyword -in $schluessel } | Sort-Object RegistryKeyword)) {
                        [ordered]@{ Adapter = [string]$a.Name; Schluessel = [string]$p.RegistryKeyword; Wert = "$(@($p.RegistryValue)[0])" }
                    }
                })
            $an = @($eintraege | Where-Object { $_.Wert -ne '0' })
            if ($ad.Count -eq 0) { $text = 'Kein kabelgebundener Adapter verbunden' }
            elseif ($eintraege.Count -eq 0) { $text = (($ad | ForEach-Object { $_.Name }) -join ', ') + ': keine Energiesparfunktionen vorhanden' }
            elseif ($an.Count -eq 0) { $text = 'alle aus (' + (($eintraege | ForEach-Object { "$($_.Adapter): $($_.Schluessel)" }) -join ', ') + ')' }
            else { $text = 'aktiv: ' + (($an | ForEach-Object { "$($_.Adapter): $($_.Schluessel) = $($_.Wert)" }) -join ', ') }
            [pscustomobject]@{ Aktiv = ($an.Count -eq 0); Wert = $text; Zustand = [ordered]@{ Eintraege = $eintraege } }
        }
        Ausfuehren = {
            param($Variante)
            $schluessel = @('*EEE', 'EEELinkAdvertisement', '*GreenEthernet', 'EnableGreenEthernet', 'AdvancedEEE', 'ULPMode', 'PowerSavingMode')
            $ad = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and [string]$_.PhysicalMediaType -match '802\.3' } | Sort-Object Name)
            $geaendert = New-Object System.Collections.ArrayList
            foreach ($a in $ad) {
                foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction Stop | Where-Object { $_.RegistryKeyword -in $schluessel })) {
                    if ("$(@($p.RegistryValue)[0])" -ne '0') {
                        Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $p.RegistryKeyword -RegistryValue '0' -NoRestart -ErrorAction Stop | Out-Null
                        if (-not $geaendert.Contains([string]$a.Name)) { [void]$geaendert.Add([string]$a.Name) }
                    }
                }
            }
            foreach ($n in $geaendert) {
                Restart-NetAdapter -Name $n -ErrorAction Stop | Out-Null
                # Warten, bis der Adapter wieder verbunden ist (höchstens 30 s), damit die Kontrolle danach ihn wieder sieht
                for ($i = 0; $i -lt 30; $i++) {
                    $s = Get-NetAdapter -Name $n -ErrorAction SilentlyContinue
                    if ($s -and $s.Status -eq 'Up') { break }
                    Start-Sleep -Seconds 1
                }
            }
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw 'Kein Vorher-Zustand vorhanden.' }
            $geaendert = New-Object System.Collections.ArrayList
            foreach ($e in @($Vorher.Eintraege)) {
                $aktuell = Get-NetAdapterAdvancedProperty -Name ([string]$e.Adapter) -RegistryKeyword ([string]$e.Schluessel) -ErrorAction Stop
                if ("$(@($aktuell.RegistryValue)[0])" -ne [string]$e.Wert) {
                    Set-NetAdapterAdvancedProperty -Name ([string]$e.Adapter) -RegistryKeyword ([string]$e.Schluessel) -RegistryValue ([string]$e.Wert) -NoRestart -ErrorAction Stop | Out-Null
                    if (-not $geaendert.Contains([string]$e.Adapter)) { [void]$geaendert.Add([string]$e.Adapter) }
                }
            }
            foreach ($n in $geaendert) {
                Restart-NetAdapter -Name $n -ErrorAction Stop | Out-Null
                for ($i = 0; $i -lt 30; $i++) {
                    $s = Get-NetAdapter -Name $n -ErrorAction SilentlyContinue
                    if ($s -and $s.Status -eq 'Up') { break }
                    Start-Sleep -Seconds 1
                }
            }
        }
    }

    #endregion
)
