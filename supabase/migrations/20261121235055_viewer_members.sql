-- Viewer members (#90, decisions 2026-11-20). Expand-only: a new column (false for everyone,
-- so nothing changes for existing members), one new read helper and one checked RPC.
-- * A Viewer sees the schedule but is never scheduled, adds no constraints and gets no points
--   or debts. Making a member a Viewer works like deactivating them: duties already scheduled
--   stay (publishing refuses them until reassigned by hand), the ledger freezes them and their
--   open swaps are invalidated.
-- * A Viewer-admin is a read-only admin: duty_private.is_manager() (every checked write) is
--   false for them; the new duty_private.is_overseer() keeps their admin reads (RLS policies,
--   balances, replanned versions). At least one admin who is not a Viewer must remain.
-- * Notifications: of the Viewers, only Viewer-admins are notified; no deadline reminders.

-- Source: schemas/tables/duty_members.sql
ALTER TABLE public.duty_members ADD COLUMN viewer boolean DEFAULT false NOT NULL;

-- Source: schemas/functions/duty_private/is_overseer.sql
-- Admin reads (decision 2026-11-20, #90): every approved, active admin, including a
-- read-only Viewer-admin, sees what admins see (drafts, everyone's constraints and notes,
-- plans, balances, pending approvals). Never use it to authorize a write: use is_manager().
CREATE FUNCTION duty_private.is_overseer() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
 select auth.uid() is not null and exists(select 1 from public.duty_members m join public.duty_roles r on r.code=m.role where m.auth_user_id=auth.uid() and r.can_manage and m.status='approved' and m.active)
$$;

REVOKE ALL ON FUNCTION duty_private.is_overseer() FROM PUBLIC, anon, authenticated, service_role;
GRANT ALL ON FUNCTION duty_private.is_overseer() TO authenticated;

-- Source: schemas/functions/duty_private/is_manager.sql
-- Admin write authority. A Viewer-admin (#90) is never a manager: every checked write
-- refuses them; their admin reads use duty_private.is_overseer().
CREATE OR REPLACE FUNCTION duty_private.is_manager() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
 select auth.uid() is not null and exists(select 1 from public.duty_members m join public.duty_roles r on r.code=m.role where m.auth_user_id=auth.uid() and r.can_manage and m.status='approved' and m.active and not m.viewer)
$$;

-- Source: schemas/functions/duty_private/assert_admin_remains.sql
CREATE OR REPLACE FUNCTION duty_private.assert_admin_remains() RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if not exists(select 1 from public.duty_members m join public.duty_roles r on r.code=m.role where m.active and m.status='approved' and r.can_manage and not m.viewer) then raise exception 'Keep at least one active admin'; end if;
end $$;

-- Source: schemas/functions/duty_private/set_viewer.sql
-- Viewer (decision 2026-11-20, #90): an admin makes an approved member a Viewer, who sees the
-- schedule but is never scheduled, adds no constraints and gets no points or debts. Like
-- deactivating: duties already scheduled stay where they are (publishing refuses them until
-- the admin reassigns them by hand), the ledger freezes the member (compensation_members) and
-- their open swaps are invalidated (reconcile_member_swaps). An admin who is a Viewer keeps
-- admin reads only, so at least one admin who is not a Viewer must remain.
CREATE FUNCTION duty_private.set_viewer(p_member uuid, p_viewer boolean, p_revision bigint) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
begin
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 perform duty_private.check_revision(p_revision);
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 if p_viewer is null then raise exception 'Choose whether this member is a Viewer'; end if;
 if exists(select 1 from public.duty_members where id=p_member and is_temporary) then raise exception 'A temporary member cannot be a Viewer'; end if;
 update public.duty_members set viewer=p_viewer where id=p_member and status='approved';
 if not found then raise exception 'Approve this member first'; end if;
 perform duty_private.assert_admin_remains();
 -- A Viewer-admin holds no swap open either: one they proposed as an admin is invalidated too
 -- (their own requests already are, by duty_reconcile_member_swaps).
 if p_viewer then
  update public.duty_swap_requests set status='invalidated',accepted_by=null,accepted_at=null,resolved_at=now(),resolved_by=null
  where proposed_by=p_member and status in ('awaiting_engineer','awaiting_admin');
 end if;
 update public.duty_workspace set revision=revision+1 where id;
end $$;

-- Source: schemas/functions/public/duty_set_viewer.sql
CREATE FUNCTION public.duty_set_viewer(p_member uuid, p_viewer boolean, p_revision bigint) RETURNS void
 LANGUAGE sql SET search_path TO '' AS $$select duty_private.set_viewer(p_member,p_viewer,p_revision)$$;

REVOKE ALL ON FUNCTION duty_private.set_viewer(uuid, boolean, bigint) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION duty_private.set_viewer(uuid, boolean, bigint) TO authenticated;
REVOKE ALL ON FUNCTION public.duty_set_viewer(uuid, boolean, bigint) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.duty_set_viewer(uuid, boolean, bigint) TO authenticated;

-- Source: schemas/functions/duty_private/balance.sql
-- Read-only display projection. Due and future published work is simulated on
-- a private copy; nothing is appended and the workspace revision never changes.
-- Members receive only their own relationships; audit events/reasons never leave.
CREATE OR REPLACE FUNCTION duty_private.balance() RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
#variable_conflict use_column
declare me text; manager boolean; actual jsonb; projected jsonb; instant bigint; lines jsonb; net jsonb;
begin
 if not duty_private.is_member() then raise exception 'Member access required' using errcode='42501'; end if;
 me:=duty_private.current_member_id()::text; manager:=duty_private.is_overseer();
 actual:=duty_private.compensation_state();
 instant:=greatest(duty_private.compensation_now(),coalesce((actual->'events'->-1->>'at')::bigint,0));
 actual:=duty_private.compensation_reconcile(actual,instant,false);
 projected:=duty_private.compensation_reconcile(actual,9007199254740991,false);
 with source as (
  -- Open actual relationships, described by their originating lot.
  select c->>'debtorId' debtor,c->>'creditorId' creditor,(c->>'units')::bigint units,
   case when jsonb_array_length(c->'path')>1 then 'routed'
    when lot ? 'correctionOf' then 'correction'
    -- A server-compiled allocation intent leg whose first counterpart is system uneven-month credit.
    when starts_with(lot->>'id',(lot->>'sourceKey')||'/intent/allocation/') and starts_with(coalesce(actual->'intents'->regexp_replace(substr(lot->>'id',length(lot->>'sourceKey')+9),'/route/[0-9]+$','')
     ->'route'->(substring(lot->>'id' from '/route/([0-9]+)$')::integer)->'transferIds'->>0,''),'uneven/') then 'uneven'
    when starts_with(lot->>'id',(lot->>'sourceKey')||'/intent/') then 'temporary'
    when starts_with(lot->>'id',(lot->>'sourceKey')||'/transfer/') then 'change'
    when lot->>'sourceKey' like 'manual/%' then 'manual' else 'other' end kind,
   case when jsonb_array_length(c->'path')=1 and starts_with(lot->>'id',(lot->>'sourceKey')||'/intent/') then
    (select min(p->>'date') from jsonb_array_elements(actual->'intents'->regexp_replace(substr(lot->>'id',length(lot->>'sourceKey')+9),'/route/[0-9]+$','')->'capacity') p) end AS day,
   case when jsonb_array_length(c->'path')=1 and starts_with(lot->>'id',(lot->>'sourceKey')||'/transfer/') then
    (select e->'operation'->>'month' from jsonb_array_elements(actual->'events') e where e->>'sourceKey'=lot->>'sourceKey' limit 1) end AS month
  from jsonb_array_elements(actual->'claims') c cross join lateral (select actual->'lots'->(c->'path'->0->>'lotId') lot) l
  union all
  -- Published repayments that settle only in the projection.
  select r->'claim'->>'debtorId',r->'claim'->>'creditorId',-(r->>'units')::bigint,'repayment',
   projected->'contributions'->(r->>'contributionId')->'capacity'->>'date',null
  from jsonb_each(projected->'settlements') x(id,r) where not (actual->'settlements' ? x.id) and r ? 'contributionId'
 ), side as (
  select creditor member,debtor counterpart,units,kind,day,month from source
  union all select debtor,creditor,-units,kind,day,month from source
 ), visible as (
  select * from side where manager or member=me
 ), relationship as (
  select member,counterpart from visible group by member,counterpart having sum(units)<>0
 )
 select coalesce(jsonb_agg(jsonb_build_object('memberId',v.member,'counterpartId',v.counterpart,'units',v.units,'kind',v.kind,'date',v.day,'month',v.month)
  order by v.member COLLATE "C",v.counterpart COLLATE "C",coalesce(v.day,v.month) COLLATE "C" nulls first,v.kind COLLATE "C",v.units),'[]')
 into lines from visible v join relationship o using(member,counterpart);
 net:=coalesce((select jsonb_object_agg(m.key,coalesce((select sum(case when c->>'creditorId'=m.key then (c->>'units')::bigint else -(c->>'units')::bigint end)
  from jsonb_array_elements(projected->'claims') c where m.key in (c->>'debtorId',c->>'creditorId')),0))
  from jsonb_each(projected->'members') m where manager or m.key=me),'{}');
 return jsonb_build_object('net',net,'lines',lines);
end $$;

-- Source: schemas/functions/duty_private/replanned_versions.sql
-- The month's versions a re-plan reversed (decision 2026-11-01), so Versions disables
-- restoring them, and deleting the live version when that would bring one back, before
-- the click. Admin-only and read-only (Viewer-admins too): ids of publications admins already see.
CREATE OR REPLACE FUNCTION duty_private.replanned_versions(p_month text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
declare s jsonb;
begin
 if not duty_private.is_overseer() then raise exception 'Admin access required' using errcode='42501'; end if;
 s:=duty_private.compensation_state();
 return coalesce((select jsonb_agg(p.id order by p.version) from public.duty_publications p
  where p.month=p_month and duty_private.compensation_replanned(s,p.month,p.id)),'[]'::jsonb);
end $$;

-- Source: schemas/functions/duty_private/generation_facts.sql
CREATE OR REPLACE FUNCTION duty_private.generation_facts(p_month text) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
declare duties jsonb:=duty_private.generation_duties(p_month); meta public.duty_allocations; neighbors jsonb; approved text[];
begin
 -- An admin-approved unavailable date of the person on that duty (owner 2026-11-21) is not a
 -- refusal for generation or its validation: never asked again, and no lock needed.
 select coalesce(array_agg(c.member_id::text||'/'||c.day::text),'{}') into approved
 from public.duty_constraints c join public.duty_months m on m.month=p_month join public.duty_assignments a on c.day>=a.day and c.day<a.end_day
  and c.member_id in (a.primary_id,a.secondary_id) and duty_private.duty_owner(a.day)=p_month
  and a.publication_id is not distinct from (case when m.status='published' then m.current_publication_id end)
 where c.duty_approved and c.kind='no';
 select x.* into meta from public.duty_allocations x join public.duty_months m using(month)
 where x.month=p_month and x.publication_id is not distinct from (case when m.status='published' then m.current_publication_id end);
 select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'ownerMonth',m.month,'start',a.day,'end',a.end_day,'engineer',a.primary_id,
  'source',case when a.publication_id is null then 'working' else 'published' end) order by m.month,a.day,a.id),'[]') into neighbors
 from public.duty_months m join public.duty_assignments a on duty_private.duty_owner(a.day)=m.month
 and (a.publication_id=m.current_publication_id or (m.status='draft' and a.publication_id is null))
 where m.month in (to_char((p_month||'-01')::date-interval '1 month','YYYY-MM'),to_char((p_month||'-01')::date+interval '1 month','YYYY-MM')) and a.primary_id is not null;
 return jsonb_build_object('month',p_month,'duties',duties,'neighbors',neighbors,
  -- noWeekends and weekendsFrom appear only when set, so other members' facts (and fingerprints) are unchanged.
  'members',coalesce((select jsonb_agg(jsonb_build_object('id',id,'active',active,'approved',status='approved','eligible',status='approved' and active and not viewer)
   ||case when no_weekends then jsonb_build_object('noWeekends',true) else '{}'::jsonb end
   ||case when weekends_from is not null then jsonb_build_object('weekendsFrom',weekends_from) else '{}'::jsonb end order by id) from public.duty_members),'[]'),
  -- A Viewer (#90) is never eligible, so Generate and Plan the month leave them out.
  'seniority',coalesce((select jsonb_agg(id order by seniority,joined_at,id) from public.duty_members where status='approved' and active and not viewer),'[]'),
  'constraints',coalesce((select jsonb_object_agg(member_id,days) from (select member_id,jsonb_object_agg(day,kind order by day) days from public.duty_constraints
    where day>=(duties->0->>'startDate')::date and day<(duties->-1->>'endDate')::date and not (member_id::text||'/'||day::text)=any(approved) group by member_id) c),'{}'),
  'allocation',meta.allocation,'allocationId',meta.allocation_id,'locks',coalesce((select jsonb_agg(jsonb_build_object('dutyId',a.day,'engineer',a.primary_id) order by a.day) from public.duty_assignments a join public.duty_months m on m.month=p_month where duty_private.duty_owner(a.day)=p_month and a.locked and a.publication_id is not distinct from (case when m.status='published' then m.current_publication_id end)),'[]'),'approvals',coalesce((select jsonb_agg(case when v->>'rule'='availability' then jsonb_set(v,'{dates}',(select jsonb_agg(q order by q) from jsonb_array_elements_text(v->'dates') q
    where not ((v->>'engineer')||'/'||q)=any(approved))) else v end order by n) from jsonb_array_elements(meta.approvals) with ordinality x(v,n)
   where v->>'rule'<>'availability' or exists(select 1 from jsonb_array_elements_text(v->'dates') q where not ((v->>'engineer')||'/'||q)=any(approved))),'[]'),
  'sourcePublicationId',meta.source_publication_id,'generation',meta.generation);
end $$;

-- Source: schemas/functions/duty_private/save_schedule.sql
CREATE OR REPLACE FUNCTION duty_private.save_schedule(p_state jsonb, p_revision bigint, p_publish text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
#variable_conflict use_column
declare x record; item jsonb; d date; a public.duty_assignments; m public.duty_months; first_day date; last_day date; publication uuid; next_version integer; locks_before jsonb; changed_locks jsonb; f jsonb; result jsonb; allocation public.duty_allocations; conflicts jsonb;
begin
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 perform duty_private.check_revision(p_revision);
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 if jsonb_typeof(p_state->'duties') is distinct from 'array' or jsonb_typeof(p_state->'months') is distinct from 'object' or jsonb_typeof(p_state->'team') is distinct from 'array' or length(p_state::text)>2000000 then raise exception 'Invalid schedule'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('day',a.day,'end_day',a.end_day,'primary_id',a.primary_id,'points',a.points)),'[]') into locks_before
 from public.duty_assignments a where a.publication_id is null and a.locked;
 if (p_state ? 'approve_unavailable' and (jsonb_typeof(p_state->'approve_unavailable') is distinct from 'array' or jsonb_array_length(p_state->'approve_unavailable')>5000))
  or (p_state ? 'publish_anyway' and (jsonb_typeof(p_state->'publish_anyway') is distinct from 'array' or jsonb_array_length(p_state->'publish_anyway')>5000)) then raise exception 'Invalid schedule'; end if;
 if p_state ? 'lock_edits' and (jsonb_typeof(p_state->'lock_edits') is distinct from 'array' or exists(select 1 from jsonb_array_elements_text(p_state->'lock_edits') d where not (p_state->'months' ? duty_private.duty_owner(d::date)))) then raise exception 'Invalid lock review'; end if;
 for x in select value,ordinality from jsonb_array_elements(p_state->'team') with ordinality loop
  -- Profile names and roles have separate checked operations.
  update public.duty_members set color=x.value->>'color',active=(x.value->>'active')::boolean,seniority=x.ordinality where id=(x.value->>'id')::uuid and status='approved';
  if not found then raise exception 'Unknown approved team member'; end if;
 end loop;
 perform duty_private.assert_admin_remains();
 for x in select * from jsonb_each(p_state->'months') loop
  select * into m from public.duty_months where month=x.key;
  if m.status='published' and (x.value->>'status'='draft' or p_publish=x.key) then raise exception 'Reopen the draft first'; end if;
  if x.value->>'status'='published' and coalesce(m.status,'draft')='draft' and p_publish is distinct from x.key then raise exception 'Use Publish to publish a draft'; end if;
  insert into public.duty_months(month,deadline,generated) values(x.key,(x.value->>'deadline')::date,coalesce((x.value->>'generated')::boolean,false))
  on conflict(month) do update set deadline=excluded.deadline,generated=case when duty_months.status='published' then true else excluded.generated end;
 end loop;
 -- A scoped save cannot erase drafts omitted from the request or materialize a
 -- published schedule as working rows. Status transitions use checked operations.
 delete from public.duty_assignments working where working.publication_id is null
 and p_state->'months' ? duty_private.duty_owner(working.day)
 and exists(select 1 from public.duty_months owning where owning.month=duty_private.duty_owner(working.day) and owning.status='draft')
 and working.day not in (select (value->>'day')::date from jsonb_array_elements(p_state->'duties'));
 for item in select value from jsonb_array_elements(p_state->'duties') loop
  if not (p_state->'months' ? duty_private.duty_owner((item->>'day')::date)) or not exists(select 1 from public.duty_months where month=duty_private.duty_owner((item->>'day')::date) and status='draft') then raise exception 'Duty requires its owning month draft'; end if;
  insert into public.duty_assignments(day,end_day,primary_id,secondary_id,manager_override,title,extra_points,saturday_extra_points,locked)
  values((item->>'day')::date,(item->>'end_day')::date,nullif(item->>'primary_id','')::uuid,nullif(item->>'secondary_id','')::uuid,coalesce((item->>'manager_override')::boolean,false),coalesce(item->>'title',''),coalesce((item->>'extra_points')::numeric,0),coalesce((item->>'saturday_extra_points')::numeric,0),coalesce((item->>'locked')::boolean,false))
  on conflict(publication_id,day) do update set end_day=excluded.end_day,primary_id=excluded.primary_id,secondary_id=excluded.secondary_id,manager_override=excluded.manager_override,title=excluded.title,extra_points=excluded.extra_points,saturday_extra_points=excluded.saturday_extra_points,locked=case when item ? 'locked' then excluded.locked else duty_assignments.locked end;
 end loop;
 if exists(select 1 from public.duty_assignments first_duty join public.duty_assignments other_duty on first_duty.day<other_duty.day and first_duty.end_day>other_duty.day where first_duty.publication_id is null and other_duty.publication_id is null) then raise exception 'Duty dates overlap'; end if;
 -- One availability approval (owner 2026-11-21): the admin approved that person on that
 -- unavailable date (the duty editor's box, a draft swap) while they are on it in this draft.
 -- No lock; a weekend split or join keeps it, since it belongs to the person and date.
 update public.duty_constraints c set duty_approved=true from jsonb_array_elements(coalesce(p_state->'approve_unavailable','[]')) x
 where c.kind='no' and not c.duty_approved and c.member_id::text=x->>'member' and c.day::text=x->>'day'
  and exists(select 1 from public.duty_assignments a where a.publication_id is null and c.day>=a.day and c.day<a.end_day
   and c.member_id in (a.primary_id,a.secondary_id) and p_state->'months' ? duty_private.duty_owner(a.day));
 perform duty_private.prune_duty_approvals();
 if exists(select 1 from jsonb_array_elements(locks_before) l where not exists(select 1 from public.duty_assignments a where a.publication_id is null
  and a.day=(l->>'day')::date and a.end_day=(l->>'end_day')::date and a.primary_id=(l->>'primary_id')::uuid and a.points=(l->>'points')::numeric and a.locked) and not coalesce(p_state->'lock_edits','[]') ? (l->>'day')) then raise exception 'Explicitly review locks before changing locked work'; end if;
 -- Lock edits are atomic with the primary save. Unrelated locks and approvals survive.
 select coalesce(jsonb_agg(l),'[]') into changed_locks from jsonb_array_elements(locks_before) l
 where not exists(select 1 from public.duty_assignments a where a.publication_id is null and a.locked
  and a.day=(l->>'day')::date and a.end_day=(l->>'end_day')::date and a.primary_id=(l->>'primary_id')::uuid and a.points=(l->>'points')::numeric);
 update public.duty_allocations meta set
  locks=coalesce((select jsonb_agg(jsonb_build_object('dutyId',a.day,'engineer',a.primary_id) order by a.day)
   from public.duty_assignments a where a.publication_id is null and a.locked and duty_private.duty_owner(a.day)=meta.month),'[]'),
  approvals=coalesce((select jsonb_agg(v) from jsonb_array_elements(meta.approvals) v where not exists(
   select 1 from jsonb_array_elements(changed_locks) l where
    (v->>'rule' in ('availability','boundary') and v->>'dutyId'=l->>'day')
    or (v->>'rule'='consecutive' and (v->'duties') ? (l->>'day'))
    or (v->>'rule'='weekends' and v->>'engineer'=l->>'primary_id'))),'[]')
 where meta.publication_id is null and p_state->'months' ? meta.month;
 if p_publish is not null then
  if not (p_state->'months' ? p_publish) or not exists(select 1 from public.duty_months where month=p_publish and status='draft') then raise exception 'An open month draft is required'; end if;
  first_day:=(p_publish||'-01')::date; last_day:=(first_day+interval '1 month'-interval '1 day')::date;
  -- Validate only this month's owned dates, including its final Friday's Saturday.
  if extract(dow from first_day)=6 then first_day:=first_day+1; end if;
  if extract(dow from last_day)=5 then last_day:=last_day+1; end if;
  for d in select generate_series(first_day,last_day,interval '1 day')::date loop
   select * into a from public.duty_assignments where publication_id is null and day<=d and end_day>d;
   if a.primary_id is null or not exists(select 1 from public.duty_members where id=a.primary_id and status='approved' and active and not viewer) then raise exception 'An active engineer is required on %',d; end if;
   if a.secondary_id is not null and not exists(select 1 from public.duty_members where id=a.secondary_id and status='approved' and active and not viewer) then raise exception 'Emergency engineer is inactive on %',d; end if;
  end loop;
  -- Every primary's and emergency cover's unavailable date on this month's duties is approved,
  -- or listed here as who and when (never a note). "Publish anyway" approves exactly the listed
  -- conflicts; one that appeared since is refused and listed again (owner 2026-11-21).
  select coalesce(jsonb_agg(jsonb_build_object('member',c.member_id,'day',c.day) order by c.day,c.member_id),'[]') into conflicts
  from public.duty_assignments a2 join public.duty_constraints c on c.kind='no' and not c.duty_approved and c.day>=greatest(a2.day,first_day) and c.day<a2.end_day and c.day<=last_day
   and c.member_id in (a2.primary_id,a2.secondary_id)
  where a2.publication_id is null and duty_private.duty_owner(a2.day)=p_publish
   and not (c.member_id=a2.primary_id and exists(select 1 from public.duty_allocations meta,jsonb_array_elements(meta.approvals) approved
    where meta.month=p_publish and meta.publication_id is null and approved->>'rule'='availability' and approved->>'dutyId'=a2.day::text and approved->>'engineer'=a2.primary_id::text
    and (approved->'dates') ? c.day::text));
  if conflicts<>'[]' then
   if not (p_state ? 'publish_anyway') or exists(select 1 from jsonb_array_elements(conflicts) x where not (p_state->'publish_anyway') @> jsonb_build_array(x)) then
    raise exception 'Availability conflict: %',conflicts;
   end if;
   update public.duty_constraints c set duty_approved=true from jsonb_array_elements(conflicts) x where c.member_id::text=x->>'member' and c.day::text=x->>'day' and c.kind='no';
  end if;
  select * into allocation from public.duty_allocations where month=p_publish and publication_id is null;
  if allocation.month is not null then
   f:=duty_private.generation_facts(p_publish);
   if allocation.calendar_fingerprint<>md5((select jsonb_agg(d-array['primary','secondary'] order by d->>'id')::text from jsonb_array_elements(f->'duties') d)) then raise exception 'Calendar changed. Confirm allocation again.' using errcode='PT409'; end if;
   result:=duty_private.generation_validate(f,allocation.allocation->'targetsUnits',(select jsonb_object_agg(d->>'id',jsonb_build_object('primary',d->'primary','secondary',d->'secondary')) from jsonb_array_elements(f->'duties') d));
   if not (result->>'complete')::boolean then raise exception 'Complete allocation required for publication'; end if;
  end if;
  update public.duty_months set publication_sequence=publication_sequence+1 where month=p_publish returning publication_sequence into next_version;
  insert into public.duty_publications(month,version,published_by) values(p_publish,next_version,duty_private.current_member_id()) returning id into publication;
  insert into public.duty_assignments(publication_id,day,end_day,primary_id,secondary_id,manager_override,title,extra_points,saturday_extra_points,locked)
  select publication,day,end_day,primary_id,secondary_id,manager_override,title,extra_points,saturday_extra_points,locked from public.duty_assignments where publication_id is null and duty_private.duty_owner(day)=p_publish;
  insert into public.duty_allocations(month,publication_id,allocation_id,allocation,locks,approvals,accounting_fingerprint,calendar_fingerprint,source_publication_id,generation)
  select month,publication,allocation_id,allocation,locks,approvals,accounting_fingerprint,calendar_fingerprint,source_publication_id,generation from public.duty_allocations where month=p_publish and publication_id is null;
  perform duty_private.compensation_publication(p_publish,publication,p_state->'compensation');
  delete from public.duty_assignments where publication_id is null and duty_private.duty_owner(day)=p_publish;
  delete from public.duty_allocations where month=p_publish and publication_id is null;
  update public.duty_months set current_publication_id=publication,status='published',generated=true where month=p_publish;
  -- Whoever left a date in this version loses its approval.
  perform duty_private.prune_duty_approvals();
 end if;
 update public.duty_workspace set revision=revision+1 where id;
end $$;

-- Source: schemas/functions/duty_private/validate_swap.sql
CREATE OR REPLACE FUNCTION duty_private.validate_swap(p_from uuid, p_to uuid, p_publication uuid, p_override boolean DEFAULT false) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare a public.duty_assignments; b public.duty_assignments; m text; conflicts boolean; who uuid; before_count integer; after_count integer;
begin
 select * into a from public.duty_assignments where id=p_from and publication_id=p_publication;
 select * into b from public.duty_assignments where id=p_to and publication_id=p_publication;
 select month into m from public.duty_months where current_publication_id=p_publication;
 if a.id is null or b.id is null or m is null or a.id=b.id then raise exception 'This publication changed. Request a new swap.'; end if;
 if duty_private.duty_owner(a.day)<>m or duty_private.duty_owner(b.day)<>m then raise exception 'Choose duties owned by the same published month'; end if;
 if a.day<(now() at time zone 'Asia/Jerusalem')::date or b.day<(now() at time zone 'Asia/Jerusalem')::date then raise exception 'Choose duties starting today or later'; end if;
 if a.primary_id is null or b.primary_id is null or a.primary_id=b.primary_id then raise exception 'Choose two different primary engineers'; end if;
 if exists(select 1 from unnest(array[a.primary_id,b.primary_id,a.secondary_id,b.secondary_id]) person
  where person is not null and not exists(select 1 from public.duty_members where id=person and active and status='approved' and not viewer)) then raise exception 'An engineer is no longer active and approved'; end if;
 if a.secondary_id=b.primary_id or b.secondary_id=a.primary_id then raise exception 'A primary engineer cannot also be emergency cover'; end if;
 if exists(select 1 from duty_private.current_duties() x join duty_private.current_duties() y on x.id<>y.id and x.day<y.end_day and y.day<x.end_day
  where x.id in (a.id,b.id)) then raise exception 'Published duty dates overlap'; end if;
 -- Emergency cover's unavailability refuses a request. A primary's own constraint never
 -- does (#92): they consent by sending or accepting; the admin's approval overrides both.
 -- An admin-approved date of that cover (owner 2026-11-21) is never asked again.
 select exists(select 1 from public.duty_constraints c where c.kind='no' and not c.duty_approved and
  ((c.member_id=a.secondary_id and c.day>=a.day and c.day<a.end_day)
   or (c.member_id=b.secondary_id and c.day>=b.day and c.day<b.end_day))) into conflicts;
 if conflicts and not p_override then raise exception 'Availability conflict. An admin must explicitly override with a reason.'; end if;
 -- Either half and emergency cover count as one weekend; preserve existing exceptions,
 -- but swaps cannot increase anyone's count above one (same rule as swapDraft).
 foreach who in array array[a.primary_id,b.primary_id] loop
  select count(distinct case when extract(dow from day)=6 then day-1 else day end) into before_count
  from duty_private.current_duties() where duty_private.duty_owner(day)=m and extract(dow from day) in (5,6) and who in (primary_id,secondary_id);
  select count(distinct case when extract(dow from day)=6 then day-1 else day end) into after_count
  from duty_private.current_duties() where duty_private.duty_owner(day)=m and extract(dow from day) in (5,6)
  and (secondary_id=who or (case when id=a.id then b.primary_id when id=b.id then a.primary_id else primary_id end)=who);
  if after_count>1 and after_count>before_count then raise exception 'This swap would create a second weekend'; end if;
 end loop;
 return conflicts;
end $$;

-- Source: schemas/functions/duty_private/reconcile_swaps.sql
CREATE OR REPLACE FUNCTION duty_private.reconcile_swaps(p_month text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare r public.duty_swap_requests; a public.duty_assignments; b public.duty_assignments; publication uuid;
begin
 select current_publication_id into publication from public.duty_months where month=p_month;
 for r in select * from public.duty_swap_requests where month=p_month
  and status in ('awaiting_engineer','awaiting_admin') order by id for update loop
  select * into a from public.duty_assignments where publication_id=publication and day=r.from_day and end_day=r.from_end_day;
  select * into b from public.duty_assignments where publication_id=publication and day=r.to_day and end_day=r.to_end_day;
  -- Consent covers the points each side gives and takes: a republished duty
  -- worth different points is a different swap (the requested copy is immutable).
  if a.id is null or b.id is null or a.primary_id is distinct from r.requester_id
   or b.primary_id is null or b.primary_id=r.requester_id
   or a.day<(now() at time zone 'Asia/Jerusalem')::date or b.day<(now() at time zone 'Asia/Jerusalem')::date
   or a.points<>coalesce((select points from public.duty_assignments where id=r.from_duty_id),a.points)
   or b.points<>coalesce((select points from public.duty_assignments where id=r.to_duty_id),b.points)
   -- Nobody waits on a member who can no longer sign in or take duties.
   or not exists(select 1 from public.duty_members where id=a.primary_id and active and status='approved' and not viewer)
   or not exists(select 1 from public.duty_members where id=b.primary_id and active and status='approved' and not viewer) then
   update public.duty_swap_requests set status='invalidated',accepted_by=null,accepted_at=null,
    resolved_at=now(),resolved_by=null where id=r.id;
  elsif b.primary_id is distinct from r.other_id then
   -- A new counterpart is a new deal: both members answer again.
   update public.duty_swap_requests set other_id=b.primary_id,status='awaiting_engineer',
    accepted_by=null,accepted_at=null,requester_accepted_at=null where id=r.id;
  end if;
 end loop;
end $$;

-- Source: schemas/functions/duty_private/edit_published_duty.sql
-- An admin changes one published duty's engineer and/or extra points without a
-- swap, publishing a new version. Accounting stays canonical: the ordinary
-- publication transition makes the old engineer owe the new one each date's shared
-- units (Temporary); Permanent adds a reviewed permanent intent from that old engineer
-- over exactly those units, so no debt. Added extra counts for whoever does the duty.
-- A weekend whose two halves end up identical (same primary, cover and lock, neither started)
-- is one ordinary Friday–Sunday duty again (decision 2026-11-07): swaps and weekend rules see
-- one weekend, never a half each. Each date keeps its own extra; already-saved identical
-- halves heal on the next edit of either.
CREATE OR REPLACE FUNCTION duty_private.edit_published_duty(p_publication uuid, p_day date, p_primary uuid, p_extra_points numeric, p_saturday_extra_points numeric, p_kind text, p_revision bigint, p_override_reason text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare d public.duty_assignments; m public.duty_months; publication uuid; next_version integer; reason text:=btrim(coalesce(p_override_reason,''),U&'\0009\000A\000B\000C\000D\0020\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000\FEFF');
 saturday numeric:=coalesce(p_saturday_extra_points,0); changed boolean; conflicts boolean:=false; capacity jsonb:='[]'; old_atoms jsonb; new_atoms jsonb; atom text; a jsonb;
 plan jsonb; intent jsonb; back boolean; backs jsonb:='[]'; fri public.duty_assignments; sat public.duty_assignments; edited bigint;
begin
 perform duty_private.check_revision(p_revision);
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 if p_kind is null or p_kind not in ('temporary','permanent') then raise exception 'Choose Temporary or Permanent'; end if;
 if length(reason)>500 then raise exception 'Keep the override reason under 500 characters'; end if;
 select * into m from public.duty_months where current_publication_id=p_publication for update;
 if m.month is null then raise exception 'This publication changed. Refresh first.' using errcode='PT409'; end if;
 -- A reopened draft was copied from the earlier version; publishing it would silently undo this edit.
 if m.status<>'published' then raise exception 'Publish or cancel the open draft before editing published duties'; end if;
 select * into d from public.duty_assignments where publication_id=p_publication and duty_assignments.day=p_day;
 if d.id is null or duty_private.duty_owner(d.day)<>m.month then raise exception 'Choose a duty in this published month'; end if;
 if d.day<(now() at time zone 'Asia/Jerusalem')::date then raise exception 'Choose duties starting today or later'; end if;
 if d.primary_id is null then raise exception 'This duty has no primary engineer'; end if;
 if p_primary is null or not exists(select 1 from public.duty_members where id=p_primary and active and status='approved' and not viewer) then raise exception 'Choose an active approved engineer'; end if;
 if p_primary=d.secondary_id then raise exception 'A primary engineer cannot also be emergency cover'; end if;
 -- Half points stay exact; the table's own bounds apply to both dates.
 if p_extra_points is null or p_extra_points<0 or p_extra_points>20 or p_extra_points*2<>trunc(p_extra_points*2)
  or saturday<0 or saturday>20 or saturday*2<>trunc(saturday*2) or (d.end_day<>d.day+2 and saturday<>0) then raise exception 'Extra points must be 0 to 20 in half points'; end if;
 changed:=p_primary<>d.primary_id;
 if not changed and p_extra_points=d.extra_points and saturday=d.saturday_extra_points then raise exception 'Nothing changed'; end if;
 if changed then
  select exists(select 1 from public.duty_constraints c where c.kind='no' and c.member_id=p_primary and c.day>=d.day and c.day<d.end_day) into conflicts;
  if conflicts and reason='' then raise exception 'Availability conflict. An admin must explicitly override with a reason.'; end if;
 end if;
 update public.duty_months set publication_sequence=publication_sequence+1 where month=m.month returning publication_sequence into next_version;
 insert into public.duty_publications(month,version,published_by) values(m.month,next_version,duty_private.current_member_id()) returning id into publication;
 insert into public.duty_assignments(publication_id,day,end_day,primary_id,secondary_id,manager_override,title,extra_points,saturday_extra_points,locked)
 select publication,x.day,x.end_day,case when x.id=d.id then p_primary else x.primary_id end,x.secondary_id,
  case when x.id=d.id and changed then exists(select 1 from public.duty_constraints c where c.kind='no' and c.day>=x.day and c.day<x.end_day and c.member_id in (p_primary,x.secondary_id))
   else x.manager_override end,x.title,case when x.id=d.id then p_extra_points else x.extra_points end,case when x.id=d.id then saturday else x.saturday_extra_points end,x.locked
 from public.duty_assignments x where x.publication_id=p_publication;
 select (x.points*2)::bigint into edited from public.duty_assignments x where x.publication_id=publication and x.day=d.day;
 select * into fri from public.duty_assignments x where x.publication_id=publication and extract(dow from x.day)=5 and x.end_day=x.day+1
  and x.day in (d.day,d.day-1);
 select * into sat from public.duty_assignments x where x.publication_id=publication and x.day=fri.day+1 and x.end_day=x.day+1;
 if fri.id is not null and sat.id is not null and fri.day>=(now() at time zone 'Asia/Jerusalem')::date and fri.primary_id is not distinct from sat.primary_id
  and fri.secondary_id is not distinct from sat.secondary_id and fri.locked=sat.locked then
  delete from public.duty_assignments where id=sat.id;
  update public.duty_assignments set end_day=fri.day+2,saturday_extra_points=sat.extra_points,manager_override=fri.manager_override or sat.manager_override,
   title=case when fri.title='' then sat.title else fri.title end where id=fri.id;
 else fri:=null;
 end if;
 -- The allocation keeps its lineage like an approved swap; locks follow the new
 -- engineer and approvals for the changed dates or the two engineers' weekends drop.
 -- Its targets follow the edit, so a reopened copy of this version still matches its plan.
 select allocation into plan from public.duty_allocations where publication_id=p_publication;
 if jsonb_typeof(plan->'targetsUnits')='object' then
  plan:=jsonb_set(plan,array['targetsUnits',d.primary_id::text],to_jsonb(coalesce((plan->'targetsUnits'->>d.primary_id::text)::bigint,0)-(d.points*2)::bigint));
  plan:=jsonb_set(plan,array['targetsUnits',p_primary::text],to_jsonb(coalesce((plan->'targetsUnits'->>p_primary::text)::bigint,0)
   +edited));
 end if;
 insert into public.duty_allocations(month,publication_id,allocation_id,allocation,locks,approvals,accounting_fingerprint,calendar_fingerprint,source_publication_id,generation,origin)
 select month,publication,allocation_id,plan,
  (select coalesce(jsonb_agg(case when changed and (l->>'dutyId')>=d.day::text and (l->>'dutyId')<d.end_day::text then jsonb_set(l,'{engineer}',to_jsonb(p_primary::text)) else l end),'[]') from jsonb_array_elements(locks) l
   where fri.id is null or l->>'dutyId'<>sat.day::text),
  (select coalesce(jsonb_agg(v),'[]') from jsonb_array_elements(approvals) v where not changed or (
   not (v->>'rule' in ('availability','boundary') and (v->>'dutyId')>=d.day::text and (v->>'dutyId')<d.end_day::text)
   and not (v->>'rule'='consecutive' and exists(select 1 from jsonb_array_elements_text(case when jsonb_typeof(v->'duties')='array' then v->'duties' else '[]' end) k where k>=d.day::text and k<d.end_day::text))
   and not (v->>'rule'='weekends' and v->>'engineer' in (d.primary_id::text,p_primary::text)))),
  accounting_fingerprint,calendar_fingerprint,p_publication,generation,'swap'
 from public.duty_allocations where publication_id=p_publication;
 if changed and p_kind='permanent' then
  -- Permanent: the engineer being replaced, whoever holds the duty now, gives it away for
  -- good (decision 2026-11-06). A permanent intent over each date's shared units, so no
  -- debt for anyone; earlier swaps, edits and the plan's own changes keep their balances.
  -- H1: giving it back to someone who held it before a Temporary change still in effect is
  -- that change's undo: a Temporary `edit/` intent, so the earlier debt cancels. Each date
  -- of a weekend keeps its own history (decision 2026-11-07): when its two dates disagree,
  -- each gets its own intent.
  old_atoms:=duty_private.compensation_atoms(duty_private.compensation_snapshot(p_publication));
  new_atoms:=duty_private.compensation_atoms(duty_private.compensation_snapshot(publication));
  for atom,a in select key,value from jsonb_each(old_atoms) where (value->>'date')::date>=d.day and (value->>'date')::date<d.end_day order by key loop
   capacity:=capacity||jsonb_build_array(jsonb_build_object('date',atom,'offset',0,'units',least((a->>'units')::bigint,(new_atoms->atom->>'units')::bigint)));
   backs:=backs||to_jsonb(duty_private.edit_returns(p_publication,atom::date) ? p_primary::text);
  end loop;
  if (select count(distinct v) from jsonb_array_elements(backs) v)<=1 then
   back:=coalesce((backs->>0)::boolean,false);
   intent:=jsonb_build_object('id','edit/'||publication,'kind',case when back then 'temporary' else 'permanent' end,'fromId',d.primary_id,'toId',p_primary,'capacity',capacity);
  else
   intent:=(select jsonb_agg(jsonb_build_object('id','edit/'||publication||'/'||(c->>'date'),'kind',case when (backs->>(n::integer-1))::boolean then 'temporary' else 'permanent' end,
    'fromId',d.primary_id,'toId',p_primary,'capacity',jsonb_build_array(c)) order by n) from jsonb_array_elements(capacity) with ordinality o(c,n));
  end if;
 end if;
 -- Record the accounting with this edit before the pointer moves; the pointer
 -- trigger then finds the version recorded and only reconciles pending swaps.
 perform duty_private.compensation_publication(m.month,publication,NULL,false,jsonb_build_object(
  'intents',case when intent is null then '[]'::jsonb when jsonb_typeof(intent)='array' then intent else jsonb_build_array(intent) end,
  'reason','Published duty edit '||d.day||' ('||p_kind||')'||case when conflicts then '. Availability override: '||reason else '' end));
 update public.duty_months set current_publication_id=publication where month=m.month;
 -- A reason is the availability approval (owner 2026-11-21): the new engineer's unavailable dates
 -- on this duty are approved for them, so a reopened draft never asks again. The old one's lapse.
 if changed and conflicts then
  update public.duty_constraints c set duty_approved=true where c.kind='no' and c.member_id=p_primary and c.day>=d.day and c.day<d.end_day;
 end if;
 perform duty_private.prune_duty_approvals();
 -- New points, or a weekend joined again, change the month's calendar; the copied plan follows it.
 if p_extra_points<>d.extra_points or saturday<>d.saturday_extra_points or fri.id is not null then
  update public.duty_allocations set calendar_fingerprint=md5((select jsonb_agg(x-array['primary','secondary'] order by x->>'id')::text
   from jsonb_array_elements(duty_private.generation_facts(m.month)->'duties') x)) where publication_id=publication;
 end if;
 -- Saving cancels a pending swap of this duty (decision 2026-11-02; Edit duty names it
 -- before saving): consent was given for the earlier engineer and points, so the
 -- pointer hook's re-ask of a new counterpart is not kept either.
 update public.duty_swap_requests set status='invalidated',accepted_by=null,accepted_at=null,resolved_at=now(),resolved_by=null
 where duty_swap_requests.month=m.month and duty_swap_requests.status in ('awaiting_engineer','awaiting_admin')
  and ((from_day=d.day and from_end_day=d.end_day) or (to_day=d.day and to_end_day=d.end_day)
   or (fri.id is not null and (from_day in (fri.day,sat.day) or to_day in (fri.day,sat.day))));
 update public.duty_workspace set revision=revision+1 where id;
 return jsonb_build_object('publication',publication,'version',next_version);
end $$;

-- Source: schemas/functions/duty_private/edit_published_weekend.sql
-- An admin edits one published weekend as one Friday–Sunday duty or as two days
-- (decision 2026-11-07), publishing a new version. Same people on both dates is one
-- duty; different people split it into a Friday and a Saturday row, each keeping its
-- date's points exactly as typed (0.5 + extra). Accounting stays per date: Temporary is
-- the ordinary publication transition (each date's old holder owes its new one that
-- date's shared units); Permanent adds a reviewed intent per changed date, so no debt,
-- unless it gives the date back to who held it before a Temporary change still in effect
-- (H1: that undo is a Temporary `edit/` intent and the earlier debt cancels). Joining
-- back and changing the halves are booked against the version just before, so undo
-- reverses exactly and nothing is booked twice. Only until Friday starts.
CREATE OR REPLACE FUNCTION duty_private.edit_published_weekend(p_publication uuid, p_friday date, p_friday_primary uuid, p_friday_extra numeric, p_saturday_primary uuid, p_saturday_extra numeric, p_kind text, p_revision bigint, p_override_reason text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare m public.duty_months; f public.duty_assignments; s public.duty_assignments; publication uuid; next_version integer;
 reason text:=btrim(coalesce(p_override_reason,''),U&'\0009\000A\000B\000C\000D\0020\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000\FEFF');
 saturday date:=p_friday+1; was_joined boolean; joined boolean; old_saturday_extra numeric; fri_changed boolean; sat_changed boolean; conflicts boolean:=false;
 cover uuid; plan jsonb; intents jsonb:='[]'; old_atoms jsonb; new_atoms jsonb; x record; back boolean;
begin
 perform duty_private.check_revision(p_revision);
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 if p_kind is null or p_kind not in ('temporary','permanent') then raise exception 'Choose Temporary or Permanent'; end if;
 if length(reason)>500 then raise exception 'Keep the override reason under 500 characters'; end if;
 select * into m from public.duty_months where current_publication_id=p_publication for update;
 if m.month is null then raise exception 'This publication changed. Refresh first.' using errcode='PT409'; end if;
 -- A reopened draft was copied from the earlier version; publishing it would silently undo this edit.
 if m.status<>'published' then raise exception 'Publish or cancel the open draft before editing published duties'; end if;
 if p_friday is null or extract(dow from p_friday)<>5 or duty_private.duty_owner(p_friday)<>m.month then raise exception 'Choose a weekend in this published month'; end if;
 select * into f from public.duty_assignments a where a.publication_id=p_publication and a.day<=p_friday and a.end_day>p_friday;
 select * into s from public.duty_assignments a where a.publication_id=p_publication and a.day<=saturday and a.end_day>saturday;
 if f.id is null or s.id is null or f.day<>p_friday then raise exception 'Choose a weekend in this published month'; end if;
 -- Split and joined until the weekend starts; a started weekend's Saturday is a normal day.
 if p_friday<(now() at time zone 'Asia/Jerusalem')::date then raise exception 'Choose duties starting today or later'; end if;
 if f.primary_id is null or s.primary_id is null then raise exception 'This duty has no primary engineer'; end if;
 if p_friday_primary is null or p_saturday_primary is null or exists(select 1 from unnest(array[p_friday_primary,p_saturday_primary]) u(member)
  where not exists(select 1 from public.duty_members dm where dm.id=u.member and dm.active and dm.status='approved' and not dm.viewer)) then raise exception 'Choose an active approved engineer'; end if;
 -- Half points stay exact; the table's own bounds apply to both dates.
 if p_friday_extra is null or p_saturday_extra is null or p_friday_extra<0 or p_friday_extra>20 or p_friday_extra*2<>trunc(p_friday_extra*2)
  or p_saturday_extra<0 or p_saturday_extra>20 or p_saturday_extra*2<>trunc(p_saturday_extra*2) then raise exception 'Extra points must be 0 to 20 in half points'; end if;
 was_joined:=f.id=s.id; joined:=p_friday_primary=p_saturday_primary;
 old_saturday_extra:=case when was_joined then f.saturday_extra_points else s.extra_points end;
 fri_changed:=p_friday_primary<>f.primary_id; sat_changed:=p_saturday_primary<>s.primary_id;
 if joined=was_joined and not fri_changed and not sat_changed and p_friday_extra=f.extra_points and p_saturday_extra=old_saturday_extra then raise exception 'Nothing changed'; end if;
 -- Emergency cover stays with its date; one weekend keeps the cover of a date that kept its
 -- engineer (Friday first), else Friday's, else Saturday's.
 if joined then
  select c into cover from unnest(array[case when not fri_changed then f.secondary_id end,case when not sat_changed then s.secondary_id end,f.secondary_id,s.secondary_id]) with ordinality u(c,n)
  where c is not null order by n limit 1;
  if cover=p_friday_primary then raise exception 'A primary engineer cannot also be emergency cover'; end if;
 elsif p_friday_primary=f.secondary_id or p_saturday_primary=s.secondary_id then raise exception 'A primary engineer cannot also be emergency cover'; end if;
 -- A new engineer on a date, or a cover joined onto a date it didn't cover, needs a reason
 -- when they marked that date unavailable.
 select exists(select 1 from public.duty_constraints c where c.kind='no' and ((fri_changed and c.member_id=p_friday_primary and c.day=p_friday)
  or (sat_changed and c.member_id=p_saturday_primary and c.day=saturday)
  or (joined and c.member_id=cover and ((c.day=p_friday and cover is distinct from f.secondary_id) or (c.day=saturday and cover is distinct from s.secondary_id))))) into conflicts;
 if conflicts and reason='' then raise exception 'Availability conflict. An admin must explicitly override with a reason.'; end if;
 update public.duty_months set publication_sequence=publication_sequence+1 where month=m.month returning publication_sequence into next_version;
 insert into public.duty_publications(month,version,published_by) values(m.month,next_version,duty_private.current_member_id()) returning id into publication;
 insert into public.duty_assignments(publication_id,day,end_day,primary_id,secondary_id,manager_override,title,extra_points,saturday_extra_points,locked)
 select publication,a.day,a.end_day,a.primary_id,a.secondary_id,a.manager_override,a.title,a.extra_points,a.saturday_extra_points,a.locked
 from public.duty_assignments a where a.publication_id=p_publication and a.id not in (f.id,s.id);
 -- A row whose dates or engineer changed records an availability override again.
 if joined then
  insert into public.duty_assignments(publication_id,day,end_day,primary_id,secondary_id,manager_override,title,extra_points,saturday_extra_points,locked)
  values(publication,p_friday,p_friday+2,p_friday_primary,cover,
   case when was_joined and not fri_changed then f.manager_override else exists(select 1 from public.duty_constraints c where c.kind='no' and c.day in (p_friday,saturday) and c.member_id in (p_friday_primary,cover)) end,
   case when f.title='' then s.title else f.title end,p_friday_extra,p_saturday_extra,f.locked or s.locked);
 else
  insert into public.duty_assignments(publication_id,day,end_day,primary_id,secondary_id,manager_override,title,extra_points,saturday_extra_points,locked)
  values(publication,p_friday,saturday,p_friday_primary,f.secondary_id,
    case when was_joined or fri_changed then exists(select 1 from public.duty_constraints c where c.kind='no' and c.day=p_friday and c.member_id in (p_friday_primary,f.secondary_id)) else f.manager_override end,
    f.title,p_friday_extra,0,f.locked),
   (publication,saturday,saturday+1,p_saturday_primary,s.secondary_id,
    case when was_joined or sat_changed then exists(select 1 from public.duty_constraints c where c.kind='no' and c.day=saturday and c.member_id in (p_saturday_primary,s.secondary_id)) else s.manager_override end,
    s.title,p_saturday_extra,0,s.locked);
 end if;
 -- The allocation keeps its lineage like an approved swap. Its targets follow each row's
 -- points, its weekend locks follow the new rows and engineers, and approvals for the
 -- weekend's dates or the engineers' weekends drop when someone changed.
 select allocation into plan from public.duty_allocations where publication_id=p_publication;
 if jsonb_typeof(plan->'targetsUnits')='object' then
  for x in select a.primary_id id,-(a.points*2)::bigint units from public.duty_assignments a where a.id in (f.id,s.id)
   union all select a.primary_id,(a.points*2)::bigint from public.duty_assignments a where a.publication_id=publication and a.day in (p_friday,saturday) loop
   plan:=jsonb_set(plan,array['targetsUnits',x.id::text],to_jsonb(coalesce((plan->'targetsUnits'->>x.id::text)::bigint,0)+x.units));
  end loop;
 end if;
 insert into public.duty_allocations(month,publication_id,allocation_id,allocation,locks,approvals,accounting_fingerprint,calendar_fingerprint,source_publication_id,generation,origin)
 select a.month,publication,a.allocation_id,plan,
  (select coalesce(jsonb_agg(l),'[]') from (select l from jsonb_array_elements(a.locks) l where l->>'dutyId' not in (p_friday::text,saturday::text)
   union all select jsonb_set(jsonb_set(t.l,'{dutyId}',to_jsonb(r.day::text)),'{engineer}',to_jsonb(r.primary_id::text)) from public.duty_assignments r
    cross join lateral (select l from jsonb_array_elements(a.locks) l where l->>'dutyId' in (p_friday::text,saturday::text) order by l->>'dutyId' limit 1) t
    where r.publication_id=publication and r.day in (p_friday,saturday) and r.locked) k(l)),
  (select coalesce(jsonb_agg(v),'[]') from jsonb_array_elements(a.approvals) v where not (fri_changed or sat_changed) or (
   not (v->>'rule' in ('availability','boundary') and v->>'dutyId' in (p_friday::text,saturday::text))
   and not (v->>'rule'='consecutive' and exists(select 1 from jsonb_array_elements_text(case when jsonb_typeof(v->'duties')='array' then v->'duties' else '[]' end) k where k in (p_friday::text,saturday::text)))
   and not (v->>'rule'='weekends' and v->>'engineer' in (f.primary_id::text,s.primary_id::text,p_friday_primary::text,p_saturday_primary::text)))),
  a.accounting_fingerprint,a.calendar_fingerprint,p_publication,a.generation,'swap'
 from public.duty_allocations a where a.publication_id=p_publication;
 if p_kind='permanent' and (fri_changed or sat_changed) then
  -- Permanent: each date's current holder gives that date away for good (decision
  -- 2026-11-06): one permanent intent per changed date over its shared units, so no debt.
  -- H1: giving a date back to who held it before a Temporary change still in effect is
  -- that change's undo, a Temporary `edit/` intent, so the earlier debt cancels.
  old_atoms:=duty_private.compensation_atoms(duty_private.compensation_snapshot(p_publication));
  new_atoms:=duty_private.compensation_atoms(duty_private.compensation_snapshot(publication));
  for x in select * from (values(p_friday,f.primary_id,p_friday_primary),(saturday,s.primary_id,p_saturday_primary)) v(day,before,after) where before<>after order by day loop
   back:=duty_private.edit_returns(p_publication,x.day) ? x.after::text;
   intents:=intents||jsonb_build_array(jsonb_build_object('id','edit/'||publication||'/'||x.day,'kind',case when back then 'temporary' else 'permanent' end,
    'fromId',x.before,'toId',x.after,'capacity',jsonb_build_array(jsonb_build_object('date',x.day::text,'offset',0,
     'units',least((old_atoms->x.day::text->>'units')::bigint,(new_atoms->x.day::text->>'units')::bigint)))));
  end loop;
 end if;
 -- Record the accounting with this edit before the pointer moves; the pointer
 -- trigger then finds the version recorded and only reconciles pending swaps.
 perform duty_private.compensation_publication(m.month,publication,NULL,false,jsonb_build_object('intents',intents,
  'reason','Published weekend edit '||p_friday||' ('||case when joined then 'one weekend' else 'two days' end||', '||p_kind||')'||case when conflicts then '. Availability override: '||reason else '' end));
 update public.duty_months set current_publication_id=publication where month=m.month;
 -- A reason is the availability approval (owner 2026-11-21) for the dates it covered; anyone
 -- moved off this weekend loses theirs.
 if conflicts then
  -- Exactly the dates the reason covered: a new engineer's date, or a cover joined onto one.
  update public.duty_constraints c set duty_approved=true where c.kind='no' and ((fri_changed and c.member_id=p_friday_primary and c.day=p_friday)
   or (sat_changed and c.member_id=p_saturday_primary and c.day=saturday)
   or (joined and c.member_id=cover and ((c.day=p_friday and cover is distinct from f.secondary_id) or (c.day=saturday and cover is distinct from s.secondary_id))));
 end if;
 perform duty_private.prune_duty_approvals();
 -- The weekend's shape or points changed the month's calendar; the copied plan follows it.
 update public.duty_allocations set calendar_fingerprint=md5((select jsonb_agg(d-array['primary','secondary'] order by d->>'id')::text
  from jsonb_array_elements(duty_private.generation_facts(m.month)->'duties') d)) where publication_id=publication;
 -- Saving cancels a pending swap of either date (decision 2026-11-02; the editor names it first).
 update public.duty_swap_requests set status='invalidated',accepted_by=null,accepted_at=null,resolved_at=now(),resolved_by=null
 where duty_swap_requests.month=m.month and duty_swap_requests.status in ('awaiting_engineer','awaiting_admin')
  and (from_day in (p_friday,saturday) or to_day in (p_friday,saturday));
 update public.duty_workspace set revision=revision+1 where id;
 return jsonb_build_object('publication',publication,'version',next_version,'joined',joined);
end $$;

-- Source: schemas/functions/duty_private/edit_returns.sql
-- Who a Permanent edit of this published date would return it to as an undo (rule H1,
-- decision 2026-11-06): the engineers who held the date before a Temporary change still in
-- effect, most recent first. Replays the version lineage forward per date, so a split or
-- joined weekend keeps each date's chain (decision 2026-11-07): an edit (only dates of this
-- duty's weekend, or of this day, changed hands, and no one gave and took within it, no new
-- intent) adds the date's previous holder; a return to one of them (a Temporary `edit/`
-- intent) drops the undone changes; a swap, a Permanent edit, a plan or any other change
-- starts again. Versions restored by deletion keep the chain of the version they restore.
-- p_day may be any date of a duty. Manager only; nothing leaves but member ids.
CREATE OR REPLACE FUNCTION duty_private.edit_returns(p_publication uuid, p_day date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare d public.duty_assignments; m text; target text:=p_publication::text; seq bigint; op jsonb; prior jsonb;
 lineage jsonb:='[]'; step jsonb; holder text; previous text; chain jsonb:='[]'; intent jsonb; k integer;
 before_atoms jsonb; after_atoms jsonb; changed jsonb; scope_start date; scope_end date;
begin
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 select * into d from public.duty_assignments where publication_id=p_publication and day<=p_day and end_day>p_day;
 if d.id is null or d.primary_id is null then return chain; end if;
 m:=duty_private.duty_owner(d.day);
 -- A weekend date's edits may change either date of its weekend; a weekday's only itself.
 scope_start:=case when extract(dow from p_day)=6 then p_day-1 else p_day end;
 scope_end:=case when extract(dow from p_day) in (5,6) then scope_start+2 else p_day+1 end;
 -- Back to the month's first version or its latest plan, newest first.
 loop
  select e.sequence,e.operation into seq,op from public.duty_compensation_events e where e.operation->>'kind'='publication' and e.operation->>'month'=m
   and not (e.operation ? 'mode') and e.operation->'after'->>'id'=target and (seq is null or e.sequence<seq) order by e.sequence desc limit 1;
  exit when not found or op->>'beforeId' is null;
  select e.operation into prior from public.duty_compensation_events e where e.operation->>'kind'='publication' and e.operation->>'month'=m
   and not (e.operation ? 'mode') and e.operation->'after'->>'id'=op->>'beforeId' and e.sequence<seq order by e.sequence desc limit 1;
  exit when prior is null;
  lineage:=jsonb_build_array(jsonb_build_object('before',prior->'after','after',op->'after'))||lineage;
  target:=op->>'beforeId';
 end loop;
 for step in select value from jsonb_array_elements(lineage) with ordinality o(value,n) order by n loop
  before_atoms:=duty_private.compensation_atoms(step->'before'); after_atoms:=duty_private.compensation_atoms(step->'after');
  previous:=before_atoms->p_day::text->>'primaryId'; holder:=after_atoms->p_day::text->>'primaryId';
  if previous is null or holder is null then chain:='[]'; continue; end if;
  if previous=holder then continue; end if;
  select i into intent from jsonb_array_elements(step->'after'->'intents') i
   where not coalesce(step->'before'->'intents' @> jsonb_build_array(jsonb_build_object('id',i->>'id')),false)
    and exists(select 1 from jsonb_array_elements(i->'capacity') c where (c->>'date')::date=p_day) limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('date',dk,'before',before_atoms->dk->>'primaryId','after',after_atoms->dk->>'primaryId')),'[]') into changed
  from (select jsonb_object_keys(before_atoms) union select jsonb_object_keys(after_atoms)) x(dk)
  where before_atoms->dk->>'primaryId' is distinct from after_atoms->dk->>'primaryId';
  if intent is not null then
   -- A return to an earlier holder undoes the changes after it; anything else starts again.
   select max(n) into k from jsonb_array_elements_text(chain) with ordinality o(v,n) where v=holder;
   chain:=case when intent->>'kind'='temporary' and starts_with(intent->>'id','edit/') and intent->'route' is null and k is not null
    then coalesce((select jsonb_agg(v order by n) from jsonb_array_elements_text(chain) with ordinality o(v,n) where n<k),'[]') else '[]' end;
  elsif not exists(select 1 from jsonb_array_elements(changed) c where (c->>'date')::date<scope_start or (c->>'date')::date>=scope_end)
   and not exists(select 1 from jsonb_array_elements(changed) a,jsonb_array_elements(changed) b where a->>'before'=b->>'after') then
   chain:=chain||to_jsonb(previous);
  else chain:='[]';
  end if;
 end loop;
 -- Most recent first; only engineers who can still take the duty.
 return coalesce((select jsonb_agg(v order by n desc) from jsonb_array_elements_text(chain) with ordinality o(v,n)
  where exists(select 1 from public.duty_members where id::text=v and active and status='approved' and not viewer)),'[]');
end $$;

-- Source: schemas/functions/duty_private/compensation_members.sql
CREATE OR REPLACE FUNCTION duty_private.compensation_members() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
#variable_conflict use_column
begin
 -- A Viewer (#90) takes part like an inactive member: no points or debts.
 if TG_OP='UPDATE' and (old.active and old.status='approved' and not old.viewer)=(new.active and new.status='approved' and not new.viewer) then return new; end if;
 -- Updates run BEFORE the row changes: due work earns under the old state.
 -- The pending member created by onboarding has zero balance and no authority.
 perform duty_private.compensation_record(jsonb_build_object('kind','members','members',jsonb_build_array(
  jsonb_build_object('id',new.id,'active',new.active and new.status='approved' and not new.viewer))),'members/'||gen_random_uuid());
 return new;
end $$;

-- Source: schemas/functions/duty_private/set_constraints.sql
CREATE OR REPLACE FUNCTION duty_private.set_constraints(p_member uuid, p_days date[], p_kind text, p_note text, p_revision bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare d date; m text; manager boolean;
begin
 perform duty_private.check_revision(p_revision);
 manager:=duty_private.is_manager();
 if (not manager and p_member is distinct from duty_private.current_member_id()) or not exists(select 1 from public.duty_members where id=p_member and status='approved') then raise exception 'Not allowed' using errcode='42501'; end if;
 -- A Viewer (#90) is never scheduled, so nobody adds constraints for them.
 if exists(select 1 from public.duty_members where id=p_member and viewer) then raise exception 'Viewers have no constraints' using errcode='42501'; end if;
 if p_kind not in ('no','prefer','clear') or p_kind is null or coalesce(cardinality(p_days),0) not between 1 and 62 or length(coalesce(p_note,''))>300 then raise exception 'Invalid constraints'; end if;
 foreach d in array p_days loop
  if d is null then raise exception 'Invalid date'; end if;
  m:=to_char(d,'YYYY-MM');
  insert into public.duty_months(month,deadline) values(m,date_trunc('month',d)::date-7) on conflict do nothing;
  if not manager and exists(select 1 from public.duty_months where month=m and (status='published' or deadline < (now() at time zone 'Asia/Jerusalem')::date)) then raise exception 'Constraints are closed for this month' using errcode='42501'; end if;
  if p_kind='clear' then delete from public.duty_constraints where member_id=p_member and day=d;
  else insert into public.duty_constraints(member_id,day,kind,note) values(p_member,d,p_kind,trim(coalesce(p_note,''))) on conflict(member_id,day) do update set kind=excluded.kind,note=excluded.note,
   -- A note edit keeps an admin's availability approval; a newly unavailable date never has one.
   duty_approved=duty_constraints.duty_approved and duty_constraints.kind='no' and excluded.kind='no'; end if;
  -- Availability is independent of the working schedule. In particular, an
  -- admin constraint edit must not create an empty draft of a published month.
 end loop;
 update public.duty_workspace set revision=revision+1 where id;
end $$;

-- Source: schemas/functions/duty_private/push_events.sql
CREATE OR REPLACE FUNCTION duty_private.push_enqueue(p_member uuid, p_kind text, p_key text, p_params jsonb, p_url text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare s public.duty_notification_settings; wanted boolean;
begin
 -- Of the Viewers (#90), only Viewer-admins are notified.
 if p_member is null or not exists(select 1 from public.duty_members m join public.duty_roles r on r.code=m.role where m.id=p_member and m.auth_user_id is not null and m.status='approved' and m.active and (not m.viewer or r.can_manage))
  or not exists(select 1 from public.duty_push_subscriptions where member_id=p_member) then return false; end if;
 select * into s from public.duty_notification_settings where member_id=p_member;
 wanted:=case
  when p_kind in ('deadline_3','deadline_1') then coalesce(s.deadlines,true)
  when p_kind in ('published','republished') then coalesce(s.published,true)
  when p_kind like 'swap\_%' then coalesce(s.swaps,true)
  when p_kind='edit' then coalesce(s.edits,true)
  when p_kind='remind_evening' then coalesce(s.evening,true)
  when p_kind='remind_morning' then coalesce(s.morning,true)
  when p_kind='member_waiting' then coalesce(s.members,true)
  else false end;
 if not wanted then return false; end if;
 insert into public.duty_push_notifications(member_id,kind,dedupe_key,params,url) values(p_member,p_kind,p_key,coalesce(p_params,'{}'::jsonb),p_url)
 on conflict(dedupe_key) do nothing;
 return found;
end $$;

-- Source: schemas/functions/duty_private/push_delivery.sql
CREATE OR REPLACE FUNCTION duty_private.push_schedule(p_now timestamp with time zone) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare local timestamp:=p_now at time zone 'Asia/Jerusalem'; today date:=(p_now at time zone 'Asia/Jerusalem')::date; r record; added integer:=0;
begin
 for r in
  select m.month,m.deadline,w.kind,x.id as member from public.duty_months m
  cross join lateral (values ('deadline_3',(m.deadline-3)+time '10:00',(m.deadline-1)+time '10:00'),
   ('deadline_1',(m.deadline-1)+time '10:00',(m.deadline+1)::timestamp)) w(kind,fire,until)
  join public.duty_members x on x.status='approved' and x.active and not x.viewer and x.auth_user_id is not null
  where m.status='draft' and m.current_publication_id is null and local>=w.fire and local<w.until
   and (w.kind='deadline_3' or not exists(select 1 from public.duty_constraints c where c.member_id=x.id
    and c.day>=to_date(m.month,'YYYY-MM') and c.day<(to_date(m.month,'YYYY-MM')+interval '1 month')))
 loop
  if duty_private.push_enqueue(r.member,r.kind,r.kind||':'||r.month||':'||r.deadline||':'||r.member,
   jsonb_build_object('month',r.month,'deadline',r.deadline),'/?tab=availability&month='||r.month) then added:=added+1; end if;
 end loop;
 for r in
  select a.day,a.end_day,p.member,p.role,k.kind from duty_private.current_duties_between(today-1,today+1) a
  cross join lateral (values (a.primary_id,'primary'),(a.secondary_id,'secondary')) p(member,role)
  left join public.duty_notification_settings s on s.member_id=p.member
  cross join lateral (values ('remind_evening',(a.day-1)+coalesce(s.evening_time,time '18:00')),
   ('remind_morning',a.day+coalesce(s.morning_time,time '08:30'))) k(kind,fire)
  where p.member is not null and a.day between today-1 and today+1 and local>=k.fire and local<k.fire+interval '3 hours'
 loop
  if duty_private.push_enqueue(r.member,r.kind,r.kind||':'||r.day||':'||r.role||':'||r.member,
   jsonb_build_object('day',r.day,'endDay',r.end_day,'role',r.role),'/?tab=schedule&month='||to_char(r.day,'YYYY-MM')) then added:=added+1; end if;
 end loop;
 return added;
end $$;

-- Source: schemas/policies/duty_allocations.sql
DROP POLICY allocations_read ON public.duty_allocations;
CREATE POLICY allocations_read ON public.duty_allocations FOR SELECT TO authenticated
 USING ((SELECT duty_private.is_overseer()));

-- Source: schemas/policies/duty_assignments.sql
DROP POLICY assignments_read ON public.duty_assignments;
CREATE POLICY assignments_read ON public.duty_assignments FOR SELECT TO authenticated USING ((( SELECT duty_private.is_overseer() AS is_overseer) OR (( SELECT duty_private.is_member() AS is_member) AND (publication_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM public.duty_months m
  WHERE (m.current_publication_id = duty_assignments.publication_id))))));

-- Source: schemas/policies/duty_compensation_events.sql
DROP POLICY duty_compensation_manager_read ON public.duty_compensation_events;
DROP POLICY duty_compensation_snapshots_manager_read ON public.duty_compensation_snapshots;
CREATE POLICY duty_compensation_manager_read ON public.duty_compensation_events FOR SELECT TO authenticated USING ((SELECT duty_private.is_overseer()));
CREATE POLICY duty_compensation_snapshots_manager_read ON public.duty_compensation_snapshots FOR SELECT TO authenticated USING ((SELECT duty_private.is_overseer()));

-- Source: schemas/policies/duty_constraints.sql
DROP POLICY constraints_read ON public.duty_constraints;
CREATE POLICY constraints_read ON public.duty_constraints FOR SELECT TO authenticated USING ((( SELECT duty_private.is_overseer() AS is_overseer) OR ((member_id = ( SELECT duty_private.current_member_id() AS current_member_id)) AND ( SELECT duty_private.is_member() AS is_member))));

-- Source: schemas/policies/duty_members.sql
DROP POLICY members_read ON public.duty_members;
CREATE POLICY members_read ON public.duty_members FOR SELECT TO authenticated USING (((auth_user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT duty_private.is_overseer() AS is_overseer) OR ((status = 'approved'::text) AND ( SELECT duty_private.is_member() AS is_member))));

-- Source: schemas/policies/duty_publications.sql
DROP POLICY publications_read ON public.duty_publications;
CREATE POLICY publications_read ON public.duty_publications FOR SELECT TO authenticated USING ((( SELECT duty_private.is_overseer() AS is_overseer) OR (( SELECT duty_private.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.duty_months m
  WHERE (m.current_publication_id = duty_publications.id))))));

-- Source: schemas/policies/duty_swap_requests.sql
DROP POLICY swaps_read ON public.duty_swap_requests;
CREATE POLICY swaps_read ON public.duty_swap_requests FOR SELECT TO authenticated USING ((( SELECT duty_private.is_member() AS is_member) AND ((requester_id = ( SELECT duty_private.current_member_id() AS current_member_id)) OR (proposed_by = ( SELECT duty_private.current_member_id() AS current_member_id)) OR ((other_id = ( SELECT duty_private.current_member_id() AS current_member_id)) AND (status = 'awaiting_engineer'::text)) OR (( SELECT duty_private.is_overseer() AS is_overseer) AND (status = 'awaiting_admin'::text)) OR (( SELECT duty_private.is_overseer() AS is_overseer) AND (status = 'awaiting_engineer'::text) AND (EXISTS ( SELECT 1 FROM public.duty_members m WHERE (m.is_temporary AND (((m.id = duty_swap_requests.other_id) AND (duty_swap_requests.accepted_by IS NULL)) OR ((m.id = duty_swap_requests.requester_id) AND (duty_swap_requests.proposed_by IS NOT NULL) AND (duty_swap_requests.requester_accepted_at IS NULL))))))))));

-- Source: schemas/triggers/duty_compensation.sql
DROP TRIGGER duty_compensation_member_update ON public.duty_members;
CREATE TRIGGER duty_compensation_member_update BEFORE UPDATE OF active,status,viewer ON public.duty_members
 FOR EACH ROW EXECUTE FUNCTION duty_private.compensation_members();

-- Source: schemas/triggers/duty_reconcile_member_swaps.sql
DROP TRIGGER duty_reconcile_member_swaps ON public.duty_members;
CREATE TRIGGER duty_reconcile_member_swaps AFTER UPDATE OF active, status, viewer ON public.duty_members FOR EACH ROW WHEN ((old.active AND (old.status = 'approved'::text) AND NOT old.viewer AND NOT (new.active AND (new.status = 'approved'::text) AND NOT new.viewer))) EXECUTE FUNCTION duty_private.reconcile_member_swaps();
