// Atlas ChartDB – OPFS data store
// Manages reading/writing tightly-packed .bin files in the Origin Private File System.

export const OPFS_DIR = "atlas-chartdb";

/** Write a Uint8Array to OPFS as `<dir>/<name>.bin` */
export async function writeDatasetBin(name: string, data: Uint8Array): Promise<void> {
  const root = await navigator.storage.getDirectory();
  const dir  = await root.getDirectoryHandle(OPFS_DIR, { create: true });
  const fh   = await dir.getFileHandle(`${name}.bin`, { create: true });
  const writable = await (fh as FileSystemFileHandle & {
    createWritable(): Promise<FileSystemWritableFileStream>;
  }).createWritable();
  // Write as ArrayBuffer to satisfy strict FileSystemWritableFileStream typings.
  // data.slice() creates a fresh view backed by a plain ArrayBuffer.
  await writable.write(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer);
  await writable.close();
}

/** Read a .bin file from OPFS; returns null if not found */
export async function readDatasetBin(name: string): Promise<Uint8Array | null> {
  try {
    const root = await navigator.storage.getDirectory();
    const dir  = await root.getDirectoryHandle(OPFS_DIR, { create: false });
    const fh   = await dir.getFileHandle(`${name}.bin`, { create: false });
    const file = await fh.getFile();
    const buf  = await file.arrayBuffer();
    return new Uint8Array(buf);
  } catch {
    return null;
  }
}

/** List all .bin dataset names stored in OPFS */
export async function listDatasets(): Promise<string[]> {
  try {
    const root = await navigator.storage.getDirectory();
    const dir  = await root.getDirectoryHandle(OPFS_DIR, { create: false });
    const names: string[] = [];
    for await (const [name] of (dir as unknown as AsyncIterable<[string, FileSystemHandle]>)) {
      if (name.endsWith(".bin")) names.push(name.slice(0, -4));
    }
    return names;
  } catch {
    return [];
  }
}

/** Delete a .bin file from OPFS */
export async function deleteDataset(name: string): Promise<void> {
  try {
    const root = await navigator.storage.getDirectory();
    const dir  = await root.getDirectoryHandle(OPFS_DIR, { create: false });
    await dir.removeEntry(`${name}.bin`);
  } catch {
    // ignore if not found
  }
}
