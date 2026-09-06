#!/usr/bin/env node
// tools/probar-perfiles.mjs — Los cinco perfiles de cliente, de punta a punta.
//
// Crea un cliente de cada tipo, lo aprueba, le emite sesión SIN gastar un SMS
// (atajo de staging anclado a la tabla centinela `_entorno`) y comprueba QUÉ
// PRECIO le calcula el servidor al pedir.
//
// Existe porque esa rama —traducir el `tipo_id` de un cliente verificado a su
// columna de precio, en `crear_pedido`— no se podía ejecutar de ninguna otra
// forma: `emitir_sesion_cliente` es solo `service_role`, y con razón.
//
// El caso que cierra el argumento es el último: un consumidor que se DECLARA
// mayorista sigue pagando precio de consumidor. El nivel sale de lo que el
// servidor sabe de quien pide, no de lo que dice el navegador.
//
// Uso:
//   SUPABASE_URL=https://<ref>.supabase.co SUPABASE_KEY=<llave publishable>
//     node tools/probar-perfiles.mjs
//
// Sale con código 1 si algún perfil paga un precio que no le toca.

const URL_BASE = process.env.SUPABASE_URL;
const LLAVE = process.env.SUPABASE_KEY || process.env.SUPABASE_PUBLISHABLE_KEY;

if (!URL_BASE || !LLAVE) {
  console.error('Faltan SUPABASE_URL y/o SUPABASE_KEY en el entorno.');
  process.exit(1);
}
// ESCRIBE: crea clientes y pedidos. Contra producción, nunca.
if (URL_BASE.includes('xbyzarzyxiugrucyjwfn')) {
  console.error('ABORTADO: esto apunta a PRODUCCIÓN y crea clientes y pedidos.');
  process.exit(1);
}

const H = { apikey: LLAVE, Authorization: 'Bearer ' + LLAVE, 'Content-Type': 'application/json' };
const rpc = async (n, d) =>
  (await fetch(URL_BASE + '/rest/v1/rpc/' + n, { method: 'POST', headers: H, body: JSON.stringify(d) })).json();

const v = await rpc('validar_vendedor_pin', { p_data: { telefono: '5500000001', pin: '1234' } });
const TK = v.token;
if (!TK) { console.error('Sin token de vendedor. ¿Está sembrado el staging?'); process.exit(1); }

const cat = await (await fetch(
  URL_BASE + '/rest/v1/productos?select=id,sabor,presentacion,precio_consumidor,' +
  'precio_tienda,precio_restaurante,precio_mayorista&limit=1', { headers: H })).json();
if (!Array.isArray(cat) || !cat.length) { console.error('Sin catálogo.'); process.exit(1); }
const p = cat[0];

console.log('\nCinco perfiles contra ' + URL_BASE);
console.log('\nProducto: ' + p.sabor + ' · ' + p.presentacion);
console.log('  consumidor $' + p.precio_consumidor + ' · tienda $' + p.precio_tienda +
            ' · restaurante $' + p.precio_restaurante +
            ' · mayorista ' + (Number(p.precio_mayorista) > 0 ? '$' + p.precio_mayorista
                                                              : '$0 → puente a tienda'));

const PERFILES = [
  { nombre: 'Consumidor Prueba',  tel: '5591000001', tipoId: 1, tipo: 'consumidor',
    esperado: Number(p.precio_consumidor) },
  { nombre: 'Restaurante Prueba', tel: '5591000002', tipoId: 2, tipo: 'restaurante',
    esperado: Number(p.precio_restaurante) },
  { nombre: 'Tienda Prueba',      tel: '5591000003', tipoId: 3, tipo: 'tienda',
    esperado: Number(p.precio_tienda) },
  { nombre: 'Mayorista Prueba',   tel: '5591000004', tipoId: 4, tipo: 'mayorista',
    esperado: Number(p.precio_mayorista) > 0 ? Number(p.precio_mayorista) : Number(p.precio_tienda) },
];

const pruebas = [];
console.log('\nCada perfil pide 10 piezas; se mira qué total calcula el SERVIDOR:\n');

