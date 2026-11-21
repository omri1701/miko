import test from 'node:test';
import assert from 'node:assert/strict';
import {publishedSwapDuties,eligibleSwapTarget,visibleSwapRequests,swapStarter,swapWaitingOn,swapAnswerFor,swapNeedsAction,readSwapConflicts,swapSummary,swapTargetBlock,swapBlockText,swapTargetWarning,swapWarningText,swapOwnConflict,coverConflicts,swapPartyConstraints,noteLabel} from '../lib/supabase/swaps.ts';
import {todayIsrael} from '../lib/rota/calendar-dates.ts';

test('Israeli midnight expires yesterday, including a continuing Friday weekend',()=>{
 const raw={months:[{month:'2026-10',current_publication_id:'p'}],members:[{id:'a',active:true,status:'approved'}],assignments:[
  {id:'friday',day:'2026-10-16',end_day:'2026-10-18',primary_id:'a',publication_id:'p'},
  {id:'saturday',day:'2026-10-17',end_day:'2026-10-18',primary_id:'a',publication_id:'p'},
  {id:'sunday',day:'2026-10-18',end_day:'2026-10-19',primary_id:'a',publication_id:'p'},
 ]};
 const ids=instant=>publishedSwapDuties(raw,'2026-10',todayIsrael(new Date(instant))).map(d=>d.id);
 assert.deepEqual(ids('2026-10-16T21:00:00Z'),['saturday','sunday']);
 assert.deepEqual(ids('2026-10-17T20:59:59Z'),['saturday','sunday']);
 assert.deepEqual(ids('2026-10-17T21:00:00Z'),['sunday']);
});

test('swap choices use the current publication, active primaries and today or later dates',()=>{
 const raw={months:[{month:'2026-10',status:'draft',current_publication_id:'current'}],members:[{id:'e',active:true,status:'approved'},{id:'off',active:false,status:'approved'}],assignments:[
  {id:'draft',publication_id:null,day:'2026-10-12',primary_id:'e'},
  {id:'old',publication_id:'old',day:'2026-10-12',primary_id:'e'},
  {id:'today',publication_id:'current',day:'2026-10-09',primary_id:'e'},
  {id:'past',publication_id:'current',day:'2026-10-08',primary_id:'e'},
  {id:'off',publication_id:'current',day:'2026-10-12',primary_id:'off'},
  {id:'open',publication_id:'current',day:'2026-10-12',primary_id:null},
  {id:'future',publication_id:'current',day:'2026-10-12',primary_id:'e'},
 ]};
 assert.deepEqual(publishedSwapDuties(raw,'2026-10','2026-10-09').map(d=>d.id),['today','future']);
 assert.deepEqual(publishedSwapDuties(raw,'2026-11','2026-10-09'),[]);
});

test('published drag and keyboard selection require another eligible primary, preserving emergency cover',()=>{
 const own={id:'x',publication_id:'p',primary_id:'a',secondary_id:'cover'};
 const target={id:'y',publication_id:'p',primary_id:'b',secondary_id:null};
 assert.equal(eligibleSwapTarget(own,target),true);
 for(const invalid of [own,{...target,publication_id:'old'},{...target,primary_id:'a'},{...target,primary_id:'cover'},{...target,secondary_id:'a'},undefined]){
  assert.equal(eligibleSwapTarget(own,invalid),false);
 }
});

test('empty request list hides the section; consent and admin action sort before outgoing history',()=>{
 const make=(id,requester_id,other_id,status,created_at='2026-10-09')=>({id,month:'2026-11',requester_id,other_id,status,created_at});
 const requests=[make('old','a','b','approved'),make('out','a','b','awaiting_engineer'),make('incoming','c','a','awaiting_engineer','2026-10-08'),make('admin','b','c','awaiting_admin'),make('private','b','c','declined')];
 assert.deepEqual(visibleSwapRequests(requests,'outsider',false),[]);
 assert.deepEqual(visibleSwapRequests([],'a',true),[]);
 assert.deepEqual(visibleSwapRequests(requests,'a',false).map(r=>r.id),['incoming','old','out']);
 assert.deepEqual(visibleSwapRequests(requests,'a',true).map(r=>r.id),['admin','incoming','old','out']);
 assert.deepEqual(visibleSwapRequests(requests,'b',false).map(r=>r.id),['out','admin','private']);
 assert.deepEqual(visibleSwapRequests(requests.map((r,i)=>({...r,month:i%2?'2026-12':'2026-11'})),'a',true).map(r=>r.id),['admin','incoming','old','out']);
});

