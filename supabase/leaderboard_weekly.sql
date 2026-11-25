-- RPS Rivals: WEEKLY leaderboard with prizes + ALL-TIME leaderboard (no prizes). PLAYER vs PLAYER only.
-- Counts ONLINE matches between two signed-in players that BOTH browsers reported the same way
-- (sd_online_reports, paired = true — one says won, the other says lost). Matches vs computer don't count.
-- Anti-farming: at most 3 wins against the SAME opponent count per day.
-- Week = Monday 00:00 UTC → next Monday. Ranked by wins, then fewer losses, then who reached that score first.
-- Prizes for last week's top 3 (claimed by the winner in the game, once; the server checks the rank):
--   #1 = 100 blue + 10 pink · #2 = 60 blue + 5 pink · #3 = 30 blue + 3 pink   (change in sd_weekly_prize_amount)
-- All-time board: just for glory, no prizes. Replaces leaderboard.sql's function. Only sd_* objects. Safe to re-run.

create index if not exists sd_online_reports_paired on public.sd_online_reports (created_at) where paired;

create or replace function public.sd_week_start(p_ts timestamptz default now())
returns date language sql stable set search_path = '' as $$
 select date_trunc('week', p_ts at time zone 'UTC')::date;   -- Monday (UTC)
$$;

create or replace function public.sd_weekly_prize_amount(p_rank int)
returns table(blue int, pink int) language sql immutable set search_path = '' as $$
 select case p_rank when 1 then 100 when 2 then 60 when 3 then 30 else 0 end,
        case p_rank when 1 then 10  when 2 then 5  when 3 then 3  else 0 end;
$$;
revoke all on function public.sd_weekly_prize_amount(int) from public, anon, authenticated;

-- player-vs-player ranking between two times (internal)
drop function if exists public.sd_week_ranking(date);
create or replace function public.sd_pvp_ranking(p_from timestamptz, p_to timestamptz)
returns table(user_id uuid, wins int, losses int, rank bigint) language sql stable security definer set search_path = '' as $$
 with r as (
  select o.user_id, o.opp_id, o.won, o.created_at, (o.created_at at time zone 'UTC')::date as day
    from public.sd_online_reports o
   where o.paired and o.created_at >= p_from and o.created_at < p_to),
 w as (  -- wins, max 3 per opponent per day
  select user_id, sum(least(3, n))::int as wins, max(last_at) as last_win
    from (select user_id, opp_id, day, count(*) as n, max(created_at) as last_at from r where won group by user_id, opp_id, day) x
   group by user_id),
 l as (select user_id, count(*)::int as losses from r where not won group by user_id)
 select w.user_id, w.wins, coalesce(l.losses, 0),
        row_number() over (order by w.wins desc, coalesce(l.losses, 0) asc, w.last_win asc, w.user_id)
   from w left join l using (user_id) join public.sd_player_profiles p on p.id = w.user_id
  where w.wins > 0 and p.username is not null;
$$;
revoke all on function public.sd_pvp_ranking(timestamptz, timestamptz) from public, anon, authenticated;

