# Alcovia — Product, Systems & Analytics Lead assignment

Submission by **Shaibaz Shaikh**.

| Deliverable | Where |
|---|---|
| Executive write-up | `site/writeup.html` (live link in the submission form) |
| GTM tracker dashboard | `site/gtm.html` |
| Student tracker dashboard | `site/students.html` |
| Warehouse schema | `schema/schema.sql` |
| Metric queries | `sql/gtm_metrics.sql`, `sql/student_metrics.sql` |
| n8n workflows (importable) | `n8n/*.json` |

## Architecture

```
ClickUp (lead statuses) ─┐
Razorpay (webhooks) ─────┤
Meta Ads Insights API ───┤                      ┌─ SQL views ─→ Metabase dashboards (embedded in ClickUp)
Smallest.ai callbacks ───┼──→ n8n ──→ Supabase ─┤
Alcovia app DB (replica) ┤   (9 flows)  (Postgres)└─ nightly rules ─→ WhatsApp / ClickUp nudges
Wearables (WHOOP, HealthKit, Health Connect, Garmin)
Quiz Google Form ────────┘
```

Principles:
1. **ClickUp stays the team's UI.** Status changes become immutable stage events, so funnel metrics are computed, not typed.
2. **Classify at source.** Every Razorpay invoice/payment link carries `notes.product_code` (`TRIAL_3M`, `PROGRAM_12M`, `WORKSHOP`) and `workshop_id`.
3. **Idempotent and observable.** Source ids are primary keys; every workflow routes failures to `08_error_handler`, which opens a P1 ClickUp task.

## n8n workflows

| # | Flow | Trigger | What it does |
|---|---|---|---|
| 01 | Razorpay → warehouse | Webhook | Verifies HMAC, upserts payment, marks invoice paid, moves ClickUp lead to Won, opens onboarding task |
| 02 | Meta Ads daily pull | 06:00 daily | Ad-level insights upsert; frequency ≥ 3 opens a "refresh creative" task |
| 03 | ClickUp stage sync | ClickUp webhook | Status → `lead_stage_events`; triggers Smallest.ai reminder calls |
| 04 | Smallest.ai outcomes | Webhook | Logs call outcome; no-answer/reschedule → 3-hour callback task |
| 05 | Daily quiz ingest | 21:00 daily | Auto-graded quiz responses → `quiz_attempts` |
| 06 | Nightly app + wearables | 02:00 daily | Replicates app sessions/focus, normalises wearables, refreshes `mv_student_health` |
| 07 | Missed-deadline alerts | 21:30 daily | One grouped nudge per teen; parent only on repeat breach; de-duped via `alerts_log` |
| 08 | Error handler | Any failure | P1 task in the Systems list |
| 09 | Trial renewal pipeline | 10:00 daily | T-21 progress report → T-14 advisor call → T-7 Razorpay invoice |

Import: n8n → Workflows → Import from file. Credentials are placeholders (`PG_ALCOVIA`, `CLICKUP`, …) and env vars are listed in each flow's sticky note and node expressions.

## Running the SQL

```bash
psql "$SUPABASE_DB_URL" -f schema/schema.sql
# metric queries take :from_date, :to_date (and :student_id for student metrics)
psql "$SUPABASE_DB_URL" -v from_date="'2026-10-01'" -v to_date="'2026-10-31'" -f sql/gtm_metrics.sql
```

## Dashboards

Static HTML + Chart.js, no build step. Dummy data is generated in the page with a fixed seed, so numbers are stable between visits and change with the timeline selector. In production the same layouts read the SQL views above.

## RCA rules (campaigns)

- **Scale** (+20–30% budget): CPQL ≤ 80% of average, ≥ 1 sign-up, frequency < 3
- **Refresh**: frequency ≥ 3 or CTR < 70% of average
- **Drop**: CPQL > 150% of average and zero sign-ups
- **Hold**: everything else
