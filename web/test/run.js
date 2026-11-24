// Mirrors the Mac app's recurrence checks so both platforms agree.
import { occurs, countWords, rrule, newTask, parseKey, iso, startOfDay, recurrenceSummary, openRanges, isBusy, dayAt, addDays, dateKey, nextOccurrence, planSummary, cycleStatus, isHabit, habitStats, focusPoints, focusLevel, taskFromGoogleTask, stableUUID, isUntilDone, calendarKeyOf, heldOver, focusLengths, clampFocus, fmtFocusLength, newProject, newProjectItem, projectRows, projectProgress, updateItem, setItemDone, indentItem, outdentItem, insertItem, findItem, itemDone, projectDeadlines, deadlineStatus, projectMapLayout, projectTodayItems, toggleStep, stepsDoneFor, makeOccurrence, countsToday, untilDoneDeadline, deleteOccurrence, newRun, timedState, reviewCard, newCard, runLog, nextPeriod, repeatCycle, periodMsLeft, newCourse, courseRules, togglePause, runElapsed } from '../public/js/model.js';
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
// Handoff at the new one's time: a weekly 4:30 PM one stays until 4:30 PM on the day the next one starts.
const hw = newTask({ mode: 'untilDone', timeMinutes: 990, startDate: iso(addDays(today, -7)), recurrence: { frequency: 'weekly', interval: 1, weekdays: [], end: { never: {} } } });
const at2 = dayAt(today, 840), at5 = dayAt(today, 1020);
const st = (now, n) => habitStats(hw, now).grid.find(g => dateKey(g.day) === k(n)).state;
check(heldOver(hw, today, at2)?.key === k(-1) && !heldOver(hw, today, at5), 'handoff: last week\'s stays until 4:30 PM, then the new one');
check(st(at2, -7) === 'open' && st(at5, -7) === 'lapsed', 'handoff: open until the new one\'s time, lapsed after');
hw.completions = { [k(-1)]: iso(at2) };            // checked off at 2 PM on handoff day → counts for last week's
check(heldOver(hw, today, at2) && st(at2, -7) === 'done' && st(at2, 0) === 'open' && st(at5, -7) === 'done' && habitStats(hw, at2).streak === 1,
  'handoff: a check-off before the new one\'s time counts for the old one');
