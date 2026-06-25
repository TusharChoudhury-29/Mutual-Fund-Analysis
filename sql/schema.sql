-- ================================================================
-- Bluestock Fintech — Mutual Fund Analytics Platform
-- SQLite Star Schema
-- File: schema.sql
-- ================================================================
--
-- SCHEMA OVERVIEW
-- ───────────────
-- Dimensions : dim_fund  (40 rows)
--              dim_date  (~1,826 rows  |  2022-01-01 → 2026-12-31)
--
-- Core Facts : fact_nav              (~64,320 rows)
--              fact_transactions     (~32,778 rows)
--              fact_performance      (40 rows — point-in-time snapshot)
--              fact_aum              (90 rows)
--              fact_portfolio        (320 rows)
--              fact_sip_industry     (48 rows)
--
-- DESIGN DECISIONS
-- ─────────────────
-- 1. dim_date uses TEXT PK (ISO-8601 'YYYY-MM-DD') — SQLite has no
--    native DATE type; TEXT + date() functions is idiomatic.
-- 2. dim_fund.amfi_code is INTEGER — it is a 6-digit numeric AMFI
--    code (e.g. 100016), not a free-text identifier.
-- 3. fact_performance has no date in the source CSV. An as_of_date
--    column is added (TEXT) so the table supports future re-snapshots
--    without a schema change.
-- 4. fact_aum grain: one row per (fund_house, date). fund_house is
--    NOT an FK to dim_fund because AUM is reported at AMC level, not
--    at scheme level, and dim_fund has no AMC-level PK.
-- 5. Internal cleaning flags (_flag, _anomaly columns) are excluded
--    from the schema — they are ETL metadata, not analytical measures.
-- 6. CHECK constraints are derived from actual observed values in the
--    cleaned CSVs, not from assumed business rules.
-- 7. All FOREIGN KEY constraints use ON DELETE RESTRICT to prevent
--    orphaned fact rows if a dimension record is deleted.
-- 8. Composite UNIQUE constraints enforce grain at each fact table.
-- ================================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;


-- ================================================================
-- DIMENSION TABLES
-- ================================================================

-- ----------------------------------------------------------------
-- dim_fund
-- Source  : clean_01_fund_master.csv
-- Grain   : One row per mutual fund scheme (identified by amfi_code)
-- PK      : amfi_code (INTEGER — 6-digit AMFI scheme code)
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_fund (

    -- Identity
    amfi_code               INTEGER     NOT NULL,
    fund_house              TEXT        NOT NULL,   -- AMC name (SBI MF, HDFC MF, ...)
    scheme_name             TEXT        NOT NULL,

    -- Classification
    category                TEXT        NOT NULL    -- Equity | Debt
                                CHECK (category IN ('Equity', 'Debt')),
    sub_category            TEXT        NOT NULL,   -- Large Cap, Mid Cap, Gilt, Liquid, ...
    plan                    TEXT        NOT NULL    -- Direct | Regular
                                CHECK (plan IN ('Direct', 'Regular')),
    sebi_category_code      TEXT,

    -- Dates & Manager
    launch_date             TEXT,                   -- ISO-8601 date; NULL if unavailable
    fund_manager            TEXT,
    benchmark               TEXT,

    -- Cost / Entry parameters (from actual data: expense 0.55–1.64%, exit 0.0–1.0%)
    expense_ratio_pct       REAL        NOT NULL
                                CHECK (expense_ratio_pct BETWEEN 0.0 AND 3.0),
    exit_load_pct           REAL        NOT NULL    DEFAULT 0.0
                                CHECK (exit_load_pct BETWEEN 0.0 AND 5.0),
    min_sip_amount          INTEGER     NOT NULL
                                CHECK (min_sip_amount > 0),
    min_lumpsum_amount      INTEGER     NOT NULL
                                CHECK (min_lumpsum_amount > 0),

    -- Risk
    risk_category           TEXT
                                CHECK (risk_category IN (
                                    'Low', 'Moderate', 'Moderately High', 'High', 'Very High'
                                )),

    -- Audit
    created_at              TEXT        NOT NULL    DEFAULT (datetime('now')),
    updated_at              TEXT        NOT NULL    DEFAULT (datetime('now')),

    PRIMARY KEY (amfi_code)
);


