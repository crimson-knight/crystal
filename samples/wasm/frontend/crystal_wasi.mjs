// A WASI preview 1 host for the Crystal frontend (type checker) compiled to
// wasm32-wasi, written from the WASI preview 1 specification
// (https://github.com/WebAssembly/WASI/blob/main/legacy/preview1/docs.md).
//
// It runs in a browser or in Node. Files live in memory: a bundle (the std
// library, the program's shards and the program) is loaded read-only, and any
// directory the program creates (the compiler's cache dir) is writable. One
// preopened directory, "/", holds everything.
//
// Only the 22 functions the frontend imports are implemented.

const ERRNO = { SUCCESS: 0, BADF: 8, EXIST: 20, INVAL: 28, ISDIR: 31, NOENT: 44, NOTDIR: 54, NOTEMPTY: 55 };
const FILETYPE = { UNKNOWN: 0, CHARACTER_DEVICE: 2, DIRECTORY: 3, REGULAR_FILE: 4 };
const OFLAGS = { CREAT: 1, DIRECTORY: 2, EXCL: 4, TRUNC: 8 };
const FDFLAGS_APPEND = 1;
const ALL_RIGHTS = 0x1fffffffn;

export class ProcessExit extends Error {
  constructor(code) {
    super(`exit ${code}`);
    this.code = code;
  }
}

// The in-memory file system: a map from absolute path to node.
export class MemoryFileSystem {
  constructor() {
    this.nodes = new Map([["/", { type: "dir", ino: 1 }]]);
    this.nextIno = 2;
  }

  static normalize(path) {
    const parts = [];
    for (const part of path.split("/")) {
      if (part === "" || part === ".") continue;
      if (part === "..") parts.pop();
      else parts.push(part);
    }
    return "/" + parts.join("/");
  }

  static parent(path) {
    const index = path.lastIndexOf("/");
    return index <= 0 ? "/" : path.slice(0, index);
  }

  mkdirs(path) {
    path = MemoryFileSystem.normalize(path);
    if (this.nodes.has(path)) return this.nodes.get(path);
    this.mkdirs(MemoryFileSystem.parent(path));
    const node = { type: "dir", ino: this.nextIno++ };
    this.nodes.set(path, node);
    return node;
  }

  writeFile(path, bytes) {
    path = MemoryFileSystem.normalize(path);
    this.mkdirs(MemoryFileSystem.parent(path));
    const node = { type: "file", ino: this.nextIno++, data: bytes, size: bytes.length };
    this.nodes.set(path, node);
    return node;
  }

  // Loads a bundle: { "files": { "/abs/path": "utf-8 text", ... } }.
  loadBundle(bundle) {
    const encoder = new TextEncoder();
    let bytes = 0;
    for (const [path, text] of Object.entries(bundle.files)) {
      const data = encoder.encode(text);
      bytes += data.length;
      this.writeFile(path, data);
    }
    return { files: Object.keys(bundle.files).length, bytes };
  }

  children(path) {
    const prefix = path === "/" ? "/" : path + "/";
    const names = [];
    for (const key of this.nodes.keys()) {
      if (key !== path && key.startsWith(prefix) && !key.slice(prefix.length).includes("/")) {
        names.push(key.slice(prefix.length));
      }
    }
    return names.sort();
  }
}

export class WasiHost {
  constructor({ args, env, fs, stdout, stderr }) {
    this.args = args;
    this.env = Object.entries(env).map(([key, value]) => `${key}=${value}`);
    this.fs = fs;
    this.stdout = stdout;
    this.stderr = stderr;
    this.memory = null;
    this.decoder = new TextDecoder();
    this.encoder = new TextEncoder();
    // fd 0..2 are stdio; fd 3 is the preopened root.
    this.fds = new Map([
      [0, { kind: "stdin" }],
      [1, { kind: "stdout" }],
      [2, { kind: "stderr" }],
      [3, { kind: "dir", path: "/", preopen: "/" }],
    ]);
    this.nextFd = 4;
    this.imports = { wasi_snapshot_preview1: this.functions() };
  }

  view() { return new DataView(this.memory.buffer); }
  bytes() { return new Uint8Array(this.memory.buffer); }
  string(ptr, len) { return this.decoder.decode(this.bytes().subarray(ptr, ptr + len)); }

