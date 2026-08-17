create or replace function public.get_admin_storage_metrics()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  database_bytes bigint;
  object_storage_bytes bigint;
  object_count bigint;
begin
  select coalesce(sum(pg_catalog.pg_database_size(datname)), 0)
  into database_bytes
  from pg_catalog.pg_database;

  select
    coalesce(sum(case when metadata->>'size' ~ '^[0-9]+$' then (metadata->>'size')::bigint else 0 end), 0),
    count(*)
  into object_storage_bytes, object_count
  from storage.objects;

  return jsonb_build_object(
    'databaseBytes', database_bytes,
    'databaseLimitBytes', 524288000,
    'objectStorageBytes', object_storage_bytes,
    'objectStorageLimitBytes', 1073741824,
    'objectCount', object_count,
    'measuredAt', now()
  );
end;
$$;

revoke all on function public.get_admin_storage_metrics() from public;
revoke all on function public.get_admin_storage_metrics() from anon;
revoke all on function public.get_admin_storage_metrics() from authenticated;
grant execute on function public.get_admin_storage_metrics() to service_role;