-- ----------------------------------------------------------------
-- dim_date
-- Source  : Generated — covers 2022-01-01 → 2026-12-31 (1,826 rows)
--           Spans the full date range across all fact tables.
-- Grain   : One row per calendar day
-- PK      : date_id (TEXT, ISO-8601 'YYYY-MM-DD')
-- Note    : financial_year uses Indian FY (April → March)
--           e.g. 2024-05-15 → FY2024-25
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_date (

    date_id                 TEXT        NOT NULL,   -- 'YYYY-MM-DD'

    -- Calendar breakdowns
    year                    INTEGER     NOT NULL,
    quarter                 INTEGER     NOT NULL    CHECK (quarter BETWEEN 1 AND 4),
    month                   INTEGER     NOT NULL    CHECK (month  BETWEEN 1 AND 12),
    month_name              TEXT        NOT NULL,   -- 'January' … 'December'
    week_of_year            INTEGER     NOT NULL    CHECK (week_of_year BETWEEN 1 AND 53),
    day_of_month            INTEGER     NOT NULL    CHECK (day_of_month BETWEEN 1 AND 31),
    day_of_week             INTEGER     NOT NULL    CHECK (day_of_week  BETWEEN 0 AND 6),   -- 0=Mon
    day_name                TEXT        NOT NULL,   -- 'Monday' … 'Sunday'

    -- Boolean flags (stored as 0/1 — SQLite has no BOOLEAN type)
    is_weekday              INTEGER     NOT NULL    DEFAULT 1
                                CHECK (is_weekday      IN (0, 1)),
    is_month_end            INTEGER     NOT NULL    DEFAULT 0
                                CHECK (is_month_end    IN (0, 1)),
    is_quarter_end          INTEGER     NOT NULL    DEFAULT 0
                                CHECK (is_quarter_end  IN (0, 1)),
    is_year_end             INTEGER     NOT NULL    DEFAULT 0
                                CHECK (is_year_end     IN (0, 1)),

    -- Indian Financial Year (April–March)
    financial_year          TEXT        NOT NULL,   -- e.g. 'FY2024-25'
    financial_quarter       TEXT        NOT NULL,   -- e.g. 'Q1FY25'
    financial_month_num     INTEGER     NOT NULL    CHECK (financial_month_num BETWEEN 1 AND 12),
                                                    -- 1=April, 12=March

    PRIMARY KEY (date_id)
);


-- ================================================================
-- FACT TABLES
-- ================================================================

-- ----------------------------------------------------------------
-- fact_nav
-- Source  : clean_02_nav_history.csv  (~64,320 rows after ffill)
-- Grain   : One row per (amfi_code, date) — daily NAV per scheme
-- FK      : amfi_code → dim_fund | date_id → dim_date
-- Note    : daily_return_pct is computed on load:
--             (nav - lag(nav)) / lag(nav) * 100
--           NULL for the first record of each fund (no prior day).
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_nav (

    nav_id                  INTEGER     NOT NULL,

    -- Dimensions
    amfi_code               INTEGER     NOT NULL,
    date_id                 TEXT        NOT NULL,

    -- Measures
    nav                     REAL        NOT NULL    CHECK (nav > 0),
    daily_return_pct        REAL,                   -- NULL for first row per fund

    PRIMARY KEY (nav_id AUTOINCREMENT),
    FOREIGN KEY (amfi_code) REFERENCES dim_fund (amfi_code) ON DELETE RESTRICT,
    FOREIGN KEY (date_id)   REFERENCES dim_date (date_id)   ON DELETE RESTRICT,
    UNIQUE (amfi_code, date_id)                             -- grain enforcement
);

CREATE INDEX IF NOT EXISTS idx_fact_nav_amfi        ON fact_nav (amfi_code);
CREATE INDEX IF NOT EXISTS idx_fact_nav_date        ON fact_nav (date_id);
CREATE INDEX IF NOT EXISTS idx_fact_nav_amfi_date   ON fact_nav (amfi_code, date_id);


