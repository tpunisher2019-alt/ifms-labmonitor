drop index if exists public.devices_hardware_fingerprint_unique_idx;

create index if not exists devices_hardware_fingerprint_idx
  on public.devices(hardware_fingerprint)
  where hardware_fingerprint is not null;

comment on column public.devices.hardware_fingerprint is
  'Sinal auxiliar do hardware. Pode se repetir em firmwares ou imagens clonadas e, isoladamente, nunca identifica uma estação.';

comment on column public.devices.mac_addresses is
  'Endereços MAC observados na estação; usados junto ao hardware para impedir a fusão de computadores distintos.';
