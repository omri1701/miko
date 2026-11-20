import {Lock} from 'lucide-react';
import {MonthTitle} from './month-title';
import {useMonthArrival} from './month-stage';
import {Select, SelectTrigger, SelectValue, SelectContent, SelectItem} from '@/components/ui/select';
import {Chip} from '@/components/ui/chip';
import {AvailabilityEditor} from '@/components/rota/availability-editor';
import {takesDuties, type State} from '@/lib/rota/engine';
import {shortDate} from '@/lib/date-format';
import type {Language, Translate} from './workspace-types';

/** The Availability tab (decision 2026-11-06): the month, who (admins), the grid. No legends. */
export function WorkspaceAvailability({state, month, monthLabel, onMonth, person, setPerson, dateCells, lang, isManager, viewer = false, meId, constraintsClosed, deadline, t, saveConstraints}: {
  state: State; month: string; monthLabel: string; onMonth: (offset: number) => void; person: string; setPerson: (id: string) => void; dateCells: string[]; lang: Language;
  isManager: boolean; /** A Viewer (#90) has no constraints; a Viewer-admin reads everyone's. */ viewer?: boolean; meId: string; constraintsClosed: boolean; deadline: string; t: Translate;
  saveConstraints: (days: string[], kind: 'no' | 'prefer' | 'clear', note: string) => Promise<boolean>;
}) {
  const active = state.team.filter(takesDuties);
  // An admin who is a Viewer has no constraints of their own: show a teammate's instead.
  const who = isManager && !active.some(p => p.id === person) && active.length ? active[0].id : person;
  const mine = state.constraints[who] ?? {};
  const counts = Object.values(mine).reduce((n, kind) => ({...n, [kind]: (n[kind] ?? 0) + 1}), {} as Record<string, number>);
  // A name swipe refreshes the grid in place, blurred to sharp (owner round 4).
  const {ref: arrivalRef, mark: markArrival} = useMonthArrival<HTMLDivElement>(month);
  return <section className="availability-screen">
    <div className="month-bar">
      <MonthTitle month={month} label={monthLabel} t={t} onChange={onMonth} onSwipe={n => {markArrival(); onMonth(n);}}
        status={constraintsClosed ? <Chip tone="neutral" size="sm" className="month-status"><Lock/>{t('Closed', 'סגור')}</Chip> : <Chip tone="brand" size="sm" className="month-status">{t(`Due ${shortDate(deadline, lang)}`, `עד ${shortDate(deadline, lang)}`)}</Chip>}/>
      {isManager && <div className="month-actions">
        <Select value={who} onValueChange={setPerson}>
          <SelectTrigger aria-label={t('Engineer', 'מהנדס')} className="picker"><SelectValue/></SelectTrigger>
          <SelectContent>{active.map(p => <SelectItem value={p.id} key={p.id}>{p.name}{p.id === meId ? t(' (you)', ' (אני)') : ''}</SelectItem>)}</SelectContent>
        </Select>
      </div>}
    </div>
    {!(viewer && !isManager) && <div className="availability-summary" aria-live="polite">
      <Chip tone="danger" size="sm"><i className="dot"/>{t(`${counts.no ?? 0} unavailable`, `${counts.no ?? 0} לא זמין`)}</Chip>
      <Chip tone="ok" size="sm"><i className="dot"/>{t(`${counts.prefer ?? 0} preferred`, `${counts.prefer ?? 0} מועדף`)}</Chip>
    </div>}
    {viewer && !isManager ? <p className="muted-copy" role="note">{t('Viewers see the schedule and don’t add constraints.', 'צופים רואים את הלוח ולא מוסיפים אילוצים.')}</p>
      : <div ref={arrivalRef}><AvailabilityEditor state={state} month={month} person={who} cells={dateCells} lang={lang} disabled={constraintsClosed} onSave={saveConstraints}/></div>}
  </section>;
}