-- ----------------------------------------------------------------
-- fact_transactions
-- Source  : clean_08_investor_transactions.csv  (~32,778 rows)
-- Grain   : One row per investor transaction event (tx_id)
-- FK      : amfi_code → dim_fund | date_id → dim_date
-- Note    : Investor demographics are stored here (not normalised
--           into a dim_investor) because investor_id appears in
--           this dataset only — no investor master table exists.
--           below_min_threshold is derived during enrichment:
--           1 if amount < min_sip_amount (SIP) or
--               amount < min_lumpsum_amount (Lumpsum).
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_transactions (

    tx_id                   INTEGER     NOT NULL,

    -- Dimensions
    investor_id             TEXT        NOT NULL,
    amfi_code               INTEGER     NOT NULL,
    date_id                 TEXT        NOT NULL,

    -- Transaction core
    transaction_type        TEXT        NOT NULL
                                CHECK (transaction_type IN ('SIP', 'Lumpsum', 'Redemption')),
    amount_inr              INTEGER     NOT NULL    CHECK (amount_inr > 0),
    payment_mode            TEXT
                                CHECK (payment_mode IN ('UPI', 'Cheque', 'Mandate', 'Net Banking')),

    -- Investor profile (denormalised — no investor master)
    state                   TEXT,
    city                    TEXT,
    city_tier               TEXT        CHECK (city_tier IN ('T30', 'B30')),
    age_group               TEXT        CHECK (age_group IN ('18-25','26-35','36-45','46-55','56+')),
    gender                  TEXT        CHECK (gender IN ('Male', 'Female')),
    annual_income_lakh      REAL        CHECK (annual_income_lakh > 0),
    kyc_status              TEXT        NOT NULL
                                CHECK (kyc_status IN ('Verified', 'Pending', 'Rejected', 'Expired')),

    -- Derived validation flag
    below_min_threshold     INTEGER     NOT NULL    DEFAULT 0
                                CHECK (below_min_threshold IN (0, 1)),

    PRIMARY KEY (tx_id AUTOINCREMENT),
    FOREIGN KEY (amfi_code) REFERENCES dim_fund (amfi_code) ON DELETE RESTRICT,
    FOREIGN KEY (date_id)   REFERENCES dim_date (date_id)   ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_fact_tx_amfi         ON fact_transactions (amfi_code);
CREATE INDEX IF NOT EXISTS idx_fact_tx_date         ON fact_transactions (date_id);
CREATE INDEX IF NOT EXISTS idx_fact_tx_investor     ON fact_transactions (investor_id);
CREATE INDEX IF NOT EXISTS idx_fact_tx_type         ON fact_transactions (transaction_type);
CREATE INDEX IF NOT EXISTS idx_fact_tx_state        ON fact_transactions (state);
CREATE INDEX IF NOT EXISTS idx_fact_tx_city_tier    ON fact_transactions (city_tier);


-- ----------------------------------------------------------------
-- fact_performance
-- Source  : clean_07_scheme_performance.csv  (40 rows)
-- Grain   : One row per (amfi_code, as_of_date) — scheme risk/return snapshot
-- FK      : amfi_code → dim_fund
-- Note    : No date column exists in the source CSV. as_of_date is
--           injected at load time (date of data extraction).
--           The UNIQUE constraint on (amfi_code, as_of_date) allows
--           future re-snapshots without schema changes.
--           max_drawdown_pct CHECK (≤ 0) enforces financial meaning —
--           drawdown is always a loss, never a gain.
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_performance (

    perf_id                 INTEGER     NOT NULL,

    -- Dimensions
    amfi_code               INTEGER     NOT NULL,
    as_of_date              TEXT        NOT NULL,   -- snapshot date, ISO-8601

    -- Return measures
    return_1yr_pct          REAL,
    return_3yr_pct          REAL,
    return_5yr_pct          REAL,
    benchmark_3yr_pct       REAL,                   -- benchmark 3-yr return for comparison

    -- Risk measures
    alpha                   REAL,                   -- Jensen's alpha
    beta                    REAL,                   -- market sensitivity
    sharpe_ratio            REAL,                   -- risk-adjusted return
    sortino_ratio           REAL,                   -- downside risk-adjusted return
    std_dev_ann_pct         REAL        CHECK (std_dev_ann_pct >= 0),
    max_drawdown_pct        REAL        CHECK (max_drawdown_pct <= 0),

    -- Fund snapshot (denormalised for reporting convenience)
    aum_crore               INTEGER     CHECK (aum_crore > 0),
    expense_ratio_pct       REAL        CHECK (expense_ratio_pct BETWEEN 0.0 AND 3.0),

    -- Rating
    morningstar_rating      INTEGER     CHECK (morningstar_rating BETWEEN 1 AND 5),
    risk_grade              TEXT
                                CHECK (risk_grade IN (
                                    'Low', 'Moderate', 'Moderately High', 'High', 'Very High'
                                )),

    PRIMARY KEY (perf_id AUTOINCREMENT),
    FOREIGN KEY (amfi_code) REFERENCES dim_fund (amfi_code) ON DELETE RESTRICT,
    UNIQUE (amfi_code, as_of_date)                          -- grain enforcement
);

CREATE INDEX IF NOT EXISTS idx_fact_perf_amfi       ON fact_performance (amfi_code);
CREATE INDEX IF NOT EXISTS idx_fact_perf_date       ON fact_performance (as_of_date);


-- ----------------------------------------------------------------
-- fact_aum
-- Source  : clean_03_aum_by_fund_house.csv  (90 rows)
-- Grain   : One row per (fund_house, date) — semi-annual AUM per AMC
-- FK      : date_id → dim_date
-- Note    : fund_house is NOT a FK to dim_fund.
--           dim_fund is scheme-level; AUM is AMC-level.
--           Linking by fund_house TEXT is intentional — there is no
--           dim_fund_house table in this schema.
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_aum (

    aum_id                  INTEGER     NOT NULL,

    -- Dimensions
    fund_house              TEXT        NOT NULL,
    date_id                 TEXT        NOT NULL,

    -- Measures
    aum_crore               INTEGER     NOT NULL    CHECK (aum_crore > 0),
    aum_lakh_crore          REAL        NOT NULL    CHECK (aum_lakh_crore > 0),
    num_schemes             INTEGER                 CHECK (num_schemes > 0),

    PRIMARY KEY (aum_id AUTOINCREMENT),
    FOREIGN KEY (date_id) REFERENCES dim_date (date_id) ON DELETE RESTRICT,
    UNIQUE (fund_house, date_id)                         -- grain enforcement
);

CREATE INDEX IF NOT EXISTS idx_fact_aum_fund_house  ON fact_aum (fund_house);
CREATE INDEX IF NOT EXISTS idx_fact_aum_date        ON fact_aum (date_id);


-- ----------------------------------------------------------------
-- fact_portfolio
-- Source  : clean_09_portfolio_holdings.csv  (320 rows)
-- Grain   : One row per (amfi_code, stock_symbol, date) — scheme holdings snapshot
-- FK      : amfi_code → dim_fund | date_id → dim_date
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_portfolio (

    holding_id              INTEGER     NOT NULL,

    -- Dimensions
    amfi_code               INTEGER     NOT NULL,
    date_id                 TEXT        NOT NULL,
    stock_symbol            TEXT        NOT NULL,   -- NSE/BSE ticker, uppercased
    stock_name              TEXT,
    sector                  TEXT,

    -- Measures
    weight_pct              REAL        NOT NULL
                                CHECK (weight_pct > 0 AND weight_pct <= 100),
    market_value_cr         REAL        NOT NULL    CHECK (market_value_cr > 0),
    current_price_inr       REAL        NOT NULL    CHECK (current_price_inr > 0),

    PRIMARY KEY (holding_id AUTOINCREMENT),
    FOREIGN KEY (amfi_code) REFERENCES dim_fund (amfi_code) ON DELETE RESTRICT,
    FOREIGN KEY (date_id)   REFERENCES dim_date (date_id)   ON DELETE RESTRICT,
    UNIQUE (amfi_code, stock_symbol, date_id)               -- grain enforcement
);

CREATE INDEX IF NOT EXISTS idx_fact_port_amfi       ON fact_portfolio (amfi_code);
CREATE INDEX IF NOT EXISTS idx_fact_port_date       ON fact_portfolio (date_id);
CREATE INDEX IF NOT EXISTS idx_fact_port_sector     ON fact_portfolio (sector);
CREATE INDEX IF NOT EXISTS idx_fact_port_symbol     ON fact_portfolio (stock_symbol);


-- ----------------------------------------------------------------
-- fact_sip_industry
-- Source  : clean_04_monthly_sip_inflows.csv  (48 rows)
-- Grain   : One row per month — industry-wide SIP aggregate
-- FK      : date_id → dim_date  (month-start date, e.g. '2022-04-01')
-- Note    : yoy_growth_pct is NULL for the first 12 months by design —
--           no prior year exists to compute growth.
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_sip_industry (

    sip_id                  INTEGER     NOT NULL,

    -- Dimension
    date_id                 TEXT        NOT NULL,   -- month (stored as first day of month)

    -- Measures
    sip_inflow_crore        INTEGER     NOT NULL    CHECK (sip_inflow_crore > 0),
    active_sip_accounts_crore   REAL,
    new_sip_accounts_lakh       REAL,
    sip_aum_lakh_crore          REAL,
    yoy_growth_pct              REAL,               -- NULL for first 12 months (by design)

    PRIMARY KEY (sip_id AUTOINCREMENT),
    FOREIGN KEY (date_id) REFERENCES dim_date (date_id) ON DELETE RESTRICT,
    UNIQUE (date_id)                                     -- one row per month, no duplicates
);

CREATE INDEX IF NOT EXISTS idx_fact_sip_date        ON fact_sip_industry (date_id);


-- ================================================================
-- END OF SCHEMA
-- ================================================================