check(!heldOver({ ...hw, timeMinutes: null, completions: {} }, today, at2), 'handoff: no time means it switches at midnight');
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
// Custom focus lengths: cleaned up, capped at 8 hours, labelled like the Mac.
check(focusLengths([90, 25, 25, 0, 999]).join() === '25,90,480' && focusLengths(undefined).join() === '10,15,25,45,60' && clampFocus('75') === 75, 'focus: custom lengths');
check(fmtFocusLength(45) === '45 min' && fmtFocusLength(90) === '1h 30m' && fmtFocusLength(120) === '2h', 'focus: length labels');
// Projects: nested subtasks, rolled-up progress, inherited deadlines, conflicts, deadlines list, map layout.
{
  const leaf = (title, o) => newProjectItem({ title, ...o });
  const pr = newProject({ title: 'Essay', start: '2026-11-01', due: '2026-11-20', items: [
    leaf('Research', { due: '2026-11-05', items: [leaf('Read sources', { due: '2026-11-03' }), leaf('Take notes')] }),
    leaf('Draft', { due: '2026-11-25' }),
    leaf('Edit'),
  ] });
  const rows = projectRows(pr);
  check(rows.map(r => `${r.depth}${r.item.title[0]}`).join() === '0R,1R,1T,0D,0E', 'projects: rows in order with depth');
  check(rows[2].due === '2026-11-05' && rows[4].due === '2026-11-20' && rows[1].start === '2026-11-01', 'projects: dates passed down');
  check(rows[3].conflict && !rows[1].conflict, 'projects: deadline later than the parent is flagged');
  check(projectProgress(pr).done === 0 && projectProgress(pr).total === 4, 'projects: progress counts leaves');
  const research = pr.items[0];
  updateItem(pr, research.items[0].id, i => setItemDone(i, true));
  check(!itemDone(research) && projectProgress(pr).done === 1, 'projects: one leaf done');
  updateItem(pr, research.items[1].id, i => setItemDone(i, true));
  check(itemDone(research) && research.doneAt, 'projects: parent done when all children are');
  updateItem(pr, research.items[1].id, i => setItemDone(i, false));
  check(!itemDone(research) && !research.doneAt, 'projects: parent reopens');
  indentItem(pr, pr.items[2].id);   // Edit goes under Draft
  check(pr.items.length === 2 && pr.items[1].items[0].title === 'Edit', 'projects: indent');
  outdentItem(pr, pr.items[1].items[0].id);
  check(pr.items.length === 3 && pr.items[2].title === 'Edit', 'projects: outdent');
  insertItem(pr, leaf('Outline'), research.id);
  check(findItem(pr, research.items[2].id).parent.id === research.id, 'projects: insert under a parent');
  updateItem(pr, research.items[0].id, i => setItemDone(i, false));
  const dl = projectDeadlines(pr, 7, d('2026-11-01'));
  check(dl.map(x => x.title).join() === 'Research,Read sources' && dl[1].path.join() === 'Research', 'projects: deadlines within a week, with path');
  check(deadlineStatus('2026-10-31', false, '2026-11-01') === 'overdue' && deadlineStatus('2026-11-03', false, '2026-11-01') === 'soon'
    && deadlineStatus('2026-11-09', false, '2026-11-01') === 'later' && deadlineStatus('2026-10-31', true, '2026-11-01') === 'done', 'projects: deadline status');
  // Today's list: due today (and overdue) or urgent count; due later shows apart; done today stays on.
  const tp = newProject({ title: 'T', due: '2026-11-30', items: [leaf('Due today', { due: '2026-11-01' }), leaf('Late', { due: '2026-10-30' }),
    leaf('Tomorrow', { due: '2026-11-02' }), leaf('Urgent', { urgent: true }), leaf('Next month', { due: '2026-12-01' }),
    leaf('Done earlier', { due: '2026-11-01', doneAt: iso(d('2026-10-29')) }), leaf('Done today', { due: '2026-11-01', doneAt: iso(new Date(2026, 10, 1, 9)) })] });
  const ti = projectTodayItems(tp, 0, new Date(2026, 10, 1, 12));
  check(ti.today.map(x => x.title).join() === 'Due today,Late,Urgent,Done today' && ti.upcoming.map(x => x.title).join() === 'Tomorrow', 'projects: today list (due today, overdue, urgent)');
  check(projectTodayItems(tp, 1, new Date(2026, 10, 1, 12)).today.some(x => x.title === 'Tomorrow')
    && projectTodayItems(tp, -1, new Date(2026, 10, 1, 12)).today.map(x => x.title).join() === 'Urgent', 'projects: today window setting');
  const lay = projectMapLayout(pr);
  const root = lay.nodes.find(n => n.id === 'root'), res = lay.nodes.find(n => n.id === research.id);
  check(lay.rows === 5 && lay.depth === 2 && res.y === 1 && root.y === 2.5 && lay.edges.length === 6, 'projects: map layout');
}
// Habit steps: ticked per occurrence, fresh each time, all shown done once the habit is checked off.
{
  let h = task('2026-10-01', { frequency: 'daily' });
  h.steps = [{ id: 'A', title: 'Stretch' }, { id: 'B', title: 'Journal' }];
  const o1 = makeOccurrence(h, d('2026-11-02'));
  h = toggleStep(h, 'B', o1.key, d('2026-11-02'));
  check(stepsDoneFor(h, makeOccurrence(h, d('2026-11-02'))).size === 1 && stepsDoneFor(h, makeOccurrence(h, d('2026-11-03'))).size === 0, 'habit steps: per occurrence');
  h = toggleStep(h, 'B', o1.key, d('2026-11-02'));
  check(!h.stepsDone, 'habit steps: untick clears');
  h = toggleStep(h, 'A', '2026-08-01', d('2026-11-02'));
  check(!h.stepsDone, 'habit steps: old days dropped');
  h.completions = { '2026-11-02': iso(new Date()) };
  check(stepsDoneFor(h, makeOccurrence(h, d('2026-11-02'))).size === 2, 'habit steps: all done once checked off');
}
// Until-done items not due yet stay out of today's ring ("Due later") unless urgent or due within the window.
{
  const now = new Date(); now.setHours(20, 0, 0, 0);   // tonight, 8 PM
  const dueDay = addDays(startOfDay(now), 3);
  const hw = task(dateKey(addDays(dueDay, -7)), { frequency: 'weekly', weekdays: [dueDay.getDay() + 1] });   // weekly, 3 days from now, at noon
  hw.mode = 'untilDone'; hw.timeMinutes = 720;
  const o = makeOccurrence(hw, now);
  const due = untilDoneDeadline(hw, now, now);
  check(due && dateKey(due) === dateKey(dueDay) && due.getHours() === 12, 'due later: weekly deadline is the next handoff');
  check(!countsToday(o, 0, now) && countsToday(o, 3, now), 'due later: not counted today, counted within 3 days');
  hw.urgent = true;
  check(countsToday(makeOccurrence(hw, now), 0, now), 'due later: urgent counts today');
  const one = newTask({ startDate: iso(addDays(startOfDay(now), -1)), mode: 'untilDone', dueDate: iso(startOfDay(now)) });
  check(countsToday(makeOccurrence(one, now), 0, now), 'due later: due today counts');
  check(countsToday(makeOccurrence(task('2026-10-01', { frequency: 'daily' }), now), 0, now), 'due later: regular items always count');
}
// Deleting a repeat: only this one, this and later ones, or all.
{
  const daily = task('2026-11-01', { frequency: 'daily' });
  const one = deleteOccurrence(daily, d('2026-12-03'), 'one');
  check(!occurs(one, d('2026-12-03')) && occurs(one, d('2026-12-04')) && occurs(one, d('2026-12-02')), 'delete repeat: only this one');
  const later = deleteOccurrence(daily, d('2026-12-03'), 'fromHere');
  check(!occurs(later, d('2026-12-03')) && !occurs(later, d('2026-12-20')) && occurs(later, d('2026-12-02')), 'delete repeat: this and later');
  check(deleteOccurrence(daily, d('2026-12-03'), 'all') === null && deleteOccurrence(daily, d('2026-11-01'), 'fromHere') === null, 'delete repeat: all (or from its first day)');
  // Until done, weekly on Thursdays: deleting a future round hides that round without bringing back the one before.
  const hw = task('2026-12-03', { frequency: 'weekly', weekdays: [5] }); hw.mode = 'untilDone';
  const gone = deleteOccurrence(hw, d('2026-12-10'), 'one');
  check(!occurs(gone, d('2026-12-11')) && !occurs(gone, d('2026-12-10')) && occurs(gone, d('2026-12-17')), 'delete repeat: until-done round');
}
// Study: timed rounds, class periods, pauses, logs, flashcard spacing.
{
  const t0 = 1_000_000_000_000, min = 60_000;
  const r = newRun('timed', null, 'Math'); r.startedAt = t0; r.studyMinutes = 25; r.breakMinutes = 5; r.rounds = 3;
  const at = m => timedState(r, t0 + m * min);
  check(at(10).round === 1 && !at(10).onBreak && at(26).onBreak && at(31).round === 2 && !at(31).onBreak && at(85).finished, 'study: timed rounds and breaks');
  check(runLog(r, t0 + 31 * min).completed === 1 && runLog(r, t0 + 85 * min).completed === 3, 'study: rounds finished in the log');
  const p = newRun('timed', null, 'x'); p.startedAt = t0; togglePause(p, t0 + 10 * min); togglePause(p, t0 + 20 * min);
  check(runElapsed(p, t0 + 30 * min) === 20 * min, 'study: pauses left out');
  const c = newCourse({ title: 'Chem', phase: 'learning' });
  const d = newRun('dynamic', c, 'Chem'); d.startedAt = t0;
  check(d.periods.length === 5 && periodMsLeft(d, t0 + 10 * min) === 20 * min, 'study: class period clock');
  nextPeriod(d, t0 + 30 * min);
  check(d.index === 1 && periodMsLeft(d, t0 + 35 * min) === 5 * min, 'study: next period starts its own clock');
  for (let i = 0; i < 4; i++) nextPeriod(d, t0 + 60 * min);
  check(d.wrapUp && runLog(d, t0 + 60 * min).completed === 5, 'study: wrap up after the quiz');
  repeatCycle(d, 'understanding', t0 + 61 * min);
  check(d.cycle === 2 && d.index === 0 && d.phase === 'understanding' && !d.wrapUp, 'study: repeat and move on a phase');
  check(courseRules(c, 'testing').homework === 'textbook' && courseRules(c, 'learning').quiz === 'closed', 'study: phase note rules');
  let k = newCard('q', 'a'); const today = new Date(2026, 10, 8);
  k = reviewCard(k, 'good', today); const k1 = k.intervalDays; k = reviewCard(k, 'good', today); const k2 = k.intervalDays; k = reviewCard(k, 'good', today);
  check(k1 === 1 && k2 === 3 && k.intervalDays === 8 && k.due === '2026-11-16', 'flashcards: good spaces out 1, 3, 8 days');
  check(reviewCard(k, 'again', today).intervalDays === 0 && reviewCard(k, 'again', today).due === '2026-11-08', 'flashcards: again comes back today');
}
// Google Tasks become until-done tasks with a stable ID (same on the Mac).
const gtask = await taskFromGoogleTask({ id: 'abc', listId: 'L1', title: 'Return books', notes: 'n', due: '2026-11-02' });
check(gtask.id === await stableUUID('gtasks:abc') && gtask.kind === 'task' && isUntilDone(gtask) && gtask.source === 'gtasks' && gtask.sourceCalendar === 'L1'
  && dateKey(gtask.dueDate) === '2026-11-02' && !gtask.channels.length && calendarKeyOf(gtask) === 'gtasks', 'google tasks: mapping');
