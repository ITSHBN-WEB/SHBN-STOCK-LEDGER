import { sql, guard } from '../lib/db.js';
import { cleanFileRefs } from '../lib/files.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const money = (v) => /^\d{1,10}(\.\d{1,2})?$/.test(String(v ?? '').trim());

const clean = (v) => String(v || '').trim().toUpperCase().slice(0, 60);

// POST /api/entries
//  IN : { type, quantity, supplier, invoiceNo, invoiceAmount, receiving1, receiving2?, supervisor, files[1-3], key }
//  OUT: { type, quantity, recordedBy, key }
export default async function handler(req, res) {
  if (!guard(req, res)) return;
  if (req.method !== 'POST') return res.status(405).json({ error: 'METHOD NOT ALLOWED' });

  const b = req.body || {};
  const type = String(b.type || '').toUpperCase();
  const supplier = clean(b.supplier);
  const invoiceNo = clean(b.invoiceNo);
  const receiving1 = clean(b.receiving1), receiving2 = clean(b.receiving2);
  const supervisor = clean(b.supervisor), recordedBy = clean(b.recordedBy);
  let files = null;
  const key = UUID.test(b.key || '') ? b.key : null;

  if (!['IN', 'OUT'].includes(type)) return res.status(400).json({ error: 'INVALID TYPE' });
  if (!money(b.quantity) || Number(b.quantity) <= 0) return res.status(400).json({ error: 'ENTER A VALID QUANTITY (KG)' });
  if (type === 'IN') {
    if (!supplier) return res.status(400).json({ error: 'SUPPLIER IS REQUIRED' });
    if (!invoiceNo) return res.status(400).json({ error: 'INVOICE NUMBER IS REQUIRED' });
    if (!money(b.invoiceAmount)) return res.status(400).json({ error: 'ENTER A VALID INVOICE AMOUNT' });
    if (!receiving1) return res.status(400).json({ error: 'RECEIVING 1 IS REQUIRED' });
    if (!supervisor) return res.status(400).json({ error: 'SUPERVISOR IS REQUIRED' });
    const fr = cleanFileRefs(b.files);
    if (fr.error) return res.status(400).json({ error: fr.error });
    files = fr.files;
  } else if (!recordedBy) {
    return res.status(400).json({ error: 'RECORD BY IS REQUIRED' });
  }

  try {
    const IN = type === 'IN';
    const rows = await sql`SELECT add_stock_entry(
      ${type}, ${Number(b.quantity)}, ${IN ? supplier : null}, ${IN ? invoiceNo : null},
      ${IN ? Number(b.invoiceAmount) : null}, ${IN ? receiving1 : null}, ${IN ? (receiving2 || null) : null},
      ${IN ? supervisor : null}, ${IN ? null : recordedBy}, ${IN ? JSON.stringify(files) : null}::jsonb, ${key}::uuid) AS result`;
    res.status(200).json(rows[0].result);
  } catch (e) {
    const msg = String(e.message || '');
    if (msg.includes('INSUFFICIENT_STOCK')) {
      const kg = (msg.match(/only ([\d.]+) KG/) || [])[1];
      return res.status(409).json({ error: `NOT ENOUGH STOCK: ONLY ${kg ?? '0'} KG AVAILABLE` });
    }
    console.error(e);
    res.status(500).json({ error: 'SERVER ERROR' });
  }
}
