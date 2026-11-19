CREATE POLICY duty_compensation_manager_read ON public.duty_compensation_events FOR SELECT TO authenticated USING ((SELECT duty_private.is_manager()));
CREATE POLICY duty_compensation_snapshots_manager_read ON public.duty_compensation_snapshots FOR SELECT TO authenticated USING ((SELECT duty_private.is_manager()));
