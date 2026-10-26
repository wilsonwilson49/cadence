// Mirrors the Mac app's recurrence checks so both platforms agree.
import { occurs, countWords, rrule, newTask, parseKey, iso, startOfDay, recurrenceSummary, openRanges, isBusy, dayAt, addDays, dateKey, nextOccurrence, planSummary, cycleStatus, isHabit, habitStats, focusPoints, focusLevel, taskFromGoogleTask, stableUUID, isUntilDone, calendarKeyOf } from '../public/js/model.js';
let fail = 0;
const check = (ok, msg) => { console.log(ok ? 'PASS' : 'FAIL', msg); if (!ok) fail++; };
const d = parseKey;
const task = (start, recurrence) => newTask({ startDate: iso(startOfDay(d(start))), recurrence: { interval: 1, weekdays: [], end: { never: {} }, ...recurrence } });

let t = task('2026-09-02', { frequency: 'weekly', weekdays: [2, 4, 6] });
check(occurs(t, d('2026-09-30')), 'weekly Wed');
check(!occurs(t, d('2026-09-29')), 'weekly not Tue');
check(!occurs(t, d('2026-08-31')), 'not before start');
t.recurrence.interval = 2;
check(!occurs(t, d('2026-09-09')) && !occurs(t, d('2026-09-07')) && occurs(t, d('2026-09-14')) && occurs(t, d('2026-09-16')), 'biweekly week parity');
const u = task('2026-09-01', { frequency: 'daily', interval: 3, end: { afterCount: { _0: 4 } } });
check(occurs(u, d('2026-09-10')) && !occurs(u, d('2026-09-13')) && !occurs(u, d('2026-09-11')), 'daily/3 count 4');
const m = task('2026-01-31', { frequency: 'monthly' });
check(occurs(m, d('2026-03-31')) && !occurs(m, d('2026-02-28')), 'monthly 31st');
m.recurrence.end = { onDate: { _0: iso(d('2026-05-01')) } };
check(!occurs(m, d('2026-05-31')), 'until date');
const s = task('2026-09-01', { frequency: 'daily' }); s.skipped = ['2026-09-05'];
check(!occurs(s, d('2026-09-05')) && occurs(s, d('2026-09-06')), 'skip');
check(countWords('Hello, world -- this is 3 words? ...') === 6, 'word count');
check(rrule(t.recurrence, t.startDate) === 'RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR', 'rrule weekly');
check(rrule(u.recurrence, u.startDate) === 'RRULE:FREQ=DAILY;INTERVAL=3;COUNT=4', 'rrule count');
check(recurrenceSummary({ frequency: 'weekly', interval: 1, weekdays: [2, 3, 4, 5, 6], end: { never: {} } }, new Date()) === 'Every weekday', 'summary');
check(!iso(new Date()).includes('.'), 'ISO has no milliseconds (Swift-compatible)');
check(isBusy({ kind: 'event' }) && !isBusy({}) && isBusy({ source: 'google' }) && !isBusy({ kind: 'event', busy: false }) && isBusy({ busy: true }), 'open/closed defaults');
// Open time: Thu 2026-10-01, open 9–17, 10-minute buffer, a closed 10:00–11:00 and an all-past morning cut at 12:02.
const thu = d('2026-10-01'), hrs = { weekdays: [2, 3, 4, 5, 6], startMinutes: 540, endMinutes: 1020, bufferMinutes: 10 };
const fmtR = r => r.map(([a, b]) => `${new Date(a).getHours()}:${new Date(a).getMinutes()}-${new Date(b).getHours()}:${new Date(b).getMinutes()}`).join(',');
check(fmtR(openRanges(thu, hrs, [[+dayAt(thu, 600), +dayAt(thu, 660)]], 0)) === '9:0-9:50,11:10-17:0', 'open ranges with buffer');
check(fmtR(openRanges(thu, hrs, [], +dayAt(thu, 722))) === '12:5-17:0', 'open ranges skip the past');
check(openRanges(d('2026-10-03'), hrs, [], 0).length === 0, 'no open time on days off');
check(openRanges(thu, hrs, [[+thu, +dayAt(thu, 1440)]], 0).length === 0, 'closed all-day blocks the day');
// Until done: every day from the start until the first check-off; past days keep only what happened.
const today = startOfDay(new Date()), k = n => dateKey(addDays(today, n));
const ud = newTask({ mode: 'untilDone', startDate: iso(addDays(today, -3)) });
check(occurs(ud, today) && occurs(ud, addDays(today, 5)) && !occurs(ud, addDays(today, -1)), 'until done: today and future, not empty past days');
ud.completions = { [k(0)]: iso(new Date()) };
check(occurs(ud, today) && !occurs(ud, addDays(today, 1)) && nextOccurrence(ud, addDays(today, 1)) === null, 'until done: gone after it is checked off');
const um = newTask({ mode: 'untilDone', startDate: iso(addDays(today, -3)), missed: { [k(-1)]: iso(new Date()) } });
check(occurs(um, addDays(today, -1)) && !occurs(um, today), 'until done: "didn\'t do it" ends it too');
// Repeating + until done: weekly from 3 days ago, so the next one arrives in 4 days.
const uw = newTask({ mode: 'untilDone', startDate: iso(addDays(today, -3)), recurrence: { frequency: 'weekly', interval: 1, weekdays: [], end: { never: {} } } });
check(occurs(uw, today) && occurs(uw, addDays(today, 3)) && occurs(uw, addDays(today, 4)), 'repeating until done: carries over until the next one');
uw.completions = { [k(0)]: iso(new Date()) };
check(occurs(uw, today) && !occurs(uw, addDays(today, 1)) && !occurs(uw, addDays(today, 3)) && occurs(uw, addDays(today, 4)) && occurs(uw, addDays(today, 6)),
  'repeating until done: finished one disappears, the next repeat comes back');
