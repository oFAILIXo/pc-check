/* Entwicklungsmodus: fängt fetch('/api/*') ab und antwortet mit erfundenen Demodaten (PC "DEMO-PC").
   Öffnen: gui/dev/mock.html (direkt als Datei oder über einen lokalen Webserver). Keine echten Daten. */
'use strict';
(() => {
  try { sessionStorage.setItem('pcCheckToken', 'demo-token'); } catch { /* egal */ }
  // Für Screenshots: mock.html?nav=sicherheit,werkzeuge klappt diese Menüpunkte auf (2.5, #65)
  try {
    const nav = new URLSearchParams(location.search).get('nav');
    if (nav != null) { const o = {}; nav.split(',').filter(Boolean).forEach(k => { o[k] = true; }); localStorage.setItem('morpheusNavAuf', JSON.stringify(o)); }
  } catch { /* egal */ }
  const iso = d => { const p = n => String(n).padStart(2, '0'); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`; };
  const F = (Area, Category, Check, Status, Value, Recommendation = '', x = {}) => ({ Area, Category, Check, Status, Value, Recommendation, OriginalStatus: '', Note: '', Effort: '', Benefit: '', Risk: '', Steps: [], Command: '', ...x });
  const base = [
    F('Sicherheit', 'System & Updates', 'Windows-Version', 'OK', 'Windows 11 Pro 24H2 (Demo)'),
    F('Sicherheit', 'System & Updates', 'Windows Update: ausstehend', 'TIPP', 'Nur optional: Treiber', 'Optionale Treiber nur bei Problemen installieren.', { Effort: 'gering', Benefit: 'mittel', Risk: 'gering', Steps: ['Einstellungen > Windows Update > „Nach Updates suchen“.', 'Danach neu starten.'] }),
    F('Sicherheit', 'Virenschutz', 'Microsoft Defender: Status', 'OK', 'Echtzeit-, Verhaltens- und Download-Schutz aktiv'),
    F('Sicherheit', 'Virenschutz', 'Defender: Einstellungen', 'TIPP', 'Netzwerkschutz aus; PUA-Schutz an', 'Netzwerkschutz einschalten.', { Effort: 'gering', Benefit: 'mittel', Risk: 'gering', Steps: ['Rechtsklick auf Start > „Terminal (Administrator)“.', 'Befehl einfügen.'], Command: 'Set-MpPreference -EnableNetworkProtection Enabled' }),
    F('Sicherheit', 'Virenschutz', 'Defender: ASR-Regeln', 'TIPP', 'Keine Regeln aktiv', 'Zwei Basisregeln aktivieren.', { Effort: 'gering', Benefit: 'mittel', Risk: 'gering' }),
    F('Sicherheit', 'Virenschutz', 'Defender: Signaturen', 'WARN', 'Stand 2026-10-22 06:10 (3 Tage)', 'Signaturen sollten täglich aktualisiert werden.'),
    F('Sicherheit', 'Virenschutz', 'Defender: Scans', 'INFO', 'Letzter Schnellscan vor 19 Tagen', 'Defender scannt normalerweise in der Wartungszeit; läuft der PC dann nie, gelegentlich manuell scannen.'),
    F('Sicherheit', 'Fernzugriff & Dienste', 'Remoteunterstützung', 'OK', 'Nicht erlaubt'),
    F('Sicherheit', 'Firewall & Netzwerk', 'Firewall-Profile', 'OK', 'Alle Profile aktiv, eingehend blockiert'),
    F('Sicherheit', 'Fernzugriff & Dienste', 'Offene Ports', 'WARN', '3 Ports lauschen auf allen Adressen (192.168.0.15, DEMO-PC)', 'Prüfen, ob die Dienste nötig sind.', { Effort: 'mittel', Benefit: 'mittel', Risk: 'gering' }),
    F('Sicherheit', 'Verschlüsselung & Firmware', 'Secure Boot', 'OK', 'UEFI, Secure Boot an'),
    F('Sicherheit', 'Verschlüsselung & Firmware', 'TPM', 'SKIP', 'Nur mit Adminrechten prüfbar'),
    F('Sicherheit', 'Systemhärtung', 'Kernisolierung (VBS / Speicherintegrität)', 'INFO', 'VBS läuft, Speicherintegrität aus'),
    F('Sicherheit', 'Verschlüsselung & Firmware', 'BitLocker', 'ACK', 'Systemlaufwerk nicht verschlüsselt', '', { OriginalStatus: 'WARN', Note: 'Bewusst zurückgestellt bis 30.04.2027' }),
    F('Sicherheit', 'Verschlüsselung & Firmware', 'Datensicherung', 'WARN', 'Dateiversionsverlauf aus; OneDrive: Desktop, Dokumente; kein Systemabbild', 'Dateiversionsverlauf einschalten oder wichtige Ordner über OneDrive sichern. Sicherst du mit einem anderen Programm oder auf ein NAS, trag den Befund in die Akzeptanzliste (accepted.psd1) ein.', { Effort: 'gering', Benefit: 'hoch', Risk: 'gering', Steps: ['Einstellungen > System > Speicher > Erweiterte Speichereinstellungen > Sicherungsoptionen öffnen.', 'Dateiversionsverlauf einschalten und ein Ziel wählen (externe Festplatte oder NAS).', 'Optional: OneDrive-Sicherung für Desktop, Dokumente und Bilder einrichten.'] }),
    F('Sicherheit', 'Systemhärtung', 'LSA-Schutz', 'TIPP', 'aus', 'LSA-Schutz einschalten (Neustart).', { Effort: 'gering', Benefit: 'hoch', Risk: 'gering' }),
    F('Sicherheit', 'Autostart & Persistenz', 'Autostarts: Signaturen (Autoruns)', 'WARN', 'Systemnahe Autostarts ohne verifizierte Signatur (1): DemoVendor Updater Task; Weitere Autostarts ohne Signatur (2): DemoTool, Old Helper', 'Prüfen, ob die Einträge zu Programmen gehören, die du kennst. Unbekannte Dienste nicht einfach löschen, sondern erst recherchieren.'),
    F('Sicherheit', 'Autostart & Persistenz', 'Autostarts: beschreibbare Pfade (Autoruns)', 'INFO', 'Autostarts in beschreibbaren Ordnern (1): DemoTool', 'Üblich bei Programmen in AppData; kein Rechtegewinn.'),
    F('Sicherheit', 'Systemhärtung', 'Systemdateien: Signaturen (Sigcheck)', 'WARN', 'Unsignierte Dateien in System32 und drivers (2): demoaudio.sys (Demo Audio Ltd.), oldprint.dll; 1 akzeptiert', 'Herkunft der Dateien klären; unbekannte Dateien mit Defender prüfen oder den Hash bei VirusTotal nachschlagen.', { Effort: 'mittel', Benefit: 'mittel', Risk: 'gering' }),
    F('Sicherheit', 'Software', 'Software-Updates', 'WARN', 'Beispielprogramm 1.2 verfügbar (C:\\Users\\Demo\\Apps)', 'Programm aktualisieren.', { Effort: 'gering', Benefit: 'hoch', Risk: 'gering' }),
    F('Performance', 'Hardware', 'Arbeitsspeicher', 'OK', '32 GB DDR5'),
    F('Performance', 'Laufwerke & Speicherplatz', 'Speicherplatz', 'INFO', 'C: 32 % frei, F: 13 % frei'),
    F('Performance', 'Laufwerke & Speicherplatz', 'Größte Speicherverbraucher', 'INFO', 'C: C:\\Users\\Demo\\AppData (41 GB); F: F:\\SteamLibrary\\steamapps\\common\\Starfall Odyssey (142 GB); D: D:\\Videos (612 GB)'),
    F('Performance', 'Energie', 'Energieplan', 'OK', 'Ausbalanciert aktiv'),
    F('Performance', 'Energie', 'Schnellstart', 'TIPP', 'an: Treiberprobleme überdauern das Herunterfahren', 'Schnellstart ausschalten.', { Effort: 'gering', Benefit: 'mittel', Risk: 'gering' }),
    F('Performance', 'Auslastung', 'CPU-Auslastung', 'OK', 'Im Leerlauf 3 %'),
    F('Performance', 'Gaming & Grafik', 'Spielmodus', 'OK', 'an'),
    F('Performance', 'Gaming & Grafik', 'Hardwarebeschleunigte GPU-Planung (HAGS)', 'TIPP', 'aus', 'HAGS einschalten (Neustart).', { Effort: 'gering', Benefit: 'mittel', Risk: 'mittel' }),
    F('Performance', 'Gaming & Grafik', 'Spielebibliotheken', 'WARN', 'F: nur 13 % frei', 'Platz schaffen oder Bibliothek verschieben.', { Effort: 'mittel', Benefit: 'hoch', Risk: 'gering', Steps: ['Steam > Einstellungen > Speicher.'] }),
    F('Performance', 'Gaming & Grafik', 'Bildschirme und Bildwiederholrate', 'OK', '165 Hz'),
    F('Performance', 'Stabilität', 'Zuverlässigkeitsindex', 'OK', '9,2 von 10'),
    F('Performance', 'Stabilität', 'Abstürze und unerwartete Neustarts', 'OK', '0 unerwartete Neustarts, 0 Bluescreens in 14 Tagen; 0 Minidumps insgesamt'),
    F('Performance', 'Stabilität', 'Programmabstürze', 'INFO', '2 Abstürze, 0 Hänger: demo-app.exe (2)'),
    F('Performance', 'Stabilität', 'Startdauer', 'OK', 'Ø 26 s bis zum Desktop'),
  ];

  // ---- v2.2: Speicher (alles erfundene Demodaten)
  const GB = b => b < 1e9 ? Math.round(b / 1e6) + ' MB' : (b / 1e9).toFixed(1).replace('.', ',') + ' GB';
  const nachGroesse = a => a.sort((x, y) => y.bytes - x.bytes);
  const ord = (pfad, bytes) => ({ pfad, bytes });
  const dat = (pfad, bytes, geaendert, windows = false) => ({ pfad, bytes, windows, geaendert });
  const spl = (plattform, name, pfad, laufwerk, bytes, zuletztGespielt = null, groesseUnsicher = false) => ({ plattform, name, pfad, laufwerk, bytes, zuletztGespielt, groesseUnsicher });
  const LAUFWERKE = [
    { laufwerk: 'C:', bezeichnung: 'System', groesse: 238e9, frei: 76e9, gezaehlt: 812345, uebersprungen: 224, dauerSek: 94, fehler: null,
      ordner: nachGroesse([
        ord('C:\\Users\\Demo\\AppData', 41e9), ord('C:\\Windows', 31.6e9), ord('C:\\Program Files', 27.8e9), ord('C:\\ProgramData', 8.9e9), ord('C:\\Users\\Demo\\Downloads', 9.4e9),
        ord('C:\\Users\\Demo\\Documents', 6.1e9), ord('C:\\Users\\Demo\\Pictures', 3.2e9), ord('C:\\Users\\Demo\\Desktop', 2.7e9), ord('C:\\Demo\\Installer', 4.3e9), ord('C:\\Apps\\Demo-Builds', 2.5e9)]),
      dateien: nachGroesse([
        dat('C:\\pagefile.sys', 16e9, '2026-10-25T09:12:00', true), dat('C:\\hiberfil.sys', 12.8e9, '2026-10-25T08:40:00', true), dat('C:\\swapfile.sys', 256e6, '2026-10-25T09:12:00', true),
        dat('C:\\Demo\\Installer\\setup-pack.iso', 4.7e9, '2026-09-11T16:30:00'), dat('C:\\Users\\Demo\\AppData\\Local\\demo-cache\\cache.bin', 3.9e9, '2026-10-24T22:05:00'),
        dat('C:\\Users\\Demo\\Pictures\\urlaub-2026.zip', 2.6e9, '2026-08-03T10:00:00'), dat('C:\\Users\\Demo\\Downloads\\demo-setup.exe', 2.1e9, '2026-10-21T14:44:00'),
        dat('C:\\Users\\Demo\\AppData\\Local\\Temp\\demo-log.7z', 1.4e9, '2026-10-19T07:12:00'), dat('C:\\Apps\\Demo-Builds\\build-0.9.zip', 1.2e9, '2026-07-30T18:20:00'),
        dat('C:\\ProgramData\\Demo\\index.db', 0.8e9, '2026-10-25T06:00:00')]) },
    { laufwerk: 'F:', bezeichnung: 'Spiele', groesse: 1e12, frei: 130e9, gezaehlt: 415870, uebersprungen: 96, dauerSek: 61, fehler: null,
      ordner: nachGroesse([
        ord('F:\\SteamLibrary\\steamapps\\common\\Starfall Odyssey', 142e9), ord('F:\\SteamLibrary\\steamapps\\common\\Pixel Racer 2', 38.5e9), ord('F:\\SteamLibrary\\steamapps\\common\\Dungeon Demo', 6.4e9),
        ord('F:\\Epic\\Skyline Builder', 58e9), ord('F:\\Epic\\Tidewalker', 23.7e9), ord('F:\\XboxGames\\Pocket Kingdoms', 15.3e9), ord('F:\\XboxGames\\Voxel Farmer', 4.6e9),
        ord('F:\\Archiv\\Fotoprojekte', 9.8e9), ord('F:\\Downloads\\Demo-Installers', 5.2e9), ord('F:\\Temp\\Shader-Cache', 3.3e9)]),
      dateien: nachGroesse([
        dat('F:\\Epic\\Skyline Builder\\Content\\Paks\\SkylineBuilder-WindowsNoEditor.pak', 9.4e9, '2026-09-30T19:58:00'), dat('F:\\Archiv\\Fotoprojekte\\raw-2025.7z', 6.8e9, '2025-12-02T11:09:00'),
        dat('F:\\XboxGames\\Pocket Kingdoms\\Content\\data.pak', 5.6e9, '2026-10-02T17:20:00'), dat('F:\\SteamLibrary\\steamapps\\common\\Pixel Racer 2\\Pixel2-Assets.bin', 4.1e9, '2026-10-12T19:31:00'),
        dat('F:\\Epic\\Tidewalker\\Tidewalker.pak', 3.9e9, '2026-06-14T12:00:00'), dat('F:\\Temp\\Shader-Cache\\cache.bin', 3.3e9, '2026-10-22T08:47:00'),
        dat('F:\\Downloads\\Demo-Installers\\installer-cache.iso', 2.8e9, '2026-08-19T20:10:00'), dat('F:\\Downloads\\Demo-Installers\\demo-setup-2.exe', 1.9e9, '2026-08-19T20:02:00'),
        dat('F:\\Archiv\\Musik\\demo-album.flac', 1.1e9, '2024-03-07T09:00:00'), dat('F:\\Archiv\\Dokumente\\Projekt-Mappe.zip', 0.7e9, '2025-10-15T16:45:00')]) },
    { laufwerk: 'D:', bezeichnung: 'Daten', groesse: 1.8e12, frei: 110e9, gezaehlt: 1204388, uebersprungen: 57, dauerSek: 412, fehler: null,
      ordner: nachGroesse([
        ord('D:\\Videos', 612e9), ord('D:\\Fotos', 287e9), ord('D:\\Backups\\Laptop-2025', 73.9e9), ord('D:\\Dokumente-Archiv', 88.4e9), ord('D:\\Musik', 41.7e9),
        ord('D:\\Ubisoft', 46.3e9), ord('D:\\GOG Games', 13e9), ord('D:\\Downloads', 19.5e9), ord('D:\\Projekte\\Demo-Code', 8.1e9), ord('D:\\Scans', 4.2e9)]),
      dateien: nachGroesse([
        dat('D:\\Videos\\Urlaub-2025.mkv', 38.2e9, '2025-08-30T17:40:00'), dat('D:\\Backups\\Laptop-2025\\system-image-alt.vhdx', 31.5e9, '2025-12-14T03:00:00'),
        dat('D:\\Fotos\\Export-Sommer.zip', 12.7e9, '2025-09-02T15:21:00'), dat('D:\\Ubisoft\\Rift Runners\\RiftRunners.pak', 17.8e9, '2026-06-18T20:40:00'),
        dat('D:\\GOG Games\\Neon Drift\\NeonDrift.pak', 8.2e9, '2026-08-02T22:20:00'), dat('D:\\Projekte\\Demo-Code\\node_modules.tar', 2.9e9, '2026-03-11T10:02:00'),
        dat('D:\\Downloads\\Demo-Trailer.mp4', 2.4e9, '2026-04-20T13:15:00'), dat('D:\\Dokumente-Archiv\\Steuer-2024.zip', 0.6e9, '2025-05-28T09:00:00'),
        dat('D:\\Musik\\Demo-Album.flac', 0.9e9, '2024-11-03T18:11:00'), dat('D:\\Scans\\Scan-0412.pdf', 0.2e9, '2026-04-12T08:30:00')]) },
  ];
  const SPIELE = nachGroesse([
    spl('Steam', 'Starfall Odyssey', 'F:\\SteamLibrary\\steamapps\\common\\Starfall Odyssey', 'F:', 142e9, '2026-10-20T21:14:03'),
    spl('Steam', 'Pixel Racer 2', 'F:\\SteamLibrary\\steamapps\\common\\Pixel Racer 2', 'F:', 38.5e9, '2026-10-12T19:40:00'),
    spl('Steam', 'Dungeon Demo', 'F:\\SteamLibrary\\steamapps\\common\\Dungeon Demo', 'F:', 6.4e9),
    spl('Steam', 'Glacier Run', 'F:\\SteamLibrary\\steamapps\\common\\Glacier Run', 'F:', 2.1e9),
    spl('Epic', 'Skyline Builder', 'F:\\Epic\\Skyline Builder', 'F:', 58e9, '2026-09-30T20:05:00'),
    spl('Epic', 'Tidewalker', 'F:\\Epic\\Tidewalker', 'F:', 23.7e9),
    spl('GOG', 'Neon Drift', 'D:\\GOG Games\\Neon Drift', 'D:', 9.8e9, '2026-08-02T22:31:00'),
    spl('GOG', 'Lantern Keep', 'D:\\GOG Games\\Lantern Keep', 'D:', 3.2e9),
    spl('EA', 'Orbit Miners', 'C:\\Program Files\\EA Games\\Orbit Miners', 'C:', 27.4e9),
    spl('EA', 'Hover Circuit', 'C:\\Program Files\\EA Games\\Hover Circuit', 'C:', 19.9e9, '2026-07-11T18:02:00'),
    spl('Ubisoft', 'Rift Runners', 'D:\\Ubisoft\\Rift Runners', 'D:', 34.2e9, '2026-06-18T20:48:00'),
    spl('Ubisoft', 'Mossy Trails', 'D:\\Ubisoft\\Mossy Trails', 'D:', 12.1e9),
    spl('Xbox', 'Pocket Kingdoms', 'F:\\XboxGames\\Pocket Kingdoms', 'F:', 15.3e9, '2026-10-02T17:25:00', true),
    spl('Xbox', 'Voxel Farmer', 'F:\\XboxGames\\Voxel Farmer', 'F:', 4.6e9),
  ]);
  // Gesamtobjekt (Vertrag 14.2), je Bericht mit eigenem Stand
  const speicherFuer = stand => JSON.parse(JSON.stringify({ version: 1, stand, laufwerke: LAUFWERKE, spiele: SPIELE }));
  const speicherTabellen = sp => {
    const ordner = [], dateien = [];
    sp.laufwerke.forEach(l => {
      l.ordner.forEach(o => ordner.push({ Laufwerk: l.laufwerk, Pfad: o.pfad, Groesse: GB(o.bytes), Bytes: o.bytes }));
      l.dateien.forEach(f => dateien.push({ Laufwerk: l.laufwerk, Pfad: f.pfad, Groesse: GB(f.bytes), Bytes: f.bytes, Windows: f.windows ? 'Ja' : '' }));
    });
    const spiele = sp.spiele.map(s => ({ Plattform: s.plattform, Name: s.name, Laufwerk: s.laufwerk, Groesse: GB(s.bytes), Bytes: s.bytes,
      ZuletztGespielt: s.zuletztGespielt ? s.zuletztGespielt.replace('T', ' ').slice(0, 16) : '–', Pfad: s.pfad, Hinweis: s.groesseUnsicher ? 'Größe eingeschränkt lesbar' : '' }));
    return { 'Speicherverbraucher: Ordner': ordner, 'Speicherverbraucher: Dateien': dateien, 'Installierte Spiele': spiele };
  };
  const speicherChecks = { 'Speicherverbraucher: Ordner': 'Größte Speicherverbraucher', 'Speicherverbraucher: Dateien': 'Größte Speicherverbraucher', 'Installierte Spiele': 'Spielebibliotheken' };
  const SICHERUNG = [
    { Art: 'Dateiversionsverlauf', Gefunden: 'Ja', Aktiv: 'Nein', Ziel: 'D:\\Backups', LetzteSicherung: '2026-08-14 12:00', Hinweis: 'Ausgeschaltet; seit August keine Sicherung' },
    { Art: 'OneDrive-Ordnersicherung', Gefunden: 'Ja', Aktiv: 'Ja', Ziel: 'Desktop, Dokumente', LetzteSicherung: '–', Hinweis: 'Letzte Sicherung unbekannt; Bilder nicht gesichert' },
    { Art: 'Systemabbild', Gefunden: 'Nein', Aktiv: 'Nein', Ziel: '–', LetzteSicherung: '–', Hinweis: 'Kein Systemabbild vorhanden' },
  ];

  const SYS_CHECKS = ['Autostarts: Signaturen (Autoruns)', 'Autostarts: beschreibbare Pfade (Autoruns)', 'Systemdateien: Signaturen (Sigcheck)'];
  const SIGCHECK = [
    { Pfad: 'C:\\Windows\\System32\\drivers\\demoaudio.sys', Firma: 'Demo Audio Ltd.', Version: '3.1.0.7', Datum: '2019-04-02', Sha256: '1c7e4a90b2d85f3e6a01c9d47b8e2f5a3d6c0b19e84f7a25c3d1b6e09f4a8d72', Akzeptiert: '' },
    { Pfad: 'C:\\Windows\\System32\\oldprint.dll', Firma: '', Version: '', Datum: '2014-11-20', Sha256: '5d0a3f8e1b9c47a26e5d0c3f7b1a948e2c6d5f0a3b87e14c9d2a6f5b0e3c7a18', Akzeptiert: '' },
    { Pfad: 'C:\\Windows\\System32\\demohelper.exe', Firma: 'Demo Helper Inc.', Version: '1.0.0.0', Datum: '2022-06-15', Sha256: 'a8f2c61d9e04b7a35c1f8e6d2b09a47e3c5d1f80b6a29e7d4c3b1058f6e2a9d4', Akzeptiert: 'Bekannte Demo-Software, geprüft' },
  ];
  const AUTORUNS = [
    { Kategorie: 'ScheduledTasks', Eintrag: 'DemoVendor Updater Task', Aktiv: true, Signierer: '', Verifiziert: false, Beschreibbar: false, Erhoeht: true, Pfad: 'C:\\Program Files\\DemoVendor\\update.exe', Ort: 'Task Scheduler', Befehl: '"C:\\Program Files\\DemoVendor\\update.exe" /service' },
    { Kategorie: 'Logon', Eintrag: 'DemoTool', Aktiv: true, Signierer: '', Verifiziert: false, Beschreibbar: true, Erhoeht: false, Pfad: 'C:\\Users\\Demo\\AppData\\Local\\DemoTool\\tool.exe', Ort: 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run', Befehl: 'C:\\Users\\Demo\\AppData\\Local\\DemoTool\\tool.exe --minimized' },
    { Kategorie: 'Logon', Eintrag: 'Old Helper', Aktiv: true, Signierer: '', Verifiziert: false, Beschreibbar: false, Erhoeht: false, Pfad: 'C:\\Users\\Demo\\AppData\\Roaming\\DemoSync\\sync.exe', Ort: 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run', Befehl: 'C:\\Users\\Demo\\AppData\\Roaming\\DemoSync\\sync.exe' },
    { Kategorie: 'Drivers', Eintrag: 'DemoAudioDrv', Aktiv: true, Signierer: 'Demo Audio GmbH', Verifiziert: true, Beschreibbar: null, Erhoeht: true, Pfad: 'C:\\Windows\\System32\\drivers\\demoaudio.sys', Ort: 'HKLM\\System\\CurrentControlSet\\Services', Befehl: '' },
    { Kategorie: 'ScheduledTasks', Eintrag: '\\DemoVendor\\Update-Check', Aktiv: true, Signierer: 'DemoVendor Inc.', Verifiziert: true, Beschreibbar: false, Erhoeht: true, Pfad: 'C:\\Program Files\\DemoVendor\\check.exe', Ort: 'Task Scheduler', Befehl: '"C:\\Program Files\\DemoVendor\\check.exe" /silent' },
  ];
  const mkReport = (i, opt = {}) => {   // i = 0 neuester; opt: { d, skip } (skip = -SkipSpeicher)
    const d = opt.d || new Date(2026, 9, 25 - i, 13, 21);
    const sp = opt.skip ? null : speicherFuer(iso(d));
    const F2 = base.map(f => ({ ...f })).filter(f => sp || f.Check !== 'Größte Speicherverbraucher');
    if (i >= 3) F2.forEach(f => { if (SYS_CHECKS.includes(f.Check)) { f.Status = 'SKIP'; f.Value = 'Sysinternals nicht eingerichtet: in Morpheus unter Werkzeuge herunterladen'; f.Recommendation = ''; } });
    if (i > 0) F2.forEach(f => { if (f.Check === 'Offene Ports' && i > 2) f.Status = 'CRIT'; if (f.Check === 'Software-Updates' && i > 4) f.Status = 'OK'; if (f.Check === 'Spielebibliotheken' && i > 6) f.Status = 'INFO'; });
    const name = `pc-check_${iso(d).slice(0, 10)}_1321`;
    return { name, json: { Meta: { Computer: 'DEMO-PC', Erstellt: iso(d), Version: '2.5.0', Admin: true, EventDays: 14, DauerSek: 120 + i, Profil: 'Gaming' }, Findings: F2,
      Changes: i < 11 ? { VerglichenMit: 'vorher.json', Erstellt: iso(new Date(2026, 9, 24 - i, 13, 21)), AdminVorher: true, Status: [{ 'Prüfung': 'Offene Ports', Vorher: 'Kritisch', Jetzt: 'Warnung', Befund: '3 Ports' }], Bestand: { 'Autostart-Einträge': { Neu: ['Demo-Tool <b>fett</b>'], Entfernt: ['Altes Tool'] } } } : null,
      Speicher: sp,
      Data: { System: [{ Computer: 'DEMO-PC', Edition: 'Windows 11 Pro', Version: '24H2' }],
        'Startdauer (letzte Messungen)': [{ Zeit: 'x', GesamtSek: 40, HauptpfadSek: 22 + (i % 5) * 3, NachAnmeldungSek: 5 }, { Zeit: 'y', GesamtSek: 41, HauptpfadSek: 24 + (i % 4) * 2, NachAnmeldungSek: 6 }],
        'Laufwerke (Volumes)': [{ Laufwerk: 'C:', Name: '', Dateisystem: 'NTFS', Groesse: '238 GB', Frei: '76 GB', FreiProzent: 30 + ((11 - i) % 7) * 2 }, { Laufwerk: 'F:', Name: 'Spiele', Dateisystem: 'NTFS', Groesse: '1 TB', Frei: '130 GB', FreiProzent: 13 }],
        'Offene Netzwerkports (nicht nur lokal)': [
          { Protokoll: 'TCP', Port: 135, Adressen: '0.0.0.0', Prozess: 'svchost', Dienste: 'RpcSs', PID: 1020 }, { Protokoll: 'TCP', Port: 445, Adressen: '0.0.0.0', Prozess: 'System', Dienste: null, PID: 4 },
          { Protokoll: 'TCP', Port: 3389, Adressen: '0.0.0.0', Prozess: 'svchost', Dienste: 'TermService', PID: 1180 }, { Protokoll: 'TCP', Port: 5040, Adressen: '0.0.0.0', Prozess: 'svchost', Dienste: 'CDPSvc', PID: 2200 },
          { Protokoll: 'TCP', Port: 8080, Adressen: '0.0.0.0', Prozess: 'demo-server', Dienste: null, PID: 7312 }, { Protokoll: 'TCP', Port: 49664, Adressen: '0.0.0.0', Prozess: 'lsass', Dienste: 'SamSs', PID: 780 },
          { Protokoll: 'UDP', Port: 5353, Adressen: '0.0.0.0', Prozess: 'msedge', Dienste: null, PID: 9020 }, { Protokoll: 'UDP', Port: 5355, Adressen: '0.0.0.0', Prozess: 'svchost', Dienste: 'Dnscache', PID: 1400 },
          { Protokoll: 'UDP', Port: 1900, Adressen: '0.0.0.0', Prozess: 'svchost', Dienste: 'SSDPSRV', PID: 3300 }],
        'Autostart-Einträge': [{ Name: 'Demo-Tool', Pfad: 'C:\\Demo\\tool.exe', Benutzer: 'Demo' }],
        ...(i < 3 ? { 'Autostarts (Autoruns, ohne Microsoft)': AUTORUNS.map(x => ({ ...x })) } : {}),
        ...(i < 3 ? { 'Unsignierte Systemdateien (Sigcheck)': SIGCHECK.map(x => ({ ...x })) } : {}),
        ...(sp ? speicherTabellen(sp) : {}),
        Datensicherung: SICHERUNG },
      DataChecks: { System: 'Windows-Version', 'Startdauer (letzte Messungen)': 'Startdauer', 'Laufwerke (Volumes)': 'Speicherplatz', 'Offene Netzwerkports (nicht nur lokal)': 'Offene Ports',
        ...(i < 3 ? { 'Autostarts (Autoruns, ohne Microsoft)': 'Autostarts: Signaturen (Autoruns)' } : {}),
        ...(i < 3 ? { 'Unsignierte Systemdateien (Sigcheck)': 'Systemdateien: Signaturen (Sigcheck)' } : {}),
        ...(sp ? speicherChecks : {}), Datensicherung: 'Datensicherung' } } };
  };
  const reps = Array.from({ length: 12 }, (_, i) => mkReport(i));
  const cnt = js => { const c = { CRIT: 0, WARN: 0, TIPP: 0, ACK: 0, INFO: 0, OK: 0, SKIP: 0 }; js.Findings.forEach(f => { c[f.Status]++; }); return c; };
  // ?berichte=0: wie im Nur-Lesen-Modus mit reparierbarem Datenordner (Daten liegen nicht im Codeordner, also kein Bericht)
  const ohneBerichte = new URLSearchParams(location.search).get('berichte') === '0';
  const reportList = () => ohneBerichte ? [] : reps.map(r => ({ name: r.name, created: r.json.Meta.Erstellt, version: '2.5.0', admin: true, profil: 'Gaming', counts: cnt(r.json) }));

  const A = (id, kategorie, pruefung, titel, erkl, n, a, r, extra = {}) => ({ id, kategorie, pruefung, titel, erklaerung: erkl, nutzen: n, aufwand: a, risiko: r, neustart: false, varianten: null,
    befehle: { ausfuehren: extra.cmd || '', rueckgaengig: extra.undo || '', erklaerung: extra.expl || [] }, zustand: { aktiv: false, wert: 'aus', stand: iso(new Date()) }, ...extra.o });
  const actions = [
    A('defender.netzwerkschutz', 'Sicherheit', 'Defender: Einstellungen', 'Netzwerkschutz einschalten', 'Blockiert Verbindungen zu bekannten Phishing- und Malware-Servern, in allen Programmen.', 'mittel', 'gering', 'gering', { cmd: 'Set-MpPreference -EnableNetworkProtection Enabled', undo: 'Set-MpPreference -EnableNetworkProtection <vorher>', expl: ['Set-MpPreference ändert eine Einstellung von Microsoft Defender.', '-EnableNetworkProtection Enabled schaltet den Schutz scharf.'] }),
    A('defender.asr-basis', 'Sicherheit', 'Defender: ASR-Regeln', 'ASR-Basisregeln aktivieren', 'Zwei Regeln gegen Treiber- und Anmeldedaten-Missbrauch.', 'mittel', 'gering', 'gering', { cmd: 'Add-MpPreference -AttackSurfaceReductionRules_Ids 56a863a9-875e-4185-98a7-b882c64b5ce5 -AttackSurfaceReductionRules_Actions <variante>', undo: 'Remove-MpPreference …', o: { varianten: ['Enabled', 'AuditMode'], zustand: { aktiv: false, wert: '0 Regeln', stand: iso(new Date()) } } }),
    A('fernzugriff.remoteunterstuetzung', 'Sicherheit', 'Remoteunterstützung', 'Remoteunterstützung ausschalten', 'Verhindert Fernhilfe-Einladungen.', 'gering', 'gering', 'gering', { cmd: 'Set-ItemProperty …', o: { zustand: { aktiv: true, wert: 'aus', stand: iso(new Date()) } } }),
    A('haertung.lsa', 'Sicherheit', 'LSA-Schutz', 'LSA-Schutz einschalten', 'Schützt gespeicherte Anmeldedaten im Arbeitsspeicher.', 'hoch', 'gering', 'gering', { cmd: 'New-ItemProperty -Path HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa -Name RunAsPPL -Value 1 -Force', o: { neustart: true } }),
    A('system.schnellstart', 'Leistung', 'Schnellstart', 'Schnellstart ausschalten', 'Windows fährt dann wirklich herunter.', 'mittel', 'gering', 'gering', { cmd: 'powercfg /hibernate off', undo: 'powercfg /hibernate on', expl: ['Schaltet Ruhezustand und Schnellstart ab.'], o: { zustand: { aktiv: false, wert: 'an', stand: iso(new Date()) } } }),
    A('energie.plan', 'Leistung', 'Energieplan', 'Energieplan wechseln', 'Wechselt zu einem vorhandenen Energiesparplan.', 'mittel', 'gering', 'gering', { cmd: 'powercfg /setactive <variante>', o: { varianten: ['Ausbalanciert', 'Höchstleistung', 'Gaming (dynamisch)'], zustand: { aktiv: false, wert: 'Ausbalanciert', stand: iso(new Date()) } } }),
    A('gaming.spielmodus', 'Gaming', 'Spielmodus', 'Spielmodus einschalten', 'Priorisiert Spiele.', 'mittel', 'gering', 'gering', { cmd: 'Set-ItemProperty …', o: { zustand: { aktiv: true, wert: 'an', stand: iso(new Date()) } } }),
    A('gaming.hags', 'Gaming', 'Hardwarebeschleunigte GPU-Planung (HAGS)', 'HAGS einschalten', 'Die Grafikkarte plant ihren Speicher selbst.', 'mittel', 'gering', 'mittel', { cmd: 'Set-ItemProperty -Path HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers -Name HwSchMode -Value 2', o: { neustart: true } }),
    A('gaming.maus', 'Gaming', 'Mausbeschleunigung', 'Mausbeschleunigung ausschalten', 'Gleichmäßigeres Zielen.', 'mittel', 'gering', 'gering', { cmd: 'Set-ItemProperty -Path "HKCU:\\Control Panel\\Mouse" -Name MouseSpeed -Value 0', o: { zustand: { aktiv: false, wert: 'an', stand: iso(new Date()) } } }),
  ];
  const journal = [
    // v2.4: Demo-Einträge der neuen Arten (17.6); neueste zuerst
    { id: '20261025-191502-01', zeit: '2026-10-25T19:15:02', art: 'update', aktion: 'Demo.Editor', titel: 'Update: Demo Editor 3.1.0 → 3.2.1', variante: 'Demo.Editor', vorher: null, nachher: null, wiederherstellungspunkt: { seq: 58, zeit: '2026-10-25T19:14:40' }, status: 'erledigt', bezug: null, meldung: 'Erfolgreich installiert.', benutzer: 'demo', befehl: 'winget upgrade --id Demo.Editor --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity', dauerSek: 41, exitCode: 0, umkehrbar: false, ohnePunkt: false },
    { id: '20261025-183011-01', zeit: '2026-10-25T18:30:11', art: 'wartung', aktion: 'dism.checkhealth', titel: 'Komponentenspeicher schnell prüfen', variante: null, vorher: null, nachher: null, wiederherstellungspunkt: null, status: 'erledigt', bezug: null, meldung: 'Keine Beschädigung im Komponentenspeicher gefunden.', benutzer: 'demo', befehl: 'C:\\WINDOWS\\system32\\Dism.exe /Online /Cleanup-Image /CheckHealth', dauerSek: 74, exitCode: 0, umkehrbar: false, ohnePunkt: false },
    { id: '20261024-190211-01', zeit: '2026-10-24T19:02:11', art: 'ausfuehren', aktion: 'netz.eee', titel: 'Energiesparfunktionen Netzwerkkarte aus', variante: null, vorher: 'an', nachher: 'aus', wiederherstellungspunkt: { seq: 56, zeit: '2026-10-24T19:02:00' }, status: 'erledigt', bezug: null, meldung: '', benutzer: 'demo' },
    { id: '20261024-110000-01', zeit: '2026-10-24T11:00:00', art: 'ausfuehren', aktion: 'gaming.gamedvr', titel: 'Game DVR aus (Zustand wurde danach geändert)', variante: null, vorher: 1, nachher: 0, wiederherstellungspunkt: { seq: 55, zeit: '2026-10-24T10:59:50' }, status: 'erledigt', bezug: null, meldung: '', benutzer: 'demo' },
  ];
  const session = { datenordner: null, version: '2.5.0', pc: 'DEMO-PC', admin: true, profil: 'Gaming', benutzer: 'demo',
    safety: { schutzAn: true, laufwerk: 'C:', sperre24h: true, letzterPunkt: '2026-10-25T12:02:11', befehl: "New-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore' -Name SystemRestorePointCreationFrequency -PropertyType DWord -Value 0 -Force" } };
  // v2.4 (#63): Demo-Schalter ?datenordner=1 (reparierbar, Nur-Lesen) bzw. ?datenordner=repariert (normal, Reparatur heute)
  const dMode = new URLSearchParams(location.search).get('datenordner');
  if (dMode === '1') {
    session.readOnly = true;
    session.readOnlyReason = 'Die Rechte des Datenordners wurden geändert.';
    session.datenordner = { zustand: 'reparierbar', konten: [{ sid: 'S-1-5-21-1-2-3-1001', name: 'DEMO-PC\\demo', rechte: 'schreiben' }], objekte: 42, pfad: 'C:\\ProgramData\\Morpheus', repariert: false };
    session.reparaturZeit = null;
  } else if (dMode === 'repariert') {
    // wie der Server: im normalen Modus kein datenordner-Objekt, reparaturZeit auf oberster Ebene
    session.datenordner = null;
    session.reparaturZeit = iso(new Date());
    journal.push({ id: '20260901-100000-01', zeit: '2026-09-01T10:00:00', art: 'ausfuehren', aktion: 'gaming.maus', titel: 'Mausbeschleunigung aus (vor der Reparatur)', variante: null, vorher: 'an', nachher: 'aus', wiederherstellungspunkt: { seq: 40, zeit: '2026-09-01T09:59:50' }, status: 'erledigt', bezug: null, meldung: '', benutzer: 'demo' });
  }
  function datenordnerReparieren(body) {
    const d = session.datenordner;
    if (!d || d.zustand !== 'reparierbar' || d.repariert[0]) return [409, { error: 'Der Datenordner lässt sich nicht reparieren (nicht reparierbar oder schon repariert).' }];
    if (body.art !== 'reparieren' && body.art !== 'neu') return [400, { error: 'Unbekannte Art.' }];
    d.repariert = [true];
    return [200, { ok: true, zustand: 'ok', meldung: body.art === 'neu' ? 'Der alte Ordner wurde beiseitegelegt und leer neu angelegt.' : 'Die Rechte wurden entfernt (42 Einträge).' }];
  }
  const help = { Status: { CRIT: 'Kritisch: echtes Risiko. Zuerst beheben.', WARN: 'Warnung: sollte behoben werden.', ACK: 'Akzeptiert: bewusst als gewollt eingetragen.', TIPP: 'Tipp: lohnende Verbesserung.', INFO: 'Hinweis: reine Information.', OK: 'OK: alles in Ordnung.', SKIP: 'Nicht geprüft.' },
    Kategorien: { Virenschutz: 'Microsoft Defender reicht für Privat-PCs, solange alle Schutzfunktionen an sind.', 'Gaming & Grafik': 'Einstellungen, die Bildraten und Frametimes beeinflussen.' },
    Pruefungen: { 'Defender: Einstellungen': { Was: 'Ob die Schutzfunktionen von Defender eingeschaltet sind.', Warum: 'Abgeschaltete Funktionen lassen Lücken.', Harmlos: 'Wenn ein anderes Virenprogramm aktiv ist.' } },
    // v2.4: Hilfetexte Wartung (17.8)
    Wartung: {
      'dism.checkhealth': { Was: 'Prüft den Komponentenspeicher schnell auf bekannte Beschädigungen. Ändert nichts.', Wann: 'Wenn Windows Fehler meldet, Updates scheitern oder Programme seltsam abbrechen.', Hinweis: 'Eine Momentaufnahme. Für eine gründliche Prüfung ist ScanHealth da.' },
      'dism.restorehealth': { Was: 'Repariert beschädigte Teile des Komponentenspeichers mit Dateien aus Windows Update.', Wann: 'Wenn die Prüfung Beschädigungen meldet, die SFC allein nicht beheben kann.', Hinweis: 'Braucht Internet. Nicht abbrechen. Vorher legt Morpheus einen Wiederherstellungspunkt an.' },
      'sfc.scannow': { Was: 'Prüft geschützte Systemdateien und repariert sie.', Wann: 'Nach einer DISM-Reparatur, wenn Windows-Dateien fehlen oder beschädigt sind.', Hinweis: 'Bei Problemen steht das Protokoll in %WinDir%\\Logs\\CBS\\CBS.log.' },
      trim: { Was: 'Gibt auf SSDs nicht mehr benötigten Speicher frei (ReTrim).', Wann: 'Ab und zu, etwa einmal im Monat; Windows erledigt das oft schon selbst.', Hinweis: 'Nur für SSDs. HDDs werden nicht angeboten.' },
    } };
  let checklist = { 'Offene Ports': { state: 'later', date: '24.10.2026', report: '2026-10-24T13:21:00' }, 'Software-Updates': { state: 'done', date: '25.10.2026', report: reps[0].json.Meta.Erstellt } };

  // ---- v2.2: Defender-Stand, Speicher-Cache, Offline-Zustand (Countdown)
  let defender = { modus: 'Normal', signaturen: '2026-10-22T06:10:00', signaturVersion: '1.421.118.0', signaturAlterTage: 3, schnellscan: '2026-10-06T03:12:00', schnellscanAlterTage: 19, echtzeit: true };
  let speicherCache = null;   // null = noch nie berechnet ({ stand: null })
  // ---- v2.2: eigene Spiele-Ordner (Vertrag 14.8)
  let spielordner = [{ plattform: 'Andere', pfad: 'G:\\Games' }];
  const PLATTFORMEN = ['Steam', 'Epic', 'GOG', 'EA', 'Ubisoft', 'Xbox', 'Andere'];
  const manuelleSpiele = () => spielordner.flatMap(e => [
    spl(e.plattform, 'Demo Spiel A', `${e.pfad}\\Demo Spiel A`, e.pfad.slice(0, 2).toUpperCase(), 12e9),
    spl(e.plattform, 'Demo Spiel B', `${e.pfad}\\Demo Spiel B`, e.pfad.slice(0, 2).toUpperCase(), 7e9)]);
  function spielordnerSpeichern(eintraege) {
    if (!Array.isArray(eintraege)) return [400, { error: 'eintraege muss eine Liste sein.' }];
    if (eintraege.length > 50) return [400, { error: 'Höchstens 50 Einträge.' }];
    for (let i = 0; i < eintraege.length; i++) {
      const { plattform, pfad } = eintraege[i] || {}, p = String(pfad || ''), n = `Eintrag ${i + 1} (${p})`;
      if (!PLATTFORMEN.includes(plattform)) return [400, { error: `${n}: unbekannte Plattform` }];
      if (!/^[A-Za-z]:\\/.test(p) || p.split(/[\\/]/).includes('..')) return [400, { error: `${n}: nur lokale Ordner wie F:\\Games` }];
      if (/^X:/i.test(p)) return [400, { error: `${n}: Ordner nicht gefunden` }];
    }
    const gesehen = new Set();
    spielordner = eintraege.filter(e => { const k = e.pfad.toLowerCase(); if (gesehen.has(k)) return false; gesehen.add(k); return true; })
      .map(({ plattform, pfad }) => ({ plattform, pfad }));
    return [200, spielordner];
  }
  let offline = { status: 'keiner', t0: 0, letzte: 0, meldung: '' };
  const OFF_SEK = 15;
  const OFF_MELDUNG_START = 'Demo: Hier würde der PC jetzt neu starten.';

  // ---- Jobs: jede Zeile erscheint 700 ms nach der vorigen
  const jobs = {}; let jobSeq = 0;
  const clock = () => { const d = new Date(); const p = n => String(n).padStart(2, '0'); return `[${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}]`; };
  function newJob(art, lines, finish) {
    const id = 'job' + (++jobSeq);
    jobs[id] = { art, t0: Date.now(), lines: lines.map(l => clock() + ' ' + l), step: 700, finish, done: false, ergebnis: null };
    return id;
  }
  function jobState(id, from) {
    const j = jobs[id]; if (!j) return [404, { error: 'Job unbekannt' }];
    const n = Math.min(j.lines.length, Math.floor((Date.now() - j.t0) / j.step));
    const finished = n >= j.lines.length;
    if (finished && !j.done) { j.done = true; j.ergebnis = j.finish(); }
    return [200, { id, art: j.art, status: finished ? 'done' : 'running', log: j.lines.slice(from, n), next: n, ergebnis: finished ? j.ergebnis : null }];
  }
  // Job mit dieser Art, der noch läuft (zeitbasiert, unabhängig davon, ob schon abgefragt wurde)
  const laufend = art => Object.keys(jobs).find(id => jobs[id].art === art && Date.now() - jobs[id].t0 < jobs[id].lines.length * jobs[id].step) || null;
  function runActions(ids, variante) {
    const sel = ids.map(i => actions.find(a => a.id === i));
    if (!sel.length || sel.some(a => !a)) return [400, { error: 'Unbekannte Aktion' }];
    if (Object.values(jobs).some(j => j.art === 'aendern' && !j.done)) return [409, { error: 'Es läuft bereits eine Änderung' }];
    const lines = ['Lese aktuellen Zustand …', 'Lege Wiederherstellungspunkt an …', 'Prüfe Wiederherstellungspunkt: vorhanden (#57)', 'Schreibe Journal-Eintrag …', ...sel.map(a => `Führe aus: ${a.titel}`), 'Prüfe Ergebnis …'];
    const id = newJob('aendern', lines, () => sel.map(a => {
      const vorher = a.zustand.wert; a.zustand = { aktiv: true, wert: variante || 'geändert', stand: iso(new Date()) };
      journal.unshift({ id: 'e' + Date.now() + a.id, zeit: iso(new Date()), art: 'ausfuehren', aktion: a.id, titel: a.titel, variante: variante || null, vorher, nachher: a.zustand.wert, wiederherstellungspunkt: { seq: 57, zeit: iso(new Date()) }, status: 'erledigt', bezug: null, meldung: '', benutzer: 'demo' });
      return { id: a.id, status: 'erledigt', vorher, nachher: a.zustand.wert, neustart: !!a.neustart, meldung: '' };
    }));
    return [200, { jobId: id }];
  }
  function undo(entryId, force, vorRep) {
    const e = journal.find(x => x.id === entryId);
    if (!e) return [404, { error: 'Eintrag unbekannt' }];
    if (e.art !== 'ausfuehren') return [400, { error: 'Für diesen Eintrag gibt es kein Rückgängig.' }];
    if (e.status !== 'erledigt') return [400, { error: 'Nicht rückgängig zu machen' }];
    if (session.reparaturZeit && e.zeit < session.reparaturZeit && !vorRep) return [409, { error: 'Der Eintrag liegt vor der Reparatur des Datenordners. Bestätigung nötig (vorReparatur).' }];
    if (e.titel.includes('geändert') && !force) return [409, { error: 'Der Zustand hat sich seit der Änderung geändert (aktuell ≠ gespeicherter Nachher-Zustand).' }];
    const id = newJob('aendern', ['Lese aktuellen Zustand …', 'Lege Wiederherstellungspunkt an …', 'Prüfe Wiederherstellungspunkt: vorhanden (#58)', 'Schreibe Journal-Eintrag …', 'Führe aus: Rückgängig', 'Prüfe Ergebnis …'], () => {
      e.status = 'zurueckgenommen';
      const a = actions.find(x => x.id === e.aktion); if (a) a.zustand = { aktiv: false, wert: String(e.vorher), stand: iso(new Date()) };
      journal.unshift({ id: 'u' + Date.now(), zeit: iso(new Date()), art: 'rueckgaengig', aktion: e.aktion, titel: e.titel, variante: null, vorher: e.nachher, nachher: e.vorher, wiederherstellungspunkt: { seq: 58, zeit: iso(new Date()) }, status: 'erledigt', bezug: e.id, meldung: '', benutzer: 'demo' });
      return { id: e.aktion, status: 'erledigt', vorher: e.nachher, nachher: e.vorher, neustart: false, meldung: '' };
    });
    return [200, { jobId: id }];
  }
  function scan(body) {
    if (laufend('sysinternals')) return [409, { error: 'Die Sysinternals-Werkzeuge werden gerade eingerichtet. Bitte warten, bis das fertig ist, und den Scan dann starten.' }];
    if (!(body.eventDays >= 1 && body.eventDays <= 90)) return [400, { error: 'Zeitraum ungültig' }];
    const speicherZeilen = body.skipSpeicher ? [] : ['[Performance] Laufwerke & Speicherplatz', '  - Größte Speicherverbraucher', 'C: wird gezählt …', 'F: wird gezählt …', 'D: wird gezählt …'];
    const lines = ['[Sicherheit] System & Updates', '  - Windows-Version', '  - Windows Update: ausstehend', '[Sicherheit] Virenschutz', '  - Defender: Einstellungen', '[Performance] Gaming & Grafik', '  - Resizable BAR und PCIe-Anbindung', ...speicherZeilen, `Profil: ${body.profil}, Zeitraum ${body.eventDays} Tage`, 'Schreibe Bericht …'];
    const id = newJob('scan', lines, () => {
      const d = new Date(), p = n => String(n).padStart(2, '0');
      const r = mkReport(0, { d, skip: !!body.skipSpeicher });
      r.name = `pc-check_${iso(d).slice(0, 10)}_${p(d.getHours())}${p(d.getMinutes())}`;
      r.json.Findings = r.json.Findings.filter(f => f.Check !== 'Offene Ports');
      if (body.skipSysinternals || !sysGeladen) {   // v2.3: Prüfungen übersprungen oder Werkzeuge fehlen
        r.json.Findings.forEach(f => { if (SYS_CHECKS.includes(f.Check)) { f.Status = 'SKIP'; f.Value = body.skipSysinternals ? 'Übersprungen (-SkipSysinternals)' : 'Sysinternals nicht eingerichtet: in Morpheus unter Werkzeuge herunterladen'; f.Recommendation = ''; } });
        delete r.json.Data['Autostarts (Autoruns, ohne Microsoft)']; delete r.json.DataChecks['Autostarts (Autoruns, ohne Microsoft)'];
      }
      reps.unshift(r); return { name: r.name };
    });
    return [200, { jobId: id }];
  }

  // ---- v2.2: Defender-Aktion (Signaturen / Schnellscan)
  function defenderRun(art) {
    if (art !== 'signaturen' && art !== 'schnellscan') return [400, { error: 'Unbekannte Art' }];
    if (laufend('defender')) return [409, { error: 'Es läuft bereits ein Defender-Vorgang' }];
    const lines = art === 'signaturen'
      ? ['Stand vorher wird gelesen …', 'Lade Signaturen herunter …', 'Installiere Signaturen …', 'Prüfe Ergebnis …']
      : ['Stand vorher wird gelesen …', 'Starte Schnellscan …', 'Schnellscan läuft: 25 %', 'Schnellscan läuft: 60 %', 'Schnellscan läuft: 90 %', 'Lese Funde …', 'Prüfe Ergebnis …'];
    const id = newJob('defender', lines, () => {
      const jetzt = iso(new Date()), vorher = { ...defender };
      let funde = [];
      if (art === 'signaturen') defender = { ...defender, signaturen: jetzt, signaturVersion: '1.421.140.0', signaturAlterTage: 0 };
      else {
        defender = { ...defender, schnellscan: jetzt, schnellscanAlterTage: 0 };
        funde = [{ zeit: jetzt, name: 'PUA:Win32/Demo.Toolbar', aktion: 'Quarantäne', erfolg: true, dateien: 'C:\\Users\\Demo\\Downloads\\demo-setup.exe' }];
      }
      const meldung = art === 'signaturen' ? 'Signaturen aktualisiert.'
        : funde.length ? 'Funde werden nur angezeigt. Quarantäne und Entfernen erledigt Windows-Sicherheit (Schutzverlauf).'
        : 'Schnellscan ohne Funde.';
      return { art, vorher, nachher: { ...defender }, funde, dauerSek: art === 'signaturen' ? 38 : 412, meldung };
    });
    return [200, { jobId: id }];
  }

  // ---- v2.3.1: Defender-Einzelscan und Akzeptanzliste (Vertrag 16.4). Zustand nur im Speicher.
  function defenderDatei(body) {
    const r = reps.find(x => x.name + '.json' === body.bericht);
    const z = r && (r.json.Data['Unsignierte Systemdateien (Sigcheck)'] || []).find(x => x.Pfad.toLowerCase() === String(body.pfad || '').toLowerCase());
    if (!z) return [404, { error: 'Datei steht nicht in der Sigcheck-Tabelle dieses Berichts' }];
    if (laufend('defender')) return [409, { error: 'Es läuft bereits ein Defender-Vorgang' }];
    const lines = ['Windows-Bestätigung erhalten', 'Prüfe Datei: ' + z.Pfad, 'Defender-Scan läuft …', 'Lese Funde seit Start …'];
    return [200, { jobId: newJob('defender', lines, () => ({ art: 'datei', pfad: z.Pfad, vorher: { ...defender }, nachher: { ...defender }, funde: /demoaudio/i.test(z.Pfad) ? [{ name: 'Trojan:Win32/Demo.A', zeit: iso(new Date(Date.now() - 864e5)), aktion: 'Quarantäne', erfolg: true, dateien: z.Pfad, frueher: true }] : [], dauerSek: 6, meldung: /demoaudio/i.test(z.Pfad) ? 'Der Fund wurde schon früher erkannt; Defender hat die Datei nicht erneut verändert.' : 'Datei ohne Funde geprüft.' })) }];
  }
  let akz = [
    { id: 'h3a91c07e5b2', check: 'BitLocker', match: '^Systemlaufwerk nicht verschlüsselt$', reason: 'Bewusst zurückgestellt', until: '2027-04-30', datei: '', sha256: '', erstellt: '', quelle: 'hand', abgelaufen: false },
    { id: '7be41d09', check: 'Systemdateien: Signaturen (Sigcheck)', match: '', reason: 'Bekannte Demo-Software, geprüft', until: '', datei: 'C:\\Windows\\System32\\demohelper.exe', sha256: 'a8f2c61d9e04b7a35c1f8e6d2b09a47e3c5d1f80b6a29e7d4c3b1058f6e2a9d4', erstellt: '2026-10-25T13:40:00', quelle: 'gui', abgelaufen: false },
  ];
  function akzNeu(b) {
    const r = reps.find(x => x.name + '.json' === b.bericht);
    if (!r) return [404, { error: 'Bericht nicht gefunden' }];
    const g = String(b.begruendung || '');
    if (/[\x00-\x1f\x7f]/.test(g) || g.trim().length < 3 || g.trim().length > 300) return [400, { error: 'Die Begründung muss 3 bis 300 Zeichen lang sein, ohne Zeilenumbrüche oder Steuerzeichen.' }];
    if (b.bis) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(b.bis) || isNaN(Date.parse(b.bis))) return [400, { error: 'Ungültiges Datum.' }];
      const heute = new Date(); heute.setHours(0, 0, 0, 0); const max = new Date(heute); max.setFullYear(max.getFullYear() + 5);
      const d = new Date(b.bis + 'T00:00:00');
      if (d < heute) return [400, { error: 'Das Datum liegt in der Vergangenheit.' }];
      if (d > max) return [400, { error: 'Das Datum liegt mehr als 5 Jahre in der Zukunft.' }];
    }
    const id = Math.random().toString(16).slice(2, 10).padEnd(8, '0');
    if (b.art === 'datei') {
      const z = (r.json.Data['Unsignierte Systemdateien (Sigcheck)'] || []).find(x => x.Pfad === b.pfad);
      if (!z) return [404, { error: 'Datei steht nicht in der Sigcheck-Tabelle dieses Berichts' }];
      if (akz.some(x => x.check === 'Systemdateien: Signaturen (Sigcheck)' && (x.datei || '').toLowerCase() === z.Pfad.toLowerCase() && x.sha256 === z.Sha256)) return [409, { error: 'Das ist bereits akzeptiert.' }];
      akz.push({ id, check: 'Systemdateien: Signaturen (Sigcheck)', match: '', reason: g, until: b.bis || '', datei: z.Pfad, sha256: z.Sha256, erstellt: iso(new Date()), quelle: 'gui', abgelaufen: false });
    } else if (b.art === 'befund') {
      const f = r.json.Findings.find(x => x.Check === b.check);
      if (!f) return [404, { error: 'Diesen Befund gibt es im Bericht nicht.' }];
      if (!['CRIT', 'WARN', 'TIPP', 'INFO'].includes(f.Status) || f.Check === 'Systemdateien: Signaturen (Sigcheck)') return [400, { error: 'Dieser Befund kann nicht akzeptiert werden.' }];
      const mt = '^' + f.Value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$';
      if (akz.some(x => x.check === f.Check && x.match === mt)) return [409, { error: 'Das ist bereits akzeptiert.' }];
      akz.push({ id, check: f.Check, match: mt, reason: g, until: b.bis || '', datei: '', sha256: '', erstellt: iso(new Date()), quelle: 'gui', abgelaufen: false });
    } else return [400, { error: 'Unbekannte Art' }];
    return [200, { regel: akz[akz.length - 1], regeln: akz.map(x => ({ ...x })) }];
  }

  // ---- v2.3: Sysinternals (Vertrag 15.6). Zustand nur im Speicher; anfangs nicht eingerichtet.
  const SYS_DEF = [
    { name: 'autorunsc', titel: 'Autoruns', datei: 'autorunsc64.exe', version: '14.11', sha256: '3f1a0c9e5b7d42a8c6e0b1d9f4a27c58e1b3d6a09f8c47e2b5d1a0c3e6f98b74' },
    { name: 'sigcheck', titel: 'Sigcheck', datei: 'sigcheck64.exe', version: '2.90', sha256: '9b2e7d41c0a85f36e1d4b79a2c8f05e3d6a1b4c7f90e2d58a3b6c1f4e7d0a925' }];
  const SYS_ORDNER = 'C:\\ProgramData\\Morpheus\\tools';
  let sysZustimmung = null;   // { akzeptiert, zeit, benutzer } nach dem Herunterladen
  let sysGeladen = null;      // ISO-Zeit, solange eingerichtet
  const sysStand = () => ({
    zustimmung: sysZustimmung ? { akzeptiert: true, zeit: sysZustimmung.zeit, benutzer: sysZustimmung.benutzer } : { akzeptiert: false, zeit: null, benutzer: null },
    werkzeuge: SYS_DEF.map(w => sysGeladen
      ? { name: w.name, titel: w.titel, datei: w.datei, pfad: SYS_ORDNER + '\\' + w.datei, vorhanden: true, geprueft: true, grund: null, signierer: 'Microsoft Corporation', version: w.version, sha256: w.sha256, geladen: sysGeladen }
      : { name: w.name, titel: w.titel, datei: w.datei, pfad: SYS_ORDNER + '\\' + w.datei, vorhanden: false, geprueft: false, grund: 'Nicht eingerichtet: Datei fehlt.', signierer: null, version: null, sha256: null, geladen: null }),
    ordner: SYS_ORDNER, lizenzUrl: 'https://learn.microsoft.com/sysinternals/license-terms' });
  function sysInstall(body) {
    if (body.eulaAkzeptiert !== true) return [400, { error: 'Die Lizenzbedingungen müssen ausdrücklich angenommen werden.' }];
    if (laufend('sysinternals')) return [409, { error: 'Es läuft schon ein Sysinternals-Vorgang.' }];
    const lines = ['Autoruns.zip wird geladen …', 'Autoruns.zip: 1,1 MB geladen', 'ZIP-Einträge werden geprüft …', 'autorunsc64.exe entpackt', 'Signatur geprüft: Microsoft Corporation', 'Sigcheck.zip wird geladen …', 'Sigcheck.zip: 0,9 MB geladen', 'sigcheck64.exe entpackt', 'Signatur geprüft: Microsoft Corporation', 'Lizenztexte abgelegt, Reste gelöscht'];
    if (laufend('scan')) return [409, { error: 'Während eines Scans nicht möglich. Bitte warten, bis der Scan fertig ist.' }];
    sysZustimmung = { zeit: iso(new Date()), benutzer: 'Demo' };   // wie der Server: Zustimmung schon beim Job-Start
    const id = newJob('sysinternals', lines, () => {
      const jetzt = iso(new Date());
      sysGeladen = jetzt;
      return { werkzeuge: sysStand().werkzeuge, meldung: 'Autoruns und Sigcheck sind eingerichtet. Beide sind von Microsoft signiert.' };
    });
    return [200, { jobId: id }];
  }
  function sysEntfernen() {
    if (laufend('sysinternals')) return [409, { error: 'Es läuft schon ein Sysinternals-Vorgang.' }];
    if (laufend('scan')) return [409, { error: 'Während eines Scans nicht möglich. Bitte warten, bis der Scan fertig ist.' }];
    sysZustimmung = null; sysGeladen = null;
    return [200, sysStand()];
  }

  // ---- v2.4: Wartung & Reparatur (Vertrag 17.3, 17.5, 17.6) und Update-Dialog (17.5). Zustand nur im Speicher; echte Werkzeuge laufen nie.
  const wartungEintrag = o => ({ parameter: null, internet: false, hinweis: null, ...o, punkt: o.klasse === 'reparatur', bericht: o.id.startsWith('powercfg.') });
  const wartungWerkzeuge = [
    wartungEintrag({ id: 'wiederherstellung.punkt', gruppe: 'Wiederherstellung', schritt: 1, klasse: 'wartung', titel: 'Wiederherstellungspunkt jetzt anlegen', erklaerung: 'Legt von Hand einen Wiederherstellungspunkt an, ohne etwas zu reparieren.', befehl: "Checkpoint-Computer -Description 'Morpheus: von Hand angelegt' -RestorePointType MODIFY_SETTINGS", dauer: 'etwa 1 Minute', abbruch: 'nein', hinweis: 'Windows legt höchstens alle 24 Stunden einen Punkt an. Ist die Sperre aktiv, passiert nichts.' }),
    wartungEintrag({ id: 'dism.checkhealth', gruppe: 'Systemdateien', schritt: 1, klasse: 'diagnose', titel: 'Komponentenspeicher schnell prüfen', erklaerung: 'Prüft, ob DISM eine Beschädigung vermerkt hat. Liest nur und ändert nichts.', befehl: 'DISM.exe /Online /Cleanup-Image /CheckHealth', dauer: '1–5 Minuten', abbruch: 'sofort' }),
    wartungEintrag({ id: 'dism.scanhealth', gruppe: 'Systemdateien', schritt: 2, klasse: 'diagnose', titel: 'Komponentenspeicher gründlich prüfen', erklaerung: 'Durchsucht den Komponentenspeicher vollständig. Dauert länger, ändert aber nichts.', befehl: 'DISM.exe /Online /Cleanup-Image /ScanHealth', dauer: '5–20 Minuten', abbruch: 'sofort' }),
    wartungEintrag({ id: 'dism.restorehealth', gruppe: 'Systemdateien', schritt: 3, klasse: 'reparatur', titel: 'Komponentenspeicher reparieren', erklaerung: 'Repariert beschädigte Teile des Komponentenspeichers mit Dateien aus Windows Update.', befehl: 'DISM.exe /Online /Cleanup-Image /RestoreHealth', dauer: '5–30 Minuten', abbruch: 'nein', internet: true, hinweis: 'Nicht abbrechen: Microsoft rät davon ab, die Reparatur zu unterbrechen.' }),
    wartungEintrag({ id: 'sfc.scannow', gruppe: 'Systemdateien', schritt: 4, klasse: 'reparatur', titel: 'Systemdateien prüfen und reparieren (SFC)', erklaerung: 'Prüft geschützte Systemdateien und repariert sie aus dem Komponentenspeicher.', befehl: 'sfc.exe /scannow', dauer: '10–20 Minuten', abbruch: 'nein', hinweis: 'Am besten nach DISM RestoreHealth ausführen.' }),
    wartungEintrag({ id: 'dism.analyze', gruppe: 'Komponentenspeicher', schritt: 1, klasse: 'diagnose', titel: 'Größe des Komponentenspeichers ansehen', erklaerung: 'Zeigt, wie groß WinSxS ist und ob eine Bereinigung sinnvoll wäre. Ändert nichts.', befehl: 'DISM.exe /Online /Cleanup-Image /AnalyzeComponentStore', dauer: '2–10 Minuten', abbruch: 'sofort' }),
    wartungEintrag({ id: 'dism.cleanup', gruppe: 'Komponentenspeicher', schritt: 2, klasse: 'reparatur', titel: 'Komponentenspeicher aufräumen', erklaerung: 'Entfernt überholte Komponentenversionen. Morpheus verwendet kein /ResetBase.', befehl: 'DISM.exe /Online /Cleanup-Image /StartComponentCleanup', dauer: '5–30 Minuten', abbruch: 'nein', hinweis: 'WinSxS nie von Hand löschen.' }),
    wartungEintrag({ id: 'chkdsk.scan', gruppe: 'Diagnose', schritt: 1, klasse: 'diagnose', titel: 'Laufwerk auf Fehler prüfen (nur lesen)', erklaerung: 'Prüft das gewählte Laufwerk, ohne etwas zu reparieren.', befehl: 'chkdsk.exe <LW> /scan', dauer: '5–60 Minuten', abbruch: 'sofort', parameter: 'laufwerk' }),
    wartungEintrag({ id: 'perfmon.rel', gruppe: 'Diagnose', schritt: 2, klasse: 'diagnose', titel: 'Zuverlässigkeitsverlauf öffnen', erklaerung: 'Zeigt Abstürze, Fehler und Updates der letzten Wochen als Verlauf.', befehl: 'perfmon /rel', dauer: 'sofort', abbruch: 'nein', hinweis: 'Öffnet sich ohne Adminrechte. Klappt das nicht: Win + R, perfmon /rel.' }),
    wartungEintrag({ id: 'dns.flush', gruppe: 'Wartung', schritt: 1, klasse: 'wartung', titel: 'DNS-Cache leeren', erklaerung: 'Leert den lokalen Namens-Cache. Hilft bei Verbindungsproblemen zu Webseiten.', befehl: 'ipconfig.exe /flushdns', dauer: 'wenige Sekunden', abbruch: 'nein' }),
    wartungEintrag({ id: 'trim', gruppe: 'Wartung', schritt: 2, klasse: 'wartung', titel: 'SSD optimieren (ReTrim)', erklaerung: 'Gibt auf SSDs nicht mehr benötigte Blöcke frei. Angeboten werden nur SSDs.', befehl: 'defrag.exe <LW> /L', dauer: '1–10 Minuten', abbruch: 'sofort', parameter: 'ssd' }),
    wartungEintrag({ id: 'zeit.resync', gruppe: 'Wartung', schritt: 3, klasse: 'wartung', titel: 'Systemzeit abgleichen', erklaerung: 'Gleicht die Uhr mit dem Zeitserver ab, damit Anmeldungen und Zertifikate stimmen.', befehl: 'w32tm.exe /resync', dauer: 'etwa 1 Minute', abbruch: 'nein' }),
    wartungEintrag({ id: 'powercfg.energy', gruppe: 'Energieberichte', schritt: 1, klasse: 'diagnose', titel: 'Energiebericht erstellen', erklaerung: 'Misst 60 Sekunden lang den Energieverbrauch und sucht nach Problemen. Der Bericht landet in der Berichtsliste.', befehl: 'powercfg.exe /energy /output <Bericht> /duration 60', dauer: '1–4 Minuten', abbruch: 'sofort' }),
    wartungEintrag({ id: 'powercfg.akku', gruppe: 'Energieberichte', schritt: 2, klasse: 'diagnose', titel: 'Akkubericht erstellen', erklaerung: 'Zeigt Kapazität und Alterung des Akkus. Nur auf Notebooks.', befehl: 'powercfg.exe /batteryreport /output <Bericht>', dauer: 'etwa 2 Minuten', abbruch: 'nein' }),
    wartungEintrag({ id: 'powercfg.schlaf', gruppe: 'Energieberichte', schritt: 3, klasse: 'diagnose', titel: 'Schlafstudie erstellen', erklaerung: 'Zeigt, wie der PC geschlafen hat. Gibt es nur mit Modern Standby.', befehl: 'powercfg.exe /sleepstudy /output <Bericht>', dauer: 'etwa 2 Minuten', abbruch: 'nein' }),
    wartungEintrag({ id: 'winget.upgrade', gruppe: 'Programme', schritt: 1, klasse: 'reparatur', titel: 'Programme aktualisieren (winget)', erklaerung: 'Aktualisiert ausgewählte Programme über winget. Startet über den Dialog „Programme aktualisieren“. winget läuft ohne Adminrechte; braucht ein Programm Adminrechte, fragt Windows selbst nach.', befehl: 'winget upgrade --id <Paket-Id> --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity', dauer: '1–10 Minuten je Programm', abbruch: 'nach-paket', parameter: 'ids', internet: true, hinweis: 'Programme vorher schließen. Fragt Windows nach Adminrechten, den angezeigten Herausgeber prüfen.' }),
  ];
  const WART_LAUFWERKE = [{ laufwerk: 'C:', bezeichnung: 'System', ssd: true }, { laufwerk: 'F:', bezeichnung: 'Spiele', ssd: true }, { laufwerk: 'D:', bezeichnung: 'Daten', ssd: false }];
  const WART_PFAD = 'C:\\WINDOWS\\system32\\';
  const WART_DISM = WART_PFAD + 'Dism.exe /Online /Cleanup-Image';
  const WART_BERICHT_ART = { 'powercfg.energy': 'energy', 'powercfg.akku': 'akku', 'powercfg.schlaf': 'schlaf' };
  const WART_BERICHT = { energy: 'Energiebericht', akku: 'Akkubericht', schlaf: 'Schlafstudie' };
  const DISM_KOPF = ['Bereitstellungs-Image-Wartungs- und -Verwaltungstool', 'Version: 10.0.26100.1', '', 'Abbildversion: 10.0.26100.1', ''];
  const DISM_FORTSCHRITT = ['[==========                 20.0%                          ]', '[===================        60.0%                          ]', '[==========================100.0%==========================]'];
  const WINGET_BEFEHL = id => `C:\\Program Files\\WindowsApps\\Microsoft.DesktopAppInstaller_Demo\\winget.exe upgrade --id ${id} --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity`;
  const wartungBerichte = [{ name: 'morpheus-energy_2026-10-25_201500.html', art: 'energy', titel: 'Energiebericht', zeit: '2026-10-25T20:15:00' }];
  const punktFehlt = new Set();
  let punktDemo = true;   // der erste dism.restorehealth-Start ohne ohnePunkt endet mit „punkt-fehlt“
  let updates = { stand: null, liste: [], fehler: null };

  // Demo-Ausgabe je Werkzeug (nach „Starte: …“): Zeilen, Ergebnis (17.6 zusammenfassung), Exit-Code, ob ein Bericht entsteht
  function wartungLauf(id, lw, pfad) {
    const z = (ergebnis, text, empfehlung = null, details = []) => ({ ergebnis, text, empfehlung, details });
    const dism = (flag, zeilen, ergebnis) => ({ start: `${WART_DISM} ${flag}`, zeilen: [...DISM_KOPF, ...DISM_FORTSCHRITT, ...zeilen, 'Der Vorgang wurde erfolgreich beendet.'], z: ergebnis, exit: 0, berichtOk: false });
    const kurz = (start, zeilen, ergebnis, exit = 0, berichtOk = false) => ({ start, zeilen, z: ergebnis, exit, berichtOk });
    switch (id) {
      case 'wiederherstellung.punkt': return kurz("Checkpoint-Computer -Description 'Morpheus: von Hand angelegt' -RestorePointType MODIFY_SETTINGS", ['Windows legt den Wiederherstellungspunkt an …', 'Wiederherstellungspunkt #59 angelegt.'], z('ok', 'Wiederherstellungspunkt #59 angelegt.'));
      case 'dism.checkhealth': return dism('/CheckHealth', ['Es wurde keine Komponentenspeicherbeschädigung erkannt.'], z('ok', 'Keine Beschädigung im Komponentenspeicher gefunden.'));
      case 'dism.scanhealth': return dism('/ScanHealth', ['Der Komponentenspeicher kann repariert werden.'], z('reparierbar', 'Der Komponentenspeicher ist beschädigt, kann aber repariert werden.', 'DISM RestoreHealth, danach SFC'));
      case 'dism.restorehealth': return dism('/RestoreHealth', ['Die Wiederherstellung wurde abgeschlossen.'], z('repariert', 'Beschädigungen im Komponentenspeicher wurden repariert.', 'SFC ausführen, um die Systemdateien zu prüfen', ['Quelldateien aus Windows Update geladen']));
      case 'dism.analyze': return dism('/AnalyzeComponentStore', ['Größe des Komponentenspeichers: 7,42 GB', 'Anzahl der Pakete: 3412', 'Ersetzte Komponenten: 128', 'Freigebbarer Speicherplatz: 1,12 GB', 'Bereinigung empfohlen: Ja'], z('reparierbar', 'Bereinigung empfohlen: etwa 1,12 GB sind freigebbar.', 'StartComponentCleanup ausführen', ['Größe: 7,42 GB', 'Pakete: 3412', 'Bereinigung empfohlen: Ja']));
      case 'dism.cleanup': return dism('/StartComponentCleanup', ['Überholte Komponenten werden entfernt.'], z('ok', 'Überholte Komponenten wurden entfernt.'));
      case 'sfc.scannow': return kurz(WART_PFAD + 'sfc.exe /scannow', ['Die Überprüfung wird gestartet.', 'Überprüfung 45 % abgeschlossen.', 'Überprüfung 100 % abgeschlossen.', 'Windows-Ressourcenschutz hat beschädigte Dateien gefunden und erfolgreich repariert.'], z('repariert', 'Beschädigte Systemdateien wurden repariert.', null, ['Protokoll: %WinDir%\\Logs\\CBS\\CBS.log']));
      case 'chkdsk.scan': return kurz(WART_PFAD + 'chkdsk.exe ' + lw + ' /scan', ['Stufe 1: Dateisystem wird geprüft, 30 Prozent', 'Stufe 2: Indizes werden geprüft, 100 Prozent', 'Windows hat den Scan abgeschlossen. Es wurden keine Probleme gefunden.'], z('ok', 'Keine Probleme gefunden.'));
      case 'dns.flush': return kurz(WART_PFAD + 'ipconfig.exe /flushdns', ['Der DNS-Auflösungscache wurde erfolgreich geleert.'], z('ok', 'DNS-Cache geleert.'));
      case 'trim': return kurz(WART_PFAD + 'defrag.exe ' + lw + ' /L', [`Retrim auf ${lw}: 30 % abgeschlossen`, `Retrim auf ${lw}: 100 % abgeschlossen`], z('ok', `Retrim auf ${lw} abgeschlossen.`));
      case 'zeit.resync': return kurz(WART_PFAD + 'w32tm.exe /resync', ['Sende Anforderung an den Zeitserver …', 'Die Uhr wurde erfolgreich mit dem Zeitserver synchronisiert.'], z('ok', 'Systemzeit synchronisiert.'));
      case 'powercfg.energy': return kurz(`${WART_PFAD}powercfg.exe /energy /output "${pfad}" /duration 60`, ['Energieverfolgung läuft 60 Sekunden …', 'Energie-Ereignisse werden analysiert …', 'Bericht gespeichert.'], z('ok', 'Energiebericht erstellt: 0 Fehler, 2 Warnungen.', null, ['Fehler: 0', 'Warnungen: 2']), 0, true);
      case 'powercfg.akku': return kurz(`${WART_PFAD}powercfg.exe /batteryreport /output "${pfad}"`, ['Akkubericht wird erstellt …', 'Bericht gespeichert.'], z('ok', 'Akku: 48.200 von 52.000 mWh volle Kapazität (93 %).'), 0, true);
      case 'powercfg.schlaf': return kurz(`${WART_PFAD}powercfg.exe /sleepstudy /output "${pfad}"`, ['Schlafstudie wird erstellt …', 'Dieser PC unterstützt keinen Modern Standby.', 'Die Schlafstudie wurde nicht erstellt.'], z('problem', 'Dieser PC unterstützt keinen Modern Standby, daher gibt es keine Schlafstudie.', 'Das ist kein Fehler dieses Werkzeugs; der Bericht gibt es nur mit Modern Standby.'), 1, false);
      default: return null;
    }
  }

  // Journal-Eintrag vorne (17.6)
  function wartungJournal(o) {
    const e = { id: 'w' + Date.now() + o.aktion, zeit: o.zeit, art: o.art, aktion: o.aktion, titel: o.titel, variante: o.variante ?? null, vorher: null, nachher: null, wiederherstellungspunkt: o.punkt ?? null, status: o.status, bezug: null, meldung: String(o.meldung || '').slice(0, 500), benutzer: 'demo', befehl: o.befehl ?? null, dauerSek: o.dauer ?? null, exitCode: o.exit ?? null, umkehrbar: false, ohnePunkt: !!o.ohne };
    journal.unshift(e);
    return e.id;
  }
  // winget-Paket: ein Journal-Eintrag je Paket (17.6)
  function updateJournal(p, punkt, ohne) {
    const status = { aktualisiert: 'erledigt', abgebrochen: 'abgebrochen' }[p.status] || 'fehlgeschlagen';
    return wartungJournal({ art: 'update', aktion: p.id, titel: `Update: ${p.name} ${p.von} → ${p.auf}`, zeit: iso(new Date()), status, meldung: p.text, variante: p.id, punkt, ohne, befehl: WINGET_BEFEHL(p.id), dauer: p.dauerSek, exit: p.exitCode });
  }

  // Start ohne Wiederherstellungspunkt: der Punkt fehlt (24-h-Sperre). Nichts startet; das Werkzeug wird gemerkt.
  function wartungPunktFehlt(w) {
    punktFehlt.add(w.id);
    const jid = newJob('wartung', [`Lege Wiederherstellungspunkt an: Morpheus: vor ${w.titel}`, 'Windows hat keinen neuen Punkt angelegt. Nichts gestartet.'], () => ({
      werkzeug: w.id, titel: w.titel, klasse: w.klasse, status: 'punkt-fehlt', befehl: null, laufwerk: null, exitCode: null, dauerSek: 0, zusammenfassung: null, punkt: null, ohnePunkt: false, bericht: null, journal: null,
      meldung: `Kein neuer Wiederherstellungspunkt möglich: Windows legt nur alle 24 Stunden einen an (24-Stunden-Sperre). Ohne Punkt startet Morpheus nichts. Sperre aufheben (PowerShell als Administrator): ${session.safety.befehl}` }));
    Object.assign(jobs[jid], { werkzeug: w.id, abbruch: 'nein' });
    return [200, { jobId: jid }];
  }

  function wartungStart(body) {
    const w = wartungWerkzeuge.find(x => x.id === body.werkzeug);
    if (!w) return [400, { error: 'Unbekanntes Werkzeug.' }];
    if (w.id === 'winget.upgrade') return [400, { error: 'Programme werden über „Programme aktualisieren“ gestartet.' }];
    if (w.id === 'perfmon.rel') return [400, { error: 'Der Zuverlässigkeitsverlauf öffnet sich über seinen eigenen Knopf.' }];
    let lw = null;
    if (w.parameter) {
      const l = WART_LAUFWERKE.find(x => x.laufwerk === body.laufwerk);
      if (!l) return [400, { error: 'Bitte ein Laufwerk aus der Liste wählen.' }];
      if (w.parameter === 'ssd' && !l.ssd) return [400, { error: 'Dieses Werkzeug läuft nur auf SSDs.' }];
      lw = l.laufwerk;
    } else if (body.laufwerk) return [400, { error: 'Für dieses Werkzeug ist kein Laufwerk erlaubt.' }];
    if (laufend('wartung')) return [409, { error: 'Es läuft schon eine Wartung. Bitte warten, bis sie fertig ist.' }];
    const ohne = body.ohnePunkt === true;
    if (ohne && !(w.punkt && punktFehlt.has(w.id))) return [400, { error: 'Ohne Wiederherstellungspunkt ist das nur nach einem Start mit „punkt-fehlt“ erlaubt.' }];
    if (w.id === 'dism.restorehealth' && punktDemo && !ohne) { punktDemo = false; return wartungPunktFehlt(w); }
    if (ohne) punktFehlt.delete(w.id);

    const d = new Date(), p = n => String(n).padStart(2, '0');
    const hms = `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
    const art = WART_BERICHT_ART[w.id];
    const name = art ? `morpheus-${art}_${iso(d).slice(0, 10)}_${hms.replace(/:/g, '')}.html` : null;
    const lauf = wartungLauf(w.id, lw, name && 'C:\\ProgramData\\Morpheus\\reports\\' + name);
    const punkt = w.punkt && !ohne;
    const punktObj = w.id === 'wiederherstellung.punkt' ? { seq: 59, zeit: iso(d) } : punkt ? { seq: 58, zeit: iso(d) } : null;
    const bericht = name && lauf.berichtOk ? name : null;
    const zeilen = [];
    if (punkt) zeilen.push(`Lege Wiederherstellungspunkt an: Morpheus: vor ${w.titel}`, `Wiederherstellungspunkt #58 geprüft (${hms}).`);
    else if (ohne) zeilen.push('Ohne Wiederherstellungspunkt: bewusst bestätigt.');
    zeilen.push(`Starte: ${lauf.start}`, ...lauf.zeilen, `Ergebnis: ${lauf.z.text}`);
    const dauerSek = Math.max(1, Math.round(zeilen.length * 0.7));
    const jid = newJob('wartung', zeilen, () => {
      if (bericht) wartungBerichte.unshift({ name: bericht, art, titel: WART_BERICHT[art], zeit: iso(new Date()) });
      const status = lauf.z.ergebnis === 'fehler' ? 'fehlgeschlagen' : 'erledigt';
      const ergebnis = { werkzeug: w.id, titel: w.titel, klasse: w.klasse, status, befehl: lauf.start, laufwerk: lw, exitCode: lauf.exit, dauerSek, zusammenfassung: lauf.z, punkt: punktObj, ohnePunkt: ohne, meldung: lauf.z.text, bericht, journal: null };
      ergebnis.journal = wartungJournal({ art: 'wartung', aktion: w.id, titel: w.titel, zeit: iso(new Date()), status, meldung: lauf.z.text, variante: lw, punkt: punktObj, ohne, befehl: lauf.start, dauer: dauerSek, exit: lauf.exit });
      return ergebnis;
    });
    Object.assign(jobs[jid], { werkzeug: w.id, abbruch: w.abbruch, laufwerk: lw, punkt: punktObj, ohne });
    return [200, { jobId: jid }];
  }

  // Abbruch: „sofort“ stoppt beim aktuellen Stand, „nach-paket“ nach dem laufenden winget-Paket. „nein“ wird abgelehnt.
  function wartungAbbrechen(jobId) {
    const j = jobs[jobId];
    if (!j || laufend('wartung') !== jobId) return [409, { error: 'Kein laufender Wartungslauf mit dieser Id.' }];
    if (!j.abbruch || j.abbruch === 'nein') return [409, { error: 'Dieser Lauf lässt sich nicht abbrechen.' }];
    const n = Math.min(j.lines.length, Math.floor((Date.now() - j.t0) / j.step));
    const plan = j.paketPlan || [];
    const m = j.abbruch === 'nach-paket' ? (plan.map(x => x.ende).find(e => e >= n) ?? j.lines.length) : n;
    j.lines = j.lines.slice(0, m);
    j.finish = () => {
      const dauerSek = Math.round((Date.now() - j.t0) / 1000);
      if (!plan.length) {
        const w = wartungWerkzeuge.find(x => x.id === j.werkzeug);
        const jid = wartungJournal({ art: 'wartung', aktion: w.id, titel: w.titel, zeit: iso(new Date()), status: 'abgebrochen', meldung: 'Vom Benutzer abgebrochen.', variante: j.laufwerk, punkt: j.punkt, ohne: j.ohne, dauer: dauerSek });
        return { werkzeug: w.id, titel: w.titel, klasse: w.klasse, status: 'abgebrochen', befehl: null, laufwerk: j.laufwerk ?? null, exitCode: null, dauerSek, zusammenfassung: { ergebnis: 'unbekannt', text: 'Abgebrochen. Der Zustand ist unklar; Details stehen im Protokoll.', empfehlung: null, details: [] }, punkt: j.punkt, ohnePunkt: j.ohne, meldung: 'Vom Benutzer abgebrochen.', bericht: null, journal: jid };
      }
      const pakete = plan.map(x => x.ende <= m ? x.paket : { ...x.paket, status: 'abgebrochen', exitCode: null, dauerSek: 0, text: 'Nicht mehr gestartet.' });
      plan.filter(x => x.ende <= m).forEach(x => updateJournal(x.paket, j.punkt, j.ohne));
      updates.liste = updates.liste.filter(u => !pakete.some(p => p.id === u.id && p.status === 'aktualisiert'));
      return { werkzeug: 'winget.upgrade', titel: 'Programme aktualisieren (winget)', klasse: 'reparatur', status: 'abgebrochen', befehl: null, laufwerk: null, exitCode: null, dauerSek, zusammenfassung: { ergebnis: 'unbekannt', text: 'Nach dem aktuellen Programm abgebrochen.', empfehlung: 'Nicht fertige Programme erneut auswählen.', details: [] }, punkt: j.punkt, ohnePunkt: j.ohne, meldung: 'Vom Benutzer abgebrochen.', bericht: null, journal: null, pakete };
    };
    return [200, { ok: true, meldung: 'Abbruch angefordert.' }];
  }

  const wartungLaeuftId = () => { const id = laufend('wartung'); return id ? jobs[id].werkzeug : null; };
  const wingetLaeuft = () => { const id = laufend('wartung'); return id && jobs[id].werkzeug === 'winget.upgrade' ? id : null; };
  let punktIdsWinget = null;   // Id-Menge des Laufs, der mit punkt-fehlt endete (ohnePunkt verlangt genau dieselbe)
  let punktDemoWinget = true;
  const wartungLaufendInfo =() => { const id = laufend('wartung'); return id ? { jobId: id, werkzeug: jobs[id].werkzeug, abbruch: jobs[id].abbruch } : null; };

  // Update-Dialog: Suche und Installation (Demo)
  function updatesSuchen() {
    const alt = laufend('updatesuche');
    if (alt) return [200, { jobId: alt }];
    const jid = newJob('updatesuche', ['winget sucht nach Updates …', '5 Updates gefunden'], () => {
      updates = { stand: iso(new Date()), fehler: null, liste: [
        { id: 'Demo.Editor', name: 'Demo Editor', installiert: '3.1.0', verfuegbar: '3.2.1', kategorie: 'Programm' },
        { id: 'Demo.Player', name: 'Demo Player', installiert: '1.0.4', verfuegbar: '1.1.0', kategorie: 'Programm' },
        { id: 'Valve.Steam', name: 'Steam', installiert: '2.10', verfuegbar: '2.11', kategorie: 'Spiel/Launcher' },
        { id: 'Contoso.LangerName.Install…', name: 'Contoso Langer Name', installiert: '4.0', verfuegbar: '4.1', kategorie: 'Id gekürzt' },
        { id: 'Microsoft.Edge', name: 'Microsoft Edge', installiert: '130.0', verfuegbar: '131.0', kategorie: 'aktualisiert sich selbst' }] };
      return { ...updates };
    });
    return [200, { jobId: jid }];
  }
  // Demo: die erste Installation von „Demo.Player“ allein endet mit punkt-fehlt (nichts gestartet)
  function wingetPunktFehlt(ids) {
    punktDemoWinget = false; punktIdsWinget = [...ids]; punktFehlt.add('winget.upgrade');
    const jid = newJob('wartung', ['Lege Wiederherstellungspunkt an: Morpheus: vor Programm-Updates', 'Windows hat keinen neuen Punkt angelegt. Nichts gestartet.'], () => ({
      werkzeug: 'winget.upgrade', titel: 'Programme aktualisieren (winget)', klasse: 'reparatur', status: 'punkt-fehlt', befehl: null, laufwerk: null, exitCode: null, dauerSek: 0, zusammenfassung: null, punkt: null, ohnePunkt: false, bericht: null, journal: null,
      meldung: `Kein neuer Wiederherstellungspunkt möglich: Windows legt nur alle 24 Stunden einen an (24-Stunden-Sperre). Ohne Punkt startet Morpheus nichts. Sperre aufheben (PowerShell als Administrator): ${session.safety.befehl}`, pakete: ids.map(id => ({ id })) }));
    Object.assign(jobs[jid], { werkzeug: 'winget.upgrade', abbruch: 'nach-paket' });
    return [200, { jobId: jid }];
  }
  function updatesInstallieren(body) {
    const ids = body.ids;
    if (!Array.isArray(ids) || ids.length < 1 || ids.length > 30) return [400, { error: 'Bitte 1 bis 30 Programme wählen.' }];
    if (new Set(ids).size !== ids.length) return [400, { error: 'Jedes Programm nur einmal wählen.' }];
    const gewaehlt = [];
    for (const id of ids) {
      const u = updates.liste.find(x => x.id === id);
      if (!u) return [400, { error: 'Dieses Programm steht nicht in der letzten Suche.' }];
      if (u.kategorie !== 'Programm') return [400, { error: `${u.name}: Kategorie „${u.kategorie}“ wird hier nicht aktualisiert.` }];
      gewaehlt.push(u);
    }
    if (laufend('wartung')) return [409, { error: 'Es läuft schon eine Wartung. Bitte warten, bis sie fertig ist.' }];
    const ohne = body.ohnePunkt === true;
    if (ohne && punktFehlt.has('winget.upgrade') && punktIdsWinget && (punktIdsWinget.length !== ids.length || !ids.every(i => punktIdsWinget.includes(i)))) return [400, { error: 'Ohne Wiederherstellungspunkt nur mit genau denselben Programmen wie beim gescheiterten Start.' }];
    if (!ohne && punktDemoWinget && ids.length === 1 && ids[0] === 'Demo.Player') return wingetPunktFehlt(ids);
    if (ohne && !punktFehlt.has('winget.upgrade')) return [400, { error: 'Ohne Wiederherstellungspunkt ist das nur nach einem Start mit „punkt-fehlt“ erlaubt.' }];
    if (ohne) { punktFehlt.delete('winget.upgrade'); punktIdsWinget = null; }

    const d = new Date(), p = n => String(n).padStart(2, '0');
    const hms = `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
    const punkt = ohne ? null : { seq: 58, zeit: iso(d) };
    const zeilen = ohne ? ['Ohne Wiederherstellungspunkt: bewusst bestätigt.'] : ['Lege Wiederherstellungspunkt an: Morpheus: vor Programm-Updates', `Wiederherstellungspunkt #58 geprüft (${hms}).`];
    zeilen.push('winget läuft ohne Adminrechte. Braucht ein Programm Adminrechte, fragt Windows selbst nach: Herausgeber prüfen.');
    const plan = [];
    gewaehlt.forEach((u, i) => {
      const paket = { id: u.id, name: u.name, von: u.installiert, auf: u.verfuegbar };
      zeilen.push(`Paket ${i + 1}/${gewaehlt.length}: ${u.name} (${u.installiert} → ${u.verfuegbar})`, `Starte: ${WINGET_BEFEHL(u.id)}`);
      if (u.id === 'Demo.Player') Object.assign(paket, { status: 'laeuft-noch', exitCode: 1, dauerSek: 6, text: 'Das Programm läuft noch. Bitte schließen und erneut versuchen.' });
      else Object.assign(paket, { status: 'aktualisiert', exitCode: 0, dauerSek: 41, text: 'Erfolgreich installiert.' });
      zeilen.push(paket.status === 'aktualisiert' ? 'Erfolgreich installiert' : paket.text, `Ergebnis: ${u.name}: ${paket.status === 'aktualisiert' ? 'aktualisiert' : paket.text}`);
      plan.push({ paket, ende: zeilen.length });
    });
    const alleOk = plan.every(x => x.paket.status === 'aktualisiert');
    const anzOk = plan.filter(x => x.paket.status === 'aktualisiert').length;
    zeilen.push(`Ergebnis: ${anzOk} von ${plan.length} Programmen erledigt, ${plan.length - anzOk} nicht`);
    const dauerSek = Math.max(1, Math.round(zeilen.length * 0.7));
    const jid = newJob('wartung', zeilen, () => {
      const pakete = plan.map(x => x.paket);
      plan.forEach(x => updateJournal(x.paket, punkt, ohne));
      updates.liste = updates.liste.filter(u => !pakete.some(p => p.id === u.id && p.status === 'aktualisiert'));
      return { werkzeug: 'winget.upgrade', titel: 'Programme aktualisieren (winget)', klasse: 'reparatur', status: 'erledigt', befehl: null, laufwerk: null, exitCode: null, dauerSek,
        zusammenfassung: { ergebnis: alleOk ? 'ok' : 'problem', text: alleOk ? 'Alle Programme aktualisiert.' : 'Ein Programm läuft noch.', empfehlung: alleOk ? null : 'Programme schließen und erneut versuchen.', details: [] },
        punkt, ohnePunkt: ohne, meldung: alleOk ? 'Alle Programme aktualisiert.' : 'Ein Programm läuft noch.', bericht: null, journal: null, pakete,
        benutzerkontext: true };
    });
    Object.assign(jobs[jid], { werkzeug: 'winget.upgrade', abbruch: 'nach-paket', punkt, ohne, paketPlan: plan });
    return [200, { jobId: jid }];
  }

  // ---- v2.2: Offline-Scan-Countdown. Jeder GET /api/defender/offline gilt als Lebenszeichen.
  const offZustand = () => {
    if (offline.status === 'countdown') {
      if (Date.now() - offline.letzte > 3000) { offline.status = 'abgebrochen'; offline.meldung = 'Abgebrochen: Das Morpheus-Fenster antwortet nicht mehr.'; }
      else if (Date.now() - offline.t0 >= OFF_SEK * 1000) { offline.status = 'gestartet'; offline.meldung = OFF_MELDUNG_START; }
    }
    const rest = offline.status === 'countdown' ? Math.max(0, Math.ceil(OFF_SEK - (Date.now() - offline.t0) / 1000)) : 0;
    return { status: offline.status, rest, meldung: offline.meldung };
  };

  // ---- /api/live: sich bewegende Demo-Werte (erster Abruf: stand = null, wie beim echten Server)
  const walk = (v, step, lo = 1, hi = 99) => Math.max(lo, Math.min(hi, v + (Math.random() - 0.5) * 2 * step));
  const hist = { cpu: [], ram: [], gpu: [] };
  const lv = { cpu: 18, ram: 52, gpu: 34, temp: 62, rx: 480, tx: 90, calls: 0 };
  const push = (a, v) => { a.push(Math.round(v)); if (a.length > 30) a.shift(); };
  for (let i = 0; i < 24; i++) { lv.cpu = walk(lv.cpu, 9); lv.ram = walk(lv.ram, 2); lv.gpu = walk(lv.gpu, 8); push(hist.cpu, lv.cpu); push(hist.ram, lv.ram); push(hist.gpu, lv.gpu); }
  function live() {
    if (lv.calls++ === 0) return { stand: null, cpu: null, ram: null, gpu: null, net: null, top: [], drives: [], verlauf: { cpu: [], ram: [], gpu: [] } };
    lv.cpu = walk(lv.cpu, 9); lv.ram = walk(lv.ram, 2); lv.gpu = walk(lv.gpu, 8); lv.temp = walk(lv.temp, 4, 45, 92); lv.rx = walk(lv.rx, 400, 0, 6000); lv.tx = walk(lv.tx, 60, 0, 900);
    push(hist.cpu, lv.cpu); push(hist.ram, lv.ram); push(hist.gpu, lv.gpu);
    return { stand: iso(new Date()), cpu: Math.round(lv.cpu), ram: { usedPct: Math.round(lv.ram), usedGB: Math.round(lv.ram * 0.32 * 10) / 10, totalGB: 32 },
      gpu: { name: 'Demo GPU RTX 4070', util: Math.round(lv.gpu), temp: Math.round(lv.temp), memUsedPct: 41 },
      net: { adapter: 'Ethernet (Demo)', linkMbps: 1000, rxKBs: Math.round(lv.rx), txKBs: Math.round(lv.tx) },
      top: [{ name: 'demo-game', cpu: Math.round(lv.cpu * 0.5 * 10) / 10 }, { name: 'msedge', cpu: Math.round(lv.cpu * 0.2 * 10) / 10 }, { name: 'demo-tool', cpu: 0.8 }],
      drives: [{ letter: 'C:', label: 'System', type: 'SSD', freePct: 32, freeGB: 76, sizeGB: 238 }, { letter: 'F:', label: 'Spiele', type: 'SSD', freePct: 13, freeGB: 130, sizeGB: 1000 }, { letter: 'D:', label: 'Daten', type: 'HDD', freePct: 6, freeGB: 110, sizeGB: 1863 }],
      verlauf: { cpu: hist.cpu.slice(), ram: hist.ram.slice(), gpu: hist.gpu.slice() } };
  }

  const realFetch = window.fetch.bind(window);
  window.fetch = async (url, opt = {}) => {
    const u = String(url);
    if (!u.startsWith('/api/')) return realFetch(url, opt);
    if (!(opt.headers && opt.headers['X-PcCheck-Token'])) return new Response(JSON.stringify({ error: 'Token fehlt' }), { status: 401 });
    const method = (opt.method || 'GET').toUpperCase();
    const body = opt.body ? JSON.parse(opt.body) : {};
    const path = u.split('?')[0], q = new URLSearchParams(u.split('?')[1] || '');
    // mock.html?latenz=1500 simuliert einen langsamen Server (z. B. /api/wartung mit Laufwerksabfrage)
    await new Promise(r => setTimeout(r, Number(new URLSearchParams(location.search).get('latenz')) || 80));
    let res = [404, { error: 'Unbekannter Pfad (Mock): ' + path }], m;
    if (path === '/api/session') res = [200, session];
    else if (path === '/api/live') res = [200, live()];
    else if (path === '/api/reports') res = [200, reportList()];
    else if ((m = path.match(/^\/api\/reports\/(pc-check_[\d_-]+)\.json$/))) { const r = reps.find(x => x.name === m[1]); res = r ? [200, r.json] : [404, { error: 'Bericht nicht gefunden' }]; }
    else if (path === '/api/actions') res = [200, actions];
    else if (path === '/api/actions/refresh') res = [200, { jobId: newJob('lesen', ['Lese Zustände …'], () => ({})) }];
    else if (path === '/api/actions/run') res = runActions(body.ids || [], body.variante);
    else if (path === '/api/journal') res = [200, journal];
    else if ((m = path.match(/^\/api\/journal\/([^/]+)\/undo$/))) res = undo(decodeURIComponent(m[1]), !!body.force, !!body.vorReparatur);
    else if (path === '/api/restorepoints') res = [200, [{ seq: 57, zeit: '2026-10-25T12:02:11', beschreibung: 'pc-check: Demo-Änderung', typ: 'MODIFY_SETTINGS' }, { seq: 56, zeit: '2026-10-24T19:02:00', beschreibung: 'pc-check: Energiesparfunktionen Netzwerkkarte aus', typ: 'MODIFY_SETTINGS' }, { seq: 55, zeit: '2026-10-24T11:40:00', beschreibung: 'Windows Update', typ: 'APPLICATION_INSTALL' }]];
    else if (path === '/api/datenordner/reparieren') res = method === 'POST' ? datenordnerReparieren(body) : [405, { error: 'Nur POST' }];
    else if (path === '/api/shutdown') res = [200, { ok: true }];
    else if (path === '/api/scan') res = scan(body);
    else if ((m = path.match(/^\/api\/jobs\/([^/]+)$/))) res = jobState(m[1], parseInt(q.get('from') || '0', 10));
    else if (path === '/api/checklist') { if (method === 'POST') checklist = body; res = [200, checklist]; }
    else if (path === '/api/help') res = [200, help];
    // v2.2: Speicher
    else if (path === '/api/speicher') res = [200, speicherCache || { stand: null }];
    else if (path === '/api/spielordner') res = method === 'POST' ? spielordnerSpeichern(body.eintraege) : [200, spielordner];
    else if (path === '/api/speicher/refresh') {
      const alt = laufend('speicher');
      res = [200, { jobId: alt || newJob('speicher', ['C: wird gezählt …', 'C:\\Windows', 'C:\\Users', 'F: wird gezählt …', 'D: wird gezählt …', 'Spiele werden gesucht …'], () => {
        speicherCache = speicherFuer(iso(new Date()));
        speicherCache.spiele = nachGroesse(speicherCache.spiele.concat(manuelleSpiele()));
        return { stand: speicherCache.stand };
      }) }];
    }
    // v2.2: Defender
    else if (path === '/api/defender') res = [200, { stand: { ...defender }, laufend: laufend('defender'), offline: offZustand() }];
    else if (path === '/api/defender/run') res = defenderRun(body.art);
    else if (path === '/api/defender/datei') res = method === 'POST' ? defenderDatei(body) : [405, { error: 'Nur POST' }];
    // v2.3.1: Akzeptanzliste
    else if (path === '/api/akzeptanz') res = method === 'POST' ? akzNeu(body) : [200, { regeln: akz.map(x => ({ ...x })), datei: 'C:\\ProgramData\\Morpheus\\accepted.psd1', bearbeitbar: true }];
    else if ((m = path.match(/^\/api\/akzeptanz\/([^/]+)\/entfernen$/))) {
      const k = akz.findIndex(x => x.id === m[1]);
      if (method !== 'POST') res = [405, { error: 'Nur POST' }];
      else if (k < 0) res = [404, { error: 'Diese Regel gibt es nicht (mehr).' }];
      else { akz.splice(k, 1); res = [200, { regeln: akz.map(x => ({ ...x })) }]; }
    }
    else if (path === '/api/defender/offline') {
      if (method === 'POST') {
        if (body.bestaetigt !== true) res = [400, { error: 'Bestätigung fehlt' }];
        else {
          if (offline.status !== 'countdown') offline = { status: 'countdown', t0: Date.now(), letzte: Date.now(), meldung: '' };
          res = [200, offZustand()];
        }
      } else {
        const z = offZustand(); offline.letzte = Date.now(); res = [200, z];
      }
    }
    else if (path === '/api/defender/offline/abbrechen') {
      if (offline.status === 'countdown') { offline.status = 'abgebrochen'; offline.meldung = 'Abgebrochen. Der PC startet nicht neu.'; }
      res = [200, offZustand()];
    }
    else if (path === '/api/defender/offline/jetzt') {
      if (offZustand().status !== 'countdown') res = [409, { error: 'Kein Countdown aktiv' }];
      else { offline.status = 'gestartet'; offline.meldung = OFF_MELDUNG_START; res = [200, offZustand()]; }
    }
    // v2.3: Sysinternals
    else if (path === '/api/sysinternals') res = [200, { ...sysStand(), laufend: laufend('sysinternals') }];
    else if (path === '/api/sysinternals/install') res = method === 'POST' ? sysInstall(body) : [405, { error: 'Nur POST' }];
    else if (path === '/api/sysinternals/entfernen') res = method === 'POST' ? sysEntfernen() : [405, { error: 'Nur POST' }];
    else if (path === '/api/sysinternals/eula') {
      const n = q.get('name');
      res = SYS_DEF.some(w => w.name === n)
        ? [200, { name: n, text: sysGeladen ? 'Demo: Hier steht im echten Betrieb der Lizenztext aus dem Download (Eula.txt).' : null }]
        : [400, { error: 'Unbekanntes Werkzeug' }];
    }
    // v2.4: Wartung & Reparatur und Update-Dialog (Vertrag 17.5)
    else if (path === '/api/wartung') res = [200, { werkzeuge: wartungWerkzeuge, laufwerke: WART_LAUFWERKE, berichte: wartungBerichte, laufend: wartungLaufendInfo(), punktFehlt: [...punktFehlt], safety: session.safety }];
    else if (path === '/api/wartung/start') res = method === 'POST' ? wartungStart(body) : [405, { error: 'Nur POST' }];
    else if (path === '/api/wartung/abbrechen') res = method === 'POST' ? wartungAbbrechen(body.jobId) : [405, { error: 'Nur POST' }];
    else if (path === '/api/wartung/zuverlaessigkeit') res = [200, { ok: true, meldung: 'Der Zuverlässigkeitsverlauf öffnet sich (Demo).' }];
    else if (path === '/api/updates') res = [200, { ...updates, suche: laufend('updatesuche'), laufend: wingetLaeuft(), wartungLaeuft: wartungLaeuftId(), punktFehlt: punktFehlt.has('winget.upgrade') }];
    else if (path === '/api/updates/suchen') res = updatesSuchen();
    else if (path === '/api/updates/installieren') res = method === 'POST' ? updatesInstallieren(body) : [405, { error: 'Nur POST' }];
    else if (path === '/api/heartbeat' || path === '/api/shutdown') res = [200, {}];
    return new Response(JSON.stringify(res[1]), { status: res[0], headers: { 'Content-Type': 'application/json' } });
  };
  // Original-HTML-Bericht: im Mock ein kleines data:-Dokument statt /report/…
  window.PCCHECK_REPORT_SRC = name => 'data:text/html;charset=utf-8,' + encodeURIComponent(`<body style="font:14px sans-serif"><h2>Demo: Original-HTML ${name}</h2><p>Im echten Betrieb liefert der Server /report/&lt;name&gt;.html.</p></body>`);
})();
