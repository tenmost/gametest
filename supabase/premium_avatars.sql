-- Space Duel: premium avatars bought with blue crystals.
-- Applied to the shared project mrrqfrmgblbgrvkbrwvt (Nov 2026, SQL Editor) — migration name "sd_premium_avatars".
-- Keep keys + prices in sync with AV / AV_PRICE in index.html. Only sd_* objects.
--
-- Tiers: cheap 25 💎, rare 100 💎, epic 300 💎 (glowing), legendary 750 💎 (moving). The 16 original avatars stay free.

alter table public.sd_player_profiles add column if not exists unlocked_avatars text[] not null default '{}';

create or replace function public.sd_avatar_price(p_avatar text)
returns integer language sql immutable set search_path = '' as $$
 select case
  when p_avatar in ('astronaut','astronaut_f','astronaut_m','robot','alien','invader','ufo','rocket','planet','comet','star','dragon','fox','wolf','lion','skull') then 0
  when p_avatar in ('moon','satellite','octopus','ghost') then 25
  when p_avatar in ('unicorn','shark','ninja','vampire') then 100
  when p_avatar in ('flame','bolt','galaxy','crystal_ball') then 300
  when p_avatar in ('vortex','crown','dragon_king') then 750
  else null end;
$$;
revoke all on function public.sd_avatar_price(text) from public, anon, authenticated;

alter table public.sd_player_profiles drop constraint if exists sd_player_profiles_avatar_check;
alter table public.sd_player_profiles add constraint sd_player_profiles_avatar_check
 check (public.sd_avatar_price(avatar) is not null);

-- choose an avatar: free ones always, premium ones only after unlocking
create or replace function public.sd_set_avatar(p_avatar text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_price int := public.sd_avatar_price(p_avatar); v_owned text[];
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if v_price is null then raise exception 'Unknown avatar'; end if;
 select unlocked_avatars into v_owned from public.sd_player_profiles where id = auth.uid();
 if not found then raise exception 'Profile missing'; end if;
 if v_price > 0 and not (p_avatar = any (v_owned)) then raise exception 'Avatar locked — unlock it with blue crystals first'; end if;
 update public.sd_player_profiles set avatar = p_avatar where id = auth.uid();
 return p_avatar;
end;
$$;
revoke all on function public.sd_set_avatar(text) from public, anon;
grant execute on function public.sd_set_avatar(text) to authenticated;

-- buy a premium avatar: price + balance checked here, then it is also equipped
create or replace function public.sd_unlock_avatar(p_avatar text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_price int := public.sd_avatar_price(p_avatar); v_bal int; v_owned text[];
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if v_price is null then raise exception 'Unknown avatar'; end if;
 if v_price = 0 then raise exception 'This avatar is free'; end if;
 select crystals, unlocked_avatars into v_bal, v_owned from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 if p_avatar = any (v_owned) then raise exception 'Already unlocked'; end if;
 if v_bal < v_price then raise exception 'Not enough blue crystals: this avatar costs % (you have %)', v_price, v_bal; end if;
 update public.sd_player_profiles
    set crystals = crystals - v_price, unlocked_avatars = array_append(unlocked_avatars, p_avatar), avatar = p_avatar
  where id = auth.uid();
 return (select jsonb_build_object('crystals', crystals, 'unlocked_avatars', to_jsonb(unlocked_avatars), 'avatar', avatar)
           from public.sd_player_profiles where id = auth.uid());
end;
$$;
revoke all on function public.sd_unlock_avatar(text) from public, anon;
grant execute on function public.sd_unlock_avatar(text) to authenticated;
