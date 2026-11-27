-- 요트 다이스 라운지: 포인트와 꾸미기 상점 (Supabase SQL Editor에서 한 번 실행)
-- 포인트 = 인정된 온라인 1등 × 10 + 봇전 승리(쉬움 1·보통 2·어려움 3, 하루 최대 10) - 산 아이템 가격
-- 포인트는 저장하지 않고 기록에서 매번 계산한다. 구매와 장착은 아래 함수로만 할 수 있다.

-- 1) 아이템 목록 (누구나 읽기, 고치기는 운영자만)
create table if not exists public.items (
  id text primary key check (id ~ '^[a-z0-9_]{2,30}$'),
  kind text not null check (kind in ('nick', 'title', 'dice', 'felt')),
  name text not null,
  price int not null check (price between 0 and 100000),
  data jsonb not null default '{}',
  sort int not null default 0
);
alter table public.items enable row level security;
drop policy if exists "items are public" on public.items;
create policy "items are public" on public.items for select using (true);
revoke all on public.items from anon, authenticated;
grant select on public.items to anon, authenticated;

-- 2) 산 아이템 (본인만 읽기, 쓰기는 buy_item 함수만)
create table if not exists public.owned (
  user_id uuid not null references public.profiles (id) on delete cascade,
  item_id text not null references public.items (id) on delete cascade,
  bought_at timestamptz not null default now(),
  primary key (user_id, item_id)
);
alter table public.owned enable row level security;
drop policy if exists "own items read" on public.owned;
create policy "own items read" on public.owned for select to authenticated using (user_id = auth.uid());
revoke all on public.owned from anon, authenticated;
grant select on public.owned to authenticated;

-- 3) 장착한 아이템 (프로필에 공개, 바꾸기는 equip_item 함수만)
alter table public.profiles add column if not exists eq_nick text references public.items (id) on delete set null;
alter table public.profiles add column if not exists eq_title text references public.items (id) on delete set null;
alter table public.profiles add column if not exists eq_dice text references public.items (id) on delete set null;
alter table public.profiles add column if not exists eq_felt text references public.items (id) on delete set null;

-- 4) 포인트 계산 (내부용: 직접 부를 수 없음)
create or replace function public._points(uid uuid) returns json
language sql stable security definer set search_path = '' as $$
  with w as (select count(*)::int n from public.results where user_id = uid and rank = 1),
       b as (select coalesce(sum(least(10, p)), 0)::int n from (
               select date_trunc('day', created_at at time zone 'Asia/Seoul') d,
                      sum(case level when 'easy' then 1 when 'normal' then 2 else 3 end) p
               from public.practice where user_id = uid and kind = 'bot' and result = 'win' group by 1) x),
       s as (select coalesce(sum(i.price), 0)::int n from public.owned o join public.items i on i.id = o.item_id where o.user_id = uid)
  select json_build_object('wins', w.n, 'win_pts', w.n * 10, 'bot_pts', b.n, 'spent', s.n, 'balance', w.n * 10 + b.n - s.n)
  from w, b, s
$$;
revoke all on function public._points(uuid) from public, anon, authenticated;

-- 내 포인트
create or replace function public.my_points() returns json
language sql stable security definer set search_path = '' as $$
  select case when auth.uid() is null then null else public._points(auth.uid()) end
$$;

-- 5) 사기: 포인트가 충분하고 아직 없는 아이템만
create or replace function public.buy_item(item text) returns json
language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); pr int; bal int;
begin
  if u is null or not exists (select 1 from public.profiles where id = u) then raise exception 'login required'; end if;
  perform pg_advisory_xact_lock(hashtext(u::text));
  select price into pr from public.items where id = item;
  if pr is null then raise exception 'no such item'; end if;
  if exists (select 1 from public.owned where user_id = u and item_id = item) then raise exception 'already owned'; end if;
  bal := (public._points(u) ->> 'balance')::int;
  if bal < pr then raise exception 'not enough points'; end if;
  insert into public.owned (user_id, item_id) values (u, item);
  return public._points(u);
end $$;

-- 6) 장착: 산 아이템만, 종류에 맞는 칸에. item이 null이면 해제
create or replace function public.equip_item(slot text, item text) returns void
language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'login required'; end if;
  if slot not in ('nick', 'title', 'dice', 'felt') then raise exception 'bad slot'; end if;
  if item is not null and not exists (
       select 1 from public.owned o join public.items i on i.id = o.item_id
       where o.user_id = u and o.item_id = item and i.kind = slot) then
    raise exception 'not owned';
  end if;
  if slot = 'nick' then update public.profiles set eq_nick = item where id = u;
  elsif slot = 'title' then update public.profiles set eq_title = item where id = u;
  elsif slot = 'dice' then update public.profiles set eq_dice = item where id = u;
  else update public.profiles set eq_felt = item where id = u; end if;
end $$;

