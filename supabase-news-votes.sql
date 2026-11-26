-- 요트 다이스 라운지: 업데이트 공지(버전별) 좋아요/싫어요 (Supabase SQL Editor에서 한 번 실행)
-- 공지 내용은 페이지 코드(CHANGELOG)에 있고, 여기에는 버전 이름(예: 1.7.1)별 표만 저장한다.
create table if not exists public.news_votes (
  ver text not null check (ver ~ '^[0-9]{1,3}(\.[0-9]{1,3}){1,3}$'),
  voter uuid not null default auth.uid() references auth.users on delete cascade,
  value smallint not null check (value in (-1, 1)),
  primary key (ver, voter)
);
alter table public.news_votes enable row level security;
drop policy if exists "news votes are public" on public.news_votes;
create policy "news votes are public" on public.news_votes for select using (true);
drop policy if exists "news vote as yourself" on public.news_votes;
create policy "news vote as yourself" on public.news_votes for insert to authenticated with check (voter = auth.uid());
drop policy if exists "change own news vote" on public.news_votes;
create policy "change own news vote" on public.news_votes for update to authenticated using (voter = auth.uid()) with check (voter = auth.uid());
drop policy if exists "remove own news vote" on public.news_votes;
create policy "remove own news vote" on public.news_votes for delete to authenticated using (voter = auth.uid());
revoke insert, update, delete on public.news_votes from anon, authenticated;
grant select on public.news_votes to anon, authenticated;
grant insert (ver, value) on public.news_votes to authenticated;
grant update (value) on public.news_votes to authenticated;
grant delete on public.news_votes to authenticated;

create or replace view public.news_vote_counts with (security_invoker = on) as
  select ver, (count(*) filter (where value = 1))::int as up, (count(*) filter (where value = -1))::int as down
  from public.news_votes group by ver;
grant select on public.news_vote_counts to anon, authenticated;
