-- =============================================================================
-- 02_funnel_analysis.sql
-- GA4 Funnel Drop-off Analysis -- Funnel Construction and Segmentation
-- Dataset: bigquery-public-data.ga4_obfuscated_sample_ecommerce (Nov 2020 - Jan 2021)
--
-- PURPOSE
-- Build the purchase funnel, validate its definition against how users actually
-- behave, and test whether any drop-off differs by segment. The funnel definition
-- arrived at here is NOT the one this file starts with -- Query 3 showed that a
-- third of purchasers bypass add_to_cart entirely, which forced a rebuild.
--
-- DESIGN DECISIONS (both are standard interview questions)
-- 1. User-level, not session-level. ~96% of users are first-time visitors with
--    ~1.33 sessions each over 92 days, so the two definitions nearly collapse into
--    one another; where they differ, user-level does not split a single buying
--    journey across two sessions. Query 4 validates that the 92-day window is not
--    too generous.
-- 2. "Ever fired" rather than strict event ordering. Simpler and standard, but
--    only defensible if violations are rare -- Query 2 measures exactly that.
-- =============================================================================


-- QUERY 1 -- The funnel
-- Collapses ~4.3M event rows into one row per user, with a 0/1 flag per funnel step,
-- then sums the flags to count users at each step. MAX(CASE WHEN ...) rather than
-- COUNTIF because a funnel asks whether a user EVER reached a step, not how many
-- times they fired the event.

WITH user_steps AS (
    SELECT
        user_pseudo_id,
        MAX(CASE WHEN event_name = 'page_view'        THEN 1 ELSE 0 END) AS s1_page_view,
        MAX(CASE WHEN event_name = 'view_item'        THEN 1 ELSE 0 END) AS s2_view_item,
        MAX(CASE WHEN event_name = 'add_to_cart'      THEN 1 ELSE 0 END) AS s3_add_to_cart,
        MAX(CASE WHEN event_name = 'begin_checkout'   THEN 1 ELSE 0 END) AS s4_checkout,
        MAX(CASE WHEN event_name = 'add_payment_info' THEN 1 ELSE 0 END) AS s5_payment,
        MAX(CASE WHEN event_name = 'purchase'         THEN 1 ELSE 0 END) AS s6_purchase
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    GROUP BY user_pseudo_id
)
SELECT
    COUNT(*)          AS total_users,
    SUM(s1_page_view) AS reached_page_view,
    SUM(s2_view_item) AS reached_view_item,
    SUM(s3_add_to_cart) AS reached_add_to_cart,
    SUM(s4_checkout)  AS reached_checkout,
    SUM(s5_payment)   AS reached_payment,
    SUM(s6_purchase)  AS reached_purchase
FROM user_steps;


-- QUERY 2 -- Event ordering violations
-- Tests the "ever fired" decision. MIN(CASE WHEN ... THEN event_timestamp END) gives
-- each user's earliest timestamp per event (no ELSE, so non-matching rows are NULL
-- and MIN skips them). Each COUNTIF then counts one kind of violation: doing a step
-- without the previous one, or doing it before the previous one.

WITH user_first_times AS (
    SELECT
        user_pseudo_id,
        MIN(CASE WHEN event_name = 'view_item'        THEN event_timestamp END) AS first_view_item,
        MIN(CASE WHEN event_name = 'add_to_cart'      THEN event_timestamp END) AS first_add_to_cart,
        MIN(CASE WHEN event_name = 'begin_checkout'   THEN event_timestamp END) AS first_checkout,
        MIN(CASE WHEN event_name = 'add_payment_info' THEN event_timestamp END) AS first_payment,
        MIN(CASE WHEN event_name = 'purchase'         THEN event_timestamp END) AS first_purchase
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    GROUP BY user_pseudo_id
)
SELECT
    COUNTIF(first_add_to_cart IS NOT NULL AND first_view_item IS NULL)  AS cart_without_any_view,
    COUNTIF(first_add_to_cart < first_view_item)                        AS cart_before_view,
    COUNTIF(first_purchase IS NOT NULL AND first_add_to_cart IS NULL)   AS purchase_without_any_cart,
    COUNTIF(first_purchase < first_checkout)                            AS purchase_before_checkout
