-- Empty disposable LOCAL only. Synthetic fixtures; always rolls back.
-- #86: PostgREST re-runs a transaction that fails with SQLSTATE 40001 or 40P01. A stale
-- revision never matches again, so those refusals looped forever in Production. Every
-- "refresh first" refusal must use the non-retryable PT409 (HTTP 409) with its message intact.
\set ON_ERROR_STOP on
begin;
do $$begin
 if exists(select 1 from auth.users) or exists(select 1 from public.duty_members) then raise exception 'Requires empty disposable LOCAL';end if;
 -- No application function raises a retryable SQLSTATE (or the condition names for them).
 if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where (n.nspname='duty_private' or (n.nspname='public' and p.proname like 'duty_%'))
   and p.prosrc ~* '(errcode\s*=\s*''(40001|40P01)''|raise\s+(exception\s+)?(serialization_failure|deadlock_detected)|using\s+errcode\s*=\s*''(serialization_failure|deadlock_detected)'')') then
  raise exception 'An application function raises a retryable SQLSTATE: %',(select string_agg(p.proname,', ') from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where (n.nspname='duty_private' or (n.nspname='public' and p.proname like 'duty_%')) and p.prosrc ~* 'errcode\s*=\s*''(40001|40P01)''');
 end if;
end$$;
insert into auth.users(id,email) values('86200000-0000-0000-0000-000000000001','stale-1@example.invalid');
insert into public.duty_members(id,email,name,role,status,active) values('86200000-0000-0000-0000-000000000001','stale-1@example.invalid','Synthetic admin','admin','approved',true);
create function pg_temp.rev() returns bigint language sql security definer as $$select revision from public.duty_workspace where id$$;
grant execute on function pg_temp.rev() to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','86200000-0000-0000-0000-000000000001',true);
-- The stale revision through two different checked RPCs (both go through check_revision).
do $$declare state text; message text;begin
 begin
  perform public.duty_set_constraints('86200000-0000-0000-0000-000000000001',array['2099-10-02'::date],'no','',pg_temp.rev()-1);
  raise exception 'Stale revision accepted';
 exception when others then get stacked diagnostics state=returned_sqlstate, message=message_text;
 end;
 if state<>'PT409' or message<>'The team data changed. Refresh and try again.' then raise exception 'Stale constraints refusal: % %',state,message;end if;
 begin
  perform public.duty_rename_self('Renamed',pg_temp.rev()+5);
  raise exception 'Stale revision accepted';
 exception when others then get stacked diagnostics state=returned_sqlstate, message=message_text;
 end;
 if state<>'PT409' or left(state,2)='40' then raise exception 'Stale rename refusal used %',state;end if;
end$$;
reset role;
select 'PASS: stale-revision and refresh-first refusals raise non-retryable PT409 (HTTP 409) with their messages; no application function raises 40001/40P01';
rollback;
