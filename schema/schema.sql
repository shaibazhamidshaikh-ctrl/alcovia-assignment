-- =====================================================================
-- Alcovia Ops Warehouse — Postgres (Supabase) schema
-- One source of truth fed by n8n from: ClickUp, Razorpay, Meta Ads,
-- Smallest.ai, the Alcovia app DB, quiz forms and wearables.
-- Design rules:
--   1. Every external record keeps its source id  -> idempotent upserts.
--   2. Funnel + activity data is stored as EVENTS, metrics are computed
--      in SQL views, never typed by hand.
--   3. Humans only enter what no system knows (session ratings, advisor
--      notes). Everything else arrives via webhook or scheduled pull.
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------
-- GTM: leads, funnel, campaigns
-- ---------------------------------------------------------------------
create table campaigns (
  campaign_id      text primary key,            -- Meta campaign id
  name             text not null,
  objective        text check (objective in ('program','workshop','brand')),
  status           text,
  created_at       timestamptz default now()
);

create table ad_sets (
  adset_id         text primary key,
  campaign_id      text references campaigns(campaign_id),
  name             text,
  audience         text
);

create table ads (
  ad_id            text primary key,
  adset_id         text references ad_sets(adset_id),
  creative_name    text,
  creative_type    text check (creative_type in ('video','static','carousel','reel')),
  landing_page_id  text
);

-- daily grain pulled from Meta Marketing API (n8n: meta_ads_daily_pull)
create table ad_insights_daily (
  ad_id            text references ads(ad_id),
  day              date,
  spend            numeric(12,2),
  impressions      int,
  reach            int,
  clicks           int,
  leads            int,
  frequency        numeric(5,2),               -- >=3.0 => creative fatigue
  primary key (ad_id, day)
);

create table landing_pages (
  landing_page_id  text primary key,
  url              text,
  variant          text
);

-- daily web vitals + bounce (GA4 / PageSpeed via n8n)
create table landing_page_daily (
  landing_page_id  text references landing_pages(landing_page_id),
  day              date,
  sessions         int,
  bounces          int,
  form_starts      int,
  form_submits     int,
  lcp_ms           int,                         -- load time (Largest Contentful Paint)
  primary key (landing_page_id, day)
);

create table leads (
  lead_id          uuid primary key default gen_random_uuid(),
  clickup_task_id  text unique,                 -- ClickUp is the CRM UI
  parent_name      text,
  teen_name        text,
  phone            text,
  city             text,
  source           text check (source in ('meta','organic','referral','workshop','other')),
  ad_id            text references ads(ad_id),  -- null for organic
  utm_campaign     text,
  created_at       timestamptz not null default now()
);

-- one row per stage transition (ClickUp status change webhook)
create type funnel_stage as enum (
  'lead','qualified','discovery_set','discovery_attended',
  'ambition_interview','architect_session','won','lost'
);

create table lead_stage_events (
  id               bigserial primary key,
  lead_id          uuid references leads(lead_id),
  stage            funnel_stage not null,
  occurred_at      timestamptz not null,
  actor            text,                        -- 'smallest.ai' | advisor email | 'system'
  lost_reason      text,
  unique (lead_id, stage)
);

-- Smallest.ai reminder / confirmation calls
create table ai_calls (
  call_id          text primary key,
  lead_id          uuid references leads(lead_id),
  purpose          text check (purpose in ('qualify','discovery_reminder','interview_reminder','renewal')),
  outcome          text check (outcome in ('confirmed','rescheduled','no_answer','declined')),
  called_at        timestamptz
);

-- ---------------------------------------------------------------------
-- Revenue: products, enrolments, payments, invoices
-- ---------------------------------------------------------------------
create table products (
  product_code     text primary key,            -- 'TRIAL_3M','PROGRAM_12M','WORKSHOP'
  name             text,
  list_price       numeric(10,2),
  duration_days    int
);

create table students (
  student_id       uuid primary key default gen_random_uuid(),
  lead_id          uuid references leads(lead_id),
  app_user_id      text unique,                 -- id in Alcovia app DB
  full_name        text not null,
  grade            int,
  school           text,
  board            text,
  advisor_email    text,
  parent_phone     text,
  pod_id           text,
  onboarded_at     date,
  status           text default 'active' check (status in ('active','paused','churned'))
);

create table enrolments (
  enrolment_id     uuid primary key default gen_random_uuid(),
  student_id       uuid references students(student_id),
  product_code     text references products(product_code),
  start_date       date not null,
  end_date         date not null,
  converted_from   uuid references enrolments(enrolment_id) -- trial -> program
);

create table workshops (
  workshop_id      text primary key,
  title            text,
  profession       text,
  held_on          date,
  seat_price       numeric(10,2) default 3999,
  capacity         int
);

create table invoices (
  invoice_id       text primary key,            -- Razorpay invoice id
  student_id       uuid references students(student_id),
  lead_id          uuid references leads(lead_id),
  product_code     text references products(product_code),
  workshop_id      text references workshops(workshop_id),
  amount           numeric(10,2),
  issued_at        timestamptz,
  due_at           timestamptz,
  status           text check (status in ('issued','paid','partially_paid','expired','cancelled'))
);

create table payments (
  payment_id       text primary key,            -- Razorpay payment id
  invoice_id       text references invoices(invoice_id),
  amount           numeric(10,2),
  method           text,
  captured_at      timestamptz,
  raw              jsonb                         -- full webhook payload for audit
);

