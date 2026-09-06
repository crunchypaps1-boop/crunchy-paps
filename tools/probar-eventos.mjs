#!/usr/bin/env node
// tools/probar-eventos.mjs — Comprueba la cola de eventos de §3.3 ejerciendo el
// código REAL de index.html: `supabaseCall` y el bloque de la cola se RECORTAN
// del archivo y se ejecutan tal cual, con un andamio mínimo que suple lo que da
// el navegador (document, sessionStorage, location).
//
// Recortar en vez de reescribir es lo que hace que esto valga algo: una copia
// del código dentro de la prueba solo demuestra que la copia funciona.
//
// Qué mide, que es exactamente lo que §3.3 prometió:
//   1. que los eventos NO salen de uno en uno,
//   2. que descargan en los cuatro momentos (20 · 5 s · purchase · pestaña oculta),
//   3. que el número de filas escritas coincide con los eventos disparados,
//   4. que los huecos de tiempo entre eventos SOBREVIVEN al viaje en lote.
//
// El punto 3 se lee de `insertados`, que devuelve el propio RPC: la tabla
// `eventos_navegacion` no se puede leer con la llave pública, y abrirle un
// camino de lectura para poder probarla sería pagar un agujero por una prueba.
//
// Uso:
//   SUPABASE_URL=https://<ref>.supabase.co SUPABASE_KEY=<llave> \
//     node tools/probar-eventos.mjs
//
// Sale con código 1 si algo falla. Tarda ~15 s: hay esperas reales de reloj.

import fs from 'node:fs';

const URL_BASE = process.env.SUPABASE_URL;
const LLAVE = process.env.SUPABASE_KEY
  || process.env.SUPABASE_PUBLISHABLE_KEY
  || process.env.SUPABASE_ANON_KEY;

if (!URL_BASE || !LLAVE) {
  console.error('Faltan SUPABASE_URL y/o SUPABASE_KEY en el entorno.');
  process.exit(1);
}
// Esto ESCRIBE en eventos_navegacion. Contra producción, nunca.
if (URL_BASE.includes('xbyzarzyxiugrucyjwfn')) {
  console.error('ABORTADO: esto apunta a PRODUCCIÓN y escribe eventos de prueba.');
  process.exit(1);
}

const html = fs.readFileSync('index.html', 'utf8');
const recortar = (desde, hasta) => {
  const a = html.indexOf(desde);
  const b = html.indexOf(hasta, a);
  if (a < 0 || b < 0) {
    console.error('No se pudo recortar el código de index.html. Si el archivo cambió,');
    console.error('actualiza las anclas de esta prueba: ' + JSON.stringify(desde.slice(0, 40)));
    process.exit(1);
  }
  return html.slice(a, b);
};

const fuenteLlamada = recortar(
  'async function supabaseCall(method, path, body, opciones) {',
  '// Helper para cargar el catálogo');
const fuenteCola = recortar('const EV_LOTE_MAX', '// GA4 User-ID:');

// Lo que el navegador da y Node no. `document.addEventListener` guarda el
// oyente para poder simular después que la pestaña se oculta.
const andamio = [
  'const SUPABASE_URL = ' + JSON.stringify(URL_BASE) + ';',
  'const SUPABASE_ANON_KEY = ' + JSON.stringify(LLAVE) + ';',
  'const PERF = { enabled: false };',
  'const perfPush = () => {};',
  'const tokenVendedor = () => "";',
  'let clienteActual = null;',
  'const location = { pathname: "/prueba", search: "" };',
  'const sessionStorage = { getItem: (k) => ({ cp_sid: "prueba-cola", utm_source: "ig" })[k] || "" };',
  'const document = {',
  '  visibilityState: "visible",',
  '  addEventListener: (_n, f) => { globalThis.__oyenteVisibilidad = f; },',
  '};',
  'const window = {};',
  // Doble de la costura window.cpAtribucion. La FUNCIÓN real se prueba aparte,',
  '// recortada del bloque de arranque; aquí solo se comprueba que track() la usa.',
  'window.cpAtribucion = (cual) => cual === "first"',
  '  ? { utm_source: "ig", utm_campaign: "lanzamiento", t: Date.now() - 3 * 86400000 }',
  '  : { utm_source: "fb", utm_campaign: "retargeting", t: Date.now() };',
  '',
].join('\n');

const cola = [
  'export { track, _evCola };',
  'export const ocultarPestana = () => {',
  '  document.visibilityState = "hidden";',
  '  globalThis.__oyenteVisibilidad();',
  '};',
].join('\n');