drop function if exists public.sd_leaderboard(integer);
create or replace function public.sd_leaderboard(p_limit integer default 10, p_period text default 'week')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_lim int := least(greatest(coalesce(p_limit, 10), 1), 50); v_week date := public.sd_week_start(); r jsonb;
begin
 if p_period = 'all' then
  with ranked as (select w.*, p.username, p.avatar from public.sd_pvp_ranking('-infinity', 'infinity') w join public.sd_player_profiles p on p.id = w.user_id)
  select jsonb_build_object('period', 'all',
   'top', coalesce((select jsonb_agg(jsonb_build_object('rank', rank, 'name', username, 'avatar', avatar, 'wins', wins, 'losses', losses,
                      'me', user_id = auth.uid()) order by rank) from ranked where rank <= v_lim), '[]'::jsonb),
   'me', (select jsonb_build_object('rank', rank, 'wins', wins, 'losses', losses, 'name', username, 'avatar', avatar) from ranked where user_id = auth.uid()),
   'players', (select count(*) from ranked)) into r;
  return r;
 end if;
 with ranked as (select w.*, p.username, p.avatar from public.sd_pvp_ranking(v_week::timestamp at time zone 'UTC', (v_week + 7)::timestamp at time zone 'UTC') w join public.sd_player_profiles p on p.id = w.user_id)
 select jsonb_build_object('period', 'week', 'week_start', v_week,
  'ends_in', extract(epoch from ((v_week + 7)::timestamp at time zone 'UTC') - now())::int,
  'prizes', (select jsonb_agg(jsonb_build_object('rank', k, 'blue', a.blue, 'pink', a.pink) order by k) from generate_series(1,3) k, public.sd_weekly_prize_amount(k) a),
  'top', coalesce((select jsonb_agg(jsonb_build_object('rank', rank, 'name', username, 'avatar', avatar, 'wins', wins, 'losses', losses,
                     'me', user_id = auth.uid()) order by rank) from ranked where rank <= v_lim), '[]'::jsonb),
  'me', (select jsonb_build_object('rank', rank, 'wins', wins, 'losses', losses, 'name', username, 'avatar', avatar) from ranked where user_id = auth.uid()),
  'players', (select count(*) from ranked)) into r;
 return r;
end;
$$;
revoke all on function public.sd_leaderboard(integer, text) from public;
grant execute on function public.sd_leaderboard(integer, text) to anon, authenticated;

-- prizes for LAST week's top 3: the winner presses CLAIM in the game; one claim per player per week
create table if not exists public.sd_weekly_prizes (
 user_id uuid not null references public.sd_player_profiles(id) on delete cascade,
 week_start date not null,
 rank int not null,
 blue int not null,
 pink int not null,
 claimed_at timestamptz not null default now(),
 primary key (user_id, week_start)
);
alter table public.sd_weekly_prizes enable row level security;
revoke all on public.sd_weekly_prizes from anon, authenticated;

create or replace function public.sd_weekly_prize()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_week date := public.sd_week_start() - 7; v_rank bigint; a record;
begin
 if auth.uid() is null then return null; end if;
 select rank into v_rank from public.sd_pvp_ranking(v_week::timestamp at time zone 'UTC', (v_week + 7)::timestamp at time zone 'UTC') where user_id = auth.uid();
 if v_rank is null or v_rank > 3 then return null; end if;
 if exists (select 1 from public.sd_weekly_prizes where user_id = auth.uid() and week_start = v_week) then return null; end if;
 select * into a from public.sd_weekly_prize_amount(v_rank::int);
 return jsonb_build_object('rank', v_rank, 'blue', a.blue, 'pink', a.pink, 'week_start', v_week);
end;
$$;
revoke all on function public.sd_weekly_prize() from public, anon;
grant execute on function public.sd_weekly_prize() to authenticated;

create or replace function public.sd_weekly_prize_claim()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_week date := public.sd_week_start() - 7; v_rank bigint; a record; p public.sd_player_profiles%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 perform 1 from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 select rank into v_rank from public.sd_pvp_ranking(v_week::timestamp at time zone 'UTC', (v_week + 7)::timestamp at time zone 'UTC') where user_id = auth.uid();
 if v_rank is null or v_rank > 3 then raise exception 'No weekly prize for you this time — keep playing!'; end if;
 select * into a from public.sd_weekly_prize_amount(v_rank::int);
 insert into public.sd_weekly_prizes(user_id, week_start, rank, blue, pink) values (auth.uid(), v_week, v_rank, a.blue, a.pink)
 on conflict do nothing;
 if not found then raise exception 'Prize already collected'; end if;
 update public.sd_player_profiles set crystals = crystals + a.blue, pink_crystals = pink_crystals + a.pink
  where id = auth.uid() returning * into p;
 return jsonb_build_object('rank', v_rank, 'blue', a.blue, 'pink', a.pink, 'crystals', p.crystals, 'pink_crystals', p.pink_crystals);
end;
$$;
revoke all on function public.sd_weekly_prize_claim() from public, anon;
grant execute on function public.sd_weekly_prize_claim() to authenticated;
