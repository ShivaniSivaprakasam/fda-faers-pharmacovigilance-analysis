USE faers_2025;
-- ==============================================================================
-- Q1 — Age-group and gender distribution of ADR reports
-- ==============================================================================
SELECT
    CASE
        WHEN age_years IS NULL THEN 'Not Reported'
        WHEN age_years < 28/365.25 THEN 'Neonate'
        WHEN age_years < 2  THEN 'Infant'
        WHEN age_years < 12 THEN 'Child'
        WHEN age_years < 18 THEN 'Adolescent'
        WHEN age_years < 65 THEN 'Adult'
        ELSE 'Elderly'
    END AS age_group,
    sex,
    COUNT(*) AS report_count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM report_level), 2) AS pct_of_total
FROM report_level
GROUP BY age_group, sex
ORDER BY report_count DESC;
 
 
-- ==============================================================================
-- Q2 — Reporting lag: event_dt -> fda_dt
-- Median computed via window function since MySQL has no native MEDIAN().
-- ==============================================================================
WITH lag_calc AS (
    SELECT DATEDIFF(fda_dt_clean, event_dt_clean) AS lag_days
    FROM report_level
    WHERE event_dt_clean IS NOT NULL AND fda_dt_clean IS NOT NULL
      AND DATEDIFF(fda_dt_clean, event_dt_clean) >= 0   -- excludes implausible negative lag
),
ranked AS (
    SELECT lag_days,
           ROW_NUMBER() OVER (ORDER BY lag_days) AS rn,
           COUNT(*) OVER () AS total
    FROM lag_calc
)
SELECT
    (SELECT ROUND(AVG(lag_days), 1) FROM lag_calc) AS mean_lag_days,
    (SELECT AVG(lag_days) FROM ranked WHERE rn IN (FLOOR((total + 1) / 2), CEIL((total + 1) / 2))) AS median_lag_days,
    (SELECT COUNT(*) FROM lag_calc) AS n_computable;
 
 
-- ==============================================================================
-- Q3 — Reporting lag: event_dt -> mfr_dt
-- ==============================================================================
SELECT
    ROUND(AVG(DATEDIFF(mfr_dt_clean, event_dt_clean)), 1) AS mean_lag_days,
    COUNT(*) AS n_computable
FROM report_level
WHERE event_dt_clean IS NOT NULL AND mfr_dt_clean IS NOT NULL
  AND DATEDIFF(mfr_dt_clean, event_dt_clean) >= 0;
 
 
-- ==============================================================================
-- Q4 — Country concentration (top 5 as % of total known-country reports)
-- Not affected by the drug-duplication issue: report_level has exactly one
-- row per report, so no COUNT(*) vs. COUNT(DISTINCT) distinction applies here.
-- ==============================================================================
WITH country_counts AS (
    SELECT reporter_country, COUNT(*) AS report_count
    FROM report_level
    WHERE reporter_country IS NOT NULL AND reporter_country <> ''
    GROUP BY reporter_country
),
totals AS (SELECT SUM(report_count) AS total_known FROM country_counts)
SELECT c.reporter_country, c.report_count,
       ROUND(c.report_count * 100.0 / t.total_known, 2) AS pct_of_known_total
FROM country_counts c CROSS JOIN totals t
ORDER BY c.report_count DESC
LIMIT 5;
 
 
-- ==============================================================================
-- Q5 — Top 10 drugs by prod_ai (Pareto), suspect drugs only (PS+SS)
-- CORRECTED: COUNT(DISTINCT primaryid), not COUNT(*) — a report listing the
-- same drug twice (e.g. as both PS and SS) must count once toward that
-- drug's volume, not twice.
-- ==============================================================================
WITH drug_counts AS (
    SELECT drug_label, COUNT(DISTINCT primaryid) AS report_count
    FROM drug_level
    WHERE role_cod IN ('PS', 'SS')
    GROUP BY drug_label
),
totals AS (SELECT SUM(report_count) AS total FROM drug_counts)
SELECT d.drug_label, d.report_count,
       ROUND(d.report_count * 100.0 / t.total, 2) AS pct_of_suspect_total
