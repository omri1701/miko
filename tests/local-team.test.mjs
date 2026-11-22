import test from 'node:test';
import assert from 'node:assert/strict';
import {LOCAL_TEMPORARY_MEMBERS,missingTemporaryMembers,localPastConstraints} from '../scripts/local-supabase.mjs';

test('local reset team adds ten named temporary members in seniority order and skips existing names',()=>{
 assert.deepEqual(LOCAL_TEMPORARY_MEMBERS,['Avi','Dana','Yossi','Noa','Eitan','Maya','Lior','Tamar','Omer','Shira']);
 assert.deepEqual(missingTemporaryMembers([{name:'Local Admin'}]),LOCAL_TEMPORARY_MEMBERS);
 assert.deepEqual(missingTemporaryMembers(LOCAL_TEMPORARY_MEMBERS.slice(0,8).map(name=>({name}))),['Omer','Shira']);
 assert.deepEqual(missingTemporaryMembers(LOCAL_TEMPORARY_MEMBERS.map(name=>({name}))),[]);
});

test('#105 rule 8: local reset adds passed constraints with notes, a long one and a block across the month edge',()=>{
 const members=['Local Admin','Local Engineer','Avi','Dana'].map((name,i)=>({id:`m${i}`,name}));
 const seeded=localPastConstraints('2026-11-22',members);
 const days=seeded.flatMap(c=>c.days);
 assert.ok(days.every(d=>d<'2026-11-22'),'all passed');
 assert.ok(seeded.some(c=>c.note.length>80),'a long note');
 const edge=seeded.find(c=>c.days.length>2);
 assert.deepEqual(edge.days,['2026-10-30','2026-10-31','2026-11-01','2026-11-02']);
 assert.ok(edge.note);
 assert.ok(seeded.every(c=>['no','prefer'].includes(c.kind)&&c.member));
 assert.deepEqual(localPastConstraints('2026-11-22',[]),[]);
});