test('split Saturday belongs to Friday’s month and carried previous weekends are excluded',()=>{
 const raw={months:[{month:'2026-07',current_publication_id:'july'},{month:'2026-08',current_publication_id:'august'}],members:[{id:'e',active:true,status:'approved'}],assignments:[
  {id:'friday',publication_id:'july',day:'2026-07-31',end_day:'2026-08-01',primary_id:'e'},
  {id:'saturday',publication_id:'july',day:'2026-08-01',end_day:'2026-08-02',primary_id:'e'},
  {id:'copy',publication_id:'august',day:'2026-08-01',end_day:'2026-08-02',primary_id:'e'},
  {id:'combined',publication_id:'august',day:'2026-08-07',end_day:'2026-08-09',primary_id:'e'},
 ]};
 assert.deepEqual(publishedSwapDuties(raw,'2026-07','2026-07-01').map(d=>d.id),['friday','saturday']);
 assert.deepEqual(publishedSwapDuties(raw,'2026-08','2026-07-01').map(d=>d.id),['combined']);
});

test('admin proposals wait on both members, then the admin; the proposer sees and cancels them',()=>{
 const base={id:'p',month:'2026-11',requester_id:'a',other_id:'b',status:'awaiting_engineer',created_at:'2026-10-09',accepted_by:null,requester_accepted_at:null};
 const proposed={...base,proposed_by:'admin'};
 assert.equal(swapStarter(proposed),'admin');
 assert.equal(swapStarter(base),'a');
 assert.deepEqual(swapWaitingOn(proposed),['a','b']);
 assert.deepEqual(swapWaitingOn({...proposed,accepted_by:'b'}),['a']);
 assert.deepEqual(swapWaitingOn({...proposed,requester_accepted_at:'2026-10-09'}),['b']);
 // A requester who asked consented by sending; older rows have no proposal fields.
 assert.deepEqual(swapWaitingOn(base),['b']);
 assert.deepEqual(swapWaitingOn({...proposed,status:'awaiting_admin'}),[]);
 assert.equal(swapNeedsAction(proposed,'a',false),true);
 assert.equal(swapNeedsAction({...proposed,requester_accepted_at:'x'},'a',false),false);
 assert.equal(swapNeedsAction(proposed,'admin',true),false);
 assert.equal(swapNeedsAction({...proposed,status:'awaiting_admin'},'admin',true),true);
 assert.deepEqual(visibleSwapRequests([proposed],'admin',true).map(r=>r.id),['p']);
 assert.deepEqual(visibleSwapRequests([{...proposed,status:'approved'}],'admin',false).map(r=>r.id),['p']);
 assert.deepEqual(visibleSwapRequests([proposed],'c',true),[]);
});

test('an admin answers for a temporary member, never for anyone else, in resolve_swap order',()=>{
 // Decision 2026-11-01: temporary members have no account, so their open side goes to the admins.
 const base={id:'t',month:'2026-11',requester_id:'a',other_id:'tamar',status:'awaiting_engineer',created_at:'2026-10-09',accepted_by:null,requester_accepted_at:null};
 const temp=new Set(['tamar','noa']);
 assert.equal(swapAnswerFor(base,'admin',true,temp),'tamar');
 assert.equal(swapAnswerFor(base,'admin',false,temp),null);
 assert.equal(swapAnswerFor(base,'admin',true),null);
 assert.equal(swapAnswerFor(base,'a',false,temp),null);
 assert.equal(swapAnswerFor({...base,other_id:'b'},'admin',true,temp),null);
 assert.equal(swapAnswerFor({...base,accepted_by:'tamar'},'admin',true,temp),null);
 // Both parties temporary: the requester's side first, then the other's; the admin still approves after.
 const both={...base,requester_id:'noa',proposed_by:'admin'};
 assert.equal(swapAnswerFor(both,'admin',true,temp),'noa');
 assert.equal(swapAnswerFor({...both,requester_accepted_at:'x'},'admin',true,temp),'tamar');
 assert.equal(swapAnswerFor({...both,requester_accepted_at:'x',accepted_by:'tamar'},'admin',true,temp),null);
 assert.equal(swapAnswerFor({...both,status:'awaiting_admin'},'admin',true,temp),null);
 // An admin who is a party answers their own side first.
 assert.equal(swapAnswerFor({...base,requester_id:'tamar',other_id:'admin',proposed_by:'boss'},'admin',true,temp),'admin');
 assert.equal(swapNeedsAction(base,'admin',true,temp),true);
 assert.deepEqual(visibleSwapRequests([base],'admin',true,temp).map(r=>r.id),['t']);
 assert.deepEqual(visibleSwapRequests([base],'admin',true),[]);
 assert.deepEqual(visibleSwapRequests([base],'c',false,temp),[]);
});

