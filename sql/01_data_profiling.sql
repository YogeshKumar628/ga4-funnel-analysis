-- =============================================================================
-- 01_data_profiling.sql
-- GA4 Funnel Drop-off Analysis -- Data Profiling
-- Dataset: bigquery-public-data.ga4_obfuscated_sample_ecommerce (Nov 2020 - Jan 2021)
--
-- PURPOSE
-- Profile and quality-check the data before building the funnel. These queries
-- establish which events exist and which form the purchase funnel, whether the
-- segmentation fields are populated enough to use, whether the 92-day window is
-- continuous and stable, and whether the event stream itself is trustworthy.
-- A funnel built on a rarely-fired event, or a metric built on duplicated events,
-- looks clean and means nothing.
--
-- Note on cleaning: this is a read-only public dataset, so cleaning cannot be a
-- mutation step. Instead every exclusion is expressed as a filter inside the query
-- and documented here, which keeps the raw data intact and every decision visible.
-- =============================================================================


-- QUERY 1 -- Event profile
-- Lists every event type with event counts and unique user counts, to identify the
-- purchase funnel steps. Unique users matters more than event count here, because a
-- funnel measures the share of people reaching each step, not how often an event
-- fired.

SELECT
    event_name,
    COUNT(*) AS event_count,
    COUNT(DISTINCT user_pseudo_id) AS unique_users
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
GROUP BY event_name
ORDER BY event_count DESC;


-- QUERY 2 -- Segment coverage
-- Checks whether device.category and traffic_source.medium are actually populated
-- before any segment analysis is built on them. Crossed together rather than run
-- separately, so field coverage and the interaction between the two are visible at
-- once.

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
-- Checks for missing days and establishes what a normal day looks like. Needed
-- before asking whether a drop-off holds across time or comes from a few outlier
-- days. COUNTIF counts rows where the condition is true -- the same pattern builds
-- the per-user funnel flags below.

SELECT
    event_date,
    COUNT(DISTINCT user_pseudo_id) AS daily_users,
    COUNTIF(event_name = 'purchase') AS purchase_events
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
GROUP BY event_date
ORDER BY event_date;


-- QUERY 4 -- Raw row inspection
-- Looks at actual rows rather than aggregates, to confirm the grain of the table
-- (one row per event, with user and context attached to every row) and to see which
-- flat columns are populated. ecommerce.purchase_revenue is NULL on every event
-- except purchase, which is correct behaviour, not missing data.

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
-- Picks a single purchaser and lists every event they fired in timestamp order, to
-- see whether a real journey matches the assumed funnel. Aggregates hide sequence;
-- this is the fastest way to sanity-check the funnel definition against reality.

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
-- Checks for null identifiers and exact-duplicate events (same user, same event,
-- same microsecond). NOTE: this check is too narrow -- it only catches events firing
-- at the identical timestamp, and missed the real duplicates found in Query 8,
-- which fire seconds apart. Kept here because the null checks are still useful and
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
-- The single-user journey showed two purchase events 77 seconds apart with
-- identical revenue, which suggested duplicate firing. This measures how widespread
-- that is across all purchasers, rather than generalising from one example.

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
-- Separates two different explanations for users with many purchase events: genuine
-- repeat buying (each event has its own transaction ID) versus duplicate firing or
-- placeholder IDs. This is what determines whether revenue can be used at all.

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
--
-- FUNNEL DEFINITION
-- Steps: all users -> view_item -> add_to_cart -> begin_checkout ->
-- add_payment_info -> purchase. begin_checkout (9,715 users) and add_shipping_info
-- (9,714) differ by one user, so they fire together and are collapsed into one step
-- rather than counted as two separate customer decisions.
-- Denominator is total_users (270,154), not page_view (269,792). The 362-user gap
-- is users who fired events without a page_view (~0.13%, immaterial).
--
-- SEGMENTATION
-- device.category is 100% clean (desktop ~192k, mobile ~132k, tablet ~7.5k) and
-- becomes the primary dimension. traffic_source.medium is ~79% usable; '(none)'
-- means direct traffic and is kept, while <Other> and (data deleted) (~21%) are
-- excluded from source-level analysis. New-vs-returning is dropped -- ~96% of users
-- are first-time visitors, so the returning group is too small to compare.
-- Tablet is only ~2.3% of traffic, so its bottom-funnel rates are low-sample and
-- are reported with a warning rather than treated as findings.
-- Desktop skews organic, mobile skews direct -- this interaction is the confounder
-- to test when any device gap appears.
--
-- TIME
-- All 92 days present, no gaps. Conversion is not stationary: Nov 2.19%, Dec 2.05%,
-- Jan 1.13%. Purchases fall off a cliff on Dec 18/19 (consistent with a Christmas
-- shipping cutoff) and stay low until mid-January. Weekends are consistently
-- quieter, so any A/B test designed on this data must run in whole weeks.
-- Decision: use the full 92 days for the headline funnel (only 4,419 purchasers
-- total, so restricting further leaves too little), then validate the device gap
-- separately within gift season and within the trough.
--
-- EVENT INTEGRITY
-- No null user_pseudo_id or event_name across 4,295,584 events.
-- Purchase events are NOT reliable as an order count:
--   - 5,692 raw purchase events across 4,419 users
--   - 906 events (15.9%) have no usable transaction ID (23 NULL + 883 '(not set)')
--   - of the 4,786 events with a real ID, only 4,451 are distinct -> 335 excess
--     events, a 7.0% duplication rate among verifiable transactions
--   - 450 events (7.9%) have no revenue value at all
-- 82.5% of purchasers (3,644 of 4,419) have exactly one purchase event, so the
-- problem is concentrated in the remaining 17%.
--
-- CONSEQUENCE FOR THE ANALYSIS
-- The funnel is unaffected -- it counts distinct users per step, so duplicate events
-- cannot inflate it. Revenue-based opportunity sizing is REJECTED: with 16% of
-- purchase events unattributable and 8% missing revenue, any dollar figure carries
-- a large unquantifiable error. Opportunity is sized in USERS instead (e.g. if
-- mobile converted at desktop's payment-step rate, N more users would have
-- purchased), computed entirely from clean distinct-user counts.
--
-- LIMITATIONS
-- 1. Data is obfuscated by Google. Absolute rates are NOT the real store's rates;
--    only relative comparisons between steps and segments are trustworthy.
-- 2. user_pseudo_id is a device-level cookie ID, so the same person on phone and
--    laptop counts as two users. Sessions per user is ~1.33 over 92 days, which is
--    implausibly low for a real store and reflects this.
-- 3. ~21% of traffic_source.medium and ~16% of purchase transaction IDs are
--    placeholder values and are excluded where relevant.
-- =============================================================================
