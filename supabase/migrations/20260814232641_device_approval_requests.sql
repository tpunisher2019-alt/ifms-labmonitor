create table if not exists public.device_enrollment_requests (
  id uuid primary key default gen_random_uuid(),
  installation_id text not null unique,
  hostname text not null,
  machine_uuid_hash text not null,
  request_secret_hash text not null,
  mac_addresses text[] not null default '{}',
  local_ip_addresses text[] not null default '{}',
  request_ip text,
  os_type text not null default 'Windows',
  os_version text,
  agent_version text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected','claimed')),
  first_requested_at timestamptz not null default now(),
  last_requested_at timestamptz not null default now(),
  approved_at timestamptz,
  approved_by uuid references auth.users(id) on delete set null,
  rejected_at timestamptz,
  rejected_by uuid references auth.users(id) on delete set null,
  claimed_at timestamptz,
  device_id uuid unique references public.devices(id) on delete set null
);

create index if not exists device_enrollment_requests_status_time_idx
  on public.device_enrollment_requests(status, last_requested_at desc);
create index if not exists device_enrollment_requests_approved_by_idx
  on public.device_enrollment_requests(approved_by);
create index if not exists device_enrollment_requests_rejected_by_idx
  on public.device_enrollment_requests(rejected_by);

alter table public.devices add column if not exists primary_mac text;
alter table public.devices add column if not exists mac_addresses text[] not null default '{}';
alter table public.devices add column if not exists local_ip_addresses text[] not null default '{}';
alter table public.devices add column if not exists public_ip text;

alter table public.device_enrollment_requests enable row level security;

revoke all on table public.device_enrollment_requests from anon, authenticated;
grant select on table public.device_enrollment_requests to authenticated;
grant update(status) on table public.device_enrollment_requests to authenticated;

drop policy if exists admin_read_device_enrollment_requests on public.device_enrollment_requests;
create policy admin_read_device_enrollment_requests
  on public.device_enrollment_requests for select to authenticated
  using ((select public.is_admin()));

drop policy if exists admin_update_device_enrollment_requests on public.device_enrollment_requests;
create policy admin_update_device_enrollment_requests
  on public.device_enrollment_requests for update to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

create or replace function public.stamp_device_enrollment_decision()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if old.status = 'claimed' and new.status <> old.status then
    raise exception 'claimed_request_is_immutable';
  end if;
  if new.status = 'pending' and old.status <> 'pending' then
    raise exception 'request_cannot_return_to_pending';
  end if;
  if new.status = 'approved' and old.status <> 'approved' then
    new.approved_at = now();
    new.approved_by = auth.uid();
    new.rejected_at = null;
    new.rejected_by = null;
  elsif new.status = 'rejected' and old.status <> 'rejected' then
    new.rejected_at = now();
    new.rejected_by = auth.uid();
    new.approved_at = null;
    new.approved_by = null;
  end if;
  return new;
end;
$$;

drop trigger if exists stamp_device_enrollment_decision on public.device_enrollment_requests;
create trigger stamp_device_enrollment_decision
before update of status on public.device_enrollment_requests
for each row execute function public.stamp_device_enrollment_decision();

revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.create_device_job(text, uuid[], uuid) from public, anon;
revoke execute on function public.is_active_user() from public, anon;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.create_device_job(text, uuid[], uuid) to authenticated;
grant execute on function public.is_active_user() to authenticated;
grant execute on function public.is_admin() to authenticated;
