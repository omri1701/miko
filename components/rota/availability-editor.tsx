'use client';
import {useLayoutEffect,useRef,useState,type CSSProperties,type ReactNode,type Ref} from 'react';
import {Trash2} from 'lucide-react';
import {toast} from 'sonner';
import {EditorDialog} from '@/components/rota/editor-dialog';
import {Avatar} from '@/components/ui/avatar';
import {useMobileLayout} from '@/hooks/use-mobile-layout';
import {tactileTick,tactileVisual} from '@/lib/tactile';
import {dateRange,shortDate,weekdayDate} from '@/lib/date-format';
import {Button} from '@/components/ui/button';
import {useHoldDrag} from '@/hooks/use-hold-drag';
import {dates,addDays,dayOf,takesDuties,type State} from '@/lib/rota/engine';
import {calendarDates,calendarOwnerMonth} from '@/lib/rota/calendar-dates';
import {MonthStage,type MonthStageHandle} from '@/components/rota/month-stage';
import {CalendarSurface} from '@/components/rota/calendar-presentation';
type EditKind='no'|'prefer'|'clear';
type Kind='no'|'prefer';
/** The admins' "Everyone" choice in the picker (#105 rule 6). */
export const EVERYONE='*';

/** "Wed 9 Dec" / "יום ד׳, 9 בדצמ׳", the same in every browser engine. */
export const dayTitle=weekdayDate;
const firstName=(name:string)=>name.trim().split(/\s+/)[0]??name;

/** Who has a constraint on each day, unavailable first (#105 rule 6). Admins only: members never
 * receive anyone else's notes, and the picker offers Everyone to admins only. */
function everyoneOn(state:State,day:string){
 const people=state.team.filter(takesDuties).flatMap(p=>{const kind=state.constraints[p.id]?.[day];return kind?[{person:p,kind,note:state.constraintNotes?.[p.id]?.[day]?.trim()??''}]:[]});
 return [...people.filter(x=>x.kind==='no'),...people.filter(x=>x.kind==='prefer')];
}

/** One month of day cells on the Schedule calendar's own surface (#95): the same panel, weekday
 * row, columns and borders, and the row heights of that month's Schedule calendar (`schedule`,
 * rendered hidden underneath and measured), so switching tabs leaves every day box in place. The
 * neighbour month (`preview`) is the same grid, read-only, while it slides in, with the same
 * passed days, so nothing changes when it lands (#105 rule 7).
 *
 * #105: the note is written in the day (rule 1); a person's consecutive days with the same kind
 * and note draw as one block per week row with the note once (rule 2, display only); the
 * neighbour month's days show their own colour and note (rule 3); passed days are darker and
 * keep theirs, today has Schedule's circle, Fri/Sat are tinted (rule 4). */
