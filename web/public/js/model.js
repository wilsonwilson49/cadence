// Data model shared with the Mac app. Records use the exact JSON the Swift app encodes:
//   PlanTask   { id, title, notes, startDate (ISO, start of local day), timeMinutes?, durationMinutes,
//                recurrence: { frequency, interval, weekdays[1=Sun..7], end: {never:{}} | {onDate:{_0:ISO}} | {afterCount:{_0:n}} },
//                reminderOffsets[], channels[], color, completions{ 'yyyy-MM-dd': ISO }, missed?{ 'yyyy-MM-dd': ISO }, skipped[], googleEventID?, createdAt, updatedAt? }
//   Reflection { id, taskID, taskTitle, occurrenceKey, text, createdAt }
// Dates are ISO-8601 *without* milliseconds, because Swift's .iso8601 decoder rejects them.

export const iso = d => new Date(d).toISOString().replace(/\.\d{3}Z$/, 'Z');
export const uuid = () => crypto.randomUUID().toUpperCase();

/** Same key → same UUID as the Mac app's stableUUID (SHA-256, v5-style bits). Used for imported events. */
export async function stableUUID(key) {
  const b = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(key))).slice(0, 16);
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map(x => x.toString(16).padStart(2, '0')).join('').toUpperCase();
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

/** Notes for an imported Google event: its description as plain text, else its location.
 *  The Mac (GoogleCalendar.swift) and server (importer.js) use the exact same rule. */
export function eventNotes(description, location) {
  const text = String(description || '')
    .replace(/<br\s*\/?>/gi, '\n').replace(/<\/p>/gi, '\n').replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&')
    .trim();
  return text || String(location || '').trim();
}

/** Calendar toggles: each item belongs to one calendar key. 'tasks' and 'events' are your own Cadence items,
 *  'calendly' the Calendly imports, and 'google:<id>' a Google calendar ('google:primary' for your main one). */
export const googleCalendarKey = (calId, primaryId) =>
  !calId || calId === 'primary' || calId === primaryId ? 'google:primary' : `google:${calId}`;
export function calendarKeyOf(task, primaryId) {
  if (task.source === 'google') return googleCalendarKey(task.sourceCalendar, primaryId);
  if (task.source === 'calendly') return 'calendly';
  if (task.source === 'gtasks') return 'gtasks';
  return isEvent(task) ? 'events' : isHabit(task) ? 'habits' : 'tasks';
}

/** A Google Tasks item as a Cadence task: kept on your list until done (Google Tasks have no schedule), due on
 *  its due date, silent like other imports. Same fields as the Mac's importer. `firstSeen` is the day it arrived. */
export async function taskFromGoogleTask(gt, firstSeen = new Date()) {
  return newTask({
    id: await stableUUID(`gtasks:${gt.id}`), kind: 'task', mode: 'untilDone', title: gt.title, notes: gt.notes || '',
    startDate: iso(startOfDay(firstSeen)), ...(gt.due ? { dueDate: iso(parseKey(gt.due)) } : {}),
    channels: [], color: 'blue', source: 'gtasks', googleTaskID: gt.id, sourceCalendar: gt.listId, ...(gt.link ? { externalURL: gt.link } : {}),
  });
}

/** Checked off or marked "didn't do" at least once (imports never hide items with history). */
export const hasHistory = task => Object.keys(task.completions || {}).length > 0 || Object.keys(task.missed || {}).length > 0;
export const isSilent = task => !(task.channels && task.channels.length);
/** Events live on the calendars only: never on the checklist, no check-off, no reflection.
 *  Imported items (Google, Calendly) are events unless you explicitly make them a task. */
export const isEvent = task => task.kind === 'event' || (task.kind !== 'task' && Boolean(task.source));
/** Habits are anything you repeat on a schedule (Atomic Habits style), kept apart from one-off tasks.
 *  Explicit kind 'habit', or any repeating non-event item (so older repeating tasks became habits). */
export const isHabit = task => !isEvent(task) && (task.kind === 'habit' || (task.recurrence?.frequency || 'none') !== 'none');
export const HABIT_STYLES = [
  ['build', 'Build a new habit'], ['stack', 'Stack it on a habit'], ['replace', 'Replace a bad habit'], ['break', 'Break a habit'],
];

