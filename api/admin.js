import { createHash, timingSafeEqual } from 'node:crypto';
import { sql, guard } from '../lib/db.js';
import { cleanFileRefs } from '../lib/files.js';

// One endpoint for the whole ADMIN tab. Every call carries the admin password and is checked here, on the server.
//   POST { password, action: 'login' }
//   POST { password, action: 'header_get',  month: 'YYYY-MM' }
//   POST { password, action: 'header_save', month: 'YYYY-MM', header: { company, address, tel, item, licenseNo, licenseExpiry } }
//   POST { password, action: 'records_get', date: 'YYYY-MM-DD' }
//   POST { password, action: 'record_save', id, data: { date, qty, supplier, brand, cost, invoiceNo, invoiceAmount, receiving1, receiving2, supervisor, recordedBy, files } }
//   POST { password, action: 'record_void', id, reason }

const sha = (v) => createHash('sha256').update(String(v ?? '')).digest();
const up = (v, n = 120) => String(v ?? '').trim().toUpperCase().slice(0, n);
const isMonth = (v) => /^\d{4}-(0[1-9]|1[0-2])$/.test(v || '');
const isDate = (v) => /^\d{4}-\d{2}-\d{2}$/.test(v || '') && new Date(v + 'T00:00:00Z').toISOString().slice(0, 10) === v;
const isMoney = (v) => /^\d{1,10}(\.\d{1,2})?$/.test(String(v ?? '').trim());
const blank = (v) => String(v ?? '').trim() === '';

