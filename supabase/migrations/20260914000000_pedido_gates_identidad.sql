-- ============================================================================
--  crear_pedido: lo que vale dinero se decide con la SESIÓN, no con el payload
--  (primera de dos partes — ver la nota del final)
-- ----------------------------------------------------------------------------
--  Encontrado el 5 sep 2026 leyendo la función. `crear_pedido` está abierta a
--  `anon` a propósito —un consumidor sin sesión tiene que poder pedir— pero se
--  cree TODO lo que le mandan. Tres campos del payload deciden dinero:
--
--    1. `total` / `subtotal` / `descuento`  → el importe del pedido
--    2. `tipoInterno`                       → lo pone en CERO
--    3. `canal = 'mostrador'`               → lo marca Pagado + Entregado
--
--  Los tres son el mismo error: el navegador decidiendo cosas que valen dinero.
--
--  Esta migración cierra el 2 y el 3 POR COMPLETO, porque son puertas de
--  identidad y se cierran con una comprobación. El 1 necesita recalcular precios
--  contra el catálogo —granel por peso, cinco columnas de precio, cupones,
--  envío— y va en su propia pieza, con su diseño y sus pruebas.
--
--  ── Por qué no se pone también una "guarda de coherencia" al total ──
--
--  Sería fácil rechazar los pedidos cuyo total no se parezca a la suma de sus
--  líneas. No se hace: los subtotales de línea vienen del mismo payload, así que
--  bastaría con mandar líneas baratas y coherentes. Una guarda así no cierra
--  nada y da la sensación de que sí — que es peor que no tenerla. El importe
--  queda abierto hasta que el servidor calcule los precios de verdad.
--
--  Reversible: el cuerpo anterior está en 20260830203059_remote_schema.sql:1146.
-- ============================================================================

