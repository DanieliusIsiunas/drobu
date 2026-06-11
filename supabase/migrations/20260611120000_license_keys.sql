-- License-key pool + vend ledger for automated Stripe fulfillment.
--
-- Custody model: keys are PRE-SIGNED offline on the dev Mac (the Ed25519
-- private key never leaves the developer Keychain); this table holds only
-- finished, opaque key strings. A cloud compromise leaks the unclaimed pool
-- (bounded batch) and claimed rows' emails — never signing capability.
--
-- Access model: RLS enabled with ZERO policies and all table/function
-- privileges revoked from anon/authenticated. Only the service_role key
-- (Edge Function secrets + dev Keychain) can touch this data, via the
-- functions below or PostgREST with the service role.

create table public.license_keys (
    id bigint generated always as identity primary key,
    -- The full DROBU-<payload>.<sig> string, vended verbatim to the customer.
    key text not null unique,
    -- Hex of the 32-byte random payload — the reconciliation identity that
    -- joins this table with tools/license-log.csv. Never reconstructs a key.
    payload_hex text not null unique,
    -- Fingerprint of the public key the batch was signed against. A keypair
    -- rotation must void all unclaimed rows of the old version BEFORE the
    -- new public key ships, or vending continues with keys the app rejects.
    key_version text not null,
    minted_at timestamptz not null default now(),
    claimed_at timestamptz,
    -- One key per purchase: the Stripe checkout session id is the
    -- idempotency anchor. UNIQUE makes double-vending impossible even under
    -- concurrent webhook retries.
    stripe_session_id text unique,
    email text,
    -- Stamped after a successful SMTP send; gates re-sends on Stripe retries.
    email_sent_at timestamptz,
    -- Observed at claim time, for audit (log-only floor check in the handler;
    -- adaptive pricing varies currency so amounts never block fulfillment).
    amount_total bigint,
    currency text,
    -- Manual, per the refund runbook entry. No revocation: the key stays valid.
    refunded_at timestamptz
);

alter table public.license_keys enable row level security;
-- Zero policies on purpose: anon/authenticated have no path to this table.
revoke all on table public.license_keys from anon, authenticated;

-- Atomic, idempotent vend.
--   * Known session id -> return the already-claimed key (Stripe retries and
--     the completed/async_payment_succeeded pair share a session id; both
--     must get the SAME key).
--   * Else claim the oldest unclaimed row under FOR UPDATE SKIP LOCKED.
--   * Concurrent duplicates for one session: the loser's UPDATE hits the
--     unique constraint, rolls back to the block savepoint (its row stays
--     unclaimed), and the handler re-reads the winner's key.
--   * Empty pool raises -> the Edge Function returns 500 -> Stripe's 72h
--     retry machinery is the recovery queue.
create or replace function public.claim_license_key(
    p_session_id text,
    p_email text,
    p_amount bigint,
    p_currency text
) returns table (key text, payload_hex text, email_sent_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row public.license_keys%rowtype;
begin
    select * into v_row from public.license_keys lk
     where lk.stripe_session_id = p_session_id;
    if found then
        return query select v_row.key, v_row.payload_hex, v_row.email_sent_at;
        return;
    end if;

    begin
        update public.license_keys lk
           set claimed_at = now(),
               stripe_session_id = p_session_id,
               email = p_email,
               amount_total = p_amount,
               currency = p_currency
         where lk.id = (
            select id from public.license_keys
             where claimed_at is null and stripe_session_id is null
             order by id
             limit 1
             for update skip locked
         )
        returning lk.* into v_row;
    exception when unique_violation then
        -- A concurrent call claimed this session first; return its key.
        select * into v_row from public.license_keys lk
         where lk.stripe_session_id = p_session_id;
        if found then
            return query select v_row.key, v_row.payload_hex, v_row.email_sent_at;
            return;
        end if;
        raise;
    end;

    if v_row.id is null then
        raise exception 'license pool empty';
    end if;

    return query select v_row.key, v_row.payload_hex, v_row.email_sent_at;
end;
$$;

revoke execute on function public.claim_license_key(text, text, bigint, text)
    from public, anon, authenticated;

-- Stamps delivery after a successful SMTP send. Kept as an RPC (rather than
-- a PostgREST table update) so table privileges stay fully sealed.
create or replace function public.mark_email_sent(p_session_id text)
returns void
language sql
security definer
set search_path = public
as $$
    update public.license_keys
       set email_sent_at = now()
     where stripe_session_id = p_session_id;
$$;

revoke execute on function public.mark_email_sent(text)
    from public, anon, authenticated;

-- Bucketed pool depth for the public health route: ordinal only, no counts.
-- Thresholds: empty = 0, low <= 5 (covers ~48h of plausible sales against
-- the daily monitor cadence + Stripe's 72h retry window), ok otherwise.
create or replace function public.pool_depth()
returns text
language sql
security definer
set search_path = public
as $$
    select case
        when count(*) = 0 then 'empty'
        when count(*) <= 5 then 'low'
        else 'ok'
    end from public.license_keys where claimed_at is null;
$$;

revoke execute on function public.pool_depth()
    from public, anon, authenticated;
