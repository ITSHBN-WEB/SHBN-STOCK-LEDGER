-- Stock ledger schema for Neon (Postgres).
-- SAFE TO RE-RUN: works for a fresh install AND as an upgrade of an existing database.
-- Principle: append-only ledger. Balances are ALWAYS computed from entries, never stored,
-- so month-to-month carry-over can never drift or break (unlike the Excel M39/M40 links).

CREATE TABLE IF NOT EXISTS stock_entries (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entry_type      TEXT          NOT NULL CHECK (entry_type IN ('IN','OUT')),
  entry_date      DATE          NOT NULL,                 -- business day, Asia/Kuala_Lumpur
  entry_ts        TIMESTAMPTZ   NOT NULL DEFAULT now(),   -- exact time of the record
  quantity_kg     NUMERIC(12,2) NOT NULL CHECK (quantity_kg > 0),
  supplier        TEXT,
  invoice_no      TEXT,
  invoice_amount  NUMERIC(12,2) CHECK (invoice_amount >= 0),
  unit_price      NUMERIC(8,2),                           -- OUT only: RM per KG at time of sale
  idempotency_key UUID UNIQUE,                            -- blocks double-click / retry duplicates
  source          TEXT          NOT NULL DEFAULT 'APP' CHECK (source IN ('APP','EXCEL_IMPORT')),
  voided_at       TIMESTAMPTZ,                            -- corrections = void, never DELETE
  void_reason     TEXT
);

-- v2 columns: receiving details (IN) and record-by (OUT)
ALTER TABLE stock_entries ADD COLUMN IF NOT EXISTS receiving_1 TEXT;
ALTER TABLE stock_entries ADD COLUMN IF NOT EXISTS receiving_2 TEXT;
ALTER TABLE stock_entries ADD COLUMN IF NOT EXISTS supervisor  TEXT;
ALTER TABLE stock_entries ADD COLUMN IF NOT EXISTS recorded_by TEXT;
-- v3 column: invoice photos/PDFs (max 3), stored as links: [{url,name,type,size}]
ALTER TABLE stock_entries ADD COLUMN IF NOT EXISTS invoice_files JSONB;
-- v4 column: brand / product name for instock
ALTER TABLE stock_entries ADD COLUMN IF NOT EXISTS brand_product TEXT;
-- v5 column: cost per carton (RM) for instock
ALTER TABLE stock_entries ADD COLUMN IF NOT EXISTS cost_per_carton NUMERIC(12,2) CHECK (cost_per_carton >= 0);

-- Rules apply to NEW rows only (NOT VALID), so records saved before this upgrade never block it.
ALTER TABLE stock_entries DROP CONSTRAINT IF EXISTS upper_only;
ALTER TABLE stock_entries ADD CONSTRAINT upper_only CHECK (
  (supplier    IS NULL OR supplier    = upper(supplier))    AND
  (invoice_no  IS NULL OR invoice_no  = upper(invoice_no))  AND
  (receiving_1 IS NULL OR receiving_1 = upper(receiving_1)) AND
  (receiving_2 IS NULL OR receiving_2 = upper(receiving_2)) AND
  (supervisor  IS NULL OR supervisor  = upper(supervisor))  AND
  (recorded_by IS NULL OR recorded_by = upper(recorded_by)) AND
  (brand_product IS NULL OR brand_product = upper(brand_product))) NOT VALID;

-- New records from the app must be complete; imported history may have gaps.
ALTER TABLE stock_entries DROP CONSTRAINT IF EXISTS in_complete;
ALTER TABLE stock_entries ADD CONSTRAINT in_complete CHECK (
  source <> 'APP' OR
  (entry_type = 'IN'  AND coalesce(supplier,'') <> '' AND coalesce(invoice_no,'') <> ''
                      AND invoice_amount IS NOT NULL
                      AND coalesce(receiving_1,'') <> '' AND coalesce(supervisor,'') <> ''
                      AND coalesce(brand_product,'') <> '' AND cost_per_carton IS NOT NULL
                      AND (CASE WHEN jsonb_typeof(invoice_files) = 'array'
                                THEN jsonb_array_length(invoice_files) ELSE 0 END) BETWEEN 1 AND 3) OR
  (entry_type = 'OUT' AND coalesce(recorded_by,'') <> '')) NOT VALID;

