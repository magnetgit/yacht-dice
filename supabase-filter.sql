-- 요트 다이스 라운지: 욕설·스팸 거르기 (Supabase SQL Editor에서 한 번 실행)
-- 금지어는 표 하나(filter_words)로 관리한다. 채팅은 페이지가 이 목록을 받아 가리고,
-- 게시글은 DB가 직접 검사해서 거절한다(페이지를 고쳐도 우회할 수 없음).

-- 1) 금지어: word는 "한글·자모·영문 소문자만 남긴" 형태로 적는다 (띄어쓰기·숫자·기호로 우회해도 잡힘)
create table if not exists public.filter_words (
  word text primary key check (word ~ '^[가-힣ㄱ-ㅎㅏ-ㅣa-z]{1,20}$'),
  kind text not null check (kind in ('abuse', 'spam'))
);
alter table public.filter_words enable row level security;
drop policy if exists "filter words are public" on public.filter_words;
create policy "filter words are public" on public.filter_words for select using (true);
revoke all on public.filter_words from anon, authenticated;
grant select on public.filter_words to anon, authenticated;

insert into public.filter_words (word, kind) select w, 'abuse' from unnest(array[
  '시발','씨발','씨빨','시빨','씨바','쓰발','쓰바','씌발','씨팔','시팔','쉬발','슈발','십새','씹','ㅅㅂ','ㅆㅂ','ㅅㅍ','ㅆㅍ',
  '병신','븅신','빙신','병쉰','ㅂㅅ','ㅄ','좆','존나','졸라','존니','ㅈㄴ','ㅈㄹ','지랄','염병','옘병',
  '개새끼','개새기','개색기','개색끼','개세끼','개쉐이','새끼','색끼','쌔끼','니미','니애미','니엄마','느금','느개비','애미','애비','엠창',
  '미친놈','미친년','미친새','미친개','또라이','닥쳐','썅','쌍놈','쌍년','창녀','등신','머저리','찐따',
  '한남충','김치녀','틀딱','급식충','맘충',
  'fuck','fuk','fck','shit','bitch','asshole','motherfucker','cunt','nigger','nigga','retard']) w
on conflict (word) do nothing;
insert into public.filter_words (word, kind) select w, 'spam' from unnest(array[
  '토토','사설토토','카지노','바카라','슬롯머신','슬롯사이트','먹튀','홀덤','파워볼','대출','작업대출','급전',
  '비아그라','시알리스','출장안마','출장마사지','조건만남','유흥','텔레그램','오픈채팅','오픈톡','카톡문의',
  '리딩방','코인리딩','수익보장','고수익','부업','재택알바','광고문의','홍보문의','casino','viagra','telegram','betting']) w
on conflict (word) do nothing;

-- 2) 요청한 사람을 알아보는 열쇠: 접속 IP를 비밀 소금과 함께 해시한 값 (IP 원래 값은 저장하지 않음)
create table if not exists public.app_secret (k text primary key, v text not null);
alter table public.app_secret enable row level security;
revoke all on public.app_secret from anon, authenticated;
insert into public.app_secret (k, v) values ('ip_salt', encode(extensions.gen_random_bytes(24), 'hex')) on conflict (k) do nothing;
create or replace function public.client_ip() returns text
language sql stable set search_path = '' as $$
  select nullif(trim(coalesce(
    current_setting('request.headers', true)::json ->> 'cf-connecting-ip',
    split_part(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ',', 1),
    current_setting('request.headers', true)::json ->> 'x-real-ip')), '')
$$;
create or replace function public.client_key() returns text
language sql stable security definer set search_path = '' as $$
  select encode(extensions.digest(coalesce(public.client_ip(), 'none') || (select v from public.app_secret where k = 'ip_salt'), 'sha256'), 'hex')
$$;
revoke all on function public.client_ip() from public, anon, authenticated;
revoke all on function public.client_key() from public, anon, authenticated;

-- 3) 글쓰기 기록 (도배·같은 글 반복 막기용, 아무도 못 읽음)
create table if not exists public.post_log (
  key text not null,
  body_hash text not null,
  at timestamptz not null default now()
);
create index if not exists post_log_key_at on public.post_log (key, at desc);
alter table public.post_log enable row level security;
revoke all on public.post_log from anon, authenticated;

-- 4) 글 검사: 피드백 글만(관리자 제외). 걸리면 이유 코드를 담아 거절한다.
create or replace function public.posts_spam_check() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  raw text := coalesce(new.title, '') || ' ' || coalesce(new.body, '');
  norm text := regexp_replace(lower(raw), '[^가-힣ㄱ-ㅎㅏ-ㅣa-z]', '', 'g');
  bnorm text := regexp_replace(lower(coalesce(new.body, '')), '[^가-힣ㄱ-ㅎㅏ-ㅣa-z0-9]', '', 'g');
  digits text := regexp_replace(raw, '[^0-9]', '', 'g');
  k text := public.client_key();
  hit text;
begin
  if new.board <> 'feedback' or public.is_admin() then return new; end if;
  if raw ~* '(https?://|www\.|[a-z0-9-]+\.(com|net|org|kr|io|me|xyz|top|co|ly|gg|site|shop|club|biz|info|link|app)([^a-z]|$)|open\.kakao|t\.me/|discord\.gg)' then
    raise exception 'spam:link';
  end if;
  if regexp_replace(raw, '[\s.\-()]', '', 'g') ~ '01[016789][0-9]{7,8}' or digits ~ '[0-9]{9,}' then
    raise exception 'spam:phone';
  end if;
  select kind into hit from public.filter_words where position(word in norm) > 0 order by kind limit 1;
  if hit = 'abuse' then raise exception 'spam:abuse'; elsif hit = 'spam' then raise exception 'spam:word'; end if;
  if exists (select 1 from public.post_log where key = k and at > now() - interval '30 seconds') then raise exception 'spam:fast'; end if;
  if (select count(*) from public.post_log where key = k and at > now() - interval '1 day') >= 10 then raise exception 'spam:daily'; end if;
  if exists (select 1 from public.post_log where body_hash = md5(bnorm) and at > now() - interval '1 day') then raise exception 'spam:dup'; end if;
  insert into public.post_log (key, body_hash) values (k, md5(bnorm));
  delete from public.post_log where at < now() - interval '3 days';
  return new;
end $$;
drop trigger if exists posts_spam_check on public.posts;
create trigger posts_spam_check before insert on public.posts for each row execute function public.posts_spam_check();
