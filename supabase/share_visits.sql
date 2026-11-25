-- RPS Rivals: the "share the game" daily mission only counts REAL shares.
-- Before: clicking SHARE called sd_daily_share() and counted at once, even if nothing was sent.
-- Now: a share counts when somebody ELSE opens your invite link (?ref=<code>).
--   * the visit is reported by the visitor's browser via sd_share_visit(code)
--   * one count per different internet address (IP) per day, max 3 a day;
--     the sharer's own visits never count (signed-in check + same-IP check)
--   * the client can no longer add shares itself (sd_daily_share is now read-only)
-- Run once in Supabase → SQL Editor. Only touches sd_* objects.

create table if not exists public.sd_share_visits (
 sharer uuid not null references public.sd_player_profiles(id) on delete cascade,
 day date not null,
 visitor text not null,          -- md5 of the visitor's IP address (never stored in plain text)
 created_at timestamptz not null default now(),
 primary key (sharer, day, visitor)
);
alter table public.sd_share_visits enable row level security;
revoke all on public.sd_share_visits from anon, authenticated;

-- remember the sharer's own IP when they press SHARE, so opening their own link doesn't count
create table if not exists public.sd_share_owner_ips (
 user_id uuid not null references public.sd_player_profiles(id) on delete cascade,
 ip text not null,
 seen_at timestamptz not null default now(),
 primary key (user_id, ip)
);
alter table public.sd_share_owner_ips enable row level security;
revoke all on public.sd_share_owner_ips from anon, authenticated;

create or replace function public.sd_request_ip()
returns text language sql stable set search_path = '' as $$
 select md5(coalesce(
   nullif(current_setting('request.headers', true)::json ->> 'cf-connecting-ip', ''),
   nullif(split_part(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ',', 1), ''),
   'unknown'));
$$;
revoke all on function public.sd_request_ip() from public, anon, authenticated;

-- called by the visitor's browser when the page is opened with ?ref=<code>
create or replace function public.sd_share_visit(p_code text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_sharer uuid; v_ip text := public.sd_request_ip(); v_day date := (now() at time zone 'UTC')::date; v_n int;
begin
 if p_code is null or p_code !~ '^[0-9a-f]{8}$' or v_ip = md5('unknown') then return false; end if;
 select id into v_sharer from public.sd_player_profiles where id::text like p_code || '%' limit 1;
 if v_sharer is null then return false; end if;
 if auth.uid() = v_sharer then return false; end if;                                   -- your own link
 if exists (select 1 from public.sd_share_owner_ips where user_id = v_sharer and ip = v_ip) then return false; end if; -- same network as the sharer
 insert into public.sd_share_visits(sharer, day, visitor) values (v_sharer, v_day, v_ip) on conflict do nothing;
 if not found then return false; end if;
 select count(*) into v_n from public.sd_share_visits where sharer = v_sharer and day = v_day;
 insert into public.sd_daily_shares(user_id, day, shares) values (v_sharer, v_day, least(3, v_n))
 on conflict (user_id, day) do update set shares = least(3, v_n);
 return true;
end;
$$;
revoke all on function public.sd_share_visit(text) from public;
grant execute on function public.sd_share_visit(text) to anon, authenticated;

-- SHARE button: no longer adds a share; it only remembers the sharer's own address and returns today's real count
create or replace function public.sd_daily_share()
returns integer language plpgsql security definer set search_path = '' as $$
declare v_day date := (now() at time zone 'UTC')::date;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not exists (select 1 from public.sd_player_profiles where id = auth.uid()) then raise exception 'Profile missing'; end if;
 insert into public.sd_share_owner_ips(user_id, ip) values (auth.uid(), public.sd_request_ip())
 on conflict (user_id, ip) do update set seen_at = now();
 return coalesce((select shares from public.sd_daily_shares where user_id = auth.uid() and day = v_day), 0);
end;
$$;
revoke all on function public.sd_daily_share() from public, anon;
grant execute on function public.sd_daily_share() to authenticated;

-- clear the shares that were counted by just clicking today (real visits from now on)
delete from public.sd_daily_shares where day = (now() at time zone 'UTC')::date;

-- clearer mission text
create or replace function public.sd_daily_pool()
returns table(id text, title text, goal integer, reward integer, pink integer) language sql immutable set search_path = '' as $$
 values ('play3',   'Play 3 matches vs computer',            3, 3, 0),
        ('win2',    'Win 2 matches',                         2, 5, 0),
        ('perfect1','Win a match without losing any health', 1, 8, 0),
        ('rounds20','Play 20 rounds',                       20, 4, 0),
        ('win4',    'Win 4 matches',                         4, 10, 0),
        ('play5',   'Play 5 matches vs computer',            5, 5, 0),
        ('share3',  '3 friends open your invite link',       3, 5, 1),
        ('online3', 'Play 3 online matches with friends',    3, 8, 1);
$$;
revoke all on function public.sd_daily_pool() from public, anon, authenticated;
