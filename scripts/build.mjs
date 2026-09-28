import { build } from "esbuild";
import { cp, mkdir, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { deflateSync } from "node:zlib";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const outDir = path.join(root, "dist", "pocketclip");
const sounds = ["capture", "copy", "save", "error"];

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(tag, data) {
  const type = Buffer.from(tag);
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(Buffer.concat([type, data])), 0);
  return Buffer.concat([length, type, data, checksum]);
}

function png(size) {
  const raw = Buffer.alloc((size * 4 + 1) * size);
  for (let y = 0; y < size; y += 1) {
    const row = y * (size * 4 + 1);
    raw[row] = 0;
    for (let x = 0; x < size; x += 1) {
      const offset = row + 1 + x * 4;
      const dx = x - size / 2;
      const dy = y - size / 2;
      const inside = dx * dx + dy * dy < (size * 0.28) ** 2;
      raw[offset] = inside ? 250 : 15;
      raw[offset + 1] = inside ? 250 : 118;
      raw[offset + 2] = inside ? 249 : 110;
      raw[offset + 3] = 255;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

await rm(path.join(root, "dist"), { recursive: true, force: true });
await mkdir(outDir, { recursive: true });

const common = {
  bundle: true,
  target: "chrome120",
  legalComments: "none",
  sourcemap: false,
};

await build({
  ...common,
  entryPoints: [path.join(root, "extension/src/background/index.ts")],
  outfile: path.join(outDir, "background.js"),
  format: "esm",
});
await build({
  ...common,
  entryPoints: [path.join(root, "extension/src/popup/popup.ts")],
  outfile: path.join(outDir, "popup.js"),
  format: "iife",
});
await build({
  ...common,
  entryPoints: [path.join(root, "extension/src/offscreen/offscreen.ts")],
  outfile: path.join(outDir, "offscreen.js"),
  format: "iife",
});
await build({
  ...common,
  entryPoints: [path.join(root, "extension/src/content/region.ts")],
  outfile: path.join(outDir, "region.js"),
  format: "iife",
});

await cp(path.join(root, "extension/manifest.json"), path.join(outDir, "manifest.json"));
await cp(path.join(root, "extension/src/popup/popup.html"), path.join(outDir, "popup.html"));
await cp(path.join(root, "extension/src/popup/popup.css"), path.join(outDir, "popup.css"));
await cp(path.join(root, "extension/src/offscreen/offscreen.html"), path.join(outDir, "offscreen.html"));
await cp(path.join(root, "extension/_locales"), path.join(outDir, "_locales"), { recursive: true });

const sfxDir = path.join(outDir, "assets", "sfx");
await mkdir(sfxDir, { recursive: true });
for (const name of sounds) {
  await cp(path.join(root, "extension/assets/sfx", `${name}.mp3`), path.join(sfxDir, `${name}.mp3`));
}

const iconDir = path.join(outDir, "icons");
await mkdir(iconDir, { recursive: true });
for (const size of [16, 32, 48, 128]) {
  await writeFile(path.join(iconDir, `icon${size}.png`), png(size));
}

const packed = await readdir(sfxDir);
if (packed.some((file) => file.endsWith(".ogg")) || packed.length !== sounds.length) {
  throw new Error(`Unexpected sfx bundle: ${packed.join(", ")}`);
}

console.log(outDir);
