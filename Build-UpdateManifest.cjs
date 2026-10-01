'use strict';
const fs = require('node:fs'), path = require('node:path');
const zlib = require('node:zlib');
const { hash, entries } = require('./UpdateEngine.cjs');
// Offsets refer to the immutable release ZIP; no second runtime archive is uploaded.
function build(archive, packageRoot, output) {
  const zip = fs.readFileSync(archive), reg = JSON.parse(fs.readFileSync(path.join(packageRoot, 'update-install.json'), 'utf8'));
  let end = -1;
  for (let i = zip.length - 22; i >= Math.max(0, zip.length - 65557); i--) if (zip.readUInt32LE(i) === 0x06054b50 && i + 22 + zip.readUInt16LE(i + 20) === zip.length) { end = i; break; }
  if (end < 0 || zip.readUInt16LE(end + 4) || zip.readUInt16LE(end + 6)) throw Error('Unsupported ZIP');
  const count = zip.readUInt16LE(end + 10); let offset = zip.readUInt32LE(end + 16); const files = [];
  for (let i = 0; i < count; i++) {
    if (zip.readUInt32LE(offset) !== 0x02014b50) throw Error('Invalid central directory');
    const flags = zip.readUInt16LE(offset + 8), method = zip.readUInt16LE(offset + 10), length = zip.readUInt32LE(offset + 20), size = zip.readUInt32LE(offset + 24);
    const nameLength = zip.readUInt16LE(offset + 28), extra = zip.readUInt16LE(offset + 30), comment = zip.readUInt16LE(offset + 32), local = zip.readUInt32LE(offset + 42);
    const name = zip.subarray(offset + 46, offset + 46 + nameLength).toString('utf8').replace(/\\/g, '/');
    if ((flags & 1) || ![0, 8].includes(method) || !name.startsWith('FlowSwitch/') || name.endsWith('/') || zip.readUInt32LE(local) !== 0x04034b50) throw Error('Unsupported archive entry');
    const rel = name.slice('FlowSwitch/'.length), bytes = fs.readFileSync(path.join(packageRoot, rel));
    if (bytes.length !== size) throw Error('ZIP file size mismatch');
    const start = local + 30 + zip.readUInt16LE(local + 26) + zip.readUInt16LE(local + 28);
    const compressed = zip.subarray(start, start + length);
    const decoded = method === 8 ? zlib.inflateRawSync(compressed, {maxOutputLength: size + 1}) : compressed;
    if (!decoded.equals(bytes)) throw Error('ZIP bytes do not match package file');
    files.push({ path: rel, bytes: size, sha256: hash(bytes), start, length, method });
    offset += 46 + nameLength + extra + comment;
  }
  entries(files);
  const result = { schema: 1, minUpdater: 1, product: 'FlowSwitch', platform: 'windows', arch: 'x64', channel: 'stable', version: reg.version, build: reg.build, manifestSha256: reg.manifestSha256, archive: { name: path.basename(archive), bytes: zip.length, sha256: hash(zip) }, files };
  fs.writeFileSync(output, JSON.stringify(result, null, 2)); return result;
}
module.exports = { build };
if (require.main === module) build(...process.argv.slice(2));