const lt = newTask({ mode: 'longTerm', startDate: iso(today), recurrence: { frequency: 'daily', interval: 1, weekdays: [], end: { onDate: { _0: iso(addDays(today, 10)) } } } });
check(occurs(lt, addDays(today, 10)) && !occurs(lt, addDays(today, 11)) && planSummary(lt).includes('10 days left'), 'long-term: every day through the end date');
// After it's done, with a break: 3 rounds, 7-day break.
const cy = newTask({ mode: 'untilDone', startDate: iso(addDays(today, -10)), cycleGapDays: 7, cycleTimes: 3 });
check(occurs(cy, today) && cycleStatus(cy).round === 1, 'cycle: round 1 stays until done');
cy.completions = { [k(-8)]: iso(new Date()) };   // round 1 done 8 days ago → round 2 started yesterday
check(occurs(cy, today) && cycleStatus(cy).round === 2 && !occurs(cy, addDays(today, -3)), 'cycle: comes back after the break');
cy.completions[k(0)] = iso(new Date());          // round 2 done today → break → round 3 in 7 days
check(!occurs(cy, addDays(today, 3)) && occurs(cy, addDays(today, 7)) && cycleStatus(cy).nextStart && cycleStatus(cy).round === 3, 'cycle: hidden during the break');
cy.missed = { [k(7)]: iso(new Date()) };         // round 3 settled → finished for good
check(!occurs(cy, addDays(today, 20)) && !occurs(cy, addDays(today, 60)) && cycleStatus(cy, addDays(today, 8)).finished, 'cycle: finished after the set number of times');
// Habits: repeating things are habits; streaks, rate, never miss twice.
const hab = newTask({ startDate: iso(addDays(today, -10)), recurrence: { frequency: 'daily', interval: 1, weekdays: [], end: { never: {} } } });
check(isHabit(hab) && !isHabit(newTask({})) && isHabit(newTask({ kind: 'habit' })) && calendarKeyOf(hab) === 'habits', 'habits: repeating items are habits');
hab.completions = { [k(-1)]: 'x', [k(-2)]: 'x', [k(-4)]: 'x' };
let hs = habitStats(hab);
check(hs.streak === 2 && hs.best === 2 && hs.rate === 30 && hs.votes === 3 && !hs.missTwice && hs.today === 'open', 'habits: streak, best, rate, votes');
hab.completions = { [k(-2)]: 'x' };
check(habitStats(hab).missTwice && habitStats(hab).streak === 0, 'habits: never miss twice after a miss');
// Focus scoring and levels.
check(focusPoints({ finished: 3, picked: 3, focusPercent: 95 }) === 65 && focusPoints({ finished: 2, picked: 5, focusPercent: 60 }) === 20, 'focus: points');
check(focusLevel(0).level === 1 && focusLevel(100).level === 2 && focusLevel(299).level === 2 && focusLevel(300).level === 3, 'focus: levels');
// Google Tasks become until-done tasks with a stable ID (same on the Mac).
const gtask = await taskFromGoogleTask({ id: 'abc', listId: 'L1', title: 'Return books', notes: 'n', due: '2026-11-02' });
check(gtask.id === await stableUUID('gtasks:abc') && gtask.kind === 'task' && isUntilDone(gtask) && gtask.source === 'gtasks' && gtask.sourceCalendar === 'L1'
  && dateKey(gtask.dueDate) === '2026-11-02' && !gtask.channels.length && calendarKeyOf(gtask) === 'gtasks', 'google tasks: mapping');
console.log(fail ? `${fail} failed` : 'all passed');
process.exit(fail ? 1 : 0);
