-- Owner decision 2026-11-21 (#92 review): an admin approves a swap over a constraint without
-- typing a reason. The approval itself is the availability override: the published duties are
-- still marked manager_override and the request keeps its approval record (override_reason
-- stays empty unless a client sends one). A member's request is still refused for emergency
-- cover's unavailability. The per-side waived dates from 20261120094825 no longer decide
-- anything and are dropped (that migration was never released). Published duty edits keep
-- their required reason. Signatures and grants are unchanged.

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
 select exists(select 1 from public.duty_constraints c where c.kind='no' and
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
   or (c.member_id in (a.primary_id,b.secondary_id) and c.day>=b.day and c.day<b.end_day))),'[]'::jsonb);
end $$;

-- Source: schemas/functions/duty_private/request_swap.sql
CREATE OR REPLACE FUNCTION duty_private.request_swap(p_from uuid, p_to uuid, p_explanation text, p_revision bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare a public.duty_assignments; b public.duty_assignments; t public.duty_assignments; m text; me uuid:=duty_private.current_member_id();
begin
 perform duty_private.check_revision(p_revision);
 -- Recheck after lock acquisition, including a membership change while waiting.
 if not duty_private.is_member() then raise exception 'Your membership is not approved' using errcode='42501'; end if;
 select * into a from public.duty_assignments where id=p_from;
 select * into b from public.duty_assignments where id=p_to;
 -- Engineers offer their own primary duty. Admins may also propose a swap between
 -- any two members (recorded in proposed_by, so both must accept). When the admin
 -- is a party, their side becomes the requester: their consent is implicit and
 -- only the other member is asked.
 if a.primary_id is distinct from me then
  if not duty_private.is_manager() then raise exception 'Choose your own primary duty' using errcode='42501'; end if;
  if b.primary_id=me then t:=a; a:=b; b:=t; end if;
 end if;
 if a.publication_id is null or b.publication_id is distinct from a.publication_id then raise exception 'Choose duties in the same current publication'; end if;
 perform duty_private.validate_swap(a.id,b.id,a.publication_id,false);
 select month into m from public.duty_months where current_publication_id=a.publication_id;
 insert into public.duty_swap_requests(month,source_publication_id,from_duty_id,to_duty_id,requester_id,other_id,from_day,from_end_day,to_day,to_end_day,explanation,proposed_by)
 values(m,a.publication_id,a.id,b.id,a.primary_id,b.primary_id,a.day,a.end_day,b.day,b.end_day,trim(coalesce(p_explanation,'')),
  case when a.primary_id<>me then me end);
 update public.duty_workspace set revision=revision+1 where id;
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
   or not exists(select 1 from public.duty_members where id=a.primary_id and active and status='approved')
   or not exists(select 1 from public.duty_members where id=b.primary_id and active and status='approved') then
   update public.duty_swap_requests set status='invalidated',accepted_by=null,accepted_at=null,
    resolved_at=now(),resolved_by=null where id=r.id;
  elsif b.primary_id is distinct from r.other_id then
   -- A new counterpart is a new deal: both members answer again.
   update public.duty_swap_requests set other_id=b.primary_id,status='awaiting_engineer',
    accepted_by=null,accepted_at=null,requester_accepted_at=null where id=r.id;
  end if;
 end loop;
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
  -- A joined weekend changed the month's calendar; the copied plan follows it.
  if joined then
   update public.duty_allocations set calendar_fingerprint=md5((select jsonb_agg(d-array['primary','secondary'] order by d->>'id')::text
    from jsonb_array_elements(duty_private.generation_facts(r.month)->'duties') d)) where publication_id=publication;
  end if;
 end if;
 update public.duty_workspace set revision=revision+1 where id;
 return (select status from public.duty_swap_requests where id=r.id);
end $$;

-- Source: schemas/tables/duty_swap_requests.sql
ALTER TABLE public.duty_swap_requests DROP COLUMN requester_waived_days, DROP COLUMN other_waived_days;

NOTIFY pgrst, 'reload schema';
