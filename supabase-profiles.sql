-- 요트 다이스 라운지: 개인 프로필과 기간별 기록 (Supabase SQL Editor에서 한 번 실행)
-- 기록은 지금처럼 인정된 결과(public.results)만 쓴다.

-- 기간의 시작 시각 (한국 시간 기준): day | week(월요일부터) | month | year | 그 밖은 전체
create or replace function public.period_start(period text) returns timestamptz
language sql stable set search_path = '' as $$
  select case period
    when 'day'   then date_trunc('day',   now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'
    when 'week'  then date_trunc('week',  now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'
    when 'month' then date_trunc('month', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'
    when 'year'  then date_trunc('year',  now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'
    else '-infinity'::timestamptz end
$$;

-- 1) 순위(1등 횟수 기준)에 '오늘'도 쓸 수 있게
create or replace function public.leaderboard(period text)
returns table (user_id uuid, name text, wins int, games int, avg_rank numeric, total_wins int)
language sql stable set search_path = '' as $$
  with r as (select x.* from public.results x where x.played_at >= public.period_start(period))
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

-- 2) 로비 기록판: 기간 안에서 사람마다 최고 점수 (먼저 낸 사람이 앞)
create or replace function public.period_records(period text)
returns table (user_id uuid, name text, best int, best_at timestamptz, games int, wins int, total_wins int)
language sql stable set search_path = '' as $$
  with r as (select x.* from public.results x where x.played_at >= public.period_start(period))
  select p.id, coalesce(p.nick, p.username),
         max(r.score)::int,
         (array_agg(r.played_at order by r.score desc, r.played_at asc))[1],
         count(*)::int,
         (count(*) filter (where r.rank = 1))::int,
         (select count(*) from public.results a where a.user_id = p.id and a.rank = 1)::int
  from r join public.profiles p on p.id = r.user_id
  group by p.id
  order by 3 desc, 4 asc
  limit 10
$$;

-- 3) 개인 프로필: 통산 전적과 최고 기록 5개
create or replace function public.profile_of(uid uuid) returns json
language sql stable set search_path = '' as $$
  with r as (select * from public.results where user_id = uid)
  select json_build_object(
    'id', p.id, 'username', p.username, 'name', coalesce(p.nick, p.username), 'joined', p.created_at,
    'games', (select count(*) from r),
    'wins', (select count(*) from r where rank = 1),
    'avg_rank', (select round(avg(rank), 2) from r),
    'avg_score', (select round(avg(score), 1) from r),
    'last_played', (select max(played_at) from r),
    'top', (select coalesce(json_agg(t order by t.score desc, t.played_at asc), '[]'::json) from
             (select score, rank, players, played_at from r order by score desc, played_at asc limit 5) t))
  from public.profiles p where p.id = uid
$$;

grant execute on function public.period_start(text) to anon, authenticated;
grant execute on function public.leaderboard(text) to anon, authenticated;
grant execute on function public.period_records(text) to anon, authenticated;
grant execute on function public.profile_of(uuid) to anon, authenticated;