-- 7) 여러 사람의 통산 승수와 장착 꾸미기 (메달·닉네임·주사위 표시용)
create or replace function public.looks_of(ids uuid[])
returns table (user_id uuid, wins int, nick jsonb, title jsonb, dice jsonb, felt jsonb)
language sql stable set search_path = '' as $$
  select p.id,
         (select count(*) from public.results r where r.user_id = p.id and r.rank = 1)::int,
         n.data, t.data, d.data, f.data
  from public.profiles p
  left join public.items n on n.id = p.eq_nick
  left join public.items t on t.id = p.eq_title
  left join public.items d on d.id = p.eq_dice
  left join public.items f on f.id = p.eq_felt
  where p.id = any(ids)
$$;

grant execute on function public.my_points() to authenticated;
grant execute on function public.buy_item(text) to authenticated;
grant execute on function public.equip_item(text, text) to authenticated;
grant execute on function public.looks_of(uuid[]) to anon, authenticated;
revoke execute on function public.buy_item(text) from public, anon;
revoke execute on function public.equip_item(text, text) from public, anon;

-- 8) 처음 상점 물건 (화려하고 고급스러울수록 비쌈). 1등 한 번 = 10포인트
insert into public.items (id, kind, name, price, data, sort) values
  -- 닉네임
  ('n_ruby',    'nick', '루비 레드',     20, '{"c":"#d0453a"}', 10),
  ('n_ocean',   'nick', '오션 블루',     20, '{"c":"#2f7fd1"}', 11),
  ('n_forest',  'nick', '포레스트',      20, '{"c":"#2e9a5c"}', 12),
  ('n_violet',  'nick', '바이올렛',      30, '{"c":"#8a5cd6"}', 13),
  ('n_gold',    'nick', '골드 메탈',     80, '{"fx":"gold"}', 20),
  ('n_neon',    'nick', '네온 사인',    120, '{"fx":"neon"}', 21),
  ('n_rainbow', 'nick', '무지개',       180, '{"fx":"rainbow"}', 22),
  ('n_aurora',  'nick', '오로라',       300, '{"fx":"aurora"}', 23),
  -- 칭호
  ('t_rookie',  'title', '굴림 새내기',     10, '{"t":"굴림 새내기","tier":"plain"}', 10),
  ('t_lucky',   'title', '행운의 주사위',   30, '{"t":"행운의 주사위","tier":"plain"}', 11),
  ('t_straight','title', '스트레이트 장인', 70, '{"t":"스트레이트 장인","tier":"silver"}', 20),
  ('t_yacht',   'title', '요트 마스터',    140, '{"t":"요트 마스터","tier":"gold"}', 30),
  ('t_legend',  'title', '펠트 위의 전설', 260, '{"t":"펠트 위의 전설","tier":"legend"}', 40),
  ('t_god',     'title', '주사위의 신',    450, '{"t":"주사위의 신","tier":"god"}', 41),
  -- 주사위
  ('d_ink',     'dice', '먹색 주사위',     40, '{"bg":["#2b2d31","#151619"],"pip":"#f4f1ea","red":"#ff6b5a"}', 10),
  ('d_ruby',    'dice', '루비 주사위',     40, '{"bg":["#d8433b","#9e2420"],"pip":"#fff6ee","red":"#ffe08a"}', 11),
  ('d_mint',    'dice', '민트 주사위',     40, '{"bg":["#bff0dc","#7fd3b4"],"pip":"#17423a","red":"#d0453a"}', 12),
  ('d_marble',  'dice', '대리석 주사위',  110, '{"bg":["#ffffff","#e4e2dd"],"pip":"#2a2c30","red":"#b8862b","fx":"marble"}', 20),
  ('d_pearl',   'dice', '진주 주사위',    160, '{"bg":["#fdf7ff","#e7f1ff","#fbeaf2"],"pip":"#5b4d66","red":"#d06a8e","fx":"sheen"}', 21),
  ('d_gold',    'dice', '황금 주사위',    220, '{"bg":["#fff0b3","#e3b440","#a8761a"],"pip":"#3d2a05","red":"#8a1c12","fx":"sheen"}', 30),
  ('d_galaxy',  'dice', '은하 주사위',    320, '{"bg":["#2a1856","#14082e","#3a1d6e"],"pip":"#f6f0ff","red":"#ff7ad9","fx":"stars"}', 40),
  -- 펠트
  ('f_navy',    'felt', '네이비 펠트',     30, '{"a":"#1f3c7a","b":"#0f2148"}', 10),
  ('f_wine',    'felt', '와인 펠트',       30, '{"a":"#7a1f33","b":"#45101c"}', 11),
  ('f_violet',  'felt', '보랏빛 펠트',     30, '{"a":"#4d2a80","b":"#2a144a"}', 12),
  ('f_black',   'felt', '블랙 & 골드',    110, '{"a":"#2a2a2a","b":"#0e0e0e","fx":"gold"}', 20),
  ('f_royal',   'felt', '로열 벨벳',      200, '{"a":"#8c1022","b":"#4a0610","fx":"velvet"}', 30),
  ('f_galaxy',  'felt', '은하수',         300, '{"a":"#1b1446","b":"#05030f","fx":"stars"}', 40)
on conflict (id) do update set kind = excluded.kind, name = excluded.name, price = excluded.price, data = excluded.data, sort = excluded.sort;
