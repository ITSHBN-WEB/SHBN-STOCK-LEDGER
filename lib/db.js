import { neon } from '@neondatabase/serverless';

export const sql = neon(process.env.DATABASE_URL);

// Optional shared passcode (set APP_PASSCODE in Vercel). Leave unset to disable.
export function guard(req, res) {
  const pass = process.env.APP_PASSCODE;
  if (pass && req.headers['x-passcode'] !== pass) {
    res.status(401).json({ error: 'WRONG OR MISSING PASSCODE' });
    return false;
  }
  return true;
}

// Ledger code from the request. Absent -> MINYAK (original ledger). Invalid -> null (caller answers 400).
export function productOf(v) {
  if (v === undefined || v === null || v === '') return 'MINYAK';
  const s = String(v).trim().toUpperCase();
  return /^[A-Z]{1,20}$/.test(s) ? s : null;
}
