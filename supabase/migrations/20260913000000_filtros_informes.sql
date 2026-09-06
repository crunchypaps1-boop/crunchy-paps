-- ============================================================================
--  Filtros compartidos en el Informe: periodo y producto
--  + el embudo se separa también por TIPO DE CLIENTE
-- ----------------------------------------------------------------------------
--  Hasta hoy el Informe tenía cinco informes y CINCO controles distintos, ninguno
--  compartido — y el más importante, el dashboard, no aceptaba ninguno: el mes en
--  curso estaba cableado en el cuerpo de la función.
--
--  ── Lo que se descubrió al leerlo, y hay que saber ──
--
--  `top_sabores`, `top_presentaciones` y `entregados` NO eran del mes: sumaban
--  TODO el histórico, dentro de un panel que por lo demás es mensual. Se pasan al
--  periodo, que es lo que una barra de filtros promete y lo que hace coherente la
--  pantalla. Es un CAMBIO DE SIGNIFICADO deliberado, no una regresión.
--
--  `por_entregar` y `por_cobrar_monto` se quedan **globales a propósito**: son
--  saldo operativo, no métrica de periodo. Acotar «lo que me deben» al mes en
--  curso escondería las deudas viejas, que es justo lo contrario de para qué se
--  mira ese número.
--
--  ── El comparativo ──
--
--  Hoy el dashboard compara MTD contra el mismo tramo del mes anterior. Si eso se
--  generalizara a «los N días inmediatamente anteriores», la vista por defecto
--  pasaría a comparar contra los ÚLTIMOS días del mes pasado en vez de los
--  primeros, y el número que se mira a diario cambiaría de significado sin que
--  nadie lo pidiera. Así que:
--
--    rango alineado a mes  → mismo tramo del mes anterior   (lo de hoy, intacto)
--    rango libre           → los N días inmediatamente anteriores
--
--  ── El filtro de producto cambia qué significa «ventas» ──
--
--  Filtrar los pedidos que CONTIENEN un sabor y seguir sumando `ordenes.total`
--  daría el valor entero de esos pedidos, incluyendo todo lo demás que llevaban.
--  Con filtro de producto el dinero sale de los SUBTOTALES DE LÍNEA que casan.
--  La tarjeta lo dice en pantalla: $ con filtro ≠ $ sin filtro para los mismos
--  pedidos, y eso no es un error, es la pregunta que se está haciendo.
--
--  ── Por qué se toca `_interno` y no la envoltura ──
--
--  `dashboard_resumen` ya está envuelto (20260901020000): la envoltura valida
--  sesión y sección y pasa `p_data` TAL CUAL. Los filtros entran en `_interno` y
--  la envoltura no se toca — el portón de seguridad se queda donde está.
--
--  Sin filtros, el resultado debe ser el de hoy. Se comprobó capturando la salida
--  ANTES de aplicar esto y comparando después, clave por clave.
--
--  Reversible: el cuerpo anterior vive en 20260830203059_remote_schema.sql:1275.
-- ============================================================================

