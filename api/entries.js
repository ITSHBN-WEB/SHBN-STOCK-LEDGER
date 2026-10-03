import { sql, guard } from '../lib/db.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const money = (v) => /^\d{1,10}(\.\d{1,2})?$/.test(String(v ?? '').trim());

// POST /api/entries  { type:'IN'|'OUT', quantity, supplier?, invoiceNo?, invoiceAmount?, key }
export default async function handler(req, res) {
  if (!guard(req, res)) return;
  if (req.method !== 'POST') return res.status(405).json({ error: 'METHOD NOT ALLOWED' });

  const b = req.body || {};
  const type = String(b.type || '').toUpperCase();
  const supplier = String(b.supplier || '').trim().toUpperCase();
  const invoiceNo = String(b.invoiceNo || '').trim().toUpperCase();
  const key = UUID.test(b.key || '') ? b.key : null;

  if (!['IN', 'OUT'].includes(type)) return res.status(400).json({ error: 'INVALID TYPE' });
  if (!money(b.quantity) || Number(b.quantity) <= 0) return res.status(400).json({ error: 'ENTER A VALID QUANTITY (KG)' });
  if (type === 'IN') {
    if (!supplier) return res.status(400).json({ error: 'SUPPLIER IS REQUIRED' });
    if (!invoiceNo) return res.status(400).json({ error: 'INVOICE NUMBER IS REQUIRED' });
    if (!money(b.invoiceAmount)) return res.status(400).json({ error: 'ENTER A VALID INVOICE AMOUNT' });
  }

  try {
    const rows = await sql`SELECT add_stock_entry(
      ${type}, ${Number(b.quantity)}, ${type === 'IN' ? supplier : null}, ${type === 'IN' ? invoiceNo : null},
      ${type === 'IN' ? Number(b.invoiceAmount) : null}, ${key}::uuid) AS result`;
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
