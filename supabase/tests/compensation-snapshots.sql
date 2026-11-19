-- Empty disposable LOCAL only. Synthetic fixtures; always rolls back.
-- #86: the ledger fold is cached. The cached state always equals a full replay, a warm
-- read folds nothing (it returns the cached fold), a new event folds only itself, a fold
-- cached by other replay code is ignored, read-only transactions still answer, and only
-- managers can read the cache (like the events it derives from).
\set ON_ERROR_STOP on
begin;
do $$begin
 if exists(select 1 from auth.users) or exists(select 1 from public.duty_members) or exists(select 1 from public.duty_compensation_events)
  or exists(select 1 from public.duty_compensation_snapshots) then raise exception 'Requires empty disposable LOCAL';end if;
end$$;
-- The reference: every event folded from the start, exactly as before the cache.
create function pg_temp.replay() returns jsonb language plpgsql as $$
declare s jsonb:='{"events":[],"members":{},"lots":{},"claims":[],"contributions":{},"settlements":{},"publications":{},"intents":{},"normalizations":[]}'::jsonb; e record;
begin
 for e in select * from public.duty_compensation_events order by sequence loop
  s:=duty_private.compensation_apply(s,jsonb_build_object('sequence',e.sequence,'sourceKey',e.source_key,'at',e.at,'actor',e.actor,'operation',e.operation)
   ||case when e.reason is null then '{}'::jsonb else jsonb_build_object('reason',e.reason) end);
 end loop;
 return s;
end$$;
create function pg_temp.same(label text) returns void language plpgsql as $$
begin
 if duty_private.compensation_state() is distinct from pg_temp.replay() then raise exception '%: cached ledger state differs from a full replay',label;end if;
 if (select sequence from public.duty_compensation_snapshots)<>(select max(sequence) from public.duty_compensation_events) then raise exception '%: cache is not at the latest event',label;end if;
end$$;
create function pg_temp.as_member(n int) returns void language sql as $$
 select set_config('request.jwt.claim.sub','86100000-0000-0000-0000-00000000000'||n,true);
$$;
create function pg_temp.rev() returns bigint language sql security definer as $$select revision from public.duty_workspace where id$$;
grant execute on function pg_temp.as_member(int),pg_temp.rev() to authenticated;
-- No events: nothing is cached.
do $$begin
 if duty_private.compensation_state()<>pg_temp.replay() or exists(select 1 from public.duty_compensation_snapshots) then raise exception 'Empty ledger cached a fold';end if;
end$$;
-- 1 admin, 2 and 3 engineers (each membership change is a ledger event).
insert into auth.users(id,email) select ('86100000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'snapshot-'||i||'@example.invalid' from generate_series(1,3) i;
insert into public.duty_members(id,email,name,role,status,active)
select id,email,'Synthetic '||right(id::text,1),case when right(id::text,1)='1' then 'admin' else 'engineer' end,'approved',true from auth.users;
-- Manual claims through the checked RPC: each write folds the cached state plus its own event.
set local role authenticated;
do $$begin
 perform pg_temp.as_member(1);
 for i in 1..4 loop
  perform public.duty_compensation(jsonb_build_object('kind','claim','debtorId','86100000-0000-0000-0000-00000000000'||(2+i%2),
   'creditorId','86100000-0000-0000-0000-00000000000'||(3-i%2),'units',i),'snapshot-claim-'||i,'Synthetic reason '||i,pg_temp.rev());
 end loop;
end$$;
reset role;
select pg_temp.same('after writes');
-- A warm read returns the cached fold without folding again: a marker planted in the cache
-- comes back, and a new event is folded onto it (only the new event).
update public.duty_compensation_snapshots set state=state||'{"probe":true}';
do $$declare s jsonb;begin
 s:=duty_private.compensation_state();
 if s->'probe' is distinct from 'true' then raise exception 'Warm read replayed the ledger instead of using the cache';end if;
end$$;
set local role authenticated;
do $$begin
 perform pg_temp.as_member(1);
 perform public.duty_compensation('{"kind":"claim","debtorId":"86100000-0000-0000-0000-000000000002","creditorId":"86100000-0000-0000-0000-000000000001","units":1}','snapshot-claim-5','Synthetic reason 5',pg_temp.rev());
end$$;
reset role;
do $$declare s jsonb;begin
 s:=duty_private.compensation_state();
 if s->'probe' is distinct from 'true' or (s-'probe') is distinct from pg_temp.replay() then raise exception 'New event was not folded onto the cached state';end if;
end$$;
update public.duty_compensation_snapshots set state=state-'probe';
select pg_temp.same('after incremental fold');
-- A fold cached by different replay code (another hash) is never used, and is replaced.
update public.duty_compensation_snapshots set code=md5('older replay code'),state=state||'{"probe":true}';
select pg_temp.same('after replay code change');
do $$begin if (select count(*) from public.duty_compensation_snapshots)<>1 or exists(select 1 from public.duty_compensation_snapshots where code=md5('older replay code')) then raise exception 'Stale replay code cache kept';end if;end$$;
-- A cache ahead of the visible events (impossible when committed) replays from the start.
update public.duty_compensation_snapshots set sequence=sequence+10,state=state||'{"probe":true}';
do $$begin if duty_private.compensation_state()<>pg_temp.replay() then raise exception 'Cache ahead of the ledger was trusted';end if;end$$;
delete from public.duty_compensation_snapshots;
-- Read-only transactions (and balance) still answer; they only skip writing the cache.
savepoint ro;
set local transaction_read_only=on;
do $$begin if duty_private.compensation_state()<>pg_temp.replay() then raise exception 'Read-only fold differs';end if;end$$;
rollback to savepoint ro;
-- Readers: managers see the cache like the ledger; engineers and anon see nothing and nobody writes it.
select pg_temp.same('rebuilt');
set local role authenticated;
do $$begin
 perform pg_temp.as_member(1);
 if (select count(*) from public.duty_compensation_snapshots)<>1 then raise exception 'Manager cannot read the cache';end if;
 perform public.duty_balance();
 perform pg_temp.as_member(2);
 if exists(select 1 from public.duty_compensation_snapshots) then raise exception 'Engineer read the ledger cache';end if;
 perform public.duty_balance();
 begin
  delete from public.duty_compensation_snapshots;
  raise exception 'Client deleted the cache';
 exception when insufficient_privilege then null;
 end;
 begin
  insert into public.duty_compensation_snapshots(code,sequence,state) values(md5('x'),1,'{}');
  raise exception 'Client wrote the cache';
 exception when insufficient_privilege then null;
 end;
end$$;
reset role;set local role anon;
do $$begin
 perform 1 from public.duty_compensation_snapshots;
 raise exception 'Anonymous read the cache';
exception when insufficient_privilege then null;
end$$;
reset role;
select 'PASS: cached ledger fold equals full replay, warm reads fold nothing, new events fold incrementally, replay-code changes invalidate, read-only reads answer, manager-only cache';
rollback;