create table monthly_targets (
  month            date primary key,            -- first of month
  revenue_target   numeric(12,2),
  program_target   int,
  trial_target     int,
  workshop_seat_target int,
  ad_budget        numeric(12,2)
);

-- ---------------------------------------------------------------------
-- Student operating rhythm
-- ---------------------------------------------------------------------
create table app_sessions (                      -- replicated nightly from app DB
  session_id       text primary key,
  student_id       uuid references students(student_id),
  started_at       timestamptz,
  ended_at         timestamptz,
  feature          text                         -- home|realm|focus|syllabus|planner|tasks|wellness…
);

create table focus_sessions (
  focus_id         text primary key,
  student_id       uuid references students(student_id),
  started_at       timestamptz,
  planned_minutes  int,
  actual_minutes   int,
  completed        boolean,
  broken_by        text                          -- null | 'app_switch' | 'manual'
);

create table timetable_blocks (
  block_id         uuid primary key default gen_random_uuid(),
  student_id       uuid references students(student_id),
  day              date,
  block_type       text check (block_type in ('school','tuition','extracurricular','self_study','free')),
  subject          text,
  planned_minutes  int,
  done_minutes     int
);

create table quizzes (
  quiz_id          text primary key,
  quiz_date        date,
  topic            text
);

create table quiz_attempts (
  quiz_id          text references quizzes(quiz_id),
  student_id       uuid references students(student_id),
  score_pct        numeric(5,2),
  submitted_at     timestamptz,
  primary key (quiz_id, student_id)
);

create table wearable_daily (
  student_id       uuid references students(student_id),
  day              date,
  source           text check (source in ('whoop','apple','samsung','garmin')),
  active_minutes   int,
  strain           numeric(5,2),
  sleep_minutes    int,
  recovery_pct     numeric(5,2),
  primary key (student_id, day, source)
);

-- Syllabus rigour: 5 stages per chapter
create table chapters (
  chapter_id       text primary key,
  board            text,
  grade            int,
  subject          text,
  title            text,
  weight           numeric(4,2) default 1      -- for weighted syllabus %
);

create type rigour_stage as enum ('read','notes','practice_70','pyq_timed','ready_80');

create table chapter_progress (
  student_id       uuid references students(student_id),
  chapter_id       text references chapters(chapter_id),
  stage            rigour_stage,
  accuracy_pct     numeric(5,2),
  reached_at       timestamptz,
  primary key (student_id, chapter_id, stage)
);

create table exam_targets (
  student_id       uuid references students(student_id),
  subject          text,
  exam_type        text check (exam_type in ('formative','unit_test','midterm','final')),
  target_pct       numeric(5,2),
  actual_pct       numeric(5,2),
  exam_date        date,
  primary key (student_id, subject, exam_type, exam_date)
);

create table tasks (                              -- advisor-assigned + own tasks
  task_id          text primary key,
  student_id       uuid references students(student_id),
  assigned_by      text,
  estimated_min    int,
  actual_min       int,
  due_at           timestamptz,
  completed_at     timestamptz
);

-- Programme activities (workshop, pod, peer, mentor, shoot, podcast …)
create type activity_type as enum (
  'academic_session','workshop','pod_session','peer_session','mentor_call',
  'personal_branding','podcast_shoot','competition_prep','parent_child',
  'out_of_city','theme_project'
);

create table activities (
  activity_id      uuid primary key default gen_random_uuid(),
  type             activity_type not null,
  title            text,
  scheduled_for    timestamptz,
  held             boolean default false,
  cadence          text check (cadence in ('weekly','monthly','quarterly'))
);

create table activity_attendance (
  activity_id      uuid references activities(activity_id),
  student_id       uuid references students(student_id),
  attended         boolean,
  rating           int check (rating between 1 and 5),   -- 1-tap in-app after session
  nps              int check (nps between 0 and 10),
  primary key (activity_id, student_id)
);

-- 11 soft skills scored by facilitator per workshop (1-5)
create table soft_skill_scores (
  activity_id      uuid references activities(activity_id),
  student_id       uuid references students(student_id),
  skill            text,           -- engagement, teamwork, crisis_mgmt, adaptability, public_speaking …
  score            int check (score between 1 and 5),
  primary key (activity_id, student_id, skill)
);

create table roadmap_milestones (
  milestone_id     uuid primary key default gen_random_uuid(),
  student_id       uuid references students(student_id),
  roadmap          text check (roadmap in ('career','personal','academic')),
  title            text,
  due_month        date,
  done_at          date
);

-- Alerts sent by automations (audit trail, prevents duplicate nudges)
create table alerts_log (
  id               bigserial primary key,
  student_id       uuid references students(student_id),
  rule             text,           -- 'deadline_missed','rigour_lag','quiz_streak_broken' …
  recipients       text[],
  sent_at          timestamptz default now(),
  sent_on          date default current_date,
  unique (student_id, rule, sent_on)
);

-- ---------------------------------------------------------------------
-- Indexes for dashboard date filters
-- ---------------------------------------------------------------------
create index on leads (created_at);
create index on lead_stage_events (stage, occurred_at);
create index on payments (captured_at);
create index on invoices (status, due_at);
create index on enrolments (end_date);
create index on app_sessions (student_id, started_at);
create index on focus_sessions (student_id, started_at);
create index on quiz_attempts (student_id);
