-- RPS Rivals: LEADERBOARD (top players by wins vs computer — server-verified wins only).
-- Shown on the start screen as a top-3 podium; clicking it opens the top 10 + your own rank.
-- Public data only: player name, avatar, wins, losses, best win streak (no crystals, no emails).
-- Everyone (also guests) may read it. Only sd_* objects. Safe to re-run.

create index if not exists sd_player_profiles_rank on public.sd_player_profiles (wins desc, best_streak desc);

create or replace function public.sd_leaderboard(p_limit integer default 10)
returns jsonb language sql stable security definer set search_path = '' as $$
 with ranked as (
  select id, username, avatar, wins, losses, best_streak,
         row_number() over (order by wins desc,
                                     (wins::numeric / greatest(1, wins + losses)) desc,
                                     best_streak desc, created_at asc) as rank
    from public.sd_player_profiles
   where username is not null and wins > 0)
 select jsonb_build_object(
  'top', coalesce((select jsonb_agg(jsonb_build_object('rank', rank, 'name', username, 'avatar', avatar, 'wins', wins,
                     'losses', losses, 'best', best_streak, 'me', id = auth.uid()) order by rank)
                     from ranked where rank <= least(greatest(coalesce(p_limit, 10), 1), 50)), '[]'::jsonb),
  'me', (select jsonb_build_object('rank', rank, 'wins', wins, 'losses', losses, 'name', username, 'avatar', avatar)
           from ranked where id = auth.uid()),
  'players', (select count(*) from ranked));
$$;
revoke all on function public.sd_leaderboard(integer) from public;
grant execute on function public.sd_leaderboard(integer) to anon, authenticated;
