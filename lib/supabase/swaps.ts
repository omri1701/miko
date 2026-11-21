import {addDays,dayOf} from '../rota/engine.ts';
import type {Snapshot,SwapRequest,DutyRow} from './snapshot.ts';
import type {DutyClient} from './rpc.ts';

export function publishedSwapDuties(raw:Snapshot,month:string,today:string){
 const publication=raw.months.find(m=>m.month===month)?.current_publication_id;
 return raw.assignments.filter(a=>publication&&a.publication_id===publication&&a.day>=today&&
  (dayOf(a.day)===6?addDays(a.day,-1):a.day).slice(0,7)===month&&
  raw.members.some(m=>m.id===a.primary_id&&m.active&&m.status==='approved')).sort((a,b)=>a.day.localeCompare(b.day));
}

export function eligibleSwapTarget(source:DutyRow|undefined,target:DutyRow|undefined){
 return !!source&&!!target&&source.id!==target.id&&source.publication_id===target.publication_id&&
  source.primary_id!==target.primary_id&&target.secondary_id!==source.primary_id&&source.secondary_id!==target.primary_id;
}

/** Who started the request: the admin who proposed it, or the requester. */
export const swapStarter=(r:SwapRequest)=>r.proposed_by??r.requester_id;

/** Members whose answer is still missing. A requester who asked consented by sending it. */
export function swapWaitingOn(r:SwapRequest){
 if(r.status!=='awaiting_engineer')return [];
 return [...(r.proposed_by&&!r.requester_accepted_at?[r.requester_id]:[]),...(r.accepted_by?[]:[r.other_id])];
}

/** A swap's duties in the month's current publication, as resolve_swap finds them. */
export function swapDuties(raw:Snapshot,r:SwapRequest){
 const publication=raw.months.find(m=>m.month===r.month)?.current_publication_id;
 const find=(day:string,end:string)=>raw.assignments.find(a=>publication&&a.publication_id===publication&&a.day===day&&a.end_day===end);
 return {source:find(r.from_day,r.from_end_day),target:find(r.to_day,r.to_end_day)};
}

export type SwapProblem={kind:'weekend';person:string}|{kind:'availability';person:string;day:string};
/** What duty_private.validate_swap would refuse, checked before the click (decision 2026-11-01): a
 * second weekend for either engineer (either half or emergency cover counts), or an availability
 * conflict among the constraints in raw. Swaps checks only the weekend here: its availability
 * alert comes from duty_swap_availability, which also covers the counterpart and cover. */
export function swapProblem(raw:Snapshot,month:string,source:DutyRow,target:DutyRow,availability=true):SwapProblem|null{
 const no=(people:(string|null)[],duty:DutyRow)=>raw.constraints.find(c=>c.kind==='no'&&people.includes(c.member_id)&&c.day>=duty.day&&c.day<duty.end_day);
 const conflict=availability?no([target.primary_id,source.secondary_id],source)??no([source.primary_id,target.secondary_id],target):undefined;
 if(conflict)return {kind:'availability',person:conflict.member_id,day:conflict.day};
 const weekends=raw.assignments.filter(a=>a.publication_id===source.publication_id&&[5,6].includes(dayOf(a.day))&&(dayOf(a.day)===6?addDays(a.day,-1):a.day).slice(0,7)===month);
 const primary=(a:DutyRow)=>a.id===source.id?target.primary_id:a.id===target.id?source.primary_id:a.primary_id;
 const count=(who:string,owner:(a:DutyRow)=>string|null)=>new Set(weekends.filter(a=>owner(a)===who||a.secondary_id===who).map(a=>dayOf(a.day)===6?addDays(a.day,-1):a.day)).size;
 for(const who of [source.primary_id,target.primary_id]){
  if(!who)continue;
  const after=count(who,primary);
  if(after>1&&after>count(who,a=>a.primary_id))return {kind:'weekend',person:who};
 }
 return null;
}

/** Whose answer Accept or Decline records for this viewer, as resolve_swap decides: their own
 * open side first; an admin also answers for a temporary member, who has no account
 * (decision 2026-11-01), the requester's side before the other's. */
