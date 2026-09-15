alter table public.devices add column if not exists active_mac text;
alter table public.devices add column if not exists active_adapter_name text;
create table public.device_name_bindings (
  mac text primary key check (mac ~ '^([0-9A-F]{2}:){5}[0-9A-F]{2}$'),
  device_id uuid not null references public.devices(id) on delete cascade,
  desired_hostname text not null check (length(desired_hostname) between 1 and 15 and desired_hostname ~ '^[A-Z0-9]([A-Z0-9-]*[A-Z0-9])?$' and desired_hostname !~ '^[0-9]+$'),
  revision uuid not null default gen_random_uuid(),
  enabled boolean not null default true,
  status text not null default 'pending' check (status in ('pending','reboot_pending','succeeded','failed','disabled')),
  result_message text,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index device_name_bindings_device_idx on public.device_name_bindings(device_id);
create unique index device_name_bindings_hostname_idx on public.device_name_bindings(desired_hostname) where enabled;
alter table public.device_name_bindings enable row level security;
revoke all on public.device_name_bindings from anon, authenticated;
grant select on public.device_name_bindings to authenticated;
create policy name_bindings_admin_read on public.device_name_bindings for select to authenticated using ((select public.is_admin()));
grant all on public.device_name_bindings to service_role;
