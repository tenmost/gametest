-- Online hero XP only for CONFIRMED matches (both logged-in players reported the same result → paired).
-- Before: any own sd_online_reports row counted, even if the other side never confirmed (e.g. a guest
-- or a made-up opponent), so one account could farm online XP alone. Replaces sd_hero_xp_award.
create or replace function public.sd_hero_xp_award(p_source text, p_ref text, p_hero text)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
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
    select * into v_r from sd_online_reports where user_id = uid and room = upper(p_ref) and created_at > now() - interval '15 minutes'
      order by created_at desc limit 1;
    if not found then raise exception 'report not found'; end if;
    if not v_r.paired then raise exception 'not confirmed yet'; end if;
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
end $function$;
