-- CHRISTMAS EVENT 2026 (20 Nov 2026 – 6 Jan 2027, UTC). Players collect 🎁 presents by winning:
--   win vs computer = 1 🎁 (finished sd_cpu_matches row, status 'won')
--   win online      = 3 🎁 (own sd_online_reports row: won, paired, and it paid a reward — so the online anti-farming caps apply)
-- Reward tiers (claimed one by one in the EVENTS window, until 13 Jan 2027):
--   1:  5 🎁 → +20 blue      2: 15 🎁 → +3 pink
--   3: 30 🎁 → 🎅 Santa avatar (event-only, can't be bought)      4: 60 🎁 → +100 blue +10 pink
-- Everything is counted and paid on the server; the browser only asks.

create table if not exists public.sd_event_claims(
  user_id uuid not null references auth.users(id) on delete cascade,
  event text not null,
  tier smallint not null,
  created_at timestamptz not null default now(),
  primary key (user_id, event, tier)
);
alter table public.sd_event_claims enable row level security;

create or replace function public.sd_event_tiers(p_event text)
returns table(tier smallint, need integer, blue integer, pink integer, avatar text)
language sql immutable set search_path = '' as $$
  select * from (values (1::smallint, 5, 20, 0, null::text), (2::smallint, 15, 0, 3, null), (3::smallint, 30, 0, 0, 'santa'), (4::smallint, 60, 100, 10, null)) t(tier, need, blue, pink, avatar)
  where p_event = 'xmas2026'
$$;

create or replace function public.sd_event_points(p_event text, p_user uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select case when p_event <> 'xmas2026' then 0 else
    (select count(*)::int from public.sd_cpu_matches m where m.user_id = p_user and m.status = 'won'
       and m.finished_at >= '2026-11-20 00:00+00' and m.finished_at < '2027-01-07 00:00+00')
  + 3 * (select count(*)::int from public.sd_online_reports r where r.user_id = p_user and r.won and r.paired and coalesce(r.reward, 0) > 0
       and r.created_at >= '2026-11-20 00:00+00' and r.created_at < '2027-01-07 00:00+00')
  end
$$;

create or replace function public.sd_event_state(p_event text default 'xmas2026')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := auth.uid(); v_pts int := 0;
begin
  if p_event <> 'xmas2026' then raise exception 'Unknown event'; end if;
  if uid is not null then v_pts := public.sd_event_points(p_event, uid); end if;
  return jsonb_build_object('event', p_event, 'starts', '2026-11-20T00:00:00Z', 'ends', '2027-01-07T00:00:00Z', 'claim_until', '2027-01-14T00:00:00Z',
    'signed_in', uid is not null, 'points', v_pts,
    'tiers', (select jsonb_agg(jsonb_build_object('tier', t.tier, 'need', t.need, 'blue', t.blue, 'pink', t.pink, 'avatar', t.avatar,
       'claimed', exists(select 1 from public.sd_event_claims c where c.user_id = uid and c.event = p_event and c.tier = t.tier)) order by t.tier)
       from public.sd_event_tiers(p_event) t));
end $$;

create or replace function public.sd_event_claim(p_event text, p_tier integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); t record; v_pts int;
begin
  if uid is null then raise exception 'Sign in required'; end if;
  if now() >= '2027-01-14 00:00+00' then raise exception 'The Christmas event is over'; end if;
  select * into t from public.sd_event_tiers(p_event) x where x.tier = p_tier;
  if not found then raise exception 'Unknown reward'; end if;
  v_pts := public.sd_event_points(p_event, uid);
  if v_pts < t.need then raise exception 'You need % presents for this reward (you have %)', t.need, v_pts; end if;
  insert into public.sd_event_claims(user_id, event, tier) values (uid, p_event, p_tier) on conflict do nothing;
  if not found then raise exception 'Already claimed'; end if;
  update public.sd_player_profiles set crystals = crystals + t.blue,
     pink_crystals = coalesce(pink_crystals, 0) + t.pink,
     unlocked_avatars = case when t.avatar is not null and not (t.avatar = any (coalesce(unlocked_avatars, '{}'))) then array_append(coalesce(unlocked_avatars, '{}'), t.avatar) else unlocked_avatars end
   where id = uid;
  return public.sd_event_state(p_event);
end $$;

revoke all on function public.sd_event_points(text, uuid) from public, anon, authenticated;
revoke all on function public.sd_event_claim(text, integer) from public, anon;
grant execute on function public.sd_event_claim(text, integer) to authenticated;
grant execute on function public.sd_event_state(text) to anon, authenticated;

-- the 🎅 Santa avatar: owned only through the event (price 1 just marks it as "not free"; sd_unlock_avatar refuses to sell it)
CREATE OR REPLACE FUNCTION public.sd_avatar_price(p_avatar text)
 RETURNS integer LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $function$
 select case
  when p_avatar in ('astronaut','astronaut_f','astronaut_m','robot','alien','invader','ufo','rocket','planet','comet','star','dragon','fox','wolf','lion','skull') then 0
  when p_avatar in ('moon','satellite','octopus','ghost') then 25
  when p_avatar in ('unicorn','shark','ninja','vampire') then 100
  when p_avatar in ('flame','bolt','galaxy','crystal_ball') then 300
  when p_avatar in ('vortex','crown','dragon_king') then 750
  when p_avatar = 'phoenix' then 100   -- paid in PINK crystals (see sd_unlock_avatar)
  when p_avatar = 'santa' then 1       -- Christmas event reward only (see sd_event_claim)
  else null end;
$function$;

CREATE OR REPLACE FUNCTION public.sd_unlock_avatar(p_avatar text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
declare v_price int := public.sd_avatar_price(p_avatar); v_pink boolean := p_avatar = 'phoenix'; v_bal int; v_pbal int; v_owned text[];
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if v_price is null then raise exception 'Unknown avatar'; end if;
 if v_price = 0 then raise exception 'This avatar is free'; end if;
 if p_avatar = 'santa' then raise exception 'Santa is a Christmas event reward — collect 30 presents to get it'; end if;
 select crystals, pink_crystals, unlocked_avatars into v_bal, v_pbal, v_owned from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 if p_avatar = any (v_owned) then raise exception 'Already unlocked'; end if;
 if v_pink then
  if v_pbal < v_price then raise exception 'Not enough pink crystals: this avatar costs % (you have %)', v_price, v_pbal; end if;
  update public.sd_player_profiles set pink_crystals = pink_crystals - v_price, unlocked_avatars = array_append(unlocked_avatars, p_avatar), avatar = p_avatar where id = auth.uid();
 else
  if v_bal < v_price then raise exception 'Not enough blue crystals: this avatar costs % (you have %)', v_price, v_bal; end if;
  update public.sd_player_profiles set crystals = crystals - v_price, unlocked_avatars = array_append(unlocked_avatars, p_avatar), avatar = p_avatar where id = auth.uid();
 end if;
 return (select jsonb_build_object('crystals', crystals, 'pink_crystals', pink_crystals, 'unlocked_avatars', to_jsonb(unlocked_avatars), 'avatar', avatar)
           from public.sd_player_profiles where id = auth.uid());
end;
$function$;
