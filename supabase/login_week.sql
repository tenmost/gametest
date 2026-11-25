-- RPS Rivals: WEEKLY LOGIN REWARDS (7-day calendar in the DAILY window).
-- Log in and press CLAIM every day: days 1–6 = +10 blue, day 7 = +10 blue +10 pink, then a new week starts.
-- Miss a day (no claim yesterday) → back to day 1. Days are UTC days counted by the server, so they can't be faked.
-- The old automatic streak bonus (every 7th day +15, every 30th +60 +2 pink) is turned off; the login streak itself
-- still counts for the 7/30/100/365-day badges. Needs login_streak.sql (already applied). Only sd_* objects. Safe to re-run.

alter table public.sd_player_profiles add column if not exists week_day smallint not null default 0 check (week_day between 0 and 7);
alter table public.sd_player_profiles add column if not exists week_last_claim date;

create or replace function public.sd_login_week_reward(p_day int)
returns table(blue int, pink int) language sql immutable set search_path = '' as $$
 select 10, case when p_day = 7 then 10 else 0 end;
$$;
revoke all on function public.sd_login_week_reward(int) from public, anon, authenticated;

-- state for the calendar: which day is next, and whether it can be claimed today
create or replace function public.sd_login_week()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_today date := (now() at time zone 'UTC')::date; p public.sd_player_profiles%rowtype; v_done int; v_next int; v_can boolean;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into p from public.sd_player_profiles where id = auth.uid();
 if not found then raise exception 'Profile missing'; end if;
 if p.week_last_claim = v_today then
  v_done := p.week_day; v_can := false; v_next := case when p.week_day >= 7 then 1 else p.week_day + 1 end;
 elsif p.week_last_claim = v_today - 1 and p.week_day < 7 then
  v_done := p.week_day; v_can := true; v_next := p.week_day + 1;
 else
  v_done := 0; v_can := true; v_next := 1;     -- new week (finished last week, first time, or missed a day)
 end if;
 return jsonb_build_object('claimed_days', v_done, 'next_day', v_next, 'can_claim', v_can,
   'missed', p.week_last_claim is not null and p.week_last_claim < v_today - 1 and p.week_day between 1 and 6,
   'resets_in', extract(epoch from ((v_today + 1)::timestamp at time zone 'UTC') - now())::int,
   'rewards', (select jsonb_agg(jsonb_build_object('day', d, 'blue', r.blue, 'pink', r.pink) order by d)
                 from generate_series(1, 7) d, public.sd_login_week_reward(d) r));
end;
$$;
revoke all on function public.sd_login_week() from public, anon;
grant execute on function public.sd_login_week() to authenticated;

create or replace function public.sd_login_week_claim()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_today date := (now() at time zone 'UTC')::date; p public.sd_player_profiles%rowtype; v_day int; r record;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into p from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 if p.week_last_claim = v_today then raise exception 'Already collected today — come back tomorrow!'; end if;
 v_day := case when p.week_last_claim = v_today - 1 and p.week_day < 7 then p.week_day + 1 else 1 end;
 select * into r from public.sd_login_week_reward(v_day);
 update public.sd_player_profiles
    set week_day = v_day, week_last_claim = v_today,
        crystals = crystals + r.blue, pink_crystals = pink_crystals + r.pink
  where id = auth.uid() returning * into p;
 return jsonb_build_object('day', v_day, 'blue', r.blue, 'pink', r.pink, 'crystals', p.crystals, 'pink_crystals', p.pink_crystals)
        || public.sd_login_week();
end;
$$;
revoke all on function public.sd_login_week_claim() from public, anon;
grant execute on function public.sd_login_week_claim() to authenticated;

-- login streak keeps counting (badges), but no automatic crystals any more — the weekly calendar gives them now
create or replace function public.sd_daily_login()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_day date := (now() at time zone 'UTC')::date; p public.sd_player_profiles%rowtype; v_streak int;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into p from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 if p.last_login_day = v_day then
  return jsonb_build_object('streak', p.login_streak, 'best', p.best_login_streak, 'new_day', false, 'reward', 0, 'pink', 0);
 end if;
 v_streak := case when p.last_login_day = v_day - 1 then p.login_streak + 1 else 1 end;
 update public.sd_player_profiles
    set login_streak = v_streak, best_login_streak = greatest(best_login_streak, v_streak), last_login_day = v_day
  where id = auth.uid() returning * into p;
 return jsonb_build_object('streak', p.login_streak, 'best', p.best_login_streak, 'new_day', true, 'reward', 0, 'pink', 0,
   'crystals', p.crystals, 'pink_crystals', p.pink_crystals);
end;
$$;
revoke all on function public.sd_daily_login() from public, anon;
grant execute on function public.sd_daily_login() to authenticated;
