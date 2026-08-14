alter table public.devices add column if not exists os_type text not null default 'Windows';
alter table public.devices add column if not exists os_version text;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  full_name text not null,
  role text not null default 'monitor' check (role in ('admin','monitor')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.system_settings (
  id boolean primary key default true check (id),
  event_retention_days integer not null default 90 check (event_retention_days between 7 and 3650),
  updated_at timestamptz not null default now(),
  updated_by text
);
insert into public.system_settings(id,event_retention_days) values(true,90) on conflict(id) do nothing;

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles(id,email,full_name,role,active)
  values(new.id,new.email,coalesce(new.raw_user_meta_data->>'full_name',split_part(new.email,'@',1)),case when lower(new.email)='gabriel.barros@ifms.edu.br' then 'admin' else 'monitor' end,true)
  on conflict(id) do update set email=excluded.email,full_name=excluded.full_name,updated_at=now();
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert or update of email on auth.users for each row execute function public.handle_new_user();

insert into public.profiles(id,email,full_name,role,active)
select id,email,case when lower(email)='gabriel.barros@ifms.edu.br' then 'Gabriel da Silva Barros' else coalesce(raw_user_meta_data->>'full_name',split_part(email,'@',1)) end,case when lower(email)='gabriel.barros@ifms.edu.br' then 'admin' else 'monitor' end,true
from auth.users on conflict(id) do update set email=excluded.email,full_name=excluded.full_name,role=case when lower(excluded.email)='gabriel.barros@ifms.edu.br' then 'admin' else public.profiles.role end,updated_at=now();

create or replace function public.is_active_user() returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.profiles where id=auth.uid() and active=true)
$$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.profiles where id=auth.uid() and role='admin' and active=true)
$$;

alter table public.profiles enable row level security;
alter table public.system_settings enable row level security;

drop policy if exists profiles_read_self_or_admin on public.profiles;
create policy profiles_read_self_or_admin on public.profiles for select to authenticated using(id=auth.uid() or public.is_admin());
drop policy if exists dashboard_read_devices on public.devices;
create policy dashboard_read_devices on public.devices for select to authenticated using(public.is_active_user());
drop policy if exists dashboard_read_events on public.device_events;
create policy dashboard_read_events on public.device_events for select to authenticated using(public.is_active_user());
drop policy if exists dashboard_read_inventory on public.software_inventory;
create policy dashboard_read_inventory on public.software_inventory for select to authenticated using(public.is_active_user());
drop policy if exists dashboard_read_releases on public.agent_releases;
create policy dashboard_read_releases on public.agent_releases for select to authenticated using(public.is_active_user());
drop policy if exists dashboard_read_jobs on public.jobs;
create policy dashboard_read_jobs on public.jobs for select to authenticated using(public.is_active_user());
drop policy if exists dashboard_read_device_jobs on public.device_jobs;
create policy dashboard_read_device_jobs on public.device_jobs for select to authenticated using(public.is_active_user());
drop policy if exists dashboard_read_settings on public.system_settings;
create policy dashboard_read_settings on public.system_settings for select to authenticated using(public.is_active_user());
drop policy if exists admin_update_settings on public.system_settings;
create policy admin_update_settings on public.system_settings for update to authenticated using(public.is_admin()) with check(public.is_admin());

create or replace function public.create_device_job(job_type text,device_ids uuid[],release_id uuid default null) returns uuid language plpgsql security definer set search_path=public as $$
declare new_job_id uuid;
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  if job_type not in ('agent_update','inventory_refresh') or coalesce(array_length(device_ids,1),0)=0 then raise exception 'invalid_job'; end if;
  insert into public.jobs(type,payload,created_by) values(job_type,case when release_id is null then '{}'::jsonb else jsonb_build_object('releaseId',release_id) end,(select email from public.profiles where id=auth.uid())) returning id into new_job_id;
  insert into public.device_jobs(job_id,device_id) select new_job_id,unnest(device_ids);
  return new_job_id;
end $$;
revoke all on function public.create_device_job(text,uuid[],uuid) from public;
grant execute on function public.create_device_job(text,uuid[],uuid) to authenticated;
