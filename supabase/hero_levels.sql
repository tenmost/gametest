-- HERO LEVELS (Nov 2026): every hero a signed-in player uses earns XP and levels up.
-- XP is only granted for a match the SERVER already knows about:
--   'cpu'    = a finished row in sd_cpu_matches owned by the player (won 30 XP / lost 10 XP)
--   'online' = the player's own sd_online_reports row for that room (won 45 XP / lost 15 XP)
-- Each match can give XP only once (sd_hero_xp_log). Level = floor(sqrt(xp/40)) + 1
-- (Lv2 at 40 XP, Lv3 160, Lv4 360, Lv5 640, Lv10 3240). Levels are for show — they grant no crystals.

create table if not exists public.sd_hero_xp(
  user_id uuid not null references auth.users(id) on delete cascade,
  hero text not null check (hero ~ '^[a-z0-9_-]{1,40}$'),
  xp integer not null default 0,
  matches integer not null default 0,
  wins integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, hero)
);
alter table public.sd_hero_xp enable row level security;
drop policy if exists sd_hero_xp_own on public.sd_hero_xp;
create policy sd_hero_xp_own on public.sd_hero_xp for select using (auth.uid() = user_id);

create table if not exists public.sd_hero_xp_log(
  user_id uuid not null references auth.users(id) on delete cascade,
  source text not null,
  ref text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, source, ref)
);
alter table public.sd_hero_xp_log enable row level security;

create or replace function public.sd_hero_level(p_xp integer) returns integer
language sql immutable as $$ select floor(sqrt(greatest(coalesce(p_xp,0),0) / 40.0))::integer + 1 $$;

create or replace function public.sd_hero_xp_award(p_source text, p_ref text, p_hero text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); v_won boolean; v_gain integer; v_row sd_hero_xp%rowtype; v_m sd_cpu_matches%rowtype; v_r sd_online_reports%rowtype;
begin
  if uid is null then raise exception 'login required'; end if;
  if p_hero is null or p_hero !~ '^[a-z0-9_-]{1,40}$' then raise exception 'bad hero'; end if;
  if p_source = 'cpu' then
    select * into v_m from sd_cpu_matches where id = p_ref::uuid and user_id = uid and status in ('won','lost')
      and coalesce(finished_at, last_play_at) > now() - interval '15 minutes';
    if not found then raise exception 'match not found'; end if;
    v_won := v_m.status = 'won'; v_gain := case when v_won then 30 else 10 end;
  elsif p_source = 'online' then
    select * into v_r from sd_online_reports where user_id = uid and room = p_ref and created_at > now() - interval '15 minutes'
      order by created_at desc limit 1;
    if not found then raise exception 'report not found'; end if;
    v_won := v_r.won; v_gain := case when v_won then 45 else 15 end;
  else raise exception 'bad source'; end if;
  insert into sd_hero_xp_log(user_id, source, ref) values (uid, p_source, p_ref) on conflict do nothing;
  if not found then
    select * into v_row from sd_hero_xp where user_id = uid and hero = p_hero;
    return jsonb_build_object('hero', p_hero, 'xp', coalesce(v_row.xp,0), 'level', sd_hero_level(coalesce(v_row.xp,0)), 'gained', 0);
  end if;
  insert into sd_hero_xp(user_id, hero, xp, matches, wins) values (uid, p_hero, v_gain, 1, case when v_won then 1 else 0 end)
  on conflict (user_id, hero) do update set xp = sd_hero_xp.xp + v_gain, matches = sd_hero_xp.matches + 1,
    wins = sd_hero_xp.wins + case when v_won then 1 else 0 end, updated_at = now()
  returning * into v_row;
  return jsonb_build_object('hero', p_hero, 'xp', v_row.xp, 'level', sd_hero_level(v_row.xp), 'gained', v_gain, 'won', v_won);
end $$;

create or replace function public.sd_hero_levels()
returns table(hero text, xp integer, level integer, matches integer, wins integer)
language sql stable security definer set search_path = public as $$
  select h.hero, h.xp, sd_hero_level(h.xp), h.matches, h.wins from sd_hero_xp h where h.user_id = auth.uid()
$$;

revoke all on function public.sd_hero_xp_award(text,text,text) from public, anon;
grant execute on function public.sd_hero_xp_award(text,text,text) to authenticated;
revoke all on function public.sd_hero_levels() from public, anon;
grant execute on function public.sd_hero_levels() to authenticated;
grant execute on function public.sd_hero_level(integer) to anon, authenticated;
