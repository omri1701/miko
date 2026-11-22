import {useRef, useState, type ReactNode} from 'react';
import {Lock} from 'lucide-react';
import {MonthTitle} from './month-title';
import {useMonthArrival, type MonthStageHandle} from './month-stage';
import {Chip} from '@/components/ui/chip';
import {AvailabilityEditor} from '@/components/rota/availability-editor';
import {takesDuties, type State} from '@/lib/rota/engine';
import {shortDate} from '@/lib/date-format';
import {calendarOwnerMonth, monthNext} from '@/lib/rota/calendar-dates';
import type {Language, Translate} from './workspace-types';

/** The Availability tab (decision 2026-11-06): the month, who (admins), the grid. No legends. */
export function WorkspaceAvailability({state, month, monthLabel, onMonth, person, setPerson, dateCells, lang, isManager, viewer = false, meId, constraintsClosed, deadline, t, saveConstraints, schedule, lastMonth, lockDay, locked = false}: {
  state: State; month: string; monthLabel: string; onMonth: (offset: number) => void; person: string; setPerson: (id: string) => void; dateCells: string[]; lang: Language;
  isManager: boolean; /** A Viewer (#90) has no constraints; a Viewer-admin reads everyone's. */ viewer?: boolean; meId: string; constraintsClosed: boolean; deadline: string; t: Translate;
  saveConstraints: (days: string[], kind: 'no' | 'prefer' | 'clear', note: string) => Promise<boolean>;
  /** A month's Schedule calendar: the grid copies its layout (#95 rule 4). */
  schedule?: (month: string) => ReactNode;
  /** The last month constraints open for (#111): the buttons and swipes stop there. */
  lastMonth?: string | null;
  /** Why a day can't be edited (#111), as a toast on tap; `locked`: the whole month is (past, or not open yet). */
  lockDay?: (day: string) => string | null; locked?: boolean;
}) {
  const active = state.team.filter(takesDuties);
  // An admin who is a Viewer has no constraints of their own: show a teammate's instead.
  const who = isManager && !active.some(p => p.id === person) && active.length ? active[0].id : person;
  const mine = state.constraints[who] ?? {};
  // Only the shown month's own days count (#95 rule 5).
  const counts = Object.entries(mine).filter(([day]) => calendarOwnerMonth(day) === month).map(([, kind]) => kind).reduce((n, kind) => ({...n, [kind]: (n[kind] ?? 0) + 1}), {} as Record<string, number>);
  // A name swipe refreshes the grid in place, blurred to sharp (owner round 4).
  const {ref: arrivalRef, mark: markArrival} = useMonthArrival<HTMLDivElement>(month);
  // The chevrons play the grid's slide; a grid swipe changes the month itself (#94).
  const stage = useRef<MonthStageHandle>(null), [nameArrival, setNameArrival] = useState<'roll' | 'blur'>('roll');
  const canGo = (n: number) => n < 0 || !lastMonth || monthNext(month, n) <= lastMonth;
  const navigate = (n: number) => {if (!canGo(n)) return; if (stage.current) stage.current.go(n); else onMonth(n);};
  return <section className="availability-screen">
    <div className="month-bar">
      <MonthTitle month={month} label={monthLabel} t={t} onChange={navigate} canGo={canGo} arrival={nameArrival} onSwipe={n => {markArrival(); onMonth(n);}}
        status={constraintsClosed || locked ? <Chip tone="neutral" size="sm" className="month-status"><Lock/>{t('Closed', 'סגור')}</Chip> : <Chip tone="brand" size="sm" className="month-status">{t(`Due ${shortDate(deadline, lang)}`, `עד ${shortDate(deadline, lang)}`)}</Chip>}/>
      {isManager && <div className="month-actions">
        <select className="picker" aria-label={t('Engineer', 'מהנדס')} value={who} onChange={e => setPerson(e.target.value)}>
          {active.map(p => <option value={p.id} key={p.id}>{p.name}{p.id === meId ? t(' (you)', ' (אני)') : ''}</option>)}
        </select>
      </div>}
    </div>
    {viewer && !isManager ? <p className="muted-copy" role="note">{t('Viewers don’t add constraints.', 'צופים לא מוסיפים אילוצים.')}</p>
      : <div ref={arrivalRef}><AvailabilityEditor state={state} month={month} person={who} cells={dateCells} lang={lang} disabled={constraintsClosed} lockDay={lockDay} onSave={saveConstraints} schedule={schedule} footer={<div className="availability-summary" aria-live="polite">
      <Chip tone="danger" size="sm"><i className="dot"/>{t(`${counts.no ?? 0} unavailable`, `${counts.no ?? 0} לא זמין`)}</Chip>
      <Chip tone="ok" size="sm"><i className="dot"/>{t(`${counts.prefer ?? 0} preferred`, `${counts.prefer ?? 0} מועדף`)}</Chip>
    </div>} stage={stage} canGo={canGo} onMonth={(n, swiped) => {setNameArrival(swiped ? 'blur' : 'roll'); onMonth(n);}}/></div>}
  </section>;
}
