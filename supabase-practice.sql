-- 요트 다이스 라운지: 봇전·혼자 한 판 기록과 마이페이지 (Supabase SQL Editor에서 한 번 실행)
-- 이 기록은 본인만 볼 수 있다. 증인이 없어 기록판·순위·메달에는 쓰지 않는다.

create table if not exists public.practice (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  game_key text not null check (char_length(game_key) between 4 and 60),
  kind text not null check (kind in ('bot', 'solo')),
  level text check (level in ('easy', 'normal', 'hard')),
  score smallint not null check (score between 0 and 330),
  bot_score smallint check (bot_score between 0 and 330),
  result text check (result in ('win', 'lose', 'draw')),
  created_at timestamptz not null default now(),
  unique (user_id, game_key),
  check ((kind = 'bot') = (level is not null and bot_score is not null and result is not null))
);
alter table public.practice enable row level security;
drop policy if exists "own practice read" on public.practice;
create policy "own practice read" on public.practice for select to authenticated using (user_id = auth.uid());
drop policy if exists "own practice write" on public.practice;
create policy "own practice write" on public.practice for insert to authenticated with check (user_id = auth.uid());
revoke all on public.practice from anon, authenticated;
grant select on public.practice to authenticated;
grant insert (game_key, kind, level, score, bot_score, result) on public.practice to authenticated;

-- 한 판은 아무리 빨라도 1분은 걸린다: 같은 사람이 40초 안에 또 저장하면 거절
create or replace function public.practice_pace() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.practice where user_id = new.user_id and created_at > now() - interval '40 seconds') then
    raise exception 'too fast';
  end if;
  return new;
end $$;
drop trigger if exists practice_pace on public.practice;
create trigger practice_pace before insert on public.practice for each row execute function public.practice_pace();

-- 마이페이지: 로그인한 본인 것만
create or replace function public.my_practice() returns json
language sql stable set search_path = '' as $$
  with b as (select * from public.practice where user_id = auth.uid() and kind = 'bot'),
       s as (select * from public.practice where user_id = auth.uid() and kind = 'solo')
  select json_build_object(
    'bot', (select coalesce(json_agg(x order by x.ord), '[]'::json) from (
              select l.level, l.ord,
                     count(b.id)::int as games,
                     (count(*) filter (where b.result = 'win'))::int as win,
                     (count(*) filter (where b.result = 'lose'))::int as lose,
                     (count(*) filter (where b.result = 'draw'))::int as draw
              from (values ('easy', 1), ('normal', 2), ('hard', 3)) l(level, ord)
              left join b on b.level = l.level group by l.level, l.ord) x),
    'bot_best', (select row_to_json(t) from (select score, bot_score, level, result, created_at from b order by score desc, created_at asc limit 1) t),
    'solo_games', (select count(*) from s),
    'solo_best', (select row_to_json(t) from (select score, created_at from s order by score desc, created_at asc limit 1) t))
$$;
grant execute on function public.my_practice() to authenticated;
