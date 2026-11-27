-- 요트 다이스 라운지: 피드백 사진 첨부 (Supabase SQL Editor에서 한 번 실행)

-- 1) 사진 저장소: 누구나 볼 수 있는 공개 버킷, 한 장 3MB까지, 이미지 형식만, u/ 폴더에만 올릴 수 있음
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('feedback', 'feedback', true, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = 3145728, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];
drop policy if exists "feedback photo upload" on storage.objects;
create policy "feedback photo upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'feedback' and (storage.foldername(name))[1] = 'u');

-- 2) 게시글에 사진 주소 목록(최대 4장). 이 프로젝트의 feedback 버킷 주소만 허용
create or replace function public.valid_post_images(arr text[]) returns boolean
language sql immutable as $$
  select arr is null or (
    coalesce(array_length(arr, 1), 0) <= 4 and
    coalesce((select bool_and(x like 'https://wpitelbsqzbatoxhdwlp.supabase.co/storage/v1/object/public/feedback/u/%'
                              and char_length(x) < 300 and x !~ '[<>"'' ]')
              from unnest(arr) as x), true))
$$;
alter table public.posts add column if not exists images text[];
alter table public.posts drop constraint if exists posts_images_ok;
alter table public.posts add constraint posts_images_ok check (public.valid_post_images(images));
grant insert (images) on public.posts to anon, authenticated;

-- 3) 목록에 사진 주소도 함께
drop view if exists public.post_list;
create view public.post_list with (security_invoker = on) as
  select p.id, p.board, p.title, p.body, p.author, p.author_name, p.created_at, p.images,
         count(v.*) filter (where v.value = 1)::int as up,
         count(v.*) filter (where v.value = -1)::int as down
  from public.posts p left join public.votes v on v.post_id = p.id
  group by p.id;
grant select on public.post_list to anon, authenticated;
