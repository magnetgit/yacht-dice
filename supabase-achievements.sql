-- 요트 다이스 라운지: 업적 (Supabase SQL Editor에서 한 번 실행)
-- kind = auto: DB가 기록(results, practice)을 보고 직접 판단한다 (metric >= threshold)
-- kind = feat: 판 안에서 일어난 일(첫 굴림 요트 등)로, 페이지가 알려 준다. 한 번만 받을 수 있고 포인트는 작게.
-- hidden = 달성하기 전에는 이름과 조건이 "???"로 보인다.

create table if not exists public.achievements (
  id text primary key check (id ~ '^[a-z0-9_]{2,30}$'),
  kind text not null check (kind in ('auto', 'feat')),
  metric text,
  threshold int,
  name text not null,
  descr text not null,
  hidden boolean not null default false,
  points int not null check (points between 0 and 1000),
  sort int not null default 0
);
alter table public.achievements enable row level security;
drop policy if exists "achievements are public" on public.achievements;
create policy "achievements are public" on public.achievements for select using (true);
revoke all on public.achievements from anon, authenticated;
grant select on public.achievements to anon, authenticated;

create table if not exists public.user_achievements (
  user_id uuid not null references public.profiles (id) on delete cascade,
  ach_id text not null references public.achievements (id) on delete cascade,
  at timestamptz not null default now(),
  primary key (user_id, ach_id)
);
alter table public.user_achievements enable row level security;
drop policy if exists "unlocked are public" on public.user_achievements;
create policy "unlocked are public" on public.user_achievements for select using (true);
revoke all on public.user_achievements from anon, authenticated;
grant select on public.user_achievements to anon, authenticated;

insert into public.achievements (id, kind, metric, threshold, name, descr, hidden, points, sort) values
  -- 기록으로 판단 (온라인 승리는 두 사람이 확인한 판만)
  ('first_win',  'auto', 'wins',   1,  '첫 승리',           '온라인 대전에서 처음으로 1등 하기',            false, 10, 10),
  ('wins_10',    'auto', 'wins',   10, '단골 우승자',       '온라인 대전에서 1등 10번',                    false, 30, 11),
  ('wins_30',    'auto', 'wins',   30, '라운지의 강자',     '온라인 대전에서 1등 30번',                    false, 60, 12),
  ('wins_100',   'auto', 'wins',   100,'요트의 전설',       '온라인 대전에서 1등 100번',                   false, 150, 13),
  ('games_10',   'auto', 'games',  10, '라운지 단골',       '온라인 대전 10판 하기',                       false, 10, 20),
  ('games_50',   'auto', 'games',  50, '라운지 터줏대감',   '온라인 대전 50판 하기',                       false, 30, 21),
  ('big_win',    'auto', 'bigw',   1,  '여럿을 꺾다',       '3명 이상 온라인 판에서 1등',                   false, 15, 22),
  ('score_200',  'auto', 'best',   200,'200점 돌파',        '한 판에서 200점 넘기',                        false, 10, 30),
  ('score_250',  'auto', 'best',   250,'250점 돌파',        '한 판에서 250점 넘기',                        false, 25, 31),
  ('score_300',  'auto', 'best',   300,'300점의 벽',        '한 판에서 300점 넘기',                        false, 60, 32),
  ('bot_hard',   'auto', 'hardw',  1,  '요트봇 정복',       '어려움 요트봇 이기기',                         false, 15, 40),
  ('bot_10',     'auto', 'botw',   10, '봇 사냥꾼',         '요트봇에게 10번 이기기',                       false, 15, 41),
  ('full_house_win','auto','w8',   1,  '만석의 왕',         '8명이 꽉 찬 판에서 1등',                       true,  50, 50),
  ('last_place', 'auto', 'last4',  1,  '꼴찌의 미학',       '4명 이상 판에서 꼴찌 하기',                    true,  5,  51),
  -- 판 안에서 일어난 일 (페이지가 알려 줌)
  ('yacht',      'feat', null, null,   '요트!',             '주사위 다섯 개를 모두 같은 눈으로 맞추기',     false, 5,  60),
  ('bonus',      'feat', null, null,   '보너스 사냥',       '상단 합계 63점을 넘겨 보너스 받기',            false, 5,  61),
  ('l_straight', 'feat', null, null,   '쭉 뻗은 길',        'L. Straight 칸 30점 채우기',                   false, 5,  62),
  ('yacht_first','feat', null, null,   '한 방에 요트',      '첫 번째 굴림에서 바로 요트',                   true,  30, 70),
  ('yacht_twice','feat', null, null,   '요트 두 번',        '한 판에서 요트를 두 번 굴리기',                true,  30, 71),
  ('six_yacht',  'feat', null, null,   '육육육육육',        '6으로 요트 만들기',                            true,  15, 72),
  ('one_yacht',  'feat', null, null,   '작고 소중한 요트',  '1로 요트 만들기',                              true,  15, 73),
  ('no_zero',    'feat', null, null,   '빈칸 없는 완벽함',  '0점 칸 없이 12칸 모두 채우기',                 true,  20, 74),
  ('low_score',  'feat', null, null,   '오늘은 쉬는 날',    '한 판을 100점 미만으로 끝내기',                true,  5,  75)
