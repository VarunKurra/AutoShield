-- AutoShield: installs, passcodes and event metadata.
--
-- Two rules this schema keeps:
--
--   1. A passcode is never stored. Only a salted SHA-256 digest of it, which
--      is what the app already keeps locally. Nobody reading this table can
--      recover the digits, including whoever runs the project.
--   2. A message is never stored. Events carry what happened, how severe it
--      was and which tier decided, and nothing a person actually wrote. The
--      settings screen promises exactly this.
--
-- Run after 20260925000000_shield_stats.sql. Idempotent.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------- installs --

create table if not exists public.installs (
    install_id      uuid        primary key,

    -- Salted digest only. Never the six digits.
    passcode_digest text,
    passcode_salt   text,
    passcode_set_at timestamptz,

    sensitivity     text        not null default 'balanced'
                    check (sensitivity in ('light', 'balanced', 'attentive')),
    outgoing_on     boolean     not null default true,
    incoming_on     boolean     not null default false,

    app_version     text        not null default '',
    os_version      text        not null default '',
    created_at      timestamptz not null default now(),
    last_seen_at    timestamptz not null default now(),

    -- A digest without a salt, or the reverse, is a bug rather than a state.
    constraint passcode_complete check (
        (passcode_digest is null and passcode_salt is null)
        or (passcode_digest is not null and passcode_salt is not null)
    )
);

comment on table public.installs is
    'One row per install. Passcodes are salted digests, never the digits.';
comment on column public.installs.passcode_digest is
    'SHA-256 of "<salt>:<code>". Cannot be reversed to the passcode.';

-- ------------------------------------------------------------------ events --

create table if not exists public.events (
    id            bigint generated always as identity primary key,
    install_id    uuid        not null references public.installs (install_id)
                              on delete cascade,

    -- caught | rephrased | edited | deleted | sent_anyway | covered | resources
    kind          text        not null
                  check (kind in ('caught', 'rephrased', 'edited', 'deleted',
                                  'sent_anyway', 'covered', 'resources')),

    -- 0..1, and the word the app showed for it.
    score         real        not null default 0 check (score between 0 and 1),
    severity      text        check (severity in ('Sharp', 'Harsh', 'Cruel')),

    -- rules | on_device | context | cache
    tier          text        check (tier in ('rules', 'on_device', 'context', 'cache')),
    category      text,

    -- How long the message was, since the text itself is never sent.
    text_length   integer     check (text_length >= 0),

    occurred_at   timestamptz not null default now()
);

comment on table public.events is
    'What happened, never what was written. No message text, ever.';

create index if not exists events_install_time_idx
    on public.events (install_id, occurred_at desc);
create index if not exists events_kind_idx on public.events (kind);

-- ------------------------------------------------------------ row security --
--
-- The app ships a publishable (anon) key, so every policy assumes that key is
-- public. An install may write its own rows and read nothing back. Aggregates
-- are read with the service role.

alter table public.installs enable row level security;
alter table public.events   enable row level security;

drop policy if exists "anon upserts install"  on public.installs;
drop policy if exists "anon updates install"  on public.installs;
drop policy if exists "anon appends events"   on public.events;

create policy "anon upserts install"
    on public.installs for insert to anon with check (true);

create policy "anon updates install"
    on public.installs for update to anon using (true) with check (true);

create policy "anon appends events"
    on public.events for insert to anon
    with check (occurred_at > now() - interval '1 day');

-- No select policy on either table, so anon cannot read anything back.

create or replace function public.touch_last_seen()
returns trigger language plpgsql as $$
begin
    new.last_seen_at = now();
    return new;
end;
$$;

drop trigger if exists installs_touch on public.installs;
create trigger installs_touch
    before update on public.installs
    for each row execute function public.touch_last_seen();

-- ------------------------------------------------------------------- views --

create or replace view public.install_overview as
select
    i.install_id,
    i.sensitivity,
    i.outgoing_on,
    i.incoming_on,
    (i.passcode_digest is not null) as passcode_set,
    i.created_at,
    i.last_seen_at,
    count(e.id) filter (where e.kind = 'caught')      as caught,
    count(e.id) filter (where e.kind = 'rephrased')   as rephrased,
    count(e.id) filter (where e.kind = 'covered')     as covered,
    count(e.id) filter (where e.kind = 'sent_anyway') as sent_anyway,
    round(avg(e.score) filter (where e.kind in ('caught', 'covered'))::numeric, 2)
        as avg_severity
from public.installs i
left join public.events e using (install_id)
group by i.install_id;

revoke all on public.install_overview from anon;

create or replace view public.severity_mix as
select
    date_trunc('day', occurred_at)::date as day,
    severity,
    count(*) as events
from public.events
where severity is not null
group by 1, 2
order by 1 desc, 2;

revoke all on public.severity_mix from anon;
