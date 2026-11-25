-- Space Duel: Crystal Nebula arena, unlocked with 50 PINK crystals.
-- NOT APPLIED YET: Dainis applies this to the shared project mrrqfrmgblbgrvkbrwvt as migration "sd_pink_arena"
-- (Supabase → SQL Editor → paste → Run). Needs social.sql (pink_crystals column) — already applied.
-- Keep prices in sync with `prices` / PINK_MAPS in index.html. Only sd_* objects.

create or replace function public.sd_unlock_map(p_map text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_price int; v_pink boolean := p_map = 'nebula'; v_prof public.sd_player_profiles%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 v_price := case p_map when 'temple' then 0 when 'city' then 20 when 'jungle' then 35 when 'ice' then 50
                       when 'lava' then 75 when 'factory' then 100 when 'nebula' then 50 else null end;
 if v_price is null then raise exception 'Unknown arena'; end if;
 select * into v_prof from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 if not (p_map = any(v_prof.unlocked_maps)) then
  if v_pink then
   if v_prof.pink_crystals < v_price then raise exception 'Not enough pink crystals'; end if;
   update public.sd_player_profiles set pink_crystals = pink_crystals - v_price, unlocked_maps = array_append(unlocked_maps, p_map)
    where id = auth.uid() returning * into v_prof;
  else
   if v_prof.crystals < v_price then raise exception 'Not enough crystals'; end if;
   update public.sd_player_profiles set crystals = crystals - v_price, unlocked_maps = array_append(unlocked_maps, p_map)
    where id = auth.uid() returning * into v_prof;
  end if;
 end if;
 return jsonb_build_object('crystals', v_prof.crystals, 'pink_crystals', v_prof.pink_crystals, 'unlocked_maps', v_prof.unlocked_maps);
end;
$$;
revoke all on function public.sd_unlock_map(text) from public, anon;
grant execute on function public.sd_unlock_map(text) to authenticated;
