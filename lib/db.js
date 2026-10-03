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