FROM drug_counts d CROSS JOIN totals t
ORDER BY d.report_count DESC
LIMIT 10;
 
 
-- ==============================================================================
-- Q6 — Serious-outcome proportion for the top 10 drugs from Q5
-- CORRECTED: dedup_drug collapses each report to ONE row per (primaryid,
-- drug_label) before joining to outcomes — this is the exact fix for the
-- bug that produced a serious_pct > 100% in the original version.
-- ==============================================================================
WITH top10_drugs AS (
    SELECT drug_label, COUNT(DISTINCT primaryid) AS report_count
    FROM drug_level
    WHERE role_cod IN ('PS', 'SS')
    GROUP BY drug_label
    ORDER BY report_count DESC
    LIMIT 10
),
dedup_drug AS (
    SELECT DISTINCT dl.primaryid, dl.drug_label
    FROM drug_level dl
    JOIN top10_drugs t ON dl.drug_label = t.drug_label
    WHERE dl.role_cod IN ('PS', 'SS')
)
SELECT dd.drug_label,
       COUNT(DISTINCT dd.primaryid) AS total_reports,
       SUM(CASE WHEN rl.has_serious_outcome = 1 THEN 1 ELSE 0 END) AS serious_reports,
       ROUND(SUM(CASE WHEN rl.has_serious_outcome = 1 THEN 1 ELSE 0 END) * 100.0
             / COUNT(DISTINCT dd.primaryid), 2) AS serious_pct
FROM dedup_drug dd
JOIN report_level rl ON dd.primaryid = rl.primaryid
GROUP BY dd.drug_label
ORDER BY total_reports DESC;
 
 
-- ==============================================================================
-- Q7 — PRR/ROR disproportionality signal detection
-- CORRECTED: dedup_drug fix applied (as in Q6). Minimum case count raised to
-- 20 (not the bare Evans minimum of 3) specifically for this RANKING, since
-- a 3-case pair can produce a PRR in the hundreds of thousands — technically
-- meets Evans criteria but is a statistically fragile, not meaningful,
-- "top signal." All three Evans criteria (PRR>=2, chi-square>=4) still apply
-- on top of this higher floor.
-- WARNING: this is the most expensive query in this file (drug_level x
-- reaction_level join). Create indexes on drug_level(primaryid, drug_label)
-- and reaction_level(primaryid, pt_clean) first, and apply the session
-- tuning at the top of this file.
-- ==============================================================================
WITH dedup_drug AS (
    SELECT primaryid, drug_label,
           MAX(dechal_clean = 'Y') AS dechal_positive,
           MAX(rechal_clean = 'Y') AS rechal_positive
    FROM drug_level
    WHERE role_cod IN ('PS', 'SS')
    GROUP BY primaryid, drug_label
),
pair_counts AS (
    SELECT dd.drug_label, rl.pt_clean AS reaction, COUNT(*) AS a
    FROM dedup_drug dd
    JOIN reaction_level rl ON dd.primaryid = rl.primaryid
    GROUP BY dd.drug_label, rl.pt_clean
    HAVING a >= 20   -- raised floor for a defensible ranking, not the bare Evans minimum of 3
),
drug_totals AS (
    SELECT drug_label, COUNT(*) AS n_drug FROM dedup_drug GROUP BY drug_label
),
reaction_totals AS (
    SELECT pt_clean AS reaction, COUNT(DISTINCT primaryid) AS n_reaction
    FROM reaction_level GROUP BY pt_clean
),
population AS (
    SELECT COUNT(DISTINCT primaryid) AS N
    FROM (
        SELECT primaryid FROM dedup_drug
        UNION
        SELECT primaryid FROM reaction_level
    ) u
),
contingency AS (
    SELECT p.drug_label, p.reaction, p.a,
           dt.n_drug, rt.n_reaction, pop.N,
           (dt.n_drug - p.a) AS b,
           (rt.n_reaction - p.a) AS c,
           (pop.N - dt.n_drug - rt.n_reaction + p.a) AS d
    FROM pair_counts p
    JOIN drug_totals dt ON p.drug_label = dt.drug_label
    JOIN reaction_totals rt ON p.reaction = rt.reaction
    CROSS JOIN population pop
)
SELECT drug_label, reaction, a AS co_occurrence_count,
       ROUND((a / (a + b)) / (c / (c + d)), 2) AS PRR,
       ROUND((a * d) / (b * c), 2) AS ROR,
       ROUND(N * POWER(a * d - b * c, 2) / ((a + b) * (c + d) * (a + c) * (b + d)), 2) AS chi_square
