-- Separa pacotes e tarefas de atualização por família de sistema operacional.
alter table public.agent_releases
  add column if not exists platform text;

update public.agent_releases
set platform = 'windows'
where platform is null;

alter table public.agent_releases
  alter column platform set default 'windows',
  alter column platform set not null;

alter table public.agent_releases
  drop constraint if exists agent_releases_platform_check;
alter table public.agent_releases
  add constraint agent_releases_platform_check
  check (platform in ('windows', 'linux'));

-- A mesma versão pode existir para Windows e Linux, cada uma com seu pacote.
alter table public.agent_releases
  drop constraint if exists agent_releases_version_key;
alter table public.agent_releases
  drop constraint if exists agent_releases_platform_version_key;
alter table public.agent_releases
  add constraint agent_releases_platform_version_key unique (platform, version);

create index if not exists agent_releases_active_platform_created_idx
  on public.agent_releases (platform, created_at desc)
  where active = true;

create or replace function public.create_device_job(
  job_type text,
  device_ids uuid[],
  release_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_job_id uuid;
  release_platform text;
  requested_count integer;
  existing_count integer;
begin
  if not public.is_admin() then
    raise exception 'admin_required';
  end if;
  if job_type not in ('agent_update', 'inventory_refresh')
     or coalesce(array_length(device_ids, 1), 0) = 0 then
    raise exception 'invalid_job';
  end if;

  select count(*) into requested_count
  from (select distinct unnest(device_ids) as id) requested;
  select count(*) into existing_count
  from public.devices d
  where d.id = any(device_ids);
  if requested_count <> existing_count then
    raise exception 'invalid_device';
  end if;

  if job_type = 'agent_update' then
    if not coalesce((select remote_updates_enabled from public.system_settings where id = true), false) then
      raise exception 'remote_updates_disabled';
    end if;
    if release_id is null then
      raise exception 'release_required';
    end if;

    select r.platform into release_platform
    from public.agent_releases r
    where r.id = release_id and r.active = true;
    if release_platform is null then
      raise exception 'invalid_release';
    end if;

    if exists (
      select 1
      from public.devices d
      where d.id = any(device_ids)
        and case
          when lower(trim(d.os_type)) like 'win%' then 'windows'
          when lower(trim(d.os_type)) in ('linux', 'debian', 'ubuntu') then 'linux'
          else lower(trim(d.os_type))
        end <> release_platform
    ) then
      raise exception 'incompatible_device_platform';
    end if;
  end if;

  insert into public.jobs(type, payload, created_by)
  values (
    job_type,
    case when release_id is null then '{}'::jsonb
         else jsonb_build_object('releaseId', release_id, 'platform', release_platform)
    end,
    (select email from public.profiles where id = (select auth.uid()))
  )
  returning id into new_job_id;

  insert into public.device_jobs(job_id, device_id)
  select new_job_id, selected.id
  from (select distinct unnest(device_ids) as id) selected;

  return new_job_id;
end
$$;

revoke all on function public.create_device_job(text, uuid[], uuid) from public, anon;
grant execute on function public.create_device_job(text, uuid[], uuid) to authenticated;