const fuente = andamio + fuenteLlamada + fuenteCola + '\n' + cola;
const mod = await import('data:text/javascript;base64,' +
  Buffer.from(fuente).toString('base64')).catch((e) => {
    console.error('El código recortado de index.html no compila: ' + e.message);
    process.exit(1);
  });

// ── Contador de peticiones ────────────────────────────────────────────────
// Se cuenta al SALIR, no al volver. Contar a la vuelta produjo un falso
// negativo la primera vez: a los 5,2 s la petición ya había salido y la
// respuesta aún no estaba, y la prueba leyó cero peticiones.
let peticiones = 0, filas = 0, respuestas = [];
const fetchReal = globalThis.fetch;
globalThis.fetch = async (u, o) => {
  peticiones++;
  const r = await fetchReal(u, o);
  const cuerpo = await r.clone().json().catch(() => null);
  if (cuerpo && cuerpo.insertados) filas += cuerpo.insertados;
  let enviados = [];
  try { enviados = JSON.parse(o.body).p_data.eventos || []; } catch (_e) {}
  respuestas.push({ ruta: String(u).split('/rpc/')[1], keepalive: !!o.keepalive, cuerpo, enviados });
  return r;
};
const reiniciar = () => { peticiones = 0; filas = 0; respuestas = []; };

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));
// Sondea hasta que hayan vuelto n respuestas. Un sleep fijo aquí es una carrera.
async function esperar(n, msMax) {
  const fin = Date.now() + msMax;
  while (respuestas.length < n && Date.now() < fin) await dormir(100);
  await dormir(150);
}

const pruebas = [];
const comprobar = (nombre, ok, detalle) => pruebas.push({ nombre, ok, detalle });

console.log('\nCola de eventos §3.3 — código real de index.html contra ' + URL_BASE + '\n');

// ── 1. Eventos sueltos: esperan al temporizador, no salen de uno en uno ──
mod.track('page_view', {});
mod.track('view_item', { id: 1 });
await dormir(300);                       // hueco real que debe sobrevivir al lote
mod.track('add_to_cart', { id: 1 });
comprobar('3 eventos, 0 peticiones antes de los 5 s', peticiones === 0,
          'peticiones=' + peticiones);

await esperar(1, 9000);
comprobar('a los 5 s sale UNA petición con los 3', peticiones === 1 && filas === 3,
          'peticiones=' + peticiones + ' filas=' + filas);
comprobar('va al RPC plural, con keepalive',
          respuestas[0]?.ruta === 'registrar_eventos' && respuestas[0]?.keepalive === true,
          respuestas[0]?.ruta + ' keepalive=' + respuestas[0]?.keepalive);
{
  // El corazón del diseño: si este hueco se aplasta a 0, el embudo miente.
  const ms = new Date(respuestas[0]?.cuerpo?.hasta) - new Date(respuestas[0]?.cuerpo?.desde);
  comprobar('el hueco real de 300 ms se conserva', ms >= 250 && ms <= 450, 'hueco=' + ms + ' ms');
}

// ── 2. Descarga por tamaño ──
reiniciar();
for (let i = 0; i < 20; i++) mod.track('scroll_' + i, {});
await esperar(1, 9000);
comprobar('a los 20 descarga sin esperar los 5 s', peticiones === 1 && filas === 20,
          'peticiones=' + peticiones + ' filas=' + filas);

// ── 3. purchase, el que más duele perder ──
reiniciar();
mod.track('view_cart', {});
mod.track('purchase', { valor: 250 });
await esperar(1, 9000);
comprobar('purchase no espera: sale ya, con el que traía', peticiones === 1 && filas === 2,
          'peticiones=' + peticiones + ' filas=' + filas);

// ── 4. La pestaña se oculta: salva las sesiones que terminan sin compra ──
reiniciar();
mod.track('abandono', {});
mod.ocultarPestana();
await esperar(1, 9000);
comprobar('al ocultarse la pestaña descarga lo pendiente', peticiones === 1 && filas === 1,
          'peticiones=' + peticiones + ' filas=' + filas);

// ── 5. La cuenta que resume §3.3 ──
reiniciar();
for (let i = 0; i < 26; i++) mod.track('embudo_' + i, {});
await esperar(2, 12000);
comprobar('26 eventos = 2 peticiones, 26 filas (antes: 26 peticiones)',
          peticiones === 2 && filas === 26,
          'peticiones=' + peticiones + ' filas=' + filas);