ALTER TABLE stock_entries DROP CONSTRAINT IF EXISTS invoice_files_ok;
ALTER TABLE stock_entries ADD CONSTRAINT invoice_files_ok CHECK (
  invoice_files IS NULL OR (jsonb_typeof(invoice_files) = 'array' AND jsonb_array_length(invoice_files) <= 3)) NOT VALID;

CREATE INDEX IF NOT EXISTS stock_entries_date_idx ON stock_entries (entry_date) WHERE voided_at IS NULL;

CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO app_settings VALUES ('out_unit_price','2.50') ON CONFLICT DO NOTHING;  -- RM/KG, from Excel col K
INSERT INTO app_settings VALUES ('max_backdate_days','31') ON CONFLICT DO NOTHING;  -- how far back a record may be dated
-- Summary report header (editable later from the ADMIN tab)
INSERT INTO app_settings VALUES
  ('report_company', 'SERVAY EVERGREEN BENONI'),
  ('report_address', 'GROUND, FIRST & SECOND FLOOR OF SHOPLOT NO. 178, 3-STOREY HYPERMARKET, BENONI COMMERCIAL CENTRE PHASE 3A, 89600, PAPAR, SABAH, MALAYSIA'),
  ('report_tel', ''),
  ('report_item', 'MINYAK PAKET 1KG'),
  ('report_license_no', ''),
  ('report_license_expiry', '')
ON CONFLICT DO NOTHING;

-- The ONLY way the app writes. One call = one atomic transaction.
DROP FUNCTION IF EXISTS add_stock_entry(text, numeric, text, text, numeric, uuid);  -- v1 signature
DROP FUNCTION IF EXISTS add_stock_entry(text, numeric, text, text, numeric, text, text, text, text, uuid);  -- v2 signature
DROP FUNCTION IF EXISTS add_stock_entry(text, numeric, text, text, numeric, text, text, text, text, jsonb, uuid);  -- v3 signature
DROP FUNCTION IF EXISTS add_stock_entry(text, numeric, text, text, numeric, text, text, text, text, jsonb, text, date, uuid);  -- v4 signature
CREATE OR REPLACE FUNCTION add_stock_entry(
  p_type text, p_qty numeric, p_supplier text, p_invoice_no text, p_invoice_amount numeric,
  p_receiving_1 text, p_receiving_2 text, p_supervisor text, p_recorded_by text, p_files jsonb,
  p_brand text, p_cost numeric, p_date date, p_key uuid
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_row stock_entries; v_bal numeric; v_price numeric; v_min numeric; v_max_back int;
  v_today date := (now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date;
BEGIN
  -- 1) Serialise all writers: concurrent users queue here, so the checks below are never stale.
  PERFORM pg_advisory_xact_lock(727001);

  -- 2) Idempotent retry: same key already saved -> return the original, do not insert again.
  IF p_key IS NOT NULL THEN
    SELECT * INTO v_row FROM stock_entries WHERE idempotency_key = p_key;
    IF FOUND THEN
      SELECT COALESCE(SUM(CASE entry_type WHEN 'IN' THEN quantity_kg ELSE -quantity_kg END),0)
        INTO v_bal FROM stock_entries WHERE voided_at IS NULL;
      RETURN jsonb_build_object('entry', to_jsonb(v_row), 'balance', v_bal, 'duplicate', true);
    END IF;
  END IF;

  -- 3) Date rules: chosen by the user, but never in the future and not older than the allowed window.
  IF p_date IS NULL THEN RAISE EXCEPTION 'DATE_REQUIRED'; END IF;
  SELECT COALESCE(value::int, 31) INTO v_max_back FROM app_settings WHERE key = 'max_backdate_days';
  v_max_back := COALESCE(v_max_back, 31);
  IF p_date > v_today THEN RAISE EXCEPTION 'DATE_IN_FUTURE'; END IF;
  IF p_date < v_today - v_max_back THEN RAISE EXCEPTION 'DATE_TOO_OLD: max % days back', v_max_back; END IF;

  SELECT COALESCE(SUM(CASE entry_type WHEN 'IN' THEN quantity_kg ELSE -quantity_kg END),0)
    INTO v_bal FROM stock_entries WHERE voided_at IS NULL;

  -- 4) Never let stock go negative ON ANY DAY. A back-dated OUT lowers the balance of that day
  --    and of every later day, so the lowest closing balance from that date onward must cover it.
  IF p_type = 'OUT' THEN
    WITH daily AS (
      SELECT entry_date AS d, SUM(CASE entry_type WHEN 'IN' THEN quantity_kg ELSE -quantity_kg END) AS net
      FROM stock_entries WHERE voided_at IS NULL GROUP BY entry_date
    ), cum AS (SELECT d, SUM(net) OVER (ORDER BY d) AS c FROM daily)
    SELECT LEAST(
             COALESCE((SELECT c FROM cum WHERE d <= p_date ORDER BY d DESC LIMIT 1), 0),
             COALESCE((SELECT MIN(c) FROM cum WHERE d > p_date), 1e15))
      INTO v_min;
    IF p_qty > v_min THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK: only % KG available', v_min;
    END IF;
  END IF;

  SELECT value::numeric INTO v_price FROM app_settings WHERE key = 'out_unit_price';

  INSERT INTO stock_entries (entry_type, entry_date, quantity_kg, supplier, invoice_no, invoice_amount, unit_price,
                             receiving_1, receiving_2, supervisor, recorded_by, invoice_files, brand_product, cost_per_carton, idempotency_key)
  VALUES (p_type, p_date, p_qty,
          upper(nullif(btrim(p_supplier),'')), upper(nullif(btrim(p_invoice_no),'')),
          CASE WHEN p_type = 'IN' THEN p_invoice_amount END,
          CASE WHEN p_type = 'OUT' THEN v_price END,
          upper(nullif(btrim(p_receiving_1),'')), upper(nullif(btrim(p_receiving_2),'')),
          upper(nullif(btrim(p_supervisor),'')),  upper(nullif(btrim(p_recorded_by),'')),
          CASE WHEN p_type = 'IN' THEN p_files END,
          CASE WHEN p_type = 'IN' THEN upper(nullif(btrim(p_brand),'')) END,
          CASE WHEN p_type = 'IN' THEN p_cost END, p_key)
  RETURNING * INTO v_row;

  v_bal := v_bal + CASE p_type WHEN 'IN' THEN p_qty ELSE -p_qty END;
  RETURN jsonb_build_object('entry', to_jsonb(v_row), 'balance', v_bal, 'duplicate', false);
