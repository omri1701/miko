import type {State} from './rota/engine.ts';
import {shortDate} from './date-format.ts';
import {explainedMessage} from './messages.ts';
export {explainedMessage};

/** What explainedMessage needs from the workspace to name a conflict: names, the notes this
 * viewer's state holds (their own; all for admins) and the date format. */
export function conflictContext(remote: {memberId: string; isAdmin: boolean}, state: State, t: (en: string, he: string) => string) {
  const lang = t('en', 'he') as 'en' | 'he';
  return {me: remote.memberId, admin: remote.isAdmin, day: (d: string) => shortDate(d, lang),
    name: (id: string) => state.team.find(p => p.id === id)?.name ?? t('A team member', 'חבר צוות'),
    note: (member: string, day: string) => state.constraintNotes?.[member]?.[day]};
}