function AvailabilityGrid({state,month,person,cells,lang,mobile,schedule,selection=[],preview=false,bind,onTap,editable,today}:{state:State;month:string;person:string;cells:string[];lang:'en'|'he';mobile:boolean;schedule?:ReactNode;selection?:string[];preview?:boolean;bind?:Ref<HTMLDivElement>;onTap?:(d:string)=>void;
 /** Whether a day can be edited (not passed, not closed, not read-only). */editable:(d:string)=>boolean;today?:string}){
 const t=(a:string,b:string)=>lang==='en'?a:b;
 const ghost=useRef<HTMLDivElement>(null),layers=useRef<HTMLDivElement>(null);
 // Written straight onto the element, before the month stage measures the new month in the same
 // commit: a re-render would show the previous month's rows for a frame and the grid would bounce (#115).
 useLayoutEffect(()=>{
  const grid=ghost.current?.querySelector<HTMLElement>('.calendar-grid'),host=layers.current;
  if(!host)return;
  if(!grid){host.style.removeProperty('--schedule-rows');return}
  const read=()=>host.style.setProperty('--schedule-rows',getComputedStyle(grid).gridTemplateRows);
  read();
  const observer=new ResizeObserver(read);observer.observe(grid);
  return()=>observer.disconnect();
 },[schedule]);
 const everyone=person===EVERYONE;
 const kindOf=(d:string)=>everyone?undefined:state.constraints[person]?.[d];
 const noteOf=(d:string)=>everyone?'':state.constraintNotes?.[person]?.[d]?.trim()??'';
 // Two neighbouring days are one block when both have the same kind and the same trimmed note.
 const joined=(a?:string,b?:string)=>!!a&&!!b&&!!kindOf(a)&&kindOf(a)===kindOf(b)&&noteOf(a)===noteOf(b);
 // A selection is one unbroken outline (#105): each selected cell draws the 2px line only toward
 // neighbours that aren't selected, over its own dividers, plus a 2px dot at an inside corner.
 const chosen=new Set(selection),on=(x?:string)=>!!x&&chosen.has(x),rtl=mobile&&lang==='he';
 function outline(i:number){
  const column=i%7,U=on(cells[i-7]),D=on(cells[i+7]),L=column>0&&on(cells[i-1]),R=column<6&&on(cells[i+1]);
  const start=rtl?'right':'left',end=rtl?'left':'right',dot='linear-gradient(var(--brand-fg),var(--brand-fg))';
  const dots=[U&&L&&!on(cells[i-8])&&`${start} top`,U&&R&&!on(cells[i-6])&&`${end} top`,D&&L&&!on(cells[i+6])&&`${start} bottom`,D&&R&&!on(cells[i+8])&&`${end} bottom`].filter(Boolean).map(at=>`${dot} ${at}/2px 2px no-repeat`);
  return {cell:{...(R?{borderInlineEndColor:'transparent'}:{}),...(D?{borderBottomColor:'transparent'}:{})} as CSSProperties,
   box:{borderTopWidth:U?0:2,borderInlineEndWidth:R?0:2,borderBottomWidth:D?0:2,borderInlineStartWidth:L?0:2,insetInlineEnd:column===6?0:-1,...(dots.length?{background:dots.join(',')}:{})} as CSSProperties};
 }
 return <div ref={layers} className="availability-layers">
  {schedule&&<div ref={ghost} className="schedule-ghost" aria-hidden="true" inert>{schedule}</div>}
  <CalendarSurface lang={lang} dir={mobile&&lang==='he'?'rtl':'ltr'} gridRef={bind} gridClassName={`availability-grid${preview?'':' gesture-grid'}${everyone?' everyone-grid':''}`}>{cells.map((d,i)=>{
   const outside=calendarOwnerMonth(d)!==month,status=kindOf(d),n=noteOf(d),selected=selection.includes(d),open=editable(d);
   const column=i%7,starts=!(column>0&&joined(cells[i-1],d)),joinsNext=column<6&&joined(d,cells[i+1]);
   let span=1;if(starts&&status)while(column+span<7&&joined(cells[i+span-1],cells[i+span]))span++;
   const people=everyone?everyoneOn(state,d):[],shown=people.length>3?people.slice(0,2):people;
   const label=everyone?people.map(x=>x.person.name).join(', '):status==='no'?t('Unavailable','לא זמין'):status==='prefer'?t('Preferred','מועדף'):t('Available','זמין');
   const past=!!today&&d<today,weekend=[5,6].includes(dayOf(d)),line=selected&&!everyone?outline(i):null;
   return <button key={month+d} type="button" data-date={d} data-gesture-key={!preview&&!everyone&&open?d:undefined} aria-disabled={!open||undefined} tabIndex={preview?-1:undefined} onClick={onTap&&(()=>onTap(d))} aria-pressed={everyone?undefined:selected} aria-label={`${shortDate(d,lang)} · ${label}${!everyone&&n?' · '+n:''}`} style={line?.cell}
    className={['day-cell','availability-day',outside?'outside':'',past?'past':'',weekend?'weekend':'',!open?'locked-day':'',status??'',joinsNext?'joins-next':'',selected?'date-selected':''].join(' ')}>
    <span className="date-line"><span className="day-number"><span className={d===today?'current-date':undefined} aria-current={d===today?'date':undefined}>{Number(d.slice(-2))}</span></span></span>
    {starts&&n&&<span className="availability-note" dir="auto" style={{'--span':span} as CSSProperties}>{n}</span>}
    {everyone&&shown.map(x=><span key={x.person.id} className={`availability-who ${x.kind}`} dir="auto">{firstName(x.person.name)}{x.note&&<i> · {x.note}</i>}</span>)}
    {everyone&&people.length>shown.length&&<span className="availability-who more">+{people.length-shown.length}</span>}
    {line&&<i className="selection-box" aria-hidden="true" style={line.box}/>}
   </button>})}</CalendarSurface>
 </div>;
}
/** `onMonth` makes the grid swipe between months (#94): the same stage as the Schedule calendar,
 * mirrored in Hebrew, axis-locked so vertical scrolling stays native. `stage` lets the chevrons play
 * the same slide. A tap opens the one sheet (#105 rule 5): the editor, or the same sheet read-only
 * for a day that can't be edited but has a constraint. In Everyone, a tap lists that day's people. */