create or replace function public.dashboard_resumen_interno(p_data jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_hoy   date := (now() at time zone 'America/Mexico_City')::date;
  v_desde date := coalesce(nullif(p_data->>'desde', '')::date, date_trunc('month', v_hoy)::date);
  v_hasta date := coalesce(nullif(p_data->>'hasta', '')::date, v_hoy);
  v_sabor text := nullif(p_data->>'sabor', '');
  v_pres  text := nullif(p_data->>'presentacion', '');
  v_prod  boolean;
  v_dias  int;
  v_pdesde date;
  v_phasta date;
  v_mes_alineado boolean;
  v_resultado jsonb;
begin
  if v_desde > v_hasta then
    return jsonb_build_object('ok', false, 'error', 'El rango empieza después de terminar');
  end if;

  v_prod := (v_sabor is not null or v_pres is not null);
  v_dias := (v_hasta - v_desde) + 1;
  -- Tope duro: dos años. Sin él, un rango absurdo barre la tabla entera.
  if v_dias > 731 then
    v_desde := v_hasta - 730;
    v_dias  := 731;
  end if;

  v_mes_alineado := (v_desde = date_trunc('month', v_desde)::date)
                and (date_trunc('month', v_hasta) = date_trunc('month', v_desde));

  if v_mes_alineado then
    -- El mismo tramo de días del mes anterior, sin desbordar su último día.
    v_pdesde := (date_trunc('month', v_desde) - interval '1 month')::date;
    v_phasta := least(
                  (v_pdesde + (v_dias - 1) * interval '1 day')::date,
                  (date_trunc('month', v_pdesde) + interval '1 month - 1 day')::date
                );
  else
    v_phasta := v_desde - 1;
    v_pdesde := v_phasta - (v_dias - 1);
  end if;

  with
  -- Pedidos válidos del periodo. Con filtro de producto, solo los que lo llevan.
  ord as (
    select o.id, o.id_vendedor, o.nombre_vendedor, o.estatus_pago, o.estatus_pedido,
           o.total, (o.fecha_orden at time zone 'America/Mexico_City')::date as f
      from ordenes o
     where coalesce(o.tipo_interno, '') = ''
       and o.estatus_pedido <> 'Cancelado'
       and (o.fecha_orden at time zone 'America/Mexico_City')::date between v_desde and v_hasta
       and (not v_prod or exists (
             select 1 from ordenes_detalle d
              where d.id_orden = o.id
                and (v_sabor is null or d.sabor = v_sabor)
                and (v_pres  is null or d.presentacion = v_pres)))
  ),
  -- Las líneas que casan con el filtro, dentro de esos pedidos.
  det as (
    select o.id as id_orden, o.f, o.id_vendedor, o.nombre_vendedor, o.estatus_pago,
           d.sabor, d.presentacion, d.tipo_venta, d.cantidad, d.subtotal
      from ord o
      join ordenes_detalle d on d.id_orden = o.id
     where (v_sabor is null or d.sabor = v_sabor)
       and (v_pres  is null or d.presentacion = v_pres)
  ),
  ord_prev as (
    select o.total, (o.fecha_orden at time zone 'America/Mexico_City')::date as f, o.id
      from ordenes o
     where coalesce(o.tipo_interno, '') = ''
       and o.estatus_pedido <> 'Cancelado'
       and (o.fecha_orden at time zone 'America/Mexico_City')::date between v_pdesde and v_phasta
       and (not v_prod or exists (
             select 1 from ordenes_detalle d
              where d.id_orden = o.id
                and (v_sabor is null or d.sabor = v_sabor)
                and (v_pres  is null or d.presentacion = v_pres)))
  ),
  det_prev as (
    select d.subtotal
      from ord_prev o
      join ordenes_detalle d on d.id_orden = o.id
     where (v_sabor is null or d.sabor = v_sabor)
       and (v_pres  is null or d.presentacion = v_pres)
  ),
  -- Un renglón por día del rango, con 0 donde no hubo venta.
  serie as (
    select g.dia::date as f from generate_series(v_desde, v_hasta, interval '1 day') g(dia)
  ),
  por_dia as (
    select s.f,
           coalesce(
             case when v_prod
                  then (select sum(x.subtotal) from det x where x.f = s.f)
                  else (select sum(y.total)    from ord y where y.f = s.f)
             end, 0) as monto
      from serie s
  ),
  vend as (
    select o.id_vendedor,
           max(o.nombre_vendedor) as nombre,
           case when v_prod
                then (select coalesce(sum(x.subtotal), 0) from det x where x.id_vendedor = o.id_vendedor)
                else sum(o.total)
           end as ventas,
           count(*) as pedidos,
           count(*) filter (where o.estatus_pago <> 'Pagado') as pendientes_pago
      from ord o
     group by o.id_vendedor
  )
  select jsonb_build_object(

    -- Ventas por día del periodo. `dia` (día del mes) se conserva porque el
    -- frontend lo usa; `fecha` es lo correcto para un rango que cruce meses.
    'ventas_dia', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dia',   extract(day from p.f)::int,
               'fecha', p.f,
               'monto', p.monto) order by p.f)
        from por_dia p), '[]'::jsonb),

    'mtd_actual', coalesce((
      select case when v_prod then (select coalesce(sum(subtotal), 0) from det)
                  else (select coalesce(sum(total), 0) from ord) end), 0),

    'mtd_anterior', coalesce((
      select case when v_prod then (select coalesce(sum(subtotal), 0) from det_prev)
                  else (select coalesce(sum(total), 0) from ord_prev) end), 0),

    -- Objetivo: cuotas del mes en que TERMINA el rango. No se filtra por
    -- producto — una cuota es global, y prorratearla sería inventar un número.
    'objetivo_mes', coalesce((
      select sum(cuota) from cuotas_vendedor
       where mes = extract(month from v_hasta)::int
         and anio = extract(year from v_hasta)::int), 0),

    -- ── Saldo operativo: GLOBAL a propósito, no del periodo ──
    -- Acotar «lo que me deben» al mes escondería las deudas viejas.
    'por_entregar', coalesce((
      select count(*) from ordenes
       where coalesce(tipo_interno, '') = '' and estatus_pedido <> 'Cancelado'
         and estatus_pedido <> 'Entregado'), 0),
    'por_cobrar_monto', coalesce((
      select sum(total) from ordenes
       where coalesce(tipo_interno, '') = '' and estatus_pedido <> 'Cancelado'
         and estatus_pago <> 'Pagado'), 0),

    -- Entregados: ahora DEL PERIODO (antes era histórico).
    'entregados', coalesce((
      select count(*) from ord where estatus_pedido = 'Entregado'), 0),

    -- Top sabores y presentaciones: ahora DEL PERIODO (antes eran históricos).
    'top_sabores', coalesce((
      select jsonb_agg(jsonb_build_object('sabor', s.sabor, 'pzas', s.pzas) order by s.pzas desc)
        from (select d.sabor, sum(d.cantidad) as pzas
                from det d
               where coalesce(d.sabor, '') <> ''
               group by d.sabor order by pzas desc limit 8) s), '[]'::jsonb),

    'top_presentaciones', coalesce((
      select jsonb_agg(jsonb_build_object('presentacion', p.presentacion, 'pzas', p.pzas) order by p.pzas desc)
        from (select d.presentacion, sum(d.cantidad) as pzas
                from det d
               where coalesce(d.presentacion, '') <> ''
                 and coalesce(d.tipo_venta, '') <> 'A granel'
               group by d.presentacion order by pzas desc limit 8) p), '[]'::jsonb),

    'por_vendedor', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id_vendedor', v.id_vendedor,
               'nombre', v.nombre,
               'ventas', v.ventas,
               'cuota', coalesce(c.cuota, 0),
               'pedidos', v.pedidos,
               'pendientes_pago', v.pendientes_pago,
               'pct_pendiente_pago', case when v.pedidos > 0
                                          then round(100.0 * v.pendientes_pago / v.pedidos)::int
                                          else 0 end
             ) order by v.ventas desc)
        from vend v
        left join cuotas_vendedor c
          on c.id_vendedor = v.id_vendedor
         and c.mes  = extract(month from v_hasta)::int
         and c.anio = extract(year  from v_hasta)::int), '[]'::jsonb),

    -- `dia_mes` se conserva por compatibilidad; `dias` es lo correcto para un
    -- rango cualquiera, y los filtros vuelven para que la pantalla los muestre.
    'dia_mes', extract(day from v_hasta)::int,
    'dias',    v_dias,
    'desde',   v_desde,
    'hasta',   v_hasta,
    'prev_desde', v_pdesde,
    'prev_hasta', v_phasta,
    'filtro_producto', v_prod,
    'sabor', v_sabor,
    'presentacion', v_pres
  ) into v_resultado;

  return jsonb_build_object('ok', true, 'data', v_resultado);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$$;