test('availability conflicts carry who and when only; malformed responses fail closed',()=>{
 assert.deepEqual(readSwapConflicts([{member:'b',day:'2026-11-02',note:'ignored'}]),[{member:'b',day:'2026-11-02'}]);
 assert.deepEqual(readSwapConflicts([]),[]);
 assert.deepEqual(readSwapConflicts([{member:null,day:'2026-11-03'}]),[{member:null,day:'2026-11-03'}]);
 for(const bad of [null,{},[{member:'b'}],[{member:1,day:'2026-11-02'}],[{member:'b',day:'2 Nov'}]])assert.throws(()=>readSwapConflicts(bad));
});

test('approval summary names both members, dates and points moved in English and Hebrew',()=>{
 const input={requester:'Alex',other:'Blair',from:{label:'2 Nov 2026',points:1},to:{label:'7 Nov 2026 – 8 Nov 2026',points:1.5}};
 assert.equal(swapSummary({...input,lang:'en'}),[
  'Duty swap: Alex ⇄ Blair',
  'Alex — gives: 2 Nov 2026 (1 pt) · takes: 7 Nov 2026 – 8 Nov 2026 (1.5 pts) · change: +0.5 pts',
  'Blair — gives: 7 Nov 2026 – 8 Nov 2026 (1.5 pts) · takes: 2 Nov 2026 (1 pt) · change: −0.5 pts',
 ].join('\n'));
 const he=swapSummary({...input,lang:'he'}).split('\n');
 assert.equal(he[0],'החלפת כוננויות: Alex ⇄ Blair');
 assert.match(he[1],/מסירה: 2 Nov 2026 \(1 נק׳\) · קבלה: .*\(1.5 נק׳\) · שינוי: \+0.5 נק׳$/);
 assert.match(he[2],/שינוי: −0.5 נק׳$/);
 assert.match(swapSummary({...input,to:{label:'x',points:1},lang:'en'}),/change: 0 pts/);
});

test('swap target hints (#92): a primary’s own unavailability is red but pickable; cover and second weekends grey',()=>{
 const members=['me','dana','avi','cover'].map(id=>({id,name:id[0].toUpperCase()+id.slice(1),active:true,status:'approved'}));
 const source={id:'s',publication_id:'p',day:'2026-11-02',end_day:'2026-11-03',primary_id:'me',secondary_id:'cover'};
 const target={id:'t',publication_id:'p',day:'2026-11-04',end_day:'2026-11-05',primary_id:'dana',secondary_id:null};
 const raw={members,months:[{month:'2026-11',current_publication_id:'p'}],constraints:[],assignments:[source,target]};
 const block=c=>swapTargetBlock(raw,'2026-11',source,target,c);
 assert.equal(block([]),null);
 // Rule 1: either primary's own constraint never blocks; it warns, the swap's own person first.
 const party=[{member:'dana',day:'2026-11-02'},{member:'me',day:'2026-11-04'}];
 assert.equal(block(party),null);
 assert.deepEqual(swapTargetWarning(source,target,party),{person:'me',day:'2026-11-04'});
 assert.deepEqual(swapTargetWarning(source,target,[{member:'dana',day:'2026-11-02'}]),{person:'dana',day:'2026-11-02'});
 assert.equal(swapTargetWarning(source,target,[]),null);
 // Emergency cover's unavailability still greys the day, anonymous or named (admins).
 assert.deepEqual(block([{member:null,day:'2026-11-02'}]),{kind:'cover',person:null,day:'2026-11-02'});
 assert.deepEqual(block([...party,{member:'cover',day:'2026-11-02'}]),{kind:'cover',person:'cover',day:'2026-11-02'});
 assert.deepEqual(coverConflicts([...party,{member:'cover',day:'2026-11-02'}],source,target),[{member:'cover',day:'2026-11-02'}]);
 // Emergency cover who left the team blocks every pair, as validate_swap does.
 assert.deepEqual(swapTargetBlock({...raw,members:members.map(m=>m.id==='cover'?{...m,active:false}:m)},'2026-11',source,target,[]),{kind:'inactive'});
 // A second weekend is checked locally from the published rows.
 const friday={id:'f',publication_id:'p',day:'2026-11-06',end_day:'2026-11-08',primary_id:'dana',secondary_id:null};
 const mine={id:'w',publication_id:'p',day:'2026-11-13',end_day:'2026-11-15',primary_id:'me',secondary_id:null};
 assert.deepEqual(swapTargetBlock({...raw,assignments:[source,friday,mine]},'2026-11',source,friday,[]),{kind:'weekend',person:'me'});
});

