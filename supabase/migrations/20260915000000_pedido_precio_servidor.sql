-- ============================================================================
--  crear_pedido, parte 2: el SERVIDOR calcula el precio, y exige identidad
-- ----------------------------------------------------------------------------
--  La parte 1 (20260914000000) cerró dos de los tres agujeros: el pedido gratis
--  por autodeclararse interno y el «pagado y entregado» por autodeclararse
--  mostrador. Quedaba el importe, que era el que llegaba hasta el cobro real:
--  con la llave pública, sin sesión, se creaba un pedido de $1 por mercancía de
--  $1.000, y Stripe lo cobraba (con un piso de $10).
--
--  Aquí el navegador deja de decidir dinero. Dos cerraduras, no una:
--
--   1. IDENTIDAD OBLIGATORIA (decisión de Abraham, 6 sep 2026): para crear un
--      pedido hace falta sesión de cliente (teléfono verificado por OTP) o de
--      vendedor. «No quiero pedidos sin relación de consumidor real.»
--   2. PRECIO RECALCULADO: cada línea se cotiza contra `productos` /
--      `productos_bebidas` según el nivel que corresponde a QUIEN PIDE, y el
--      total se compara con el declarado.
--
--  Hacen falta las dos. La identidad sola no basta —un cliente verificado
--  seguiría fijándose el precio desde su consola— y el recálculo solo tampoco:
--  sin identidad no se sabe qué columna de precio aplicar.
--
--  ── El nivel de precio sale de quién pide, nunca del payload ──
--
--    vendedor  → el canal que eligió, acotado a la lista. Es personal
--                autenticado: fijar precio en el mostrador es parte de su
--                trabajo, y ya podía hacerlo con la caja en la mano.
--    cliente   → su `tipo_id` REAL en `clientes`, y solo si `aprobado_b2b`.
--                Mapa según la propia app (index.html:6831):
--                1 consumidor · 2 restaurante · 3 tienda · 4 mayorista · 5 mostrador
--    sin nada  → no llega hasta aquí (cerradura 1)
--
--  ── Si el total no cuadra, se RECHAZA ──
--
--  No se corrige en silencio: el cliente vería un precio en pantalla y se le
--  cobraría otro. Se devuelve `error: 'precio_cambiado'` con el total correcto
--  para que la app lo muestre y pida reconfirmar. Tolerancia de $1 por el
--  redondeo.
--
--  ⚠️ ORDEN DE DESPLIEGUE: **la app PRIMERO**. Esta versión exige
--  `tokenCliente` en el payload, y la app de hoy no lo manda: si entra antes,
--  todos los pedidos de consumidor fallan. La app nueva contra la base vieja,
--  en cambio, manda un campo de más que la función vieja ignora.
--
--  Reversible: 20260914000000 tiene el cuerpo anterior íntegro.
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
  v_tipo_int     TEXT;
  v_estatus_ped  TEXT;
  v_estatus_pag  TEXT;
  v_fecha_pago   TIMESTAMPTZ;
  v_producto     JSONB;
  v_id_cliente   BIGINT;
  v_telefono     TEXT;
  v_nombre_cli   TEXT;
  v_filas_det    INTEGER := 0;

  v_id_vend_ses  BIGINT;
  v_tel_ses      TEXT;
  v_cli          clientes%ROWTYPE;
  v_nivel        TEXT;

  v_p            productos%ROWTYPE;
  v_pid          TEXT;
  v_tv           TEXT;
  v_cant         NUMERIC;
  v_gram         NUMERIC;
  v_base         NUMERIC;
  v_pct          NUMERIC;
  v_pkg          NUMERIC;
  v_unit         NUMERIC;
  v_sub_linea    NUMERIC;

  v_sub          NUMERIC := 0;
  v_desc         NUMERIC := 0;
  v_envio        NUMERIC := 0;
  v_desc_envio   NUMERIC := 0;
  v_total        NUMERIC := 0;
  v_declarado    NUMERIC;

  v_cod_cupon    TEXT;
  v_cupon        JSONB;
  v_tipo_cup     TEXT;
  v_valor_cup    NUMERIC;

  v_calc         JSONB := '[]'::JSONB;   -- líneas recotizadas por el servidor
