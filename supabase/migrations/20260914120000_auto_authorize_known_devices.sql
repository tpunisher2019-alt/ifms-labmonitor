alter table public.system_settings
  add column if not exists auto_authorize_known_devices boolean;

update public.system_settings
set auto_authorize_known_devices = true
where auto_authorize_known_devices is null;

alter table public.system_settings
  alter column auto_authorize_known_devices set default true,
  alter column auto_authorize_known_devices set not null;

comment on column public.system_settings.auto_authorize_known_devices is
  'Autoriza automaticamente uma nova instalação somente quando a impressão física do hardware coincide com um dispositivo já cadastrado.';
