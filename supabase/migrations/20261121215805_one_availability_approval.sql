-- #103 (user-approved, 2026-11-21): one availability approval, no locks.
-- * duty_constraints.duty_approved: an admin approved that person on that unavailable date while
--   they are on the duty covering it (draft or current publication). It comes from the duty
--   editor's box, an approved swap ("Approve anyway"), a published edit with a reason, or
--   "Publish anyway". It lapses when nobody keeps them on that date (prune_duty_approvals) and
--   a newly marked unavailable date never has it. A weekend split or join keeps it.
-- * save_schedule's Publish honors it for primaries and emergency cover and ignores
--   manager_override; unapproved conflicts are refused as [{member,day}] unless the request's
--   publish_anyway lists every one of them, which approves exactly those.
-- * generation_facts treats an approved date of the person on that duty as available, so Plan
--   the month and its validators never ask again and need no lock.
-- * resolve_swap no longer locks swapped duties or adds allocation approvals (reverts that #103
--   step); it approves the new holders' dates instead.
-- Existing manager exceptions and Plan the month availability approvals become approvals.
-- Cancel draft, restore, delete and Generate also end approvals of people they move off a date.
-- Signatures are unchanged; one new internal function.

ALTER TABLE public.duty_constraints ADD COLUMN duty_approved boolean DEFAULT false NOT NULL;

-- Source: schemas/functions/duty_private/prune_duty_approvals.sql
-- An admin's availability approval (duty_constraints.duty_approved, owner 2026-11-21) holds for
-- that person on that unavailable date while they are on the duty covering it, in the open draft
-- or the current publication. Once nobody keeps them there it lapses; putting them back asks again.
CREATE OR REPLACE FUNCTION duty_private.prune_duty_approvals() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
 update public.duty_constraints c set duty_approved=false where c.duty_approved and not exists(
  select 1 from public.duty_assignments a join public.duty_months m on m.month=duty_private.duty_owner(a.day)
  where (a.publication_id is null or a.publication_id=m.current_publication_id)
   and c.day>=a.day and c.day<a.end_day and c.member_id in (a.primary_id,a.secondary_id));
end $$;
REVOKE ALL ON FUNCTION duty_private.prune_duty_approvals() FROM PUBLIC, anon, authenticated, service_role;

-- Existing approvals: a duty's manager exception covered its people's unavailable dates, and a
-- Plan the month availability approval covered its engineer's listed dates.
UPDATE public.duty_constraints c SET duty_approved=true WHERE c.kind='no' AND (
 EXISTS(SELECT 1 FROM public.duty_assignments a JOIN public.duty_months m ON m.month=duty_private.duty_owner(a.day)
  WHERE (a.publication_id IS NULL OR a.publication_id=m.current_publication_id) AND a.manager_override
   AND c.day>=a.day AND c.day<a.end_day AND c.member_id IN (a.primary_id,a.secondary_id))
 OR EXISTS(SELECT 1 FROM public.duty_allocations al JOIN public.duty_months m ON m.month=al.month, jsonb_array_elements(al.approvals) v
  WHERE (al.publication_id IS NULL OR al.publication_id=m.current_publication_id) AND v->>'rule'='availability'
   AND v->>'engineer'=c.member_id::text AND (v->'dates') ? c.day::text));