  resolve(dirFd, ptr, len) {
    const dir = this.fds.get(dirFd);
    if (!dir || dir.kind !== "dir") return null;
    const relative = this.string(ptr, len);
    return MemoryFileSystem.normalize(relative.startsWith("/") ? relative : `${dir.path}/${relative}`);
  }

  writeFilestat(ptr, node) {
    const view = this.view();
    view.setBigUint64(ptr, 0n, true);
    view.setBigUint64(ptr + 8, BigInt(node.ino), true);
    view.setUint8(ptr + 16, node.type === "dir" ? FILETYPE.DIRECTORY : FILETYPE.REGULAR_FILE);
    view.setBigUint64(ptr + 24, 1n, true);
    view.setBigUint64(ptr + 32, BigInt(node.type === "dir" ? 0 : node.size), true);
    view.setBigUint64(ptr + 40, 0n, true);
    view.setBigUint64(ptr + 48, 0n, true);
    view.setBigUint64(ptr + 56, 0n, true);
  }

  // Copies the string list (args or environ) into guest memory.
  writeStrings(list, pointersPtr, bufferPtr) {
    const view = this.view();
    let offset = bufferPtr;
    list.forEach((item, index) => {
      const data = this.encoder.encode(item + "\0");
      view.setUint32(pointersPtr + index * 4, offset, true);
      this.bytes().set(data, offset);
      offset += data.length;
    });
    return ERRNO.SUCCESS;
  }

  writeSizes(list, countPtr, sizePtr) {
    const view = this.view();
    view.setUint32(countPtr, list.length, true);
    view.setUint32(sizePtr, list.reduce((sum, item) => sum + this.encoder.encode(item).length + 1, 0), true);
    return ERRNO.SUCCESS;
  }

  readIovs(iovs, count, handler) {
    const view = this.view();
    let total = 0;
    for (let index = 0; index < count; index++) {
      const ptr = view.getUint32(iovs + index * 8, true);
      const len = view.getUint32(iovs + index * 8 + 4, true);
      const done = handler(ptr, len);
      total += done;
      if (done < len) break;
    }
    return total;
  }

  fileRead(entry, iovs, count, position) {
    const data = entry.node.data;
    let pos = position;
    const total = this.readIovs(iovs, count, (ptr, len) => {
      const chunk = data.subarray(pos, Math.min(pos + len, entry.node.size));
      this.bytes().set(chunk, ptr);
      pos += chunk.length;
      return chunk.length;
    });
    return total;
  }

  fileWrite(entry, chunk) {
    const node = entry.node;
    const end = entry.pos + chunk.length;
    if (end > node.data.length) {
      const grown = new Uint8Array(Math.max(end, node.data.length * 2));
      grown.set(node.data.subarray(0, node.size));
      node.data = grown;
    }
    node.data.set(chunk, entry.pos);
    entry.pos = end;
    node.size = Math.max(node.size, end);
  }

