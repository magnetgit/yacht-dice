-- 요트 다이스 라운지: 닉네임 중복 막기 (Supabase SQL Editor에서 한 번 실행)
-- 아이디(username)는 원래 유일하다. 여기서는 닉네임도 회원끼리 겹치지 않게 하고(대소문자 무시),
-- 남의 아이디와 같은 닉네임도 못 쓰게 한다. 로그인 안 한 사람은 페이지가 nick_taken()으로 미리 확인한다.

create unique index if not exists profiles_nick_unique on public.profiles (lower(nick)) where nick is not null;

-- 이 이름을 다른 회원이 닉네임이나 아이디로 쓰고 있는지 (나 자신은 빼고)
create or replace function public.nick_taken(n text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
    where (lower(p.nick) = lower(trim(n)) or lower(p.username) = lower(trim(n)))
      and p.id is distinct from auth.uid())
$$;
grant execute on function public.nick_taken(text) to anon, authenticated;

-- 닉네임 바꾸기: 다른 회원의 닉네임·아이디와 같으면 거절
create or replace function public.profiles_nick_check() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.nick is not null and exists (
       select 1 from public.profiles p
       where p.id <> new.id and (lower(p.nick) = lower(new.nick) or lower(p.username) = lower(new.nick))) then
    raise exception 'nick taken';
  end if;
  return new;
end $$;
drop trigger if exists profiles_nick_check on public.profiles;
create trigger profiles_nick_check before update of nick on public.profiles for each row execute function public.profiles_nick_check();

-- 가입할 때 닉네임이 이미 쓰이고 있으면 닉네임은 비워 두고 가입은 진행 (페이지가 미리 막는다)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare nk text := left(new.raw_user_meta_data->>'nick', 12);
begin
  if new.is_anonymous then return new; end if;
  if nk is not null and exists (select 1 from public.profiles p where lower(p.nick) = lower(nk) or lower(p.username) = lower(nk)) then
    nk := null;
  end if;
  insert into public.profiles (id, username, nick)
  values (new.id, lower(new.raw_user_meta_data->>'username'), nk);
  return new;
end $$;
