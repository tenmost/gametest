-- RPS Rivals: CARD SKINS in the SHOP (cosmetic). Price + balance are checked here, never in the browser.
--   classic free · neon 150 blue · frost 150 blue · molten 400 blue · golden 1200 blue · prism 150 PINK
-- Keep keys/prices in sync with CARD_SKINS in index.html. Only sd_* objects. Safe to re-run.

alter table public.sd_player_profiles add column if not exists card_skin text not null default 'classic';
alter table public.sd_player_profiles add column if not exists unlocked_card_skins text[] not null default '{}';

create or replace function public.sd_card_skin_price(p_skin text)
returns table(price int, pink boolean) language sql immutable set search_path = '' as $$
 select v.price, v.pink from (values ('classic',0,false),('neon',150,false),('frost',150,false),('molten',400,false),('golden',1200,false),('prism',150,true))
   as v(k, price, pink) where v.k = p_skin;
$$;
revoke all on function public.sd_card_skin_price(text) from public, anon, authenticated;

-- buy a skin (and put it on right away)
create or replace function public.sd_unlock_card_skin(p_skin text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v record; p public.sd_player_profiles%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into v from public.sd_card_skin_price(p_skin);
 if not found then raise exception 'Unknown card skin'; end if;
 select * into p from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 if p_skin <> 'classic' and not (p_skin = any(p.unlocked_card_skins)) then
  if v.pink then
   if p.pink_crystals < v.price then raise exception 'Not enough pink crystals'; end if;
   update public.sd_player_profiles set pink_crystals = pink_crystals - v.price where id = auth.uid();
  else
   if p.crystals < v.price then raise exception 'Not enough crystals'; end if;
   update public.sd_player_profiles set crystals = crystals - v.price where id = auth.uid();
  end if;
  update public.sd_player_profiles set unlocked_card_skins = array_append(unlocked_card_skins, p_skin) where id = auth.uid();
 end if;
 update public.sd_player_profiles set card_skin = p_skin where id = auth.uid() returning * into p;
 return jsonb_build_object('card_skin', p.card_skin, 'unlocked_card_skins', p.unlocked_card_skins, 'crystals', p.crystals, 'pink_crystals', p.pink_crystals);
end;
$$;
revoke all on function public.sd_unlock_card_skin(text) from public, anon;
grant execute on function public.sd_unlock_card_skin(text) to authenticated;

-- switch to a skin you already own
create or replace function public.sd_set_card_skin(p_skin text)
returns text language plpgsql security definer set search_path = '' as $$
declare p public.sd_player_profiles%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not exists (select 1 from public.sd_card_skin_price(p_skin)) then raise exception 'Unknown card skin'; end if;
 select * into p from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 if p_skin <> 'classic' and not (p_skin = any(p.unlocked_card_skins)) then raise exception 'You do not own this card skin yet'; end if;
 update public.sd_player_profiles set card_skin = p_skin where id = auth.uid();
 return p_skin;
end;
$$;
revoke all on function public.sd_set_card_skin(text) from public, anon;
grant execute on function public.sd_set_card_skin(text) to authenticated;
