-- Supabase CPU at its limit (#86, Production evidence on the issue). The stale-revision refusal
-- ("The team data changed. Refresh and try again.") and every other "refresh first" refusal
-- were raised with SQLSTATE 40001 (serialization_failure). PostgREST re-runs a transaction that
-- fails with 40001, but a stale p_revision (or fingerprint) never matches again, so each such
-- request looped forever: ~600 rolled-back transactions a second since 2026-11-08 (96.7% of
-- database time). They now raise SQLSTATE PT409, which PostgREST returns once as HTTP 409.
-- Messages are unchanged (the client maps them by text), as are signatures, grants and data.

-- Source: schemas/functions/duty_private/check_revision.sql
-- Stale-revision and other "refresh first" refusals use SQLSTATE PT409 (HTTP 409), never
-- 40001/40P01: PostgREST re-runs a transaction that fails with a serialization or deadlock
-- code, and a stale p_revision can never match, so the request looped forever (#86).
CREATE OR REPLACE FUNCTION duty_private.check_revision(p_revision bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare current_revision bigint;
begin
 if not duty_private.is_member() then raise exception 'Your membership is not approved' using errcode='42501'; end if;
 select revision into current_revision from public.duty_workspace where id for update;
 -- Membership may have changed while waiting for the workspace lock.
 if not duty_private.is_member() then raise exception 'Your membership is not approved' using errcode='42501'; end if;
 if current_revision is distinct from p_revision then raise exception 'The team data changed. Refresh and try again.' using errcode='PT409'; end if;
end $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

-- Source: schemas/functions/duty_private/allocation_rebind.sql
-- Republishing a restored/generated arrangement never replays old origins.
-- Carried reservations retain their IDs; still-outstanding cancelled plans can
-- bind new real capacity using fresh IDs and the retained source publication.
CREATE OR REPLACE FUNCTION duty_private.allocation_rebind(s jsonb, publication jsonb, source_publication uuid, allocation_id uuid, instant bigint) RETURNS jsonb
 LANGUAGE plpgsql STABLE SET search_path TO '' AS $$
#variable_conflict use_column
declare original jsonb; r jsonb; c jsonb; e jsonb; after_state jsonb; finish jsonb; excluded jsonb; reservations jsonb:=publication->'reservations';
 atoms jsonb; day text; a jsonb; cell bigint; remaining bigint; off bigint; ref jsonb; key text; wanted bigint[]; position integer;
begin
 select x->'operation'->'after' into original from jsonb_array_elements(s->'events') x where x->'operation'->'after'->>'id'=source_publication::text limit 1;
 if original is null then raise exception 'Review missing allocation publication lineage'; end if;
 e:=jsonb_build_object('sequence',coalesce((s->'events'->-1->>'sequence')::bigint,0)+1,'sourceKey','publication/'||(publication->>'id')||'/'||(coalesce((s->'events'->-1->>'sequence')::bigint,0)+1),'at',instant,
  'actor',coalesce(auth.uid()::text,'system'),'operation',jsonb_build_object('kind','publication','month',publication->'month','beforeId',s->'publications'->(publication->>'month')->'id','after',publication));
 finish:=duty_private.compensation_transition(s,e); excluded:=finish->'excluded'; atoms:=finish->'atoms';
 after_state:=duty_private.compensation_apply(s,e);
 for r in select value from jsonb_array_elements(reservations) loop excluded:=duty_private.compensation_exclude(excluded,r->'capacity'); end loop;
 for r in select value from jsonb_array_elements(original->'reservations') order by value->>'id' COLLATE "C" loop
  c:=after_state->'contributions'->(r->>'id');
  if c->>'status'='settled' or exists(select 1 from jsonb_array_elements(reservations) kept where kept->>'id'=r->>'id') then continue; end if;
  wanted:='{}';
  for off in 0..(r->'capacity'->>'units')::bigint-1 loop
   ref:=duty_private.compensation_slice(r->'claim',1,off);
   -- Historical ancestors may already have carried or earned descendants with
   -- different IDs. Compare original source slices, not contribution IDs.
   if exists(select 1 from jsonb_each(after_state->'contributions') child where
    (child.value->>'status'='settled' or (child.value->>'status' in ('pending','held') and exists(select 1 from jsonb_array_elements(reservations) kept where kept->>'id'=child.key)))
    and duty_private.compensation_locate(jsonb_build_object('claims',jsonb_build_array(duty_private.compensation_segment(child.value->'claim','{"at":0,"sequence":0,"lotId":"lineage"}'))),ref) is not null) then continue; end if;
   -- Explicit manager release is not an invitation to reserve the same work
   -- again through an older publication's metadata.
   if exists(select 1 from jsonb_array_elements(s->'events') released join jsonb_each(s->'contributions') child on child.key=released->'operation'->>'contributionId'
    where released->'operation'->>'kind'='release' and duty_private.compensation_locate(jsonb_build_object('claims',jsonb_build_array(
     duty_private.compensation_segment(child.value->'claim','{"at":0,"sequence":0,"lotId":"lineage"}'))),ref) is not null) then raise exception 'Repayment lineage changed. Refresh and review.' using errcode='PT409'; end if;
   if duty_private.compensation_locate(jsonb_build_object('claims',duty_private.compensation_candidates(after_state)),ref) is null then raise exception 'Repayment lineage changed. Refresh and review.' using errcode='PT409'; end if;
   wanted:=array_append(wanted,off);
  end loop;
  remaining:=cardinality(wanted); position:=1;
  for day,a in select * from jsonb_each(atoms) where value->>'primaryId'=r->'claim'->>'debtorId' order by key loop
   if (a->>'endInstantMs')::bigint<=instant then continue; end if;
   for cell in 0..(a->>'units')::bigint-1 loop
    if remaining=0 then exit; end if;
    if coalesce(excluded->day,'[]') @> jsonb_build_array(cell) then continue; end if;
    off:=wanted[position]; key:='allocation/'||allocation_id||'/rebind/'||md5((publication->>'id')||'/'||(r->>'id')||'/'||off);
    ref:=duty_private.compensation_slice(r->'claim',1,off);
    reservations:=reservations||jsonb_build_array(jsonb_build_object('id',key,'capacity',jsonb_build_object('date',day,'offset',cell,'units',1),'claim',ref));
    excluded:=duty_private.compensation_exclude(excluded,jsonb_build_object('date',day,'offset',cell,'units',1));
    -- Reserve selected source units in the preview too, so later plans cannot
    -- borrow a prefix already earmarked by this operation.
    after_state:=jsonb_set(after_state,array['contributions',key],jsonb_build_object('id',key,'claim',ref,'status','pending'));
    remaining:=remaining-1; position:=position+1;
   end loop;
  end loop;
  if remaining<>0 then raise exception 'Repayment capacity changed. Refresh and review.' using errcode='PT409'; end if;
 end loop;
 return jsonb_build_object('fingerprint',md5((s->'events')::text),'intents',publication->'intents','reservations',reservations);
end $$;

-- Source: schemas/functions/duty_private/compensation.sql
CREATE OR REPLACE FUNCTION duty_private.compensation(p_operation jsonb, p_source_key text, p_reason text, p_revision bigint, p_fingerprint text DEFAULT NULL, p_cutoff bigint DEFAULT NULL) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
#variable_conflict use_column
declare s jsonb; projected jsonb; instant bigint; first_count bigint; key text; previous public.duty_compensation_events; allowed text[]; kind text:=p_operation->>'kind';
begin
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 perform 1 from public.duty_workspace where id for update;
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 if jsonb_typeof(p_operation) IS DISTINCT FROM 'object' or length(p_operation::text)>100000 or kind is null then raise exception 'Invalid compensation operation'; end if;
 case kind
 when 'claim' then allowed:=array['kind','debtorId','creditorId','units'];
 when 'adjust' then allowed:=array['kind','claim','units','mode'];
 when 'correct' then allowed:=array['kind','lotId','deltaUnits'];
 when 'reverse-settlement' then allowed:=array['kind','settlementId'];
 when 'release' then allowed:=array['kind','contributionId'];
 when 'reconcile' then allowed:=array['kind'];
 else raise exception 'Invalid compensation operation';
 end case;
 if p_operation-allowed<>'{}' then raise exception 'Invalid compensation fields'; end if;
 if kind<>'reconcile' then
  if p_source_key is null or p_source_key !~ '^[A-Za-z0-9][A-Za-z0-9_./:-]{0,159}$' or coalesce(btrim(p_reason,U&'\0009\000A\000B\000C\000D\0020\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000\FEFF'),'')='' or length(p_reason)>2000 then raise exception 'Source key and reason required'; end if;
  key:='manual/'||auth.uid()::text||'/'||p_source_key;
  select * into previous from public.duty_compensation_events where source_key=key;
  if found and (previous.operation<>p_operation or previous.reason is distinct from p_reason or previous.actor<>auth.uid()::text) then raise exception 'source-key-conflict'; end if;
 end if;
 -- An identical authorized retry may carry its original revision. It cannot
 -- write a second discretionary event or apply changed content under that key.
 if previous.sequence is null then perform duty_private.check_revision(p_revision); end if;
 s:=duty_private.compensation_state(); first_count:=jsonb_array_length(s->'events');
 instant:=greatest(duty_private.compensation_now(),coalesce((s->'events'->-1->>'at')::bigint,0));
 s:=duty_private.compensation_reconcile(s,instant);
 if previous.sequence is null and p_fingerprint is not null and p_fingerprint<>md5((s->'events')::text) then raise exception 'Compensation changed. Refresh and review.' using errcode='PT409'; end if;
 if kind<>'reconcile' then s:=duty_private.compensation_append(s,p_operation,key,instant,auth.uid()::text,p_reason); end if;
 if jsonb_array_length(s->'events')<>first_count then update public.duty_workspace set revision=revision+1 where id; end if;
 if p_cutoff is not null then
  if p_cutoff<instant or p_cutoff>9007199254740991 then raise exception 'projection-before-now'; end if;
  projected:=duty_private.compensation_view(duty_private.compensation_reconcile(s,p_cutoff,false));
 end if;
 return jsonb_build_object('revision',(select revision from public.duty_workspace where id),'actualAtMs',instant,'cutoffMs',p_cutoff,
  'fingerprint',md5((s->'events')::text),'actual',duty_private.compensation_view(s),
  'projected',case when projected is not null then jsonb_build_object('claims',projected->'claims','net',projected->'net') end);
end $$;

-- Source: schemas/functions/duty_private/compensation_publication.sql
-- edit: a server-built published duty edit, {intents, reason}. Its permanent
-- intents join the carried ones; the reason is the event's manager-only audit.
CREATE OR REPLACE FUNCTION duty_private.compensation_publication(month text, publication uuid, metadata jsonb DEFAULT NULL, deleting boolean DEFAULT false, edit jsonb DEFAULT NULL) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
#variable_conflict use_column
declare s jsonb; before_pub jsonb; after_pub jsonb; op jsonb; atoms jsonb; old_atoms jsonb; reservations jsonb; instant bigint; known jsonb; allocation public.duty_allocations; facts jsonb; checked jsonb; assignments jsonb; ledger text; key text; before_state jsonb;
begin
 perform 1 from public.duty_workspace where id for update;
 s:=duty_private.compensation_state(); before_pub:=s->'publications'->month;
 instant:=greatest(duty_private.compensation_now(),coalesce((s->'events'->-1->>'at')::bigint,0));
 s:=duty_private.compensation_reconcile(s,instant);
 -- Ordinary copies retain accounting metadata and contribution identities.
 if before_pub->>'id'=publication::text then return; end if;
 if before_pub is null and publication is null then return; end if;
 ledger:=md5((s->'events')::text);
 select * into allocation from public.duty_allocations where publication_id=publication and duty_allocations.month=month;
 -- A new plan for a published month replaces that month's ledger entries in this
 -- transaction (decision 2026-11-01): audited corrections reverse every lot its
 -- publications booked and the publication is deleted, cancelling its pending
 -- repayments; the plan is then booked as a first publication. Refused while another
 -- month's repayment uses those lots (review-replan-later:<month>) or once it started. A month
 -- whose only version was deleted while its lots couldn't be reversed keeps them live until
 -- then; they are reversed too.
 if not deleting and publication is not null and allocation.month is not null and allocation.source_publication_id is null then
  -- The ledger may have moved since the plan was confirmed (another month published): the
  -- re-plan and the binding below re-check every source, so the plan publishes whenever it
  -- still books (decision 2026-11-01); only a plan that no longer books asks to refresh.
  -- A month that can't be re-planned says why: refreshing would not change that.
  begin s:=duty_private.compensation_replan(s,month,instant,true);
  exception when others then
   if SQLERRM not like 'review-replan-%' and allocation.accounting_fingerprint<>ledger then raise exception 'Compensation changed. Refresh and review.' using errcode='PT409'; end if;
   raise;
  end;
  before_pub:=null;
 end if;
 -- Deleting a month's only version removes what it booked (decision 2026-11-07): the same
 -- audited corrections as a re-plan reverse every live lot the month's publications booked and
 -- the deletion cancels its pending repayments, so with no version left every net is zero. The
 -- kept draft copy is then a plan of its own: publishing it books it again. When worked or used
 -- points make that impossible (review-replan-*: started, a later month's repayment settled,
 -- settled by hand), the lots stay live as before and a new plan reverses them. A later month's
 -- pending repayment of those lots is released and becomes a debt the other way: a deleted
 -- month counts as nothing (decision 2026-11-07).
 if deleting and publication is null and before_pub is not null then
  begin
   s:=duty_private.compensation_replan(s,month,instant,true,'Deleted the published '||month||' version');
   -- A new allocation identity: its intents are booked again, never matched to the reversed ones.
   update public.duty_allocations a set source_publication_id=null,allocation_id=gen_random_uuid()
    where a.month=compensation_publication.month and a.publication_id is null and a.source_publication_id::text=before_pub->>'id';
   return;
  exception when raise_exception then
   if SQLERRM not like 'review-replan-%' then raise; end if;
  end;
 end if;
 after_pub:=duty_private.compensation_snapshot(publication);
 if deleting and after_pub is not null then
  select x->'operation'->'after' into known from jsonb_array_elements(s->'events') x where x->'operation'->>'kind'='publication' and x->'operation'->'after'->>'id'=publication::text limit 1;
  -- Pre-cutover history was never committed in this ledger. For an unknown
  -- version compare only this live transition; never replay its old origins.
  if known is not null then after_pub:=known; end if;
  if known is not null and duty_private.compensation_replanned(s,month,publication) then raise exception '% was re-planned after this version, so its points can''t come back. Reopen the month and change its plan instead.',to_char(to_date(month||'-01','YYYY-MM-DD'),'FMMonth YYYY'); end if;
 end if;
 if after_pub is not null and known is null then
  atoms:=duty_private.compensation_atoms(after_pub); old_atoms:=duty_private.compensation_atoms(before_pub);
  select coalesce(jsonb_agg(r order by r->>'id' COLLATE "C"),'[]') into reservations from jsonb_array_elements(coalesce(before_pub->'reservations','[]')) r
   where atoms->(r->'capacity'->>'date')->>'primaryId'=old_atoms->(r->'capacity'->>'date')->>'primaryId'
   and (r->'capacity'->>'offset')::bigint+(r->'capacity'->>'units')::bigint<=(atoms->(r->'capacity'->>'date')->>'units')::bigint
   and ((atoms->(r->'capacity'->>'date')->>'endInstantMs')::bigint>instant
    or atoms->(r->'capacity'->>'date')->'endInstantMs'=old_atoms->(r->'capacity'->>'date')->'endInstantMs');
  after_pub:=after_pub||jsonb_build_object('reservations',reservations,'intents',coalesce(before_pub->'intents','[]'));
  -- Existing rota RPCs permit historical manual edits. Keep already completed
  -- accounting facts unchanged while recording the new physical version ID.
  if before_pub is not null then
   after_pub:=jsonb_set(after_pub,'{duties}',coalesce((select jsonb_agg(d order by d->>'startDate') from (
    select d from jsonb_array_elements(before_pub->'duties') d where (extract(epoch from (((d->>'endDate')::date+time '09:00') at time zone 'Asia/Jerusalem'))*1000)::bigint<=instant
    union all select d from jsonb_array_elements(after_pub->'duties') d where not exists(
     select 1 from jsonb_array_elements(before_pub->'duties') old where (extract(epoch from (((old->>'endDate')::date+time '09:00') at time zone 'Asia/Jerusalem'))*1000)::bigint<=instant
     and (d->>'startDate')::date<(old->>'endDate')::date and (old->>'startDate')::date<(d->>'endDate')::date)
    -- A new combined weekend may overlap only a completed Friday. Preserve its
    -- pending Saturday atom and its real Sunday handover instead of dropping it.
    union all select jsonb_build_object('startDate',day::date,'endDate',day::date+1,'primaryId',d->'primaryId','units',1)
    from jsonb_array_elements(after_pub->'duties') d cross join lateral generate_series((d->>'startDate')::date,(d->>'endDate')::date-1,interval '1 day') day
    where (d->>'endDate')::date=(d->>'startDate')::date+2
     and exists(select 1 from jsonb_array_elements(before_pub->'duties') old where (extract(epoch from (((old->>'endDate')::date+time '09:00') at time zone 'Asia/Jerusalem'))*1000)::bigint<=instant
      and (d->>'startDate')::date<(old->>'endDate')::date and (old->>'startDate')::date<(d->>'endDate')::date)
     and not exists(select 1 from jsonb_array_elements(before_pub->'duties') old where (extract(epoch from (((old->>'endDate')::date+time '09:00') at time zone 'Asia/Jerusalem'))*1000)::bigint<=instant
      and day::date>=(old->>'startDate')::date and day::date<(old->>'endDate')::date)
   ) a),'[]'));
  end if;
  if allocation.month is not null then
   if metadata is not null then raise exception 'Allocation accounting is server-owned'; end if;
   if allocation.source_publication_id is null then
    if before_pub is not null and allocation.allocation->'transfers'<>'[]' then raise exception 'Review published transfer lineage before changing allocation'; end if;
    facts:=duty_private.generation_facts(month);
    begin metadata:=duty_private.allocation_bind(facts,allocation.allocation,s,allocation.allocation_id,after_pub,instant);
    exception when others then
     if allocation.accounting_fingerprint<>ledger then raise exception 'Compensation changed. Refresh and review.' using errcode='PT409'; end if;
     raise;
    end;
   elsif allocation.origin<>'swap' then
    if allocation.source_publication_id::text is distinct from s->'publications'->month->>'id' and duty_private.compensation_replanned(s,month,allocation.source_publication_id) then raise exception '% was re-planned after this version, so its points can''t come back. Reopen the month and change its plan instead.',to_char(to_date(month||'-01','YYYY-MM-DD'),'FMMonth YYYY'); end if;
    metadata:=duty_private.allocation_rebind(s,after_pub,allocation.source_publication_id,allocation.allocation_id,instant);
   end if;
  end if;
  -- Client metadata (a month without a confirmed allocation) cannot borrow the
  -- identities the server reserves for compiled allocation intent and system
  -- uneven-month credit, which duty_balance would otherwise label as such.
  if allocation.month is null and metadata is not null and exists(select 1 from jsonb_array_elements(case when jsonb_typeof(metadata->'intents')='array' then metadata->'intents' else '[]'::jsonb end) i
   where jsonb_typeof(i)='object' and not coalesce(s->'intents' ? (i->>'id'),false) and (starts_with(coalesce(i->>'id',''),'allocation/')
    or exists(select 1 from jsonb_array_elements(case when jsonb_typeof(i->'route')='array' then i->'route' else '[]'::jsonb end) l where jsonb_typeof(l)='object'
     and (exists(select 1 from jsonb_array_elements(case when jsonb_typeof(l->'transferIds')='array' then l->'transferIds' else '[]'::jsonb end) t where starts_with(coalesce(t#>>'{}',''),'uneven/'))
      or exists(select 1 from jsonb_array_elements(case when jsonb_typeof(l->'counterparts')='array' then l->'counterparts' else '[]'::jsonb end) c where starts_with(coalesce(c->>'id',''),'uneven/')))))) then raise exception 'invalid-intent'; end if;
  if metadata is not null then
   if jsonb_typeof(metadata) IS DISTINCT FROM 'object' or metadata - array['fingerprint','reservations','intents']<>'{}' then raise exception 'Invalid compensation metadata'; end if;
   if metadata->>'fingerprint' is distinct from md5((s->'events')::text) then raise exception 'Compensation changed. Refresh and review.' using errcode='PT409'; end if;
   after_pub:=after_pub||jsonb_build_object('reservations',coalesce(metadata->'reservations',reservations),'intents',coalesce(metadata->'intents',before_pub->'intents','[]'));
  end if;
  if edit is not null then
   if metadata is not null or deleting or before_pub is null then raise exception 'invalid-publication-edit'; end if;
   after_pub:=jsonb_set(after_pub,'{intents}',(after_pub->'intents')||coalesce(edit->'intents','[]'));
  end if;
 end if;
 op:=jsonb_build_object('kind','publication','month',month,'beforeId',before_pub->'id','after',after_pub);
 -- Unknown pre-cutover versions preserve completed facts below the ordinary
 -- transition rules. Known deletion uses the core's terminal handling.
 -- Deleting back to a known earlier version is that version's exact undo (decision 2026-11-06).
 if deleting and (after_pub is null or known is not null) and before_pub is not null then
  op:=op||case when after_pub is null then '{"mode":"delete"}' else '{"mode":"delete","revert":true}' end::jsonb;
 end if;
 key:='publication/'||coalesce(publication::text,'none')||'/'||(coalesce((s->'events'->-1->>'sequence')::bigint,0)+1); before_state:=s;
 s:=duty_private.compensation_append(s,op,key,instant,coalesce(auth.uid()::text,'system'),nullif(edit->>'reason',''));
 -- A repayment this change left held (a revert or an edit undid the debt it repays) is never
 -- lost: its planned work becomes a debt the other way (decision 2026-11-07).
 perform duty_private.compensation_release_held(before_state,s,key||'/',instant,coalesce(auth.uid()::text,'system'),
  'Repayment released: a change to '||to_char(to_date(month||'-01','YYYY-MM-DD'),'FMMonth YYYY')||' undid the debt it repaid',true);
end $$;

-- Source: schemas/functions/duty_private/confirm_allocation.sql
CREATE OR REPLACE FUNCTION duty_private.confirm_allocation(p_month text, p_allocation jsonb, p_locks jsonb, p_approvals jsonb, p_revision bigint, p_fingerprint text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
declare ctx jsonb; facts jsonb; assignments jsonb; checked jsonb; projected jsonb; old_meta public.duty_allocations; instant bigint; fits boolean:=true; plan_facts jsonb;
begin
 ctx:=duty_private.generation_context(p_month,p_revision);
 if p_fingerprint IS DISTINCT FROM ctx->>'fingerprint' then raise exception 'Generation inputs changed. Refresh and review.' using errcode='PT409'; end if;
 if length(p_allocation::text)>1000000 or length(p_approvals::text)>100000 or length(p_locks::text)>100000 then raise exception 'Allocation too large'; end if;
 if not exists(select 1 from public.duty_months where month=p_month and status='draft') then raise exception 'An open month draft is required'; end if;
 facts:=(ctx->'facts')||jsonb_build_object('locks',p_locks,'approvals',p_approvals);
 -- A split weekend never changes planning (decision 2026-11-07): fair shares and uneven credit
 -- see each split, locked or not, as the weekend it came from (its halves' sum), as the
 -- browser's planning context does. Generate's own checks keep the real duties.
 plan_facts:=facts||jsonb_build_object('duties',(select jsonb_agg(jsonb_build_object('id',k,'units',u) order by k)
  from (select coalesce(d->>'weekendId',d->>'id') k,sum((d->>'units')::bigint) u from jsonb_array_elements(facts->'duties') d group by 1) g));
 if exists(select 1 from jsonb_array_elements(p_locks) l where not exists(select 1 from jsonb_array_elements(facts->'duties') d where d->>'id'=l->>'dutyId' and d->>'primary'=l->>'engineer')) then raise exception 'Lock requires its existing primary assignment'; end if;
 select jsonb_object_agg(d->>'id',jsonb_build_object('primary',
  (select l->'engineer' from jsonb_array_elements(p_locks) l where l->>'dutyId'=d->>'id'),'secondary',d->'secondary')) into assignments from jsonb_array_elements(facts->'duties') d;
 checked:=duty_private.generation_validate(facts,p_allocation->'targetsUnits',assignments);
 select * into old_meta from public.duty_allocations where month=p_month and publication_id is null;
 -- Copies retain original reviewed provenance, even when its claims have already
 -- settled. A new proposal must use current unreserved sources instead.
 if old_meta.source_publication_id is null or old_meta.allocation IS DISTINCT FROM p_allocation then
  -- A new plan for a published month is checked against the ledger without that month's
  -- own entries, as its publication will book it (decision 2026-11-01). Re-planned now and
  -- projected after, as generation_context does: the re-plan keys carry the ledger position.
  projected:=duty_private.compensation_state();
  instant:=greatest((ctx->>'actualAtMs')::bigint,coalesce((projected->'events'->-1->>'at')::bigint,0));
  projected:=duty_private.compensation_replan(projected,p_month,instant);
  projected:=duty_private.compensation_reconcile(projected,greatest(instant,(ctx->>'coverageStartMs')::bigint,coalesce((projected->'events'->-1->>'at')::bigint,0)),false);
  perform duty_private.allocation_compile(facts,p_allocation,checked->'actualUnits',projected);
  -- The stored fair shares, saved again unchanged, only have to still split into the month's
  -- duties (decision 2026-11-07), so Save stores exactly what was typed. A new baseline must
  -- be the month's ordinary fit.
  if old_meta.month is not null and old_meta.allocation->'baselineUnits'=p_allocation->'baselineUnits' then
   perform duty_private.allocation_kept_baseline(plan_facts,p_allocation->'baselineUnits');
  else perform duty_private.allocation_baseline(plan_facts,p_allocation->'baselineUnits'); end if;
  -- The transfer list is derived, never chosen: the per-person changes and the
  -- recorded pairs must give exactly this list under the current seniority.
  if p_allocation->'transfers' IS DISTINCT FROM duty_private.allocation_transfers(facts->'seniority',p_allocation->'changes',p_allocation->'pairs') then raise exception 'invalid-derived-transfers'; end if;
  -- Uneven-month credit is derived too: exactly the fitted baseline's excess over the
  -- plain split that each creditor still carries after permanent changes, owed by the
  -- members still below it, paired under the current seniority. A manager can neither
  -- add, enlarge, redirect nor drop it.
  if coalesce(p_allocation->'uneven','[]'::jsonb) IS DISTINCT FROM duty_private.allocation_uneven(plan_facts,p_allocation->'baselineUnits',p_allocation->'changes') then raise exception 'invalid-uneven-credit'; end if;
  -- A stored baseline the month's duties can no longer split into (a published edit changed their
  -- points, and the copied plan's calendar follows it) is replaced by the new plan's (2026-11-06).
  if old_meta.month is not null and old_meta.allocation->'baselineUnits'<>p_allocation->'baselineUnits' then
   begin perform duty_private.allocation_baseline(plan_facts,old_meta.allocation->'baselineUnits');
   exception when raise_exception then if SQLERRM<>'invalid-ordinary-baseline' then raise; end if; fits:=false;
   end;
  end if;
  if fits and old_meta.month is not null and old_meta.calendar_fingerprint=md5((select jsonb_agg(d-array['primary','secondary'] order by d->>'id')::text from jsonb_array_elements(facts->'duties') d))
   and (select array_agg(key order by key) from jsonb_each(old_meta.allocation->'baselineUnits'))=(select array_agg(key order by key) from jsonb_each(p_allocation->'baselineUnits'))
   and old_meta.allocation->'baselineUnits'<>p_allocation->'baselineUnits' then raise exception 'Ordinary baseline is immutable. Classify target changes as transfers.'; end if;
 end if;
 insert into public.duty_allocations(month,allocation,locks,approvals,accounting_fingerprint,calendar_fingerprint)
 values(p_month,p_allocation,p_locks,p_approvals,ctx->>'accountingFingerprint',md5((select jsonb_agg(d-array['primary','secondary'] order by d->>'id')::text from jsonb_array_elements(facts->'duties') d)))
 on conflict(month,publication_id) do update set allocation=excluded.allocation,locks=excluded.locks,approvals=excluded.approvals,
  accounting_fingerprint=excluded.accounting_fingerprint,calendar_fingerprint=excluded.calendar_fingerprint,generation=null,
  allocation_id=case when duty_allocations.allocation=excluded.allocation then duty_allocations.allocation_id else gen_random_uuid() end,
  source_publication_id=case when duty_allocations.allocation=excluded.allocation then duty_allocations.source_publication_id end;
 update public.duty_assignments a set locked=exists(select 1 from jsonb_array_elements(p_locks) l where l->>'dutyId'=a.day::text) where a.publication_id is null and duty_private.duty_owner(a.day)=p_month;
 update public.duty_workspace set revision=revision+1 where id;
 return duty_private.generation_context(p_month,(select revision from public.duty_workspace where id));
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
  -- Consent may precede an audited availability override, but never bypasses
  -- active membership, emergency duplication, overlap, weekends or future dates.
  perform duty_private.validate_swap(a.id,b.id,current_publication,p_action='accept' or length(reason)>0);
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
 update public.duty_workspace set revision=revision+1 where id;
 return duty_private.generation_context(p_month,(select revision from public.duty_workspace where id));
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
     and (approved->'dates') ? d::text))) then raise exception 'Availability conflict on %',d; end if;
  end loop;
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
