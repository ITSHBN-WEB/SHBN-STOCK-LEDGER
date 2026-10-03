// Shared validation for invoice files (used by api/upload.js and api/entries.js).
export const MAX_FILES = 3;
export const LIMITS = { 'image/jpeg': 1_500_000, 'image/png': 1_500_000, 'application/pdf': 3_000_000 };
const EXT = { 'image/jpeg': 'jpg', 'image/png': 'png', 'application/pdf': 'pdf' };
const MAGIC = { 'image/jpeg': [0xff, 0xd8, 0xff], 'image/png': [0x89, 0x50, 0x4e, 0x47], 'application/pdf': [0x25, 0x50, 0x44, 0x46] };

export const cleanName = (n) => String(n || 'INVOICE').replace(/[^\w.\- ]+/g, '').trim().slice(0, 80) || 'INVOICE';

// body: { name, type, data(base64) }  ->  { error } | { buf, type, ext, name }
export function checkUpload(body = {}) {
  const type = String(body.type || '');
  if (!LIMITS[type]) return { error: 'ONLY JPG, PNG OR PDF FILES ARE ALLOWED' };
  if (typeof body.data !== 'string' || !body.data) return { error: 'EMPTY FILE' };
  const buf = Buffer.from(body.data, 'base64');
  if (buf.length === 0) return { error: 'EMPTY FILE' };
  if (buf.length > LIMITS[type]) return { error: `FILE TOO LARGE (MAX ${LIMITS[type] / 1_000_000} MB)` };
  if (!MAGIC[type].every((b, i) => buf[i] === b)) return { error: 'FILE CONTENT DOES NOT MATCH ITS TYPE' };
  return { buf, type, ext: EXT[type], name: cleanName(body.name) };
}

// Only accept links that point to our own Vercel Blob store.
export function cleanFileRefs(arr) {
  if (!Array.isArray(arr) || arr.length < 1) return { error: 'ATTACH AT LEAST 1 INVOICE FILE' };
  if (arr.length > MAX_FILES) return { error: `MAXIMUM ${MAX_FILES} INVOICE FILES` };
  const files = [];
  for (const f of arr) {
    let host = '';
    try { const u = new URL(String(f?.url)); host = u.protocol === 'https:' ? u.hostname : ''; } catch { /* invalid */ }
    if (!host.endsWith('.blob.vercel-storage.com')) return { error: 'INVALID FILE LINK' };
    if (!LIMITS[f.type]) return { error: 'INVALID FILE TYPE' };
    files.push({ url: String(f.url), name: cleanName(f.name), type: f.type, size: Number(f.size) || 0 });
  }
  return { files };
}