SELECT duty_private.prune_duty_approvals();

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
   if a.primary_id is null or not exists(select 1 from public.duty_members where id=a.primary_id and status='approved' and active) then raise exception 'An active engineer is required on %',d; end if;
   if a.secondary_id is not null and not exists(select 1 from public.duty_members where id=a.secondary_id and status='approved' and active) then raise exception 'Emergency engineer is inactive on %',d; end if;
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
  'members',coalesce((select jsonb_agg(jsonb_build_object('id',id,'active',active,'approved',status='approved','eligible',status='approved' and active)
   ||case when no_weekends then jsonb_build_object('noWeekends',true) else '{}'::jsonb end
   ||case when weekends_from is not null then jsonb_build_object('weekendsFrom',weekends_from) else '{}'::jsonb end order by id) from public.duty_members),'[]'),
  'seniority',coalesce((select jsonb_agg(id order by seniority,joined_at,id) from public.duty_members where status='approved' and active),'[]'),
  'constraints',coalesce((select jsonb_object_agg(member_id,days) from (select member_id,jsonb_object_agg(day,kind order by day) days from public.duty_constraints
    where day>=(duties->0->>'startDate')::date and day<(duties->-1->>'endDate')::date and not (member_id::text||'/'||day::text)=any(approved) group by member_id) c),'{}'),
  'allocation',meta.allocation,'allocationId',meta.allocation_id,'locks',coalesce((select jsonb_agg(jsonb_build_object('dutyId',a.day,'engineer',a.primary_id) order by a.day) from public.duty_assignments a join public.duty_months m on m.month=p_month where duty_private.duty_owner(a.day)=p_month and a.locked and a.publication_id is not distinct from (case when m.status='published' then m.current_publication_id end)),'[]'),'approvals',coalesce((select jsonb_agg(case when v->>'rule'='availability' then jsonb_set(v,'{dates}',(select jsonb_agg(q order by q) from jsonb_array_elements_text(v->'dates') q
    where not ((v->>'engineer')||'/'||q)=any(approved))) else v end order by n) from jsonb_array_elements(meta.approvals) with ordinality x(v,n)
   where v->>'rule'<>'availability' or exists(select 1 from jsonb_array_elements_text(v->'dates') q where not ((v->>'engineer')||'/'||q)=any(approved))),'[]'),
  'sourcePublicationId',meta.source_publication_id,'generation',meta.generation);
end $$;

