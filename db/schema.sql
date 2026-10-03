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

-- Rules apply to NEW rows only (NOT VALID), so records saved before this upgrade never block it.
ALTER TABLE stock_entries DROP CONSTRAINT IF EXISTS upper_only;
ALTER TABLE stock_entries ADD CONSTRAINT upper_only CHECK (
  (supplier    IS NULL OR supplier    = upper(supplier))    AND
  (invoice_no  IS NULL OR invoice_no  = upper(invoice_no))  AND
  (receiving_1 IS NULL OR receiving_1 = upper(receiving_1)) AND
  (receiving_2 IS NULL OR receiving_2 = upper(receiving_2)) AND
  (supervisor  IS NULL OR supervisor  = upper(supervisor))  AND
  (recorded_by IS NULL OR recorded_by = upper(recorded_by))) NOT VALID;

-- New records from the app must be complete; imported history may have gaps.
ALTER TABLE stock_entries DROP CONSTRAINT IF EXISTS in_complete;
ALTER TABLE stock_entries ADD CONSTRAINT in_complete CHECK (
  source <> 'APP' OR
  (entry_type = 'IN'  AND coalesce(supplier,'') <> '' AND coalesce(invoice_no,'') <> ''
                      AND invoice_amount IS NOT NULL
                      AND coalesce(receiving_1,'') <> '' AND coalesce(supervisor,'') <> '') OR
  (entry_type = 'OUT' AND coalesce(recorded_by,'') <> '')) NOT VALID;

CREATE INDEX IF NOT EXISTS stock_entries_date_idx ON stock_entries (entry_date) WHERE voided_at IS NULL;

CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO app_settings VALUES ('out_unit_price','2.50') ON CONFLICT DO NOTHING;  -- RM/KG, from Excel col K

-- The ONLY way the app writes. One call = one atomic transaction.
DROP FUNCTION IF EXISTS add_stock_entry(text, numeric, text, text, numeric, uuid);  -- v1 signature
CREATE OR REPLACE FUNCTION add_stock_entry(
  p_type text, p_qty numeric, p_supplier text, p_invoice_no text, p_invoice_amount numeric,
  p_receiving_1 text, p_receiving_2 text, p_supervisor text, p_recorded_by text, p_key uuid
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_row stock_entries; v_bal numeric; v_price numeric;
BEGIN
  -- 1) Serialise all writers: concurrent users queue here, so the balance check below is never stale.
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

  -- 3) Never let stock go negative.
  SELECT COALESCE(SUM(CASE entry_type WHEN 'IN' THEN quantity_kg ELSE -quantity_kg END),0)
    INTO v_bal FROM stock_entries WHERE voided_at IS NULL;
  IF p_type = 'OUT' AND p_qty > v_bal THEN
    RAISE EXCEPTION 'INSUFFICIENT_STOCK: only % KG available', v_bal;
  END IF;

  SELECT value::numeric INTO v_price FROM app_settings WHERE key = 'out_unit_price';

  INSERT INTO stock_entries (entry_type, entry_date, quantity_kg, supplier, invoice_no, invoice_amount, unit_price,
                             receiving_1, receiving_2, supervisor, recorded_by, idempotency_key)
  VALUES (p_type, (now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date, p_qty,
          upper(nullif(btrim(p_supplier),'')), upper(nullif(btrim(p_invoice_no),'')),
          CASE WHEN p_type = 'IN' THEN p_invoice_amount END,
          CASE WHEN p_type = 'OUT' THEN v_price END,
          upper(nullif(btrim(p_receiving_1),'')), upper(nullif(btrim(p_receiving_2),'')),
          upper(nullif(btrim(p_supervisor),'')),  upper(nullif(btrim(p_recorded_by),'')),
          p_key)
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
  'days', COALESCE((SELECT jsonb_agg(jsonb_build_object('date', d, 'opening', closing - in_kg + out_kg,
                    'in', in_kg, 'out', out_kg, 'closing', closing) ORDER BY d) FROM ledger), '[]'::jsonb),
  'entries', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', id, 'type', entry_type, 'date', entry_date, 'ts', entry_ts,
                    'supplier', supplier, 'invoice_no', invoice_no, 'invoice_amount', invoice_amount,
                    'receiving_1', receiving_1, 'receiving_2', receiving_2, 'supervisor', supervisor,
                    'recorded_by', recorded_by, 'qty', quantity_kg) ORDER BY entry_ts, id)
              FROM stock_entries, bounds
              WHERE voided_at IS NULL AND entry_date >= first_day AND entry_date < next_first), '[]'::jsonb)
);
$$;
