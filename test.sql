-- SQL scrip for generating cohort of traumatic brain injury and low bp


/* admission 때 나이가 들어 있는 간단한 테이블 */
DROP MATERIALIZED VIEW IF EXISTS _admissions;
CREATE MATERIALIZED VIEW _admissions AS
select a.subject_id, hadm_id, admittime, dischtime, deathtime, p.dod
, ROUND((admittime::date - dob::date)::numeric / 365.242) as age
from admissions a
join patients p
on a.subject_id = p.subject_id;





/* 진단명으로 찾기 */
-- A 2071명: 진단코드에 붙은 TBI (*materialized view admissions_tbi*)
SELECT hadm_id, i.icd9_code, short_title
FROM diagnoses_icd i
JOIN d_icd_diagnoses d ON i.icd9_code = d.icd9_code
WHERE regexp_match(i.icd9_code,  '^85[0-4]\d{1}') IS NOT NULL;
-- B 328명: 몇 가지 구체적인 진단명 0124, 0125, 0202, 0221
SELECT hadm_id, i.icd9_code, d.short_title
FROM procedures_icd i
JOIN d_icd_procedures d ON i.icd9_code = d.icd9_code
WHERE regexp_match(i.icd9_code,  '^0124|^0125|^0202|^0221') IS NOT NULL;
-- A와 B 병합해도 2071명에서 더 늘지 않는다.

/* 수술명으로 찾기 
0109 Cranial puncture NEC
0124 Other craniotomy
0125 Other craniectomy
0221 EVD */
-- 290 rows
select hadm_id, i.icd9_code, short_title
from procedures_icd i
join d_icd_procedures d
on i.icd9_code = d.icd9_code
where i.icd9_code IN ('0124', '0125', '0109', '0221');


-- 진단명과 수술명으로 찾은 hadm_id 병합
SELECT hadm_id, i.icd9_code, short_title
FROM diagnoses_icd i
JOIN d_icd_diagnoses d ON i.icd9_code = d.icd9_code
WHERE regexp_match(i.icd9_code,  '^85[0-4]\d{1}') IS NOT NULL
UNION
SELECT hadm_id, i.icd9_code, short_title
FROM procedures_icd i
JOIN d_icd_procedures d
ON i.icd9_code = d.icd9_code
WHERE i.icd9_code IN ('0124', '0125', '0109', '0221');

-- 위의 길이는 2148이지만 distinct hadm_id는 모두 2073. 처음 값과 다르지 않다.



/* 사망 여부로 정리하기 */
-- m
DROP MATERIALIZED VIEW IF EXISTS mortality_30
CREATE MATERIALIZED VIEW mortality_30 AS
SELECT subject_id, hadm_id
, CASE 
WHEN dischtime = deathtime 
THEN TRUE
ELSE FALSE END AS hospital_death
,
CASE
WHEN (cast(dischtime as date) 
- cast(admittime as date)) < 31 THEN TRUE -- 30일까지만 TRUE
ELSE FALSE END AS thirty_days
from admissions;

-- 30일 사망
-- n
select hospital_death, thirty_days, count(*)
from mortality_30
group by hospital_death, thirty_days;
--
-- m과 n을 합치려면 with가 상책
select hospital_death, thirty_days, count(*)
from SELECT subject_id, hadm_id
, CASE 
WHEN dischtime = deathtime 
THEN TRUE
ELSE FALSE END AS hospital_death
,
CASE
WHEN (cast(dischtime as date) 
- cast(admittime as date)) < 31 THEN TRUE -- 30일까지만 TRUE
ELSE FALSE END AS thirty_days
from admissions
group by hospital_death, thirty_days



/* SBP만 걸러서 표시하기
   166,731 events in 1,383 admissions
   ---> sbp.csv 
*/

select hadm_id, charttime, min(charttime) over (partition by hadm_id)
, itemid, value, valuenum, valueuom
from chartevents
where itemid IN (select itemid
	from d_items_bp
	where label ~* 'systolic'
	) AND hadm_id IN (
		select hadm_id
		from admissions_tbi	
	)
order by hadm_id, charttime;



-- 같은 코드지만 icustay_id 기준 24 sec
-- --> to R
SELECT hadm_id, icustay_id, charttime
, min(charttime) OVER (partition by icustay_id) AS admit_time
, charttime - min(charttime) OVER (partition by icustay_id) AS hours_from
, itemid, value, valuenum, valueuom
FROM chartevents
WHERE itemid IN (
	select itemid
	from d_items_bp
	where label ~* 'systolic'
	) AND hadm_id IN (
		select hadm_id
		from admissions_tbi	
	)
ORDER BY hadm_id, icustay_id, charttime;

-- 위와 정확히 같은 내용을 window w as .. 분리해서 실행하면 조금 느려진다. 126 sec
SELECT hadm_id, icustay_id, charttime
, min(charttime) OVER w AS admit_time
, charttime - min(charttime) OVER  w AS hours_from
, itemid, value, valuenum
, lag(valuenum) OVER w
, valueuom
FROM chartevents
WHERE itemid IN (
	select itemid
	from d_items_bp
	where label ~* 'systolic'
	) AND hadm_id IN (
		select hadm_id
		from admissions_tbi	
	)
WINDOW w AS (partition by icustay_id)
ORDER BY hadm_id, icustay_id, charttime;



