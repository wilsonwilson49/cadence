// Cadence web app: renders every screen as HTML strings and handles events by delegation.
import * as M from './model.js';
import { store } from './store.js';
import { Reminders, chime } from './reminders.js';
import { ai, checkReflection, testKey, DEFAULT_MODEL } from './aicheck.js';

// ---------- tiny helpers ----------
const $ = sel => document.querySelector(sel);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const ic = (name, cls = '') => `<svg class="i ${cls}" aria-hidden="true"><use href="#${name}"/></svg>`;
const color = c => M.COLORS[c] || c || '#0a84ff';
const tint = (hex, a) => `color-mix(in srgb, ${hex} ${Math.round(a * 100)}%, transparent)`;
const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
const HOUR = 48;

const SCREENS = [
  ['home', 'Home', 'house', ''],
  ['today', 'Today', 'sun', 'Plan'], ['week', 'Week', 'week', 'Plan'], ['month', 'Month', 'month', 'Plan'],
  ['todo', 'To-Do List', 'list', 'Plan'], ['projects', 'Projects', 'layers', 'Plan'],
  ['study', 'Study', 'study', 'Study'], ['flashcards', 'Flashcards', 'cards', 'Study'], ['habits', 'Habits', 'habit', 'Grow'], ['reflections', 'Reflections', 'quote', 'Grow'],
  ['focus', 'Focus', 'target', 'Focus'], ['screentime', 'Screen Time', 'monitor', 'Focus'],
  ['notes', 'Notes', 'note', 'Tools'], ['reminders', 'Reminders', 'bell', 'Tools'],
  ['booking', 'Booking', 'people', 'Connect'], ['settings', 'Settings', 'gear', ''],
];

const ui = {
  route: 'home',
  weekStart: M.startOfWeek(new Date()),
  month: M.startOfMonth(new Date()),
  selectedDay: M.startOfDay(new Date()),
  todo: { mode: 'checklist', range: 7, showCompleted: true, search: '' },
  reflSearch: '',
  booking: { busy: [], loading: false, message: null, loadedFor: null, week: [] },
  modal: null,
  auth: { mode: 'login', error: null, busy: false },
  flash: null,
  weekScrolled: false,
  justDone: new Set(),     // occurrence ids that were just checked off (pop animation)
  lastRoute: null,
  modalFresh: false,
};

const ringPrev = new Map(); // ring key -> last drawn fraction, so rings animate between values

const reminders = new Reminders({
  banner: content => showBanner(content),
  // Pushy and strict reminders: a dialog (strict covers the page). Never on top of an editor you're typing in.
  nag: (occ, level, count, putOff) => { if (ui.modal) closeModal(); openModal({ type: 'nag', occ, level, count, putOff }); },
  nagShowing: () => ui.modal?.type === 'nag',
  canInterrupt: () => !ui.modal || ['checkin', 'detail'].includes(ui.modal.type),
  // Checked off somewhere else (another tab, the Mac): the dialog goes away.
  nagRefresh: items => { if (ui.modal?.type === 'nag' && !items.some(o => o.id === ui.modal.occ.id)) closeModal(); },
  checkIn: title => openModal({ type: 'checkin', title, reflecting: null }),
  openChecklist: occ => {
    if (occ && !occ.resolved) beginReflection(occ);
    else navigate('today');
  },
});

// ---------- routing ----------
// Clean URLs: /app/<screen>. Old #screen links are upgraded in place.
function readRoute() {
  const legacy = location.hash.replace(/^#/, '').split('?')[0];
  if (legacy && SCREENS.some(s => s[0] === legacy)) history.replaceState(null, '', `/app/${legacy}`);
  const route = (location.pathname.match(/^\/app\/?([^/]*)/) || [])[1] || 'home';
  ui.route = SCREENS.some(s => s[0] === route) ? route : 'home';
  const projectId = ui.route === 'projects' ? (location.pathname.match(/^\/app\/projects\/([^/]+)/) || [])[1] || null : null;
  if (projectId !== ui.projectId) { proj.picked = new Set(); proj.anchor = null; }
  ui.projectId = projectId;
  const params = new URLSearchParams(location.search);
  const google = params.get('google');
  if (google) {
    ui.flash = google === 'connected' ? 'Google Calendar connected.' : `Google: ${google}`;
    history.replaceState(null, '', '/app/settings');
    store.refreshGoogle();
  }
  if (params.get('mode') === 'register') { ui.auth.mode = 'register'; history.replaceState(null, '', location.pathname); }
}

function navigate(route) {
  const path = route === 'home' ? '/app' : `/app/${route}`;
  if (location.pathname !== path) history.pushState(null, '', path);
  readRoute();
  render();
}
addEventListener('popstate', () => { readRoute(); render(); });

// ---------- rendering ----------
let booted = false;

// Never swap the DOM between mouse-down and mouse-up: the browser would drop the click.
// Updates that arrive mid-click (e.g. a sync kicked off by the window regaining focus) wait until it's done.
let pointerDown = false, renderPending = false;
addEventListener('pointerdown', () => { pointerDown = true; }, true);
const releasePointer = () => {
  pointerDown = false;
  if (renderPending) { renderPending = false; setTimeout(render, 0); }
};
addEventListener('pointerup', releasePointer, true);
addEventListener('pointercancel', releasePointer, true);

function render() {
  const app = $('#app');
  if (!booted) return;
  if (pointerDown) { renderPending = true; return; }
  if (!store.user) { app.innerHTML = authView(); return; }

  const active = document.activeElement;
  const focusId = active?.id;
  const sel = focusId && 'selectionStart' in active ? [active.selectionStart, active.selectionEnd] : null;
  const scroll = $('#main')?.scrollTop ?? 0;
  const weekScroll = $('#weekScroll')?.scrollTop;

  const routeChanged = ui.lastRoute !== ui.route;
  ui.lastRoute = ui.route;
  app.innerHTML = `<div class="shell">${sidebar()}<main id="main" class="${routeChanged ? 'enter' : ''}">${view()}</main></div>`;
  updateSyncUI();
  animateRings();

  if (ui.route !== 'week') $('#main').scrollTop = scroll;
  const ws = $('#weekScroll');
  if (ws) ws.scrollTop = weekScroll ?? (ui.weekScrolled ? ws.scrollTop : 7 * HOUR);
  ui.weekScrolled = Boolean(ws);
  // The habit tracker opens on the newest days (today is the right-most column).
  for (const el of document.querySelectorAll('.ht-wrap')) el.scrollLeft = el.scrollWidth;
  if (focusId) {
    const el = document.getElementById(focusId);
    if (el) { el.focus(); if (sel) try { el.setSelectionRange(...sel); } catch { /* not a text input */ } }
  }
  if (ui.modal && ['checkin', 'detail'].includes(ui.modal.type) && !ui.modal.reflecting) renderModal();
}

// Sidebar sections fold (click the heading) and can be hidden (Settings › Sidebar). Both stay on this device.
const NAV_SECTIONS = [...new Set(SCREENS.map(s => s[3]).filter(Boolean))];
function sidebar() {
  let lastSection = null;
  const folded = new Set(store.device('navFolded', [])), hidden = new Set(store.device('navHidden', []));
  const items = SCREENS.map(([id, label, icon, section]) => {
    if (section && hidden.has(section) && ui.route !== id) return '';
    let head = '';
    if (section !== lastSection) {
      head = section ? `<button class="nav-section fold ${folded.has(section) ? 'folded' : ''}" data-act="nav-fold" data-sec="${section}" title="Fold or unfold · hide sections in Settings">${section}<span class="chev">${folded.has(section) ? '▸' : '▾'}</span></button>`
        : id === 'home' ? '' : '<div class="nav-section"></div>';
      lastSection = section;
    }
    if (section && folded.has(section) && ui.route !== id) return head;
    const badge = id === 'today' ? store.remainingToday() : id === 'reflections' ? store.reflections.size
      : id === 'habits' ? (store.countedToday(store.tasksOn(new Date())).filter(o => M.isHabit(o.task) && !M.isUntilDone(o.task) && !o.resolved).length || '')
      : id === 'focus' && focus.running ? (focus.pausedAt ? 'Paused' : fmtClock(focusLeft())) : id === 'study' && studyRun ? M.fmtStudyClock(studyClockMs(studyRun))
      : id === 'flashcards' ? (store.dueCardCount || '') : id === 'projects' ? (store.projectToday().filter(d => d.item && !M.itemDone(d.item)).length || '') : '';
    return `${head}<a class="nav-item ${ui.route === id ? 'on' : ''}" href="${id === 'home' ? '/app' : `/app/${id}`}" title="${label} (${SHORTCUT_FOR[id]})">${ic(icon)}<span class="lbl">${label}</span>${badge ? `<span class="badge">${badge}</span>` : ''}</a>`;
  }).join('');
  return `<nav class="sidebar">
    <div class="brand"><img src="/icon-192.png" alt=""><span>Cadence</span></div>
    ${items}
    <div class="spacer"></div>
    <div class="new-btns"><button class="btn primary" data-act="new-task" title="New task (N)">${ic('plus')} New Task</button>
      <button class="btn" data-act="new-event" title="New event (E)">${ic('cal')} New Event</button></div>
    <div class="account">
      <div class="row"><b class="grow ellipsis">${esc(store.user.username)}</b>
        <button class="btn ghost sm icon" data-act="sign-out" title="Sign out">${ic('logout')}</button></div>
      ${syncControl()}
    </div>
  </nav>`;
}

function view() {
  switch (ui.route) {
    case 'week': return weekView();
    case 'month': return monthView();
    case 'todo': return todoView();
    case 'projects': return projectsView();
    case 'study': return studyView();
    case 'flashcards': return flashcardsView();
    case 'notes': return notesView();
    case 'reminders': return customRemindersView();
    case 'reflections': return reflectionsView();
    case 'habits': return habitsView();
    case 'focus': return focusView();
    case 'screentime': return screenTimeView();
    case 'booking': return bookingView();
    case 'settings': return settingsView();
    case 'today': return todayView();
    default: return homeView();
  }
}

// ---------- shared bits ----------
/** Today's progress ring, following the "ring shows" setting (what's left, or what's done). */
const todayRing = (done, total, size, width, key) => ring(done, total, size, width, key, { left: store.settings.ringShowsLeft ?? true });

function ring(done, total, size = 72, width = 8, key = `ring${size}`, { left = false } = {}) {
  const r = (size - width) / 2, c = 2 * Math.PI * r;
  const remaining = Math.max(0, total - done);
  const f = left ? (total ? remaining / total : 0) : total ? done / total : 1;
  const from = ringPrev.has(key) ? ringPrev.get(key) : f;
  ringPrev.set(key, f);
  return `<div class="ring" style="width:${size}px;height:${size}px">
    <svg width="${size}" height="${size}"><circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="var(--line-strong)" stroke-width="${width}"/>
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${!left && f >= 1 ? 'var(--green)' : 'var(--accent)'}" stroke-width="${width}" stroke-linecap="round"
      stroke-dasharray="${c}" class="ring-arc" style="stroke-dashoffset:${c * (1 - from)}" data-to="${c * (1 - f)}"/></svg>
    ${left && total && !remaining ? `<div class="lbl green" style="font-size:${size * 0.34}px">✓</div>`
      : size >= 44 ? `<div class="lbl" style="font-size:${size * 0.24}px">${!total ? '–' : left ? `${remaining}<small style="display:block;font-size:.45em;opacity:.65;margin-top:-2px">left</small>` : `${done}/${total}`}</div>` : ''}</div>`;
}

// Priority, hardness and time taken (rules in model.js).
const PRIO_LABEL = Object.fromEntries(M.PRIORITIES);
const hardColor = n => (n <= 2 ? 'var(--green)' : n === 3 ? '#d6b43c' : n === 4 ? 'var(--orange)' : 'var(--red)');
/** Five bars rising like a signal meter, filled up to the hardness. */
const hardMeter = n => `<span class="hmeter" style="--hc:${hardColor(n)}" aria-label="Hardness ${n} of 5">${[1, 2, 3, 4, 5].map(i => `<i class="${i <= n ? 'on' : ''}" style="height:${40 + 15 * (i - 1)}%"></i>`).join('')}</span>`;
/** "Usually about 40 min: 60% of the 7 times you timed took that long or less." */
function typicalText(t) {
  const times = M.takenTimes(t), p = M.typicalMinutes(t);
  if (!p) return '';
  return times.length === 1 ? `It took ${M.fmtMinutes(p)} the one time you timed it.` : `Usually about ${M.fmtMinutes(p)}: 60% of the ${times.length} times you timed took that long or less.`;
}
/** Every recorded time as a tick from 0 to the longest; filled up to the 60% mark. */
function timeSpread(times) {
  const typ = M.percentile(times, 0.6), longest = times[times.length - 1], pct = n => Math.min(100, (n / Math.max(1, longest)) * 100);
  return `<div class="spread" role="img" aria-label="60% of ${times.length} times took ${M.fmtMinutes(typ)} or less; the longest took ${M.fmtMinutes(longest)}">
    <div class="spread-track"><div class="spread-fill" style="width:${pct(typ)}%"></div>${times.map(n => `<i class="${n <= typ ? 'in' : ''}" style="left:${pct(n)}%"></i>`).join('')}<b style="left:${pct(typ)}%"></b></div>
    <div class="spread-labels"><span>0</span><span><b>60% ≤ ${M.fmtMinutes(typ)}</b></span><span>longest ${M.fmtMinutes(longest)}</span></div></div>`;
}
const takenChoices = t => [...new Set([15, 30, 45, 60, 90, ...(t.timeMinutes != null ? [t.durationMinutes] : []), ...(M.typicalMinutes(t) ? [M.typicalMinutes(t)] : [])])].sort((a, b) => a - b);
/** "After another task": which one, how long after, and where it stands. */
function followUpControls(d) {
  const options = M.possibleTriggers([...store.tasks.values()], d.id);
  if (!options.length) return '<div class="small muted">There’s no other task for it to follow yet.</div>';
  const trigger = store.tasks.get(d.after)?.title || 'that task';
  return `<div class="grid2"><label class="field"><span>After</span><select class="input" data-edit="after" data-rerender>${options.map(t => `<option value="${t.id}" ${t.id === d.after ? 'selected' : ''}>${esc(t.title || 'Untitled')}</option>`).join('')}</select></label>
      <label class="field"><span>Comes up</span><select class="input" data-edit="afterMinutes">${M.AFTER_CHOICES.map(n => `<option value="${n}" ${(d.afterMinutes || 0) === n ? 'selected' : ''}>${M.afterLabel(n)}</option>`).join('')}</select></label></div>
    <label class="check"><input type="checkbox" data-edit="persist" data-rerender ${d.mode === 'untilDone' ? 'checked' : ''}>${ic('flame')} Once it’s up, keep it on my list until it’s done</label>
    <div class="small muted">${ic('right')} ${d.armedAt ? `Came up at ${M.fmtTimeMinutes(d.timeMinutes ?? 0)} on ${M.fmtDay(d.startDate, { weekday: 'short', month: 'short', day: 'numeric' })} after “${esc(trigger)}” was checked off. It comes up again the next time.`
      : `Off your list until “${esc(trigger)}” is checked off; then it comes up ${M.afterLabel(d.afterMinutes || 0).toLowerCase()} with a reminder.`}</div>`;
}
/** The tasks that follow this one, and a way to add another. */
function followUpsFieldset(m) {
  const list = [...store.tasks.values()].filter(f => f.after === m.draft.id && !f.archived);
  return `<div class="fieldset"><div class="legend">Then</div>
    ${list.map(f => `<div class="row" style="gap:8px">${ic('right')}<span class="grow ellipsis">${esc(f.title)}</span><span class="small muted">${M.afterLabel(f.afterMinutes || 0)}</span>
      <button type="button" class="btn sm ghost" data-act="edit-followup" data-id="${f.id}">Edit</button></div>`).join('')}
    <div><button type="button" class="btn sm" data-act="edit-add-followup">${ic('plus')} Add a task that follows this one</button></div>
    <div class="small muted">Follow-ups wait off your list until this is checked off, then come up on their own: chain the next step to the last.</div></div>`;
}

function timeTakenFieldset(m) {
  const d = m.draft, entries = Object.entries(d.timeTaken || {}).filter(([, v]) => v > 0).sort((a, b) => b[0].localeCompare(a[0]));
  const typ = M.typicalMinutes(d);
  return `<div class="fieldset"><div class="legend">Time it took</div>${!entries.length
    ? '<div class="small muted">Not timed yet. When you check it off, you can write down how long it took, and this shows how long it usually takes.</div>'
    : `${timeSpread(M.takenTimes(d))}<div class="small muted">${esc(typicalText(d))}</div>
      ${typ !== d.durationMinutes ? `<div><button type="button" class="btn sm" data-act="edit-use-typical" title="Sets its length to how long it usually takes">Plan ${M.fmtMinutes(typ)} for it</button></div>` : ''}
      <table class="times">${entries.slice(0, m.allTimes ? entries.length : 6).map(([k, v]) => `<tr><td>${M.fmtDay(M.parseKey(k), { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })}</td>
        <td class="num">${M.fmtMinutes(v)}</td><td><button type="button" class="btn sm ghost" data-act="edit-time-del" data-k="${k}" title="Remove this time" aria-label="Remove this time">${ic('x')}</button></td></tr>`).join('')}</table>
      ${entries.length > 6 ? `<button type="button" class="btn sm ghost" data-act="edit-times-all">${m.allTimes ? 'Show fewer' : `Show all ${entries.length}`}</button>` : ''}`}</div>`;
}

function crow(o, { compact = false, showDate = false, ctx = '' } = {}) {
  const t = o.task;
  const meta = [];
  if (showDate || o.overdue) meta.push(`<span class="${o.overdue ? 'red' : ''}">${M.fmtDay(o.day, { weekday: 'short', month: 'short', day: 'numeric' })}</span>`);
  if (o.bonus) {
    const today = M.bonusKeysOn(t, o.day).length;
    // "2× today" only when the round is longer than today (otherwise the summary already says it).
    const showToday = today && !o.done && today !== M.bonusRoundKeys(t, o.day).length;
    meta.push(`<span>${ic('star')}Bonus · ${esc(M.bonusSummary(t, o.day))}${showToday ? ` · ${today}× today` : ''}</span>`);
    const rep = !compact && M.bonusRepeatSummary(t), next = o.done && !compact && M.bonusNextRound(t, o.day);
    if (rep) meta.push(`<span class="ellipsis">${ic('repeat')}${esc(rep)}</span>`);
    if (next) meta.push(`<span>back ${M.fmtDay(next, { weekday: 'short', month: 'short', day: 'numeric' })}</span>`);
    if (!compact && !o.done) meta.push(`<span class="bonus-pts">+${M.BONUS_POINTS} in focus</span>`);
  } else meta.push(o.start ? `<span>${ic('clock')}${M.fmtTime(o.start)}</span>` : compact ? '' : `<span>${ic('sun')}Any time</span>`);
  if (M.isUntilDone(t) && !compact && !o.resolved) meta.push(`<span>${ic('flame')}${esc(M.carryLabel(t, o.day))}</span>`);
  const plan = o.bonus ? null : M.planSummary(t);
  if (plan && !compact) meta.push(`<span>${ic(M.isUntilDone(t) ? 'flame' : 'repeat')}${esc(plan)}</span>`);
  const trig = t.after && store.tasks.get(t.after);
  if (trig) meta.push(`<span class="ellipsis">${ic('right')}after ${esc(trig.title)}</span>`);
  const next = !compact && !o.resolved ? [...store.tasks.values()].filter(f => f.after === t.id && !f.archived) : [];
  if (next.length) meta.push(`<span class="ellipsis" title="Comes up when this is checked off">${ic('right')}then ${esc(next.map(f => f.title).join(', '))}</span>`);
  const pr = M.priorityOf(t), hd = M.hardnessOf(t), took = o.done && t.timeTaken?.[o.key], typ = M.typicalMinutes(t);
  if (pr && !o.resolved) meta.push(`<span class="prio prio-${pr}" title="${PRIO_LABEL[pr]} priority"><b>${'!'.repeat(3 - M.priorityRank(t))}</b>${PRIO_LABEL[pr]}</span>`);
  if (hd) meta.push(`<span title="Hardness ${hd} of 5: ${M.HARDNESS[hd - 1]}">${hardMeter(hd)}</span>`);
  if (took) meta.push(`<span>${ic('timer')}took ${M.fmtMinutes(took)}</span>`);
  else if (!o.resolved && typ && !compact) meta.push(`<span title="${esc(typicalText(t))}">${ic('timer')}usually ${M.fmtMinutes(typ)}</span>`);
  if (M.nagLevel(t) !== 'normal' && !o.resolved) {
    const [, label, desc] = M.NAG_LEVELS.find(x => x[0] === M.nagLevel(t));
    meta.push(`<span class="${M.nagLevel(t) === 'strict' ? 'red' : 'orange'}" title="Keeps after you until it’s checked off. ${esc(desc)}">${ic(M.nagLevel(t) === 'strict' ? 'lock' : 'bell')}${label}</span>`);
  }
  if (M.pastDue(t)) meta.push(`<span class="red"><b>Past due</b></span>`);
  if (o.overdue) meta.push('<span class="red"><b>Overdue</b></span>');
  if (t.source === 'calendly') meta.push(`<span>${ic('people')}Calendly</span>`);
  if (t.source === 'google') meta.push(`<span>${ic('cal')}Google</span>`);
  if (M.isSilent(t) && !o.bonus) meta.push(`<span title="No notifications">${ic('bell-off')}</span>`);
  if (t.externalURL && !compact) meta.push(`<a href="${esc(t.externalURL)}" target="_blank" rel="noopener" title="Open meeting link">${ic('link')}</a>`);
  if (o.missed) meta.unshift(`<span class="red"><b>Didn’t do it</b></span>`);
  const steps = M.habitSteps(t);
  if (t.urgent && M.isUntilDone(t) && !o.resolved) meta.unshift('<span class="urgent-tag">URGENT</span>');
  if (steps.length) { const n = M.stepsDoneFor(t, o).size; meta.push(`<span class="${n === steps.length ? 'green' : ''}">${ic('list')}${n}/${steps.length} steps</span>`); }
  const hasRefl = o.resolved && store.reflectionFor(o, o.missed ? 'missed' : 'done');
  return `<div class="crow ${o.done ? 'done' : ''} ${o.missed ? 'missed' : ''} ${ui.justDone.has(o.id) ? 'just-done' : ''}">
    <button class="checkbtn" style="${o.done ? `color:${color(t.color)}` : ''}" data-act="toggle" data-occ="${esc(o.id)}" data-ctx="${ctx}"
      title="${o.done ? 'Mark as not done' : 'Complete — you’ll write a short reflection first'}">${ic(o.done ? 'checked' : 'circle')}</button>
    ${o.bonus ? `<span class="bonus-star" title="Bonus task: optional, +${M.BONUS_POINTS} points when you finish it during a focus session">${ic('star-fill')}</span>`
      : `<button class="missbtn ${o.missed ? 'on' : ''}" data-act="miss" data-occ="${esc(o.id)}" data-ctx="${ctx}"
      title="${o.missed ? 'Undo “didn’t do it”' : 'Didn’t do it / couldn’t — you’ll reflect on why'}">${ic('x')}</button>`}
    ${compact ? '' : `<span class="bar" style="background:${color(t.color)}"></span>`}
    <div class="grow"><div class="title ellipsis">${esc(t.title)}</div><div class="meta">${meta.join('')}</div>${steps.length && !compact ? stepList(o, ctx) : ''}</div>
    ${hasRefl ? `<span class="muted" title="Reflection saved">${ic('quote')}</span>` : ''}
    ${ctx === 'checkin' ? '' : `<div class="actions">
      <button class="btn ghost sm" data-act="edit" data-task="${t.id}">Edit</button>
      ${t.recurrence.frequency !== 'none' && !M.isUntilDone(t) && !o.bonus ? `<button class="btn ghost sm" data-act="skip" data-occ="${esc(o.id)}" title="Skip this occurrence">Skip</button>` : ''}
      ${M.isUntilDone(t) && t.urgent && !o.resolved ? `<button class="btn ghost sm" data-act="task-urgent" data-task="${t.id}" data-off="1" title="Back to due later">Not urgent</button>` : ''}
      ${o.bonus && !o.done && M.bonusKeysOn(t, o.day).length ? `<button class="btn ghost sm" data-act="bonus-undo" data-task="${t.id}" title="Take back the last check-off today">Undo one</button>` : ''}
    </div>`}
  </div>`;
}

/** A habit's steps for one occurrence: tick them off as you go; ticking the last one opens the check-off. */
function stepList(o, ctx = '') {
  const done = M.stepsDoneFor(o.task, o);
  return `<div class="steps">${M.habitSteps(o.task).map(s => `<button class="step ${done.has(s.id) ? 'on' : ''}" data-act="step-toggle" data-occ="${esc(o.id)}" data-step="${esc(s.id)}" data-ctx="${ctx}"
    ${o.resolved ? 'disabled' : ''} style="--c:${color(o.task.color)}"><span class="box">${done.has(s.id) ? '✓' : ''}</span>${esc(s.title)}</button>`).join('')}</div>`;
}

function findOcc(id) {
  const [taskId, key] = id.split('|');
  const t = store.tasks.get(taskId);
  // A bonus task's id names one particular check-off ("…#2").
  return t ? M.makeOccurrence(t, M.parseKey(key), M.isBonus(t) ? key : null) : null;
}

function empty(icon, title, text) {
  return `<div style="text-align:center;padding:48px 16px" class="muted">
    <div style="font-size:36px">${ic(icon)}</div><div style="font-size:17px;font-weight:650;color:var(--text);margin:6px 0">${esc(title)}</div>${esc(text)}</div>`;
}

// ---------- Home (in-app dashboard) ----------
function homeView() {
  const now = new Date();
  const all = store.countedToday();
  const proj = store.projectToday(), projOpen = proj.filter(d => d.item && !M.itemDone(d.item)).length, total = all.length + proj.length;
  const done = all.filter(o => o.done).length + proj.length - projOpen;
  const open = all.filter(o => !o.resolved);
  const hour = now.getHours();
  const greet = hour >= 5 && hour < 12 ? 'Good morning' : hour >= 12 && hour < 17 ? 'Good afternoon' : 'Good evening';
  const weekStart = M.startOfWeek(now);
  const weekCount = [...Array(7)].reduce((n, _, i) => n + store.tasksOn(M.addDays(weekStart, i)).length, 0);
  const overdue = store.overdue().length;
  const latest = store.sortedReflections()[0];
  const nextTimed = [...store.occurrencesOn(now), ...store.occurrencesOn(M.addDays(now, 1))]
    .filter(o => !o.resolved && o.start && o.start > now).sort((a, b) => a.start - b.start)[0];
  const nextEvent = store.googleEventsOn(now).find(e => !e.isAllDay && e.startDate > now);
  const upNext = [nextTimed && { title: nextTimed.task.title, at: nextTimed.start, color: color(nextTimed.task.color) },
    nextEvent && { title: nextEvent.title, at: nextEvent.startDate, color: nextEvent.colorHex || '#0a84ff' }]
    .filter(Boolean).sort((a, b) => a.at - b.at)[0];
  const ss = store.syncState;
  const tile = (route, icon, title, value, sub, hue) => `<a class="tile" href="/app/${route}" style="--hue:${hue}">
    <span class="tile-ic">${ic(icon)}</span><span class="tile-title">${title}</span>
    <span class="tile-value">${value}</span><span class="tile-sub">${sub}</span></a>`;
  return `<div class="page stack" style="padding-top:28px;max-width:980px">
    <div class="hero"><div class="grow">
      <div class="muted" style="font-size:17px">${greet}${store.user ? `, ${esc(store.user.username)}` : ''}</div>
      <h2>${M.fmtDay(now)}</h2>
      <div class="muted">${!total ? 'Nothing on your checklist today.' : done === total ? 'Everything is checked off. Nice work.' : `${open.length + projOpen} thing${open.length + projOpen === 1 ? '' : 's'} left today.`}</div></div>
      <div class="row"><button class="btn" data-act="check-in">${ic('sun')} Check in</button><button class="btn" data-act="new-event">${ic('cal')} New event</button><button class="btn primary" data-act="new-task">${ic('plus')} New task</button></div></div>

    <div class="home-grid">
      <a class="card pad home-today" href="/app/today">
        <div class="row" style="gap:16px">${todayRing(done, total, 76, 9, 'home')}
          <div class="grow"><div class="section-title" style="margin:0">${ic('sun')}Today</div>
          <div class="muted small">${total ? `${done} of ${total} done` : 'A clear day'}${overdue ? ` · <span class="red">${overdue} overdue</span>` : ''}</div></div>
          <span class="muted">${ic('right')}</span></div>
        ${open.length ? `<div class="home-list">${open.slice(0, 4).map(o => `<div class="row small"><span style="width:7px;height:7px;border-radius:50%;background:${color(o.task.color)}"></span>
          <span class="grow ellipsis">${esc(o.task.title)}</span><span class="muted">${o.start ? M.fmtTime(o.start) : o.overdue ? 'overdue' : 'any time'}</span></div>`).join('')}
          ${open.length > 4 ? `<div class="small muted">+${open.length - 4} more</div>` : ''}</div>` : ''}
      </a>
      <div class="card pad home-next">
        <div class="section-title" style="margin:0 0 6px">${ic('clock')}Up next</div>
        ${upNext ? `<div class="row"><span style="width:4px;align-self:stretch;border-radius:2px;background:${upNext.color}"></span>
          <div><div style="font-weight:600">${esc(upNext.title)}</div><div class="muted small">${M.isToday(upNext.at) ? '' : 'Tomorrow · '}${M.fmtTime(upNext.at)}</div></div></div>`
          : '<div class="muted small">Nothing else scheduled with a time.</div>'}
        <div class="section-title" style="margin:14px 0 6px">${ic('quote')}Latest reflection</div>
        ${latest ? `<div class="small" style="font-style:italic">“${esc(latest.text.length > 140 ? latest.text.slice(0, 140) + '…' : latest.text)}”</div>
          <div class="tiny muted" style="margin-top:4px">${esc(latest.taskTitle)}</div>` : '<div class="muted small">Check something off to write your first one.</div>'}
      </div>
    </div>

    <div class="tiles">
      ${tile('week', 'week', 'Week', weekCount, 'tasks this week', '#0a84ff')}
      ${tile('month', 'month', 'Month', M.fmtDay(now, { month: 'short' }), 'see the whole month', '#30b0c7')}
      ${tile('todo', 'list', 'To-Do List', store.tasks.size ? [...store.tasks.values()].filter(t => !t.archived).length : 0, overdue ? `${overdue} overdue` : 'all your tasks', '#ff9f0a')}
      ${(() => { const hs = [...store.tasks.values()].filter(t => !t.archived && M.isHabit(t)); const best = Math.max(0, ...hs.map(t => M.habitStats(t).streak));
        return tile('habits', 'habit', 'Habits', hs.length, best ? `best streak ${best} days` : 'build one today', '#30d158'); })()}
      ${tile('reflections', 'quote', 'Reflections', store.reflections.size, store.reflectionStreak ? `${store.reflectionStreak}-day streak` : 'your record', '#5e5ce6')}
      ${(() => { const pts = store.focusSessions.reduce((n, s) => n + (s.points || 0), 0); const lv = M.focusLevel(pts);
        return tile('focus', 'target', 'Focus', `Level ${lv.level}`, `${pts} points`, '#82a8ef'); })()}
      ${(() => { const today = store.screenDays(new Date()); const sec = today.reduce((n, d) => n + (d.totalSeconds || 0), 0);
        return tile('screentime', 'monitor', 'Screen time', today.length ? M.fmtDuration(sec) : '—', today.length ? 'today on your Mac' : 'tracked by the Mac app', '#5ac8fa'); })()}
      ${tile('booking', 'people', 'Open time', durLabel(openTimeDays().reduce((n, d) => n + d.total, 0)), 'free in the next 7 days', '#30d158')}
      ${tile('settings', 'gear', 'Settings', ss.status === 'synced' ? 'Synced' : ss.status === 'offline' ? 'Offline' : '—', store.google.connected ? 'Google connected' : 'reminders & sync', '#8e8e93')}
    </div>
  </div>`;
}

// ---------- Events (calendar-only items: your own + imported + Google) ----------
function scheduleOn(day) {
  const list = [
    ...store.eventsOn(day).filter(o => store.taskShown(o.task)).map(o => ({ id: `t|${o.id}`, title: o.task.title, start: o.start, end: o.end, allDay: !o.start,
      color: color(o.task.color), source: o.task.source, link: o.task.externalURL, notes: o.task.notes, silent: M.isSilent(o.task), busy: o.busy })),
    ...store.visibleGoogleEventsOn(day).map(e => ({ id: `g|${e.id}`, title: e.title, start: e.isAllDay ? null : e.startDate, end: e.isAllDay ? null : e.endDate,
      allDay: e.isAllDay, color: e.colorHex || '#0a84ff', source: 'google', link: e.link, notes: e.location, busy: !e.transparent })),
  ];
  return list.sort((a, b) => (a.allDay === b.allDay ? (a.start || 0) - (b.start || 0) : a.allDay ? -1 : 1));
}

function eventRow(ev) {
  const src = ev.source === 'calendly' ? `<span>${ic('people')}Calendly</span>` : ev.source === 'google' ? `<span>${ic('cal')}Google</span>` : '';
  return `<div class="crow erow" data-act="detail" data-item="${esc(ev.id)}">
    <span class="evt-time">${ev.allDay ? 'All day' : `${M.fmtTime(ev.start)}<small>${M.fmtTime(ev.end)}</small>`}</span>
    <span class="bar ${ev.busy === false ? 'free' : ''}" style="--hue:${ev.color};background:${ev.color}"></span>
    <div class="grow"><div class="title ellipsis">${esc(ev.title)}</div><div class="meta">${src}${ev.busy === false ? `<span title="Open: just for info">${ic('eye')}Open</span>` : ''}${ev.notes ? `<span class="ellipsis">${esc(ev.notes)}</span>` : ''}${ev.silent === false ? `<span title="Reminds you">${ic('bell')}</span>` : ''}</div></div>
    ${ev.link ? `<a href="${esc(ev.link)}" target="_blank" rel="noopener" title="Open">${ic('link')}</a>` : ''}
  </div>`;
}

// ---------- Today ----------
function todayView() {
  const today = new Date();
  // Until-done items that aren't due yet go under "Due later" and stay out of the ring (unless urgent).
  const later = store.dueLater([...store.overdue(), ...store.tasksOn(today)]);
  const items = store.countedToday(store.tasksOn(today)), overdue = store.overdue(), all = [...overdue, ...items];
  // Tasks, habits, and tasks that stay on until you do them each get their own section.
  const habits = items.filter(o => M.isHabit(o.task) && !M.isUntilDone(o.task));
  const daily = items.filter(o => !M.isHabit(o.task) && !M.isUntilDone(o.task)), ongoing = items.filter(o => M.isUntilDone(o.task));
  // Project subtasks on today's list count in the ring too (see "On today").
  const proj = store.projectToday(), projDone = proj.filter(d => d.item && M.itemDone(d.item)).length, total = all.length + proj.length;
  const done = all.filter(o => o.done).length + projDone, settled = all.filter(o => o.resolved).length + projDone;
  const hour = today.getHours();
  const greet = hour >= 5 && hour < 12 ? 'Good morning' : hour >= 12 && hour < 17 ? 'Good afternoon' : 'Good evening';
  const status = !total ? 'A clear day.' : done === total ? 'Everything is checked off. Nice work.'
    : settled === total ? `All settled: ${done} done, ${total - done} not done.` : `${total - settled} of ${total} left to check off.`;
  const events = scheduleOn(today);
  const s = store.settings;
  const perm = 'Notification' in window ? Notification.permission : 'unsupported';
  return `<div class="page stack" style="padding-top:28px">
    <div class="hero"><div class="grow">
      <div class="muted" style="font-size:17px">${greet}</div>
      <h2>${M.fmtDay(today)}</h2><div class="muted">${status}</div></div><button class="ring-btn" data-act="ring-mode" title="${store.settings.ringShowsLeft ?? true ? 'Showing what’s left · click to show what’s done' : 'Showing what’s done · click to show what’s left'}">${todayRing(done, total, 80, 9)}</button></div>
    ${perm === 'default' && reminders.enabled ? `<div class="callout warn"><span class="big">${ic('bell')}</span>
      <div class="grow"><b>Turn on notifications</b><div class="small muted">So reminders reach you even when this tab is in the background.</div></div>
      <button class="btn primary" data-act="ask-notify">Allow</button></div>` : ''}
    <form class="quickadd" data-form="quick">${ic('plus')}<input id="quickAdd" placeholder="Quick add to today — press Return" autocomplete="off"></form>
    ${overdue.length ? `<div><div class="section-title">${ic('alert')}Overdue <span class="count">${overdue.length}</span></div>
      <div class="card">${overdue.map(o => crow(o)).join('')}</div></div>` : ''}
    <div><div class="section-title">${ic('list')}Today’s checklist <span class="count">${daily.length}</span></div>
      <div class="card">${daily.length ? daily.map(o => crow(o)).join('')
        : `<div class="crow"><span style="font-size:22px;color:var(--orange)">${ic('sun')}</span><div><div>${ongoing.length ? 'Nothing else scheduled for today.' : 'Nothing scheduled for today.'}</div><div class="small muted">Add a task above, or use New Task for one with a time and repeat schedule.</div></div></div>`}</div>
      ${ongoing.length ? '' : `<div class="small muted" style="margin-top:6px">Checking an item off asks for a reflection of at least ${s.minReflectionWords} words. They’re saved under Reflections.</div>`}</div>
    ${habits.length ? `<div><div class="section-title">${ic('habit')}Habits <span class="count">${habits.filter(o => !o.resolved).length} left</span><span class="grow"></span>
        <a class="btn sm" href="/app/habits">Habit tracker</a></div>
      <div class="card">${habits.map(o => crow(o)).join('')}</div></div>` : ''}
    ${ongoing.length ? `<div><div class="section-title">${ic('flame')}Until done <span class="count">${ongoing.length}</span>
        <span class="small muted" style="font-weight:400">stays on your list until you check it off or mark it “didn’t do it”</span></div>
      <div class="card">${ongoing.map(o => crow(o)).join('')}</div>
      <div class="small muted" style="margin-top:6px">Checking an item off asks for a reflection of at least ${s.minReflectionWords} words. They’re saved under Reflections.</div></div>` : ''}
    ${(() => { const bonus = store.bonusTasks(); return bonus.length ? `<div><div class="section-title">${ic('star')}Bonus <span class="count">${bonus.filter(o => !o.done).length}</span>
        <span class="small muted" style="font-weight:400">optional · not counted in today’s progress · +${M.BONUS_POINTS} each in a focus session</span></div>
      <div class="card">${bonus.map(o => crow(o)).join('')}</div></div>` : ''; })()}
    ${later.length ? `<div><div class="section-title">${ic('clock')}Due later <span class="count">${later.length}</span>
        <span class="small muted" style="font-weight:400">not counted in today’s progress · mark one urgent to work on it today</span><span class="grow"></span>${projectTodaySelect()}</div>
      <div class="card">${later.map(o => { const d = M.untilDoneDeadline(o.task, o.day);
        return `<div class="later-row">${crow(o)}${d ? `<span class="small muted mono">due ${M.WEEKDAY_SHORT[d.getDay()]} ${M.fmtTime(d)}</span>` : ''}
          <button class="btn sm" data-act="task-urgent" data-task="${o.task.id}" title="Put it on today’s list and in today’s progress">! Urgent</button></div>`; }).join('')}</div></div>` : ''}
    ${(() => { const up = store.upcomingOneOffs(); return up.length ? `<div><div class="section-title">${ic('cal')}Upcoming <span class="count">${up.length}</span>
        <span class="small muted" style="font-weight:400">one-off tasks in the next 30 days · not counted today</span></div>
      <div class="card">${up.map(o => `<div class="later-row">${crow(o, { showDate: true })}<span class="small muted">${M.dueRelative(M.dateKey(o.day))}</span></div>`).join('')}</div></div>` : ''; })()}
    ${projectTodaySection()}
    ${projectUpcomingSection()}
    <div><div class="section-title">${ic('cal')}Schedule <span class="count">${events.length}</span><span class="grow"></span>
      <button class="btn sm" data-act="new-event">${ic('plus')} New event</button></div>
      <div class="card">${events.length ? events.map(eventRow).join('') : '<div class="crow muted">No events today. Events show on your calendars but never on the checklist.</div>'}</div></div>
    ${(() => { const st = screenSummary(today); if (!st.has) return '';
      const over = s.screenLimitMinutes && st.total > s.screenLimitMinutes * 60;
      return `<a class="callout" href="/app/screentime" style="text-decoration:none;color:inherit"><span class="big" style="color:#5ac8fa">${ic('monitor')}</span><div class="grow">
        <b class="${over ? 'red' : ''}">Screen time today: ${M.fmtDuration(st.total)}${s.screenLimitMinutes ? ` of ${M.fmtDuration(s.screenLimitMinutes * 60)}` : ''}</b>
        <div class="small muted">${M.fmtDuration(st.distracting)} in distracting apps${st.apps[0] ? ` · most: ${esc(st.apps[0].name)} (${M.fmtDuration(st.apps[0].seconds)})` : ''}. A focus session helps.</div></div></a>`; })()}
    <div class="callout"><span class="big">${ic('bell')}</span><div class="grow">
      <b>${s.nudgeEnabled ? `Checklist reminder every ${s.nudgeIntervalMinutes} min while this page is open` : 'Recurring checklist reminders are off'}</b>
      <div class="small muted">${!reminders.enabled ? 'Browser reminders are off on this device (Settings).' : s.nudgeEnabled ? `Next one around ${M.fmtTime(reminders.nextNudge)}. You’ll also get a check-in when you come back to your computer.` : 'Turn them on in Settings.'}</div></div>
      <button class="btn" data-act="check-in">Check in now</button></div>
  </div>`;
}

// ---------- Calendar toggles ----------
/** Every calendar the views can show: [key, name, color]. */
function calendarList() {
  const g = store.google, pid = store.primaryCalendarId;
  const list = [['tasks', 'Tasks', '#0a84ff'], ['habits', 'Habits', '#30d158'], ['events', 'Events', '#30b0c7']];
  if ([...store.tasks.values()].some(t => t.source === 'gtasks' && !t.archived)) list.push(['gtasks', 'Google Tasks', '#4285f4']);
  if (store.calendly.connected || [...store.tasks.values()].some(t => t.source === 'calendly' && !t.archived)) list.push(['calendly', 'Calendly', '#bf5af2']);
  const add = (id, fallback) => {
    const key = M.googleCalendarKey(id, pid);
    if (list.some(x => x[0] === key)) return;
    const c = g.calendars?.find(c => c.id === id || ((!id || id === 'primary') && c.primary));
    list.push([key, c?.summary || fallback || id, c?.colorHex || '#0a84ff']);
  };
  if (g.connected) for (const id of store.googleCalendarIDs.length ? store.googleCalendarIDs : ['primary']) add(id, 'Google Calendar');
  for (const t of store.tasks.values()) if (t.source === 'google' && !t.archived) add(t.sourceCalendar || 'primary', 'Google Calendar');
  return list;
}

function calendarsMenu() {
  const list = calendarList(), shown = list.filter(([k]) => store.calendarShown(k)).length;
  return `<div class="calmenu"><button class="btn ${shown < list.length ? 'filtered' : ''}" data-act="cal-menu" title="Show or hide calendars">${ic('layers')} Calendars${shown < list.length ? ` <span class="count">${shown}/${list.length}</span>` : ''}</button>
    ${ui.calMenu ? `<div class="calmenu-pop"><div class="small muted" style="margin-bottom:6px">Show on Week, Month &amp; Booking</div>
      ${list.map(([k, l, c]) => `<label class="check"><input type="checkbox" data-act-change="cal-toggle" value="${esc(k)}" ${store.calendarShown(k) ? 'checked' : ''}>
        <span class="sw" style="background:${c}"></span><span class="ellipsis">${esc(l)}</span></label>`).join('')}
      <div class="tiny muted" style="margin-top:6px">Hidden calendars don’t count against your open time. Your checklist and reminders aren’t affected.</div></div>` : ''}</div>`;
}

// ---------- Habits (Atomic Habits tracker) ----------
const STYLE_LABEL = { build: 'Building', stack: 'Stacked', replace: 'Replacing', break: 'Breaking' };

/** Today's screen time in one app (from the Mac app's synced summaries), in seconds, or null. */
function appSecondsToday(app) {
  const days = store.screenDays(new Date());
  if (!days.length || !app) return null;
  const want = app.trim().toLowerCase();
  return days.reduce((n, d) => n + (d.apps || []).filter(a => a.name.toLowerCase().includes(want)).reduce((m, a) => m + a.seconds, 0), 0);
}

function habitCard(t, st) {
  const h = t.habit || {}, today = new Date(), occ = M.occurs(t, today) ? M.makeOccurrence(t, today) : null;
  const sentence = habitSentence(t), next = !occ ? M.nextOccurrence(t, M.addDays(today, 1)) : null;
  const used = h.style === 'break' && h.app ? appSecondsToday(h.app) : null;
  const limit = (h.limitMinutes || 0) * 60;
  return `<div class="habit-card" style="--hue:${color(t.color)}">
    <div class="row" style="align-items:flex-start"><span class="hc-bar"></span>
      <div class="grow" style="min-width:0"><div class="hc-title ellipsis">${esc(t.title)}</div>
        <div class="small muted">${esc(M.planSummary(t) || 'Every day')} · ${STYLE_LABEL[h.style || 'build']}</div></div>
      <div class="hc-streak" title="Current streak (best ${st.best})">${ic('flame')}<b>${st.streak}</b><small>best ${st.best}</small></div></div>
    ${sentence ? `<div class="hc-sentence">${esc(sentence)}</div>` : ''}
    ${used != null ? `<div class="hc-screen ${limit && used > limit ? 'over' : ''}">${ic('monitor')} ${esc(h.app)} today: <b>${M.fmtDuration(used)}</b>${limit ? ` of ${M.fmtDuration(limit)}` : ''}</div>` : ''}
    <div class="hc-grid" title="Last 30 days">${st.grid.map(g => `<i class="${g.state}" title="${M.fmtDay(g.day, { month: 'short', day: 'numeric' })}: ${{ done: 'done', missed: 'didn’t do it', lapsed: 'missed', open: 'today', off: 'not scheduled' }[g.state]}"></i>`).join('')}</div>
    <div class="hc-meta"><span>${st.rate == null ? 'New' : `${st.rate}% kept`}</span><span>${st.votes} vote${st.votes === 1 ? '' : 's'}${h.identity ? ' for who you’re becoming' : ''}</span>
      ${h.twoMinute ? `<span title="The 2-minute version">${ic('timer')}${esc(h.twoMinute)}</span>` : ''}${h.reward ? `<span title="Reward">${ic('check')}then ${esc(h.reward)}</span>` : ''}</div>
    ${occ && M.habitSteps(t).length ? stepList(occ) : ''}
    ${st.missTwice ? `<div class="hc-warn">${ic('alert')} Missed last time. Never miss twice: even the 2-minute version counts today.</div>` : ''}
    <div class="row" style="flex-wrap:wrap">
      ${occ && !occ.resolved ? `<button class="btn primary sm" data-act="toggle" data-occ="${esc(occ.id)}">${ic('check')} Done today…</button>
        <button class="btn sm" data-act="miss" data-occ="${esc(occ.id)}">${ic('x')} Didn’t do it…</button>`
        : occ?.done ? `<span class="green small">${ic('check')} Done today</span>` : occ?.missed ? `<span class="red small">${ic('x')} Not done today</span>`
        : `<span class="small muted">${next ? `Next: ${M.fmtDay(next, { weekday: 'short', month: 'short', day: 'numeric' })}` : 'Not scheduled'}</span>`}
      <span class="grow"></span><button class="btn ghost sm" data-act="edit" data-task="${t.id}">Edit</button></div>
  </div>`;
}

/** The tracker grid: a row per habit, a column per day, newest on the right. */
const CELL_LABEL = { done: 'done', missed: 'didn’t do it', lapsed: 'missed', open: 'to do today', off: 'not scheduled' };
function habitTable(habits, stats) {
  const n = ui.habitRange || 14;
  const days = stats.get(habits[0].id).grid.slice(-n).map(g => g.day);
  const cols = days.map((d, i) => habits.map(t => stats.get(t.id).grid.slice(-n)[i].state));
  return `<div class="card ht-card"><div class="row" style="padding:10px 12px 0">
      <div class="section-title" style="margin:0">${ic('week')}Tracker</div><span class="grow"></span>
      <div class="seg">${[[7, 'Week'], [14, '2 weeks'], [30, 'Month']].map(([v, l]) => `<button class="${n === v ? 'on' : ''}" data-act="habit-range" data-n="${v}">${l}</button>`).join('')}</div></div>
    <div class="ht-wrap"><table class="ht">
      <thead><tr><th class="ht-name"></th>${days.map(d => `<th class="${M.isToday(d) ? 'today' : ''}"><span>${M.WEEKDAY_LETTER[d.getDay()]}</span><b>${d.getDate()}</b></th>`).join('')}
        <th class="ht-sum" title="Current streak">${ic('flame')}</th><th class="ht-sum" title="Kept in the last 30 days">%</th></tr></thead>
      <tbody>${habits.map(t => { const st = stats.get(t.id), g = st.grid.slice(-n);
        return `<tr><td class="ht-name"><span class="dot" style="background:${color(t.color)}"></span><span class="ellipsis">${esc(t.title)}</span></td>
          ${g.map(c => { const key = M.dateKey(c.day), canCheck = c.state === 'open' || c.state === 'lapsed';
            return `<td><button class="ht-cell ${c.state}" style="--hue:${color(t.color)}" ${canCheck ? `data-act="toggle" data-occ="${esc(`${t.id}|${key}`)}"` : 'tabindex="-1"'}
              title="${esc(t.title)} · ${M.fmtDay(c.day, { weekday: 'short', month: 'short', day: 'numeric' })}: ${CELL_LABEL[c.state]}${canCheck ? ' (click to check off)' : ''}">${c.state === 'done' ? ic('check') : c.state === 'missed' ? ic('x') : ''}</button></td>`; }).join('')}
          <td class="ht-sum"><b>${st.streak}</b></td><td class="ht-sum">${st.rate == null ? '–' : `${st.rate}%`}</td></tr>`; }).join('')}</tbody>
      <tfoot><tr><td class="ht-name small muted">Done</td>${cols.map(states => { const sched = states.filter(x => x !== 'off').length, done = states.filter(x => x === 'done').length;
        return `<td class="small ${sched && done === sched ? 'green' : 'muted'}">${sched ? `${done}/${sched}` : ''}</td>`; }).join('')}<td></td><td></td></tr></tfoot>
    </table></div></div>`;
}

function habitsView() {
  const habits = [...store.tasks.values()].filter(t => M.isHabit(t) && !t.archived && store.taskShown(t)).sort((a, b) => a.title.localeCompare(b.title));
  const stats = new Map(habits.map(t => [t.id, M.habitStats(t)]));
  const dueToday = habits.filter(t => stats.get(t.id).today);
  const doneToday = dueToday.filter(t => stats.get(t.id).today === 'done').length;
  const votes = [...stats.values()].reduce((n, s) => n + s.votes, 0);
  const identities = new Map();
  for (const t of habits) if (t.habit?.identity) identities.set(t.habit.identity, (identities.get(t.habit.identity) || 0) + stats.get(t.id).votes);
  const card = store.settings.habitScorecard || [];
  const stat = (v, l, icon, c) => `<div class="stat" style="background:${tint(c, .1)}"><span style="color:${c}">${ic(icon)}</span><div><b>${v}</b><span class="small muted">${l}</span></div></div>`;
  return `<div class="header"><div class="grow"><h1>Habits</h1><div class="sub">Small habits, repeated. Every check-off is a vote for the person you’re becoming.</div></div>
      <button class="btn primary" data-act="new-habit">${ic('plus')} New habit</button></div>
    <div class="page stack">
      ${habits.length ? habitTable(habits, stats) : ''}
      <div class="stats">${stat(`${doneToday}/${dueToday.length}`, 'done today', 'check', '#30d158')}${stat(Math.max(0, ...[...stats.values()].map(s => s.streak)), 'best current streak', 'flame', '#ff9f0a')}
        ${stat(votes, 'votes cast', 'habit', '#5e5ce6')}${stat(habits.length, habits.length === 1 ? 'habit' : 'habits', 'repeat', '#30b0c7')}</div>
      ${identities.size ? `<div class="identities">${[...identities].map(([id, n]) => `<span class="identity">${ic('quote')} I am someone who ${esc(id)} <b>${n} vote${n === 1 ? '' : 's'}</b></span>`).join('')}</div>` : ''}
      ${habits.length ? `<div class="habit-grid">${habits.map(t => habitCard(t, stats.get(t.id))).join('')}</div>`
        : empty('habit', 'No habits yet', 'Start tiny: pick one thing you want to do every day, and the 2-minute version of it.')}
      <div><div class="section-title">${ic('list')}Habit scorecard <span class="small muted" style="font-weight:400">what you already do, rated</span></div>
        <div class="card">
          ${card.map(c => `<div class="crow"><span class="grow">${esc(c.text)}</span>
            <div class="seg score">${[['+', 'Good'], ['=', 'Neutral'], ['-', 'Bad']].map(([r, l]) => `<button class="${c.rating === r ? 'on r' + (r === '+' ? 'g' : r === '-' ? 'b' : 'n') : ''}" data-act="score-rate" data-id="${c.id}" data-r="${r}" title="${l}">${r === '-' ? '–' : r}</button>`).join('')}</div>
            ${c.rating === '-' ? `<button class="btn sm" data-act="score-replace" data-id="${c.id}">${ic('repeat')} Replace it</button>` : ''}
            <button class="btn ghost sm icon" data-act="score-del" data-id="${c.id}" title="Remove">${ic('x')}</button></div>`).join('')}
          <form class="crow" data-form="scorecard"><input class="input grow" name="text" placeholder="Something you do every day, e.g. check my phone right after waking up" autocomplete="off">
            <button class="btn">${ic('plus')} Add</button></form>
        </div>
        <div class="small muted" style="margin-top:6px">Rate each one good (+), neutral (=) or bad (–) for who you want to be. “Replace it” starts a habit that takes a bad one’s place.</div></div>
      <div class="laws">${[['1', 'Make it obvious', 'Give it a cue: a time and place, or stack it after a habit you already have.'],
        ['2', 'Make it attractive', 'Pair it with something you enjoy, and spend time with people who already do it.'],
        ['3', 'Make it easy', 'Shrink it to a 2-minute version. Showing up matters more than doing it well.'],
        ['4', 'Make it satisfying', 'Reward yourself right after, and don’t break the chain: never miss twice.']]
        .map(([n, t, d]) => `<div class="law"><b>${n}</b><div><div style="font-weight:650">${t}</div><div class="small muted">${d}</div></div></div>`).join('')}</div>
    </div>`;
}

// ---------- Focus (time pressure) ----------
// A session runs on this device: it survives a reload (saved in this browser), counts the time you spend away
// from Cadence (another tab or app) against your focus, and is saved to your account when it ends.
const FOCUS_KEY = 'cadence:focus';
const focus = (() => { try { return JSON.parse(localStorage.getItem(FOCUS_KEY) || 'null') || { running: false }; } catch { return { running: false }; } })();
const saveFocus = () => { try { localStorage.setItem(FOCUS_KEY, JSON.stringify(focus)); } catch { /* storage blocked */ } };
const fmtClock = ms => { const s = Math.ceil(ms / 1000), m = Math.floor(s / 60); return `${m}:${String(s % 60).padStart(2, '0')}`; };
// Pause: the clock stops (a sprint gets the time back on resume), and nothing counts as away until you resume.
const focusNow = () => focus.pausedAt || Date.now();
const focusLeft = () => Math.max(0, (focus.endsAt || 0) - focusNow());
const awayNow = () => (focus.awayMs || 0) + (focus.awaySince ? Date.now() - focus.awaySince : 0);
/** Time spent so far in this session, not counting pauses (ms). */
const focusElapsed = () => Math.max(0, focusNow() - focus.startedAt - (focus.pausedMs || 0));
const pauseClock = () => fmtClock(focus.pausedAt ? Date.now() - focus.pausedAt : 0);
function togglePause() {
  if (!focus.running) return;
  const now = Date.now();
  if (focus.pausedAt) {
    const d = now - focus.pausedAt;
    focus.pausedMs = (focus.pausedMs || 0) + d; focus.endsAt += d;
    if (d >= 1000) focus.pauses = [...(focus.pauses || []), { start: M.iso(new Date(focus.pausedAt)), end: M.iso(new Date(now)) }];
    focus.pausedAt = null; focus.awaySince = document.hasFocus() ? null : now;
  } else {
    if (focus.awaySince) { focus.awayMs = (focus.awayMs || 0) + now - focus.awaySince; focus.awaySince = null; }
    focus.pausedAt = now; focus.pauseNudgedAt = now;
  }
  saveFocus(); render();
}
/** Work mode: the points the time so far is worth (2 per 5 minutes, times the multiplier), before completing it. */
function workTimePoints() {
  const e = Math.max(1, focusElapsed()), pct = Math.round(100 * (e - Math.min(e, awayNow())) / e);
  return M.studyPoints(Math.floor(focusElapsed() / 60_000), pct);
}
/** Work mode's clock, counting up: "12:34" or "1:02:03". */
const workClock = () => {
  const s = Math.max(0, Math.floor(focusElapsed() / 1000));
  return s >= 3600 ? `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}` : `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
};

// Bonus tasks during a session: ticked on the Focus page (reflected on when it ends), or checked off anywhere
// else while it runs (store.onComplete). Each is +15 points before the multiplier; they're not part of the list.
const bonusDone = id => (focus.bonusTicks || []).filter(x => x === id).length + (focus.bonusCredited || []).filter(x => x.startsWith(`${id}|`)).length;
function canTickBonus(t) {
  if (!focus.running || !M.isBonus(t)) return false;
  const left = M.bonusLeft(store.tasks.get(t.id) || t);
  return left == null || (focus.bonusTicks || []).filter(x => x === t.id).length < left;
}
/** The ticked bonus tasks as check-offs to reflect on, each with its own key ("…#2"), never past its limit. */
function tickedBonusOccs() {
  const today = new Date(), sim = new Map(), out = [];
  for (const id of focus.bonusTicks || []) {
    const t = sim.get(id) ?? store.tasks.get(id);
    if (!t || !M.isBonus(t) || M.bonusUsedUp(t)) continue;
    const key = M.nextBonusKey(t, today);
    out.push(M.makeOccurrence(store.tasks.get(id), today, key));
    sim.set(id, { ...t, completions: { ...t.completions, [key]: M.iso(new Date()) } });
  }
  return out;
}
store.onComplete = (t, key) => {
  const id = `${t.id}|${key}`;
  if (!focus.running || !M.isBonus(t) || (focus.bonusCredited || []).includes(id) || focus.finished.includes(id)) return;
  focus.bonusCredited = [...(focus.bonusCredited || []), id];
  saveFocus();
};

function startFocus(minutes, picked, work = null) {
  Object.assign(focus, { running: true, id: M.uuid(), startedAt: Date.now(), endsAt: Date.now() + minutes * 60_000, minutes, picked, finished: [], bonusTicks: [], bonusCredited: [],
    pausedAt: null, pausedMs: 0, pauses: [],
    awayMs: 0, awaySince: document.hasFocus() ? null : Date.now(), mode: work ? 'work' : 'sprint', workId: work?.id ?? null, title: work?.task.title ?? null });
  ui.focusResult = null;
  saveFocus(); render(); focusTick();
}

// Focus › Work: one task as the headline, a clock counting up, until you complete it. (The Mac app also blocks
// distracting apps and sites while it runs there; a browser tab can't.)
const isWorking = () => focus.running && focus.mode === 'work';
function startWork(o) {
  if (focus.running) endFocus({ quiet: true });
  startFocus(M.FOCUS_MAX_MINUTES, [o.id], o);
  navigate('focus');
}
function completeWork() {
  if (!isWorking()) return;
  const o = findOcc(focus.workId), minutes = Math.max(1, Math.round(focusElapsed() / 60_000));
  focus.finished = [focus.workId];
  endFocus({ quiet: true });
  if (o) reflectQueue([o], minutes);
}

/** `quiet`: you ended it yourself, so no "Time!" alert. */
function endFocus({ quiet = false } = {}) {
  if (!focus.running) return;
  // Ended while paused: it ended when the break began. Pauses aren't part of the time.
  const end = Math.min(focusNow(), focus.endsAt), elapsed = Math.max(1, end - focus.startedAt - (focus.pausedMs || 0));
  const away = Math.min(elapsed, awayNow());
  const focusPercent = Math.round(100 * (elapsed - away) / elapsed);
  const finished = focus.finished.length, picked = focus.picked.length;
  // Bonus tasks don't count toward clearing the list; each one finished is worth bonus points instead.
  const isB = id => M.isBonus(findOcc(id)?.task);
  const ticked = tickedBonusOccs(), extras = [...ticked.map(o => o.id), ...(focus.bonusCredited || [])];
  const session = store.saveFocusSession({
    id: focus.id, startedAt: M.iso(new Date(focus.startedAt)), endedAt: M.iso(new Date(end)), plannedMinutes: focus.minutes,
    actualMinutes: Math.round(elapsed / 60_000), picked, finished, finishedTitles: focus.finished.map(id => findOcc(id)?.task.title).filter(Boolean),
    finishedIds: focus.finished, awaySeconds: Math.round(away / 1000), focusPercent, device: 'web',
    // Work sessions also score the time spent, like study sessions; sprints score what they finish.
    points: (focus.mode === 'work' ? M.workPoints : M.focusPoints)({ minutes: Math.round(elapsed / 60_000), finished: focus.finished.filter(id => !isB(id)).length,
      picked: focus.picked.filter(id => !isB(id)).length, focusPercent, bonus: extras.length + focus.finished.filter(isB).length }),
    ...(extras.length ? { bonus: extras.length, bonusIds: extras, bonusTitles: extras.map(id => findOcc(id)?.task.title).filter(Boolean) } : {}),
    ...(focus.mode === 'work' ? { mode: 'work', title: focus.title, occurrenceID: focus.workId } : {}),
    ...(focus.pauses?.length ? { pauses: focus.pauses, pausedSeconds: Math.round((focus.pausedMs || 0) / 1000) } : {}),
  }, { skip: focus.mode === 'work' && elapsed < 60_000 && !finished && !extras.length });
  Object.assign(focus, { running: false, bonusTicks: [], bonusCredited: [], pausedAt: null, pausedMs: 0, pauses: [] });
  saveFocus();
  ui.focusResult = session;
  if (quiet) { render(); return; }
  reflectQueue([...focus.finished.map(findOcc).filter(Boolean), ...ticked]);
  reminders.deliver({ kind: 'nudge', title: `Time! ${finished} done${extras.length ? ` + ${extras.length} bonus` : ''}`, body: `${focusPercent}% focused · +${session.points} points. Write your reflections to check them off.`, tint: '#82a8ef' },
    store.settings.defaultChannels);
  navigate('focus');
}

let focusTimer = null;
function focusTick() {
  clearInterval(focusTimer);
  if (!focus.running) return;
  focusTimer = setInterval(() => {
    if (!focus.running) { clearInterval(focusTimer); return; }
    if (focus.pausedAt) {
      // On a break: only the break's own clock moves, plus a reminder every 10 minutes.
      for (const el of document.querySelectorAll('[data-pause-clock]')) el.textContent = pauseClock();
      if (Date.now() - (focus.pauseNudgedAt || focus.pausedAt) >= 10 * 60_000) {
        focus.pauseNudgedAt = Date.now(); saveFocus();
        reminders.deliver({ kind: 'nudge', title: 'Still on a break?', body: `Paused for ${Math.round((Date.now() - focus.pausedAt) / 60_000)} min. Resume when you’re back.`, tint: '#82a8ef' }, ['banner']);
      }
      return;
    }
    if (focusLeft() <= 0) { clearInterval(focusTimer); endFocus(); return; }
    // Update just the clock pieces, not the whole page.
    if (isWorking()) {
      const t = workClock();
      for (const el of document.querySelectorAll('[data-focus-clock]')) el.textContent = t;
      for (const el of document.querySelectorAll('[data-focus-away]')) el.textContent = M.fmtDuration(awayNow() / 1000);
      for (const el of document.querySelectorAll('[data-work-points]')) el.textContent = workTimePoints();
      for (const el of document.querySelectorAll('[data-work-bar]')) el.style.width = `${Math.min(100, focusElapsed() / (Number(el.dataset.target) * 600))}%`;
      const badge = document.querySelector('.nav-item[href="/app/focus"] .badge');
      if (badge) badge.textContent = t;
      return;
    }
    const left = focusLeft(), frac = left / (focus.minutes * 60_000);
    for (const el of document.querySelectorAll('[data-focus-clock]')) el.textContent = fmtClock(left);
    for (const el of document.querySelectorAll('[data-focus-ring]')) el.style.strokeDashoffset = String(2 * Math.PI * 90 * (1 - frac));
    for (const el of document.querySelectorAll('[data-focus-away]')) el.textContent = M.fmtDuration(awayNow() / 1000);
    document.body.classList.toggle('focus-final', left < 5 * 60_000);
    const badge = document.querySelector('.nav-item[href="/app/focus"] .badge');
    if (badge) badge.textContent = fmtClock(left);
  }, 1000);
}
// Time in another tab or app counts as time away.
window.addEventListener('blur', () => { if (focus.running && !focus.pausedAt && !focus.awaySince) { focus.awaySince = Date.now(); saveFocus(); } });
window.addEventListener('focus', () => {
  if (focus.running && focus.awaySince) { focus.awayMs = (focus.awayMs || 0) + Date.now() - focus.awaySince; focus.awaySince = null; saveFocus(); }
});
if (focus.running) setTimeout(() => (focusLeft() <= 0 ? endFocus() : focusTick()));

function focusView() {
  const sessions = store.focusSessions, points = sessions.reduce((n, x) => n + (x.points || 0), 0), lv = M.focusLevel(points);
  const week = sessions.filter(x => new Date(x.startedAt) >= M.startOfWeek(new Date()));
  const best = Math.max(0, ...sessions.map(x => x.finished || 0));
  const levelCard = `<div class="focus-level"><div class="lv-badge">${lv.level}</div><div class="grow">
      <div class="row"><b>Level ${lv.level}</b><span class="grow"></span><span class="small muted">${points} points · ${lv.span - lv.into} to level ${lv.level + 1}</span></div>
      <div class="progress"><div style="width:${Math.round(100 * lv.into / lv.span)}%"></div></div>
      <div class="small muted" style="margin-top:4px">${M.focusStreak(sessions)}-day focus streak · ${week.reduce((n, x) => n + (x.points || 0), 0)} points this week · best session: ${best} done</div></div></div>`;
  let body;
  const workMode = (ui.focusMode ?? (() => { try { return localStorage.getItem('cadence:focusMode'); } catch { return null; } })() ?? 'work') === 'work';
  if (isWorking()) return workingView();
  if (focus.running) {
    const occs = focus.picked.map(findOcc).filter(Boolean), left = focusLeft();
    body = `<div class="focus-run">
      <div class="focus-clock"><svg viewBox="0 0 200 200"><circle cx="100" cy="100" r="90" class="track"/>
        <circle cx="100" cy="100" r="90" class="bar" data-focus-ring style="stroke-dasharray:${2 * Math.PI * 90};stroke-dashoffset:${2 * Math.PI * 90 * (1 - left / (focus.minutes * 60_000))}"/></svg>
        <div class="fc-inner"><div class="fc-time ${focus.pausedAt ? 'paused' : ''}" data-focus-clock>${fmtClock(left)}</div>
          ${focus.pausedAt ? `<div class="small paused-tag">${ic('pause')} Paused <span data-pause-clock>${pauseClock()}</span></div>` : ''}
          <div class="small muted">${focus.finished.length} of ${occs.length} done</div>
          ${(focus.bonusTicks || []).length + (focus.bonusCredited || []).length ? `<div class="small bonus-pts">${ic('star-fill')} ${(focus.bonusTicks || []).length + (focus.bonusCredited || []).length} bonus</div>` : ''}
          <div class="tiny muted">away <span data-focus-away>${M.fmtDuration(awayNow() / 1000)}</span></div></div></div>
      <div class="grow stack" style="gap:10px;min-width:0">
        <div class="small muted">Tap Done as you finish each one. You’ll write the reflections when time’s up, so the clock is only for doing.</div>
        ${occs.length ? `<div class="card">${occs.map(o => { const on = focus.finished.includes(o.id); return `<div class="crow ${on ? 'done' : ''}">
          <button class="checkbtn" data-act="focus-done" data-occ="${esc(o.id)}" style="${on ? `color:${color(o.task.color)}` : ''}">${ic(on ? 'checked' : 'circle')}</button>
          <div class="grow"><div class="title ellipsis">${esc(o.task.title)}</div><div class="meta"><span>${M.isHabit(o.task) ? 'Habit' : 'Task'}</span></div></div></div>`; }).join('')}</div>` : ''}
        ${bonusCard()}
        <div class="row">${pauseBtn()}<button class="btn" data-act="focus-more">${ic('plus')} 5 minutes</button><span class="grow"></span>
          <button class="btn danger" data-act="focus-end">End now</button></div>
        ${focus.pausedAt ? '<div class="small muted">On a break: the clock is stopped and time in other tabs doesn’t count as away until you resume.</div>' : ''}
      </div></div>`;
  } else {
    const open = store.todayChecklist().filter(o => !o.resolved);
    const pick = ui.focusPick ?? new Set(open.map(o => o.id));
    const mins = M.clampFocus(ui.focusMinutes ?? store.settings.focusMinutes ?? 25);
    const lengths = M.focusLengths(store.settings.focusLengths);
    const r = ui.focusResult;
    const unreflected = r ? [...(r.finishedIds || []), ...(r.bonusIds || [])].map(findOcc).filter(o => o && !o.resolved && !M.bonusUsedUp(o.task)) : [];
    const bonusOpen = store.openBonusTasks();
    const modeSeg = `<div class="seg" role="group" aria-label="Focus mode" style="max-width:440px">
      <button class="${workMode ? 'on' : ''}" data-act="focus-mode" data-m="work">${ic('target')} Work on one task</button>
      <button class="${workMode ? '' : 'on'}" data-act="focus-mode" data-m="sprint">${ic('timer')} Sprint through a list</button></div>`;
    body = `${modeSeg}${r ? `<div class="focus-result"><div class="fr-big">${r.finished}</div><div class="grow"><b>${r.mode === 'work'
        ? `${r.finished ? 'Done' : 'Stopped'}: ${esc(r.title || 'work')} after ${M.fmtFocusLength(Math.max(1, r.actualMinutes))}`
        : `Time! ${r.finished} of ${r.picked} done in ${r.actualMinutes} min`}</b>
        <div class="small muted">${r.focusPercent}% focused (${M.fmtDuration(r.awaySeconds)} away) · ×${M.focusMultiplier(r.focusPercent)} · <b class="green">+${r.points} points</b></div>
        ${r.bonus ? `<div class="small muted">${ic('star-fill')} Bonus: ${esc((r.bonusTitles || []).join(', '))} (+${M.BONUS_POINTS} each)</div>` : ''}
        ${unreflected.length ? `<div class="stack" style="gap:6px;margin-top:10px"><div class="small">Write a reflection for each to check it off:</div>
          ${unreflected.map(o => `<div class="row"><span class="grow ellipsis">${esc(o.task.title)}</span><button class="btn sm primary" data-act="toggle" data-occ="${esc(o.id)}">Reflect &amp; check off</button></div>`).join('')}</div>`
          : r.finished || r.bonus ? '<div class="small green" style="margin-top:6px">All reflected and checked off.</div>' : ''}</div>
        <button class="btn ghost sm icon" data-act="focus-dismiss" title="Close">${ic('x')}</button></div>` : ''}
      ${workMode ? workSetup(open, bonusOpen) : `<div class="card pad stack" style="gap:14px">
        <div><div class="section-title" style="margin:0 0 8px">${ic('timer')}How long?</div>
          <div class="row" style="flex-wrap:wrap">${lengths.map(n => `<span class="flen"><button class="btn ${mins === n ? 'primary' : ''}" data-act="focus-mins" data-m="${n}">${M.fmtFocusLength(n)}</button><button class="flen-x" data-act="focus-len-remove" data-m="${n}" title="Remove this length">${ic('x')}</button></span>`).join('')}
            <span class="flen-custom"><input class="input" type="number" min="1" max="${M.FOCUS_MAX_MINUTES}" style="width:80px" value="${mins}" data-bind="focusMinutes" title="Any length, in minutes"><span class="small muted">min</span></span>
            ${lengths.includes(mins) ? '' : `<button class="btn sm" data-act="focus-len-save" title="Add ${M.fmtFocusLength(mins)} to the length buttons">${ic('plus')} Save ${M.fmtFocusLength(mins)}</button>`}</div>
          <div class="tiny muted" style="margin-top:6px">Type any length up to ${M.FOCUS_MAX_MINUTES / 60} hours. Save it to keep it as a button; hover a button and click × to remove it.</div></div>
        <div><div class="section-title" style="margin:0 0 8px">${ic('list')}What will you get through? <span class="count">${pick.size}</span></div>
          ${open.length ? `<div class="focus-pick">${open.map(o => `<label class="check"><input type="checkbox" data-act-change="focus-pick" value="${esc(o.id)}" ${pick.has(o.id) ? 'checked' : ''}>
            <span class="ellipsis">${esc(o.task.title)}</span><span class="tiny muted">${M.isHabit(o.task) ? 'habit' : M.isUntilDone(o.task) ? 'until done' : 'today'}</span></label>`).join('')}</div>`
            : `<div class="muted">${bonusOpen.length ? 'Nothing open on today’s list, but there are bonus tasks.' : 'Nothing open on today’s list. Add a task first.'}</div>`}</div>
        ${bonusOpen.length ? `<div class="small muted">${ic('star')} Bonus: ${esc(bonusOpen.map(o => o.task.title).join(', '))}. They’re listed while the clock runs: tick off any you do for +${M.BONUS_POINTS} points each.</div>` : ''}
        <div class="row"><div class="small muted grow">Score: 10 points per task finished in time, ${M.BONUS_POINTS} per bonus task, ×1.5 if you stay 90% focused (×1.25 at 75%), +20 for clearing the list.</div>
          <button class="btn primary" data-act="focus-start" ${pick.size || bonusOpen.length ? '' : 'disabled'}>${ic('target')} Start ${M.fmtFocusLength(mins)} focus</button></div>
      </div>`}`;
  }
  return `<div class="header"><div class="grow"><h1>Focus</h1><div class="sub">${workMode && !focus.running
    ? 'Work on one thing: pick it, and it stays up front until you complete it. The Mac app also blocks distracting apps and sites.'
    : 'Race the clock: set a time, then see how much of your list you can finish before it runs out.'}</div></div></div>
    <div class="page stack" style="max-width:980px">
      ${levelCard}${body}
      ${sessions.length ? `<div><div class="section-title">${ic('clock')}Recent sessions</div><div class="card">${sessions.slice(0, 8).map(x => `<div class="crow">
        <span class="evt-time">${M.fmtDay(x.startedAt, { month: 'short', day: 'numeric' })}<small>${M.fmtTime(x.startedAt)}</small></span>
        <div class="grow"><div class="title ellipsis">${x.mode === 'work' ? `${x.finished ? 'Finished' : 'Worked on'} “${esc(x.title || 'a task')}” for ${M.fmtFocusLength(Math.max(1, x.actualMinutes))}` : `${x.finished} of ${x.picked} done in ${x.actualMinutes} min`}${x.bonus ? ` · ${x.bonus} bonus` : ''}</div>
          <div class="meta"><span>${x.focusPercent}% focused</span>${x.distractingSeconds ? `<span>${M.fmtDuration(x.distractingSeconds)} in distracting apps</span>` : ''}<span>${x.device === 'mac' ? 'Mac' : 'Web'}</span></div></div>
        <b class="green">+${x.points}</b></div>`).join('')}</div></div>` : ''}
    </div>`;
}

/** Focus › Work: pick one and it starts straight away. Most important first. */
function workSetup(open, bonus = []) {
  const rank = o => M.priorityRank(o.task);
  const list = open.filter(o => !o.event).map((o, i) => [o, i]).sort((a, b) => rank(a[0]) - rank(b[0]) || a[1] - b[1]).map(([o]) => o);
  return `<div class="card pad stack" style="gap:12px">
    <div class="section-title" style="margin:0">${ic('target')}What are you working on?</div>
    <div class="small muted">Click one and it starts straight away: it goes up front as your headline and the clock runs until you complete it. Time in other tabs and apps counts as away.</div>
    <div class="small muted">Score: 2 points for every 5 minutes you work (pauses don’t count), plus 10 for completing it, all ×1.5 if you stay 90% focused (×1.25 at 75%), and +20 when you complete it.</div>
    <form class="row" data-form="work-new"><input class="input grow" name="title" placeholder="Something else? Type it and press Enter" autocomplete="off"><button class="btn">Start</button></form>
    ${list.length ? `<div class="work-pick">${list.map(o => {
      const t = o.task, pr = M.priorityOf(t), hd = M.hardnessOf(t), typ = M.typicalMinutes(t);
      return `<button class="work-row" data-act="work-start" data-occ="${esc(o.id)}" title="Start working on this now">
        <span class="bar" style="background:${color(t.color)}"></span>
        <span class="grow"><span class="title ellipsis">${esc(t.title)}</span><span class="meta">${pr ? `<span class="prio prio-${pr}"><b>${'!'.repeat(3 - M.priorityRank(t))}</b>${PRIO_LABEL[pr]}</span>` : ''}${hd ? hardMeter(hd) : ''}${typ ? `<span>${ic('timer')}usually ${M.fmtMinutes(typ)}</span>` : ''}${o.overdue ? '<span class="red">Overdue</span>' : ''}${o.start ? `<span>${ic('clock')}${M.fmtTime(o.start)}</span>` : ''}</span></span>
        <span class="go">${ic('play')} Work on this</span></button>`;
    }).join('')}</div>` : '<div class="muted">Nothing open on today’s list.</div>'}
    ${bonus.length ? `<div class="section-title" style="margin:6px 0 0">${ic('star')}Bonus <span class="count">${bonus.length}</span>
        <span class="small muted" style="font-weight:400">optional · +${M.BONUS_POINTS} points when you finish one in a session</span></div>
      <div class="work-pick">${bonus.map(o => `<button class="work-row" data-act="work-start" data-occ="${esc(o.id)}" title="Start working on this now">
        <span class="bar" style="background:${color(o.task.color)}"></span>
        <span class="grow"><span class="title ellipsis">${esc(o.task.title)}</span><span class="meta"><span class="bonus-pts">${ic('star-fill')}+${M.BONUS_POINTS}</span><span>${esc(M.bonusSummary(o.task))}</span></span></span>
        <span class="go">${ic('play')} Work on this</span></button>`).join('')}</div>` : ''}</div>`;
}

/** Pause / Resume for a running session (sprint or work). */
const pauseBtn = () => `<button class="btn ${focus.pausedAt ? 'primary' : ''}" data-act="focus-pause" title="${focus.pausedAt ? 'Back to it' : 'Take a break: the clock stops and nothing counts until you resume'}">${ic(focus.pausedAt ? 'play' : 'pause')} ${focus.pausedAt ? 'Resume' : 'Pause'}</button>`;

/** While a sprint runs: the bonus tasks, to tick off each time you do one (up to its limit). */
function bonusCard() {
  const list = store.bonusTasks().filter(o => !o.done || bonusDone(o.task.id));
  if (!list.length) return '';
  return `<div><div class="section-title" style="margin:0 0 6px">${ic('star')}Bonus <span class="small muted" style="font-weight:400">optional · +${M.BONUS_POINTS} points each, times your focus</span></div>
    <div class="card">${list.map(o => {
      const t = o.task, n = bonusDone(t.id), can = canTickBonus(t), mine = (focus.bonusTicks || []).includes(t.id), left = M.bonusLeft(t);
      return `<div class="crow">
        <button class="checkbtn bonus-btn ${n ? 'on' : ''}" data-act="bonus-tick" data-task="${t.id}" ${can ? '' : 'disabled'} title="${can ? (n ? 'Did it again' : `Did it: +${M.BONUS_POINTS} points`) : 'That’s its limit'}">${ic(n ? 'star-fill' : 'star')}</button>
        <div class="grow"><div class="title ellipsis">${esc(t.title)}</div><div class="meta"><span>${left == null ? 'no limit' : left === 0 ? 'used up' : `${left} left`}</span></div></div>
        ${n ? `<b class="bonus-pts mono">×${n} +${n * M.BONUS_POINTS}</b>` : ''}
        ${mine ? `<button class="btn ghost sm" data-act="bonus-untick" data-task="${t.id}" title="Take one back">−1</button>` : ''}</div>`;
    }).join('')}</div></div>`;
}

/** Focus › Work while it runs: the task as a headline, the clock counting up, and Complete. */
function workingView() {
  const o = findOcc(focus.workId);
  const t = o?.task ?? { title: focus.title || 'Your task', color: 'blue' };
  const pr = M.priorityOf(t), hd = M.hardnessOf(t), typ = M.typicalMinutes(t);
  const target = typ || (t.timeMinutes != null ? t.durationMinutes : null);
  const others = store.todayChecklist().filter(x => !x.resolved && !x.event && x.id !== focus.workId);
  const otherBonus = store.openBonusTasks().filter(x => x.task.id !== o?.task.id);
  const credited = (focus.bonusCredited || []).length;
  const elapsedMin = focusElapsed() / 60_000;
  return `<div class="header"><div class="grow"><h1>Focus</h1><div class="sub">Working on one thing until it’s done.</div></div></div>
    <div class="page stack" style="max-width:980px">
      <div class="work-head" style="border-left-color:${color(t.color)}">
        <div class="kicker">Now working on</div>
        <h2 class="headline">${esc(t.title)}</h2>
        <div class="meta">${M.isBonus(t) ? `<span class="bonus-pts">${ic('star-fill')}Bonus · +${M.BONUS_POINTS} points</span>` : ''}${credited ? `<span>${ic('star')}${credited} bonus done on the side</span>` : ''}${pr ? `<span class="prio prio-${pr}"><b>${'!'.repeat(3 - M.priorityRank(t))}</b>${PRIO_LABEL[pr]} priority</span>` : ''}${hd ? `<span>${hardMeter(hd)} ${M.HARDNESS[hd - 1]}</span>` : ''}${typ ? `<span>${ic('timer')}usually ${M.fmtMinutes(typ)}</span>` : ''}${o?.overdue ? '<span class="red">Overdue</span>' : ''}</div>
        ${t.notes ? `<div class="muted notes">${esc(t.notes)}</div>` : ''}
        ${o && M.habitSteps(t).length ? stepList(o, 'work') : ''}
        <div class="row" style="gap:28px;align-items:center;flex-wrap:wrap">
          <div><div class="work-clock ${focus.pausedAt ? 'paused' : ''}" data-focus-clock>${workClock()}</div>${focus.pausedAt
            ? `<div class="small paused-tag">${ic('pause')} Paused · on a break for <span data-pause-clock>${pauseClock()}</span></div>`
            : `<div class="small muted">away <span data-focus-away>${M.fmtDuration(awayNow() / 1000)}</span></div>`}
            <div class="small green mono" title="2 points for every 5 minutes, times your focus multiplier. Completing it adds more.">+<span data-work-points>${workTimePoints()}</span> points for time so far</div></div>
          ${target ? `<div class="grow" style="max-width:320px"><div class="progress"><div data-work-bar data-target="${target}" style="width:${Math.min(100, (elapsedMin / target) * 100)}%"></div></div>
            <div class="small muted" style="margin-top:4px">${elapsedMin > target ? `Past the ${M.fmtMinutes(target)} it usually takes` : `It usually takes ${M.fmtMinutes(target)}`}</div></div>` : ''}
        </div>
        <div class="row" style="gap:8px;flex-wrap:wrap">
          <button class="btn primary" data-act="work-complete" title="Check it off: you’ll write the reflection, with the time already filled in">${ic('check')} Complete</button>
          ${pauseBtn()}
          ${others.length || otherBonus.length ? `<select class="input" style="width:auto" data-work-switch aria-label="Switch task"><option value="">Switch task…</option>${others.map(x => `<option value="${esc(x.id)}">${esc(x.task.title)}</option>`).join('')}
            ${otherBonus.length ? `<optgroup label="Bonus">${otherBonus.map(x => `<option value="${esc(x.id)}">${esc(x.task.title)}</option>`).join('')}</optgroup>` : ''}</select>` : ''}
          <span class="grow"></span>
          <button class="btn danger" data-act="work-stop" title="Stop without checking it off (the time is still logged)">Stop</button>
        </div>
      </div>
    </div>`;
}

// ---------- Screen time ----------
// Measured by the Cadence Mac app (which apps were in front while you used your Mac); each Mac syncs one
// summary per day. The web shows them and keeps the settings (distracting apps, limits) that every device uses.
function screenSummary(day) {
  const recs = store.screenDays(day), apps = new Map();
  for (const r of recs) for (const a of r.apps || []) apps.set(a.name, (apps.get(a.name) || 0) + a.seconds);
  const distracting = new Set((store.settings.distractingApps || []).map(x => x.toLowerCase()));
  const list = [...apps].map(([name, seconds]) => ({ name, seconds, distracting: distracting.has(name.toLowerCase()) })).sort((a, b) => b.seconds - a.seconds);
  return { has: recs.length > 0, total: recs.reduce((n, r) => n + (r.totalSeconds || 0), 0), distracting: list.filter(a => a.distracting).reduce((n, a) => n + a.seconds, 0), apps: list };
}

function screenTimeView() {
  const s = store.settings, today = screenSummary(new Date());
  const days = [...Array(7)].map((_, i) => M.addDays(M.startOfDay(new Date()), i - 6)).map(d => ({ d, ...screenSummary(d) }));
  const max = Math.max(1, ...days.map(x => x.total));
  const sel = (key, value) => `<select class="input" style="width:auto" data-setting="${key}">${[[0, 'Off'], [30, '30 min'], [60, '1 hour'], [90, '1.5 hours'], [120, '2 hours'], [180, '3 hours'], [240, '4 hours'], [360, '6 hours'], [480, '8 hours']]
    .map(([v, l]) => `<option value="${v}" ${Number(value) === v ? 'selected' : ''}>${l}</option>`).join('')}</select>`;
  const over = (sec, lim) => lim && sec > lim * 60;
  return `<div class="header"><div class="grow"><h1>Screen Time</h1><div class="sub">Where your computer time goes, so focus time and habits can use it.</div></div></div>
    <div class="page stack" style="max-width:980px">
      ${!today.has && !days.some(x => x.has) ? `<div class="callout"><span class="big">${ic('monitor')}</span><div class="grow"><b>Screen time comes from the Cadence Mac app</b>
        <div class="small muted">A website can’t see what other apps you use. In the Mac app, open Screen Time and turn on tracking: it records how long each app is in front while you’re using your Mac, and the daily totals show up here and on every device.</div></div></div>` : ''}
      <div class="stats">
        <div class="stat" style="background:${tint('#5ac8fa', .12)}"><span style="color:#5ac8fa">${ic('monitor')}</span><div><b class="${over(today.total, s.screenLimitMinutes) ? 'red' : ''}">${today.has ? M.fmtDuration(today.total) : '—'}</b><span class="small muted">today${s.screenLimitMinutes ? ` · limit ${M.fmtDuration(s.screenLimitMinutes * 60)}` : ''}</span></div></div>
        <div class="stat" style="background:${tint('#e4685f', .1)}"><span style="color:#e4685f">${ic('alert')}</span><div><b class="${over(today.distracting, s.distractingLimitMinutes) ? 'red' : ''}">${today.has ? M.fmtDuration(today.distracting) : '—'}</b><span class="small muted">distracting${s.distractingLimitMinutes ? ` · limit ${M.fmtDuration(s.distractingLimitMinutes * 60)}` : ''}</span></div></div>
        <div class="stat" style="background:${tint('#30d158', .1)}"><span style="color:#30d158">${ic('target')}</span><div><b>${M.fmtDuration(store.focusSessions.filter(x => M.isToday(x.startedAt)).reduce((n, x) => n + (x.actualMinutes || 0) * 60, 0))}</b><span class="small muted">in focus sessions today</span></div></div>
        <div class="stat" style="background:${tint('#5e5ce6', .1)}"><span style="color:#5e5ce6">${ic('week')}</span><div><b>${days.some(x => x.has) ? M.fmtDuration(days.reduce((n, x) => n + x.total, 0) / Math.max(1, days.filter(x => x.has).length)) : '—'}</b><span class="small muted">daily average (7 days)</span></div></div></div>
      ${days.some(x => x.has) ? `<div class="card pad"><div class="section-title" style="margin:0 0 10px">${ic('week')}Last 7 days</div>
        <div class="st-week">${days.map(x => `<div class="st-day" title="${M.fmtDay(x.d, { weekday: 'long' })}: ${M.fmtDuration(x.total)} (${M.fmtDuration(x.distracting)} distracting)">
          <div class="st-col"><div class="st-bar" style="height:${100 * x.total / max}%"><div class="st-dis" style="height:${x.total ? 100 * x.distracting / x.total : 0}%"></div></div></div>
          <div class="tiny muted">${M.WEEKDAY_SHORT[x.d.getDay()]}</div><div class="tiny">${x.has ? M.fmtDuration(x.total) : ''}</div></div>`).join('')}</div>
        <div class="tiny muted" style="margin-top:6px"><span class="st-key"></span> all apps <span class="st-key dis"></span> distracting</div></div>` : ''}
      ${today.apps.length ? `<div class="card pad"><div class="section-title" style="margin:0 0 10px">${ic('list')}Today by app <span class="small muted" style="font-weight:400">click one to mark it distracting</span></div>
        ${today.apps.slice(0, 12).map(a => `<div class="st-app ${a.distracting ? 'dis' : ''}" data-act="toggle-distracting" data-app="${esc(a.name)}" title="${a.distracting ? 'Distracting — click to unmark' : 'Click to mark as distracting'}">
          <span class="ellipsis" style="width:160px">${esc(a.name)}</span><div class="grow st-track"><div style="width:${100 * a.seconds / today.apps[0].seconds}%"></div></div>
          <span class="small" style="width:64px;text-align:right">${M.fmtDuration(a.seconds)}</span>${a.distracting ? `<span class="tiny red">distracting</span>` : '<span class="tiny muted" style="visibility:hidden">distracting</span>'}</div>`).join('')}</div>` : ''}
      <div><h3 style="margin:6px 0">Focus settings</h3><div class="card">
        <div class="srow"><div>Daily screen-time limit<div class="small muted">The Mac app nudges you once you go past it.</div></div>${sel('screenLimitMinutes', s.screenLimitMinutes)}</div>
        <div class="srow"><div>Daily limit for distracting apps</div>${sel('distractingLimitMinutes', s.distractingLimitMinutes)}</div>
        <div class="srow" style="flex-wrap:wrap"><div class="grow">Distracting apps<div class="small muted">During a focus session, the Mac app nudges you back when one of these comes to the front, and time in them lowers your focus score.</div>
          <div class="chips" style="margin-top:8px">${(s.distractingApps || []).map(a => `<span class="chip-x">${esc(a)}<button data-act="toggle-distracting" data-app="${esc(a)}" title="Remove">${ic('x')}</button></span>`).join('') || '<span class="small muted">None yet.</span>'}</div></div>
          <form class="row" data-form="distracting"><input class="input" name="app" placeholder="App name, e.g. YouTube" style="width:200px"><button class="btn">${ic('plus')} Add</button></form></div>
      </div></div>
    </div>`;
}

// ---------- Week ----------
function calItemsTimed(day) {
  const items = [];
  for (const o of store.visibleOccurrencesOn(day)) if (o.start && (!M.isUntilDone(o.task) || M.untilDoneWeekDay(o))) items.push({ kind: o.event ? 'event' : 'task', o, ud: M.isUntilDone(o.task) && !o.resolved, start: o.start, end: o.end, title: o.task.title, color: color(o.task.color), done: o.done, missed: o.missed, id: `t|${o.id}` });
  for (const e of store.visibleGoogleEventsOn(day)) if (!e.isAllDay) items.push({ kind: 'google', e, start: e.startDate, end: e.endDate, title: e.title, color: e.colorHex || '#0a84ff', done: false, id: `g|${e.id}` });
  items.sort((a, b) => a.start - b.start || b.end - a.end);
  // Greedy lanes inside clusters of overlapping items.
  const out = []; let cluster = [], laneEnds = [], clusterEnd = 0;
  const flush = () => { for (const p of cluster) p.lanes = Math.max(1, laneEnds.length); out.push(...cluster); cluster = []; laneEnds = []; };
  for (const p of items) {
    if (p.start >= clusterEnd) flush();
    let lane = laneEnds.findIndex(e => e <= p.start);
    if (lane < 0) { lane = laneEnds.length; laneEnds.push(p.end); } else laneEnds[lane] = p.end;
    p.lane = lane; cluster.push(p); clusterEnd = Math.max(clusterEnd, +p.end);
  }
  flush();
  return out;
}

const chipFor = it => `<div class="chip ${ui.weekSel?.has(it.id) ? 'picked' : ''} ${it.done ? 'done' : ''} ${it.missed ? 'missed' : ''}" style="background:${tint(it.color, it.kind === 'task' ? .18 : .12)}" data-act="detail" data-item="${esc(it.id)}">
  ${it.ud ? `<span class="flame">${ic('flame')}</span>` : it.kind !== 'task' ? `<span style="color:${it.color}">${ic('cal')}</span>` : `<span class="dot" style="border-color:${it.color};background:${it.done ? it.color : 'transparent'}"></span>`}
  <span>${it.start && it.kind !== 'allday' ? `<span class="muted">${M.fmtTime(it.start)}</span> ` : ''}${esc(it.title)}</span></div>`;

function allDayItems(day) {
  return [
    ...store.visibleOccurrencesOn(day).filter(o => !o.start && (!M.isUntilDone(o.task) || M.untilDoneWeekDay(o))).map(o => ({ kind: o.event ? 'event' : 'task', o, ud: M.isUntilDone(o.task) && !o.resolved, title: o.task.title, color: color(o.task.color), done: o.done, missed: o.missed, id: `t|${o.id}` })),
    ...store.visibleGoogleEventsOn(day).filter(e => e.isAllDay).map(e => ({ kind: 'google', e, title: e.title, color: e.colorHex || '#0a84ff', id: `g|${e.id}` })),
  ];
}

/** Split a checklist into what's on for the day and the tasks that stay until done (with a subheading). */
function splitUntilDone(items) {
  const habits = items.filter(o => M.isHabit(o.task));
  const daily = items.filter(o => !M.isHabit(o.task) && !M.isUntilDone(o.task)), ongoing = items.filter(o => !M.isHabit(o.task) && M.isUntilDone(o.task));
  return [[null, daily], ...(habits.length ? [['Habits', habits]] : []), ...(ongoing.length ? [['Until done', ongoing]] : [])];
}

// ---------- Week: pick several tasks and change them together ----------
function weekPicked() { return [...(ui.weekSel || new Map()).keys()].map(id => findOcc(id.slice(2))).filter(Boolean); }
function weekSelBar(days) {
  const n = ui.weekSel?.size || 0;
  if (!ui.weekSelecting && !n) return '';
  const pick = n ? '' : `${days.map(d => `<button class="btn sm" data-act="sel-day" data-day="${M.dateKey(d)}">${M.WEEKDAY_SHORT[d.getDay()]}</button>`).join('')}<button class="btn sm" data-act="sel-week">Whole week</button>`;
  const acts = !n ? '' : `<button class="btn sm" data-act="sel-checkoff">${ic('check')} Check off</button>
    <button class="btn sm" data-act="sel-mode" data-v="untilDone">${ic('flame')} Until done</button>
    <button class="btn sm" data-act="sel-mode" data-v="">Just on its day</button>
    <button class="btn sm" data-act="sel-urgent" data-v="1">Urgent</button><button class="btn sm" data-act="sel-urgent" data-v="">Not urgent</button>
    <select class="input sm" style="width:auto" data-sel-color><option value="">Color…</option>${Object.keys(M.COLORS).map(c => `<option value="${c}">${c[0].toUpperCase() + c.slice(1)}</option>`).join('')}</select>
    <select class="input sm" style="width:auto" data-sel-priority><option value="">Priority…</option>${M.PRIORITIES.map(([k, l]) => `<option value="${k}">${l}</option>`).join('')}<option value="none">None</option></select>
    <select class="input sm" style="width:auto" data-sel-hardness><option value="">Hardness…</option>${M.HARDNESS.map((l, i) => `<option value="${i + 1}">${i + 1} · ${l}</option>`).join('')}<option value="none">Not rated</option></select>
    <select class="input sm" style="width:auto" data-sel-move><option value="">Move…</option><option value="-1">1 day earlier</option><option value="1">1 day later</option><option value="7">1 week later</option></select>
    <button class="btn sm danger" data-act="sel-del" data-scope="one">${ic('trash')} Only these days</button>
    <button class="btn sm danger" data-act="sel-del" data-scope="later">These and later</button>
    <button class="btn sm danger" data-act="sel-del" data-scope="all">Whole tasks…</button>`;
  return `<div class="week-selbar"><b>${n ? `${n} picked` : 'Click tasks to pick them, or pick a whole day:'}</b>${pick}${acts}<span class="grow"></span>
    ${n ? '<button class="btn sm" data-act="sel-clear">Clear</button>' : ''}<button class="btn sm" data-act="sel-done">Done</button></div>`;
}
function selPickDay(d) {
  ui.weekSel ??= new Map();
  for (const o of store.visibleOccurrencesOn(d)) if (!o.resolved && !o.event && (!M.isUntilDone(o.task) || M.untilDoneWeekDay(o))) ui.weekSel.set(`t|${o.id}`, true);
}
function selTasks() { return [...new Set(weekPicked().map(o => o.task.id))].map(id => store.tasks.get(id)).filter(Boolean); }
function selEdit(fn, msg) {
  pushWeekUndo();
  const before = selTasks().map(t => structuredClone(t));
  for (const t of before) { const c = structuredClone(t); fn(c); store.upsertTask(c); }
  ui.weekSel = new Map(); render();
  toast(msg, { icon: 'check', undo: () => { before.forEach(t => store.upsertTask(t)); render(); } });
}

/** The week calendar's focus strip (focus, work and study time down the left of each day). On unless turned off. */
function weekShowsFocus() {
  if (ui.weekFocus != null) return ui.weekFocus;
  try { return localStorage.getItem('cadence:weekFocus') !== '0'; } catch { return true; }
}
const fmtHM = m => (m < 60 ? `${m}m` : m % 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m / 60}h`);
function focusMarks(d) {
  const blocks = store.focusBlocks(d);
  if (M.isToday(d) && focus.running) {
    // Pauses are gaps, like on finished sessions.
    for (const [a, b] of M.focusSegments(focus.startedAt, focusNow(), focus.pauses)) {
      if (b - a >= 60_000) blocks.push({ id: `live-${a}`, start: new Date(a), end: new Date(b), kind: isWorking() ? 'work' : 'focus', title: `${isWorking() ? focus.title : 'Focus sprint'} (${focus.pausedAt ? 'paused' : 'now'})` });
    }
  }
  const day0 = M.startOfDay(d);
  return blocks.map(b => {
    const top = ((b.start - day0) / 3_600_000) * HOUR, h = Math.max(3, ((b.end - b.start) / 3_600_000) * HOUR);
    return `<div class="fmark k-${b.kind}" style="top:${top}px;height:${h}px" title="${M.FOCUS_KINDS[b.kind]}: ${esc(b.title)} · ${M.fmtTime(b.start)}–${M.fmtTime(b.end)} (${M.fmtMinutes(M.blockMinutes(b))})"></div>`;
  }).join('');
}

function weekView() {
  const days = [...Array(7)].map((_, i) => M.addDays(ui.weekStart, i));
  const showFocus = weekShowsFocus(), lane = showFocus ? 7 : 0;
  const weekMins = days.reduce((t, d) => { const m = store.focusMinutes(d); t.focus += m.focus; t.study += m.study; return t; }, { focus: 0, study: 0 });
  const weekSub = showFocus && weekMins.focus + weekMins.study
    ? `${[weekMins.focus ? `${fmtHM(weekMins.focus)} focused` : '', weekMins.study ? `${fmtHM(weekMins.study)} studied` : ''].filter(Boolean).join(', ')} this week. ` : '';
  store.ensureGoogle(days[0], M.addDays(days[6], 1));
  const end = days[6];
  const title = `${M.fmtDay(days[0], { month: 'short', day: 'numeric' })} – ${M.fmtDay(end, { month: days[0].getMonth() === end.getMonth() ? undefined : 'short', day: 'numeric' })}, ${end.getFullYear()}`;
  const now = new Date();
  return `<div class="week">
    <div class="header"><div class="grow"><h1>${title}</h1><div class="sub">${weekSub}Double-click an empty slot — or inside an existing block — to add a task at that time.</div></div>
      <div class="row"><button class="btn ${showFocus ? 'primary' : ''}" data-act="week-focus" title="Show the time you spent focusing (purple), working on a task (blue) and studying (green) down the left of each day" aria-pressed="${showFocus}">${ic('target')} Focus time</button><button class="btn ${ui.weekSelecting ? 'primary' : ''}" data-act="sel-toggle" title="Pick several tasks to change them all at once. You can also ⌘/Ctrl- or Shift-click tasks, or Shift-drag a box around them.">${ic('check')} Select</button>${calendarsMenu()}<button class="btn" data-act="new-event">${ic('cal')} New event</button><button class="btn icon" data-act="week-prev" title="Previous week">${ic('left')}</button>
      <button class="btn" data-act="week-today">Today</button><button class="btn icon" data-act="week-next" title="Next week">${ic('right')}</button></div></div>
    ${weekSelBar(days)}
    <div class="week-head"><div></div>${days.map(d => {
      const open = store.tasksOn(d).filter(o => !o.resolved).length;
      const fm = showFocus ? store.focusMinutes(d) : { focus: 0, study: 0 };
      return `<div class="d ${M.isToday(d) ? 'today' : ''}"><div class="dow">${M.WEEKDAY_SHORT[d.getDay()].toUpperCase()}</div><div class="num">${d.getDate()}</div><div class="open">${open ? `${open} open` : ''}</div>
        ${showFocus ? `<div class="ftot" ${fm.focus + fm.study ? `title="${[fm.focus ? `Focused ${fmtHM(fm.focus)}` : '', fm.study ? `studied ${fmtHM(fm.study)}` : ''].filter(Boolean).join(', ')}"` : ''}>${fm.focus + fm.study ? `${ic('target')}${fmtHM(fm.focus + fm.study)}` : ''}</div>` : ''}</div>`;
    }).join('')}</div>
    <div class="week-allday"><div class="lab">any<br>time</div>${days.map(d => {
      const items = allDayItems(d);
      return `<div class="cell" data-day="${M.dateKey(d)}">${items.slice(0, items.length > 4 ? 3 : 4).map(chipFor).join('')}${items.length > 4 ? `<div class="more">+${items.length - 3} more</div>` : ''}</div>`;
    }).join('')}</div>
    <div class="week-scroll" id="weekScroll"><div class="week-grid" style="height:${24 * HOUR}px">
      <div class="hours">${[...Array(24)].map((_, h) => `<div class="h">${h ? M.fmtTimeMinutes(h * 60) : ''}</div>`).join('')}</div>
      ${days.map(d => `<div class="wcol ${M.isToday(d) ? 'today' : ''}" data-day="${M.dateKey(d)}">
        ${showFocus ? focusMarks(d) : ''}
        ${calItemsTimed(d).map(p => {
          const dayStart = M.startOfDay(d);
          const top = Math.max(0, (p.start - dayStart) / 3_600_000) * HOUR;
          const bottom = Math.min(24, (p.end - dayStart) / 3_600_000) * HOUR;
          return `<div class="block ${ui.weekSel?.has(p.id) ? 'picked' : ''} ${p.done ? 'done' : ''} ${p.missed ? 'missed' : ''} ${p.kind !== 'task' ? 'evt' : ''} ${busyOf(p) ? '' : 'free'}" data-item="${esc(p.id)}" data-start="${+p.start}" data-end="${+p.end}"
            title="${busyOf(p) ? 'Closed' : 'Open (just for info)'} · click for details · double-click to add a task at this time"
            style="top:${top}px;height:${Math.max(20, bottom - top - 1)}px;left:calc(${lane}px + (100% - ${lane}px) * ${p.lane / p.lanes} + 2px);width:calc((100% - ${lane}px) / ${p.lanes} - 4px);
            background:${tint(p.color, p.done ? .1 : p.kind !== 'task' ? .14 : .24)};border-color:${p.color}">
            <b>${p.ud ? `<span class="flame">${ic('flame')}</span> ` : p.kind !== 'task' ? `${ic('cal')} ` : ''}${esc(p.title)}</b>${M.fmtTime(p.start)}</div>`;
        }).join('')}
        ${M.isToday(d) ? `<div class="nowline" style="top:${M.minutesOf(now) / 60 * HOUR}px"></div>` : ''}
      </div>`).join('')}
    </div></div>
  </div>`;
}

// ---------- Month ----------
function monthView() {
  const first = M.startOfWeek(ui.month);
  const days = [...Array(42)].map((_, i) => M.addDays(first, i));
  store.ensureGoogle(days[0], M.addDays(days[41], 1));
  const cells = days.map(d => {
    const items = [
      ...store.visibleOccurrencesOn(d).filter(o => !M.isUntilDone(o.task) || M.untilDoneMarker(o)).map(o => ({ kind: o.event ? 'event' : 'task', title: o.task.title, color: color(o.task.color), done: o.done, missed: o.missed, id: `t|${o.id}` })),
      ...store.visibleGoogleEventsOn(d).map(e => ({ kind: 'google', title: e.title, color: e.colorHex || '#0a84ff', id: `g|${e.id}` })),
    ];
    const max = 4, shown = items.length > max ? max - 1 : max;
    const tasks = store.tasksOn(d);
    const allDone = tasks.length && tasks.every(o => o.done);
    return `<div class="mcell ${d.getMonth() !== ui.month.getMonth() ? 'out' : ''} ${M.isToday(d) ? 'today' : ''} ${M.sameDay(d, ui.selectedDay) ? 'sel' : ''}" data-act="select-day" data-day="${M.dateKey(d)}">
      <div class="row"><span class="n">${d.getDate()}</span><span class="grow"></span>${allDone ? `<span class="green small" title="Everything done">${ic('check')}</span>` : ''}</div>
      ${items.slice(0, shown).map(it => `<div class="chip ${it.done ? 'done' : ''} ${it.missed ? 'missed' : ''}" style="background:${tint(it.color, .13)}">
        ${it.kind !== 'task' ? `<span style="color:${it.color}">${ic('cal')}</span>` : `<span class="dot" style="border-color:${it.color};background:${it.done ? 'transparent' : it.color}"></span>`}<span>${esc(it.title)}</span></div>`).join('')}
      ${items.length > shown ? `<div class="more">+${items.length - shown} more</div>` : ''}</div>`;
  }).join('');
  const sel = ui.selectedDay;
  const tasks = store.tasksOn(sel), events = scheduleOn(sel);
  return `<div class="month"><div class="month-main">
    <div class="header"><div class="grow"><h1>${M.fmtDay(ui.month, { month: 'long', year: 'numeric' })}</h1><div class="sub">Click a day to see it, double-click to add a task.</div></div>
      <div class="row">${calendarsMenu()}<button class="btn icon" data-act="month-prev">${ic('left')}</button><button class="btn" data-act="month-today">Today</button><button class="btn icon" data-act="month-next">${ic('right')}</button></div></div>
    <div class="dows">${M.WEEKDAY_SHORT.map(w => `<div>${w.toUpperCase()}</div>`).join('')}</div>
    <div class="mgrid">${cells}</div></div>
    <aside class="daypanel stack" style="gap:12px">
      <div><div class="muted">${M.fmtDay(sel, { weekday: 'long' })}</div><h2 style="margin:0">${M.fmtDay(sel, { month: 'long', day: 'numeric' })}</h2></div>
      <div class="row"><button class="btn" data-act="new-task" data-day="${M.dateKey(sel)}">${ic('plus')} Task</button>
        <button class="btn" data-act="new-event" data-day="${M.dateKey(sel)}">${ic('cal')} Event</button></div>
      ${!tasks.length && !events.length ? '<div class="muted">Nothing planned.</div>' : ''}
      ${tasks.length ? `<div><div class="section-title">Checklist <span class="count">${tasks.length}</span></div>${tasks.map(o => crow(o, { compact: true })).join('')}</div>` : ''}
      ${events.length ? `<div><div class="section-title">Events <span class="count">${events.length}</span></div>
        <div>${events.map(eventRow).join('')}</div></div>` : ''}
    </aside></div>`;
}

// ---------- To-Do ----------
function todoView() {
  const t = ui.todo;
  const match = title => !t.search || title.toLowerCase().includes(t.search.toLowerCase());
  let body = '';
  if (t.mode === 'checklist') {
    const overdue = store.overdue().filter(o => match(o.task.title));
    // Until-done tasks are listed once (in their own group), not again on every day they carry over to;
    // a repeating one still shows on the day its next one starts.
    const ongoing = store.tasksOn(new Date()).filter(o => !M.isHabit(o.task) && M.isUntilDone(o.task) && match(o.task.title) && (t.showCompleted || !o.resolved));
    const groups = [...Array(t.range)].map((_, i) => M.addDays(M.startOfDay(new Date()), i))
      .map(d => [d, store.tasksOn(d).filter(o => !M.isHabit(o.task) && match(o.task.title) && (t.showCompleted || !o.resolved)
        && (!M.isUntilDone(o.task) || (!M.isToday(d) && M.sameDay(M.repStartOn(o.task, d), d))))])
      .filter(([, list]) => list.length);
    const group = (title, icon, list, showDate) => `<div><div class="section-title">${ic(icon)}${title}
      <span class="small muted" style="font-weight:400">${list.filter(o => o.done).length}/${list.length} done</span></div>
      <div class="card">${list.map(o => crow(o, { showDate })).join('')}</div></div>`;
    if (overdue.length) body += group('Overdue', 'alert', overdue, true);
    if (ongoing.length) body += group('Until done', 'flame', ongoing, false);
    const bonus = store.bonusTasks().filter(o => match(o.task.title) && (t.showCompleted || !o.done));
    if (bonus.length) body += group('Bonus (optional)', 'star', bonus, false);
    for (const [d, list] of groups) {
      const title = M.isToday(d) ? 'Today' : M.daysBetween(new Date(), d) === 1 ? 'Tomorrow' : M.fmtDay(d, { weekday: 'long', month: 'short', day: 'numeric' });
      body += group(title, M.isToday(d) ? 'sun' : 'cal', list, false);
    }
    if (!body) body = empty('list', t.search ? 'No matches' : 'No tasks yet', t.search ? '' : 'Create a task with New Task. Tasks can repeat daily, on certain weekdays, monthly or yearly.');
  } else if (t.mode === 'events') {
    const days = [...Array(t.range)].map((_, i) => M.addDays(M.startOfDay(new Date()), i));
    for (const d of days) {
      const list = scheduleOn(d).filter(ev => match(ev.title));
      if (!list.length) continue;
      const title = M.isToday(d) ? 'Today' : M.daysBetween(new Date(), d) === 1 ? 'Tomorrow' : M.fmtDay(d, { weekday: 'long', month: 'short', day: 'numeric' });
      body += `<div><div class="section-title">${ic(M.isToday(d) ? 'sun' : 'cal')}${title}<span class="count">${list.length}</span></div><div class="card">${list.map(eventRow).join('')}</div></div>`;
    }
    if (!body) body = empty('cal', t.search ? 'No matches' : 'No upcoming events', t.search ? '' : 'Create one with New event, or connect Google Calendar or Calendly in Settings.');
  } else {
    const tasks = [...store.tasks.values()].filter(x => !x.archived && !M.isEvent(x) && !M.isHabit(x) && match(x.title));
    const untilDone = tasks.filter(x => M.isUntilDone(x)).sort((a, b) => b.startDate.localeCompare(a.startDate));
    const repeating = tasks.filter(x => !M.isUntilDone(x) && !M.isBonus(x) && x.recurrence.frequency !== 'none').sort((a, b) => a.title.localeCompare(b.title));
    const once = tasks.filter(x => !M.isUntilDone(x) && !M.isBonus(x) && x.recurrence.frequency === 'none').sort((a, b) => b.startDate.localeCompare(a.startDate));
    const bonus = tasks.filter(M.isBonus).sort((a, b) => M.bonusFinished(a) - M.bonusFinished(b) || String(b.createdAt).localeCompare(String(a.createdAt)));
    const row = x => {
      const next = M.nextOccurrence(x);
      const doneCount = Object.keys(x.completions || {}).length;
      const fin = M.isUntilDone(x) && M.finishOf(x), cst = M.isCycle(x) && M.cycleStatus(x);
      const bNext = M.isBonus(x) && !M.bonusFinished(x) && (!M.bonusRound(x, new Date()) || M.bonusUsedUp(x)) && M.bonusNextRound(x, new Date());
      const status = M.isBonus(x) ? `<span class="${M.bonusFinished(x) ? 'green' : ''}">${ic('star')}Bonus · ${M.bonusFinished(x) ? 'all done' : esc(M.bonusSummary(x))}</span>${M.bonusRepeatSummary(x) ? `<span>${ic('repeat')}${esc(M.bonusRepeatSummary(x))}</span>` : ''}${bNext ? `<span>${ic('right')}Next: ${M.fmtDay(bNext, { weekday: 'short', month: 'short', day: 'numeric' })}</span>` : ''}`
        : cst ? (cst.finished ? `<span class="green">${ic('check')}All ${cst.times} done</span>`
          : cst.nextStart ? `<span>${ic('clock')}Back ${M.fmtDay(cst.nextStart, { month: 'short', day: 'numeric' })} · round ${cst.round} of ${cst.times}</span>`
          : `<span>${ic('flame')}Round ${cst.round} of ${cst.times}</span>`)
        : M.isUntilDone(x) ? (fin ? (fin.missed ? `<span class="red">${ic('x')}Not done ${M.fmtDay(M.parseKey(fin.key), { month: 'short', day: 'numeric' })}</span>`
          : `<span class="green">${ic('check')}Done ${M.fmtDay(M.parseKey(fin.key), { month: 'short', day: 'numeric' })}</span>`)
          : M.pastDue(x) ? `<span class="red">${ic('alert')}Past due</span>` : `<span>${ic('flame')}Not done yet</span>`)
        : next ? `<span>${ic('right')}Next: ${M.fmtDay(next, { weekday: 'short', month: 'short', day: 'numeric' })}</span>`
        : x.recurrence.frequency === 'none' && !doneCount && M.startOfDay(x.startDate) < M.startOfDay(new Date()) ? `<span class="red">${ic('alert')}Overdue</span>`
        : doneCount ? `<span class="green">${ic('check')}Done</span>` : '';
      return `<div class="crow"><span class="dot" style="width:10px;height:10px;border-radius:50%;background:${color(x.color)}"></span>
        <div class="grow"><div class="title">${esc(x.title)}</div><div class="meta">
          ${M.isBonus(x) ? '' : `<span>${ic('repeat')}${esc(M.planSummary(x) || 'Once')}</span>
          <span>${ic('clock')}${x.timeMinutes != null ? M.fmtTimeMinutes(x.timeMinutes) : 'Any time'}</span>`}${status}
          ${x.recurrence.frequency !== 'none' && !M.isUntilDone(x) && !M.isBonus(x) ? `<span>${doneCount} done</span>` : ''}</div></div>
        <button class="btn sm" data-act="edit" data-task="${x.id}">Edit</button>
        <button class="btn ghost sm icon danger" data-act="delete-task" data-task="${x.id}" title="Delete task">${ic('trash')}</button></div>`;
    };
    if (untilDone.length) body += `<div><div class="section-title">${ic('flame')}Kept on your list until done <span class="count">${untilDone.length}</span></div><div class="card">${untilDone.map(row).join('')}</div></div>`;
    if (repeating.length) body += `<div><div class="section-title">${ic('repeat')}Recurring <span class="count">${repeating.length}</span></div><div class="card">${repeating.map(row).join('')}</div></div>`;
    if (once.length) body += `<div><div class="section-title">${ic('check')}One-time <span class="count">${once.length}</span></div><div class="card">${once.map(row).join('')}</div></div>`;
    if (bonus.length) body += `<div><div class="section-title">${ic('star')}Bonus <span class="count">${bonus.length}</span></div><div class="card">${bonus.map(row).join('')}</div></div>`;
    if (!body) body = empty('list', t.search ? 'No matches' : 'No tasks yet', '');
  }
  return `<div class="header"><div class="grow"><h1>To-Do List</h1><div class="sub">Every task in one place. Repeating things are habits now: they live on the <a href="/app/habits">Habits</a> page.</div></div>
    <div class="seg"><button class="${t.mode === 'checklist' ? 'on' : ''}" data-act="todo-mode" data-mode="checklist">Upcoming checklist</button>
    <button class="${t.mode === 'tasks' ? 'on' : ''}" data-act="todo-mode" data-mode="tasks">All tasks</button>
    <button class="${t.mode === 'events' ? 'on' : ''}" data-act="todo-mode" data-mode="events">Events</button></div></div>
    <div class="page stack">
      <div class="row" style="flex-wrap:wrap">
        <input id="todoSearch" class="input" style="max-width:260px" placeholder="Search" value="${esc(t.search)}" data-bind="todoSearch">
        ${t.mode !== 'tasks' ? `<select class="input" style="width:auto" data-bind="todoRange">
          ${[7, 14, 31].map(n => `<option value="${n}" ${t.range === n ? 'selected' : ''}>Next ${n} days</option>`).join('')}</select>
          ${t.mode === 'checklist' ? `<label class="check"><input type="checkbox" data-bind="todoCompleted" ${t.showCompleted ? 'checked' : ''}>Show completed</label>` : ''}` : ''}
        <span class="grow"></span>${t.mode === 'events' ? `<button class="btn" data-act="new-event">${ic('plus')} New event</button>` : `<button class="btn" data-act="new-task">${ic('plus')} New Task</button>`}</div>
      ${body}</div>`;
}

// ---------- Reflections ----------
function reflectionsView() {
  const all = store.sortedReflections();
  const q = ui.reflSearch.toLowerCase();
  const f = ui.reflFilter || 'all';
  const missedCount = all.filter(r => r.outcome === 'missed').length;
  const list = all.filter(r => (f === 'all' || (r.outcome || 'done') === f) && (!q || r.text.toLowerCase().includes(q) || r.taskTitle.toLowerCase().includes(q)));
  const words = all.reduce((n, r) => n + M.countWords(r.text), 0);
  const groups = new Map();
  for (const r of list) { const k = M.dateKey(r.createdAt); if (!groups.has(k)) groups.set(k, []); groups.get(k).push(r); }
  const stat = (v, l, icon, c) => `<div class="stat" style="background:${tint(c, .1)}"><span style="color:${c}">${ic(icon)}</span><div><b>${v}</b><span class="small muted">${l}</span></div></div>`;
  return `<div class="header"><div class="grow"><h1>Reflections</h1><div class="sub">A record of what you wrote each time you checked something off, or didn’t get to it.</div></div>
      <button class="btn" data-act="export-refl" ${all.length ? '' : 'disabled'}>${ic('copy')} Export</button></div>
    <div class="page stack">
      <div class="stats">${stat(all.length, 'reflections', 'quote', '#5e5ce6')}${stat(words, 'words written', 'text', '#30b0c7')}
        ${stat(store.reflectionStreak, store.reflectionStreak === 1 ? 'day streak' : 'days streak', 'flame', '#ff9f0a')}
        ${stat(new Set(all.map(r => r.taskID)).size, 'different tasks', 'stack', '#30d158')}</div>
      <div class="row" style="flex-wrap:wrap"><div class="seg">${[['all', 'All'], ['done', 'Done'], ['missed', `Didn’t do (${missedCount})`]].map(([k, l]) => `<button class="${f === k ? 'on' : ''}" data-act="refl-filter" data-f="${k}">${l}</button>`).join('')}</div>
        <input id="reflSearch" class="input grow" placeholder="Search reflections" value="${esc(ui.reflSearch)}" data-bind="reflSearch"></div>
      ${!all.length ? empty('quote', 'No reflections yet', `Each time you check off a task you’ll write a short reflection (at least ${store.settings.minReflectionWords} words). They collect here.`) : ''}
      ${[...groups].map(([k, rs]) => `<div><div class="section-title">${M.isToday(M.parseKey(k)) ? 'Today' : M.fmtDay(M.parseKey(k), { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })}</div>
        <div class="stack" style="gap:8px">${rs.map(r => {
          const t = store.tasks.get(r.taskID);
          const forDay = /^\d{4}-\d{2}-\d{2}$/.test(r.occurrenceKey) && r.occurrenceKey !== M.dateKey(r.createdAt) ? `<span class="small muted">for ${M.fmtDay(M.parseKey(r.occurrenceKey), { month: 'short', day: 'numeric' })}</span>` : '';
          return `<div class="card refl ${r.outcome === 'missed' ? 'missed' : ''}"><div class="row"><span style="width:8px;height:8px;border-radius:50%;background:${color(t?.color ?? 'gray')}"></span>
            <b>${esc(r.taskTitle)}</b>${r.outcome === 'missed' ? `<span class="tag-missed">${ic('x')} Didn’t do it</span>` : r.outcome === 'away' ? `<span class="tag-done">${ic('clock')} Away</span>` : r.outcome === 'decision' ? `<span class="tag-done">${ic('timer')} Kept going</span>` : `<span class="tag-done">${ic('check')} Done</span>`}${forDay}<span class="grow"></span>
            <span class="small muted">${M.countWords(r.text)} words · ${M.fmtTime(r.createdAt)}</span>
            <button class="btn ghost sm icon" data-act="copy-refl" data-id="${r.id}" title="Copy">${ic('copy')}</button>
            <button class="btn ghost sm icon danger" data-act="delete-refl" data-id="${r.id}" title="Delete">${ic('trash')}</button></div>
            <p>${esc(r.text)}</p></div>`;
        }).join('')}</div></div>`).join('')}
    </div>`;
}

// ---------- Booking: your open time over the next 7 days ----------
const OT_HOUR = 40;
const durLabel = ms => { const m = Math.round(ms / 60_000), h = Math.floor(m / 60); return h ? (m % 60 ? `${h}h ${m % 60}m` : `${h}h`) : `${m}m`; };
const busyOf = it => it.kind === 'google' ? !it.e.transparent : it.o.busy;

/** Each of the next 7 days: its items (closed or open), Google-only busy times, and the open time left. */
function openTimeDays() {
  const a = store.settings.availability, today = M.startOfDay(new Date());
  const days = [...Array(7)].map((_, i) => M.addDays(today, i));
  store.ensureGoogle(days[0], M.addDays(days[6], 1));
  const fb = ui.booking.busy.map(b => [+new Date(b.start), +new Date(b.end)]);
  return days.map(day => {
    const from = +day, to = +M.addDays(day, 1);
    const timed = calItemsTimed(day).map(p => ({ ...p, busy: busyOf(p) }));
    const allDay = allDayItems(day).map(it => ({ ...it, busy: busyOf(it) }));
    const blocked = timed.filter(p => p.busy).map(p => [+p.start, +p.end]);
    if (allDay.some(it => it.busy)) blocked.push([from, to]);
    // Google's free/busy also covers calendars and events Cadence doesn't show. Skip anything you've
    // marked open here (Google catches up a moment later) and anything already drawn.
    const openHere = new Set(timed.filter(p => !p.busy).map(p => `${+p.start}|${+p.end}`));
    const extra = [];
    for (const [bs, be] of fb) {
      const s = Math.max(bs, from), e = Math.min(be, to);
      if (e <= s || openHere.has(`${bs}|${be}`) || blocked.some(([x, y]) => x <= s && y >= e)) continue;
      extra.push([s, e]);
    }
    blocked.push(...extra);
    const open = M.openRanges(day, a, blocked);
    return { day, timed, allDay, extra, open, total: open.reduce((n, [s, e]) => n + e - s, 0) };
  });
}

async function loadBusy() {
  const b = ui.booking;
  if (!store.google.connected) { b.busy = []; return; }
  b.loading = true; render();
  try { b.busy = await store.freeBusy(new Date(), M.addDays(M.startOfDay(new Date()), 8)); }
  catch (e) { b.message = e.message; }
  b.loading = false; b.loadedFor = Date.now(); render();
}

function bookingView() {
  const b = ui.booking, a = store.settings.availability;
  if (store.google.connected && (!b.loadedFor || Date.now() - b.loadedFor > 120_000) && !b.loading) setTimeout(loadBusy);
  const week = openTimeDays();
  ui.booking.week = week;
  const total = week.reduce((n, d) => n + d.total, 0);
  // Hours shown: your open hours, stretched to fit anything scheduled outside them.
  let lo = a.startMinutes, hi = a.endMinutes;
  for (const d of week) for (const p of d.timed) {
    lo = Math.min(lo, M.minutesOf(p.start));
    hi = Math.max(hi, M.sameDay(p.end, d.day) ? M.minutesOf(p.end) : 1440);
  }
  const h0 = Math.floor(lo / 60), h1 = Math.max(h0 + 1, Math.ceil(hi / 60));
  const y = (day, t) => ((t - +day) / 3_600_000 - h0) * OT_HOUR;
  const clip = (day, s, e) => { const top = Math.max(0, y(day, s)), bot = Math.min((h1 - h0) * OT_HOUR, y(day, e)); return bot > top ? `top:${top}px;height:${Math.max(16, bot - top - 1)}px` : null; };
  const now = Date.now();
  const col = d => {
    const off = !a.weekdays.includes(M.weekday(d.day));
    const parts = [];
    if (off) parts.push(`<div class="ot-off" style="top:0;bottom:0"></div>`);
    else {
      const s = clip(d.day, +M.dayAt(d.day, h0 * 60), +M.dayAt(d.day, a.startMinutes)), e = clip(d.day, +M.dayAt(d.day, a.endMinutes), +M.addDays(d.day, 1));
      if (s) parts.push(`<div class="ot-off" style="${s}"></div>`);
      if (e) parts.push(`<div class="ot-off" style="${e}"></div>`);
    }
    if (M.isToday(d.day)) { const p = clip(d.day, +M.dayAt(d.day, h0 * 60), now); if (p) parts.push(`<div class="ot-past" style="${p}"></div>`); }
    for (const [s, e] of d.open) {
      const pos = clip(d.day, s, e);
      if (pos) parts.push(`<button class="ot-open" data-act="ot-book" data-s="${s}" data-e="${e}" style="${pos}" title="Open ${M.fmtTime(s)}–${M.fmtTime(e)} · click to book a time in it">
        <b>${M.fmtTime(s)}–${M.fmtTime(e)}</b><span>${durLabel(e - s)} open</span></button>`);
    }
    for (const [s, e] of d.extra) { const pos = clip(d.day, s, e); if (pos) parts.push(`<div class="ot-item closed gbusy" style="${pos};left:2px;right:2px" title="Busy in Google Calendar">Busy</div>`); }
    for (const p of d.timed) {
      const pos = clip(d.day, +p.start, +p.end);
      if (pos) parts.push(`<div class="ot-item ${p.busy ? 'closed' : 'open'}" data-act="detail" data-item="${esc(p.id)}" title="${esc(p.title)} · ${p.busy ? 'closed: blocks this time' : 'open: just for info'}"
        style="${pos};left:calc(${(p.lane * 100) / p.lanes}% + 2px);width:calc(${100 / p.lanes}% - 4px);--hue:${p.color}"><b>${esc(p.title)}</b>${M.fmtTime(p.start)}</div>`);
    }
    if (M.isToday(d.day)) { const t = y(d.day, now); if (t > 0 && t < (h1 - h0) * OT_HOUR) parts.push(`<div class="nowline" style="top:${t}px"></div>`); }
    return `<div class="ot-col ${M.isToday(d.day) ? 'today' : ''}" data-day="${M.dateKey(d.day)}" data-h0="${h0}" style="height:${(h1 - h0) * OT_HOUR}px">${parts.join('')}</div>`;
  };
  return `<div class="header"><div class="grow"><h1>Booking</h1><div class="sub">Your open time for the next 7 days. Click a green stretch to book it; click anything else to change it, or drag it to move it. Double-click a free spot to add an event.</div></div>
      ${calendarsMenu()}<button class="btn" data-act="busy-refresh" ${b.loading ? 'disabled' : ''}>${ic('refresh', b.loading ? 'spinning' : '')} Refresh</button>
      <button class="btn" data-act="copy-avail" ${total ? '' : 'disabled'}>${ic('copy')} Copy open times</button></div>
    <div class="page stack" style="max-width:1200px">
      ${!store.google.connected ? `<div class="callout warn"><span class="big">${ic('cal')}</span><div class="grow"><b>Google Calendar isn’t connected</b>
        <div class="small muted">Open time only accounts for what’s in Cadence, and bookings are saved as Cadence events without sending invites.</div></div>
        <a class="btn" href="/app/settings">Connect in Settings</a></div>` : ''}
      ${b.message ? `<div class="callout" style="background:${tint('#30d158', .12)}"><span class="big green">${ic('check')}</span><div class="grow">${esc(b.message)}</div></div>` : ''}
      <div class="ot-summary"><div><span class="ot-big">${durLabel(total)}</span> open this week</div><span class="grow"></span>
        <span class="small muted">Open hours: ${a.weekdays.map(w => M.WEEKDAY_SHORT[w - 1]).join(' ')} · ${M.fmtTimeMinutes(a.startMinutes)}–${M.fmtTimeMinutes(a.endMinutes)}</span>
        <button class="btn sm ${b.editHours ? 'primary' : ''}" data-act="ot-hours">${b.editHours ? 'Done' : 'Edit hours'}</button></div>
      ${b.editHours ? (() => {
        const times = (from, to) => { const o = []; for (let m = from; m <= to; m += 30) o.push(m); return o; };
        const sel = (key, opts, v) => `<select class="input sm" style="width:auto" data-setting="${key}">${opts.map(([o, l]) => `<option value="${o}" ${o === v ? 'selected' : ''}>${l}</option>`).join('')}</select>`;
        return `<div class="card pad row ot-hours-edit" style="flex-wrap:wrap;gap:14px">
          <div class="row" style="gap:6px"><span class="small muted">Days</span><div class="wd">${[1, 2, 3, 4, 5, 6, 7].map(w => `<button class="${a.weekdays.includes(w) ? 'on' : ''}" data-act="avail-day" data-w="${w}" title="${M.WEEKDAY_SHORT[w - 1]}">${M.WEEKDAY_LETTER[w - 1]}</button>`).join('')}</div></div>
          <div class="row" style="gap:6px"><span class="small muted">From</span>${sel('availability.startMinutes', times(300, 1260).map(m => [m, M.fmtTimeMinutes(m)]), a.startMinutes)}
            <span class="small muted">until</span>${sel('availability.endMinutes', times(420, 1410).map(m => [m, M.fmtTimeMinutes(m)]), a.endMinutes)}</div>
          <div class="row" style="gap:6px"><span class="small muted">Keep free around closed items</span>${sel('availability.bufferMinutes', [[0, 'None'], [5, '5 min'], [10, '10 min'], [15, '15 min'], [30, '30 min']], a.bufferMinutes)}</div>
          <span class="small muted">Changes apply right away and sync to your Mac.</span></div>`;
      })() : ''}
      <div class="ot-legend"><span><i class="sw open-time"></i>Open time</span><span><i class="sw closed"></i>Closed — blocks time</span>
        <span><i class="sw open"></i>Open — just for info</span><span><i class="sw off"></i>Outside your open hours</span></div>
      <div class="ot-wrap"><div class="ot">
        <div></div>${week.map(d => `<div class="ot-head ${M.isToday(d.day) ? 'today' : ''}"><div class="dow">${M.isToday(d.day) ? 'TODAY' : M.WEEKDAY_SHORT[d.day.getDay()].toUpperCase()}</div>
          <div class="num">${d.day.getDate()}</div><div class="small ${d.total ? 'green' : 'muted'}">${d.total ? `${durLabel(d.total)} open` : 'no open time'}</div></div>`).join('')}
        <div class="ot-lab">all<br>day</div>${week.map(d => `<div class="ot-allday">${d.allDay.map(it => `<div class="ot-chip ${it.busy ? 'closed' : 'open'}" style="--hue:${it.color}" data-act="detail" data-item="${esc(it.id)}" title="${it.busy ? 'Closed: blocks the whole day' : 'Open: just for info'}">${esc(it.title)}</div>`).join('')}</div>`).join('')}
        <div class="ot-hours">${[...Array(h1 - h0)].map((_, i) => `<div style="height:${OT_HOUR}px">${M.fmtTimeMinutes((h0 + i) * 60)}</div>`).join('')}</div>
        ${week.map(col).join('')}
      </div></div>
      ${store.calendly.connected && store.calendly.eventTypes.length ? `<div><div class="section-title">${ic('link')}Your Calendly links</div>
        <div class="small muted" style="margin:-4px 0 8px">Public links anyone can book from. Booked meetings land on your calendar automatically.</div>
        <div class="card">${store.calendly.eventTypes.map(t => `<div class="crow"><span style="width:10px;height:10px;border-radius:50%;background:${esc(t.color || '#bf5af2')}"></span>
          <div class="grow"><div class="title">${esc(t.name)}</div><div class="meta"><span>${t.minutes} min</span><span class="ellipsis">${esc(t.url)}</span></div></div>
          <button class="btn sm" data-act="copy-text" data-text="${esc(t.url)}">${ic('copy')} Copy link</button>
          <a class="btn sm icon" href="${esc(t.url)}" target="_blank" rel="noopener" title="Open">${ic('link')}</a></div>`).join('')}</div></div>` : ''}
      <div class="small muted">Closed items take their time out of your open time; open ones are just for info. Events you make in Cadence start out closed and tasks start out open — change it in any item’s editor. “Copy open times” puts the list on your clipboard to paste into an email.</div>
    </div>`;
}

// ---------- Settings ----------
/** Pushy and strict reminders. Strict covers the page and putting it off takes a reason. */
function nagDialog(m) {
  const o = m.occ, t = o.task, strict = m.level === 'strict', every = M.nagMinutes(t);
  const since = o.day < M.startOfDay(new Date()) ? `Overdue since ${M.fmtDay(o.day, { weekday: 'long', month: 'short', day: 'numeric' })}`
    : o.start ? `Was due at ${M.fmtTime(o.start)}` : t.dueDate ? `Due ${M.fmtDay(new Date(t.dueDate), { weekday: 'long', month: 'short', day: 'numeric' })}` : 'On today’s list';
  const putOff = m.putOff || [];
  return `<div class="dialog nag ${strict ? 'strict' : ''}"><div class="body">
    <div class="nag-ic ${strict ? 'red' : 'orange'}">${ic(strict ? 'lock' : 'alert')}</div>
    <div class="nag-kicker">Still not done</div>
    <h2 class="nag-title">${esc(t.title)}</h2>
    <div class="muted">${esc(since)} · reminder ${m.count}${m.count > 1 ? `, every ${every} min` : ''}</div>
    ${putOff.length ? `<div class="nag-log"><b>Put off ${putOff.length} time${putOff.length === 1 ? '' : 's'} today:</b>${putOff.slice(-3).map(p => `<div>${M.fmtTime(p.at)} — “${esc(p.reason)}”</div>`).join('')}</div>` : ''}
    ${strict ? '<div class="small muted">In the Cadence Mac app, your distracting apps and blocked websites stay blocked until this is done.</div>' : ''}
    <div class="row nag-actions"><button class="btn primary" data-act="nag-done" autofocus>${ic('check')} Check it off…</button><button class="btn" data-act="nag-open">Open Today</button></div>
    ${strict ? `<div class="nag-why"><label class="field"><span>Not now? Say why, in a few words.</span>
        <input class="input" id="nagWhy" value="${esc(m.why || '')}" placeholder="e.g. at dinner with family, back at 8" autocomplete="off"></label>
        <div class="row"><select class="input" id="nagMin" style="width:auto">${[10, 15, 30, 60].map(x => `<option value="${x}" ${(m.minutes || 15) === x ? 'selected' : ''}>${x === 60 ? '1 hour' : `${x} min`}</option>`).join('')}</select>
        <button class="btn" data-act="nag-snooze">Put it off</button>${m.error ? `<span class="error">${esc(m.error)}</span>` : ''}</div></div>`
      : `<div class="row nag-actions"><span class="small muted">Not now:</span>${[5, 10, 30, 60].map(x => `<button class="btn sm" data-act="nag-snooze" data-min="${x}">${x === 60 ? '1 hour' : `${x} min`}</button>`).join('')}</div>`}
  </div></div>`;
}

/** Settings › Tough love: a domain from whatever was typed ("https://www.youtube.com/watch…" → "youtube.com"). */
function addBlockedSite(raw) {
  let d = String(raw || '').trim().toLowerCase();
  try { d = new URL(d.includes('://') ? d : `https://${d}`).hostname; } catch { return; }
  d = d.replace(/^www\./, '');
  const list = store.settings.blockedSites || [];
  if (!d.includes('.') || list.includes(d)) return;
  store.updateSettings({ blockedSites: [...list, d] }); render();
}

/** The app's typeface. Stored on this device and applied before first paint (see app.html); same choices as the Mac and iPhone. */
const FONT_CHOICES = [['verdana', 'Verdana'], ['system', 'System'], ['helvetica', 'Helvetica'], ['georgia', 'Georgia'], ['mono', 'Menlo / monospace'], ['custom', 'Another font…']];
const currentFont = () => { try { return localStorage.getItem('cadence:font') || 'verdana'; } catch { return 'verdana'; } };
function setFont(v) {
  try { localStorage.setItem('cadence:font', v); } catch { /* private mode: still applies for this visit */ }
  const r = document.documentElement;
  if (v.startsWith('custom:')) { r.dataset.font = 'custom'; r.style.setProperty('--sans', `"${v.slice(7).replace(/[^\w .-]/g, '')}", Verdana, sans-serif`); }
  else { r.dataset.font = v; r.style.removeProperty('--sans'); }
}

/** Dark / light / match the system. Stored on this device and applied before first paint (see app.html). */
const currentTheme = () => { try { return localStorage.getItem('cadence:theme') || 'dark'; } catch { return 'dark'; } };
function setTheme(t) {
  try { localStorage.setItem('cadence:theme', t); } catch { /* private mode: still applies for this visit */ }
  document.documentElement.dataset.theme = t;
}

function settingsView() {
  const s = store.settings, g = store.google;
  const perm = 'Notification' in window ? Notification.permission : 'unsupported';
  const sel = (key, options, value) => `<select class="input" data-setting="${key}">${options.map(([v, l]) => `<option value="${v}" ${String(v) === String(value) ? 'selected' : ''}>${l}</option>`).join('')}</select>`;
  const tog = (key, label, value) => `<label class="check"><input type="checkbox" data-setting="${key}" data-type="bool" ${value ? 'checked' : ''}>${label}</label>`;
  const chans = key => `<div class="chans">${M.CHANNELS.map(([c, l, d]) => `<label class="check" title="${esc(d)}"><input type="checkbox" data-setting-set="${key}" value="${c}" ${s[key].includes(c) ? 'checked' : ''}>${l}</label>`).join('')}</div>`;
  const times = (from, to) => { const o = []; for (let m = from; m <= to; m += 30) o.push([m, M.fmtTimeMinutes(m)]); return o; };
  const a = s.availability;
  return `<div class="header"><div class="grow"><h1>Settings</h1><div class="sub">Settings marked “this device” stay on this browser; everything else syncs with the Mac app.</div></div></div>
  <div class="page settings">
    ${ui.flash ? `<div class="callout"><span class="big">${ic('check')}</span><div class="grow">${esc(ui.flash)}</div><button class="btn ghost sm" data-act="clear-flash">${ic('x')}</button></div>` : ''}
    <div><h3>Appearance</h3><div class="card">
      <div class="srow"><div>Theme<div class="small muted">This device. Dark is the default.</div></div>
        <select class="input" data-theme-pick>${[['dark', 'Dark'], ['light', 'Light'], ['system', 'Match the system']].map(([v, l]) => `<option value="${v}" ${currentTheme() === v ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
      <div class="srow"><div>Font<div class="small muted">This device. Verdana is the default; “Another font…” takes the name of any font installed on this computer.</div></div>
        <div class="row" style="justify-content:flex-end;flex-wrap:wrap">
          <select class="input" data-font-pick>${FONT_CHOICES.map(([v, l]) => `<option value="${v}" ${(currentFont().startsWith('custom:') ? 'custom' : currentFont()) === v ? 'selected' : ''}>${l}</option>`).join('')}</select>
          ${currentFont().startsWith('custom:') || ui.fontCustom ? `<form class="row" data-form="font-custom"><input class="input" id="fontName" placeholder="e.g. Avenir Next" value="${esc(currentFont().startsWith('custom:') ? currentFont().slice(7) : '')}" style="min-width:160px" autocomplete="off"><button class="btn">Use</button></form>` : ''}</div></div>
      <div class="srow"><div class="small muted" style="font-family:var(--sans)">The quick brown fox jumps over the lazy dog. 0123456789</div></div>
    </div></div>

    <div><h3>Tough love</h3><div class="card">
      <div class="srow"><div class="grow">For things you’d rather put off<div class="small muted">In a task’s editor, set <b>Persistent</b>, <b>Pushy</b> or <b>Strict</b> and it keeps after you until it’s checked off. Strict covers the screen and asks why when you put it off.</div></div></div>
      <div class="srow">${tog('blockDuringFocus', 'Block distracting apps and sites during focus and study sessions (Mac app)', s.blockDuringFocus)}</div>
      <div class="srow" style="flex-wrap:wrap"><div class="grow">Blocked websites<div class="small muted">The Cadence Mac app blocks these in Safari, Chrome, Arc, Brave, Edge, Vivaldi, Opera and Firefox (Firefox needs Accessibility access for Cadence) while a strict task is overdue (and during focus sessions if that’s on). A browser tab can’t block other sites, so this needs the Mac app.</div>
        <div class="chips" style="margin-top:8px">${(s.blockedSites || []).map(x => `<span class="chip-x">${esc(x)}<button data-act="site-remove" data-site="${esc(x)}" title="Remove">${ic('x')}</button></span>`).join('') || '<span class="small muted">None yet.</span>'}</div>
        <form class="row" data-form="site-add" style="margin-top:8px"><input class="input" id="siteNew" placeholder="e.g. youtube.com" style="max-width:240px" autocomplete="off"><button class="btn">Add</button>
          <select class="input" data-site-suggest style="width:auto"><option value="">Suggestions…</option>${['youtube.com', 'instagram.com', 'tiktok.com', 'reddit.com', 'x.com', 'facebook.com', 'netflix.com', 'twitch.tv'].filter(x => !(s.blockedSites || []).includes(x)).map(x => `<option>${x}</option>`).join('')}</select></form></div></div>
      <div class="srow"><div class="small muted">Blocked apps are the ones marked distracting on the Screen Time page.</div><a class="btn sm" href="/app/screentime">Screen Time</a></div>
    </div></div>

    <div><h3>AI check</h3><div class="card">
      <div class="srow"><div class="grow">Check that reflections are real<div class="small muted">Before a reflection is accepted, Google’s Gemini reads it and sends back keyboard mashing, padding and copy-paste. Honest short answers pass. If Gemini can’t be reached, it’s accepted as usual.</div></div>
        <label class="check"><input type="checkbox" data-act-change="ai-toggle" ${ai.on ? 'checked' : ''} ${ai.key ? '' : 'disabled'}>On</label></div>
      <div class="srow" style="flex-wrap:wrap">${ai.key
        ? `<div class="grow">${ic('lock')} Gemini API key saved in this browser</div><button class="btn sm danger" data-act="ai-remove">Remove key</button>`
        : `<form class="row grow" data-form="ai-key"><input class="input grow" type="password" name="key" placeholder="Paste your Gemini API key" autocomplete="off"><button class="btn">Save</button></form>`}</div>
      <div class="srow" style="flex-wrap:wrap"><label class="row grow" style="gap:8px">Model <input class="input" data-ai-model value="${esc(ai.model)}" placeholder="${DEFAULT_MODEL}" style="max-width:260px"></label>
        <button class="btn sm" data-act="ai-test" ${ai.key ? '' : 'disabled'}>Test</button><span class="small" id="aiTest">${esc(ui.aiTest || '')}</span></div>
      <div class="srow"><div class="small muted">Get a key at aistudio.google.com (API keys). It stays in this browser only: it isn’t sent to Cadence or synced, and reflection text goes to Google only while this is on.</div></div>
    </div></div>

    <div><h3>Account & sync</h3><div class="card">
      <div class="srow"><div>Signed in as <b>${esc(store.user.username)}</b><div class="small muted">You stay signed in on this browser until you sign out.</div></div><button class="btn" data-act="sign-out">${ic('logout')} Sign out</button></div>
      <div class="srow"><div>Sync<div class="small muted">Changes sync a moment after you make them, and every 20 seconds.</div></div>${syncControl('big')}</div>
      <div class="srow"><div>Your data<div class="small muted">Download everything Cadence stores for your account, as a JSON file.</div></div>
        <a class="btn" href="/api/account/export" download>${ic('copy')} Download my data</a></div>
      <div class="srow"><div>Delete account<div class="small muted">Permanently removes your account, tasks, reflections and connections from our servers.</div></div>
        <button class="btn danger" data-act="delete-account">${ic('trash')} Delete account…</button></div>
      <div class="srow"><div>Desktop apps<div class="small muted">Cadence for Mac, Windows and Linux keeps reminders running in the background.</div></div>
        <div class="row" style="flex-wrap:wrap;justify-content:flex-end">${downloadButtons()}</div></div>
      <div class="srow"><div>Mac app<div class="small muted">In Cadence for Mac, open Settings › Sync with Cadence Web and sign in with this same username and password. That's all — it finds this site automatically.</div></div></div>
    </div></div>

    ${window.cadenceDesktop?.setOpenAtLogin ? `<div><h3>This computer</h3><div class="card">
      <div class="srow"><label class="check"><input type="checkbox" data-act-change="open-at-login" ${ui.openAtLogin ? 'checked' : ''}>Open Cadence when I log in</label>
        <span class="small muted">It starts quietly in the tray, so reminders and check-ins work all day.</span></div></div></div>` : ''}
    <div><h3>Reminders on this device</h3><div class="card">
      <div class="srow"><label class="check"><input type="checkbox" data-act-change="browser-reminders" ${reminders.enabled ? 'checked' : ''}>Show reminders in this browser</label>
        <span class="small muted">Turn off if the Mac app already reminds you on this computer.</span></div>
      <div class="srow"><div>Browser notifications: <b>${{ granted: 'allowed', denied: 'blocked', default: 'not asked yet', unsupported: 'not supported' }[perm]}</b>
        ${perm === 'denied' ? '<div class="small muted">Allow them in your browser’s site settings. On-screen banners are used meanwhile.</div>' : ''}</div>
        ${perm === 'default' ? '<button class="btn primary" data-act="ask-notify">Allow notifications</button>' : ''}</div>
      <div class="srow"><div class="row"><button class="btn" data-act="test-reminder">${ic('bell')} Send a test reminder</button><button class="btn" data-act="check-in">Show check-in window</button></div></div>
    </div></div>

    <div><h3>Notifications</h3><div class="card">
      <div class="srow"><div class="grow">Default alert style for new tasks${chans('defaultChannels')}</div></div>
      <div class="srow"><span>Tasks without a time remind at</span>${sel('untimedReminderMinutes', times(300, 1320), s.untimedReminderMinutes)}</div>
      <div class="srow"><span>On-screen banners</span>${sel('bannerAutoDismissSeconds', [[0, 'Stay until dismissed'], [10, 'Hide after 10 seconds'], [30, 'Hide after 30 seconds'], [120, 'Hide after 2 minutes']], s.bannerAutoDismissSeconds)}</div>
    </div></div>

    <div><h3>Recurring checklist reminder</h3><div class="card">
      <div class="srow">${tog('nudgeEnabled', 'Remind me to check my checklist while I’m at the computer', s.nudgeEnabled)}</div>
      <div class="srow"><span>Every</span>${sel('nudgeIntervalMinutes', [15, 20, 30, 45, 60, 90, 120].map(n => [n, `${n} minutes`]), s.nudgeIntervalMinutes)}</div>
      <div class="srow">${tog('nudgeOnlyWhenIncomplete', 'Skip when everything is already done', s.nudgeOnlyWhenIncomplete)}</div>
      <div class="srow"><div class="grow">Alert style${chans('nudgeChannels')}</div></div>
    </div></div>

    <div><h3>Check-in when you open your computer</h3><div class="card">
      <div class="srow">${tog('checkInOnLaunch', 'When Cadence opens (app launch / page load)', s.checkInOnLaunch)}</div>
      <div class="srow">${tog('checkInOnWake', 'When the computer wakes from sleep', s.checkInOnWake)}</div>
      <div class="srow">${tog('checkInOnUnlock', 'When I unlock the Mac / come back to this tab after 10+ minutes', s.checkInOnUnlock)}</div>
      <div class="srow">${tog('checkInOnlyWhenIncomplete', 'Only if something is still unchecked', s.checkInOnlyWhenIncomplete)}</div>
      <div class="srow"><div class="grow">Alert style${chans('checkInChannels')}</div></div>
    </div></div>

    <div><h3>Reflections</h3><div class="card">
      <div class="srow"><span>Minimum reflection length</span>${sel('minReflectionWords', [20, 25, 30, 40, 50, 75, 100, 150, 200].map(n => [n, `${n} words`]), s.minReflectionWords)}</div>
      <div class="small muted" style="padding-bottom:8px">Every checklist item needs a reflection before it can be checked off. The minimum can’t go below 20 words.</div>
    </div></div>

    <div><h3>Google Calendar</h3><div class="card">
      ${!g.configured ? `<div class="srow"><div class="muted">Google isn’t set up on this server yet. The server owner adds <span class="mono">GOOGLE_CLIENT_ID</span> and <span class="mono">GOOGLE_CLIENT_SECRET</span> (see the README).</div></div>`
        : g.connected ? `${g.error ? `<div class="srow"><div class="callout warn" style="width:100%"><span class="big">${ic('alert')}</span>
            <div class="grow"><b>Google isn't returning your events</b><div class="small">${esc(g.error)}</div></div></div></div>` : ''}
          <div class="srow"><div class="green">${ic('check')} Connected${g.email ? ` as ${esc(g.email)}` : ''}</div>
            <div class="row"><button class="btn" data-act="google-refresh">${ic('refresh')} Refresh</button><button class="btn danger" data-act="google-disconnect">Disconnect</button></div></div>
          <div class="srow">${tog('showGoogleEvents', 'Show Google events in Cadence calendars', s.showGoogleEvents)}</div>
          <div class="srow">${g.tasks ? tog('syncGoogleTasks', 'Sync Google Tasks (they show up as tasks kept until done; checking one off completes it in Google)', s.syncGoogleTasks !== false)
            : `<div class="grow">Google Tasks<div class="small muted">Your Google connection is from before Cadence supported Google Tasks. Connect again to add it.</div></div>
              <a class="btn" href="/api/google/connect">${ic('sync')} Connect again</a>`}</div>
          <div class="srow"><span>Remind me before Google events</span>${sel('googleEventReminderMinutes', [[0, 'Off'], [5, '5 minutes'], [10, '10 minutes'], [15, '15 minutes'], [30, '30 minutes']], s.googleEventReminderMinutes)}</div>
          ${g.calendars.length ? `<div class="srow"><div class="grow">Calendars to show and check for busy times (this device)
            <div class="chans" style="margin-top:6px">${g.calendars.map(c => `<label class="check"><input type="checkbox" data-act-change="gcal" value="${esc(c.id)}"
              ${(store.googleCalendarIDs.length ? store.googleCalendarIDs.includes(c.id) : c.primary) ? 'checked' : ''}>
              <span style="width:9px;height:9px;border-radius:50%;background:${c.colorHex || '#0a84ff'}"></span>${esc(c.summary)}</label>`).join('')}</div></div></div>` : ''}`
        : `<div class="srow"><div>Show your Google events here, get reminders for them, and book meetings that send invites.</div><a class="btn primary" href="/api/google/connect">Connect Google Calendar</a></div>`}
    </div></div>

    <div><h3>Calendly</h3><div class="card">
      ${store.calendly.connected ? `<div class="srow"><div class="green">${ic('check')} Connected${store.calendly.name ? ` as ${esc(store.calendly.name)}` : ''}</div>
          <div class="row"><button class="btn" data-act="calendly-refresh">${ic('refresh')} Refresh</button><button class="btn danger" data-act="calendly-disconnect">Disconnect</button></div></div>
        ${store.calendly.schedulingUrl ? `<div class="srow"><span class="mono muted ellipsis">${esc(store.calendly.schedulingUrl)}</span><button class="btn" data-act="copy-text" data-text="${esc(store.calendly.schedulingUrl)}">${ic('copy')} Copy booking page link</button></div>` : ''}`
      : `<div class="srow"><div class="small">In Calendly, open <b>Integrations › API &amp; Webhooks</b>, generate a <b>Personal Access Token</b>, and paste it here. Booked meetings show up on your checklist (without notifications), and your booking links appear on the Booking page.
          <div style="margin-top:4px"><a href="https://calendly.com/integrations/api_webhooks" target="_blank" rel="noopener">Open Calendly API settings ${ic('link')}</a></div></div></div>
        <form class="srow" data-form="calendly"><input class="input grow" name="token" type="password" placeholder="Personal Access Token" autocomplete="off" required>
          <button class="btn primary" ${ui.calendlyBusy ? 'disabled' : ''}>${ui.calendlyBusy ? 'Connecting…' : 'Connect'}</button></form>`}
    </div></div>

    <div><h3>Calendar imports</h3><div class="card">
      <div class="srow">${tog('autoImportCalendars', 'Import Google Calendar events and Calendly meetings onto my checklist', s.autoImportCalendars)}</div>
      <div class="srow"><span>Import the next</span>${sel('importDaysAhead', [3, 7, 14, 21, 30, 60].map(n => [n, `${n} days`]), s.importDaysAhead)}</div>
      <div class="srow"><div class="small muted grow">${ui.importSummary ? esc(ui.importSummary) : `Imported items never notify you — turn notifications on for any single one in its editor. Deleting one hides it for good. Google Calendar is re-checked every 2 minutes while this page is open${store.google.push ? ' and pushes changes instantly' : ''}; Calendly every 30 minutes.`}</div>
        <button class="btn ${ui.importing ? 'busy' : ''}" data-act="import-now" ${ui.importing || !(store.google.connected || store.calendly.connected) ? 'disabled' : ''}>${ic('sync', ui.importing ? 'spinning' : '')} ${ui.importing ? 'Importing…' : 'Import now'}</button></div>
    </div></div>

    <div id="presets"><h3>Task presets</h3><div class="card">
      <div class="srow small muted">Saved combinations of conditions (repeat, keep until done, due date, reminders, color…). Pick one at the top of the New Task window, or save the current one there with “Save as preset”.</div>
      ${(s.taskPresets || []).map(p => `<div class="srow"><span class="dot" style="width:10px;height:10px;border-radius:50%;flex:none;background:${color(p.color)}"></span>
        <input class="input" style="max-width:220px" value="${esc(p.name)}" data-preset-name="${p.id}" aria-label="Preset name">
        <span class="small muted grow">${esc(presetSummary(p))}</span>
        <button class="btn ghost sm icon danger" data-act="preset-delete" data-id="${p.id}" title="Delete preset">${ic('trash')}</button></div>`).join('')
        || '<div class="srow muted">No presets. Make one from the New Task window.</div>'}
    </div></div>

    <div><h3>Sidebar</h3><div class="card">
      ${NAV_SECTIONS.map(sec => `<div class="srow"><label class="check"><input type="checkbox" data-act-change="nav-hide" value="${sec}" ${store.device('navHidden', []).includes(sec) ? '' : 'checked'}>${sec}</label>
        <span class="small muted">${SCREENS.filter(x => x[3] === sec).map(x => x[1]).join(', ')}</span></div>`).join('')}
      <div class="srow small muted">Hidden sections are only hidden in this browser. Click a section’s heading in the sidebar to fold it.</div></div></div>
    <div><h3>Today’s progress ring</h3><div class="card">
      <div class="srow"><div>The ring shows<div class="small muted">What’s left starts full and empties as you check things off; what’s done fills up. Click the ring on Today to switch quickly. Syncs to your Mac.</div></div>
        <div class="seg"><button class="${s.ringShowsLeft ?? true ? 'on' : ''}" data-act="ring-mode-set" data-v="1">What’s left</button><button class="${s.ringShowsLeft ?? true ? '' : 'on'}" data-act="ring-mode-set" data-v="0">What’s done</button></div></div>
      <div class="srow"><div>Until-done tasks and project subtasks count today when<div class="small muted">Ones due later are listed apart and don’t count. Urgent ones always count.</div></div>${projectTodaySelect()}</div>
    </div></div>
    <div id="open-hours"><h3>Open hours</h3><div class="card">
      <div class="srow small muted">When you’re normally free to be booked. Booking shows what’s left of these hours after your closed tasks and events.</div>
      <div class="srow"><span>Days</span><div class="wd">${[1, 2, 3, 4, 5, 6, 7].map(w => `<button class="${a.weekdays.includes(w) ? 'on' : ''}" data-act="avail-day" data-w="${w}" title="${M.WEEKDAY_SHORT[w - 1]}">${M.WEEKDAY_LETTER[w - 1]}</button>`).join('')}</div></div>
      <div class="srow"><span>From</span>${sel('availability.startMinutes', times(360, 1200), a.startMinutes)}</div>
      <div class="srow"><span>Until</span>${sel('availability.endMinutes', times(480, 1380), a.endMinutes)}</div>
      <div class="srow"><span>Breathing room around closed items</span>${sel('availability.bufferMinutes', [[0, 'None'], [5, '5 minutes'], [10, '10 minutes'], [15, '15 minutes'], [30, '30 minutes']], a.bufferMinutes)}</div>
    </div></div>

    <div class="small muted" style="order:99">Read our <a href="/privacy" target="_blank">Privacy Policy</a> and <a href="/terms" target="_blank">Terms of Service</a>.</div>

  </div>`;
}

// ---------- Desktop downloads (GitHub release assets, fixed names) ----------
const RELEASE = 'https://github.com/wilsonwilson49/cadence/releases/latest/download';
const DOWNLOADS = [
  ['mac', 'Mac', 'Cadence-mac.zip'], ['windows', 'Windows', 'Cadence-Setup.exe'],
  ['linux', 'Linux (AppImage)', 'Cadence.AppImage'], ['deb', 'Linux (.deb)', 'Cadence.deb'],
];
function downloadButtons() {
  const ua = navigator.userAgent;
  const mine = /Mac/.test(ua) ? 'mac' : /Win/.test(ua) ? 'windows' : /Linux|X11/.test(ua) ? 'linux' : null;
  const sorted = [...DOWNLOADS].sort((a, b) => (b[0] === mine) - (a[0] === mine));
  return sorted.map(([os, label, file]) => `<a class="btn ${os === mine ? 'primary' : 'sm'}" href="${RELEASE}/${file}" download>${ic('copy')} ${os === mine ? `Download for ${label}` : label}</a>`).join('');
}

// ---------- Auth ----------
function authView() {
  const a = ui.auth, create = a.mode === 'register';
  return `<div class="auth"><form class="auth-card" data-form="auth">
    <a href="/" class="small muted" style="text-decoration:none">← Back to home</a>
    <div class="logo"><img src="/icon-192.png" alt=""><div><h1>Cadence</h1><div class="muted small">Your checklist, calendars and reflections — on the web and on your Mac.</div></div></div>
    <div class="seg" style="align-self:flex-start"><button type="button" class="${!create ? 'on' : ''}" data-act="auth-mode" data-mode="login">Sign in</button>
      <button type="button" class="${create ? 'on' : ''}" data-act="auth-mode" data-mode="register">Create account</button></div>
    <label class="field"><span>Username</span><input class="input" name="username" autocomplete="username" required minlength="3" maxlength="32" pattern="[A-Za-z0-9_.\\-]+" autofocus></label>
    <label class="field"><span>Password</span><input class="input" name="password" type="password" autocomplete="${create ? 'new-password' : 'current-password'}" required minlength="${create ? 8 : 1}"></label>
    ${create ? '<div class="small muted">Usernames: 3–32 letters, numbers, dots, dashes or underscores. Passwords: at least 8 characters.</div>' : ''}
    <label class="check"><input type="checkbox" name="remember" checked>Keep me signed in</label>
    ${a.error ? `<div class="error">${esc(a.error)}</div>` : ''}
    <button class="btn primary" style="min-height:38px" ${a.busy ? 'disabled' : ''}>${create ? 'Create account' : 'Sign in'}</button>
    <div class="small muted" style="text-align:center">${create ? 'By creating an account you agree to the' : 'See our'}
      <a href="/terms" target="_blank">Terms of Service</a> and <a href="/privacy" target="_blank">Privacy Policy</a>.</div>
  </form></div>`;
}

// ---------- modals ----------
function openModal(m) { ui.modal = m; ui.modalFresh = true; renderModal(); }
function closeModal() { ui.modal = null; renderModal(); render(); }

function renderModal() {
  const root = $('#modal');
  const m = ui.modal;
  if (!m) { root.innerHTML = ''; ui.modalHTML = null; return; }
  let html = '';
  if (m.type === 'reflection') html = reflectionDialog(m.occ, m.locked ? 'locked' : 'reflection', m.mode, m.minutes, m.left);
  else if (m.type === 'checkin') html = m.reflecting ? reflectionDialog(m.reflecting, 'checkin', m.reflectMode) : checkInDialog(m);
  else if (m.type === 'editor') html = editorDialog(m);
  else if (m.type === 'detail') html = detailDialog(m);
  else if (m.type === 'delete-repeat') html = deleteRepeatDialog(m);
  else if (m.type === 'booking') html = bookingDialog(m);
  else if (m.type === 'delete-account') html = `<form class="dialog sm" data-form="delete-account"><div class="body">
    <div class="row" style="gap:12px"><span class="badge-icon" style="background:var(--red)">${ic('trash')}</span><h2>Delete your account?</h2></div>
    <div>This permanently deletes <b>${esc(store.user.username)}</b> and everything in it — tasks, reflections, settings, and your Google and Calendly connections — for every device. It can’t be undone.</div>
    <div class="small muted">Tip: <a href="/api/account/export" download>download your data</a> first. The Mac app keeps its own copy on your Mac until you delete it there.</div>
    <label class="field"><span>Type your password to confirm</span><input class="input" name="password" type="password" autocomplete="current-password" required autofocus></label>
    ${m.error ? `<div class="error">${esc(m.error)}</div>` : ''}
    </div><div class="foot"><span class="grow"></span><button type="button" class="btn" data-act="close">Cancel</button>
      <button class="btn primary" style="background:var(--red)" ${m.working ? 'disabled' : ''}>${m.working ? 'Deleting…' : 'Delete forever'}</button></div></form>`;
  else if (m.type === 'delete-google') html = `<div class="dialog sm"><div class="body">
    <h2>Remove “${esc(m.task.title)}”?</h2>
    <div class="muted">This event is synced with Google Calendar.</div>
    ${m.error ? `<div class="error">${esc(m.error)}</div>` : ''}</div>
    <div class="foot" style="flex-wrap:wrap"><button class="btn" data-act="close">Cancel</button><span class="grow"></span>
      <button class="btn" data-act="google-hide">Hide in Cadence</button>
      <button class="btn primary" style="background:var(--red)" data-act="google-delete" ${m.working ? 'disabled' : ''}>${m.working ? 'Deleting…' : 'Delete from Google too'}</button></div></div>`;
  else if (m.type === 'nag') html = nagDialog(m);
  else if (m.type === 'pj-keys') html = `<div class="dialog sm"><div class="body"><h2>Keyboard shortcuts</h2>
      <table class="keys">${PROJECT_KEYS.map(([k, v]) => `<tr><td><kbd>${esc(k)}</kbd></td><td class="muted">${esc(v)}</td></tr>`).join('')}</table>
      <div class="small muted" style="margin-top:10px">No shortcuts needed: the + boxes add subtasks, the bar above the list changes picked ones, and each row has its own buttons. On Windows, use Ctrl for ⌘.</div></div>
    <div class="foot"><span class="grow"></span><button class="btn primary" data-act="close">Done</button></div></div>`;
  else if (m.type === 'sel-checkoff') html = `<div class="dialog sm"><div class="body"><h2>Check off ${ui.weekSel?.size || 0} item${ui.weekSel?.size === 1 ? '' : 's'}</h2>
      <div class="muted small">One reflection (at least ${store.settings.minReflectionWords} words), saved for each of them.</div>
      <textarea class="input" id="selRefl" rows="4" autofocus style="width:100%;margin-top:8px"></textarea></div>
    <div class="foot"><span class="grow"></span><button class="btn" data-act="close">Cancel</button><button class="btn primary" data-act="sel-checkoff-go">Check off</button></div></div>`;
  else if (m.type === 'confirm') html = `<div class="dialog sm"><div class="body"><h2>${esc(m.title)}</h2><div class="muted">${esc(m.text)}</div></div>
    <div class="foot">${m.alt ? `<button class="btn danger" data-act="confirm-alt">${esc(m.alt)}</button>` : ''}<span class="grow"></span><button class="btn" data-act="close">Cancel</button><button class="btn primary" data-act="confirm-yes">${esc(m.yes)}</button></div></div>`;
  // The popup is redrawn whenever the app refreshes (sync, the minute tick, any change). Rebuilding the whole
  // overlay each time replayed its fade and made the backdrop and dialog flicker over the page. So: nothing
  // changes when nothing changed, and otherwise only the dialog's contents are swapped, keeping scroll and focus.
  const overlay = root.firstElementChild;
  if (overlay && !ui.modalFresh) {
    if (html === ui.modalHTML) return;
    ui.modalHTML = html;
    const scrollEl = overlay.querySelector('.dialog .body'), scrollTop = scrollEl?.scrollTop ?? 0;
    const active = document.activeElement, focusId = overlay.contains(active) ? active.id : null;
    const sel = focusId && 'selectionStart' in active ? [active.selectionStart, active.selectionEnd] : null;
    overlay.innerHTML = html;
    const body = overlay.querySelector('.dialog .body'); if (body) body.scrollTop = scrollTop;
    if (focusId) { const el = document.getElementById(focusId); if (el) { el.focus(); if (sel) try { el.setSelectionRange(...sel); } catch { /* not text */ } } }
    animateRings();
    return;
  }
  ui.modalHTML = html;
  const cover = m.type === 'nag' && m.level === 'strict';
  root.innerHTML = `<div class="overlay ${ui.modalFresh ? 'opening' : ''} ${cover ? 'cover' : ''}" data-act="overlay">${html}</div>`;
  ui.modalFresh = false;
  animateRings();
  const focus = root.querySelector('[autofocus]');
  if (focus) setTimeout(() => focus.focus(), 0);
}

const PROMPTS = ['What went well, and why?', 'What got in the way or felt harder than expected?', 'What will you do differently next time?',
  'How did this move you toward a bigger goal?', 'What did you learn about how you work?'];

const MISSED_PROMPTS = ['What got in the way?', 'Was it in your control, or not?', 'What would make it happen next time?',
  'Was it still the right thing to plan, or should it change?', 'How do you feel about skipping it?'];

/** The reflection's submit button: enough words, and the time taken (if any) is a length. */
function reflReady() {
  const text = $('#reflText'), btn = $('#reflSubmit');
  if (!text || !btn) return;
  const enough = M.countWords(text.value) >= Number(text.dataset.min);
  const taken = $('#reflTaken'), note = $('#reflTakenNote');
  const raw = taken?.value.trim() || '', mins = M.parseMinutes(raw), bad = raw && mins == null;
  if (note) { note.textContent = mins ? M.fmtMinutes(mins) : bad ? 'Try 45, 1:30 or 1h 30m' : 'optional'; note.className = `small ${bad ? 'orange' : 'muted'}`; }
  btn.disabled = !enough || bad;
}

function reflectionDialog(o, ctx, mode = 'done', minutes = null, left = 0) {
  const min = store.settings.minReflectionWords, missed = mode === 'missed';
  const seed = [...(o.task.id + o.key)].reduce((n, c) => n + c.charCodeAt(0), 0);
  const pool = missed ? MISSED_PROMPTS : PROMPTS;
  const prompts = [0, 1, 2].map(i => pool[(seed + i) % pool.length]);
  return `<form class="dialog" data-form="reflection" data-occ="${esc(o.id)}" data-ctx="${ctx}" data-mode="${mode}"><div class="body">
    <div class="row" style="gap:12px"><span class="badge-icon" style="background:${missed ? 'var(--red)' : color(o.task.color)}">${ic(missed ? 'x' : 'quote')}</span>
      <div class="grow"><h2>${missed ? 'Why didn’t it happen?' : 'Reflect to complete'}</h2><div class="muted ellipsis">${esc(o.task.title)} · ${M.fmtDay(o.day, { weekday: 'long', month: 'short', day: 'numeric' })}</div></div></div>
    <div>${missed ? `Write at least ${min} words about why you didn’t or couldn’t do it. It’s marked as not done, not failed — this is for learning.` : `Write at least ${min} words before checking this off.`} Some prompts:<ul class="prompts">${prompts.map(p => `<li>${p}</li>`).join('')}</ul></div>
    <textarea class="input" id="reflText" rows="7" placeholder="${missed ? 'What happened?' : 'How did it go?'}" autofocus data-min="${min}"></textarea>
    ${missed ? '' : `<div class="taken"><div class="row" style="gap:8px;flex-wrap:wrap">${ic('timer')}<label for="reflTaken"><b>How long did it take?</b></label>
        <input class="input" id="reflTaken" style="width:130px" placeholder="e.g. 45 or 1:30" autocomplete="off" value="${minutes || ''}"><span class="small muted" id="reflTakenNote">${minutes ? M.fmtMinutes(minutes) : 'optional'}</span></div>
      <div class="row" style="gap:5px;flex-wrap:wrap;margin-top:6px">${takenChoices(o.task).map(n => `<button type="button" class="btn sm" data-act="refl-taken" data-v="${n}">${M.fmtMinutes(n)}</button>`).join('')}</div>
      ${typicalText(o.task) ? `<div class="small muted" style="margin-top:4px">${esc(typicalText(o.task))}</div>` : ''}</div>`}</div>
    <div class="small orange" id="reflAi" role="alert" hidden style="padding:0 22px 10px"></div>
    <div class="foot"><div class="progress" id="reflBar"><div style="width:0"></div></div><span class="small muted" id="reflCount">0 / ${min} words</span><span class="grow"></span>
      ${ctx === 'locked' ? `<span class="small muted">${left > 1 ? `${left} to go · ` : ''}reflect before you move on</span><button type="button" class="btn" data-act="refl-skip" title="Leave it open on your list, no reflection">I didn’t finish it</button>`
        : `<button type="button" class="btn" data-act="${ctx === 'checkin' ? 'checkin-back' : 'close'}">Cancel</button>`}
      <button class="btn ${missed ? 'danger-solid' : 'primary'}" id="reflSubmit" disabled title="Ctrl/⌘ + Enter">${ic(missed ? 'x' : 'check')} ${missed ? 'Submit & mark not done' : 'Submit & complete'}</button></div></form>`;
}

function checkInDialog(m) {
  const items = store.countedToday(), done = items.filter(o => o.done).length, left = items.filter(o => !o.resolved).length;
  const upcoming = scheduleOn(new Date()).filter(e => !e.allDay && e.end > new Date()).map(e => ({ title: e.title, startDate: e.start, colorHex: e.color }));
  return `<div class="dialog"><div class="body">
    <div class="row" style="gap:14px"><span class="badge-icon" style="width:46px;height:46px;background:var(--orange)">${ic('sun')}</span>
      <div class="grow"><h2>${esc(m.title)}</h2><div class="muted">${M.fmtDay(new Date())} · ${!items.length ? 'nothing scheduled' : done === items.length ? 'all done' : left ? `${left} left` : 'all settled'}</div></div>
      ${todayRing(done, items.length, 54, 6, 'checkin')}</div>
    ${done && done === items.length ? `<div class="green">${ic('check')} Everything is checked off. Nice work.</div>` : ''}
    <div class="card" style="max-height:340px;overflow:auto">${items.length ? splitUntilDone(items).map(([label, list]) => (label ? `<div class="crow-sub">${ic(label === 'Habits' ? 'habit' : 'flame')}${label}</div>` : '') + list.map(o => crow(o, { ctx: 'checkin' })).join('')).join('') : '<div class="crow muted">Nothing on today’s checklist. Add something so future-you knows the plan.</div>'}</div>
    ${upcoming.length ? `<div><b>Still ahead on your calendar</b>${upcoming.slice(0, 4).map(e => `<div class="row small" style="margin-top:4px">
      <span style="width:3px;height:16px;background:${e.colorHex || '#0a84ff'};border-radius:2px"></span><span class="muted" style="width:72px">${M.fmtTime(e.startDate)}</span>${esc(e.title)}</div>`).join('')}</div>` : ''}
    </div><div class="foot"><button class="btn" data-act="new-task">${ic('plus')} Add task</button><span class="grow"></span>
      <button class="btn" data-act="close" data-then="today">Open Today</button><button class="btn primary" data-act="close" autofocus>Done for now</button></div></div>`;
}

function itemById(id) {
  const [kind, ...rest] = id.split('|');
  const tail = rest.join('|');
  if (kind === 't') { const o = findOcc(tail); return o && { kind: 'task', o, title: o.task.title, start: o.start, end: o.end, color: color(o.task.color) }; }
  const e = store.google.events.get(tail);
  if (!e) return null;
  const ev = { ...e, startDate: e.isAllDay ? M.parseKey(e.start) : new Date(e.start), endDate: e.isAllDay ? M.parseKey(e.end) : new Date(e.end) };
  return { kind: 'google', e: ev, title: e.title, start: e.isAllDay ? null : ev.startDate, end: e.isAllDay ? null : ev.endDate, color: e.colorHex || '#0a84ff' };
}

/** Deleting a repeating item: only this one, this and later ones, or all of them. */
function deleteRepeatDialog(m) {
  const t = store.tasks.get(m.task);
  if (!t) return '<div class="dialog sm"><div class="body">This item no longer exists.</div><div class="foot"><span class="grow"></span><button class="btn" data-act="close">Close</button></div></div>';
  const day = M.parseKey(m.day), label = M.fmtDay(day, { weekday: 'short', month: 'short', day: 'numeric' });
  const b = (scope, text, sub, cls = '') => `<button class="btn ${cls} del-opt" data-act="delete-task" data-task="${t.id}" data-scope="${scope}" data-day="${m.day}"><b>${text}</b><span class="small muted">${sub}</span></button>`;
  return `<div class="dialog sm"><div class="body"><h2>Delete “${esc(t.title)}”?</h2><div class="muted">It repeats (${esc(M.planSummary(t) || 'repeating')}).</div>
    <div class="stack" style="gap:8px;margin-top:6px">
      ${b('one', `Only this one (${label})`, M.isUntilDone(t) ? 'That round is skipped; the next one comes as usual.' : 'Just that day is skipped; the rest stay.')}
      ${b('fromHere', 'This one and all later ones', 'It stops here. Past days and their reflections stay.')}
      ${b('all', 'All of them, past and future', 'The whole task goes. Reflections you wrote are kept.', 'danger')}
    </div></div><div class="foot"><span class="grow"></span><button class="btn" data-act="close">Cancel</button></div></div>`;
}

function detailDialog(m) {
  const it = itemById(m.item);
  if (!it) return `<div class="dialog sm"><div class="body">This item no longer exists.</div><div class="foot"><span class="grow"></span><button class="btn" data-act="close">Close</button></div></div>`;
  const during = it.start && it.end ? (() => {
    const len = it.end - it.start;
    const opts = [['At its start', it.start]];
    if (len >= 30 * 60_000) opts.push(['Halfway through', new Date(+it.start + len / 2)], ['15 min before it ends', M.addMinutes(it.end, -15)]);
    return `<div class="fieldset"><div class="legend">${ic('layers')} Add task during this</div><div class="row" style="flex-wrap:wrap">
      ${opts.map(([l, d]) => `<button class="btn sm" data-act="new-at" data-at="${+d}">${l} (${M.fmtTime(d)})</button>`).join('')}</div></div>`;
  })() : '';
  let body = '', buttons = '';
  if (it.kind === 'task' && it.o.event) {
    const o = it.o, t = o.task;
    const from = t.source === 'calendly' ? 'From Calendly' : t.source === 'google' ? 'From Google Calendar' : 'Event';
    body = `<div class="muted">${ic('cal')} ${M.fmtDay(o.day)}</div>
      <div class="muted">${ic('clock')} ${o.start ? `${M.fmtTime(o.start)} – ${M.fmtTime(o.end)}` : 'All day'}</div>
      ${M.planSummary(t) ? `<div class="muted">${ic('repeat')} ${esc(M.planSummary(t))}</div>` : ''}
      ${t.notes ? `<div>${esc(t.notes)}</div>` : ''}
      <div class="small muted">${from} · ${M.isBusy(t) ? 'closed: blocks this time' : 'open: just for info'} · ${M.isSilent(t) ? 'no reminders' : 'reminds you'} · not on your checklist</div>`;
    buttons = `${t.externalURL ? `<a class="btn" href="${esc(t.externalURL)}" target="_blank" rel="noopener">${ic('link')} Open</a>` : ''}
      <button class="btn" data-act="edit" data-task="${t.id}">Edit…</button>
      <button class="btn" data-act="make-kind" data-task="${t.id}" data-kind="task" title="Put it on your checklist">${ic('list')} Make it a task</button>
      <button class="btn danger" data-act="delete-task" data-task="${t.id}" data-occ="${esc(o.id)}">${t.source ? 'Hide' : 'Delete'}${t.recurrence.frequency !== 'none' ? '…' : ''}</button>`;
  } else if (it.kind === 'task') {
    const o = it.o, t = o.task, r = store.reflectionFor(o, o.missed ? 'missed' : 'done');
    body = `<div class="muted">${ic('cal')} ${M.fmtDay(o.day)}</div>
      <div class="muted">${ic('clock')} ${o.start ? `${M.fmtTime(o.start)} – ${M.fmtTime(o.end)}` : 'Any time'}</div>
      ${M.planSummary(t) ? `<div class="muted">${ic('repeat')} ${esc(M.planSummary(t))}</div>` : ''}
      ${t.notes ? `<div>${esc(t.notes)}</div>` : ''}<div class="small muted">${M.isBusy(t) ? 'Closed: blocks this time' : 'Open: just for info, you’re still free then'}</div>${r ? `<div class="muted" style="font-style:italic">“${esc(r.text)}”</div>` : ''}`;
    buttons = `${o.done ? `<button class="btn" data-act="toggle" data-occ="${esc(o.id)}">Mark not done</button>` : `<button class="btn primary" data-act="toggle" data-occ="${esc(o.id)}">Complete…</button>`}
      ${o.missed ? `<button class="btn" data-act="miss" data-occ="${esc(o.id)}">Undo “didn’t do it”</button>` : o.done ? '' : `<button class="btn" data-act="miss" data-occ="${esc(o.id)}">${ic('x')} Didn’t do it…</button>`}
      <button class="btn" data-act="edit" data-task="${t.id}">Edit…</button>
      ${t.recurrence.frequency !== 'none' && !M.isUntilDone(t) ? `<button class="btn" data-act="skip" data-occ="${esc(o.id)}">Skip</button>` : ''}
      ${t.source ? `<button class="btn" data-act="make-kind" data-task="${t.id}" data-kind="event" title="Take it off your checklist">${ic('cal')} Make it an event</button>` : ''}
      <button class="btn danger" data-act="delete-task" data-task="${t.id}" data-occ="${esc(o.id)}">${ic('trash')} Delete${t.recurrence.frequency !== 'none' ? '…' : ''}</button>`;
  } else {
    const e = it.e;
    body = `<div class="muted">${ic('cal')} ${M.fmtDay(e.startDate)}</div>${!e.isAllDay ? `<div class="muted">${ic('clock')} ${M.fmtTime(e.startDate)} – ${M.fmtTime(e.endDate)}</div>` : ''}
      ${e.location ? `<div class="muted">${esc(e.location)}</div>` : ''}<div class="small muted">From Google Calendar · ${e.transparent ? 'shown as free (open)' : 'busy (closed)'}</div>`;
    buttons = e.link ? `<a class="btn" href="${esc(e.link)}" target="_blank" rel="noopener">${ic('link')} Open in Google Calendar</a>` : '';
  }
  return `<div class="dialog sm"><div class="body"><div class="row"><span style="width:10px;height:10px;border-radius:50%;background:${it.color}"></span><h2 class="grow">${esc(it.title)}</h2></div>
    ${body}${quickEditFields(it, m.item)}${during}</div><div class="foot" style="flex-wrap:wrap">${buttons}<span class="grow"></span><button class="btn" data-act="close">Close</button></div></div>`;
}

/** Is this calendar item pinned to its days (repeating, long-term, a cycle)? Then edits change only its time. */
const fixedDaysOf = it => it.kind === 'task' && (it.o.task.recurrence.frequency !== 'none' || it.o.task.mode === 'longTerm' || M.isCycle(it.o.task));
const busyOfItem = it => (it.kind === 'task' ? M.isBusy(it.o.task) : !it.e.transparent);

/** The detail dialog's quick edit: title, when, how long, open or closed. Works on Google events too. */
function quickEditFields(it, id) {
  const timed = Boolean(it.start), len = timed ? Math.round((it.end - it.start) / 60_000) : 0, fixed = fixedDaysOf(it);
  const lens = [...new Set([15, 30, 45, 60, 90, 120, 180, 240, len].filter(Boolean))].sort((a, b) => a - b);
  const hm = d => `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  return `<div class="fieldset quick-edit"><div class="legend">${ic('text')} Quick edit</div>
    <input class="input" id="qeTitle" value="${esc(it.title)}" placeholder="Title">
    ${timed ? `<div class="row" style="gap:6px;flex-wrap:wrap">${fixed ? '' : `<input class="input" type="date" id="qeDate" value="${M.dateKey(it.start)}" style="width:auto">`}
      <input class="input" type="time" id="qeTime" value="${hm(it.start)}" style="width:auto" step="300">
      <select class="input" id="qeLen" style="width:auto">${lens.map(n => `<option value="${n}" ${n === len ? 'selected' : ''}>${n < 60 ? `${n} min` : n % 60 ? `${Math.floor(n / 60)} hr ${n % 60} min` : `${n / 60} hr`}</option>`).join('')}</select></div>` : ''}
    <label class="check"><input type="checkbox" id="qeBusy" ${busyOfItem(it) ? 'checked' : ''}>Blocks the time (closed)</label>
    ${fixed && timed ? '<div class="small muted">It repeats, so a new time applies to every repeat.</div>' : ''}
    <div class="row">${it.kind === 'google' ? `<button class="btn sm danger" data-act="gevent-delete" data-item="${esc(id)}">${ic('trash')} Delete from Google</button>` : ''}
      <span class="grow"></span><button class="btn sm primary" data-act="quick-save" data-item="${esc(id)}">Save changes</button></div>
    <div class="tiny muted">Tip: on the week and booking grids you can also drag a block to move it, or drag its bottom edge to change its length.</div></div>`;
}

/**
 * Quick edit or drag from any calendar: new title, start, length or open/closed (leave a field out to keep it).
 * A repeating item keeps its days and moves every repeat to the new time. Synced events change in Google too.
 * Same as AppModel.applyEdit on the Mac.
 */
function applyEdit(it, { title, start, minutes, busy } = {}) {
  title = title?.trim() || undefined;
  if (it.kind === 'task') {
    const t0 = store.tasks.get(it.o.task.id);
    if (!t0) return;
    const t = structuredClone(t0), fixed = fixedDaysOf(it);
    if (title) t.title = title;
    if (start) { if (!fixed) t.startDate = M.iso(M.startOfDay(start)); t.timeMinutes = M.minutesOf(start); }
    if (minutes != null) t.durationMinutes = Math.max(5, minutes);
    if (busy != null) t.busy = busy;
    if (JSON.stringify(t) === JSON.stringify(t0)) return;
    store.upsertTask(t);
    toast(`Updated “${t.title}”`, { icon: 'check', undo: () => store.upsertTask(t0) });
    if (t.source === 'google' && t.googleEventID && store.google.connected) {
      const moveTime = !fixed && (start || minutes != null) && t.timeMinutes != null;
      const s0 = moveTime ? M.dayAt(new Date(t.startDate), t.timeMinutes) : null;
      store.updateGoogleEvent({ calendarID: t.sourceCalendar || 'primary', eventId: t.googleEventID, ...(title ? { title } : {}),
        ...(s0 ? { start: M.iso(s0), end: M.iso(M.addMinutes(s0, t.durationMinutes)), allDay: false } : {}), ...(busy != null ? { busy } : {}) })
        .catch(err => toast(`Saved in Cadence, but Google didn’t take it: ${err.message}`, { icon: 'alert' }));
    }
  } else {
    const e = it.e, eventId = e.id.split('|').slice(1).join('|');
    const s0 = start || e.startDate, len = minutes != null ? minutes * 60_000 : e.endDate - e.startDate;
    const moved = !e.isAllDay && (start || minutes != null);
    if (!title && !moved && busy == null) return;
    store.updateGoogleEvent({ calendarID: e.calendarID, eventId, ...(title ? { title } : {}),
      ...(moved ? { start: M.iso(s0), end: M.iso(new Date(+s0 + len)), allDay: false } : {}), ...(busy != null ? { busy } : {}) })
      .then(() => toast(`Updated “${title || e.title}” in Google Calendar`, { icon: 'cal' }))
      .catch(err => toast(`Google didn’t take the change: ${err.message}`, { icon: 'alert' }));
  }
}

// Drag a block on the week or booking grid to move it (15-minute steps, across days), or its bottom edge to resize it.
let calDrag = null, swallowClick = false;
document.addEventListener('pointerdown', e => {
  const el = e.target.closest('.block[data-item], .ot-item[data-item]');
  if (!el || e.button !== 0 || (e.shiftKey && el.closest('.week'))) return;
  const it = itemById(el.dataset.item);
  if (!it?.start || (it.kind === 'task' && M.isUntilDone(it.o.task)) || (it.kind === 'task' && (it.o.done || it.o.missed))) return;
  const col = el.closest('.wcol, .ot-col');
  if (!col) return;
  const r = el.getBoundingClientRect();
  calDrag = { el, it, x: e.clientX, y: e.clientY, hour: el.closest('.wcol') ? HOUR : OT_HOUR, colW: col.offsetWidth,
    resize: e.clientY > r.bottom - 7, h: el.offsetHeight, moved: false };
});
addEventListener('pointermove', e => {
  const d = calDrag;
  if (!d) return;
  const dx = e.clientX - d.x, dy = e.clientY - d.y;
  if (!d.moved && Math.hypot(dx, dy) < 5) return;
  d.moved = true;
  d.el.classList.add('dragging');
  const days = d.resize ? 0 : Math.round(dx / d.colW), mins = Math.round(dy / d.hour * 4) * 15;
  if (d.resize) {
    d.el.style.height = `${Math.max(12, d.h + dy)}px`;
    const len = Math.max(15, Math.round(((d.it.end - d.it.start) / 60_000 + dy / d.hour * 60) / 15) * 15);
    d.el.dataset.dragLabel = `${M.fmtTime(d.it.start)}–${M.fmtTime(M.addMinutes(d.it.start, len))} · ${len} min`;
  } else {
    d.el.style.transform = `translate(${dx}px, ${dy}px)`;
    const ns = M.addMinutes(M.addDays(d.it.start, days), mins);
    d.el.dataset.dragLabel = `${days ? `${M.WEEKDAY_SHORT[ns.getDay()]} ` : ''}${M.fmtTime(ns)}–${M.fmtTime(new Date(+ns + (d.it.end - d.it.start)))}`;
  }
});
addEventListener('pointerup', e => {
  const d = calDrag;
  calDrag = null;
  if (!d?.moved) return;
  swallowClick = true;
  setTimeout(() => { swallowClick = false; }, 50);
  const dx = e.clientX - d.x, dy = e.clientY - d.y;
  d.el.classList.remove('dragging'); d.el.style.transform = ''; delete d.el.dataset.dragLabel;
  if (d.resize) {
    const len = Math.max(15, Math.round(((d.it.end - d.it.start) / 60_000 + dy / d.hour * 60) / 15) * 15);
    applyEdit(d.it, { minutes: len });
  } else {
    const days = Math.round(dx / d.colW), mins = Math.round(dy / d.hour * 4) * 15;
    if (days || mins) applyEdit(d.it, { start: M.addMinutes(M.addDays(d.it.start, days), mins) });
  }
  render();
});
// The click that ends a drag shouldn't also open the details.
/** Project keys. Returns true when the key was used. */
function projKey(e) {
  const cmd = e.metaKey || e.ctrlKey, sh = e.shiftKey, alt = e.altKey, k = e.key;
  const pf = e.target.dataset?.pfield === 'item-title' ? e.target : null;
  if (pf) {
    const id = pf.dataset.item, p = store.projects.get(ui.projectId); if (!p) return false;
    if (k === 'Tab') { projEdit(p.id, q => (sh ? M.outdentItem : M.indentItem)(q, id)); render(); focusItem(id); return true; }
    if (k === 'Enter' && sh) { projAdd(id); return true; }
    if (k === 'Enter' && cmd) { projOps.toggleDone(); return true; }
    if (k === 'Enter' && !alt) { projAdd(M.findItem(p, id)?.parent?.id ?? null, id); return true; }
    if ((k === 'ArrowUp' || k === 'ArrowDown') && alt) { projOps.move(k === 'ArrowUp' ? -1 : 1); return true; }
    if ((k === 'ArrowUp' || k === 'ArrowDown') && !cmd && !sh) {
      const ids = projRowsNow().map(r => r.item.id), j = ids.indexOf(id) + (k === 'ArrowUp' ? -1 : 1);
      if (ids[j]) focusItem(ids[j]); return true;
    }
    if (k === 'Backspace' && !pf.value && !cmd) { projOps.delete(); return true; }
    if (k === 'Escape') { pf.blur(); proj.picked = new Set([id]); proj.anchor = id; render(); return true; }
    return false;
  }
  if (e.target.closest?.('input, textarea, select, [contenteditable]')) return false;
  const kl = k.toLowerCase();
  if (cmd && kl === 'z') return sh ? projUndo(proj.redo, proj.undo) || true : projUndo(proj.undo, proj.redo) || true;
  if (cmd && kl === 'a') { projRowsNow(); const p = store.projects.get(ui.projectId); proj.picked = new Set(M.projectRows(p).map(r => r.item.id)); render(); return true; }
  if (cmd && kl === 'c') return projOps.copy() !== false;
  if (cmd && kl === 'x') { projOps.cut(); return true; }
  if (cmd && kl === 'v') { projOps.paste(); return true; }
  if (cmd && kl === 'd') { projOps.duplicate(); return true; }
  if (k === '?' || (cmd && k === '/')) { openModal({ type: 'pj-keys' }); return true; }
  if (k === 'Escape' && proj.picked.size) { proj.picked = new Set(); render(); return true; }
  if ((k === 'ArrowUp' || k === 'ArrowDown') && alt) { projOps.move(k === 'ArrowUp' ? -1 : 1); return true; }
  if ((k === 'ArrowUp' || k === 'ArrowDown') && !cmd) {
    const ids = projRowsNow().map(r => r.item.id); if (!ids.length) return false;
    const cur = ids.indexOf(proj.anchor), next = ids[Math.min(ids.length - 1, Math.max(0, (cur < 0 ? (k === 'ArrowUp' ? ids.length : -1) : cur) + (k === 'ArrowUp' ? -1 : 1)))];
    if (!sh) proj.picked = new Set(); proj.picked.add(next); proj.anchor = next; render(); return true;
  }
  if (!proj.picked.size || cmd) return false;
  if (k === 'Tab') { sh ? projOps.outdent() : projOps.indent(); return true; }
  if (k === 'Enter' && sh && proj.picked.size === 1) { projAdd([...proj.picked][0]); return true; }
  if (k === 'Enter' && proj.picked.size === 1) { const id = [...proj.picked][0]; if (projMode() === 'outline') proj.picked = new Set(); render(); focusItem(id); return true; }
  if (k === ' ') { projOps.toggleDone(); return true; }
  if (k === 'Delete' || k === 'Backspace') { projOps.delete(); return true; }
  if (kl === 'u') { projOps.toggleUrgent(); return true; }
  return false;
}

// Projects outline: clicking a row (not its title or buttons) picks it; Shift-drag draws a box to pick rows.
document.addEventListener('click', e => {
  if (ui.route !== 'projects') return;
  const row = e.target.closest('.poutline .prow[data-pick]');
  if (!row || e.target.closest('input, button, select, label, a, .datefield')) return;
  projClick(row.dataset.pick, e);
});
let pjBand = null;
document.addEventListener('pointerdown', e => {
  if (ui.route !== 'projects' || !e.shiftKey || e.button !== 0 || !e.target.closest('.poutline') || e.target.closest('input, button, select')) return;
  e.preventDefault();
  const box = document.createElement('div'); box.className = 'sel-band'; document.body.appendChild(box);
  pjBand = { x: e.clientX, y: e.clientY, box, moved: false };
});
document.addEventListener('pointermove', e => {
  if (!pjBand) return;
  const x = Math.min(pjBand.x, e.clientX), y = Math.min(pjBand.y, e.clientY), w = Math.abs(e.clientX - pjBand.x), h = Math.abs(e.clientY - pjBand.y);
  if (w + h > 4) pjBand.moved = true;
  Object.assign(pjBand.box.style, { left: `${x}px`, top: `${y}px`, width: `${w}px`, height: `${h}px` });
});
document.addEventListener('pointerup', () => {
  if (!pjBand) return;
  const r = pjBand.box.getBoundingClientRect(), moved = pjBand.moved;
  pjBand.box.remove(); pjBand = null;
  if (!moved) return;
  for (const el of document.querySelectorAll('.poutline .prow[data-pick]')) {
    const b = el.getBoundingClientRect();
    if (!(b.bottom < r.top || b.top > r.bottom)) proj.picked.add(el.dataset.pick);
  }
  swallowClick = true; setTimeout(() => { swallowClick = false; }, 0);
  render();
});

// Week: ⌘/Ctrl + Z X C V. Copy and cut take the picked tasks, or the one under the mouse; paste drops them at the
// spot under the mouse (keeping their spacing), or on today if the mouse isn't over the calendar.
const weekClip = { items: [], undo: [], hoverItem: null, hoverPoint: null };
function pushWeekUndo() { weekClip.undo.push(structuredClone([...store.tasks.values()])); if (weekClip.undo.length > 30) weekClip.undo.shift(); }
function weekUndo() {
  const before = weekClip.undo.pop(); if (!before) return false;
  const ids = new Set(before.map(t => t.id));
  for (const t of [...store.tasks.values()]) if (!ids.has(t.id)) store.deleteTask(t.id);
  for (const t of before) { const cur = store.tasks.get(t.id); if (!cur || JSON.stringify(cur) !== JSON.stringify(t)) store.upsertTask(t); }
  ui.weekSel = new Map(); render(); toast('Undone', { icon: 'check' });
  return true;
}
function weekTargets() {
  if (ui.weekSel?.size) return weekPicked();
  const o = weekClip.hoverItem && findOcc(weekClip.hoverItem.slice(2));
  return o ? [o] : [];
}
function weekCopy(quiet) {
  const occs = weekTargets().filter(o => !o.task.source || o.task.source === 'gtasks' ? true : !M.isEvent(o.task));
  if (!occs.length) return false;
  weekClip.items = occs.map(o => ({ ...structuredClone(o.task), startDate: M.iso(M.startOfDay(o.day)), recurrence: { frequency: 'none', interval: 1 } }));
  if (!quiet) toast(`Copied ${occs.length}`, { icon: 'check' });
  return true;
}
function weekCut() {
  const occs = weekTargets();
  if (!weekCopy(true)) return false;
  pushWeekUndo();
  for (const o of occs) { const t = store.tasks.get(o.task.id); if (!t) continue; const next = M.deleteOccurrence(t, o.day, 'one'); if (next) store.upsertTask(next); else store.deleteTask(t.id); }
  ui.weekSel = new Map(); render(); toast(`Cut ${occs.length}`, { icon: 'trash' });
  return true;
}
function weekPaste() {
  const src = weekClip.items; if (!src.length) return false;
  const when = t => M.dayAt(new Date(t.startDate), t.timeMinutes ?? 0);
  const first = Math.min(...src.map(t => +when(t)));
  const p = weekClip.hoverPoint || { day: M.startOfDay(new Date()), minutes: null };
  const timed = src.filter(t => t.timeMinutes != null).map(t => t.timeMinutes);
  const shift = +M.dayAt(p.day, p.minutes ?? (timed.length ? Math.min(...timed) : 0)) - first;
  pushWeekUndo();
  ui.weekSel = new Map();
  for (const s of src) {
    const moved = new Date(+when(s) + shift);
    const t = { ...structuredClone(s), id: M.uuid(), createdAt: M.iso(new Date()), startDate: M.iso(M.startOfDay(moved)), completions: {}, missed: {}, skipped: [] };
    for (const k of ['updatedAt', 'stepsDone', 'googleEventID', 'googleTaskID', 'source', 'externalURL', 'sourceCalendar', 'archived']) delete t[k];
    if (s.timeMinutes != null) t.timeMinutes = M.minutesOf(moved);
    if (s.dueDate) t.dueDate = M.dateKey(new Date(+M.parseKey(String(s.dueDate).slice(0, 10)) + shift));
    store.upsertTask(t);
    ui.weekSel.set(`t|${t.id}|${M.dateKey(moved)}`, true);
  }
  render(); toast(`Pasted ${src.length}`, { icon: 'check' });
  return true;
}
document.addEventListener('mousemove', e => {
  if (ui.route !== 'week') return;
  weekClip.hoverItem = e.target.closest?.('.week [data-item^="t|"]')?.dataset.item || null;
  const col = e.target.closest?.('.wcol[data-day]'), cell = e.target.closest?.('.week-allday .cell[data-day]');
  if (col) { const r = col.getBoundingClientRect(); weekClip.hoverPoint = { day: M.parseKey(col.dataset.day), minutes: Math.min(1425, Math.max(0, Math.floor((e.clientY - r.top) / HOUR * 4) * 15)) }; }
  else if (cell) weekClip.hoverPoint = { day: M.parseKey(cell.dataset.day), minutes: null };
  else weekClip.hoverPoint = null;
});
document.addEventListener('keydown', e => {
  if (ui.route !== 'week' || ui.modal || !(e.metaKey || e.ctrlKey) || e.shiftKey || e.altKey) return;
  if (e.target.closest?.('input, textarea, select, [contenteditable]')) return;
  const k = e.key.toLowerCase();
  const done = k === 'z' ? weekUndo() : k === 'x' ? weekCut() : k === 'c' ? weekCopy() : k === 'v' ? weekPaste() : false;
  if (done) e.preventDefault();
});

// Week: shift + drag draws a box; every task it touches is picked.
let band = null;
document.addEventListener('pointerdown', e => {
  if (ui.route !== 'week' || !e.shiftKey || e.button !== 0 || !e.target.closest('.week') || e.target.closest('button, input, select, .week-selbar')) return;
  e.preventDefault();
  const box = document.createElement('div'); box.className = 'sel-band'; document.body.appendChild(box);
  band = { x: e.clientX, y: e.clientY, box, moved: false };
});
document.addEventListener('pointermove', e => {
  if (!band) return;
  const x = Math.min(band.x, e.clientX), y = Math.min(band.y, e.clientY), w = Math.abs(e.clientX - band.x), h = Math.abs(e.clientY - band.y);
  if (w + h > 4) band.moved = true;
  Object.assign(band.box.style, { left: `${x}px`, top: `${y}px`, width: `${w}px`, height: `${h}px` });
});
document.addEventListener('pointerup', e => {
  if (!band) return;
  const r = band.box.getBoundingClientRect(), moved = band.moved;
  band.box.remove(); band = null;
  if (!moved) return;
  ui.weekSel ??= new Map();
  for (const el of document.querySelectorAll('.week [data-item^="t|"]')) {
    const b = el.getBoundingClientRect();
    if (b.right < r.left || b.left > r.right || b.bottom < r.top || b.top > r.bottom || el.classList.contains('done') || el.classList.contains('missed')) continue;
    ui.weekSel.set(el.dataset.item, true);
  }
  swallowClick = true; setTimeout(() => { swallowClick = false; }, 0);
  render();
});

// Week: while Select is on (or with ⌘/Ctrl/Shift held), clicking a task picks it instead of opening it.
document.addEventListener('click', e => {
  if (ui.route !== 'week') return;
  const el = e.target.closest('.week [data-item^="t|"]');
  if (!el || !(ui.weekSelecting || e.metaKey || e.ctrlKey || e.shiftKey)) return;
  e.stopPropagation(); e.preventDefault();
  ui.weekSel ??= new Map();
  ui.weekSel.has(el.dataset.item) ? ui.weekSel.delete(el.dataset.item) : ui.weekSel.set(el.dataset.item, true);
  render();
}, true);
document.addEventListener('click', e => { if (swallowClick) { swallowClick = false; e.stopPropagation(); e.preventDefault(); } }, true);

// --- task editor ---
const DURATIONS = [5, 10, 15, 30, 45, 60, 90, 120, 180, 240];
const BEFORE = [0, 5, 10, 15, 30, 60, 120, 1440];
const DURING = [-10, -15, -30, -45, -60, -90];

function openEditor(task, isNew) {
  const end = M.endOf(task.recurrence);
  openModal({
    type: 'editor', isNew, error: null, saving: false, addToGoogle: false,
    // New events sync with Google Calendar by default when it's connected.
    syncGoogle: isNew && M.isEvent(task) && store.google.connected,
    draft: structuredClone(task),
    date: M.dateKey(task.startDate),
    hasTime: task.timeMinutes != null,
    time: `${String(Math.floor((task.timeMinutes ?? 540) / 60)).padStart(2, '0')}:${String((task.timeMinutes ?? 540) % 60).padStart(2, '0')}`,
    endMode: end.type, endDate: M.dateKey(end.date ?? M.addMonths(M.parseKey(M.dateKey(task.startDate)), 3)), endCount: end.count ?? 10,
    cycleGap: task.cycleGapDays && task.cycleGapDays % 7 === 0 ? task.cycleGapDays / 7 : (task.cycleGapDays ?? 1),
    cycleUnit: task.cycleGapDays && task.cycleGapDays % 7 === 0 ? 'weeks' : (task.cycleGapDays != null ? 'days' : 'weeks'), cycleTimes: task.cycleTimes ?? 3,
    hasDue: Boolean(task.dueDate), dueDate: M.dateKey(task.dueDate ?? M.addDays(M.parseKey(M.dateKey(task.startDate)), 7)),
  });
}

// --- habits: the Atomic Habits fields (how to make it stick) ---
const HABIT_FIELDS = ['identity', 'cue', 'stackAfter', 'replaces', 'twoMinute', 'reward', 'app', 'limitMinutes'];
function habitSentence(t) {
  const h = t.habit || {}, title = t.title.trim() || 'this habit', lower = title[0].toLowerCase() + title.slice(1);
  if (h.style === 'stack' && h.stackAfter) return `After I ${h.stackAfter}, I will ${lower}.`;
  if (h.style === 'replace' && h.replaces) return `Instead of ${h.replaces}, I will ${lower}.`;
  if (h.style === 'break') return `I’m breaking the habit: ${lower}.`;
  return h.cue ? `I will ${lower} ${h.cue}.` : '';
}

/** Habit editor: the steps checklist. */
function stepFields(m) {
  const steps = m.draft.steps || [];
  return `<div class="fieldset"><div class="legend">${ic('list')} Steps <span class="small muted" style="font-weight:400">optional</span></div>
    ${steps.map((s, i) => `<div class="row step-edit"><span class="muted">☐</span><input class="input grow" data-edit="step-${i}" value="${esc(s.title)}" placeholder="Step ${i + 1}">
      <button type="button" class="btn ghost sm icon" data-act="step-move" data-i="${i}" data-d="-1" ${i ? '' : 'disabled'} title="Move up">↑</button>
      <button type="button" class="btn ghost sm icon" data-act="step-move" data-i="${i}" data-d="1" ${i < steps.length - 1 ? '' : 'disabled'} title="Move down">↓</button>
      <button type="button" class="btn ghost sm icon danger" data-act="step-remove" data-i="${i}" title="Remove">${ic('x')}</button></div>`).join('')}
    <div class="row"><input class="input grow" id="stepNew" data-edit="step-new" placeholder="Add a step, e.g. stretch — press Return"><button type="button" class="btn sm" data-act="step-add">${ic('plus')} Add</button></div>
    <div class="small muted">Tick them off each time; they start fresh every time it comes around. Ticking the last one opens the check-off.</div></div>`;
}

function habitFields(m) {
  const d = m.draft, h = d.habit || (d.habit = { style: 'build' }), style = h.style || 'build';
  const others = [...store.tasks.values()].filter(t => M.isHabit(t) && !t.archived && t.id !== d.id).map(t => t.title);
  const field = (k, label, ph) => `<label class="field"><span>${label}</span><input class="input" data-edit="h-${k}" value="${esc(h[k] ?? '')}" placeholder="${esc(ph)}"></label>`;
  const sentence = habitSentence(d);
  return `<div class="fieldset"><div class="legend">${ic('habit')} Make it stick</div>
    <div class="seg wide">${M.HABIT_STYLES.map(([v, l]) => `<button type="button" class="${style === v ? 'on' : ''}" data-act="habit-style" data-style="${v}">${l.replace(/ a (new )?habit$/, '').replace('Stack it on', 'Stack on')}</button>`).join('')}</div>
    ${style === 'stack' ? `<label class="field"><span>After I… (a habit you already have)</span><input class="input" data-edit="h-stackAfter" list="habitTitles" value="${esc(h.stackAfter ?? '')}" placeholder="pour my morning coffee"></label>
      <datalist id="habitTitles">${others.map(o => `<option value="${esc(o[0].toLowerCase() + o.slice(1))}">`).join('')}</datalist>` : ''}
    ${style === 'replace' ? field('replaces', 'Instead of… (the habit you’re replacing)', 'scrolling my phone in bed') : ''}
    ${style === 'break' ? `<div class="grid2">${field('app', 'Screen-time app to keep down (optional)', 'YouTube')}${field('limitMinutes', 'Daily limit (minutes)', '30')}</div>
      <div class="small muted" style="margin-top:-6px">The Cadence Mac app measures screen time, so the habit shows how you’re doing against the limit.</div>` : ''}
    ${field('identity', 'Who you’re becoming: I am someone who…', 'reads every day')}
    <div class="grid2">${field('cue', 'Make it obvious: when and where', 'at 9 PM on the couch')}${field('twoMinute', 'Make it easy: the 2-minute version', 'read one page')}</div>
    ${field('reward', 'Make it satisfying: right after, I get…', 'a cup of tea')}
    ${sentence ? `<div class="habit-sentence">${ic('quote')} ${esc(sentence)}</div>` : ''}
  </div>`;
}

// --- task presets: a saved set of conditions to start new tasks from ---
function presetRow(m) {
  const presets = store.settings.taskPresets || [];
  return `<div class="preset-row">${ic('stack')}
    ${m.isNew && presets.length ? `<select class="input" data-edit="preset"><option value="">Start from a preset…</option>
      ${presets.map(p => `<option value="${p.id}" ${m.preset === p.id ? 'selected' : ''}>${esc(p.name)}</option>`).join('')}</select>` : `<span class="small muted grow">${presets.length ? '' : 'No presets yet.'}</span>`}
    ${m.namingPreset ? `<input class="input" data-edit="presetName" placeholder="Preset name" value="${esc(m.presetName)}" style="width:170px">
      <button type="button" class="btn sm primary" data-act="preset-save">Save preset</button><button type="button" class="btn sm" data-act="preset-cancel">Cancel</button>`
      : `<button type="button" class="btn sm" data-act="preset-new" title="Save these conditions (repeat, keep until done, reminders, color…) to reuse">${ic('plus')} Save as preset</button>`}</div>
    ${m.presetSaved ? `<div class="small green" style="margin-top:-8px">${ic('check')} Saved “${esc(m.presetSaved)}”. Pick it from the preset menu next time.</div>` : ''}`;
}

function presetSummary(p) {
  const rec = p.recurrence || { frequency: 'none' }, parts = [p.kind === 'event' ? 'Event' : 'Task'];
  if (p.mode === 'longTerm') parts.push(`every day for ${(p.spanDays ?? 29) + 1} days`);
  else if (rec.frequency === 'none') parts.push('once');
  else if (rec.frequency === 'weekly' && !rec.weekdays?.length) parts.push((rec.interval || 1) > 1 ? `every ${rec.interval} weeks` : 'weekly');
  else { const t = M.recurrenceSummary({ ...rec, end: { never: {} } }, new Date()); parts.push(t[0].toLowerCase() + t.slice(1)); }
  if (p.cycleGapDays != null) parts.push(`back ${p.cycleGapDays % 7 === 0 ? `${p.cycleGapDays / 7} wk` : `${p.cycleGapDays} d`} after each, ${p.cycleTimes ?? 3}×`);
  else if (p.mode === 'untilDone') parts.push('kept on the list until done');
  if (p.dueDays != null) parts.push(`due in ${p.dueDays} day${p.dueDays === 1 ? '' : 's'}`);
  if (p.timeMinutes != null) parts.push(`at ${M.fmtTimeMinutes(p.timeMinutes)}`);
  if (!p.channels?.length) parts.push('no notifications');
  if (p.kind === 'event' || p.busy) parts.push(p.busy ? 'closed' : 'open');
  return parts.join(' · ');
}

function presetFromEditor(m, name) {
  const d = m.draft, day = M.parseKey(m.date), r = d.recurrence;
  const p = {
    id: M.uuid(), name, kind: M.isEvent(d) ? 'event' : 'task', title: d.title.trim(), notes: d.notes || '', durationMinutes: d.durationMinutes,
    recurrence: { frequency: r.frequency, interval: r.interval || 1, weekdays: r.frequency === 'weekly' ? [...r.weekdays] : [],
      end: m.endMode === 'afterCount' && r.frequency !== 'none' ? { afterCount: { _0: m.endCount } } : { never: {} } },
    reminderOffsets: [...d.reminderOffsets], channels: [...d.channels], color: d.color, busy: M.isBusy(d),
  };
  if (m.hasTime) p.timeMinutes = editorStartMinutes(m);
  if (d.mode) p.mode = d.mode;
  if (M.isCycle(d)) { p.cycleGapDays = m.cycleGap * (m.cycleUnit === 'weeks' ? 7 : 1); p.cycleTimes = m.cycleTimes; }
  if (m.endMode === 'onDate' && r.frequency !== 'none') p.spanDays = Math.max(0, M.daysBetween(day, M.parseKey(m.endDate)));
  if (d.mode === 'untilDone' && r.frequency === 'none' && m.hasDue) p.dueDays = Math.max(0, M.daysBetween(day, M.parseKey(m.dueDate)));
  return p;
}

function applyPreset(m, p) {
  const d = m.draft, day = M.parseKey(m.date), rec = p.recurrence || {};
  Object.assign(d, {
    kind: p.kind === 'event' ? 'event' : 'task', title: d.title.trim() ? d.title : (p.title || ''), notes: d.notes?.trim() ? d.notes : (p.notes || ''),
    durationMinutes: p.durationMinutes || 30, color: p.color || 'blue', busy: p.busy ?? p.kind === 'event',
    recurrence: { frequency: rec.frequency || 'none', interval: rec.interval || 1, weekdays: [...(rec.weekdays || [])], end: { never: {} } },
    reminderOffsets: [...(p.reminderOffsets?.length ? p.reminderOffsets : [0])], channels: [...(p.channels || [])],
  });
  if (p.mode) d.mode = p.mode; else delete d.mode;
  if (p.cycleGapDays != null) {
    d.cycleGapDays = p.cycleGapDays; d.cycleTimes = p.cycleTimes ?? 3;
    m.cycleUnit = p.cycleGapDays % 7 === 0 ? 'weeks' : 'days'; m.cycleGap = m.cycleUnit === 'weeks' ? p.cycleGapDays / 7 : p.cycleGapDays; m.cycleTimes = d.cycleTimes;
  } else { delete d.cycleGapDays; delete d.cycleTimes; }
  m.hasTime = p.timeMinutes != null;
  if (m.hasTime) m.time = `${String(Math.floor(p.timeMinutes / 60)).padStart(2, '0')}:${String(p.timeMinutes % 60).padStart(2, '0')}`;
  m.endMode = p.spanDays != null ? 'onDate' : rec.end?.afterCount ? 'afterCount' : 'never';
  if (rec.end?.afterCount) m.endCount = rec.end.afterCount._0;
  if (p.spanDays != null) m.endDate = M.dateKey(M.addDays(day, p.spanDays));
  m.hasDue = p.dueDays != null;
  if (m.hasDue) m.dueDate = M.dateKey(M.addDays(day, p.dueDays));
  m.busyChosen = true; m.preset = p.id; m.presetSaved = null;
  if (M.isEvent(d)) m.syncGoogle = store.google.connected;
}

function editorStartMinutes(m) { const [h, mi] = m.time.split(':').map(Number); return h * 60 + mi; }

function editorOverlaps(m) {
  if (!m.hasTime) return [];
  const day = M.parseKey(m.date), start = M.dayAt(day, editorStartMinutes(m)), end = M.addMinutes(start, m.draft.durationMinutes);
  const out = [];
  for (const o of store.occurrencesOn(day)) if (o.task.id !== m.draft.id && o.start && o.start < end && o.end > start) out.push(`${o.task.title} · ${M.fmtTime(o.start)}–${M.fmtTime(o.end)}`);
  for (const e of store.googleEventsOn(day)) if (!e.isAllDay && e.startDate < end && e.endDate > start) out.push(`${e.title} · ${M.fmtTime(e.startDate)}–${M.fmtTime(e.endDate)} (Google)`);
  return out;
}

function editorDialog(m) {
  const d = m.draft, r = d.recurrence, lt = d.mode === 'longTerm', cyc = M.isCycle(d), persist = d.mode === 'untilDone' && !cyc;
  const isHab = M.isHabit(d), bonus = M.isBonus(d), kindName = M.isEvent(d) ? 'Event' : bonus ? 'Bonus' : isHab ? 'Habit' : 'Task';
  const unit = M.FREQUENCIES.find(f => f[0] === r.frequency)[2];
  const overlaps = editorOverlaps(m);
  const preview = { ...r, end: m.endMode === 'onDate' ? { onDate: { _0: M.iso(M.parseKey(m.endDate)) } } : m.endMode === 'afterCount' ? { afterCount: { _0: m.endCount } } : { never: {} } };
  const offCheck = o => `<label class="check"><input type="checkbox" data-edit="offset" value="${o}" ${d.reminderOffsets.includes(o) ? 'checked' : ''}>${M.offsetLabel(o)}</label>`;
  return `<form class="dialog" data-form="editor"><div class="body">
    <div class="row"><h2 class="grow">${m.isNew ? 'New' : 'Edit'} ${bonus ? 'Bonus Task' : kindName}</h2>
      <div class="seg"><button type="button" class="${kindName === 'Task' ? 'on' : ''}" data-act="edit-kind" data-kind="task">${ic('list')} Task</button>
      <button type="button" class="${kindName === 'Habit' ? 'on' : ''}" data-act="edit-kind" data-kind="habit">${ic('habit')} Habit</button>
      <button type="button" class="${kindName === 'Event' ? 'on' : ''}" data-act="edit-kind" data-kind="event">${ic('cal')} Event</button>
      <button type="button" class="${kindName === 'Bonus' ? 'on' : ''}" data-act="edit-kind" data-kind="bonus">${ic('star')} Bonus</button></div></div>
    <div class="small muted" style="margin-top:-6px">${M.isEvent(d) ? 'Events show on your calendars only: no checkbox, no reflection.'
      : bonus ? `Bonus tasks are optional extras: listed on Today and in Focus, but never required, never overdue and never reminding you. Each one you finish during a focus session is worth +${M.BONUS_POINTS} points.`
      : isHab ? 'Habits repeat on a schedule and are tracked on the Habits page: streaks, never missing twice, and who you’re becoming.'
      : 'Tasks go on your checklist; checking one off asks for a short reflection.'}</div>
    ${bonus ? '' : presetRow(m)}
    <label class="field"><span>Title</span><input class="input" data-edit="title" value="${esc(d.title)}" placeholder="What do you need to do?" autofocus required></label>
    <label class="field"><span>Notes</span><textarea class="input" data-edit="notes" rows="2" placeholder="Optional details">${esc(d.notes)}</textarea></label>
    ${M.isEvent(d) ? '' : `<div class="fieldset"><div class="legend">Priority and hardness</div>
      <div class="seg wide" role="group" aria-label="Priority">${[['', 'None'], ...M.PRIORITIES].map(([k, l]) => `<button type="button" class="${(M.priorityOf(d) || '') === k ? 'on' : ''}" data-act="edit-priority" data-v="${k}">${l}</button>`).join('')}</div>
      <div class="row" style="gap:10px;margin-top:10px"><span class="small" style="font-weight:600">Hardness</span>
        <span class="hpick" role="group" aria-label="Hardness">${[1, 2, 3, 4, 5].map(i => `<button type="button" class="${i <= (M.hardnessOf(d) || 0) ? 'on' : ''}" style="--hc:${hardColor(M.hardnessOf(d) || i)};height:${9 + 3 * i}px" data-act="edit-hardness" data-v="${i}" title="${i}: ${M.HARDNESS[i - 1]}" aria-label="${i}, ${M.HARDNESS[i - 1]}" aria-pressed="${M.hardnessOf(d) === i}"></button>`).join('')}</span>
        <span class="small muted">${M.hardnessOf(d) ? `${M.hardnessOf(d)} · ${M.HARDNESS[M.hardnessOf(d) - 1]}` : 'Not rated'}</span></div></div>`}
    ${bonus ? bonusFieldset(m) : `<div class="fieldset"><div class="legend">When</div>
      ${M.isEvent(d) || isHab ? '' : `<div class="seg wide" role="group" aria-label="Starts"><button type="button" class="${d.after ? '' : 'on'}" data-act="edit-starts" data-v="">On a date</button><button type="button" class="${d.after ? 'on' : ''}" data-act="edit-starts" data-v="1">${ic('right')} After another task</button></div>`}
      ${d.after ? followUpControls(d) : ''}
      <div class="grid2" ${d.after ? 'style="display:none"' : ''}><label class="field"><span>Date</span><input class="input" type="date" data-edit="date" data-rerender value="${m.date}"></label>
        <label class="field"><span>&nbsp;</span><label class="check"><input type="checkbox" data-edit="hasTime" data-rerender ${m.hasTime ? 'checked' : ''}>At a specific time</label></label></div>
      ${m.hasTime && !d.after ? `<div class="grid2"><label class="field"><span>Time</span><input class="input" type="time" data-edit="time" data-rerender value="${m.time}"></label>
        <label class="field"><span>Duration</span><select class="input" data-edit="duration" data-rerender>${[...new Set([...DURATIONS, d.durationMinutes])].sort((a, b) => a - b).map(n => `<option value="${n}" ${d.durationMinutes === n ? 'selected' : ''}>${n < 60 ? `${n} min` : n % 60 ? `${Math.floor(n / 60)} hr ${n % 60} min` : `${n / 60} hr`}</option>`).join('')}</select></label></div>` : ''}
    </div>
    <div class="fieldset"><div class="legend">Your time</div>
      <div class="seg wide"><button type="button" class="${M.isBusy(d) ? 'on' : ''}" data-act="edit-busy" data-busy="1">${ic('lock')} Closed</button>
        <button type="button" class="${M.isBusy(d) ? '' : 'on'}" data-act="edit-busy" data-busy="0">${ic('eye')} Open</button></div>
      <div class="small muted">${M.isBusy(d) ? `Blocks this time: it’s taken out of your open time on Booking${d.source === 'google' || m.syncGoogle ? ', and shows as busy in Google Calendar' : ''}.` : 'Just for info: it shows on your calendars, but you’re still free to be booked then.'}</div></div>
    ${overlaps.length ? `<div class="fieldset"><div class="legend">${ic('layers')} Overlaps with</div>${overlaps.map(l => `<div class="small">${esc(l)}</div>`).join('')}
      <div class="small muted">That’s fine: this task’s reminders will still fire on time, even in the middle of the other one.</div></div>` : ''}
    ${d.source === 'google' && !m.isNew ? `<div class="fieldset"><div class="legend">${ic('sync')} Synced with Google Calendar</div>
      <div class="small muted">Changes you save here update the event in Google Calendar, and changes made in Google show up here. Repeats are managed in Google Calendar.</div>
      ${d.externalURL ? `<a class="small" href="${esc(d.externalURL)}" target="_blank" rel="noopener">${ic('link')} Open in Google Calendar</a>` : ''}</div>` : `
    <div class="fieldset" ${d.after ? 'style="display:none"' : ''}><div class="legend">${isHab || M.isEvent(d) ? 'Repeat' : 'Conditions'}</div>
      <div class="grid2"><label class="field"><span>${isHab || M.isEvent(d) ? 'Repeats' : 'Comes back'}</span><select class="input" data-edit="frequency" data-rerender>
        ${(isHab ? M.FREQUENCIES.filter(([v]) => v !== 'none') : M.isEvent(d) ? M.FREQUENCIES : [['none', 'No, just once']])
          .map(([v, l]) => `<option value="${v}" ${!lt && !cyc && r.frequency === v ? 'selected' : ''}>${l}</option>`).join('')}
        ${isHab ? `<option value="longTerm" ${lt ? 'selected' : ''}>Long-term: every day until a date</option>` : ''}
        ${!isHab && !M.isEvent(d) ? `<option value="cycle" ${cyc ? 'selected' : ''}>After it’s done, with a break</option>` : ''}</select></label>
      ${lt ? `<label class="field"><span>Every day until</span><input class="input" type="date" data-edit="endDate" data-rerender value="${m.endDate}" min="${m.date}"></label>` : ''}
      ${!lt && r.frequency !== 'none' ? `<label class="field"><span>Every</span><div class="row"><input class="input" type="number" min="1" max="99" style="width:80px" data-edit="interval" data-rerender value="${r.interval}"><span>${unit}${r.interval > 1 ? 's' : ''}</span></div></label>` : ''}</div>
      ${cyc ? `<div class="grid2"><label class="field"><span>Break before it comes back</span><div class="row">
          <input class="input" type="number" min="1" max="365" style="width:80px" data-edit="cycleGap" data-rerender value="${m.cycleGap}">
          <select class="input" style="width:auto" data-edit="cycleUnit" data-rerender><option value="days" ${m.cycleUnit === 'days' ? 'selected' : ''}>days</option><option value="weeks" ${m.cycleUnit === 'weeks' ? 'selected' : ''}>weeks</option></select></div></label>
        <label class="field"><span>Times in total</span><input class="input" type="number" min="1" max="99" style="width:80px" data-edit="cycleTimes" data-rerender value="${m.cycleTimes}"></label></div>
        <div class="small muted">${ic('flame')} No dates: it stays on your list every day until you check it off (or mark it “didn’t do it”), then takes a ${m.cycleGap}-${m.cycleUnit === 'weeks' ? 'week' : 'day'} break and comes back — ${m.cycleTimes} time${m.cycleTimes == 1 ? '' : 's'} in total, then it’s finished for good.</div>` : ''}
      ${lt ? `<div class="small muted">${ic('repeat')} On your checklist and reminds you every day until ${M.fmtDay(M.parseKey(m.endDate), { weekday: 'short', month: 'short', day: 'numeric' })} (${Math.max(0, M.daysBetween(M.parseKey(m.date), M.parseKey(m.endDate))) + 1} days). Check off each day on its own.</div>` : ''}
      ${!lt && !cyc && r.frequency === 'weekly' ? `<div class="row" style="flex-wrap:wrap"><div class="wd">${[1, 2, 3, 4, 5, 6, 7].map(w => `<button type="button" class="${M.effectiveWeekdays(r, M.parseKey(m.date)).includes(w) ? 'on' : ''}" data-act="edit-weekday" data-w="${w}">${M.WEEKDAY_LETTER[w - 1]}</button>`).join('')}</div>
        <button type="button" class="btn sm" data-act="edit-weekdays">Weekdays</button></div>` : ''}
      ${!lt && !cyc && r.frequency !== 'none' ? `<div class="grid2"><label class="field"><span>Ends</span><select class="input" data-edit="endMode" data-rerender>
          <option value="never" ${m.endMode === 'never' ? 'selected' : ''}>Never</option><option value="onDate" ${m.endMode === 'onDate' ? 'selected' : ''}>On a date</option>
          <option value="afterCount" ${m.endMode === 'afterCount' ? 'selected' : ''}>After a number of times</option></select></label>
        ${m.endMode === 'onDate' ? `<label class="field"><span>End date</span><input class="input" type="date" data-edit="endDate" data-rerender value="${m.endDate}" min="${m.date}"></label>` : ''}
        ${m.endMode === 'afterCount' ? `<label class="field"><span>Times</span><input class="input" type="number" min="1" max="999" data-edit="endCount" data-rerender value="${m.endCount}"></label>` : ''}</div>
        <div class="small muted">${esc(M.recurrenceSummary(preview, M.parseKey(m.date)))}</div>` : ''}
      ${M.isEvent(d) || lt || cyc ? '' : `<label class="check" style="margin-top:4px"><input type="checkbox" data-edit="persist" data-rerender ${persist ? 'checked' : ''}>${ic('flame')} Keep it on my list every day until it’s done</label>
        ${persist ? `<div class="small muted" style="margin-top:-4px">${r.frequency === 'none'
          ? 'It shows up and reminds you every day until you check it off or mark it “didn’t do it”. Then it’s gone.'
          : 'Each one shows up and reminds you every day until you check it off or mark it “didn’t do it”, or until the next one arrives and takes its place.'}</div>
          ${r.frequency === 'none' ? `<div class="row" style="flex-wrap:wrap"><label class="check"><input type="checkbox" data-edit="hasDue" data-rerender ${m.hasDue ? 'checked' : ''}>Has a due date</label>
            ${m.hasDue ? `<input class="input" style="width:auto" type="date" data-edit="dueDate" data-rerender value="${m.dueDate}" min="${m.date}"><span class="small muted">It keeps going past the due date, marked “Past due”.</span>` : ''}</div>` : ''}` : ''}`}
    </div>
    `}`}
    ${isHab ? stepFields(m) : ''}
    ${isHab ? habitFields(m) : ''}
    ${bonus ? '' : `<div class="fieldset"><div class="legend">Reminders</div>
      <label class="check"><input type="checkbox" data-edit="notify" data-rerender ${d.channels.length ? 'checked' : ''}>
        ${d.channels.length ? `${ic('bell')} Notify me about this task` : `${ic('bell-off')} No notifications — stays on the checklist quietly`}</label>
      ${d.channels.length ? `
      <div class="checks">${BEFORE.map(offCheck).join('')}</div>
      ${m.hasTime ? `<div class="small" style="font-weight:600">During the task</div><div class="checks">${DURING.filter(o => -o < d.durationMinutes).map(offCheck).join('')}</div>` : ''}
      <div class="chans">${M.CHANNELS.map(([c, l, desc]) => `<label class="check" title="${esc(desc)}"><input type="checkbox" data-edit="channel" value="${c}" ${d.channels.includes(c) ? 'checked' : ''}>${l}</label>`).join('')}</div>
      ${!m.hasTime ? `<div class="small muted">Tasks without a time remind at ${M.fmtTimeMinutes(store.settings.untimedReminderMinutes)} on the day.</div>` : ''}` : ''}
      ${d.source ? `<div class="small muted">Imported from ${d.source === 'calendly' ? 'Calendly' : 'Google Calendar'}. Its title and time update on each import.</div>` : ''}
    </div>`}
    ${M.isEvent(d) || bonus ? '' : `<div class="fieldset"><div class="legend">For things you’d rather put off</div>
      <div class="seg wide">${M.NAG_LEVELS.map(([k, l]) => `<button type="button" class="${M.nagLevel(d) === k ? 'on' : ''}" data-act="edit-nag" data-nag="${k}">${l}</button>`).join('')}</div>
      <div class="small muted">${esc(M.NAG_LEVELS.find(x => x[0] === M.nagLevel(d))[2])}</div>
      ${M.nagLevel(d) !== 'normal' ? `<label class="field"><span>Comes back every</span><select class="input" data-edit="nagEvery" style="width:auto">${M.NAG_EVERY.map(x => `<option value="${x}" ${M.nagMinutes(d) === x ? 'selected' : ''}>${x === 60 ? 'hour' : `${x} min`}</option>`).join('')}</select></label>` : ''}</div>`}
    ${M.isEvent(d) || isHab ? '' : followUpsFieldset(m)}
    ${M.isEvent(d) ? '' : timeTakenFieldset(m)}
    <div class="fieldset"><div class="legend">Color</div><div class="swatches">${Object.entries(M.COLORS).map(([k, v]) => `<button type="button" class="swatch ${d.color === k ? 'on' : ''}" style="background:${v}" data-act="edit-color" data-color="${k}" title="${k}"></button>`).join('')}</div></div>
    ${store.google.connected && store.google.tasks && m.isNew && !M.isEvent(d) && !isHab && !bonus && !d.source
      ? `<label class="check"><input type="checkbox" data-edit="addToGTasks" ${m.addToGTasks ? 'checked' : ''}>${ic('list')} Also add to Google Tasks</label>` : ''}
    ${d.source === 'gtasks' ? `<div class="small muted">${ic('sync')} Synced with Google Tasks: title, notes, due date and checking it off update Google too.</div>` : ''}
    ${!store.google.connected || d.googleEventID || d.source || bonus ? '' : M.isEvent(d)
      ? `<label class="check"><input type="checkbox" data-edit="syncGoogle" data-rerender ${m.syncGoogle ? 'checked' : ''}>${ic('sync')} Sync with Google Calendar</label>
         <div class="small muted" style="margin-top:-8px">${m.syncGoogle ? `Creates it in your Google Calendar${r.frequency !== 'none' ? ' (with the repeat schedule)' : ''}; edits stay in sync both ways.` : 'Keep this event in Cadence only.'}</div>`
      : `<label class="check"><input type="checkbox" data-edit="addToGoogle" ${m.addToGoogle ? 'checked' : ''}>Also add to Google Calendar${r.frequency !== 'none' ? ' (with the repeat schedule)' : ''}</label>`}
    ${m.error ? `<div class="error">${esc(m.error)}</div>` : ''}
    </div><div class="foot">${!m.isNew ? `<button type="button" class="btn danger" data-act="delete-task" data-task="${d.id}">Delete</button>` : ''}<span class="grow"></span>
      <button type="button" class="btn" data-act="close">Cancel</button><button class="btn primary" ${m.saving ? 'disabled' : ''}>${m.isNew ? (M.isEvent(d) ? 'Add Event' : bonus ? 'Add Bonus Task' : 'Add Task') : 'Save'}</button></div></form>`;
}

/** A bonus task's settings: when it's on your list from, and how many times it can be checked off. */
function bonusFieldset(m) {
  const d = m.draft, limit = d.bonusLimit ?? 1, saved = store.tasks.get(d.id), r = d.recurrence;
  const cyc = d.cycleGapDays != null, repeats = cyc || r.frequency !== 'none';
  const opts = [...new Set([...[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 20, 30, 50, 100, 0], limit])].sort((a, b) => (a <= 0 ? Infinity : a) - (b <= 0 ? Infinity : b));
  const unit = M.FREQUENCIES.find(f => f[0] === r.frequency)?.[2] || 'day';
  const preview = { ...r, end: m.endMode === 'onDate' ? { onDate: { _0: M.iso(M.parseKey(m.endDate)) } } : m.endMode === 'afterCount' ? { afterCount: { _0: m.endCount } } : { never: {} } };
  return `<div class="fieldset"><div class="legend">${ic('star')} Bonus</div>
    <div class="grid2"><label class="field"><span>${repeats ? 'Starts' : 'On your list from'}</span><input class="input" type="date" data-edit="date" data-rerender value="${m.date}"></label>
      <label class="field"><span>${repeats ? 'Each time, it can be checked off' : 'Can be checked off'}</span><select class="input" data-edit="bonusLimit" data-rerender>${opts.map(n => `<option value="${n}" ${n === limit ? 'selected' : ''}>${M.bonusLimitLabel(n)}</option>`).join('')}</select></label></div>
    ${saved && M.bonusCount(saved) ? `<div class="small">Checked off ${M.bonusCount(saved)} time${M.bonusCount(saved) === 1 ? '' : 's'} so far${M.bonusFinished(saved) ? ': all done' : repeats ? ` (this time: ${esc(M.bonusSummary(saved).toLowerCase())})` : ''}</div>` : ''}
    <div class="small muted">${limit <= 0 ? `No limit: check it off as many times as you like (several times a day too)${repeats ? ', each time it comes around' : ''}.`
      : limit === 1 ? (repeats ? 'Check it off once each time it comes around.' : 'Check it off once and it’s done for good. It never shows as overdue or missed if you don’t.')
      : `It stays on your list until you’ve checked it off ${limit} times (several times a day is fine)${repeats ? ', then waits until it comes around again' : ', then it’s done for good'}.`}</div></div>
  <div class="fieldset"><div class="legend">Comes back</div>
    <div class="grid2"><label class="field"><span>Comes back</span><select class="input" data-edit="bonusRepeat" data-rerender>
      <option value="none" ${!cyc && r.frequency === 'none' ? 'selected' : ''}>No, just once</option>
      ${M.FREQUENCIES.filter(([v]) => v !== 'none').map(([v, l]) => `<option value="${v}" ${!cyc && r.frequency === v ? 'selected' : ''}>${l}</option>`).join('')}
      ${limit > 0 ? `<option value="cycle" ${cyc ? 'selected' : ''}>After it’s done, with a break</option>` : ''}</select></label>
      ${!cyc && r.frequency !== 'none' ? `<label class="field"><span>Every</span><div class="row"><input class="input" type="number" min="1" max="99" style="width:80px" data-edit="interval" data-rerender value="${r.interval}"><span>${unit}${r.interval > 1 ? 's' : ''}</span></div></label>` : ''}</div>
    ${cyc ? `<div class="grid2"><label class="field"><span>Break before it comes back</span><div class="row">
        <input class="input" type="number" min="1" max="365" style="width:80px" data-edit="cycleGap" data-rerender value="${m.cycleGap}">
        <select class="input" style="width:auto" data-edit="cycleUnit" data-rerender><option value="days" ${m.cycleUnit === 'days' ? 'selected' : ''}>days</option><option value="weeks" ${m.cycleUnit === 'weeks' ? 'selected' : ''}>weeks</option></select></div></label>
      <label class="field"><span>Times in total</span><input class="input" type="number" min="1" max="99" style="width:80px" data-edit="cycleTimes" data-rerender value="${m.cycleTimes}"></label></div>
      <div class="small muted">${ic('flame')} Once it’s been checked off${limit === 1 ? '' : ` ${limit} times`}, it takes a ${m.cycleGap}-${m.cycleUnit === 'weeks' ? 'week' : 'day'} break and comes back: ${m.cycleTimes} time${m.cycleTimes == 1 ? '' : 's'} in total.</div>` : ''}
    ${!cyc && r.frequency === 'weekly' ? `<div class="row" style="flex-wrap:wrap"><div class="wd">${[1, 2, 3, 4, 5, 6, 7].map(w => `<button type="button" class="${M.effectiveWeekdays(r, M.parseKey(m.date)).includes(w) ? 'on' : ''}" data-act="edit-weekday" data-w="${w}">${M.WEEKDAY_LETTER[w - 1]}</button>`).join('')}</div>
      <button type="button" class="btn sm" data-act="edit-weekdays">Weekdays</button></div>` : ''}
    ${!cyc && r.frequency !== 'none' ? `<div class="grid2"><label class="field"><span>Ends</span><select class="input" data-edit="endMode" data-rerender>
        <option value="never" ${m.endMode === 'never' ? 'selected' : ''}>Never</option><option value="onDate" ${m.endMode === 'onDate' ? 'selected' : ''}>On a date</option>
        <option value="afterCount" ${m.endMode === 'afterCount' ? 'selected' : ''}>After a number of times</option></select></label>
      ${m.endMode === 'onDate' ? `<label class="field"><span>End date</span><input class="input" type="date" data-edit="endDate" data-rerender value="${m.endDate}" min="${m.date}"></label>` : ''}
      ${m.endMode === 'afterCount' ? `<label class="field"><span>Times</span><input class="input" type="number" min="1" max="999" data-edit="endCount" data-rerender value="${m.endCount}"></label>` : ''}</div>
      <div class="small muted">${esc(M.recurrenceSummary(preview, M.parseKey(m.date)))}. Each time it comes around it’s a fresh start: anything not checked off doesn’t carry over.</div>` : ''}
  </div>`;
}

function readEditorInputs() {
  const m = ui.modal;
  if (m?.type !== 'editor') return;
  const root = $('#modal');
  const val = k => root.querySelector(`[data-edit="${k}"]`);
  if (val('title')) m.draft.title = val('title').value;
  for (const k of HABIT_FIELDS) if (val(`h-${k}`)) (m.draft.habit ??= { style: 'build' })[k] = val(`h-${k}`).value;
  (m.draft.steps || []).forEach((s, i) => { if (val(`step-${i}`)) s.title = val(`step-${i}`).value; });
  if (val('step-new')) m.stepNew = val('step-new').value;
  if (val('presetName')) m.presetName = val('presetName').value;
  if (val('notes')) m.draft.notes = val('notes').value;
  if (val('date')?.value) m.date = val('date').value;
  if (val('hasTime')) m.hasTime = val('hasTime').checked;
  if (val('time')?.value) m.time = val('time').value;
  if (val('duration')) m.draft.durationMinutes = Number(val('duration').value);
  if (val('after')) m.draft.after = val('after').value;
  if (val('afterMinutes')) { const v = Number(val('afterMinutes').value); if (v) m.draft.afterMinutes = v; else delete m.draft.afterMinutes; }
  if (val('hasDue')) m.hasDue = val('hasDue').checked;
  if (val('bonusLimit')) {
    const v = Number(val('bonusLimit').value);
    if (v === 1) delete m.draft.bonusLimit; else m.draft.bonusLimit = v;
    if (v <= 0) { delete m.draft.cycleGapDays; delete m.draft.cycleTimes; }   // with no limit, a round is never "done"
  }
  if (val('dueDate')?.value) m.dueDate = val('dueDate').value;
  if (val('cycleGap')) m.cycleGap = Math.min(365, Math.max(1, Number(val('cycleGap').value) || 1));
  if (val('cycleUnit')) m.cycleUnit = val('cycleUnit').value;
  if (val('cycleTimes')) m.cycleTimes = Math.min(99, Math.max(1, Number(val('cycleTimes').value) || 1));
  // A bonus task's "Comes back": just once, on a schedule (like a habit's), or after it's done with a break (like a task's).
  const bv = val('bonusRepeat')?.value;
  if (bv === 'cycle' && (m.draft.bonusLimit ?? 1) > 0) {
    m.draft.recurrence = { ...m.draft.recurrence, frequency: 'none', interval: 1, weekdays: [] };
    m.draft.cycleGapDays = m.cycleGap * (m.cycleUnit === 'weeks' ? 7 : 1); m.draft.cycleTimes = m.cycleTimes;
  } else if (bv) {
    // (A break needs a limit: with "No limit" it falls back to just once.)
    const f = M.FREQUENCIES.some(([v]) => v === bv) ? bv : 'none';
    delete m.draft.cycleGapDays; delete m.draft.cycleTimes;
    if (f === 'weekly' && m.draft.recurrence.frequency !== 'weekly' && !m.draft.recurrence.weekdays.length) m.draft.recurrence.weekdays = [M.weekday(M.parseKey(m.date))];
    m.draft.recurrence.frequency = f;
  }
  const fv = val('frequency')?.value, wasLongTerm = m.draft.mode === 'longTerm', wasCycle = M.isCycle(m.draft);
  if (fv === 'cycle') {
    // After it's done, with a break: no dates, so no repeat schedule.
    m.draft.mode = 'untilDone';
    m.draft.recurrence = { ...m.draft.recurrence, frequency: 'none', interval: 1, weekdays: [] };
    m.draft.cycleGapDays = m.cycleGap * (m.cycleUnit === 'weeks' ? 7 : 1);
    m.draft.cycleTimes = m.cycleTimes;
  } else if (wasCycle && val('frequency')) { delete m.draft.cycleGapDays; delete m.draft.cycleTimes; delete m.draft.mode; }
  if (fv === 'cycle') { /* handled above */ } else if (fv === 'longTerm') {
    if (!wasLongTerm) {
      m.draft.mode = 'longTerm';
      m.draft.recurrence = { ...m.draft.recurrence, frequency: 'daily', interval: 1, weekdays: [] };
      m.endMode = 'onDate'; if (m.endDate <= m.date) m.endDate = M.dateKey(M.addDays(M.parseKey(m.date), 30));
    }
  } else if (val('frequency')) {
    if (wasLongTerm) { delete m.draft.mode; m.endMode = 'never'; }
    const f = val('frequency').value;
    if (f === 'weekly' && m.draft.recurrence.frequency !== 'weekly' && !m.draft.recurrence.weekdays.length) m.draft.recurrence.weekdays = [M.weekday(M.parseKey(m.date))];
    m.draft.recurrence.frequency = f;
  }
  // "Keep it on my list until it's done" works with any repeat except long-term.
  const pv = val('persist');
  if (pv && !wasLongTerm && fv !== 'longTerm' && fv !== 'cycle') { if (pv.checked) m.draft.mode = 'untilDone'; else if (m.draft.mode === 'untilDone') delete m.draft.mode; }
  if (val('interval')) m.draft.recurrence.interval = Math.min(99, Math.max(1, Number(val('interval').value) || 1));
  if (val('endMode')) m.endMode = val('endMode').value;
  if (val('endDate')?.value) m.endDate = val('endDate').value;
  if (val('endCount')) m.endCount = Math.min(999, Math.max(1, Number(val('endCount').value) || 1));
  const notify = val('notify');
  if (root.querySelector('[data-edit="offset"]')) m.draft.reminderOffsets = [...root.querySelectorAll('[data-edit="offset"]:checked')].map(e => Number(e.value));
  if (notify && !notify.checked) m.draft.channels = [];
  else if (root.querySelector('[data-edit="channel"]')) m.draft.channels = [...root.querySelectorAll('[data-edit="channel"]:checked')].map(e => e.value);
  else if (notify?.checked) m.draft.channels = [...store.settings.defaultChannels];
  if (val('nagEvery')) { const v = Number(val('nagEvery').value); if (v && v !== 10) m.draft.nagEvery = v; else delete m.draft.nagEvery; }
  if (val('addToGoogle')) m.addToGoogle = val('addToGoogle').checked;
  if (val('syncGoogle')) m.syncGoogle = val('syncGoogle').checked;
  if (val('addToGTasks')) m.addToGTasks = val('addToGTasks').checked;
}

async function saveEditor() {
  readEditorInputs();
  const m = ui.modal, t = structuredClone(m.draft);
  t.title = t.title.trim();
  if (!t.title) { m.error = 'Give the task a title.'; renderModal(); return; }
  t.startDate = M.iso(M.parseKey(m.date));
  if (m.hasTime) t.timeMinutes = editorStartMinutes(m); else delete t.timeMinutes;
  t.recurrence.end = m.endMode === 'onDate' ? { onDate: { _0: M.iso(M.parseKey(m.endDate)) } } : m.endMode === 'afterCount' ? { afterCount: { _0: m.endCount } } : { never: {} };
  if (t.recurrence.frequency === 'weekly' && !t.recurrence.weekdays.length) t.recurrence.weekdays = [M.weekday(M.parseKey(m.date))];
  if (t.recurrence.frequency !== 'weekly') t.recurrence.weekdays = [];
  if (M.isEvent(t)) { delete t.mode; delete t.nag; delete t.nagEvery; }
  // Habits keep their Atomic Habits notes (trimmed); tasks and events don't have any.
  // Habit steps: drop empty ones (and add one still typed in the box).
  const steps = [...(t.steps || []), ...(m.stepNew?.trim() ? [{ id: M.uuid(), title: m.stepNew }] : [])]
    .map(s => ({ ...s, title: s.title.trim() })).filter(s => s.title);
  if (M.isHabit(t) && steps.length) t.steps = steps; else { delete t.steps; delete t.stepsDone; }
  if (M.isHabit(t)) {
    t.kind = 'habit';
    const h = { style: t.habit?.style || 'build' };
    for (const k of HABIT_FIELDS) { const v = String(t.habit?.[k] ?? '').trim(); if (v) h[k] = k === 'limitMinutes' ? Math.max(1, Number(v) || 0) : v; }
    t.habit = h;
  } else delete t.habit;
  if (M.isBonus(t)) {
    // Optional extras: no time, schedule, reminders or follow-up trigger of their own.
    delete t.timeMinutes;
    if (t.cycleGapDays != null && M.bonusMax(t) != null) {
      t.recurrence = { frequency: 'none', interval: 1, weekdays: [], end: { never: {} } };
      t.cycleGapDays = m.cycleGap * (m.cycleUnit === 'weeks' ? 7 : 1); t.cycleTimes = m.cycleTimes;
    } else { delete t.cycleGapDays; delete t.cycleTimes; }
    for (const k of ['mode', 'dueDate', 'urgent', 'after', 'afterMinutes', 'armedAt', 'armedBy', 'nag', 'nagEvery']) delete t[k];
    t.channels = []; t.busy = false;
    if (t.bonusLimit === 1) delete t.bonusLimit;
  } else delete t.bonusLimit;
  if (t.mode === 'longTerm') {
    if (m.endDate < m.date) { m.error = 'The end date has to be on or after the start date.'; renderModal(); return; }
    t.recurrence = { frequency: 'daily', interval: 1, weekdays: [], end: { onDate: { _0: M.iso(M.parseKey(m.endDate)) } } };
  } else if (t.mode !== 'untilDone') delete t.mode;
  if (M.isCycle(t) && t.mode === 'untilDone') {
    t.cycleGapDays = m.cycleGap * (m.cycleUnit === 'weeks' ? 7 : 1); t.cycleTimes = m.cycleTimes;
    t.recurrence = { frequency: 'none', interval: 1, weekdays: [], end: { never: {} } };
  } else if (!M.isBonus(t)) { delete t.cycleGapDays; delete t.cycleTimes; }
  if (t.mode === 'untilDone' && !M.isCycle(t) && t.recurrence.frequency === 'none' && m.hasDue) t.dueDate = M.iso(M.parseKey(m.dueDate)); else delete t.dueDate;
  if (t.after) {
    // A follow-up keeps the date and time it was set off at (or none yet); it has no schedule of its own.
    t.startDate = m.draft.startDate;
    if (t.armedAt && m.draft.timeMinutes != null) t.timeMinutes = m.draft.timeMinutes; else delete t.timeMinutes;
    t.recurrence = { frequency: 'none', interval: 1, weekdays: [], end: { never: {} } };
    delete t.cycleGapDays; delete t.cycleTimes; delete t.dueDate;
    if (t.mode === 'longTerm') delete t.mode;
    if (store.tasks.get(t.id)?.after !== t.after) { delete t.armedAt; delete t.armedBy; }
  } else { delete t.afterMinutes; delete t.armedAt; delete t.armedBy; }
  t.reminderOffsets = t.reminderOffsets.filter(o => o >= 0 || (t.timeMinutes != null && -o < t.durationMinutes));
  if (!t.reminderOffsets.length) t.reminderOffsets = [0];
  const day0 = M.parseKey(m.date);
  const start0 = t.timeMinutes != null ? M.dayAt(day0, t.timeMinutes) : day0;
  const googleFields = {
    title: t.title, details: t.notes, allDay: t.timeMinutes == null, busy: M.isBusy(t),
    start: M.iso(start0), end: M.iso(M.addMinutes(start0, t.durationMinutes)),
    startDate: M.dateKey(day0), endDate: M.dateKey(M.addDays(day0, 1)),
  };

  // A Google Tasks item: save here, then push the title/notes/due date to Google.
  if (!m.isNew && t.source === 'gtasks' && t.googleTaskID) {
    store.upsertTask(t);
    closeModal();
    store.updateGoogleTask({ listId: t.sourceCalendar || '@default', taskId: t.googleTaskID, title: t.title, notes: t.notes,
      due: t.dueDate ? M.dateKey(t.dueDate) : null }).then(() => toast('Updated in Google Tasks too', { icon: 'sync', tone: 'good' }))
      .catch(e => toast(`Saved in Cadence, but Google Tasks didn't update: ${e.message}`, { icon: 'alert', tone: 'bad' }));
    return;
  }

  // A new task that also goes to Google Tasks: create it there, then keep it as the synced copy.
  if (m.isNew && m.addToGTasks && !M.isEvent(t) && !M.isHabit(t) && store.google.tasks) {
    m.saving = true; renderModal();
    try {
      const gt = await store.createGoogleTask({ title: t.title, notes: t.notes, due: M.dateKey(t.dueDate || t.startDate) });
      store.upsertTask({ ...t, id: await M.stableUUID(`gtasks:${gt.id}`), source: 'gtasks', googleTaskID: gt.id, sourceCalendar: gt.listId,
        ...(gt.link ? { externalURL: gt.link } : {}) });
      closeModal(); toast('Added to Cadence and Google Tasks', { icon: 'sync', tone: 'good' });
    } catch (e) {
      store.upsertTask(t);
      m.saving = false; m.error = `Saved in Cadence only — Google Tasks failed: ${e.message}`; renderModal();
    }
    return;
  }

  // Editing an event that's synced with Google: save here, then push the change to Google.
  if (!m.isNew && t.source === 'google' && t.googleEventID) {
    store.upsertTask(t);
    closeModal();
    store.updateGoogleEvent({ ...googleFields, calendarID: t.sourceCalendar || 'primary', eventId: t.googleEventID })
      .then(() => toast('Updated in Google Calendar too', { icon: 'sync', tone: 'good' }))
      .catch(e => toast(`Saved in Cadence, but Google Calendar didn't update: ${e.message}`, { icon: 'alert', tone: 'bad' }));
    return;
  }

  // A new event that syncs with Google: create it in Google first, then keep it as the synced copy.
  if (m.isNew && M.isEvent(t) && m.syncGoogle && store.google.connected) {
    m.saving = true; renderModal();
    try {
      const ev = await store.createGoogleEvent({ ...googleFields, rrule: M.rrule(t.recurrence, day0) });
      if (t.recurrence.frequency === 'none') {
        // Same ID the importer would give it, so it's never imported twice.
        store.upsertTask({ ...t, id: await M.stableUUID(`google:${ev.id}`), kind: 'event', source: 'google', googleEventID: ev.id,
          sourceCalendar: ev.calendarID || 'primary', ...(ev.link ? { externalURL: ev.link } : {}) });
      }
      closeModal();
      toast(t.recurrence.frequency === 'none' ? 'Event added to Cadence and Google Calendar' : 'Repeating event created in Google Calendar; its dates appear here in a moment',
        { icon: 'sync', tone: 'good' });
      if (t.recurrence.frequency !== 'none') runImport();
    } catch (e) {
      store.upsertTask(t);
      m.saving = false; m.error = `Saved in Cadence only — Google Calendar failed: ${e.message}`; renderModal();
    }
    return;
  }

  store.upsertTask(t);
  if (!m.addToGoogle) { closeModal(); return; }
  m.saving = true; renderModal();
  try {
    const day = M.parseKey(m.date);
    const start = t.timeMinutes != null ? M.dayAt(day, t.timeMinutes) : day;
    const ev = await store.createGoogleEvent({
      title: t.title, details: t.notes, allDay: t.timeMinutes == null, busy: M.isBusy(t),
      start: M.iso(start), end: M.iso(M.addMinutes(start, t.durationMinutes)),
      startDate: M.dateKey(day), endDate: M.dateKey(M.addDays(day, 1)),
      rrule: M.rrule(t.recurrence, day),
    });
    const latest = store.tasks.get(t.id);
    if (latest) store.upsertTask({ ...latest, googleEventID: ev.id });
    closeModal();
  } catch (e) {
    m.saving = false; m.error = `Saved in Cadence, but Google Calendar failed: ${e.message}`; renderModal();
  }
}

// --- booking dialog (book a time inside an open stretch) ---
const BOOK_MINUTES = [15, 30, 45, 60, 90, 120];
function bookingDialog(m) {
  const g = store.google.connected;
  const t = `${String(m.start.getHours()).padStart(2, '0')}:${String(m.start.getMinutes()).padStart(2, '0')}`;
  return `<form class="dialog sm" data-form="booking"><div class="body">
    <h2>Book open time</h2><div class="muted">${M.fmtDay(m.start)} · open ${M.fmtTime(m.start)}–${M.fmtTime(m.rangeEnd)}</div>
    <label class="field"><span>Title</span><input class="input" name="title" placeholder="Meeting" autofocus></label>
    <div class="grid2"><label class="field"><span>Starts</span><input class="input" type="time" name="time" value="${t}" step="300" required></label>
      <label class="field"><span>Length</span><select class="input" name="minutes">${BOOK_MINUTES.map(n => `<option value="${n}" ${n === m.minutes ? 'selected' : ''}>${n < 60 ? `${n} min` : n % 60 ? `${Math.floor(n / 60)} hr ${n % 60} min` : `${n / 60} hr`}</option>`).join('')}</select></label></div>
    <div class="grid2"><label class="field"><span>Invitee name <span class="muted">(optional)</span></span><input class="input" name="name"></label>
      <label class="field"><span>Invitee email <span class="muted">(optional)</span></span><input class="input" name="email" type="email"></label></div>
    <label class="field"><span>Notes</span><textarea class="input" name="notes" rows="2"></textarea></label>
    ${g ? `<label class="check"><input type="checkbox" name="meet" checked>Add a Google Meet link</label>
      <div class="small muted">Saved to Google Calendar as a closed event. If you add an email, Google sends them an invitation.</div>`
      : '<div class="small muted">Google Calendar isn’t connected, so this is saved as a Cadence event only (no invitation).</div>'}
    ${m.error ? `<div class="error">${esc(m.error)}</div>` : ''}
    </div><div class="foot"><span class="grow"></span><button type="button" class="btn" data-act="close">Cancel</button><button class="btn primary" ${m.working ? 'disabled' : ''}>Book</button></div></form>`;
}

// ---------- banners ----------
function showBanner(c) {
  const el = document.createElement('div');
  el.className = 'banner';
  el.innerHTML = `<span class="badge-icon" style="background:${c.tint || 'var(--accent)'}">${ic(c.kind === 'event' ? 'cal' : c.kind === 'checkIn' ? 'sun' : c.kind === 'nudge' ? 'list' : 'check')}</span>
    <div class="grow"><div class="row"><span class="k grow">CADENCE</span><span class="k">${M.fmtTime(new Date())}</span></div>
    <div class="t ellipsis">${esc(c.title)}</div><div class="b">${esc(c.body)}</div>
    <div class="row" style="justify-content:flex-end;margin-top:6px"><button class="btn sm" data-x>Dismiss</button>
    <button class="btn sm primary" data-open>${c.occurrence && !c.occurrence.resolved ? 'Complete…' : 'Open checklist'}</button></div></div>`;
  const remove = () => { el.classList.add('leaving'); setTimeout(() => el.remove(), 200); };
  el.querySelector('[data-x]').onclick = remove;
  el.querySelector('[data-open]').onclick = () => {
    remove();
    const occ = c.occurrence && findOcc(c.occurrence.id);
    if (occ && !occ.resolved) beginReflection(occ); else navigate('today');
  };
  const box = $('#banners');
  box.prepend(el);
  while (box.children.length > 4) box.lastElementChild.remove();
  const secs = store.settings.bannerAutoDismissSeconds;
  if (secs > 0) setTimeout(remove, secs * 1000);
}

// ---------- actions ----------
/** After a focus session: each finished item's reflection, one after another, and the dialog can't be closed
 *  until it's written (or you say you didn't finish it). */
function reflectQueue(occs, minutes = null) {
  ui.reflectQueue = occs.filter(o => !o.resolved).map(o => o.id);
  ui.reflectMinutes = minutes;
  nextQueuedReflection();
}
function nextQueuedReflection() {
  const id = ui.reflectQueue?.shift();
  const o = id && findOcc(id);
  if (!o) { ui.reflectQueue = null; if (ui.modal?.locked) closeModal(); return; }
  openModal({ type: 'reflection', occ: o, mode: 'done', minutes: ui.reflectMinutes, locked: true, left: ui.reflectQueue.length + 1 });
}

function beginReflection(o, mode = 'done', minutes = null) {
  const fresh = findOcc(o.id) ?? o;
  openModal({ type: 'reflection', occ: fresh, mode, minutes });
}

/** A new habit: daily, building something new, with the Atomic Habits fields to fill in. */
function newHabitAt(day, fields = {}) {
  openEditor(M.newTask({ kind: 'habit', busy: false, color: 'green', startDate: M.iso(M.startOfDay(day)),
    recurrence: { frequency: 'daily', interval: 1, weekdays: [], end: { never: {} } }, habit: { style: 'build' },
    channels: [...store.settings.defaultChannels], ...fields }), true);
}

function newTaskAt(day, minutes) {
  openEditor(M.newTask({ busy: false, startDate: M.iso(M.startOfDay(day)), ...(minutes != null ? { timeMinutes: minutes } : {}), channels: [...store.settings.defaultChannels] }), true);
}

/** A new event defaults to the next whole hour, one hour long, with a 10-minute heads-up. */
function newEventAt(day, minutes) {
  const now = new Date();
  const m = minutes ?? (M.sameDay(day, now) ? Math.min(23 * 60, (now.getHours() + 1) * 60) : 9 * 60);
  openEditor(M.newTask({ kind: 'event', busy: true, color: 'teal', startDate: M.iso(M.startOfDay(day)), timeMinutes: m, durationMinutes: 60,
    reminderOffsets: [10], channels: [...store.settings.defaultChannels] }), true);
}

function toggleOcc(id, ctx) {
  const o = findOcc(id);
  if (!o) return;
  if (o.done) {
    store.uncomplete(o);
    if (ui.modal?.type === 'detail') closeModal();
    toast(`Unchecked ${o.task.title} — the reflection stays saved`, { icon: 'circle' });
    return;
  }
  if (ctx === 'checkin' && ui.modal?.type === 'checkin') { ui.modal.reflecting = o; ui.modal.reflectMode = 'done'; renderModal(); return; }
  beginReflection(o);
}

/** The X box: "didn't do it / couldn't", with a reflection on why. Clicking it again undoes it. */
function missOcc(id, ctx) {
  const o = findOcc(id);
  if (!o) return;
  if (o.missed) {
    store.unmiss(o);
    if (ui.modal?.type === 'detail') closeModal();
    toast(`${o.task.title} is open again — the reflection stays saved`, { icon: 'circle' });
    return;
  }
  if (ctx === 'checkin' && ui.modal?.type === 'checkin') { ui.modal.reflecting = o; ui.modal.reflectMode = 'missed'; renderModal(); return; }
  beginReflection(o, 'missed');
}

function confirmThen(title, text, yes, fn) { openModal({ type: 'confirm', title, text, yes, fn }); }


// ---------- Projects ----------
// Big goals broken into subtasks (and subtasks of subtasks), each with a deadline, plus a timeline and a map.
const PROJ_STATUS_COLOR = { done: 'var(--green)', overdue: 'var(--red)', today: 'var(--orange)', soon: '#d6a700', later: 'var(--muted)', none: 'var(--muted)' };
const projMode = () => store.device('projectMode', 'outline');
const projCollapsed = id => (ui.projCollapsed ||= new Map()).get(id) || new Set();

/** "Nov 20 · in 5 days" chip, coloured by how close it is. `inherited` = shown from the level above. */
function dueChip(due, { done = false, inherited = false, compact = false } = {}) {
  const st = M.deadlineStatus(due, done);
  const c = inherited || st === 'later' || st === 'none' ? 'var(--muted)' : PROJ_STATUS_COLOR[st];
  return `<span class="duechip ${inherited ? 'inh' : ''}" style="--c:${c}" title="${inherited ? 'Uses the deadline above it' : ''}">${inherited ? '↳' : '⚑'} ${esc(M.shortDay(due))}${compact || done ? '' : ` · ${esc(M.dueRelative(due))}`}</span>`;
}

/** A date that may be unset: a chip that opens the browser's date picker. */
function dateField(label, value, attrs, { status = 'none', compact = false, placeholder } = {}) {
  const c = !value ? 'var(--muted)' : status === 'later' || status === 'none' ? 'var(--text)' : PROJ_STATUS_COLOR[status];
  const text = value ? (compact ? M.shortDay(value) : `${label}: ${M.shortDay(value)}${label === 'Deadline' ? ` · ${M.dueRelative(value)}` : ''}`) : (placeholder || label);
  return `<span class="pdate ${value ? 'set' : ''}" style="--c:${c}"><button class="pdate-btn" data-act="pick-date" title="${value ? `Change the ${label.toLowerCase()}` : `Set a ${label.toLowerCase()}`}">${label === 'Start' ? '▸' : '⚑'} ${esc(text)}</button>
    <input type="date" tabindex="-1" value="${value || ''}" ${attrs}>${value ? `<button class="pdate-x" data-act="clear-date" title="Remove">${ic('x')}</button>` : ''}</span>`;
}

function projectsView() {
  const p = ui.projectId && store.projects.get(ui.projectId);
  return p ? projectDetailView(p) : projectListView();
}

function projectCard(p) {
  const pr = M.projectProgress(p), rows = M.projectRows(p), today = M.dateKey(new Date());
  const overdue = rows.filter(r => !M.itemDone(r.item) && r.item.due && r.item.due < today).length;
  const next = rows.filter(r => !M.itemDone(r.item) && r.item.due).sort((a, b) => a.item.due.localeCompare(b.item.due))[0];
  const pct = pr.total ? Math.round(pr.done / pr.total * 100) : 0;
  return `<a class="pcard" href="/app/projects/${esc(p.id)}" style="--pc:${color(p.color)}">
    <div class="row" style="align-items:flex-start"><span class="pbar"></span><div class="grow" style="min-width:0">
      <div class="ptitle ellipsis">${esc(p.title || 'Untitled project')}</div>
      <div class="small muted">${pr.total ? `${pr.done} of ${pr.total} done` : 'No subtasks yet'}</div></div>
      ${pr.total ? `<b class="small">${pct}%</b>` : ''}</div>
    <div class="pprog"><div style="width:${pct}%"></div></div>
    <div class="row" style="gap:6px;flex-wrap:wrap">${p.due ? dueChip(p.due, { done: M.projectDone(p) }) : ''}
      ${overdue ? `<span class="small red"><b>${overdue} overdue</b></span>` : ''}</div>
    ${next ? `<div class="row small" style="gap:6px"><span class="muted">Next:</span><span class="grow ellipsis">${esc(next.item.title || 'Untitled')}</span>${dueChip(next.item.due, { compact: true })}</div>` : ''}
  </a>`;
}

function projectListView() {
  const active = store.activeProjects, archived = [...store.projects.values()].filter(p => p.archived);
  const gantt = store.device('projectListGantt', false), folded = projCollapsed('all');
  return `<div class="header"><div class="grow"><h1>Projects</h1><div class="sub">Break a big goal into subtasks, give each a deadline, and see it all on a Gantt chart.</div></div>
      <div class="seg"><button class="${gantt ? '' : 'on'}" data-act="project-list-mode" data-gantt="0">Cards</button><button class="${gantt ? 'on' : ''}" data-act="project-list-mode" data-gantt="1">Gantt</button></div>
      <button class="btn primary" data-act="project-new">${ic('plus')} New Project</button></div>
    <div class="page stack" style="max-width:${gantt ? 1300 : 1100}px">
      ${active.length && gantt ? `<div class="row small muted"><span class="grow">Every project on one chart. Click a project's name to fold it; click a subtask to open its project.</span>
          <button class="btn sm" data-act="gantt-fold-all" data-fold="1">Fold all</button><button class="btn sm" data-act="gantt-fold-all" data-fold="0">Unfold all</button></div>
        <div class="card pad">${ganttChart(active, folded)}</div>`
      : active.length ? `<div class="pgrid">${active.map(projectCard).join('')}</div>`
        : `<div class="card pad stack" style="gap:8px"><b>${ic('layers')} No projects yet</b>
            <div class="muted">A project is anything with several steps: an essay, a science fair entry, a trip. Add subtasks, split those into smaller ones, and give any of them a deadline. Deadlines coming up show on your Today list.</div>
            <div><button class="btn primary" data-act="project-new">${ic('plus')} Start a project</button></div></div>`}
      ${archived.length ? `<details><summary class="section-title" style="cursor:pointer">Archived (${archived.length})</summary><div class="pgrid">${archived.map(projectCard).join('')}</div></details>` : ''}
    </div>`;
}

// ---------- Project editing: picking several, undo/redo, clipboard, keyboard ----------
// Everything here also has a button, menu or ghost box, so none of it needs a shortcut.
const proj = { picked: new Set(), anchor: null, undo: [], redo: [], lastKey: null, clip: [] };
const projPicked = id => proj.picked.has(id);
/** Every project change goes through here. Changes with the same key (typing in one title) undo together. */
function projEdit(pid, fn, key = null) {
  const cur = store.projects.get(pid);
  if (!cur) return;
  if (!key || key !== proj.lastKey) { proj.undo.push({ pid, p: structuredClone(cur) }); if (proj.undo.length > 60) proj.undo.shift(); proj.redo = []; }
  proj.lastKey = key;
  store.editProject(pid, fn);
}
function projUndo(from, to) {
  const s = from.pop(); if (!s) return false;
  const cur = store.projects.get(s.pid); if (!cur) return false;
  to.push({ pid: s.pid, p: structuredClone(cur) }); proj.lastKey = null;
  store.upsertProject(s.p); render(); return true;
}
function projRowsNow() { const p = store.projects.get(ui.projectId); return p ? M.projectRows(p, projCollapsed(p.id)) : []; }
/** Picked items not inside another picked one, in outline order (or the one being typed in). */
function projTargets() {
  const p = store.projects.get(ui.projectId); if (!p) return [];
  const typing = document.activeElement?.dataset?.pfield === 'item-title' ? document.activeElement.dataset.item : null;
  const ids = proj.picked.size ? proj.picked : new Set(typing ? [typing] : []);
  const out = [];
  const walk = (list, covered) => { for (const i of list) { const on = !covered && ids.has(i.id); if (on) out.push(i.id); walk(i.items || [], covered || on); } };
  walk(p.items, false);
  return out;
}
function projClick(id, e) {
  if (e?.metaKey || e?.ctrlKey) { proj.picked.has(id) ? proj.picked.delete(id) : proj.picked.add(id); proj.anchor = id; }
  else if (e?.shiftKey && proj.anchor) {
    const ids = projRowsNow().map(r => r.item.id), a = ids.indexOf(proj.anchor), b = ids.indexOf(id);
    if (a >= 0 && b >= 0) ids.slice(Math.min(a, b), Math.max(a, b) + 1).forEach(x => proj.picked.add(x)); else proj.picked.add(id);
  } else { proj.picked = proj.picked.size === 1 && proj.picked.has(id) ? new Set() : new Set([id]); proj.anchor = id; }
  render();
}
const focusItem = id => setTimeout(() => { const el = document.getElementById(`pi-${id}`); if (el) { el.focus(); el.setSelectionRange(el.value.length, el.value.length); } }, 0);
function projAdd(parent, after = null) {
  const pid = ui.projectId, n = M.newProjectItem();
  projEdit(pid, p => M.insertItem(p, n, parent, after));
  if (parent) { const set = new Set(projCollapsed(pid)); set.delete(parent); ui.projCollapsed.set(pid, set); }
  proj.anchor = n.id;
  proj.picked = projMode() === 'outline' ? new Set() : new Set([n.id]);
  render(); focusItem(n.id);
  return n.id;
}
function projBulk(fn) { const ids = projTargets(); if (!ids.length) return; const f = document.activeElement?.dataset?.item; projEdit(ui.projectId, p => { fn(p, ids); }); render(); if (f && !proj.picked.size) focusItem(f); }
const projOps = {
  toggleDone: () => projBulk((p, ids) => { const all = ids.every(id => M.itemDone(M.findItem(p, id)?.item || {})); ids.forEach(id => M.updateItem(p, id, i => M.setItemDone(i, !all))); }),
  toggleUrgent: () => projBulk((p, ids) => { const all = ids.every(id => M.findItem(p, id)?.item.urgent); ids.forEach(id => M.updateItem(p, id, i => { if (all) delete i.urgent; else i.urgent = true; })); }),
  setDue: key => projBulk((p, ids) => ids.forEach(id => M.updateItem(p, id, i => { if (key) i.due = key; else delete i.due; }))),
  indent: () => projBulk((p, ids) => ids.forEach(id => M.indentItem(p, id))),
  outdent: () => projBulk((p, ids) => [...ids].reverse().forEach(id => M.outdentItem(p, id))),
  move: d => projBulk((p, ids) => (d < 0 ? ids : [...ids].reverse()).forEach(id => M.moveItem(p, id, d))),
  delete: () => {
    const ids = projTargets(); if (!ids.length) return;
    const order = projRowsNow().map(r => r.item.id), k = order.indexOf(ids[0]), above = k > 0 ? order[k - 1] : null;
    const wasTyping = !proj.picked.size;
    projEdit(ui.projectId, p => { ids.forEach(id => M.removeItem(p, id)); });
    proj.picked = new Set();
    if (above) { if (wasTyping) { render(); focusItem(above); return; } proj.picked.add(above); proj.anchor = above; }
    render(); toast(`Deleted ${plural(ids.length, 'subtask')}`, { icon: 'trash', undo: () => projUndo(proj.undo, proj.redo) });
  },
  copy: () => { const p = store.projects.get(ui.projectId), ids = projTargets(); if (!p || !ids.length) return false; proj.clip = ids.map(id => structuredClone(M.findItem(p, id).item)); toast(`Copied ${plural(ids.length, 'subtask')}`, { icon: 'check' }); return true; },
  cut: () => { if (projOps.copy()) projOps.delete(); },
  paste: () => {
    const p = store.projects.get(ui.projectId); if (!p || !proj.clip.length) return;
    const fresh = i => ({ ...i, id: M.uuid(), items: (i.items || []).map(fresh) });
    const after = projTargets().pop() || null, parent = after ? M.findItem(p, after)?.parent?.id ?? null : null;
    const copies = proj.clip.map(fresh);
    projEdit(p.id, q => { let prev = after; for (const c of copies) { M.insertItem(q, c, parent, prev); prev = c.id; } });
    proj.picked = new Set(copies.map(c => c.id)); proj.anchor = copies.at(-1).id; render();
  },
  duplicate: () => { if (projOps.copy()) projOps.paste(); },
};
const PROJECT_KEYS = [['Return', 'New subtask below (while typing) · edit the picked one'], ['⇧ Return', 'New subtask inside this one'],
  ['Tab / ⇧ Tab', 'Move in a level / out a level'], ['↑ ↓', 'Move between subtasks (⇧ to pick several)'], ['⌥ ↑ / ⌥ ↓', 'Move it up or down'],
  ['⌘ Return / Space', 'Done / not done'], ['U', 'Urgent on or off'], ['Delete', 'Delete (or Backspace in an empty title)'],
  ['Esc', 'Stop typing and pick the row · clear the pick'], ['⌘-click / ⇧-click', 'Pick several · pick a range'], ['⇧-drag', 'Draw a box to pick rows'],
  ['⌘A', 'Pick everything'], ['⌘C ⌘X ⌘V ⌘D', 'Copy, cut, paste, duplicate'], ['⌘Z / ⇧⌘Z', 'Undo / redo'], ['?', 'Show these shortcuts']];
function projPickBar() {
  const n = proj.picked.size; if (!n) return '';
  return `<div class="week-selbar proj-bar"><b>${n} picked</b>
    <button class="btn sm" data-act="pj" data-op="toggleDone" title="Space">${ic('check')} Done</button>
    <button class="btn sm" data-act="pj" data-op="toggleUrgent" title="U">! Urgent</button>
    <select class="input sm" style="width:auto" data-pj-due title="Deadline"><option value="">Deadline…</option><option value="0">Today</option><option value="1">Tomorrow</option><option value="7">In a week</option><option value="none">No deadline</option></select>
    <button class="btn sm icon" data-act="pj" data-op="outdent" title="Move out a level (⇧Tab)">${ic('left')}</button>
    <button class="btn sm icon" data-act="pj" data-op="indent" title="Move in a level (Tab)">${ic('right')}</button>
    <button class="btn sm icon" data-act="pj" data-op="move" data-d="-1" title="Move up (⌥↑)">↑</button>
    <button class="btn sm icon" data-act="pj" data-op="move" data-d="1" title="Move down (⌥↓)">↓</button>
    <button class="btn sm" data-act="pj" data-op="copy" title="⌘C">Copy</button>
    <button class="btn sm" data-act="pj" data-op="duplicate" title="⌘D">Duplicate</button>
    <button class="btn sm danger" data-act="pj" data-op="delete" title="Delete">${ic('trash')}</button>
    <span class="grow"></span><button class="btn sm" data-act="pj-clear" title="Esc">Clear</button></div>`;
}
const ghostBtn = (label, attrs, cls = '') => `<button class="ghost-add ${cls}" ${attrs} title="${esc(label)}">${ic('plus')}${cls.includes('mini') ? '' : `<span>${esc(label)}</span>`}</button>`;

function projectDetailView(p) {
  const pr = M.projectProgress(p), mode = projMode(), collapsed = projCollapsed(p.id);
  const tabs = [['outline', 'Outline'], ['gantt', 'Gantt'], ['map', 'Map']];
  const legend = `<div class="plegend small"><span><i style="background:var(--red)"></i>Overdue</span><span><i style="background:var(--orange)"></i>Due today</span>
    <span><i style="background:var(--green)"></i>Done</span><span><i style="background:${color(p.color)}"></i>On track</span><span>◆ Deadline</span><span><i style="background:var(--red);width:2px"></i>Today</span>
    <span class="grow"></span><span class="muted">Click to pick (⌘/⇧ for several). The dashed + boxes add subtasks.</span></div>`;
  let body;
  if (mode === 'gantt' || mode === 'timeline') body = `${legend}<div class="card pad">${ganttChart([p], collapsed, { single: true })}</div>${projectSelected(p, collapsed)}`;
  else if (mode === 'map') body = `${legend}<div class="card pad">${projectMap(p, collapsed)}</div>${projectSelected(p, collapsed)}`;
  else body = projectOutline(p, collapsed);
  return `<div class="header" style="padding-bottom:4px"><a class="btn ghost sm" href="/app/projects">${ic('left')} Projects</a><span class="grow"></span>
      <button class="btn ghost sm" data-act="pj-undo" title="Undo (⌘Z)" ${proj.undo.length ? '' : 'disabled'}>Undo</button>
      <button class="btn ghost sm" data-act="pj-redo" title="Redo (⇧⌘Z)" ${proj.redo.length ? '' : 'disabled'}>Redo</button>
      <button class="btn ghost sm" data-act="pj-keys" title="Keyboard shortcuts (?)">Shortcuts</button>
      <div class="seg">${tabs.map(([k, l]) => `<button class="${mode === k || (k === 'gantt' && mode === 'timeline') ? 'on' : ''}" data-act="project-mode" data-mode="${k}">${l}</button>`).join('')}</div>
      <button class="btn ghost sm" data-act="project-archive" data-project="${esc(p.id)}">${p.archived ? 'Unarchive' : 'Archive'}</button>
      <button class="btn ghost sm danger" data-act="project-delete" data-project="${esc(p.id)}" title="Delete project">${ic('trash')}</button></div>
    <div class="page stack" style="max-width:1200px">
      <div class="phead"><div class="grow stack" style="gap:8px;min-width:0">
        <input id="ptitle-${esc(p.id)}" class="ptitle-input" placeholder="Project name" value="${esc(p.title)}" data-pfield="title" data-project="${esc(p.id)}" autocomplete="off">
        <div class="row" style="gap:8px;flex-wrap:wrap">
          <span class="pswatches">${Object.keys(M.COLORS).map(c => `<button class="pswatch ${p.color === c ? 'on' : ''}" style="background:${M.COLORS[c]}" data-act="project-color" data-color="${c}" data-project="${esc(p.id)}" title="${c}"></button>`).join('')}</span>
          ${dateField('Start', p.start, `data-pdate="start" data-project="${esc(p.id)}"`, { placeholder: `Started ${M.shortDay(M.projectStartKey(p))}` })}
          ${dateField('Deadline', p.due, `data-pdate="due" data-project="${esc(p.id)}"`, { status: M.deadlineStatus(p.due, M.projectDone(p)) })}
          <span class="small muted">${pr.total ? `${pr.done} of ${pr.total} done` : 'Add subtasks below'}</span></div></div>
        ${pr.total ? ring(pr.done, pr.total, 64, 8, `proj-${p.id}`) : ''}</div>
      ${projPickBar()}
      ${body}
    </div>`;
}

function projectOutline(p, collapsed) {
  const rows = M.projectRows(p, collapsed);
  const parts = [], open = [];
  for (const r of rows) {
    while (open.length && open.at(-1).depth >= r.depth) { const g = open.pop(); parts.push(`<div class="prow pghost" style="--depth:${g.depth + 1}">${ghostBtn(`Add to “${g.title || 'this'}”`, `data-act="pj-add" data-parent="${esc(g.id)}"`)}</div>`); }
    parts.push(projectRow(p, r, collapsed));
    if ((r.item.items || []).length && !collapsed.has(r.item.id)) open.push({ id: r.item.id, depth: r.depth, title: r.item.title });
  }
  while (open.length) { const g = open.pop(); parts.push(`<div class="prow pghost" style="--depth:${g.depth + 1}">${ghostBtn(`Add to “${g.title || 'this'}”`, `data-act="pj-add" data-parent="${esc(g.id)}"`)}</div>`); }
  return `<div class="card poutline" style="--pc:${color(p.color)}">${rows.length ? parts.join('')
      : '<div class="muted" style="padding:10px 4px">No subtasks yet. Add the first one below, then use + on a row to break it down further.</div>'}
      <form class="prow padd" data-form="project-add" data-project="${esc(p.id)}">${ic('plus')}<input id="padd-${esc(p.id)}" placeholder="Add a subtask — press Return" autocomplete="off"></form></div>
    <div class="small muted">Return adds the next subtask, Tab moves it in a level, Shift-Tab out. Click a row’s edge to pick it (⌘ or Shift for several, or Shift-drag a box), then change them all from the bar. Press ? for every shortcut.</div>`;
}

function projectRow(p, r, collapsed, { selectedView = false } = {}) {
  const i = r.item, kids = (i.items || []).length > 0, done = M.itemDone(i), pr = M.itemProgress(i), pid = esc(p.id), iid = esc(i.id);
  const d = `data-project="${pid}" data-item="${iid}"`;
  return `<div class="prow ${done ? 'done' : ''} ${selectedView ? 'sel' : ''} ${!selectedView && projPicked(i.id) ? 'picked' : ''}" data-pick="${iid}" style="--depth:${selectedView ? 0 : r.depth}">
    <button class="pcollapse ${kids ? '' : 'hide'}" data-act="project-collapse" ${d}>${collapsed.has(i.id) ? '▸' : '▾'}</button>
    <button class="checkbtn" style="${done ? 'color:var(--green)' : ''}" data-act="project-done" ${d} title="${kids ? (done ? 'Mark everything inside not done' : 'Mark everything inside done') : done ? 'Mark not done' : 'Mark done'}">${ic(done ? 'checked' : 'circle')}</button>
    <input id="pi-${iid}" class="ptext ${r.depth === 0 ? 'top' : ''}" value="${esc(i.title)}" placeholder="Subtask" data-pfield="item-title" ${d} autocomplete="off">
    ${kids ? `<span class="small muted mono">${pr.done}/${pr.total}</span><span class="pmini"><span style="width:${pr.total ? pr.done / pr.total * 100 : 0}%"></span></span>` : ''}
    <button class="purgent ${i.urgent ? 'on' : 'hover-only'}" data-act="project-urgent" ${d} title="${i.urgent ? 'Urgent: on today’s list and in today’s progress ring. Click to unmark.' : 'Mark urgent: put it on today’s list and in today’s progress ring'}">! Urgent</button>
    ${r.conflict ? `<span class="red" title="This deadline is after ${esc(M.shortDay(r.limit))}, the deadline of what it's part of.">${ic('alert')}</span>` : ''}
    <span class="pdates">${i.start ? dateField('Start', i.start, `data-pdate="start" ${d}`, { compact: true }) : `<span class="hover-only">${dateField('Start', null, `data-pdate="start" ${d}`, { compact: true })}</span>`}
      ${i.due ? dateField('Deadline', i.due, `data-pdate="due" ${d}`, { compact: true, status: M.deadlineStatus(i.due, done) })
        : `<span class="hover-only">${dateField('Deadline', null, `data-pdate="due" ${d}`, { compact: true })}</span>${r.due ? `<span class="hover-hide">${dueChip(r.due, { done, inherited: true, compact: true })}</span>` : ''}`}</span>
    <span class="pacts">
      <button class="btn ghost sm icon" data-act="project-add-child" ${d} title="Add a subtask inside this one">${ic('plus')}</button>
      <button class="btn ghost sm icon" data-act="project-outdent" ${d} title="Move out a level" ${r.parentId ? '' : 'disabled'}>${ic('left')}</button>
      <button class="btn ghost sm icon" data-act="project-indent" ${d} title="Make it a subtask of the one above">${ic('right')}</button>
      <button class="btn ghost sm icon" data-act="project-move" data-delta="-1" ${d} title="Move up">↑</button>
      <button class="btn ghost sm icon" data-act="project-move" data-delta="1" ${d} title="Move down">↓</button>
      <button class="btn ghost sm icon danger" data-act="project-remove" ${d} title="Delete">${ic('trash')}</button></span>
  </div>`;
}

/** Under the timeline and map: edit whatever was clicked. */
function projectSelected(p, collapsed) {
  const one = proj.picked.size === 1 ? [...proj.picked][0] : null;
  const r = one && M.projectRows(p, collapsed).find(x => x.item.id === one);
  return r ? `<div class="card"><div class="small muted" style="padding-top:6px">Selected${r.parentId ? ` · in ${esc(M.findItem(p, r.parentId)?.item.title || '')}` : ''}</div>${projectRow(p, r, collapsed, { selectedView: true })}</div>` : '';
}

/**
 * Gantt chart: one bar per project and per subtask, from its start to its deadline, on a shared day scale with
 * weekends shaded and today marked. Shows one project or several. `collapsed` holds folded subtask and project ids.
 */
function ganttChart(projects, collapsed, { single = false } = {}) {
  const RH = 30, HEAD = 36, today = M.dateKey(new Date());
  const lines = projects.flatMap(p => {
    if (collapsed.has(p.id)) return [{ p }];
    const rows = M.projectRows(p, collapsed);
    if (!single) return [{ p }, ...rows.map(r => ({ p, r }))];
    const out = [{ p }], open = [];
    for (const r of rows) {
      while (open.length && open.at(-1).depth >= r.depth) { const g = open.pop(); out.push({ p, ghost: g.id, depth: g.depth + 1 }); }
      out.push({ p, r });
      if ((r.item.items || []).length && !collapsed.has(r.item.id)) open.push({ id: r.item.id, depth: r.depth });
    }
    while (open.length) { const g = open.pop(); out.push({ p, ghost: g.id, depth: g.depth + 1 }); }
    out.push({ p, ghost: null, depth: 0 });
    return out;
  });
  const keys = [today, ...projects.flatMap(p => [M.projectStartKey(p), p.due, ...M.projectRows(p).flatMap(r => [r.start, r.due])])].filter(Boolean).sort();
  const lo = M.addDays(M.parseKey(keys[0]), -1), hi = M.addDays(M.parseKey(keys[keys.length - 1]), 3);
  const days = Math.max(14, Math.round((hi - lo) / 86_400_000));
  const DW = Math.max(16, Math.min(34, 900 / days)), W = days * DW, H = HEAD + lines.length * RH;
  const x = k => Math.round((M.parseKey(k) - lo) / 86_400_000) * DW;
  const diamond = (cx, cy, s, fill) => `<path d="M${cx} ${cy - s}l${s} ${s}-${s} ${s}-${s}-${s}z" fill="${fill}"/>`;
  const bar = (start, due, y, inset, c, op, pr, dashed) => {
    const x0 = Math.min(x(start), x(due)), x1 = x(due) + DW, bw = Math.max(DW - 2, x1 - x0 - 2), h = RH - inset * 2, rx = Math.min(6, h / 2);
    return { x1, svg: `<rect x="${x0 + 1}" y="${y + inset}" width="${bw}" height="${h}" rx="${rx}" fill="${c}" fill-opacity="${op}" ${dashed ? 'stroke="var(--red)" stroke-width="1.5" stroke-dasharray="3 2"' : ''}/>
      ${pr.done ? `<rect x="${x0 + 1}" y="${y + inset}" width="${bw * pr.done / pr.total}" height="${h}" rx="${rx}" fill="${c}" fill-opacity="0.55"/>` : ''}` };
  };
  let svg = '';
  for (let i = 0; i <= days; i++) {
    const d = M.addDays(lo, i), px = i * DW, wd = d.getDay(), mon = wd === 1, first = d.getDate() === 1;
    if ((wd === 0 || wd === 6) && i < days) svg += `<rect x="${px}" y="${HEAD - 4}" width="${DW}" height="${H}" class="tl-weekend"/>`;
    if (mon || first || DW >= 22) svg += `<line x1="${px}" y1="${HEAD - 4}" x2="${px}" y2="${H}" class="tl-grid ${first ? 'm' : mon ? 'w' : ''}"/>`;
    if (first || i === 0) svg += `<text x="${px + 3}" y="12" class="tl-month">${d.toLocaleDateString(undefined, { month: 'short' })}</text>`;
    if (mon || DW >= 22) svg += `<text x="${px + DW / 2}" y="${HEAD - 8}" class="tl-day">${d.getDate()}</text>`;
  }
  lines.forEach((l, i) => {
    const y = HEAD + i * RH;
    if ('ghost' in l) return;
    if (!l.r) {
      const p = l.p, pc = color(p.color), pr = M.projectProgress(p), due = p.due || M.projectRows(p).map(r => r.due).filter(Boolean).sort().pop();
      svg += `<rect x="0" y="${y}" width="${W}" height="${RH}" fill="${pc}" fill-opacity="0.07"/>`;
      if (!due) return;
      const b = bar(M.projectStartKey(p), due, y, 9, pc, 0.25, pr, false);
      svg += `<g class="tl-row" data-act="gantt-fold" data-project="${esc(p.id)}">${b.svg}${p.due ? diamond(b.x1 - DW / 2, y + RH / 2, 7, pc) : ''}
        <text x="${b.x1 - DW / 2 + 10}" y="${y + RH / 2 + 3.5}" class="tl-date" font-weight="700" fill="${pc}">${esc(M.shortDay(due))}${pr.total ? ` · ${Math.round(pr.done / pr.total * 100)}%` : ''}</text></g>`;
      return;
    }
    const { p, r } = l, pc = color(p.color), done = M.itemDone(r.item), st = M.deadlineStatus(r.due, done, today);
    const c = done ? 'var(--green)' : st === 'overdue' ? 'var(--red)' : st === 'today' || r.item.urgent ? 'var(--orange)' : pc;
    if (!r.due) { svg += `<circle cx="${x(r.start) + DW / 2}" cy="${y + RH / 2}" r="3" class="tl-dot"/>`; return; }
    const b = bar(r.start, r.due, y, 8, c, r.item.due ? 0.24 : 0.1, M.itemProgress(r.item), r.conflict);
    svg += `<g class="tl-row" data-act="${single ? 'project-select' : 'gantt-open'}" data-project="${esc(p.id)}" data-item="${esc(r.item.id)}"><rect x="0" y="${y}" width="${W}" height="${RH}" fill="transparent" ${projPicked(r.item.id) ? 'stroke="var(--accent)" stroke-opacity=".6"' : ''}/>${b.svg}
      ${r.item.due ? `${diamond(b.x1 - DW / 2, y + RH / 2, 6, c)}<text x="${b.x1 - DW / 2 + 9}" y="${y + RH / 2 + 3.5}" class="tl-date" fill="${c}">${esc(M.shortDay(r.item.due))}</text>` : ''}</g>`;
  });
  if (single && projects[0]?.due) {
    const p = projects[0], px = x(p.due) + DW, pc = color(p.color);
    svg += `<line x1="${px}" y1="${HEAD - 4}" x2="${px}" y2="${H}" stroke="${pc}" stroke-width="1.5" stroke-dasharray="4 3"/><text x="${px - 3}" y="12" text-anchor="end" class="tl-dl" fill="${pc}">deadline</text>`;
  }
  const tx = x(today) + DW / 2;
  svg += `<line x1="${tx}" y1="${HEAD - 14}" x2="${tx}" y2="${H}" stroke="var(--red)" stroke-width="1.5"/><circle cx="${tx}" cy="${HEAD - 14}" r="3.5" fill="var(--red)"/>`;
  const labels = lines.map(({ p, r, ghost, depth }) => {
    if (ghost !== undefined) return `<div class="tl-label" style="padding-left:${depth * 14 + 18}px">${ghostBtn(ghost ? 'Add inside' : 'Add subtask', `data-act="pj-add" ${ghost ? `data-parent="${esc(ghost)}"` : ''}`)}</div>`;
    if (!r) return `<div class="tl-label tl-proj" style="--pc:${color(p.color)}" data-act="gantt-fold" data-project="${esc(p.id)}" title="Fold or unfold">
      <span class="muted tiny">${collapsed.has(p.id) ? '▸' : '▾'}</span><span class="pbar"></span><span class="ellipsis">${esc(p.title || 'Untitled project')}</span></div>`;
    const done = M.itemDone(r.item), kids = (r.item.items || []).length;
    return `<div class="tl-label ${projPicked(r.item.id) ? 'sel' : ''} ${done ? 'done' : ''}" style="padding-left:${r.depth * 14 + 18}px" data-act="${single ? 'project-select' : 'gantt-open'}" data-project="${esc(p.id)}" data-item="${esc(r.item.id)}">
      <span class="${done ? 'green' : 'muted'}">${done ? '✓' : kids ? '<b>○</b>' : '○'}</span><span class="ellipsis ${r.depth === 0 ? 'top' : ''}">${esc(r.item.title || 'Untitled')}</span>
      ${r.item.urgent && !done ? '<span class="red" title="Urgent">!</span>' : ''}</div>`;
  }).join('');
  return `<div class="timeline"><div class="tl-labels"><div class="tl-head"><span class="small muted">${single ? 'Subtask' : 'Project / subtask'}</span></div>${labels}</div>
    <div class="tl-scroll"><svg width="${W}" height="${H}" class="tl-svg">${svg}</svg></div></div>`;
}

/** The tree of subtasks drawn left to right. */
function projectMap(p, collapsed) {
  const lay = M.projectMapLayout(p, collapsed), NW = 180, GAP = 44, RH = 62, pc = color(p.color);
  const W = (lay.depth + 1) * (NW + GAP) + 20, H = lay.rows * RH + 20;
  const pos = new Map(lay.nodes.map(n => [n.id, { x: 10 + n.depth * (NW + GAP), y: 10 + n.y * RH + RH / 2 }]));
  const edges = lay.edges.map(([a, b]) => {
    const A = pos.get(a), B = pos.get(b), fx = A.x + NW, tx = B.x, mid = (fx + tx) / 2;
    const done = M.itemDone(M.findItem(p, b)?.item || {});
    return `<path d="M${fx} ${A.y}C${mid} ${A.y} ${mid} ${B.y} ${tx} ${B.y}" class="map-edge ${done ? 'done' : ''}"/>`;
  }).join('');
  const nodes = lay.nodes.map(n => {
    const at = pos.get(n.id);
    if (!n.item) {
      const pr = M.projectProgress(p);
      return `<div class="map-node root" style="left:${at.x}px;top:${at.y}px;width:${NW}px;background:${pc}">
        <b>${esc(p.title || 'Untitled project')}</b><div class="row" style="gap:6px"><span class="pmini light"><span style="width:${pr.total ? pr.done / pr.total * 100 : 0}%"></span></span><span class="tiny">${pr.done}/${pr.total}</span></div>
        ${p.due ? `<div class="tiny">Due ${esc(M.shortDay(p.due))} · ${esc(M.dueRelative(p.due))}</div>` : ''}</div>`;
    }
    const i = n.item, done = M.itemDone(i), pr = M.itemProgress(i), st = M.deadlineStatus(i.due, done), kids = (i.items || []).length;
    const border = projPicked(i.id) ? 'var(--accent)' : st === 'overdue' || st === 'today' ? PROJ_STATUS_COLOR[st] : '';
    return `<div class="map-node ${done ? 'done' : ''}" style="left:${at.x}px;top:${at.y}px;width:${NW}px;${border ? `border-color:${border};` : ''}" data-act="project-select" data-item="${esc(i.id)}">
      <div class="row" style="gap:5px"><span class="${done ? 'green' : 'muted'}">${done ? '✓' : kids ? '<b>○</b>' : '○'}</span><span class="ellipsis grow">${esc(i.title || 'Untitled')}</span>${i.urgent && !done ? '<b class="red" title="Urgent">!</b>' : ''}${collapsed.has(i.id) && kids ? `<span class="tiny muted">+${kids}</span>` : ''}</div>
      <div class="row" style="gap:6px">${kids ? `<span class="pmini grow" style="--pc:${pc}"><span style="width:${pr.done / pr.total * 100}%"></span></span><span class="tiny muted">${pr.done}/${pr.total}</span>` : '<span class="grow"></span>'}
        ${i.due ? dueChip(i.due, { done, compact: true }) : ''}</div></div>`;
  }).join('');
  const ghosts = lay.nodes.map(n => { const at = pos.get(n.id); return `<span style="position:absolute;left:${at.x + NW + 8}px;top:${at.y - 11}px">${ghostBtn('Add a subtask inside', `data-act="pj-add" ${n.item ? `data-parent="${esc(n.item.id)}"` : ''}`, 'mini')}</span>`; }).join('');
  return `<div class="map-scroll"><div class="map" style="width:${W + 40}px;height:${H}px"><svg width="${W}" height="${H}">${edges}</svg>${nodes}${ghosts}</div></div>`;
}

const PROJECT_TODAY_CHOICES = [[-1, 'Only urgent ones'], [0, 'Due today'], [1, 'Due by tomorrow'], [2, 'Due within 2 days'], [3, 'Due within 3 days'], [7, 'Due within a week']];
const projectTodaySelect = () => `<label class="small muted row" style="gap:6px" title="Which project subtasks join today’s list and its progress ring. Urgent ones always do.">On today:
  <select class="input sm" style="width:auto" data-bind="projectTodayDays">${PROJECT_TODAY_CHOICES.map(([v, l]) => `<option value="${v}" ${(store.settings.projectTodayDays ?? 0) === v ? 'selected' : ''}>${l}</option>`).join('')}</select></label>`;

function projectDeadlineRow(d, { upcoming = false } = {}) {
  const done = Boolean(d.item && M.itemDone(d.item));
  const pid = esc(d.project.id), title = d.item ? (d.title || 'Untitled') : `${d.title || 'Untitled project'} (whole project)`;
  return `<div class="crow ${done ? 'done' : ''}">
    ${d.item ? `<button class="checkbtn" style="${done ? `color:${color(d.project.color)}` : ''}" data-act="project-done" data-project="${pid}" data-item="${esc(d.item.id)}" title="${done ? 'Mark not done' : (d.item.items || []).length ? 'Mark it and everything inside done' : 'Mark done'}">${ic(done ? 'checked' : 'circle')}</button>`
      : `<span style="font-size:18px;color:${color(d.project.color)};width:21px;text-align:center">⚑</span>`}
    <a class="grow" href="/app/projects/${pid}" style="color:inherit;text-decoration:none;min-width:0"><div class="title ellipsis">${esc(title)}${d.item?.urgent && !done ? ' <span class="urgent-tag">URGENT</span>' : ''}</div>
      <div class="small muted ellipsis">${[d.project.title || 'Untitled project', ...d.path].map(esc).join(' › ')}</div></a>
    ${d.due ? dueChip(d.due, { done }) : ''}
    ${upcoming && d.item ? `<button class="btn ghost sm icon" data-act="project-urgent" data-project="${pid}" data-item="${esc(d.item.id)}" title="Mark urgent: move it onto today’s list">!</button>` : ''}</div>`;
}

/** On the Today screen: project subtasks on today's list (urgent, or due within the setting's window). Counted in the ring. */
function projectTodaySection() {
  const list = store.projectToday();
  if (!list.length) return '';
  const open = list.filter(d => d.item && !M.itemDone(d.item)).length;
  return `<div><div class="section-title">${ic('layers')}Project tasks <span class="count">${open}</span><span class="grow"></span>${projectTodaySelect()}</div>
    <div class="card">${list.map(d => projectDeadlineRow(d)).join('')}</div></div>`;
}

/** Project deadlines in the next week that aren't on today's list. Not counted. */
function projectUpcomingSection() {
  const list = store.projectUpcoming();
  if (!list.length) return '';
  return `<div><div class="section-title">⚑ Coming up in projects <span class="count">${list.length}</span>
      <span class="small muted" style="font-weight:400">not counted in today’s progress</span><span class="grow"></span>${store.projectToday().length ? '' : projectTodaySelect()}</div>
    <div class="card">${list.map(d => projectDeadlineRow(d, { upcoming: true })).join('')}</div></div>`;
}

const projectEdit = (el, fn, key) => projEdit(el.dataset.project || ui.projectId, fn, key);


// ---------- Study ----------
// A session runs in this browser (saved so it survives a reload). Courses, logs and flashcards sync.
const STUDY_KEY = 'cadence:studyRun';
let studyRun = (() => { try { return JSON.parse(localStorage.getItem(STUDY_KEY) || 'null'); } catch { return null; } })();
const saveRun = () => { try { studyRun ? localStorage.setItem(STUDY_KEY, JSON.stringify(studyRun)) : localStorage.removeItem(STUDY_KEY); } catch { /* storage blocked */ } };
const studyNotified = new Set();
let lastActivity = Date.now(), lastScreenNudge = 0;
for (const ev of ['mousemove', 'keydown', 'pointerdown', 'wheel']) addEventListener(ev, () => { lastActivity = Date.now(); }, { passive: true, capture: true });

/** What the clock shows: time left in the round / period / session, or time so far. */
function studyClockMs(r, now = Date.now()) {
  if (r.mode === 'timed') return M.timedState(r, now).msLeft;
  if (r.mode === 'dynamic') return r.taskBased || r.wrapUp ? M.runElapsed(r, now) : M.periodMsLeft(r, now);
  return M.offlineMsLeft(r, now) ?? M.runElapsed(r, now);
}

function studyNotify(title, body) {
  reminders.deliver({ kind: 'nudge', title, body, tint: '#5e5ce6' }, ['notification', 'banner', 'sound']);
}

function startStudy(r) { studyRun = r; studyNotified.clear(); ui.studyLast = null; saveRun(); render(); studyTick(); }

function finishStudy() {
  const r = studyRun;
  if (!r) return;
  const log = M.runLog(r);
  if (log.minutes > 0 || log.completed > 0) store.saveStudyLog(log);
  // Studying counts for Focus too (points, levels, streak).
  if (log.minutes > 0) {
    const percent = log.mode === 'offline' ? Math.max(0, 100 - Math.round(100 * log.screenSeconds / (log.minutes * 60))) : 100;
    store.saveFocusSession({ id: log.id, startedAt: log.startedAt, endedAt: log.endedAt, plannedMinutes: log.minutes, actualMinutes: log.minutes, picked: 1, finished: 1,
      finishedTitles: [`Study: ${log.title}`], finishedIds: [], awaySeconds: log.mode === 'offline' ? log.screenSeconds : 0, focusPercent: percent, device: 'web', points: M.studyPoints(log.minutes, percent) });
  }
  if (r.mode === 'dynamic' && r.courseId) store.editCourse(r.courseId, c => { c.phase = r.phase; });
  studyRun = null; saveRun();
  ui.studyLast = log;
  render();
}

function updateRun(fn) { if (!studyRun) return; fn(studyRun); saveRun(); render(); }

let studyTimer = null;
function studyTick() {
  clearInterval(studyTimer);
  if (!studyRun) return;
  studyTimer = setInterval(() => {
    const r = studyRun;
    if (!r) { clearInterval(studyTimer); return; }
    const now = Date.now();
    if (!r.pausedAt) {
      if (r.mode === 'timed') {
        const st = M.timedState(r, now);
        if (st.finished) { studyNotify('Study session done', `${r.rounds} round${r.rounds === 1 ? '' : 's'} of ${r.title}. Nice work.`); finishStudy(); return; }
        const key = `${st.round}|${st.onBreak}`;
        if (!studyNotified.has(key)) {
          studyNotified.add(key);
          if (!(st.round === 1 && !st.onBreak)) {
            if (st.onBreak) studyNotify(`Break: ${r.breakMinutes} min`, `Round ${st.round} of ${r.rounds} done. Stand up, stretch, look away from the screen.`);
            else studyNotify(`Round ${st.round} of ${r.rounds}`, `Back to ${r.title}.`);
            render();
          }
        }
      } else if (r.mode === 'dynamic' && !r.taskBased && !r.wrapUp && M.periodMsLeft(r, now) <= 0 && !studyNotified.has(`p${r.cycle}|${r.index}`)) {
        studyNotified.add(`p${r.cycle}|${r.index}`);
        const last = r.index + 1 >= r.periods.length && r.cycle >= (r.repeats || 1);
        if (r.autoAdvance) {
          if (last) { studyNotify('Session done', `${r.title}: all intervals finished. Nice work.`); finishStudy(); return; }
          updateRun(x => M.nextPeriod(x, now));
          const n = M.runPeriod(studyRun);
          studyNotify(`${n.title}: ${n.minutes} min`, n.kind === 'breakTime' ? 'Break time. Look away from the screen.' : `Back to ${r.title}.`);
        } else {
          const next = last ? 'wrap up' : (r.periods[r.index + 1] || r.periods[0]).title;
          studyNotify(`Time's up: ${M.runPeriod(r).title}`, `Next: ${next}. Move on when you're ready.`);
        }
      } else if (r.mode === 'offline') {
        // Using this page during a no-computer session is noted, with a reminder every couple of minutes.
        if (document.visibilityState === 'visible' && now - lastActivity < 2000) {
          r.screenMs += 1000;
          if (r.screenMs >= 20_000 && now - lastScreenNudge > 120_000) { lastScreenNudge = now; studyNotify('No-computer session', `You're on the computer. Back to ${r.title} on paper?`); }
          if (r.screenMs % 15_000 === 0) saveRun();
        }
        const left = M.offlineMsLeft(r, now);
        if (left != null && left <= 0 && !studyNotified.has('offline-done')) {
          studyNotified.add('offline-done');
          studyNotify("Time's up", `${r.plannedMinutes} min of ${r.title} away from the screen. End the session in Cadence to log it.`);
        }
      }
    }
    const ms = studyClockMs(r, now);
    for (const el of document.querySelectorAll('[data-study-clock]')) el.textContent = M.fmtStudyClock(ms);
    for (const el of document.querySelectorAll('[data-study-elapsed]')) el.textContent = M.fmtStudyClock(M.runElapsed(r, now));
    for (const el of document.querySelectorAll('[data-study-ring]')) {
      const total = Number(el.dataset.total) || 1;
      el.style.strokeDashoffset = String(2 * Math.PI * 90 * (1 - Math.max(0, Math.min(1, ms / total))));
    }
    for (const el of document.querySelectorAll('[data-study-screen]')) el.textContent = M.fmtStudyClock(r.screenMs);
    const badge = document.querySelector('.nav-item[href="/app/study"] .badge');
    if (badge) badge.textContent = M.fmtStudyClock(ms);
  }, 1000);
}
if (studyRun) setTimeout(studyTick, 0);

const ruleChip = (label, rule) => `<span class="rule-chip ${rule}">${ic(rule === 'closed' ? 'lock' : 'book')} ${label}: ${M.NOTE_RULES[rule]}</span>`;
function phaseBanner(course, phase = course.phase) {
  const r = M.courseRules(course, phase), info = M.PHASE_INFO[phase];
  return `<div class="phase-banner"><span class="phase-tag" style="background:${color(course.color)}">${info.title}</span><span class="small muted grow">${esc(info.blurb)}</span>
    ${ruleChip('Homework', r.homework)}${ruleChip('Quiz', r.quiz)}</div>`;
}
function bigClock(ms, total, caption, tint = 'var(--accent)') {
  const c = 2 * Math.PI * 90, f = Math.max(0, Math.min(1, ms / Math.max(1, total)));
  return `<div class="big-clock"><svg width="200" height="200" viewBox="0 0 200 200"><circle cx="100" cy="100" r="90" fill="none" stroke="var(--line-strong)" stroke-width="12"/>
    <circle cx="100" cy="100" r="90" fill="none" stroke="${tint}" stroke-width="12" stroke-linecap="round" stroke-dasharray="${c}" style="stroke-dashoffset:${c * (1 - f)};transition:stroke-dashoffset 1s linear"
      transform="rotate(-90 100 100)" data-study-ring data-total="${total}"/></svg>
    <div class="big-clock-text"><b data-study-clock class="${ms < 0 ? 'orange' : ''}">${M.fmtStudyClock(ms)}</b><span class="small muted">${caption}</span></div></div>`;
}
function mistakeList(course, title = 'What you got wrong') {
  const list = M.openMistakes(course);
  if (!list.length) return '';
  return `<div class="mistakes"><div class="orange" style="font-weight:650">${ic('refresh')} ${title}</div>
    ${list.map(m => `<div class="row"><button class="checkbtn" data-act="mistake-done" data-course="${esc(course.id)}" data-id="${esc(m.id)}" title="Got it now">${ic('circle')}</button>
      <span class="grow">${esc(m.text)}</span><span class="tiny muted">${M.fmtDay(new Date(m.addedAt), { month: 'short', day: 'numeric' })}</span></div>`).join('')}</div>`;
}

function studyView() {
  const tab = store.device('studyTab', 'session');
  const tabs = [['session', 'Session'], ['courses', 'Presets'], ['history', 'History']];
  const body = tab === 'courses' ? coursesPanel() : tab === 'history' ? studyHistory() : studyRun ? runningStudy() : studySetup();
  return `<div class="header"><div class="grow"><h1>Study</h1><div class="sub">Interval presets (the class period, 25 on / 5 off, your own) or time away from the screen.</div></div>
      <div class="seg">${tabs.map(([k, l]) => `<button class="${tab === k ? 'on' : ''}" data-act="study-tab" data-tab="${k}">${l}</button>`).join('')}</div></div>
    <div class="page stack" style="max-width:1000px">${body}</div>`;
}

function studyStats() {
  const today = store.studyMinutes(new Date()), week = [...Array(7)].reduce((n, _, i) => n + store.studyMinutes(M.addDays(new Date(), -i)), 0);
  const tile = (v, l, i, hue, href) => `<${href ? `a href="${href}"` : 'div'} class="stat" style="background:${tint(hue, .1)};${href ? 'text-decoration:none;color:inherit' : ''}"><span style="color:${hue}">${ic(i)}</span><div><b>${v}</b><span class="small muted">${l}</span></div></${href ? 'a' : 'div'}>`;
  return `<div class="stats4">${tile(M.fmtDuration(today * 60), 'studied today', 'clock', '#5e5ce6')}${tile(M.fmtDuration(week * 60), 'in the last 7 days', 'week', '#0a84ff')}
    ${tile(store.studyStreak, 'day streak', 'flame', '#ff9f0a')}${tile(store.dueCardCount, 'flashcards due', 'cards', '#82a8ef', '/app/flashcards')}</div>`;
}

/** This session's copy of the chosen preset (saved one, or a built-in "tpl:<name>"): change any length before starting. */
function studyDraft() {
  const key = store.device('studyPreset', 'tpl:classPeriod');
  if (ui.studyDraft?.key !== key) {
    const saved = store.courses.get(key);
    ui.studyDraft = { key, course: saved ? structuredClone(saved) : M.templateCourse(key.replace('tpl:', '')) };
  }
  return ui.studyDraft;
}

function studySetup() {
  const d = store.device('studySetup', {}), mode = M.STARTABLE_MODES.includes(d.mode) ? d.mode : 'dynamic', courses = store.activeCourses;
  const draft = studyDraft(), c = draft.course, saved = store.courses.get(draft.key);
  const last = ui.studyLast;
  const minutesInput = (value, attrs, max = 480) => `<span class="min-field"><input class="input sm" type="number" min="1" max="${max}" value="${value}" ${attrs}>
    <select class="input sm" ${attrs.replace('data-draft', 'data-draft-pick')}><option value="">min</option>${[5, 10, 15, 20, 25, 30, 45, 50, 60, 90, 120].map(m => `<option value="${m}">${m} min</option>`).join('')}</select></span>`;
  let options;
  if (mode === 'offline') {
    const pm = d.plannedMinutes ?? 60;
    options = `<label class="row small">How long <select class="input sm" style="width:auto" data-study-opt="plannedMinutes">${[30, 45, 60, 90, 120, 180, 0].map(m => `<option value="${m}" ${m === pm ? 'selected' : ''}>${m ? M.fmtDuration(m * 60) : 'Until I stop'}</option>`).join('')}</select></label>
      <div class="small muted">Close the laptop or walk away from it. If you use this page during the session, Cadence notes it and reminds you.</div>`;
  } else {
    const changed = saved && JSON.stringify([saved.periods, saved.repeats, saved.autoAdvance, saved.taskBased]) !== JSON.stringify([c.periods, c.repeats, c.autoAdvance, c.taskBased]);
    options = `${c.showPhase !== false && saved ? phaseBanner(saved) : ''}
      ${c.showPhase !== false && saved && M.openMistakes(saved).length ? `<div class="orange small">${ic('refresh')} You’ll start with ${M.openMistakes(saved).length} thing(s) you got wrong last time.</div>` : ''}
      <div class="row small">Each interval ends <div class="seg"><button class="${c.taskBased ? '' : 'on'}" data-act="draft-taskbased" data-v="0">When its time is up</button><button class="${c.taskBased ? 'on' : ''}" data-act="draft-taskbased" data-v="1">When its tasks are done</button></div></div>
      <div class="period-strip">${c.periods.map((p, i) => p.enabled === false ? '' : `<span class="period-pill ${p.kind === 'breakTime' ? 'brk' : ''}"><b>${esc(p.title)}</b>${c.taskBased ? `<span class="tiny muted">${p.tasks.length} task${p.tasks.length === 1 ? '' : 's'}</span>` : minutesInput(p.minutes, `data-draft="minutes" data-i="${i}"`)}</span>`).join('<span class="muted">›</span>')}</div>
      <div class="row small" style="gap:14px">Repeat <input class="input sm" type="number" min="1" max="20" value="${c.repeats || 1}" data-draft="repeats" style="width:60px">×
        <label class="check"><input type="checkbox" data-draft="autoAdvance" ${c.autoAdvance ? 'checked' : ''}>Move on to the next interval by itself</label></div>
      <div class="row small"><span class="muted grow">${c.taskBased ? 'Tick off each interval’s tasks, then move on.' : `About ${M.fmtDuration(M.activePeriods(c).reduce((n, p) => n + p.minutes, 0) * (c.repeats || 1) * 60)} in all. Change any length; it’s just for this session unless you save it.`}</span>
        ${saved ? (changed ? `<button class="btn sm" data-act="draft-save">Save to ${esc(saved.title)}</button>` : '') : '<button class="btn sm" data-act="draft-save">Save as my preset</button>'}</div>`;
  }
  return `${last ? `<div class="callout" style="background:${tint('#30d158', .12)}"><span class="big green">${ic('check')}</span><div class="grow"><b>Logged ${M.fmtDuration(last.minutes * 60)} of ${esc(last.title)}</b>
      <div class="small muted">${M.STUDY_MODES[last.mode].title}${last.mode === 'offline' ? (last.screenSeconds > 30 ? ` · screen used ${M.fmtDuration(last.screenSeconds)}` : ' · screen-free') : ''}${last.phase ? ` · ${M.PHASE_INFO[last.phase].title} phase` : ''}</div></div>
      <button class="btn ghost sm icon" data-act="study-dismiss">${ic('x')}</button></div>` : ''}
    <div class="mode-cards two">${M.STARTABLE_MODES.map(k => { const m = M.STUDY_MODES[k]; return `<button class="mode-card ${mode === k ? 'on' : ''}" data-act="study-mode" data-mode="${k}">
      <b>${ic(m.icon)} ${m.title}</b><span class="small muted">${m.blurb}</span></button>`; }).join('')}</div>
    <div class="card pad stack" style="gap:12px">
      <div class="row"><label class="row small">Preset <select class="input sm" style="width:auto" data-study-opt="preset">
        ${courses.length ? `<optgroup label="Your presets">${courses.map(x => `<option value="${x.id}" ${x.id === draft.key ? 'selected' : ''}>${esc(x.title)}</option>`).join('')}</optgroup>` : ''}
        <optgroup label="Built in">${Object.entries(M.TEMPLATES).filter(([k]) => k !== 'blank').map(([k, l]) => `<option value="tpl:${k}" ${draft.key === `tpl:${k}` ? 'selected' : ''}>${l}</option>`).join('')}</optgroup></select></label>
        <button class="btn sm" data-act="course-new">${ic('plus')} New preset</button></div>
      <input class="input" id="studyTitle" placeholder="${saved ? `What you’re studying (default: ${esc(saved.chapter || saved.title)})` : 'What you’re studying, e.g. Ch. 4 problems'}">
      ${options}
      <div class="row"><span class="grow"></span><button class="btn primary" data-act="study-start">${ic('play')} Start ${mode === 'offline' ? 'no-computer' : 'interval'} session</button></div>
    </div>
    ${studyStats()}`;
}

function runningStudy() {
  const r = studyRun, now = Date.now(), course = r.courseId ? store.courses.get(r.courseId) : null;
  let body = '';
  if (r.mode === 'timed') {
    const st = M.timedState(r, now), total = (st.onBreak ? r.breakMinutes : r.studyMinutes) * 60_000;
    body = `<div class="card pad row" style="gap:30px">${bigClock(st.msLeft, total, st.onBreak ? 'break' : 'studying', st.onBreak ? 'var(--green)' : 'var(--accent)')}
      <div class="stack" style="gap:10px"><h2 style="margin:0">${st.onBreak ? 'Break' : `Round ${st.round} of ${r.rounds}`}</h2>
        <div class="muted">${st.onBreak ? 'Stand up, stretch, drink some water, look away from the screen.' : `Just ${esc(r.title)}. Phone away.`}</div>
        <div class="row" style="gap:5px">${[...Array(r.rounds)].map((_, i) => `<span class="round-pip ${i + 1 < st.round || (i + 1 === st.round && st.onBreak) ? 'done' : i + 1 === st.round ? 'now' : ''}"></span>`).join('')}</div>
        <div class="small muted">${r.studyMinutes} min study · ${r.breakMinutes} min break</div></div></div>`;
  } else if (r.mode === 'offline') {
    const left = M.offlineMsLeft(r, now);
    body = `<div class="card pad row" style="gap:30px">${bigClock(left ?? M.runElapsed(r, now), left == null ? 1 : r.plannedMinutes * 60_000, left == null ? 'away' : left < 0 ? 'over' : 'left', 'var(--teal, #30b0c7)')}
      <div class="stack" style="gap:10px"><h2 style="margin:0">Away from the screen</h2>
        <div class="muted">Close the laptop or walk away. Paper, textbook, whiteboard. Come back and end the session when you’re done.</div>
        <div class="${r.screenMs < 10_000 ? 'green' : 'orange'}">${ic(r.screenMs < 10_000 ? 'check' : 'monitor')} Screen used: <span data-study-screen>${M.fmtStudyClock(r.screenMs)}</span></div></div></div>`;
  } else {
    const strip = `<div class="period-strip"><span class="small muted">Cycle ${r.cycle}</span>${r.periods.map((p, i) => `<button class="period-pill ${i === r.index && !r.wrapUp ? 'now' : i < r.index || r.wrapUp ? 'done' : ''}" data-act="period-go" data-i="${i}">${i < r.index || r.wrapUp ? ic('check') + ' ' : ''}${esc(p.title)}</button>`).join('')}</div>`;
    if (r.wrapUp) {
      const next = M.nextPhase(r.phase);
      const ph = r.showPhase !== false;
      body = `${course && ph ? phaseBanner(course, r.phase) : ''}${strip}<div class="card pad stack" style="gap:12px"><h2 style="margin:0">${ic('check')} ${ph ? `Cycle ${r.cycle} done` : 'All intervals done'}</h2>
        <div class="muted">${ph ? 'Repeat, and move on to the next phase if it seems good.' : 'Go again, or finish and log it.'}</div>
        <div class="row" style="flex-wrap:wrap"><button class="btn" data-act="cycle-repeat" data-phase="${r.phase}">${ic('refresh')} ${ph ? `Repeat ${M.PHASE_INFO[r.phase].title.toLowerCase()}` : 'Go again'}</button>
          ${next && ph ? `<button class="btn primary" data-act="cycle-repeat" data-phase="${next}">Move on to ${M.PHASE_INFO[next].title.toLowerCase()}</button>` : ''}<span class="grow"></span>
          <button class="btn" data-act="study-finish">Finish and log</button></div>
        ${course && ph ? `<div class="row"><input class="input grow" id="nextChapter" placeholder="Done with ${esc(course.chapter || 'this chapter')}? Next chapter"><button class="btn" data-act="cycle-chapter">Start it in the reading phase</button></div>` : ''}</div>`;
    } else {
      const p = M.runPeriod(r), left = M.periodMsLeft(r, now);
      const rule = M.periodRule(p.kind, course ? M.courseRules(course, r.phase) : M.PHASE_INFO[r.phase].rules);
      const next = r.periods[r.index + 1]?.title || 'Wrap up';
      body = `${course && r.showPhase !== false ? phaseBanner(course, r.phase) : ''}${strip}<div class="card pad stack" style="gap:12px">
        <div class="row" style="align-items:flex-start;gap:24px">${r.taskBased ? '' : bigClock(left, p.minutes * 60_000, left < 0 ? 'over' : 'left')}
          <div class="stack grow" style="gap:8px"><div class="row"><h2 style="margin:0">${esc(p.title)}</h2>${rule ? ruleChip('Notes', rule) : ''}</div>
            ${p.blurb ? `<div class="muted">${esc(p.blurb)}</div>` : ''}
            ${p.tasks.length ? `<div class="stack" style="gap:4px">${p.tasks.map((t, i) => `<label class="check"><input type="checkbox" data-act-change="period-task" data-i="${i}" ${M.isChecked(r, p, i) ? 'checked' : ''}><span class="${M.isChecked(r, p, i) ? 'muted' : ''}">${esc(t)}</span></label>`).join('')}</div>`
              : r.taskBased ? '<div class="small muted">No tasks programmed for this period. Add them under Courses, or move on when you’re done.</div>' : ''}</div></div>
        ${r.index === 0 && course ? mistakeList(course, 'Start here: what you got wrong last time') : ''}
        ${p.kind === 'quiz' || p.kind === 'officeHours' ? `<form class="row" data-form="mistake"><input class="input grow" id="mistakeText" placeholder="${p.kind === 'quiz' ? 'Something you got wrong (you’ll start there next time)' : 'Something to come back to'}">
            <label class="check small"><input type="checkbox" id="mistakeCard" ${course ? '' : 'disabled'}>Also make a flashcard</label><button class="btn">Add</button></form>
          ${r.mistakes.length ? `<div class="small muted">This session: ${r.mistakes.map(esc).join(' · ')}</div>` : ''}` : ''}
        <div class="row">${r.taskBased ? '' : `<span class="row small">Length <button class="btn sm" data-act="period-less">−5</button><input class="input sm" type="number" min="1" max="480" value="${p.minutes}" data-run-minutes="1" style="width:64px"> min<button class="btn sm" data-act="period-more5">+5</button></span>`}<span class="grow"></span>
          <button class="btn ${r.taskBased && p.tasks.length && !M.periodTasksDone(r, p) ? '' : 'primary'}" data-act="period-next">Next: ${esc(next)} ${ic('right')}</button></div></div>`;
    }
  }
  return `<div class="row"><div class="grow"><div class="small muted">${ic(M.STUDY_MODES[r.mode].icon)} ${M.STUDY_MODES[r.mode].title}</div><h2 style="margin:2px 0 0">${esc(r.title)}</h2></div>
      <span class="small muted"><span data-study-elapsed>${M.fmtStudyClock(M.runElapsed(r, now))}</span> so far</span>
      <button class="btn" data-act="study-pause">${ic(r.pausedAt ? 'play' : 'pause')} ${r.pausedAt ? 'Resume' : 'Pause'}</button>
      <button class="btn" data-act="study-end">End…</button></div>
    ${body}${r.pausedAt ? `<div class="orange">${ic('pause')} Paused. The clock picks up where it left off.</div>` : ''}`;
}

function studyHistory() {
  const logs = store.sortedStudyLogs, days = [...Array(14)].map((_, i) => M.addDays(M.startOfDay(new Date()), i - 13));
  const mins = days.map(d => store.studyMinutes(d)), top = Math.max(30, ...mins);
  return `${studyStats()}
    <div class="card pad"><div class="study-bars">${days.map((d, i) => `<div class="sb"><span class="tiny muted">${mins[i] || ''}</span><i style="height:${Math.max(2, mins[i] / top * 90)}px;${M.isToday(d) ? 'background:var(--accent)' : ''}"></i><span class="tiny muted">${M.WEEKDAY_LETTER[d.getDay()]}</span></div>`).join('')}</div></div>
    <div><div class="section-title">${ic('list')}Sessions <span class="count">${logs.length}</span></div>
      <div class="card">${logs.length ? logs.slice(0, 60).map(l => { const c = l.courseID && store.courses.get(l.courseID);
        return `<div class="crow"><span style="color:${c ? color(c.color) : 'var(--muted)'}">${ic(M.STUDY_MODES[l.mode]?.icon || 'study')}</span>
        <div class="grow" style="min-width:0"><div class="title ellipsis">${esc(l.title)}</div><div class="meta"><span>${M.fmtDay(new Date(l.startedAt), { weekday: 'short', month: 'short', day: 'numeric' })} ${M.fmtTime(new Date(l.startedAt))}</span>
          <span>${M.STUDY_MODES[l.mode]?.title || ''}</span>${l.phase ? `<span>${M.PHASE_INFO[l.phase].title} phase</span>` : ''}${l.note ? `<span class="ellipsis">${esc(l.note)}</span>` : ''}</div></div>
        <b class="mono">${M.fmtDuration(l.minutes * 60)}</b><button class="btn ghost sm icon" data-act="studylog-delete" data-id="${esc(l.id)}" title="Delete">${ic('trash')}</button></div>`; }).join('')
        : '<div class="crow muted">Nothing yet. Start a session under Session.</div>'}</div></div>`;
}

function coursesPanel() {
  const courses = store.activeCourses;
  let sel = store.device('studyCourseEdit', '');
  if (!store.courses.get(sel) && courses[0]) sel = courses[0].id;
  const c = store.courses.get(sel);
  return `<div class="courses"><div class="course-list">${courses.map(x => `<button class="course-item ${x.id === sel ? 'on' : ''}" data-act="course-pick" data-id="${x.id}" style="--pc:${color(x.color)}">
      <span class="pbar"></span><span class="grow" style="min-width:0"><b class="ellipsis">${esc(x.title)}</b><span class="tiny muted ellipsis">${M.PHASE_INFO[x.phase].title}${x.chapter ? ` · ${esc(x.chapter)}` : ''}</span></span></button>`).join('')}
      <select class="input sm" data-act-change="preset-new"><option value="">+ New preset…</option>${Object.entries(M.TEMPLATES).map(([k, l]) => `<option value="${k}">${k === 'blank' ? 'Blank' : `From ${l}`}</option>`).join('')}</select>
      ${courses.length ? '' : '<div class="small muted">A preset is a set of intervals you study with: the class period, 25 on / 5 off, or your own. Make one per subject if you like (Chemistry, CS), each with its own lengths, tasks and phase.</div>'}</div>
    <div class="grow stack" style="gap:14px;min-width:0">${c ? courseEditor(c) : '<div class="muted">Pick a preset to change it.</div>'}</div></div>`;
}

function courseEditor(c) {
  const cid = esc(c.id);
  const field = (k, v, ph, cls = 'input') => `<input class="${cls}" id="cf-${k}-${cid}" value="${esc(v)}" placeholder="${ph}" data-course-field="${k}" data-course="${cid}" autocomplete="off">`;
  const rulesTable = M.PHASES.map(p => { const r = M.courseRules(c, p);
    const sel = key => `<select class="input sm" data-course-rule="${p}|${key}" data-course="${cid}">${Object.entries(M.NOTE_RULES).map(([k, l]) => `<option value="${k}" ${r[key] === k ? 'selected' : ''}>${l}</option>`).join('')}</select>`;
    return `<tr class="${p === c.phase ? 'on' : ''}"><td><b>${M.PHASE_INFO[p].title}</b><div class="tiny muted">${esc(M.PHASE_INFO[p].blurb)}</div></td><td>${sel('homework')}</td><td>${sel('quiz')}</td></tr>`; }).join('');
  const periods = c.periods.map((p, i) => `<div class="period-edit ${p.enabled === false ? 'off' : ''}">
      <div class="row"><input type="checkbox" data-act-change="period-enable" data-course="${cid}" data-i="${i}" ${p.enabled === false ? '' : 'checked'}>
        <input class="ptext top" id="pt-${esc(p.id)}" value="${esc(p.title)}" data-period-field="title" data-course="${cid}" data-i="${i}">
        ${c.taskBased ? '' : `<input class="input sm" type="number" min="1" max="240" value="${p.minutes}" data-period-field="minutes" data-course="${cid}" data-i="${i}" style="width:64px"><span class="small muted">min</span>`}
        <button class="btn ghost sm icon" data-act="period-move" data-course="${cid}" data-i="${i}" data-d="-1" ${i ? '' : 'disabled'}>↑</button>
        <button class="btn ghost sm icon" data-act="period-move" data-course="${cid}" data-i="${i}" data-d="1" ${i < c.periods.length - 1 ? '' : 'disabled'}>↓</button>
        <button class="btn ghost sm icon danger" data-act="period-remove" data-course="${cid}" data-i="${i}">${ic('x')}</button></div>
      <input class="ptext small muted" id="pb-${esc(p.id)}" value="${esc(p.blurb)}" placeholder="What to do in this period" data-period-field="blurb" data-course="${cid}" data-i="${i}">
      ${p.tasks.map((t, ti) => `<div class="row small"><span class="muted">☐</span><span class="grow">${esc(t)}</span><button class="btn ghost sm icon" data-act="period-task-remove" data-course="${cid}" data-i="${i}" data-t="${ti}">${ic('x')}</button></div>`).join('')}
      <form class="row small" data-form="period-task" data-course="${cid}" data-i="${i}"><span class="muted">+</span><input class="ptext" id="ptask-${esc(p.id)}" placeholder="Add a task for this period"></form></div>`).join('');
  return `<div class="row"><input class="ptitle-input" id="cf-title-${cid}" value="${esc(c.title)}" data-course-field="title" data-course="${cid}" placeholder="Preset name" autocomplete="off">
      <span class="pswatches">${Object.keys(M.COLORS).map(x => `<button class="pswatch ${c.color === x ? 'on' : ''}" style="background:${M.COLORS[x]}" data-act="course-color" data-color="${x}" data-course="${cid}"></button>`).join('')}</span>
      <button class="btn ghost sm icon danger" data-act="course-delete" data-course="${cid}" title="Delete course">${ic('trash')}</button></div>
    ${field('chapter', c.chapter, 'What you’re on now (e.g. Ch. 4: Stoichiometry)')}
    <label class="check"><input type="checkbox" data-act-change="course-showphase" data-course="${cid}" ${c.showPhase !== false ? 'checked' : ''}>Use the phase, note rules and “what you got wrong” (the class-period way of studying)</label>
    ${c.showPhase === false ? '' : `<div class="card pad stack" style="gap:10px"><div class="section-title" style="margin:0">${ic('study')} Phase</div>
      <div class="seg">${M.PHASES.map(p => `<button class="${c.phase === p ? 'on' : ''}" data-act="course-phase" data-course="${cid}" data-phase="${p}">${M.PHASE_INFO[p].title}</button>`).join('')}</div>
      <div class="small muted">These overlap a lot with the class periods, so it’s guidance: some ideas to try while studying.</div>
      <table class="rules"><tr><th>Phase</th><th>Homework</th><th>Quiz</th></tr>${rulesTable}</table></div>`}
    <div class="card pad stack" style="gap:10px"><div class="row"><div class="section-title grow" style="margin:0">${ic('timer')} Intervals</div>
        <div class="seg"><button class="${c.taskBased ? '' : 'on'}" data-act="course-taskbased" data-course="${cid}" data-v="0">Timed</button><button class="${c.taskBased ? 'on' : ''}" data-act="course-taskbased" data-course="${cid}" data-v="1">By tasks</button></div></div>
      <div class="small muted">${c.taskBased ? 'Each period ends when you’ve ticked off its tasks.' : `Each interval ends when its time is up (${M.fmtDuration(M.activePeriods(c).reduce((n, p) => n + p.minutes, 0) * 60)} per round). Tasks are a checklist along the way.`}</div>
      <div class="row small" style="gap:14px">Repeat <input class="input sm" type="number" min="1" max="20" value="${c.repeats || 1}" data-course-num="repeats" data-course="${cid}" style="width:60px">×
        <label class="check"><input type="checkbox" data-act-change="course-auto" data-course="${cid}" ${c.autoAdvance ? 'checked' : ''}>Move on by itself when time’s up</label></div>
      ${periods}
      <div class="row"><select class="input sm" style="width:auto" data-act-change="period-add" data-course="${cid}"><option value="">+ Add an interval…</option>${Object.entries(M.PERIOD_KINDS).map(([k, v]) => `<option value="${k}">${v.title}</option>`).join('')}</select>
        <span class="grow"></span><select class="input sm" style="width:auto" data-act-change="preset-replace" data-course="${cid}"><option value="">Replace with…</option>${Object.entries(M.TEMPLATES).filter(([k]) => k !== 'blank').map(([k, l]) => `<option value="${k}">${l}</option>`).join('')}</select></div></div>
    ${mistakeList(c)}
    <div class="small muted">${ic('cards')} ${c.cards.length} flashcard${c.cards.length === 1 ? '' : 's'} · ${M.dueCards(c).length} due · <a href="/app/flashcards">Flashcards</a></div>`;
}

// ---------- Flashcards ----------
function flashcardsView() {
  const courses = store.activeCourses, sel = store.device('cardsCourse', ''), course = sel ? store.courses.get(sel) : null;
  const scope = course ? [course] : courses;
  const due = scope.reduce((n, c) => n + M.dueCards(c).length, 0);
  let body;
  if (!courses.length) body = '<div class="card pad muted">Flashcards belong to a preset (one per subject works well). Make one under Study › Presets first.</div>';
  else if (ui.review) body = reviewView();
  else {
    const addTo = course || store.courses.get(store.device('cardsAddTo', '')) || courses[0], q = (ui.cardSearch || '').toLowerCase();
    body = `<div class="due-hero"><div><div class="due-num">${due}</div><div class="muted">${due === 1 ? 'card due today' : 'cards due today'}</div></div><span class="grow"></span>
        <button class="btn primary" data-act="review-start" ${due ? '' : 'disabled'}>${ic('play')} Review</button></div>
      <form class="card pad stack" style="gap:8px" data-form="card-add"><div class="row"><b>New card</b>${course ? `<span class="muted">for ${esc(course.title)}</span>` : `<span class="small muted">for</span><select class="input sm" style="width:auto" data-act-change="cards-addto">${courses.map(c => `<option value="${c.id}" ${c.id === addTo.id ? 'selected' : ''}>${esc(c.title)}</option>`).join('')}</select>`}</div>
        <input class="input" id="cardFront" placeholder="Front (question)" autocomplete="off"><input class="input" id="cardBack" placeholder="Back (answer)" autocomplete="off">
        <input type="hidden" id="cardCourse" value="${addTo.id}"><div class="row"><span class="grow"></span><button class="btn">Add card</button></div></form>
      <input class="input" id="cardSearch" style="max-width:300px" placeholder="Search cards" value="${esc(ui.cardSearch || '')}" data-bind="cardSearch">
      ${scope.map(c => { const cards = c.cards.filter(k => !q || k.front.toLowerCase().includes(q) || k.back.toLowerCase().includes(q));
        return cards.length ? `<div><div class="section-title">${ic('cards')}${esc(c.title)} <span class="count">${cards.length}</span></div><div class="card">${cards.map(k => {
          const days = Math.round((M.parseKey(k.due) - M.startOfDay(new Date())) / 86_400_000);
          return `<div class="card-row"><input class="ptext" id="cfr-${esc(k.id)}" value="${esc(k.front)}" data-card-field="front" data-course="${c.id}" data-card="${esc(k.id)}">
            <input class="ptext muted" id="cba-${esc(k.id)}" value="${esc(k.back)}" placeholder="(answer)" data-card-field="back" data-course="${c.id}" data-card="${esc(k.id)}">
            <span class="tiny mono ${days <= 0 ? 'pink' : 'muted'}">${days <= 0 ? 'due' : `in ${days}d`}</span>
            <button class="btn ghost sm icon" data-act="card-delete" data-course="${c.id}" data-card="${esc(k.id)}">${ic('trash')}</button></div>`; }).join('')}</div></div>` : ''; }).join('')}`;
  }
  return `<div class="header"><div class="grow"><h1>Flashcards</h1><div class="sub">Spaced repetition: what you know comes back less often, what you miss comes back soon.</div></div>
      <select class="input" style="width:auto" data-act-change="cards-course"><option value="">All courses</option>${courses.map(c => `<option value="${c.id}" ${c.id === sel ? 'selected' : ''}>${esc(c.title)}</option>`).join('')}</select></div>
    <div class="page stack" style="max-width:900px">${body}</div>`;
}

function reviewView() {
  const rv = ui.review, [cid, kid] = rv.queue[0] || [], c = cid && store.courses.get(cid), card = c?.cards.find(k => k.id === kid);
  const head = `<div class="row"><span class="muted grow">${rv.reviewed} reviewed · ${rv.queue.length} left</span><button class="btn" data-act="review-stop">Stop</button></div>`;
  if (!card) return `${head}<div class="card pad stack" style="align-items:center;gap:8px"><span class="big green">${ic('check')}</span><b>${rv.reviewed ? `All done: ${rv.reviewed} reviewed.` : 'Nothing due.'}</b><button class="btn" data-act="review-stop">Back to cards</button></div>`;
  return `${head}<div class="flashcard"><div class="small" style="color:${color(c.color)};font-weight:650">${esc(c.title)}</div><div class="fc-front">${esc(card.front)}</div>
      ${rv.shown ? `<hr><div class="fc-back ${card.back ? '' : 'muted'}">${esc(card.back || '(no answer written)')}</div>` : ''}</div>
    ${rv.shown ? `<div class="grades">${[['again', 'Again', 'red'], ['hard', 'Hard', 'orange'], ['good', 'Good', 'green'], ['easy', 'Easy', 'blue']].map(([g, l, h], i) => `<button class="btn grade ${h}" data-act="review-grade" data-g="${g}">${l}<span class="tiny">${i + 1}</span></button>`).join('')}</div>
      <div class="small muted">Keys 1–4 also work.</div>` : `<button class="btn primary" style="width:100%" data-act="review-show">Show answer <span class="tiny">space</span></button>`}`;
}

// ---------- Notes ----------
function notesView() {
  const q = (ui.noteSearch || '').toLowerCase();
  const notes = store.sortedNotes.filter(n => !q || (n.title || '').toLowerCase().includes(q) || (n.body || '').toLowerCase().includes(q));
  let sel = ui.noteSel;
  if (!store.notes.get(sel)) sel = ui.noteSel = notes[0]?.id || null;
  const n = sel && store.notes.get(sel);
  return `<div class="header"><div class="grow"><h1>Notes</h1><div class="sub">Quick notes that sync to your Mac and iPhone.</div></div>
      <button class="btn primary" data-act="note-new">${ic('plus')} New note</button></div>
    <div class="page notes-page"><div class="note-list"><input class="input" id="noteSearch" placeholder="Search" value="${esc(ui.noteSearch || '')}" data-bind="noteSearch">
        ${notes.map(x => `<button class="note-item ${x.id === sel ? 'on' : ''}" data-act="note-pick" data-id="${x.id}"><b class="ellipsis">${x.pinned ? ic('pin') + ' ' : ''}${esc(M.noteTitle(x))}</b>
          <span class="tiny muted ellipsis">${M.fmtDay(new Date(x.updatedAt || x.createdAt), { month: 'short', day: 'numeric' })} ${esc((x.body || '').replace(/\n/g, ' ').slice(0, 60))}</span></button>`).join('')
          || '<div class="small muted" style="padding:8px">No notes yet.</div>'}</div>
      <div class="note-edit">${n ? `<div class="row"><input class="ptitle-input" id="noteTitle-${n.id}" placeholder="Title" value="${esc(n.title)}" data-note-field="title" data-id="${n.id}">
          <button class="btn ghost sm" data-act="note-pin" data-id="${n.id}">${ic('pin')} ${n.pinned ? 'Unpin' : 'Pin'}</button>
          <button class="btn ghost sm icon danger" data-act="note-delete" data-id="${n.id}" title="Delete">${ic('trash')}</button></div>
        <textarea class="note-body" id="noteBody-${n.id}" data-note-field="body" data-id="${n.id}" placeholder="Write anything…">${esc(n.body)}</textarea>`
        : '<div class="muted" style="padding:40px;text-align:center">Pick a note, or make a new one.</div>'}</div></div>`;
}

const REMINDER_TEMPLATES = [
  { title: 'Drink water', kind: 'every', everyMinutes: 60 },
  { title: 'Stand up and stretch', times: [660, 900], weekdays: [2, 3, 4, 5, 6] },
  { title: 'Take medicine', times: [480, 1200] },
  { title: 'Rest your eyes', kind: 'every', everyMinutes: 20, body: 'Look at something 20 feet away for 20 seconds.' },
  { title: 'Wind down for bed', times: [1350] },
];
const hhmm = m => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
const localDT = d => { const x = new Date(d); return `${M.dateKey(x)}T${hhmm(M.minutesOf(x))}`; };

function customRemindersView() {
  const list = store.sortedCustomReminders;
  let sel = ui.remSel;
  if (!store.customReminders.get(sel)) sel = ui.remSel = list[0]?.id || null;
  const r = sel && store.customReminders.get(sel), kind = r?.kind || 'times';
  const days = r ? (r.weekdays?.length ? r.weekdays : [1, 2, 3, 4, 5, 6, 7]) : [];
  const dayRow = `<div class="srow"><span class="small muted">Days</span> ${M.WEEKDAY_LETTER.map((l, i) => `<button class="btn sm ${days.includes(i + 1) ? 'primary' : 'ghost'}" data-act="rem-day" data-d="${i + 1}" data-id="${r?.id}">${l}</button>`).join('')}</div>`;
  const editor = !r ? '<div class="muted" style="padding:40px;text-align:center">Pick a reminder, or make a new one.</div>' : `
    <div class="row"><input class="ptitle-input" placeholder="Title" value="${esc(r.title)}" data-rem-field="title" data-id="${r.id}">
      <label class="row small"><input type="checkbox" data-rem-check="enabled" data-id="${r.id}" ${r.enabled !== false ? 'checked' : ''}> On</label>
      <button class="btn ghost sm icon danger" data-act="rem-delete" data-id="${r.id}" title="Delete">${ic('trash')}</button></div>
    <input class="input" placeholder="Message (optional)" value="${esc(r.body || '')}" data-rem-field="body" data-id="${r.id}">
    <div class="seg">${[['times', 'At set times'], ['every', 'Every so often'], ['once', 'Once']].map(([k, t]) => `<button class="${kind === k ? 'on' : ''}" data-act="rem-kind" data-k="${k}" data-id="${r.id}">${t}</button>`).join('')}</div>
    ${kind === 'times' ? `<div class="srow">${[...(r.times || [540])].sort((a, b) => a - b).map(m => `<span class="chip">${M.fmtTimeMinutes(m)} <button class="btn ghost sm icon" data-act="rem-untime" data-m="${m}" data-id="${r.id}" ${(r.times || []).length <= 1 ? 'disabled' : ''}>${ic('x')}</button></span>`).join(' ')}
        <input type="time" class="input" style="width:auto" data-rem-addtime data-id="${r.id}" title="Add a time"></div>${dayRow}` : ''}
    ${kind === 'every' ? `<div class="srow row">Every <input type="number" class="input" style="width:80px" min="5" max="720" value="${r.everyMinutes || 60}" data-rem-num="everyMinutes" data-id="${r.id}"> min
        from <input type="time" class="input" style="width:auto" value="${hhmm(r.fromMinutes ?? 540)}" data-rem-time="fromMinutes" data-id="${r.id}">
        to <input type="time" class="input" style="width:auto" value="${hhmm(r.toMinutes ?? 1020)}" data-rem-time="toMinutes" data-id="${r.id}"></div>${dayRow}` : ''}
    ${kind === 'once' ? `<div class="srow"><input type="datetime-local" class="input" style="width:auto" value="${r.at ? localDT(r.at) : ''}" data-rem-at data-id="${r.id}"></div>` : ''}
    <div class="small muted">${esc(M.reminderSummary(r))}${(() => { const n = M.nextReminderFire(r); return n ? ` · next ${M.fmtDay(n, { weekday: 'short' })} ${M.fmtTime(n)}` : ''; })()}</div>
    <div class="srow"><span class="small muted">Alert with</span> ${[['notification', 'Notification'], ['banner', 'On-screen banner'], ['sound', 'Sound']].map(([c, t]) => `<label class="row small"><input type="checkbox" data-rem-chan="${c}" data-id="${r.id}" ${(r.channels || []).includes(c) ? 'checked' : ''}> ${t}</label>`).join(' ')}</div>`;
  return `<div class="header"><div class="grow"><h1>Reminders</h1><div class="sub">Get notified about anything: drink water, stretch, take medicine. Syncs to your Mac and iPhone.</div></div>
      <select class="input" style="width:auto" data-rem-template><option value="">From a template…</option>${REMINDER_TEMPLATES.map((t, i) => `<option value="${i}">${esc(t.title)}</option>`).join('')}</select>
      <button class="btn primary" data-act="rem-new">${ic('plus')} New reminder</button></div>
    <div class="page notes-page"><div class="note-list">
        ${list.map(x => `<button class="note-item ${x.id === sel ? 'on' : ''}" data-act="rem-pick" data-id="${x.id}"><b class="ellipsis">${ic(x.enabled === false ? 'bell-off' : 'bell')} ${esc(x.title || 'Untitled')}</b>
          <span class="tiny muted ellipsis">${esc(M.reminderSummary(x))}</span></button>`).join('') || '<div class="small muted" style="padding:8px">No reminders yet.</div>'}</div>
      <div class="note-edit rem-edit">${editor}</div></div>`;
}
const remNew = over => { const r = store.upsertCustomReminder(M.newCustomReminder(over)); ui.remSel = r.id; render(); };

const actions = {
  'site-remove': el => { store.updateSettings({ blockedSites: (store.settings.blockedSites || []).filter(x => x !== el.dataset.site) }); render(); },
  'sel-toggle': () => { ui.weekSelecting = !ui.weekSelecting; if (!ui.weekSelecting) ui.weekSel = new Map(); render(); },
  'sel-done': () => { ui.weekSelecting = false; ui.weekSel = new Map(); render(); },
  'sel-clear': () => { ui.weekSel = new Map(); render(); },
  'sel-day': el => { selPickDay(M.parseKey(el.dataset.day)); render(); },
  'sel-week': () => { for (let i = 0; i < 7; i++) selPickDay(M.addDays(ui.weekStart, i)); render(); },
  'sel-mode': el => selEdit(t => { if (el.dataset.v) t.mode = 'untilDone'; else { delete t.mode; delete t.dueDate; } }, el.dataset.v ? 'Kept on the checklist until done' : 'Now just on their day'),
  'sel-urgent': el => selEdit(t => { if (el.dataset.v) t.urgent = true; else delete t.urgent; }, el.dataset.v ? 'Marked urgent' : 'Not urgent'),
  'sel-checkoff': () => openModal({ type: 'sel-checkoff' }),
  'sel-checkoff-go': () => {
    const text = $('#selRefl')?.value || '';
    if (M.countWords(text) < store.settings.minReflectionWords) return;
    for (const o of weekPicked()) if (!o.resolved) store.complete(o, text);
    ui.weekSel = new Map(); closeModal(); toast('Checked off', { icon: 'check' });
  },
  'sel-del': el => {
    const scope = el.dataset.scope, occs = weekPicked();
    if (scope === 'all') {
      const ts = selTasks();
      openModal({ type: 'confirm', title: `Delete ${ts.length} task${ts.length === 1 ? '' : 's'} completely?`, text: 'Every repeat goes too. Past reflections stay.', yes: 'Delete', fn: () => {
        pushWeekUndo(); const copies = ts.map(t => structuredClone(t)); ts.forEach(t => store.deleteTask(t.id)); ui.weekSel = new Map(); render();
        toast(`Deleted ${copies.length}`, { icon: 'trash', undo: () => { copies.forEach(t => store.upsertTask(t)); render(); } });
      } });
      return;
    }
    pushWeekUndo();
    const copies = new Map();
    for (const o of occs) {
      const t = store.tasks.get(o.task.id); if (!t) continue;
      if (!copies.has(t.id)) copies.set(t.id, structuredClone(t));
      const next = M.deleteOccurrence(t, o.day, scope === 'later' ? 'fromHere' : 'one');
      if (next) store.upsertTask(next); else store.deleteTask(t.id);
    }
    ui.weekSel = new Map(); render();
    toast(`Deleted ${occs.length}`, { icon: 'trash', undo: () => { copies.forEach(t => store.upsertTask(t)); render(); } });
  },
  'rem-new': () => remNew(),
  'rem-pick': el => { ui.remSel = el.dataset.id; render(); },
  'rem-delete': el => { const r = store.customReminders.get(el.dataset.id); if (!r) return; store.deleteCustomReminder(r.id); ui.remSel = null; render(); toast('Reminder deleted', { icon: 'trash', undo: () => { store.upsertCustomReminder(r); render(); } }); },
  'rem-kind': el => { store.editCustomReminder(el.dataset.id, r => { r.kind = el.dataset.k; }); render(); },
  'rem-untime': el => { store.editCustomReminder(el.dataset.id, r => { r.times = (r.times || []).filter(m => m !== +el.dataset.m); }); render(); },
  'rem-day': el => {
    store.editCustomReminder(el.dataset.id, r => {
      const w = new Set(r.weekdays?.length ? r.weekdays : [1, 2, 3, 4, 5, 6, 7]), d = +el.dataset.d;
      w.has(d) ? w.delete(d) : w.add(d);
      if (w.size) r.weekdays = w.size === 7 ? [] : [...w].sort();
    });
    render();
  },
  'nav-fold': el => { const f = new Set(store.device('navFolded', [])); f.has(el.dataset.sec) ? f.delete(el.dataset.sec) : f.add(el.dataset.sec); store.setDevice('navFolded', [...f]); render(); },
  'study-tab': el => { store.setDevice('studyTab', el.dataset.tab); render(); },
  'study-mode': el => { store.setDevice('studySetup', { ...store.device('studySetup', {}), mode: el.dataset.mode }); render(); },
  'study-preset': el => { store.setDevice('studySetup', { ...store.device('studySetup', {}), studyMinutes: +el.dataset.s, breakMinutes: +el.dataset.b, rounds: +el.dataset.r }); render(); },
  'study-taskbased': el => { store.setDevice('studySetup', { ...store.device('studySetup', {}), taskBased: el.dataset.v === '1' }); render(); },
  'study-dismiss': () => { ui.studyLast = null; render(); },
  'study-start': () => {
    const d = store.device('studySetup', {}), mode = M.STARTABLE_MODES.includes(d.mode) ? d.mode : 'dynamic';
    const draft = studyDraft(), saved = store.courses.get(draft.key), typed = ($('#studyTitle')?.value || '').trim();
    const r = M.newRun(mode, draft.course, typed || (saved ? (saved.chapter ? `${saved.title}: ${saved.chapter}` : saved.title) : draft.course.title));
    r.courseId = saved?.id ?? null;
    r.plannedMinutes = d.plannedMinutes ?? 60;
    startStudy(r);
  },
  'draft-taskbased': el => { studyDraft().course.taskBased = el.dataset.v === '1'; render(); },
  'draft-save': () => {
    const draft = studyDraft(), saved = store.courses.get(draft.key), c = draft.course;
    if (saved) store.editCourse(saved.id, x => { Object.assign(x, { periods: c.periods, repeats: c.repeats, autoAdvance: c.autoAdvance, taskBased: c.taskBased }); });
    else {
      const copy = store.upsertCourse({ ...structuredClone(c), id: M.uuid(), periods: c.periods.map(p => ({ ...p, id: M.uuid() })) });
      store.setDevice('studyPreset', copy.id); ui.studyDraft = null;
    }
    toast('Preset saved', { icon: 'check' }); render();
  },
  'period-less': () => updateRun(r => M.setMinutes(r, M.runPeriod(r).minutes - 5)),
  'period-more5': () => updateRun(r => M.setMinutes(r, M.runPeriod(r).minutes + 5)),
  'study-pause': () => updateRun(r => M.togglePause(r)),
  'study-end': () => {
    const r = studyRun;
    openModal({ type: 'confirm', title: 'End this session?', text: `Ending logs ${M.fmtDuration(M.runElapsed(r) / 1000)} under History.`, yes: 'End and log', fn: finishStudy,
      alt: 'Discard it', altFn: () => { studyRun = null; saveRun(); render(); } });
  },
  'study-finish': () => finishStudy(),
  'period-go': el => updateRun(r => { r.index = Number(el.dataset.i); r.wrapUp = false; r.periodStart = M.runElapsed(r); }),
  'period-next': () => updateRun(r => M.nextPeriod(r)),
  'period-more': () => updateRun(r => { r.periodStart += 300_000; }),
  'cycle-repeat': el => updateRun(r => M.repeatCycle(r, el.dataset.phase)),
  'cycle-chapter': () => {
    const t = ($('#nextChapter')?.value || '').trim(), r = studyRun;
    if (r?.courseId) store.editCourse(r.courseId, c => { if (t) c.chapter = t; c.phase = 'reading'; });
    updateRun(x => { M.repeatCycle(x, 'reading'); if (t) x.title = `${store.courses.get(x.courseId)?.title || ''}: ${t}`; });
  },
  'mistake-done': el => store.editCourse(el.dataset.course, c => { const m = c.mistakes.find(x => x.id === el.dataset.id); if (m) m.resolvedAt = M.iso(new Date()); }),
  'studylog-delete': el => store.deleteStudyLog(el.dataset.id),
  'course-new': () => {
    const colors = Object.keys(M.COLORS).filter(c => c !== 'gray');
    const c = store.upsertCourse({ ...M.templateCourse('blank'), color: colors[Math.floor(Math.random() * colors.length)] });
    store.setDevice('studyCourseEdit', c.id); store.setDevice('studyTab', 'courses');
    store.setDevice('studyPreset', c.id); ui.studyDraft = null;
    render(); setTimeout(() => { const i = document.getElementById(`cf-title-${c.id}`); i?.focus(); i?.select(); }, 0);
  },
  'course-pick': el => { store.setDevice('studyCourseEdit', el.dataset.id); render(); },
  'course-color': el => store.editCourse(el.dataset.course, c => { c.color = el.dataset.color; }),
  'course-phase': el => store.editCourse(el.dataset.course, c => { c.phase = el.dataset.phase; }),
  'course-taskbased': el => store.editCourse(el.dataset.course, c => { c.taskBased = el.dataset.v === '1'; }),
  'course-delete': el => {
    const c = store.courses.get(el.dataset.course);
    if (!c || !confirm(`Delete ${c.title} and its ${c.cards.length} flashcard(s)? Your study history is kept.`)) return;
    store.deleteCourse(c.id);
    toast(`Deleted ${c.title}`, { icon: 'trash', undo: () => store.upsertCourse(c) });
  },
  'period-move': el => store.editCourse(el.dataset.course, c => { const i = +el.dataset.i, j = i + +el.dataset.d; [c.periods[i], c.periods[j]] = [c.periods[j], c.periods[i]]; }),
  'period-remove': el => store.editCourse(el.dataset.course, c => { c.periods.splice(+el.dataset.i, 1); }),
  'period-reset': el => store.editCourse(el.dataset.course, c => { c.periods = M.classPeriod(); }),
  'period-task-remove': el => store.editCourse(el.dataset.course, c => { c.periods[+el.dataset.i].tasks.splice(+el.dataset.t, 1); }),
  'review-start': () => {
    const sel = store.device('cardsCourse', ''), scope = sel ? [store.courses.get(sel)].filter(Boolean) : store.activeCourses;
    const queue = scope.flatMap(c => M.dueCards(c).map(k => [c.id, k.id])).sort(() => Math.random() - 0.5);
    ui.review = { queue, shown: false, reviewed: 0 }; render();
  },
  'review-stop': () => { ui.review = null; render(); },
  'review-show': () => { if (ui.review) { ui.review.shown = true; render(); } },
  'review-grade': el => {
    const rv = ui.review, [cid, kid] = rv?.queue[0] || [];
    if (!cid) return;
    store.editCourse(cid, c => { const i = c.cards.findIndex(k => k.id === kid); if (i >= 0) c.cards[i] = M.reviewCard(c.cards[i], el.dataset.g); });
    rv.queue.shift(); rv.reviewed++; rv.shown = false;
    if (el.dataset.g === 'again') rv.queue.push([cid, kid]);
    render();
  },
  'card-delete': el => store.editCourse(el.dataset.course, c => { c.cards = c.cards.filter(k => k.id !== el.dataset.card); }),
  'note-new': () => { const n = store.upsertNote({ id: M.uuid(), title: '', body: '', createdAt: M.iso(new Date()) }); ui.noteSel = n.id; ui.noteSearch = ''; render(); setTimeout(() => document.getElementById(`noteTitle-${n.id}`)?.focus(), 0); },
  'note-pick': el => { ui.noteSel = el.dataset.id; render(); },
  'note-pin': el => { const n = store.notes.get(el.dataset.id); if (n) store.upsertNote({ ...n, pinned: !n.pinned }); },
  'note-delete': el => { const n = store.notes.get(el.dataset.id); if (!n) return; store.deleteNote(n.id); ui.noteSel = null; toast('Note deleted', { icon: 'trash', undo: () => store.upsertNote(n) }); },
  'project-new': () => {
    const colors = Object.keys(M.COLORS).filter(c => c !== 'gray');
    const p = M.newProject({ color: colors[Math.floor(Math.random() * colors.length)] });
    store.upsertProject(p);
    navigate(`projects/${p.id}`);
    setTimeout(() => document.getElementById(`ptitle-${p.id}`)?.focus(), 0);
  },
  'ring-mode-set': el => store.updateSettings({ ringShowsLeft: el.dataset.v === '1' }),
  'ring-mode': () => store.updateSettings({ ringShowsLeft: !(store.settings.ringShowsLeft ?? true) }),
  'task-urgent': el => store.setUrgent(el.dataset.task, el.dataset.off !== '1'),
  'bonus-undo': el => { store.undoBonus(el.dataset.task); render(); },
  'quick-save': el => {
    const it = itemById(el.dataset.item);
    if (!it) return;
    const title = $('#qeTitle')?.value, len = $('#qeLen') ? Number($('#qeLen').value) : null;
    let start = null;
    if (it.start && $('#qeTime')?.value) {
      const [h, mi] = $('#qeTime').value.split(':').map(Number);
      start = M.dayAt($('#qeDate')?.value ? M.parseKey($('#qeDate').value) : it.start, h * 60 + mi);
    }
    const oldLen = it.start ? Math.round((it.end - it.start) / 60_000) : null;
    applyEdit(it, { title: title !== it.title ? title : undefined, start: start && +start !== +it.start ? start : undefined,
      minutes: len != null && len !== oldLen ? len : undefined, busy: $('#qeBusy').checked !== busyOfItem(it) ? $('#qeBusy').checked : undefined });
    closeModal();
  },
  'gevent-delete': el => {
    const it = itemById(el.dataset.item);
    if (it?.kind !== 'google' || !confirm(`Delete “${it.title}” from Google Calendar?`)) return;
    const e = it.e;
    store.deleteGoogleEvent(e.calendarID, e.id.split('|').slice(1).join('|')).then(() => toast(`Deleted “${e.title}” from Google Calendar`, { icon: 'trash' }))
      .catch(err => toast(`Google didn’t delete it: ${err.message}`, { icon: 'alert' }));
    closeModal();
  },
  'ot-hours': () => { ui.booking.editHours = !ui.booking.editHours; render(); },
  'project-urgent': el => projectEdit(el, p => M.updateItem(p, el.dataset.item, i => { if (i.urgent) delete i.urgent; else i.urgent = true; })),
  'project-list-mode': el => { store.setDevice('projectListGantt', el.dataset.gantt === '1'); render(); },
  'gantt-fold': el => {
    const key = ui.route === 'projects' && ui.projectId ? ui.projectId : 'all', set = new Set(projCollapsed(key));
    if (set.has(el.dataset.project)) set.delete(el.dataset.project); else set.add(el.dataset.project);
    ui.projCollapsed.set(key, set); render();
  },
  'gantt-fold-all': el => { projCollapsed('all'); ui.projCollapsed.set('all', new Set(el.dataset.fold === '1' ? store.activeProjects.map(p => p.id) : [])); render(); },
  'gantt-open': el => { store.setDevice('projectMode', 'gantt'); navigate(`projects/${el.dataset.project}`); proj.picked = new Set([el.dataset.item]); proj.anchor = el.dataset.item; render(); },
  'project-mode': el => { store.setDevice('projectMode', el.dataset.mode); render(); },
  'project-color': el => projectEdit(el, p => { p.color = el.dataset.color; }),
  'project-archive': el => projectEdit(el, p => { if (p.archived) delete p.archived; else p.archived = true; }),
  'project-delete': el => {
    const p = store.projects.get(el.dataset.project);
    if (!p || !confirm(`Delete “${p.title || 'Untitled project'}” and all its subtasks?`)) return;
    store.deleteProject(p.id);
    navigate('projects');
    toast(`Deleted “${p.title || 'Untitled project'}”`, { icon: 'trash', undo: () => store.upsertProject(p) });
  },
  'project-collapse': el => {
    const pid = el.dataset.project, set = new Set(projCollapsed(pid));
    if (set.has(el.dataset.item)) set.delete(el.dataset.item); else set.add(el.dataset.item);
    ui.projCollapsed.set(pid, set); render();
  },
  'project-done': el => projectEdit(el, p => M.updateItem(p, el.dataset.item, i => M.setItemDone(i, !M.itemDone(i)))),
  'project-add-child': el => {
    const n = M.newProjectItem(), pid = el.dataset.project;
    projectEdit(el, p => M.insertItem(p, n, el.dataset.item));
    const set = new Set(projCollapsed(pid)); set.delete(el.dataset.item); ui.projCollapsed.set(pid, set);
    render(); setTimeout(() => document.getElementById(`pi-${n.id}`)?.focus(), 0);
  },
  'project-indent': el => projectEdit(el, p => M.indentItem(p, el.dataset.item)),
  'project-outdent': el => projectEdit(el, p => M.outdentItem(p, el.dataset.item)),
  'project-move': el => projectEdit(el, p => M.moveItem(p, el.dataset.item, Number(el.dataset.delta))),
  'project-remove': el => {
    const before = structuredClone(store.projects.get(el.dataset.project));
    const gone = M.findItem(before, el.dataset.item)?.item;
    projectEdit(el, p => { M.removeItem(p, el.dataset.item); });
    proj.picked.delete(el.dataset.item);
    toast(`Deleted “${gone?.title || 'subtask'}”${gone?.items?.length ? ` and ${plural(M.itemProgress(gone).total, 'piece')} inside` : ''}`, { icon: 'trash', undo: () => store.upsertProject(before) });
  },
  'project-select': (el, e) => projClick(el.dataset.item, e),
  'pj': el => { const op = el.dataset.op; op === 'move' ? projOps.move(Number(el.dataset.d)) : projOps[op](); },
  'pj-clear': () => { proj.picked = new Set(); render(); },
  'pj-add': el => projAdd(el.dataset.parent || null),
  'pj-undo': () => projUndo(proj.undo, proj.redo),
  'pj-redo': () => projUndo(proj.redo, proj.undo),
  'pj-keys': () => openModal({ type: 'pj-keys' }),
  'pick-date': el => {
    const input = el.parentElement.querySelector('input[type=date]');
    try { input.showPicker(); } catch { input.focus(); input.click(); }
  },
  'clear-date': el => setProjectDate(el.parentElement.querySelector('input[type=date]'), ''),
  'new-task': el => newTaskAt(el.dataset.day ? M.parseKey(el.dataset.day) : new Date()),
  'new-event': el => newEventAt(el.dataset.day ? M.parseKey(el.dataset.day) : new Date()),
  'make-kind': el => {
    const t = store.tasks.get(el.dataset.task);
    if (!t) return;
    store.upsertTask({ ...t, kind: el.dataset.kind });
    if (ui.modal) closeModal();
    toast(el.dataset.kind === 'task' ? `“${t.title}” is now on your checklist` : `“${t.title}” is now an event`, { icon: el.dataset.kind === 'task' ? 'list' : 'cal',
      undo: () => store.upsertTask({ ...store.tasks.get(t.id), kind: t.kind }) });
  },
  'edit-kind': el => {
    readEditorInputs();
    const m = ui.modal, k = el.dataset.kind, d = m.draft, wasBonus = M.isBonus(d);
    d.kind = k;
    if (k === 'bonus') {
      // Optional extras: no date to miss, no time, no reminders. A repeat schedule (or a task's "after it's done,
      // with a break") carries over.
      for (const x of ['mode', 'habit', 'after', 'afterMinutes', 'armedAt', 'armedBy', 'nag', 'nagEvery']) delete d[x];
      d.channels = []; m.hasTime = false;
      if (m.isNew && d.color === 'blue') d.color = 'yellow';
    } else if (wasBonus) {
      d.channels = [...store.settings.defaultChannels];
      if (m.isNew && d.color === 'yellow') d.color = 'blue';
    }
    if (k === 'event') delete d.mode;   // events have no check-off, so no "until done"/long-term
    if (k === 'habit') {
      // Habits repeat; they start out daily and as building something new.
      if (d.recurrence.frequency === 'none') d.recurrence = { ...d.recurrence, frequency: 'daily', interval: 1 };
      if (M.isCycle(d)) { delete d.cycleGapDays; delete d.cycleTimes; delete d.mode; }
      d.habit ??= { style: 'build' };
      if (m.isNew && d.color === 'blue') d.color = 'green';
    }
    if (k === 'task') {
      // Repeating things are habits; a task happens once (or comes back after a break).
      if (d.recurrence.frequency !== 'none') { d.recurrence = { ...d.recurrence, frequency: 'none', weekdays: [] }; m.endMode = 'never'; }
      if (d.mode === 'longTerm') delete d.mode;
    }
    if (!m.busyChosen) m.draft.busy = k === 'event';   // events start closed, tasks open
    if (k === 'event' && m.isNew) {
      if (!m.hasTime) { m.hasTime = true; m.time = '09:00'; }
      if (m.draft.durationMinutes === 30) m.draft.durationMinutes = 60;
      m.draft.reminderOffsets = [10];
    }
    renderModal();
  },
  'preset-new': () => { readEditorInputs(); const m = ui.modal; m.namingPreset = true; m.presetName = m.draft.title.trim() || ''; m.presetSaved = null; renderModal(); setTimeout(() => $('[data-edit="presetName"]')?.focus()); },
  'preset-cancel': () => { readEditorInputs(); ui.modal.namingPreset = false; renderModal(); },
  'preset-save': () => {
    readEditorInputs();
    const m = ui.modal, name = ($('[data-edit="presetName"]')?.value || '').trim() || 'My preset';
    store.updateSettings({ taskPresets: [...(store.settings.taskPresets || []), presetFromEditor(m, name)] });
    m.namingPreset = false; m.presetSaved = name; renderModal();
  },
  'preset-delete': el => {
    const p = (store.settings.taskPresets || []).find(x => x.id === el.dataset.id);
    if (!p) return;
    store.updateSettings({ taskPresets: store.settings.taskPresets.filter(x => x.id !== p.id) });
    toast(`Deleted preset “${p.name}”`, { icon: 'trash', undo: () => store.updateSettings({ taskPresets: [...store.settings.taskPresets, p] }) });
  },
  'toggle-distracting': el => {
    const app = el.dataset.app, list = store.settings.distractingApps || [];
    const has = list.some(x => x.toLowerCase() === app.toLowerCase());
    store.updateSettings({ distractingApps: has ? list.filter(x => x.toLowerCase() !== app.toLowerCase()) : [...list, app] });
  },
  'focus-mins': el => { ui.focusMinutes = Number(el.dataset.m); render(); },
  'focus-len-save': () => {
    const m = M.clampFocus(ui.focusMinutes ?? store.settings.focusMinutes);
    const list = M.focusLengths(store.settings.focusLengths);
    if (list.length >= 8) { toast('You can keep up to 8 lengths. Remove one first.', { icon: 'alert' }); return; }
    store.updateSettings({ focusLengths: M.focusLengths([...list, m]) });
  },
  'focus-len-remove': el => {
    const m = Number(el.dataset.m), before = M.focusLengths(store.settings.focusLengths);
    store.updateSettings({ focusLengths: before.filter(x => x !== m) });
    toast(`Removed ${M.fmtFocusLength(m)}`, { icon: 'trash', undo: () => store.updateSettings({ focusLengths: before }) });
  },
  'focus-start': () => {
    const pick = ui.focusPick ?? new Set(store.todayChecklist().filter(o => !o.resolved).map(o => o.id));
    const mins = M.clampFocus(ui.focusMinutes ?? store.settings.focusMinutes ?? 25);
    if (mins !== store.settings.focusMinutes) store.updateSettings({ focusMinutes: mins });
    ui.focusPick = null;
    startFocus(mins, [...pick]);
  },
  'focus-done': el => {
    const id = el.dataset.occ, i = focus.finished.indexOf(id);
    if (i >= 0) focus.finished.splice(i, 1); else focus.finished.push(id);
    saveFocus(); render();
    if (focus.finished.length === focus.picked.length) endFocus();   // cleared the list: stop the clock
  },
  'focus-more': () => { focus.endsAt += 5 * 60_000; focus.minutes += 5; saveFocus(); render(); },
  'focus-end': () => confirmThen('End this focus session?', 'Your score counts what you’ve finished so far.', 'End now', () => endFocus()),
  'focus-dismiss': () => { ui.focusResult = null; render(); },
  'focus-mode': el => { ui.focusMode = el.dataset.m; try { localStorage.setItem('cadence:focusMode', el.dataset.m); } catch { /* storage blocked */ } render(); },
  'work-start': el => { const o = findOcc(el.dataset.occ); if (o) startWork(o); },
  'bonus-tick': el => { const t = store.tasks.get(el.dataset.task); if (t && canTickBonus(t)) { focus.bonusTicks = [...(focus.bonusTicks || []), t.id]; saveFocus(); render(); } },
  'bonus-untick': el => { const a = [...(focus.bonusTicks || [])], i = a.lastIndexOf(el.dataset.task); if (i >= 0) { a.splice(i, 1); focus.bonusTicks = a; saveFocus(); render(); } },
  'work-complete': () => completeWork(),
  'work-stop': () => endFocus({ quiet: true }),
  'focus-pause': () => togglePause(),
  'week-focus': () => { ui.weekFocus = !weekShowsFocus(); try { localStorage.setItem('cadence:weekFocus', ui.weekFocus ? '1' : '0'); } catch { /* storage blocked */ } render(); },
  'score-rate': el => store.updateSettings({ habitScorecard: store.settings.habitScorecard.map(c => c.id === el.dataset.id ? { ...c, rating: el.dataset.r } : c) }),
  'score-del': el => store.updateSettings({ habitScorecard: store.settings.habitScorecard.filter(c => c.id !== el.dataset.id) }),
  'score-replace': el => {
    const c = store.settings.habitScorecard.find(x => x.id === el.dataset.id);
    if (c) newHabitAt(new Date(), { habit: { style: 'replace', replaces: c.text[0].toLowerCase() + c.text.slice(1) } });
  },
  'habit-range': el => { ui.habitRange = Number(el.dataset.n); render(); },
  'step-add': () => {
    readEditorInputs();
    const m = ui.modal, title = (m.stepNew || '').trim();
    if (!title) return;
    (m.draft.steps ||= []).push({ id: M.uuid(), title });
    m.stepNew = '';
    renderModal();
    const box = $('#stepNew');
    if (box) { box.value = ''; box.focus(); }
  },
  'step-remove': el => { readEditorInputs(); ui.modal.draft.steps.splice(Number(el.dataset.i), 1); renderModal(); },
  'step-move': el => {
    readEditorInputs();
    const a = ui.modal.draft.steps, i = Number(el.dataset.i), j = i + Number(el.dataset.d);
    if (a[j]) [a[i], a[j]] = [a[j], a[i]];
    renderModal();
  },
  'step-toggle': el => {
    const o = findOcc(el.dataset.occ);
    if (!o) return;
    if (store.toggleStep(o, el.dataset.step)) toggleOcc(el.dataset.occ, el.dataset.ctx);
  },
  'habit-style': el => { readEditorInputs(); (ui.modal.draft.habit ??= {}).style = el.dataset.style; renderModal(); },
  'new-habit': () => newHabitAt(new Date()),
  'edit-busy': el => { readEditorInputs(); ui.modal.draft.busy = el.dataset.busy === '1'; ui.modal.busyChosen = true; renderModal(); },
  'new-at': el => { const d = new Date(Number(el.dataset.at)); newTaskAt(d, Math.min(1435, Math.floor(M.minutesOf(d) / 5) * 5)); },
  edit: el => { const t = store.tasks.get(el.dataset.task); if (t) openEditor(t, false); },
  'cal-menu': () => { ui.calMenu = !ui.calMenu; render(); },
  'refl-filter': el => { ui.reflFilter = el.dataset.f; render(); },
  toggle: el => toggleOcc(el.dataset.occ, el.dataset.ctx),
  miss: el => missOcc(el.dataset.occ, el.dataset.ctx),
  skip: el => {
    const o = findOcc(el.dataset.occ);
    if (!o) return;
    const before = structuredClone(o.task);
    store.skip(o);
    if (ui.modal?.type === 'detail') closeModal();
    toast(`Skipped ${o.task.title} for ${M.fmtDay(o.day, { weekday: 'short', month: 'short', day: 'numeric' })}`, { icon: 'right', undo: () => store.upsertTask({ ...before, skipped: (store.tasks.get(before.id)?.skipped || []).filter(k => k !== o.key) }) });
  },
  'delete-task': el => {
    const t = store.tasks.get(el.dataset.task);
    if (!t) return;
    // A repeating one: ask whether it's only this one, this and later ones, or all of them.
    if (t.recurrence.frequency !== 'none' && !el.dataset.scope) {
      const o = el.dataset.occ ? findOcc(el.dataset.occ) : null;
      openModal({ type: 'delete-repeat', task: t.id, day: M.dateKey(o?.day ?? M.nextOccurrence(t, new Date()) ?? new Date()) });
      return;
    }
    if (el.dataset.scope && el.dataset.scope !== 'all') {
      const next = M.deleteOccurrence(t, M.parseKey(el.dataset.day), el.dataset.scope);
      if (ui.modal) closeModal();
      if (next) {
        store.upsertTask(next);
        toast(el.dataset.scope === 'one' ? `Deleted “${t.title}” on ${M.fmtDay(M.parseKey(el.dataset.day), { weekday: 'short', month: 'short', day: 'numeric' })}` : `“${t.title}” stops from ${M.fmtDay(M.parseKey(el.dataset.day), { weekday: 'short', month: 'short', day: 'numeric' })}`,
          { icon: 'trash', undo: () => store.upsertTask(t) });
        return;
      }
    }
    if (t.source === 'google' && t.googleEventID && store.google.connected) { openModal({ type: 'delete-google', task: t }); return; }
    const copy = structuredClone(t);
    store.deleteTask(t.id);
    if (ui.modal) closeModal();
    toast(`Deleted “${t.title}”`, { icon: 'trash', undo: () => { store.restoreTask(copy); toast('Task restored', { icon: 'check' }); } });
  },
  'confirm-yes': () => { const fn = ui.modal.fn; closeModal(); fn(); },
  'confirm-alt': () => { const fn = ui.modal.altFn; closeModal(); fn?.(); },
  close: el => { const then = el.dataset.then; closeModal(); if (then) navigate(then); },
  overlay: (el, e) => { if (e.target === el && !ui.modal?.locked && !['editor', 'nag'].includes(ui.modal?.type)) closeModal(); },
  'nag-done': () => { const o = ui.modal.occ; reminders.snoozeNag(o, 5); closeModal(); beginReflection(o); },
  'nag-open': () => { const o = ui.modal.occ; reminders.snoozeNag(o, M.nagMinutes(o.task)); closeModal(); navigate('today'); },
  'nag-snooze': el => {
    const m = ui.modal, o = m.occ;
    if (m.level === 'strict') {
      m.why = $('#nagWhy')?.value || ''; m.minutes = Number($('#nagMin')?.value) || 15;
      if (M.countWords(m.why) < 4) { m.error = 'Say why in at least 4 words.'; renderModal(); setTimeout(() => $('#nagWhy')?.focus(), 0); return; }
      reminders.snoozeNag(o, m.minutes, m.why);
    } else reminders.snoozeNag(o, Number(el.dataset.min) || 10);
    closeModal();
  },
  'checkin-back': () => { ui.modal.reflecting = null; renderModal(); },
  'check-in': () => reminders.checkIn('Daily check-in', { manual: true }),
  detail: el => openModal({ type: 'detail', item: el.dataset.item }),
  'sign-out': () => confirmThen('Sign out?', 'You’ll need your username and password to sign back in on this browser.', 'Sign out', () => store.signOut()),
  'auth-mode': el => { ui.auth = { mode: el.dataset.mode, error: null, busy: false }; render(); },
  'week-prev': () => { ui.weekStart = M.addDays(ui.weekStart, -7); render(); },
  'week-next': () => { ui.weekStart = M.addDays(ui.weekStart, 7); render(); },
  'week-today': () => { ui.weekStart = M.startOfWeek(new Date()); ui.weekScrolled = false; render(); },
  'month-prev': () => { ui.month = M.addMonths(ui.month, -1); render(); },
  'month-next': () => { ui.month = M.addMonths(ui.month, 1); render(); },
  'month-today': () => { ui.month = M.startOfMonth(new Date()); ui.selectedDay = M.startOfDay(new Date()); render(); },
  'select-day': (el, e) => {
    if (e.detail === 2) { newTaskAt(M.parseKey(el.dataset.day)); return; }
    ui.selectedDay = M.parseKey(el.dataset.day); render();
  },
  'todo-mode': el => { ui.todo.mode = el.dataset.mode; render(); },
  'export-refl': () => {
    let md = '# Cadence Reflections\n\n', last = '';
    for (const r of store.sortedReflections()) {
      const k = M.dateKey(r.createdAt);
      if (k !== last) { md += `## ${M.fmtDay(r.createdAt, { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })}\n\n`; last = k; }
      md += `### ${r.taskTitle}${r.outcome === 'missed' ? ' (didn’t do it)' : ''} — ${M.fmtTime(r.createdAt)}\n\n${r.text}\n\n`;
    }
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([md], { type: 'text/markdown' }));
    a.download = `Cadence Reflections ${M.dateKey(new Date())}.md`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  },
  'copy-refl': el => { navigator.clipboard?.writeText(store.reflections.get(el.dataset.id)?.text ?? ''); toast('Copied to clipboard', { icon: 'copy' }); },
  'delete-refl': el => {
    const r = store.reflections.get(el.dataset.id);
    if (!r) return;
    const copy = structuredClone(r);
    store.deleteReflection(r.id);
    toast('Reflection deleted', { icon: 'trash', undo: () => store.restoreReflection(copy) });
  },
  'busy-refresh': () => { ui.booking.loadedFor = null; loadBusy(); },
  'copy-avail': () => {
    const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
    let text = `Here’s when I’m free over the next week (${tz}):\n\n`;
    for (const d of ui.booking.week || []) if (d.open.length) {
      text += `• ${M.fmtDay(d.day, { weekday: 'long', month: 'short', day: 'numeric' })}: ${d.open.map(([s, e]) => `${M.fmtTime(s)}–${M.fmtTime(e)}`).join(', ')}\n`;
    }
    text += '\nLet me know what works and I’ll send an invite.';
    navigator.clipboard?.writeText(text);
    ui.booking.message = 'Open times copied to the clipboard.'; render();
  },
  'ot-book': (el, e) => {
    // Start where you clicked (rounded down to 15 minutes), kept inside the open stretch.
    const s = Number(el.dataset.s), end = Number(el.dataset.e);
    const r = el.getBoundingClientRect();
    const at = s + ((e?.clientY ?? r.top) - r.top) / r.height * (end - s);
    const q = 15 * 60_000, latest = Math.max(s, end - q);
    let start = Math.min(latest, Math.max(s, Math.floor(at / q) * q));
    if (start < s) start = s;
    openModal({ type: 'booking', start: new Date(start), rangeEnd: new Date(end), minutes: Math.min(30, Math.max(15, Math.round((end - start) / 60_000))) });
  },
  'sync-now': () => { syncUI.manual = true; store.sync(); },
  'copy-origin': () => { navigator.clipboard?.writeText(location.origin); toast('Address copied', { icon: 'copy' }); },
  'clear-flash': () => { ui.flash = null; render(); },
  'ask-notify': async () => { if ('Notification' in window) await Notification.requestPermission(); render(); },
  'test-reminder': () => reminders.deliver({ kind: 'test', title: 'Test reminder', body: 'This is how Cadence reminders will look.', tint: '#0a84ff' }, store.settings.defaultChannels),
  'google-refresh': () => store.refreshGoogle(),
  'delete-account': () => openModal({ type: 'delete-account' }),
  'google-hide': () => {
    const t = ui.modal.task;
    store.deleteTask(t.id);   // imported items are hidden, not deleted
    closeModal();
    toast(`Hid “${t.title}” in Cadence`, { icon: 'trash', undo: () => store.upsertTask({ ...store.tasks.get(t.id), archived: false }) });
  },
  'google-delete': async () => {
    const m = ui.modal, t = m.task;
    m.working = true; renderModal();
    try {
      await store.deleteGoogleEvent(t.sourceCalendar || 'primary', t.googleEventID);
      store.deleteTask(t.id);
      closeModal();
      toast(`Deleted “${t.title}” from Cadence and Google Calendar`, { icon: 'trash' });
    } catch (e) {
      m.working = false; m.error = `Google Calendar didn't delete it: ${e.message}`; renderModal();
    }
  },
  'calendly-refresh': () => store.refreshCalendly(),
  'calendly-disconnect': () => confirmThen('Disconnect Calendly?', 'Meetings already on your checklist stay; new ones won’t be imported.', 'Disconnect', () => store.disconnectCalendly()),
  'import-now': () => runImport({ manual: true }),
  'copy-text': el => { navigator.clipboard?.writeText(el.dataset.text); toast('Link copied', { icon: 'copy' }); },
  'google-disconnect': () => confirmThen('Disconnect Google Calendar?', 'Cadence will stop showing your Google events on the web.', 'Disconnect', () => store.disconnectGoogle()),
  'avail-day': el => {
    const w = Number(el.dataset.w), a = store.settings.availability;
    const days = a.weekdays.includes(w) ? a.weekdays.filter(x => x !== w) : [...a.weekdays, w].sort();
    if (days.length) store.updateSettings({ availability: { ...a, weekdays: days } });
  },
  'edit-weekday': el => {
    readEditorInputs();
    const r = ui.modal.draft.recurrence, w = Number(el.dataset.w);
    const cur = M.effectiveWeekdays(r, M.parseKey(ui.modal.date));
    r.weekdays = cur.includes(w) ? (cur.length > 1 ? cur.filter(x => x !== w) : cur) : [...cur, w].sort();
    renderModal();
  },
  'edit-weekdays': () => { readEditorInputs(); ui.modal.draft.recurrence.weekdays = [2, 3, 4, 5, 6]; renderModal(); },
  'edit-color': el => { readEditorInputs(); ui.modal.draft.color = el.dataset.color; renderModal(); },
  'edit-starts': el => {
    readEditorInputs(); const d = ui.modal.draft;
    if (el.dataset.v) { const first = M.possibleTriggers([...store.tasks.values()], d.id)[0]; if (first) d.after = first.id; }
    else { delete d.after; delete d.afterMinutes; delete d.armedAt; delete d.armedBy; }
    renderModal();
  },
  'edit-followup': async el => { const f = store.tasks.get(el.dataset.id); if (!f) return; await saveEditor(); if (!ui.modal) openEditor(f, false); },
  'edit-add-followup': async () => {
    readEditorInputs();
    const id = ui.modal.draft.id;
    await saveEditor();
    if (!ui.modal) openEditor(M.newTask({ after: id }), true);
  },
  'edit-priority': el => { readEditorInputs(); const d = ui.modal.draft; if (el.dataset.v) d.priority = el.dataset.v; else delete d.priority; renderModal(); },
  'edit-hardness': el => { readEditorInputs(); const d = ui.modal.draft, v = Number(el.dataset.v); if (M.hardnessOf(d) === v) delete d.hardness; else d.hardness = v; renderModal(); },
  'edit-use-typical': () => { readEditorInputs(); const d = ui.modal.draft; d.durationMinutes = M.typicalMinutes(d) || d.durationMinutes; renderModal(); },
  'edit-time-del': el => { readEditorInputs(); const d = ui.modal.draft; d.timeTaken = { ...d.timeTaken }; delete d.timeTaken[el.dataset.k]; if (!Object.keys(d.timeTaken).length) delete d.timeTaken; renderModal(); },
  'edit-times-all': () => { readEditorInputs(); ui.modal.allTimes = !ui.modal.allTimes; renderModal(); },
  'refl-skip': () => nextQueuedReflection(),
  'ai-remove': () => { ai.key = ''; ai.on = false; ui.aiTest = ''; render(); },
  'ai-test': async () => { ui.aiTest = 'Testing…'; render(); ui.aiTest = await testKey(); render(); },
  'refl-taken': el => { const input = $('#reflTaken'); if (input) { input.value = el.dataset.v; reflReady(); } },
  'edit-nag': el => { readEditorInputs(); const d = ui.modal.draft; if (el.dataset.nag === 'normal') { delete d.nag; delete d.nagEvery; } else d.nag = el.dataset.nag; renderModal(); },
};

// Single click on a week block opens details; double click adds a task at that moment.
let blockClickTimer = null;
document.addEventListener('click', e => {
  if (ui.calMenu && !e.target.closest('.calmenu')) { ui.calMenu = false; render(); }
  const block = e.target.closest('.block');
  if (block) {
    clearTimeout(blockClickTimer);
    if (e.detail === 1) blockClickTimer = setTimeout(() => openModal({ type: 'detail', item: block.dataset.item }), 220);
    return;
  }
  const link = e.target.closest('a[href^="/app"]');
  if (link && !link.target && !e.metaKey && !e.ctrlKey && !e.shiftKey && e.button === 0) {
    e.preventDefault();
    const href = link.getAttribute('href');
    navigate(href === '/app' ? 'home' : href.replace(/^\/app\//, ''));
    return;
  }
  const el = e.target.closest('[data-act]');
  if (!el) return;
  const fn = actions[el.dataset.act];
  if (fn) { if (el.tagName === 'BUTTON' && el.type !== 'submit') e.preventDefault(); fn(el, e); }
});

document.addEventListener('dblclick', e => {
  // Booking grid: double-click a free spot to add an event there.
  const oc = e.target.closest('.ot-col');
  if (oc && !e.target.closest('.ot-open, .ot-item')) {
    const y = e.clientY - oc.getBoundingClientRect().top;
    newEventAt(M.parseKey(oc.dataset.day), Math.min(1425, Number(oc.dataset.h0) * 60 + Math.floor((y / OT_HOUR) * 60 / 15) * 15));
    return;
  }
  const col = e.target.closest('.wcol');
  if (!col) return;
  clearTimeout(blockClickTimer);
  const day = M.parseKey(col.dataset.day);
  const y = e.clientY - col.getBoundingClientRect().top;
  const block = e.target.closest('.block');
  // Inside an existing block: exact time (5-minute steps) so the new task's reminder lands mid-task.
  const step = block ? 5 : 30;
  const minutes = Math.min(1435, Math.max(0, Math.floor((y / HOUR) * 60 / step) * step));
  newTaskAt(day, minutes);
});

document.addEventListener('input', e => {
  const el = e.target;
  if (el.id === 'reflText') {
    const min = Number(el.dataset.min), n = M.countWords(el.value);
    $('#reflCount').textContent = `${n} / ${min} words`;
    $('#reflCount').className = `small ${n >= min ? 'green' : 'muted'}`;
    $('#reflBar').className = `progress ${n >= min ? 'ok' : ''}`;
    $('#reflBar').firstElementChild.style.width = `${Math.min(100, (n / min) * 100)}%`;
    reflReady();
    return;
  }
  if (el.id === 'reflTaken') { reflReady(); return; }
  if (el.dataset.courseField) { store.editCourse(el.dataset.course, c => { c[el.dataset.courseField] = el.value; }); return; }
  if (el.dataset.periodField && el.dataset.periodField !== 'minutes') { store.editCourse(el.dataset.course, c => { c.periods[+el.dataset.i][el.dataset.periodField] = el.value; }); return; }
  if (el.dataset.cardField) { store.editCourse(el.dataset.course, c => { const k = c.cards.find(x => x.id === el.dataset.card); if (k) k[el.dataset.cardField] = el.value; }); return; }
  if (el.dataset.remField) { store.editCustomReminder(el.dataset.id, r => { r[el.dataset.remField] = el.value; }); return; }
  if (el.dataset.noteField) { const n = store.notes.get(el.dataset.id); if (n) store.upsertNote({ ...n, [el.dataset.noteField]: el.value }); return; }
  if (el.dataset.bind === 'cardSearch') { ui.cardSearch = el.value; render(); return; }
  if (el.dataset.bind === 'noteSearch') { ui.noteSearch = el.value; render(); return; }
  if (el.dataset.pfield === 'title') { projectEdit(el, p => { p.title = el.value; }, 'ptitle'); return; }
  if (el.dataset.pfield === 'item-title') { projectEdit(el, p => M.updateItem(p, el.dataset.item, i => { i.title = el.value; }), `t-${el.dataset.item}`); return; }
  const bind = el.dataset.bind;
  if (bind === 'todoSearch') { ui.todo.search = el.value; render(); }
  if (bind === 'reflSearch') { ui.reflSearch = el.value; render(); }
});

function setProjectDate(el, value) {
  const field = el.dataset.pdate;
  projectEdit(el, p => {
    const target = el.dataset.item ? M.findItem(p, el.dataset.item)?.item : p;
    if (!target) return;
    if (value) target[field] = value; else delete target[field];
  });
}

document.addEventListener('change', e => {
  const el = e.target;
  if (el.dataset.pdate) { setProjectDate(el, el.value); return; }
  if (el.dataset.themePick !== undefined) { setTheme(el.value); return; }
  if (el.dataset.fontPick !== undefined) {
    if (el.value === 'custom') { ui.fontCustom = true; render(); setTimeout(() => $('#fontName')?.focus(), 0); return; }
    ui.fontCustom = false; setFont(el.value); render(); return;
  }
  if (el.dataset.siteSuggest !== undefined) { if (el.value) addBlockedSite(el.value); return; }
  if (el.dataset.pjDue !== undefined) { const v = el.value; if (v) projOps.setDue(v === 'none' ? null : M.dateKey(M.addDays(new Date(), Number(v)))); return; }
  if (el.dataset.aiModel !== undefined) { ai.model = el.value; return; }
  if (el.dataset.workSwitch !== undefined) { const o = el.value && findOcc(el.value); if (o) startWork(o); return; }
  if (el.dataset.selColor !== undefined) { const c = el.value; if (c) selEdit(t => { t.color = c; }, 'Color changed'); return; }
  if (el.dataset.selPriority !== undefined) {
    const v = el.value;
    if (v) selEdit(t => { if (v === 'none') delete t.priority; else t.priority = v; }, v === 'none' ? 'Priority cleared' : `${v[0].toUpperCase() + v.slice(1)} priority`);
    return;
  }
  if (el.dataset.selHardness !== undefined) {
    const v = el.value;
    if (v) selEdit(t => { if (v === 'none') delete t.hardness; else t.hardness = Number(v); }, v === 'none' ? 'Hardness cleared' : `Hardness ${v}: ${M.HARDNESS[v - 1]}`);
    return;
  }
  if (el.dataset.selMove !== undefined) {
    const n = Number(el.value); if (!n) return;
    selEdit(t => { if (t.recurrence.frequency !== 'none') return; t.startDate = M.iso(M.addDays(new Date(t.startDate), n)); if (t.dueDate) t.dueDate = M.dateKey(M.addDays(M.parseKey(String(t.dueDate).slice(0, 10)), n)); }, 'Moved (repeating ones keep their pattern)');
    return;
  }
  if (el.dataset.remTemplate !== undefined) { const t = REMINDER_TEMPLATES[+el.value]; if (t) remNew(structuredClone(t)); return; }
  if (el.dataset.id && store.customReminders.get(el.dataset.id) && !el.dataset.remField) {
    const id = el.dataset.id, toMin = v => { const [h, m] = String(v).split(':').map(Number); return h * 60 + m; };
    if (el.dataset.remCheck) store.editCustomReminder(id, r => { r[el.dataset.remCheck] = el.checked; });
    else if (el.dataset.remChan) store.editCustomReminder(id, r => { const c = new Set(r.channels || []); el.checked ? c.add(el.dataset.remChan) : c.delete(el.dataset.remChan); r.channels = [...c]; });
    else if (el.dataset.remAddtime !== undefined) { if (!el.value) return; store.editCustomReminder(id, r => { const m = toMin(el.value); r.times = [...new Set([...(r.times || []), m])]; }); }
    else if (el.dataset.remTime) { if (!el.value) return; store.editCustomReminder(id, r => { r[el.dataset.remTime] = toMin(el.value); }); }
    else if (el.dataset.remNum) store.editCustomReminder(id, r => { r[el.dataset.remNum] = Math.min(720, Math.max(5, Number(el.value) || 60)); });
    else if (el.dataset.remAt !== undefined) { if (!el.value) return; store.editCustomReminder(id, r => { r.at = M.iso(new Date(el.value)); }); }
    else return;
    render(); return;
  }
  if (el.dataset.studyOpt === 'preset') { store.setDevice('studyPreset', el.value); ui.studyDraft = null; render(); return; }
  if (el.dataset.draft || el.dataset.draftPick) {
    const c = studyDraft().course, k = el.dataset.draft || el.dataset.draftPick;
    if (el.dataset.draftPick && !el.value) return;
    if (k === 'minutes') c.periods[+el.dataset.i].minutes = Math.min(480, Math.max(1, Number(el.value) || 1));
    else if (k === 'repeats') c.repeats = Math.min(20, Math.max(1, Number(el.value) || 1));
    else if (k === 'autoAdvance') c.autoAdvance = el.checked;
    render(); return;
  }
  if (el.dataset.runMinutes) { updateRun(r => M.setMinutes(r, el.value)); return; }
  if (el.dataset.studyOpt) {
    const k = el.dataset.studyOpt, v = k === 'course' ? el.value : Math.max(0, Number(el.value) || 0);
    store.setDevice('studySetup', { ...store.device('studySetup', {}), [k]: v, ...(k === 'course' ? { taskBased: undefined } : {}) }); render(); return;
  }
  if (el.dataset.periodField === 'minutes') { store.editCourse(el.dataset.course, c => { c.periods[+el.dataset.i].minutes = Math.min(240, Math.max(1, Number(el.value) || 1)); }); return; }
  if (el.dataset.courseRule) { const [phase, key] = el.dataset.courseRule.split('|'); store.editCourse(el.dataset.course, c => { c.rules = { ...(c.rules || {}), [phase]: { ...M.courseRules(c, phase), [key]: el.value } }; }); return; }
  if (el.dataset.actChange === 'preset-new') { if (!el.value) return; const c = store.upsertCourse(M.templateCourse(el.value)); store.setDevice('studyCourseEdit', c.id); render(); return; }
  if (el.dataset.actChange === 'preset-replace') { if (!el.value) return; const t = M.templateCourse(el.value); store.editCourse(el.dataset.course, c => { Object.assign(c, { periods: t.periods, repeats: t.repeats, autoAdvance: t.autoAdvance, showPhase: t.showPhase }); }); return; }
  if (el.dataset.actChange === 'course-showphase') { store.editCourse(el.dataset.course, c => { c.showPhase = el.checked; }); return; }
  if (el.dataset.actChange === 'course-auto') { store.editCourse(el.dataset.course, c => { c.autoAdvance = el.checked; }); return; }
  if (el.dataset.courseNum) { store.editCourse(el.dataset.course, c => { c[el.dataset.courseNum] = Math.min(20, Math.max(1, Number(el.value) || 1)); }); return; }
  if (el.dataset.actChange === 'period-enable') { store.editCourse(el.dataset.course, c => { c.periods[+el.dataset.i].enabled = el.checked; }); return; }
  if (el.dataset.actChange === 'period-add') { if (el.value) store.editCourse(el.dataset.course, c => { c.periods.push(M.newPeriod(el.value)); }); return; }
  if (el.dataset.actChange === 'period-task') { updateRun(r => M.isChecked(r, M.runPeriod(r), +el.dataset.i) ? r.checked = r.checked.filter(k => k !== `${M.runPeriod(r).id}|${el.dataset.i}`) : r.checked.push(`${M.runPeriod(r).id}|${el.dataset.i}`)); return; }
  if (el.dataset.actChange === 'cards-course') { store.setDevice('cardsCourse', el.value); ui.review = null; render(); return; }
  if (el.dataset.actChange === 'cards-addto') { store.setDevice('cardsAddTo', el.value); render(); return; }
  if (el.dataset.actChange === 'nav-hide') { const h = new Set(store.device('navHidden', [])); el.checked ? h.delete(el.value) : h.add(el.value); store.setDevice('navHidden', [...h]); render(); return; }
  if (el.dataset.bind === 'projectTodayDays') { store.updateSettings({ projectTodayDays: Number(el.value) }); return; }
  if (el.dataset.bind === 'todoRange') { ui.todo.range = Number(el.value); render(); return; }
  if (el.dataset.bind === 'todoCompleted') { ui.todo.showCompleted = el.checked; render(); return; }
  if (el.closest('[data-form="editor"]')) {
    if (el.dataset.edit === 'preset') {
      const p = (store.settings.taskPresets || []).find(x => x.id === el.value);
      readEditorInputs();
      if (p) applyPreset(ui.modal, p);
      renderModal();
      return;
    }
    if ('rerender' in el.dataset) { readEditorInputs(); renderModal(); }
    return;
  }
  if (el.dataset.presetName) {
    const name = el.value.trim();
    if (name) store.updateSettings({ taskPresets: store.settings.taskPresets.map(p => p.id === el.dataset.presetName ? { ...p, name } : p) });
    return;
  }
  if (el.dataset.setting) {
    const key = el.dataset.setting;
    const v = el.dataset.type === 'bool' ? el.checked : Number.isNaN(Number(el.value)) ? el.value : Number(el.value);
    if (key.startsWith('availability.')) store.updateSettings({ availability: { ...store.settings.availability, [key.split('.')[1]]: v } });
    else store.updateSettings({ [key]: v });
    return;
  }
  if (el.dataset.settingSet) {
    const key = el.dataset.settingSet;
    const set = new Set(store.settings[key]);
    if (el.checked) set.add(el.value); else set.delete(el.value);
    store.updateSettings({ [key]: [...set] });
    return;
  }
  if (el.dataset.actChange === 'ai-toggle') { ai.on = el.checked; render(); return; }
  if (el.dataset.actChange === 'browser-reminders') { store.setDevice('browserReminders', el.checked); render(); return; }
  if (el.dataset.actChange === 'focus-pick') {
    const pick = ui.focusPick ?? new Set(store.todayChecklist().filter(o => !o.resolved).map(o => o.id));
    if (el.checked) pick.add(el.value); else pick.delete(el.value);
    ui.focusPick = pick; render();
    return;
  }
  if (el.dataset.bind === 'focusMinutes') { ui.focusMinutes = M.clampFocus(el.value); render(); return; }
  if (el.dataset.actChange === 'open-at-login') { ui.openAtLogin = el.checked; window.cadenceDesktop?.setOpenAtLogin(el.checked); return; }
  if (el.dataset.actChange === 'cal-toggle') {
    store.setCalendarShown(el.value, el.checked);
    ui.booking.loadedFor = null;   // busy times depend on which calendars count
    return;
  }
  if (el.dataset.actChange === 'gcal') {
    const ids = [...document.querySelectorAll('[data-act-change="gcal"]:checked')].map(x => x.value);
    store.setDevice('googleCalendarIDs', ids);
    store.refreshGoogle();
  }
});

document.addEventListener('submit', async e => {
  const form = e.target;
  e.preventDefault();
  const kind = form.dataset.form;
  if (kind === 'mistake') {
    const t = ($('#mistakeText')?.value || '').trim(), r = studyRun;
    if (t && r) {
      if (r.courseId) store.editCourse(r.courseId, c => { c.mistakes.push({ id: M.uuid(), text: t, addedAt: M.iso(new Date()) }); if ($('#mistakeCard')?.checked) c.cards.push(M.newCard(t, '')); });
      updateRun(x => { x.mistakes.push(t); });
      setTimeout(() => $('#mistakeText')?.focus(), 0);
    }
    return;
  }
  if (kind === 'period-task') {
    const input = form.querySelector('input'), t = input.value.trim();
    if (t) store.editCourse(form.dataset.course, c => { c.periods[+form.dataset.i].tasks.push(t); });
    const id = input.id; setTimeout(() => document.getElementById(id)?.focus(), 0);
    return;
  }
  if (kind === 'card-add') {
    const f = ($('#cardFront')?.value || '').trim(), b = ($('#cardBack')?.value || '').trim(), cid = $('#cardCourse')?.value;
    if (f && cid) store.editCourse(cid, c => { c.cards.push(M.newCard(f, b)); });
    setTimeout(() => $('#cardFront')?.focus(), 0);
    return;
  }
  if (kind === 'font-custom') {
    const name = ($('#fontName')?.value || '').replace(/[^\w .-]/g, '').trim();
    if (name) { setFont(`custom:${name}`); ui.fontCustom = false; render(); toast(`Font: ${name}`, { icon: 'check' }); }
    return;
  }
  if (kind === 'site-add') { addBlockedSite($('#siteNew')?.value); setTimeout(() => $('#siteNew')?.focus(), 0); return; }
  if (kind === 'project-add') {
    const input = form.querySelector('input'), title = input.value.trim();
    if (title) store.editProject(form.dataset.project, p => M.insertItem(p, M.newProjectItem({ title })));
    setTimeout(() => { const i = document.getElementById(`padd-${form.dataset.project}`); if (i) { i.value = ''; i.focus(); } }, 0);
    return;
  }
  if (kind === 'quick') {
    const input = form.querySelector('input');
    const title = input.value.trim();
    if (title) {
      store.upsertTask(M.newTask({ title, channels: [...store.settings.defaultChannels] }));
      toast(`Added “${title}” to today`, { icon: 'plus' });
    }
    input.value = '';
  } else if (kind === 'auth') {
    const fd = new FormData(form);
    ui.auth.busy = true; ui.auth.error = null; render();
    try {
      await store.signIn(String(fd.get('username')).trim(), String(fd.get('password')), { create: ui.auth.mode === 'register', remember: fd.get('remember') === 'on' });
      ui.auth = { mode: 'login', error: null, busy: false };
      navigate('home');
      reminders.checkIn('Time to check in');
    } catch (err) {
      ui.auth.busy = false; ui.auth.error = err.message; render();
    }
  } else if (kind === 'distracting') {
    const app = form.querySelector('[name=app]').value.trim();
    if (app && !(store.settings.distractingApps || []).some(x => x.toLowerCase() === app.toLowerCase())) store.updateSettings({ distractingApps: [...(store.settings.distractingApps || []), app] });
  } else if (kind === 'scorecard') {
    const input = form.querySelector('[name=text]'), text = input.value.trim();
    if (!text) return;
    store.updateSettings({ habitScorecard: [...(store.settings.habitScorecard || []), { id: M.uuid(), text, rating: '=' }] });
    setTimeout(() => $('[data-form="scorecard"] [name=text]')?.focus());
  } else if (kind === 'ai-key') {
    const key = String(new FormData(form).get('key') || '').trim();
    if (!key) return;
    ai.key = key; ai.on = true; render();
    toast('Gemini key saved in this browser', { icon: 'lock' });
  } else if (kind === 'work-new') {
    // "Something else": a quiet task for today (no reminders), and straight to work on it.
    const title = String(new FormData(form).get('title') || '').trim();
    if (!title) return;
    const t = M.newTask({ title, kind: 'task', channels: [] });
    store.upsertTask(t);
    const o = store.todayChecklist().find(x => x.task.id === t.id);
    if (o) startWork(o);
  } else if (kind === 'reflection') {
    const text = $('#reflText').value.trim();
    const o = findOcc(form.dataset.occ), missed = form.dataset.mode === 'missed';
    if (o && ai.enabled && M.countWords(text) >= store.settings.minReflectionWords) {
      // Gemini reads it first; filler goes back with a note.
      const btn = $('#reflSubmit'), note = $('#reflAi');
      btn.disabled = true; btn.dataset.label ??= btn.innerHTML; btn.textContent = 'Checking…';
      const v = await checkReflection(text, missed ? `Why “${o.task.title}” didn’t get done` : `Checking off “${o.task.title}”`);
      btn.innerHTML = btn.dataset.label; btn.disabled = false;
      if (!v.genuine) { if (note) { note.hidden = false; note.textContent = v.reason; } return; }
    }
    const taken = missed ? null : M.parseMinutes($('#reflTaken')?.value);
    if (!o || !(missed ? store.miss(o, text) : store.complete(o, text, taken))) return;
    if (missed) toast(`Marked ${o.task.title} as not done · reflection saved`, { icon: 'x' });
    else {
      ui.justDone.add(o.id);
      setTimeout(() => { ui.justDone.delete(o.id); }, 1200);
      toast(`Checked off ${o.task.title} · reflection saved`, { icon: 'check', tone: 'good' });
    }
    if (form.dataset.ctx === 'checkin') { ui.modal.reflecting = null; renderModal(); render(); }
    else if (form.dataset.ctx === 'locked') nextQueuedReflection();
    else closeModal();
  } else if (kind === 'delete-account') {
    const m = ui.modal;
    m.working = true; m.error = null; renderModal();
    try {
      await store.deleteAccount(String(new FormData(form).get('password')));
      ui.modal = null; renderModal();
      ui.auth = { mode: 'login', error: null, busy: false };
      render();
      toast('Your account and data were deleted', { icon: 'check' });
    } catch (err) {
      m.working = false; m.error = err.message; renderModal();
    }
  } else if (kind === 'calendly') {
    const token = String(new FormData(form).get('token') || '').trim();
    ui.calendlyBusy = true; render();
    try {
      await store.connectCalendly(token);
      toast(`Calendly connected${store.calendly.name ? ` as ${store.calendly.name}` : ''}`, { icon: 'check', tone: 'good' });
      runImport({ manual: true });
    } catch (err) {
      toast(err.message, { icon: 'alert', tone: 'bad' });
    }
    ui.calendlyBusy = false; render();
  } else if (kind === 'editor') {
    saveEditor();
  } else if (kind === 'booking') {
    const m = ui.modal, fd = new FormData(form);
    const name = String(fd.get('name') || '').trim(), email = String(fd.get('email') || '').trim();
    const title = String(fd.get('title') || '').trim() || (name ? `Meeting with ${name}` : 'Meeting');
    const [hh, mm] = String(fd.get('time')).split(':').map(Number);
    const minutes = Number(fd.get('minutes')) || 30, notes = String(fd.get('notes') || '');
    const start = M.dayAt(m.start, hh * 60 + mm), end = M.addMinutes(start, minutes);
    const local = M.newTask({ kind: 'event', busy: true, color: 'purple', title, notes, startDate: M.iso(M.startOfDay(start)),
      timeMinutes: hh * 60 + mm, durationMinutes: minutes, reminderOffsets: [10], channels: [...store.settings.defaultChannels] });
    m.working = true; m.error = null; renderModal();
    try {
      if (store.google.connected) {
        const ev = await store.createGoogleEvent({ title, details: notes, start: M.iso(start), end: M.iso(end), busy: true,
          ...(email ? { attendees: [{ email, name }] } : {}), addMeetLink: fd.get('meet') === 'on' });
        // Keep the synced copy right away (same ID the importer gives it) so open time updates at once.
        store.upsertTask({ ...local, id: await M.stableUUID(`google:${ev.id}`), source: 'google', googleEventID: ev.id,
          sourceCalendar: ev.calendarID || 'primary', ...(ev.link ? { externalURL: ev.link } : {}) });
        ui.booking.message = email ? `Booked “${title}” — invitation sent to ${email}.` : `Booked “${title}” in Cadence and Google Calendar.`;
      } else {
        store.upsertTask(local);
        ui.booking.message = `Booked “${title}” on your Cadence calendar.`;
      }
      ui.booking.loadedFor = null;
      closeModal();
    } catch (err) {
      m.working = false; m.error = err.message; renderModal();
    }
  }
});

const SHORTCUT_FOR = { home: 'H', today: 'T', week: 'W', month: 'M', todo: 'L', projects: 'P', study: 'Y', flashcards: 'K', notes: 'O', habits: 'A', reflections: 'R', focus: 'F', screentime: 'U', booking: 'B', settings: ',' };
document.addEventListener('keydown', e => {
  // Notes: Return or Tab in the title goes to the body.
  if (e.target.dataset?.noteField === 'title' && (e.key === 'Enter' || (e.key === 'Tab' && !e.shiftKey))) {
    e.preventDefault();
    const b = document.getElementById(`noteBody-${e.target.dataset.id}`);
    if (b) { b.focus(); b.setSelectionRange(0, 0); }
    return;
  }
  // Flashcard review: space shows the answer, 1-4 grade it.
  if (ui.route === 'flashcards' && ui.review && !e.target.closest?.('input, textarea, select') && !ui.modal) {
    if (e.key === ' ' && !ui.review.shown) { e.preventDefault(); actions['review-show'](); return; }
    const g = { 1: 'again', 2: 'hard', 3: 'good', 4: 'easy' }[e.key];
    if (g && ui.review.shown) { e.preventDefault(); actions['review-grade']({ dataset: { g } }); return; }
  }
  // Habit editor: Return in the "add a step" box adds the step instead of saving the habit.
  if (e.target.dataset?.edit === 'step-new' && e.key === 'Enter' && !e.isComposing) { e.preventDefault(); actions['step-add'](e.target); return; }
  // Projects: see PROJECT_KEYS.
  if (ui.route === 'projects' && ui.projectId && !ui.modal && !e.isComposing && projKey(e)) { e.preventDefault(); return; }
  const typing = e.target.closest?.('input, textarea, select, [contenteditable]');
  if (!typing && !ui.modal && store.user && !e.metaKey && !e.ctrlKey && !e.altKey) {
    const k = e.key.toLowerCase();
    const route = Object.entries(SHORTCUT_FOR).find(([, key]) => key.toLowerCase() === k)?.[0];
    if (route) { e.preventDefault(); navigate(route); return; }
    if (k === 'n') { e.preventDefault(); newTaskAt(new Date()); return; }
    if (k === 'e') { e.preventDefault(); newEventAt(new Date()); return; }
    if (k === 'c') { e.preventDefault(); reminders.checkIn('Daily check-in', { manual: true }); return; }
    if (k === 's') { e.preventDefault(); syncUI.manual = true; store.sync(); return; }
  }
  if (e.key === 'Escape' && ui.modal && !ui.modal.locked && !['editor', 'nag'].includes(ui.modal.type)) closeModal();
  if (e.key === 'Enter' && (e.metaKey || e.ctrlKey) && e.target.id === 'reflText' && !$('#reflSubmit').disabled) $('#reflSubmit').click();
  if (e.key === 'Enter' && (e.metaKey || e.ctrlKey) && e.target.closest('[data-form="editor"]')) { e.preventDefault(); saveEditor(); }
});

// Keep "now" lines, greetings and day boundaries fresh.
setInterval(() => { if (!ui.modal || ['checkin', 'detail'].includes(ui.modal.type)) render(); }, 60_000);

// ---------- calendar imports (Google + Calendly → silent checklist items) ----------
// IDs match the Mac app (stableUUID of "google:<event id>" / "calendly:<uri>"), so either device can import.
async function runImport({ manual = false } = {}) {
  if (ui.importing || !store.user) return;
  const s = store.settings;
  if (!manual && !s.autoImportCalendars) return;
  if (!store.google.connected && !store.calendly.connected) {
    if (manual) toast('Connect Google Calendar or Calendly first', { icon: 'alert', tone: 'bad' });
    return;
  }
  ui.importing = true; render();
  const from = M.startOfDay(new Date()), to = M.addDays(from, Math.max(1, s.importDaysAhead));
  const parts = [];
  const summary = (name, r) => `${name}: ${r.added} new, ${r.updated} updated, ${r.removed} removed`;
  if (store.google.connected) {
    try {
      const { events, cancelled } = await store.googleImportWindow(from, to);
      const items = await Promise.all(events.map(googleTask));
      const archiveIds = new Set(await Promise.all(cancelled.map(id => M.stableUUID(`google:${id}`))));
      // Imported earlier but no longer in the window: moved or deleted. Ask Google about each.
      const seen = new Set([...items.map(i => i.id), ...archiveIds]);
      const stale = [...store.tasks.values()].filter(t => t.source === 'google' && !t.archived && !Object.keys(t.completions || {}).length
        && !seen.has(t.id) && new Date(t.startDate) >= from && new Date(t.startDate) < to && t.googleEventID).slice(0, 25);
      for (const t of stale) {
        const ev = await store.googleEvent(t.sourceCalendar || 'primary', t.googleEventID).catch(() => undefined);
        if (ev) items.push(await googleTask(ev)); else if (ev === null) archiveIds.add(t.id);
      }
      parts.push(summary('Google', store.applyImport('google', items, from, to, { archiveMissing: false, archiveIds })));
      store.refreshGoogleView();
    } catch (e) { parts.push(`Google failed: ${e.message}`); }
  }
  if (store.calendly.connected && (manual || Date.now() - ui.lastCalendlyImport > 30 * 60_000)) {
    ui.lastCalendlyImport = Date.now();
    try {
      const meetings = await store.calendlyMeetings(from, to);
      const items = await Promise.all(meetings.map(async m => {
        const st = new Date(m.start), en = new Date(m.end);
        return M.newTask({
          id: await M.stableUUID(`calendly:${m.uri}`), title: m.name + (m.invitees.length ? ` with ${m.invitees.join(', ')}` : ''),
          notes: m.location || '', startDate: M.iso(M.startOfDay(st)), timeMinutes: M.minutesOf(st),
          durationMinutes: Math.max(5, Math.floor((en - st) / 60_000)),
          channels: [], color: 'purple', source: 'calendly', ...(m.joinURL ? { externalURL: m.joinURL } : {}),
        });
      }));
      parts.push(summary('Calendly', store.applyImport('calendly', items, from, to)));
    } catch (e) { parts.push(`Calendly failed: ${e.message}`); }
  }
  if (store.google.connected && store.google.tasks && s.syncGoogleTasks !== false) {
    try { parts.push(summary('Google Tasks', await importGoogleTasks())); } catch (e) { parts.push(`Google Tasks failed: ${e.message}`); }
  }
  ui.importing = false;
  ui.importSummary = `${parts.join(' · ')} — ${M.fmtTime(new Date())}`;
  if (manual) toast(parts.join(' · '), { icon: parts.some(p => p.includes('failed')) ? 'alert' : 'check' });
  render();
}
/** Google Tasks → Cadence: new ones arrive as until-done tasks; edits update them; ones completed or deleted
 *  in Google are hidden here. Checking one off in Cadence (or unchecking it) updates Google right away. */
async function importGoogleTasks() {
  const { tasks } = await store.googleTasks();
  let added = 0, updated = 0, removed = 0;
  for (const gt of tasks) {
    const item = await M.taskFromGoogleTask(gt), cur = store.tasks.get(item.id);
    const doneHere = cur && Object.keys(cur.completions || {}).length > 0;
    if (gt.deleted || gt.status === 'completed') {
      if (cur && !cur.archived && !doneHere) { store.upsertTask({ ...cur, archived: true }); removed++; }
      continue;
    }
    if (!cur) { store.upsertTask(item); added++; continue; }
    if (cur.archived) continue;
    if (doneHere) { store.updateGoogleTask({ listId: gt.listId, taskId: gt.id, status: 'completed' }).catch(() => {}); continue; }
    const next = { ...cur, title: item.title, notes: item.notes, sourceCalendar: item.sourceCalendar };
    if (item.dueDate) next.dueDate = item.dueDate; else delete next.dueDate;
    if (next.title !== cur.title || next.notes !== cur.notes || next.dueDate !== cur.dueDate) { store.upsertTask(next); updated++; }
  }
  return { added, updated, removed };
}
store.onGoogleTaskChange = (t, patch) => store.updateGoogleTask({ listId: t.sourceCalendar || '@default', taskId: t.googleTaskID, ...patch })
  .catch(e => toast(`Google Tasks didn't update: ${e.message}`, { icon: 'alert', tone: 'bad' }));

// Google is re-checked every 2 minutes and whenever you come back to the tab; Calendly every 30.
ui.lastCalendlyImport = 0;
setInterval(() => { if (!document.hidden) runImport(); }, 2 * 60_000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) runImport(); });

/** A Google event as a silent checklist task — field-for-field the same as the Mac and server importers. */
async function googleTask(e) {
  const raw = e.id.slice(e.id.indexOf('|') + 1);
  const st = e.isAllDay ? M.parseKey(e.start) : new Date(e.start);
  const en = e.isAllDay ? M.parseKey(e.end) : new Date(e.end);
  return M.newTask({
    id: await M.stableUUID(`google:${raw}`), title: e.title, notes: M.eventNotes(e.description, e.location),
    startDate: M.iso(M.startOfDay(st)), ...(e.isAllDay ? {} : { timeMinutes: M.minutesOf(st) }),
    durationMinutes: e.isAllDay ? 30 : Math.max(5, Math.floor((en - st) / 60_000)),
    channels: [], color: 'blue', source: 'google', googleEventID: raw, sourceCalendar: e.calendarID,
    ...(e.link ? { externalURL: e.link } : {}), busy: !e.transparent,
  });
}

// ---------- sync indicator ----------
const syncUI = { manual: false, spinUntil: 0, flashUntil: 0 };

function relTime(d) {
  const sec = (Date.now() - new Date(d)) / 1000;
  if (sec < 45) return 'just now';
  if (sec < 3600) return `${Math.round(sec / 60)} min ago`;
  return `at ${M.fmtTime(d)}`;
}

function syncControl(size = '') {
  return `<button class="syncbtn ${size}" data-act="sync-now" data-sync-ui title="Sync now (S)">
    <span class="sync-icon">${ic('sync', 'spin')}${ic('check', 'done')}</span><span class="sync-label">Sync</span></button>`;
}

function updateSyncUI() {
  const now = Date.now();
  const spinning = now < syncUI.spinUntil;
  const s = store.syncState;
  let label, state;
  if (spinning) { label = 'Syncing…'; state = 'syncing'; }
  else if (s.status === 'offline') { label = s.error || 'Offline'; state = 'offline'; }
  else if (s.lastSynced) { label = `Synced ${relTime(s.lastSynced)}`; state = now < syncUI.flashUntil ? 'synced flash' : 'synced'; }
  else { label = 'Not synced yet'; state = ''; }
  if (store.pending.size && !spinning) label += ` · ${store.pending.size} waiting`;
  for (const el of document.querySelectorAll('[data-sync-ui]')) {
    el.className = `syncbtn ${el.classList.contains('big') ? 'big' : ''} ${state}`;
    el.querySelector('.sync-label').textContent = label;
    el.title = s.status === 'offline' ? `${label} — click to retry` : 'Sync now (S)';
  }
}

store.onSync(() => {
  if (store.syncing) {
    // Show motion for anything the user caused (a button press or a local edit being pushed);
    // quiet background polls don't flicker the icon.
    if (syncUI.manual || store.pending.size) syncUI.spinUntil = Math.max(syncUI.spinUntil, Date.now() + 750);
    updateSyncUI();
    return;
  }
  const visible = syncUI.spinUntil > Date.now() - 50;
  const finish = () => {
    if (visible && store.syncState.status === 'synced') syncUI.flashUntil = Date.now() + 1400;
    if (syncUI.manual && store.syncState.status === 'offline') toast(store.syncState.error || 'Couldn’t reach the server', { icon: 'alert', tone: 'bad' });
    syncUI.manual = false;
    updateSyncUI();
    setTimeout(updateSyncUI, 1500);
  };
  setTimeout(finish, Math.max(0, syncUI.spinUntil - Date.now()));
});
setInterval(updateSyncUI, 30_000);
addEventListener('offline', updateSyncUI);

// ---------- progress rings animate from their previous value ----------
function animateRings() {
  const arcs = document.querySelectorAll('.ring-arc[data-to]');
  if (!arcs.length) return;
  requestAnimationFrame(() => requestAnimationFrame(() => {
    for (const a of arcs) a.style.strokeDashoffset = a.dataset.to;
  }));
}

// ---------- toasts ----------
function toast(text, { icon = 'check', undo, tone } = {}) {
  let box = $('#toasts');
  if (!box) { box = document.createElement('div'); box.id = 'toasts'; document.body.append(box); }
  const el = document.createElement('div');
  el.className = `toast ${tone || ''}`;
  el.innerHTML = `${ic(icon)}<span class="grow">${esc(text)}</span>${undo ? '<button class="btn sm">Undo</button>' : ''}`;
  const close = () => { el.classList.add('leaving'); setTimeout(() => el.remove(), 200); };
  if (undo) el.querySelector('button').onclick = () => { undo(); close(); };
  box.append(el);
  while (box.children.length > 3) box.firstElementChild.remove();
  setTimeout(close, undo ? 6000 : 2800);
}

// ---------- desktop app (Windows/Linux) ----------
// The desktop wrapper exposes window.cadenceDesktop: wake/unlock events, tray commands, a tray badge.
if (window.cadenceDesktop) {
  window.cadenceDesktop.getOpenAtLogin?.().then(on => { ui.openAtLogin = on; if (ui.route === 'settings') render(); });
  window.cadenceDesktop.onWake(() => reminders.checkIn('Welcome back — check your list'));
  window.cadenceDesktop.onCommand(cmd => {
    if (cmd === 'check-in') reminders.checkIn('Daily check-in', { manual: true });
    if (cmd === 'new-task') newTaskAt(new Date());
  });
  store.subscribe(() => window.cadenceDesktop.setBadge(store.user ? store.remainingToday() : 0));
}

// ---------- start ----------
readRoute();
store.subscribe(render);
store.boot().then(() => {
  booted = true;
  render();
  if (store.user) reminders.start();
  else store.subscribe(function startOnce() { if (store.user && !reminders.started) { reminders.started = true; reminders.start(); } });
  if (store.user) reminders.started = true;
  setTimeout(() => runImport(), 4000);
});