create or replace function public.crear_pedido(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
DECLARE
  v_idempotency  TEXT;
  v_existente    ordenes%ROWTYPE;
  v_id_orden     BIGINT;
  v_consec       TEXT;
  v_canal        TEXT;
  v_subtotal     NUMERIC;
  v_descuento    NUMERIC;
  v_total        NUMERIC;
  v_tipo_int     TEXT;
  v_estatus_ped  TEXT;
  v_estatus_pag  TEXT;
  v_fecha_pago   TIMESTAMPTZ;
  v_producto     JSONB;
  v_id_cliente   BIGINT;
  v_telefono     TEXT;
  v_nombre_cli   TEXT;
  v_filas_det    INTEGER := 0;
  v_id_vend_ses  BIGINT;          -- ← NUEVO: quién pide, según el servidor
BEGIN
  v_idempotency := COALESCE(p_data->>'idempotencyKey', '');
  v_canal := COALESCE(p_data->>'canal', 'web');
  v_tipo_int := COALESCE(p_data->>'tipoInterno', '');
  v_id_cliente := NULLIF(p_data->>'idCliente', '')::BIGINT;
  v_telefono := p_data->>'telefono';
  v_nombre_cli := COALESCE(p_data->>'nombreCliente', '');

  -- 0) IDENTIDAD — la única fuente fiable de quién está pidiendo.
  --    `supabaseCall` ya inyecta el token de vendedor en `p_data.token` cuando
  --    hay sesión de panel; un consumidor normal no lleva ninguno, y eso está
  --    bien: lo que no puede es AUTOCONCEDERSE privilegios de mostrador.
  SELECT s.id_vendedor INTO v_id_vend_ses
    FROM public.resolver_sesion_vendedor(p_data->>'token') s;

  -- Pedido interno = producto que sale sin cobrarse. Solo el personal.
  IF v_tipo_int <> '' AND v_id_vend_ses IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'Un pedido interno requiere sesión de vendedor');
  END IF;

  -- Canal mostrador = nace Pagado y Entregado. Solo el personal.
  -- No se rechaza: se degrada a 'web', que es lo que de verdad es. Rechazar
  -- castigaría a un cliente por un canal mal puesto; degradar deja el pedido
  -- en su estado honesto (Pendiente de pago) y no pierde la venta.
  IF v_canal = 'mostrador' AND v_id_vend_ses IS NULL THEN
    v_canal := 'web';
  END IF;

  -- 1) Idempotency
  IF v_idempotency <> '' THEN
    SELECT * INTO v_existente FROM ordenes WHERE idempotency_key = v_idempotency LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object(
        'ok', true, 'duplicado', true,
        'idOrden', v_existente.id, 'consecutivo', v_existente.consecutivo
      );
    END IF;
  END IF;

  -- 2) Totales
  --    ⚠️ SIGUEN VINIENDO DEL CLIENTE. Es el agujero 1, abierto a propósito
  --    hasta la segunda parte: cerrarlo a medias sería peor. No añadir aquí
  --    guardas cosméticas — ver la cabecera.
  v_subtotal := COALESCE((p_data->>'subtotal')::NUMERIC, 0);
  v_descuento := COALESCE((p_data->>'descuento')::NUMERIC, 0);
  v_total := COALESCE((p_data->>'total')::NUMERIC, v_subtotal - v_descuento);
  IF v_tipo_int <> '' THEN
    v_total := 0; v_subtotal := 0; v_descuento := 0;
  END IF;

  -- 3) Estatus por canal
  v_estatus_ped := 'Pendiente';
  v_estatus_pag := 'Pendiente';
  IF v_canal = 'mostrador' OR v_tipo_int <> '' THEN
    v_estatus_ped := 'Entregado';
    v_estatus_pag := 'Pagado';
    v_fecha_pago := NOW();
  END IF;

  -- 4) Generar consecutivo
  v_consec := siguiente_consecutivo();

  -- 5) Insertar orden
  INSERT INTO ordenes (
    consecutivo, canal, id_cliente, nombre_cliente,
    id_vendedor, nombre_vendedor,
    fecha_orden, fecha_entrega, fecha_pago,
    tipo_pago_id, tipo_pago,
    estatus_pedido, estatus_pago,
    subtotal, descuento, total, notas,
    cp, colonia, municipio, estado, direccion, coordenadas,
    zona_entrega, stripe_payment_id, cupon_codigo, tipo_interno,
    idempotency_key
  ) VALUES (
    v_consec, v_canal, v_id_cliente, v_nombre_cli,
    -- El vendedor sale de la SESIÓN cuando la hay. Antes se creía el
    -- `idVendedor` del payload, así que se podía atribuir una venta a
    -- cualquiera — y de ahí cuelgan las cuotas y el reparto de comisiones.
    COALESCE(v_id_vend_ses, NULLIF(p_data->>'idVendedor', '')::BIGINT),
    p_data->>'nombreVendedor',
    NOW(), COALESCE((p_data->>'fechaEntrega')::TIMESTAMPTZ, NOW()), v_fecha_pago,
    COALESCE((p_data->>'tipoPagoId')::INTEGER, 0), p_data->>'tipoPago',
    v_estatus_ped, v_estatus_pag, v_subtotal, v_descuento, v_total,
    p_data->>'notas', p_data->>'cp', p_data->>'colonia', p_data->>'municipio',
    p_data->>'estado', p_data->>'direccion', p_data->>'coordenadas',
    COALESCE(p_data->>'zonaEntrega', 'cdmx'),
    p_data->>'stripePaymentId',
    UPPER(COALESCE(p_data->>'cuponCodigo', '')),
    v_tipo_int,
    NULLIF(v_idempotency, '')
  ) RETURNING id INTO v_id_orden;

  -- 6) Líneas de detalle
  FOR v_producto IN SELECT * FROM jsonb_array_elements(p_data->'productos') LOOP
    INSERT INTO ordenes_detalle (
      id_orden, consecutivo_orden,
      id_producto, sabor, presentacion, tipo_venta,
      cantidad, gramos_vendidos, precio_unitario, descuento, subtotal, precio_kg, notas_linea
    ) VALUES (
      v_id_orden, v_consec,
      v_producto->>'idProducto', v_producto->>'sabor', v_producto->>'presentacion',
      v_producto->>'tipoVenta',
      COALESCE((v_producto->>'cantidad')::NUMERIC, 0),
      COALESCE((v_producto->>'gramos')::NUMERIC, 0),
      COALESCE((v_producto->>'precio')::NUMERIC, 0),
      COALESCE((v_producto->>'descuento')::NUMERIC, 0),
      COALESCE((v_producto->>'subtotal')::NUMERIC, 0),
      COALESCE((v_producto->>'precioKg')::NUMERIC, 0),
      NULL
    );
    v_filas_det := v_filas_det + 1;
  END LOOP;

  -- 7) Los puntos se otorgan al confirmar Pagado + Entregado (trg_otorgar_puntos).

  RETURN jsonb_build_object(
    'ok', true,
    'idOrden', v_id_orden,
    'consecutivo', v_consec,
    'lineas', v_filas_det,
    'puntosAcumulados', 0
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

alter function public.crear_pedido(jsonb) owner to postgres;

comment on function public.crear_pedido(jsonb) is
  'Crea un pedido. Los pedidos internos y el canal mostrador exigen sesión de vendedor; el id_vendedor sale de la sesión. PENDIENTE (segunda parte): el importe todavía lo decide el cliente — el servidor debe recalcularlo contra el catálogo. Ver cambios/2026-09-05-precio-lo-decide-el-navegador.md.';
