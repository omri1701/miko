-- Admin reads (decision 2026-11-20, #90): every approved, active admin, including a
-- read-only Viewer-admin, sees what admins see (drafts, everyone's constraints and notes,
-- plans, balances, pending approvals). Never use it to authorize a write: use is_manager().
CREATE FUNCTION duty_private.is_overseer() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
 select auth.uid() is not null and exists(select 1 from public.duty_members m join public.duty_roles r on r.code=m.role where m.auth_user_id=auth.uid() and r.can_manage and m.status='approved' and m.active)
$$;
