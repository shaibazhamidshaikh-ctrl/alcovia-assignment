-- =====================================================================
-- GTM tracker metrics. Every query takes :from_date and :to_date so the
-- dashboard's timeline selector maps 1:1 onto SQL.
-- =====================================================================

-- 1. Revenue: target vs achievement (month)
with rev as (
  select date_trunc('month', p.captured_at)::date as month,
         sum(p.amount) filter (where i.product_code = 'PROGRAM_12M') as program_rev,
         sum(p.amount) filter (where i.product_code = 'TRIAL_3M')    as trial_rev,
         sum(p.amount) filter (where i.product_code = 'WORKSHOP')    as workshop_rev,
         sum(p.amount)                                               as total_rev
  from payments p join invoices i using (invoice_id)
  where p.captured_at between :from_date and :to_date
  group by 1
)
select r.month, t.revenue_target, r.total_rev,
       round(100.0 * r.total_rev / nullif(t.revenue_target,0), 1) as achievement_pct,
       r.program_rev, r.trial_rev, r.workshop_rev,
       round(100.0 * (r.program_rev + r.trial_rev) / nullif(r.total_rev,0),1) as program_share_pct
from rev r left join monthly_targets t using (month)
order by r.month;

-- 2. Trial vs full program sign-ups + students onboarded
select date_trunc('month', e.start_date)::date as month,
       count(*) filter (where e.product_code = 'TRIAL_3M')     as trial_signups,
       count(*) filter (where e.product_code = 'PROGRAM_12M'
                          and e.converted_from is null)          as direct_program_signups,
       count(*) filter (where e.product_code = 'PROGRAM_12M'
                          and e.converted_from is not null)      as trial_to_program,
       count(distinct e.student_id)                              as students_onboarded
from enrolments e
where e.start_date between :from_date and :to_date
group by 1 order by 1;

-- 3. Workshop revenue per fortnightly workshop (Razorpay, ₹3,999/seat)
select w.workshop_id, w.title, w.held_on,
       count(p.payment_id)                       as seats_sold,
       w.capacity,
       round(100.0*count(p.payment_id)/nullif(w.capacity,0),1) as fill_pct,
       coalesce(sum(p.amount),0)                 as revenue
from workshops w
left join invoices i on i.workshop_id = w.workshop_id
left join payments p on p.invoice_id = i.invoice_id
where w.held_on between :from_date and :to_date
group by w.workshop_id order by w.held_on;

-- 4. Invoices generated but not paid (ageing buckets)
select invoice_id, student_id, lead_id, product_code, amount, issued_at, due_at,
       case when now() <= due_at then 'not_due'
            when now() - due_at <= interval '7 days'  then '0-7d overdue'
            when now() - due_at <= interval '30 days' then '8-30d overdue'
            else '30d+ overdue' end as ageing
from invoices
where status in ('issued','partially_paid')
  and issued_at between :from_date and :to_date
order by due_at;

-- 5. Renewals coming up for 3-month trial teens (next 30 days)
select s.full_name, s.advisor_email, e.end_date,
       e.end_date - current_date as days_left,
       -- engagement signal to prioritise renewal calls
       (select round(avg(extract(epoch from (ended_at-started_at))/60),1)
          from app_sessions a where a.student_id = s.student_id
           and a.started_at > now() - interval '14 days')  as avg_session_min_14d,
       (select count(*) from activity_attendance aa
          where aa.student_id = s.student_id and aa.attended) as sessions_attended
from enrolments e join students s using (student_id)
where e.product_code = 'TRIAL_3M'
  and e.end_date between current_date and current_date + 30
  and not exists (select 1 from enrolments e2 where e2.converted_from = e.enrolment_id)
order by e.end_date;

-- 6. Funnel: stage counts + stage-to-stage conversion (cohort = leads created in window)
with cohort as (
  select lead_id from leads where created_at between :from_date and :to_date
),
stage_counts as (
  select stage, count(distinct lead_id) as n
  from lead_stage_events where lead_id in (select lead_id from cohort)
  group by stage
)
select
  (select count(*) from cohort)                                    as total_leads,
  max(n) filter (where stage='qualified')                          as qualified,
  max(n) filter (where stage='discovery_set')                      as discovery_set,
  max(n) filter (where stage='discovery_attended')                 as discovery_attended,
  round(100.0*max(n) filter (where stage='discovery_attended')
        / nullif(max(n) filter (where stage='discovery_set'),0),1) as show_up_rate_pct,
  max(n) filter (where stage='ambition_interview')                 as ambition_interview,
  round(100.0*(1 - max(n) filter (where stage='architect_session')::numeric
        / nullif(max(n) filter (where stage='ambition_interview'),0)),1) as interview_dropoff_pct,
  max(n) filter (where stage='architect_session')                  as architect_session,
  max(n) filter (where stage='won')                                as won
