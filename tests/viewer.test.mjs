import test from 'node:test';
import assert from 'node:assert/strict';
import {fromSnapshot,canManage,isViewer,readSnapshot} from '../lib/supabase/snapshot.ts';
import {takesDuties,blocks} from '../lib/rota/engine.ts';
import {workspaceMetrics} from '../lib/rota/workspace-data.ts';
import {publishedSwapDuties,swapTargetBlock} from '../lib/supabase/swaps.ts';

// Viewer members (#90): the database enforces every rule (supabase/tests/viewer.sql); the app
// mirrors it so a Viewer is never offered as a person to schedule and sees no edit actions.
const member=(id,extra={})=>({id,email:id+'@example.invalid',name:id,role:'engineer',status:'approved',active:true,seniority:1,color:'#adc9ee',...extra});
const row=(day,primary,publication,extra={})=>({id:day+publication,publication_id:publication,day,end_day:day.slice(0,8)+String(Number(day.slice(8))+1).padStart(2,'0'),primary_id:primary,secondary_id:null,manager_override:false,title:'',extra_points:0,points:1,...extra});
function fixture(){
 return {revision:1,members:[member('admin',{role:'admin'}),member('boss',{role:'admin',viewer:true}),member('eve',{viewer:true}),member('engineer')],
  months:[{month:'2099-10',deadline:'2099-09-24',status:'published',generated:true,current_publication_id:'p',publication_sequence:1}],constraints:[],
  assignments:[row('2099-10-05','engineer','p'),row('2099-10-06','eve','p'),row('2099-10-07','engineer','p',{secondary_id:'eve'})],
  publications:[{id:'p',month:'2099-10',version:1,published_at:'2099-09-30T00:00:00Z',published_by:'admin'}],
  roles:[{code:'admin',label:'Admin',can_manage:true},{code:'engineer',label:'Engineer',can_manage:false}],memberStatuses:[],monthStatuses:[],constraintTypes:[]};
}

test('the viewer flag is read, optional for older rows, and carried onto the team',()=>{
 const raw=readSnapshot(fixture());
 const state=fromSnapshot(raw,'engineer');
 assert.deepEqual(state.team.filter(p=>p.viewer).map(p=>p.id),['boss','eve']);
 assert.equal('viewer' in state.team.find(p=>p.id==='engineer'),false,'non-Viewers carry no flag');
 const old=fixture();delete old.members[2].viewer;assert.doesNotThrow(()=>readSnapshot(old));
 const bad=fixture();bad.members[2].viewer='yes';assert.throws(()=>readSnapshot(bad),/Invalid team data/);
});

test('a Viewer-admin keeps admin views but is a Viewer; a Viewer is never scheduled',()=>{
 const raw=readSnapshot(fixture());
 assert.equal(canManage(raw,'boss'),true);assert.equal(isViewer(raw,'boss'),true);
 assert.equal(isViewer(raw,'admin'),false);assert.equal(isViewer(raw,'eve'),true);
 assert.equal(takesDuties({id:'x',name:'x',color:'#000000',active:true,viewer:true}),false);
 assert.equal(takesDuties({id:'x',name:'x',color:'#000000',active:true}),true);
 assert.equal(takesDuties({id:'x',name:'x',color:'#000000',active:false}),false);
 const state=fromSnapshot(raw,'admin');
 assert.deepEqual(workspaceMetrics(state,'2099-10',blocks('2099-10',state.specials,state.splitWeekends)).active.map(p=>p.id),['admin','engineer']);
});

test('swaps never offer a Viewer\'s duty or a pair covered by a Viewer',()=>{
 const raw=readSnapshot(fixture());
 assert.deepEqual(publishedSwapDuties(raw,'2099-10','2099-10-01').map(r=>r.day),['2099-10-05','2099-10-07']);
 const [a,,c]=raw.assignments;
 assert.deepEqual(swapTargetBlock(raw,'2099-10',a,c,[]),{kind:'inactive'});
});
