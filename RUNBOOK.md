# Runbook: RobotShopWebUnavailable

**Alert:** `RobotShopWebUnavailable`. The shop's front page has failed its health probe for at least one minute.
**Severity:** critical. Customers cannot load the shop.
**Goal:** restore service first, find the cause after.

## 1. Acknowledge and note the time

Write down the UTC time (`date -u`). You need it for the postmortem.

## 2. See what is broken

```
kubectl get pods -n robot-shop
```

- A pod that is missing, `Pending`, `CrashLoopBackOff` or `0/1` is where to start.
- If the whole cluster is unreachable, check `kubectl get nodes`.

## 3. Check what changed recently

```
helm history robot-shop -n robot-shop
```

If a release was installed or upgraded shortly before the alert, suspect it.

## 4. Mitigate (do this before looking for the cause)

| Situation | Action |
|---|---|
| Bad release | `helm rollback robot-shop <last good revision> -n robot-shop` |
| A deployment was scaled to 0 | `kubectl scale deployment <name> --replicas=1 -n robot-shop` |
| A pod is stuck or crashing | `kubectl rollout restart deployment <name> -n robot-shop` |
| Pods `Pending` | `kubectl describe pod <pod> -n robot-shop` and read the Events section |

## 5. Verify recovery

- The probe query `probe_success{instance="http://web.robot-shop.svc:8080/"}` returns `1` in Grafana Explore.
- The resolved message appears in `#alerts`.
- Note the UTC time of recovery.

## 6. Find the cause

- Logs for a service, in Grafana Explore with the Loki data source: `{service="web"} | detected_level="error"`. Replace `web` with the service you suspect.
- Pod details: `kubectl describe pod <pod> -n robot-shop`, then `kubectl logs <pod> -n robot-shop --previous`.
- A slow request can be followed in Jaeger (the shipping service is traced).

## 7. After the incident

Write a blameless postmortem: timeline, impact (minutes of downtime against the 432-minute budget), root cause, what went well, and follow-up actions.

## Escalation

If service is not restored within 15 minutes, ask the instructor for help.