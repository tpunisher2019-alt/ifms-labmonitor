create table if not exists public.system_settings (
  id boolean primary key default true check (id),
  event_retention_days integer not null default 90 check (event_retention_days between 7 and 3650),
  updated_at timestamptz not null default now(),
  updated_by text
);

insert into public.system_settings(id, event_retention_days)
values (true, 90)
on conflict (id) do nothing;

alter table public.system_settings enable row level security;

create or replace function public.cleanup_expired_device_events()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_count bigint;
  retention_days integer;
begin
  select event_retention_days into retention_days from public.system_settings where id = true;
  delete from public.device_events
  where occurred_at < now() - make_interval(days => coalesce(retention_days, 90));
  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

revoke all on function public.cleanup_expired_device_events() from public, anon, authenticated;

create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule(
  'labmonitor-event-retention-daily',
  '15 3 * * *',
  $$select public.cleanup_expired_device_events();$$
);

