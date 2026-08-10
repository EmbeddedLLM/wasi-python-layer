#!/usr/bin/env node
// Run a wasm32-wasip1 module under Node's WASI (preview1) and let its stdout
// flow to the parent. Used to execute CLAPACK's `arithchk.c` (target-accurate
// arith.h generation) — the wasip2 build output cannot be executed by Node,
// so the helper module is compiled with --target=wasm32-wasip1.
//
// Usage: node run-wasi-preview1.js <module.wasm>
const fs = require('fs');
const { WASI } = require('node:wasi');

const wasi = new WASI({ version: 'preview1', args: [], env: {}, preopens: {} });

(async () => {
  const buf = fs.readFileSync(process.argv[2]);
  const mod = await WebAssembly.compile(buf);
  const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
  wasi.start(inst);
})().catch((e) => {
  console.error('WASI preview1 run failed:', e);
  process.exit(1);
});