FROM user_first_times;


-- QUERY 3 -- Actual paths taken by purchasers
-- Query 2 flagged 1,504 purchasers with no add_to_cart event -- 34% of all buyers.
-- Two possible explanations: a real path that skips the cart, or broken tracking.
-- This lists every distinct step pattern among purchasers rather than assuming one,
-- which is what distinguishes the two.

WITH user_paths AS (
    SELECT
        user_pseudo_id,
        MAX(CASE WHEN event_name = 'view_item'        THEN 1 ELSE 0 END) AS did_view,
        MAX(CASE WHEN event_name = 'add_to_cart'      THEN 1 ELSE 0 END) AS did_cart,
        MAX(CASE WHEN event_name = 'begin_checkout'   THEN 1 ELSE 0 END) AS did_checkout,
        MAX(CASE WHEN event_name = 'add_payment_info' THEN 1 ELSE 0 END) AS did_payment,
        MAX(CASE WHEN event_name = 'purchase'         THEN 1 ELSE 0 END) AS did_purchase
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    GROUP BY user_pseudo_id
)
SELECT
    did_view,
    did_cart,
    did_checkout,
    did_payment,
    COUNT(*) AS users
FROM user_paths
WHERE did_purchase = 1
GROUP BY did_view, did_cart, did_checkout, did_payment
ORDER BY users DESC;


-- QUERY 4 -- Time from first item view to purchase
-- Tests the user-level decision. event_timestamp is in microseconds, so dividing by
-- 86,400,000,000 converts to days. APPROX_QUANTILES(x, 100) splits values into 100
-- buckets and returns the boundaries; [OFFSET(50)] is the median, [OFFSET(90)] the
-- 90th percentile. Median and p90 matter more than the mean on a skewed distribution.

WITH user_journey AS (
    SELECT
        user_pseudo_id,
        MIN(CASE WHEN event_name = 'view_item' THEN event_timestamp END) AS first_view,
        MIN(CASE WHEN event_name = 'purchase'  THEN event_timestamp END) AS first_purchase
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    GROUP BY user_pseudo_id
)
SELECT
    COUNT(*) AS purchasers_with_view,
    ROUND(AVG((first_purchase - first_view) / 86400000000.0), 2) AS avg_days_to_purchase,
    ROUND(APPROX_QUANTILES((first_purchase - first_view) / 86400000000.0, 100)[OFFSET(50)], 2) AS median_days,
    ROUND(APPROX_QUANTILES((first_purchase - first_view) / 86400000000.0, 100)[OFFSET(90)], 2) AS p90_days
FROM user_journey
WHERE first_purchase IS NOT NULL AND first_view IS NOT NULL;


-- QUERY 5 -- Cart path vs direct path
-- With add_to_cart reclassified from a funnel gate to a path attribute, this
-- compares conversion between users who reached checkout via the cart and those who
-- went straight there. SAFE_DIVIDE returns NULL instead of erroring on a zero
-- denominator.

WITH user_steps AS (
    SELECT
        user_pseudo_id,
        MAX(CASE WHEN event_name = 'add_to_cart'      THEN 1 ELSE 0 END) AS did_cart,
        MAX(CASE WHEN event_name = 'begin_checkout'   THEN 1 ELSE 0 END) AS did_checkout,
        MAX(CASE WHEN event_name = 'add_payment_info' THEN 1 ELSE 0 END) AS did_payment,
        MAX(CASE WHEN event_name = 'purchase'         THEN 1 ELSE 0 END) AS did_purchase
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    GROUP BY user_pseudo_id
)
SELECT
    CASE WHEN did_cart = 1 THEN 'cart path' ELSE 'direct path' END AS path_type,
    COUNT(*)          AS users_at_checkout,
    SUM(did_payment)  AS reached_payment,
    SUM(did_purchase) AS reached_purchase,
    ROUND(SAFE_DIVIDE(SUM(did_payment), COUNT(*)) * 100, 1)          AS checkout_to_payment_pct,
    ROUND(SAFE_DIVIDE(SUM(did_purchase), SUM(did_payment)) * 100, 1) AS payment_to_purchase_pct
