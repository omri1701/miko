-- The ledger is the only authoritative compensation state. No balances/FKs to
-- deletable publication rows: every operation contains its immutable provenance.
CREATE TABLE public.duty_compensation_events (
 sequence bigint PRIMARY KEY CHECK (sequence > 0),
 source_key text NOT NULL UNIQUE CHECK (length(source_key) BETWEEN 1 AND 240),
 at bigint NOT NULL CHECK (at BETWEEN 0 AND 9007199254740991),
 actor text NOT NULL CHECK (length(actor) BETWEEN 1 AND 80),
 reason text,
 operation jsonb NOT NULL CHECK (jsonb_typeof(operation) = 'object'),
 CHECK (reason IS NULL OR length(reason) BETWEEN 1 AND 2000)
);
ALTER TABLE public.duty_compensation_events ENABLE ROW LEVEL SECURITY;

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
