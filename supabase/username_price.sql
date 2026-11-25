-- Space Duel: changing your player name costs blue crystals (the first name, chosen at sign-up, is free).
-- NOT APPLIED YET: Dainis applies this to the shared project mrrqfrmgblbgrvkbrwvt as migration "sd_username_price"
-- (Supabase → SQL Editor → paste → Run). Until then name changes are still free on the server.
-- Keep the price in sync with NAME_PRICE in index.html. Only sd_* objects.

create or replace function public.sd_set_username(p_username text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_name text := trim(p_username); v_price constant int := 150; v_cur text; v_bal int;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if v_name is null or char_length(v_name) not between 3 and 24 or v_name !~ '^[A-Za-z0-9_ .-]+$' then raise exception 'Invalid username'; end if;
 select username, crystals into v_cur, v_bal from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 if v_cur = v_name then return v_name; end if;
 if exists (select 1 from public.sd_player_profiles where lower(username) = lower(v_name) and id <> auth.uid()) then raise exception 'Username already taken'; end if;
 if v_bal < v_price then raise exception 'Not enough blue crystals: changing your player name costs % (you have %)', v_price, v_bal; end if;
 update public.sd_player_profiles set username = v_name, crystals = crystals - v_price where id = auth.uid();
 return v_name;
end;
$$;
revoke all on function public.sd_set_username(text) from public, anon;
grant execute on function public.sd_set_username(text) to authenticated;