-- Source: schemas/functions/duty_private/resolve_swap.sql
CREATE OR REPLACE FUNCTION duty_private.resolve_swap(p_request uuid, p_action text, p_revision bigint, p_override_reason text DEFAULT ''::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare r public.duty_swap_requests; a public.duty_assignments; b public.duty_assignments;
 current_publication uuid; publication uuid; next_version integer; reason text:=trim(coalesce(p_override_reason,'')); side text; next_status text;
 party boolean:=false; me uuid:=duty_private.current_member_id(); joined boolean:=false;
begin
 perform duty_private.check_revision(p_revision);
 if not duty_private.is_member() then raise exception 'Your membership is not approved' using errcode='42501'; end if;
 select * into r from public.duty_swap_requests where id=p_request for update;
 if r.id is null then raise exception 'Request not found' using errcode='42501'; end if;
 if p_action='cancel' then
  if coalesce(r.proposed_by,r.requester_id) is distinct from me then raise exception 'Only the person who started the request can cancel' using errcode='42501'; end if;
 elsif p_action in ('accept','decline') then
  -- Each party answers only for their own side. A requester who asked for the
  -- swap consented by sending it; one an admin proposed it for must accept too.
  -- Temporary members have no account: an admin answers for them, and only for them.
  party:=coalesce(r.other_id=me or (r.requester_id=me and r.proposed_by is not null),false);
  if not party and not (duty_private.is_manager() and exists(select 1 from public.duty_members m where m.is_temporary
    and (m.id=r.other_id or (m.id=r.requester_id and r.proposed_by is not null)))) then
   raise exception 'Only the current counterpart can respond' using errcode='42501';
  end if;
 elsif p_action in ('approve','reject') then
  if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 else raise exception 'Invalid swap action'; end if;
 if r.status not in ('awaiting_engineer','awaiting_admin') then raise exception 'This request is no longer pending'; end if;
 perform duty_private.reconcile_swaps(r.month);
 select * into r from public.duty_swap_requests where id=p_request;
 -- Commit safe invalidation (raising here would roll it back).
 if r.status='invalidated' then
  update public.duty_workspace set revision=revision+1 where id;
  return 'invalidated';
 end if;
 if p_action in ('accept','decline') then
  if r.status<>'awaiting_engineer' then raise exception 'Engineer consent already recorded'; end if;
  -- The caller's own side first; then an admin answers a temporary member's open side,
  -- the requester's before the other's (swapAnswerFor mirrors this order).
  if r.other_id=me and r.accepted_by is null then side:='other';
  elsif r.requester_id=me and r.proposed_by is not null and r.requester_accepted_at is null then side:='requester';
  elsif duty_private.is_manager() and r.proposed_by is not null and r.requester_accepted_at is null
   and exists(select 1 from public.duty_members where id=r.requester_id and is_temporary) then side:='requester';
  elsif duty_private.is_manager() and r.accepted_by is null
   and exists(select 1 from public.duty_members where id=r.other_id and is_temporary) then side:='other';
  elsif r.other_id=me or (r.requester_id=me and r.proposed_by is not null) then
   raise exception 'Your answer is already recorded';
  elsif party then raise exception 'The counterpart changed. Refresh first.' using errcode='PT409';
  else raise exception 'Only the current counterpart can respond' using errcode='42501'; end if;
 elsif p_action='approve' then
  -- Every swap ends with an explicit admin approval after both members accepted,
  -- even one an admin started or takes part in.
  if r.status<>'awaiting_admin' or r.accepted_by is distinct from r.other_id or (r.proposed_by is not null and r.requester_accepted_at is null) then
   raise exception 'Both engineers must accept before admin review';
  end if;
 end if;
 if p_action in ('accept','approve') then
  select current_publication_id into current_publication from public.duty_months where month=r.month;
  select * into a from public.duty_assignments where publication_id=current_publication and day=r.from_day and end_day=r.from_end_day;
  select * into b from public.duty_assignments where publication_id=current_publication and day=r.to_day and end_day=r.to_end_day;
  -- Availability never refuses a consented swap (#92, owner 2026-11-21): the admin's approval
  -- is the override, no reason needed; the published duty is marked manager_override. Never
  -- bypasses active membership, emergency duplication, overlap, weekends or future dates.
  perform duty_private.validate_swap(a.id,b.id,current_publication,true);
 end if;
 if p_action='approve' then
  update public.duty_months set publication_sequence=publication_sequence+1 where month=r.month returning publication_sequence into next_version;
  insert into public.duty_publications(month,version,published_by) values(r.month,next_version,me) returning id into publication;
  insert into public.duty_assignments(publication_id,day,end_day,primary_id,secondary_id,manager_override,title,extra_points,saturday_extra_points,locked)
  select publication,d.day,d.end_day,case when d.id=a.id then r.other_id when d.id=b.id then r.requester_id else d.primary_id end,
   d.secondary_id,case when d.id in (a.id,b.id) then exists(
    select 1 from public.duty_constraints c where c.kind='no' and c.day>=d.day and c.day<d.end_day
    and c.member_id in (case when d.id=a.id then r.other_id else r.requester_id end,d.secondary_id)
   ) else d.manager_override end,d.title,d.extra_points,d.saturday_extra_points,d.locked
  from public.duty_assignments d where d.publication_id=current_publication;
  -- A weighted swap moves points between the two engineers: the copied plan's targets
  -- follow it, so a reopened copy of this version still matches its plan (2026-11-06).
  insert into public.duty_allocations(month,publication_id,allocation_id,allocation,locks,approvals,accounting_fingerprint,calendar_fingerprint,source_publication_id,generation,origin)
  select month,publication,allocation_id,case when jsonb_typeof(allocation->'targetsUnits')='object' and a.points<>b.points then
    jsonb_set(jsonb_set(allocation,array['targetsUnits',r.requester_id::text],to_jsonb(coalesce((allocation->'targetsUnits'->>r.requester_id::text)::bigint,0)-(a.points*2)::bigint+(b.points*2)::bigint)),
     array['targetsUnits',r.other_id::text],to_jsonb(coalesce((allocation->'targetsUnits'->>r.other_id::text)::bigint,0)-(b.points*2)::bigint+(a.points*2)::bigint))
   else allocation end,
   (select coalesce(jsonb_agg(case when l->>'dutyId'=a.day::text then jsonb_set(l,'{engineer}',to_jsonb(r.other_id::text)) when l->>'dutyId'=b.day::text then jsonb_set(l,'{engineer}',to_jsonb(r.requester_id::text)) else l end),'[]') from jsonb_array_elements(locks) l),
   (select coalesce(jsonb_agg(v),'[]') from jsonb_array_elements(approvals) v where
    not (v->>'rule' in ('availability','boundary') and v->>'dutyId' in (a.day::text,b.day::text))
    and not (v->>'rule'='consecutive' and ((v->'duties') ? a.day::text or (v->'duties') ? b.day::text))
    and not (v->>'rule'='weekends' and v->>'engineer' in (r.requester_id::text,r.other_id::text))),accounting_fingerprint,calendar_fingerprint,current_publication,generation,'swap' from public.duty_allocations where publication_id=current_publication;
  -- Both halves of a weekend on one person are one weekend again (decision 2026-11-07).
  joined:=duty_private.join_weekend_halves(publication,a.day);
  joined:=duty_private.join_weekend_halves(publication,b.day) or joined;
  -- The admin's approval is the availability approval (owner 2026-11-21): each new holder's
  -- unavailable dates on the swapped duties are approved for them. No lock; never asked again.
  update public.duty_constraints c set duty_approved=true from (values(a.day,a.end_day,r.other_id),(b.day,b.end_day,r.requester_id)) x(day,end_day,who)
  where c.kind='no' and c.member_id=x.who and c.day>=x.day and c.day<x.end_day;
 end if;
 next_status:=case p_action when 'accept' then case when (side='other' and (r.proposed_by is null or r.requester_accepted_at is not null))
   or (side='requester' and r.accepted_by is not null) then 'awaiting_admin' else 'awaiting_engineer' end
  when 'decline' then 'declined' when 'approve' then 'approved' when 'reject' then 'rejected' else 'cancelled' end;
 -- Finalize before the publication trigger revalidates all other pending requests.
 update public.duty_swap_requests set status=next_status,
  accepted_by=case when p_action='accept' and side='other' then r.other_id else accepted_by end,
  accepted_at=case when p_action='accept' and side='other' then now() else accepted_at end,
  requester_accepted_at=case when p_action='accept' and side='requester' then now() else requester_accepted_at end,
  resolved_at=case when p_action='accept' then null else now() end,
  resolved_by=case when p_action='accept' then null else me end,
  result_publication_id=publication,override_reason=case when p_action='approve' then reason else '' end where id=r.id;
 if publication is not null then
  update public.duty_months set current_publication_id=publication where month=r.month;
  -- The two former holders' approvals on the swapped dates lapse (they are no longer on them).
  perform duty_private.prune_duty_approvals();
  -- A joined weekend changed the month's calendar; the copied plan follows it.
  if joined then
   update public.duty_allocations set calendar_fingerprint=md5((select jsonb_agg(d-array['primary','secondary'] order by d->>'id')::text
    from jsonb_array_elements(duty_private.generation_facts(r.month)->'duties') d)) where publication_id=publication;
  end if;
 end if;
 update public.duty_workspace set revision=revision+1 where id;
 return (select status from public.duty_swap_requests where id=r.id);
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
 if p_primary is null or not exists(select 1 from public.duty_members where id=p_primary and active and status='approved') then raise exception 'Choose an active approved engineer'; end if;
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
  where not exists(select 1 from public.duty_members dm where dm.id=u.member and dm.active and dm.status='approved')) then raise exception 'Choose an active approved engineer'; end if;
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
  where person is not null and not exists(select 1 from public.duty_members where id=person and active and status='approved')) then raise exception 'An engineer is no longer active and approved'; end if;
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

