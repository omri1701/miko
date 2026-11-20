'use client';
import {useLayoutEffect,useRef,useState,type CSSProperties,type ReactNode,type Ref} from 'react';
import {Pencil,Trash2} from 'lucide-react';
import {EditorDialog} from '@/components/rota/editor-dialog';
import {useMobileLayout} from '@/hooks/use-mobile-layout';
import {tactileTick,tactileVisual} from '@/lib/tactile';
import {dateRange,shortDate} from '@/lib/date-format';
import {Button} from '@/components/ui/button';
import {useHoldDrag} from '@/hooks/use-hold-drag';
import {dates,addDays,type State} from '@/lib/rota/engine';
import {calendarDates,calendarOwnerMonth} from '@/lib/rota/calendar-dates';
import {MonthStage,type MonthStageHandle} from '@/components/rota/month-stage';
import {CalendarSurface} from '@/components/rota/calendar-presentation';
type EditKind='no'|'prefer'|'clear';
/** One month of day cells on the Schedule calendar's own surface (#95): the same panel, weekday
 * row, columns and borders, and the row heights of that month's Schedule calendar (`schedule`,
 * rendered hidden underneath and measured), so switching tabs leaves every day box in place. The
 * neighbour month (`preview`) is the same grid, read-only, while it slides in. */
function AvailabilityGrid({state,month,person,cells,lang,disabled,mobile,schedule,selection=[],preview=false,bind,onTap}:{state:State;month:string;person:string;cells:string[];lang:'en'|'he';disabled:boolean;mobile:boolean;schedule?:ReactNode;selection?:string[];preview?:boolean;bind?:Ref<HTMLDivElement>;onTap?:(d:string)=>void}){
 const t=(a:string,b:string)=>lang==='en'?a:b;
 const ghost=useRef<HTMLDivElement>(null),[rows,setRows]=useState('');
 useLayoutEffect(()=>{
  const grid=ghost.current?.querySelector<HTMLElement>('.calendar-grid');
  if(!grid){setRows('');return}
  const read=()=>setRows(getComputedStyle(grid).gridTemplateRows);
  read();
  const observer=new ResizeObserver(read);observer.observe(grid);
  return()=>observer.disconnect();
 },[schedule]);
 return <div className="availability-layers" style={rows?{'--schedule-rows':rows} as CSSProperties:undefined}>
  {schedule&&<div ref={ghost} className="schedule-ghost" aria-hidden="true" inert>{schedule}</div>}
  <CalendarSurface lang={lang} dir={mobile&&lang==='he'?'rtl':'ltr'} gridRef={bind} gridClassName={`availability-grid${preview?'':' gesture-grid'}`}>{cells.map(d=>{
   const outside=calendarOwnerMonth(d)!==month,status=outside?undefined:state.constraints[person]?.[d],selected=selection.includes(d),n=outside?undefined:state.constraintNotes?.[person]?.[d];
   const label=status==='no'?t('Unavailable','לא זמין'):status==='prefer'?t('Preferred','מועדף'):t('Available','זמין');
   return <button key={d} type="button" data-date={d} data-gesture-key={!outside&&!preview?d:undefined} disabled={disabled||outside} tabIndex={preview||outside?-1:undefined} onClick={onTap&&(()=>onTap(d))} aria-pressed={selected} aria-label={`${shortDate(d,lang)} · ${label}${n?' · '+n:''}`}
    className={['day-cell','availability-day',outside?'outside':'',status??'',selected?'date-selected':''].join(' ')}>
    <span className="date-line"><span className="day-number">{Number(d.slice(-2))}</span></span>
    {n?.trim()&&<span className="mobile-note-dot" aria-hidden="true"/>}
    {n?.trim()&&<span className="availability-description">{n}</span>}
   </button>})}</CalendarSurface>
 </div>;
}
/** `onMonth` makes the grid swipe between months (#94): the same stage as the Schedule calendar,
 * mirrored in Hebrew, axis-locked so vertical scrolling stays native. `stage` lets the chevrons play
 * the same slide. On phones a tap on an unavailable day with a note reads the note first (#95). */
