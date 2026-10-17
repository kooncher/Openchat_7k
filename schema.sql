-- รันไฟล์นี้ทั้งไฟล์ใน Supabase > SQL Editor ครั้งเดียว
-- *** เปลี่ยนรหัสผู้ดูแลในบรรทัดล่างก่อนรัน ***
create table settings (id int primary key default 1, admin_password text not null);
insert into settings (admin_password) values ('Tam13042542');

create table roster  (key text primary key, name text not null);
create table members (id uuid primary key, name text not null, key text unique not null, created_at timestamptz default now());
create table messages (
  id bigint generated always as identity primary key,
  member_id uuid not null references members(id) on delete cascade,
  body text, img text, created_at timestamptz default now()
);
alter table settings enable row level security;
alter table roster   enable row level security;
alter table members  enable row level security;
alter table messages enable row level security;

create function is_member() returns boolean language sql security definer stable set search_path = public as
$$ select exists (select 1 from members where id = auth.uid()) $$;

create policy "members read"  on members  for select using (is_member());
create policy "messages read" on messages for select using (is_member());
create policy "messages send" on messages for insert with check (
  member_id = auth.uid() and is_member()
  and (body is not null or img is not null) and length(coalesce(body,'')) <= 2000);

create function norm_key(t text) returns text language sql immutable as
$$ select lower(regexp_replace(normalize(t, NFKC), '\s+', '', 'g')) $$;

-- สมาชิกเข้าร่วม: ชื่อต้องตรงรายชื่อ และยังไม่มีคนใช้
create function join_group(p_name text) returns text language plpgsql security definer set search_path = public as $$
declare k text := norm_key(p_name); r roster; begin
  if auth.uid() is null then raise exception 'ยังไม่ได้เข้าสู่ระบบ'; end if;
  if exists (select 1 from members where id = auth.uid()) then
    return (select name from members where id = auth.uid()); end if;
  select * into r from roster where key = k;
  if not found then raise exception 'ไม่พบชื่อนี้ในรายชื่อสมาชิกเกม'; end if;
  if exists (select 1 from members where key = k) then
    raise exception 'ชื่อนี้ถูกใช้ไปแล้ว หากเป็นชื่อของคุณ แจ้งผู้ดูแลให้รีเซ็ต'; end if;
  insert into members (id, name, key) values (auth.uid(), r.name, k);
  return r.name; end $$;

create function check_admin(pw text) returns void language plpgsql security definer set search_path = public as $$
begin if not exists (select 1 from settings where admin_password = pw) then raise exception 'รหัสผู้ดูแลไม่ถูกต้อง'; end if; end $$;

create function admin_get(pw text) returns jsonb language plpgsql security definer set search_path = public as $$
begin perform check_admin(pw);
  return jsonb_build_object(
    'roster',  coalesce((select jsonb_agg(name order by name) from roster), '[]'),
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name) from members), '[]'));
end $$;

create function admin_set_roster(pw text, p_names text[]) returns void language plpgsql security definer set search_path = public as $$
begin perform check_admin(pw);
  delete from roster;
  insert into roster (key, name) select distinct on (norm_key(n)) norm_key(n), trim(n) from unnest(p_names) n where trim(n) <> '';
end $$;

create function admin_remove_member(pw text, p_id uuid) returns void language plpgsql security definer set search_path = public as $$
begin perform check_admin(pw); delete from members where id = p_id; end $$;

revoke execute on function check_admin(text) from public, anon, authenticated;
revoke execute on function norm_key(text) from public, anon, authenticated;

-- ที่เก็บรูป (สูงสุด 5MB เฉพาะไฟล์รูป)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-images', 'chat-images', true, 5242880, array['image/jpeg','image/png','image/gif','image/webp'])
on conflict (id) do nothing;
create policy "members upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-images' and is_member() and (storage.foldername(name))[1] = auth.uid()::text);

-- เรียลไทม์
alter publication supabase_realtime add table messages, members;