--
--
-- glasgow coma scale

select itemid, label
from d_items
where label ~* 'glasgow|gcs|coma';

-- "itemid","label"
-- 198,"GCS Total"
-- 227011,"GCSEye_ApacheIV"
-- 227012,"GCSMotor_ApacheIV"
-- 227013,"GcsScore_ApacheIV"
-- 227014,"GCSVerbal_ApacheIV"
-- 220739,"GCS - Eye Opening"
-- 228112,"GCSVerbalApacheIIValue (intubated)"
-- 223900,"GCS - Verbal Response"
-- 223901,"GCS - Motor Response"
-- 226755,"GcsApacheIIScore"
-- 226756,"GCSEyeApacheIIValue"
-- 226757,"GCSMotorApacheIIValue"
-- 226758,"GCSVerbalApacheIIValue"

drop materialized view if exists gcsevents;
create materialized view gcsevents as
select icustay_id, charttime, c.itemid, label, value, valuenum, valueuom
from chartevents c
JOIN d_items d
ON c.itemid = d.itemid
where c.itemid IN (
	select itemid
	from d_items
	where label ~* 'glasgow|gcs|coma'
);


-- 각 항목(eye, verbal, motor)의 측정 빈도
select case -- 8.7 sec
	when d.label ~* 'eye' then 'eye'
	when d.label ~* 'motor' then 'motor'
	when d.label ~* 'verbal' then 'verbal'
	end as cat
	, count(*)
from chartevents c
JOIN d_items d
ON c.itemid = d.itemid
where c.itemid IN (
	select itemid
	from d_items
	where label ~* 'glasgow|gcs|coma' AND label ~* 'eye|verbal|motor'
)
group by cat;
-- Eye    227011, 220739, 226756
-- Motor  227012, 223901, 226757
-- Verbal 227014, 228112 (intu), 223900, 226758
-- Verbal value 중에는 'No Response-ETT'로 배당된 값들이 있으며 오히려 228112에 해당하는 값은 나오지 않는다.

-- gcs 측정된 환자 명단 21,877명
drop materialized view if exists patients_gcs;
create materialized view patients_gcs AS
	select distinct hadm_id
	from chartevents c
	JOIN d_items d
	ON c.itemid = d.itemid
	where c.itemid IN (
		select itemid
		from d_items
		where label ~* 'glasgow|gcs|coma' AND label ~* 'eye|verbal|motor'
	);

-- Eye    227011, 220739, 226756
-- Motor  227012, 223901, 226757
-- Verbal 227014, 228112 (intu), 223900, 226758

-- 말하기 점수에 해당하는 네 개 항의 입력값들을 점검코자 아래 쿼리를 수행하면:
select itemid, value, valuenum, valueuom
from chartevents
where itemid in (227014, 228112, 223900, 226758)
order by random()
limit 30;
-- value 중에는 'No Response-ETT'로 배당된 값들이 있으며 오히려 itemid = 228112은 한번도 입력된 적이 없다.
-- 다음 코드는 입력 순서 파악

select hadm_id, charttime, itemid, value, valuenum, valueuom
from chartevents
where itemid in (
		select itemid
		from d_items
		where label ~* 'glasgow|gcs|coma' AND label ~* 'eye|verbal|motor'
	)
order by hadm_id, charttime
limit 100;




-- 저 위에서 만들었던... SBP가 측정된 TBI 환자에서 세 번 연속 SBP < 100 이었던 환자 추리기 125.6 sec
with s as (
select hadm_id, valuenum,lag(valuenum) over w as bef1
, lag(valuenum, 2) over w as bef2
, valuenum < 100 AND lag(valuenum) over w < 100 AND lag(valuenum, 2) over w < 100 as low_3_consec
from chartevents
where itemid IN (select itemid
	from d_items_bp
	where label ~* 'systolic'
	) AND hadm_id IN (
		select hadm_id
		from admissions_tbi	
	)
window w as (partition by hadm_id)
)
select low_3_consec, count(*)
from s
group by low_3_consec; -- 3528 incidences vs. 162959


-- 위와 비슷한 맥락
-- 각 환자마다 중환자실에 입실해서 기록된 첫 SBP -- 150 sec
SELECT hadm_id
, (ARRAY_AGG(valuenum ORDER BY charttime))[1] AS first_bp
FROM chartevents
WHERE itemid IN (
	SELECT itemid
	FROM d_items_bp
	WHERE label ~* 'systolic'
	) AND hadm_id IN (
		SELECT hadm_id
		FROM admissions_tbi	
	)
GROUP BY hadm_id;



-- etomidate 처방 받은 환자
select *
from prescriptions
where drug ~* 'etomidate'; 
-- 그리고 사망한 일시와의 관계
drop materialized view if exists _etomidate_death;
create materialized view _etomidate_death as
select p.subject_id, p.hadm_id, icustay_id
, startdate, dose_val_rx
, a.deathtime <= a.dischtime as death_hosp
, a.deathtime - startdate as post_etomidate
from prescriptions p
join admissions a
on a.hadm_id = p.hadm_id
where drug_name_generic ~* 'etomidate';


-- ASA score?
-- ASA, status, class로는 특별한 게 나오지 않는다.
-- 
select *
from d_items
where label ~* 'ASA';






--- 주목할 만한 itemid
-- 628 sedation score


	