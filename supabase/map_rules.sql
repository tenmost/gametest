-- Space Duel: arena rules on the server — Forgotten Graveyard = SUDDEN DEATH (one fight decides the match).
-- NOT APPLIED YET: Dainis applies this to the shared project mrrqfrmgblbgrvkbrwvt as migration "sd_map_rules"
-- (Supabase → SQL Editor → paste → Run). Until then the game plays Graveyard as a normal best-of-three for signed-in players.
-- Keep in sync with MAP_RULES in index.html. Only sd_* objects. (Pick timers are client-side only and need nothing here.)

alter table public.sd_cpu_matches add column if not exists map text;
alter table public.sd_cpu_matches add column if not exists fights_to_win smallint not null default 2 check (fights_to_win between 1 and 2);

-- new start function that knows the arena; returns {id, fw}. The old sd_match_start() stays for older clients.
create or replace function public.sd_match_start2(p_map text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_fw smallint := case when p_map = 'factory' then 1 else 2 end;
begin
 v_id := public.sd_match_start();   -- same checks + closes any active match (counts as a loss if rounds were played)
 update public.sd_cpu_matches set map = left(p_map, 20), fights_to_win = v_fw where id = v_id;
 return jsonb_build_object('id', v_id, 'fw', v_fw);
end;
$$;
revoke all on function public.sd_match_start2(text) from public, anon;
grant execute on function public.sd_match_start2(text) to authenticated;

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
  if m.p_fights >= m.fights_to_win or m.c_fights >= m.fights_to_win then
   v_done := true; v_won := m.p_fights >= m.fights_to_win;
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
