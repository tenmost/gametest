-- RPS Rivals: INBOX — friend-request count + private messages between ACCEPTED friends only.
-- No direct table access for clients (RLS on, no policies); everything goes through these security-definer RPCs.
-- Only sd_* objects. Safe to re-run.

create table if not exists public.sd_messages (
  id bigserial primary key,
  friendship uuid not null references public.sd_friends(id) on delete cascade,
  sender uuid not null,
  receiver uuid not null,
  body text not null check (char_length(body) between 1 and 200),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists sd_messages_conv on public.sd_messages (friendship, created_at desc);
create index if not exists sd_messages_unread on public.sd_messages (receiver) where read_at is null;
alter table public.sd_messages enable row level security;
revoke all on public.sd_messages from anon, authenticated;

-- send: only to an accepted friend, max 8 messages per minute, links removed
create or replace function public.sd_msg_send(p_friendship uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare f public.sd_friends%rowtype; b text; other uuid; n int;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into f from public.sd_friends where id = p_friendship;
 if not found or f.status <> 'accepted' or auth.uid() not in (f.requester, f.addressee) then raise exception 'Not friends'; end if;
 b := btrim(regexp_replace(coalesce(p_body,''), '\s+', ' ', 'g'));
 b := regexp_replace(b, '(https?://|www\.)\S*', '[link removed]', 'gi');
 b := left(b, 200);
 if b = '' then raise exception 'Empty message'; end if;
 select count(*) into n from public.sd_messages where sender = auth.uid() and created_at > now() - interval '1 minute';
 if n >= 8 then raise exception 'Slow down — too many messages'; end if;
 other := case when f.requester = auth.uid() then f.addressee else f.requester end;
 insert into public.sd_messages(friendship, sender, receiver, body) values (p_friendship, auth.uid(), other, b);
 delete from public.sd_messages where friendship = p_friendship and id not in (select id from public.sd_messages where friendship = p_friendship order by id desc limit 200);
 return jsonb_build_object('ok', true, 'to', other);
end; $$;

-- one conversation (newest 60), oldest first; marks the ones sent to you as read
create or replace function public.sd_msg_list(p_friendship uuid)
returns table(id bigint, mine boolean, body text, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare f public.sd_friends%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into f from public.sd_friends where sd_friends.id = p_friendship;
 if not found or auth.uid() not in (f.requester, f.addressee) then raise exception 'Not friends'; end if;
 update public.sd_messages m set read_at = now() where m.friendship = p_friendship and m.receiver = auth.uid() and m.read_at is null;
 return query select x.id, x.mine, x.body, x.created_at from (
   select m.id, m.sender = auth.uid() as mine, m.body, m.created_at from public.sd_messages m
    where m.friendship = p_friendship order by m.id desc limit 60) x order by x.id;
end; $$;

-- what the bell shows: incoming friend requests + unread messages per friend
create or replace function public.sd_inbox()
returns jsonb language sql stable security definer set search_path = '' as $$
 select jsonb_build_object(
  'requests', (select count(*) from public.sd_friends f where f.addressee = auth.uid() and f.status = 'pending'),
  'unread', coalesce((select jsonb_object_agg(friendship, c) from (select friendship, count(*) c from public.sd_messages where receiver = auth.uid() and read_at is null group by friendship) u), '{}'::jsonb))
 where auth.uid() is not null;
$$;

revoke all on function public.sd_msg_send(uuid, text) from public, anon;
revoke all on function public.sd_msg_list(uuid) from public, anon;
revoke all on function public.sd_inbox() from public, anon;
grant execute on function public.sd_msg_send(uuid, text) to authenticated;
grant execute on function public.sd_msg_list(uuid) to authenticated;
grant execute on function public.sd_inbox() to authenticated;
