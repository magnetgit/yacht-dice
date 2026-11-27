-- 요트 다이스 라운지: 신고와 이용 제한 (Supabase SQL Editor에서 한 번 실행)
-- 신고는 누구나(로그인 안 해도 익명 세션으로) 할 수 있고, 내용은 관리자만 본다.
-- 제한은 관리자가 아이디·기기(cid)·IP(해시) 단위로 걸고, 기간(또는 영구)을 정한다.
-- IP는 원래 값 대신 소금을 친 해시(client_key)만 저장한다.

-- 1) 기기 접속 기록: 어떤 기기(cid)가 어떤 IP 해시·계정으로 들어왔는지 (관리자만)
create table if not exists public.device_seen (
  cid text not null check (char_length(cid) between 4 and 64),
  key text not null,
  uid uuid references auth.users on delete set null,
  name text,
  last_at timestamptz not null default now(),
  primary key (cid, key)
);
alter table public.device_seen enable row level security;
revoke all on public.device_seen from anon, authenticated;

-- 2) 신고
create table if not exists public.user_reports (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  reporter uuid references auth.users on delete set null,
  reporter_cid text,
  reporter_key text,
  target_uid uuid references auth.users on delete set null,
  target_cid text,
  target_name text,
  target_post bigint references public.posts (id) on delete set null,
  reason text not null check (reason in ('abuse', 'spam', 'cheat', 'nickname', 'other')),
  detail text check (char_length(detail) <= 300),
  context text check (char_length(context) <= 1500),
  status text not null default 'open' check (status in ('open', 'done')),
  handled_at timestamptz
);
alter table public.user_reports enable row level security;
revoke all on public.user_reports from anon, authenticated;

-- 3) 이용 제한
create table if not exists public.bans (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users on delete set null,
  target_uid uuid references auth.users on delete set null,
  target_cid text,
  ip_keys text[] not null default '{}',
  target_name text,
  reason text not null check (char_length(reason) between 1 and 200),
  until timestamptz,             -- null이면 영구
  lifted_at timestamptz
);
alter table public.bans enable row level security;
revoke all on public.bans from anon, authenticated;

-- 지금 이 요청(로그인 계정, 기기, IP)이 제한 중인지
create or replace function public.active_ban(p_cid text) returns public.bans
language sql stable security definer set search_path = '' as $$
  select b.* from public.bans b
  where b.lifted_at is null and (b.until is null or b.until > now())
    and ((auth.uid() is not null and b.target_uid = auth.uid())
         or (p_cid is not null and b.target_cid = p_cid)
         or public.client_key() = any(b.ip_keys))
  order by b.until desc nulls first limit 1
$$;
revoke all on function public.active_ban(text) from public, anon, authenticated;
create or replace function public.is_banned_now() returns boolean
language sql stable security definer set search_path = '' as $$
  select (public.active_ban(null)).id is not null
$$;
revoke all on function public.is_banned_now() from public, anon, authenticated;

-- 페이지가 열릴 때: 접속 기록을 남기고, 제한 중이면 사유와 기간을 돌려준다
create or replace function public.checkin(p_cid text, p_name text) returns json
language plpgsql security definer set search_path = '' as $$
declare b public.bans;
begin
  if p_cid is null or char_length(p_cid) not between 4 and 64 then return null; end if;
  insert into public.device_seen (cid, key, uid, name, last_at)
    values (p_cid, public.client_key(), auth.uid(), left(p_name, 12), now())
    on conflict (cid, key) do update set uid = coalesce(excluded.uid, public.device_seen.uid),
      name = coalesce(excluded.name, public.device_seen.name), last_at = now();
  b := public.active_ban(p_cid);
  if b.id is null then return null; end if;
  return json_build_object('reason', b.reason, 'until', b.until);
end $$;
grant execute on function public.checkin(text, text) to anon, authenticated;

-- 방장이 들어온 사람을 확인할 때: 제한 중인 기기·계정 목록만 돌려준다
create or replace function public.banned_among(cids text[], uids uuid[]) returns text[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct x), '{}') from (
    select b.target_cid x from public.bans b
      where b.lifted_at is null and (b.until is null or b.until > now()) and b.target_cid = any(cids)
    union
    select d.cid from public.device_seen d join public.bans b on d.key = any(b.ip_keys)
      where b.lifted_at is null and (b.until is null or b.until > now()) and d.cid = any(cids)
    union
    select 'uid:' || b.target_uid::text from public.bans b
      where b.lifted_at is null and (b.until is null or b.until > now()) and b.target_uid = any(uids)
  ) s
$$;
grant execute on function public.banned_among(text[], uuid[]) to anon, authenticated;

-- 신고하기 (로그인 또는 익명 세션). 10분에 5번까지
create or replace function public.report_user(p_cid text, t_uid uuid, t_cid text, t_name text, t_post bigint,
                                              p_reason text, p_detail text, p_context text) returns void
