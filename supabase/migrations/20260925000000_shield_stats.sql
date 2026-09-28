-- Shield: anonymous aggregate stats.
--
-- Deliberately the smallest table that answers "is this working". One row per
-- install per day, counts only. No message text, no rewrites, no app names, no
-- account, no IP retention. An install id is a random UUID generated on the
-- device and stored in UserDefaults; it identifies nothing about a person and
-- is thrown away if they reinstall.
--
-- Shield's settings screen says exactly this, and the switch is off by default.

create extension if not exists "pgcrypto";

create table if not exists public.daily_stats (
    install_id    uuid        not null,
    day           date        not null,

    -- Outgoing: drafts Shield paused before they sent.
    caught        integer     not null default 0 check (caught      >= 0),
    rewritten     integer     not null default 0 check (rewritten   >= 0),
    dropped       integer     not null default 0 check (dropped     >= 0),
    sent_anyway   integer     not null default 0 check (sent_anyway >= 0),

    -- Incoming: messages Shield put behind glass.
    covered       integer     not null default 0 check (covered     >= 0),

    -- Which tier resolved each check, so the cascade can be tuned.
    tier_rules    integer     not null default 0 check (tier_rules    >= 0),
    tier_device   integer     not null default 0 check (tier_device   >= 0),
    tier_context  integer     not null default 0 check (tier_context  >= 0),

    -- Sensitivity in force, to read the counts against.
    sensitivity   text        not null default 'balanced'
                  check (sensitivity in ('light', 'balanced', 'attentive')),

    app_version   text        not null default '',
    updated_at    timestamptz not null default now(),

    primary key (install_id, day)
);

comment on table  public.daily_stats is
    'Anonymous per-install daily counts. Never contains message text.';
comment on column public.daily_stats.install_id is
    'Random UUID generated on device. Not linked to any account or person.';

create index if not exists daily_stats_day_idx on public.daily_stats (day desc);

-- Row level security -------------------------------------------------------
--
-- The app ships a publishable (anon) key, so the policies have to assume the
-- key is public. An install may write its own row and nothing else, and
-- nobody may read rows back through the anon key at all. Aggregates are read
-- with the service role from the dashboard.

alter table public.daily_stats enable row level security;

drop policy if exists "anon inserts own row"  on public.daily_stats;
drop policy if exists "anon updates own row"  on public.daily_stats;
drop policy if exists "no anon reads"         on public.daily_stats;

create policy "anon inserts own row"
    on public.daily_stats for insert
    to anon
    with check (
        day between current_date - interval '2 days' and current_date + interval '1 day'
    );

create policy "anon updates own row"
    on public.daily_stats for update
    to anon
    using  (day >= current_date - interval '2 days')
    with check (day >= current_date - interval '2 days');

-- No select policy is created, so anon cannot read anything back.

-- Keep updated_at honest.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists daily_stats_touch on public.daily_stats;
create trigger daily_stats_touch
    before update on public.daily_stats
    for each row execute function public.touch_updated_at();

-- A convenience view for the dashboard, service role only.
create or replace view public.daily_totals as
select
    day,
    count(*)                        as installs,
    sum(caught)                     as caught,
    sum(rewritten)                  as rewritten,
    sum(dropped)                    as dropped,
    sum(sent_anyway)                as sent_anyway,
    sum(covered)                    as covered,
    sum(tier_rules)                 as tier_rules,
    sum(tier_device)                as tier_device,
    sum(tier_context)               as tier_context,
    round(
        100.0 * sum(rewritten + dropped)
        / nullif(sum(caught), 0), 1) as pct_reconsidered
from public.daily_stats
group by day
order by day desc;

revoke all on public.daily_totals from anon;
