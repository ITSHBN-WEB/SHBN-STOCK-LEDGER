# Stock Ledger (Neon + Vercel + GitHub)

## Structure
- `db/schema.sql`   table, `add_stock_entry()` (locked write), `ledger_json()` (dashboard data)
- `api/`            Vercel serverless endpoints (`/api/ledger`, `/api/entries`)
- `lib/db.js`       Neon connection + optional passcode check
- `public/index.html` frontend (Dashboard + Add Record)

## Setup (about 10 minutes)
1. **Neon**: create a project. Open the SQL Editor, paste all of `db/schema.sql`, run it.
2. **GitHub**: create a repo, upload these files (keep the folder layout; `.env` is never committed).
3. **Vercel**: Add New Project > import the repo. Framework preset: **Other**. Before deploying, add
   Environment Variables: `DATABASE_URL` (Neon pooled connection string) and `APP_PASSCODE` (any shared code).
4. Deploy, open the URL, add an INSTOCK record, then an OUTSTOCK record, and check the Dashboard.

Local test (optional): `npm i -g vercel`, copy `.env.example` to `.env`, run `vercel dev`.

## Multi-user safeguards
- All writes go through `add_stock_entry()`, which takes a database lock, so two people saving at the
  same moment are processed one after the other, never in parallel.
- Outstock larger than the real balance is rejected (balance can never go negative).
- Each form carries a one-time key: double-click, slow network retry, or refresh-resend cannot create duplicates.
- Balances are calculated from the entries, never stored, so they cannot drift.
- Records are never deleted; corrections use `voided_at` (to be added as a screen later).
- Database rejects lowercase supplier / invoice text even if someone bypasses the form.
