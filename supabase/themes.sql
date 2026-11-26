-- RPS Rivals: MENU THEMES (cosmetic look of the start screen). Price + balance are checked here, never in the browser.
--   moon free · forge free · arcane (Magic Night) 300 blue · sakura (Sakura Dojo) 500 blue · frost (Frost Kingdom) 800 blue · royal (Golden Dragon) 60 PINK
-- Keep keys/prices in sync with THEME_SHOP in index.html. Only sd_* objects. Safe to re-run.

alter table public.sd_player_profiles add column if not exists unlocked_themes text[] not null default '{}';

create or replace function public.sd_theme_price(p_theme text)
returns table(price int, pink boolean) language sql immutable set search_path = '' as $$
 select v.price, v.pink from (values ('moon',0,false),('forge',0,false),('arcane',300,false),('sakura',500,false),('frost',800,false),('royal',60,true))
   as v(k, price, pink) where v.k = p_theme;
$$;
revoke all on function public.sd_theme_price(text) from public, anon, authenticated;

create or replace function public.sd_unlock_theme(p_theme text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v record; p public.sd_player_profiles%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into v from public.sd_theme_price(p_theme);
 if not found then raise exception 'Unknown theme'; end if;
 select * into p from public.sd_player_profiles where id = auth.uid() for update;
 if not found then raise exception 'Profile missing'; end if;
 if v.price > 0 and not (p_theme = any(p.unlocked_themes)) then
  if v.pink then
   if p.pink_crystals < v.price then raise exception 'Not enough pink crystals'; end if;
   update public.sd_player_profiles set pink_crystals = pink_crystals - v.price where id = auth.uid();
  else
   if p.crystals < v.price then raise exception 'Not enough crystals'; end if;
   update public.sd_player_profiles set crystals = crystals - v.price where id = auth.uid();
  end if;
  update public.sd_player_profiles set unlocked_themes = array_append(unlocked_themes, p_theme) where id = auth.uid();
 end if;
 select * into p from public.sd_player_profiles where id = auth.uid();
 return jsonb_build_object('unlocked_themes', p.unlocked_themes, 'crystals', p.crystals, 'pink_crystals', p.pink_crystals);
end;
$$;
revoke all on function public.sd_unlock_theme(text) from public, anon;
grant execute on function public.sd_unlock_theme(text) to authenticated;
