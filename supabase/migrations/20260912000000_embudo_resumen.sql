-- ============================================================================
--  embudo_resumen — ¿dónde se cae la gente antes de comprar?
--  PLAN.md §7.6, pregunta 1
-- ----------------------------------------------------------------------------
--  El embudo:
--
--    view_catalog → view_item → add_to_cart → begin_checkout → select_payment → purchase
--
--  ── Por qué se mide por el paso MÁS LEJANO de cada sesión ──
--
--  Lo evidente sería contar cuántas sesiones dispararon cada evento. No sirve:
--  se puede añadir al carrito desde el catálogo sin abrir ninguna ficha, así que
--  `add_to_cart` puede tener MÁS sesiones que `view_item` y el «embudo» crece en
--  mitad del recorrido. Deja de ser un embudo y el porcentaje no significa nada.
--
--  Aquí, cada sesión aporta UN número: el escalón más lejano al que llegó. El
--  escalón N cuenta las sesiones con `mayor >= N`, así que cada uno es subconjunto
--  del anterior por construcción y «sobrevive el 40 %» quiere decir exactamente eso.
--
--  ── Por qué DOS embudos y no uno ──
--
--  Es una sola app: cuando un vendedor atiende el mostrador pasa por el mismo
--  catálogo, abre el mismo cajón de checkout y confirma con la misma función. Sus
--  sesiones entran al embudo como si fueran de un cliente — y no es ruido neutro:
--  un vendedor abre el checkout para cerrar una venta que YA está hecha, así que
--  convierte casi al 100 %. Mezclado, el embudo sale estupendo y esconde
--  justamente la caída que se busca.
--
--  El frontend marca `params->>'v' = '1'` en las sesiones de personal (va en
--  `params`, que ya es jsonb: sin columnas nuevas). Se devuelven los dos canales
--  por separado. Decisión de Abraham, 5 sep 2026: el del mostrador también
--  interesa — si el personal se atasca en un paso, es fricción de la herramienta
--  que usan todos los días, y hoy eso no lo ve nadie.
--
--  ⚠️ Los eventos ANTERIORES al despliegue no llevan la marca, así que caen todos
--  en «consumidor». La tarjeta avisa de la fecha de corte; no se intenta adivinar
--  hacia atrás.
--
--  Aditivo y reversible:
--    drop function if exists public.embudo_resumen(jsonb);
--    drop index if exists public.idx_eventos_creado_en;
-- ============================================================================

-- La consulta filtra por rango de fecha sobre una tabla que solo crece y que hoy
-- no tiene un solo índice. Con 3.757 filas no se nota; es de los hallazgos
-- dormidos por volumen, no de los que no existen (hallazgo 08).
create index if not exists idx_eventos_creado_en
  on public.eventos_navegacion (creado_en desc);

comment on index public.idx_eventos_creado_en is
  'Sirve embudo_resumen: barrido por rango de fecha. Creado 5 sep 2026, PLAN.md §7.6.';

create or replace function public.embudo_resumen(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_id_vend bigint;
  v_dias    integer := coalesce((p_data->>'dias')::integer, 30);
  v_desde   timestamptz;
  v_out     jsonb;
begin
  -- Mismo portón que dashboard_resumen: sesión válida y sección `resumen`.
  select s.id_vendedor into v_id_vend
    from public.sesion_exige_seccion(p_data->>'token', 'resumen') s;
  if v_id_vend is null then
    return jsonb_build_object('ok', false, 'error', 'No autorizado');
  end if;

  -- Tope duro: sin él, un `dias` absurdo barre la tabla entera.
  if v_dias < 1   then v_dias := 1;   end if;
  if v_dias > 180 then v_dias := 180; end if;
  v_desde := now() - (v_dias || ' days')::interval;

  with ev as (
    select
      nullif(e.session_id, '') as sid,
      case e.evento
        when 'view_catalog'   then 1
        when 'view_item'      then 2
        when 'add_to_cart'    then 3
        when 'begin_checkout' then 4
        when 'select_payment' then 5
        when 'purchase'       then 6
        else 0
      end as paso,
      coalesce(e.params->>'v', '') = '1' as es_personal
    from public.eventos_navegacion e
    where e.creado_en >= v_desde
  ),
  por_sesion as (
    -- Una fila por sesión: su canal y su escalón más lejano. Las sesiones que
    -- solo dispararon eventos de fuera del embudo (login, view_section, banners)
    -- no entran: no empezaron el recorrido.
    select sid,
           bool_or(es_personal) as personal,
           max(paso)            as mayor
      from ev
     where paso > 0 and sid is not null
     group by sid
  ),
  conteo as (
    select personal,
           count(*)                            as sesiones,
           count(*) filter (where mayor >= 1) as p1,
           count(*) filter (where mayor >= 2) as p2,
           count(*) filter (where mayor >= 3) as p3,
           count(*) filter (where mayor >= 4) as p4,
           count(*) filter (where mayor >= 5) as p5,
           count(*) filter (where mayor >= 6) as p6
      from por_sesion
     group by personal
  )
  select jsonb_agg(
           jsonb_build_object(
             'canal',    case when c.personal then 'personal' else 'consumidor' end,
             'sesiones', c.sesiones,
             'pasos',    jsonb_build_array(
               jsonb_build_object('paso', 1, 'evento', 'view_catalog',   'nombre', 'Ve el catálogo',    'sesiones', c.p1),
               jsonb_build_object('paso', 2, 'evento', 'view_item',      'nombre', 'Abre un producto',  'sesiones', c.p2),
               jsonb_build_object('paso', 3, 'evento', 'add_to_cart',    'nombre', 'Añade al carrito',  'sesiones', c.p3),
               jsonb_build_object('paso', 4, 'evento', 'begin_checkout', 'nombre', 'Abre el checkout',  'sesiones', c.p4),
               jsonb_build_object('paso', 5, 'evento', 'select_payment', 'nombre', 'Elige pago',        'sesiones', c.p5),
               jsonb_build_object('paso', 6, 'evento', 'purchase',       'nombre', 'Compra',            'sesiones', c.p6)
             )
           )
           order by c.personal            -- consumidor primero
         )
    into v_out
    from conteo c;

  return jsonb_build_object(
    'ok',     true,
    'dias',   v_dias,
    'desde',  v_desde,
    'canales', coalesce(v_out, '[]'::jsonb)
  );
end;
$$;

alter function public.embudo_resumen(jsonb) owner to postgres;

-- Se concede a anon/authenticated como el resto de RPCs de panel: el portón real
-- es `sesion_exige_seccion` dentro de la función, no el GRANT. Sin token no
-- devuelve una sola cifra.
grant execute on function public.embudo_resumen(jsonb) to anon;
grant execute on function public.embudo_resumen(jsonb) to authenticated;
grant execute on function public.embudo_resumen(jsonb) to service_role;

comment on function public.embudo_resumen(jsonb) is
  'Embudo por sesión (paso más lejano alcanzado), separado en consumidor y personal. Exige sesión con sección resumen. Creado 5 sep 2026, PLAN.md §7.6 pregunta 1.';
