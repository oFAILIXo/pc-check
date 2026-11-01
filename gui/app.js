/* pc-check GUI (v2.0): Oberfläche in Vanilla JS.
   Kein Inline-Script, kein eval. Alle Texte aus Berichtsdaten werden per textContent eingesetzt (siehe h()). */
'use strict';
(() => {

// ---------------------------------------------------------------- Konstanten
const STATUS = ['CRIT', 'WARN', 'TIPP', 'ACK', 'INFO', 'OK', 'SKIP'];
const STATUS_NAME = { CRIT: 'Kritisch', WARN: 'Warnung', TIPP: 'Tipp', ACK: 'Akzeptiert', INFO: 'Hinweis', OK: 'OK', SKIP: 'Nicht geprüft' };
const STATUS_COLOR = { CRIT: 'var(--red)', WARN: 'var(--orange)', TIPP: 'var(--magenta)', ACK: 'var(--violet)', INFO: 'var(--blue)', OK: 'var(--green)', SKIP: 'var(--b01)' };
const RANK = { CRIT: 0, WARN: 1, TIPP: 2, INFO: 3, ACK: 4, SKIP: 5, OK: 6 };
const LEVEL = { gering: 1, mittel: 2, hoch: 3 };
const GAMING_CHECKS = ['Bildschirme und Bildwiederholrate', 'Grafikkarte und Treiber', 'Resizable BAR und PCIe-Anbindung', 'Arbeitsspeicher', 'Prozessor-Energieeinstellungen', 'Energieplan',
  'Spielebibliotheken', 'Spielmodus', 'Hardwarebeschleunigte GPU-Planung (HAGS)', 'Hintergrundaufzeichnung (Game DVR)', 'Optimierungen für Spiele im Fenstermodus',
  'Overlays und Hintergrund-Tools', 'Mausbeschleunigung', 'Netzwerkverbindung', 'Netzwerkkarte: Energiesparfunktionen', 'Virtualisierung und Spieleleistung'];
const REPORT_RE = /^pc-check_\d{4}-\d{2}-\d{2}_\d{4}$/;
// Menütexte zentral (2.5, #65): Für die englische Oberfläche (#66) wird nur dieses Objekt übersetzt.
const MENU_TEXTE = {
  gruppen: { bereiche: 'Bereiche', verwalten: 'Verwalten' },
  punkte: { uebersicht: 'Übersicht', sicherheit: 'Sicherheit', leistung: 'Leistung', gaming: 'Gaming', stabilitaet: 'Stabilität', alle: 'Alle Prüfungen',
    checkliste: 'Checkliste', aenderungen: 'Änderungen', werkzeuge: 'Werkzeuge', berichte: 'Berichte', scan: 'Neuer Scan', rohdaten: 'Rohdaten', einstellungen: 'Einstellungen' },
  unter: { gamingCheck: 'Gaming-Check', wartung: 'Wartung & Reparatur', defender: 'Microsoft Defender', updates: 'Programme aktualisieren',
    sysinternals: 'Sysinternals', spieleOrdner: 'Eigene Spiele-Ordner', keinBericht: 'Kategorien nach dem ersten Scan' },
  filter: { problem: 'Nur Probleme', CRIT: 'Kritisch', WARN: 'Warnungen', TIPP: 'Tipps', ACK: 'Akzeptiert', SKIP: 'Nicht geprüft' },
  // Reihenfolge wie in der Karte „Wartung & Reparatur“
  werkzeuge: [['wiederherstellung.punkt', 'Wiederherstellungspunkt'], ['dism.checkhealth', 'DISM: schnell prüfen'], ['dism.scanhealth', 'DISM: gründlich prüfen'],
    ['dism.restorehealth', 'DISM: reparieren'], ['sfc.scannow', 'SFC: Systemdateien'], ['dism.analyze', 'WinSxS analysieren'], ['dism.cleanup', 'WinSxS bereinigen'],
    ['chkdsk.scan', 'Datenträger prüfen'], ['perfmon.rel', 'Zuverlässigkeitsverlauf'], ['dns.flush', 'DNS-Speicher leeren'], ['trim', 'SSD optimieren (TRIM)'],
    ['zeit.resync', 'Uhrzeit synchronisieren'], ['powercfg.energy', 'Energiebericht'], ['powercfg.akku', 'Akkubericht'], ['powercfg.schlaf', 'Schlafstudie']],
  aria: { nav: 'Hauptnavigation', auf: 'Unterpunkte von {0} einblenden', zu: 'Unterpunkte von {0} ausblenden' },
};
const MT = MENU_TEXTE.punkte;
// kinder: 'kategorien' (aus dem Bericht), 'filter' (Status-Filter), 'werkzeuge' (Karten und Einzelwerkzeuge)
const NAV = [
  { id: 'uebersicht', label: MT.uebersicht, icon: 'home' }, { group: MENU_TEXTE.gruppen.bereiche },
  { id: 'sicherheit', label: MT.sicherheit, icon: 'shield', badge: true, kinder: 'kategorien' }, { id: 'leistung', label: MT.leistung, icon: 'gauge', badge: true, kinder: 'kategorien' },
  { id: 'gaming', label: MT.gaming, icon: 'pad', badge: true, kinder: 'kategorien' }, { id: 'stabilitaet', label: MT.stabilitaet, icon: 'pulse', badge: true, kinder: 'kategorien' },
  { id: 'alle', label: MT.alle, icon: 'list', kinder: 'filter' }, { group: MENU_TEXTE.gruppen.verwalten },
  { id: 'checkliste', label: MT.checkliste, icon: 'check' }, { id: 'aenderungen', label: MT.aenderungen, icon: 'undo' }, { id: 'werkzeuge', label: MT.werkzeuge, icon: 'tool', kinder: 'werkzeuge' },
  { id: 'berichte', label: MT.berichte, icon: 'doc' }, { id: 'scan', label: MT.scan, icon: 'scan' },
  { id: 'rohdaten', label: MT.rohdaten, icon: 'db' }, { id: 'einstellungen', label: MT.einstellungen, icon: 'gear' },
];
const NAV_KEY = 'morpheusNavAuf';
const NAV_STANDARD_AUF = { 'werkzeuge/wartung': true };   // Einzelwerkzeuge sofort sichtbar, sobald „Werkzeuge“ offen ist
const CAT_VIEWS = ['sicherheit', 'leistung', 'gaming', 'stabilitaet', 'alle'];
const LIVE_MS = 5000;
const SB_KEY = 'pcCheckStatusbar';

// ---------------------------------------------------------------- Zustand
const S = {
  token: null, session: null, reports: [], cur: null, report: null, findings: [], cache: {},
  actions: [], help: null, checklist: {}, journal: null, view: 'uebersicht', rv: 0,
  ui: { f: {}, reveal: null, focusSpOrdner: false }, sel: new Set(), variant: {}, cmp: [], origName: null, scan: null, multiBtns: [],
  points: null, live: { state: 'idle', data: null }, sbOn: true,
  speicher: null, spSrc: '', spApi: null, spPop: null, spJob: null, spOrdner: null, spoMsg: null, spoJob: null,   // Speicherverbraucher (Abschnitt 14.7)
};

// ---------------------------------------------------------------- DOM-Helfer
function add(e, kids) {
  for (const k of kids.flat(Infinity)) {
    if (k == null || k === false) continue;
    e.append(k.nodeType ? k : document.createTextNode(String(k)));
  }
}
/** Element bauen. Attribute: class, text, on<Ereignis> (Funktion), checked/value/selected/disabled (Eigenschaften). */
function h(tag, attrs, ...kids) {
  const e = document.createElement(tag);
  if (tag === 'button' && attrs && !attrs['data-mark'] && !attrs['data-filter'] && !/(btn|info|kpi|pill|srow|tile)/.test(attrs.class || '')) {
    attrs = { ...attrs, class: ('btn ' + (attrs.class === 'copy' ? 'sm ghost' : (attrs.class || ''))).trim() };   // einheitlicher Button-Stil
  }
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v == null || v === false) continue;
      if (k === 'class') e.className = v;
      else if (k === 'text') e.textContent = v;
      else if (k.startsWith('on') && typeof v === 'function') e.addEventListener(k.slice(2), v);
      else if (k === 'checked' || k === 'value' || k === 'selected') e[k] = v;
      else if (v === true) e.setAttribute(k, '');
      else e.setAttribute(k, v);
    }
  }
  add(e, kids);
  return e;
}
const svgNS = 'http://www.w3.org/2000/svg';
function svg(tag, attrs) {
  const e = document.createElementNS(svgNS, tag);
  for (const [k, v] of Object.entries(attrs || {})) e.setAttribute(k, v);
  return e;
}
function icon(id) { const s = svg('svg', { class: 'i', 'aria-hidden': 'true' }); s.append(svg('use', { href: '#i-' + id })); return s; }
const $ = (s, r = document) => r.querySelector(s);
const pad = n => String(n).padStart(2, '0');
function fmtDate(s) {
  const d = new Date(s);
  if (isNaN(d)) return s || '';
  return `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
function fmtWhen(s) {   // „heute 14:25“, „gestern 11:40“, sonst „24.10. 19:02“
  const d = new Date(s); if (isNaN(d)) return s || '';
  const t = `${pad(d.getHours())}:${pad(d.getMinutes())}`, now = new Date();
  const day = x => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diff = Math.round((day(now) - day(d)) / 86400000);
  if (diff === 0) return 'heute ' + t;
  if (diff === 1) return 'gestern ' + t;
  return `${pad(d.getDate())}.${pad(d.getMonth() + 1)}. ${t}`;
}
function fmtAgo(s) {
  const d = new Date(s); if (isNaN(d)) return '–';
  const m = Math.round((Date.now() - d.getTime()) / 60000);
  if (m < 2) return 'gerade eben';
  if (m < 60) return `vor ${m} min`;
  if (m < 60 * 36) return `vor ${Math.round(m / 60)} h`;
  const t = Math.round(m / 1440);
  return t === 1 ? 'vor 1 Tag' : `vor ${t} Tagen`;
}
const dec = (v, d = 0) => (v == null || isNaN(v)) ? '–' : Number(v).toFixed(d).replace('.', ',');
function fmtShort(s) { const d = new Date(s); return isNaN(d) ? '' : `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${String(d.getFullYear()).slice(2)}`; }
function fmtState(v) {
  if (v == null) return 'nicht gesetzt';
  if (typeof v === 'object') { let t = JSON.stringify(v); if (t.length > 120) t = t.slice(0, 117) + '…'; return t; }
  return String(v);
}
function toast(msg) {
  const t = h('div', { class: 'toast', role: 'status', text: msg });
  document.body.append(t);
  setTimeout(() => t.remove(), 3500);
}
async function copyText(text, btn) {
  const label = btn ? btn.textContent : '';
  const done = ok => { if (btn) { btn.textContent = ok ? '✔ Kopiert' : 'Nicht möglich'; setTimeout(() => { btn.textContent = label; }, 2000); } else toast(ok ? 'Kopiert' : 'Kopieren nicht möglich'); };
  try { await navigator.clipboard.writeText(text); done(true); return; } catch { /* Rückfall */ }
  const ta = h('textarea', { style: 'position:fixed;left:-9999px', 'aria-hidden': 'true' });
  ta.value = text; document.body.append(ta); ta.select();
  let ok = false; try { ok = document.execCommand('copy'); } catch { ok = false; }
  ta.remove(); done(ok);
}
function levelsNode(n, a, r) {
  const parts = [['Nutzen', n, 'n'], ['Aufwand', a, 'a'], ['Risiko', r, 'r']].filter(x => x[1]);
  if (!parts.length) return null;
  return h('span', { class: 'lv' }, parts.map(x => h('span', { class: `${x[2]}-${x[1]}`, text: `${x[0]} ${x[1]}` })));
}
/** Befehl mit einfacher Einfärbung (Cmdlet = blau, Parameter = gelb); nur DOM-Knoten. */
function fillCmd(pre, text) {
  pre.replaceChildren();
  String(text || '').split(/(\s+)/).forEach(tok => {
    if (!tok || /^\s+$/.test(tok)) { if (tok) pre.append(document.createTextNode(tok)); return; }
    if (/^-[A-Za-z]\w*$/.test(tok)) pre.append(h('span', { class: 'p', text: tok }));
    else if (/^(Get|Set|New|Add|Remove|Enable|Disable|Start|Stop|Invoke|Test|Clear)-[A-Za-z]+$/.test(tok)) pre.append(h('span', { class: 'k', text: tok }));
    else pre.append(document.createTextNode(tok));
  });
}
function cmdBlock(text, withCopy = true, label = 'PowerShell · Administrator') {
  const btn = withCopy ? h('button', { type: 'button', class: 'btn sm ghost', text: 'Kopieren', onclick: e => copyText(text, e.currentTarget) }) : null;
  const pre = h('pre'); fillCmd(pre, text);
  return h('div', { class: 'code' }, h('div', { class: 'ch' }, h('span', { text: label }), btn), pre);
}
const norm = s => (s || '').normalize('NFC');

// ---------------------------------------------------------------- API
class ApiError extends Error { constructor(msg, status) { super(msg); this.status = status; } }
function fatal(msg) {
  const f = $('#fatal');
  f.replaceChildren(h('div', { class: 'card' }, h('h2', { text: msg })));
  f.classList.remove('hide');
}
async function api(path, o = {}) {
  const method = o.method || 'GET';
  const opt = { method, headers: { 'X-PcCheck-Token': S.token || '' } };
  if (method === 'POST') { opt.headers['Content-Type'] = 'application/json'; opt.body = JSON.stringify(o.body == null ? {} : o.body); }
  let r;
  try { r = await fetch(path, opt); } catch { throw new ApiError('Keine Verbindung zur GUI. Läuft sie noch?', 0); }
  if (r.status === 401) { fatal('Sitzung abgelaufen, GUI neu starten.'); throw new ApiError('Sitzung abgelaufen, GUI neu starten.', 401); }
  const txt = await r.text();
  let data = null;
  try { data = txt ? JSON.parse(txt) : null; } catch { data = null; }
  if (!r.ok) throw new ApiError((data && data.error) || `Fehler ${r.status}`, r.status);
  return data;
}
/**
 * Edge bekommt nur einen Einmal-Code (#b=…), weil seine Befehlszeile für alle Programme des Benutzers lesbar ist.
 * Der Code wird sofort gegen das eigentliche Token getauscht; danach ist er wertlos.
 */
async function initToken() {
  const m = location.hash.match(/^#b=([\w-]+)/);
  if (m) {
    history.replaceState(null, '', location.pathname + location.search + '#/uebersicht');
    const r = await fetch('/api/session/claim', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code: m[1] }) });
    let data = null; try { data = await r.json(); } catch { /* leer */ }
    if (!r.ok || !data || !data.token) throw new Error((data && data.error) || 'Der Startcode wurde abgelehnt. Bitte die GUI neu starten.');
    S.token = data.token;
    try { sessionStorage.setItem('pcCheckToken', S.token); } catch { /* ohne Speicher weiter */ }
  } else {
    try { S.token = sessionStorage.getItem('pcCheckToken'); } catch { S.token = null; }
  }
}
let hbFail = 0;
function startHeartbeat() {
  // sofort=true (Fenster wieder sichtbar/fokussiert): Ein Verbindungsfehler heißt, der Server ist beendet
  const beat = (sofort) => api('/api/heartbeat', { method: 'POST' }).then(() => { hbFail = 0; }, e => {
    if (e.status === 401) return;
    if (sofort === true && e.status === 0) { fatal('Morpheus läuft nicht mehr. Bitte über das Startmenü neu starten.'); return; }
    if (++hbFail >= 3) fatal('Verbindung zur GUI verloren. Das Fenster kann geschlossen werden.');
  });
  setInterval(() => beat(false), 10000);
  // Edge drosselt Hintergrundfenster: beim Zurückkehren sofort ein Lebenszeichen senden
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') beat(true); });
  window.addEventListener('focus', () => beat(true));
}
/** Job abfragen, bis er fertig ist. onLines bekommt neue Logzeilen. */
async function followJob(id, onLines) {
  let from = 0, errs = 0;
  for (;;) {
    let j;
    try { j = await api(`/api/jobs/${encodeURIComponent(id)}?from=${from}`); errs = 0; }
    catch (e) { if (e.status === 401 || ++errs > 5) throw e; await sleep(1000); continue; }
    if (j.log && j.log.length) { onLines(j.log); }
    if (typeof j.next === 'number') from = j.next; else from += (j.log || []).length;
    if (j.status !== 'running') return j;
    await sleep(1000);
  }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---------------------------------------------------------------- Daten laden
const normName = n => String(n || '').replace(/\.(json|html|md)$/i, '');
async function loadReportJson(name) {
  if (!REPORT_RE.test(name)) throw new ApiError('Ungültiger Berichtsname', 400);
  if (!S.cache[name]) S.cache[name] = await api(`/api/reports/${name}.json`);
  return S.cache[name];
}
async function showReport(name) {
  const r = await loadReportJson(name);
  S.cur = name; S.report = r; S.findings = (r.Findings || []).map(f => ({ ...f, Category: norm(f.Category), Check: norm(f.Check) }));
  pickSpeicher();
}
async function loadReports() {
  const list = await api('/api/reports');
  S.reports = (list || []).map(r => ({ ...r, name: normName(r.name) })).filter(r => REPORT_RE.test(r.name));
}
async function loadActions() { try { S.actions = (await api('/api/actions')) || []; } catch (e) { if (e.status === 401) throw e; S.actions = []; } }
/**
 * Zustände der Aktionen am System neu lesen lassen (Job „refresh“), danach Liste und Ansicht aktualisieren.
 * Ohne diesen Anstoß kennt der Server keine Zustände: Alle Karten zeigten „Zustand unbekannt“ und „Ausführen“.
 * Läuft schon ein Lesen, liefert der Server dessen Job; parallele Aufrufe hier teilen sich ein Versprechen.
 */
let statesRun = null;
function refreshActionStates() {
  if (statesRun) return statesRun;
  statesRun = (async () => {
    try {
      const r = await api('/api/actions/refresh', { method: 'POST' });
      if (r && r.jobId) await followJob(r.jobId, () => {});
      await loadActions();
      // „Werkzeuge“ zeigt keine Anpassungen; neu zeichnen würde die Karten neu laden und die Position verschieben (2.5, #65)
      if (S.view === 'werkzeuge') renderNav(); else refreshView();
    } catch (e) { if (e.status === 401) throw e; /* ohne Zustände weiter (Mock, Nur-Lesen ohne Safety) */ }
    finally { statesRun = null; }
  })();
  return statesRun;
}
async function loadSession() { S.session = await api('/api/session'); }
async function loadAll() {
  await Promise.all([loadSession(), loadReports()]);
  await Promise.all([
    loadActions(),
    api('/api/help').then(x => { S.help = x; }, () => { S.help = null; }),
    api('/api/checklist').then(x => { S.checklist = x || {}; }, () => { S.checklist = {}; }),
    loadSpeicher(),
  ]);
  if (S.reports.length) await showReport(S.reports[0].name);
}

// ---------------------------------------------------------------- Befunde
function viewOf(f) {
  const c = norm(f.Category);
  if (f.Area === 'Sicherheit') return 'sicherheit';
  if (c === 'Gaming & Grafik') return 'gaming';
  if (c === 'Stabilität') return 'stabilitaet';
  return 'leistung';
}
const isProblem = f => f.Status === 'CRIT' || f.Status === 'WARN';
const isOpen = f => f.Status === 'CRIT' || f.Status === 'WARN' || f.Status === 'TIPP';
const findingByCheck = c => S.findings.find(f => f.Check === c);
function tipScore(f) { return f.Benefit ? 2 * (LEVEL[f.Benefit] || 0) - (LEVEL[f.Effort] || 0) - ((LEVEL[f.Risk] || 0) - 1) : -99; }
function counts(list) { const c = {}; STATUS.forEach(s => { c[s] = 0; }); list.forEach(f => { if (c[f.Status] != null) c[f.Status]++; }); return c; }
function actionsFor(f) { return S.actions.filter(a => norm(a.pruefung) === f.Check); }
function actionView(a) { return a.kategorie === 'Sicherheit' ? 'sicherheit' : a.kategorie === 'Gaming' ? 'gaming' : a.kategorie === 'Stabilität' ? 'stabilitaet' : 'leistung'; }
const safety = () => (S.session && S.session.safety) || {};
// Nur-Lesen-Modus: der Codeordner ist nicht gesichert (oder keine Adminrechte); der Server antwortet bei Änderungen mit 403
const readOnly = () => !!(S.session && S.session.readOnly);
const locked = () => safety().schutzAn === false || readOnly();
const lockTitle = () => readOnly() ? 'Nur-Lesen-Modus: Morpheus läuft nicht aus einem gesicherten Ordner, deshalb wird nichts geändert.' : 'Computerschutz ist aus: ohne Wiederherstellungspunkt wird nichts geändert.';
function uiF(view) { return S.ui.f[view] || (S.ui.f[view] = { mode: 'all', term: '' }); }

// ---------------------------------------------------------------- Dialog
const Dlg = { prev: null, running: false, onEsc: null, onClose: null };
function dlgOpen(title, body, buttons, opts = {}) {
  Dlg.running = !!opts.lock; Dlg.onEsc = opts.onEsc || null; Dlg.onClose = opts.onClose || null;
  if (!$('#modal').classList.contains('on')) Dlg.prev = document.activeElement;
  $('#dlg-title').textContent = title;
  $('#dlg-body').replaceChildren(...[].concat(body).filter(Boolean));
  const bx = $('#dlg-buttons'); bx.replaceChildren();
  buttons.forEach(b => bx.append(h('button', { type: 'button', class: b.primary ? 'primary' : (b.danger ? 'danger' : ''), disabled: !!b.disabled, onclick: b.onClick, text: b.label })));
  const m = $('#modal'); m.classList.add('on'); m.setAttribute('aria-hidden', 'false');
  const first = bx.querySelector('button.primary:not(:disabled)') || bx.querySelector('button:not(:disabled)');
  if (first) first.focus();
}
function dlgClose() {
  const m = $('#modal'); m.classList.remove('on'); m.setAttribute('aria-hidden', 'true'); Dlg.running = false;
  const cb = Dlg.onClose; Dlg.onClose = null; Dlg.onEsc = null; if (cb) cb();
  if (Dlg.prev && Dlg.prev.isConnected) Dlg.prev.focus();
}
document.addEventListener('keydown', e => {
  const m = $('#modal');
  if (!m.classList.contains('on')) return;
  if (e.key === 'Escape' && Dlg.onEsc) { e.preventDefault(); Dlg.onEsc(); }
  else if (e.key === 'Escape' && !Dlg.running) { e.preventDefault(); dlgClose(); }
  if (e.key === 'Tab') {
    const f = [...$('#dlg').querySelectorAll('button:not(:disabled),a[href],input,select,textarea,summary')].filter(x => x.offsetParent !== null);
    if (!f.length) return;
    const first = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    else if (!$('#dlg').contains(document.activeElement)) { e.preventDefault(); first.focus(); }
  }
});

// ---------------------------------------------------------------- Aktionen ausführen
const RUN_STEPS = [
  ['Aktuellen Zustand lesen', /lese|zustand|vorher/i],
  ['Wiederherstellungspunkt anlegen', /wiederherstellungspunkt|checkpoint/i],
  ['Wiederherstellungspunkt prüfen', /geprüft|prüfe|vorhanden|bestätigt/i],
  ['Journal-Eintrag schreiben', /journal/i],
  ['Änderung ausführen', /ausführ|führe|setze|schalte|ändere/i],
  ['Ergebnis prüfen', /ergebnis|nachher|erledigt|kontroll/i],
];
const RESULT_TEXT = { erledigt: 'Erledigt', fehlgeschlagen: 'Fehlgeschlagen', 'fehlgeschlagen-zurueckgesetzt': 'Fehlgeschlagen, wieder zurückgesetzt', zurueckgenommen: 'Zurückgenommen', uebersprungen: 'Übersprungen', 'übersprungen': 'Übersprungen', 'uebersprungen-erreicht': 'Schon erledigt, nichts geändert', 'uebersprungen-voraussetzung': 'Nicht ausgeführt (Voraussetzung fehlt)' };
const FORCE_RE = /zustand.*ge[äa]ndert|ge[äa]ndert.*zustand/i;

/** Gemeinsame Anzeige eines laufenden Jobs im Dialog: Schritte, Live-Log, Ergebnis. */
function jobView(steps) {
  const ul = h('ul', { class: 'steps', 'aria-label': 'Ablauf' }, steps.map(s => h('li', null, h('span', { class: 's' }), s[0])));
  const log = h('pre', { class: 'log', 'aria-live': 'polite', text: '' });
  let cur = -1;
  const setLi = (li, cls) => { li.className = cls; li.firstChild.textContent = cls === 'done' ? '✓' : (cls === 'fail' ? '✕' : ''); };
  const mark = (idx, cls) => { [...ul.children].forEach((li, i) => setLi(li, i < idx ? 'done' : (i === idx ? cls : ''))); };
  return {
    nodes: [ul, log], ul, log,
    lines(arr) {
      for (const l of arr) {
        log.append(document.createTextNode(l + '\n'));
        const i = steps.findIndex((s, k) => k >= cur && s[1].test(l));
        if (i >= 0 && i >= cur) { cur = i; mark(i, 'run'); }
      }
      log.scrollTop = log.scrollHeight;
    },
    finish(ok) { if (ok) [...ul.children].forEach(li => setLi(li, 'done')); else mark(Math.max(cur, 0), 'fail'); },
  };
}
function resultList(items) {
  const arr = [].concat(items || []).filter(Boolean);
  if (!arr.length) return null;
  return h('ul', { class: 'result' }, arr.map(r => {
    const a = S.actions.find(x => x.id === r.id);
    const okc = r.status === 'erledigt' ? 'ok' : (String(r.status).startsWith('fehl') ? 'rem' : 'warn');
    return h('li', null,
      h('b', { text: a ? a.titel : (r.id || 'Aktion') }), ' ',
      h('span', { class: okc, text: RESULT_TEXT[r.status] || r.status || '' }),
      r.meldung ? h('div', { class: 'note', text: r.meldung }) : null,
      r.status === 'erledigt' && r.neustart ? h('div', { class: 'warn', text: '⟳ Für diese Änderung ist ein Neustart nötig. Er wird nicht automatisch ausgelöst.' }) : null);
  }));
}
async function afterChange() {
  await Promise.all([loadSession().catch(() => {}), loadActions()]);
  S.sel.clear(); refreshView(); loadExtra();
  refreshActionStates();   // Zustände nach der Änderung neu lesen
}
function runCmdText(a, variante) { return (a.befehle && a.befehle.ausfuehren || '').replace(/<variante>/g, variante || '<variante>'); }

function openRunDialog(actions, variante) {
  if (!actions.length) return;
  const title = actions.length > 1 ? `${actions.length} Änderungen ausführen` : actions[0].titel;
  const body = [];
  actions.forEach(a => {
    const v = a.varianten && a.varianten.length ? (variante || S.variant[a.id] || a.varianten[0]) : null;
    body.push(h('div', null, actions.length > 1 ? h('b', { text: a.titel }) : null, v ? h('div', { class: 'note', text: `Variante: ${v}` }) : null, cmdBlock(runCmdText(a, v), false)));
  });
  const noRp = actions.some(a => a.ohneWiederherstellungspunkt || a.id === 'system.wiederherstellung');
  body.push(h('div', { class: 'note', text: noRp ? 'Achtung: Diese Aktion schaltet die Wiederherstellungspunkte erst ein und kann deshalb vorher keinen anlegen.' : 'Vorher wird ein Wiederherstellungspunkt angelegt und geprüft. Fehlt er, wird nichts geändert. Jede Änderung erscheint danach unter „Änderungen“ und lässt sich einzeln zurücknehmen.' }));
  if (actions.some(a => a.neustart)) body.push(h('div', { class: 'warn', style: 'margin-top:6px', text: '⟳ Mindestens eine Änderung wirkt erst nach einem Neustart. Neu gestartet wird nicht automatisch.' }));
  dlgOpen(title, body, [{ label: 'Abbrechen', onClick: dlgClose }, { label: 'Ausführen', primary: true, onClick: () => startRun(actions, title, variante) }]);
}
async function startRun(actions, title, variante) {
  const jv = jobView(RUN_STEPS);
  const single = actions.length === 1 && actions[0].varianten && actions[0].varianten.length;
  const v = single ? (variante || S.variant[actions[0].id] || actions[0].varianten[0]) : null;
  dlgOpen(title, jv.nodes, [{ label: 'Läuft …', disabled: true }], { lock: true });
  let job = null, err = null;
  try {
    const body = { ids: actions.map(a => a.id) };
    if (v) body.variante = v;
    jv.lines(['Bitte im Windows-Fenster „Morpheus – Änderung bestätigen“ mit „Ja“ bestätigen …']);
    const r = await api('/api/actions/run', { method: 'POST', body });
    job = await followJob(r.jobId, jv.lines);
  } catch (e) { err = e; }
  finishJob(title, jv, job, err, 'Fertig');
}
function finishJob(title, jv, job, err, doneLabel) {
  const ok = !err && job && job.status === 'done';
  jv.finish(ok);
  const body = [...jv.nodes];
  const res = job && job.ergebnis;
  if (err) body.push(h('p', { class: 'rem', text: err.message }));
  else if (job && job.status === 'failed') body.push(h('p', { class: 'rem', text: (res && res.error) || 'Der Vorgang ist fehlgeschlagen.' }));
  const list = res && !res.error ? resultList(res) : null;
  if (list) body.push(h('h3', { text: 'Ergebnis' }), list);
  dlgOpen(title, body, [{ label: doneLabel, primary: true, onClick: dlgClose }]);
  Dlg.running = false;
  afterChange();
}

// ---------------------------------------------------------------- Rückgängig
function openUndoDialog(e) {
  const body = [
    h('p', { text: `„${e.titel || e.aktion}“ wird auf den früheren Zustand zurückgesetzt: ${fmtState(e.nachher)} → ${fmtState(e.vorher)}.` }),
    h('div', { class: 'note', text: 'Auch das Zurücknehmen ist eine Änderung: Vorher wird ein neuer Wiederherstellungspunkt angelegt und geprüft.' }),
  ];
  dlgOpen('Änderung rückgängig machen', body, [{ label: 'Abbrechen', onClick: dlgClose }, { label: '↶ Rückgängig', primary: true, onClick: () => startUndo(e, false) }]);
}
async function startUndo(e, force, vorRep) {
  const title = 'Rückgängig: ' + (e.titel || e.aktion);
  const jv = jobView(RUN_STEPS);
  dlgOpen(title, jv.nodes, [{ label: 'Läuft …', disabled: true }], { lock: true });
  let job = null, err = null;
  try {
    jv.lines(['Bitte im Windows-Fenster „Morpheus – Änderung bestätigen“ mit „Ja“ bestätigen …']);
    const r = await api(`/api/journal/${encodeURIComponent(e.id)}/undo`, { method: 'POST', body: Object.assign({}, force ? { force: true } : null, vorRep ? { vorReparatur: true } : null) });
    job = await followJob(r.jobId, jv.lines);
  } catch (x) { err = x; }
  const msg = err ? err.message : (job && job.status === 'failed' && job.ergebnis && job.ergebnis.error) || '';
  if (!vorRep && /vor der Reparatur des Datenordners/i.test(msg)) {
    Dlg.running = false;
    dlgOpen(title, [h('p', { class: 'warn', text: 'Dieser Eintrag stammt aus der Zeit, in der der Datenordner ungeschützt war. Hast du diese Änderung selbst vorgenommen?' })],
      [{ label: 'Abbrechen', onClick: dlgClose }, { label: 'Ja, trotzdem zurücknehmen', danger: true, onClick: () => startUndo(e, force, true) }]);
    return;
  }
  if (!force && FORCE_RE.test(msg)) {
    Dlg.running = false;
    dlgOpen(title, [h('p', { class: 'warn', text: msg }), h('p', { text: 'Der Zustand hat sich seit der Änderung geändert. Trotzdem auf den früheren Wert zurücksetzen?' })],
      [{ label: 'Abbrechen', onClick: dlgClose }, { label: 'Trotzdem zurücksetzen', danger: true, onClick: () => startUndo(e, true, vorRep) }]);
    return;
  }
  finishJob(title, jv, job, err, 'Fertig');
}

// ---------------------------------------------------------------- Bausteine
function infoTip(check, cat) {
  const hp = S.help; if (!hp) return null;
  const P = hp.Pruefungen || hp.pruefungen || {}, K = hp.Kategorien || hp.kategorien || {};
  const e = P[check];
  let tip = null;
  if (e) tip = h('span', { class: 'tip', role: 'tooltip' }, h('b', { text: 'Was wird geprüft? ' }), e.Was, h('br'), h('b', { text: 'Warum wichtig? ' }), e.Warum, h('br'), h('b', { text: 'Wann ist eine Warnung harmlos? ' }), e.Harmlos);
  else if (K[cat]) tip = h('span', { class: 'tip', role: 'tooltip', text: K[cat] });
  if (!tip) return null;
  return [h('button', { type: 'button', class: 'info', 'aria-label': 'Erklärung', 'aria-expanded': 'false', text: 'i' }), tip];
}
function howTo(f) {
  const steps = f.Steps || [];
  if (!steps.length && !f.Command) return null;
  return h('details', { class: 'how' }, h('summary', { text: 'So geht\'s' }),
    steps.length ? h('ol', null, steps.map(s => h('li', { text: s }))) : null,
    f.Command ? cmdBlock(f.Command) : null);
}
function actionCard(a) {
  const z = a.zustand || {};
  const done = z.aktiv === true, lock = locked();
  const hasVar = a.varianten && a.varianten.length;
  const stateNode = h('span', { class: 'state ' + (z.aktiv === true ? 'on' : (z.aktiv === false ? 'off' : 'unk')), title: z.stand ? `Gelesen: ${fmtDate(z.stand)}` : null },
    h('i'), z.wert != null && z.wert !== '' ? `Zustand: ${z.wert}${done ? ' ✓' : ''}` : 'Zustand unbekannt');
  let sel = null, curCmd = runCmdText(a, hasVar ? (S.variant[a.id] || a.varianten[0]) : null);
  const cmdPre = h('pre'); fillCmd(cmdPre, curCmd);
  if (hasVar) {
    sel = h('select', { 'aria-label': 'Variante', onchange: e => { S.variant[a.id] = e.target.value; curCmd = runCmdText(a, e.target.value); fillCmd(cmdPre, curCmd); } },
      a.varianten.map(v => h('option', { value: v, selected: (S.variant[a.id] || a.varianten[0]) === v, text: v })));
  }
  const chk = (!hasVar && !done && !lock)
    ? h('input', { type: 'checkbox', checked: S.sel.has(a.id), 'aria-label': `${a.titel} auswählen`, onchange: e => { if (e.target.checked) S.sel.add(a.id); else S.sel.delete(a.id); updateMulti(); } })
    : null;
  const btn = done ? h('button', { type: 'button', class: 'sm', disabled: true, text: 'Bereits erledigt' })
    : lock ? h('button', { type: 'button', class: 'sm', disabled: true, title: lockTitle(), text: 'Gesperrt' })
      : h('button', { type: 'button', class: 'sm primary', text: 'Ausführen', onclick: () => openRunDialog([a], sel ? sel.value : null) });
  const expl = (a.befehle && a.befehle.erklaerung) || [];
  const copyBtn = h('button', { type: 'button', class: 'copy', text: 'Kopieren', onclick: e => copyText(curCmd, e.currentTarget) });
  return h('div', { class: 'action' + (done ? ' quiet' : ''), 'data-id': a.id },
    h('div', { class: 'ah' }, chk, h('span', { class: 'at', text: a.titel }), levelsNode(a.nutzen, a.aufwand, a.risiko),
      a.neustart ? h('span', { class: 'lv' }, h('span', { class: 'restart', text: 'Neustart nötig' })) : null,
      h('div', { class: 'acts' }, sel, stateNode, btn)),
    a.erklaerung ? h('p', { class: 'ae', text: a.erklaerung }) : null,
    h('details', { class: 'cmd' }, h('summary', { text: 'Befehl zeigen und erklären' }),
      h('div', { class: 'code' }, h('div', { class: 'ch' }, h('span', { text: 'PowerShell · Administrator' }), copyBtn), cmdPre),
      expl.length ? h('ul', { class: 'explain' }, expl.map(x => h('li', { text: x }))) : null,
      a.befehle && a.befehle.rueckgaengig ? h('div', { class: 'note' }, 'Rückgängig: ', h('code', { text: a.befehle.rueckgaengig }), ' (der vorherige Wert wird im Journal gespeichert)') : null));
}
function updateMulti() {
  const n = S.sel.size;
  S.multiBtns.forEach(b => { b.disabled = !n || locked(); b.textContent = `Ausgewählte ausführen (${n})`; });
}
/** Akzeptieren am Befund: nur bei angezeigtem Bericht, offenen Status und nicht bei Sigcheck (dort je Datei). */
const canAccept = f => !!S.cur && ['CRIT', 'WARN', 'TIPP', 'INFO'].includes(f.Status) && norm(f.Check) !== SIG_CHECK;
function findingRow(f, opts = {}) {
  const m = S.checklist[f.Check];
  const acts = actionsFor(f);
  const note = f.Status === 'ACK' ? `Ursprünglich: ${STATUS_NAME[f.OriginalStatus] || f.OriginalStatus || ''} · ${f.Note || ''}` : f.Note;
  const todo = (isOpen(f) || canAccept(f)) ? h('div', { class: 'todo' },
    !isOpen(f) ? null : h('button', { type: 'button', class: m && m.state === 'done' ? 'on' : '', 'data-mark': 'done', title: 'Als erledigt markieren; der nächste Lauf zeigt, ob es wirklich behoben ist', text: '✔ erledigt', onclick: () => toggleMark(f.Check, 'done') }),
    !isOpen(f) ? null : h('button', { type: 'button', class: m && m.state === 'later' ? 'on' : '', 'data-mark': 'later', title: 'Für später vormerken', text: '⏱ später', onclick: () => toggleMark(f.Check, 'later') }),
    canAccept(f) ? h('button', { type: 'button', 'data-mark': 'acc', title: readOnly() ? lockTitle() : 'Diesen Befund in die Akzeptanzliste aufnehmen', disabled: readOnly(), text: 'Akzeptieren …', onclick: () => openAkzeptieren({ art: 'befund', check: f.Check }) }) : null) : null;
  const lvl = levelsNode(f.Benefit, f.Effort, f.Risk);
  const tbls = tablesFor(f.Check);
  const dataBtn = tbls.length ? h('button', { type: 'button', class: 'btn sm ghost data-link', title: 'Die Detailtabelle(n) zu dieser Prüfung im Anhang (Rohdaten) öffnen', text: `📋 Daten ansehen${tbls.length > 1 ? ` (${tbls.length})` : ''}`, onclick: () => openRaw(tbls) }) : null;
  return h('div', { class: 'card finding' + (m && m.state === 'done' ? ' m-done' : ''), 'data-check': f.Check, 'data-status': f.Status },
    h('div', { class: 'fhead' },
      h('span', { class: 'chip ' + f.Status, text: STATUS_NAME[f.Status] || f.Status }),
      h('span', { class: 'fname' }, f.Check, infoTip(f.Check, f.Category)),
      opts.hint ? h('span', { class: 'cat-hint', text: `${f.Area} · ${f.Category}` }) : null,
      dataBtn, todo),
    h('p', { class: 'fval', text: f.Value }),
    note ? h('div', { class: 'fnote', text: note }) : null,
    f.Recommendation ? h('div', { class: 'frec', text: f.Recommendation }) : null,
    defenderTool(f),
    sysTool(f),
    lvl ? h('div', { class: 'lvwrap' }, lvl) : null,
    howTo(f),
    acts.map(actionCard));
}
const DEF_FIND = { 'Defender: Signaturen': ['signaturen', 'Signaturen aktualisieren'], 'Defender: Scans': ['schnellscan', 'Schnellscan starten'] };
/** Knopf am Befund „Defender: Signaturen“ / „Defender: Scans“ (nur bei offenem Befund), startet dieselbe Aufgabe wie unter „Werkzeuge“. */
function defenderTool(f) {
  const d = DEF_FIND[norm(f.Check)];
  if (!d || f.Status === 'OK' || f.Status === 'ACK' || f.Status === 'SKIP') return null;
  return h('div', { class: 'deftool' },
    h('button', { type: 'button', class: 'sm primary', disabled: readOnly(), title: readOnly() ? lockTitle() : null, text: d[1], onclick: () => startDefender(d[0]) }),
    h('a', { href: '#/werkzeuge', text: 'Alle Defender-Werkzeuge →' }));
}
const SYS_FIND = new Set(['Autostarts: Signaturen (Autoruns)', 'Autostarts: beschreibbare Pfade (Autoruns)', 'Systemdateien: Signaturen (Sigcheck)']);
/** Link am Sysinternals-Befund zur Karte unter „Werkzeuge“, nur wenn dort etwas zu tun ist (nicht eingerichtet bzw. Werkzeug nicht vertrauenswürdig). */
function sysTool(f) {
  if (!SYS_FIND.has(norm(f.Check))) return null;
  const v = String(f.Value || '');
  let text = null;
  if (f.Status === 'SKIP' && v.startsWith('Sysinternals nicht eingerichtet')) text = 'Sysinternals einrichten →';
  else if (f.Status === 'WARN' && v.includes('nicht ausgeführt')) text = 'Werkzeuge neu herunterladen →';
  if (!text) return null;
  return h('div', { class: 'deftool' }, h('a', { href: '#/werkzeuge', text }));
}
function toggleMark(check, state) {
  // Im Nur-Lesen-Modus speichert der Server nichts (403), also auch lokal nichts ändern
  if (readOnly()) { toast('Im Nur-Lesen-Modus wird die Checkliste nicht gespeichert.'); return; }
  const m = S.checklist[check];
  if (m && m.state === state) delete S.checklist[check];
  else S.checklist[check] = { state, date: new Date().toLocaleDateString('de-DE'), report: S.report.Meta.Erstellt };
  api('/api/checklist', { method: 'POST', body: S.checklist }).catch(e => toast('Checkliste nicht gespeichert: ' + e.message));
  refreshView();
}
function banner(kind, iconId, ...kids) { return h('div', { class: 'banner' + (kind ? ' b-' + kind : '') }, icon(iconId), h('div', null, ...kids)); }
function reportBar() {
  if (!S.reports.length || S.cur === S.reports[0].name) return null;
  return banner('info', 'doc', h('b', { text: 'Du siehst den Bericht vom ' + fmtDate(S.report.Meta.Erstellt) + '. ' }), 'Es gibt einen neueren. ',
    h('button', { type: 'button', class: 'link', text: 'Zum neuesten Bericht', onclick: async () => { try { await showReport(S.reports[0].name); refreshView(); } catch (e) { toast(e.message); } } }));
}
// ---- Datenordner-Rechte (Vertrag 18.10)
const dOrd = () => (S.session && S.session.datenordner) || null;
const dOrdRepariert = d => Array.isArray(d.repariert) ? !!d.repariert[0] : !!d.repariert;
const dOrdReparierbar = () => { const d = dOrd(); return !!(d && d.zustand === 'reparierbar' && !dOrdRepariert(d)); };
function dOrdKonten(d) { return (d.konten || []).map(k => (k.rechte === 'schreiben' ? 'Vollzugriff für ' : 'Leserecht für ') + (k.name || k.sid)).join(', '); }
function dOrdHinweis() {
  // Der Server liefert reparaturZeit auf oberster Ebene von /api/session (auch im normalen Modus, höchstens 7 Tage alt)
  const zeit = S.session && S.session.reparaturZeit;
  if (!zeit || dOrdReparierbar()) return null;
  return banner('', 'warn', h('b', { text: 'Der Datenordner wurde am ' + fmtDate(zeit) + ' repariert. ' }), 'Bitte prüfen, ob alle Einträge von dir stammen.');
}
function dOrdBanner() {
  const d = dOrd();
  const b = banner('err', 'warn', h('b', { text: 'Die Rechte des Datenordners wurden geändert' }),
    h('p', { text: (dOrdKonten(d) || 'Weitere Konten') + (d.pfad ? ' auf ' + d.pfad : '') + '. Ursache: meist „Fortsetzen“ im Explorer.' }),
    h('p', { text: 'Risiko: Programme unter diesem Konto könnten Morpheus’ Daten ändern. Bis zur Reparatur ist Morpheus im Nur-Lesen-Modus.' }),
    h('div', { class: 'brow' },
      h('button', { type: 'button', class: 'sm primary', 'data-f': 'repair', text: 'Rechte reparieren …', onclick: () => openDatenordner('reparieren') }), ' ',
      h('button', { type: 'button', class: 'sm', 'data-f': 'neu', text: 'Stattdessen neu anlegen …', onclick: () => openDatenordner('neu') })));
  b.classList.add('dord-banner');
  return b;
}
/** Das Datenordner-Banner gehört auf jede Ansicht (auch ohne Bericht, z. B. auf der Übersicht beim Start). */
function dOrdBannerEinsetzen(node) {
  if (!dOrdReparierbar() || !node || node.querySelector('.dord-banner')) return;
  const h1 = node.querySelector('h1');
  const b = dOrdBanner();
  if (h1 && h1.parentNode) {
    // nach Titel und Untertitel einfügen
    let nach = h1;
    if (nach.nextElementSibling && nach.nextElementSibling.classList.contains('sub')) nach = nach.nextElementSibling;
    nach.after(b);
  } else node.prepend(b);
}
function openDatenordner(art) {
  const d = dOrd() || {}, neu = art === 'neu';
  const body = neu ? [
    h('p', { text: `Der Ordner wird beiseitegelegt (${(d.pfad || 'C:\\ProgramData\\Morpheus')}.unsicher-<Datum>) und leer neu angelegt.` }),
    h('p', { class: 'warn', text: 'Berichte, Journal und Akzeptanzliste sind dann in Morpheus nicht mehr sichtbar.' }),
    h('p', { class: 'muted', text: 'Windows fragt danach in einem eigenen Fenster nach.' })]
  : [
    h('p', { text: 'Das passiert:' }),
    h('ul', null,
      h('li', { text: 'Die Rechte der genannten Konten werden entfernt' + (dOrdKonten(d) ? ' (' + dOrdKonten(d) + ')' : '') + '.' }),
      h('li', { text: 'temp, tools und der gespeicherte Zustand werden neu angelegt.' }),
      h('li', { text: 'Journal, Akzeptanzliste und Checkliste bleiben und werden neu geschrieben.' }),
      h('li', { text: 'Berichte bleiben unverändert.' }),
      h('li', { text: 'Die Sysinternals-Werkzeuge werden bei Bedarf neu geladen.' })),
    h('p', { class: 'muted', text: 'Windows fragt danach in einem eigenen Fenster nach.' })];
  dlgOpen(neu ? 'Datenordner neu anlegen' : 'Rechte des Datenordners reparieren', body,
    [{ label: 'Abbrechen', onClick: dlgClose }, neu ? { label: 'Neu anlegen', danger: true, onClick: () => runDatenordner(art) } : { label: 'Rechte reparieren', primary: true, onClick: () => runDatenordner(art) }]);
}
async function runDatenordner(art) {
  const title = art === 'neu' ? 'Datenordner neu anlegen' : 'Rechte des Datenordners reparieren';
  dlgOpen(title, [h('p', { text: 'Bitte im Windows-Fenster „Morpheus – Änderung bestätigen“ mit „Ja“ bestätigen …' })], [{ label: 'Läuft …', disabled: true }], { lock: true });
  let r = null, err = null;
  try { r = await api('/api/datenordner/reparieren', { method: 'POST', body: { art } }); } catch (x) { err = x; }
  Dlg.running = false;
  if (err || !r || r.ok === false) {
    const msg = err ? (err.status === 403 ? 'Im Windows-Dialog abgelehnt. Es wurde nichts geändert.' : err.message) : (r && r.meldung) || 'Das hat nicht geklappt.';
    dlgOpen(title, [h('p', { class: 'rem', text: msg })], [{ label: 'Schließen', primary: true, onClick: dlgClose }]);
    return;
  }
  const d = dOrd(); if (d) d.repariert = [true];
  const note = h('p', { class: 'muted' });
  const quit = async () => {
    try { await api('/api/shutdown', { method: 'POST' }); } catch { /* Server beendet sich, die Antwort kann ausbleiben */ }
    note.textContent = 'Morpheus wurde beendet. Morpheus über das Startmenü neu starten.';
    dlgOpen(title, [h('p', { class: 'ok', text: 'Morpheus wurde beendet.' }), h('p', { text: 'Morpheus über das Startmenü neu starten.' })], [{ label: 'Schließen', primary: true, onClick: dlgClose }]);
  };
  dlgOpen(title, [h('p', { class: 'ok', text: r.meldung || 'Fertig.' }), h('p', { text: 'Morpheus muss neu gestartet werden, damit es wieder normal arbeitet.' }), note],
    [{ label: 'Später', onClick: () => { dlgClose(); refreshView(); } }, { label: 'Morpheus beenden', primary: true, onClick: quit }]);
}
function safetyBanner() {
  const s = safety();
  if (dOrdReparierbar()) return dOrdBanner();
  if (readOnly()) {
    return banner('err', 'warn', h('b', { text: 'Nur-Lesen-Modus: ' }), (S.session.readOnlyReason || 'Morpheus läuft nicht aus einem gesicherten Ordner.') + ' Änderungen, „Rückgängig“ und Scans sind gesperrt. Starte Morpheus über das Startmenü bzw. ',
      h('code', { text: 'C:\\Program Files\\Morpheus\\pc-check-gui.cmd' }), '.');
  }
  if (s.schutzAn === false) {
    const cmd = `Enable-ComputerRestore -Drive '${(s.laufwerk || 'C:').replace(/\\$/, '')}\\'`;
    return banner('err', 'warn', h('b', { text: 'Computerschutz ist aus: ' }), 'Ohne Wiederherstellungspunkt führt die GUI keine Änderungen aus. Alle Ausführen-Buttons sind gesperrt.',
      h('details', { class: 'cmd' }, h('summary', { text: 'Befehl zum Einschalten (Administrator-PowerShell)' }), cmdBlock(cmd),
        h('ul', { class: 'explain' }, h('li', { text: 'Schaltet den Computerschutz (Systemwiederherstellung) für das Laufwerk ein. Danach die GUI-Seite neu laden.' }))));
  }
  if (s.speicherKlein) {
    return banner('', 'warn', h('b', { text: 'Speicher für Wiederherstellungspunkte zu klein. ' }), `Erlaubt sind nur ${s.speicherMax || 'wenige GB'}. Windows löscht ältere Punkte, sobald neue entstehen; das Netz vor Änderungen hält dann nur kurz. Rückgängig über „Änderungen“ funktioniert trotzdem. `,
      h('a', { href: '#/sicherheit', text: 'Unter Sicherheit > Wiederherstellung vergrößern' }), '.');
  }
  if (s.sperre24h) {
    return banner('', 'warn', h('b', { text: '24-Stunden-Sperre aktiv. ' }), 'Windows legt höchstens einen Wiederherstellungspunkt pro 24 Stunden an. Solange das so ist, kann die GUI heute eventuell keine weitere Änderung absichern und führt sie dann nicht aus.',
      h('details', { class: 'cmd' }, h('summary', { text: 'Befehl zum Aufheben der Sperre (einmalig, Administrator-PowerShell)' }), cmdBlock(s.befehl || ''),
        h('ul', { class: 'explain' }, h('li', { text: 'Setzt den Mindestabstand zwischen zwei Wiederherstellungspunkten auf 0 Minuten.' }), h('li', null, 'Rückgängig: den Wert wieder löschen (', h('code', { text: 'Remove-ItemProperty … -Name SystemRestorePointCreationFrequency' }), ').'))));
  }
  return null;
}
const MONO_COL = /^(Pfad|Path|Image Path|Launch String|Befehl\w*|Ort|Datei(?:name|pfad)?|Sha256)$|(^|[\s_-])(Pfad|Path|Befehl|Ort|Datei|Dateiname|Sha256)($|[\s_-])/i;
const accLocal = new Set();   // lokal als „akzeptiert (ab nächstem Scan)“ markierte Sigcheck-Dateien (Pfad klein)
const SIG_TABLE = 'Unsignierte Systemdateien (Sigcheck)', SIG_CHECK = 'Systemdateien: Signaturen (Sigcheck)';
const cellText = v => v == null ? '' : (typeof v === 'boolean' ? (v ? 'Ja' : 'Nein') : (typeof v === 'object' ? JSON.stringify(v) : v));
function tableFrom(rows, max = 300, name = '') {
  rows = (rows || []).filter(r => r != null);
  if (!rows.length) return h('p', { class: 'muted', text: 'Keine Einträge.' });
  const cols = Object.keys(rows[0]);
  const sig = norm(name) === SIG_TABLE && !!S.cur;
  const t = h('div', { class: 'tbl-scroll' }, h('table', null,
    h('thead', null, h('tr', null, cols.map(c => h('th', { text: c })), sig ? h('th', { text: 'Aktionen' }) : null)),
    h('tbody', null, rows.slice(0, max).map(r => { const cell = sig ? h('td') : null; if (cell) cell.append(sigActions(r, cell)); return h('tr', null, cols.map(c => h('td', { class: MONO_COL.test(c) ? 'mono' : null, text: cellText(r[c]) })), cell); }))));
  return rows.length > max ? h('div', null, t, h('p', { class: 'muted', text: `… ${rows.length - max} weitere Einträge im JSON-Bericht.` })) : t;
}
/** Aktionen je Zeile der Sigcheck-Tabelle (Vertrag 16.5). */
function sigActions(r, cell) {
  const ro = readOnly(), tt = ro ? lockTitle() : null, pfad = String(r.Pfad || ''), sha = String(r.Sha256 || '');
  const okHash = /^[0-9a-fA-F]{64}$/.test(sha), acc = String(r.Akzeptiert || ''), lokal = accLocal.has(pfad.toLowerCase());
  if (!okHash) return h('div', { class: 'row-acts' }, acc ? [h('span', { class: 'chip OK', title: acc, text: 'akzeptiert' }), ' '] : null, h('span', { class: 'muted', text: 'Für diese Zeile neu scannen (der Bericht enthält keinen Hash).' }));
  return h('div', { class: 'row-acts' },
    h('button', { type: 'button', class: 'sm', disabled: ro, title: tt, text: 'Mit Defender prüfen', onclick: () => startDefenderDatei(pfad) }), ' ',
    acc ? h('span', { class: 'chip OK', title: acc, text: 'akzeptiert' })
      : lokal ? h('span', { class: 'chip OK', text: 'akzeptiert (ab nächstem Scan)' })
      : h('button', { type: 'button', class: 'sm', disabled: ro, title: tt, text: 'Akzeptieren …', onclick: () => openAkzeptieren({ art: 'datei', pfad, sha256: sha, onDone: () => { accLocal.add(pfad.toLowerCase()); if (cell && cell.isConnected) cell.replaceChildren(sigActions(r, cell)); } }) }), ' ',
    okHash ? h('a', { href: 'https://www.virustotal.com/gui/file/' + sha.toLowerCase(), target: '_blank', rel: 'noopener noreferrer', title: 'Öffnet deinen Browser; dabei geht nur der Hash an VirusTotal.', text: 'VirusTotal ↗' }) : null, ' ',
    okHash ? h('button', { type: 'button', class: 'sm ghost', text: 'Hash kopieren', onclick: e => copyText(sha, e.currentTarget) }) : null);
}
function noReport() {
  return h('div', { class: 'card' }, h('h2', { text: 'Noch kein Bericht vorhanden' }), h('p', null, 'Starte unter ', h('a', { href: '#/scan', text: 'Neuer Scan' }), ' die erste Prüfung.'));
}

// ---------------------------------------------------------------- Navigation und Kopfleiste
function badgeFor(id) {
  if (!S.report) return null;
  const list = S.findings.filter(f => viewOf(f) === id);
  const c = counts(list), n = c.CRIT + c.WARN + c.TIPP;
  if (!n) return null;
  return h('span', { class: 'cnt ' + (c.CRIT ? 'c' : c.WARN ? 'w' : 't'), title: `${c.CRIT} kritisch, ${c.WARN} Warnungen, ${c.TIPP} Tipps`, text: String(n) });
}
// ---- Aufklappbares Menü (2.5, #65): Bereiche klappen Kategorien, Filter bzw. Werkzeuge auf; Zustand je Benutzer in localStorage
function navLaden() {
  try { const o = JSON.parse(localStorage.getItem(NAV_KEY) || '{}'); return (o && typeof o === 'object' && !Array.isArray(o)) ? o : {}; } catch { return {}; }
}
function navIstAuf(key) {
  if (!S.navAuf) S.navAuf = navLaden();
  return Object.prototype.hasOwnProperty.call(S.navAuf, key) ? S.navAuf[key] === true : !!NAV_STANDARD_AUF[key];
}
function navUmschalten(key, auf) {
  const neu = auf == null ? !navIstAuf(key) : !!auf;
  if (!S.navAuf) S.navAuf = navLaden();
  S.navAuf[key] = neu;
  try { localStorage.setItem(NAV_KEY, JSON.stringify(S.navAuf)); } catch { /* ohne Speicher weiter */ }
  const item = [...document.querySelectorAll('#nav .nv-item')].find(x => x.dataset.key === key);
  if (!item) return;
  const btn = item.querySelector(':scope > .nv-row > .nv-tog'), sub = item.querySelector(':scope > .nv-sub');
  item.classList.toggle('auf', neu);
  if (sub) sub.hidden = !neu;
  if (btn) { btn.setAttribute('aria-expanded', neu ? 'true' : 'false'); btn.setAttribute('aria-label', (neu ? MENU_TEXTE.aria.zu : MENU_TEXTE.aria.auf).replace('{0}', () => btn.dataset.label)); }
}
/** Unterpunkte: [{ key, label, view, ziel?: { sel } | { kat } | { wt }, filter?, kinder?, leer? }] */
function navKinder(n) {
  if (n.kinder === 'kategorien') {
    if (!S.report) return [{ key: n.id + '/leer', label: MENU_TEXTE.unter.keinBericht, view: n.id, leer: true }];
    const kats = [];
    S.findings.forEach(f => { if (viewOf(f) === n.id && !kats.includes(f.Category)) kats.push(f.Category); });
    const out = kats.map(k => ({ key: n.id + '/kat/' + k, label: k, view: n.id, ziel: { kat: k } }));
    if (n.id === 'gaming' && GAMING_CHECKS.some(c => findingByCheck(c))) out.unshift({ key: 'gaming/check', label: MENU_TEXTE.unter.gamingCheck, view: 'gaming', ziel: { sel: '#gaming-check' } });
    return out;
  }
  if (n.kinder === 'filter') return Object.entries(MENU_TEXTE.filter).map(([m, l]) => ({ key: 'alle/filter/' + m, label: l, view: 'alle', filter: m }));
  if (n.kinder === 'werkzeuge') {
    const u = MENU_TEXTE.unter;
    return [
      { key: 'werkzeuge/wartung', label: u.wartung, view: 'werkzeuge', ziel: { sel: '#wartung-card' },
        kinder: MENU_TEXTE.werkzeuge.map(([id, l]) => ({ key: 'werkzeuge/wt/' + id, label: l, view: 'werkzeuge', ziel: { wt: id } })) },
      { key: 'werkzeuge/defender', label: u.defender, view: 'werkzeuge', ziel: { sel: '#def-card' } },
      { key: 'werkzeuge/updates', label: u.updates, view: 'werkzeuge', ziel: { sel: '#upd-card' } },
      { key: 'werkzeuge/sysinternals', label: u.sysinternals, view: 'werkzeuge', ziel: { sel: '#sys-card' } },
      { key: 'werkzeuge/spiele', label: u.spieleOrdner, view: 'werkzeuge', ziel: { sel: '#spo-card' } },
    ];
  }
  return [];
}
/** Klick auf einen Unterpunkt: Ansicht öffnen, Filter setzen bzw. zum Ziel springen */
function navGehe(k) {
  S.ui.navSub = k.leer ? null : k.key;
  let neuZeichnen = false;
  if (k.filter) { const f = uiF('alle'); neuZeichnen = f.mode !== k.filter || !!f.term; S.ui.f.alle = { mode: k.filter, term: '' }; }
  if (k.ziel) {
    S.ui.navZiel = k.ziel;
    // Eine Kategorie ist nur sichtbar, wenn Filter und Suche sie nicht ausblenden
    if (k.ziel.kat) { const f = uiF(k.view); neuZeichnen = f.mode !== 'all' || !!f.term; S.ui.f[k.view] = { mode: 'all', term: '' }; }
  }
  if (location.hash === '#/' + k.view) {
    // Gleiche Ansicht: nicht neu zeichnen (Karten wie „Wartung & Reparatur“ würden neu laden und das Ziel verschieben),
    // nur Menü markieren und springen. Neu gezeichnet wird nur, wenn ein Filter das Ziel ausblendet.
    if (neuZeichnen) refreshView(); else renderNav();
    navZielZeigen();
  } else { S.ui.navSubNeu = true; location.hash = '#/' + k.view; }
}
function navZielSuchen(z) {
  if (z.sel) return $(z.sel);
  if (z.kat) return [...document.querySelectorAll('#view .section-title[data-kat]')].find(x => x.dataset.kat === z.kat) || null;
  if (z.wt) return z.wt === WT_PUNKT_ID ? $('#wt-punkt') : ([...document.querySelectorAll('#view .wt-row[data-id]')].find(x => x.dataset.id === z.wt) || null);
  return null;
}
// Scrollt so, dass das Ziel um seinen scroll-margin-top unter der Oberkante steht. Bewusst nicht scrollIntoView:
// Im Edge-App-Fenster landete das bei Sprüngen innerhalb einer Ansicht teils am Seitenende (Mock-Test 2.5).
function navScrollZu(el) {
  const soll = parseFloat(getComputedStyle(el).scrollMarginTop) || 0;
  window.scrollTo({ top: Math.max(0, Math.round(window.scrollY + el.getBoundingClientRect().top - soll)), behavior: 'instant' });
  return soll;
}
let navHalten = null;
function navHaltenStopp() {
  if (!navHalten) return;
  clearInterval(navHalten.timer);
  ['wheel', 'touchstart', 'keydown', 'mousedown'].forEach(t => window.removeEventListener(t, navHaltenStopp, true));
  navHalten = null;
}
/** Springt zum gemerkten Ziel. Werkzeuge laden nach: Das Ziel kann erst später entstehen (bis 30 Versuche à 150 ms) und durch
 *  nachgeladene Karten darüber verschoben werden. Deshalb hält ein Wächter es bis zu 8 s an seinem Platz, bis der Nutzer selbst
 *  scrollt, klickt oder tippt. */
function navZielZeigen(versuch = 0) {
  const z = S.ui.navZiel; if (!z) return;
  const el = navZielSuchen(z);
  if (!el) {
    if (versuch < 30) setTimeout(() => { if (S.ui.navZiel === z) navZielZeigen(versuch + 1); }, 150);
    else S.ui.navZiel = null;
    return;
  }
  S.ui.navZiel = null;
  navHaltenStopp();
  navScrollZu(el);
  if (!el.hasAttribute('tabindex')) el.setAttribute('tabindex', '-1');
  el.focus({ preventScroll: true });
  el.classList.remove('nv-flash'); void el.offsetWidth; el.classList.add('nv-flash');
  const start = Date.now(), view = S.view;
  navHalten = { timer: setInterval(() => {
    if (Date.now() - start > 8000 || S.view !== view) { navHaltenStopp(); return; }
    const ziel = el.isConnected ? el : navZielSuchen(z);
    if (!ziel) return;
    const soll = parseFloat(getComputedStyle(ziel).scrollMarginTop) || 0, ist = ziel.getBoundingClientRect().top;
    const amEnde = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2;
    if (Math.abs(ist - soll) > 6 && !(amEnde && ist > soll)) navScrollZu(ziel);
  }, 120) };
  ['wheel', 'touchstart', 'keydown', 'mousedown'].forEach(t => window.addEventListener(t, navHaltenStopp, true));
}
let navUid = 0;
function navEintrag(e) {
  const hat = !!(e.kinder && e.kinder.length), auf = hat && navIstAuf(e.key), subId = 'nv-sub-' + (++navUid);
  const link = h('a', { href: e.href, class: 'nv-link' + (e.aktiv ? ' on' : '') + (e.leer ? ' leer' : ''), 'aria-current': e.aktiv ? (e.ebene ? 'location' : 'page') : null, onclick: e.onclick },
    e.ic ? icon(e.ic) : null, h('span', { class: 'nv-label', text: e.label }), e.badge);
  const tog = hat ? h('button', { type: 'button', class: 'nv-tog', 'aria-expanded': auf ? 'true' : 'false', 'aria-controls': subId, 'data-label': e.label,
    'aria-label': (auf ? MENU_TEXTE.aria.zu : MENU_TEXTE.aria.auf).replace('{0}', () => e.label), onclick: () => navUmschalten(e.key) }, icon('chev')) : null;
  const item = h('div', { class: 'nv-item lv' + e.ebene + (auf ? ' auf' : ''), 'data-key': e.key }, h('div', { class: 'nv-row' }, link, tog));
  if (hat) item.append(h('div', { class: 'nv-sub', id: subId, role: 'group', 'aria-label': e.label, hidden: !auf }, e.kinder.map(navEintrag)));
  return item;
}
function navUnter(k, ebene) {
  const aktiv = S.view === k.view && !k.leer && (k.filter ? uiF('alle').mode === k.filter : S.ui.navSub === k.key);
  return { key: k.key, label: k.label, href: '#/' + k.view, aktiv, ebene, leer: k.leer, kinder: k.kinder ? k.kinder.map(x => navUnter(x, ebene + 1)) : null,
    onclick: ev => { ev.preventDefault(); navGehe(k); } };
}
function renderNav() {
  const sess = S.session || {};
  const fokus = document.activeElement && document.activeElement.closest && document.activeElement.closest('#nav .nv-item');
  const fokusKey = fokus ? fokus.dataset.key : null, fokusTog = !!(fokusKey && document.activeElement.classList.contains('nv-tog'));
  navUid = 0;
  $('#nav').replaceChildren(h('div', { class: 'navgroup' }, NAV.map(n => {
    if (n.group) return h('div', { class: 'navh', text: n.group });
    let b = null;
    if (n.badge) b = badgeFor(n.id);
    else if (n.id === 'berichte') b = S.reports.length ? h('span', { class: 'cnt n', text: String(S.reports.length) }) : null;
    else if (n.id === 'checkliste') { const k = Object.keys(S.checklist).length; b = k ? h('span', { class: 'cnt i', text: String(k) }) : null; }
    const kinder = n.kinder ? navKinder(n).map(k => navUnter(k, 1)) : null;
    // Klick auf den Bereich öffnet die Ansicht und klappt ihn auf (wie im Azure Portal)
    return navEintrag({ key: n.id, label: n.label, href: '#/' + n.id, ic: n.icon, badge: b, aktiv: S.view === n.id, ebene: 0, kinder,
      onclick: () => { if (kinder && kinder.length && !navIstAuf(n.id)) navUmschalten(n.id, true); S.ui.navSub = null; } });
  })));
  if (fokusKey) {
    const it = [...document.querySelectorAll('#nav .nv-item')].find(x => x.dataset.key === fokusKey);
    const ziel = it && it.querySelector(fokusTog ? ':scope > .nv-row > .nv-tog' : ':scope > .nv-row > a');
    if (ziel) ziel.focus({ preventScroll: true });
  }
  $('#side-foot').replaceChildren(h('span', { class: 'dot' }), `${sess.pc || ''}${sess.version ? ' · v' + sess.version : ''}${sess.admin ? ' · Admin' : ''}`);
  updateChrome();
}
/** Tastatur: Pfeil hoch/runter wandert durch die sichtbaren Einträge, rechts klappt auf bzw. geht zum ersten Unterpunkt, links klappt zu bzw. geht zum Oberpunkt */
function initNav() {
  const nav = $('#nav');
  nav.setAttribute('aria-label', MENU_TEXTE.aria.nav);
  nav.addEventListener('keydown', ev => {
    if (ev.altKey || ev.ctrlKey || ev.metaKey || ev.shiftKey) return;
    const item = ev.target.closest && ev.target.closest('.nv-item'); if (!item) return;
    const linkVon = it => it && it.querySelector(':scope > .nv-row > a');
    const links = [...nav.querySelectorAll('a.nv-link')].filter(a => a.offsetParent !== null);
    const i = links.indexOf(linkVon(item));
    const hat = !!item.querySelector(':scope > .nv-sub'), auf = item.classList.contains('auf');
    let ziel = null;
    switch (ev.key) {
      case 'ArrowDown': ziel = links[Math.min(links.length - 1, i + 1)]; break;
      case 'ArrowUp': ziel = links[Math.max(0, i - 1)]; break;
      case 'Home': ziel = links[0]; break;
      case 'End': ziel = links[links.length - 1]; break;
      case 'ArrowRight':
        if (!hat) return;
        if (!auf) { navUmschalten(item.dataset.key, true); ziel = linkVon(item); }
        else ziel = item.querySelector(':scope > .nv-sub a.nv-link');
        break;
      case 'ArrowLeft':
        if (hat && auf) { navUmschalten(item.dataset.key, false); ziel = linkVon(item); }
        else ziel = linkVon(item.parentElement && item.parentElement.closest('.nv-item'));
        break;
      default: return;
    }
    ev.preventDefault();
    if (ziel) ziel.focus();
  });
}
function updateChrome() {
  const m = S.report && S.report.Meta;
  $('#crumb').replaceChildren(...(m ? ['Bericht vom ', h('b', { text: fmtDate(m.Erstellt) }), ` · Profil ${m.Profil || '–'}`] : ['Noch kein Bericht vorhanden']));
  $('#ki-btn').disabled = !S.report;
  syncSearch();
  renderStatusReport();
}
function syncSearch() {
  const i = $('#gsearch');
  if (document.activeElement !== i) i.value = CAT_VIEWS.includes(S.view) ? (uiF(S.view).term || '') : '';
}
function initTopbar() {
  const gs = $('#gsearch');
  gs.addEventListener('input', e => {
    const term = e.target.value.trim().toLowerCase();
    const v = CAT_VIEWS.includes(S.view) ? S.view : 'alle';
    if (v !== S.view && !term) return;
    uiF(v).term = term;
    if (v !== S.view) location.hash = '#/' + v; else refreshView();
  });
  gs.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); if (gs.value) { gs.value = ''; gs.dispatchEvent(new Event('input')); } gs.blur(); } });
  document.addEventListener('keydown', e => {
    if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey || $('#modal').classList.contains('on')) return;
    const t = e.target, tag = t && t.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || (t && t.isContentEditable)) return;
    e.preventDefault(); gs.focus(); gs.select();
  });
  $('#ki-btn').addEventListener('click', e => { if (S.report) copyText(buildKi(), $('#ki-btn span')); });
}

// ---------------------------------------------------------------- Ansicht: Kategorien
const FILTERS = [['all', 'Alle'], ['problem', 'Probleme'], ['CRIT', 'Kritisch'], ['WARN', 'Warnungen'], ['TIPP', 'Tipps'], ['INFO', 'Hinweise'], ['ACK', 'Akzeptiert'], ['OK', 'OK'], ['SKIP', 'Nicht geprüft']];
function passes(f, st) {
  let ok = st.mode === 'all' || (st.mode === 'problem' ? isProblem(f) : f.Status === st.mode);
  if (ok && st.term) ok = `${f.Check} ${f.Value} ${f.Recommendation} ${f.Category}`.toLowerCase().includes(st.term);
  return ok;
}
function miniChips(list) {
  const c = counts(list);
  return [...STATUS.filter(s => c[s] && s !== 'OK'), ...(c.OK ? ['OK'] : [])].map(s => h('span', { class: 'chip ' + s, text: `${c[s]} ${STATUS_NAME[s]}` }));
}
function catView(id, title, sub, pred, extra) {
  const fs = S.findings.filter(pred), st = uiF(id);
  const box = h('div');
  const filtBtns = FILTERS.map(([m, l]) => h('button', { type: 'button', 'data-filter': m, class: st.mode === m ? 'active' : '', text: l, onclick: () => { st.mode = m; build(); } }));
  const multi = h('button', { type: 'button', class: 'primary', text: 'Ausgewählte ausführen (0)', disabled: true, onclick: () => openRunDialog(S.actions.filter(a => S.sel.has(a.id))) });
  const hasActions = S.actions.length > 0;
  const bar = h('div', { class: 'toolbar sticky' }, h('div', { class: 'filters', role: 'group', 'aria-label': 'Filter nach Status' }, filtBtns), hasActions ? h('div', { class: 'tools' }, multi) : null);
  if (hasActions) { S.multiBtns = [multi]; }
  const mine = S.actions.filter(a => actionView(a) === id && !findingByCheck(norm(a.pruefung)));
  function build() {
    filtBtns.forEach(b => b.classList.toggle('active', b.dataset.filter === st.mode));
    const groups = [];
    fs.forEach(f => { let g = groups.find(x => x.cat === f.Category); if (!g) groups.push(g = { cat: f.Category, all: [], vis: [] }); g.all.push(f); if (passes(f, st)) g.vis.push(f); });
    const nodes = [];
    groups.forEach(g => {
      if (!g.vis.length) return;
      nodes.push(h('div', { class: 'section-title', 'data-kat': g.cat }, h('h3', null, g.cat, infoTip('', g.cat)), miniChips(g.all), h('span', { class: 'bar' })));
      g.vis.forEach(f => nodes.push(findingRow(f)));
    });
    if (!nodes.length && fs.length) nodes.push(h('div', { class: 'card muted', text: 'Keine Prüfung passt zu Filter und Suche.' }));
    if (!fs.length && !mine.length) nodes.push(h('div', { class: 'card muted', text: 'Keine Prüfungen in diesem Bereich.' }));
    if (mine.length && st.mode === 'all' && !st.term) nodes.push(h('div', { class: 'more' }, h('div', { class: 'section-title' }, h('h3', { text: 'Weitere Anpassungen' }), h('span', { class: 'bar' })), h('div', { class: 'card' }, mine.map(actionCard))));
    box.replaceChildren(...nodes);
    updateMulti();
    if (S.ui.reveal) doReveal();
  }
  const root = h('section', null, h('h1', { text: title }), h('p', { class: 'sub', text: sub }), reportBar(), safetyBanner(), extra ? extra() : null, bar, box);
  build();
  return root;
}
function gamingGrid() {
  const rows = GAMING_CHECKS.map(c => findingByCheck(c)).filter(Boolean);
  if (!rows.length) return null;
  return h('div', { id: 'gaming-check' }, h('div', { class: 'section-title' }, h('h3', { text: 'Gaming-Check' }), h('span', { class: 'bar' })), h('div', { class: 'card' }, h('div', { class: 'gaming' }, rows.map(f =>
    h('div', { class: 'g-item', style: `--c:${STATUS_COLOR[f.Status]}` },
      h('span', { class: 'chip ' + f.Status, text: STATUS_NAME[f.Status] }),
      h('a', { href: '#/gaming', text: f.Check, onclick: e => { e.preventDefault(); reveal(f.Check); } }),
      h('div', { class: 'v', text: f.Value }))))));
}
const V = {};
V.sicherheit = () => catView('sicherheit', 'Sicherheit', 'Kategorien 1–10 des Berichts · Anpassungen mit Button lassen sich direkt und abgesichert umsetzen.', f => viewOf(f) === 'sicherheit');
V.leistung = () => catView('leistung', 'Leistung', 'Hardware · Laufwerke & Speicherplatz · Energie · Auslastung', f => viewOf(f) === 'leistung');
V.gaming = () => catView('gaming', 'Gaming', 'Gaming & Grafik und die spielerelevanten Prüfungen', f => viewOf(f) === 'gaming', gamingGrid);
V.stabilitaet = () => catView('stabilitaet', 'Stabilität', 'Abstürze, Bluescreens, Treiberfehler und Startdauer', f => viewOf(f) === 'stabilitaet');
V.alle = () => catView('alle', 'Alle Prüfungen', 'Alle Bereiche, gefiltert nach Status oder Suchbegriff', () => true);

// ---------------------------------------------------------------- Ansicht: Übersicht
/** Zustandswert: 100 − 20·Kritisch − 5·Warnung − 1·Tipp (mindestens 0). */
const scoreOf = c => Math.max(0, 100 - 20 * (c.CRIT || 0) - 5 * (c.WARN || 0) - (c.TIPP || 0));
function scoreInfo(v) {
  if (v >= 85) return { title: 'Gut in Form', c1: '#2aa198', c2: '#859900' };
  if (v >= 60) return { title: 'Einige Punkte prüfen', c1: '#b58900', c2: '#e0b23a' };
  return { title: 'Handlungsbedarf', c1: '#cb4b16', c2: '#dc322f' };
}
function chartNode(title, pts, prop, unit, better, color) {
  pts = pts.filter(p => p[prop] != null);
  if (pts.length < 2) return null;
  const w = 300, hh = 64, px = 6, py = 8;
  const vals = pts.map(p => p[prop]);
  const min = Math.min(...vals); let max = Math.max(...vals); if (max === min) max = min + 1;
  const xy = pts.map((p, i) => ({ x: +(px + (w - 2 * px) * i / (pts.length - 1)).toFixed(1), y: +(py + (hh - 2 * py) * (1 - (p[prop] - min) / (max - min))).toFixed(1), v: p[prop], d: fmtShort(p.datum) }));
  const first = vals[0], last = vals[vals.length - 1];
  const trend = last === first ? 'gleich' : ((last < first) === (better === 'low') ? 'besser' : 'schlechter');
  const s = svg('svg', { viewBox: `0 0 ${w} ${hh}`, preserveAspectRatio: 'none', role: 'img', 'aria-label': title });
  const line = xy.map(p => `${p.x},${p.y}`).join(' ');
  const gid = 'ga' + Math.random().toString(36).slice(2, 8);
  const defs = svg('defs'), lg = svg('linearGradient', { id: gid, x1: '0', y1: '0', x2: '0', y2: '1' });
  lg.append(svg('stop', { offset: '0', 'stop-color': color || '#2aa198', 'stop-opacity': '.35' }), svg('stop', { offset: '1', 'stop-color': color || '#2aa198', 'stop-opacity': '0' }));
  defs.append(lg); s.append(defs);
  s.append(svg('path', { class: 'area', d: `M${xy[0].x},${hh} L${line.replace(/ /g, ' L')} L${xy[xy.length - 1].x},${hh}Z`, fill: `url(#${gid})` }));
  s.append(svg('polyline', { points: line }));
  xy.forEach(p => { const c = svg('circle', { cx: p.x, cy: p.y, r: 3 }); const t = svg('title'); t.textContent = `${p.d}: ${p.v} ${unit}`; c.append(t); s.append(c); });
  return h('div', { class: 'chart', style: color ? `--c:${color}` : null },
    h('div', { class: 'chart-head' }, h('span', { text: title }), h('span', { class: trend === 'gleich' ? 'muted' : (trend === 'besser' ? 'trend up' : 'trend down'), text: trend })),
    h('div', { class: 'n', text: `${last}${unit ? ' ' + unit : ''}` }),
    s, h('div', { class: 'chart-foot' }, h('span', { text: xy[0].d }), h('span', { text: xy[xy.length - 1].d })));
}
function historyPoint(r, created) {
  const F = r.Findings || [], D = r.Data || {};
  const boot = (D['Startdauer (letzte Messungen)'] || []).filter(Boolean).map(x => Number(x.HauptpfadSek)).filter(x => !isNaN(x));
  const rel = F.find(f => norm(f.Check) === 'Zuverlässigkeitsindex');
  const mm = rel && /^([\d.,]+) von/.exec(rel.Value || '');
  const vol = (D['Laufwerke (Volumes)'] || []).find(v => v.Laufwerk === 'C:');
  return {
    datum: created,
    zustand: scoreOf(counts(F)),
    probleme: F.filter(isProblem).length,
    startSek: boot.length ? Math.round(boot.reduce((a, b) => a + b, 0) / boot.length * 10) / 10 : null,
    index: mm ? Number(mm[1].replace(',', '.')) : null,
    freiC: vol && vol.FreiProzent != null ? Number(vol.FreiProzent) : null,
  };
}
async function fillCharts(box, token) {
  const list = S.reports.slice(0, 12).slice().reverse();
  const quick = list.map(r => ({ datum: r.created, zustand: scoreOf(r.counts || {}), probleme: ((r.counts || {}).CRIT || 0) + ((r.counts || {}).WARN || 0), startSek: null, index: null, freiC: null }));
  const draw = pts => {
    if (token !== S.rv) return;
    const nodes = [chartNode('Zustandswert', pts, 'zustand', 'von 100', 'high', '#2aa198'), chartNode('Probleme (Kritisch + Warnung)', pts, 'probleme', '', 'low', '#cb4b16'), chartNode('Startdauer bis Desktop', pts, 'startSek', 's', 'low', '#268bd2'),
      chartNode('Zuverlässigkeitsindex', pts, 'index', 'von 10', 'high', '#6c71c4'), chartNode('Freier Platz auf C:', pts, 'freiC', '%', 'high', '#859900')].filter(Boolean);
    box.replaceChildren(...(nodes.length ? nodes : [h('p', { class: 'muted', text: 'Für einen Verlauf braucht es mindestens zwei Berichte.' })]));
  };
  draw(quick);
  if (list.length < 2) return;
  const full = await Promise.all(list.map(async (r, i) => { try { return historyPoint(await loadReportJson(r.name), r.created); } catch { return quick[i]; } }));
  draw(full);
}
function plural(n, one, many) { return `${n} ${n === 1 ? one : many}`; }
function heroText(c) {
  const parts = [c.CRIT && plural(c.CRIT, 'kritischer Punkt', 'kritische Punkte'), c.WARN && plural(c.WARN, 'Warnung', 'Warnungen'), c.TIPP && plural(c.TIPP, 'lohnender Tipp', 'lohnende Tipps')].filter(Boolean);
  if (!parts.length) return 'Keine offenen Punkte.';
  const n = (c.CRIT || 0) + (c.WARN || 0) + (c.TIPP || 0);
  return `${c.CRIT ? '' : 'Nichts Kritisches. '}${parts.length > 1 ? parts.slice(0, -1).join(', ') + ' und ' + parts[parts.length - 1] : parts[0]} ${n === 1 ? 'wartet' : 'warten'} auf dich.`;
}
function ringNode(score) {
  const C = 351.86, si = scoreInfo(score);
  const s = svg('svg', { viewBox: '0 0 132 132', 'aria-hidden': 'true' });
  const defs = svg('defs'), g = svg('linearGradient', { id: 'gr', x1: '0', y1: '0', x2: '1', y2: '1' });
  g.append(svg('stop', { offset: '0', 'stop-color': si.c1 }), svg('stop', { offset: '1', 'stop-color': si.c2 }));
  defs.append(g);
  const val = svg('circle', { class: 'val', cx: 66, cy: 66, r: 56, stroke: 'url(#gr)', 'stroke-width': 12, fill: 'none', 'stroke-linecap': 'round', 'stroke-dasharray': C, 'stroke-dashoffset': C });
  s.append(defs, svg('circle', { cx: 66, cy: 66, r: 56, stroke: '#ffffff12', 'stroke-width': 12, fill: 'none' }), val);
  requestAnimationFrame(() => requestAnimationFrame(() => val.setAttribute('stroke-dashoffset', String(+(C * (1 - score / 100)).toFixed(1)))));
  return h('div', { class: 'ring', role: 'img', 'aria-label': `Zustandswert ${score} von 100` }, s, h('div', { class: 'v' }, h('div', null, h('b', { text: String(score) }), h('span', { text: 'von 100' }))));
}
/** Zeile in „Nächste Schritte“ / „Lohnende Tipps“. */
function stepRow(f, showLevels) {
  // Nur bestätigt offene Aktionen: Ein noch nicht gelesener Zustand (zustand null) gilt nicht als offen,
  // sonst erscheint „Ausführen“ für Erledigtes und endet in „Schon erledigt, nichts geändert“.
  const open = actionsFor(f).filter(a => a.zustand && a.zustand.aktiv === false && !(a.varianten && a.varianten.length));
  const go = e => { e.preventDefault(); reveal(f.Check); };
  let btn;
  if (open.length === 1 && !locked()) btn = h('button', { type: 'button', class: 'sm primary', text: 'Ausführen', onclick: () => openRunDialog([open[0]]) });
  else btn = h('button', { type: 'button', class: 'sm', text: (f.Steps && f.Steps.length) || f.Command ? 'So geht\'s' : 'Ansehen', onclick: go });
  return h('div', { class: 'row' }, h('span', { class: 'chip ' + f.Status, text: STATUS_NAME[f.Status] }),
    h('div', null, h('div', { class: 't' }, h('a', { href: '#/' + viewOf(f), text: f.Check, onclick: go }), showLevels ? levelsNode(f.Benefit, f.Effort, f.Risk) : null),
      h('div', { class: 'd', text: f.Recommendation || f.Value })), btn);
}
V.uebersicht = () => {
  if (!S.report) return h('section', null, h('h1', { text: 'Übersicht' }), noReport());
  const m = S.report.Meta, c = counts(S.findings), score = scoreOf(c), si = scoreInfo(score);
  const todo = S.findings.filter(isProblem).sort((a, b) => RANK[a.Status] - RANK[b.Status] || (a.Area === 'Sicherheit' ? 0 : 1) - (b.Area === 'Sicherheit' ? 0 : 1) || a.Category.localeCompare(b.Category, 'de'));
  const tips = S.findings.filter(f => f.Status === 'TIPP').sort((a, b) => tipScore(b) - tipScore(a) || a.Area.localeCompare(b.Area, 'de') || a.Category.localeCompare(b.Category, 'de'));
  const charts = h('div', { class: 'charts' }, h('p', { class: 'muted', text: 'Lädt …' }));
  const hp = S.help && (S.help.Status || S.help.status);
  const ch = S.report.Changes;
  const token = S.rv;
  const toFilter = s => () => { S.ui.f.alle = { mode: s, term: '' }; if (location.hash === '#/alle') refreshView(); else location.hash = '#/alle'; };
  const pill = (s, label, color) => h('button', { type: 'button', class: 'pill', style: `--c:${color}`, title: hp && hp[s] ? hp[s] : 'Nur diese anzeigen', onclick: toFilter(s) }, h('i'), `${c[s]} ${label}`);
  const kpi = (s, label) => h('button', { type: 'button', class: 'kpi', style: `--c:${STATUS_COLOR[s]}`, title: hp && hp[s] ? hp[s] : 'Nur diese anzeigen', onclick: toFilter(s) }, h('b', { text: String(c[s]) }), h('span', null, h('i'), label));
  const root = h('section', null,
    h('h1', { text: 'Übersicht' }),
    h('p', { class: 'sub', text: `Was auf deinem PC gut läuft und was sich noch lohnt. · Bericht vom ${fmtDate(m.Erstellt)} · Adminrechte ${m.Admin ? 'ja' : 'nein'}${m.DauerSek != null ? ' · Dauer ' + m.DauerSek + ' s' : ''} · ${m.Computer || ''}` }),
    reportBar(), safetyBanner(),
    h('div', { class: 'grid g-hero' },
      h('div', { class: 'card hero' }, ringNode(score),
        h('div', null, h('h3', { text: si.title }), h('p', { text: heroText(c) }),
          h('div', { class: 'pills' }, pill('OK', 'OK', 'var(--green)'), pill('ACK', c.ACK === 1 ? 'akzeptiert' : 'akzeptiert', 'var(--cyan)'), pill('INFO', c.INFO === 1 ? 'Hinweis' : 'Hinweise', 'var(--blue)')),
          h('div', { class: 'formula', text: 'Zustandswert = 100 − 20 · Kritisch − 5 · Warnung − 1 · Tipp' }))),
      h('div', { class: 'card' }, h('h2', { text: 'Auf einen Blick' }),
        h('div', { class: 'kpis' }, kpi('CRIT', 'Kritisch'), kpi('WARN', 'Warnungen'), kpi('TIPP', 'Tipps'), kpi('SKIP', 'Nicht geprüft')))),
    h('div', { class: 'grid g-2' },
      h('div', { class: 'card' }, h('h2', null, 'Nächste Schritte', h('span', { class: 'hint', text: 'Kritisch und Warnungen' })),
        todo.length ? [h('div', { class: 'list' }, todo.slice(0, 3).map(f => stepRow(f, false))), todo.length > 3 ? h('p', { class: 'note' }, `Insgesamt ${todo.length} Punkte mit Handlungsbedarf. `, h('a', { href: '#/alle', text: 'Alle anzeigen', onclick: () => { S.ui.f.alle = { mode: 'problem', term: '' }; } })) : null]
          : h('p', { text: 'Kein Handlungsbedarf. 🎉' })),
      h('div', { class: 'card' }, h('h2', null, 'Lohnende Tipps', h('span', { class: 'hint', text: 'sortiert nach Nutzen' })),
        tips.length ? [h('div', { class: 'list' }, tips.slice(0, 5).map(f => stepRow(f, true))),
          tips.length > 5 ? h('p', { class: 'note' }, `Insgesamt ${tips.length} Tipps. `, h('a', { href: '#/alle', text: 'Alle anzeigen', onclick: () => { S.ui.f.alle = { mode: 'TIPP', term: '' }; } })) : null]
          : h('p', { class: 'muted', text: 'Keine Tipps.' }))),
    h('div', { class: 'card' }, h('h2', null, 'Verlauf', h('span', { class: 'hint', text: 'letzte bis zu 12 Berichte · Punkte berühren für Datum und Wert' })), charts),
    ch ? changesCard(ch) : null,
    hp ? h('details', { class: 'card' }, h('summary', { text: 'So liest du die Statuswerte' }), h('ul', null, STATUS.map(s => h('li', null, h('span', { class: 'chip ' + s, text: STATUS_NAME[s] }), ' ', hp[s] || '')))) : null);
  fillCharts(charts, token);
  return root;
};
function changesCard(ch) {
  const status = ch.Status || [], bestand = ch.Bestand || {};
  let prev = ch.Erstellt ? fmtDate(ch.Erstellt) : '';
  return h('details', { class: 'card' }, h('summary', { text: 'Änderungen seit dem letzten Lauf' }),
    h('p', { class: 'muted', text: `Verglichen mit dem Bericht vom ${prev}.${ch.AdminVorher === false ? ' Achtung: Der vorige Lauf hatte keine Adminrechte, ein Teil der Unterschiede kann daher stammen.' : ''}` }),
    status.length ? [h('h3', { text: 'Geänderte Prüfergebnisse' }), tableFrom(status)] : null,
    Object.keys(bestand).map(t => h('div', null, h('h3', { text: t }), h('ul', { class: 'chg' },
      (bestand[t].Neu || []).map(x => h('li', { class: 'add', text: '➕ ' + x })), (bestand[t].Entfernt || []).map(x => h('li', { class: 'rem', text: '➖ ' + x }))))),
    !status.length && !Object.keys(bestand).length ? h('p', { text: 'Keine Änderungen.' }) : null);
}

// ---------------------------------------------------------------- KI-Kopie (Anonymisierung wie Protect-Text in pc-check.ps1)
const reEsc = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
function protect(text, ctx) {
  if (!text) return '';
  let t = String(text);
  if (ctx.pc) t = t.replace(new RegExp(reEsc(ctx.pc), 'gi'), '<PC>');
  if (ctx.user && ctx.user.length >= 3) t = t.replace(new RegExp(reEsc(ctx.user), 'gi'), '<Benutzer>');
  t = t.replace(/[\w.+-]+@[\w-]+\.[\w.-]+/g, '<E-Mail>')
    .replace(/S-1-5-21-[\d-]+/gi, '<SID>')
    .replace(/\b([0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b/gi, '<MAC>')
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '<IP>')
    .replace(/\bfe80:[0-9a-f:%]*|\b[0-9a-f]{4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f:]+/gi, '<IPv6>')
    .replace(/(\\Users\\)[^\\\s"']+/gi, '$1<Benutzer>'); // zusätzlich zur PS-Fassung: Profilordner
  return t;
}
function buildKi() {
  const m = S.report.Meta, sys = ((S.report.Data || {}).System || [])[0] || {};
  const ctx = { pc: m.Computer || (S.session && S.session.pc) || '', user: (S.session && (S.session.benutzer || S.session.user)) || ((S.journal || [])[0] || {}).benutzer || '' };
  const c = counts(S.findings), L = [];
  L.push('Ich habe meinen Windows-PC mit dem Prüfscript Morpheus (pc-check) untersucht. Bitte erkläre mir die folgenden Befunde verständlich,');
  L.push('bewerte, wie dringend sie sind, und sag mir Schritt für Schritt, was ich tun sollte. Frag nach, wenn dir Angaben fehlen.', '');
  L.push(`System: ${sys.Edition || 'Windows'}, Version ${sys.Version || ''}; Morpheus ${m.Version || ''}; Adminrechte: ${m.Admin ? 'ja' : 'nein'}`);
  L.push(`Nutzung: ${m.Profil || ''}`);
  L.push(`Übersicht: ${c.CRIT} kritisch, ${c.WARN} Warnungen, ${c.TIPP} Tipps, ${c.ACK} akzeptiert, ${c.INFO} Hinweise, ${c.OK} OK`);
  ['CRIT', 'WARN', 'TIPP', 'ACK', 'INFO'].forEach(s => {
    const list = S.findings.filter(f => f.Status === s);
    if (!list.length) return;
    L.push('', `== ${STATUS_NAME[s]} ==`);
    list.forEach(f => {
      L.push(`- [${f.Area} / ${f.Category}] ${f.Check}: ${protect(f.Value, ctx)}`);
      if (f.Recommendation) L.push(`  Empfehlung des Scripts: ${protect(f.Recommendation, ctx)}`);
      if (s === 'ACK') L.push(`  Von mir bewusst akzeptiert: ${protect(f.Note, ctx)}`);
    });
  });
  return L.join('\n');
}

// ---------------------------------------------------------------- Ansicht: Checkliste
V.checkliste = () => {
  if (!S.report) return h('section', null, h('h1', { text: 'Meine Checkliste' }), noReport());
  const created = S.report.Meta.Erstellt;
  const groups = { open: [], fixed: [], pending: [], later: [] };
  Object.keys(S.checklist).forEach(c => {
    const m = S.checklist[c], f = findingByCheck(c), still = f ? isOpen(f) : false;
    const g = m.state === 'later' ? (still ? 'later' : 'fixed') : (!still ? 'fixed' : (m.report === created ? 'pending' : 'open'));
    groups[g].push({ c, f, d: m.date });
  });
  const titles = { open: 'Als erledigt markiert, aber weiterhin gemeldet', fixed: 'Behoben (bestätigt durch diesen Bericht)', pending: 'Als erledigt markiert (der nächste Lauf bestätigt es)', later: 'Für später vorgemerkt' };
  const body = ['open', 'fixed', 'pending', 'later'].filter(g => groups[g].length).map(g => h('div', null,
    h('h3', { class: g === 'open' ? 'rem' : (g === 'fixed' ? 'add' : ''), text: titles[g] }),
    h('ul', { class: 'checklist' }, groups[g].map(x => h('li', null,
      x.f ? h('a', { href: '#/' + viewOf(x.f), text: x.c, onclick: e => { e.preventDefault(); reveal(x.c); } }) : x.c,
      h('span', { class: 'muted', text: ` – markiert am ${x.d}` }))))));
  const any = body.length;
  return h('section', null, h('h1', { text: 'Meine Checkliste' }), h('p', { class: 'sub', text: 'Bei Warnungen und Tipps kannst du „✔ erledigt“ oder „⏱ später“ anklicken. Der nächste Bericht zeigt, was wirklich behoben ist.' }), reportBar(),
    h('div', { class: 'card' }, any ? body : h('p', { class: 'muted', text: 'Noch nichts markiert.' })),
    any ? h('button', { type: 'button', class: 'danger', text: 'Markierungen löschen', onclick: () => dlgOpen('Markierungen löschen', h('p', { text: 'Alle Markierungen für diesen PC löschen?' }), [{ label: 'Abbrechen', onClick: dlgClose },
      { label: 'Löschen', danger: true, onClick: () => { S.checklist = {}; api('/api/checklist', { method: 'POST', body: {} }).catch(e => toast(e.message)); dlgClose(); refreshView(); } }]) }) : null);
};

// ---------------------------------------------------------------- Ansicht: Änderungen
const JSTAT = { begonnen: 'begonnen', erledigt: 'erledigt', fehlgeschlagen: 'fehlgeschlagen', 'fehlgeschlagen-zurueckgesetzt': 'fehlgeschlagen, zurückgesetzt', zurueckgenommen: 'zurückgenommen' };
/** Protokoll-Eintrag einer Wartung bzw. eines Programm-Updates (Abschnitt 18.8): kein Rückgängig, kein „vorher → nachher“. */
function journalWartung(e) {
  const st = e.status, failed = String(st).startsWith('fehl');
  const color = failed ? 'var(--red)' : (st === 'erledigt' ? 'var(--cyan)' : (st === 'begonnen' ? 'var(--yellow)' : 'var(--b01)'));
  const chip = st === 'erledigt' ? h('span', { class: 'chip OK', text: 'erledigt' })
    : failed ? h('span', { class: 'chip CRIT', text: 'fehlgeschlagen' })
      : st === 'abgebrochen' ? h('span', { class: 'chip INFO', text: 'abgebrochen' })
        : st === 'begonnen' ? h('span', { class: 'chip WARN', text: 'begonnen (unterbrochen?)' })
          : h('span', { class: 'chip INFO', text: String(st || '') });
  const meta = [];
  if (e.dauerSek != null) meta.push('Dauer ' + fmtDur(e.dauerSek));
  if (e.exitCode != null) meta.push('Exit-Code ' + e.exitCode);
  return h('div', { class: 'ev', style: `--c:${color}` },
    h('div', { class: 'h' }, h('b', { text: e.titel || e.aktion }), h('span', { class: 'chip INFO', text: 'Protokoll' }), h('span', { class: 'chip INFO', text: 'kein Rückgängig' }), chip,
      h('span', { class: 'when', title: fmtDate(e.zeit), text: fmtWhen(e.zeit) })),
    h('div', { class: 'm' },
      e.befehl ? h('div', null, h('code', { text: e.befehl })) : null,
      meta.length ? h('div', { text: meta.join(' · ') }) : null,
      e.ohnePunkt ? h('div', null, h('span', { class: 'chip WARN', text: 'ohne Wiederherstellungspunkt' }))
        : (e.wiederherstellungspunkt && e.wiederherstellungspunkt.seq != null ? h('div', null, 'Wiederherstellungspunkt ', h('code', { text: '#' + e.wiederherstellungspunkt.seq })) : null),
      e.meldung ? h('div', { class: 'note', text: e.meldung }) : null));
}
function journalEvent(e) {
  if (e.art === 'wartung' || e.art === 'update') return journalWartung(e);
  const undone = e.status === 'zurueckgenommen', failed = String(e.status).startsWith('fehl'), isUndo = e.art === 'rueckgaengig';
  const color = failed ? 'var(--red)' : undone ? 'var(--b01)' : isUndo ? 'var(--green)' : 'var(--cyan)';
  const chip = failed ? h('span', { class: 'chip CRIT', text: JSTAT[e.status] || e.status })
    : undone ? h('span', { class: 'chip INFO', text: 'zurückgenommen' })
      : isUndo ? h('span', { class: 'chip ACK', text: 'Rücknahme' })
        : h('span', { class: 'chip ' + (e.status === 'erledigt' ? 'OK' : 'WARN'), text: e.status === 'erledigt' ? 'aktiv' : (JSTAT[e.status] || e.status) });
  const canUndo = e.status === 'erledigt' && !isUndo;
  return h('div', { class: 'ev', style: `--c:${color}` },
    h('div', { class: 'h' }, h('b', { style: undone ? 'color:var(--b1)' : null, text: (isUndo ? 'Rückgängig: ' : '') + (e.titel || e.aktion) }), chip,
      h('span', { class: 'when', title: fmtDate(e.zeit), text: fmtWhen(e.zeit) }),
      canUndo ? h('button', { type: 'button', class: 'sm', disabled: readOnly(), title: readOnly() ? lockTitle() : null, onclick: () => openUndoDialog(e) }, icon('undo'), 'Rückgängig') : null),
    h('div', { class: 'm' }, `${fmtState(e.vorher)} → ${fmtState(e.nachher)}`, e.variante ? ` (${e.variante})` : '',
      e.wiederherstellungspunkt && e.wiederherstellungspunkt.seq != null ? [' · Wiederherstellungspunkt ', h('code', { text: '#' + e.wiederherstellungspunkt.seq })] : null,
      e.meldung ? h('div', { class: 'note', text: e.meldung }) : null));
}
V.aenderungen = () => {
  const jbox = h('div', { class: 'card' }, h('h2', { text: 'Verlauf deiner Änderungen' }), h('p', { class: 'muted', text: 'Lädt …' }));
  const rbox = h('div', { class: 'card' }, h('h2', { text: 'Wiederherstellungspunkte' }), h('p', { class: 'muted', text: 'Lädt …' }));
  const token = S.rv;
  api('/api/journal').then(list => {
    if (token !== S.rv) return;
    S.journal = list || [];
    renderStatusReport();
    jbox.replaceChildren(h('h2', { text: 'Verlauf deiner Änderungen' }), ...(S.journal.length
      ? [h('div', { class: 'tl' }, S.journal.slice(0, 100).map(journalEvent)), S.journal.length > 100 ? h('p', { class: 'note', text: `… ${S.journal.length - 100} ältere Einträge nicht angezeigt.` }) : null]
      : [h('p', { class: 'muted', text: 'Noch keine Änderungen durchgeführt.' })]).filter(Boolean));
  }).catch(e => jbox.replaceChildren(h('h2', { text: 'Verlauf deiner Änderungen' }), h('p', { class: 'rem', text: e.message })));
  api('/api/restorepoints').then(list => {
    if (token !== S.rv) return;
    S.points = list || [];
    renderStatusReport();
    rbox.replaceChildren(h('h2', { text: 'Wiederherstellungspunkte' }), ...(list && list.length
      ? [h('div', { class: 'list' }, list.map(p => h('div', { class: 'row rp' }, h('code', { text: '#' + p.seq }),
        h('div', null, h('div', { class: 't', style: 'font-weight:500', text: p.beschreibung }), h('div', { class: 'd', text: `${fmtWhen(p.zeit)}${p.typ ? ' · ' + p.typ : ''}` }))))),
      h('p', { class: 'note' }, 'Alles zurück auf einen Punkt: ', h('code', { text: 'rstrui.exe' }), ' starten (Start → Ausführen). Das setzt auch Programme und Treiber zurück, die danach installiert wurden.')]
      : [h('p', { class: 'muted', text: 'Keine Wiederherstellungspunkte gefunden.' })]));
  }).catch(e => rbox.replaceChildren(h('h2', { text: 'Wiederherstellungspunkte' }), h('p', { class: 'rem', text: e.message })));
  return h('section', null, h('h1', { text: 'Änderungen' }), h('p', { class: 'sub', text: 'Jede Änderung lässt sich einzeln zurücknehmen. Wiederherstellungspunkte sind das Netz darunter.' }),
    safetyBanner(), dOrdHinweis(), h('div', { class: 'grid g-hero' }, jbox, rbox));
};

// ---------------------------------------------------------------- Ansicht: Berichte
/** Adresse des Original-Berichts mit einmaliger Lesemarke (nie mit Token: das Script im Bericht kann seine Adresse lesen). */
async function origSrc(name) {
  if (typeof window.PCCHECK_REPORT_SRC === 'function') return window.PCCHECK_REPORT_SRC(name);
  const r = await api('/api/report-ticket', { method: 'POST', body: { name: name + '.html' } });
  return `/report/${name}.html?k=${encodeURIComponent(r.ticket)}`;
}
V.berichte = () => {
  const cmpBox = h('div'), origBox = h('div');
  const cmpBtn = h('button', { type: 'button', class: 'primary', text: 'Vergleichen', onclick: doCompare });
  function sync() { cmpBtn.disabled = S.cmp.length !== 2; }
  async function doCompare() {
    cmpBox.replaceChildren(h('p', { class: 'muted', text: 'Lädt …' }));
    try {
      const names = S.cmp.slice().sort(); // Dateiname enthält das Datum: A = älter
      const [A, B] = await Promise.all(names.map(loadReportJson));
      const map = r => { const o = new Map(); (r.Findings || []).forEach(f => o.set(`${norm(f.Category)}|${norm(f.Check)}`, f)); return o; };
      const a = map(A), b = map(B), rows = [];
      new Set([...a.keys(), ...b.keys()]).forEach(k => { const x = a.get(k), y = b.get(k); if (!x || !y || x.Status !== y.Status) rows.push({ k, x, y }); });
      rows.sort((p, q) => RANK[(p.y || p.x).Status] - RANK[(q.y || q.x).Status]);
      const bd = f => f ? h('span', { class: 'chip ' + f.Status, text: STATUS_NAME[f.Status] }) : h('span', { class: 'muted', text: '–' });
      cmpBox.replaceChildren(h('div', { class: 'card' }, h('h3', { text: `Vergleich: ${fmtDate(A.Meta.Erstellt)} (A) und ${fmtDate(B.Meta.Erstellt)} (B)` }),
        rows.length ? h('div', { class: 'tablewrap' }, h('table', null, h('thead', null, h('tr', null, ['Prüfung', 'Status A', 'Status B'].map(x => h('th', { text: x })))),
          h('tbody', null, rows.map(r => h('tr', null, h('td', null, (r.y || r.x).Check, h('div', { class: 'cat-hint', text: (r.y || r.x).Category })), h('td', null, bd(r.x)), h('td', null, bd(r.y))))))) : h('p', { text: 'Keine Unterschiede im Status.' })));
    } catch (e) { cmpBox.replaceChildren(h('p', { class: 'rem', text: e.message })); }
  }
  function showOrig(name) {
    if (S.origName === name) { S.origName = null; origBox.replaceChildren(); return; }
    S.origName = name;
    // sandbox ohne allow-same-origin und ohne allow-popups: der Bericht kann weder die API noch Fenster öffnen
    const frame = h('iframe', { sandbox: 'allow-scripts', title: 'Original-HTML-Bericht', style: 'width:100%;height:78vh;border:1px solid var(--line);border-radius:6px;background:#fff' });
    origBox.replaceChildren(h('div', { class: 'card' }, h('div', { class: 'toolbar' }, h('b', { text: 'Original-HTML-Bericht' }), h('button', { type: 'button', text: 'Schließen', onclick: () => showOrig(name) })), frame));
    origSrc(name).then(src => { frame.src = src; }, e => origBox.replaceChildren(h('p', { class: 'rem', text: e.message })));
  }
  const rows = S.reports.map(r => {
    const c = r.counts || {};
    const cb = h('input', { type: 'checkbox', checked: S.cmp.includes(r.name), 'aria-label': 'Zum Vergleich auswählen',
      onchange: e => { if (e.target.checked) { S.cmp.push(r.name); if (S.cmp.length > 2) S.cmp.shift(); } else S.cmp = S.cmp.filter(x => x !== r.name); refreshChecks(); sync(); } });
    return { r, cb, tr: h('tr', null, h('td', null, cb), h('td', { text: fmtDate(r.created) + (r.name === S.cur ? ' (angezeigt)' : '') }), h('td', { text: r.version || '' }), h('td', { text: r.admin ? 'ja' : 'nein' }), h('td', { text: r.profil || '' }),
      h('td', { text: String(c.CRIT || 0) }), h('td', { text: String(c.WARN || 0) }), h('td', { text: String(c.TIPP || 0) }),
      h('td', null, h('button', { type: 'button', text: 'Anzeigen', onclick: async () => { try { await showReport(r.name); location.hash = '#/uebersicht'; if (S.view === 'uebersicht') refreshView(); } catch (e) { toast(e.message); } } }), ' ',
        h('button', { type: 'button', text: 'Original-HTML', onclick: () => showOrig(r.name) }))) };
  });
  function refreshChecks() { rows.forEach(x => { x.cb.checked = S.cmp.includes(x.r.name); }); }
  sync();
  return h('section', null, h('h1', { text: 'Berichte' }), h('p', { class: 'sub', text: `${S.reports.length} Berichte · zwei beliebige lassen sich vergleichen` }), reportBar(),
    h('div', { class: 'toolbar' }, cmpBtn, h('span', { class: 'note', text: 'Zwei Berichte ankreuzen, dann „Vergleichen“.' })),
    S.reports.length ? h('div', { class: 'card' }, h('div', { class: 'tablewrap' }, h('table', null,
      h('thead', null, h('tr', null, ['', 'Datum', 'Version', 'Admin', 'Profil', 'Krit.', 'Warn.', 'Tipps', ''].map(x => h('th', { text: x })))),
      h('tbody', null, rows.map(x => x.tr))))) : noReport(),
    cmpBox, origBox);
};

// ---------------------------------------------------------------- Ansicht: Scan
V.scan = () => {
  const sc = S.scan;
  const profil = h('select', { id: 'sc-profil', 'aria-label': 'Profil' }, [['Auto', 'Automatisch'], ['Gaming', 'Gaming'], ['Office', 'Office'], ['Laptop', 'Laptop']].map(([v, l]) => h('option', { value: v, text: l })));
  const days = h('select', { id: 'sc-days', 'aria-label': 'Zeitraum' }, [7, 14, 30, 60, 90].map(d => h('option', { value: String(d), selected: d === 14, text: `${d} Tage` })));
  const upd = h('input', { type: 'checkbox', checked: true }), wg = h('input', { type: 'checkbox', checked: true }), nsp = h('input', { type: 'checkbox' }), nsi = h('input', { type: 'checkbox' });
  const log = h('pre', { class: 'log scanlog', id: 'scanlog', 'aria-live': 'polite', text: sc ? sc.lines.join('\n') : 'Bereit. Der Scan ändert nichts am System (ca. 2–5 Minuten).' });
  const btn = h('button', { type: 'button', class: 'btn brand', text: 'Scan starten', disabled: !!(sc && sc.running) || readOnly(), title: readOnly() ? lockTitle() : null, onclick: startScan });
  const msg = h('div', { id: 'scanmsg' });
  function startScan() {
    const d = parseInt(days.value, 10);
    if (!(d >= 1 && d <= 90)) return;
    S.scan = { running: true, lines: [], done: false };
    log.textContent = ''; btn.disabled = true; msg.replaceChildren();
    runScan({ profil: profil.value, eventDays: d, skipWinget: !wg.checked, skipUpdateSearch: !upd.checked, skipSpeicher: nsp.checked, skipSysinternals: nsi.checked });
  }
  S.scanUi = { log, btn, msg };
  if (sc && sc.msg) msg.replaceChildren(sc.msg);
  log.scrollTop = log.scrollHeight;
  return h('section', { class: 'noaccent' }, h('h1', { text: 'Neuer Scan' }), h('p', { class: 'sub', text: 'Der Scan ist rein lesend. Danach erscheint der neue Bericht automatisch als aktueller Bericht.' }),
    h('div', { class: 'card' }, h('div', { class: 'toolbar' },
      h('label', null, 'Profil ', profil), h('label', null, 'Zeitraum ', days),
      h('label', null, upd, ' Windows-Update-Suche'), h('label', null, wg, ' winget-Prüfung'), h('label', null, nsp, ' Speicherverbraucher nicht berechnen (spart 1–2 Minuten)'), h('label', null, nsi, ' Sysinternals-Prüfungen überspringen'), btn), log, msg));
};
async function runScan(body) {
  const ui = () => { const u = S.scanUi; return u && u.log.isConnected ? u : null; };
  const out = lines => { S.scan.lines.push(...lines); const u = ui(); if (u) { u.log.textContent = S.scan.lines.join('\n'); u.log.scrollTop = u.log.scrollHeight; } };
  try {
    const r = await api('/api/scan', { method: 'POST', body });
    const job = await followJob(r.jobId, out);
    S.scan.running = false;
    if (job.status === 'done') {
      await loadReports();
      if (S.reports.length) await showReport(S.reports[0].name);
      await loadSpeicher();
      S.scan.msg = banner('info', 'doc', h('b', { text: 'Scan fertig. ' }), 'Der neue Bericht wird jetzt angezeigt. ', h('a', { href: '#/uebersicht', text: 'Zur Übersicht →' }));
      toast('Scan fertig: neuer Bericht geladen');
    } else S.scan.msg = h('p', { class: 'rem', text: (job.ergebnis && job.ergebnis.error) || 'Der Scan ist fehlgeschlagen.' });
  } catch (e) { S.scan.running = false; S.scan.msg = h('p', { class: 'rem', text: e.message }); }
  const u = ui();
  if (u) { u.btn.disabled = false; u.msg.replaceChildren(S.scan.msg); }
  renderNav();
  if (S.view !== 'scan' && !$('#modal').classList.contains('on')) refreshView();
}

// ---------------------------------------------------------------- Ansicht: Rohdaten, Einstellungen
/** Titel der Detailtabellen, die beim Scan in dieser Prüfung entstanden sind (DataChecks ab v2.1). */
function tablesFor(check) {
  const dc = (S.report && S.report.DataChecks) || {};
  return Object.keys(dc).filter(t => dc[t] === check && S.report.Data && S.report.Data[t] && S.report.Data[t].length);
}
/** Springt in den Anhang und klappt die genannten Tabellen auf. */
function openRaw(titles) {
  S.ui.rawOpen = titles;
  if (location.hash === '#/rohdaten') refreshView(); else location.hash = '#/rohdaten';
}
V.rohdaten = () => {
  if (!S.report) return h('section', null, h('h1', { text: 'Rohdaten' }), noReport());
  const D = S.report.Data || {}, want = S.ui.rawOpen || [], dc = S.report.DataChecks || {};
  S.ui.rawOpen = null;
  let first = null;
  const sec = h('section', null, h('h1', { text: 'Rohdaten' }), h('p', { class: 'sub', text: 'Die Detailtabellen hinter den Prüfungen. Zum Aufklappen anklicken.' }), reportBar(),
    Object.keys(D).map(t => {
      const rows = D[t] || [], body = h('div');
      const d = h('details', { class: 'raw' }, h('summary', null, t, h('span', { class: 'muted', text: ` (${rows.length})` }),
        dc[t] ? h('span', { class: 'muted', text: ` · Prüfung „${dc[t]}“` }) : null), body);
      d.addEventListener('toggle', () => { if (d.open && !body.firstChild) body.append(tableFrom(rows, 300, t)); });
      if (want.includes(t)) { d.open = true; body.append(tableFrom(rows, 300, t)); d.classList.add('flash'); if (!first) first = d; }
      return d;
    }));
  if (first) setTimeout(() => first.scrollIntoView({ block: 'start', behavior: 'smooth' }), 50);
  return sec;
};
V.einstellungen = () => {
  const m = (S.report && S.report.Meta) || {}, s = safety();
  const acc = S.findings.filter(f => f.Status === 'ACK');
  const akzBody = h('div'); loadAkzeptanz(akzBody);
  return h('section', null, h('h1', { text: 'Einstellungen' }), h('p', { class: 'sub', text: 'Erst nur zur Ansicht. Profil und Zeitraum wählst du beim Scan.' }),
    h('div', { class: 'card' }, h('table', null, h('tbody', null,
      h('tr', null, h('td', { text: 'Profil (letzter Bericht)' }), h('td', { text: m.Profil || '–' })),
      h('tr', null, h('td', { text: 'Zeitraum Ereignisse' }), h('td', { text: m.EventDays != null ? `${m.EventDays} Tage` : '–' })),
      h('tr', null, h('td', { text: 'Computerschutz' }), h('td', null, s.schutzAn === false ? h('span', { class: 'rem', text: 'aus' }) : h('span', { class: 'ok', text: `an${s.laufwerk ? ' (' + s.laufwerk + ')' : ''}` }), ' · 24-h-Sperre ', s.sperre24h ? h('span', { class: 'warn', text: 'aktiv' }) : h('span', { class: 'ok', text: 'aus' }))),
      h('tr', null, h('td', { text: 'Letzter Wiederherstellungspunkt' }), h('td', { text: s.letzterPunkt ? fmtDate(s.letzterPunkt) : '–' })),
      h('tr', null, h('td', { text: 'Morpheus-Version' }), h('td', { text: (S.session && S.session.version) || '' }))))),
    h('h2', { text: 'Akzeptanzliste' }), dOrdHinweis(),
    h('div', { class: 'card' }, akzBody),
    h('h2', { text: `Akzeptierte Abweichungen (${acc.length})` }),
    h('div', { class: 'card' }, acc.length ? acc.map(f => findingRow(f, { hint: true })) : h('p', { class: 'muted', text: 'Keine akzeptierten Abweichungen im angezeigten Bericht.' })));
};

// ---------------------------------------------------------------- Akzeptanzliste (Vertrag 16.4/16.5)
const akzErr = e => e.status === 403 ? 'Im Windows-Dialog abgelehnt.' : (e.message || 'Das hat nicht geklappt.');
function loadAkzeptanz(box) {
  box.replaceChildren(h('p', { class: 'muted', text: 'Lade …' }));
  api('/api/akzeptanz').then(d => { if (box.isConnected) box.replaceChildren(akzTable(d || {}, box)); },
    e => { if (box.isConnected) box.replaceChildren(h('p', { class: 'rem', text: 'Die Akzeptanzliste konnte nicht geladen werden: ' + e.message })); });
}
function akzTable(d, box) {
  const regeln = d.regeln || [], ro = readOnly() || d.bearbeitbar === false;
  const intro = h('p', { class: 'muted', text: 'Hier stehen alle Regeln, mit denen Befunde oder einzelne Dateien als „akzeptiert“ gelten. Änderungen wirken ab dem nächsten Scan.' });
  if (!regeln.length) return h('div', null, intro, h('p', { class: 'muted', text: 'Keine Regeln.' }));
  const rows = regeln.map(r => h('tr', null,
    h('td', { text: r.check || '' }),
    h('td', { class: 'mono', text: r.datei || r.match || '' }),
    h('td', { text: r.reason || '' }),
    h('td', null, r.until || 'unbegrenzt', r.abgelaufen ? [' ', h('span', { class: 'chip WARN', text: 'abgelaufen' })] : null),
    h('td', { text: r.quelle === 'gui' ? 'GUI' : 'von Hand' }),
    h('td', null, h('button', { type: 'button', class: 'sm', disabled: ro, title: ro ? lockTitle() : null, text: 'Zurücknehmen …', onclick: () => akzEntfernen(r, box) }))));
  return h('div', null, intro, h('div', { class: 'tbl-scroll' }, h('table', null,
    h('thead', null, h('tr', null, ['Prüfung', 'Datei bzw. Muster', 'Begründung', 'Gilt bis', 'Quelle', ''].map(x => h('th', { text: x })))),
    h('tbody', null, rows))));
}
function akzEntfernen(r, box) {
  dlgOpen('Regel zurücknehmen', [
    h('p', null, 'Soll die Regel für „', h('b', { text: r.check || '' }), '“ zurückgenommen werden?'),
    r.datei ? h('p', { class: 'mono', text: r.datei }) : null,
    h('p', { class: 'muted', text: 'Begründung: ' + (r.reason || '') }),
    h('div', { class: 'note', text: 'Windows fragt vorher in einem eigenen Fenster nach deiner Bestätigung. Der Befund kommt beim nächsten Scan wieder.' })],
  [{ label: 'Abbrechen', onClick: dlgClose }, { label: 'Zurücknehmen', danger: true, onClick: async () => {
    dlgOpen('Regel zurücknehmen', [h('p', { text: 'Bitte im Windows-Fenster „Morpheus – Änderung bestätigen“ mit „Ja“ bestätigen …' })], [{ label: 'Läuft …', disabled: true }], { lock: true });
    try {
      await api('/api/akzeptanz/' + encodeURIComponent(r.id) + '/entfernen', { method: 'POST', body: {} });
      dlgClose(); toast('Regel zurückgenommen'); if (box.isConnected) loadAkzeptanz(box);
    } catch (e) {
      dlgOpen('Regel zurücknehmen', [h('p', { class: 'rem', text: akzErr(e) })], [{ label: 'Schließen', primary: true, onClick: dlgClose }]);
    }
  } }]);
}
const pad2 = n => String(n).padStart(2, '0');
const ymd = d => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;   // lokales Datum
/** Akzeptieren-Dialog. t = { art:'befund', check } oder { art:'datei', pfad, sha256, onDone } (nur für den angezeigten Bericht). */
function openAkzeptieren(t) {
  const datei = t.art === 'datei';
  const today = new Date(), maxD = new Date(today.getFullYear() + 5, today.getMonth(), today.getDate());
  const minS = ymd(today), maxS = ymd(maxD);
  const reason = h('textarea', { rows: 3, maxlength: 300, 'aria-label': 'Begründung', placeholder: 'Warum ist das in Ordnung? (3–300 Zeichen)', style: 'width:100%' });
  const count = h('span', { class: 'muted', text: '0 / 300' });
  const bis = h('input', { type: 'date', 'aria-label': 'Gilt bis', min: minS, max: maxS });
  const msg = h('p', { role: 'alert' });
  const send = h('button', { type: 'button', class: 'primary', text: 'Akzeptieren' });
  const close = h('button', { type: 'button', text: 'Abbrechen', onclick: dlgClose });
  const clean = () => reason.value.replace(/[\r\n\t]+/g, ' ').replace(/ {2,}/g, ' ').trim();
  reason.addEventListener('input', () => { count.textContent = `${clean().length} / 300`; });
  const fail = text => { msg.className = 'rem'; msg.textContent = text; };
  send.onclick = async () => {
    if (Dlg.running) return;
    const begruendung = clean();
    if (begruendung.length < 3 || begruendung.length > 300) { fail('Bitte eine Begründung mit 3 bis 300 Zeichen eingeben.'); reason.focus(); return; }
    if (bis.value && (!/^\d{4}-\d{2}-\d{2}$/.test(bis.value) || bis.value < minS || bis.value > maxS)) { fail('„Gilt bis“ muss zwischen heute und höchstens 5 Jahren in der Zukunft liegen.'); bis.focus(); return; }
    const body = datei ? { art: 'datei', bericht: S.cur + '.json', pfad: t.pfad, begruendung } : { art: 'befund', bericht: S.cur + '.json', check: t.check, begruendung };
    if (bis.value) body.bis = bis.value;
    Dlg.running = true; send.disabled = true; close.disabled = true; reason.disabled = true; bis.disabled = true; send.textContent = 'Warte auf Windows …';
    msg.className = 'note'; msg.textContent = 'Bitte im Windows-Fenster „Morpheus – Änderung bestätigen“ mit „Ja“ bestätigen …';
    try {
      await api('/api/akzeptanz', { method: 'POST', body });
      Dlg.running = false;
      if (t.onDone) t.onDone();
      dlgOpen('Akzeptiert', [h('p', { class: 'ok', text: 'Die Regel wurde gespeichert.' }), h('p', { text: 'Wirkt ab dem nächsten Scan. Bis dahin zeigt der Bericht den Befund weiter an.' })],
        [{ label: 'Später', onClick: dlgClose }, { label: 'Neuer Scan', primary: true, onClick: () => { dlgClose(); location.hash = '#/scan'; } }]);
    } catch (e) {
      Dlg.running = false;
      fail(akzErr(e)); send.disabled = false; close.disabled = false; reason.disabled = false; bis.disabled = false; send.textContent = 'Akzeptieren';
    }
  };
  dlgOpen(datei ? 'Datei akzeptieren' : 'Befund akzeptieren', [
    h('p', null, datei ? 'Datei: ' : 'Prüfung: ', h('b', { class: datei ? 'mono' : null, text: datei ? t.pfad : t.check })),
    h('p', { class: 'muted', text: datei ? `Gilt nur für genau diese Datei (SHA256 ${t.sha256 || 'unbekannt'}). Ändert sie sich, kommt die Warnung zurück.` : 'Gilt, solange der Befund genau so lautet. Ändert er sich, kommt die Warnung zurück.' }),
    datei ? null : h('p', { class: 'muted', text: 'Enthält der Befund Zahlen oder Tage (z. B. „vor 15 Tagen“), ändert er sich mit dem nächsten Scan und die Akzeptanz greift dann nicht mehr.' }),
    h('label', null, 'Begründung (Pflicht) ', count, h('br'), reason),
    h('label', null, 'Gilt bis (optional) ', bis),
    msg, h('div', { class: 'note', text: 'Windows fragt danach in einem eigenen Fenster nach deiner Bestätigung.' })],
  []);
  $('#dlg-buttons').replaceChildren(close, send); reason.focus();
}
// Defender-Einzelscan einer Datei aus der Sigcheck-Tabelle
function startDefenderDatei(pfad) {
  const title = 'Datei mit Defender prüfen';
  dlgOpen(title, [
    h('p', null, 'Microsoft Defender prüft diese Datei auf Schadsoftware:'), h('p', { class: 'mono', text: pfad }),
    h('div', { class: 'note', text: 'Windows fragt vorher in einem eigenen Fenster nach deiner Bestätigung. Defender prüft die Datei. Findet er etwas, wendet er seine üblichen Maßnahmen an (z. B. Quarantäne) – bei Treibern kann das Folgen haben. Morpheus zeigt das Ergebnis an.' })],
  [{ label: 'Abbrechen', onClick: dlgClose }, { label: 'Starten', primary: true, onClick: () => runDefenderDatei(pfad, title) }]);
}
async function runDefenderDatei(pfad, title) {
  const jv = jobView([['Windows-Bestätigung', /bestätig/i], ['Datei prüfen', /prüf|scan/i], ['Funde lesen', /funde/i]]);
  dlgOpen(title, jv.nodes, [{ label: 'Läuft …', disabled: true }], { lock: true });
  let job = null, err = null;
  try {
    jv.lines(['Bitte im Windows-Fenster „Morpheus – Änderung bestätigen“ mit „Ja“ bestätigen …']);
    const r = await api('/api/defender/datei', { method: 'POST', body: { bericht: S.cur + '.json', pfad } });
    job = await followJob(r.jobId, jv.lines);
  } catch (e) { err = e; }
  const ok = !err && !!job && job.status === 'done', res = job && job.ergebnis;
  jv.finish(ok);
  const body = [...jv.nodes];
  if (err) body.push(h('p', { class: 'rem', text: err.message }));
  else if (!ok) body.push(h('p', { class: 'rem', text: (res && res.error) || 'Der Vorgang ist fehlgeschlagen.' }));
  else {
    const funde = [].concat((res && res.funde) || []).filter(Boolean);
    body.push(h('h3', { text: 'Ergebnis' }), h('p', { class: 'mono', text: pfad }),
      funde.length ? h('ul', { class: 'result' }, funde.map(f => h('li', null, h('b', { text: f.name || 'Unbekannter Fund' }), ' ', h('span', { class: 'muted', text: f.zeit ? fmtDate(f.zeit) : '' }), ' ', h('span', { class: f.erfolg === false ? 'rem' : 'warn', text: f.aktion || '' }), f.frueher ? [' ', h('span', { class: 'chip INFO', text: 'früher erkannt' })] : null, f.dateien ? h('div', { class: 'note', text: f.dateien }) : null)))
        : h('p', { class: 'ok', text: 'Keine Funde.' }),
      res && res.meldung ? h('p', { text: res.meldung }) : null);
  }
  dlgOpen(title, body, [{ label: 'Fertig', primary: true, onClick: dlgClose }]);
  Dlg.running = false;
}

// ---------------------------------------------------------------- Ansicht: Werkzeuge (Microsoft Defender)
const ageText = n => n == null || isNaN(n) ? '' : (Number(n) === 0 ? 'heute' : Number(n) === 1 ? 'vor 1 Tag' : `vor ${n} Tagen`);
const fmtDur = s => s == null || isNaN(s) ? '' : (s < 60 ? `${s} s` : `${Math.floor(s / 60)} min ${s % 60} s`);
const onOff = v => v === true || /^(true|an|ein)$/i.test(String(v)) ? ['an', 'ok'] : (v === false || /^(false|aus)$/i.test(String(v)) ? ['aus', 'rem'] : ['unbekannt', 'muted']);
function defBody(d) {
  const st = d.stand || {}, running = !!d.laufend, lock = readOnly(), dis = lock || running;
  const tt = lock ? lockTitle() : (running ? 'Es läuft schon eine Defender-Aufgabe.' : null);
  const [rtText, rtCls] = onOff(st.echtzeit);
  const row = (label, ...kids) => h('tr', null, h('td', { class: 'muted', text: label }), h('td', null, ...kids));
  const info = st.fehler ? h('p', { class: 'rem', text: 'Der Defender-Stand ist nicht lesbar: ' + st.fehler })
    : h('div', { class: 'tablewrap' }, h('table', null, h('tbody', null,
      row('Signaturen', st.signaturen ? fmtDate(st.signaturen) : '–', st.signaturVersion ? ` · Version ${st.signaturVersion}` : '', st.signaturAlterTage != null ? h('span', { class: Number(st.signaturAlterTage) > 3 ? 'warn' : 'muted', text: ` · ${ageText(st.signaturAlterTage)}` }) : null),
      row('Letzter Schnellscan', st.schnellscan ? fmtDate(st.schnellscan) : 'noch nie', st.schnellscan && st.schnellscanAlterTage != null ? h('span', { class: 'muted', text: ` · ${ageText(st.schnellscanAlterTage)}` }) : null),
      row('Echtzeitschutz', h('span', { class: rtCls, text: rtText })),
      st.modus ? row('Modus', String(st.modus)) : null)));
  return [info,
    running ? h('p', { class: 'warn', text: 'Es läuft schon eine Defender-Aufgabe. Warte, bis sie fertig ist.' }) : null,
    h('div', { class: 'toolbar' },
      h('button', { type: 'button', class: 'primary', disabled: dis, title: tt, text: 'Signaturen aktualisieren', onclick: () => startDefender('signaturen') }),
      h('button', { type: 'button', class: '', disabled: dis, title: tt, text: 'Schnellscan starten', onclick: () => startDefender('schnellscan') }),
      h('button', { type: 'button', class: 'danger', disabled: dis, title: tt, text: 'Offline-Scan …', onclick: startOffline }),
      running ? h('button', { type: 'button', class: 'sm ghost', text: 'Anzeige aktualisieren', onclick: refreshView }) : null),
    h('p', { class: 'note', text: 'Funde zeigt Morpheus nur an. Quarantäne und Entfernen machst du in Windows-Sicherheit (Viren- & Bedrohungsschutz > Schutzverlauf). Einen Vollscan startet Morpheus nicht: Er dauert Stunden und läuft besser über Windows-Sicherheit.' })];
}
V.werkzeuge = () => {
  const body = h('div', null, h('p', { class: 'muted', text: 'Lädt …' }));
  const token = S.rv;
  api('/api/defender').then(d => {
    if (token !== S.rv) return;
    body.replaceChildren(...defBody(d || {}).filter(Boolean));
    const o = d && d.offline;
    if (o && o.status === 'countdown' && !$('#modal').classList.contains('on')) openCountdown(o);
  }, e => { if (token === S.rv) body.replaceChildren(h('p', { class: 'rem', text: 'Der Defender-Stand konnte nicht geladen werden: ' + e.message })); });
  return h('section', null, h('h1', { text: 'Werkzeuge' }), h('p', { class: 'sub', text: 'Kleine Helfer für den PC. Sie starten nur, wenn du es auslöst, und fragen vorher in Windows nach.' }),
    readOnly() ? safetyBanner() : null,
    // Reihenfolge (2.4): Wartung & Reparatur zuerst
    wartungCard(),
    h('div', { class: 'card', id: 'def-card' }, h('h2', { text: 'Microsoft Defender' }), body),
    updCard(),
    sysCard(),
    spOrdnerCard());
};

// Eigene Spiele-Ordner (Abschnitt 14.8). Entwurf in S.spOrdner: [{ plattform, pfad }], bleibt beim Neuzeichnen erhalten.
const SP_PLATT = ['Steam', 'Epic', 'GOG', 'EA', 'Ubisoft', 'Xbox', 'Andere'];
function gotoSpOrdner() {
  closeSpPop(false);
  S.ui.focusSpOrdner = true;
  if (location.hash === '#/werkzeuge') renderView(true); else location.hash = '#/werkzeuge';
}
function spOrdnerCard() {
  const ro = readOnly(), tt = ro ? lockTitle() : null;
  const card = h('div', { class: 'card', id: 'spo-card' });
  const token = S.rv;
  const draw = () => {
    if (token !== S.rv) return;
    const busy = !!S.spoJob, dis = ro || busy;
    const list = S.spOrdner;
    const kids = [h('h2', { text: 'Spiele-Ordner' }),
      h('p', { class: 'note', text: 'Findet Morpheus eine Spielebibliothek nicht, trag den Ordner hier ein. Gemeint ist ein Ordner, in dem jeder Unterordner ein Spiel ist, z. B. F:\\Games. Pfad im Explorer aus der Adressleiste kopieren und einfügen.' })];
    if (!list) {
      kids.push(S.spoMsg && S.spoMsg.err ? h('p', { class: 'rem', text: S.spoMsg.err }) : h('p', { class: 'muted', text: 'Lädt …' }));
    } else {
      list.forEach((e, i) => {
        kids.push(h('div', { class: 'spo-row' },
          h('select', { 'aria-label': 'Plattform', disabled: dis, title: tt, onchange: ev => { e.plattform = ev.target.value; } },
            SP_PLATT.map(p => h('option', { value: p, text: p, selected: p === e.plattform }))),
          h('input', { type: 'text', 'aria-label': 'Ordnerpfad', placeholder: 'z. B. G:\\Games', spellcheck: 'false', autocomplete: 'off', maxlength: '260', value: e.pfad || '', disabled: dis, title: tt, oninput: ev => { e.pfad = ev.target.value; } }),
          h('button', { type: 'button', class: 'sm', disabled: dis, title: tt, text: 'Entfernen', onclick: () => { list.splice(i, 1); draw(); } })));
      });
      if (!list.length) kids.push(h('p', { class: 'muted', text: 'Noch keine eigenen Ordner eingetragen.' }));
      kids.push(h('div', { class: 'toolbar' },
        h('button', { type: 'button', class: '', disabled: dis || list.length >= 50, title: tt, text: 'Ordner hinzufügen', onclick: () => { list.push({ plattform: 'Andere', pfad: '' }); draw(); } }),
        h('button', { type: 'button', class: 'primary', disabled: dis, title: tt, text: 'Speichern', onclick: save })));
      const m = S.spoMsg;
      if (m && m.err) kids.push(h('p', { class: 'rem', role: 'alert', text: m.err }));
      if (m && m.saved) kids.push(h('div', { class: 'toolbar' },
        h('span', { class: 'note', text: 'Gespeichert. Die Spiele erscheinen nach dem nächsten Neuberechnen bzw. Scan.' }),
        h('button', { type: 'button', class: 'sm', disabled: dis, title: tt, text: 'Jetzt neu berechnen', onclick: recalc })));
      if (busy) kids.push(h('div', { class: 'note', 'aria-live': 'polite', text: S.spoJob.line }));
    }
    card.replaceChildren(...kids);
  };
  const save = async () => {
    if (ro || S.spoJob) return;
    const eintraege = S.spOrdner.map(e => ({ plattform: e.plattform, pfad: String(e.pfad || '').trim() })).filter(e => e.pfad);
    try {
      const r = await api('/api/spielordner', { method: 'POST', body: { eintraege } });
      S.spOrdner = Array.isArray(r) ? r.map(e => ({ plattform: e.plattform, pfad: e.pfad })) : eintraege;
      S.spoMsg = { saved: true };
    } catch (e) { S.spoMsg = { err: e.message }; }
    draw();
  };
  const recalc = async () => {
    if (ro || S.spoJob || S.spJob) return;
    S.spoJob = { line: 'Wird gestartet …' }; draw();
    try {
      await startSpeicherRefresh(l => { if (S.spoJob) { S.spoJob.line = l; draw(); } });
      toast('Speicherverbraucher neu berechnet');
    } catch (e) { toast(e.message); }
    S.spoJob = null; draw();
  };
  if (S.spOrdner) draw();
  else {
    S.spoMsg = null; draw();
    api('/api/spielordner').then(d => {
      S.spOrdner = (Array.isArray(d) ? d : []).map(e => ({ plattform: e.plattform, pfad: e.pfad }));
      draw();
    }, e => { S.spoMsg = { err: 'Die Spiele-Ordner konnten nicht geladen werden: ' + e.message }; draw(); });
  }
  if (S.ui.focusSpOrdner) {
    S.ui.focusSpOrdner = false;
    setTimeout(() => { if (card.isConnected) card.scrollIntoView({ block: 'start', behavior: 'smooth' }); }, 50);
  }
  return card;
}

// ---------------------------------------------------------------- Sysinternals (Abschnitt 15)
const SYS_INFO = { autorunsc: 'Zeigt alle Autostarts: Dienste, Treiber, Aufgaben, Anmeldung.', sigcheck: 'Prüft Signaturen von Systemdateien.' };
const SYS_TITLE = 'Sysinternals (Microsoft)';
function sysCard() {
  const body = h('div', null, h('p', { class: 'muted', text: 'Lädt …' }));
  const token = S.rv;
  const load = () => api('/api/sysinternals').then(d => {
    if (token !== S.rv) return;
    S.sys = d || {};
    const prog = h('p', { class: 'note', 'aria-live': 'polite' });
    body.replaceChildren(...sysBody(S.sys, prog).filter(Boolean));
    if (S.sys.laufend && !S.sys.fehler) {
      followJob(S.sys.laufend, l => { if (token === S.rv && l.length) prog.textContent = l[l.length - 1]; }).then(() => { if (token === S.rv) load(); }, () => { /* Anzeige bleibt */ });
    }
  }, e => { if (token === S.rv) body.replaceChildren(h('p', { class: 'rem', text: 'Der Sysinternals-Stand konnte nicht geladen werden: ' + e.message })); });
  load();
  return h('div', { class: 'card', id: 'sys-card' }, h('h2', { text: SYS_TITLE }), body);
}
function sysBody(d, prog) {
  if (d.fehler) return [h('p', { class: 'rem', text: 'Der Sysinternals-Stand ist nicht lesbar: ' + d.fehler })];
  const ro = readOnly(), running = !!d.laufend, dis = ro || running;
  const tt = ro ? lockTitle() : (running ? 'Es läuft schon ein Sysinternals-Vorgang.' : null);
  const ws = Array.isArray(d.werkzeuge) ? d.werkzeuge : [];
  const da = ws.some(w => w.vorhanden);
  const z = d.zustimmung || {};
  const state = w => {
    if (w.vorhanden && w.geprueft) return h('span', { class: 'ok', text: `✓ Signiert von ${w.signierer || 'Microsoft Corporation'}${w.version ? ' · Version ' + w.version : ''}${w.geladen ? ' · geladen am ' + fmtDate(w.geladen) : ''}` });
    if (w.vorhanden) return h('span', { class: 'rem', text: '✗ ' + (w.grund || 'Die Prüfung ist fehlgeschlagen.') });
    return h('span', { class: 'muted', text: 'nicht eingerichtet' });
  };
  const row = w => h('tr', null,
    h('td', null, h('b', { text: w.titel || w.name }), h('div', { class: 'note', text: SYS_INFO[w.name] || '' })),
    h('td', null, state(w)));
  return [
    h('p', { class: 'note', text: 'Kostenlose Werkzeuge von Microsoft. Morpheus lädt sie nur auf deinen Klick und prüft vor jedem Start die Microsoft-Signatur.' }),
    ws.length ? h('div', { class: 'tablewrap' }, h('table', null, h('tbody', null, ws.map(row)))) : h('p', { class: 'muted', text: 'Keine Angaben zu den Werkzeugen.' }),
    h('p', { class: z.akzeptiert ? 'note' : 'muted', text: z.akzeptiert ? `Lizenz angenommen am ${z.zeit ? fmtDate(z.zeit) : '?'}${z.benutzer ? ' (' + z.benutzer + ')' : ''}.` : 'Lizenz noch nicht angenommen.' }),
    running ? h('p', { class: 'warn', text: 'Es läuft schon ein Sysinternals-Vorgang. Warte, bis er fertig ist.' }) : null,
    running ? prog : null,
    ro ? h('p', { class: 'note', text: lockTitle() }) : null,
    h('div', { class: 'toolbar' },
      h('button', { type: 'button', class: 'primary', disabled: dis, title: tt, text: da ? 'Neu herunterladen …' : 'Herunterladen …', onclick: () => sysInstallDlg(d) }),
      da ? h('button', { type: 'button', class: '', text: 'Lizenztext', onclick: () => sysEulaDlg(ws) }) : null,
      (da || z.akzeptiert) ? h('button', { type: 'button', class: 'danger', disabled: dis, title: tt, text: da ? 'Entfernen …' : 'Zustimmung zurücknehmen …', onclick: () => sysRemoveDlg() }) : null,
      running ? h('button', { type: 'button', class: 'sm ghost', text: 'Anzeige aktualisieren', onclick: refreshView }) : null),
    h('p', { class: 'note', text: 'Die Ergebnisse erscheinen nach dem nächsten Scan unter Sicherheit (Autostart & Persistenz, Systemhärtung).' })];
}
/** Fehlertext für 403/409 verständlich machen. */
function sysErr(e) {
  if (e && e.status === 403) return 'Abgelehnt: ' + e.message;
  if (e && e.status === 409) return 'Es läuft schon ein Sysinternals-Vorgang. ' + e.message;
  return (e && e.message) || 'Der Vorgang ist fehlgeschlagen.';
}
function sysInstallDlg(d) {
  const url = /^https:\/\//.test(String(d.lizenzUrl || '')) ? d.lizenzUrl : 'https://learn.microsoft.com/sysinternals/license-terms';
  const ordner = d.ordner || 'C:\\ProgramData\\Morpheus\\tools';
  const da = (d.werkzeuge || []).some(w => w.vorhanden);
  const title = da ? 'Sysinternals neu herunterladen' : 'Sysinternals herunterladen';
  let wb = null;
  const chk = h('input', { type: 'checkbox', id: 'sys-ok', onchange: () => { if (wb) wb.disabled = !chk.checked; } });
  dlgOpen(title, [
    h('p', { text: 'Morpheus lädt Autoruns und Sigcheck herunter. Das passiert:' }),
    h('ul', null,
      h('li', { text: 'Quelle: download.sysinternals.com (Microsoft), zusammen ca. 4 MB.' }),
      h('li', { text: `Ablage: ${ordner} (nur Administratoren dürfen dort schreiben).` }),
      h('li', { text: 'Vor jedem Start prüft Morpheus die Microsoft-Signatur der Programme. Ein Abgleich mit VirusTotal findet nicht statt.' }),
      h('li', { text: 'Außer der Download-Anfrage an Microsoft verlassen keine Daten deinen PC.' })),
    h('h3', { text: 'Lizenz in Kürze' }),
    h('p', { text: 'Die Werkzeuge sind kostenlos. Du nutzt sie nach den Sysinternals-Lizenzbedingungen von Microsoft. Du darfst die Programme nicht weitergeben oder verkaufen, und es gibt keine Gewähr.' }),
    h('p', null, h('a', { href: url, target: '_blank', rel: 'noopener noreferrer', text: 'Lizenzbedingungen lesen' })),
    h('label', { class: 'chk' }, chk, 'Ich habe die Sysinternals-Lizenzbedingungen gelesen und nehme sie an.'),
    h('div', { class: 'note', text: 'Windows fragt danach in einem eigenen Fenster nach deiner Bestätigung.' })],
  [{ label: 'Abbrechen', onClick: dlgClose }, { label: 'Herunterladen', primary: true, disabled: true, onClick: () => runSysInstall(title) }]);
  wb = $('#dlg-buttons').lastElementChild;
}
async function runSysInstall(title) {
  const jv = jobView([['Windows-Bestätigung', /bestätig/i], ['Autoruns laden und prüfen', /autoruns/i], ['Sigcheck laden und prüfen', /sigcheck/i]]);
  dlgOpen(title, jv.nodes, [{ label: 'Läuft …', disabled: true }], { lock: true });
  let job = null, err = null;
  try {
    jv.lines(['Bitte im Windows-Fenster „Morpheus – Änderung bestätigen“ mit „Ja“ bestätigen …']);
    const r = await api('/api/sysinternals/install', { method: 'POST', body: { eulaAkzeptiert: true } });
    job = await followJob(r.jobId, jv.lines);
  } catch (e) { err = e; }
  const ok = !err && !!job && job.status === 'done', res = job && job.ergebnis;
  jv.finish(ok);
  const body = [...jv.nodes];
  if (err) body.push(h('p', { class: 'rem', text: sysErr(err) }));
  else if (!ok) body.push(h('p', { class: 'rem', text: (res && res.error) || (job && job.error) || 'Der Vorgang ist fehlgeschlagen.' }));
  else if (res) body.push(sysResult(res));
  dlgOpen(title, body, [{ label: 'Fertig', primary: true, onClick: dlgClose }]);
  Dlg.running = false;
  if (S.view === 'werkzeuge') refreshView();
}
function sysResult(res) {
  const ws = [].concat(res.werkzeuge || []).filter(Boolean);
  return h('div', null, h('h3', { text: 'Ergebnis' }),
    ws.length ? h('ul', { class: 'result' }, ws.map(w => h('li', null, h('b', { text: w.titel || w.name }), ' ',
      w.vorhanden && w.geprueft ? h('span', { class: 'ok', text: `Signiert von ${w.signierer || 'Microsoft Corporation'}${w.version ? ' · Version ' + w.version : ''}` }) : h('span', { class: 'rem', text: w.grund || 'nicht eingerichtet' })))) : null,
    res.meldung ? h('p', { text: res.meldung }) : null);
}
async function sysEulaDlg(ws) {
  const names = ws.map(w => ({ name: w.name, titel: w.titel || w.name })).filter(w => w.name);
  const pre = h('pre', { class: 'log eula', tabindex: '0', 'aria-live': 'polite', text: 'Lädt …' });
  const tabs = h('div', { class: 'toolbar' });
  const show = async n => {
    [...tabs.children].forEach((b, i) => b.classList.toggle('primary', names[i].name === n.name));
    pre.textContent = 'Lädt …';
    try {
      const r = await api('/api/sysinternals/eula?name=' + encodeURIComponent(n.name));
      pre.textContent = r && typeof r.text === 'string' && r.text ? r.text : 'Lizenztext nicht vorhanden (wird beim Herunterladen mitgeliefert).';
    } catch (e) { pre.textContent = e.message; }
  };
  names.forEach(n => tabs.append(h('button', { type: 'button', class: 'sm', text: n.titel, onclick: () => show(n) })));
  dlgOpen('Sysinternals-Lizenztext', [tabs, pre], [{ label: 'Schließen', primary: true, onClick: dlgClose }]);
  if (names.length) show(names[0]); else pre.textContent = 'Lizenztext nicht vorhanden (wird beim Herunterladen mitgeliefert).';
}
function sysRemoveDlg() {
  dlgOpen('Sysinternals entfernen', [
    h('p', { text: 'Die Werkzeuge werden gelöscht und die Lizenz-Zustimmung zurückgenommen. Die Sysinternals-Prüfungen im Scan werden dann übersprungen.' }),
    h('div', { class: 'note', text: 'Windows fragt vorher in einem eigenen Fenster nach deiner Bestätigung.' })],
  [{ label: 'Abbrechen', onClick: dlgClose }, { label: 'Entfernen', danger: true, onClick: goSysRemove }]);
}
async function goSysRemove() {
  const title = 'Sysinternals entfernen';
  dlgOpen(title, [h('p', { text: 'Bitte im Windows-Fenster „Morpheus – Änderung bestätigen“ mit „Ja“ bestätigen …' })], [{ label: 'Wartet auf Windows …', disabled: true }], { lock: true });
  try {
    await api('/api/sysinternals/entfernen', { method: 'POST' });
    dlgOpen(title, [h('p', { class: 'ok', text: 'Die Werkzeuge wurden entfernt und die Lizenz-Zustimmung zurückgenommen.' })], [{ label: 'Fertig', primary: true, onClick: dlgClose }]);
  } catch (e) {
    dlgOpen(title, [h('p', { class: 'rem', text: sysErr(e) })], [{ label: 'Schließen', primary: true, onClick: dlgClose }]);
  }
  Dlg.running = false;
  if (S.view === 'werkzeuge') refreshView();
}

// Defender-Aufgabe (Signaturen, Schnellscan): Bestätigung in der GUI, dann Windows-Bestätigung, dann Job
function startDefender(art) {
  const sig = art === 'signaturen', title = sig ? 'Signaturen aktualisieren' : 'Schnellscan starten';
  dlgOpen(title, [
    h('p', { text: sig ? 'Microsoft Defender lädt die neuesten Virensignaturen und installiert sie. Das dauert meist weniger als eine Minute.' : 'Microsoft Defender prüft die wichtigsten Bereiche deines PCs auf Schadsoftware. Das dauert einige Minuten; du kannst den PC dabei weiter benutzen.' }),
    h('div', { class: 'note', text: 'Windows fragt vorher in einem eigenen Fenster nach deiner Bestätigung. Morpheus ändert keine Einstellungen; findet Defender etwas, wendet er seine üblichen Maßnahmen an (z. B. Quarantäne).' })],
  [{ label: 'Abbrechen', onClick: dlgClose }, { label: 'Starten', primary: true, onClick: () => runDefender(art, title) }]);
}
async function runDefender(art, title) {
  const jv = jobView([['Windows-Bestätigung', /bestätig/i], ['Stand lesen', /stand vorher/i], [art === 'signaturen' ? 'Signaturen aktualisieren' : 'Schnellscan', /signaturen werden|schnellscan läuft/i], ['Stand prüfen', /stand nachher/i], ['Funde lesen', /funde seit/i]]);
  dlgOpen(title, jv.nodes, [{ label: 'Läuft …', disabled: true }], { lock: true });
  let job = null, err = null;
  try {
    jv.lines(['Bitte im Windows-Fenster „Morpheus – Änderung bestätigen“ mit „Ja“ bestätigen …']);
    const r = await api('/api/defender/run', { method: 'POST', body: { art } });
    job = await followJob(r.jobId, jv.lines);
  } catch (e) { err = e; }
  const ok = !err && !!job && job.status === 'done', res = job && job.ergebnis;
  jv.finish(ok);
  const body = [...jv.nodes];
  if (err) body.push(h('p', { class: 'rem', text: err.message }));
  else if (!ok) body.push(h('p', { class: 'rem', text: (res && res.error) || 'Der Vorgang ist fehlgeschlagen.' }));
  else if (res) body.push(defResult(res));
  dlgOpen(title, body, [{ label: 'Fertig', primary: true, onClick: dlgClose }]);
  Dlg.running = false;
  if (S.view === 'werkzeuge') refreshView();
}
function defResult(res) {
  const v = res.vorher || {}, n = res.nachher || {}, funde = [].concat(res.funde || []).filter(Boolean);
  const cell = (st, k) => st.fehler ? 'nicht lesbar' : (k === 'signaturVersion' ? (st[k] || '–') : (st[k] ? fmtDate(st[k]) : (k === 'schnellscan' ? 'noch nie' : '–')));
  const row = (label, k) => h('tr', null, h('td', { text: label }), h('td', { text: cell(v, k) }), h('td', { text: cell(n, k) }));
  return h('div', null, h('h3', { text: 'Ergebnis' }),
    h('div', { class: 'tablewrap' }, h('table', null, h('thead', null, h('tr', null, ['', 'Vorher', 'Nachher'].map(x => h('th', { text: x })))),
      h('tbody', null, row('Signaturen vom', 'signaturen'), row('Signaturversion', 'signaturVersion'), row('Letzter Schnellscan', 'schnellscan')))),
    h('h3', { text: 'Funde' }),
    funde.length ? h('ul', { class: 'result' }, funde.map(f => h('li', null, h('b', { text: f.name || 'Unbekannter Fund' }), ' ', h('span', { class: 'muted', text: f.zeit ? fmtDate(f.zeit) : '' }), ' ', h('span', { class: f.erfolg === false ? 'rem' : 'warn', text: f.aktion || '' }),
      f.dateien ? h('div', { class: 'note', text: f.dateien }) : null))) : h('p', { class: 'ok', text: 'Keine Funde.' }),
    res.meldung ? h('p', { text: res.meldung }) : null,
    res.dauerSek != null ? h('div', { class: 'note', text: 'Dauer: ' + fmtDur(res.dauerSek) }) : null);
}

// Offline-Scan: Warnung mit Häkchen, Windows-Bestätigung, dann Countdown (läuft im Server; die GUI zeigt nur an und meldet sich jede Sekunde)
function startOffline() {
  let wb = null;
  const chk = h('input', { type: 'checkbox', id: 'off-ok', onchange: () => { if (wb) wb.disabled = !chk.checked; } });
  dlgOpen('Microsoft Defender Offline-Scan', [
    h('p', { class: 'warn', text: 'Der PC startet sofort neu (nach 15 Sekunden Countdown). Der Scan dauert ca. 15 Minuten, danach startet Windows normal. Vorher alle Dateien speichern und Programme schließen.' }),
    h('label', { class: 'chk' }, chk, 'Ich habe alles gespeichert und verstanden, dass der PC neu startet.')],
  [{ label: 'Abbrechen', onClick: dlgClose }, { label: 'Weiter', danger: true, disabled: true, onClick: goOffline }]);
  wb = $('#dlg-buttons').lastElementChild;
}
async function goOffline() {
  const title = 'Microsoft Defender Offline-Scan';
  dlgOpen(title, [h('p', { text: 'Bitte im Windows-Fenster „Morpheus – Änderung bestätigen“ mit „Ja“ bestätigen …' })], [{ label: 'Wartet auf Windows …', disabled: true }], { lock: true });
  try {
    const st = await api('/api/defender/offline', { method: 'POST', body: { bestaetigt: true } });
    openCountdown(st);
  } catch (e) {
    dlgOpen(title, [h('p', { class: 'rem', text: e.message })], [{ label: 'Schließen', primary: true, onClick: dlgClose }]);
  }
}
function openCountdown(st0) {
  const title = 'Microsoft Defender Offline-Scan';
  const ctl = { alive: true, done: false, busy: false, fails: 0 };
  const num = h('div', { class: 'cd-num', 'aria-hidden': 'true' }), txt = h('p', { class: 'cd-txt', role: 'timer', 'aria-live': 'off' }), msg = h('p', { class: 'note' });
  const setRest = r => { const n = Math.max(0, Math.round(Number(r) || 0)); num.textContent = String(n); txt.textContent = `Der PC startet in ${n} ${n === 1 ? 'Sekunde' : 'Sekunden'} neu.`; };
  const btns = () => [...$('#dlg-buttons').children];
  const finish = s => {
    if (ctl.done) return; ctl.done = ctl.alive = false;
    const started = s.status === 'gestartet';
    dlgOpen(title, [h('p', { class: s.status === 'fehler' ? 'rem' : (started ? 'warn' : ''), text: started ? 'Der PC startet jetzt neu …' : (s.meldung || (s.status === 'abgebrochen' ? 'Der Offline-Scan wurde abgebrochen. Es passiert nichts.' : 'Der Countdown ist beendet.')) }), started && s.meldung ? h('p', { class: 'note', text: s.meldung }) : null],
      [{ label: 'Schließen', primary: true, onClick: dlgClose }]);
  };
  const act = async path => {
    if (ctl.busy || ctl.done) return;
    ctl.busy = true; btns().forEach(b => { b.disabled = true; });
    try {
      const s = await api('/api/defender/offline/' + path, { method: 'POST' });
      if (s.status === 'countdown') { setRest(s.rest); msg.textContent = ''; btns().forEach(b => { b.disabled = false; }); } else finish(s);
    } catch (e) { msg.textContent = e.message; btns().forEach(b => { b.disabled = false; }); }
    ctl.busy = false;
  };
  const cancel = () => act('abbrechen'), now = () => act('jetzt');
  setRest(st0.rest);
  dlgOpen(title, [h('p', { class: 'warn', text: 'Speichere alles und schließe deine Programme.' }), num, txt, msg],
    [{ label: 'Abbrechen', primary: true, onClick: cancel }, { label: 'Jetzt neu starten', danger: true, onClick: now }], { onEsc: cancel, onClose: () => { ctl.alive = false; } });
  (async () => {   // genau eine Abfrage pro Sekunde, nie überlappend
    while (ctl.alive) {
      const t0 = Date.now();
      try {
        const s = await api('/api/defender/offline');
        if (!ctl.alive) break;
        ctl.fails = 0;
        if (s.status === 'countdown') { if (!ctl.busy) msg.textContent = ''; setRest(s.rest); } else { finish(s); break; }
      } catch (e) {
        if (e.status === 401) break;
        if (++ctl.fails >= 2 && !ctl.busy) msg.textContent = 'Keine Verbindung zu Morpheus. Der Server bricht den Countdown selbst ab, wenn er dich nicht mehr erreicht.';
      }
      await sleep(Math.max(0, 1000 - (Date.now() - t0)));
    }
  })();
}

// ---------------------------------------------------------------- Wartung & Reparatur, Programme aktualisieren (Abschnitt 18)
const WT_KLASSE = { diagnose: ['INFO', 'liest nur'], wartung: ['OK', 'harmlos'], reparatur: ['WARN', 'nicht umkehrbar'] };
const WT_ERG = { ok: ['OK', 'in Ordnung'], repariert: ['OK', 'repariert'], reparierbar: ['WARN', 'reparierbar'], problem: ['WARN', 'Problem'], fehler: ['CRIT', 'Fehler'], unbekannt: ['INFO', 'nicht eindeutig'] };
const WT_STATUS = { erledigt: 'Erledigt', fehlgeschlagen: 'Fehlgeschlagen', abgebrochen: 'Abgebrochen', zeitueberschreitung: 'Zeitlimit überschritten' };
const WT_PAKET = { aktualisiert: ['OK', 'aktualisiert'], 'kein-update': ['OK', 'kein Update nötig'], neustart: ['WARN', 'Neustart nötig'], 'laeuft-noch': ['WARN', 'Programm läuft noch'], fehlgeschlagen: ['CRIT', 'fehlgeschlagen'], abgebrochen: ['INFO', 'abgebrochen'] };
const WT_GRUPPEN_OHNE = ['Wiederherstellung', 'Programme'];
const WT_PUNKT_ID = 'wiederherstellung.punkt', WT_WINGET_ID = 'winget.upgrade';
const WT_WIN_TEXT = 'Bitte im Windows-Fenster „Morpheus – Änderung bestätigen“ mit „Ja“ bestätigen …';
const WT = new Map();          // jobId -> Verfolger eines laufenden Wartungs- bzw. Update-Jobs (bleibt auch ohne Dialog aktiv)
const WT_SEARCH = new Map();   // jobId -> Verfolger einer Update-Suche
S.wt = { tools: [], sel: new Set(), report: null, scrollReport: false };

const klasseChip = k => { const c = WT_KLASSE[k] || ['INFO', String(k || '')]; return h('span', { class: 'chip ' + c[0], text: c[1] }); };
const wtChip = (tab, key, fallback) => { const c = tab[key]; return h('span', { class: 'chip ' + (c ? c[0] : 'INFO'), text: c ? c[1] : (fallback || String(key || '')) }); };
const wtErr = e => e && e.status === 403 ? 'Abgelehnt: ' + e.message : ((e && e.message) || 'Der Vorgang ist fehlgeschlagen.');
/** Werkzeug aus dem zuletzt geladenen Katalog (mit Rückfall für winget und den Wiederherstellungspunkt). */
function wtTool(id) {
  const w = (S.wt.tools || []).find(x => x.id === id);
  if (w) return w;
  if (id === WT_WINGET_ID) return { id, titel: 'Programme aktualisieren (winget)', klasse: 'reparatur', punkt: true, abbruch: 'nach-paket', befehl: 'winget upgrade --id <Paket-Id> --exact --source winget --silent' };
  if (id === WT_PUNKT_ID) return { id, titel: 'Wiederherstellungspunkt anlegen', erklaerung: 'Legt jetzt einen Wiederherstellungspunkt an und prüft ihn.', klasse: 'wartung', punkt: false, abbruch: 'nein', dauer: 'etwa eine Minute', befehl: "Checkpoint-Computer -Description 'Morpheus: von Hand angelegt' -RestorePointType MODIFY_SETTINGS" };
  return { id, titel: String(id || 'Wartung'), klasse: 'wartung', punkt: false, abbruch: 'nein' };
}
function wtCfg(id, abbruch) {
  const w = wtTool(id), winget = id === WT_WINGET_ID;
  return { w, title: winget ? 'Programme aktualisieren' : w.titel, winget, punkt: !!w.punkt || winget || id === WT_PUNKT_ID, abbruch: abbruch || w.abbruch || 'nein' };
}
function wtSteps(cfg) {
  const st = [['Windows-Bestätigung', /bestätig/i]];
  if (cfg.punkt) st.push(['Wiederherstellungspunkt anlegen und prüfen', /wiederherstellungspunkt/i]);
  if (cfg.w.id !== WT_PUNKT_ID) st.push([cfg.winget ? 'Programme werden aktualisiert' : 'Werkzeug läuft', /^\[[^\]]*\] (Starte:|Paket \d)/]);
  // winget: nur die Abschlusszeile „<ok> von <n> Programmen erledigt …“ (jedes Paket meldet auch „Ergebnis: <Name>: …“)
  st.push(['Ergebnis', cfg.winget ? /Ergebnis: \d+ von \d+/ : /Ergebnis:/]);
  return st;
}
const wtBefehl = (w, lw) => String(w.befehl || '').replace(/<LW>/g, lw || '<LW>');

/** Verfolger für einen Job anlegen (oder den vorhandenen liefern). Läuft bis zum Ende, auch wenn kein Dialog offen ist. */
function wtCtl(jobId, cfg) {
  let c = WT.get(jobId);
  if (c) return c;
  c = { jobId, cfg, jv: jobView(wtSteps(cfg)), bg: true, done: false, cancelling: false, job: null, err: null };
  c.jv.lines(['Windows-Bestätigung erteilt, der Auftrag läuft.']);
  WT.set(jobId, c);
  followJob(jobId, c.jv.lines).then(j => { c.job = j; }, e => { c.err = e; }).then(() => wtDone(c));
  return c;
}
function wtShow(c) {
  c.bg = false;
  if (c.done) { wtResultDlg(c); return; }
  const btns = [];
  if (c.cfg.abbruch !== 'nein') btns.push({ label: c.cancelling ? 'Abbruch angefordert …' : (c.cfg.winget ? 'Nach dem aktuellen Programm aufhören' : 'Abbrechen'), disabled: c.cancelling, onClick: ev => wtCancel(c, ev.currentTarget) });
  btns.push({ label: 'Im Hintergrund weiterlaufen lassen', onClick: () => wtBackground(c) });
  dlgOpen(c.cfg.title, [...c.jv.nodes, c.cfg.abbruch === 'nein' ? h('div', { class: 'note', text: 'Dieses Werkzeug lässt sich nicht sicher abbrechen. Du kannst das Fenster im Hintergrund weiterlaufen lassen.' }) : null], btns, { lock: true });
}
function wtBackground(c) {
  c.bg = true; dlgClose();
  if (S.view === 'werkzeuge') refreshView();
}
async function wtCancel(c, btn) {
  if (c.cancelling) return;
  c.cancelling = true; btn.disabled = true; btn.textContent = 'Abbruch angefordert …';
  try {
    const r = await api('/api/wartung/abbrechen', { method: 'POST', body: { jobId: c.jobId } });
    if (r && r.meldung) toast(r.meldung);
  } catch (e) { c.cancelling = false; btn.disabled = false; btn.textContent = c.cfg.winget ? 'Nach dem aktuellen Programm aufhören' : 'Abbrechen'; toast(e.message); }
}
function wtDone(c) {
  c.done = true; WT.delete(c.jobId);
  loadSession().catch(() => {});
  if (c.cfg.winget) S.wt.sel.clear();
  const res = c.job && c.job.ergebnis;
  // Ids des gescheiterten winget-Laufs merken: ohne Punkt verlangt der Server genau diese Menge
  if (c.cfg.winget) {
    if (res && res.status === 'punkt-fehlt') S.wt.punktIds = c.cfg.ids || [].concat(res.pakete || []).filter(Boolean).map(p => p.id).filter(Boolean);
    else if (res && res.status) S.wt.punktIds = null;
  }
  if (c.bg) {
    const pf = res && res.status === 'punkt-fehlt';
    const st = c.err ? c.err.message : (res && res.status ? (WT_STATUS[res.status] || (pf ? 'kein Wiederherstellungspunkt, nichts gestartet. Unter „Werkzeuge“ kannst du bewusst ohne Punkt starten.' : res.status)) : (c.job && c.job.status === 'failed' ? 'fehlgeschlagen' : 'fertig'));
    toast(`${c.cfg.title}: ${st}`);
  } else wtResultDlg(c);
  if (S.view === 'werkzeuge') refreshView();
}

/** Start: Windows-Bestätigung abwarten, dann dem Job im Dialog folgen. post(ohnePunkt) liefert { jobId }. */
async function wtRun(cfg, post, ohnePunkt) {
  dlgOpen(cfg.title, [h('p', { text: WT_WIN_TEXT }), h('div', { class: 'note', text: 'Danach beginnt die Arbeit; dieses Fenster zeigt den Ablauf.' })], [{ label: 'Wartet auf Windows …', disabled: true }], { lock: true });
  let r;
  try { r = await post(!!ohnePunkt); }
  catch (e) {
    dlgOpen(cfg.title, [h('p', { class: 'rem', text: wtErr(e) })], [{ label: 'Schließen', primary: true, onClick: dlgClose }]);
    if (S.view === 'werkzeuge') refreshView();
    return;
  }
  // Ohne Wiederherstellungspunkt gibt es den Schritt nicht; er soll nicht als erledigt erscheinen
  const c = wtCtl(r.jobId, ohnePunkt ? { ...cfg, punkt: false } : cfg);
  c.cfg.post = post;
  wtShow(c);
  if (S.view === 'werkzeuge') refreshView();
}
const wtPostWinget = ids => ohne => api('/api/updates/installieren', { method: 'POST', body: { ids, ...(ohne ? { ohnePunkt: true } : {}) } });
const wtPostStart = (w, lw) => ohne => api('/api/wartung/start', { method: 'POST', body: { werkzeug: w.id, ...(lw ? { laufwerk: lw } : {}), ...(ohne ? { ohnePunkt: true } : {}) } });

function wtStartDlg(w, lw) {
  const cfg = wtCfg(w.id), cmd = wtBefehl(w, lw);
  const body = [
    w.erklaerung ? h('p', { text: w.erklaerung }) : null,
    h('p', null, klasseChip(w.klasse), w.dauer ? [' ', h('span', { class: 'wt-dur', text: 'Dauer: ' + w.dauer })] : null, lw ? [' ', h('span', { class: 'wt-dur', text: 'Laufwerk: ' + lw })] : null),
    cmdBlock(cmd, true, /^Checkpoint-Computer/.test(cmd) ? 'PowerShell · Administrator' : 'Eingabeaufforderung · Administrator'),
    w.klasse === 'reparatur' ? h('div', { class: 'wt-box', role: 'note' }, h('b', { text: 'Nicht umkehrbar: ' }), 'kein Rückgängig unter „Änderungen“. Vorher wird ein Wiederherstellungspunkt angelegt und geprüft.') : null,
    w.internet ? h('p', { class: 'note', text: 'Braucht eine Internetverbindung (Windows Update).' }) : null,
    w.hinweis ? h('p', { class: 'note', text: w.hinweis }) : null,
    h('div', { class: 'note', text: 'Windows fragt vorher in einem eigenen Fenster nach deiner Bestätigung.' })];
  dlgOpen(w.titel, body, [{ label: 'Abbrechen', onClick: dlgClose }, { label: 'Starten', primary: true, onClick: () => wtRun(cfg, wtPostStart(w, lw)) }]);
}

function wtResultNodes(res, cfg) {
  const z = res.zusammenfassung || {}, kids = [h('h3', { text: 'Ergebnis' })];
  kids.push(h('p', { class: 'wt-res' }, h('b', { text: WT_STATUS[res.status] || res.status || '' }), z.ergebnis ? [' ', wtChip(WT_ERG, z.ergebnis)] : null,
    res.ohnePunkt ? [' ', h('span', { class: 'chip WARN', text: 'ohne Wiederherstellungspunkt' })] : null));
  if (z.text) kids.push(h('p', { text: z.text }));
  if (z.empfehlung) kids.push(h('p', null, h('b', { text: 'Empfehlung: ' }), z.empfehlung));
  const det = [].concat(z.details || []).filter(Boolean);
  if (det.length) kids.push(h('ul', { class: 'explain' }, det.map(x => h('li', { text: String(x) }))));
  const pk = [].concat(res.pakete || []).filter(Boolean);
  if (pk.length) kids.push(h('div', { class: 'tbl-scroll wt-upd' }, h('table', null,
    h('thead', null, h('tr', null, ['Programm', 'von', 'auf', 'Ergebnis'].map(x => h('th', { text: x })))),
    h('tbody', null, pk.map(p => h('tr', null, h('td', { text: p.name || p.id }), h('td', { text: p.von || '' }), h('td', { text: p.auf || '' }),
      h('td', null, wtChip(WT_PAKET, p.status), p.text ? h('div', { class: 'note', text: p.text }) : null)))))));
  const meta = [];
  if (res.dauerSek != null) meta.push('Dauer ' + fmtDur(res.dauerSek));
  if (res.exitCode != null) meta.push('Exit-Code ' + res.exitCode);
  if (meta.length) kids.push(h('p', { class: 'note', text: meta.join(' · ') }));
  if (res.punkt && res.punkt.seq != null) kids.push(h('p', { class: 'note' }, 'Wiederherstellungspunkt ', h('code', { text: '#' + res.punkt.seq }), res.punkt.zeit ? ` (${fmtDate(res.punkt.zeit)})` : ''));
  if (res.meldung) kids.push(h('p', { class: 'note wt-msg', text: res.meldung }));
  if (res.status !== 'punkt-fehlt') kids.push(h('p', { class: 'note', text: 'Steht unter „Änderungen“ im Protokoll (kein Rückgängig).' }));
  return kids;
}
function wtResultDlg(c) {
  const job = c.job, err = c.err, res = job && job.ergebnis, cfg = c.cfg;
  if (res && res.status === 'punkt-fehlt') { c.jv.finish(false); wtPunktFehlt(c, res); return; }
  const ok = !err && !!res && !res.error && res.status === 'erledigt';
  c.jv.finish(ok);
  const body = [...c.jv.nodes];
  if (err) body.push(h('p', { class: 'rem', text: err.message }));
  else if (!res || res.error || !res.status) body.push(h('p', { class: 'rem', text: (res && res.error) || 'Der Vorgang ist fehlgeschlagen.' }));
  else body.push(...wtResultNodes(res, cfg));
  // 2.5 (#67, G3): winget lief ohne Adminrechte
  if (res && res.benutzerkontext) body.push(h('p', null, h('span', { class: 'chip OK', text: 'ohne Adminrechte' }), ' winget lief im Benutzerkontext. Programme, die Adminrechte brauchen, haben selbst über Windows gefragt.'));
  const btns = [];
  if (res && res.bericht) btns.push({ label: 'Bericht öffnen', onClick: () => wtOpenReport(res.bericht) });
  if (cfg.winget) btns.push({ label: 'Erneut suchen', onClick: () => { dlgClose(); updSuchen(); } });
  btns.push({ label: 'Fertig', primary: true, onClick: dlgClose });
  dlgOpen(cfg.title, body, btns);
  Dlg.running = false;
}
function wtPunktFehlt(c, res) {
  const cfg = c.cfg;
  let wb = null;
  const chk = h('input', { type: 'checkbox', onchange: () => { if (wb) wb.disabled = !chk.checked; } });
  const ids = cfg.ids || S.wt.punktIds;
  const post = cfg.post || (cfg.winget ? (ids && ids.length ? wtPostWinget(ids) : null) : wtPostStart(cfg.w, null));
  dlgOpen(cfg.title, [
    h('p', { class: 'rem', text: 'Es wurde nichts gestartet: Windows hat keinen Wiederherstellungspunkt angelegt.' }),
    h('p', { class: 'wt-msg', text: res.meldung || '' }),
    post ? h('label', { class: 'chk' }, chk, 'Ich habe verstanden: ohne Wiederherstellungspunkt gibt es kein Netz. Trotzdem starten.') : null],
  [{ label: 'Schließen', primary: true, onClick: dlgClose }, post ? { label: 'Ohne Wiederherstellungspunkt starten', danger: true, disabled: true, onClick: () => wtRun(cfg, post, true) } : null].filter(Boolean));
  wb = $('#dlg-buttons').lastElementChild;
  if (!post || wb.textContent !== 'Ohne Wiederherstellungspunkt starten') wb = null;
}

// ---- Berichte (Energie, Akku, Schlafstudie)
function wtReportSrc(name) {
  if (typeof window.PCCHECK_REPORT_SRC === 'function') return Promise.resolve(window.PCCHECK_REPORT_SRC(name));
  return api('/api/report-ticket', { method: 'POST', body: { name } }).then(r => `/report/${name}?k=${encodeURIComponent(r.ticket)}`);
}
function wtViewer(box, list) {
  box.replaceChildren();
  const name = S.wt.report;
  if (!name) return;
  const b = list.find(x => x.name === name), titel = b ? b.titel : name;
  // sandbox ohne allow-same-origin und ohne allow-popups: der Bericht erreicht weder die API noch öffnet er Fenster
  const frame = h('iframe', { class: 'wt-frame', sandbox: 'allow-scripts', title: 'Bericht: ' + titel });
  box.append(h('div', { class: 'wt-report', id: 'wt-report' }, h('div', { class: 'toolbar' }, h('b', { text: titel }),
    h('button', { type: 'button', text: 'Schließen', onclick: () => { S.wt.report = null; wtViewer(box, list); } })), frame));
  wtReportSrc(name).then(src => { frame.src = src; }, e => { if (frame.isConnected) frame.replaceWith(h('p', { class: 'rem', text: e.message })); });
}
function wtOpenReport(name) {
  S.wt.report = name; S.wt.scrollReport = true;
  dlgClose();
  if (S.view === 'werkzeuge') refreshView(); else location.hash = '#/werkzeuge';
}

// ---- Karte „Wartung & Reparatur“
function wtRow(w, d, dis, tt) {
  const laufw = Array.isArray(d.laufwerke) ? d.laufwerke : [];
  const hp = S.help && (S.help.Wartung || S.help.wartung), help = hp && hp[w.id];
  let sel = null, noLw = null;
  if (w.parameter === 'laufwerk' || w.parameter === 'ssd') {
    const opts = laufw.filter(l => w.parameter === 'laufwerk' || l.ssd === true);
    if (opts.length) sel = h('select', { 'aria-label': 'Laufwerk für ' + w.titel }, opts.map(l => h('option', { value: l.laufwerk, text: l.bezeichnung ? `${l.laufwerk} ${l.bezeichnung}` : l.laufwerk })));
    else noLw = w.parameter === 'ssd' ? 'Keine SSD gefunden. TRIM gibt es nur für SSDs.' : 'Keine festen Laufwerke gefunden.';
  }
  const off = dis || !!noLw;
  const step = w.gruppe === 'Systemdateien' && w.schritt ? `${w.schritt}. ` : '';
  let cb = cmdBlock(wtBefehl(w, sel ? sel.value : null), true, 'Eingabeaufforderung · Administrator');
  if (sel) sel.addEventListener('change', () => { const n = cmdBlock(wtBefehl(w, sel.value), true, 'Eingabeaufforderung · Administrator'); cb.replaceWith(n); cb = n; });
  const meta = [w.dauer ? 'Dauer: ' + w.dauer : null, w.internet ? 'braucht Internet' : null].filter(Boolean).join(' · ');
  return h('div', { class: 'wt-row', 'data-id': w.id },
    h('div', { class: 'wt-head' }, h('b', { class: 'wt-title', text: step + w.titel }), klasseChip(w.klasse)),
    w.erklaerung ? h('p', { class: 'wt-expl', text: w.erklaerung }) : null,
    meta ? h('p', { class: 'wt-meta', text: meta }) : null,
    w.hinweis ? h('p', { class: 'wt-meta', text: w.hinweis }) : null,
    noLw ? h('p', { class: 'wt-meta', text: noLw }) : null,
    (d.punktFehlt || []).includes(w.id) ? h('p', { class: 'wt-meta', text: 'Der letzte Start brach ab, weil kein Wiederherstellungspunkt entstand. Beim erneuten Start kannst du das bewusst übergehen.' }) : null,
    (d.punktFehlt || []).includes(w.id) && !dis ? h('div', { class: 'wt-acts' }, h('button', { type: 'button', class: 'sm', text: 'Ohne Wiederherstellungspunkt starten …',
      onclick: () => wtPunktFehlt({ cfg: { ...wtCfg(w.id), post: wtPostStart(w, sel ? sel.value : null) } }, { meldung: 'Beim letzten Start entstand kein Wiederherstellungspunkt.' }) })) : null,
    help ? h('details', { class: 'cmd' }, h('summary', { text: 'ⓘ Mehr' }),
      h('div', { class: 'wt-help' }, help.Was ? h('p', null, h('b', { text: 'Was passiert? ' }), help.Was) : null, help.Wann ? h('p', null, h('b', { text: 'Wann sinnvoll? ' }), help.Wann) : null, help.Hinweis ? h('p', null, h('b', { text: 'Hinweis: ' }), help.Hinweis) : null)) : null,
    h('details', { class: 'cmd' }, h('summary', { text: 'Befehl zeigen' }), cb),
    h('div', { class: 'wt-acts' }, sel, h('button', { type: 'button', class: 'sm' + (w.klasse === 'reparatur' ? '' : ' primary'), disabled: off, title: off ? (noLw && !dis ? noLw : tt) : null, text: 'Starten …', onclick: () => wtStartDlg(w, sel ? sel.value : null) })));
}
function wtRestore(d, dis, tt) {
  const sf = d.safety || safety(), w = wtTool(WT_PUNKT_ID);
  const off = dis || sf.schutzAn === false;
  const state = h('div', { class: 'wt-state' },
    h('span', null, 'Computerschutz ', sf.schutzAn === false ? h('span', { class: 'chip CRIT', text: 'aus' }) : (sf.schutzAn === true ? h('span', { class: 'chip OK', text: 'an' }) : h('span', { class: 'chip INFO', text: 'unbekannt' }))),
    h('span', null, '24-Stunden-Sperre ', sf.sperre24h ? h('span', { class: 'chip WARN', text: 'aktiv' }) : h('span', { class: 'chip OK', text: 'nein' })),
    sf.speicherKlein ? h('span', null, 'Speicher ', h('span', { class: 'chip WARN', text: 'zu klein' }), sf.speicherMax ? ` (erlaubt: ${sf.speicherMax})` : '') : null,
    h('span', null, 'Letzter Punkt: ', h('b', { text: sf.letzterPunkt ? fmtDate(sf.letzterPunkt) : '–' })));
  return h('div', { class: 'wt-group', id: 'wt-punkt' }, h('h3', { text: 'Wiederherstellungspunkt' }),
    h('p', { class: 'wt-expl', text: 'Vor jeder nicht umkehrbaren Reparatur legt Morpheus selbst einen Wiederherstellungspunkt an. Hier kannst du einen von Hand anlegen.' }),
    state,
    sf.schutzAn === false ? h('div', null, h('p', { class: 'wt-meta', text: 'Der Computerschutz ist aus. Schalte ihn ein (Administrator-PowerShell), danach die Seite neu laden:' }), sf.befehlSchutz ? cmdBlock(sf.befehlSchutz) : null) : null,
    sf.sperre24h ? h('div', null, h('p', { class: 'wt-meta', text: 'Windows legt innerhalb von 24 Stunden keinen weiteren Wiederherstellungspunkt an. Den Mindestabstand hebst du einmalig mit diesem Befehl auf (Administrator-PowerShell):' }), sf.befehl ? cmdBlock(sf.befehl) : null,
      h('p', { class: 'wt-meta', text: 'Mehr dazu: README, Abschnitt „24-Stunden-Sperre“.' })) : null,
    h('div', { class: 'wt-acts' }, h('button', { type: 'button', class: 'sm primary', disabled: off, title: off ? (dis ? tt : 'Der Computerschutz ist aus: ohne ihn lässt sich kein Wiederherstellungspunkt anlegen.') : null, text: 'Wiederherstellungspunkt jetzt anlegen', onclick: () => wtStartDlg(w, null) })));
}
function wtBody(d, upd) {
  S.wt.tools = Array.isArray(d.werkzeuge) ? d.werkzeuge : [];
  const ro = readOnly(), run = d.laufend || null, suche = !!(upd && upd.suche);
  const dis = ro || !!run || suche;
  const cfgRun = run ? wtCfg(run.werkzeug, run.abbruch) : null;
  const tt = ro ? lockTitle() : (run ? `Es läuft schon: ${cfgRun.title}. Warte, bis es fertig ist.` : (suche ? 'Es läuft gerade eine Update-Suche.' : null));
  const kids = [h('p', { class: 'wt-expl', text: 'Windows-Bordmittel, die Morpheus für dich startet. Jedes Werkzeug zeigt vorher den genauen Befehl und fragt in Windows nach.' }),
    h('div', { class: 'wt-legend', role: 'list', 'aria-label': 'Legende' },
      h('span', { role: 'listitem' }, klasseChip('diagnose'), ' ändert nichts'), h('span', { role: 'listitem' }, klasseChip('wartung'), ' kleine, unkritische Änderung'), h('span', { role: 'listitem' }, klasseChip('reparatur'), ' kein Rückgängig unter „Änderungen“'))];
  if (ro) kids.push(h('p', { class: 'wt-meta', text: lockTitle() }));
  if (run) {
    const c = wtCtl(run.jobId, cfgRun);
    kids.push(h('div', { class: 'wt-run', role: 'status' }, h('span', { text: `Läuft: ${cfgRun.title} …` }), h('button', { type: 'button', class: 'sm', text: 'Anzeigen', onclick: () => wtShow(c) })));
  }
  kids.push(wtRestore(d, dis, tt));
  const groups = [];
  S.wt.tools.filter(w => !WT_GRUPPEN_OHNE.includes(w.gruppe) && w.id !== WT_PUNKT_ID && w.id !== 'perfmon.rel').forEach(w => { let g = groups.find(x => x.name === w.gruppe); if (!g) groups.push(g = { name: w.gruppe, list: [] }); g.list.push(w); });
  const berichte = Array.isArray(d.berichte) ? d.berichte : [];
  const viewer = h('div'), repBtns = [];
  groups.forEach(g => {
    g.list.sort((a, b) => (a.schritt || 0) - (b.schritt || 0));
    const gk = [h('h3', { text: g.name })];
    if (g.name === 'Systemdateien') gk.push(h('p', { class: 'wt-expl', text: 'Reihenfolge 1 bis 4: Erst prüfen (1, 2), bei Befund den Komponentenspeicher reparieren (3), danach die Systemdateien (4). SFC repariert aus dem Komponentenspeicher, den DISM vorher in Ordnung bringt.' }));
    if (g.name === 'Komponentenspeicher') gk.push(h('p', { class: 'wt-expl', text: 'Den Ordner WinSxS nie von Hand löschen. Morpheus verwendet kein /ResetBase, damit Updates deinstallierbar bleiben.' }));
    gk.push(h('div', { class: 'wt-list' }, g.list.map(w => wtRow(w, d, dis, tt))));
    if (g.name === 'Diagnose') gk.push(h('div', { class: 'wt-row', 'data-id': 'perfmon.rel' },
      h('div', { class: 'wt-head' }, h('b', { class: 'wt-title', text: 'Zuverlässigkeitsverlauf' }), klasseChip('diagnose')),
      h('p', { class: 'wt-expl', text: 'Zeigt in Windows, wann Programme oder das System abgestürzt sind.' }),
      h('p', { class: 'wt-meta', text: 'Öffnet sich ohne Adminrechte; klappt das nicht: Win + R, perfmon /rel' }),
      h('div', { class: 'wt-acts' }, h('button', { type: 'button', class: 'sm primary', text: 'Zuverlässigkeitsverlauf öffnen', onclick: wtZuverlaessigkeit }))));
    if (g.name === 'Energieberichte') {
      gk.push(h('h3', { class: 'wt-sub', text: 'Erstellte Berichte' }));
      gk.push(berichte.length ? h('div', { class: 'wt-reps' }, berichte.map(b => {
        const btn = h('button', { type: 'button', class: 'sm', onclick: () => {
          S.wt.report = S.wt.report === b.name ? null : b.name; S.wt.scrollReport = !!S.wt.report;
          wtViewer(viewer, berichte); repBtns.forEach(x => x()); wtScrollReport();
        } });
        const upd = () => { btn.textContent = S.wt.report === b.name ? 'Schließen' : 'Öffnen'; };
        upd(); repBtns.push(upd);
        return h('div', { class: 'wt-rep' }, h('b', { text: b.titel || b.name }), h('span', { class: 'wt-meta', text: b.zeit ? fmtDate(b.zeit) : '' }), btn);
      })) : h('p', { class: 'wt-meta', text: 'Noch keine Berichte erstellt.' }));
      gk.push(viewer);
    }
    kids.push(h('div', { class: 'wt-group' }, gk));
  });
  if (!groups.length) kids.push(h('p', { class: 'muted', text: 'Der Server hat keine Werkzeuge gemeldet.' }));
  wtViewer(viewer, berichte);
  wtScrollReport();
  return kids;
}
function wtScrollReport() {
  if (!S.wt.scrollReport || !S.wt.report) return;
  S.wt.scrollReport = false;
  setTimeout(() => { const el = $('#wt-report'); if (el) el.scrollIntoView({ block: 'start', behavior: 'smooth' }); }, 80);
}
async function wtZuverlaessigkeit() {
  try {
    const r = await api('/api/wartung/zuverlaessigkeit', { method: 'POST' });
    toast((r && r.meldung) || (r && r.ok === false ? 'Das hat nicht geklappt. Win + R, dann perfmon /rel' : 'Zuverlässigkeitsverlauf wird geöffnet'));
  } catch (e) { toast(e.message + ' Alternativ: Win + R, perfmon /rel'); }
}
function wartungCard() {
  const body = h('div', null, h('p', { class: 'muted', text: 'Lädt …' }));
  const token = S.rv;
  Promise.all([api('/api/wartung'), api('/api/updates').catch(() => null)]).then(([d, upd]) => {
    if (token !== S.rv) return;
    body.replaceChildren(...wtBody(d || {}, upd).filter(Boolean));
  }, e => { if (token === S.rv) body.replaceChildren(h('p', { class: 'rem', text: 'Wartung & Reparatur konnte nicht geladen werden: ' + e.message })); });
  return h('div', { class: 'card', id: 'wartung-card' }, h('h2', { text: 'Wartung & Reparatur' }), body);
}

// ---- Karte „Programme aktualisieren (winget)“
function updSuchen() {
  api('/api/updates/suchen', { method: 'POST' }).then(r => updShowSearch(updFollowSearch(r.jobId, false)), e => toast(wtErr(e)));
}
function updFollowSearch(jobId, bg) {
  let c = WT_SEARCH.get(jobId);
  if (c) return c;
  const title = 'Nach Programm-Updates suchen';
  c = { jobId, bg, log: h('pre', { class: 'log', 'aria-live': 'polite', text: '' }) };
  WT_SEARCH.set(jobId, c);
  followJob(jobId, l => { c.log.append(document.createTextNode(l.join('\n') + '\n')); c.log.scrollTop = c.log.scrollHeight; })
    .then(j => ({ j }), e => ({ e }))
    .then(r => {
      WT_SEARCH.delete(jobId);
      const msg = r.e ? r.e.message : (r.j && r.j.status === 'failed' ? ((r.j.ergebnis && r.j.ergebnis.error) || 'Die Suche ist fehlgeschlagen.') : null);
      if (c.bg) toast(msg || 'Update-Suche fertig');
      else if (msg) dlgOpen(title, [c.log, h('p', { class: 'rem', text: msg })], [{ label: 'Schließen', primary: true, onClick: dlgClose }]);
      else dlgClose();
      if (S.view === 'werkzeuge') refreshView();
    });
  return c;
}
function updShowSearch(c) {
  c.bg = false;
  dlgOpen('Nach Programm-Updates suchen', [h('p', { class: 'note', text: 'winget fragt die Paketquellen ab. Das dauert meist ein bis zwei Minuten. Es wird nichts installiert.' }), c.log],
    [{ label: 'Im Hintergrund weiterlaufen lassen', onClick: () => { c.bg = true; dlgClose(); if (S.view === 'werkzeuge') refreshView(); } }], { lock: true });
}
function updInstallDlg(items) {
  const ids = items.map(x => x.id);
  const cfg = { ...wtCfg(WT_WINGET_ID), ids };
  const body = [
    h('p', { text: items.length === 1 ? 'Dieses Programm wird mit winget aktualisiert:' : `Diese ${items.length} Programme werden mit winget aktualisiert:` }),
    h('ul', { class: 'wt-pk' }, items.map(x => h('li', null, h('b', { text: x.name || x.id }), h('span', { class: 'muted', text: ` ${x.installiert || '?'} → ${x.verfuegbar || '?'}` })))),
    h('p', null, h('span', { class: 'chip WARN', text: 'nicht umkehrbar' })),
    h('p', { text: 'Programm-Updates lassen sich nicht über „Änderungen“ zurücknehmen. Vorher wird ein Wiederherstellungspunkt angelegt.' }),
    h('p', { text: 'Bitte die Programme vorher schließen.' }),
    h('p', { class: 'note', text: 'winget lädt aus den Herstellerquellen und nimmt die Lizenzbedingungen der Pakete an.' }),
    h('div', { class: 'note', text: 'Windows fragt vorher in einem eigenen Fenster nach deiner Bestätigung.' })];
  const post = wtPostWinget(ids);
  dlgOpen('Programme aktualisieren', body, [{ label: 'Abbrechen', onClick: dlgClose }, { label: 'Aktualisieren', primary: true, onClick: () => wtRun(cfg, post) }]);
}
function updBody(d) {
  const ro = readOnly(), run = d.laufend || null, search = d.suche || null;
  const fremd = d.wartungLaeuft && d.wartungLaeuft !== WT_WINGET_ID;
  const dis = ro || !!run || !!search || !!fremd;
  const tt = ro ? lockTitle() : (fremd ? 'Es läuft gerade ein Wartungswerkzeug.' : (run ? 'Es läuft schon eine Wartung bzw. ein Programm-Update.' : (search ? 'Die Suche läuft noch.' : null)));
  if (d.punktFehlt === false) S.wt.punktIds = null;
  const pIds = d.punktFehlt === true && Array.isArray(S.wt.punktIds) && S.wt.punktIds.length ? S.wt.punktIds : null;
  const liste = Array.isArray(d.liste) ? d.liste : [];
  const prog = liste.filter(x => x.kategorie === 'Programm');
  const sel = S.wt.sel;
  [...sel].forEach(id => { if (!prog.some(x => x.id === id)) sel.delete(id); });
  const kids = [h('p', { class: 'wt-expl', text: 'Aktualisiert Programme über winget, das Paketsystem von Windows. Spiele und Launcher sowie Programme, die sich selbst aktualisieren, fasst Morpheus nicht an.' })];
  kids.push(h('p', { class: 'wt-meta', text: d.stand ? `Stand der Suche: ${fmtDate(d.stand)}` : 'Noch nicht gesucht.' }));
  if (d.fehler) kids.push(h('p', { class: 'rem', text: String(d.fehler) }));
  if (ro) kids.push(h('p', { class: 'wt-meta', text: lockTitle() }));
  if (run) { const c = wtCtl(run, wtCfg(WT_WINGET_ID)); kids.push(h('div', { class: 'wt-run', role: 'status' }, h('span', { text: 'Läuft: Programme aktualisieren …' }), h('button', { type: 'button', class: 'sm', text: 'Anzeigen', onclick: () => wtShow(c) }))); }
  if (search) { const c = updFollowSearch(search, true); kids.push(h('div', { class: 'wt-run', role: 'status' }, h('span', { text: 'Die Suche nach Updates läuft …' }), h('button', { type: 'button', class: 'sm', text: 'Anzeigen', onclick: () => updShowSearch(c) }))); }
  const punktBtn = pIds ? h('button', { type: 'button', class: 'sm', text: 'Ohne Wiederherstellungspunkt starten …', disabled: dis, title: dis ? tt : null,
    onclick: () => wtPunktFehlt({ cfg: { ...wtCfg(WT_WINGET_ID), ids: pIds } }, { meldung: 'Beim letzten Start entstand kein Wiederherstellungspunkt.' }) }) : null;
  if (d.punktFehlt === true) kids.push(h('div', { class: 'wt-meta' }, h('span', { class: 'chip WARN', text: 'Wiederherstellungspunkt fehlte' }),
    ' Der letzte Start brach ab, weil kein Wiederherstellungspunkt entstand. ', pIds ? punktBtn : 'Wähle beim erneuten Start dieselben Programme; dann kannst du das bewusst übergehen.'));
  const goBtn = h('button', { type: 'button', class: 'sm primary', disabled: true, text: 'Ausgewählte aktualisieren …', onclick: () => { if (sel.size > 30) { toast('Bitte höchstens 30 Programme auf einmal auswählen.'); return; } updInstallDlg(prog.filter(x => sel.has(x.id))); } });
  const boxes = [];
  const all = h('input', { type: 'checkbox', id: 'upd-all', disabled: dis || !prog.length, 'aria-label': 'Alle auswählen', onchange: e => { prog.forEach(x => { if (e.target.checked) sel.add(x.id); else sel.delete(x.id); }); boxes.forEach(b => { b.checked = e.target.checked; }); sync(); } });
  function sync() {
    goBtn.disabled = dis || !sel.size;
    goBtn.title = dis ? tt : null;
    goBtn.textContent = sel.size ? `Ausgewählte aktualisieren … (${sel.size})` : 'Ausgewählte aktualisieren …';
    all.checked = prog.length > 0 && sel.size === prog.length;
  }
  kids.push(h('div', { class: 'toolbar' },
    h('button', { type: 'button', class: 'primary', disabled: dis, title: tt, text: d.stand ? 'Erneut suchen' : 'Nach Updates suchen', onclick: updSuchen }),
    prog.length ? h('label', null, all, ' Alle auswählen') : null, prog.length ? goBtn : null));
  if (liste.length) {
    kids.push(h('div', { class: 'tbl-scroll wt-upd' }, h('table', null,
      h('thead', null, h('tr', null, [h('th', { text: '' }), ...['Name', 'Installiert', 'Verfügbar', 'Kategorie'].map(x => h('th', { text: x }))])),
      h('tbody', null, liste.map(x => {
        const can = x.kategorie === 'Programm';
        const gekuerzt = x.kategorie === 'Id gekürzt', hint = gekuerzt ? 'Die Id ist gekürzt; bitte über winget selbst aktualisieren.' : null;
        const cb = h('input', { type: 'checkbox', checked: can && sel.has(x.id), disabled: !can || dis, title: can ? null : (hint || `Nicht auswählbar: ${x.kategorie || 'unbekannte Kategorie'}`), 'aria-label': `${x.name || x.id} auswählen`,
          onchange: e => { if (e.target.checked) sel.add(x.id); else sel.delete(x.id); sync(); } });
        if (can) boxes.push(cb);
        return h('tr', { class: can ? null : 'dim' }, h('td', null, cb), h('td', null, x.name || x.id, h('div', { class: 'note', text: x.id })), h('td', { text: x.installiert || '' }), h('td', { text: x.verfuegbar || '' }), h('td', null, x.kategorie || '', hint ? h('div', { class: 'note', text: hint }) : null));
      })))));
    kids.push(h('p', { class: 'wt-meta', text: 'Graue Zeilen aktualisiert Morpheus nicht; als Grund steht die Kategorie dahinter.' }));
  } else if (d.stand && !d.fehler) kids.push(h('p', { class: 'ok', text: 'Keine Programm-Updates gefunden.' }));
  sync();
  return kids;
}
function updCard() {
  const body = h('div', null, h('p', { class: 'muted', text: 'Lädt …' }));
  const token = S.rv;
  api('/api/updates').then(d => {
    if (token !== S.rv) return;
    body.replaceChildren(...updBody(d || {}).filter(Boolean));
  }, e => { if (token === S.rv) body.replaceChildren(h('p', { class: 'rem', text: 'Die Update-Liste konnte nicht geladen werden: ' + e.message })); });
  return h('div', { class: 'card', id: 'upd-card' }, h('h2', { text: 'Programme aktualisieren (winget)' }), body);
}

// ---------------------------------------------------------------- Rechte Statusleiste
const sbVisible = () => S.sbOn && window.matchMedia('(min-width:1400px)').matches;
const clampPct = v => Math.max(0, Math.min(100, Number(v) || 0));
const TONE_OF = { OK: 'green', ACK: 'green', INFO: 'yellow', TIPP: 'yellow', WARN: 'orange', CRIT: 'red', SKIP: 'grey' };
const toneOf = f => (f && TONE_OF[f.Status]) || 'grey';
function scCard(title, src, isLive, ...kids) {
  return h('section', { class: 'sc' }, h('div', { class: 'sc-h' }, h('h4', { text: title }), h('span', { class: 'src' + (isLive ? ' live' : ''), text: src })), ...kids);
}
function sparkNode(vals, w = 74, hh = 20) {
  const s = svg('svg', { class: 'sp', viewBox: `0 0 ${w} ${hh}`, 'aria-hidden': 'true' });
  const v = (vals || []).filter(x => x != null && !isNaN(x)).map(Number).slice(-30);
  if (v.length >= 2) s.append(svg('polyline', { points: v.map((x, i) => `${(i * (w - 2) / (v.length - 1) + 1).toFixed(1)},${(hh - 2 - clampPct(x) / 100 * (hh - 4)).toFixed(1)}`).join(' ') }));
  return s;
}
const loadTone = v => v == null ? 'grey' : v >= 90 ? 'red' : v >= 75 ? 'yellow' : 'cyan';
function mrow(label, v, hist, sub) {
  return h('div', { class: 'mrow g-' + loadTone(v) },
    h('span', { class: 'lbl', text: label }), h('div', { class: 'meter' }, h('i', { style: `width:${clampPct(v)}%` })), h('span', { class: 'val', text: v == null ? '–' : dec(v, 0) + ' %' }),
    h('span', { class: 'sub2' }, sub), sparkNode(hist));
}
function fmtRate(kbs) { if (kbs == null || isNaN(kbs)) return '–'; return kbs < 1024 ? `${dec(kbs, 0)} KB/s` : `${dec(kbs / 1024, 1)} MB/s`; }
function fmtLink(m) { if (m == null || isNaN(m)) return '–'; return m >= 1000 ? `${dec(m / 1000, m % 1000 ? 1 : 0)} Gbit/s` : `${dec(m, 0)} Mbit/s`; }

function renderStatusLive() {
  const box = $('#st-live'); if (!box) return;
  const L = S.live;
  if (L.state === 'unsupported') { box.replaceChildren(); return; }
  const d = L.data;
  if (!d || d.stand == null) {
    box.replaceChildren(h('div', { class: 'st-sec', text: 'Live' }),
      scCard('CPU · RAM · GPU', L.state === 'error' ? 'nicht erreichbar' : 'live', L.state !== 'error', h('p', { class: 'wait', text: L.state === 'error' ? 'Messwerte sind gerade nicht erreichbar.' : 'wird gemessen …' })));
    return;
  }
  const src = L.state === 'error' ? 'veraltet' : 'live', isLive = L.state !== 'error', v = d.verlauf || {};
  const cards = [h('div', { class: 'st-sec', text: 'Live' })];
  // 1. CPU · RAM · GPU
  const g = d.gpu, ram = d.ram || {};
  const temp = g && g.temp != null ? h('span', { class: 'chip ' + (g.temp >= 88 ? 'CRIT' : g.temp >= 80 ? 'Y' : ''), title: 'GPU-Temperatur', text: `${dec(g.temp, 0)} °C` }) : null;
  cards.push(scCard('CPU · RAM · GPU', src, isLive,
    mrow('CPU', d.cpu, v.cpu, null),
    mrow('RAM', ram.usedPct, v.ram, ram.usedGB != null && ram.totalGB != null ? `${dec(ram.usedGB, 1)} von ${dec(ram.totalGB, 0)} GB` : null),
    mrow('GPU', g ? g.util : null, v.gpu, g ? [g.name || 'GPU', g.memUsedPct != null ? ` · VRAM ${dec(g.memUsedPct, 0)} %` : '', ' ', temp] : 'keine GPU erkannt')));
  // 2. Laufwerke
  const drives = (d.drives || []).filter(Boolean);
  if (drives.length) {
    cards.push(scCard('Laufwerke', src, isLive, drives.map(x => {
      const free = x.freePct != null ? Number(x.freePct) : (x.sizeGB ? x.freeGB / x.sizeGB * 100 : null);
      const tone = free == null ? 'grey' : free < 10 ? 'red' : free < 20 ? 'yellow' : 'green';
      const letter = spLetter(x.letter);
      return h('div', { class: 'drow g-' + tone, 'data-letter': letter, tabindex: '0', role: 'button', 'aria-haspopup': 'dialog', 'aria-expanded': S.spPop && S.spPop.letter === letter ? 'true' : 'false', title: 'Größte Speicherverbraucher anzeigen',
        onmouseenter: () => spHover(letter), onmouseleave: spLeave, onclick: () => spClick(letter, false),
        onkeydown: e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); spClick(letter, true); } } },
        h('div', { class: 'l1' }, h('i', { class: 'adot' }), h('b', { text: x.letter || '?' }), x.label ? h('span', { class: 'lab', text: x.label }) : null, x.type ? h('span', { class: 'chip type', text: x.type }) : null,
          h('span', { class: 'pct', text: free == null ? '–' : `${dec(100 - free, 0)} % belegt` })),
        h('div', { class: 'meter' }, h('i', { style: `width:${free == null ? 0 : clampPct(100 - free)}%` })),
        h('div', { class: 'l2', text: x.freeGB != null && x.sizeGB != null ? `${dec(x.freeGB, 0)} GB frei von ${dec(x.sizeGB, 0)} GB` : 'Größe unbekannt' }));
    })));
  }
  // 3. Netzwerk
  const n = d.net;
  cards.push(scCard('Netzwerk', src, isLive, n
    ? [h('div', { class: 'kv' }, h('span', { class: 'muted', text: 'Adapter' }), h('b', { text: n.adapter || '–' })), h('div', { class: 'kv' }, h('span', { class: 'muted', text: 'Link' }), h('b', { text: fmtLink(n.linkMbps) })),
      h('div', { class: 'kv' }, h('span', { class: 'muted', text: '↓ Empfang' }), h('b', { text: fmtRate(n.rxKBs) })), h('div', { class: 'kv' }, h('span', { class: 'muted', text: '↑ Senden' }), h('b', { text: fmtRate(n.txKBs) }))]
    : h('p', { class: 'wait', text: 'Keine aktive Verbindung.' })));
  // 4. Top-Prozesse
  const top = (d.top || []).filter(Boolean).slice(0, 3);
  cards.push(scCard('Top-Prozesse', src, isLive, top.length
    ? top.map(p => h('div', { class: 'pr' }, h('span', { class: 'nm', title: p.name, text: p.name }), h('b', { text: p.cpu == null ? '–' : dec(p.cpu, 1) + ' %' })))
    : h('p', { class: 'wait', text: 'Keine Daten.' })));
  box.replaceChildren(...cards);
  if (S.spPop) { syncSpRows(); placeSpPop(); }   // das offene Speicher-Fenster liegt außerhalb dieser Karten und bleibt stehen
}

