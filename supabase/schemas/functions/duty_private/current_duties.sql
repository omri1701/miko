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

CREATE FUNCTION duty_private.current_duties() RETURNS SETOF public.duty_assignments
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
 select * from duty_private.current_duties_between('-infinity'::date,'infinity'::date)
$$;