test('swap hint text says who and which day, never the note, for engineers and admins in both languages',()=>{
 const names={me:'Me',dana:'Dana',avi:'Avi'},day=d=>d.slice(8);
 const say=(block,me,lang='en')=>swapBlockText(block,{me,name:id=>names[id],day,lang});
 assert.equal(say({kind:'cover',person:null,day:'2026-11-02'},'me'),'Emergency cover can’t take 02');
 assert.equal(say({kind:'cover',person:'avi',day:'2026-11-02'},'admin'),'Avi can’t cover 02');
 assert.equal(say({kind:'weekend',person:'dana'},'admin'),'This would give Dana a second weekend');
 assert.equal(say({kind:'past'},'me'),'This day has passed');
 // #92 red days: "you marked" for yourself, names for others; never the note.
 const warn=(w,me,lang='en')=>swapWarningText(w,{me,name:id=>names[id],day,lang});
 assert.equal(warn({person:'me',day:'2026-11-04'},'me'),'You marked 04 as unavailable');
 assert.equal(warn({person:'dana',day:'2026-11-02'},'me'),'Dana marked 02 as unavailable');
 assert.equal(warn({person:'me',day:'2026-11-04'},'me','he'),'סימנת את 04 כלא זמין');
 assert.equal(warn({person:'dana',day:'2026-11-02'},'admin','he'),'Dana סימן/ה את 02 כלא זמין');
 // Admins always read the note (owner review of #103).
 assert.equal(swapWarningText({person:'dana',day:'2026-11-02'},{me:'admin',name:id=>names[id],day,lang:'he',note:'Dentist'}),'Dana · 02: Dentist');
});

test('#92 consent: the answering member sees their own unavailable date; admins read each party’s note',()=>{
 const r={requester_id:'me',other_id:'dana',from_day:'2026-11-02',from_end_day:'2026-11-03',to_day:'2026-11-04',to_end_day:'2026-11-05'};
 const raw={constraints:[{member_id:'dana',day:'2026-11-02',kind:'no',note:'Secret'},{member_id:'me',day:'2026-11-04',kind:'prefer',note:''}]};
 // Rule 2: Dana takes 2 Nov, which she marked unavailable; a preference is not unavailability.
 assert.equal(swapOwnConflict(raw,r,'dana'),'2026-11-02');
 assert.equal(swapOwnConflict(raw,r,'me'),null);
 // Admin view: each party's constraint on the duty they take, with its note.
 const notes={...raw,constraints:[...raw.constraints,{member_id:'me',day:'2026-11-04',kind:'no',note:''},{member_id:'me',day:'2026-11-02',kind:'no',note:'Own day'}]};
 assert.deepEqual(swapPartyConstraints(notes,r).map(c=>noteLabel(c.member_id,c.day,c.note,{name:id=>id,day:d=>d.slice(8)})),['dana · 02: Secret','me · 04']);
});
