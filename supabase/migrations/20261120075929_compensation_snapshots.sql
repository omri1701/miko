-- Supabase CPU at its limit (#86). duty_private.compensation_state replayed the whole
-- append-only ledger through PL/pgSQL on every call, copying the growing state per event:
-- O(events²). Every balance read (each open Home/Team screen, once per workspace revision),
-- Plan the month context, publication, swap and ledger write paid it. It now keeps the fold
-- in public.duty_compensation_snapshots and folds only events newer than the cached one.
-- Events are immutable and numbered 1..N, and compensation_apply is pure, so the result is
-- identical. The cache is keyed by a hash of every duty_private function's source: a later
-- migration that changes any private function ignores older rows. No ledger data, RPC or client grant changes;
-- the new table is readable only like the events it derives from (managers, via RLS).

-- Source: schemas/tables/duty_compensation_events.sql (cache table)
-- Derived, disposable cache of the ledger fold (#86), written only by
-- duty_private.compensation_state: the state after events 1..sequence, for the replay
-- private functions whose source hashes to code. Never authoritative; deleting rows only
-- costs one full replay (a manual ledger repair must delete them). Readable like the events it is derived from (managers only).
CREATE TABLE public.duty_compensation_snapshots (
 code text CONSTRAINT duty_compensation_snapshots_pkey PRIMARY KEY CHECK (code ~ '^[0-9a-f]{32}$'),
 sequence bigint NOT NULL CHECK (sequence > 0),
 state jsonb NOT NULL CHECK (jsonb_typeof(state) = 'object')
);
ALTER TABLE public.duty_compensation_snapshots ENABLE ROW LEVEL SECURITY;

-- Source: schemas/policies/duty_compensation_events.sql
CREATE POLICY duty_compensation_snapshots_manager_read ON public.duty_compensation_snapshots FOR SELECT TO authenticated USING ((SELECT duty_private.is_manager()));

-- Source: schemas/grants/tables.sql
REVOKE ALL ON TABLE public.duty_compensation_snapshots FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.duty_compensation_snapshots TO authenticated, service_role;

-- Source: schemas/functions/duty_private/compensation_state.sql
-- The ledger state: every event folded in sequence order through the pure
-- compensation_apply. Events are append-only and numbered 1..N without gaps (each
-- append takes the workspace lock and the next number), so the fold of the first k
-- events never changes. A cached fold (#86) is reused and only newer events are folded;
-- a full replay of every event cost O(events²) on every balance read, Plan the month,
-- publication and swap. The cache is keyed by a hash of every duty_private function's
-- source, so any migration that changes a private function (and so possibly how events
-- fold) ignores older cached states. A manual ledger repair must delete the cache rows.
CREATE OR REPLACE FUNCTION duty_private.compensation_state() RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
#variable_conflict use_column
declare s jsonb; e record; fold_code text; cached bigint:=0; last bigint:=0;
begin
 select md5(string_agg(p.proname||'('||pg_catalog.pg_get_function_identity_arguments(p.oid)||')'||p.prosrc,'|' order by p.proname,p.oid))
 into fold_code from pg_catalog.pg_proc p
 where p.pronamespace='duty_private'::regnamespace;
 select x.sequence,x.state into cached,s from public.duty_compensation_snapshots x where x.code=fold_code;
 -- Reuse only a fold whose events are all visible here, numbered 1..k (always true for a
 -- committed snapshot; anything else replays from the start).
 if s is null or cached<1 or (select count(*) from public.duty_compensation_events where sequence<=cached)<>cached then
  s:='{"events":[],"members":{},"lots":{},"claims":[],"contributions":{},"settlements":{},"publications":{},"intents":{},"normalizations":[]}'::jsonb;
  cached:=0;
 end if;
 last:=cached;
 for e in select * from public.duty_compensation_events where sequence>cached order by sequence loop
  s:=duty_private.compensation_apply(s,jsonb_build_object('sequence',e.sequence,'sourceKey',e.source_key,'at',e.at,'actor',e.actor,'operation',e.operation)
   ||case when e.reason is null then '{}'::jsonb else jsonb_build_object('reason',e.reason) end);
  last:=e.sequence;
 end loop;
 -- Keep the newer fold. Never waits: another transaction writing the cache, a read-only
 -- transaction or a serialization conflict just skips it (the result is the same).
 if last>cached and pg_catalog.pg_try_advisory_xact_lock(pg_catalog.hashtext('duty_compensation_snapshots')) then
  begin
   insert into public.duty_compensation_snapshots(code,sequence,state) values(fold_code,last,s)
   on conflict on constraint duty_compensation_snapshots_pkey do update set sequence=excluded.sequence,state=excluded.state
   where duty_compensation_snapshots.sequence<excluded.sequence;
   delete from public.duty_compensation_snapshots x where x.code<>fold_code;
  exception when read_only_sql_transaction or serialization_failure or lock_not_available then null;
  end;
 end if;
 return s;
end $$;
