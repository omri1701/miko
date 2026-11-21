import type {State} from './rota/engine.ts';
import {shortDate} from './date-format.ts';
import {explainedMessage} from './messages.ts';
import {constraintLine, visibleNote} from './supabase/swaps.ts';
export {explainedMessage};

/** What explainedMessage needs from the workspace to name a conflict: names, the notes this
 * viewer's state holds (their own; all for admins) and the date format. */
export function conflictContext(remote: {memberId: string; isAdmin: boolean}, state: State, t: (en: string, he: string) => string) {
  const lang = t('en', 'he') as 'en' | 'he';
  return {me: remote.memberId, admin: remote.isAdmin, lang, day: (d: string) => shortDate(d, lang),
    name: (id: string) => state.team.find(p => p.id === id)?.name ?? t('A team member', 'חבר צוות'),
    note: (member: string, day: string) => state.constraintNotes?.[member]?.[day]};
}

/** One conflict as its human line: "Avi marked 9 Dec as unavailable · note" (note for its owner and admins). */
export function conflictLine(c: {member: string; day: string}, context: ReturnType<typeof conflictContext>) {
  return constraintLine({member: c.member, day: c.day, note: visibleNote(context.note(c.member, c.day), c.member, context)}, {me: context.me, name: context.name, day: context.day, lang: context.lang});
}