FROM contingency
WHERE b > 0 AND c > 0 AND d > 0
HAVING PRR >= 2 AND chi_square >= 4
ORDER BY PRR DESC
LIMIT 10;
 
 
-- ==============================================================================
-- Q8 — Most common real indication per top-10 drug
-- Window function RANK() picks the top result per group. Excludes the
-- "Product used for unknown indication" MedDRA placeholder, which is a real
-- code but not a clinical indication.
-- ==============================================================================
WITH top10_drugs AS (
    SELECT drug_label, COUNT(DISTINCT primaryid) AS report_count
    FROM drug_level
    WHERE role_cod IN ('PS', 'SS')
    GROUP BY drug_label
    ORDER BY report_count DESC
    LIMIT 10
),
indi_ranked AS (
    SELECT di.drug_label, di.indi_pt_clean,
           COUNT(DISTINCT di.primaryid) AS indication_count,
           RANK() OVER (PARTITION BY di.drug_label ORDER BY COUNT(DISTINCT di.primaryid) DESC) AS rnk
    FROM drug_indi_level di
    JOIN top10_drugs t ON di.drug_label = t.drug_label
    WHERE di.is_unknown_indication = 0
    GROUP BY di.drug_label, di.indi_pt_clean
)
SELECT drug_label, indi_pt_clean AS top_real_indication, indication_count
FROM indi_ranked
WHERE rnk = 1
ORDER BY indication_count DESC;
 
 
-- ==============================================================================
-- Q9 — Top 10 reactions most frequently linked to serious outcomes (Pareto)
-- Not affected by the drug-duplication issue: reaction_level's grain is one
-- row per (primaryid, reaction), independent of the drug_level bug.
-- ==============================================================================
WITH serious_reactions AS (
    SELECT pt_clean, COUNT(*) AS reaction_count
    FROM reaction_level
    WHERE has_serious_outcome = 1
    GROUP BY pt_clean
),
totals AS (SELECT SUM(reaction_count) AS total FROM serious_reactions)
SELECT s.pt_clean AS reaction, s.reaction_count,
       ROUND(s.reaction_count * 100.0 / t.total, 2) AS pct_of_serious_listings
FROM serious_reactions s CROSS JOIN totals t
ORDER BY s.reaction_count DESC
LIMIT 10;
 
 
-- ==============================================================================
-- Q10 — Countries with the highest death RATE (min 100 reports to qualify)
-- Not affected by the drug-duplication issue: report_level-based.
-- ==============================================================================
WITH country_stats AS (
    SELECT reporter_country,
           COUNT(*) AS total_reports,
           SUM(CASE WHEN has_death = 1 THEN 1 ELSE 0 END) AS death_reports
    FROM report_level
    WHERE reporter_country IS NOT NULL AND reporter_country <> ''
    GROUP BY reporter_country
    HAVING COUNT(*) >= 100
)
SELECT reporter_country, total_reports, death_reports,
       ROUND(death_reports * 100.0 / total_reports, 2) AS death_rate_pct