export default async function handler(req, res) {
  if (!guard(req, res)) return;
  if (req.method !== 'POST') return res.status(405).json({ error: 'METHOD NOT ALLOWED' });
  const b = req.body || {};

  const expected = process.env.ADMIN_PASSWORD;
  if (!expected) return res.status(503).json({ error: 'ADMIN PASSWORD IS NOT SET ON THE SERVER (VERCEL VARIABLE ADMIN_PASSWORD)' });

  try {
    // Lock after too many wrong passwords (10 in 10 minutes), then check the password in constant time.
    const [{ n }] = await sql`SELECT count(*)::int AS n FROM admin_attempts WHERE ts > now() - interval '10 minutes'`;
    if (n >= 10) return res.status(429).json({ error: 'TOO MANY WRONG ATTEMPTS. TRY AGAIN IN 10 MINUTES' });
    if (!timingSafeEqual(sha(b.password), sha(expected))) {
      await sql`INSERT INTO admin_attempts DEFAULT VALUES`;
      await sql`DELETE FROM admin_attempts WHERE ts < now() - interval '1 day'`;
      return res.status(403).json({ error: 'WRONG PASSWORD' });
    }

    switch (b.action) {
      case 'login':
        return res.status(200).json({ ok: true });

      case 'header_get': {
        if (!isMonth(b.month)) return res.status(400).json({ error: 'INVALID MONTH' });
        const m = `${b.month}-01`;
        const r = await sql`SELECT report_header(${m}::date) AS header,
          EXISTS (SELECT 1 FROM report_headers WHERE month = ${m}::date) AS own`;
        return res.status(200).json(r[0]);
      }

      case 'header_save': {
        if (!isMonth(b.month)) return res.status(400).json({ error: 'INVALID MONTH' });
        const h = b.header || {};
        const v = { company: up(h.company), address: up(h.address, 300), tel: up(h.tel), item: up(h.item),
                    lic: up(h.licenseNo), exp: up(h.licenseExpiry) };
        if (!v.company) return res.status(400).json({ error: 'NAMA SYARIKAT IS REQUIRED' });
        if (!v.item) return res.status(400).json({ error: 'JENIS BARANG KAWALAN IS REQUIRED' });
        const m = `${b.month}-01`;
        await sql`INSERT INTO report_headers (month, company, address, tel, item, license_no, license_expiry)
          VALUES (${m}::date, ${v.company}, ${v.address}, ${v.tel}, ${v.item}, ${v.lic}, ${v.exp})
          ON CONFLICT (month) DO UPDATE SET company = EXCLUDED.company, address = EXCLUDED.address, tel = EXCLUDED.tel,
            item = EXCLUDED.item, license_no = EXCLUDED.license_no, license_expiry = EXCLUDED.license_expiry, updated_at = now()`;
        return res.status(200).json({ ok: true });
      }

      case 'records_get': {
        if (!isDate(b.date)) return res.status(400).json({ error: 'INVALID DATE' });
        const r = await sql`SELECT admin_records_json(${b.date}::date) AS records`;
        return res.status(200).json({ records: r[0].records });
      }

      case 'record_save': {
        const id = Number(b.id);
        if (!Number.isInteger(id) || id < 1) return res.status(400).json({ error: 'INVALID RECORD' });
        const row = (await sql`SELECT entry_type, source FROM stock_entries WHERE id = ${id} AND voided_at IS NULL`)[0];
        if (!row) return res.status(404).json({ error: 'RECORD NOT FOUND (IT MAY HAVE BEEN CHANGED OR VOIDED)' });
        const d = b.data || {}, IN = row.entry_type === 'IN', strict = row.source === 'APP';

        if (!isDate(d.date)) return res.status(400).json({ error: 'SELECT A VALID DATE' });
        if (!isMoney(d.qty) || Number(d.qty) <= 0) return res.status(400).json({ error: 'ENTER A VALID QUANTITY (KG)' });
        const data = { date: d.date, qty: Number(d.qty) };

        if (IN) {
          if (strict) {
            if (blank(d.supplier)) return res.status(400).json({ error: 'SUPPLIER IS REQUIRED' });
            if (blank(d.brand)) return res.status(400).json({ error: 'BRAND / PRODUCT IS REQUIRED' });
            if (blank(d.cost)) return res.status(400).json({ error: 'COST PER CARTON IS REQUIRED' });
            if (blank(d.invoiceNo)) return res.status(400).json({ error: 'INVOICE NUMBER IS REQUIRED' });
            if (blank(d.invoiceAmount)) return res.status(400).json({ error: 'INVOICE AMOUNT IS REQUIRED' });
            if (blank(d.receiving1)) return res.status(400).json({ error: 'RECEIVING 1 IS REQUIRED' });
            if (blank(d.supervisor)) return res.status(400).json({ error: 'SUPERVISOR IS REQUIRED' });
          }
          for (const [k, label] of [['cost', 'COST PER CARTON'], ['invoiceAmount', 'INVOICE AMOUNT']]) {
            if (!blank(d[k]) && !isMoney(d[k])) return res.status(400).json({ error: `ENTER A VALID ${label}` });
          }
          const files = Array.isArray(d.files) ? d.files : [];
          if (strict || files.length) {
            const fr = cleanFileRefs(files);
            if (fr.error) return res.status(400).json({ error: fr.error });
            data.files = fr.files;
          } else data.files = [];
          Object.assign(data, {
            supplier: up(d.supplier), brand: up(d.brand), cost: blank(d.cost) ? '' : String(d.cost).trim(),
            invoice_no: up(d.invoiceNo), invoice_amount: blank(d.invoiceAmount) ? '' : String(d.invoiceAmount).trim(),
            receiving_1: up(d.receiving1), receiving_2: up(d.receiving2), supervisor: up(d.supervisor),
          });
        } else {
          if (strict && blank(d.recordedBy)) return res.status(400).json({ error: 'RECORD BY IS REQUIRED' });
          data.recorded_by = up(d.recordedBy);
        }
        const r = await sql`SELECT admin_update_entry(${id}, ${JSON.stringify(data)}::jsonb) AS result`;
        return res.status(200).json(r[0].result);
      }

      case 'record_void': {
        const id = Number(b.id), reason = up(b.reason, 200);
        if (!Number.isInteger(id) || id < 1) return res.status(400).json({ error: 'INVALID RECORD' });
        if (!reason) return res.status(400).json({ error: 'A REASON IS REQUIRED' });
        const r = await sql`SELECT admin_void_entry(${id}, ${reason}) AS result`;
        return res.status(200).json(r[0].result);
      }

      default:
        return res.status(400).json({ error: 'UNKNOWN ACTION' });
    }
  } catch (e) {
    const msg = String(e.message || '');
    if (msg.includes('NEGATIVE_BALANCE')) {
      const m = msg.match(/NEGATIVE_BALANCE: (-?[\d.]+) KG on (\d{4})-(\d{2})-(\d{2})/);
      return res.status(409).json({ error: m ? `NOT ALLOWED: STOCK WOULD BE ${m[1]} KG ON ${+m[4]}/${+m[3]}/${m[2]}` : 'NOT ALLOWED: STOCK WOULD GO NEGATIVE' });
    }
    if (msg.includes('NOT_FOUND')) return res.status(404).json({ error: 'RECORD NOT FOUND (IT MAY HAVE BEEN CHANGED OR VOIDED)' });
    if (msg.includes('DATE_IN_FUTURE')) return res.status(400).json({ error: 'DATE CANNOT BE IN THE FUTURE' });
    if (msg.includes('in_complete')) return res.status(400).json({ error: 'THIS RECORD IS MISSING REQUIRED DETAILS. FILL IN THE EMPTY BOXES (BRAND, COST, FILES...) AND SAVE' });
    if (/check constraint|invalid input|out of range/i.test(msg)) return res.status(400).json({ error: 'PLEASE CHECK THE VALUES ENTERED' });
    console.error(e);
    return res.status(500).json({ error: 'SERVER ERROR' });
  }
}