const PROT = [
  ['Defender', f => /^(Microsoft )?Defender: Status$/.test(f.Check)],
  ['Firewall', f => /^Firewall/.test(f.Check) && /Profile|Status/.test(f.Check)],
  ['Windows Update', f => f.Check === 'Windows Update: ausstehend'],
  ['Secure Boot', f => f.Check === 'Secure Boot'],
  ['TPM', f => f.Check === 'TPM'],
  ['BitLocker', f => f.Check === 'BitLocker'],
  ['Kernisolierung', f => /^Kernisolierung/.test(f.Check)],
];
const RISKY_PORTS = new Set([3389, 445, 139, 5985, 5986, 22, 23]);
const SYS_PROCS = new Set(['system', 'svchost', 'lsass', 'wininit', 'services', 'spoolsv', 'smss', 'csrss', 'winlogon', 'lsm', 'dns', 'wuauserv', 'dwm', 'fontdrvhost', 'idle']);
const dataTable = name => { const D = (S.report && S.report.Data) || {}, k = Object.keys(D).find(x => norm(x) === name); return k ? (D[k] || []) : null; };
const findBy = pred => S.findings.find(pred);
function portCard(src) {
  const rows = dataTable('Offene Netzwerkports (nicht nur lokal)');
  if (!rows) return scCard('Offene Ports', src, false, h('p', { class: 'wait', text: 'Keine Portdaten im Bericht.' }));
  const seen = new Map();
  rows.filter(Boolean).forEach(r => {
    const port = Number(r.Port), key = `${r.Protokoll}/${port}`;
    if (isNaN(port) || seen.has(key)) return;
    const proc = String(r.Prozess || '').replace(/\.exe$/i, '');
    seen.set(key, { port, proto: r.Protokoll, proc, tone: RISKY_PORTS.has(port) ? 'red' : (!proc || SYS_PROCS.has(proc.toLowerCase()) ? 'green' : 'yellow') });
  });
  const list = [...seen.values()], ord = { red: 0, yellow: 1, green: 2 };
  list.sort((a, b) => ord[a.tone] - ord[b.tone] || a.port - b.port);
  const cnt = t => list.filter(x => x.tone === t).length;
  return scCard('Offene Ports', src, false,
    h('div', { class: 'kv' }, h('span', { class: 'muted', text: 'von außen erreichbar' }), h('b', { text: String(list.length) })),
    list.length ? [h('div', { class: 'kv' }, h('span', { class: 'muted', text: 'riskant · fremd · System' }), h('b', { text: `${cnt('red')} · ${cnt('yellow')} · ${cnt('green')}` })),
      list.slice(0, 5).map(p => h('div', { class: 'port g-' + p.tone }, h('i', { class: 'adot' }), h('code', { text: String(p.port) }), h('span', { class: 'nm', title: `${p.proto} · ${p.proc || 'System'}`, text: `${p.proc || 'System'} · ${p.proto}` }))),
      list.length > 5 ? h('div', { class: 'note', text: `… und ${list.length - 5} weitere` }) : null] : h('p', { class: 'wait', text: 'Keine offenen Ports gefunden.' }));
}
function stabilityCard(src) {
  const tile = (label, tone, valNode, f) => h(f ? 'button' : 'div', { type: f ? 'button' : null, class: 'tile g-' + tone, onclick: f ? () => reveal(f.Check) : null, title: f ? 'Zum Befund' : null },
    h('div', { class: 'tl2' }, h('i', { class: 'adot' }), label), h('b', null, valNode));
  const fRel = findBy(f => f.Check === 'Zuverlässigkeitsindex'), fCrash = findBy(f => f.Check === 'Abstürze und unerwartete Neustarts');
  const fApp = findBy(f => f.Check === 'Programmabstürze'), fBoot = findBy(f => f.Check === 'Startdauer');
  const rel = fRel && /([\d.,]+)\s*von\s*(\d+)/.exec(fRel.Value || ''), relN = rel ? Number(rel[1].replace(',', '.')) : null;
  const bs = fCrash && (/(\d+)\s*Bluescreens?/i.exec(fCrash.Value || '') ? Number(/(\d+)\s*Bluescreens?/i.exec(fCrash.Value)[1]) : (/^Keine/i.test(fCrash.Value || '') ? 0 : null));
  const am = fApp && (/^(\d+)/.exec(fApp.Value || '') ? Number(/^(\d+)/.exec(fApp.Value)[1]) : (/^Keine/i.test(fApp.Value || '') ? 0 : null));
  const bootRows = (dataTable('Startdauer (letzte Messungen)') || []).filter(Boolean).map(x => Number(x.HauptpfadSek)).filter(x => !isNaN(x));
  const boot = bootRows.length ? bootRows.reduce((a, b) => a + b, 0) / bootRows.length : null;
  const dash = h('span', { class: 'muted', text: '–' });
  return scCard('Stabilität', src, false, h('div', { class: 'tiles' },
    tile('Zuverlässigkeit', relN == null ? 'grey' : relN >= 8 ? 'green' : relN >= 6 ? 'yellow' : 'orange', relN == null ? dash : [dec(relN, relN % 1 ? 1 : 0), h('small', { text: ` / ${rel[2]}` })], fRel),
    tile('Bluescreens', bs == null ? 'grey' : bs === 0 ? 'green' : 'red', bs == null ? dash : String(bs), fCrash),
    tile('App-Abstürze', am == null ? 'grey' : am === 0 ? 'green' : am <= 5 ? 'yellow' : 'orange', am == null ? dash : String(am), fApp),
    tile('Startdauer', boot == null ? 'grey' : boot <= 30 ? 'green' : boot <= 60 ? 'yellow' : 'orange', boot == null ? dash : [dec(boot, 0), h('small', { text: ' s' })], fBoot)));
}
function safetyCard() {
  const s = safety(), sess = !!S.session;
  const pt = S.points && S.points[0] ? S.points[0].zeit : s.letzterPunkt;
  const undoable = S.journal ? S.journal.filter(e => e.status === 'erledigt' && e.art !== 'rueckgaengig').length : null;
  const row = (tone, label, val) => h('div', { class: 'pr g-' + tone }, h('i', { class: 'adot' }), h('span', { class: 'nm', text: label }), h('b', { text: val }));
  return scCard('Absicherung', 'Sitzung', false,
    row(!sess || s.schutzAn == null ? 'grey' : s.schutzAn ? 'green' : 'red', 'Computerschutz', !sess || s.schutzAn == null ? '–' : s.schutzAn ? `an${s.laufwerk ? ' (' + s.laufwerk + ')' : ''}` : 'aus'),
    row(s.sperre24h == null ? 'grey' : s.sperre24h ? 'yellow' : 'green', '24-h-Sperre', s.sperre24h == null ? '–' : s.sperre24h ? 'aktiv' : 'aus'),
    row(pt ? 'green' : 'grey', 'Letzter Punkt', pt ? fmtAgo(pt) : '–'),
    row(undoable == null ? 'grey' : 'cyan', 'Rücknehmbar', undoable == null ? '–' : plural(undoable, 'Änderung', 'Änderungen')),
    h('a', { class: 'more-link', href: '#/aenderungen', text: 'Zu den Änderungen →' }));
}
function renderStatusReport() {
  const box = $('#st-report'); if (!box) return;
  const nodes = [];
  if (S.report) {
    const src = 'Bericht vom ' + fmtDate(S.report.Meta.Erstellt);
    nodes.push(h('div', { class: 'st-sec', text: 'Aus dem Bericht' }));
    // 5. Schutz-Ampeln
    nodes.push(scCard('Schutz-Ampeln', src, false, PROT.map(([name, pred]) => {
      const f = findBy(pred), tone = toneOf(f);
      return h('button', { type: 'button', class: 'srow g-' + tone, disabled: !f, title: f ? `${f.Check}: ${f.Value || ''}` : 'Nicht im Bericht', onclick: f ? () => reveal(f.Check) : null },
        h('i', { class: 'adot' }), name, h('span', { class: 'sv', text: f ? (STATUS_NAME[f.Status] || f.Status) : 'fehlt' }));
    })));
    nodes.push(portCard(src), stabilityCard(src));
  }
  nodes.push(h('div', { class: 'st-sec', text: 'Absicherung' }), safetyCard());
  box.replaceChildren(...nodes);
}

