-- An admin's availability approval (duty_constraints.duty_approved, owner 2026-11-21) holds for
-- that person on that unavailable date while they are on the duty covering it, in the open draft
-- or the current publication. Once nobody keeps them there it lapses; putting them back asks again.
CREATE FUNCTION duty_private.prune_duty_approvals() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
 update public.duty_constraints c set duty_approved=false where c.duty_approved and not exists(
  select 1 from public.duty_assignments a join public.duty_months m on m.month=duty_private.duty_owner(a.day)
  where (a.publication_id is null or a.publication_id=m.current_publication_id)
   and c.day>=a.day and c.day<a.end_day and c.member_id in (a.primary_id,a.secondary_id));
end $$;