// ── La atribución: código real del BLOQUE DE ARRANQUE ─────────────────────
// Se recorta igual que la cola, y se envuelve en visitar(qs) para poder simular
// varias llegadas. El almacén es un Map: si fuera sessionStorage de verdad, esto
// no probaría nada — el fallo que se corrige es justamente que moría con él.
const fuenteAtrib = recortar('var CP_UTM_DIAS = 30;', '// id de sesión first-party');

const atrib = await import('data:text/javascript;base64,' + Buffer.from([
  'export const almacen = new Map();',
  'const localStorage = {',
  '  getItem: (k) => (almacen.has(k) ? almacen.get(k) : null),',
  '  setItem: (k, v) => almacen.set(k, String(v)),',
  '};',
  'export const window = {};',
  'let location = { search: "" };',
  'export function visitar(qs) {',
  '  location = { search: qs };',
  fuenteAtrib,
  '}',
].join(String.fromCharCode(10))).toString('base64'));

const dias = (n) => n * 86400000;

atrib.visitar('?utm_source=ig&utm_medium=social&utm_campaign=lanzamiento');
comprobar('llegada con UTM: se guardan primera y última',
  atrib.window.cpAtribucion('first').utm_campaign === 'lanzamiento' &&
  atrib.window.cpAtribucion('last').utm_campaign === 'lanzamiento',
  'first=' + atrib.window.cpAtribucion('first').utm_campaign);

// Cerrar la pestaña y volver: sessionStorage se habría vaciado. El almacén no.
atrib.visitar('');
comprobar('vuelve SIN UTM: la atribución sobrevive',
  atrib.window.cpAtribucion('first').utm_source === 'ig' &&
  atrib.window.cpAtribucion('last').utm_source === 'ig',
  'first=' + atrib.window.cpAtribucion('first').utm_source);

atrib.visitar('?utm_source=fb&utm_campaign=retargeting');
comprobar('segunda campaña: cambia la última, NO la primera',
  atrib.window.cpAtribucion('first').utm_campaign === 'lanzamiento' &&
  atrib.window.cpAtribucion('last').utm_campaign === 'retargeting',
  'first=' + atrib.window.cpAtribucion('first').utm_campaign +
  ' last=' + atrib.window.cpAtribucion('last').utm_campaign);

// Envejecer la primera 31 días: fuera de ventana es como si no hubiera nada.
{
  const o = JSON.parse(atrib.almacen.get('cp_utm_first'));
  o.t = Date.now() - dias(31);
  atrib.almacen.set('cp_utm_first', JSON.stringify(o));
}
comprobar('a los 31 días la primera deja de contar',
  !atrib.window.cpAtribucion('first').utm_source, 'vencida');

atrib.visitar('?utm_source=tiktok&utm_campaign=reto');
comprobar('con la ventana vencida, una llegada nueva reinicia la primera',
  atrib.window.cpAtribucion('first').utm_campaign === 'reto',
  'first=' + atrib.window.cpAtribucion('first').utm_campaign);

comprobar('una llegada sin UTM nunca borra lo guardado',
  (atrib.visitar('?otra=cosa'),
   atrib.window.cpAtribucion('first').utm_campaign === 'reto'), 'intacta');

// ── track() usa la costura: última en las columnas, primera en purchase ──
reiniciar();
mod.track('view_item', { id: 1 });
mod.track('purchase', { valor: 250 });
await esperar(1, 9000);
{
  const ev = respuestas[0]?.enviados || [];
  const vista = ev.find((e) => e.evento === 'view_item');
  const compra = ev.find((e) => e.evento === 'purchase');
  comprobar('las columnas utm_* llevan la ÚLTIMA atribución',
    vista?.utmSource === 'fb' && vista?.utmCampaign === 'retargeting',
    'utmSource=' + vista?.utmSource);
  comprobar('purchase lleva además la PRIMERA, dentro de params',
    compra?.params?.utm_first_campaign === 'lanzamiento' &&
    compra?.params?.utm_first_dias === 3,
    'first=' + compra?.params?.utm_first_campaign +
    ' dias=' + compra?.params?.utm_first_dias);
  comprobar('los eventos que no son purchase NO cargan la primera',
    vista?.params?.utm_first_campaign === undefined, 'limpio');
}

let fallos = 0;
for (const p of pruebas) {
  if (!p.ok) fallos++;
  console.log('  ' + (p.ok ? 'ok   ' : 'FALLA') + ' ' + p.nombre.padEnd(54) + ' ' + p.detalle);
}
console.log(fallos ? '\n' + fallos + ' de ' + pruebas.length + ' fallando.\n'
                   : '\nLas ' + pruebas.length + ' comprobaciones pasan.\n');
process.exit(fallos ? 1 : 0);
