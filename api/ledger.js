import { sql, guard, productOf } from '../lib/db.js';

// GET /api/ledger?month=YYYY-MM  &product=MINYAK|GULA (defaults to the current month, Malaysia time)
export default async function handler(req, res) {
  if (!guard(req, res)) return;
  if (req.method !== 'GET') return res.status(405).json({ error: 'METHOD NOT ALLOWED' });
  const m = /^\d{4}-(0[1-9]|1[0-2])$/.test(req.query.month || '') ? `${req.query.month}-01` : null;
  const product = productOf(req.query.product);
  if (!product) return res.status(400).json({ error: 'UNKNOWN LEDGER' });
  try {
    const rows = await sql`SELECT ledger_json(COALESCE(${m}::date, (now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date), ${product}) AS data`;
    res.setHeader('Cache-Control', 'no-store');
    res.status(200).json(rows[0].data);
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'SERVER ERROR' });
  }
}