// Things you'd rather put off: levels, interval, and when they start keeping after you.
{
  const M2 = await import('../public/js/model.js');
  const now = new Date(2026, 10, 21, 15, 0);
  const base = { id: 'n1', title: 'Essay', startDate: new Date(2026, 10, 21).toISOString(), recurrence: { frequency: 'none', interval: 1, weekdays: [] }, reminderOffsets: [0], channels: [] };
  check(M2.nagLevel({ nag: 'strict' }) === 'strict' && M2.nagLevel({ nag: 'bogus' }) === 'normal' && M2.nagLevel({}) === 'normal', 'nag: levels');
  check(M2.nagMinutes({}) === 10 && M2.nagMinutes({ nagEvery: 3 }) === 3, 'nag: interval defaults to 10 min');
  const timed = { task: { ...base, timeMinutes: 14 * 60 }, day: new Date(2026, 10, 21) };
  check(+M2.nagStart(timed, 540, now) === +new Date(2026, 10, 21, 14, 0), 'nag: starts at the task time');
  const untimed = { task: base, day: new Date(2026, 10, 21) };
  check(+M2.nagStart(untimed, 540, now) === +new Date(2026, 10, 21, 9, 0), 'nag: untimed starts at the reminder time');
  const overdue = { task: base, day: new Date(2026, 10, 18) };
  check(+M2.nagStart(overdue, 540, now) === +new Date(2026, 10, 18), 'nag: overdue already started');
  const until = { task: { ...base, mode: 'untilDone', timeMinutes: 600 }, day: new Date(2026, 10, 18) };
  check(+M2.nagStart(until, 540, now) === +new Date(2026, 10, 21, 10, 0), 'nag: until-done starts at its time each day');
}
// Priority, hardness and time taken.
{
  const M2 = await import('../public/js/model.js');
  const parse = ['45', '45m', '1:30', '1h 30m', '1.5h', '90 min', '2 hours', '', 'soon', '0', '1:75'].map(M2.parseMinutes);
  check(JSON.stringify(parse) === JSON.stringify([45, 45, 90, 90, 90, 90, 120, null, null, null, null]), 'time taken: parsing lengths');
  check(M2.percentile([10], 0.6) === 10 && M2.percentile([10, 20], 0.6) === 20 && M2.percentile([10, 20, 30, 40, 50], 0.6) === 30 && M2.percentile([], 0.6) === null, 'time taken: 60% mark');
  check(M2.typicalMinutes({ timeTaken: { a: 50, b: 20, c: 30, d: 0, e: 40, f: 200 } }) === 40, 'time taken: typical ignores zeros, resists one long day');
  check(M2.fmtMinutes(45) === '45 min' && M2.fmtMinutes(90) === '1 hr 30 min' && M2.fmtMinutes(120) === '2 hr', 'time taken: formatting');
  check(M2.priorityOf({ priority: 'high' }) === 'high' && M2.priorityOf({ priority: 'urgent' }) === null && M2.hardnessOf({ hardness: 9 }) === 5 && M2.hardnessOf({}) === null, 'priority and hardness: values');
  const occ = (title, priority, timeMinutes, createdAt) => ({ task: { title, priority, timeMinutes, createdAt } });
  const order = [occ('none', undefined, null, '1'), occ('low', 'low', null, '2'), occ('high', 'high', null, '3'), occ('timed', undefined, 600, '4'), occ('timed high', 'high', 600, '5')]
    .sort(M2.sortOccurrences).map(o => o.task.title);
  check(order.join(',') === 'timed high,timed,high,low,none', 'priority: sorts any-time items and ties');
}
// Focus time on the calendar.
{
  const M2 = await import('../public/js/model.js');
  const day = new Date(2026, 10, 22), at = (h, m = 0) => new Date(2026, 10, 22, h, m).toISOString();
  const sessions = [
    { id: 'w', startedAt: at(7), endedAt: at(7, 50), mode: 'work', title: 'Lab report', finished: 1, picked: 1 },
    { id: 'f', startedAt: at(10, 30), endedAt: at(10, 55), finished: 2, picked: 3 },
    { id: 's1', startedAt: at(13), endedAt: at(14, 10), finished: 1, picked: 1, finishedTitles: ['Study: Chemistry'] },
    { id: 'late', startedAt: new Date(2026, 10, 22, 23, 30).toISOString(), endedAt: new Date(2026, 10, 23, 0, 30).toISOString(), finished: 0, picked: 1 },
  ];
  const logs = [{ id: 's1', title: 'Chemistry', startedAt: at(13), endedAt: at(14, 10) }];
  const b = M2.focusBlocks(sessions, logs, day);
  check(b.map(x => x.kind).join(',') === 'work,focus,study,focus' && b[0].title === 'Lab report', 'focus time: kinds, study counted once');
  check(M2.blockMinutes(b[3]) === 30 && M2.blockMinutes(b[2]) === 70, 'focus time: clipped to the day');
}
// Follow-up (trigger) tasks.
{
  const M2 = await import('../public/js/model.js');
  const rec = { frequency: 'none', interval: 1, weekdays: [], end: { never: {} } };
  const x = { id: 'x', title: 'Gym', startDate: new Date(2026, 10, 22).toISOString(), recurrence: { ...rec, frequency: 'daily' }, completions: {} };
  const y = { id: 'y', title: 'Shake', startDate: new Date(2026, 10, 1).toISOString(), recurrence: rec, after: 'x', afterMinutes: 30, completions: {} };
  check(!M2.occurs(y, new Date(2026, 10, 22)) && M2.isWaiting(y), 'follow-up: waits off every list');
  const armed = M2.armFollowUp(y, 'x', '2026-11-22', new Date(2026, 10, 22, 9, 10, 20));
  check(M2.occurs(armed, new Date(2026, 10, 22)) && armed.timeMinutes === 9 * 60 + 41 && armed.armedBy === 'x|2026-11-22', 'follow-up: comes up 30 min after, on the next minute');
  const z = { id: 'z', title: 'Stretch', after: 'y', completions: {} };
  check(M2.possibleTriggers([x, y, z], 'x').map(t => t.id).join() === '', 'follow-up: no loops (x can\'t follow what follows it)');
  check(M2.possibleTriggers([x, y, z], 'z').map(t => t.id).join() === 'x,y', 'follow-up: can follow anything else');
}
// Bonus tasks: optional, never on a day's list, checked off up to a limit (several times a day), extra focus points.
{
  const M2 = await import('../public/js/model.js');
  const rec = { frequency: 'none', interval: 1, weekdays: [], end: { never: {} } };
  const day = new Date(2026, 10, 23), later = new Date(2026, 10, 30);
  const once = { id: 'b1', kind: 'bonus', title: 'Clean desk', startDate: new Date(2026, 10, 20).toISOString(), recurrence: rec, completions: {} };
  check(!M2.occurs(once, day) && M2.bonusListed(once, day) && !M2.makeOccurrence(once, new Date(2026, 10, 21)).overdue, 'bonus: not on day lists, listed, never overdue');
  check(!M2.bonusListed(once, new Date(2026, 10, 19)), 'bonus: not before its start date');
  const onceDone = { ...once, completions: { '2026-11-23': 'x' } };
  check(M2.bonusUsedUp(onceDone) && M2.bonusListed(onceDone, day) && M2.makeOccurrence(onceDone, day).done && !M2.bonusListed(onceDone, later), 'bonus: once, shown ticked that day, then gone');
  const three = { ...once, id: 'b3', bonusLimit: 3, completions: { '2026-11-23': 'x', '2026-11-23#2': 'x' } };
  check(M2.nextBonusKey(three, day) === '2026-11-23#3' && M2.bonusKeysOn(three, day).join() === '2026-11-23,2026-11-23#2', 'bonus: second and third the same day get their own keys');
  check(M2.bonusLeft(three) === 1 && M2.bonusSummary(three) === '2 of 3 done' && !M2.makeOccurrence(three, day).done, 'bonus: counts toward its limit');
  const many = { ...once, id: 'bn', bonusLimit: 0, startDate: new Date(2026, 10, 1).toISOString(), completions: Object.fromEntries([...Array(12)].map((_, i) => [`2026-11-${10 + i}`, 'x'])) };
  check(M2.bonusLeft(many) == null && M2.bonusListed(many, later) && M2.bonusSummary(many) === 'Done 12 times · no limit', 'bonus: no limit');
  check(M2.parseKey('2026-11-23#2').getDate() === 23 && M2.makeOccurrence(three, day, '2026-11-23#2').done, 'bonus: keys with #n read as their day');
  const habit = { id: 'h', kind: 'habit', title: 'Read', startDate: day.toISOString(), recurrence: { ...rec, frequency: 'daily' }, completions: { '2026-11-22': 'x' } };
  check(!M2.bonusUsedUp(habit), 'bonus: "used up" never applies to other tasks');
  check(M2.focusPoints({ finished: 2, picked: 2, focusPercent: 95, bonus: 2 }) === 95 && M2.focusPoints({ finished: 0, picked: 0, focusPercent: 50, bonus: 1 }) === 15,
    'bonus: 15 points each, multiplied, not part of clearing the list');
}
// Repeating bonus tasks: a fresh round each time it comes around (schedule), or after a break (cycle).
{
  const M2 = await import('../public/js/model.js');
  const rec = { frequency: 'none', interval: 1, weekdays: [], end: { never: {} } }, D = (m, d) => new Date(2026, m, d);
  const daily = { id: 'd', kind: 'bonus', title: 'Push-ups', startDate: D(10, 20).toISOString(), recurrence: { ...rec, frequency: 'daily' }, bonusLimit: 2,
    completions: { '2026-11-23': 'x', '2026-11-23#2': 'x', '2026-11-22': 'x' } };
  check(!M2.isHabit(daily) && !M2.occurs(daily, D(10, 23)), 'bonus repeat: not a habit, not on day lists');
  check(M2.bonusUsedUp(daily, D(10, 23)) && M2.bonusListed(daily, D(10, 23)) && M2.makeOccurrence(daily, D(10, 23)).done, 'bonus repeat: used up today, shown ticked');
  check(M2.bonusLeft(daily, D(10, 22)) === 1 && M2.bonusLeft(daily, D(10, 24)) === 2 && M2.bonusListed(daily, D(10, 24)), 'bonus repeat: each day starts fresh, nothing carries over');
  check(M2.bonusNextRound(daily, D(10, 23)).getDate() === 24 && M2.bonusRepeatSummary(daily) === 'Every day, each time', 'bonus repeat: next round, summary');
  const weekly = { ...daily, id: 'w', bonusLimit: undefined, recurrence: { ...rec, frequency: 'weekly', weekdays: [2] }, completions: { '2026-11-25': 'x' } };   // Mondays
  const r = M2.bonusRound(weekly, D(10, 25));
  check(M2.dateKey(r.start) === '2026-11-23' && M2.dateKey(r.end) === '2026-11-30' && M2.bonusUsedUp(weekly, D(10, 27)) && !M2.bonusListed(weekly, D(10, 27)) && M2.bonusListed(weekly, D(10, 30)),
    'bonus repeat: weekly round lasts until the next Monday');
  const ending = { ...daily, id: 'e', completions: {}, recurrence: { ...rec, frequency: 'daily', end: { onDate: { _0: D(10, 25).toISOString() } } } };
  check(M2.bonusListed(ending, D(10, 25)) && !M2.bonusListed(ending, D(10, 26)) && M2.bonusFinished(ending, D(10, 26)), 'bonus repeat: stops after its end date');
  const cyc = { id: 'c', kind: 'bonus', title: 'Deep clean', startDate: D(10, 1).toISOString(), recurrence: rec, bonusLimit: 2, cycleGapDays: 7, cycleTimes: 3,
    completions: { '2026-11-03': 'x', '2026-11-05': 'x' } };
  check(M2.bonusListed(cyc, D(10, 5)) && !M2.bonusListed(cyc, D(10, 8)) && M2.bonusListed(cyc, D(10, 12)) && M2.bonusLeft(cyc, D(10, 12)) === 2,
    'bonus cycle: used up, 7-day break, then a fresh round');
  check(M2.bonusRepeatSummary(cyc) === 'Back 1 week after it’s done · round 2 of 3' && !M2.bonusFinished(cyc, D(10, 8)), 'bonus cycle: summary');
  const all = { ...cyc, cycleTimes: 1 };
  check(M2.bonusFinished(all, D(10, 9)) && !M2.bonusListed(all, D(10, 20)), 'bonus cycle: done for good after its last round');
}
console.log(fail ? `${fail} failed` : 'all passed');
process.exit(fail ? 1 : 0);
