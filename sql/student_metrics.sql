-- =====================================================================
-- Student dashboard metrics — every KPI sits in one of three lenses:
--   Q1 QUANTITY   : did Alcovia conduct it?
--   Q2 QUALITY    : did Alcovians like it?
--   Q3 PERFORMANCE: how did the Alcovian perform?
-- Params: :from_date, :to_date, optional :student_id (null = cohort)
-- =====================================================================

-- ---------- DAY LEVEL ----------------------------------------------

-- Focus minutes / day and focus completion (Q3)
select s.full_name,
       round(sum(f.actual_minutes)::numeric / greatest(1, (:to_date::date - :from_date::date + 1)),1) as avg_focus_min_per_day,
       round(100.0*avg(f.completed::int),1) as focus_completion_pct,
       count(*) filter (where f.broken_by='app_switch') as focus_breaks
from students s left join focus_sessions f
  on f.student_id = s.student_id and f.started_at between :from_date and :to_date
where (:student_id is null or s.student_id = :student_id)
group by s.full_name;

-- Timetable adherence: done vs planned self-study minutes (Q3)
select student_id,
       round(100.0*sum(done_minutes)/nullif(sum(planned_minutes),0),1) as timetable_adherence_pct
from timetable_blocks
where block_type='self_study' and day between :from_date and :to_date
group by student_id;

-- Daily 8 PM quiz: Q1 quizzes held, Q3 participation + average score
select count(distinct q.quiz_id)                                      as quizzes_held,         -- Q1
       round(100.0*count(qa.*)/nullif(count(distinct q.quiz_id)*
             (select count(*) from students where status='active'),0),1) as participation_pct, -- Q3
       round(avg(qa.score_pct),1)                                     as avg_score_pct         -- Q3
from quizzes q left join quiz_attempts qa using (quiz_id)
where q.quiz_date between :from_date and :to_date;

-- Wearables: active minutes, sleep, recovery (Q3)
select student_id,
       round(avg(active_minutes)) as avg_active_min,
       round(avg(sleep_minutes)/60.0,1) as avg_sleep_h,
       round(avg(recovery_pct)) as avg_recovery_pct,
       count(distinct day) filter (where sleep_minutes < 420) as short_sleep_days   -- <7h
from wearable_daily
where day between :from_date and :to_date
group by student_id;

-- ---------- WEEK LEVEL (academic) ------------------------------------

-- Task completion rate, deadline adherence, time-estimation accuracy (Q3)
select student_id,
       round(100.0*avg((completed_at is not null)::int),1)                       as task_completion_pct,
       round(100.0*avg((completed_at <= due_at)::int) filter (where completed_at is not null),1) as deadline_adherence_pct,
       round(100.0*(1 - avg(abs(actual_min - estimated_min)::numeric/nullif(estimated_min,0))),1) as estimation_accuracy_pct
from tasks
where due_at between :from_date and :to_date
group by student_id;

-- Chapter readiness score: stage reached -> 20/40/60/80/100 (Q3)
with best as (
  select student_id, chapter_id,
         max(case stage when 'read' then 20 when 'notes' then 40 when 'practice_70' then 60
                        when 'pyq_timed' then 80 when 'ready_80' then 100 end) as score
  from chapter_progress group by 1,2
)
select b.student_id, c.subject,
       round(sum(b.score*c.weight)/nullif(sum(100*c.weight),0)*100,1) as readiness_score,
       count(*) filter (where b.score = 100) as chapters_exam_ready
from best b join chapters c using (chapter_id)
group by 1,2;

-- Syllabus pace vs 25%-per-quarter rule (Q3)
-- expected % = days elapsed in academic year / 365 ; actual = chapters at >= practice_70
select s.student_id,
       round(100.0*(current_date - date '2026-04-01')/365,1) as expected_pct,
       round(100.0*count(distinct cp.chapter_id) filter (where cp.stage >= 'practice_70')
             / nullif((select count(*) from chapters ch where ch.grade = s.grade and ch.board = s.board),0),1) as actual_pct
