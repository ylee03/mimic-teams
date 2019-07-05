/*
SQL query admissions 테이블에 나이와 dod를 더해 놓은 간단한
*/

set search_path to mimiciii;
drop materialized view if exists _admissions;
create materialized view _admissions as
SELECT a.subject_id,
    a.hadm_id,
    a.admittime,
    a.dischtime,
    a.deathtime,
    a.ethnicity,
    p.dod,
    round((a.admittime::date - p.dob::date)::numeric / 365.242) AS age
   FROM admissions a
     JOIN patients p ON a.subject_id = p.subject_id;
