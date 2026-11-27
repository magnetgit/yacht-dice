-- 요트 다이스 라운지: 로비 공용 채팅 (Supabase SQL Editor에서 한 번 실행)
-- 채팅은 Supabase Realtime(웹소켓)으로 오가서 TURN 중계를 쓰지 않는다. 접속자 목록은 Realtime presence로.
-- 쓰기는 로그인한 사람만. 욕설·링크·연락처·도배는 DB가 거절한다(페이지에서도 미리 가린다).

create table if not exists public.lobby_chat (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  name text not null default '',
  body text not null check (char_length(body) between 1 and 100),
  created_at timestamptz not null default now()
);
create index if not exists lobby_chat_time on public.lobby_chat (created_at desc);
alter table public.lobby_chat enable row level security;
drop policy if exists "lobby chat is public" on public.lobby_chat;
create policy "lobby chat is public" on public.lobby_chat for select using (true);
drop policy if exists "chat as yourself" on public.lobby_chat;
create policy "chat as yourself" on public.lobby_chat for insert to authenticated with check (user_id = auth.uid());
revoke all on public.lobby_chat from anon, authenticated;
grant select on public.lobby_chat to anon, authenticated;
grant insert (body) on public.lobby_chat to authenticated;

create or replace function public.lobby_chat_check() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  norm text := regexp_replace(lower(new.body), '[^가-힣ㄱ-ㅎㅏ-ㅣa-z]', '', 'g');
  hit text;
begin
  new.created_at := now();
  new.name := coalesce((select coalesce(p.nick, p.username) from public.profiles p where p.id = new.user_id), '손님');
  if public.is_banned_now() then raise exception 'banned'; end if;
  if new.body ~* '(https?://|www\.|[a-z0-9-]+\.(com|net|org|kr|io|me|xyz|top|co|ly|gg|site|shop|club|biz|info|link|app)([^a-z]|$)|open\.kakao|t\.me/|discord\.gg)' then
    raise exception 'spam:link';
  end if;
  if regexp_replace(new.body, '[\s.\-()]', '', 'g') ~ '01[016789][0-9]{7,8}' or regexp_replace(new.body, '[.-]', '', 'g') ~ '[0-9]{9,}' then
    raise exception 'spam:phone';
  end if;
  select kind into hit from public.filter_words where position(word in norm) > 0 order by kind limit 1;
  if hit = 'abuse' then raise exception 'spam:abuse'; elsif hit = 'spam' then raise exception 'spam:word'; end if;
  -- 도배: 2초에 한 번, 1분에 15번까지, 같은 말은 30초 안에 다시 못 씀
  if exists (select 1 from public.lobby_chat where user_id = new.user_id and created_at > now() - interval '2 seconds') then raise exception 'spam:fast'; end if;
  if (select count(*) from public.lobby_chat where user_id = new.user_id and created_at > now() - interval '1 minute') >= 15 then raise exception 'spam:fast'; end if;
  if exists (select 1 from public.lobby_chat where user_id = new.user_id and body = new.body and created_at > now() - interval '30 seconds') then raise exception 'spam:dup'; end if;
  -- 오래된 대화 정리 (최근 이틀만 남김)
  delete from public.lobby_chat where created_at < now() - interval '2 days';
  return new;
end $$;
drop trigger if exists lobby_chat_check on public.lobby_chat;
create trigger lobby_chat_check before insert on public.lobby_chat for each row execute function public.lobby_chat_check();

-- 관리자는 대화를 지울 수 있다
drop policy if exists "admin deletes chat" on public.lobby_chat;
create policy "admin deletes chat" on public.lobby_chat for delete to authenticated using (public.is_admin());
grant delete on public.lobby_chat to authenticated;

-- 새 대화를 Realtime으로 받기
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'lobby_chat') then
    alter publication supabase_realtime add table public.lobby_chat;
  end if;
end $$;