/** Closed items block their time; open ones are just for info. Unset: events are closed, tasks open. */
export const isBusy = task => task.busy ?? isEvent(task);

// ---------- dates ----------
export const startOfDay = d => { const x = new Date(d); x.setHours(0, 0, 0, 0); return x; };
export const addDays = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
export const addMonths = (d, n) => { const x = new Date(d); x.setMonth(x.getMonth() + n); return x; };
export const addMinutes = (d, n) => new Date(new Date(d).getTime() + n * 60_000);
export const startOfWeek = d => addDays(startOfDay(d), -new Date(d).getDay()); // weeks start Sunday
export const startOfMonth = d => { const x = startOfDay(d); x.setDate(1); return x; };
export const weekday = d => new Date(d).getDay() + 1; // 1 = Sunday … 7 = Saturday (Swift Calendar)
export const sameDay = (a, b) => dateKey(a) === dateKey(b);
export const isToday = d => sameDay(d, new Date());
export const minutesOf = d => new Date(d).getHours() * 60 + new Date(d).getMinutes();
export const dayAt = (day, minutes) => { const x = startOfDay(day); x.setHours(Math.floor(minutes / 60), minutes % 60, 0, 0); return x; };
export const daysBetween = (a, b) => Math.round((startOfDay(b) - startOfDay(a)) / 86_400_000);

