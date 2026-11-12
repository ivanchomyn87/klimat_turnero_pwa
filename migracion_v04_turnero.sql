-- KLIMAT · v0.4 · Turnero web conectado a Supabase
-- Ejecutar en SQL Editor DESPUÉS de schema.sql / migraciones anteriores / policies_dev.sql.
-- Antes: Authentication → Users → "Add user" (correo + contraseña del técnico).

create table if not exists turnos (
  id text primary key,                       -- código del turno, ej. KLM-A7K2P
  fecha date not null, inicio_min int not null, duracion_h numeric not null, buffer_min int not null default 15,
  estado text not null default 'pending',    -- pending | confirmed | suggested | cancelled
  datos jsonb not null,                      -- copia completa del turno (cliente, servicio, dirección, notas)
  cliente_id uuid,                           -- vínculo con clientes (KLIMAT PWA) al confirmar
  created_at timestamptz default now(), updated_at timestamptz default now()
);
create index if not exists idx_turnos_fecha on turnos (fecha);
create index if not exists idx_turnos_upd on turnos (updated_at);

create table if not exists turnero_config (
  id text primary key, datos jsonb not null default '{}'::jsonb, updated_at timestamptz default now()
);

alter table turnos enable row level security;
alter table turnero_config enable row level security;

-- El público (clave anon) SOLO puede crear solicitudes pendientes; no puede leer ni modificar turnos.
drop policy if exists turnos_publico_insert on turnos;
create policy turnos_publico_insert on turnos for insert to anon
  with check (estado = 'pending' and id ~ '^KLM-[A-Z0-9]{5}$');
-- El técnico (sesión de Supabase Auth) gestiona todo.
drop policy if exists turnos_tecnico_all on turnos;
create policy turnos_tecnico_all on turnos for all to authenticated using (true) with check (true);
drop policy if exists turnero_config_tecnico on turnero_config;
create policy turnero_config_tecnico on turnero_config for all to authenticated using (true) with check (true);

-- Funciones públicas con datos mínimos
create or replace function turnos_ocupados(p_desde date, p_hasta date)
returns table (fecha date, inicio_min int, duracion_h numeric, buffer_min int)
language sql security definer set search_path = public as $$
  select fecha, inicio_min, duracion_h, buffer_min from turnos
  where fecha between p_desde and p_hasta and estado <> 'cancelled'
$$;

create or replace function turnero_config_publica() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'dias', coalesce((select datos->'dias' from turnero_config where id = 'main'), '{}'::jsonb),
    'precios', coalesce((select datos->'precios' from turnero_config where id = 'main'), '{}'::jsonb))
$$;

create or replace function turno_por_codigo(p_codigo text) returns jsonb
language sql security definer set search_path = public as $$
  select datos - 'clientPhone' from turnos where id = upper(p_codigo)
$$;

create or replace function turno_aceptar_opcion(p_codigo text, p_idx int) returns void
language plpgsql security definer set search_path = public as $$
declare t turnos; o jsonb; m int;
begin
  select * into t from turnos where id = upper(p_codigo) and estado = 'suggested';
  if not found then raise exception 'turno no encontrado'; end if;
  o := t.datos->'suggestedOptions'->p_idx;
  if o is null then raise exception 'opción inválida'; end if;
  m := (o->>'startMin')::int;
  update turnos set fecha = (o->>'date')::date, inicio_min = m, estado = 'confirmed', updated_at = now(),
    datos = t.datos || jsonb_build_object('date', o->>'date', 'startMin', m, 'status', 'confirmed',
      'timeLabel', lpad((m/60)::text, 2, '0') || ':' || lpad((m%60)::text, 2, '0') || ' hs', 'suggestedOptions', '[]'::jsonb)
  where id = t.id;
end $$;

grant execute on function turnos_ocupados(date, date), turnero_config_publica(), turno_por_codigo(text), turno_aceptar_opcion(text, int) to anon, authenticated;