language plpgsql security definer set search_path = '' as $$
declare k text := public.client_key();
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  if public.is_banned_now() then raise exception 'banned'; end if;
  if (select count(*) from public.user_reports where reporter_key = k and created_at > now() - interval '10 minutes') >= 5 then
    raise exception 'too many reports';
  end if;
  if t_uid is null and t_cid is null and t_post is null then raise exception 'no target'; end if;
  insert into public.user_reports (reporter, reporter_cid, reporter_key, target_uid, target_cid, target_name, target_post, reason, detail, context)
  values (auth.uid(), left(p_cid, 64), k, t_uid, left(t_cid, 64), left(t_name, 40), t_post, p_reason, left(p_detail, 300), left(p_context, 1500));
end $$;
grant execute on function public.report_user(text, uuid, text, text, bigint, text, text, text) to authenticated;

-- 4) 관리자용 (is_admin()이 아니면 거절)
create or replace function public.admin_reports() returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return (select coalesce(json_agg(r order by r.created_at desc), '[]'::json) from (
    select u.id, u.created_at, u.status, u.reason, u.detail, u.context, u.target_post, u.target_name, u.target_cid, u.target_uid,
           (select coalesce(p.nick, p.username) || ' (@' || p.username || ')' from public.profiles p where p.id = u.reporter) as reporter_name,
           u.reporter_cid,
           (select p.username from public.profiles p where p.id = u.target_uid) as target_username,
           (select count(*) from public.user_reports o where (o.target_uid = u.target_uid or o.target_cid = u.target_cid)) as times_reported,
           exists (select 1 from public.device_seen a join public.device_seen b2 on a.key = b2.key
                   where a.cid = u.reporter_cid and b2.cid = u.target_cid) as same_ip
    from public.user_reports u order by u.created_at desc limit 200) r);
end $$;
create or replace function public.admin_bans() returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return (select coalesce(json_agg(r order by r.created_at desc), '[]'::json) from (
    select b.id, b.created_at, b.target_name, b.target_cid, b.reason, b.until, b.lifted_at,
           (select p.username from public.profiles p where p.id = b.target_uid) as target_username,
           cardinality(b.ip_keys) as ip_count,
           (b.lifted_at is null and (b.until is null or b.until > now())) as active
    from public.bans b order by b.created_at desc limit 200) r);
end $$;
-- 제한 걸기: 계정(t_uid)과 기기(t_cid) 중 아는 것으로. with_ip면 그 계정·기기가 쓴 IP 해시도 함께 막는다.
-- days가 null이면 영구
create or replace function public.admin_ban(t_uid uuid, t_cid text, t_name text, p_reason text, days int, with_ip boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare keys text[] := '{}';
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if t_uid is null and t_cid is null then raise exception 'no target'; end if;
  if t_uid is not null and exists (select 1 from public.admins where user_id = t_uid) then raise exception 'cannot ban admin'; end if;
  if with_ip then
    select coalesce(array_agg(distinct key), '{}') into keys from public.device_seen
      where (t_cid is not null and cid = t_cid) or (t_uid is not null and uid = t_uid);
    -- 관리자 본인 IP는 빼기
    keys := array(select x from unnest(keys) x where x <> public.client_key());
  end if;
  insert into public.bans (created_by, target_uid, target_cid, ip_keys, target_name, reason, until)
  values (auth.uid(), t_uid, t_cid, keys, left(t_name, 40), left(p_reason, 200),
          case when days is null then null else now() + make_interval(days => days) end);
end $$;
create or replace function public.admin_unban(ban_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.bans set lifted_at = now() where id = ban_id;
end $$;
create or replace function public.admin_report_done(rep_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.user_reports set status = 'done', handled_at = now() where id = rep_id;
end $$;
revoke execute on function public.admin_reports() from public, anon;
revoke execute on function public.admin_bans() from public, anon;
revoke execute on function public.admin_ban(uuid, text, text, text, int, boolean) from public, anon;
revoke execute on function public.admin_unban(bigint) from public, anon;
revoke execute on function public.admin_report_done(bigint) from public, anon;
grant execute on function public.admin_reports() to authenticated;
grant execute on function public.admin_bans() to authenticated;
grant execute on function public.admin_ban(uuid, text, text, text, int, boolean) to authenticated;
grant execute on function public.admin_unban(bigint) to authenticated;
grant execute on function public.admin_report_done(bigint) to authenticated;

-- 5) 제한 중이면 글쓰기, 대전 기록, 봇전 기록, 구매도 막는다
create or replace function public.block_banned() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if public.is_banned_now() and not public.is_admin() then raise exception 'banned'; end if;
  return new;
end $$;
drop trigger if exists block_banned on public.posts;
create trigger block_banned before insert on public.posts for each row execute function public.block_banned();
drop trigger if exists block_banned on public.reports;
create trigger block_banned before insert on public.reports for each row execute function public.block_banned();
drop trigger if exists block_banned on public.practice;
create trigger block_banned before insert on public.practice for each row execute function public.block_banned();
drop trigger if exists block_banned on public.owned;
create trigger block_banned before insert on public.owned for each row execute function public.block_banned();
