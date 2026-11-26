-- BUG REPORTS (v1.2.0): logged-in players send bug reports / ideas / player reports from the game,
-- admins read and answer them in admin.html (🐞 Bug reports tab).
-- Anti-spam (server-side): account needs a game profile, account at least 10 minutes old,
-- text 15–1000 chars, min 60 s between reports, max 5 per 24 h, no repeat of the same text within 7 days.
create table if not exists public.sd_bug_reports(
  id bigserial primary key,
  user_id uuid not null,
  username text,
  kind text not null check (kind in ('bug','broken','idea','player')),
  body text not null,
  page text, version text, device text, screen text,
  status text not null default 'new' check (status in ('new','seen','fixed','wontfix')),
  admin_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());
create index if not exists sd_bug_reports_user on public.sd_bug_reports(user_id, created_at desc);
create index if not exists sd_bug_reports_status on public.sd_bug_reports(status, created_at desc);
alter table public.sd_bug_reports enable row level security;  -- no policies: only through the functions below
revoke all on public.sd_bug_reports from anon, authenticated;

create or replace function public.sd_bug_report(p_kind text, p_body text, p_page text default null, p_version text default null, p_device text default null, p_screen text default null)
returns bigint language plpgsql security definer set search_path to '' as $$
declare uid uuid := auth.uid(); v_name text; v_body text; v_id bigint; v_created timestamptz;
begin
  if uid is null then raise exception 'Log in to send a report'; end if;
  select username into v_name from public.sd_player_profiles where id = uid;
  if not found then raise exception 'Make your player profile first'; end if;
  select created_at into v_created from auth.users where id = uid;
  if v_created is not null and v_created > now() - interval '10 minutes' then raise exception 'New accounts can send reports after 10 minutes'; end if;
  if p_kind is null or p_kind not in ('bug','broken','idea','player') then raise exception 'Pick what kind of report it is'; end if;
  v_body := btrim(regexp_replace(coalesce(p_body,''), '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]', '', 'g'));
  if char_length(v_body) < 15 then raise exception 'Please write a bit more (at least 15 letters)'; end if;
  if char_length(v_body) > 1000 then raise exception 'Too long (max 1000 letters)'; end if;
  if exists (select 1 from public.sd_bug_reports where user_id = uid and created_at > now() - interval '60 seconds') then raise exception 'Please wait a minute before sending another report'; end if;
  if (select count(*) from public.sd_bug_reports where user_id = uid and created_at > now() - interval '24 hours') >= 5 then raise exception 'You can send 5 reports a day — thank you! Try again tomorrow'; end if;
  if exists (select 1 from public.sd_bug_reports where user_id = uid and lower(body) = lower(v_body) and created_at > now() - interval '7 days') then raise exception 'You already sent this report'; end if;
  insert into public.sd_bug_reports(user_id, username, kind, body, page, version, device, screen)
  values (uid, v_name, p_kind, v_body, left(p_page,60), left(p_version,20), left(p_device,300), left(p_screen,40))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.sd_my_bug_reports()
returns table(id bigint, kind text, body text, status text, admin_note text, created_at timestamptz, updated_at timestamptz)
language sql stable security definer set search_path to '' as $$
  select r.id, r.kind, r.body, r.status, r.admin_note, r.created_at, r.updated_at
    from public.sd_bug_reports r where r.user_id = auth.uid() order by r.created_at desc limit 10 $$;

create or replace function public.sd_admin_bug_reports(p_status text default null, p_limit int default 200)
returns table(id bigint, user_id uuid, username text, kind text, body text, page text, version text, device text, screen text,
              status text, admin_note text, created_at timestamptz, updated_at timestamptz, user_reports bigint)
language plpgsql stable security definer set search_path to '' as $$
begin
  if not public.sd_is_admin() then raise exception 'Admins only'; end if;
  return query select r.id, r.user_id, r.username, r.kind, r.body, r.page, r.version, r.device, r.screen, r.status, r.admin_note,
    r.created_at, r.updated_at, (select count(*) from public.sd_bug_reports x where x.user_id = r.user_id)
    from public.sd_bug_reports r where p_status is null or r.status = p_status
    order by (r.status = 'new') desc, r.created_at desc limit least(greatest(coalesce(p_limit,200),1),500);
end $$;

create or replace function public.sd_admin_bug_counts()
returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if not public.sd_is_admin() then raise exception 'Admins only'; end if;
  return (select jsonb_object_agg(status, n) from (select status, count(*) n from public.sd_bug_reports group by status) s);
end $$;

create or replace function public.sd_admin_bug_set(p_id bigint, p_status text, p_note text default null)
returns boolean language plpgsql security definer set search_path to '' as $$
begin
  if not public.sd_is_admin() then raise exception 'Admins only'; end if;
  if p_status not in ('new','seen','fixed','wontfix') then raise exception 'Bad status'; end if;
  update public.sd_bug_reports set status = p_status,
    admin_note = case when p_note is null then admin_note else nullif(left(btrim(p_note),500),'') end, updated_at = now()
   where id = p_id;
  return found;
end $$;

revoke all on function public.sd_bug_report(text,text,text,text,text,text), public.sd_my_bug_reports(),
  public.sd_admin_bug_reports(text,int), public.sd_admin_bug_counts(), public.sd_admin_bug_set(bigint,text,text) from public, anon;
grant execute on function public.sd_bug_report(text,text,text,text,text,text), public.sd_my_bug_reports(),
  public.sd_admin_bug_reports(text,int), public.sd_admin_bug_counts(), public.sd_admin_bug_set(bigint,text,text) to authenticated;
