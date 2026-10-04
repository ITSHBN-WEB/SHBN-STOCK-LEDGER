import { put } from '@vercel/blob';
import { randomUUID } from 'node:crypto';
import { guard } from '../lib/db.js';
import { checkUpload } from '../lib/files.js';

// POST /api/upload  { name, type, data: <base64> }  ->  { url, name, type, size }
// One file per request (keeps each request under Vercel's 4.5 MB body limit).
export default async function handler(req, res) {
  if (!guard(req, res)) return;
  if (req.method !== 'POST') return res.status(405).json({ error: 'METHOD NOT ALLOWED' });

  const r = checkUpload(req.body);
  if (r.error) return res.status(400).json({ error: r.error });

  try {
    const month = new Date().toISOString().slice(0, 7);
    const blob = await put(`invoices/${month}/${randomUUID()}.${r.ext}`, r.buf, {
      access: 'public', contentType: r.type, addRandomSuffix: true,
    });
    res.status(200).json({ url: blob.url, name: r.name, type: r.type, size: r.buf.length });
  } catch (e) {
    console.error(e);
    const noStore = /token|BLOB_STORE_ID|authenticat|OIDC/i.test(String(e.message));
    res.status(500).json({ error: noStore ? 'FILE STORAGE IS NOT CONNECTED (VERCEL BLOB)' : 'UPLOAD FAILED, TRY AGAIN' });
  }
}
