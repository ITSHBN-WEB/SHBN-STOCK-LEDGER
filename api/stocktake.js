import { sql, guard, productOf } from '../lib/db.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const money = (v) => /^\d{1,10}(\.\d{1,2})?$/.test(String(v ?? '').trim());

// GET  /api/stocktake?product=GULA                       -> { product, name, balance, items: [last 20 stocktakes] }
// POST /api/stocktake { product, sap, physical, remark?, submittedBy, key }
//      -> { stocktake: {...with timestamp and discrepancy}, duplicate }
// Stocktakes are a permanent audit record: they are added, never edited or deleted.
export default async function handler(req, res) {
  if (!guard(req, res)) return;
  try {
    if (req.method === 'GET') {
      const product = productOf(req.query.product);
      if (!product) return res.status(400).json({ error: 'UNKNOWN LEDGER' });
      const rows = await sql`SELECT stocktakes_json(${product}, 20) AS data`;
      res.setHeader('Cache-Control', 'no-store');
      return res.status(200).json(rows[0].data);
    }
    if (req.method !== 'POST') return res.status(405).json({ error: 'METHOD NOT ALLOWED' });

    const b = req.body || {};
    const product = productOf(b.product);
    if (!product) return res.status(400).json({ error: 'UNKNOWN LEDGER' });
    if (!money(b.sap)) return res.status(400).json({ error: 'ENTER A VALID SAP BALANCE STOCK' });
    if (!money(b.physical)) return res.status(400).json({ error: 'ENTER A VALID PHYSICAL COUNT QUANTITY' });
    const by = String(b.submittedBy ?? '').trim().toUpperCase().slice(0, 60);
    if (!by) return res.status(400).json({ error: 'SUBMIT BY IS REQUIRED' });
    const remark = String(b.remark ?? '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean).join('\n').toUpperCase().slice(0, 500);
    const key = UUID.test(b.key || '') ? b.key : null;

    const rows = await sql`SELECT add_stocktake(${product}, ${Number(b.sap)}, ${Number(b.physical)}, ${remark}, ${by}, ${key}::uuid) AS result`;
    return res.status(200).json(rows[0].result);
  } catch (e) {
    if (String(e.message || '').includes('UNKNOWN_PRODUCT')) return res.status(400).json({ error: 'UNKNOWN LEDGER' });
    console.error(e);
    return res.status(500).json({ error: 'SERVER ERROR' });
  }
}