// Abfrage von /api/live alle 5 s; Pause bei verstecktem Tab oder ausgeblendeter Leiste
let liveTimer = null, liveBusy = false;
function liveStop() { if (liveTimer) { clearTimeout(liveTimer); liveTimer = null; } }
async function livePoll() {
  liveTimer = null;
  if (!sbVisible() || S.live.state === 'unsupported' || document.hidden || liveBusy) return;
  liveBusy = true;
  let again = true;
  try {
    const d = await api('/api/live');
    S.live = { state: 'ok', data: d || {} };
  } catch (e) {
    if (e.status === 404 || e.status === 501) { S.live = { state: 'unsupported', data: null }; again = false; }
    else if (e.status === 401) again = false;
    else S.live = { state: 'error', data: S.live.data };
  } finally { liveBusy = false; }
  renderStatusLive();
  if (again) liveTimer = setTimeout(livePoll, LIVE_MS);
}
function liveEnsure() { if (sbVisible() && S.live.state !== 'unsupported' && !document.hidden && !liveTimer && !liveBusy) livePoll(); }
function applySb() {
  $('#app').classList.toggle('st-off', !S.sbOn);
  $('#st-toggle').setAttribute('aria-pressed', S.sbOn ? 'true' : 'false');
  renderStatusLive(); renderStatusReport();
  if (sbVisible()) liveEnsure(); else { liveStop(); closeSpPop(false); }
}
function initStatusbar() {
  try { S.sbOn = localStorage.getItem(SB_KEY) !== '0'; } catch { S.sbOn = true; }
  $('#st-toggle').addEventListener('click', () => {
    S.sbOn = !S.sbOn;
    try { localStorage.setItem(SB_KEY, S.sbOn ? '1' : '0'); } catch { /* ohne Speicher weiter */ }
    applySb();
  });
  window.matchMedia('(min-width:1400px)').addEventListener('change', () => { if (sbVisible()) liveEnsure(); else { liveStop(); closeSpPop(false); } });
  document.addEventListener('visibilitychange', () => { if (document.hidden) liveStop(); else liveEnsure(); });
  applySb();
}
async function loadExtra() {
  const [j, p] = await Promise.all([api('/api/journal').catch(() => null), api('/api/restorepoints').catch(() => null)]);
  if (j) S.journal = j;
  if (p) S.points = p;
  renderStatusReport();
}

