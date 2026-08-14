create extension if not exists pgcrypto;

create table if not exists public.enrollment_tokens (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique,
  label text not null,
  expires_at timestamptz,
  used_at timestamptz,
  used_by uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.devices (
  id uuid primary key default gen_random_uuid(),
  installation_id text not null unique,
  hostname text not null,
  device_secret_hash text not null,
  agent_version text not null,
  status text not null default 'online' check (status in ('online','offline','disabled')),
  last_seen_at timestamptz not null default now(),
  inventory_collected_at timestamptz,
  inventory_hash text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.enrollment_tokens
  drop constraint if exists enrollment_tokens_used_by_fkey;
alter table public.enrollment_tokens
  add constraint enrollment_tokens_used_by_fkey foreign key (used_by) references public.devices(id);

create table if not exists public.device_events (
  event_id uuid primary key,
  device_id uuid not null references public.devices(id) on delete cascade,
  occurred_at timestamptz not null,
  event_type text not null,
  session_key text,
  session_id integer,
  user_name text,
  payload jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default now()
);
create index if not exists device_events_device_time_idx on public.device_events(device_id, occurred_at desc);
create index if not exists device_events_type_time_idx on public.device_events(event_type, occurred_at desc);

create table if not exists public.software_inventory (
  device_id uuid not null references public.devices(id) on delete cascade,
  inventory_key text not null,
  name text not null,
  version text,
  publisher text,
  install_date text,
  scope text,
  architecture text,
  product_code text,
  estimated_size_kb bigint,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (device_id, inventory_key)
);
create index if not exists software_inventory_name_idx on public.software_inventory(lower(name));

create table if not exists public.agent_releases (
  id uuid primary key default gen_random_uuid(),
  version text not null unique,
  storage_path text not null unique,
  sha256 text not null check (length(sha256) = 64),
  release_notes text,
  active boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.jobs (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('agent_update','inventory_refresh')),
  payload jsonb not null default '{}'::jsonb,
  created_by text,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  cancelled_at timestamptz
);

create table if not exists public.device_jobs (
  job_id uuid not null references public.jobs(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','leased','succeeded','failed','cancelled')),
  leased_at timestamptz,
  completed_at timestamptz,
  result jsonb,
  primary key (job_id, device_id)
);
create index if not exists device_jobs_device_status_idx on public.device_jobs(device_id, status);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('agent-releases', 'agent-releases', false, 52428800, array['application/zip', 'application/x-zip-compressed'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

alter table public.enrollment_tokens enable row level security;
alter table public.devices enable row level security;
alter table public.device_events enable row level security;
alter table public.software_inventory enable row level security;
alter table public.agent_releases enable row level security;
alter table public.jobs enable row level security;
alter table public.device_jobs enable row level security;

-- Não há políticas para anon/authenticated: dispositivos passam exclusivamente
-- pela Edge Function e o painel usa uma chave secreta somente no servidor.

-- Exemplo para gerar um token de matrícula de uso único:
-- insert into public.enrollment_tokens(token_hash, label, expires_at)
-- values (encode(digest('COLE-UM-TOKEN-ALEATORIO-AQUI', 'sha256'), 'hex'), 'Laboratório 01', now() + interval '7 days');
