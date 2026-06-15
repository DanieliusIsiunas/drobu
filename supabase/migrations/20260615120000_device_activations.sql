-- Per-license device-activation ledger + cap enforcement.
--
-- Layers an ONLINE device cap on top of the existing OFFLINE Ed25519 license
-- (see 20260611120000_license_keys.sql). The license signature stays the
-- proof-of-purchase, verified locally + re-verified by the activate-device
-- Edge Function; this table only answers "is this device within the cap".
--
-- Identity model: rows are keyed by `payload_hex`, NOT a foreign key to
-- license_keys.id. Manually-issued keys (issue-license-key.sh without
-- --session) are signature-valid but have NO license_keys row, so a hard FK
-- would reject them. payload_hex (derivable from any key, already the
-- reconciliation identity of license_keys) is the license identity here;
-- revocation is a LEFT JOIN to license_keys.refunded_at (absent row => not
-- revocable, acceptable for manual keys).
--
-- Access model: identical to license_keys — RLS on with ZERO policies, all
-- privileges revoked from anon/authenticated; only service_role (the Edge
-- Function secret) reaches the functions below.

create table public.activations (
    id bigint generated always as identity primary key,
    -- Hex of the license's 32-byte payload — the license identity. Joins to
    -- license_keys.payload_hex when a row exists (vended keys), absent for
    -- manually-issued keys.
    payload_hex text not null,
    -- SHA256(IOPlatformUUID + salt) from the client. Never the raw UUID.
    device_hash text not null,
    -- Human-readable ("Daniel's MacBook"), for the in-app device list. PII —
    -- only the name + the salted hash ever leave the device, over TLS.
    device_name text,
    activated_at timestamptz not null default now(),
    last_seen_at timestamptz not null default now(),
    -- Soft delete: freeing a seat sets this; history is retained for audit.
    deactivated_at timestamptz
);

-- One ACTIVE row per device per license; deactivated rows don't count toward
-- the cap and may re-accumulate as history.
create unique index activations_active_device_uniq
    on public.activations (payload_hex, device_hash)
    where deactivated_at is null;
create index activations_payload_hex_idx on public.activations (payload_hex);

alter table public.activations enable row level security;
-- Zero policies on purpose: anon/authenticated have no path to this table.
revoke all on table public.activations from public, anon, authenticated;

-- Active device list for a license as a jsonb array of {device_name,
-- activated_at}. Helper used by activate_device's return and by support.
create or replace function public.list_activations(p_payload_hex text)
returns jsonb
language sql
security definer
set search_path = public
as $$
    select coalesce(
        jsonb_agg(
            jsonb_build_object('device_name', device_name, 'activated_at', activated_at)
            order by activated_at
        ),
        '[]'::jsonb
    )
    from public.activations
    where payload_hex = p_payload_hex and deactivated_at is null;
$$;

revoke execute on function public.list_activations(text)
    from public, anon, authenticated;
grant execute on function public.list_activations(text) to service_role;

-- Atomic, idempotent device activation with cap enforcement.
--   * Refunded license -> 'revoked' (the dead refunded_at marker becomes
--     enforceable; manual keys with no license_keys row are never revoked).
--   * Known device (same payload_hex+device_hash, active) -> refresh
--     last_seen_at, 'activated', NO new seat consumed.
--   * Under cap -> insert, 'activated'.
--   * At cap, new device -> 'over_cap', nothing inserted.
-- A per-license transaction advisory lock serializes concurrent activations
-- so two simultaneous claims of the final seat can't both insert past the cap.
create or replace function public.activate_device(
    p_payload_hex text,
    p_device_hash text,
    p_device_name text,
    p_cap int
) returns table (status text, active_devices jsonb, email text)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_refunded boolean;
    v_email text;
    v_active int;
    v_updated int;
begin
    -- Serialize all activations for this license; released at txn end.
    perform pg_advisory_xact_lock(hashtext(p_payload_hex));

    select (lk.refunded_at is not null), lk.email
      into v_refunded, v_email
      from public.license_keys lk
     where lk.payload_hex = p_payload_hex;
    -- No license_keys row (manual key): v_refunded is NULL -> not revoked.

    if coalesce(v_refunded, false) then
        return query select 'revoked'::text,
                            public.list_activations(p_payload_hex),
                            v_email;
        return;
    end if;

    -- Known device: refresh and return without consuming a seat.
    update public.activations
       set last_seen_at = now(),
           device_name = coalesce(p_device_name, device_name)
     where payload_hex = p_payload_hex
       and device_hash = p_device_hash
       and deactivated_at is null;
    get diagnostics v_updated = row_count;
    if v_updated > 0 then
        return query select 'activated'::text,
                            public.list_activations(p_payload_hex),
                            v_email;
        return;
    end if;

    select count(*) into v_active
      from public.activations
     where payload_hex = p_payload_hex and deactivated_at is null;

    if v_active >= p_cap then
        return query select 'over_cap'::text,
                            public.list_activations(p_payload_hex),
                            v_email;
        return;
    end if;

    insert into public.activations (payload_hex, device_hash, device_name)
        values (p_payload_hex, p_device_hash, p_device_name);

    return query select 'activated'::text,
                        public.list_activations(p_payload_hex),
                        v_email;
end;
$$;

revoke execute on function public.activate_device(text, text, text, int)
    from public, anon, authenticated;
grant execute on function public.activate_device(text, text, text, int)
    to service_role;

-- Free one device's seat. Idempotent: a no-op when the device isn't active.
create or replace function public.deactivate_device(
    p_payload_hex text,
    p_device_hash text
) returns void
language sql
security definer
set search_path = public
as $$
    update public.activations
       set deactivated_at = now()
     where payload_hex = p_payload_hex
       and device_hash = p_device_hash
       and deactivated_at is null;
$$;

revoke execute on function public.deactivate_device(text, text)
    from public, anon, authenticated;
grant execute on function public.deactivate_device(text, text) to service_role;

-- Support operation: free every seat for a license (e.g. logic-board repair,
-- Mac migration, or a "reset my activations" support ticket).
create or replace function public.deactivate_all_devices(p_payload_hex text)
returns void
language sql
security definer
set search_path = public
as $$
    update public.activations
       set deactivated_at = now()
     where payload_hex = p_payload_hex
       and deactivated_at is null;
$$;

revoke execute on function public.deactivate_all_devices(text)
    from public, anon, authenticated;
grant execute on function public.deactivate_all_devices(text) to service_role;