export function swapAnswerFor(r:SwapRequest,me:string,admin:boolean,temporary:ReadonlySet<string>=new Set()){
 const waiting=swapWaitingOn(r);
 return waiting.includes(me)?me:admin?waiting.find(id=>temporary.has(id))??null:null;
}

export function swapNeedsAction(r:SwapRequest,me:string,admin:boolean,temporary?:ReadonlySet<string>){
 return swapAnswerFor(r,me,admin,temporary)!==null||(admin&&r.status==='awaiting_admin');
}

export function visibleSwapRequests(requests:SwapRequest[],me:string,admin:boolean,temporary?:ReadonlySet<string>){
 return requests.filter(r=>r.requester_id===me||r.proposed_by===me||
  (r.other_id===me&&r.status==='awaiting_engineer')||(admin&&r.status==='awaiting_admin')||swapAnswerFor(r,me,admin,temporary)!==null)
  .sort((a,b)=>Number(swapNeedsAction(b,me,admin,temporary))-Number(swapNeedsAction(a,me,admin,temporary))||b.created_at.localeCompare(a.created_at));
}

/** A member's unavailability that blocks a swap: who and which date, never the note.
 * Members see emergency cover's conflicts without a name (member null). */
export type SwapConflict={member:string|null;day:string};
export function readSwapConflicts(value:unknown):SwapConflict[]{
 if(!Array.isArray(value)||value.some(c=>typeof c!=='object'||c===null||(c.member!==null&&typeof c.member!=='string')||typeof c.day!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(c.day)))
  throw Error('Invalid availability check');
 return value.map(c=>({member:c.member,day:c.day}));
}
const inside=(d:{day:string;end_day:string},day:string)=>day>=d.day&&day<d.end_day;
/** A primary's own unavailability on the duty they would take (#92): they consent by sending or
 * accepting, so it never blocks. Anything else (emergency cover) blocks a request. */
export const partyConflict=(c:SwapConflict,source:DutyRow,target:DutyRow)=>
 (c.member!==null&&c.member===source.primary_id&&inside(target,c.day))||(c.member!==null&&c.member===target.primary_id&&inside(source,c.day));
export const coverConflicts=(conflicts:SwapConflict[],source:DutyRow,target:DutyRow)=>conflicts.filter(c=>!partyConflict(c,source,target));
/** A note is shown only to its owner and to admins (owner 2026-11-21); never to other members. */
export const visibleNote=(note:string|undefined,member:string,{me,admin}:{me:string;admin:boolean})=>admin||member===me?note??'':'';
/** One constraint line, read like a person wrote it: "You marked 22 Dec as unavailable · doctor",
 * "Avi marked 22 Dec as unavailable · doctor" (admins) or without the note (other members).
 * Callers pass `note` through visibleNote. */
export function constraintLine({member,day:d,note}:{member:string;day:string;note?:string},{me,name,day,lang}:{me:string;name:(id:string)=>string;day:(d:string)=>string;lang:'en'|'he'}){
 const he=lang==='he';
 const text=member===me?(he?`סימנת את ${day(d)} כלא זמין`:`You marked ${day(d)} as unavailable`)
  :he?`${name(member)} סימן/ה את ${day(d)} כלא זמין`:`${name(member)} marked ${day(d)} as unavailable`;
 return note?`${text} · ${note}`:text;
}
/** The two members' own 'no' constraints on the duty each would take (other: from, requester: to).
 * Members' snapshots hold only their own constraints (RLS); admins' hold all. */
export function swapPartyConstraints(raw:Snapshot,r:SwapRequest){
 return raw.constraints.filter(c=>c.kind==='no'&&((c.member_id===r.other_id&&inside({day:r.from_day,end_day:r.from_end_day},c.day))
  ||(c.member_id===r.requester_id&&inside({day:r.to_day,end_day:r.to_end_day},c.day)))).sort((a,b)=>a.day.localeCompare(b.day));
}
/** Why a target day can't be picked for a swap, shown before the pick (decision 2026-11-05).
 * Built from duty_swap_availability's conflicts (who and which date, never the note or kind)
 * and the second-weekend rule, so a day the calendar still offers is one the server accepts. */
export type SwapBlock=
 |{kind:'cover';person:string|null;day:string}
 |{kind:'weekend';person:string}
 |{kind:'inactive'}
 |{kind:'past'};