on conflict (id) do update set kind = excluded.kind, metric = excluded.metric, threshold = excluded.threshold,
  name = excluded.name, descr = excluded.descr, hidden = excluded.hidden, points = excluded.points, sort = excluded.sort;

-- 업적 받기: auto는 기록으로 확인하고, feat는 페이지가 보낸 목록 중 feat 종류만. 새로 받은 것만 돌려준다
create or replace function public.claim_achievements(feats text[]) returns json
language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); res json;
begin
  if u is null or not exists (select 1 from public.profiles where id = u) then return '[]'::json; end if;
  if public.is_banned_now() then return '[]'::json; end if;
  with r as (select * from public.results where user_id = u),
       p as (select * from public.practice where user_id = u),
       st as (select
         (select count(*) from r where rank = 1) as wins,
         (select count(*) from r) as games,
         greatest(coalesce((select max(score) from r), 0), coalesce((select max(score) from p), 0)) as best,
         (select count(*) from p where kind = 'bot' and result = 'win') as botw,
         (select count(*) from p where kind = 'bot' and result = 'win' and level = 'hard') as hardw,
         (select count(*) from r where rank = 1 and players >= 3) as bigw,
         (select count(*) from r where rank = 1 and players = 8) as w8,
         (select count(*) from r where rank = players and players >= 4) as last4),
       ok as (
         select a.id from public.achievements a, st
         where (a.kind = 'feat' and a.id = any(coalesce(feats, '{}')))
            or (a.kind = 'auto' and (case a.metric when 'wins' then st.wins when 'games' then st.games when 'best' then st.best
                  when 'botw' then st.botw when 'hardw' then st.hardw when 'bigw' then st.bigw when 'w8' then st.w8
                  when 'last4' then st.last4 else 0 end) >= a.threshold)),
       ins as (insert into public.user_achievements (user_id, ach_id) select u, id from ok on conflict do nothing returning ach_id)
  select coalesce(json_agg(json_build_object('id', a.id, 'name', a.name, 'points', a.points, 'hidden', a.hidden) order by a.sort), '[]'::json)
    into res from ins join public.achievements a on a.id = ins.ach_id;
  return res;
end $$;
revoke execute on function public.claim_achievements(text[]) from public, anon;
grant execute on function public.claim_achievements(text[]) to authenticated;

-- 포인트에 업적 보상 더하기
create or replace function public._points(uid uuid) returns json
language sql stable security definer set search_path = '' as $$
  with w as (select count(*)::int n from public.results where user_id = uid and rank = 1),
       b as (select coalesce(sum(least(10, p)), 0)::int n from (
               select date_trunc('day', created_at at time zone 'Asia/Seoul') d,
                      sum(case level when 'easy' then 1 when 'normal' then 2 else 3 end) p
               from public.practice where user_id = uid and kind = 'bot' and result = 'win' group by 1) x),
       a as (select coalesce(sum(ac.points), 0)::int n from public.user_achievements ua join public.achievements ac on ac.id = ua.ach_id where ua.user_id = uid),
       s as (select coalesce(sum(i.price), 0)::int n from public.owned o join public.items i on i.id = o.item_id where o.user_id = uid)
  select json_build_object('wins', w.n, 'win_pts', w.n * 10, 'bot_pts', b.n, 'ach_pts', a.n, 'spent', s.n, 'balance', w.n * 10 + b.n + a.n - s.n)
  from w, b, a, s
$$;
revoke all on function public._points(uuid) from public, anon, authenticated;