for (const perfil of PERFILES) {
  await rpc('registrar_o_actualizar_cliente', {
    p_data: { token: TK, nombre: perfil.nombre, telefono: perfil.tel, tipoId: perfil.tipoId },
  });

  const cli = await rpc('buscar_clientes', { p_data: { token: TK, q: perfil.tel } });
  const encontrado = (cli.clientes || [])[0];

  if (encontrado && perfil.tipoId > 1) {
    // Argumentos POSICIONALES, no `p_data`: la firma real es
    // aprobar_cliente_b2b(p_id_cliente, p_aprobar, p_actor, p_token).
    // La primera versión de esta prueba usó `p_data`, PostgREST no encontró la
    // función, y el script siguió como si nada porque no miraba la respuesta —
    // y los tres perfiles B2B salieron en rojo culpando al código, que estaba
    // bien. Por eso ahora la aprobación falla en voz alta.
    const ap = await rpc('aprobar_cliente_b2b',
      { p_id_cliente: encontrado.id, p_aprobar: true, p_actor: 'prueba', p_token: TK });
    if (!ap || ap.ok !== true) {
      console.log('  ' + perfil.tipo.padEnd(12) + ' NO SE PUDO APROBAR: ' +
                  JSON.stringify(ap).slice(0, 110));
    }
  }

  const ses = await rpc('emitir_sesion_prueba', { p_telefono: perfil.tel });
  if (!ses.ok) {
    console.log('  FALLA ' + perfil.tipo.padEnd(12) + ' no se pudo emitir sesión: ' +
                JSON.stringify(ses).slice(0, 110));
    pruebas.push(false);
    continue;
  }

  const esperadoTotal = 10 * perfil.esperado;
  const r = await rpc('crear_pedido', { p_data: {
    tokenCliente: ses.token,
    nombre: perfil.nombre, telefono: perfil.tel,
    total: esperadoTotal,
    productos: [{ idProducto: String(p.id), sabor: p.sabor, presentacion: p.presentacion,
                  tipoVenta: 'Por Pieza', cantidad: 10, gramos: 0 }],
    idempotencyKey: 'perf-' + perfil.tipo + '-' + Date.now(),
  } });

  const ok = r.ok === true && Number(r.total) === esperadoTotal && r.nivelPrecio === perfil.tipo;
  pruebas.push(ok);
  console.log('  ' + (ok ? 'ok   ' : 'FALLA') + ' ' + perfil.tipo.padEnd(12) +
              ' esperado $' + esperadoTotal + ' · servidor ' +
              (r.ok ? '$' + r.total + ' nivel=' + r.nivelPrecio
                    : JSON.stringify(r).slice(0, 90)));
}

// El caso que cierra el argumento: el nivel NO se lo elige quien pide.
const ses = await rpc('emitir_sesion_prueba', { p_telefono: '5591000001' });
const precioMay = Number(p.precio_mayorista) > 0 ? Number(p.precio_mayorista) : Number(p.precio_tienda);
const trampa = await rpc('crear_pedido', { p_data: {
  tokenCliente: ses.token, tipoCliente: 'mayorista',
  nombre: 'Consumidor Prueba', telefono: '5591000001',
  total: 10 * precioMay,
  productos: [{ idProducto: String(p.id), sabor: p.sabor, presentacion: p.presentacion,
                tipoVenta: 'Por Pieza', cantidad: 10, gramos: 0 }],
  idempotencyKey: 'trampa-' + Date.now(),
} });
const okTrampa = trampa.ok === false && trampa.error === 'precio_cambiado' &&
                 Number(trampa.totalCorrecto) === 10 * Number(p.precio_consumidor);
pruebas.push(okTrampa);
console.log('\n  ' + (okTrampa ? 'ok   ' : 'FALLA') +
            ' un consumidor que se DECLARA mayorista paga de consumidor · ' +
            (trampa.error || 'ACEPTADO') +
            (trampa.totalCorrecto ? ' correcto=$' + trampa.totalCorrecto : ''));

const fallos = pruebas.filter((x) => !x).length;
console.log(fallos ? '\n' + fallos + ' de ' + pruebas.length + ' fallando\n'
                   : '\nLas ' + pruebas.length + ' comprobaciones pasan.\n');
process.exit(fallos ? 1 : 0);