from students s left join chapter_progress cp using (student_id)
group by s.student_id, s.grade, s.board;

-- Score target vs actual by exam type (Q3)
select student_id, subject, exam_type, target_pct, actual_pct,
       actual_pct - target_pct as gap,
       case when actual_pct < target_pct - 10 then 'TRIGGER tutor support' end as action
from exam_targets
where exam_date between :from_date and :to_date and actual_pct is not null;

-- ---------- MONTH / QUARTER LEVEL (programme) ------------------------

-- Per activity type: conducted vs planned (Q1), rating + NPS (Q2), attendance (Q3)
select a.type,
       count(*)                                            as planned,
       count(*) filter (where a.held)                      as conducted,        -- Q1
       round(100.0*avg(a.held::int),1)                     as delivery_pct,     -- Q1
       round(avg(aa.rating),2)                             as avg_rating,       -- Q2
       round(100.0*(avg((aa.nps>=9)::int) - avg((aa.nps<=6)::int)),0) as nps,   -- Q2
       round(100.0*avg(aa.attended::int),1)                as attendance_pct    -- Q3
from activities a left join activity_attendance aa using (activity_id)
where a.scheduled_for between :from_date and :to_date
group by a.type order by a.type;

-- Soft-skill growth: first vs latest workshop score per skill (Q3)
with ranked as (
  select ss.*, a.scheduled_for,
         row_number() over (partition by ss.student_id, ss.skill order by a.scheduled_for)      as rn_first,
         row_number() over (partition by ss.student_id, ss.skill order by a.scheduled_for desc) as rn_last
  from soft_skill_scores ss join activities a using (activity_id)
)
select student_id, skill,
       max(score) filter (where rn_first=1) as first_score,
       max(score) filter (where rn_last=1)  as latest_score,
       max(score) filter (where rn_last=1) - max(score) filter (where rn_first=1) as delta
from ranked group by 1,2;

-- Roadmap milestone hit-rate (career binary, personal monthly, academic) (Q3)
select student_id, roadmap,
       count(*) filter (where due_month <= current_date)                         as due,
       count(*) filter (where done_at is not null and done_at <= due_month + 30)  as on_time,
       round(100.0*count(*) filter (where done_at is not null)
             / nullif(count(*) filter (where due_month <= current_date),0),1)     as hit_rate_pct
from roadmap_milestones group by 1,2;

-- ---------- COMPOSITE: Student health score (weekly) -----------------
-- 35% academics (readiness + task completion), 25% focus, 20% programme
-- attendance, 10% quiz, 10% wellness. Red < 50, Amber 50-70, Green > 70.
-- (implemented as a materialised view refreshed nightly by n8n)
create materialized view if not exists mv_student_health as
select s.student_id, s.full_name, s.advisor_email,
       round(
         0.35 * coalesce(acad.score,0) +
         0.25 * least(100, coalesce(foc.min_per_day,0) / 45.0 * 100) +   -- 45 focus-min/day = 100
         0.20 * coalesce(att.pct,0) +
         0.10 * coalesce(quiz.pct,0) +
         0.10 * coalesce(well.pct,0)
       ,0) as health_score
from students s
left join lateral (
  select (avg((t.completed_at is not null)::int)*100) as score
  from tasks t where t.student_id=s.student_id and t.due_at > now()-interval '7 days') acad on true
left join lateral (
  select sum(actual_minutes)/7.0 as min_per_day
  from focus_sessions f where f.student_id=s.student_id and f.started_at > now()-interval '7 days') foc on true
left join lateral (
  select avg(attended::int)*100 as pct
  from activity_attendance aa join activities a using (activity_id)
  where aa.student_id=s.student_id and a.scheduled_for > now()-interval '30 days') att on true
left join lateral (
  select count(*)/7.0*100 as pct
  from quiz_attempts qa join quizzes q using (quiz_id)
  where qa.student_id=s.student_id and q.quiz_date > current_date-7) quiz on true
left join lateral (
  select avg(recovery_pct) as pct
  from wearable_daily w where w.student_id=s.student_id and w.day > current_date-7) well on true
where s.status='active';
