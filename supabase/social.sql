-- Space Duel: pink crystals, friend invites (referrals), share + online-with-friends daily missions, pink avatar.
-- NOT APPLIED YET: Dainis applies this to the shared project mrrqfrmgblbgrvkbrwvt as migration "sd_social"
-- (Supabase → SQL Editor → paste → Run). Needs daily_missions.sql + premium_avatars.sql first (already applied).
-- Only sd_* objects. Nothing here touches tenmost.com tables.
--
-- Trust rules:
--  * invites: a friend counts only when a NEW account (created < 2 days ago, email-confirmed by Supabase) claims your code -> +1 pink, +10 blue to you, +5 blue to them
--  * online matches with friends count only when BOTH signed-in players report the same match (same room, each other as opponent, within 3 minutes)
--  * "share the game" cannot be verified by a browser, so it is capped: max 3 counted per day (daily mission only)

-- ---------- pink crystals + referral columns ----------
alter table public.sd_player_profiles add column if not exists pink_crystals integer not null default 0 check (pink_crystals >= 0);
alter table public.sd_player_profiles add column if not exists referred_by uuid references public.sd_player_profiles(id) on delete set null;
create index if not exists sd_player_profiles_referred_by on public.sd_player_profiles (referred_by);

-- ---------- invites ----------
-- invite code = first 8 characters of the player's id (shown in the invite link ?ref=xxxxxxxx)
create or replace function public.sd_claim_referral(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me public.sd_player_profiles%rowtype; v_ref uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_code is null or p_code !~ '^[0-9a-f]{8}$' then raise exception 'Invalid invite code'; end if;
 select * into me from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 if me.referred_by is not null then raise exception 'Invite already used'; end if;
 if me.created_at < now() - interval '2 days' then raise exception 'Invites only work for new accounts'; end if;
 select id into v_ref from public.sd_player_profiles where id::text like p_code || '%' and id <> auth.uid() limit 1;
 if v_ref is null then raise exception 'Invite code not found'; end if;
 update public.sd_player_profiles set referred_by = v_ref, crystals = crystals + 5 where id = auth.uid();
 update public.sd_player_profiles set pink_crystals = pink_crystals + 1, crystals = crystals + 10 where id = v_ref;
 return jsonb_build_object('ok', true, 'welcome_crystals', 5);
end;
$$;
revoke all on function public.sd_claim_referral(text) from public, anon;
grant execute on function public.sd_claim_referral(text) to authenticated;

create or replace function public.sd_my_invites()
returns jsonb language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('code', left(auth.uid()::text, 8),
   'joined', (select count(*) from public.sd_player_profiles where referred_by = auth.uid()));
$$;
revoke all on function public.sd_my_invites() from public, anon;
grant execute on function public.sd_my_invites() to authenticated;

-- ---------- shares (capped, for the daily mission) ----------
create table if not exists public.sd_daily_shares (
 user_id uuid not null references public.sd_player_profiles(id) on delete cascade,
 day date not null,
 shares integer not null default 0,
 primary key (user_id, day)
);
alter table public.sd_daily_shares enable row level security;
revoke all on public.sd_daily_shares from anon, authenticated;

create or replace function public.sd_daily_share()
returns integer language plpgsql security definer set search_path = '' as $$
declare v_day date := (now() at time zone 'UTC')::date; v_n int;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not exists (select 1 from public.sd_player_profiles where id = auth.uid()) then raise exception 'Profile missing'; end if;
 insert into public.sd_daily_shares(user_id, day, shares) values (auth.uid(), v_day, 1)
 on conflict (user_id, day) do update set shares = least(3, public.sd_daily_shares.shares + 1)
 returning shares into v_n;
 return v_n;
end;
$$;
revoke all on function public.sd_daily_share() from public, anon;
grant execute on function public.sd_daily_share() to authenticated;

-- ---------- online matches with friends (both players must report) ----------
create table if not exists public.sd_online_reports (
 id bigserial primary key,
 user_id uuid not null references public.sd_player_profiles(id) on delete cascade,
 opp_id uuid not null references public.sd_player_profiles(id) on delete cascade,
 room text not null,
 won boolean not null,
 paired boolean not null default false,
 created_at timestamptz not null default now()
);
create index if not exists sd_online_reports_user on public.sd_online_reports (user_id, created_at);
alter table public.sd_online_reports enable row level security;
revoke all on public.sd_online_reports from anon, authenticated;

create or replace function public.sd_online_report(p_room text, p_opp uuid, p_won boolean)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_me bigint; v_other bigint;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_opp is null or p_opp = auth.uid() then raise exception 'Invalid opponent'; end if;
 if p_room is null or char_length(p_room) not between 3 and 16 then raise exception 'Invalid room'; end if;
 if exists (select 1 from public.sd_online_reports where user_id = auth.uid() and created_at > now() - interval '20 seconds') then raise exception 'Too fast'; end if;
 if not exists (select 1 from public.sd_player_profiles where id = p_opp) then raise exception 'Opponent has no profile'; end if;
 insert into public.sd_online_reports(user_id, opp_id, room, won) values (auth.uid(), p_opp, upper(p_room), p_won) returning id into v_me;
 select id into v_other from public.sd_online_reports
  where user_id = p_opp and opp_id = auth.uid() and room = upper(p_room) and not paired and won <> p_won
    and created_at > now() - interval '3 minutes'
  order by created_at desc limit 1 for update;
 if v_other is not null then update public.sd_online_reports set paired = true where id in (v_me, v_other); end if;
 return v_other is not null;
end;
$$;
revoke all on function public.sd_online_report(text, uuid, boolean) from public, anon;
grant execute on function public.sd_online_report(text, uuid, boolean) to authenticated;

-- ---------- daily missions v2: 3 regular (rotating) + 2 social every day, social ones also give 1 pink ----------
drop function if exists public.sd_daily_progress(uuid, date);
drop function if exists public.sd_daily_pool();
create function public.sd_daily_pool()
returns table(id text, title text, goal integer, reward integer, pink integer) language sql immutable set search_path = '' as $$
 values ('play3',   'Play 3 matches vs computer',            3, 3, 0),
        ('win2',    'Win 2 matches',                         2, 5, 0),
        ('perfect1','Win a match without losing any health', 1, 8, 0),
        ('rounds20','Play 20 rounds',                       20, 4, 0),
        ('win4',    'Win 4 matches',                         4, 10, 0),
        ('play5',   'Play 5 matches vs computer',            5, 5, 0),
        ('share3',  'Share the game with 3 friends',         3, 5, 1),
        ('online3', 'Play 3 online matches with friends',    3, 8, 1);
$$;
revoke all on function public.sd_daily_pool() from public, anon, authenticated;

create or replace function public.sd_daily_set(p_day date)
returns text[] language sql immutable set search_path = '' as $$
 select array(select (array['play3','win2','perfect1','rounds20','win4','play5'])[1 + ((i + (p_day - date '2026-01-01') * 2) % 6)]
                from generate_series(0, 2) i order by i) || array['share3','online3'];
$$;
revoke all on function public.sd_daily_set(date) from public, anon, authenticated;

create function public.sd_daily_progress(p_user uuid, p_day date)
returns table(id text, title text, goal integer, reward integer, pink integer, progress integer, claimed boolean)
language sql stable security definer set search_path = '' as $$
 with m as (
  select status, perfect, rounds from public.sd_cpu_matches
   where user_id = p_user and finished_at >= p_day::timestamp at time zone 'UTC'
     and finished_at < (p_day + 1)::timestamp at time zone 'UTC'
     and (status = 'won' or (status = 'lost' and reward > 0))),
 s as (
  select count(*)::int as played, count(*) filter (where status = 'won')::int as won,
         count(*) filter (where status = 'won' and perfect)::int as perfect, coalesce(sum(rounds),0)::int as rounds from m),
 x as (
  select coalesce((select shares from public.sd_daily_shares where user_id = p_user and day = p_day), 0) as shares,
         (select count(*)::int from public.sd_online_reports where user_id = p_user and paired
            and created_at >= p_day::timestamp at time zone 'UTC' and created_at < (p_day + 1)::timestamp at time zone 'UTC') as online)
 select p.id, p.title, p.goal, p.reward, p.pink,
        least(p.goal, case p.id when 'play3' then s.played when 'play5' then s.played when 'win2' then s.won
                                when 'win4' then s.won when 'perfect1' then s.perfect when 'rounds20' then s.rounds
                                when 'share3' then x.shares when 'online3' then x.online else 0 end),
        exists (select 1 from public.sd_daily_claims c where c.user_id = p_user and c.day = p_day and c.mission = p.id)
   from public.sd_daily_pool() p, s, x
  where p.id = any (public.sd_daily_set(p_day))
  order by array_position(public.sd_daily_set(p_day), p.id);
$$;
revoke all on function public.sd_daily_progress(uuid, date) from public, anon, authenticated;

create or replace function public.sd_daily_claim(p_mission text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_day date := (now() at time zone 'UTC')::date; d record;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 perform 1 from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 select * into d from public.sd_daily_progress(auth.uid(), v_day) x where x.id = p_mission;
 if not found then raise exception 'Not a mission today'; end if;
 if d.claimed then raise exception 'Already claimed'; end if;
 if d.progress < d.goal then raise exception 'Mission not finished yet'; end if;
 insert into public.sd_daily_claims(user_id, day, mission, reward) values (auth.uid(), v_day, p_mission, d.reward);
 update public.sd_player_profiles set crystals = crystals + d.reward, pink_crystals = pink_crystals + d.pink where id = auth.uid();
 return public.sd_daily_missions() || jsonb_build_object('reward', d.reward, 'pink', d.pink,
   'crystals', (select crystals from public.sd_player_profiles where id = auth.uid()),
   'pink_crystals', (select pink_crystals from public.sd_player_profiles where id = auth.uid()));
end;
$$;
revoke all on function public.sd_daily_claim(text) from public, anon;
grant execute on function public.sd_daily_claim(text) to authenticated;

-- ---------- pink avatar: Cosmic Phoenix, 100 pink crystals ----------
create or replace function public.sd_avatar_price(p_avatar text)
returns integer language sql immutable set search_path = '' as $$
 select case
  when p_avatar in ('astronaut','astronaut_f','astronaut_m','robot','alien','invader','ufo','rocket','planet','comet','star','dragon','fox','wolf','lion','skull') then 0
  when p_avatar in ('moon','satellite','octopus','ghost') then 25
  when p_avatar in ('unicorn','shark','ninja','vampire') then 100
  when p_avatar in ('flame','bolt','galaxy','crystal_ball') then 300
  when p_avatar in ('vortex','crown','dragon_king') then 750
  when p_avatar = 'phoenix' then 100   -- paid in PINK crystals (see sd_unlock_avatar)
  else null end;
$$;

create or replace function public.sd_unlock_avatar(p_avatar text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_price int := public.sd_avatar_price(p_avatar); v_pink boolean := p_avatar = 'phoenix'; v_bal int; v_pbal int; v_owned text[];
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if v_price is null then raise exception 'Unknown avatar'; end if;
 if v_price = 0 then raise exception 'This avatar is free'; end if;
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
$$;
revoke all on function public.sd_unlock_avatar(text) from public, anon;
grant execute on function public.sd_unlock_avatar(text) to authenticated;
