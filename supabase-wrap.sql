-- 요트 다이스 라운지: 판 요약과 연말 결산 (Supabase SQL Editor에서 한 번 실행)

-- 1) 판 요약: 판이 끝나면 각자 자기 것만 남긴다 (요트 횟수 등, 결산 집계용. 본인만 읽기)
create table if not exists public.game_stats (
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  game_key text not null check (char_length(game_key) between 4 and 60),
  mode text not null check (mode in ('online', 'bot', 'solo')),
  score smallint not null check (score between 0 and 330),
  yachts smallint not null default 0 check (yachts between 0 and 12),
  bonus boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (user_id, game_key)
);
alter table public.game_stats enable row level security;
drop policy if exists "own stats read" on public.game_stats;
create policy "own stats read" on public.game_stats for select to authenticated using (user_id = auth.uid());
drop policy if exists "own stats write" on public.game_stats;
create policy "own stats write" on public.game_stats for insert to authenticated with check (user_id = auth.uid());
revoke all on public.game_stats from anon, authenticated;
grant select on public.game_stats to authenticated;
grant insert (game_key, mode, score, yachts, bonus) on public.game_stats to authenticated;
drop trigger if exists block_banned on public.game_stats;
create trigger block_banned before insert on public.game_stats for each row execute function public.block_banned();

-- 2) 연말 결산: 한 해(한국 시간) 기록을 모아 한 번에 돌려준다. 로그인했으면 "나의 결산"도 함께
create or replace function public.wrap(yr int) returns json
language plpgsql stable security definer set search_path = '' as $$
declare
  t0 timestamptz := make_timestamptz(yr, 1, 1, 0, 0, 0, 'Asia/Seoul');
  t1 timestamptz := make_timestamptz(yr + 1, 1, 1, 0, 0, 0, 'Asia/Seoul');
  u uuid := auth.uid();
  res json;
begin
  if yr < 2026 or yr > 2100 then return null; end if;
  with r as (select x.*, coalesce(p.nick, p.username) as nm from public.results x join public.profiles p on p.id = x.user_id
             where x.played_at >= t0 and x.played_at < t1),
       per as (select user_id, max(nm) as nm, count(*)::int as g, (count(*) filter (where rank = 1))::int as w,
                      max(score)::int as best, round(avg(score), 1) as avg from r group by user_id),
       gs as (select * from public.game_stats where created_at >= t0 and created_at < t1),
       ys as (select g.user_id, coalesce(p.nick, p.username) as nm, sum(g.yachts)::int as y
              from gs g join public.profiles p on p.id = g.user_id group by 1, 2),
       pairs as (select a.user_id as ua, b.user_id as ub, count(*)::int as n
                 from r a join r b on a.game_id = b.game_id and a.user_id < b.user_id group by 1, 2),
       games as (select game_id, min(played_at) as ts from r group by game_id)
  select json_build_object(
    'year', yr,
    'games', (select count(*) from games),
    'players', (select count(*) from per),
    'yachts', (select coalesce(sum(yachts), 0) from gs),
    'bot_games', (select count(*) from public.practice where kind = 'bot' and created_at >= t0 and created_at < t1),
    'top_wins', (select coalesce(json_agg(t), '[]'::json) from (select user_id, nm, w, g from per where w > 0 order by w desc, g asc limit 3) t),
    'top_games', (select coalesce(json_agg(t), '[]'::json) from (select user_id, nm, g, w from per order by g desc, w desc limit 3) t),
    'high', (select row_to_json(t) from (select user_id, nm, score, players, rank, played_at from r order by score desc, played_at asc limit 1) t),
    'avg_king', (select row_to_json(t) from (select user_id, nm, avg, g from per where g >= 5 order by avg desc limit 1) t),
    'rate_king', (select row_to_json(t) from (select user_id, nm, w, g, round(w * 100.0 / g)::int as rate from per where g >= 5 order by w * 1.0 / g desc, g desc limit 1) t),
    'rival', (select row_to_json(t) from (
        select pr.ua, pr.ub, (select nm from per where user_id = pr.ua) as na, (select nm from per where user_id = pr.ub) as nb, pr.n,
               (select count(*) from r a join r b on a.game_id = b.game_id where a.user_id = pr.ua and b.user_id = pr.ub and a.rank < b.rank)::int as wa,
               (select count(*) from r a join r b on a.game_id = b.game_id where a.user_id = pr.ub and b.user_id = pr.ua and a.rank < b.rank)::int as wb
        from pairs pr order by pr.n desc limit 1) t),
    'yacht_king', (select row_to_json(t) from (select user_id, nm, y from ys where y > 0 order by y desc limit 1) t),
    'month', (select row_to_json(t) from (select extract(month from ts at time zone 'Asia/Seoul')::int as m, count(*)::int as n from games group by 1 order by 2 desc, 1 limit 1) t),
    'dow', (select row_to_json(t) from (select extract(dow from ts at time zone 'Asia/Seoul')::int as d, count(*)::int as n from games group by 1 order by 2 desc, 1 limit 1) t),
    'hour', (select row_to_json(t) from (select extract(hour from ts at time zone 'Asia/Seoul')::int as h, count(*)::int as n from games group by 1 order by 2 desc, 1 limit 1) t),
    'me', case when u is null or not exists (select 1 from public.profiles where id = u) then null else json_build_object(
        'nm', (select coalesce(nick, username) from public.profiles where id = u),
        'g', coalesce((select g from per where user_id = u), 0),
        'w', coalesce((select w from per where user_id = u), 0),
        'best', (select row_to_json(t) from (select score, players, rank, played_at from r where user_id = u order by score desc, played_at asc limit 1) t),
        'rank_w', (select rk from (select user_id, rank() over (order by w desc)::int as rk from per) z where user_id = u),
        'of', (select count(*) from per),
        'yachts', coalesce((select y from ys where user_id = u), 0),
        'bot_w', (select count(*) from public.practice where user_id = u and kind = 'bot' and result = 'win' and created_at >= t0 and created_at < t1),
        'bot_g', (select count(*) from public.practice where user_id = u and kind = 'bot' and created_at >= t0 and created_at < t1),
        'ach', (select count(*) from public.user_achievements where user_id = u and at >= t0 and at < t1)) end
  ) into res;
  return res;
end $$;
grant execute on function public.wrap(int) to anon, authenticated;
