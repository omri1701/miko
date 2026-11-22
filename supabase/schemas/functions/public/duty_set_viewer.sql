CREATE FUNCTION public.duty_set_viewer(p_member uuid, p_viewer boolean, p_revision bigint) RETURNS void
 LANGUAGE sql SET search_path TO '' AS $$select duty_private.set_viewer(p_member,p_viewer,p_revision)$$;