END $$;

-- Dashboard payload in ONE statement (consistent snapshot): current balance, daily ledger, entries.
-- Day logic = your Excel: opening(day) = closing(previous day); 1st of month = last day of previous month.
CREATE OR REPLACE FUNCTION ledger_json(p_month date) RETURNS jsonb LANGUAGE sql STABLE AS $$
WITH bounds AS (
  SELECT date_trunc('month', p_month)::date AS first_day,
         (date_trunc('month', p_month) + interval '1 month')::date AS next_first,
         LEAST((date_trunc('month', p_month) + interval '1 month')::date - 1,
               (now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date) AS last_day
), opening AS (
  SELECT COALESCE(SUM(CASE entry_type WHEN 'IN' THEN quantity_kg ELSE -quantity_kg END),0) AS qty
  FROM stock_entries, bounds WHERE voided_at IS NULL AND entry_date < first_day
), per_day AS (
  SELECT entry_date,
         SUM(CASE WHEN entry_type='IN'  THEN quantity_kg ELSE 0 END) AS in_kg,
         SUM(CASE WHEN entry_type='OUT' THEN quantity_kg ELSE 0 END) AS out_kg
  FROM stock_entries, bounds
  WHERE voided_at IS NULL AND entry_date >= first_day AND entry_date < next_first GROUP BY entry_date
), days AS (
  SELECT g::date AS d FROM bounds, generate_series(first_day, last_day, interval '1 day') g
), ledger AS (
  SELECT d, COALESCE(in_kg,0) AS in_kg, COALESCE(out_kg,0) AS out_kg,
         (SELECT qty FROM opening) + SUM(COALESCE(in_kg,0) - COALESCE(out_kg,0)) OVER (ORDER BY d) AS closing
  FROM days LEFT JOIN per_day ON entry_date = d
)
SELECT jsonb_build_object(
  'balance', (SELECT COALESCE(SUM(CASE entry_type WHEN 'IN' THEN quantity_kg ELSE -quantity_kg END),0)
              FROM stock_entries WHERE voided_at IS NULL),
  'month_opening', (SELECT qty FROM opening),
  'max_backdate_days', COALESCE((SELECT value::int FROM app_settings WHERE key = 'max_backdate_days'), 31),
  'days', COALESCE((SELECT jsonb_agg(jsonb_build_object('date', d, 'opening', closing - in_kg + out_kg,
                    'in', in_kg, 'out', out_kg, 'closing', closing) ORDER BY d) FROM ledger), '[]'::jsonb),
  'entries', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', id, 'type', entry_type, 'date', entry_date, 'ts', entry_ts,
                    'supplier', supplier, 'invoice_no', invoice_no, 'invoice_amount', invoice_amount,
                    'receiving_1', receiving_1, 'receiving_2', receiving_2, 'supervisor', supervisor,
                    'recorded_by', recorded_by, 'files', invoice_files, 'brand', brand_product, 'cost', cost_per_carton, 'qty', quantity_kg) ORDER BY entry_ts, id)
              FROM stock_entries, bounds
              WHERE voided_at IS NULL AND entry_date >= first_day AND entry_date < next_first), '[]'::jsonb)
);
$$;

