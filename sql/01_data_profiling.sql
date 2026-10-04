-- =============================================================================
-- 01_data_profiling.sql
-- GA4 Funnel Drop-off Analysis -- Data Profiling
-- Dataset: bigquery-public-data.ga4_obfuscated_sample_ecommerce (Nov 2020 - Jan 2021)

-- PURPOSE:
-- Profile and quality-check the data before building the funnel. These queries establish which events exist and which form the purchase funnel, whether the segmentation fields are populated enough to use, 
-- and whether the 92-day window is continuous and stable, and whether the event stream itself is trustworthy. A funnel built on a rarely fired event, or a metric built on duplicate events, looks clean but means nothing.

-- Note on cleaning: this is a read-only public dataset, so cleaning cannot be a mutation step. Instead, every exclusion is expressed as a filter inside the query and documented here, which keeps the raw data intact and every decision visible.
-- =============================================================================

-- QUERY 1 -- Event profile
-- Lists every event type with event counts and unique user counts, to identify the purchase funnel steps. Unique users matter more than event count here, because a funnel measures the share of people reaching each step, 
-- not how often an event fired.

SELECT
    event_name,
    COUNT(*) AS event_count,
    COUNT(DISTINCT user_pseudo_id) AS unique_users
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
GROUP BY event_name
ORDER BY event_count DESC;


-- QUERY 2 -- Segment coverage
-- Checks whether device. category and traffic_source.medium are actually populated before any segment analysis is built on them. Crossed together rather than run separately, so field coverage and the interaction 
-- between the two are visible at once.

SELECT
    device.category AS device_category,
    traffic_source.medium AS traffic_medium,
    COUNT(DISTINCT user_pseudo_id) AS users
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
GROUP BY device_category, traffic_medium
ORDER BY users DESC
LIMIT 30;


-- QUERY 3 -- Daily volume and continuity
-- Checks for missing days and establishes what a normal day looks like. Needed before asking whether a drop-off holds across time or comes from a few outlier days. COUNTIF counts rows where 
-- the condition is true -- the same pattern builds the per-user funnel flags in 02_funnel_analysis.sql.

SELECT
    event_date,
    COUNT(DISTINCT user_pseudo_id) AS daily_users,
    COUNTIF(event_name = 'purchase') AS purchase_events
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
GROUP BY event_date
ORDER BY event_date;


-- QUERY 4 -- Raw row inspection
-- Looks at actual rows rather than aggregates, to confirm the grain of the table (one row per event, with user and context attached to every row) and to see which flat columns are populated. ecommerce.purchase_revenue is 
-- NULL on every event except purchase, which is correct behaviour, not missing data.

SELECT
    event_date,
    event_timestamp,
    event_name,
    user_pseudo_id,
    device.category AS device_category,
    device.operating_system AS os,
    geo.country AS country,
    traffic_source.medium AS traffic_medium,
    ecommerce.purchase_revenue AS purchase_revenue
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX = '20201201'
LIMIT 50;


-- QUERY 5 -- One user's full journey
-- Picks a single purchaser and lists every event they fired in timestamp order, to see whether a real journey matches the assumed funnel. Aggregates hide sequence; this is the fastest way to sanity-check the funnel definition against reality.

WITH one_buyer AS (
    SELECT user_pseudo_id
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX = '20201201'
      AND event_name = 'purchase'
    LIMIT 1
)
SELECT
    event_timestamp,
    event_name,
    device.category AS device_category,
    ecommerce.purchase_revenue AS revenue
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX = '20201201'
  AND user_pseudo_id IN (SELECT user_pseudo_id FROM one_buyer)
ORDER BY event_timestamp;


-- QUERY 6 -- Basic integrity check
-- Checks for null identifiers and exact-duplicate events (same user, same event, same microsecond). 
-- NOTE: This check is too narrow -- it only catches events firing at the identical timestamp, and misses the real duplicates found in Query 8, which fire seconds apart. Kept here because the null checks are still useful and
-- because the limitation is worth knowing.

SELECT
    COUNT(*) AS total_events,
    COUNTIF(user_pseudo_id IS NULL) AS null_user_id,
    COUNTIF(event_name IS NULL) AS null_event_name,
    COUNT(DISTINCT CONCAT(CAST(event_timestamp AS STRING), user_pseudo_id, event_name))
        AS distinct_event_signatures
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131';


