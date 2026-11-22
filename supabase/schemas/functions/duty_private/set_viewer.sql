-- Viewer (decision 2026-11-20, #90): an admin makes an approved member a Viewer, who sees the
-- schedule but is never scheduled, adds no constraints and gets no points or debts. Like
-- deactivating: duties already scheduled stay where they are (publishing refuses them until
-- the admin reassigns them by hand), the ledger freezes the member (compensation_members) and
-- their open swaps are invalidated (reconcile_member_swaps). An admin who is a Viewer keeps
-- admin reads only, so at least one admin who is not a Viewer must remain.
CREATE FUNCTION duty_private.set_viewer(p_member uuid, p_viewer boolean, p_revision bigint) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
begin
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 perform duty_private.check_revision(p_revision);
 if not duty_private.is_manager() then raise exception 'Admin access required' using errcode='42501'; end if;
 if p_viewer is null then raise exception 'Choose whether this member is a Viewer'; end if;
 if exists(select 1 from public.duty_members where id=p_member and is_temporary) then raise exception 'A temporary member cannot be a Viewer'; end if;
 update public.duty_members set viewer=p_viewer where id=p_member and status='approved';
 if not found then raise exception 'Approve this member first'; end if;
 perform duty_private.assert_admin_remains();
 -- A Viewer-admin holds no swap open either: one they proposed as an admin is invalidated too
 -- (their own requests already are, by duty_reconcile_member_swaps).
 if p_viewer then
  update public.duty_swap_requests set status='invalidated',accepted_by=null,accepted_at=null,resolved_at=now(),resolved_by=null
  where proposed_by=p_member and status in ('awaiting_engineer','awaiting_admin');
 end if;
 update public.duty_workspace set revision=revision+1 where id;
end $$;