export function dateKey(d) {
  const x = new Date(d);
  return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}`;
}
export function parseKey(k) {
  const [y, m, d] = k.split('-').map(Number);
  return new Date(y, m - 1, d);
}

// ---------- formatting ----------
const fmt = (opts) => new Intl.DateTimeFormat(undefined, opts);
export const fmtTime = d => fmt({ hour: 'numeric', minute: '2-digit' }).format(new Date(d));
export const fmtTimeMinutes = m => fmtTime(dayAt(new Date(), m));
export const fmtDay = (d, opts = { weekday: 'long', month: 'long', day: 'numeric' }) => fmt(opts).format(new Date(d));
export const WEEKDAY_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
export const WEEKDAY_LETTER = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

export function offsetLabel(m) {
  if (m < 0) { const a = -m; return a % 60 === 0 ? `${a / 60} hr into task` : `${a} min into task`; }
  if (m === 0) return 'At start';
  if (m % 1440 === 0) return m === 1440 ? '1 day before' : `${m / 1440} days before`;
  if (m % 60 === 0) return m === 60 ? '1 hour before' : `${m / 60} hours before`;
  return `${m} min before`;
}

export function countWords(text) {
  return String(text).split(/\s+/).filter(w => /[\p{L}\p{N}]/u.test(w)).length;
}

// ---------- recurrence ----------
export const FREQUENCIES = [
  ['none', 'Does not repeat', ''], ['daily', 'Daily', 'day'], ['weekly', 'Weekly', 'week'],
  ['monthly', 'Monthly', 'month'], ['yearly', 'Yearly', 'year'],
];

export function endOf(rec) {
  const e = rec.end || { never: {} };
  if (e.onDate) return { type: 'onDate', date: new Date(e.onDate._0) };
  if (e.afterCount) return { type: 'afterCount', count: e.afterCount._0 };
  return { type: 'never' };
}

export const effectiveWeekdays = (rec, start) =>
  (rec.weekdays && rec.weekdays.length ? [...rec.weekdays].sort((a, b) => a - b) : [weekday(start)]);

function matches(task, d, s) {
  const r = task.recurrence;
  const n = Math.max(1, r.interval || 1);
  switch (r.frequency) {
    case 'none': return daysBetween(s, d) === 0;
    case 'daily': return daysBetween(s, d) % n === 0;
    case 'weekly':
      if (!effectiveWeekdays(r, s).includes(weekday(d))) return false;
      return Math.floor(daysBetween(startOfWeek(s), startOfWeek(d)) / 7) % n === 0;
    case 'monthly': {
      if (d.getDate() !== s.getDate()) return false;
      const months = (d.getFullYear() - s.getFullYear()) * 12 + d.getMonth() - s.getMonth();
      return months % n === 0;
    }
    case 'yearly':
      if (d.getDate() !== s.getDate() || d.getMonth() !== s.getMonth()) return false;
      return (d.getFullYear() - s.getFullYear()) % n === 0;
    default: return false;
  }
}

function patternIndex(task, d, s) {
  let count = 0;
  for (let c = s, i = 0; c < d && i < 20000; c = addDays(c, 1), i++) if (matches(task, c, s)) count++;
  return count;
}

/** Long-term: every day until an end date (each day is its own check-off).
 *  Until done ("keep it on my list"): each one stays on the list every day until it's checked off or marked
 *  not done, or until the next repeat arrives (the next one takes over). */
export const isLongTerm = task => task.mode === 'longTerm';
export const isUntilDone = task => task.mode === 'untilDone';

/** "After it's done, with a break": an until-done task with no dates. When a round is settled it takes a break of
 *  cycleGapDays, then comes back, for cycleTimes rounds in total. */
export const isCycle = task => isUntilDone(task) && task.cycleGapDays != null;

/** A cycle task's rounds so far: [{ start, settled }] (settled = the day key it was checked off / marked not done). */
export function cycleRounds(task) {
  const keys = [...Object.keys(task.completions || {}), ...Object.keys(task.missed || {})].sort();
  const times = Math.max(1, task.cycleTimes || 1), rounds = [];
  let start = startOfDay(task.startDate);
  for (let i = 0; i < times; i++) {
    const from = dateKey(start), settled = keys.find(k => k >= from) ?? null;
    rounds.push({ start, settled });
    if (!settled) break;
    start = addDays(parseKey(settled), Math.max(0, task.cycleGapDays));
  }
  return rounds;
}

/** Where a cycle task stands today: the round, or the break before the next one, or finished. */
export function cycleStatus(task, day = new Date()) {
  const rounds = cycleRounds(task), times = Math.max(1, task.cycleTimes || 1), d = startOfDay(day);
  const last = rounds[rounds.length - 1];
  if (last.settled && rounds.length >= times) return { finished: true, round: times, times };
  if (last.settled) return { round: rounds.length + 1, times, nextStart: addDays(parseKey(last.settled), task.cycleGapDays) };
  if (last.start > d) return { round: rounds.length, times, nextStart: last.start };
  return { round: rounds.length, times, active: true };
}

/** Where an until-done task's current one started: the latest repeat day on or before `day` (its start if it doesn't repeat). */
export function repStartOn(task, day) {
  if (isCycle(task)) {
    const d = startOfDay(day);
    return cycleRounds(task).filter(r => r.start <= d).pop()?.start ?? null;
  }
  const s = startOfDay(task.startDate);
  for (let c = startOfDay(day), i = 0; c >= s && i < 400; c = addDays(c, -1), i++) if (occursByPattern(task, c)) return c;
  return null;
}

/** How the current one (as of `day`) was settled: { key, missed } for the first check-off or "didn't do it", or null. */
export function finishOf(task, day = new Date()) {
  const rep = repStartOn(task, day);
  if (!rep) return null;
  const from = dateKey(rep);
  const keys = [...Object.keys(task.completions || {}), ...Object.keys(task.missed || {})].filter(k => k >= from).sort();
  return keys.length ? { key: keys[0], missed: !(task.completions && task.completions[keys[0]]) } : null;
}
export const finishedKey = (task, day) => finishOf(task, day)?.key ?? null;

// ---------- habit tracker ----------
/** The next day the habit's schedule lands on after `day` (null if none within a year). */
function nextScheduled(task, day) {
  for (let c = addDays(day, 1), i = 0; i < 400; c = addDays(c, 1), i++) if (occursByPattern(task, c)) return c;
  return null;
}

/** Streaks, rate and a 30-day grid for a habit. Each scheduled day is done (checked off), missed
 *  ("didn't do it"), open (today, still to do) or lapsed (passed without either). For a habit that's kept
 *  until done, a scheduled day counts as done if it was checked off before the next one came. */
export function habitStats(task, today = new Date()) {
  const t0 = startOfDay(today), start = startOfDay(task.startDate);
  const done = new Set(Object.keys(task.completions || {})), missed = new Set(Object.keys(task.missed || {}));
  const carry = isUntilDone(task);
  const stateOf = d => {
    const key = dateKey(d);
    if (!carry) return done.has(key) ? 'done' : missed.has(key) ? 'missed' : sameDay(d, t0) ? 'open' : 'lapsed';
    const next = nextScheduled(task, d), until = next ? dateKey(next) : '9999';
    const inRep = k => k >= key && k < until;
    if ([...done].some(inRep)) return 'done';
    if ([...missed].some(inRep)) return 'missed';
    return next && next <= t0 ? 'lapsed' : 'open';
  };
  const days = [];   // scheduled days, oldest first, up to today (a year at most)
  for (let c = addDays(t0, -365), i = 0; i <= 365; c = addDays(c, 1), i++) if (c >= start && occursByPattern(task, c)) days.push(c);
  const states = days.map(d => ({ day: d, state: stateOf(d) }));
  // Current streak: done days in a row, not counting today if it's still open.
  let streak = 0;
  for (let i = states.length - 1; i >= 0; i--) {
    if (states[i].state === 'open' && i === states.length - 1) continue;
    if (states[i].state !== 'done') break;
    streak++;
  }
  let best = 0, run = 0;
  for (const s of states) { run = s.state === 'done' ? run + 1 : 0; best = Math.max(best, run); }
  const recent = states.filter(s => s.day > addDays(t0, -30) && s.state !== 'open');
  const rate = recent.length ? Math.round(100 * recent.filter(s => s.state === 'done').length / recent.length) : null;
  // "Never miss twice": the last scheduled day before today wasn't done.
  const past = states.filter(s => s.state !== 'open');
  const last = past[past.length - 1];
  const missTwice = Boolean(last && last.state !== 'done' && states.some(s => s.state === 'open'));
  const grid = [...Array(30)].map((_, i) => {
    const d = addDays(t0, i - 29), s = states.find(x => sameDay(x.day, d));
    return { day: d, state: s ? s.state : 'off' };
  });
  return { streak, best, rate, votes: done.size, missTwice, grid, today: states.find(s => sameDay(s.day, t0))?.state ?? null };
}

/** For an until-done occurrence: "On your list since Mon · day 3", so carried-over items read as one task. */
export function carryLabel(task, day) {
  const rep = repStartOn(task, day);
  if (!rep) return '';
  const n = daysBetween(rep, day) + 1;
  return n <= 1 ? 'New today' : `On your list since ${fmtDay(rep, { weekday: 'short', month: 'short', day: 'numeric' })} · day ${n}`;
}
/** Whether an until-done task was (or will be) on your list on `day`, past days included: for drawing its whole stretch. */
export function untilDoneActive(task, day) {
  if (task.archived) return false;
  const d = startOfDay(day), rep = repStartOn(task, d);
  if (!rep) return false;
  const key = dateKey(d), from = dateKey(rep);
  return ![...Object.keys(task.completions || {}), ...Object.keys(task.missed || {})].some(k => k >= from && k < key);
}
/** Where an until-done task appears on a month grid: the day one starts, the day it's settled, and today. */
export function untilDoneMarker(o) {
  const rep = repStartOn(o.task, o.day);
  return Boolean(rep && sameDay(rep, o.day)) || o.resolved || isToday(o.day);
}

export function occurs(task, day) {
  if (task.archived) return false;
  const d = startOfDay(day);
  if (d < startOfDay(task.startDate)) return false;
  if (!isUntilDone(task)) return occursByPattern(task, d);
  // Until done: shows every day from its repeat day until it's settled (checked off or "didn't do it");
  // the next repeat replaces it. Past days only keep the day it was settled.
  const rep = repStartOn(task, d);
  if (!rep) return false;
  const key = dateKey(d), from = dateKey(rep);
  const settled = [...Object.keys(task.completions || {}), ...Object.keys(task.missed || {})].some(k => k >= from && k < key);
  if (settled) return false;
  if (d < startOfDay(new Date())) return Boolean((task.completions && task.completions[key]) || (task.missed && task.missed[key]));
  return true;
}

/** The plain repeat schedule (no until-done carry-over). */
function occursByPattern(task, d) {
  const s = startOfDay(task.startDate);
  if (d < s) return false;
  const repeating = task.recurrence.frequency !== 'none';
  const end = endOf(task.recurrence);
  if (repeating && end.type === 'onDate' && d > startOfDay(end.date)) return false;
  if (!matches(task, d, s)) return false;
  if (repeating && end.type === 'afterCount' && patternIndex(task, d, s) >= end.count) return false;
  return !(task.skipped || []).includes(dateKey(d));
}

export function nextOccurrence(task, from = new Date()) {
  let day = startOfDay(Math.max(startOfDay(from), startOfDay(task.startDate)));
  for (let i = 0; i < 400; i++) {
    if (occurs(task, day)) return day;
    if (task.recurrence.frequency === 'none' && !isUntilDone(task)) return null;
    day = addDays(day, 1);
  }
  return null;
}

/** How a task repeats, in words: covers the long-term and until-done types too. */
export function planSummary(task) {
  if (isCycle(task)) {
    const gap = task.cycleGapDays % 7 === 0 && task.cycleGapDays ? `${task.cycleGapDays / 7} week${task.cycleGapDays === 7 ? '' : 's'}` : `${task.cycleGapDays} day${task.cycleGapDays === 1 ? '' : 's'}`;
    const st = cycleStatus(task);
    if (st.finished) return `Until done, back ${gap} later · all ${st.times} times done`;
    if (st.nextStart) return `Until done, back ${gap} later · round ${st.round} of ${st.times} on ${fmtDay(st.nextStart, { month: 'short', day: 'numeric' })}`;
    return `Until done, back ${gap} later · round ${st.round} of ${st.times}`;
  }
  if (isUntilDone(task)) {
    const repeats = task.recurrence.frequency !== 'none';
    const base = repeats ? `Until done · a new one ${recurrenceSummary(task.recurrence, task.startDate).replace(/^Every /, 'every ').replace(/^(Daily|Weekly|Monthly|Yearly)/, m => m.toLowerCase())}` : 'Every day until done';
    const f = finishOf(task);
    if (f) return `${base} · ${f.missed ? 'not done' : 'finished'}`;
    if (!task.dueDate || repeats) return base;
    const left = daysBetween(new Date(), task.dueDate);
    return `${base} · due ${fmtDay(task.dueDate, { month: 'short', day: 'numeric' })}${left > 1 ? ` (${left} days left)` : left === 1 ? ' (tomorrow)' : left === 0 ? ' (today)' : ''}`;
  }
  if (isLongTerm(task)) {
    const e = endOf(task.recurrence);
    if (e.type !== 'onDate') return 'Long-term · every day';
    const left = daysBetween(new Date(), e.date);
    return `Long-term · every day until ${fmtDay(e.date, { month: 'short', day: 'numeric' })}${left > 0 ? ` (${left} day${left === 1 ? '' : 's'} left)` : left === 0 ? ' (last day)' : ''}`;
  }
  return task.recurrence.frequency === 'none' ? '' : recurrenceSummary(task.recurrence, task.startDate);
}

/** An until-done task past its due date that still isn't finished. */
export const pastDue = task => isUntilDone(task) && !isCycle(task) && task.recurrence.frequency === 'none' && task.dueDate && !finishOf(task) && startOfDay(task.dueDate) < startOfDay(new Date());

export function recurrenceSummary(rec, start) {
  const n = Math.max(1, rec.interval || 1);
  let s;
  switch (rec.frequency) {
    case 'none': return 'Once';
    case 'daily': s = n === 1 ? 'Every day' : `Every ${n} days`; break;
    case 'weekly': {
      const days = effectiveWeekdays(rec, start);
      if (n === 1 && days.join() === '2,3,4,5,6') s = 'Every weekday';
      else if (n === 1 && days.length === 7) s = 'Every day';
      else s = `${n === 1 ? 'Weekly' : `Every ${n} weeks`} on ${days.map(w => WEEKDAY_SHORT[w - 1]).join(', ')}`;
      break;
    }
    case 'monthly': s = `${n === 1 ? 'Monthly' : `Every ${n} months`} on day ${new Date(start).getDate()}`; break;
    case 'yearly': s = `${n === 1 ? 'Yearly' : `Every ${n} years`} on ${fmtDay(start, { month: 'short', day: 'numeric' })}`; break;
  }
  const e = endOf(rec);
  if (e.type === 'onDate') s += `, until ${fmtDay(e.date, { month: 'short', day: 'numeric', year: 'numeric' })}`;
  if (e.type === 'afterCount') s += `, ${e.count} times`;
  return s;
}

export function rrule(rec, start) {
  if (rec.frequency === 'none') return null;
  const parts = [`FREQ=${rec.frequency.toUpperCase()}`];
  if ((rec.interval || 1) > 1) parts.push(`INTERVAL=${rec.interval}`);
  if (rec.frequency === 'weekly') {
    const codes = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];
    parts.push(`BYDAY=${effectiveWeekdays(rec, start).map(w => codes[w - 1]).join(',')}`);
  }
  const e = endOf(rec);
  if (e.type === 'onDate') {
    const eod = new Date(addDays(startOfDay(e.date), 1) - 1000);
    parts.push(`UNTIL=${iso(eod).replace(/[-:]/g, '')}`);
  }
  if (e.type === 'afterCount') parts.push(`COUNT=${e.count}`);
  return `RRULE:${parts.join(';')}`;
}

// ---------- occurrences ----------
export function makeOccurrence(task, day) {
  const d = startOfDay(day);
  const key = dateKey(d);
  const start = task.timeMinutes != null ? dayAt(d, task.timeMinutes) : null;
  const event = isEvent(task);
  const done = !event && Boolean(task.completions && task.completions[key]);
  // "Didn't do it": marked with the X box and a reflection on why. Settles the item like a check-off.
  const missed = !event && !done && Boolean(task.missed && task.missed[key]);
  return {
    task, day: d, key,
    id: `${task.id}|${key}`,
    start,
    end: start ? addMinutes(start, Math.max(5, task.durationMinutes || 30)) : null,
    event,
    busy: isBusy(task),
    done, missed, resolved: done || missed,
    overdue: !event && !done && !missed && d < startOfDay(new Date()),
  };
}

/**
 * Open time on `day`: your open hours minus closed items (padded by `bufferMinutes`) and time
 * already past. `blocked` is [[startMs, endMs], ...]; returns the same shape, in order.
 */
export function openRanges(day, hours, blocked, now = Date.now()) {
  if (!hours.weekdays.includes(weekday(day)) || hours.endMinutes <= hours.startMinutes) return [];
  const buf = (hours.bufferMinutes || 0) * 60_000;
  let free = [[+dayAt(day, hours.startMinutes), +dayAt(day, hours.endMinutes)]];
  const cuts = blocked.map(([s, e]) => [s - buf, e + buf]);
  cuts.push([-Infinity, Math.ceil(now / 300_000) * 300_000]);   // the past, to the next 5 minutes
  for (const [cs, ce] of cuts) {
    free = free.flatMap(([fs, fe]) => ce <= fs || cs >= fe ? [[fs, fe]] : [...(cs > fs ? [[fs, cs]] : []), ...(ce < fe ? [[ce, fe]] : [])]);
  }
  return free.filter(([fs, fe]) => fe - fs >= 5 * 60_000);
}

export function sortOccurrences(a, b) {
  const x = a.task.timeMinutes, y = b.task.timeMinutes;
  if (x != null && y != null) return x === y ? a.task.title.localeCompare(b.task.title) : x - y;
  if (x == null && y != null) return 1;
  if (x != null && y == null) return -1;
  return String(a.task.createdAt).localeCompare(String(b.task.createdAt));
}

export function newTask(fields = {}) {
  const now = iso(new Date());
  return {
    id: uuid(), title: '', notes: '', startDate: iso(startOfDay(new Date())),
    durationMinutes: 30,
    recurrence: { frequency: 'none', interval: 1, weekdays: [], end: { never: {} } },
    reminderOffsets: [0], channels: ['notification', 'banner'], color: 'blue',
    completions: {}, skipped: [], createdAt: now,
    ...fields,
  };
}

// ---------- settings (the synced subset; device-only settings live in localStorage) ----------
export const DEFAULT_SETTINGS = {
  nudgeEnabled: true, nudgeIntervalMinutes: 30, nudgeChannels: ['notification', 'banner'], nudgeOnlyWhenIncomplete: true,
  checkInOnLaunch: true, checkInOnWake: true, checkInOnUnlock: true, checkInOnlyWhenIncomplete: false,
  checkInChannels: ['checkIn', 'sound'],
  defaultChannels: ['notification', 'banner'], untimedReminderMinutes: 540, bannerAutoDismissSeconds: 0,
  minReflectionWords: 20, showGoogleEvents: true, googleEventReminderMinutes: 0,
  autoImportCalendars: true, importDaysAhead: 14,
  availability: { weekdays: [2, 3, 4, 5, 6], startMinutes: 540, endMinutes: 1020, bufferMinutes: 10 },
  hiddenCalendars: [],
  // Habits tracker: the Atomic Habits scorecard (what you already do, rated good / bad / neutral).
  habitScorecard: [],
  // Focus & screen time: apps you count as distracting (names as the Mac shows them) and daily limits (0 = off).
  distractingApps: [],
  screenLimitMinutes: 0,
  distractingLimitMinutes: 0,
  focusMinutes: 25,
  syncGoogleTasks: true,
  // Task presets: saved combinations of conditions to start new tasks from. Dates are stored relative to the
  // start day (spanDays: repeat end / long-term end, dueDays: due date). Same shape as TaskPreset on the Mac.
  taskPresets: [
    { id: 'B0B0B0B0-0000-4000-8000-000000000001', name: 'Homework', kind: 'task', title: '', notes: '', durationMinutes: 60,
      recurrence: { frequency: 'none', interval: 1, weekdays: [], end: { never: {} } }, reminderOffsets: [0], channels: ['notification', 'banner'],
      color: 'orange', busy: false, mode: 'untilDone', dueDays: 2 },
    { id: 'B0B0B0B0-0000-4000-8000-000000000002', name: 'Daily habit', kind: 'task', title: '', notes: '', durationMinutes: 30,
      recurrence: { frequency: 'daily', interval: 1, weekdays: [], end: { never: {} } }, reminderOffsets: [0], channels: ['notification', 'banner'],
      color: 'green', busy: false },
    { id: 'B0B0B0B0-0000-4000-8000-000000000003', name: 'Weekly chore (until done)', kind: 'task', title: '', notes: '', durationMinutes: 30,
      recurrence: { frequency: 'weekly', interval: 1, weekdays: [], end: { never: {} } }, reminderOffsets: [0], channels: ['notification', 'banner'],
      color: 'teal', busy: false, mode: 'untilDone' },
    { id: 'B0B0B0B0-0000-4000-8000-000000000004', name: 'Meeting', kind: 'event', title: '', notes: '', timeMinutes: 600, durationMinutes: 30,
      recurrence: { frequency: 'none', interval: 1, weekdays: [], end: { never: {} } }, reminderOffsets: [10], channels: ['notification', 'banner'],
      color: 'purple', busy: true },
  ],
};

export const CHANNELS = [
  ['notification', 'Notification', 'Browser / system notification'],
  ['banner', 'On-screen banner', 'A Cadence banner that stays until dismissed'],
  ['sound', 'Sound', 'Play a chime'],
  ['checkIn', 'Checklist window', 'Pop open the daily checklist'],
];

export const COLORS = {
  blue: '#0a84ff', teal: '#30b0c7', green: '#30d158', yellow: '#ffd60a', orange: '#ff9f0a',
  red: '#ff453a', pink: '#ff375f', purple: '#bf5af2', gray: '#8e8e93',
};

// ---------- focus sessions (time pressure) ----------
/** Points for a focus session: 10 per task finished in time, multiplied by how focused you stayed
 *  (time not spent away or in distracting apps), plus 20 for clearing everything you picked. */
export function focusMultiplier(percent) { return percent >= 90 ? 1.5 : percent >= 75 ? 1.25 : 1; }
export function focusPoints({ finished, picked, focusPercent }) {
  return Math.round(finished * 10 * focusMultiplier(focusPercent ?? 100) + (picked && finished >= picked ? 20 : 0));
}
/** Levels: 2 at 100 points, 3 at 300, 4 at 600… (each level needs 100 more than the last). */
export const levelStart = level => 50 * (level - 1) * level;
export function focusLevel(points) {
  let level = 1;
  while (levelStart(level + 1) <= points) level++;
  return { level, into: points - levelStart(level), span: levelStart(level + 1) - levelStart(level) };
}
/** Days in a row (ending today or yesterday) with at least one focus session. */
export function focusStreak(sessions) {
  const days = new Set(sessions.map(s => dateKey(s.startedAt)));
  let d = startOfDay(new Date());
  if (!days.has(dateKey(d))) d = addDays(d, -1);
  let n = 0;
  while (days.has(dateKey(d))) { n++; d = addDays(d, -1); }
  return n;
}
export const fmtDuration = sec => { const m = Math.round(sec / 60), h = Math.floor(m / 60); return h ? `${h}h ${m % 60}m` : `${m}m`; };
