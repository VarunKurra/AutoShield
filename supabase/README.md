# Shield on Supabase

One table, counts only. Nothing here can identify a person or reconstruct a
message, because nothing but integers is ever sent.

## Setup

```bash
brew install supabase/tap/supabase     # not installed on this machine yet
supabase login
supabase init
supabase link --project-ref <your-project-ref>
supabase db push
```

Or paste `migrations/20260925000000_shield_stats.sql` straight into the SQL
editor in the dashboard. It is idempotent, so running it twice is safe.

## What gets written

One row per install per day:

| column | meaning |
|---|---|
| `install_id` | random UUID made on the device, tied to nothing |
| `day` | the date the counts belong to |
| `caught` / `rewritten` / `dropped` / `sent_anyway` | outgoing outcomes |
| `covered` | incoming messages put behind glass |
| `tier_rules` / `tier_device` / `tier_context` | which tier resolved each check |
| `sensitivity` | the setting in force |

No message text. No rewrites. No app names. No account. No timestamps finer
than a day.

## Row level security

The app ships a publishable key, so the policies assume that key is public.
Anon can insert and update recent rows and **cannot read anything back**. There
is no select policy at all. Read aggregates with the service role, through the
`daily_totals` view:

```sql
select * from daily_totals limit 30;
```

## Turning it on

Off by default. Settings → Your messages → "Share anonymous counts".