// ---------------------------------------------------------------- Speicher-Fenster an der Laufwerkskarte
// Datenquelle: das jüngere von Bericht (Speicher) und GET /api/speicher. Hover, Klick und Neuzeichnen laden und rechnen nichts.
async function loadSpeicher() {
  try { S.spApi = await api('/api/speicher'); } catch { S.spApi = null; }
  pickSpeicher();
}
function pickSpeicher() {
  const rep = S.report && S.report.Speicher && S.report.Speicher.stand ? S.report.Speicher : null;
  const apiD = S.spApi && S.spApi.stand ? S.spApi : null;
  const t = x => { const n = new Date(x.stand).getTime(); return isNaN(n) ? 0 : n; };
  if (rep && (!apiD || t(rep) >= t(apiD))) { S.speicher = rep; S.spSrc = 'aus dem Bericht'; }
  else if (apiD) { S.speicher = apiD; S.spSrc = 'neu berechnet'; }
  else { S.speicher = null; S.spSrc = ''; }
  if (S.spPop) renderSpPop();
}
function fmtBytes(b) {
  b = Number(b); if (b == null || isNaN(b)) return '–';
  const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0;
  while (b >= 1024 && i < 4) { b /= 1024; i++; }
  return `${dec(b, i >= 4 ? 2 : (i === 3 ? 1 : 0))} ${u[i]}`;
}
const spLetter = l => String(l || '').replace(/[:\\\/]+$/, '').toUpperCase() + ':';
const spRow = letter => [...document.querySelectorAll('.drow')].find(r => r.dataset.letter === letter) || null;
const spTimer = { open: null, close: null };
function spClear() { clearTimeout(spTimer.open); clearTimeout(spTimer.close); spTimer.open = spTimer.close = null; }
function spEl() {
  let p = $('#sp-pop');
  if (!p) {
    p = h('div', { id: 'sp-pop', class: 'sp-pop hide', role: 'dialog', tabindex: '-1' });
    p.addEventListener('mouseenter', () => clearTimeout(spTimer.close));
    p.addEventListener('mouseleave', () => spLeave());
    p.addEventListener('keydown', e => {
      if (e.key !== 'Tab') return;
      const f = [...p.querySelectorAll('button:not(:disabled)')];
      if (!f.length) return;
      if (e.shiftKey && document.activeElement === f[0]) { e.preventDefault(); f[f.length - 1].focus(); }
      else if (!e.shiftKey && document.activeElement === f[f.length - 1]) { e.preventDefault(); f[0].focus(); }
    });
    document.body.append(p);
  }
  return p;
}
function syncSpRows() {
  document.querySelectorAll('.drow').forEach(r => r.setAttribute('aria-expanded', S.spPop && S.spPop.letter === r.dataset.letter ? 'true' : 'false'));
}
function placeSpPop() {
  const pop = $('#sp-pop'), P = S.spPop; if (!pop || !P) return;
  const st = $('#status').getBoundingClientRect(), row = spRow(P.letter), vh = window.innerHeight;
  const w = Math.max(260, Math.min(500, st.left - 24));
  pop.style.width = w + 'px'; pop.style.maxHeight = (vh - 24) + 'px';
  pop.style.left = Math.max(8, st.left - 8 - w) + 'px';
  const top = row ? row.getBoundingClientRect().top - 8 : 12;
  pop.style.top = Math.max(12, Math.min(top, vh - pop.offsetHeight - 12)) + 'px';
}
function openSpPop(letter, pinned, focusIn) {
  spClear();
  if (!sbVisible()) return;
  const same = S.spPop && S.spPop.letter === letter;
  S.spPop = { letter, pinned: !!pinned || !!(same && S.spPop.pinned) };
  renderSpPop(); syncSpRows();
  if (focusIn) { const c = $('#sp-pop [data-f="close"]'); if (c) c.focus(); }
}
function closeSpPop(restore) {
  spClear();
  const P = S.spPop; S.spPop = null;
  const pop = $('#sp-pop'); if (pop) { pop.classList.add('hide'); pop.replaceChildren(); }
  syncSpRows();
  if (restore && P) { const r = spRow(P.letter); if (r) r.focus(); }
}
function spHover(letter) {
  clearTimeout(spTimer.close);
  if (S.spPop && (S.spPop.pinned ? S.spPop.letter !== letter : false)) return;
  if (S.spPop && S.spPop.letter === letter) return;
  clearTimeout(spTimer.open);
  spTimer.open = setTimeout(() => openSpPop(letter, false), 300);
}
function spLeave() {
  clearTimeout(spTimer.open);
  if (!S.spPop || S.spPop.pinned) return;
  clearTimeout(spTimer.close);
  spTimer.close = setTimeout(() => { if (S.spPop && !S.spPop.pinned) closeSpPop(false); }, 250);
}
function spClick(letter, viaKey) {
  spClear();
  if (S.spPop && S.spPop.pinned && S.spPop.letter === letter) { closeSpPop(viaKey); return; }
  openSpPop(letter, true, viaKey);
}
document.addEventListener('mousedown', e => {
  if (!S.spPop) return;
  if (e.target.closest && (e.target.closest('#sp-pop') || e.target.closest('.drow'))) return;
  closeSpPop(false);
});
document.addEventListener('keydown', e => {
  if (e.key !== 'Escape' || !S.spPop || $('#modal').classList.contains('on')) return;
  e.preventDefault(); closeSpPop(true);
});
window.addEventListener('resize', () => { if (S.spPop) { if (sbVisible()) placeSpPop(); else closeSpPop(false); } });