FROM user_steps
WHERE did_checkout = 1
GROUP BY path_type;


-- QUERY 6 -- How many users appear on more than one device
-- Device lives on every event row, not on the user, so a user with events on two
-- devices needs an assignment rule. This measures how often that situation arises
-- before choosing one.

SELECT
    device_count,
    COUNT(*) AS users
FROM (
    SELECT
        user_pseudo_id,
        COUNT(DISTINCT device.category) AS device_count
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    GROUP BY user_pseudo_id
)
GROUP BY device_count
ORDER BY device_count;


-- QUERY 7 -- Funnel by device
-- Assignment rule: each user takes the device from their EARLIEST event -- the
-- device they arrived on. Assigning device at purchase instead would bias the
-- comparison by labelling users where they ended up rather than where they started.
-- ROW_NUMBER() OVER (PARTITION BY user ORDER BY timestamp) numbers each user's
-- events chronologically, restarting per user; WHERE rn = 1 keeps the first.

WITH user_device AS (
    SELECT
        user_pseudo_id,
        device.category AS device_category,
        ROW_NUMBER() OVER (PARTITION BY user_pseudo_id ORDER BY event_timestamp) AS rn
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),
first_device AS (
    SELECT user_pseudo_id, device_category
    FROM user_device
    WHERE rn = 1
),
user_steps AS (
    SELECT
        user_pseudo_id,
        MAX(CASE WHEN event_name = 'view_item'        THEN 1 ELSE 0 END) AS did_view,
        MAX(CASE WHEN event_name = 'add_to_cart'      THEN 1 ELSE 0 END) AS did_cart,
        MAX(CASE WHEN event_name = 'begin_checkout'   THEN 1 ELSE 0 END) AS did_checkout,
        MAX(CASE WHEN event_name = 'add_payment_info' THEN 1 ELSE 0 END) AS did_payment,
        MAX(CASE WHEN event_name = 'purchase'         THEN 1 ELSE 0 END) AS did_purchase
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    GROUP BY user_pseudo_id
)
SELECT
    d.device_category,
    COUNT(*)            AS total_users,
    SUM(s.did_view)     AS reached_view_item,
    SUM(s.did_checkout) AS reached_checkout,
    SUM(s.did_payment)  AS reached_payment,
    SUM(s.did_purchase) AS reached_purchase,
    SUM(s.did_cart)     AS used_cart
FROM user_steps s
JOIN first_device d ON s.user_pseudo_id = d.user_pseudo_id
GROUP BY d.device_category
ORDER BY total_users DESC;


-- QUERY 8 -- Path gap by time period
-- Checks whether the path gap is structural or a seasonal artefact. Users are bucketed
-- by the period of their FIRST event, so each user sits in exactly one period -- a
-- per-event assignment would place the same user in two periods and contaminate the
-- comparison. event_date is a YYYYMMDD string, which sorts lexically in the same order
-- as chronologically, so string comparison is safe here.

WITH user_first_event AS (
    SELECT
        user_pseudo_id,
        MIN(event_date) AS first_date
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    GROUP BY user_pseudo_id
),
user_period AS (
    SELECT
        user_pseudo_id,
        CASE
            WHEN first_date <= '20201218' THEN '1_gift_season'
            WHEN first_date <= '20210118' THEN '2_trough'
            ELSE '3_recovery'
        END AS period
    FROM user_first_event
),
user_steps AS (
    SELECT
        user_pseudo_id,
        MAX(CASE WHEN event_name = 'add_to_cart'      THEN 1 ELSE 0 END) AS did_cart,
        MAX(CASE WHEN event_name = 'begin_checkout'   THEN 1 ELSE 0 END) AS did_checkout,
        MAX(CASE WHEN event_name = 'add_payment_info' THEN 1 ELSE 0 END) AS did_payment,
        MAX(CASE WHEN event_name = 'purchase'         THEN 1 ELSE 0 END) AS did_purchase
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    GROUP BY user_pseudo_id
)
SELECT
    p.period,
    CASE WHEN s.did_cart = 1 THEN 'cart path' ELSE 'direct path' END AS path_type,
    COUNT(*)            AS users_at_checkout,
    SUM(s.did_payment)  AS reached_payment,
    SUM(s.did_purchase) AS reached_purchase,
    ROUND(SAFE_DIVIDE(SUM(s.did_payment), COUNT(*)) * 100, 1)  AS checkout_to_payment_pct,
    ROUND(SAFE_DIVIDE(SUM(s.did_purchase), COUNT(*)) * 100, 1) AS checkout_to_purchase_pct
