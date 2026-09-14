-- ==============================================================================
-- FIX Q7 (PRR/ROR) AND Q13 (dechal/rechal) — run this ENTIRE script in one
-- MySQL Command Line Client session (not Workbench's query editor).
-- The CLI has no client-side query timeout, so this avoids the Error 2013
-- issues Workbench kept hitting, and temp tables won't vanish mid-script.
--
-- HOW TO OPEN: search Windows Start menu for "MySQL 8.0 Command Line Client"
-- (installed alongside Workbench). Enter your MySQL password when prompted.
-- Then paste this entire script in and press Enter — multi-statement scripts
-- work fine as long as each line ends in a semicolon, which they all do here.
-- ==============================================================================

USE faers_2025;

SET SESSION sort_buffer_size = 67108864;
SET SESSION tmp_table_size = 268435456;
SET SESSION max_heap_table_size = 268435456;

-- Step 1: deduplicate drug entries to one row per (primaryid, drug_label) —
-- this is the actual bug fix (see the Excel validation that caught it).
DROP TEMPORARY TABLE IF EXISTS dedup_drug;
CREATE TEMPORARY TABLE dedup_drug AS
SELECT primaryid, drug_label,
       MAX(dechal_clean = 'Y') AS dechal_positive,
       MAX(rechal_clean = 'Y') AS rechal_positive
FROM drug_level
WHERE role_cod IN ('PS', 'SS')
GROUP BY primaryid, drug_label;

ALTER TABLE dedup_drug ADD INDEX idx_dd_primaryid (primaryid);
ALTER TABLE dedup_drug ADD INDEX idx_dd_label (drug_label(100));

SELECT COUNT(*) AS dedup_drug_rows FROM dedup_drug;

-- Step 2: pair co-occurrence counts, now correct since both sides are
-- deduplicated per primaryid.
DROP TEMPORARY TABLE IF EXISTS pair_counts;
CREATE TEMPORARY TABLE pair_counts AS
SELECT dd.drug_label, rl.pt_clean AS reaction, COUNT(*) AS a,
       SUM(dd.dechal_positive) AS dechal_pos,
       SUM(dd.rechal_positive) AS rechal_pos
FROM dedup_drug dd
JOIN reaction_level rl ON dd.primaryid = rl.primaryid
GROUP BY dd.drug_label, rl.pt_clean
HAVING a >= 3;

SELECT COUNT(*) AS distinct_pairs FROM pair_counts;

-- Step 3: marginal totals (small, fast)
DROP TEMPORARY TABLE IF EXISTS drug_totals;
CREATE TEMPORARY TABLE drug_totals AS
SELECT drug_label, COUNT(*) AS n_drug FROM dedup_drug GROUP BY drug_label;

DROP TEMPORARY TABLE IF EXISTS reaction_totals;
CREATE TEMPORARY TABLE reaction_totals AS
SELECT pt_clean AS reaction, COUNT(DISTINCT primaryid) AS n_reaction FROM reaction_level GROUP BY pt_clean;

-- Step 4: write corrected Q7 directly into the final table (replaces the old buggy one)
-- N = 1,617,313 hardcoded from the earlier validated population count.
DROP TABLE IF EXISTS q7_prr_ror_signals;
CREATE TABLE q7_prr_ror_signals AS
SELECT drug_label, reaction, a AS co_occurrence_count, PRR, ROR, chi_square
FROM (
    SELECT p.drug_label, p.reaction, p.a,
           dt.n_drug, rt.n_reaction,
           ROUND((p.a / dt.n_drug) / ((rt.n_reaction - p.a) / (1617313 - dt.n_drug - rt.n_reaction + p.a)), 2) AS PRR,
           ROUND((p.a * (1617313 - dt.n_drug - rt.n_reaction + p.a)) / ((dt.n_drug - p.a) * (rt.n_reaction - p.a)), 2) AS ROR,
           ROUND(1617313 * POWER(p.a * (1617313 - dt.n_drug - rt.n_reaction + p.a) - (dt.n_drug - p.a) * (rt.n_reaction - p.a), 2)
                 / (dt.n_drug * (1617313 - dt.n_drug) * rt.n_reaction * (1617313 - rt.n_reaction)), 2) AS chi_square
    FROM pair_counts p
    JOIN drug_totals dt ON p.drug_label = dt.drug_label
    JOIN reaction_totals rt ON p.reaction = rt.reaction
    WHERE (dt.n_drug - p.a) > 0 AND (rt.n_reaction - p.a) > 0
) x
WHERE PRR >= 2 AND chi_square >= 4
ORDER BY PRR DESC
LIMIT 10;

SELECT * FROM q7_prr_ror_signals;

-- Step 5: write corrected Q13 directly into the final table
DROP TABLE IF EXISTS q13_dechal_rechal_top_pairs;
CREATE TABLE q13_dechal_rechal_top_pairs AS
SELECT drug_label, reaction AS pt_clean, a AS pair_count,
       ROUND(dechal_pos / a * 100, 2) AS pct_dechal_positive,
       ROUND(rechal_pos / a * 100, 2) AS pct_rechal_positive
FROM pair_counts
WHERE a >= 20
ORDER BY a DESC
LIMIT 10;

SELECT * FROM q13_dechal_rechal_top_pairs;