-- QUERY 7 -- Purchase events per user
-- The single-user journey showed two purchase events 77 seconds apart with identical revenue, which suggested duplicate firing. This measures how widespread that is, across all purchasers, rather than generalising from one example.

SELECT
    purchases_per_user,
    COUNT(*) AS user_count
FROM (
    SELECT
        user_pseudo_id,
        COUNTIF(event_name = 'purchase') AS purchases_per_user
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    GROUP BY user_pseudo_id
    HAVING purchases_per_user > 0
)
GROUP BY purchases_per_user
ORDER BY purchases_per_user;


-- QUERY 8 -- Transaction ID integrity
-- Separates two different explanations for users with many purchase events: genuine repeat buying (each event has its own transaction ID) versus duplicate firing or placeholder IDs. 
-- This is what determines whether revenue can be used at all.

SELECT
    COUNT(*) AS purchase_events,
    COUNTIF(ecommerce.transaction_id IS NULL) AS null_txn_id,
    COUNTIF(ecommerce.transaction_id = '(not set)') AS not_set_txn_id,
    COUNTIF(ecommerce.purchase_revenue IS NULL) AS null_revenue,
    COUNT(DISTINCT ecommerce.transaction_id) AS distinct_txn_ids
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  AND event_name = 'purchase';


-- =============================================================================
-- FINDINGS
-- (Profiling stage. The funnel definition and device plan were later revised in 02_funnel_analysis.sql -- marked [REVISED] below.)
--
-- FUNNEL
-- * Steps: all users -> view_item -> add_to_cart -> begin_checkout -> add_payment_info -> purchase
-- * begin_checkout (9,715) and add_shipping_info (9,714) fire together -> collapsed into one step
-- * Denominator = total_users (270,154), not page_view (269,792)
-- * [REVISED] add_to_cart is a path attribute, not a step -- 34% of purchasers never fired it (02, Query 3)

-- SEGMENTATION
-- * Device: no placeholders -> primary dimension
--   desktop 156,905 | mobile 107,175 | tablet 6,074 (first-event device, 02 Q7)
--   Do NOT sum Query 2's rows -- users appear in several rows, inflating totals
-- * Traffic medium = channel that FIRST ACQUIRED the user
--   ~1/5 are placeholders (<Other>, (data deleted)) -> excluded
--   '(none)' = direct traffic -> kept
-- * New vs returning: dropped -- ~96% first arrived within the window
-- * Tablet (2.2% of users): low-sample, reported with a warning only
-- * [REVISED] No device gap exists: desktop 1.60%, mobile 1.68%, tablet 1.63% end-to-end (02, Query 7)

-- TIME
-- * All 92 days present, no gaps
-- * Purchase events per daily user: Nov 2.19% | Dec 2.05% | Jan 1.13% (relative indicator only, not a true conversion rate)
-- * Purchase cliff on Dec 18/19 -- Christmas shipping cutoff
-- * Full 92 days used for the funnel (only 4,419 purchasers), with findings validated separately per period

-- EVENT INTEGRITY
-- * No NULL user IDs or event names (4,295,584 events)
-- * Query 6 missed the real duplicates -- it only catches same-microsecond events
-- * Purchase events are NOT a reliable order count:
--     5,692 purchase events
--     - 906 with no usable transaction ID (15.9%)
--     = 4,786 with a real ID -> 4,451 distinct -> 335 duplicates (7.0%)
--     450 events with no revenue (7.9%)

-- DECISIONS THIS DROVE
-- * Funnel is unaffected -- it counts distinct users, immune to duplicates
-- * No revenue figure reported anywhere
-- * Only opportunity figure is an UPPER BOUND: 4,058 x 14.47pp = ~587 extra
--   purchasers over 92 days, IF the whole gap were caused by the path
--   (unlikely -- self-selection is probably a large part of it)

-- LIMITATIONS
-- * Obfuscated by Google (method unpublished) -- trust relative comparisons, not absolute rates or counts
-- * user_pseudo_id is device-level: one person on two devices = two users
-- =============================================================================
