-- 요트 다이스 라운지: 공지·피드백 게시판과 추천/비추천 (Supabase SQL Editor에서 한 번 실행)

-- 익명 로그인 계정(추천용, 기기마다 하나)은 profiles를 만들지 않는다
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.is_anonymous then return new; end if;
  insert into public.profiles (id, username, nick)
  values (new.id, lower(new.raw_user_meta_data->>'username'), left(new.raw_user_meta_data->>'nick', 12));
  return new;
end $$;

-- 관리자(공지 작성, 글 삭제)
create table if not exists public.admins (user_id uuid primary key references auth.users on delete cascade);
alter table public.admins enable row level security;
drop policy if exists "admins are public" on public.admins;
create policy "admins are public" on public.admins for select using (true);
grant select on public.admins to anon, authenticated;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;
grant execute on function public.is_admin() to anon, authenticated;

-- 게시글: board = notice(공지) | feedback(피드백). 작성자 이름은 DB가 정한다(익명 글은 '익명').
create table if not exists public.posts (
  id bigint generated always as identity primary key,
  board text not null check (board in ('notice', 'feedback')),
  title text not null check (char_length(title) between 1 and 60),
  body text not null check (char_length(body) between 1 and 2000),
  author uuid references auth.users on delete set null,
  author_name text not null default '익명',
  created_at timestamptz not null default now()
);
create index if not exists posts_board_time on public.posts (board, created_at desc);
create or replace function public.posts_fill() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.created_at := now();
  if new.author is null then new.author_name := '익명';
  else new.author_name := coalesce((select coalesce(p.nick, p.username) from public.profiles p where p.id = new.author), '익명');
  end if;
  -- 도배 방지: 한 사람(익명은 전체 익명 기준) 1분에 5개까지
  if (select count(*) from public.posts q where q.created_at > now() - interval '1 minute'
        and ((new.author is null and q.author is null) or q.author = new.author)) >= 5 then
    raise exception 'too many posts';
  end if;
  return new;
end $$;
drop trigger if exists posts_fill on public.posts;
create trigger posts_fill before insert on public.posts for each row execute function public.posts_fill();
alter table public.posts enable row level security;
drop policy if exists "posts are public" on public.posts;
create policy "posts are public" on public.posts for select using (true);
drop policy if exists "write feedback" on public.posts;
create policy "write feedback" on public.posts for insert to anon, authenticated
  with check (board = 'feedback' and (author is null or author = auth.uid()));
drop policy if exists "write notice" on public.posts;
create policy "write notice" on public.posts for insert to authenticated
  with check (board = 'notice' and public.is_admin() and author = auth.uid());
drop policy if exists "delete own or admin" on public.posts;
create policy "delete own or admin" on public.posts for delete to authenticated
  using (public.is_admin() or (author is not null and author = auth.uid()));
revoke insert, update, delete on public.posts from anon, authenticated;
grant select on public.posts to anon, authenticated;
grant insert (board, title, body, author) on public.posts to anon, authenticated;
grant delete on public.posts to authenticated;

-- 추천(+1)/비추천(-1): 한 계정(익명 로그인 포함)에 글마다 한 표. 같은 걸 다시 누르면 삭제(취소).
create table if not exists public.votes (
  post_id bigint not null references public.posts (id) on delete cascade,
  voter uuid not null default auth.uid() references auth.users on delete cascade,
  value smallint not null check (value in (-1, 1)),
  primary key (post_id, voter)
);
alter table public.votes enable row level security;
drop policy if exists "votes are public" on public.votes;
create policy "votes are public" on public.votes for select using (true);
drop policy if exists "vote as yourself" on public.votes;
create policy "vote as yourself" on public.votes for insert to authenticated with check (voter = auth.uid());
drop policy if exists "change own vote" on public.votes;
create policy "change own vote" on public.votes for update to authenticated using (voter = auth.uid()) with check (voter = auth.uid());
drop policy if exists "remove own vote" on public.votes;
create policy "remove own vote" on public.votes for delete to authenticated using (voter = auth.uid());
revoke insert, update, delete on public.votes from anon, authenticated;
grant select on public.votes to anon, authenticated;
grant insert (post_id, value) on public.votes to authenticated;
grant update (value) on public.votes to authenticated;
grant delete on public.votes to authenticated;

-- 목록용: 글 + 추천/비추천 수
create or replace view public.post_list with (security_invoker = on) as
  select p.id, p.board, p.title, p.body, p.author, p.author_name, p.created_at,
         count(v.*) filter (where v.value = 1)::int as up,
         count(v.*) filter (where v.value = -1)::int as down
  from public.posts p left join public.votes v on v.post_id = p.id
  group by p.id;
grant select on public.post_list to anon, authenticated;
