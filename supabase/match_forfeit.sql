-- Space Duel: leaving a match vs computer counts as a loss.
-- Applied to the shared project mrrqfrmgblbgrvkbrwvt (Nov 2026, SQL Editor) — migration name "sd_match_forfeit".
-- Only sd_* objects. Nothing here touches tenmost.com tables.

-- EXIT button: the player gives up the active match. Loss, 0 crystals, losses +1,
-- win streak reset (by the sd_cpu_matches_streak trigger on status -> 'lost').
create or replace function public.sd_match_forfeit(p_match uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m public.sd_cpu_matches%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into m from public.sd_cpu_matches where id = p_match and user_id = auth.uid() for update;
 if not found or m.status <> 'active' then raise exception 'Match not active'; end if;
 update public.sd_cpu_matches set status = 'lost', reward = 0, finished_at = now() where id = m.id;
 update public.sd_player_profiles set losses = losses + 1 where id = auth.uid();
 return jsonb_build_object('forfeit', true,
   'crystals', (select crystals from public.sd_player_profiles where id = auth.uid()));
end;
$$;
revoke all on function public.sd_match_forfeit(uuid) from public, anon;
grant execute on function public.sd_match_forfeit(uuid) to authenticated;

-- Starting a new match while one is still active (page refresh / tab closed mid-match):
-- if at least one round was played, the old match counts as a loss (0 crystals),
-- so a losing match can't be escaped by reloading. Untouched matches are just abandoned.
create or replace function public.sd_match_start()
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_lost int;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not exists (select 1 from public.sd_player_profiles where id = auth.uid()) then raise exception 'Profile missing'; end if;
 with f as (
  update public.sd_cpu_matches set status = 'lost', reward = 0, finished_at = now()
   where user_id = auth.uid() and status = 'active' and rounds > 0 returning 1)
 select count(*) into v_lost from f;
 if v_lost > 0 then update public.sd_player_profiles set losses = losses + v_lost where id = auth.uid(); end if;
 update public.sd_cpu_matches set status = 'abandoned', finished_at = now() where user_id = auth.uid() and status = 'active';
 insert into public.sd_cpu_matches(user_id) values (auth.uid()) returning id into v_id;
 return v_id;
end;
$$;
revoke all on function public.sd_match_start() from public, anon;
grant execute on function public.sd_match_start() to authenticated;
