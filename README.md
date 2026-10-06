# Stock Ledger (Neon + Vercel + GitHub)

## Structure
- `db/schema.sql`   table, `add_stock_entry()` (locked write), `ledger_json()` (dashboard data)
- `api/`            Vercel serverless endpoints (`/api/ledger`, `/api/entries`)
- `api/admin.js`    ADMIN tab (password-checked on the server): report header per month, edit / void records
- `api/report.js`   monthly summary report data
- `api/upload.js`   uploads one invoice photo/PDF to Vercel Blob
- `lib/db.js`       Neon connection + optional passcode check
- `lib/files.js`    invoice file rules (types, size, allowed links)
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

## Upgrading an existing deployment (v2: receiving details, record by, expandable days)
1. Neon SQL Editor: paste the whole updated `db/schema.sql` and run it (safe to re-run; existing records are kept).
2. Replace `api/entries.js` and `public/index.html` in GitHub with the new versions (upload > commit). Vercel redeploys by itself.

## Upgrading to v3 (invoice photo / PDF upload on Instock)
1. **Vercel > your project > Storage > Create > Blob.** Connect it to the project (all environments).
   Vercel now connects it with OIDC and adds `BLOB_STORE_ID` (not a token). This needs `@vercel/blob` 2.x (already set in package.json).
2. Neon SQL Editor: paste the whole updated `db/schema.sql` and run it (safe to re-run).
3. GitHub: upload the new/changed files: `package.json`, `api/entries.js`, `api/upload.js`,
   `lib/files.js`, `public/index.html`, `db/schema.sql`. Vercel redeploys by itself.
   (Redeploy once more if the Blob token was added after the last deployment.)

Rules: 1 to 3 files per Instock record; photos are shrunk in the browser (about 300 to 600 KB);
PDF max 3 MB; only JPG, PNG, PDF; only links from your own Blob store are accepted.

## Upgrading to v4 (Brand / Product box, back-dated records with date confirmation)
1. Neon SQL Editor: paste the whole updated `db/schema.sql` and run it (safe to re-run; adds `brand_product`,
   the `max_backdate_days` setting (default 31) and replaces `add_stock_entry()` with the date-aware version).
2. GitHub: replace `api/entries.js` and `public/index.html` (plus `db/schema.sql`). Vercel redeploys by itself.

Rules: every record carries the date of the actual movement (confirmed by the user, never in the future, at most
31 days back). A back-dated OUT is refused if it would make the balance negative on that day or any later day.

## Upgrading to v5 (Cost per carton box + SUMMARY REPORT tab)
1. Neon SQL Editor: paste the whole updated `db/schema.sql` and run it (safe to re-run). It adds `cost_per_carton`,
   the report header settings (company, address, item, tel, licence) and the `report_json()` function.
2. GitHub: upload `api/report.js` (new), and replace `api/entries.js`, `public/index.html`, `db/schema.sql`.

Report rules: stok semasa = stok mula + instock; baki = stok semasa - outstock; harga = sale price (RM 2.50);
jumlah jualan = outstock qty x harga; cost per carton shows one value if equal that day, stacked if different.
Print: SUMMARY REPORT tab > PRINT REPORT (A4 landscape).

## Upgrading to v6 (wider layout, ADMIN tab)
1. **Vercel > Settings > Environment Variables:** add `ADMIN_PASSWORD` (the admin password). Redeploy afterwards.
   The password is never stored in the code or in GitHub. 10 wrong attempts within 10 minutes lock the admin login for 10 minutes.
2. Neon SQL Editor: paste the whole updated `db/schema.sql` and run it (safe to re-run).
3. GitHub: upload `api/admin.js` (new) and replace `public/index.html` and `db/schema.sql`.

ADMIN functions: update the report header (saved per month: applies from that month onward, earlier months keep
their own header); edit an existing record by date (all fields, invoice files, date) with a confirmation popup;
void a record (reason required). A change is refused if any day's stock would go negative. Every edit / void is
written to `stock_entry_audit` (before and after).