  functions() {
    const host = this;
    return {
      args_get: (argv, buffer) => host.writeStrings(host.args, argv, buffer),
      args_sizes_get: (count, size) => host.writeSizes(host.args, count, size),
      environ_get: (environ, buffer) => host.writeStrings(host.env, environ, buffer),
      environ_sizes_get: (count, size) => host.writeSizes(host.env, count, size),

      clock_time_get(id, _precision, timePtr) {
        const nanoseconds = id === 0
          ? BigInt(Date.now()) * 1000000n
          : BigInt(Math.round(performance.now() * 1e6));
        host.view().setBigUint64(timePtr, nanoseconds, true);
        return ERRNO.SUCCESS;
      },

      random_get(ptr, len) {
        const target = host.bytes().subarray(ptr, ptr + len);
        for (let offset = 0; offset < len; offset += 65536) {
          crypto.getRandomValues(target.subarray(offset, Math.min(offset + 65536, len)));
        }
        return ERRNO.SUCCESS;
      },

      proc_exit(code) { throw new ProcessExit(code); },

      // Every subscription fires at once: the frontend is single threaded and
      // only polls to sleep, which a type check never needs to do.
      poll_oneoff(inPtr, outPtr, count, eventsPtr) {
        const view = host.view();
        for (let index = 0; index < count; index++) {
          const sub = inPtr + index * 48;
          const event = outPtr + index * 32;
          view.setBigUint64(event, view.getBigUint64(sub, true), true);
          view.setUint16(event + 8, ERRNO.SUCCESS, true);
          view.setUint8(event + 10, view.getUint8(sub + 8));
        }
        view.setUint32(eventsPtr, count, true);
        return ERRNO.SUCCESS;
      },

      fd_write(fd, iovs, count, writtenPtr) {
        const entry = host.fds.get(fd);
        if (!entry) return ERRNO.BADF;
        const total = host.readIovs(iovs, count, (ptr, len) => {
          const chunk = host.bytes().slice(ptr, ptr + len);
          if (entry.kind === "stdout") host.stdout(chunk);
          else if (entry.kind === "stderr") host.stderr(chunk);
          else if (entry.kind === "file") {
            if (entry.append) entry.pos = entry.node.size;
            host.fileWrite(entry, chunk);
          } else return 0;
          return len;
        });
        host.view().setUint32(writtenPtr, total, true);
        return ERRNO.SUCCESS;
      },

      fd_read(fd, iovs, count, readPtr) {
        const entry = host.fds.get(fd);
        if (!entry) return ERRNO.BADF;
        if (entry.kind === "stdin") { host.view().setUint32(readPtr, 0, true); return ERRNO.SUCCESS; }
        if (entry.kind !== "file") return ERRNO.ISDIR;
        const total = host.fileRead(entry, iovs, count, entry.pos);
        entry.pos += total;
        host.view().setUint32(readPtr, total, true);
        return ERRNO.SUCCESS;
      },

      fd_pread(fd, iovs, count, offset, readPtr) {
        const entry = host.fds.get(fd);
        if (!entry) return ERRNO.BADF;
        if (entry.kind !== "file") return ERRNO.ISDIR;
        host.view().setUint32(readPtr, host.fileRead(entry, iovs, count, Number(offset)), true);
        return ERRNO.SUCCESS;
      },

      fd_seek(fd, offset, whence, newOffsetPtr) {
        const entry = host.fds.get(fd);
        if (!entry || entry.kind !== "file") return ERRNO.BADF;
        const base = whence === 0 ? 0 : whence === 1 ? entry.pos : entry.node.size;
        const target = base + Number(offset);
        if (target < 0) return ERRNO.INVAL;
        entry.pos = target;
        host.view().setBigUint64(newOffsetPtr, BigInt(target), true);
        return ERRNO.SUCCESS;
      },

      fd_close(fd) {
        if (!host.fds.has(fd)) return ERRNO.BADF;
        host.fds.delete(fd);
        return ERRNO.SUCCESS;
      },

      fd_fdstat_get(fd, ptr) {
        const entry = host.fds.get(fd);
        if (!entry) return ERRNO.BADF;
        const view = host.view();
        const type = entry.kind === "dir" ? FILETYPE.DIRECTORY
          : entry.kind === "file" ? FILETYPE.REGULAR_FILE : FILETYPE.CHARACTER_DEVICE;
        view.setUint8(ptr, type);
        view.setUint16(ptr + 2, entry.append ? FDFLAGS_APPEND : 0, true);
        view.setBigUint64(ptr + 8, ALL_RIGHTS, true);
        view.setBigUint64(ptr + 16, ALL_RIGHTS, true);
        return ERRNO.SUCCESS;
      },

      fd_fdstat_set_flags: () => ERRNO.SUCCESS,

      fd_filestat_get(fd, ptr) {
        const entry = host.fds.get(fd);
        if (!entry) return ERRNO.BADF;
        if (entry.kind === "file" || entry.kind === "dir") {
          host.writeFilestat(ptr, entry.node || host.fs.nodes.get(entry.path));
        } else {
          host.writeFilestat(ptr, { type: "file", ino: 0, size: 0 });
          host.view().setUint8(ptr + 16, FILETYPE.CHARACTER_DEVICE);
        }
        return ERRNO.SUCCESS;
      },

      fd_prestat_get(fd, ptr) {
        const entry = host.fds.get(fd);
        if (!entry || !entry.preopen) return ERRNO.BADF;
        host.view().setUint8(ptr, 0);
        host.view().setUint32(ptr + 4, host.encoder.encode(entry.preopen).length, true);
        return ERRNO.SUCCESS;
      },

      fd_prestat_dir_name(fd, ptr, len) {
        const entry = host.fds.get(fd);
        if (!entry || !entry.preopen) return ERRNO.BADF;
        host.bytes().set(host.encoder.encode(entry.preopen).subarray(0, len), ptr);
        return ERRNO.SUCCESS;
      },

      fd_readdir(fd, buf, bufLen, cookie, usedPtr) {
        const entry = host.fds.get(fd);
        if (!entry || entry.kind !== "dir") return ERRNO.BADF;
        const view = host.view();
        const names = [".", "..", ...host.fs.children(entry.path)];
        let used = 0;
        for (let index = Number(cookie); index < names.length && used < bufLen; index++) {
          const name = host.encoder.encode(names[index]);
          const childPath = MemoryFileSystem.normalize(`${entry.path}/${names[index]}`);
          const node = host.fs.nodes.get(childPath) || { type: "dir", ino: 0 };
          const header = new Uint8Array(24);
          const headerView = new DataView(header.buffer);
          headerView.setBigUint64(0, BigInt(index + 1), true);
          headerView.setBigUint64(8, BigInt(node.ino), true);
          headerView.setUint32(16, name.length, true);
          headerView.setUint8(20, node.type === "dir" ? FILETYPE.DIRECTORY : FILETYPE.REGULAR_FILE);
          const record = new Uint8Array(24 + name.length);
          record.set(header);
          record.set(name, 24);
          const room = Math.min(record.length, bufLen - used);
          host.bytes().set(record.subarray(0, room), buf + used);
          used += room;
        }
        view.setUint32(usedPtr, used, true);
        return ERRNO.SUCCESS;
      },

      path_filestat_get(fd, _flags, pathPtr, pathLen, ptr) {
        const path = host.resolve(fd, pathPtr, pathLen);
        if (path === null) return ERRNO.BADF;
        const node = host.fs.nodes.get(path);
        if (!node) return ERRNO.NOENT;
        host.writeFilestat(ptr, node);
        return ERRNO.SUCCESS;
      },

      path_create_directory(fd, pathPtr, pathLen) {
        const path = host.resolve(fd, pathPtr, pathLen);
        if (path === null) return ERRNO.BADF;
        if (host.fs.nodes.has(path)) return ERRNO.EXIST;
        if (!host.fs.nodes.has(MemoryFileSystem.parent(path))) return ERRNO.NOENT;
        host.fs.mkdirs(path);
        return ERRNO.SUCCESS;
      },

      path_open(fd, _dirflags, pathPtr, pathLen, oflags, _rightsBase, _rightsInheriting, fdflags, fdPtr) {
        const path = host.resolve(fd, pathPtr, pathLen);
        if (path === null) return ERRNO.BADF;
        let node = host.fs.nodes.get(path);
        if (node && (oflags & OFLAGS.EXCL) && (oflags & OFLAGS.CREAT)) return ERRNO.EXIST;
        if (!node) {
          if (!(oflags & OFLAGS.CREAT)) return ERRNO.NOENT;
          if (!host.fs.nodes.has(MemoryFileSystem.parent(path))) return ERRNO.NOENT;
          node = host.fs.writeFile(path, new Uint8Array(0));
        }
        if ((oflags & OFLAGS.DIRECTORY) && node.type !== "dir") return ERRNO.NOTDIR;
        if (node.type === "file" && (oflags & OFLAGS.TRUNC)) node.size = 0;
        const newFd = host.nextFd++;
        host.fds.set(newFd, node.type === "dir"
          ? { kind: "dir", path }
          : { kind: "file", path, node, pos: 0, append: (fdflags & FDFLAGS_APPEND) !== 0 });
        host.view().setUint32(fdPtr, newFd, true);
        return ERRNO.SUCCESS;
      },
    };
  }

  // Instantiates and runs a WASI command module; returns its exit code.
  async run(module) {
    const instance = await WebAssembly.instantiate(module, this.imports);
    this.memory = instance.exports.memory;
    try {
      instance.exports._start();
      return 0;
    } catch (error) {
      if (error instanceof ProcessExit) return error.code;
      throw error;
    }
  }
}
