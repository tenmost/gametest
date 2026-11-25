-- RPS Rivals: crystals for ONLINE matches (player vs player). Computer matches stay at about 20 % of this.
--   Online win = 25 blue · online loss = 5 blue        (computer: win 5, perfect win 8, loss 1 — unchanged)
-- Safety: a match only pays once BOTH players' games reported the same result (one says won, the other lost,
-- same room, within 3 minutes — the pairing in sd_online_report). Anti-farming: rewards only for the first
-- 3 matches against the SAME opponent per day and at most 20 rewarded online matches per player per day.
-- Replaces sd_online_report from social.sql (same arguments, same answer). Only sd_* objects. Safe to re-run.

alter table public.sd_online_reports add column if not exists reward integer not null default 0;

create or replace function public.sd_online_reward_amount(p_won boolean)
returns integer language sql immutable set search_path = '' as $$ select case when p_won then 25 else 5 end $$;
revoke all on function public.sd_online_reward_amount(boolean) from public, anon, authenticated;

-- pays one paired report (internal)
create or replace function public.sd_online_pay(p_report bigint)
returns integer language plpgsql security definer set search_path = '' as $$
declare r public.sd_online_reports%rowtype; v_day date; v_amt int;
begin
 select * into r from public.sd_online_reports where id = p_report for update;
 if not found or not r.paired or r.reward > 0 then return 0; end if;
 v_day := (r.created_at at time zone 'UTC')::date;
 if (select count(*) from public.sd_online_reports where user_id = r.user_id and opp_id = r.opp_id and reward > 0
       and created_at >= v_day::timestamp at time zone 'UTC' and created_at < (v_day + 1)::timestamp at time zone 'UTC') >= 3 then return 0; end if;
 if (select count(*) from public.sd_online_reports where user_id = r.user_id and reward > 0
       and created_at >= v_day::timestamp at time zone 'UTC' and created_at < (v_day + 1)::timestamp at time zone 'UTC') >= 20 then return 0; end if;
 v_amt := public.sd_online_reward_amount(r.won);
 update public.sd_online_reports set reward = v_amt where id = r.id;
 update public.sd_player_profiles set crystals = crystals + v_amt where id = r.user_id;
 return v_amt;
end;
$$;
revoke all on function public.sd_online_pay(bigint) from public, anon, authenticated;

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
 if v_other is not null then
  update public.sd_online_reports set paired = true where id in (v_me, v_other);
  perform public.sd_online_pay(v_me);
  perform public.sd_online_pay(v_other);
 end if;
 return v_other is not null;
end;
$$;
revoke all on function public.sd_online_report(text, uuid, boolean) from public, anon;
grant execute on function public.sd_online_report(text, uuid, boolean) to authenticated;