FROM country_stats
ORDER BY death_rate_pct DESC
LIMIT 10;
 
 
-- ==============================================================================
-- Q11 — Primary reporters vs. severity of outcome
-- Not affected by the drug-duplication issue: rpsr_level-based.
-- Reminder: RPSR covers only ~2.7% of all reports.
-- ==============================================================================
SELECT rpsr_cod_clean,
       COUNT(*) AS total_reports,
       SUM(CASE WHEN has_serious_outcome = 1 THEN 1 ELSE 0 END) AS serious_reports,
       SUM(CASE WHEN has_death = 1 THEN 1 ELSE 0 END) AS death_reports,
       ROUND(AVG(has_serious_outcome) * 100, 2) AS serious_pct,
       ROUND(AVG(has_death) * 100, 2) AS death_pct
FROM rpsr_level
GROUP BY rpsr_cod_clean
ORDER BY total_reports DESC;
 
 
-- ==============================================================================
-- Q12 — Therapy duration vs. severity for the top-ranked suspect drug
-- CORRECTED: selected_drug now uses COUNT(DISTINCT primaryid), consistent
-- with Q5's fix, so the "#1 drug" this chart is built around is determined
-- the same, correct way everywhere in the project.
-- ==============================================================================
WITH selected_drug AS (
    SELECT drug_label
    FROM drug_level
    WHERE role_cod IN ('PS', 'SS')
    GROUP BY drug_label
    ORDER BY COUNT(DISTINCT primaryid) DESC
    LIMIT 1
),
scoped AS (
    SELECT
        CASE
            WHEN dt.duration_days <= 7   THEN '1_<=7d'
            WHEN dt.duration_days <= 30  THEN '2_8-30d'
            WHEN dt.duration_days <= 90  THEN '3_31-90d'
            WHEN dt.duration_days <= 180 THEN '4_91-180d'
            WHEN dt.duration_days <= 365 THEN '5_181-365d'
            ELSE '6_>365d'
        END AS duration_bucket,
        dt.primaryid,
        rl.has_serious_outcome
    FROM drug_ther_level dt
    JOIN selected_drug sd ON dt.drug_label = sd.drug_label
    JOIN report_level rl ON dt.primaryid = rl.primaryid
    WHERE dt.role_cod IN ('PS', 'SS') AND dt.duration_days IS NOT NULL
)
SELECT SUBSTRING(duration_bucket, 3) AS duration_bucket,
       COUNT(DISTINCT primaryid) AS n_reports,
       ROUND(AVG(has_serious_outcome) * 100, 2) AS serious_pct
FROM scoped
GROUP BY duration_bucket
ORDER BY duration_bucket;
 
 
-- ==============================================================================
-- Q13 — Dechal/rechal proportions for the top 10 drug-reaction pairs
-- CORRECTED: same dedup_drug + minimum case count logic as Q7 (both share
-- the identical drug x reaction join, so both needed the identical fix).
-- ==============================================================================
WITH dedup_drug AS (
    SELECT primaryid, drug_label,
           MAX(dechal_clean = 'Y') AS dechal_positive,
           MAX(rechal_clean = 'Y') AS rechal_positive
    FROM drug_level
    WHERE role_cod IN ('PS', 'SS')
    GROUP BY primaryid, drug_label
)
SELECT dd.drug_label, rl.pt_clean AS reaction,
       COUNT(*) AS pair_count,
       ROUND(AVG(dd.dechal_positive) * 100, 2) AS pct_dechal_positive,
       ROUND(AVG(dd.rechal_positive) * 100, 2) AS pct_rechal_positive
FROM dedup_drug dd
JOIN reaction_level rl ON dd.primaryid = rl.primaryid
GROUP BY dd.drug_label, rl.pt_clean
HAVING pair_count >= 20
ORDER BY pair_count DESC
LIMIT 10;
 