FROM user_steps s
JOIN user_period p ON s.user_pseudo_id = p.user_pseudo_id
WHERE s.did_checkout = 1
GROUP BY p.period, path_type
ORDER BY p.period, path_type;


-- QUERY 9 -- Path gap by traffic channel
-- Final confounder check: does the path gap survive within each acquisition channel,
-- or is it driven by one channel's traffic mix? Placeholder mediums are excluded
-- INSIDE the first_medium CTE, after rn = 1, so a user whose first event has no usable
-- medium is dropped rather than reassigned to their second event's medium -- dropping
-- is honest, reassigning would be a guess. '(none)' is kept: in GA it means direct
-- traffic (typed URL, bookmark, no referrer), which is a real channel.

WITH user_first_event AS (
    SELECT
        user_pseudo_id,
        traffic_source.medium AS traffic_medium,
        ROW_NUMBER() OVER (PARTITION BY user_pseudo_id ORDER BY event_timestamp) AS rn
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),
first_medium AS (
    SELECT user_pseudo_id, traffic_medium
    FROM user_first_event
    WHERE rn = 1
      AND traffic_medium NOT IN ('<Other>', '(data deleted)')
),
user_steps AS (
    SELECT
        user_pseudo_id,
        MAX(CASE WHEN event_name = 'add_to_cart'    THEN 1 ELSE 0 END) AS did_cart,
        MAX(CASE WHEN event_name = 'begin_checkout' THEN 1 ELSE 0 END) AS did_checkout,
        MAX(CASE WHEN event_name = 'purchase'       THEN 1 ELSE 0 END) AS did_purchase
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    GROUP BY user_pseudo_id
)
SELECT
    m.traffic_medium,
    CASE WHEN s.did_cart = 1 THEN 'cart path' ELSE 'direct path' END AS path_type,
    COUNT(*)            AS users_at_checkout,
    SUM(s.did_purchase) AS reached_purchase,
    ROUND(SAFE_DIVIDE(SUM(s.did_purchase), COUNT(*)) * 100, 1) AS checkout_to_purchase_pct
FROM user_steps s
JOIN first_medium m ON s.user_pseudo_id = m.user_pseudo_id
WHERE s.did_checkout = 1
GROUP BY m.traffic_medium, path_type
ORDER BY m.traffic_medium, path_type;