async function copyPath(p) {
  try { await navigator.clipboard.writeText(p); toast('Pfad kopiert'); } catch { toast('Kopieren nicht möglich'); }
}
function spItem(label, path, bytes, max, extra, sub) {
  const pct = max > 0 ? Math.max(1, Math.round(Number(bytes) / max * 100)) : 0;
  return h('button', { type: 'button', class: 'sp-item', title: `${path}\nKlick kopiert den Pfad.`, onclick: () => copyPath(path) },
    h('span', { class: 'sp-top' }, h('span', { class: 'sp-name', text: label }), extra, h('span', { class: 'sp-size', text: fmtBytes(bytes) })),
    h('span', { class: 'sp-bar' }, h('i', { style: `width:${Math.min(100, pct)}%` })),
    sub ? h('span', { class: 'sp-sub' }, sub) : null);
}
function spSection(title, list, empty, build) {
  const max = list.reduce((m, x) => Math.max(m, Number(x.bytes) || 0), 0);
  return h('div', { class: 'sp-sec' }, h('h4', { text: title }), list.length ? list.map(x => build(x, max)) : h('p', { class: 'note', text: empty }));
}
function renderSpPop() {
  const P = S.spPop, pop = spEl();
  if (!P) { pop.classList.add('hide'); pop.replaceChildren(); return; }
  const had = pop.contains(document.activeElement) && document.activeElement !== pop ? document.activeElement.dataset.f : null;
  const sp = S.speicher, lw = sp && (sp.laufwerke || []).find(x => spLetter(x.laufwerk) === P.letter);
  const drive = ((S.live.data && S.live.data.drives) || []).find(x => spLetter(x.letter) === P.letter);
  const bez = (lw && lw.bezeichnung) || (drive && drive.label) || '';
  const kids = [h('div', { class: 'sp-head' }, h('b', { text: `${P.letter}${bez ? ' ' + bez : ''} – Größte Speicherverbraucher` }),
    h('button', { type: 'button', class: 'sm ghost', 'data-f': 'close', 'aria-label': 'Schließen', title: 'Schließen (Esc)', text: '✕', onclick: () => closeSpPop(true) }))];
  const refresh = h('button', { type: 'button', class: 'sm', 'data-f': 'refresh', disabled: readOnly() || !!S.spJob, title: readOnly() ? lockTitle() : null, text: S.spJob ? 'Wird berechnet …' : (lw ? 'Neu berechnen' : 'Jetzt berechnen'), onclick: spRefresh });
  const prog = h('div', { class: 'note', id: 'sp-prog', 'aria-live': 'polite', text: S.spJob ? S.spJob.line : '' });
  if (!sp || !sp.stand || !lw) {
    kids.push(h('p', { text: `Für ${P.letter} gibt es noch keine Auswertung.` }), h('div', { class: 'sp-foot' }, refresh), prog);
  } else {
    kids.push(h('div', { class: 'note', text: `Stand: ${fmtDate(sp.stand)} · ${S.spSrc}${lw.uebersprungen ? ` · ${lw.uebersprungen} Ordner ohne Zugriff übersprungen` : ''}` }));
    if (lw.fehler) kids.push(h('p', { class: 'rem', text: String(lw.fehler) }));
    const folders = (lw.ordner || []).slice(0, 10), files = (lw.dateien || []).slice(0, 10);
    const games = (sp.spiele || []).filter(g => spLetter(g.laufwerk) === P.letter).sort((a, b) => (Number(b.bytes) || 0) - (Number(a.bytes) || 0)).slice(0, 10);
    kids.push(
      spSection('Ordner', folders, 'Keine Ordner ausgewertet.', (x, max) => spItem(x.pfad, x.pfad, x.bytes, max)),
      spSection('Dateien', files, 'Keine großen Dateien gefunden.', (x, max) => spItem(x.pfad, x.pfad, x.bytes, max, x.windows ? h('span', { class: 'chip type', text: 'Windows' }) : null)),
      files.some(x => x.windows) ? h('p', { class: 'note', text: 'pagefile.sys (Auslagerungsdatei), hiberfil.sys (Ruhezustand/Schnellstart) und swapfile.sys gehören zu Windows. Nicht löschen. Verkleinern: Auslagerungsdatei unter Systemsteuerung > System > Erweiterte Systemeinstellungen > Leistung > Virtueller Arbeitsspeicher; hiberfil.sys mit „powercfg /hibernate off“ (schaltet auch Schnellstart ab) oder „powercfg /h /type reduced“.' }) : null,
      spSection(`Spiele auf ${P.letter}`, games, `Keine Spiele auf ${P.letter} gefunden.`, (x, max) => spItem(x.name || x.pfad, x.pfad, x.bytes, max, x.plattform ? h('span', { class: 'chip type', text: x.plattform }) : null,
        [`zuletzt gespielt: ${x.zuletztGespielt ? fmtShort(x.zuletztGespielt) : '–'}`, x.groesseUnsicher ? ' · Größe eingeschränkt lesbar' : ''])));
    const hasGames = (dataTable('Installierte Spiele') || []).length > 0;
    kids.push(h('div', { class: 'sp-foot' }, refresh, hasGames ? h('button', { type: 'button', class: 'link', 'data-f': 'games', text: 'Alle Spiele', onclick: () => { closeSpPop(false); openRaw(['Installierte Spiele']); } }) : null,
      h('button', { type: 'button', class: 'link', 'data-f': 'spordner', text: 'Spiele-Ordner festlegen …', onclick: gotoSpOrdner })), prog,
      h('p', { class: 'note', text: 'Deinstallieren nur über die jeweilige Plattform (Steam, Epic …). Morpheus löscht nichts.' }));
  }
  pop.setAttribute('aria-label', `Speicherverbraucher ${P.letter}`);
  pop.replaceChildren(...kids.filter(k => k != null && k !== false));
  pop.classList.remove('hide');
  placeSpPop();
  if (had) { const b = pop.querySelector(`[data-f="${had}"]:not(:disabled)`); (b || pop).focus({ preventScroll: true }); }
}
// Gemeinsamer Speicher-Job (Speicher-Fenster und Karte „Spiele-Ordner“); onLine bekommt jede neue letzte Fortschrittszeile
async function startSpeicherRefresh(onLine) {
  const r = await api('/api/speicher/refresh', { method: 'POST' });
  const job = await followJob(r.jobId, lines => { const l = lines[lines.length - 1]; if (l && onLine) onLine(l); });
  if (job.status === 'failed') throw new Error((job.ergebnis && job.ergebnis.error) || 'Die Berechnung ist fehlgeschlagen.');
  await loadSpeicher();
}
async function spRefresh() {
  if (S.spJob || S.spoJob || readOnly()) return;
  S.spJob = { line: 'Wird gestartet …' }; renderSpPop();
  try {
    await startSpeicherRefresh(l => { if (S.spJob) { S.spJob.line = l; const p = $('#sp-prog'); if (p) p.textContent = l; } });
    toast('Speicherverbraucher neu berechnet');
  } catch (e) { toast(e.message); }
  S.spJob = null; renderSpPop();
}

