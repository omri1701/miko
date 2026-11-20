-- Database efficiency pass (#86). Expand-only; no data, RPC, grant to clients or behaviour changes.
-- * duty_allocations gets a primary key (Supabase advisor "no primary key"). allocation_id is
--   shared by a draft and its publication and publication_id is NULL for the working draft, so
--   a new row id is the key; the existing (month, publication_id) uniqueness is unchanged.
-- * duty_swaps_pending_month is dropped: duty_swaps_pending_pair has the same predicate and
--   leads with month, and duty_swaps_month still covers the month foreign key.
-- * The push clock (pg_cron, every 15 minutes) read every current published duty on each run
--   to find the reminders due today; it now reads only the three days a reminder can be due.

-- Source: schemas/tables/duty_allocations.sql
ALTER TABLE public.duty_allocations ADD COLUMN id uuid NOT NULL DEFAULT gen_random_uuid() CONSTRAINT duty_allocations_pkey PRIMARY KEY;

-- Source: schemas/tables/duty_swap_requests.sql
DROP INDEX public.duty_swaps_pending_month;

-- Source: schemas/functions/duty_private/current_duties.sql
-- The duties the team sees: each date from its owning month's current publication, or from
-- the publication that holds it when its owning month has none. Starting days p_from..p_to
-- only (#86): the push clock reads three days, not every published duty, on each run.
CREATE FUNCTION duty_private.current_duties_between(p_from date, p_to date) RETURNS SETOF public.duty_assignments
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
 select a.* from public.duty_assignments a
 join public.duty_months m on m.current_publication_id=a.publication_id
 where a.day between p_from and p_to
 and (m.month=duty_private.duty_owner(a.day)
 or not exists(select 1 from public.duty_months owner where owner.month=duty_private.duty_owner(a.day) and owner.current_publication_id is not null))
$$;

CREATE OR REPLACE FUNCTION duty_private.current_duties() RETURNS SETOF public.duty_assignments
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
 select * from duty_private.current_duties_between('-infinity'::date,'infinity'::date)
$$;

-- Source: schemas/grants/functions.sql
REVOKE ALL ON FUNCTION duty_private.current_duties_between(p_from date, p_to date) FROM PUBLIC, anon, authenticated, service_role;

-- Source: schemas/functions/duty_private/push_delivery.sql
-- Timed notifications in Asia/Jerusalem, recorded once each (dedupe keys):
-- * constraint deadline: from 10:00 three days before the deadline date, to everyone;
--   from 10:00 the day before, only to members with no constraints in that month.
--   Only for months not yet published.
-- * duty reminders: the evening before (default 18:00) and the morning of the duty
--   (default 08:30), for the primary engineer and emergency cover of the duties the
--   team sees (duty_private.current_duties: each date from its owning month; only the three
--   days a reminder can be due, #86). Each has a three-hour window, so a late run still reminds once.
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
  join public.duty_members x on x.status='approved' and x.active and x.auth_user_id is not null
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
