-- Space Duel: win streaks on player profiles + friends (request by player name, accept/decline, remove).
-- Applied to the shared project mrrqfrmgblbgrvkbrwvt as migration "sd_friends_and_streaks".
-- Only sd_* objects. Nothing here touches tenmost.com tables.

-- ---------- win streaks (updated by a trigger when a server-verified match vs computer ends) ----------
alter table public.sd_player_profiles add column if not exists current_streak integer not null default 0 check (current_streak >= 0);
alter table public.sd_player_profiles add column if not exists best_streak integer not null default 0 check (best_streak >= 0);

create or replace function public.sd_cpu_match_streak()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
 if old.status = 'active' and new.status = 'won' then
  update public.sd_player_profiles
     set current_streak = current_streak + 1, best_streak = greatest(best_streak, current_streak + 1)
   where id = new.user_id;
 elsif old.status = 'active' and new.status = 'lost' then
  update public.sd_player_profiles set current_streak = 0 where id = new.user_id;
 end if;
 return new;
end;
$$;
revoke all on function public.sd_cpu_match_streak() from public, anon, authenticated;
drop trigger if exists sd_cpu_matches_streak on public.sd_cpu_matches;
create trigger sd_cpu_matches_streak after update of status on public.sd_cpu_matches
 for each row execute function public.sd_cpu_match_streak();

-- backfill streaks from matches already played
with f as (
 select user_id, status, finished_at,
        sum(case when status = 'lost' then 1 else 0 end) over (partition by user_id order by finished_at, id) grp
   from public.sd_cpu_matches where status in ('won','lost') and finished_at is not null
), runs as (
 select user_id, grp, count(*) filter (where status = 'won') wins_in_run, max(finished_at) last_at from f group by user_id, grp
), agg as (
 select user_id, max(wins_in_run) best,
        (array_agg(wins_in_run order by last_at desc))[1] cur
   from runs group by user_id
)
update public.sd_player_profiles p set best_streak = coalesce(a.best, 0), current_streak = coalesce(a.cur, 0)
  from agg a where a.user_id = p.id;

-- ---------- friends ----------
create table if not exists public.sd_friends (
 id uuid primary key default gen_random_uuid(),
 requester uuid not null references public.sd_player_profiles(id) on delete cascade,
 addressee uuid not null references public.sd_player_profiles(id) on delete cascade,
 status text not null default 'pending' check (status in ('pending','accepted')),
 created_at timestamptz not null default now(),
 accepted_at timestamptz,
 check (requester <> addressee)
);
create unique index if not exists sd_friends_pair_key on public.sd_friends (least(requester, addressee), greatest(requester, addressee));
create index if not exists sd_friends_addressee on public.sd_friends (addressee);
alter table public.sd_friends enable row level security;
revoke all on public.sd_friends from anon, authenticated;
-- no policies: clients use only the RPCs below

create or replace function public.sd_friend_request(p_username text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_me uuid := auth.uid(); v_them uuid; v_row public.sd_friends%rowtype;
begin
 if v_me is null then raise exception 'Sign in required'; end if;
 if not exists (select 1 from public.sd_player_profiles where id = v_me) then raise exception 'Profile missing'; end if;
 select id into v_them from public.sd_player_profiles where lower(username) = lower(trim(p_username));
 if v_them is null then raise exception 'Player not found'; end if;
 if v_them = v_me then raise exception 'That is you'; end if;
 select * into v_row from public.sd_friends
  where least(requester, addressee) = least(v_me, v_them) and greatest(requester, addressee) = greatest(v_me, v_them) for update;
 if found then
  if v_row.status = 'accepted' then raise exception 'Already friends'; end if;
  if v_row.requester = v_me then raise exception 'Request already sent'; end if;
  update public.sd_friends set status = 'accepted', accepted_at = now() where id = v_row.id;  -- they asked me first
  return 'accepted';
 end if;
 if (select count(*) from public.sd_friends where requester = v_me and status = 'pending') >= 30 then raise exception 'Too many pending requests'; end if;
 if (select count(*) from public.sd_friends where (requester = v_me or addressee = v_me) and status = 'accepted') >= 200 then raise exception 'Friend list full'; end if;
 insert into public.sd_friends(requester, addressee) values (v_me, v_them);
 return 'sent';
end;
$$;
revoke all on function public.sd_friend_request(text) from public, anon;
grant execute on function public.sd_friend_request(text) to authenticated;

create or replace function public.sd_friend_respond(p_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_accept then
  update public.sd_friends set status = 'accepted', accepted_at = now() where id = p_id and addressee = auth.uid() and status = 'pending';
 else
  delete from public.sd_friends where id = p_id and addressee = auth.uid() and status = 'pending';
 end if;
 if not found then raise exception 'Request not found'; end if;
end;
$$;
revoke all on function public.sd_friend_respond(uuid, boolean) from public, anon;
grant execute on function public.sd_friend_respond(uuid, boolean) to authenticated;

-- removes a friend, cancels my sent request
create or replace function public.sd_friend_remove(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 delete from public.sd_friends where id = p_id and (requester = auth.uid() or addressee = auth.uid());
 if not found then raise exception 'Friend not found'; end if;
end;
$$;
revoke all on function public.sd_friend_remove(uuid) from public, anon;
grant execute on function public.sd_friend_remove(uuid) to authenticated;

-- my friends + pending requests; stats only for accepted friends
create or replace function public.sd_friends_list()
returns table(id uuid, status text, incoming boolean, username text, avatar text, wins integer, losses integer, best_streak integer)
language sql stable security definer set search_path = '' as $$
 select f.id, f.status, f.addressee = auth.uid(), p.username, p.avatar,
        case when f.status = 'accepted' then p.wins end,
        case when f.status = 'accepted' then p.losses end,
        case when f.status = 'accepted' then p.best_streak end
   from public.sd_friends f
   join public.sd_player_profiles p on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
  where auth.uid() is not null and (f.requester = auth.uid() or f.addressee = auth.uid())
  order by f.status desc, lower(p.username);
$$;
revoke all on function public.sd_friends_list() from public, anon;
grant execute on function public.sd_friends_list() to authenticated;
