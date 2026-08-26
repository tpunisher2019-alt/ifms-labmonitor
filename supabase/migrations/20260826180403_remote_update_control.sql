alter table public.system_settings
  add column if not exists remote_updates_enabled boolean not null default true;

update public.system_settings
set remote_updates_enabled = true,
    updated_at = now()
where id = true;

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
begin
  if not public.is_admin() then
    raise exception 'admin_required';
  end if;
  if job_type not in ('agent_update', 'inventory_refresh')
     or coalesce(array_length(device_ids, 1), 0) = 0 then
    raise exception 'invalid_job';
  end if;
  if job_type = 'agent_update'
     and not coalesce((select remote_updates_enabled from public.system_settings where id = true), false) then
    raise exception 'remote_updates_disabled';
  end if;

  insert into public.jobs(type, payload, created_by)
  values (
    job_type,
    case when release_id is null then '{}'::jsonb else jsonb_build_object('releaseId', release_id) end,
    (select email from public.profiles where id = (select auth.uid()))
  )
  returning id into new_job_id;

  insert into public.device_jobs(job_id, device_id)
  select new_job_id, unnest(device_ids);
  return new_job_id;
end
$$;

revoke all on function public.create_device_job(text, uuid[], uuid) from public, anon;
grant execute on function public.create_device_job(text, uuid[], uuid) to authenticated;
