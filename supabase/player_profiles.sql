-- Player profiles: private, server-owned progression.
create table if not exists public.sd_player_profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 username text not null check (char_length(username) between 3 and 24),
 crystals integer not null default 0 check (crystals >= 0),
 wins integer not null default 0 check (wins >= 0),
 losses integer not null default 0 check (losses >= 0),
 unlocked_characters text[] not null default array['girl']::text[],
 unlocked_maps text[] not null default array['temple']::text[],
 created_at timestamptz not null default now()
);
alter table public.sd_player_profiles enable row level security;
revoke all on public.sd_player_profiles from anon, authenticated;
grant select on public.sd_player_profiles to authenticated;
create policy "Read own game profile" on public.sd_player_profiles for select to authenticated using (auth.uid() = id);
create or replace function public.sd_init_player_profile(p_username text)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_username is null or char_length(trim(p_username)) not between 3 and 24 then raise exception 'Invalid username'; end if;
 insert into public.sd_player_profiles(id,username) values(auth.uid(),trim(p_username)) on conflict(id) do nothing;
end;
$$;
revoke all on function public.sd_init_player_profile(text) from public, anon;
grant execute on function public.sd_init_player_profile(text) to authenticated;
-- Match rewards must be implemented by a trusted match verifier, not a browser RPC accepting arbitrary scores.
