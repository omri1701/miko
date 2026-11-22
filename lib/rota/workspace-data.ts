import {
  blocks,
  totals,
  allKnownBlocks,
  unapproved,
  ownerMonth,
  normalizeWeekends,
  type State,
  type Duty,
} from './engine.ts';
import {calendarDates} from './calendar-dates.ts';

// Workspace projections: scheduling rules remain in the React-free engine.
export function workspaceMetrics(state: State, month: string, duties: Duty[]) {
  const owned = duties.filter((b) => ownerMonth(b) === month),
    active = state.team.filter((p) => p.active),
    monthTotals = totals(state, owned),
    historyTotals = totals(state, allKnownBlocks(state));
  const assigned = owned.filter((b) => state.assignments[b.id]?.primary).length;
  // Who is on a date they marked unavailable, not yet approved: Publish lists each one.
  const unavailableDays = owned.flatMap((b) => {
    const a = state.assignments[b.id];
    return [a?.primary, a?.secondary].flatMap((id) => id ? unapproved(b, id, state).map((day) => ({member: id, day})) : []);
  }).sort((p, q) => p.day.localeCompare(q.day) || p.member.localeCompare(q.member));
  const conflicts = owned.filter((b) => unavailableDays.some(({day}) => b.start <= day && day < b.end));
  // Each person and day behind those conflicts, with its duty (#110 draft lines), in date order.
  const conflictDays = unavailableDays.flatMap(({member, day}) => {
    const duty = conflicts.find((b) => b.start <= day && day < b.end);
    return duty ? [{person: member, date: day, duty}] : [];
  });
  const gaps = active.flatMap((p) => {
    const mine = owned.filter(
      (b) =>
        state.assignments[b.id]?.primary === p.id,
    );
    return mine
      .filter(
        (b, i) =>
          i > 0 &&
          b.start === mine[i - 1].end &&
          (!b.weekendId || b.weekendId !== mine[i - 1].weekendId) &&
          (b.start.slice(0, 7) === month || mine[i - 1].start.slice(0, 7) === month),
      )
      .map((b) => ({ p, b }));
  });

  return { owned, active, monthTotals, historyTotals, assigned, conflicts, conflictDays, unavailableDays, gaps };
}
export type WorkspaceMetrics = ReturnType<typeof workspaceMetrics>;

export {calendarDates} from './calendar-dates.ts';

// Populate every visible date, keeping combined weekends as one period.
export function visibleCalendarBlocks(state: State, month: string) {
  const months = new Set(calendarDates(month).map(day => day.slice(0, 7)));
  const duties = new Map<string, Duty>();
  for (const m of months) for (const b of blocks(m, state.specials, state.splitWeekends)) duties.set(b.id, b);
  return [...duties.values()];
}

export function prepareWorkspaceUpdate(s: State, changed: State, month: string, monthDetails: State['months'][string], draft = true) {
  // Normalization must not merge a different month's independent split weekend.
  const n = normalizeWeekends({...changed, splitWeekends: changed.splitWeekends?.filter(f => f.startsWith(month))});
  n.splitWeekends = [...(changed.splitWeekends ?? []).filter(f => !f.startsWith(month)), ...(n.splitWeekends ?? [])];
  if (draft) {
    const before = new Map(allKnownBlocks(s).map(b => [b.id, b]));
    const after = new Map(allKnownBlocks(n).map(b => [b.id, b]));
    for (const [id, b] of new Map([...before, ...after])) {
      const changedDuty = JSON.stringify(s.assignments[id]) !== JSON.stringify(n.assignments[id]) ||
        JSON.stringify(before.get(id)) !== JSON.stringify(after.get(id));
      if (changedDuty && ownerMonth(b) !== month) throw Error('Edit duties in their owning month.');
    }
    n.months = {...n.months, [month]: {...(n.months[month] ?? monthDetails), status: 'draft'}};
  }
  return n;
}

/** Clear board: the unlocked assignments a draft month owns. A published month has none to clear. */
export function clearableAssignments(state: State, month: string): State['assignments'] {
  if (state.months[month]?.status === 'published') return {};
  return Object.fromEntries(blocks(month, state.specials, state.splitWeekends).filter(b => ownerMonth(b) === month)
    .flatMap(b => {const a = state.assignments[b.id]; return a && !a.locked && (a.primary || a.secondary) ? [[b.id, a]] : [];}));
}

/** Removes those assignments for a fresh start. Locks, specials, constraints and the plan stay. */
export function clearBoard(state: State, month: string): State {
  const cleared = clearableAssignments(state, month), assignments = {...state.assignments};
  for (const id of Object.keys(cleared)) delete assignments[id];
  const details = state.months[month];
  return {...state, assignments, months: details ? {...state.months, [month]: {...details, generated: false}} : state.months};
}

/** Undo for Clear board: puts back only what is still empty, so later edits win. */
export function restoreCleared(state: State, month: string, cleared: State['assignments'], generated?: boolean): State {
  const owned = new Set(blocks(month, state.specials, state.splitWeekends).filter(b => ownerMonth(b) === month).map(b => b.id)), assignments = {...state.assignments};
  for (const [id, a] of Object.entries(cleared)) if (owned.has(id) && !assignments[id]?.primary && !assignments[id]?.secondary) assignments[id] = a;
  const details = state.months[month];
  return {...state, assignments, months: details ? {...state.months, [month]: {...details, generated: details.generated || generated}} : state.months};
}