-- Report header, versioned by month: a row saved for month M applies to M and every later month until the next
-- row. Earlier months keep their own header, so past reports never change. No row = the defaults in app_settings.
CREATE TABLE IF NOT EXISTS report_headers (
  month          DATE PRIMARY KEY CHECK (month = date_trunc('month', month)::date),
  company        TEXT NOT NULL DEFAULT '',
  address        TEXT NOT NULL DEFAULT '',
  tel            TEXT NOT NULL DEFAULT '',
  item           TEXT NOT NULL DEFAULT '',
  license_no     TEXT NOT NULL DEFAULT '',
  license_expiry TEXT NOT NULL DEFAULT '',
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION report_header(p_month date) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (SELECT jsonb_build_object('company', company, 'address', address, 'tel', tel, 'item', item,
                               'license_no', license_no, 'license_expiry', license_expiry)
       FROM report_headers WHERE month <= date_trunc('month', p_month)::date ORDER BY month DESC LIMIT 1),
    jsonb_build_object(
      'company', (SELECT value FROM app_settings WHERE key = 'report_company'),
      'address', (SELECT value FROM app_settings WHERE key = 'report_address'),
      'tel',     (SELECT value FROM app_settings WHERE key = 'report_tel'),
      'item',    (SELECT value FROM app_settings WHERE key = 'report_item'),
      'license_no',     (SELECT value FROM app_settings WHERE key = 'report_license_no'),
      'license_expiry', (SELECT value FROM app_settings WHERE key = 'report_license_expiry')));
$$;

