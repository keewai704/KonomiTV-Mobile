// Builds the single self-contained page script of the data broadcasting view.
//
//   node esbuild.config.mjs           # bundle into App/KonomiTV/Resources/BML
//   node esbuild.config.mjs --dev     # unminified, with inline source maps
//
// The output is committed: the iOS CI has no Node toolchain, so the app bundle
// always ships a prebuilt page. web-bml and esbuild are pinned in
// package-lock.json, so the same sources produce the same bundle.

import { copyFile, mkdir } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import * as esbuild from 'esbuild'

const here = dirname(fileURLToPath(import.meta.url))
const outputDirectory = resolve(here, '..', 'App', 'KonomiTV', 'Resources', 'BML')
const development = process.argv.includes('--dev')

await mkdir(resolve(outputDirectory, 'fonts'), { recursive: true })

await esbuild.build({
  entryPoints: [resolve(here, 'src', 'main.ts')],
  outfile: resolve(outputDirectory, 'bml.js'),
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: ['safari17'],
  minify: !development,
  sourcemap: development ? 'inline' : false,
  legalComments: 'none',
  logLevel: 'info',
})

// The page and the fonts web-bml renders with are copied next to the bundle.
// Kosugi / Kosugi Maru are Fontworks' fonts, distributed under the Apache
// License 2.0 (see fonts/LICENSE.txt); web-bml is MIT.
for (const file of ['index.html']) {
  await copyFile(resolve(here, 'src', file), resolve(outputDirectory, file))
}
for (const file of [
  'Kosugi-Regular.woff2',
  'KosugiMaru-Regular.woff2',
  'LICENSE.txt',
  'AUTHORS.txt',
  'CONTRIBUTORS.txt',
]) {
  await copyFile(resolve(here, 'fonts', file), resolve(outputDirectory, 'fonts', file))
}

console.log(`BML bundle written to ${outputDirectory}`)