from stage_counts;

-- 7. Top metrics
-- 7a. Cost per qualified lead (paid only)
select sum(ai.spend) / nullif((
         select count(distinct e.lead_id)
         from lead_stage_events e join leads l using (lead_id)
         where e.stage='qualified' and l.source='meta'
           and l.created_at between :from_date and :to_date),0) as cpql
from ad_insights_daily ai where ai.day between :from_date and :to_date;

-- 7b. Program conversion % (paid & signed up / leads in window)
select round(100.0 * count(distinct e.lead_id) filter (where e.stage='won')
       / nullif(count(distinct l.lead_id),0),2) as program_conversion_pct
from leads l left join lead_stage_events e using (lead_id)
where l.created_at between :from_date and :to_date;

-- 7c. Organic lead count
select count(*) as organic_leads from leads
where source <> 'meta' and created_at between :from_date and :to_date;

-- 7d. Average lead journey (days from lead -> won or lost)
select final_stage, round(avg(extract(epoch from (closed_at - created_at))/86400),1) as avg_days
from (
  select l.lead_id, l.created_at, e.stage as final_stage, e.occurred_at as closed_at
  from leads l join lead_stage_events e using (lead_id)
  where e.stage in ('won','lost') and l.created_at between :from_date and :to_date
) t group by final_stage;

-- 8. Campaign performance per creative: CTR, CPL, frequency flag
select c.objective, c.name as campaign, a.creative_name, a.creative_type,
       sum(i.spend)                                         as spend,
       round(100.0*sum(i.clicks)/nullif(sum(i.impressions),0),2) as ctr_pct,
       round(sum(i.spend)/nullif(sum(i.leads),0),0)         as cpl,
       round(avg(i.frequency) filter (where i.day > :to_date::date - 7),2) as freq_7d,
       case when avg(i.frequency) filter (where i.day > :to_date::date - 7) >= 3
            then 'REFRESH (freq 3+)' end                    as fatigue_flag
from ad_insights_daily i
join ads a using (ad_id) join ad_sets s using (adset_id) join campaigns c using (campaign_id)
where i.day between :from_date and :to_date
group by 1,2,3,4
order by ctr_pct desc;

-- 9. Landing page health
select lp.url, lp.variant,
       sum(d.sessions) as sessions,
       round(100.0*sum(d.bounces)/nullif(sum(d.sessions),0),1)      as bounce_pct,
       round(100.0*(1 - sum(d.form_submits)::numeric/nullif(sum(d.form_starts),0)),1) as form_dropoff_pct,
       round(avg(d.lcp_ms)/1000.0,2)                                as avg_load_s,
       case when avg(d.lcp_ms) > 2500 then 'SLOW' else 'OK' end      as speed_flag
from landing_page_daily d join landing_pages lp using (landing_page_id)
where d.day between :from_date and :to_date
group by 1,2;

-- 10. RCA — scale / refresh / drop decision per campaign
-- Rule set (documented in README): compares each campaign to blended averages.
with c as (
  select ca.campaign_id, ca.name, ca.objective,
         sum(i.spend) spend, sum(i.leads) leads,
         sum(i.clicks)::numeric/nullif(sum(i.impressions),0) ctr,
         avg(i.frequency) filter (where i.day > :to_date::date - 7) freq
  from ad_insights_daily i join ads a using (ad_id) join ad_sets s using (adset_id)
  join campaigns ca using (campaign_id)
  where i.day between :from_date and :to_date group by 1,2,3
),
q as (
  select l.utm_campaign as campaign_id,
         count(distinct l.lead_id) filter (where e.stage='qualified') qual,
         count(distinct l.lead_id) filter (where e.stage='won') won
  from leads l left join lead_stage_events e using (lead_id)
  where l.created_at between :from_date and :to_date group by 1
),
j as (
  select c.*, q.qual, q.won,
         c.spend/nullif(q.qual,0) as cpql,
         avg(c.spend/nullif(q.qual,0)) over () as avg_cpql,
         avg(c.ctr) over () as avg_ctr
  from c left join q using (campaign_id)
)
select name, objective, spend, qual, won, round(cpql) cpql, round(100*ctr,2) ctr_pct, round(freq,2) freq,
  case
    when won >= 1 and cpql <= avg_cpql*0.8 and freq < 3  then 'SCALE  (+20-30% budget)'
    when freq >= 3 or ctr < avg_ctr*0.7                 then 'REFRESH creative'
    when cpql > avg_cpql*1.5 and coalesce(won,0) = 0    then 'DROP / pause'
    else 'HOLD' end as decision
from j order by decision, cpql;
