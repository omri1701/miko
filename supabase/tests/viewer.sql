-- Synthetic fixtures only, on an empty disposable LOCAL database. Always rolls back.
-- Viewer members (#90, decisions 2026-11-20): only an admin sets the flag, through the checked
-- RPC. A Viewer sees the schedule but is never scheduled, adds no constraints and takes no part
-- in the ledger; becoming one works like deactivation (duties stay; publishing refuses them).
-- A Viewer-admin reads like an admin but every checked write refuses them. Only Viewer-admins
-- are notified.
begin;
do $$begin
 if exists(select 1 from auth.users) or exists(select 1 from public.duty_members) then raise exception 'Requires empty disposable LOCAL'; end if;
end$$;
-- 1 admin, 2 admin (becomes a Viewer-admin), 3 engineer (becomes a Viewer), 4 and 5 engineers, 6 pending.
insert into auth.users(id,email,email_confirmed_at,is_anonymous) select
 ('77000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'viewer-test-'||i||'@example.invalid',now(),false from generate_series(1,6) i;
insert into public.duty_members(id,email,name,role,status,active,seniority) select id,email,'Viewer '||right(id::text,1),
 case when right(id::text,1) in ('1','2') then 'admin' else 'engineer' end,
 case when right(id::text,1)='6' then 'pending' else 'approved' end,true,right(id::text,1)::integer from auth.users;
insert into public.duty_members(id,name,is_temporary,status,active,seniority) values('77000000-0000-0000-0000-000000000007','Temporary','true','approved',true,7);
create function pg_temp.must_fail(command text, pattern text) returns void language plpgsql as $$begin
 begin execute command; exception when others then
  if sqlerrm !~ pattern then raise exception 'Unexpected refusal: %, expected %',sqlerrm,pattern;end if;return;
 end;raise exception 'Unexpected acceptance: %',command;
end$$;
create function pg_temp.check(ok boolean, message text) returns void language plpgsql as $$begin
 if ok is not true then raise exception 'Failed: %',message; end if;
end$$;
create function pg_temp.member_event(p_member text) returns boolean language sql as $$
 select (m->>'active')::boolean from public.duty_compensation_events e cross join lateral jsonb_array_elements(e.operation->'members') m
 where e.operation->>'kind'='members' and m->>'id'=p_member order by e.sequence desc limit 1 $$;
grant execute on function pg_temp.must_fail(text,text), pg_temp.check(boolean,text) to anon, authenticated;
select pg_temp.check(not exists(select 1 from public.duty_members where viewer),'nobody is a Viewer by default');

set local role anon;
select pg_temp.must_fail($c$select public.duty_set_viewer('77000000-0000-0000-0000-000000000003',true,0)$c$,'permission denied');
reset role;
set local role authenticated;
-- An engineer sets it for nobody, themself included, and never writes the column directly.
set local request.jwt.claim.sub='77000000-0000-0000-0000-000000000004';
select pg_temp.must_fail($c$select public.duty_set_viewer('77000000-0000-0000-0000-000000000003',true,(select revision from public.duty_workspace))$c$,'Admin access required');
select pg_temp.must_fail($c$select public.duty_set_viewer('77000000-0000-0000-0000-000000000004',true,(select revision from public.duty_workspace))$c$,'Admin access required');
select pg_temp.must_fail($c$select duty_private.set_viewer('77000000-0000-0000-0000-000000000004',true,(select revision from public.duty_workspace))$c$,'Admin access required');
select pg_temp.must_fail($c$update public.duty_members set viewer=true where id='77000000-0000-0000-0000-000000000004'$c$,'permission denied');
set local request.jwt.claim.sub='77000000-0000-0000-0000-000000000001';
select pg_temp.must_fail($c$update public.duty_members set viewer=true where id='77000000-0000-0000-0000-000000000003'$c$,'permission denied');
select pg_temp.must_fail($c$select public.duty_set_viewer('77000000-0000-0000-0000-000000000003',true,-1)$c$,'team data changed');
select pg_temp.must_fail($c$select public.duty_set_viewer('77000000-0000-0000-0000-000000000006',true,(select revision from public.duty_workspace))$c$,'Approve this member first');
select pg_temp.must_fail($c$select public.duty_set_viewer('77000000-0000-0000-0000-000000000007',true,(select revision from public.duty_workspace))$c$,'temporary member cannot be a Viewer');
select pg_temp.must_fail($c$select public.duty_set_viewer('77000000-0000-0000-0000-000000000003',null,(select revision from public.duty_workspace))$c$,'Choose whether');

-- October is published while member 3 still takes part: 4 on odd days, 5 on even days, 3 on the 10th.
do $$declare rev bigint; schedule jsonb;begin
 select revision into rev from public.duty_workspace;
 select jsonb_build_object('team','[]'::jsonb,'months',jsonb_build_object('2099-10',jsonb_build_object('deadline','2099-09-25','status','draft','generated',true)),
  'duties',jsonb_agg(jsonb_build_object('day',d::date,'end_day',d::date+1,'primary_id',case when d::date='2099-10-10' then '77000000-0000-0000-0000-000000000003'
   when extract(day from d)::integer%2=1 then '77000000-0000-0000-0000-000000000004' else '77000000-0000-0000-0000-000000000005' end)))
 into schedule from generate_series('2099-10-01'::date,'2099-10-31'::date,interval '1 day') d;
 perform public.duty_save_schedule(schedule,rev,'2099-10');
end$$;
-- Member 4 offers 1 October for member 3's 10 October.
set local request.jwt.claim.sub='77000000-0000-0000-0000-000000000004';
select public.duty_request_swap((select id from public.duty_assignments where day='2099-10-01' and publication_id is not null),
 (select id from public.duty_assignments where day='2099-10-10' and publication_id is not null),'',(select revision from public.duty_workspace));

-- Rule 1: making member 3 a Viewer.
set local request.jwt.claim.sub='77000000-0000-0000-0000-000000000001';
-- A teammate's constraint with a private note (read by the Viewer-admin below). The admin enters
-- it: 2099 is past a member's own three-month window (#111).
select public.duty_set_constraints('77000000-0000-0000-0000-000000000004',array['2099-11-05'::date],'no','Private fixture note',(select revision from public.duty_workspace));
create temp table before_revision as select revision from public.duty_workspace;
select public.duty_set_viewer('77000000-0000-0000-0000-000000000003',true,(select revision from public.duty_workspace));
select pg_temp.check((select revision from public.duty_workspace)=(select revision+1 from before_revision),'setting advances the revision');
select pg_temp.check((select viewer from public.duty_members where id='77000000-0000-0000-0000-000000000003'),'setting stored');
select pg_temp.check(public.duty_load()->'members' @> '[{"id":"77000000-0000-0000-0000-000000000003","viewer":true}]','setting loaded');
-- Like deactivation: the open swap is invalidated, the published duty stays, the ledger freezes them.
select pg_temp.check((select primary_id from public.duty_assignments a join public.duty_months m on m.current_publication_id=a.publication_id where a.day='2099-10-10')='77000000-0000-0000-0000-000000000003','scheduled duties stay');
reset role;
select pg_temp.check((select status from public.duty_swap_requests)='invalidated','a Viewer holds no swap open');
select pg_temp.check(pg_temp.member_event('77000000-0000-0000-0000-000000000003') is false,'ledger: no points or debts for a Viewer');
-- Generate and Plan the month leave a Viewer out.
do $$declare f jsonb:=duty_private.generation_facts('2099-11');begin
 if not f->'members' @> '[{"id":"77000000-0000-0000-0000-000000000003","eligible":false,"active":true}]' or f->'seniority' ? '77000000-0000-0000-0000-000000000003'
  or not f->'seniority' ? '77000000-0000-0000-0000-000000000004' then raise exception 'Generation facts: %',f; end if;
end$$;
set local role authenticated;
-- Never scheduled: a swap onto a Viewer's duty, or a published edit to a Viewer, is refused.
set local request.jwt.claim.sub='77000000-0000-0000-0000-000000000004';
select pg_temp.must_fail($c$select public.duty_request_swap((select id from public.duty_assignments where day='2099-10-01' and publication_id is not null),
 (select id from public.duty_assignments where day='2099-10-10' and publication_id is not null),'',(select revision from public.duty_workspace))$c$,'no longer active');
set local request.jwt.claim.sub='77000000-0000-0000-0000-000000000001';
select pg_temp.must_fail($c$select public.duty_edit_published_duty((select current_publication_id from public.duty_months where month='2099-10'),'2099-10-03',
 '77000000-0000-0000-0000-000000000003',0,0,'temporary',(select revision from public.duty_workspace),'')$c$,'Choose an active approved engineer');
-- A draft keeps a Viewer's duty (the admin reassigns by hand), but publishing refuses it.
do $$declare rev bigint; schedule jsonb;begin
 select revision into rev from public.duty_workspace;
 select jsonb_build_object('team','[]'::jsonb,'months',jsonb_build_object('2099-11',jsonb_build_object('deadline','2099-10-25','status','draft','generated',true)),
  'duties',jsonb_agg(jsonb_build_object('day',d::date,'end_day',d::date+1,'primary_id',case when d::date='2099-11-10' then '77000000-0000-0000-0000-000000000003'
   else '77000000-0000-0000-0000-000000000005' end)))
 into schedule from generate_series('2099-11-01'::date,'2099-11-30'::date,interval '1 day') d;
 perform public.duty_save_schedule(schedule,rev);
 select revision into rev from public.duty_workspace;
 begin perform public.duty_save_schedule(schedule,rev,'2099-11'); raise exception 'Viewer published';
 exception when others then if sqlerrm !~ 'An active engineer is required on 2099-11-10' then raise; end if; end;
end$$;
-- No constraints for a Viewer, from themself or from an admin.
select pg_temp.must_fail($c$select public.duty_set_constraints('77000000-0000-0000-0000-000000000003',array['2099-11-06'::date],'no','',(select revision from public.duty_workspace))$c$,'Viewers have no constraints');
set local request.jwt.claim.sub='77000000-0000-0000-0000-000000000003';
select pg_temp.must_fail($c$select public.duty_set_constraints('77000000-0000-0000-0000-000000000003',array['2099-11-06'::date],'prefer','',(select revision from public.duty_workspace))$c$,'Viewers have no constraints');
-- A Viewer still signs in and sees the published schedule, never drafts or others' notes.
select pg_temp.check(duty_private.is_member(),'a Viewer keeps member access');
select pg_temp.check(not duty_private.is_overseer(),'an engineer Viewer is no overseer');
select pg_temp.check((select count(*) from public.duty_assignments where publication_id is not null)=31,'published schedule visible');
select pg_temp.check(not exists(select 1 from public.duty_assignments where publication_id is null),'drafts hidden');
select pg_temp.check(not exists(select 1 from public.duty_constraints),'others'' constraints hidden');

-- Rule 3: member 2 becomes a read-only Viewer-admin; the last admin who can manage stays.
-- First, as an admin, member 2 proposes a swap between members 4 and 5.
set local request.jwt.claim.sub='77000000-0000-0000-0000-000000000002';
select public.duty_request_swap((select id from public.duty_assignments where day='2099-10-03' and publication_id is not null),
 (select id from public.duty_assignments where day='2099-10-04' and publication_id is not null),'',(select revision from public.duty_workspace));
create temp table proposal as select id from public.duty_swap_requests where proposed_by='77000000-0000-0000-0000-000000000002';
set local request.jwt.claim.sub='77000000-0000-0000-0000-000000000001';
select public.duty_set_viewer('77000000-0000-0000-0000-000000000002',true,(select revision from public.duty_workspace));
reset role;
select pg_temp.check((select status from public.duty_swap_requests where id=(select id from proposal))='invalidated','a Viewer-admin''s proposal is invalidated');
set local role authenticated;
set local request.jwt.claim.sub='77000000-0000-0000-0000-000000000002';
select pg_temp.must_fail($c$select public.duty_resolve_swap((select id from proposal),'cancel',(select revision from public.duty_workspace))$c$,'.');
set local request.jwt.claim.sub='77000000-0000-0000-0000-000000000001';
select pg_temp.must_fail($c$select public.duty_set_viewer('77000000-0000-0000-0000-000000000001',true,(select revision from public.duty_workspace))$c$,'Keep at least one active admin');
select pg_temp.must_fail($c$select public.duty_set_role('77000000-0000-0000-0000-000000000001','engineer',(select revision from public.duty_workspace))$c$,'Keep at least one active admin');
set local request.jwt.claim.sub='77000000-0000-0000-0000-000000000002';
select pg_temp.check(not duty_private.is_manager() and duty_private.is_overseer(),'Viewer-admin reads, never manages');
-- Sees everything admins see: drafts, everyone's constraints and notes, approvals, balances, versions.
select pg_temp.check(exists(select 1 from public.duty_assignments where publication_id is null),'Viewer-admin sees drafts');
select pg_temp.check((select note from public.duty_constraints where member_id='77000000-0000-0000-0000-000000000004')='Private fixture note','Viewer-admin sees constraint notes');
select pg_temp.check(exists(select 1 from public.duty_members where status='pending'),'Viewer-admin sees pending approvals');
select pg_temp.check(exists(select 1 from public.duty_compensation_events),'Viewer-admin reads the ledger');
select pg_temp.check((select count(*) from jsonb_object_keys(public.duty_balance()->'net'))>1,'Viewer-admin sees every balance');
select public.duty_replanned_versions('2099-10');
-- ...but cannot edit, generate, publish or approve.
select pg_temp.must_fail($c$select public.duty_review_member('77000000-0000-0000-0000-000000000006','approved',(select revision from public.duty_workspace))$c$,'Admin access required');
select pg_temp.must_fail($c$select public.duty_save_schedule(jsonb_build_object('team','[]'::jsonb,'duties','[]'::jsonb,'months','{}'::jsonb),(select revision from public.duty_workspace))$c$,'Admin access required');
select pg_temp.must_fail($c$select public.duty_save_schedule(jsonb_build_object('team','[]'::jsonb,'duties','[]'::jsonb,'months',jsonb_build_object('2099-11',jsonb_build_object('deadline','2099-10-25','status','draft','generated',true))),(select revision from public.duty_workspace),'2099-11')$c$,'Admin access required');
select pg_temp.must_fail($c$select public.duty_generation_context('2099-11',(select revision from public.duty_workspace))$c$,'Admin access required');
select pg_temp.must_fail($c$select public.duty_cancel_draft('2099-11',(select revision from public.duty_workspace))$c$,'Admin access required');
select pg_temp.must_fail($c$select public.duty_set_viewer('77000000-0000-0000-0000-000000000003',false,(select revision from public.duty_workspace))$c$,'Admin access required');
select pg_temp.must_fail($c$select public.duty_set_no_weekends('77000000-0000-0000-0000-000000000004',true,(select revision from public.duty_workspace))$c$,'Admin access required');
select pg_temp.must_fail($c$select public.duty_set_role('77000000-0000-0000-0000-000000000004','admin',(select revision from public.duty_workspace))$c$,'Admin access required');
select pg_temp.must_fail($c$select public.duty_edit_published_duty((select current_publication_id from public.duty_months where month='2099-10'),'2099-10-03',
 '77000000-0000-0000-0000-000000000005',0,0,'temporary',(select revision from public.duty_workspace),'')$c$,'Admin access required');
select pg_temp.must_fail($c$select public.duty_set_constraints('77000000-0000-0000-0000-000000000004',array['2099-11-07'::date],'no','',(select revision from public.duty_workspace))$c$,'Not allowed');
select pg_temp.must_fail($c$select public.duty_set_constraints('77000000-0000-0000-0000-000000000002',array['2099-11-07'::date],'no','',(select revision from public.duty_workspace))$c$,'Viewers have no constraints');
select pg_temp.must_fail($c$select public.duty_request_swap((select id from public.duty_assignments where day='2099-10-01' and publication_id is not null),
 (select id from public.duty_assignments where day='2099-10-02' and publication_id is not null),'',(select revision from public.duty_workspace))$c$,'Choose your own primary duty');
select pg_temp.must_fail($c$update public.duty_members set viewer=false where id='77000000-0000-0000-0000-000000000002'$c$,'permission denied');
reset role;

-- Notifications: of the Viewers, only the Viewer-admin is notified; no deadline reminders for Viewers.
insert into public.duty_push_subscriptions(member_id,endpoint,p256dh,auth) select id,'https://fcm.googleapis.com/fcm/send/viewer-'||right(id::text,1),repeat('B',87),repeat('A',22)
 from public.duty_members where id in ('77000000-0000-0000-0000-000000000002','77000000-0000-0000-0000-000000000003','77000000-0000-0000-0000-000000000004');
select pg_temp.check(not duty_private.push_enqueue('77000000-0000-0000-0000-000000000003','published','viewer-test-3','{}','/?tab=schedule'),'a Viewer gets no notifications');
select pg_temp.check(duty_private.push_enqueue('77000000-0000-0000-0000-000000000002','published','viewer-test-2','{}','/?tab=schedule'),'a Viewer-admin is notified');
select pg_temp.check(duty_private.push_enqueue('77000000-0000-0000-0000-000000000004','published','viewer-test-4','{}','/?tab=schedule'),'others unchanged');
insert into public.duty_months(month,deadline) values('2099-12','2099-11-24');
select duty_private.push_schedule(('2099-11-21 10:30')::timestamp at time zone 'Asia/Jerusalem');
select pg_temp.check((select array_agg(member_id::text order by member_id) from public.duty_push_notifications where kind='deadline_3')='{77000000-0000-0000-0000-000000000004}','deadline reminders skip Viewers');

-- Clearing the setting brings the member back into the ledger and generation.
set local role authenticated;
set local request.jwt.claim.sub='77000000-0000-0000-0000-000000000001';
select public.duty_set_viewer('77000000-0000-0000-0000-000000000003',false,(select revision from public.duty_workspace));
reset role;
select pg_temp.check(pg_temp.member_event('77000000-0000-0000-0000-000000000003') is true,'ledger: rejoins when no longer a Viewer');
select pg_temp.check(duty_private.generation_facts('2099-11')->'seniority' ? '77000000-0000-0000-0000-000000000003','eligible again');
rollback;
