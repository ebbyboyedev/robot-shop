# SLO and Error Budget Policy: Stan's Robot Shop

## What we measure (the SLI)

Availability of the shop's front page: the share of health probes against `http://web.robot-shop.svc:8080/` that succeed.
The blackbox exporter makes one probe every 15 seconds, and Prometheus stores the result as `probe_success` (1 = success, 0 = failure).

## The target (the SLO)

**99% of probes succeed, measured over a rolling 30 days.**

## The error budget

The budget is the failure the SLO allows: 1% of 30 days.

| Item | Value |
|---|---|
| Period | 30 days = 43,200 minutes |
| Allowed failure (1%) | **432 minutes** |
| Failed probes allowed | about 1 in 100 |

Budget consumed = minutes the front page was failing divided by 432.

## How we track it

- The `Robot Shop RED` Grafana dashboard shows availability, errors and latency per service.
- The query `avg_over_time(probe_success{instance="http://web.robot-shop.svc:8080/"}[30d])` gives the 30-day availability.
- Alert `RobotShopWebUnavailable` pages the `#alerts` channel in Slack when the front page fails its probes for one minute. It links to the runbook.

## What we do as the budget is used

| Budget used | Action |
|---|---|
| Under 50% | Normal work. Releases continue. |
| 50% to 99% | Slow down. Every change needs a rollback plan. Review the causes of the failures so far. |
| 100% or more | **Freeze.** No feature releases. Only reliability fixes and rollbacks go out until availability is back above 99% over 30 days. |

## Rules

1. A single incident that uses more than 25% of the budget (over 108 minutes) needs a blameless postmortem.
2. Every postmortem produces at least one follow-up action with an owner.
3. Planned maintenance counts against the budget unless it is announced in advance and approved.

## Known limits of this SLO

- The probe checks that the front page answers. It does not prove that checkout, payments or shipping work.
- The probes come from inside the cluster, so they cannot see an outage that happens between users and the cluster.
- Burn-rate alerts (fast and slow) are not implemented. They are the natural next step.