-- Monthly summary report (all days of the month, same columns as the Excel sheet).
-- stok_semasa = opening + instock ; baki = stok_semasa - outstock ; harga = sale price per KG.
CREATE OR REPLACE FUNCTION report_json(p_month date) RETURNS jsonb LANGUAGE sql STABLE AS $$
WITH b AS (
  SELECT date_trunc('month', p_month)::date AS first_day,
         (date_trunc('month', p_month) + interval '1 month')::date AS next_first
), price AS (
  SELECT COALESCE((SELECT value::numeric FROM app_settings WHERE key = 'out_unit_price'), 2.50) AS p
), opening AS (
  SELECT COALESCE(SUM(CASE entry_type WHEN 'IN' THEN quantity_kg ELSE -quantity_kg END),0) AS qty
  FROM stock_entries, b WHERE voided_at IS NULL AND entry_date < first_day
), per_day AS (
  SELECT entry_date AS d,
    SUM(CASE WHEN entry_type = 'IN'  THEN quantity_kg ELSE 0 END) AS in_kg,
    SUM(CASE WHEN entry_type = 'OUT' THEN quantity_kg ELSE 0 END) AS out_kg,
    SUM(CASE WHEN entry_type = 'OUT' THEN quantity_kg * COALESCE(unit_price, (SELECT p FROM price)) ELSE 0 END) AS out_amt,
    COALESCE(jsonb_agg(DISTINCT COALESCE(unit_price, (SELECT p FROM price))) FILTER (WHERE entry_type = 'OUT'), '[]'::jsonb) AS out_prices,
    COALESCE(jsonb_agg(jsonb_build_object('supplier', supplier, 'brand', brand_product, 'invoice_no', invoice_no,
                       'cost', cost_per_carton, 'amount', invoice_amount, 'qty', quantity_kg) ORDER BY entry_ts, id)
             FILTER (WHERE entry_type = 'IN'), '[]'::jsonb) AS buys
  FROM stock_entries, b
  WHERE voided_at IS NULL AND entry_date >= first_day AND entry_date < next_first GROUP BY entry_date
), days AS (
  SELECT g::date AS d FROM b, generate_series(first_day, next_first - 1, interval '1 day') g
), ledger AS (
  SELECT d, COALESCE(in_kg,0) AS in_kg, COALESCE(out_kg,0) AS out_kg, COALESCE(out_amt,0) AS out_amt,
         COALESCE(out_prices,'[]'::jsonb) AS out_prices, COALESCE(buys,'[]'::jsonb) AS buys,
         (SELECT qty FROM opening) + SUM(COALESCE(in_kg,0) - COALESCE(out_kg,0)) OVER (ORDER BY d) AS closing
  FROM days LEFT JOIN per_day USING (d)
)
SELECT jsonb_build_object(
  'month', (SELECT to_char(first_day, 'YYYY-MM') FROM b),
  'price', (SELECT p FROM price),
  'header', report_header(p_month),
  'total_in',  (SELECT COALESCE(SUM(in_kg),0)  FROM ledger),
  'total_out', (SELECT COALESCE(SUM(out_kg),0) FROM ledger),
  'rows', (SELECT jsonb_agg(jsonb_build_object('date', d, 'opening', closing - in_kg + out_kg, 'in', in_kg,
                   'semasa', closing + out_kg, 'out', out_kg, 'out_amount', out_amt, 'out_prices', out_prices,
                   'buys', buys, 'closing', closing) ORDER BY d) FROM ledger)
);
$$;

-- ===================== v6: ADMIN (report header per month, edit / void records, audit) =====================

-- Every admin edit / void is logged (who changed what, before and after).
CREATE TABLE IF NOT EXISTS stock_entry_audit (
  id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entry_id  BIGINT NOT NULL,
  action    TEXT   NOT NULL CHECK (action IN ('EDIT','VOID')),
  ts        TIMESTAMPTZ NOT NULL DEFAULT now(),
  before    JSONB,
  after     JSONB,
  reason    TEXT
);

-- Wrong-password log, used to lock the admin login after too many attempts.
CREATE TABLE IF NOT EXISTS admin_attempts (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ts TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Raises an error if the running balance is negative on any day from p_from onward.
CREATE OR REPLACE FUNCTION assert_ledger_ok(p_from date) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_d date; v_c numeric;
BEGIN
  SELECT d, c INTO v_d, v_c FROM (
    SELECT d, SUM(net) OVER (ORDER BY d) AS c FROM (
      SELECT entry_date AS d, SUM(CASE entry_type WHEN 'IN' THEN quantity_kg ELSE -quantity_kg END) AS net
      FROM stock_entries WHERE voided_at IS NULL GROUP BY entry_date) x) y
  WHERE c < 0 AND d >= p_from ORDER BY d LIMIT 1;
  IF FOUND THEN RAISE EXCEPTION 'NEGATIVE_BALANCE: % KG on %', v_c, v_d; END IF;
END $$;

-- The records of one day, for the admin edit screen.
CREATE OR REPLACE FUNCTION admin_records_json(p_date date) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'type', entry_type, 'date', entry_date, 'ts', entry_ts, 'source', source, 'qty', quantity_kg,
      'supplier', supplier, 'brand', brand_product, 'cost', cost_per_carton, 'invoice_no', invoice_no,
      'invoice_amount', invoice_amount, 'receiving_1', receiving_1, 'receiving_2', receiving_2,
      'supervisor', supervisor, 'recorded_by', recorded_by, 'files', COALESCE(invoice_files, '[]'::jsonb))
    ORDER BY entry_ts, id), '[]'::jsonb)
  FROM stock_entries WHERE entry_date = p_date AND voided_at IS NULL;