alter function public.dashboard_resumen_interno(jsonb) owner to postgres;
revoke all on function public.dashboard_resumen_interno(jsonb) from public, anon, authenticated;

comment on function public.dashboard_resumen_interno(jsonb) is
  'Dashboard con filtros de periodo (desde/hasta) y producto (sabor/presentacion). Sin filtros reproduce la vista de hoy. por_entregar y por_cobrar_monto son globales a propósito. Ampliado 5 sep 2026.';

-- ============================================================================
--  El embudo, además, por TIPO DE CLIENTE
-- ----------------------------------------------------------------------------
--  Hoy todo el tráfico es de consumidor, pero el catálogo ya sirve a tiendas,
--  restaurantes y mayoristas con precios distintos, y sus recorridos no tienen por
--  qué parecerse: un tendero que repone cada semana no se comporta como alguien
--  que descubre la marca. Cuando convivan, un embudo agregado los promediaría en
--  una cifra que no describe a ninguno.
--
--  El frontend marca `params->>'t'` con el tipo (consumidor/tienda/restaurante/
--  mayorista/vendedor). Los eventos anteriores no lo llevan y caen en
--  'sin marcar' — se ve tal cual, en vez de repartirlos a ojo.
-- ============================================================================

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
  select s.id_vendedor into v_id_vend
    from public.sesion_exige_seccion(p_data->>'token', 'resumen') s;
  if v_id_vend is null then
    return jsonb_build_object('ok', false, 'error', 'No autorizado');
  end if;

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
      coalesce(e.params->>'v', '') = '1' as es_personal,
      nullif(e.params->>'t', '')         as tipo
    from public.eventos_navegacion e
    where e.creado_en >= v_desde
  ),
  por_sesion as (
    select sid,
           bool_or(es_personal) as personal,
           -- El tipo puede cambiar dentro de una sesión (alguien entra como
           -- consumidor y luego se identifica como tienda). Gana el ÚLTIMO que
           -- se vio: es el que describe la compra, que es lo que interesa.
           (array_remove(array_agg(tipo order by paso), null))[
              cardinality(array_remove(array_agg(tipo order by paso), null))] as tipo,
           max(paso) as mayor
      from ev
     where paso > 0 and sid is not null
     group by sid
  ),
  conteo as (
    select personal,
           coalesce(tipo, 'sin marcar') as tipo,
           count(*)                            as sesiones,
           count(*) filter (where mayor >= 1) as p1,
           count(*) filter (where mayor >= 2) as p2,
           count(*) filter (where mayor >= 3) as p3,
           count(*) filter (where mayor >= 4) as p4,
           count(*) filter (where mayor >= 5) as p5,
           count(*) filter (where mayor >= 6) as p6
      from por_sesion
     group by personal, coalesce(tipo, 'sin marcar')
  )
  select jsonb_agg(
           jsonb_build_object(
             'canal',    case when c.personal then 'personal' else 'consumidor' end,
             'tipo',     c.tipo,
             'sesiones', c.sesiones,
             'pasos',    jsonb_build_array(
               jsonb_build_object('paso', 1, 'evento', 'view_catalog',   'nombre', 'Ve el catálogo',   'sesiones', c.p1),
               jsonb_build_object('paso', 2, 'evento', 'view_item',      'nombre', 'Abre un producto', 'sesiones', c.p2),
               jsonb_build_object('paso', 3, 'evento', 'add_to_cart',    'nombre', 'Añade al carrito', 'sesiones', c.p3),
               jsonb_build_object('paso', 4, 'evento', 'begin_checkout', 'nombre', 'Abre el checkout', 'sesiones', c.p4),
               jsonb_build_object('paso', 5, 'evento', 'select_payment', 'nombre', 'Elige pago',       'sesiones', c.p5),
               jsonb_build_object('paso', 6, 'evento', 'purchase',       'nombre', 'Compra',           'sesiones', c.p6)
             )
           )
           order by c.personal, c.sesiones desc
         )
    into v_out
    from conteo c;

  return jsonb_build_object(
    'ok',      true,
    'dias',    v_dias,
    'desde',   v_desde,
    'canales', coalesce(v_out, '[]'::jsonb)
  );
end;
$$;

alter function public.embudo_resumen(jsonb) owner to postgres;
grant execute on function public.embudo_resumen(jsonb) to anon;
grant execute on function public.embudo_resumen(jsonb) to authenticated;
grant execute on function public.embudo_resumen(jsonb) to service_role;

comment on function public.embudo_resumen(jsonb) is
  'Embudo por sesión (paso más lejano), separado por canal (consumidor/personal) y por tipo de cliente. Ampliado 5 sep 2026.';