export function AvailabilityEditor({state,month,person,cells,lang,disabled,onSave,onMonth,stage,schedule,footer}:{state:State;month:string;person:string;cells:string[];lang:'en'|'he';disabled:boolean;onSave:(days:string[],kind:EditKind,note:string)=>boolean|void|Promise<boolean|void>;onMonth?:(offset:number,swiped:boolean)=>void;stage?:Ref<MonthStageHandle>;
 /** That month's Schedule calendar, for the row heights (#95 rule 4). */schedule?:(month:string)=>ReactNode;
 /** Shown under the grid with the selection count (#95: nothing sits between the month bar and the grid). */footer?:ReactNode}){
 const mobile=useMobileLayout();
 const t=(a:string,b:string)=>lang==='en'?a:b;
 const [selection,setSelection]=useState<string[]>([]),[kind,setKind]=useState<'no'|'prefer'>('no'),[note,setNote]=useState(''),[open,setOpen]=useState(false),[saving,setSaving]=useState(false);
 const [reading,setReading]=useState<string|null>(null);
 const [confirmation,setConfirmation]=useState<{value:EditKind;signature:string;changed?:boolean}|null>(null);
 const anchor=useRef(''),lastSelected=useRef(''),selectionRef=useRef(selection),saveLock=useRef(false);
 useLayoutEffect(()=>{selectionRef.current=selection},[selection]);
 const [context,setContext]=useState({person,month,disabled});
 const liveContext=useRef(context);
 useLayoutEffect(()=>{liveContext.current=context},[context]);
 if(context.person!==person||context.month!==month||context.disabled!==disabled){
  setContext({person,month,disabled});setSelection([]);setNote('');setOpen(false);setConfirmation(null);setReading(null);
 }
 function edit(days:string[]){if(!days.length)return;setNote(days.length===1?state.constraintNotes?.[person]?.[days[0]]??'':'');setKind(state.constraints[person]?.[days[0]]??'no');setConfirmation(null);setOpen(true)}
 function close(){if(saveLock.current)return;setOpen(false);setConfirmation(null);setSelection([]);selectionRef.current=[];anchor.current='';setNote('')}
 function select(days:string[]){const unique=[...new Set(days)];selectionRef.current=unique;setSelection(unique);if(unique.length)lastSelected.current=unique[0]}
 const owns=(d:string)=>calendarOwnerMonth(d)===month;
 function range(a:string,b:string){return dates(a<b?a:b,addDays(a<b?b:a,1)).filter(owns)}
 const {container,bindContainer,ignoreClick}=useHoldDrag({enabled:!disabled&&!open,holdMs:280,onStart:key=>{anchor.current=key;select([key])},onMove:key=>{if(anchor.current)select(range(anchor.current,key))},onEnd:key=>{const a=anchor.current;anchor.current='';if(!a||!key){close();return}const days=range(a,key);select(days);edit(days)},onCancel:close});
 function toggle(d:string){if(ignoreClick()||disabled)return;select([d]);if(mobile){tactileTick();tactileVisual(container.current?.querySelector(`[data-gesture-key="${d}"]`)??null)}
  // A phone cuts the note short: an unavailable day with a note opens it to read, with Edit (#95).
  if(mobile&&state.constraints[person]?.[d]==='no'&&state.constraintNotes?.[person]?.[d]?.trim()){lastSelected.current=d;setReading(d);return}
  edit([d])}
 function closeReading(){setReading(null);setSelection([]);selectionRef.current=[]}
 const hasPersistedSelection=selection.some(d=>!!state.constraints[person]?.[d]||!!state.constraintNotes?.[person]?.[d]);
 const hasNotes=selection.some(d=>!!state.constraintNotes?.[person]?.[d]);
 function conflicts(value:EditKind){return selection.some(d=>{
  const previous=state.constraints[person]?.[d],description=state.constraintNotes?.[person]?.[d]??'';
  return value==='clear'?!!description:selection.length>1&&((!!previous&&previous!==value)||(!!description&&description!==note));
 })}
 const signature=JSON.stringify([person,selection.map(d=>[d,state.constraints[person]?.[d],state.constraintNotes?.[person]?.[d]])]);
 async function save(value:EditKind,confirmed=false){
  if(saveLock.current||disabled||!selectionRef.current.length)return;
  if(conflicts(value)&&!confirmed){setConfirmation({value,signature});return}
  if(confirmed&&confirmation?.signature!==signature){setConfirmation({value,signature,changed:true});return}
  saveLock.current=true;setSaving(true);
  const days=[...selectionRef.current],editingPerson=person,editingMonth=month;
  try{if(await onSave(days,value,note)!==false&&liveContext.current.person===editingPerson&&liveContext.current.month===editingMonth&&!liveContext.current.disabled){saveLock.current=false;close()}}
  finally{saveLock.current=false;setSaving(false);setConfirmation(null)}
 }
 const title=(d:string)=>shortDate(d,lang);
 const restoreFocus=(e:Event)=>{e.preventDefault();container.current?.querySelector<HTMLButtonElement>(`[data-gesture-key="${lastSelected.current}"]`)?.focus()};
 const grid=<AvailabilityGrid state={state} month={month} person={person} cells={cells} lang={lang} disabled={disabled} mobile={mobile} schedule={schedule?.(month)} selection={selection} bind={bindContainer} onTap={toggle}/>;
 const rangeTitle=dateRange(selection,lang),count=new Set(selection).size;
 const selectionCount=lang==='en'?`${count} ${count===1?'day':'days'} selected`:count===1?'נבחר יום אחד':`נבחרו ${count} ימים`;
 function warning(value:EditKind){
  if(value==='clear')return t('Removing constraints will also permanently delete existing descriptions from the selected dates.','הסרת האילוצים תמחק גם את התיאורים הקיימים בתאריכים שנבחרו.');
  const change=t('This will replace existing availability on all selected dates.','פעולה זו תחליף את הזמינות הקיימת בכל התאריכים שנבחרו.');
  return change+(hasNotes?(note.trim()?t(' Existing descriptions will be replaced with the new description.',' התיאורים הקיימים יוחלפו בתיאור החדש.'):t(' The description is blank: existing descriptions will be cleared.',' התיאור ריק: התיאורים הקיימים יימחקו.')):'');
 }
 return <div className="constraint-editor">
 {onMonth?<MonthStage ref={stage} month={month} rtl={lang==='he'} onChange={onMonth} preview={m=><AvailabilityGrid preview state={state} month={m} person={person} cells={calendarDates(m)} lang={lang} disabled={disabled} mobile={mobile} schedule={schedule?.(m)}/>}>{grid}</MonthStage>:grid}
 <div className="availability-tools" dir={lang==='he'?'rtl':'ltr'}>{footer}<p className="gesture-hint" role="status" aria-atomic="true">{count?selectionCount:' '}</p></div>
 <EditorDialog open={open} onClose={close} saving={saving} lang={lang} title={<bdi>{rangeTitle}</bdi>} description={<span className="constraint-range-help">{selection.length>1?t('Applies to all selected dates','חל על כל התאריכים שנבחרו'):t('Choose availability for this date.','בחרו זמינות לתאריך זה.')}</span>} className="availability-dialog" onCloseAutoFocus={restoreFocus}>
  {conflicts(kind)&&<p className="constraint-notes-help" role="status">{warning(kind)} {t('You will be asked to confirm before saving.','לפני השמירה יידרש אישור.')}</p>}
  <div className="constraint-choices">
   <button disabled={saving} aria-pressed={kind==='no'} className={kind==='no'?'chosen no':''} onClick={()=>setKind('no')}>{t('Unavailable','לא זמין')}</button>
   <button disabled={saving} aria-pressed={kind==='prefer'} className={kind==='prefer'?'chosen prefer':''} onClick={()=>setKind('prefer')}>{t('Prefer duty','מעדיף כוננות')}</button>
  </div>
  <label className="field-label">{t('Description (optional)','תיאור (לא חובה)')}<textarea disabled={saving} value={note} maxLength={300} rows={2} placeholder={t('Vacation, appointment…','חופשה, תור…')} onChange={e=>setNote(e.target.value)}/></label>
  {hasPersistedSelection&&<Button disabled={saving} variant="outline" className="remove-constraint" onClick={()=>save('clear')}><Trash2 size={16}/>{t('Remove constraint','הסרת אילוץ')}</Button>}
  <div className="editor-actions">
   <Button disabled={saving} onClick={()=>save(kind)}>{t('Save','שמירה')}</Button>
  </div>
  <EditorDialog open={!!confirmation} onClose={()=>{if(!saveLock.current)setConfirmation(null)}} saving={saving} lang={lang} role="alertdialog" title={t('Replace existing availability?','להחליף את הזמינות הקיימת?')} description={confirmation?warning(confirmation.value):''}>
   {confirmation?.changed&&<p role="status" className="constraint-notes-help">{t('Availability changed. Review the warning and confirm again.','הזמינות השתנתה. בדקו את האזהרה ואשרו שוב.')}</p>}
   <div className="editor-actions">
    <Button variant="outline" disabled={saving} onClick={()=>setConfirmation(null)}>{t('Cancel','ביטול')}</Button>
    <Button disabled={saving} onClick={()=>{if(confirmation)save(confirmation.value,true)}}>{confirmation?.value==='clear'?t('Remove constraints and notes','הסרת אילוצים והערות'):t('Replace and save','החלפה ושמירה')}</Button>
   </div>
  </EditorDialog>
 </EditorDialog>
 <EditorDialog open={!!reading} onClose={closeReading} lang={lang} title={<bdi>{reading?title(reading):''}</bdi>} description={<span className="constraint-range-help">{t('Unavailable','לא זמין')}</span>} className="constraint-note-sheet" onCloseAutoFocus={restoreFocus}>
  <p className="constraint-note-full" dir="auto">{reading?state.constraintNotes?.[person]?.[reading]:''}</p>
  <div className="editor-actions"><Button onClick={()=>{const d=reading;if(!d)return;setReading(null);select([d]);edit([d])}}><Pencil size={16}/>{t('Edit','עריכה')}</Button></div>
 </EditorDialog>
 </div>
}