$$;

-- Edit one record. Balances are always computed from entries, so every opening / closing balance after the
-- edited date updates by itself. Refused if any day would go negative.
CREATE OR REPLACE FUNCTION admin_update_entry(p_id bigint, p_d jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_old stock_entries; v_new stock_entries; v_date date; v_bal numeric;
  v_today date := (now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date;
  v_in boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(727001);
  SELECT * INTO v_old FROM stock_entries WHERE id = p_id AND voided_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'NOT_FOUND'; END IF;
  v_in := v_old.entry_type = 'IN';
  v_date := (p_d->>'date')::date;
  IF v_date IS NULL OR v_date > v_today THEN RAISE EXCEPTION 'DATE_IN_FUTURE'; END IF;

  UPDATE stock_entries SET
    entry_date      = v_date,
    quantity_kg     = (p_d->>'qty')::numeric,
    supplier        = CASE WHEN v_in THEN upper(nullif(btrim(p_d->>'supplier'), '')) END,
    brand_product   = CASE WHEN v_in THEN upper(nullif(btrim(p_d->>'brand'), '')) END,
    cost_per_carton = CASE WHEN v_in THEN nullif(p_d->>'cost', '')::numeric END,
    invoice_no      = CASE WHEN v_in THEN upper(nullif(btrim(p_d->>'invoice_no'), '')) END,
    invoice_amount  = CASE WHEN v_in THEN nullif(p_d->>'invoice_amount', '')::numeric END,
    receiving_1     = CASE WHEN v_in THEN upper(nullif(btrim(p_d->>'receiving_1'), '')) END,
    receiving_2     = CASE WHEN v_in THEN upper(nullif(btrim(p_d->>'receiving_2'), '')) END,
    supervisor      = CASE WHEN v_in THEN upper(nullif(btrim(p_d->>'supervisor'), '')) END,
    recorded_by     = CASE WHEN v_in THEN NULL ELSE upper(nullif(btrim(p_d->>'recorded_by'), '')) END,
    invoice_files   = CASE WHEN v_in AND jsonb_typeof(p_d->'files') = 'array' THEN p_d->'files' ELSE invoice_files END
  WHERE id = p_id RETURNING * INTO v_new;

  PERFORM assert_ledger_ok(LEAST(v_old.entry_date, v_date));
  INSERT INTO stock_entry_audit (entry_id, action, before, after) VALUES (p_id, 'EDIT', to_jsonb(v_old), to_jsonb(v_new));

  SELECT COALESCE(SUM(CASE entry_type WHEN 'IN' THEN quantity_kg ELSE -quantity_kg END), 0)
    INTO v_bal FROM stock_entries WHERE voided_at IS NULL;
  RETURN jsonb_build_object('entry', to_jsonb(v_new), 'balance', v_bal);
END $$;

-- Void (soft-delete) one record. The record stays in the database and in the audit log.
CREATE OR REPLACE FUNCTION admin_void_entry(p_id bigint, p_reason text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_old stock_entries; v_new stock_entries; v_bal numeric;
BEGIN
  PERFORM pg_advisory_xact_lock(727001);
  SELECT * INTO v_old FROM stock_entries WHERE id = p_id AND voided_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'NOT_FOUND'; END IF;
  UPDATE stock_entries SET voided_at = now(), void_reason = p_reason WHERE id = p_id RETURNING * INTO v_new;
  PERFORM assert_ledger_ok(v_old.entry_date);
  INSERT INTO stock_entry_audit (entry_id, action, before, after, reason) VALUES (p_id, 'VOID', to_jsonb(v_old), to_jsonb(v_new), p_reason);
  SELECT COALESCE(SUM(CASE entry_type WHEN 'IN' THEN quantity_kg ELSE -quantity_kg END), 0)
    INTO v_bal FROM stock_entries WHERE voided_at IS NULL;
  RETURN jsonb_build_object('balance', v_bal);
END $$;