-- Source: schemas/functions/duty_private/swap_availability.sql
CREATE OR REPLACE FUNCTION duty_private.swap_availability(p_from uuid, p_to uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare a public.duty_assignments; b public.duty_assignments; admin boolean:=duty_private.is_manager(); me uuid:=duty_private.current_member_id();
begin
 if not duty_private.is_member() then raise exception 'Your membership is not approved' using errcode='42501'; end if;
 select * into a from public.duty_assignments where id=p_from;
 select * into b from public.duty_assignments where id=p_to;
 if a.publication_id is null or b.publication_id is distinct from a.publication_id
  or not exists(select 1 from public.duty_months where current_publication_id=a.publication_id) then
  raise exception 'Choose duties in the same current publication';
 end if;
 -- Only the two members (or an admin) learn whose availability blocks this swap,
 -- and members only for a pair they could still request.
 if not admin then
  if me is distinct from a.primary_id and me is distinct from b.primary_id then
   raise exception 'Choose your own primary duty' using errcode='42501';
  end if;
  if a.primary_id is null or b.primary_id is null or a.primary_id=b.primary_id
   or least(a.day,b.day)<(now() at time zone 'Asia/Jerusalem')::date then
   raise exception 'Choose duties starting today or later';
  end if;
 end if;
 -- Every unavailability the swap meets: which date, never the note. A primary's own never
 -- blocks a request (#92); emergency cover's does; admin approval overrides both. Members
 -- learn the two primaries by name; emergency cover stays anonymous to them.
 return coalesce((select jsonb_agg(jsonb_build_object('member',case when admin or c.member_id in (a.primary_id,b.primary_id) then c.member_id end,'day',c.day) order by c.day,c.member_id)
  from public.duty_constraints c where c.kind='no' and
  ((c.member_id in (b.primary_id,a.secondary_id) and c.day>=a.day and c.day<a.end_day)
   or (c.member_id in (a.primary_id,b.secondary_id) and c.day>=b.day and c.day<b.end_day))
  -- An admin-approved date of the cover staying on that duty is never asked again (owner 2026-11-21).
  and not (c.duty_approved and ((c.member_id=a.secondary_id and c.day>=a.day and c.day<a.end_day) or (c.member_id=b.secondary_id and c.day>=b.day and c.day<b.end_day)))),'[]'::jsonb);
end $$;

-- Source: schemas/functions/duty_private/cancel_draft.sql
CREATE OR REPLACE FUNCTION duty_private.cancel_draft(p_month text, p_revision bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare m public.duty_months;
begin
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 perform duty_private.check_revision(p_revision);
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 select * into m from public.duty_months where month=p_month;
 if m.current_publication_id is null or m.status<>'draft' then raise exception 'A reopened published month is required'; end if;
 delete from public.duty_assignments where publication_id is null and duty_private.duty_owner(day)=p_month;
 delete from public.duty_allocations where month=p_month and publication_id is null;
 update public.duty_months set status='published',generated=true where month=p_month;
 -- Whoever this left off a date loses its availability approval (#103).
 perform duty_private.prune_duty_approvals();
 update public.duty_workspace set revision=revision+1 where id;
end $$;

-- Source: schemas/functions/duty_private/restore_publication.sql
CREATE OR REPLACE FUNCTION duty_private.restore_publication(p_publication uuid, p_revision bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v public.duty_publications;
begin
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 perform duty_private.check_revision(p_revision);
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 select * into v from public.duty_publications where id=p_publication;
 if v.id is null then raise exception 'Version no longer exists'; end if;
 -- A version from before a re-plan can't come back: its ledger entries were reversed (decision 2026-11-01).
 if duty_private.compensation_replanned(duty_private.compensation_state(),v.month,v.id) then raise exception '% was re-planned after this version, so its points can''t come back. Reopen the month and change its plan instead.',to_char(to_date(v.month||'-01','YYYY-MM-DD'),'FMMonth YYYY'); end if;
 -- Old versions may contain adjacent coverage. Only Friday-owned rows belong
 -- to this draft; retain the original historical publication byte-for-byte.
 delete from public.duty_assignments where publication_id is null and duty_private.duty_owner(day)=v.month;
 insert into public.duty_assignments(day,end_day,primary_id,secondary_id,manager_override,title,extra_points,saturday_extra_points,locked)
 select day,end_day,primary_id,secondary_id,manager_override,title,extra_points,saturday_extra_points,locked
 from public.duty_assignments where publication_id=p_publication and duty_private.duty_owner(day)=v.month;
 delete from public.duty_allocations where month=v.month and publication_id is null;
 insert into public.duty_allocations(month,publication_id,allocation_id,allocation,locks,approvals,accounting_fingerprint,calendar_fingerprint,source_publication_id,generation,origin)
 select month,null,allocation_id,allocation,locks,approvals,md5((duty_private.compensation_state()->'events')::text),calendar_fingerprint,p_publication,generation,'restored' from public.duty_allocations where publication_id=p_publication;
 update public.duty_months set status='draft',generated=true where month=v.month;
 -- Whoever this left off a date loses its availability approval (#103).
 perform duty_private.prune_duty_approvals();
 update public.duty_workspace set revision=revision+1 where id;
end $$;

-- Source: schemas/functions/duty_private/save_generation.sql
CREATE OR REPLACE FUNCTION duty_private.save_generation(p_month text, p_assignments jsonb, p_revision bigint, p_fingerprint text, p_seed integer) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
#variable_conflict use_column
declare ctx jsonb; f jsonb; checked jsonb; meta public.duty_allocations; d jsonb; s jsonb; instant bigint;
begin
 ctx:=duty_private.generation_context(p_month,p_revision);
 if p_fingerprint IS DISTINCT FROM ctx->>'fingerprint' then raise exception 'Generation inputs changed. Refresh and review.' using errcode='PT409'; end if;
 if p_seed is null or p_seed<0 or length(p_assignments::text)>100000 then raise exception 'Invalid generation result'; end if;
 -- Sample after obtaining the workspace lock, and again immediately before the
 -- mutation. A lock wait can cross opening without any revision change.
 if duty_private.compensation_now()>=(ctx->>'coverageStartMs')::bigint then raise exception 'generation-window-closed'; end if;
 if not exists(select 1 from public.duty_months where month=p_month and status='draft') then raise exception 'An open month draft is required'; end if;
 select * into meta from public.duty_allocations where month=p_month and publication_id is null;
 if meta.month is null then raise exception 'Confirmed allocation required'; end if;
 if meta.accounting_fingerprint IS DISTINCT FROM ctx->>'accountingFingerprint' then raise exception 'Compensation changed. Refresh and review.' using errcode='PT409'; end if;
 f:=ctx->'facts';
 if meta.calendar_fingerprint<>md5((select jsonb_agg(d-array['primary','secondary'] order by d->>'id')::text from jsonb_array_elements(f->'duties') d)) then raise exception 'Calendar changed. Confirm allocation again.' using errcode='PT409'; end if;
 checked:=duty_private.generation_validate(f,meta.allocation->'targetsUnits',p_assignments);
 -- Generate never places a non-weekend member on a weekend duty (either half of a split
 -- weekend included). A weekend the manager locked to them is kept, never deleted; manual
 -- calendar edits stay the manager's call, so publication does not apply this rule.
 if exists(select 1 from jsonb_array_elements(f->'duties') d join jsonb_array_elements(f->'members') m on m->>'id'=p_assignments->(d->>'id')->>'primary'
  where d->>'weekendId' is not null and m->'noWeekends'='true'
   and not (f->'locks') @> jsonb_build_array(jsonb_build_object('dutyId',d->'id','engineer',m->'id'))) then raise exception 'non-weekend-primary'; end if;
 if meta.source_publication_id is null then
  -- Re-planned now and projected after, as generation_context and Confirm do.
  s:=duty_private.compensation_state();
  instant:=greatest((ctx->>'actualAtMs')::bigint,coalesce((s->'events'->-1->>'at')::bigint,0));
  s:=duty_private.compensation_replan(s,p_month,instant);
  s:=duty_private.compensation_reconcile(s,greatest(instant,(ctx->>'coverageStartMs')::bigint,coalesce((s->'events'->-1->>'at')::bigint,0)),false);
  perform duty_private.allocation_compile(f,meta.allocation,checked->'actualUnits',s);
 end if;
 if duty_private.compensation_now()>=(ctx->>'coverageStartMs')::bigint then raise exception 'generation-window-closed'; end if;
 for d in select value from jsonb_array_elements(f->'duties') loop
  insert into public.duty_assignments(day,end_day,primary_id,secondary_id,title,extra_points,saturday_extra_points)
  values((d->>'startDate')::date,(d->>'endDate')::date,(p_assignments->(d->>'id')->>'primary')::uuid,(d->>'secondary')::uuid,d->>'title',(d->>'extra')::numeric,coalesce((d->>'saturdayExtra')::numeric,0))
  on conflict(publication_id,day) do update set primary_id=excluded.primary_id;
 end loop;
 update public.duty_allocations set generation=jsonb_build_object('seed',p_seed,'sourceRevision',p_revision,'fingerprint',p_fingerprint,
  'savedAtMs',ctx->'actualAtMs','metrics',checked) where month=p_month and publication_id is null;
 update public.duty_months set generated=true where month=p_month;
 -- Whoever this left off a date loses its availability approval (#103).
 perform duty_private.prune_duty_approvals();
 update public.duty_workspace set revision=revision+1 where id;
 return duty_private.generation_context(p_month,(select revision from public.duty_workspace where id));
end $$;

-- Source: schemas/functions/duty_private/delete_publication.sql
CREATE OR REPLACE FUNCTION duty_private.delete_publication(p_publication uuid, p_revision bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v public.duty_publications; replacement uuid;
begin
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 perform duty_private.check_revision(p_revision);
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 select * into v from public.duty_publications where id=p_publication;
 if v.id is null then raise exception 'Version no longer exists'; end if;
 select id into replacement from public.duty_publications where month=v.month and id<>v.id order by version desc limit 1;
 -- Deleting the current version can't bring back one from before a re-plan (decision 2026-11-01).
 if replacement is not null and exists(select 1 from public.duty_months where current_publication_id=v.id)
  and duty_private.compensation_replanned(duty_private.compensation_state(),v.month,replacement) then raise exception '% was re-planned after this version, so its points can''t come back. Reopen the month and change its plan instead.',to_char(to_date(v.month||'-01','YYYY-MM-DD'),'FMMonth YYYY'); end if;
 -- Deleting the final publication must not silently discard the only schedule.
 -- Keep an already-open draft, otherwise copy the version before deleting it.
 if replacement is null and exists(select 1 from public.duty_months where current_publication_id=v.id and status='published') then
  insert into public.duty_assignments(day,end_day,primary_id,secondary_id,manager_override,title,extra_points,saturday_extra_points,locked)
  select day,end_day,primary_id,secondary_id,manager_override,title,extra_points,saturday_extra_points,locked from public.duty_assignments
  where publication_id=v.id and duty_private.duty_owner(day)=v.month;
  insert into public.duty_allocations(month,publication_id,allocation_id,allocation,locks,approvals,accounting_fingerprint,calendar_fingerprint,source_publication_id,generation)
  select month,null,allocation_id,allocation,locks,approvals,accounting_fingerprint,calendar_fingerprint,p_publication,generation from public.duty_allocations where publication_id=p_publication;
 end if;
 update public.duty_months set current_publication_id=replacement,status=case when replacement is null then 'draft' else status end where current_publication_id=v.id;
 delete from public.duty_publications where id=v.id;
 -- Whoever this left off a date loses its availability approval (#103).
 perform duty_private.prune_duty_approvals();
 update public.duty_workspace set revision=revision+1 where id;
end $$;

NOTIFY pgrst, 'reload schema';