export function swapTargetBlock(raw:Snapshot,month:string,source:DutyRow,target:DutyRow,conflicts:SwapConflict[]):SwapBlock|null{
 // validate_swap refuses a pair whose emergency cover left the team.
 if([source.secondary_id,target.secondary_id].some(id=>id&&!raw.members.some(m=>m.id===id&&m.active&&m.status==='approved')))return {kind:'inactive'};
 const cover=coverConflicts(conflicts,source,target)[0];
 if(cover)return {kind:'cover',person:cover.member,day:cover.day};
 const problem=swapProblem(raw,month,source,target,false);
 return problem?.kind==='weekend'?{kind:'weekend',person:problem.person}:null;
}
/** A target that stays tappable but shows red (#92): a primary marked one of its dates
 * unavailable. The swap's own person first, then the other primary. */
export type SwapWarning={person:string;day:string};
export function swapTargetWarning(source:DutyRow,target:DutyRow,conflicts:SwapConflict[]):SwapWarning|null{
 const party=conflicts.filter(c=>partyConflict(c,source,target));
 const first=party.find(c=>c.member===source.primary_id)??party[0];
 return first?{person:first.member!,day:first.day}:null;
}
/** The red day's line: constraintLine for its person, with the note when the viewer may read it. */
export const swapWarningText=(w:SwapWarning,options:{me:string;name:(id:string)=>string;day:(d:string)=>string;lang:'en'|'he';note?:string})=>
 constraintLine({member:w.person,day:w.day,note:options.note},options);
/** One short reason, phrased for the viewer: "you" for themselves, names for others. */
export function swapBlockText(block:SwapBlock,{me,name,day,lang}:{me:string;name:(id:string)=>string;day:(d:string)=>string;lang:'en'|'he'}){
 const he=lang==='he';
 switch(block.kind){
  case 'past':return he?'הכוננות הזו כבר עברה':'This day has passed';
  case 'inactive':return he?'כונן החירום כבר אינו פעיל':'Emergency cover is no longer active';
  case 'cover':return block.person
   ?he?`ל${name(block.person)} אין אפשרות לכסות את ${day(block.day)}`:`${name(block.person)} can’t cover ${day(block.day)}`
   :he?`לכונן החירום אין אפשרות ב־${day(block.day)}`:`Emergency cover can’t take ${day(block.day)}`;
  case 'weekend':return block.person===me?(he?'ההחלפה תיתן לך סוף שבוע שני':'This would give you a second weekend')
   :he?`ההחלפה תיתן ל${name(block.person)} סוף שבוע שני`:`This would give ${name(block.person)} a second weekend`;
 }
}
export async function swapAvailability(client:DutyClient,from:string,to:string){
 const {data,error}=await client.rpc('duty_swap_availability',{p_from:from,p_to:to});
 if(error)throw error;
 return readSwapConflicts(data);
}

const pointsText=(n:number,lang:'en'|'he')=>lang==='he'?`${n} נק׳`:`${n} ${n===1?'pt':'pts'}`;
const signed=(n:number,lang:'en'|'he')=>(n>0?'+':n<0?'−':'')+pointsText(Math.abs(n),lang);
/** Plain text an admin copies into the external system before approving. */
export function swapSummary({requester,other,from,to,lang}:{requester:string;other:string;from:{label:string;points:number};to:{label:string;points:number};lang:'en'|'he'}){
 const he=lang==='he',change=to.points-from.points;
 const side=(name:string,gives:typeof from,takes:typeof from,delta:number)=>he
  ?`${name} — מסירה: ${gives.label} (${pointsText(gives.points,lang)}) · קבלה: ${takes.label} (${pointsText(takes.points,lang)}) · שינוי: ${signed(delta,lang)}`
  :`${name} — gives: ${gives.label} (${pointsText(gives.points,lang)}) · takes: ${takes.label} (${pointsText(takes.points,lang)}) · change: ${signed(delta,lang)}`;
 return [`${he?'החלפת כוננויות':'Duty swap'}: ${requester} ⇄ ${other}`,side(requester,from,to,change),side(other,to,from,-change)].join('\n');
}