export function AvailabilityEditor({state,month,person,cells,lang,disabled,onSave,onMonth,canGo,lockDay,closedDay,today,onPerson,stage,schedule,footer}:{state:State;month:string;person:string;cells:string[];lang:'en'|'he';disabled:boolean;onSave:(days:string[],kind:EditKind,note:string)=>boolean|void|Promise<boolean|void>;onMonth?:(offset:number,swiped:boolean)=>void;
 /** False for a direction the grid can't swipe to (#111). */canGo?:(offset:number)=>boolean;
 /** Why a day can't be edited (a past month or day, a month not open yet; #111), shown as a toast on tap. */lockDay?:(d:string)=>string|null;
 /** A day whose month is closed (deadline, published, read-only): no toast, read-only sheet. Defaults to `disabled`. */closedDay?:(d:string)=>boolean;
 /** The Israel day: earlier days are passed (#105 rule 4). */today?:string;
 /** Everyone (#105 rule 6): a tap on a person switches the picker to them. */onPerson?:(id:string)=>void;
 stage?:Ref<MonthStageHandle>;
 /** That month's Schedule calendar, for the row heights (#95 rule 4). */schedule?:(month:string)=>ReactNode;
 /** Shown under the grid with the selection count (#95: nothing sits between the month bar and the grid). */footer?:ReactNode}){
 const mobile=useMobileLayout();
 const t=(a:string,b:string)=>lang==='en'?a:b;
 const everyone=person===EVERYONE;
 const [selection,setSelection]=useState<string[]>([]),[kind,setKind]=useState<Kind>('no'),[note,setNote]=useState(''),[open,setOpen]=useState(false),[saving,setSaving]=useState(false);
 const [viewing,setViewing]=useState<string|null>(null),[dayList,setDayList]=useState<string|null>(null);
 const [confirmation,setConfirmation]=useState<{value:EditKind;signature:string;changed?:boolean}|null>(null);
 const anchor=useRef(''),lastSelected=useRef(''),selectionRef=useRef(selection),saveLock=useRef(false),pending=useRef<string|null>(null);
 useLayoutEffect(()=>{selectionRef.current=selection},[selection]);
 const [context,setContext]=useState({person,month,disabled});
 const liveContext=useRef(context);
 useLayoutEffect(()=>{liveContext.current=context},[context]);
 if(context.person!==person||context.month!==month||context.disabled!==disabled){
  setContext({person,month,disabled});setSelection([]);setNote('');setOpen(false);setConfirmation(null);setViewing(null);setDayList(null);
 }
 const editable=(d:string)=>!(closedDay?closedDay(d):disabled)&&!lockDay?.(d);
 function edit(days:string[]){if(!days.length)return;setNote(days.length===1?state.constraintNotes?.[person]?.[days[0]]??'':'');setKind(state.constraints[person]?.[days[0]]??'no');setConfirmation(null);setOpen(true)}
 function close(){if(saveLock.current)return;setOpen(false);setConfirmation(null);setSelection([]);selectionRef.current=[];anchor.current='';setNote('')}
 function select(days:string[]){const unique=[...new Set(days)];selectionRef.current=unique;setSelection(unique);if(unique.length)lastSelected.current=unique[0]}
 function range(a:string,b:string){return dates(a<b?a:b,addDays(a<b?b:a,1)).filter(editable)}
 const {container,bindContainer,ignoreClick}=useHoldDrag({enabled:!everyone&&!open&&!viewing,holdMs:280,onStart:key=>{anchor.current=key;select([key])},onMove:key=>{if(anchor.current)select(range(anchor.current,key))},onEnd:key=>{const a=anchor.current;anchor.current='';if(!a||!key){close();return}const days=range(a,key);select(days);edit(days)},onCancel:close});
 /** One day's sheet for the shown person: the editor, or read-only with the kind and the full note. */
 function openDay(d:string){
  if(!editable(d)){
   if(state.constraints[person]?.[d]){select([d]);setViewing(d);return}
   const lock=lockDay?.(d);if(lock)toast(lock,{id:'constraint-lock'});
   return;
  }
  select([d]);edit([d]);
 }
 function tap(d:string){if(ignoreClick())return;
  lastSelected.current=d;
  if(everyone){if(everyoneOn(state,d).length)setDayList(d);return}
  if(mobile&&editable(d)){tactileTick();tactileVisual(container.current?.querySelector(`[data-gesture-key="${d}"]`)??null)}
  openDay(d)}
 // Everyone → a person: once the picker has switched to them, that day's sheet opens.
 useLayoutEffect(()=>{const d=pending.current;if(!d||everyone)return;pending.current=null;openDay(d)});
 function choosePerson(id:string){const d=dayList;if(!d)return;pending.current=d;setDayList(null);onPerson?.(id)}
 function closeViewing(){setViewing(null);setSelection([]);selectionRef.current=[]}
 const hasPersistedSelection=selection.some(d=>!!state.constraints[person]?.[d]||!!state.constraintNotes?.[person]?.[d]);
 const hasNotes=selection.some(d=>!!state.constraintNotes?.[person]?.[d]);
 function conflicts(value:EditKind){return selection.some(d=>{
  const previous=state.constraints[person]?.[d],description=state.constraintNotes?.[person]?.[d]??'';
  return value==='clear'?!!description:selection.length>1&&((!!previous&&previous!==value)||(!!description&&description!==note));
 })}
 const signature=JSON.stringify([person,selection.map(d=>[d,state.constraints[person]?.[d],state.constraintNotes?.[person]?.[d]])]);
 async function save(value:EditKind,confirmed=false){
  if(saveLock.current||!selectionRef.current.length||!selectionRef.current.every(editable))return;
  if(conflicts(value)&&!confirmed){setConfirmation({value,signature});return}
  if(confirmed&&confirmation?.signature!==signature){setConfirmation({value,signature,changed:true});return}
  saveLock.current=true;setSaving(true);
  const days=[...selectionRef.current],editingPerson=person,editingMonth=month;
  try{if(await onSave(days,value,note)!==false&&liveContext.current.person===editingPerson&&liveContext.current.month===editingMonth&&!liveContext.current.disabled){saveLock.current=false;close()}}
  finally{saveLock.current=false;setSaving(false);setConfirmation(null)}
 }
 const restoreFocus=(e:Event)=>{e.preventDefault();container.current?.querySelector<HTMLButtonElement>(`.month-pane:not(.month-peek) [data-date="${lastSelected.current}"], .availability-grid [data-date="${lastSelected.current}"]`)?.focus()};
 const grid=<AvailabilityGrid state={state} month={month} person={person} cells={cells} lang={lang} mobile={mobile} schedule={schedule?.(month)} selection={selection} bind={bindContainer} onTap={tap} editable={editable} today={today}/>;
 const count=new Set(selection).size;
 const rangeTitle=count===1?dayTitle(selection[0],lang):dateRange(selection,lang);
 const selectionCount=lang==='en'?`${count} ${count===1?'day':'days'} selected`:count===1?'נבחר יום אחד':`נבחרו ${count} ימים`;
 function warning(value:EditKind){
  if(value==='clear')return t('Removing constraints will also permanently delete existing descriptions from the selected dates.','הסרת האילוצים תמחק גם את התיאורים הקיימים בתאריכים שנבחרו.');
  const change=t('This will replace existing availability on all selected dates.','פעולה זו תחליף את הזמינות הקיימת בכל התאריכים שנבחרו.');
  return change+(hasNotes?(note.trim()?t(' Existing descriptions will be replaced with the new description.',' התיאורים הקיימים יוחלפו בתיאור החדש.'):t(' The description is blank: existing descriptions will be cleared.',' התיאור ריק: התיאורים הקיימים יימחקו.')):'');
 }
 const kindLabel=(k?:string)=>k==='prefer'?t('Prefer duty','מעדיף כוננות'):t('Unavailable','לא זמין');
 const viewedKind=viewing?state.constraints[person]?.[viewing]:undefined,viewedNote=viewing?state.constraintNotes?.[person]?.[viewing]?.trim():'';
 const listed=dayList?everyoneOn(state,dayList):[];
 // The note field grows to show the whole note (#105 rule 5).
 const grow=(el:HTMLTextAreaElement|null)=>{if(!el)return;el.style.height='auto';el.style.height=`${el.scrollHeight+2}px`};
 return <div className="constraint-editor">
 {onMonth?<MonthStage ref={stage} month={month} rtl={lang==='he'} onChange={onMonth} canGo={canGo} preview={m=><AvailabilityGrid preview state={state} month={m} person={person} cells={calendarDates(m)} lang={lang} mobile={mobile} schedule={schedule?.(m)} editable={editable} today={today}/>}>{grid}</MonthStage>:grid}
 <div className="availability-tools" dir={lang==='he'?'rtl':'ltr'}>{footer}<p className="gesture-hint" role="status" aria-atomic="true">{count?selectionCount:' '}</p></div>
 <EditorDialog open={open} onClose={close} saving={saving} lang={lang} title={<bdi>{rangeTitle}</bdi>} className="availability-dialog" onCloseAutoFocus={restoreFocus}>
  <div className="constraint-choices">
   <button disabled={saving} aria-pressed={kind==='no'} className={kind==='no'?'chosen no':''} onClick={()=>setKind('no')}>{t('Unavailable','לא זמין')}</button>
   <button disabled={saving} aria-pressed={kind==='prefer'} className={kind==='prefer'?'chosen prefer':''} onClick={()=>setKind('prefer')}>{t('Prefer duty','מעדיף כוננות')}</button>
  </div>
  <label className="field-label">{t('Description (optional)','תיאור (לא חובה)')}<textarea ref={grow} disabled={saving} value={note} maxLength={300} rows={2} placeholder={t('Vacation, appointment…','חופשה, תור…')} onChange={e=>{setNote(e.target.value);grow(e.target)}}/></label>
  <div className="editor-actions">
   <Button disabled={saving} onClick={()=>save(kind)}>{t('Save','שמירה')}</Button>
  </div>
  {hasPersistedSelection&&<Button disabled={saving} variant="ghost" className="remove-constraint" onClick={()=>save('clear')}><Trash2 size={16}/>{t('Remove constraint','הסרת אילוץ')}</Button>}
  <EditorDialog open={!!confirmation} onClose={()=>{if(!saveLock.current)setConfirmation(null)}} saving={saving} lang={lang} role="alertdialog" title={t('Replace existing availability?','להחליף את הזמינות הקיימת?')} description={confirmation?warning(confirmation.value):''}>
   {confirmation?.changed&&<p role="status" className="constraint-notes-help">{t('Availability changed. Review the warning and confirm again.','הזמינות השתנתה. בדקו את האזהרה ואשרו שוב.')}</p>}
   <div className="editor-actions">
    <Button variant="outline" disabled={saving} onClick={()=>setConfirmation(null)}>{t('Cancel','ביטול')}</Button>
    <Button disabled={saving} onClick={()=>{if(confirmation)save(confirmation.value,true)}}>{confirmation?.value==='clear'?t('Remove constraints and notes','הסרת אילוצים והערות'):t('Replace and save','החלפה ושמירה')}</Button>
   </div>
  </EditorDialog>
 </EditorDialog>
 <EditorDialog open={!!viewing} onClose={closeViewing} lang={lang} title={<bdi>{viewing?dayTitle(viewing,lang):''}</bdi>} className="availability-dialog constraint-view" onCloseAutoFocus={restoreFocus}>
  <p className={`constraint-state ${viewedKind??''}`}><i aria-hidden="true"/>{kindLabel(viewedKind)}</p>
  {viewedNote&&<p className="constraint-note-full" dir="auto">{viewedNote}</p>}
 </EditorDialog>
 <EditorDialog open={!!dayList} onClose={()=>setDayList(null)} lang={lang} title={<bdi>{dayList?dayTitle(dayList,lang):''}</bdi>} className="availability-dialog everyone-day" onCloseAutoFocus={restoreFocus}>
  {(['no','prefer'] as const).map(k=>{const group=listed.filter(x=>x.kind===k);return group.length?<section key={k} className={`everyone-group ${k}`}>
   <h3>{kindLabel(k)}</h3>
   <ul>{group.map(x=><li key={x.person.id}><button type="button" className="everyone-person" onClick={()=>choosePerson(x.person.id)}>
    <Avatar name={x.person.name} color={x.person.color} size={36}/>
    <span><b>{x.person.name}</b>{x.note&&<small dir="auto">{x.note}</small>}</span>
   </button></li>)}</ul>
  </section>:null})}
 </EditorDialog>
 </div>
}
