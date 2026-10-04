import { sql, guard } from '../lib/db.js';

// GET /api/report?month=YYYY-MM  (defaults to the current month, Malaysia time)
export default async function handler(req, res) {
  if (!guard(req, res)) return;
  if (req.method !== 'GET') return res.status(405).json({ error: 'METHOD NOT ALLOWED' });
  const m = /^\d{4}-(0[1-9]|1[0-2])$/.test(req.query.month || '') ? `${req.query.month}-01` : null;
  try {
    const rows = await sql`SELECT report_json(COALESCE(${m}::date, (now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date)) AS data`;
    res.setHeader('Cache-Control', 'no-store');
    res.status(200).json(rows[0].data);
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'SERVER ERROR' });
  }
}