// ---------------------------------------------------------------- Routing
function reveal(check) {
  const f = findingByCheck(check); if (!f) return;
  S.ui.reveal = check;
  const v = viewOf(f);
  S.ui.f[v] = { mode: 'all', term: '' };
  if (location.hash === '#/' + v) refreshView(); else location.hash = '#/' + v;
}
function doReveal() {
  const c = S.ui.reveal; if (!c) return;
  const el = [...document.querySelectorAll('.finding')].find(x => x.dataset.check === c);
  if (!el) return;
  S.ui.reveal = null;
  el.scrollIntoView({ block: 'center' });
  el.classList.remove('flash'); void el.offsetWidth; el.classList.add('flash');
}
function renderView(keepScroll) {
  S.rv++;
  const y = window.scrollY;
  const view = V[S.view] || V.uebersicht;
  let node;
  try { node = view(); } catch (e) { console.error(e); node = banner('err', 'warn', h('b', { text: 'Anzeigefehler: ' }), e.message); }
  dOrdBannerEinsetzen(node);
  if (!keepScroll) node.classList.add('view-in');
  // Beim Neuzeichnen laden Karten (z. B. Werkzeuge) ihren Inhalt nachträglich; bis dahin ist die Seite kürzer und
  // scrollTo würde nach oben gekappt. Die alte Höhe bleibt deshalb kurz als Mindesthöhe stehen (2.5.0, Test C).
  const vw = $('#view');
  clearTimeout(S.ui.minHT);
  vw.style.minHeight = keepScroll ? vw.offsetHeight + 'px' : '';
  if (keepScroll) S.ui.minHT = setTimeout(() => { vw.style.minHeight = ''; }, 3000);
  vw.replaceChildren(node);
  renderNav();
  if (keepScroll) window.scrollTo(0, y); else if (!S.ui.reveal) window.scrollTo(0, 0);
  if (S.ui.reveal) doReveal();
  if (S.ui.navZiel && !keepScroll) navZielZeigen();
}
function refreshView() { renderView(true); }
function route() {
  const m = location.hash.match(/^#\/(\w+)/);
  const v = m && V[m[1]] ? m[1] : 'uebersicht';
  // Ein Unterpunkt bleibt nur markiert, wenn der Wechsel von ihm kam
  if (S.ui.navSubNeu) S.ui.navSubNeu = false; else { S.ui.navSub = null; S.ui.navZiel = null; }
  S.view = v;
  closeTips();
  renderView(false);
}

// ---------------------------------------------------------------- Sprechblasen (ⓘ)
function closeTips(except) {
  document.querySelectorAll('.tip.open').forEach(t => { if (t !== except) { t.classList.remove('open'); if (t.previousElementSibling) t.previousElementSibling.setAttribute('aria-expanded', 'false'); } });
}
document.addEventListener('click', e => {
  const btn = e.target.closest ? e.target.closest('button.info') : null;
  if (e.target.closest && e.target.closest('.tip')) return;
  if (!btn) { closeTips(null); return; }
  const tip = btn.nextElementSibling, open = !tip.classList.contains('open');
  closeTips(tip); tip.classList.toggle('open', open); btn.setAttribute('aria-expanded', open ? 'true' : 'false');
});
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeTips(null); });

// ---------------------------------------------------------------- Start
async function init() {
  try { await initToken(); } catch (e) { fatal(e.message); return; }
  if (!S.token) { fatal('Kein Zugriffstoken. Bitte die GUI über pc-check-gui starten.'); return; }
  try {
    await loadAll();
  } catch (e) {
    if (e.status !== 401) fatal('Die GUI konnte nicht geladen werden: ' + e.message);
    return;
  }
  startHeartbeat();
  initTopbar(); initStatusbar(); initNav();
  window.addEventListener('hashchange', route);
  route();
  loadExtra();
  refreshActionStates();   // Zustände aller Aktionen beim Start lesen (dauert einige Sekunden)
}
init();
})();
