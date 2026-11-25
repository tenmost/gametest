-- Space Duel: daily login streak (log in on consecutive days) with rewards + achievements.
-- NOT APPLIED YET: Dainis applies this to the shared project mrrqfrmgblbgrvkbrwvt as migration "sd_login_streak"
-- (Supabase → SQL Editor → paste → Run). Needs social.sql (pink_crystals) — already applied. Only sd_* objects.
--
-- The game calls sd_daily_login() once when a signed-in player opens it. Days are counted in UTC by the server,
-- so they can't be faked. Rewards: every 7th day in a row +15 blue; every 30th day +60 blue + 2 pink.

alter table public.sd_player_profiles add column if not exists login_streak integer not null default 0 check (login_streak >= 0);
alter table public.sd_player_profiles add column if not exists best_login_streak integer not null default 0 check (best_login_streak >= 0);
alter table public.sd_player_profiles add column if not exists last_login_day date;

create or replace function public.sd_daily_login()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_day date := (now() at time zone 'UTC')::date; p public.sd_player_profiles%rowtype; v_streak int; v_blue int := 0; v_pink int := 0;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into p from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 if p.last_login_day = v_day then
  return jsonb_build_object('streak', p.login_streak, 'best', p.best_login_streak, 'new_day', false, 'reward', 0, 'pink', 0);
 end if;
 v_streak := case when p.last_login_day = v_day - 1 then p.login_streak + 1 else 1 end;
 if v_streak % 30 = 0 then v_blue := 60; v_pink := 2; elsif v_streak % 7 = 0 then v_blue := 15; end if;
 update public.sd_player_profiles
    set login_streak = v_streak, best_login_streak = greatest(best_login_streak, v_streak), last_login_day = v_day,
        crystals = crystals + v_blue, pink_crystals = pink_crystals + v_pink
  where id = auth.uid() returning * into p;
 return jsonb_build_object('streak', p.login_streak, 'best', p.best_login_streak, 'new_day', true, 'reward', v_blue, 'pink', v_pink,
   'crystals', p.crystals, 'pink_crystals', p.pink_crystals);
end;
$$;
revoke all on function public.sd_daily_login() from public, anon;
grant execute on function public.sd_daily_login() to authenticated;
