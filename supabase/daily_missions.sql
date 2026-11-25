-- Space Duel: daily missions (3 per day, reset at 00:00 UTC), rewards in blue crystals.
-- NOT APPLIED YET: Dainis applies this to the shared project mrrqfrmgblbgrvkbrwvt as migration "sd_daily_missions"
-- (Supabase → SQL Editor → paste → Run). Until then the game hides the DAILY button.
-- Only sd_* objects. Nothing here touches tenmost.com tables.
--
-- Progress is computed on the server from sd_cpu_matches (server-verified matches vs computer),
-- so the browser can't fake it. A match counts as "played" only if it really ended
-- (won, or lost normally with the 1-crystal consolation reward) — EXIT/forfeit losses (reward 0) don't count.

create table if not exists public.sd_daily_claims (
 user_id uuid not null references public.sd_player_profiles(id) on delete cascade,
 day date not null,
 mission text not null,
 reward integer not null,
 claimed_at timestamptz not null default now(),
 primary key (user_id, day, mission)
);
alter table public.sd_daily_claims enable row level security;
revoke all on public.sd_daily_claims from anon, authenticated;

-- Mission pool: id, title, goal, reward (the game shows the titles from here). New ids must also go into sd_daily_set and sd_daily_progress.
create or replace function public.sd_daily_pool()
returns table(id text, title text, goal integer, reward integer) language sql immutable set search_path = '' as $$
 values ('play3',   'Play 3 matches vs computer',            3, 3),
        ('win2',    'Win 2 matches',                         2, 5),
        ('perfect1','Win a match without losing any health', 1, 8),
        ('rounds20','Play 20 rounds',                       20, 4),
        ('win4',    'Win 4 matches',                         4, 10),
        ('play5',   'Play 5 matches vs computer',            5, 5);
$$;
revoke all on function public.sd_daily_pool() from public, anon, authenticated;

-- Today's 3 missions: the pool rotated by the day number, so every day is a bit different.
create or replace function public.sd_daily_set(p_day date)
returns text[] language sql immutable set search_path = '' as $$
 select array(select (array['play3','win2','perfect1','rounds20','win4','play5'])[1 + ((i + (p_day - date '2026-01-01') * 2) % 6)]
                from generate_series(0, 2) i order by i);
$$;
revoke all on function public.sd_daily_set(date) from public, anon, authenticated;

create or replace function public.sd_daily_progress(p_user uuid, p_day date)
returns table(id text, title text, goal integer, reward integer, progress integer, claimed boolean)
language sql stable security definer set search_path = '' as $$
 with m as (
  select status, perfect, rounds from public.sd_cpu_matches
   where user_id = p_user and finished_at >= p_day::timestamp at time zone 'UTC'
     and finished_at < (p_day + 1)::timestamp at time zone 'UTC'
     and (status = 'won' or (status = 'lost' and reward > 0))),
 s as (
  select count(*)::int as played, count(*) filter (where status = 'won')::int as won,
         count(*) filter (where status = 'won' and perfect)::int as perfect, coalesce(sum(rounds),0)::int as rounds from m)
 select p.id, p.title, p.goal, p.reward,
        least(p.goal, case p.id when 'play3' then s.played when 'play5' then s.played when 'win2' then s.won
                                when 'win4' then s.won when 'perfect1' then s.perfect when 'rounds20' then s.rounds else 0 end),
        exists (select 1 from public.sd_daily_claims c where c.user_id = p_user and c.day = p_day and c.mission = p.id)
   from public.sd_daily_pool() p, s
  where p.id = any (public.sd_daily_set(p_day))
  order by array_position(public.sd_daily_set(p_day), p.id);
$$;
revoke all on function public.sd_daily_progress(uuid, date) from public, anon, authenticated;

-- Game calls this: today's missions with progress.
create or replace function public.sd_daily_missions()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_day date := (now() at time zone 'UTC')::date;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 return jsonb_build_object('day', v_day,
   'resets_in', extract(epoch from ((v_day + 1)::timestamp at time zone 'UTC') - now())::int,
   'missions', coalesce((select jsonb_agg(to_jsonb(d)) from public.sd_daily_progress(auth.uid(), v_day) d), '[]'::jsonb));
end;
$$;
revoke all on function public.sd_daily_missions() from public, anon;
grant execute on function public.sd_daily_missions() to authenticated;

-- Game calls this: claim a finished mission's reward (checked on the server, once per day per mission).
create or replace function public.sd_daily_claim(p_mission text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_day date := (now() at time zone 'UTC')::date; d record;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 perform 1 from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 select * into d from public.sd_daily_progress(auth.uid(), v_day) x where x.id = p_mission;
 if not found then raise exception 'Not a mission today'; end if;
 if d.claimed then raise exception 'Already claimed'; end if;
 if d.progress < d.goal then raise exception 'Mission not finished yet'; end if;
 insert into public.sd_daily_claims(user_id, day, mission, reward) values (auth.uid(), v_day, p_mission, d.reward);
 update public.sd_player_profiles set crystals = crystals + d.reward where id = auth.uid();
 return public.sd_daily_missions() || jsonb_build_object('reward', d.reward,
   'crystals', (select crystals from public.sd_player_profiles where id = auth.uid()));
end;
$$;
revoke all on function public.sd_daily_claim(text) from public, anon;
grant execute on function public.sd_daily_claim(text) to authenticated;
