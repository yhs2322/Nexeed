-- 진행자 미배정 교육 → 모든 진행자에게 배정 요청(알림) → 선착순 수락자에게 배정
-- Supabase 대시보드 > SQL Editor 에 붙여넣어 실행해도 됩니다. (여러 번 실행해도 안전)

create table if not exists public.nexeed_assignment_offers (
  course_id uuid not null references public.nexeed_courses(id) on delete cascade,
  instructor_id uuid not null references public.nexeed_members(id) on delete cascade,
  status text not null default '대기' check (status in ('대기','수락','거절','마감')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  primary key (course_id, instructor_id)
);
create index if not exists nexeed_assignment_offers_instructor_idx
  on public.nexeed_assignment_offers(instructor_id, status);

alter table public.nexeed_assignment_offers enable row level security;

drop policy if exists nx_select on public.nexeed_assignment_offers;
create policy nx_select on public.nexeed_assignment_offers
  for select to authenticated
  using (public.nexeed_is_admin() or (public.nexeed_approved() and instructor_id = auth.uid()));
-- insert/update/delete 정책 없음: 아래 트리거와 함수(security definer)로만 변경됩니다.

-- 미배정 교육이면 승인된 모든 진행자에게 요청 생성 / 배정되면 나머지 요청 자동 마감
create or replace function public.nexeed_course_offer_sync()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if new.assignee is null and (tg_op = 'INSERT' or old.assignee is not null) then
    insert into public.nexeed_assignment_offers(course_id, instructor_id)
    select new.id, m.id from public.nexeed_members m
    where m.role = '진행자' and m.approved
    on conflict (course_id, instructor_id)
      do update set status = '대기', created_at = now(), responded_at = null;
  elsif new.assignee is not null and (tg_op = 'INSERT' or old.assignee is distinct from new.assignee) then
    update public.nexeed_assignment_offers
       set status = case when instructor_id = new.assignee then '수락' else '마감' end,
           responded_at = coalesce(responded_at, now())
     where course_id = new.id and status = '대기';
  end if;
  return new;
end;
$$;

drop trigger if exists nexeed_course_offer_sync on public.nexeed_courses;
create trigger nexeed_course_offer_sync
  after insert or update of assignee on public.nexeed_courses
  for each row execute function public.nexeed_course_offer_sync();

-- 진행자: 나에게 온 대기 중 배정 요청 목록
create or replace function public.nexeed_my_open_offers()
returns table(course_id uuid, title text, client text, date date, "time" text, place text, setup text, description text, offered_at timestamptz)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select c.id, c.title, c.client, c.date, c.time, c.place, c.setup, c.description, o.created_at
  from public.nexeed_assignment_offers o
  join public.nexeed_courses c on c.id = o.course_id
  join public.nexeed_members m on m.id = auth.uid()
  where o.instructor_id = auth.uid() and o.status = '대기' and c.assignee is null
    and m.role = '진행자' and m.approved
  order by c.date nulls last, o.created_at;
$$;

-- 진행자: 수락 (선착순 — 동시에 눌러도 한 명만 배정)
create or replace function public.nexeed_accept_offer(course uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if not exists (select 1 from public.nexeed_members where id = auth.uid() and role = '진행자' and approved) then
    raise exception '승인된 진행자만 수락할 수 있습니다.';
  end if;
  if not exists (select 1 from public.nexeed_assignment_offers
                 where course_id = course and instructor_id = auth.uid() and status = '대기') then
    raise exception '수락 가능한 배정 요청이 없습니다.';
  end if;
  update public.nexeed_courses set assignee = auth.uid() where id = course and assignee is null;
  if not found then
    update public.nexeed_assignment_offers set status = '마감', responded_at = now()
     where course_id = course and instructor_id = auth.uid() and status = '대기';
    raise exception '이미 다른 진행자에게 배정된 교육입니다.';
  end if;
end;
$$;

-- 진행자: 거절
create or replace function public.nexeed_decline_offer(course uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  update public.nexeed_assignment_offers set status = '거절', responded_at = now()
   where course_id = course and instructor_id = auth.uid() and status = '대기';
  if not found then raise exception '응답 가능한 배정 요청이 없습니다.'; end if;
end;
$$;

-- 관리자: 교육별 진행자 응답 현황
create or replace function public.nexeed_offer_status(course uuid)
returns table(instructor_id uuid, name text, status text, responded_at timestamptz)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if not public.nexeed_is_admin() then raise exception 'Admin access required'; end if;
  return query
    select o.instructor_id, m.name, o.status, o.responded_at
    from public.nexeed_assignment_offers o join public.nexeed_members m on m.id = o.instructor_id
    where o.course_id = course order by o.status, m.name;
end;
$$;

revoke all on function public.nexeed_course_offer_sync() from public, anon, authenticated;
revoke all on function public.nexeed_my_open_offers() from public, anon;
revoke all on function public.nexeed_accept_offer(uuid) from public, anon;
revoke all on function public.nexeed_decline_offer(uuid) from public, anon;
revoke all on function public.nexeed_offer_status(uuid) from public, anon;
grant execute on function public.nexeed_my_open_offers() to authenticated;
grant execute on function public.nexeed_accept_offer(uuid) to authenticated;
grant execute on function public.nexeed_decline_offer(uuid) to authenticated;
grant execute on function public.nexeed_offer_status(uuid) to authenticated;
revoke all on table public.nexeed_assignment_offers from anon;
grant select on table public.nexeed_assignment_offers to authenticated;

-- 실시간 알림 (Realtime)
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='nexeed_assignment_offers') then
    alter publication supabase_realtime add table public.nexeed_assignment_offers;
  end if;
end $$;
