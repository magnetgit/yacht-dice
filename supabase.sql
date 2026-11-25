-- 요트 다이스 라운지: 계정과 대전 기록 (Supabase SQL Editor에서 한 번 실행)

-- 1) 계정: 로그인 아이디와 마지막으로 쓴 닉네임. 비밀번호는 Supabase Auth가 따로 암호화해 보관한다.
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_]{3,16}$'),
  nick text check (nick is null or char_length(nick) between 1 and 12),
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "profiles are public" on public.profiles;
create policy "profiles are public" on public.profiles for select using (true);
drop policy if exists "own nick" on public.profiles;
create policy "own nick" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
revoke insert, update, delete on public.profiles from anon, authenticated;
grant update (nick) on public.profiles to authenticated;

-- 가입하면 profiles 행을 자동으로 만든다 (아이디는 가입할 때 보낸 username)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, username, nick)
  values (new.id, lower(new.raw_user_meta_data->>'username'), left(new.raw_user_meta_data->>'nick', 12));
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 2) 대전 보고: 판이 끝나면 로그인한 참가자 각자가, 같은 판의 로그인 참가자 모두의 등수를 보고한다.
--    자기 이름으로만 보고할 수 있고, 같은 판의 서로 다른 두 사람 이상이 똑같이 보고한 결과만 인정한다.
create table if not exists public.reports (
  game_id text not null check (char_length(game_id) between 4 and 40),
  subject uuid not null references public.profiles (id) on delete cascade,
  reporter uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  rank smallint not null check (rank between 1 and 8),
  score smallint not null check (score between 0 and 500),
  players smallint not null check (players between 2 and 8 and rank <= players),
  created_at timestamptz not null default now(),
  primary key (game_id, subject, reporter)
);
alter table public.reports enable row level security;
drop policy if exists "reports are public" on public.reports;
create policy "reports are public" on public.reports for select using (true);
drop policy if exists "report as yourself" on public.reports;
create policy "report as yourself" on public.reports for insert to authenticated with check (reporter = auth.uid());
revoke update, delete on public.reports from anon, authenticated;

-- 인정된 결과
create or replace view public.results with (security_invoker = on) as
  select game_id, subject as user_id, rank, score, players, min(created_at) as played_at
  from public.reports
  group by game_id, subject, rank, score, players
  having count(distinct reporter) >= 2;

-- 3) 순위: period = week | month | year | all (한국 시간 기준). 1등 횟수, 같으면 평균 등수.
create or replace function public.leaderboard(period text)
returns table (user_id uuid, name text, wins int, games int, avg_rank numeric, total_wins int)
language sql stable set search_path = '' as $$
  with since as (
    select case period
      when 'week'  then date_trunc('week',  now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'
      when 'month' then date_trunc('month', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'
      when 'year'  then date_trunc('year',  now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'
      else '-infinity'::timestamptz end as t
  ), r as (
    select x.* from public.results x, since where x.played_at >= since.t
  )
  select p.id, coalesce(p.nick, p.username),
         (count(*) filter (where r.rank = 1))::int,
         count(*)::int,
         round(avg(r.rank), 2),
         (select count(*) from public.results a where a.user_id = p.id and a.rank = 1)::int
  from r join public.profiles p on p.id = r.user_id
  group by p.id
  order by 3 desc, 5 asc, 4 desc, 2 asc
  limit 50
$$;

-- 4) 메달용: 여러 사람의 통산 1등 횟수
create or replace function public.wins_of(ids uuid[])
returns table (user_id uuid, wins int)
language sql stable set search_path = '' as $$
  select r.user_id, (count(*) filter (where r.rank = 1))::int
  from public.results r where r.user_id = any(ids) group by r.user_id
$$;

grant execute on function public.leaderboard(text) to anon, authenticated;
grant execute on function public.wins_of(uuid[]) to anon, authenticated;

-- 5) 이 프로젝트는 새 표에 기본 권한이 없어서 필요한 것만 직접 연다
grant usage on schema public to anon, authenticated;
grant select on public.profiles to anon, authenticated;
grant select on public.reports to anon, authenticated;
grant insert (game_id, subject, rank, score, players) on public.reports to authenticated;
grant select on public.results to anon, authenticated;

-- [운영용] 친구가 비밀번호를 잊었을 때: 아이디와 새 비밀번호를 바꿔 넣고 이 한 줄만 실행
-- update auth.users set encrypted_password = extensions.crypt('새비밀번호', extensions.gen_salt('bf')) where email = '아이디@yacht-dice.local';
