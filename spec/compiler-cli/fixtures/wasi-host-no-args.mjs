// A minimal WASI host that reports zero program arguments (argc 0), as many
// browser hosts do. It runs the module named by its first argument, sends the
// module's stdout and stderr to its own, and exits with the module's status.
//
// Usage: deno run --allow-read wasi-host-no-args.mjs <program.wasm>
const bytes = await Deno.readFile(Deno.args[0]);
let memory;
const view = () => new DataView(memory.buffer);
class Exit extends Error {
  constructor(code) { super(`exit ${code}`); this.code = code; }
}
const streams = { 1: Deno.stdout, 2: Deno.stderr };
const ERRNO_BADF = 8, ERRNO_NOSYS = 52;

const wasi = {
  args_sizes_get: (count, size) => { view().setUint32(count, 0, true); view().setUint32(size, 0, true); return 0; },
  args_get: () => 0,
  environ_sizes_get: (count, size) => { view().setUint32(count, 0, true); view().setUint32(size, 0, true); return 0; },
  environ_get: () => 0,
  clock_time_get: (id, precision, result) => {
    const nanoseconds = id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6));
    view().setBigUint64(result, nanoseconds, true);
    return 0;
  },
  clock_res_get: (id, result) => { view().setBigUint64(result, 1000n, true); return 0; },
  fd_fdstat_get: (fd, result) => {
    if (!(fd in streams) && fd !== 0) return ERRNO_BADF;
    new Uint8Array(memory.buffer, result, 24).fill(0);
    view().setUint8(result, 2); // character device
    return 0;
  },
  fd_fdstat_set_flags: () => 0,
  fd_filestat_get: (fd, result) => { new Uint8Array(memory.buffer, result, 64).fill(0); view().setUint8(result + 16, 2); return 0; },
  fd_prestat_get: () => ERRNO_BADF,
  fd_prestat_dir_name: () => ERRNO_BADF,
  fd_close: () => 0,
  fd_seek: () => 70, // ESPIPE
  fd_read: (fd, iovs, count, read) => { view().setUint32(read, 0, true); return 0; },
  fd_write: (fd, iovs, count, written) => {
    const stream = streams[fd];
    if (!stream) return ERRNO_BADF;
    let total = 0;
    for (let i = 0; i < count; i++) {
      const base = view().getUint32(iovs + i * 8, true);
      const length = view().getUint32(iovs + i * 8 + 4, true);
      const chunk = new Uint8Array(memory.buffer, base, length).slice();
      for (let offset = 0; offset < chunk.length;) offset += stream.writeSync(chunk.subarray(offset));
      total += length;
    }
    view().setUint32(written, total, true);
    return 0;
  },
  proc_exit: (code) => { throw new Exit(code); },
  random_get: (pointer, length) => { crypto.getRandomValues(new Uint8Array(memory.buffer, pointer, length)); return 0; },
  sched_yield: () => 0,
};
const imports = {
  wasi_snapshot_preview1: new Proxy(wasi, { get: (target, name) => target[name] ?? (() => ERRNO_NOSYS) }),
};

const { instance } = await WebAssembly.instantiate(bytes, imports);
memory = instance.exports.memory;
try {
  instance.exports._start();
} catch (error) {
  if (error instanceof Exit) Deno.exit(error.code);
  console.error(`host: ${error}`);
  Deno.exit(70);
}
Deno.exit(0);
