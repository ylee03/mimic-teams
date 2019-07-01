/*
Jul 2 TUE
*/

-- hypokalemia 진단 받은 환자들의 매일매일 K+ 수치의 개요는 어떠한가?
with hy as (
	select hadm_id, icd9_code
	from diagnoses_icd
	where icd9_code = '2768')

select l.hadm_id, cast(charttime as date) as aday, l.itemid, valuenum
, min(valuenum) over w
, avg(valuenum) over w
from labevents l
join hy
on l.hadm_id = hy.hadm_id
where itemid IN (50971, 50822)
window w as (partition by aday);


-- 이어지는 난제: 연속적인 K+ 측정값을 찾아야 하나?
