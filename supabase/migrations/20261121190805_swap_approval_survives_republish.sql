-- #103 (user-approved fix, 2026-11-21): publish -> approve a swap over a constraint -> reopen ->
-- publish was refused ("unavailable-primary"), because the swap's copied plan dropped the
-- availability approval. Now:
-- * resolve_swap locks each swapped duty whose new holder marked one of its dates unavailable and
--   records the same availability approval Plan the month uses, for exactly that person and
--   those dates (reason: the admin's, or "Swap approved by an admin").
-- * Publishing drops an availability approval whose duty now has someone else or whose dates no
--   longer match that person's constraints, so the normal check applies again.
-- * A refusal names every conflict as [{member,day}] (never notes) so the app can say who and when.
-- Signatures and grants are unchanged.

-- Source: schemas/functions/duty_private/generation_validate.sql
-- Independent validator: no solver witness, proof status, client calendar,
-- eligibility, point total or override boolean is authoritative.
CREATE OR REPLACE FUNCTION duty_private.generation_validate(f jsonb, targets jsonb, assignments jsonb) RETURNS jsonb
 LANGUAGE plpgsql STABLE SET search_path TO '' AS $$
#variable_conflict use_column
declare d jsonb; a jsonb; l jsonb; approval jsonb; n jsonb; previous jsonb; m jsonb; denied jsonb;
 ids jsonb:=f->'seniority'; totals jsonb:='{}'; fixed_weekends jsonb; k text; engineer text;
 total bigint:=0; assigned bigint:=0; amount bigint; scopes text[]:='{}'; scope text; locked_points bigint;
begin
 if jsonb_typeof(targets) IS DISTINCT FROM 'object' or jsonb_typeof(assignments) IS DISTINCT FROM 'object'
  or jsonb_typeof(f->'locks') IS DISTINCT FROM 'array' or jsonb_typeof(f->'approvals') IS DISTINCT FROM 'array'
  or jsonb_array_length(ids)=0 then raise exception 'invalid-generation-input'; end if;
 if (select count(*) from jsonb_each(targets))<>jsonb_array_length(ids) or exists(select 1 from jsonb_each(targets) where not ids ? key) then raise exception 'invalid-target-members'; end if;
 for k in select jsonb_array_elements_text(ids) loop
  amount:=duty_private.compensation_units(targets->k); total:=total+amount; totals:=totals||jsonb_build_object(k,0);
 end loop;
 if total<>(select sum((x->>'units')::bigint) from jsonb_array_elements(f->'duties') x) then raise exception 'target-total-mismatch'; end if;
 if (select count(*) from jsonb_each(assignments))<>jsonb_array_length(f->'duties')
  or exists(select 1 from jsonb_each(assignments) where not exists(select 1 from jsonb_array_elements(f->'duties') d where d->>'id'=key)) then raise exception 'assignment-coverage-shape'; end if;
 for l in select value from jsonb_array_elements(f->'locks') loop
  if jsonb_typeof(l) IS DISTINCT FROM 'object' or l-array['dutyId','engineer']<>'{}' or not ids ? (l->>'engineer')
   or not exists(select 1 from jsonb_array_elements(f->'duties') d where d->>'id'=l->>'dutyId')
   or (select count(*) from jsonb_array_elements(f->'locks') x where x->>'dutyId'=l->>'dutyId')<>1 then raise exception 'invalid-lock'; end if;
 end loop;
 for approval in select value from jsonb_array_elements(f->'approvals') loop
  if jsonb_typeof(approval) IS DISTINCT FROM 'object' or jsonb_typeof(approval->'reason') IS DISTINCT FROM 'string' or coalesce(approval->>'reason','') !~ '[^[:space:]]' or length(approval->>'reason')>2000 then raise exception 'approval-reason-required'; end if;
  case approval->>'rule'
  when 'availability' then
   if approval-array['rule','reason','dutyId','engineer','dates']<>'{}' then raise exception 'invalid-approval'; end if;
   select x into d from jsonb_array_elements(f->'duties') x where x->>'id'=approval->>'dutyId';
   select coalesce(jsonb_agg(day::date::text order by day),'[]') into denied from generate_series((d->>'startDate')::date,(d->>'endDate')::date-1,interval '1 day') day
    where f->'constraints'->(approval->>'engineer')->>day::date::text='no';
   if denied='[]' or denied IS DISTINCT FROM (select jsonb_agg(x order by x) from jsonb_array_elements(approval->'dates') x)
    or not (f->'locks') @> jsonb_build_array(jsonb_build_object('dutyId',approval->'dutyId','engineer',approval->'engineer')) then raise exception 'invalid-availability-approval'; end if;
   scope:='availability/'||(approval->>'dutyId');
  when 'consecutive' then
   if approval-array['rule','reason','duties']<>'{}' or jsonb_array_length(approval->'duties')<>2 then raise exception 'invalid-pair-approval'; end if;
   select x into d from jsonb_array_elements(f->'duties') x where x->>'id'=approval->'duties'->>0;
   select x into previous from jsonb_array_elements(f->'duties') x where x->>'id'=approval->'duties'->>1;
   select x into l from jsonb_array_elements(f->'locks') x where x->>'dutyId'=d->>'id';
   if d is null or previous is null or d->>'endDate'<>previous->>'startDate' or l is null
    or not (f->'locks') @> jsonb_build_array(jsonb_build_object('dutyId',previous->'id','engineer',l->'engineer')) then raise exception 'invalid-pair-approval'; end if;
   scope:='consecutive/'||(d->>'id')||'/'||(previous->>'id');
  when 'boundary' then
   if approval-array['rule','reason','dutyId','neighborId']<>'{}' then raise exception 'invalid-boundary-approval'; end if;
   select x into d from jsonb_array_elements(f->'duties') x where x->>'id'=approval->>'dutyId';
   select x into n from jsonb_array_elements(f->'neighbors') x where x->>'id'=approval->>'neighborId';
   if d is null or n is null or not (d->>'endDate'=n->>'start' or d->>'startDate'=n->>'end')
    or not (f->'locks') @> jsonb_build_array(jsonb_build_object('dutyId',d->'id','engineer',n->'engineer')) then raise exception 'invalid-boundary-approval'; end if;
   scope:='boundary/'||(d->>'id')||'/'||(n->>'ownerMonth')||'/'||(n->>'start')||'/'||(n->>'end')||'/'||(n->>'engineer');
  when 'weekends' then
   if approval-array['rule','reason','engineer','weekends']<>'{}' then raise exception 'invalid-weekend-approval'; end if;
   select coalesce(jsonb_agg(w order by w),'[]') into fixed_weekends from (select distinct d->'weekendId' w from jsonb_array_elements(f->'duties') d
    join jsonb_array_elements(f->'locks') l on l->>'dutyId'=d->>'id' where l->>'engineer'=approval->>'engineer' and d->>'weekendId' is not null) q;
   if jsonb_array_length(fixed_weekends)<2 or fixed_weekends IS DISTINCT FROM (select jsonb_agg(x order by x) from jsonb_array_elements(approval->'weekends') x) then raise exception 'invalid-weekend-approval'; end if;
   scope:='weekends/'||(approval->>'engineer');
  else raise exception 'unknown-approval';
  end case;
  if scope=any(scopes) then raise exception 'duplicate-approval-scope'; end if; scopes:=array_append(scopes,scope);
 end loop;
 for d in select value from jsonb_array_elements(f->'duties') loop
  a:=assignments->(d->>'id'); engineer:=a->>'primary';
  if jsonb_typeof(a) IS DISTINCT FROM 'object' or a-array['primary','secondary']<>'{}' or not a ? 'primary'
   or coalesce(a->'secondary','null') IS DISTINCT FROM d->'secondary' then raise exception 'secondary-changed'; end if;
  select x into l from jsonb_array_elements(f->'locks') x where x->>'dutyId'=d->>'id';
  if l is not null and l->>'engineer' IS DISTINCT FROM engineer then raise exception 'lock-changed'; end if;
  if engineer is null then continue; end if;
  if not ids ? engineer or engineer=d->>'secondary' then raise exception 'ineligible-primary'; end if;
  if exists(select 1 from generate_series((d->>'startDate')::date,(d->>'endDate')::date-1,interval '1 day') day where f->'constraints'->engineer->>day::date::text='no')
   and not exists(select 1 from jsonb_array_elements(f->'approvals') v where v->>'rule'='availability' and v->>'dutyId'=d->>'id' and v->>'engineer'=engineer) then
   -- Who and when, every one (#103): the app names each as a person; notes never travel here.
   raise exception 'unavailable-primary: %',(select jsonb_agg(jsonb_build_object('member',p.who,'day',g.day::date::text) order by g.day,p.who)
    from jsonb_array_elements(f->'duties') o cross join lateral (select assignments->(o->>'id')->>'primary' who) p
    cross join lateral generate_series((o->>'startDate')::date,(o->>'endDate')::date-1,interval '1 day') g(day)
    where p.who is not null and f->'constraints'->p.who->>g.day::date::text='no'
     and not exists(select 1 from jsonb_array_elements(f->'approvals') v where v->>'rule'='availability' and v->>'dutyId'=o->>'id' and v->>'engineer'=p.who));
  end if;
  amount:=(totals->>engineer)::bigint+(d->>'units')::bigint;
  if amount>(targets->>engineer)::bigint then raise exception 'target-exceeded'; end if;
  totals:=jsonb_set(totals,array[engineer],to_jsonb(amount)); assigned:=assigned+(d->>'units')::bigint;
  for n in select value from jsonb_array_elements(f->'neighbors') where value->>'engineer'=engineer loop
   if (d->>'startDate')::date>(n->>'end')::date or (n->>'start')::date>(d->>'endDate')::date then continue; end if;
   -- Touching the same member's duty in the neighbouring month is a back-to-back day: a last
   -- resort, allowed like one inside the month (decision 2026-11-01). A locked duty still
   -- needs its boundary review, and an overlap is never possible.
   if ((d->>'startDate')::date<(n->>'end')::date and (n->>'start')::date<(d->>'endDate')::date) or (l is not null and not exists(select 1 from jsonb_array_elements(f->'approvals') v join jsonb_array_elements(f->'neighbors') reviewed on reviewed->>'id'=v->>'neighborId'
     where v->>'rule'='boundary' and v->>'dutyId'=d->>'id' and reviewed-array['id','source']=n-array['id','source'])) then raise exception 'neighbor-conflict'; end if;
  end loop;
 end loop;
 -- Generate may assign extra weekends and back-to-back duties as a last resort.
 -- Fixed (locked) duties still need the manager's exact approval for either.
 for k in select jsonb_array_elements_text(ids) loop
  select coalesce(jsonb_agg(w order by w),'[]') into fixed_weekends from (select distinct d->'weekendId' w from jsonb_array_elements(f->'duties') d
   join jsonb_array_elements(f->'locks') l on l->>'dutyId'=d->>'id' where l->>'engineer'=k and d->>'weekendId' is not null) q;
  select v into approval from jsonb_array_elements(f->'approvals') v where v->>'rule'='weekends' and v->>'engineer'=k;
  if approval is null and jsonb_array_length(fixed_weekends)>1 then raise exception 'weekend-cap'; end if;
  previous:=null;
  for d in select value from jsonb_array_elements(f->'duties') where assignments->(value->>'id')->>'primary'=k order by value->>'startDate' loop
   if previous->>'endDate'=d->>'startDate'
    and (f->'locks') @> jsonb_build_array(jsonb_build_object('dutyId',previous->'id','engineer',k),jsonb_build_object('dutyId',d->'id','engineer',k))
    and not exists(select 1 from jsonb_array_elements(f->'approvals') v where v->>'rule'='consecutive' and v->'duties'=jsonb_build_array(previous->'id',d->'id')) then raise exception 'consecutive-primary'; end if;
   previous:=d;
  end loop;
 end loop;
 return jsonb_build_object('actualUnits',totals,'assignedUnits',assigned,'missingUnits',total-assigned,'complete',assigned=total);
end $$;

-- Source: schemas/functions/duty_private/save_schedule.sql
CREATE OR REPLACE FUNCTION duty_private.save_schedule(p_state jsonb, p_revision bigint, p_publish text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
#variable_conflict use_column
declare x record; item jsonb; d date; a public.duty_assignments; m public.duty_months; first_day date; last_day date; publication uuid; next_version integer; locks_before jsonb; changed_locks jsonb; f jsonb; result jsonb; allocation public.duty_allocations;
begin
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 perform duty_private.check_revision(p_revision);
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 if jsonb_typeof(p_state->'duties') is distinct from 'array' or jsonb_typeof(p_state->'months') is distinct from 'object' or jsonb_typeof(p_state->'team') is distinct from 'array' or length(p_state::text)>2000000 then raise exception 'Invalid schedule'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('day',a.day,'end_day',a.end_day,'primary_id',a.primary_id,'points',a.points)),'[]') into locks_before
 from public.duty_assignments a where a.publication_id is null and a.locked;
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
   if not a.manager_override and exists(select 1 from public.duty_constraints c where c.member_id in (a.primary_id,a.secondary_id) and c.day=d and c.kind='no'
    and not (c.member_id=a.primary_id and exists(select 1 from public.duty_allocations meta,jsonb_array_elements(meta.approvals) approved
     where meta.month=p_publish and meta.publication_id is null and approved->>'rule'='availability' and approved->>'dutyId'=a.day::text and approved->>'engineer'=a.primary_id::text
     and (approved->'dates') ? d::text))) then
    -- Who and when, every one of them (#103): the app names each as a person (never a note here).
    raise exception 'Availability conflict: %',(select jsonb_agg(jsonb_build_object('member',c.member_id,'day',c.day) order by c.day,c.member_id)
     from public.duty_assignments a2 join public.duty_constraints c on c.kind='no' and c.day>=greatest(a2.day,first_day) and c.day<a2.end_day and c.day<=last_day
      and c.member_id in (a2.primary_id,a2.secondary_id)
     where a2.publication_id is null and not a2.manager_override and duty_private.duty_owner(a2.day)=p_publish
      and not (c.member_id=a2.primary_id and exists(select 1 from public.duty_allocations meta,jsonb_array_elements(meta.approvals) approved
       where meta.month=p_publish and meta.publication_id is null and approved->>'rule'='availability' and approved->>'dutyId'=a2.day::text and approved->>'engineer'=a2.primary_id::text
       and (approved->'dates') ? c.day::text)));
   end if;
  end loop;
  -- An availability approval holds for exactly its person and dates (#103): one whose duty now
  -- has someone else, or whose dates no longer match that person's constraints, is dropped, so
  -- the normal check applies again.
  update public.duty_allocations meta set approvals=coalesce((select jsonb_agg(v) from jsonb_array_elements(meta.approvals) v where v->>'rule'<>'availability'
   or (select jsonb_agg(q order by q) from jsonb_array_elements(v->'dates') q)=(select jsonb_agg(to_jsonb(c.day::text) order by c.day) from public.duty_assignments a2
    join public.duty_constraints c on c.member_id=a2.primary_id and c.kind='no' and c.day>=a2.day and c.day<a2.end_day
    where a2.publication_id is null and a2.day::text=v->>'dutyId' and a2.primary_id::text=v->>'engineer')),'[]')
  where meta.month=p_publish and meta.publication_id is null;
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
 end if;
 update public.duty_workspace set revision=revision+1 where id;
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
   ) else d.manager_override end,d.title,d.extra_points,d.saturday_extra_points,
   -- The new holder's own constraint keeps its approval (#103): the duty is locked to them, as
   -- Plan the month locks an approved availability exception, so reopening never loses it.
   d.locked or (d.id in (a.id,b.id) and (select jsonb_agg(c.day::text order by c.day) from public.duty_constraints c where c.kind='no' and c.member_id=case when d.id=a.id then r.other_id else r.requester_id end and c.day>=d.day and c.day<d.end_day) is not null)
  from public.duty_assignments d where d.publication_id=current_publication;
  -- A weighted swap moves points between the two engineers: the copied plan's targets
  -- follow it, so a reopened copy of this version still matches its plan (2026-11-06).
  insert into public.duty_allocations(month,publication_id,allocation_id,allocation,locks,approvals,accounting_fingerprint,calendar_fingerprint,source_publication_id,generation,origin)
  select month,publication,allocation_id,case when jsonb_typeof(allocation->'targetsUnits')='object' and a.points<>b.points then
    jsonb_set(jsonb_set(allocation,array['targetsUnits',r.requester_id::text],to_jsonb(coalesce((allocation->'targetsUnits'->>r.requester_id::text)::bigint,0)-(a.points*2)::bigint+(b.points*2)::bigint)),
     array['targetsUnits',r.other_id::text],to_jsonb(coalesce((allocation->'targetsUnits'->>r.other_id::text)::bigint,0)-(b.points*2)::bigint+(a.points*2)::bigint))
   else allocation end,
   (select coalesce(jsonb_agg(case when l->>'dutyId'=a.day::text then jsonb_set(l,'{engineer}',to_jsonb(r.other_id::text)) when l->>'dutyId'=b.day::text then jsonb_set(l,'{engineer}',to_jsonb(r.requester_id::text)) else l end),'[]') from jsonb_array_elements(locks) l)
   ||(select coalesce(jsonb_agg(jsonb_build_object('dutyId',x.day::text,'engineer',x.who::text)),'[]') from (values(a.day,a.end_day,r.other_id),(b.day,b.end_day,r.requester_id)) x(day,end_day,who)
    where (select jsonb_agg(c.day::text order by c.day) from public.duty_constraints c where c.kind='no' and c.member_id=x.who and c.day>=x.day and c.day<x.end_day) is not null and not exists(select 1 from jsonb_array_elements(locks) l where l->>'dutyId'=x.day::text)),
   (select coalesce(jsonb_agg(v),'[]') from jsonb_array_elements(approvals) v where
    not (v->>'rule' in ('availability','boundary') and v->>'dutyId' in (a.day::text,b.day::text))
    and not (v->>'rule'='consecutive' and ((v->'duties') ? a.day::text or (v->'duties') ? b.day::text))
    and not (v->>'rule'='weekends' and v->>'engineer' in (r.requester_id::text,r.other_id::text)))
   -- The admin's approval, for exactly that person and those dates (#103).
   ||(select coalesce(jsonb_agg(jsonb_build_object('rule','availability','reason',coalesce(nullif(reason,''),'Swap approved by an admin'),'dutyId',x.day::text,'engineer',x.who::text,'dates',x.dates)),'[]')
    from (select y.day,y.who,(select jsonb_agg(c.day::text order by c.day) from public.duty_constraints c where c.kind='no' and c.member_id=y.who and c.day>=y.day and c.day<y.end_day) dates from (values(a.day,a.end_day,r.other_id),(b.day,b.end_day,r.requester_id)) y(day,end_day,who)) x where x.dates is not null),accounting_fingerprint,calendar_fingerprint,current_publication,generation,'swap' from public.duty_allocations where publication_id=current_publication;
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
