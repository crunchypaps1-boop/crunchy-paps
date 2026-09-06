-- ============================================================================
--  ⚠️ ESTE ARCHIVO NO ES UNA MIGRACIÓN, Y ESTÁ FUERA DE migrations/ A PROPÓSITO
-- ----------------------------------------------------------------------------
--  Decisión de Abraham, 6 sep 2026: que este atajo **no pueda** llegar a
--  producción, ni por descuido ni por un `db push` distraído. La guarda de
--  `_entorno` lo haría inofensivo allá de todos modos, pero el beneficio de
--  tenerlo en producción es CERO, así que no se despliega y punto. Misma
--  convención que `supabase/urgente/` y `supabase/rollback/`.
--
--  Consecuencia asumida: los historiales de migración de staging y producción
--  dejan de ser idénticos. Es el precio, y es barato.
--
--  Para aplicarlo (o reaplicarlo tras un reset de staging):
--
--      cd C:\Proyectos\crunchy-paps
--      cat supabase/.temp/project-ref     # DEBE decir dkwatbsaidlfjqjnfyrk
--      supabase db query --linked -f supabase/solo-staging/otp_atajo_staging.sql
--
--  Sin esto, `node tools/probar-perfiles.mjs` no puede emitir sesiones y falla
--  con «Este atajo solo existe en staging».
--
--  Atajo de OTP para PRUEBAS — imposible de usar en producción por construcción
-- ----------------------------------------------------------------------------
--  Problema: para probar la app como consumidor, tienda, restaurante o mayorista
--  hace falta una sesión de cliente, y esa sesión solo la emite
--  `emitir_sesion_cliente`, que es **solo service_role** — y con razón: si `anon`
--  pudiera llamarla, cualquiera se emitiría una sesión para el teléfono que
--  quisiera y toda la Etapa B sería decorativa.
--
--  Consecuencia práctica: la rama que traduce el `tipo_id` de un cliente
--  verificado a su columna de precio (crear_pedido, 20260915000000) **no se ha
--  podido ejecutar nunca**. Si el emparejamiento por teléfono falla, un tendero
--  aprobado pagaría precio de consumidor —más caro— y se quejaría.
--
--  ── Por qué esto NO es un agujero ──
--
--  El atajo se apoya en el mismo centinela que protege el seed de datos falsos:
--  la tabla `public._entorno`, creada A MANO **solo** en el proyecto de staging
--  (`dkwatbsaidlfjqjnfyrk`) y que **no existe en ninguna migración**. En
--  producción no existe, y `to_regclass` devuelve null: la función sale por la
--  puerta de servicio sin tocar nada.
--
--  No es una bandera que se pueda olvidar encendida, ni una variable de entorno
--  mal puesta: es la AUSENCIA de una tabla que nadie va a crear en producción
--  porque no está escrita en ningún sitio. Es la misma protección que lleva
--  meses impidiendo que `seed_staging.sql` borre la base real.
--
--  Además cuesta cero SMS, que era el otro motivo: cada prueba con OTP real
--  quema un mensaje de Twilio facturado.
--
--  Reversible: drop function if exists public.emitir_sesion_prueba(text);
-- ============================================================================

create or replace function public.emitir_sesion_prueba(p_telefono text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_entorno text;
begin
  -- La cerradura. `to_regclass` no lanza excepción si la tabla no existe:
  -- devuelve null y salimos limpiamente.
  if to_regclass('public._entorno') is null then
    return jsonb_build_object('ok', false,
      'error', 'Este atajo solo existe en staging');
  end if;

  -- La columna se llama `nombre` (medido en seed_staging.sql:29, no supuesto).
  execute 'select nombre from public._entorno limit 1' into v_entorno;
  if coalesce(v_entorno, '') <> 'staging' then
    return jsonb_build_object('ok', false,
      'error', 'Este atajo solo existe en staging');
  end if;

  -- Se delega en la función de verdad: una sesión de prueba tiene que ser
  -- exactamente igual que una real, o las pruebas no prueban el camino real.
  return public.emitir_sesion_cliente(p_telefono);
end;
$$;

alter function public.emitir_sesion_prueba(text) owner to postgres;

-- Se concede a `anon` A PROPÓSITO: en producción la función existe pero no hace
-- nada, porque la tabla centinela no está. En staging es lo que permite que un
-- agente de navegador recorra la app con los cinco perfiles sin gastar SMS.
grant execute on function public.emitir_sesion_prueba(text) to anon;
grant execute on function public.emitir_sesion_prueba(text) to authenticated;
grant execute on function public.emitir_sesion_prueba(text) to service_role;

comment on function public.emitir_sesion_prueba(text) is
  'Emite una sesión de cliente SIN OTP, solo si existe la tabla centinela public._entorno con valor staging. En producción esa tabla no existe y la función no hace nada. Sirve para probar los perfiles (consumidor/tienda/restaurante/mayorista) sin gastar SMS. Creada 6 sep 2026.';
