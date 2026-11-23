// Run the wasm32 frontend in Node through crystal_wasi.mjs (no other WASI host).
// usage: node run_node.mjs <frontend.wasm> <bundle.json> -- <frontend args...>
import { readFileSync } from "node:fs";
import { MemoryFileSystem, WasiHost } from "./crystal_wasi.mjs";

const separator = process.argv.indexOf("--");
const [wasmPath, bundlePath] = process.argv.slice(2, separator);
const frontendArgs = process.argv.slice(separator + 1);

const started = performance.now();
const fs = new MemoryFileSystem();
const loaded = fs.loadBundle(JSON.parse(readFileSync(bundlePath, "utf8")));
fs.mkdirs("/cache");
const compileStart = performance.now();
const module = await WebAssembly.compile(readFileSync(wasmPath));
const compileMs = performance.now() - compileStart;

const host = new WasiHost({
  args: ["crystal-frontend", ...frontendArgs],
  env: { CRYSTAL_PATH: process.env.FRONTEND_CRYSTAL_PATH || "/src", CRYSTAL_CACHE_DIR: "/cache", HOME: "/cache" },
  fs,
  stdout: (bytes) => process.stdout.write(bytes),
  stderr: (bytes) => process.stderr.write(bytes),
});
const runStart = performance.now();
const code = await host.run(module);
const runMs = performance.now() - runStart;
console.error(JSON.stringify({
  exit_code: code, bundle_files: loaded.files, bundle_bytes: loaded.bytes,
  module_compile_ms: Math.round(compileMs), run_ms: Math.round(runMs), total_ms: Math.round(performance.now() - started),
  linear_memory_bytes: host.memory.buffer.byteLength, node_rss_bytes: process.memoryUsage().rss,
}));
process.exit(code);
