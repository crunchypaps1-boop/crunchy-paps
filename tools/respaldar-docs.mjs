#!/usr/bin/env node
// tools/respaldar-docs.mjs — Copia los documentos internos al repo PRIVADO.
//
// Los cuatro archivos viven en esta carpeta, que es donde Claude Code los lee,
// y están fuera del repositorio público a propósito. Hasta que existió el repo
// privado, existían SOLO en esta máquina: un disco que fallara se llevaba toda
// la memoria del proyecto.
//
// Uso:  node tools/respaldar-docs.mjs
//       node tools/respaldar-docs.mjs --revisar    (solo dice qué cambió)
//
// Correrlo al terminar una sesión de trabajo.

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';

const ORIGEN  = 'C:\\Proyectos\\crunchy-paps';
const DESTINO = 'C:\\Proyectos\\crunchy-paps-docs';
const FIJOS   = ['.claude/agents/altas-b2b.md', 'PLAN.md', 'PROGRESO.md', 'ACCESOS.md', 'DESPLIEGUE.md', 'CLAUDE.md'];

// `cambios/` es una CARPETA que crece: un archivo por cambio (PLAN.md §1.5).
// Se recorre en vez de enumerarse, porque una lista fija habría que acordarse de
// actualizar en cada cambio nuevo — y lo que hay que acordarse de hacer, no se
// hace. Si la carpeta no existe todavía, no pasa nada.
const CAMBIOS = 'cambios';
const listarCambios = () => {
  const dir = join(ORIGEN, CAMBIOS);
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((n) => n.endsWith('.md'))
    .sort()
    .map((n) => `${CAMBIOS}/${n}`);
};

const DOCS = [...FIJOS, ...listarCambios()];

const soloRevisar = process.argv.includes('--revisar');

if (!existsSync(DESTINO)) {
  console.error(`No existe ${DESTINO}.`);
  console.error('Clónalo primero:  git clone https://github.com/abr-m-m/crunchy-paps-docs.git');
  process.exit(1);
}

const git = (...args) =>
  execFileSync('git', args, { cwd: DESTINO, encoding: 'utf8' }).trim();

// Salvaguarda: si el repo de destino no fuera privado, esto publicaría el
// inventario de seguridad y la bitácora de vulnerabilidades.
try {
  const url = git('remote', 'get-url', 'origin');
  if (!url.includes('crunchy-paps-docs')) {
    console.error('ABORTADO: el remoto de destino no es crunchy-paps-docs.');
    console.error('  ' + url);
    process.exit(1);
  }
} catch {
  console.error('ABORTADO: el destino no tiene remoto configurado.');
  process.exit(1);
}

let copiados = 0;
const cambios = [];
for (const doc of DOCS) {
  const origen = join(ORIGEN, doc);
  if (!existsSync(origen)) { console.log(`  ${doc.padEnd(42)} no está en el origen, se omite`); continue; }
  const nuevo = readFileSync(origen);
  const destino = join(DESTINO, doc);
  const viejo = existsSync(destino) ? readFileSync(destino) : null;
  if (viejo && viejo.equals(nuevo)) { console.log(`  ${doc.padEnd(42)} sin cambios`); continue; }
  const lineas = nuevo.toString('utf8').split('\n').length;
  const antes  = viejo ? viejo.toString('utf8').split('\n').length : 0;
  // "nuevo líneas" se leía mal en la salida; un archivo que no existía antes
  // dice cuántas trae, no cuántas cambió.
  const delta  = viejo ? (lineas - antes >= 0 ? '+' : '') + (lineas - antes) + ' líneas'
                       : `nuevo (${lineas} líneas)`;
  cambios.push(`${doc} (${delta} líneas)`);
  console.log(`  ${doc.padEnd(42)} ${delta}`);
  if (!soloRevisar) { mkdirSync(dirname(destino), { recursive: true }); writeFileSync(destino, nuevo); copiados++; }
}

if (!cambios.length) { console.log('\n  Todo al día. Nada que respaldar.'); process.exit(0); }
if (soloRevisar)     { console.log(`\n  ${cambios.length} archivo(s) cambiarían. Corre sin --revisar para subirlos.`); process.exit(0); }

git('add', '-A');
// Fecha LOCAL (CDMX), no UTC. `toISOString()` fechaba los respaldos hechos de
// noche en el día siguiente: así nacieron los "Respaldo 2026-09-02" de commits
// del 1 de septiembre, y de ahí los encabezados equivocados de PROGRESO.md.
const d = new Date();
const fecha = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
git('-c', 'user.email=abraham.mmora@gmail.com', '-c', 'user.name=Abraham',
    'commit', '-q', '-m', `Respaldo ${fecha}: ${cambios.join(', ')}`);
execFileSync('git', ['push', '-q'], { cwd: DESTINO, stdio: 'inherit' });

console.log(`\n  ${copiados} archivo(s) respaldados y subidos a crunchy-paps-docs (privado).`);
