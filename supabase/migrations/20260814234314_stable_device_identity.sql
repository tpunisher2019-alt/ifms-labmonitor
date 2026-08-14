alter table public.devices add column if not exists hardware_fingerprint text;
alter table public.device_enrollment_requests add column if not exists hardware_fingerprint text;
alter table public.device_enrollment_requests add column if not exists matched_device_id uuid references public.devices(id) on delete set null;
alter table public.device_enrollment_requests add column if not exists match_score integer not null default 0;
alter table public.device_enrollment_requests add column if not exists match_reasons text[] not null default '{}';
alter table public.device_enrollment_requests drop constraint if exists device_enrollment_requests_installation_id_key;

create unique index if not exists devices_hardware_fingerprint_unique_idx
  on public.devices(hardware_fingerprint)
  where hardware_fingerprint is not null;
create index if not exists device_enrollment_requests_matched_device_idx
  on public.device_enrollment_requests(matched_device_id);
create index if not exists device_enrollment_requests_installation_time_idx
  on public.device_enrollment_requests(installation_id, last_requested_at desc);
