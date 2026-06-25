-- =====================================================================
-- 1. TOP 5 FUNDS BY AUM
-- =====================================================================
SELECT 
    fund_house,
    num_schemes,
    aum_crore,
    aum_lakh_crore
FROM fact_aum
WHERE date_id = (SELECT MAX(date_id) FROM fact_aum)
ORDER BY aum_crore DESC
LIMIT 5;


-- =====================================================================
-- 2. AVERAGE NAV PER MONTH
-- =====================================================================
SELECT 
    d.year,
    d.month,
    d.month_name,
    ROUND(AVG(n.nav), 4) AS average_nav
FROM fact_nav n
JOIN dim_date d ON n.date_id = d.date_id
GROUP BY d.year, d.month, d.month_name
ORDER BY d.year DESC, d.month DESC;


-- =====================================================================
-- 3. SIP YEAR-OVER-YEAR (YoY) GROWTH TRENDS
-- =====================================================================
SELECT 
    date_id AS month_start,
    sip_inflow_crore,
    sip_aum_lakh_crore,
    active_sip_accounts_crore,
    yoy_growth_pct AS database_calculated_yoy_pct
FROM fact_sip_industry
WHERE yoy_growth_pct IS NOT NULL
ORDER BY date_id DESC;


-- =====================================================================
-- 4. TOTAL TRANSACTION VALUE & VOLUME BY STATE
-- =====================================================================
SELECT 
    state,
    COUNT(tx_id) AS total_transactions,
    SUM(amount_inr) AS total_investment_inr,
    ROUND(AVG(amount_inr), 2) AS average_ticket_size_inr
FROM fact_transactions
GROUP BY state
ORDER BY total_investment_inr DESC;


-- =====================================================================
-- 5. LOW-COST FUNDS (EXPENSE RATIO < 1%)
-- =====================================================================
SELECT 
    amfi_code,
    account_name AS fund_name,
    telephone_number AS contact_id,  
    expense_ratio_pct
FROM dim_fund
WHERE expense_ratio_pct < 1.0
ORDER BY expense_ratio_pct ASC;


-- =====================================================================
-- 6. PREFERRED PAYMENT MODES BY INVESTOR INCOME GROUP (Custom Choice 1)
-- =====================================================================
SELECT 
    CASE 
        WHEN annual_income_lakh < 5.0 THEN 'Retail (<5 Lakhs)'
        WHEN annual_income_lakh BETWEEN 5.0 AND 15.0 THEN 'Mass Affluent (5-15 Lakhs)'
        ELSE 'HNI (>15 Lakhs)'
    END AS income_segment,
    payment_mode,
    COUNT(tx_id) AS transaction_count,
    SUM(amount_inr) AS volume_inr
FROM fact_transactions
WHERE annual_income_lakh IS NOT NULL
GROUP BY 1, payment_mode
ORDER BY income_segment, transaction_count DESC;


-- =====================================================================
-- 7. TOP 5 EQUITY SECTORS BY PORTFOLIO WEIGHT (Custom Choice 2)
-- =====================================================================
SELECT 
    sector,
    COUNT(DISTINCT stock_symbol) AS unique_stocks_held,
    ROUND(SUM(weight_pct), 2) AS aggregated_portfolio_weight_pct,
    ROUND(SUM(market_value_cr), 2) AS total_market_value_cr
FROM fact_portfolio
WHERE sector IS NOT NULL AND sector != ''
GROUP BY sector
ORDER BY aggregated_portfolio_weight_pct DESC
LIMIT 5;


-- =====================================================================
-- 8. FUNDS RANKED BY TOP RISK-ADJUSTED PERFORMANCE (Custom Choice 3)
-- =====================================================================
SELECT 
    p.amfi_code,
    f.scheme_name,
    f.category,
    p.morningstar_rating,
    p.sharpe_ratio,
    p.alpha,
    p.return_3yr_pct AS annual_3yr_return_pct
FROM fact_performance p
JOIN dim_fund f ON p.amfi_code = f.amfi_code
WHERE p.morningstar_rating >= 4
ORDER BY p.sharpe_ratio DESC, p.alpha DESC
LIMIT 10;


-- =====================================================================
-- 9. TRANSACTION RETENTION RATIO: SIP VS REDEMPTIONS (Custom Choice 4)
-- =====================================================================
SELECT 
    d.year,
    d.month_name,
    SUM(CASE WHEN t.transaction_type = 'SIP' THEN t.amount_inr ELSE 0 END) AS total_sip_inflow,
    SUM(CASE WHEN t.transaction_type = 'Redemption' THEN t.amount_inr ELSE 0 END) AS total_redemption_outflow,
    ROUND(
        SUM(CASE WHEN t.transaction_type = 'SIP' THEN t.amount_inr ELSE 0 END) * 1.0 / 
        NULLIF(SUM(CASE WHEN t.transaction_type = 'Redemption' THEN t.amount_inr ELSE 0 END), 0), 2
    ) AS inflow_to_outflow_ratio
FROM fact_transactions t
JOIN dim_date d ON t.date_id = d.date_id
GROUP BY d.year, d.month, d.month_name
ORDER BY d.year DESC, d.month DESC;


-- =====================================================================
-- 10. REVENUE LEAKAGE ALERT: VALIDATION THRESHOLD BREACHES (Custom Choice 5)
-- =====================================================================
SELECT 
    t.tx_id,
    t.investor_id,
    f.scheme_name,
    t.transaction_type,
    t.amount_inr,
    f.min_sip_amount,
    f.min_lumpsum_amount
FROM fact_transactions t
JOIN dim_fund f ON t.amfi_code = f.amfi_code
WHERE t.below_min_threshold = 1
ORDER BY t.amount_inr ASC
LIMIT 10;