BEGIN
  v_idempotency := COALESCE(p_data->>'idempotencyKey', '');
  v_canal       := COALESCE(p_data->>'canal', 'web');
  v_tipo_int    := COALESCE(p_data->>'tipoInterno', '');
  v_id_cliente  := NULLIF(p_data->>'idCliente', '')::BIGINT;
  v_telefono    := p_data->>'telefono';
  v_nombre_cli  := COALESCE(p_data->>'nombreCliente', '');
  v_cod_cupon   := UPPER(COALESCE(p_data->>'cuponCodigo', ''));

  -- ── 0) IDENTIDAD ────────────────────────────────────────────────────────
  SELECT s.id_vendedor INTO v_id_vend_ses
    FROM public.resolver_sesion_vendedor(p_data->>'token') s;
  v_tel_ses := public.resolver_sesion_cliente(p_data->>'tokenCliente');

  IF v_id_vend_ses IS NULL AND v_tel_ses IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sesion_requerida',
      'mensaje', 'Verifica tu teléfono para completar el pedido');
  END IF;

  IF v_tipo_int <> '' AND v_id_vend_ses IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'Un pedido interno requiere sesión de vendedor');
  END IF;

  IF v_canal = 'mostrador' AND v_id_vend_ses IS NULL THEN
    v_canal := 'web';
  END IF;

  -- ── 1) NIVEL DE PRECIO ──────────────────────────────────────────────────
  IF v_id_vend_ses IS NOT NULL THEN
    v_nivel := LOWER(COALESCE(p_data->>'tipoCliente', 'consumidor'));
    IF v_nivel NOT IN ('consumidor','tienda','restaurante','mayorista','mostrador') THEN
      v_nivel := 'consumidor';
    END IF;
  ELSE
    v_nivel := 'consumidor';
    SELECT * INTO v_cli FROM clientes
     WHERE RIGHT(REGEXP_REPLACE(COALESCE(telefono,''), '\D', '', 'g'), 10)
         = RIGHT(REGEXP_REPLACE(COALESCE(v_tel_ses,''), '\D', '', 'g'), 10)
     LIMIT 1;
    IF FOUND AND COALESCE(v_cli.aprobado_b2b, false) THEN
      v_nivel := CASE v_cli.tipo_id
                   WHEN 2 THEN 'restaurante'
                   WHEN 3 THEN 'tienda'
                   WHEN 4 THEN 'mayorista'
                   ELSE 'consumidor'
                 END;
    END IF;
  END IF;

  -- ── 2) Idempotency ──────────────────────────────────────────────────────
  IF v_idempotency <> '' THEN
    SELECT * INTO v_existente FROM ordenes WHERE idempotency_key = v_idempotency LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('ok', true, 'duplicado', true,
        'idOrden', v_existente.id, 'consecutivo', v_existente.consecutivo);
    END IF;
  END IF;

  -- ── 3) RECOTIZAR CADA LÍNEA ─────────────────────────────────────────────
  FOR v_producto IN SELECT * FROM jsonb_array_elements(p_data->'productos') LOOP
    v_pid  := COALESCE(v_producto->>'idProducto', '');
    v_tv   := COALESCE(v_producto->>'tipoVenta', 'Por Pieza');
    v_cant := COALESCE((v_producto->>'cantidad')::NUMERIC, 0);
    v_gram := COALESCE((v_producto->>'gramos')::NUMERIC, 0);
    v_base := NULL; v_pct := 0; v_pkg := 0; v_p := NULL;

    IF v_pid ~ '^b[0-9]+$' THEN
      -- Bebida: una sola columna de precio, igual para todos los niveles.
      SELECT b.precio INTO v_base FROM productos_bebidas b
       WHERE b.id = SUBSTRING(v_pid FROM 2)::BIGINT
         AND COALESCE(b.activo, true) AND NOT COALESCE(b.descontinuado, false);
    ELSE
      IF v_pid ~ '^[0-9]+$' THEN
        SELECT * INTO v_p FROM productos WHERE id = v_pid::BIGINT;
      END IF;
      IF v_p.id IS NULL THEN
        SELECT * INTO v_p FROM productos
         WHERE sabor = v_producto->>'sabor'
           AND presentacion = v_producto->>'presentacion'
           AND NOT COALESCE(descontinuado, false)
         LIMIT 1;
      END IF;
      IF v_p.id IS NOT NULL THEN
        v_base := CASE v_nivel
                    WHEN 'tienda'      THEN v_p.precio_tienda
                    WHEN 'restaurante' THEN v_p.precio_restaurante
                    -- Puente vivo: mientras precio_mayorista sea 0/NULL se cobra
                    -- precio de tienda, igual que hace getPrecio en la app.
                    WHEN 'mayorista'   THEN COALESCE(NULLIF(v_p.precio_mayorista, 0), v_p.precio_tienda)
                    WHEN 'mostrador'   THEN v_p.precio_mostrador
                    ELSE v_p.precio_consumidor
                  END;
        v_pct := COALESCE(v_p.descuento_pct, 0);
        v_pkg := COALESCE(v_p.precio_granel_kg, 0);
      END IF;
    END IF;

    -- Una línea que no se puede cotizar tumba el pedido entero. Adivinar un
    -- precio sería volver al problema que esto viene a cerrar.
    IF v_base IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'producto_no_encontrado',
        'mensaje', 'No pudimos cotizar: ' ||
                   COALESCE(NULLIF(v_producto->>'sabor',''), v_pid, 'un producto'));
    END IF;

    IF v_tv = 'A granel' THEN
      IF v_pkg <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'granel_sin_precio',
          'mensaje', 'Ese producto no se vende a granel');
      END IF;
      v_unit      := v_pkg;
      v_sub_linea := ROUND(v_gram / 1000.0 * v_pkg, 2);
    ELSE
      -- Mismo redondeo que la app (Math.round del precio con descuento).
      v_unit      := CASE WHEN v_pct > 0 THEN ROUND(v_base * (1 - v_pct / 100.0)) ELSE v_base END;
      v_sub_linea := ROUND(v_cant * v_unit, 2);
    END IF;

    v_sub  := v_sub + v_sub_linea;
    v_calc := v_calc || jsonb_build_object(
      'idProducto',   v_pid,
      'sabor',        v_producto->>'sabor',
      'presentacion', v_producto->>'presentacion',
      'tipoVenta',    v_tv,
      'cantidad',     v_cant,
      'gramos',       v_gram,
      'precio',       CASE WHEN v_tv = 'A granel' THEN 0 ELSE v_unit END,
      'precioKg',     CASE WHEN v_tv = 'A granel' THEN v_pkg ELSE 0 END,
      'subtotal',     v_sub_linea
    );
  END LOOP;

  -- ── 4) CUPÓN — lo valida quien ya sabía hacerlo ─────────────────────────
  IF v_cod_cupon <> '' AND v_tipo_int = '' THEN
    v_cupon := public.validar_cupon(v_cod_cupon, v_telefono, v_id_cliente, v_sub, v_nivel)::JSONB;
    IF COALESCE((v_cupon->>'ok')::BOOLEAN, false) THEN
      v_tipo_cup  := v_cupon->'cupon'->>'tipo';
      v_valor_cup := COALESCE((v_cupon->'cupon'->>'valor')::NUMERIC, 0);
      IF v_tipo_cup = 'descuento_pct' THEN
        v_desc := ROUND(v_sub * v_valor_cup / 100.0, 2);
      ELSIF v_tipo_cup = 'descuento_fijo' THEN
        v_desc := LEAST(v_valor_cup, v_sub);
      END IF;
    END IF;
  END IF;

  -- ── 5) ENVÍO ────────────────────────────────────────────────────────────
  -- 80 = COSTO_PAQUETERIA (index.html:3789). Es una constante duplicada en dos
  -- sitios: debería vivir en config_produccion y leerse desde los dos. Anotado.
  IF COALESCE(p_data->>'metodoEntrega','') = 'paqueteria'
     AND v_nivel = 'consumidor' AND v_tipo_int = '' THEN
    v_envio := 80;
  END IF;
  IF v_tipo_cup = 'envio_gratis' THEN v_desc_envio := v_envio; END IF;

  v_total := GREATEST(0, v_sub - v_desc + v_envio - v_desc_envio);

  IF v_tipo_int <> '' THEN
    v_total := 0; v_sub := 0; v_desc := 0;
  END IF;

  -- ── 6) CUADRE ───────────────────────────────────────────────────────────
  v_declarado := COALESCE((p_data->>'total')::NUMERIC, -1);
  IF v_tipo_int = '' AND ABS(v_total - v_declarado) > 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'precio_cambiado',
      'mensaje', 'El precio cambió. Revisa tu carrito y confirma de nuevo.',
      'totalCorrecto', v_total, 'subtotal', v_sub,
      'descuento', v_desc, 'envio', v_envio - v_desc_envio,
      'totalEnviado', v_declarado);
  END IF;

  -- ── 7) Estatus ──────────────────────────────────────────────────────────
  v_estatus_ped := 'Pendiente';
  v_estatus_pag := 'Pendiente';
  IF v_canal = 'mostrador' OR v_tipo_int <> '' THEN
    v_estatus_ped := 'Entregado';
    v_estatus_pag := 'Pagado';
    v_fecha_pago := NOW();
  END IF;

  v_consec := siguiente_consecutivo();

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
    COALESCE(v_id_vend_ses, NULLIF(p_data->>'idVendedor', '')::BIGINT),
    p_data->>'nombreVendedor',
    NOW(), COALESCE((p_data->>'fechaEntrega')::TIMESTAMPTZ, NOW()), v_fecha_pago,
    COALESCE((p_data->>'tipoPagoId')::INTEGER, 0), p_data->>'tipoPago',
    v_estatus_ped, v_estatus_pag,
    v_sub, v_desc, v_total,          -- ← cifras del SERVIDOR
    p_data->>'notas', p_data->>'cp', p_data->>'colonia', p_data->>'municipio',
    p_data->>'estado', p_data->>'direccion', p_data->>'coordenadas',
    COALESCE(p_data->>'zonaEntrega', 'cdmx'),
    p_data->>'stripePaymentId',
    v_cod_cupon,
    v_tipo_int,
    NULLIF(v_idempotency, '')
  ) RETURNING id INTO v_id_orden;

  -- ── 8) Líneas, con los precios recotizados ──────────────────────────────
  FOR v_producto IN SELECT * FROM jsonb_array_elements(v_calc) LOOP
    INSERT INTO ordenes_detalle (
      id_orden, consecutivo_orden,
      id_producto, sabor, presentacion, tipo_venta,
      cantidad, gramos_vendidos, precio_unitario, descuento, subtotal, precio_kg, notas_linea
    ) VALUES (
      v_id_orden, v_consec,
      v_producto->>'idProducto', v_producto->>'sabor', v_producto->>'presentacion',
      v_producto->>'tipoVenta',
      (v_producto->>'cantidad')::NUMERIC,
      (v_producto->>'gramos')::NUMERIC,
      (v_producto->>'precio')::NUMERIC,
      0,
      (v_producto->>'subtotal')::NUMERIC,
      (v_producto->>'precioKg')::NUMERIC,
      NULL
    );
    v_filas_det := v_filas_det + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'idOrden', v_id_orden,
    'consecutivo', v_consec,
    'lineas', v_filas_det,
    'total', v_total,
    'nivelPrecio', v_nivel,
    'puntosAcumulados', 0
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

alter function public.crear_pedido(jsonb) owner to postgres;

comment on function public.crear_pedido(jsonb) is
  'Crea un pedido. EXIGE sesión (cliente por OTP o vendedor). El precio de cada línea se recotiza contra el catálogo según el nivel que corresponde a quien pide; el cupón se valida con validar_cupon; el total se compara con el declarado y se rechaza si no cuadra. El navegador ya no decide dinero. Reescrita 6 sep 2026 — ver cambios/2026-09-05-precio-lo-decide-el-navegador.md.';