-- =============================================================================
-- FINDINGS
--
-- THE INITIAL FUNNEL (Query 1), which matched the Day 1 profiling exactly:
--   all users 270,154 -> view_item 61,252 (22.7%) -> add_to_cart 12,545 (20.5%)
--   -> begin_checkout 9,715 (77.4%) -> add_payment_info 5,751 (59.2%)
--   -> purchase 4,419 (76.8%).  End-to-end 1.6%.
-- Denominator is total_users, not page_view: 362 users (0.13%) fired events without
-- a page_view.
--
-- WHY THAT FUNNEL WAS WRONG (Queries 2 and 3)
-- Ordering violations were negligible for most steps (6, 3 and 1 users), BUT 1,504
-- purchasers -- 34% of all buyers -- had no add_to_cart event at all. Query 3 settled
-- the cause: every one of the 4,419 purchasers fired begin_checkout, and 4,418 fired
-- add_payment_info. Broken tracking would scatter failures across steps; instead the
-- later steps are 100% complete while add_to_cart is missing for exactly a third.
-- That is a second real route into checkout (a buy-now path), not lost events.
-- Purchaser paths:
--   view -> cart -> checkout -> payment   2,915 (66.0%)
--   view -> [no cart] -> checkout -> payment  1,478 (33.4%)
--   no view -> no cart -> checkout -> payment    25 (0.6%)
--
-- CORRECTED FUNNEL: all users -> view_item -> begin_checkout -> add_payment_info
-- -> purchase, with add_to_cart demoted from a gate to a PATH ATTRIBUTE.
--
-- USER-LEVEL DEFINITION VALIDATED (Query 4)
-- Median time from first item view to purchase is 0.03 days (~43 minutes); p90 is
-- 14.1 days; mean 4.13. The mean-median gap shows a heavily skewed distribution, so
-- the median is the number to quote. A 92-day window is generous but not smearing
-- unrelated activity together.
--
-- THE MAIN FINDING (Query 5)
--   cart path   5,657 at checkout -> 64.6% to payment -> 79.8% to purchase = 51.5%
--   direct path 4,058 at checkout -> 51.7% to payment -> 71.8% to purchase = 37.1%
-- A 14.4pp gap in end-to-end checkout conversion, worse at BOTH stages, not one.
--
-- DEVICE: NULL RESULT (Queries 6 and 7)
-- 98.5% of users appear on exactly one device, so the first-event assignment rule
-- affects only 1.5% and no conclusion depends on it.
-- End-to-end conversion: desktop 1.60%, mobile 1.68%, tablet 1.63%. Every step is
-- within ~1pp across devices, and mobile is marginally BETTER than desktop. The
-- expected mobile-checkout problem does not exist in this data. Reported as a
-- finding, and it also rules device out as a confounder for the path gap.
-- Caution: three devices with very different sample sizes producing near-identical
-- rates is unusually clean and may partly be an obfuscation artefact.
--
-- PATH GAP HOLDS ACROSS TIME (Query 8) -- checkout -> purchase
--   gift season  cart 50.3% vs direct 36.4%  (gap 13.9pp, n = 4,065 / 3,551)
--   trough       cart 51.4% vs direct 42.9%  (gap  8.5pp, n =   938 /   301)
--   recovery     cart 59.2% vs direct 40.8%  (gap 18.4pp, n =   654 /   206)
-- Never closes or reverses. The trough and recovery direct-path arms are thin
-- (301 and 206 users) and should not carry the headline.
-- Secondary observation: the direct path carried 47% of checkout traffic in gift
-- season but only 24% afterwards, and cart-path conversion rose steadily as it fell
-- (50.3% -> 51.4% -> 59.2%). Consistent with gift season bringing lower-intent
-- traffic that preferred the fast path -- which SUPPORTS the selection-effect
-- explanation rather than the path-design one.
--
-- PATH GAP HOLDS ACROSS CHANNELS (Query 9) -- checkout -> purchase
--   (none)/direct  cart 50.3% vs direct 34.5%  (gap 15.8pp)
--   organic        cart 51.4% vs direct 35.4%  (gap 16.0pp)
--   referral       cart 52.5% vs direct 40.4%  (gap 12.1pp)
--   cpc            cart 53.2% vs direct 39.0%  (gap 14.2pp, n = 200 direct, thin)
-- The cart-path column spans under 3pp across four channels while path moves
-- conversion by 12-16pp within every one of them. Traffic mix is ruled out.
-- ~21% of users are excluded here (placeholder mediums) -- state this wherever these
-- numbers appear, not only in the limitations section.
--
-- WHAT THIS DOES AND DOES NOT ESTABLISH
-- Established: the direct-to-checkout path converts 12-18pp worse than the cart
-- path, consistently across device, time period and traffic channel.
-- NOT established: causation. Adding an item to a cart is itself a signal of intent,
-- so the gap may reflect WHO chooses each path rather than how each path is built.
-- No amount of subgroup analysis separates these, and the gift-season pattern above
-- actively supports the selection explanation. This ambiguity is precisely what an
-- experiment resolves, and it is the motivation for the experiment design phase.
--
-- STILL TO DO (Python): two-proportion z-tests on each gap, effect sizes, and
-- confidence intervals -- to state formally which of these differences clear
-- significance rather than eyeballing them.
-- =============================================================================
