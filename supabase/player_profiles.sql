-- Space Duel player accounts: profiles, server-verified matches vs computer, crystal rewards and arena unlocks.
-- Applied to the shared project mrrqfrmgblbgrvkbrwvt as migration "sd_player_profiles".
-- Only sd_* objects. Nothing here touches tenmost.com tables.

-- ---------- profiles ----------
create table if not exists public.sd_player_profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 username text not null check (char_length(username) between 3 and 24),
 crystals integer not null default 0 check (crystals >= 0),
 wins integer not null default 0 check (wins >= 0),
 losses integer not null default 0 check (losses >= 0),
 unlocked_characters text[] not null default array['girl']::text[],
 unlocked_maps text[] not null default array['temple']::text[],
 created_at timestamptz not null default now()
);
create unique index if not exists sd_player_profiles_username_key on public.sd_player_profiles (lower(username));
alter table public.sd_player_profiles enable row level security;
revoke all on public.sd_player_profiles from anon, authenticated;
grant select on public.sd_player_profiles to authenticated;
drop policy if exists "Read own game profile" on public.sd_player_profiles;
create policy "Read own game profile" on public.sd_player_profiles for select to authenticated using ((select auth.uid()) = id);

create or replace function public.sd_init_player_profile(p_username text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_name text := trim(p_username);
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if exists (select 1 from public.sd_player_profiles where id = auth.uid()) then return; end if;
 if v_name is null or char_length(v_name) not between 3 and 24 or v_name !~ '^[A-Za-z0-9_ .-]+$' then raise exception 'Invalid username'; end if;
 if exists (select 1 from public.sd_player_profiles where lower(username) = lower(v_name)) then raise exception 'Username already taken'; end if;
 insert into public.sd_player_profiles(id, username) values (auth.uid(), v_name) on conflict (id) do nothing;
end;
$$;
revoke all on function public.sd_init_player_profile(text) from public, anon;
grant execute on function public.sd_init_player_profile(text) to authenticated;

-- ---------- matches vs computer (the server picks the computer's card) ----------
create table if not exists public.sd_cpu_matches (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.sd_player_profiles(id) on delete cascade,
 status text not null default 'active' check (status in ('active','won','lost','abandoned')),
 p_hp smallint not null default 3, c_hp smallint not null default 3,
 p_fights smallint not null default 0, c_fights smallint not null default 0,
 rounds smallint not null default 0,
 perfect boolean not null default true,
 reward integer not null default 0,
 last_play_at timestamptz,
 created_at timestamptz not null default now(),
 finished_at timestamptz
);
create index if not exists sd_cpu_matches_user_active on public.sd_cpu_matches (user_id) where status = 'active';
alter table public.sd_cpu_matches enable row level security;
revoke all on public.sd_cpu_matches from anon, authenticated;

create or replace function public.sd_match_start()
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not exists (select 1 from public.sd_player_profiles where id = auth.uid()) then raise exception 'Profile missing'; end if;
 update public.sd_cpu_matches set status = 'abandoned', finished_at = now() where user_id = auth.uid() and status = 'active';
 insert into public.sd_cpu_matches(user_id) values (auth.uid()) returning id into v_id;
 return v_id;
end;
$$;
revoke all on function public.sd_match_start() from public, anon;
grant execute on function public.sd_match_start() to authenticated;

create or replace function public.sd_match_play(p_match uuid, p_move text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 m public.sd_cpu_matches%rowtype;
 v_opp text; v_res int; v_done boolean := false; v_won boolean; v_reward int := 0; v_fight_over boolean := false;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_move not in ('rock','paper','scissors') then raise exception 'Invalid move'; end if;
 select * into m from public.sd_cpu_matches where id = p_match and user_id = auth.uid() for update;
 if not found or m.status <> 'active' then raise exception 'Match not active'; end if;
 if m.last_play_at is not null and now() - m.last_play_at < interval '1 second' then raise exception 'Too fast'; end if;

 v_opp := (array['rock','paper','scissors'])[1 + floor(random() * 3)::int];
 v_res := case when p_move = v_opp then 0
               when (p_move, v_opp) in (('rock','scissors'),('paper','rock'),('scissors','paper')) then 1
               else -1 end;
 if v_res = 1 then m.c_hp := m.c_hp - 1; end if;
 if v_res = -1 then m.p_hp := m.p_hp - 1; m.perfect := false; end if;
 m.rounds := m.rounds + 1;

 if m.p_hp = 0 or m.c_hp = 0 then
  v_fight_over := true;
  if m.c_hp = 0 then m.p_fights := m.p_fights + 1; else m.c_fights := m.c_fights + 1; end if;
  if m.p_fights >= 2 or m.c_fights >= 2 then
   v_done := true; v_won := m.p_fights >= 2;
   v_reward := case when v_won then (case when m.perfect then 8 else 5 end) else 1 end;
   m.status := case when v_won then 'won' else 'lost' end;
   m.finished_at := now();
   update public.sd_player_profiles
      set crystals = crystals + v_reward,
          wins = wins + (case when v_won then 1 else 0 end),
          losses = losses + (case when v_won then 0 else 1 end)
    where id = auth.uid();
  else
   m.p_hp := 3; m.c_hp := 3;
  end if;
 end if;

 update public.sd_cpu_matches
    set p_hp = m.p_hp, c_hp = m.c_hp, p_fights = m.p_fights, c_fights = m.c_fights, rounds = m.rounds,
        perfect = m.perfect, status = m.status, reward = v_reward, last_play_at = now(), finished_at = m.finished_at
  where id = m.id;

 return jsonb_build_object('opp', v_opp, 'result', v_res, 'fight_over', v_fight_over, 'match_over', v_done,
   'won', v_won, 'reward', v_reward, 'p_fights', m.p_fights, 'c_fights', m.c_fights,
   'crystals', (select crystals from public.sd_player_profiles where id = auth.uid()));
end;
$$;
revoke all on function public.sd_match_play(uuid, text) from public, anon;
grant execute on function public.sd_match_play(uuid, text) to authenticated;

-- ---------- arena unlocks (price and balance checked here) ----------
create or replace function public.sd_unlock_map(p_map text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_price int; v_prof public.sd_player_profiles%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 v_price := case p_map when 'temple' then 0 when 'city' then 20 when 'jungle' then 35 when 'ice' then 50
                       when 'lava' then 75 when 'factory' then 100 else null end;
 if v_price is null then raise exception 'Unknown arena'; end if;
 select * into v_prof from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 if p_map = any(v_prof.unlocked_maps) then
  return jsonb_build_object('crystals', v_prof.crystals, 'unlocked_maps', v_prof.unlocked_maps);
 end if;
 if v_prof.crystals < v_price then raise exception 'Not enough crystals'; end if;
 update public.sd_player_profiles
    set crystals = crystals - v_price, unlocked_maps = array_append(unlocked_maps, p_map)
  where id = auth.uid()
  returning crystals, unlocked_maps into v_prof.crystals, v_prof.unlocked_maps;
 return jsonb_build_object('crystals', v_prof.crystals, 'unlocked_maps', v_prof.unlocked_maps);
end;
$$;
revoke all on function public.sd_unlock_map(text) from public, anon;
grant execute on function public.sd_unlock_map(text) to authenticated;

-- ---------- avatar + player name change (migration "sd_player_avatar_and_rename") ----------
alter table public.sd_player_profiles add column if not exists avatar text not null default 'astronaut'
 check (avatar in ('astronaut','astronaut_f','astronaut_m','robot','alien','invader','ufo','rocket','planet','comet','star','dragon','fox','wolf','lion','skull'));

create or replace function public.sd_set_avatar(p_avatar text)
returns text language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_avatar not in ('astronaut','astronaut_f','astronaut_m','robot','alien','invader','ufo','rocket','planet','comet','star','dragon','fox','wolf','lion','skull') then raise exception 'Unknown avatar'; end if;
 update public.sd_player_profiles set avatar = p_avatar where id = auth.uid();
 if not found then raise exception 'Profile missing'; end if;
 return p_avatar;
end;
$$;
revoke all on function public.sd_set_avatar(text) from public, anon;
grant execute on function public.sd_set_avatar(text) to authenticated;

create or replace function public.sd_set_username(p_username text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_name text := trim(p_username);
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if v_name is null or char_length(v_name) not between 3 and 24 or v_name !~ '^[A-Za-z0-9_ .-]+$' then raise exception 'Invalid username'; end if;
 if exists (select 1 from public.sd_player_profiles where lower(username) = lower(v_name) and id <> auth.uid()) then raise exception 'Username already taken'; end if;
 update public.sd_player_profiles set username = v_name where id = auth.uid();
 if not found then raise exception 'Profile missing'; end if;
 return v_name;
end;
$$;
revoke all on function public.sd_set_username(text) from public, anon;
grant execute on function public.sd_set_username(text) to authenticated;
