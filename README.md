# Capstone 2: Keep It Running (Stan's Robot Shop)

A fork of `instana/robot-shop`, run on the EKS cluster built in Capstone 1 and made observable: metrics, logs, a trace, an SLO and an alert that reaches Slack.
The cluster itself is built from code in the Capstone 1 repository (`ebbyboyedev/capstone-voting-app`, folder `terraform/`).

## What is in this repository

| Path | Purpose |
|---|---|
| `K8s/helm` | The shop's Helm chart, with the Instana settings removed and a few fixes (see "Problems and fixes") |
| `K8s/load-deployment.yaml` | The load generator that keeps traffic flowing |
| `monitoring/` | Values and manifests for Prometheus, Grafana, Loki, Fluent Bit, Jaeger, the probes and the alert rule |
| `monitoring/robot-shop-dashboard.json` | The Grafana dashboard, exported as code |
| `docs/SLO_AND_ERROR_BUDGET_POLICY.md` | The SLO and error budget policy |
| `RUNBOOK.md` | The runbook the alert links to |
| `POSTMORTEM.md` | The blameless postmortem for the incident drill (*to be added after the drill*) |
| `scripts/install-shop.sh` | Installs the shop and the load generator |

## Step 1: Deploy and watch

- Installed the chart into its own namespace: `helm install robot-shop ./K8s/helm --namespace robot-shop --create-namespace`.
- Removed the Instana agent settings: the `INSTANA_AGENT_HOST` entry from the `cart`, `payment`, `user`, `catalogue` and `dispatch` Deployments, the end-user-monitoring variables from `web`, and the matching `eum` section of `values.yaml`.
- Started the load generator (15 simulated clients, some deliberately bad requests) with `kubectl apply -f K8s/load-deployment.yaml -n robot-shop`.
- **Known gap:** the load generator image is `robotshop/rs-load:latest`, an unpinned tag.

### Problems and fixes

1. **Redis stayed `Pending`.** The chart asked for a storage class called `standard`, which does not exist on EKS. I changed `storageClassName` to `gp2`, which the chart's own documentation recommends for EKS.
2. **The disk still was not created.** The cluster had no EBS CSI driver. I added the `aws-ebs-csi-driver` add-on in Terraform. Its controller crash-looped: the log showed it could not get credentials from the node's metadata service, because pods on the node cannot reach it. The fix was EKS Pod Identity: the `eks-pod-identity-agent` add-on, a dedicated IAM role for the driver, and an association between that role and the driver's service account, all in Terraform.
3. **Not enough room for pods.** One node holds only 29 pods, and 26 were running before monitoring was added. I raised the node group to two nodes (`desired_size = 2`).
4. **`shipping` never became ready.** Its log showed `GC overhead limit exceeded`, meaning the Java heap was too small for the load. I raised the heap to `-Xmx1280m` and the container limits to 2000Mi memory and 500m CPU. The pod became ready, its restart count stayed at zero, and the error lines in Loki stopped at the moment the new pod started.

## Step 2: Metrics

- Installed `kube-prometheus-stack` with Helm, using `monitoring/kube-prometheus-stack-values.yaml`. It limits Prometheus memory and keeps 6 hours of data, so it does not exhaust a node. Grafana was first limited to 256Mi, was `OOMKilled`, and now has a 768Mi limit.
- **Why the dashboard uses probes.** The shop's services do not expose request, error and latency metrics. I installed the blackbox exporter and a `Probe` object (`monitoring/probe.yaml`) that calls the front page and the `/health` page of `catalogue`, `cart`, `user` and `payment` every 15 seconds.
- The dashboard `Robot Shop RED` has four panels:
  - **Availability:** `avg_over_time(probe_success[5m])`
  - **Errors:** `1 - avg_over_time(probe_success[5m])`
  - **Latency:** `probe_duration_seconds`
  - **Requests:** `rate(items_added[5m])`. **This is a compromise.** The cart is the only service that publishes a traffic metric, a counter of items added to carts, so request volume is shown for that one business action, not for all HTTP traffic. A `ServiceMonitor` (`monitoring/servicemonitor-cart.yaml`) scrapes it, and I added a `service: cart` label to the cart's Service in the chart so the monitor can find it.
- The dashboard is exported to `monitoring/robot-shop-dashboard.json`.

## Step 3: Logs

- **Loki** runs as a single binary with filesystem storage on a 5 Gi `gp2` disk (`monitoring/loki-values.yaml`). Its memory caches are switched off, because their default requests cannot be scheduled on this cluster.
- **Fluent Bit** runs on every node and ships container logs to Loki (`monitoring/fluent-bit-values.yaml`), with Kubernetes labels added automatically. Grafana's Loki data source points at `http://loki.monitoring.svc.cluster.local:3100`.
- **Searching:**
  - By service: `{service="cart"}`
  - Errors from every service: `{job="fluent-bit"} | detected_level="error"`
- This search found a real problem: roughly a thousand errors per hour from `web`, all caused by `shipping` failing its readiness check (see problem 4 above).

## Step 4: Tracing

- **Jaeger** runs in the `monitoring` namespace (`monitoring/jaeger.yaml`) and stores traces in memory, so a restart loses them.
- The **OpenTelemetry Java agent** is attached to the `shipping` service. An init container downloads the agent jar into a shared folder, and environment variables load it and send traces to Jaeger over OTLP (HTTP, port 4318).
- A request through the shop to `shipping` produces a trace with five spans, including the database query. *(Add the screenshot of the trace here.)*
- **Limits:** only `shipping` is instrumented, so the trace shows one service. The instructor's OpenTelemetry Collector configuration was not available, so the agent sends traces directly to Jaeger without a Collector in between. The agent is downloaded from GitHub's "latest" release and is not pinned.

## Step 5: SLO and alert

- **SLO:** 99% of probes against the front page succeed over 30 days. The error budget is 432 minutes. See `SLO_AND_ERROR_BUDGET_POLICY.md`.
- **Alert:** `RobotShopWebUnavailable` fires when the front page fails its probe for one minute (`monitoring/slo-rules.yaml`). Alertmanager sends it to the `#alerts` channel of my Slack workspace, and the message links to `RUNBOOK.md`.
- **Slack webhook:** the URL is stored only as a Kubernetes secret (`slack-webhook` in the `monitoring` namespace) and mounted into Alertmanager. It is not in Git. The secret must be created again after every cluster rebuild.
- **Tested:** I scaled the `web` deployment to zero. The alert arrived in Slack with the runbook link. *(Add the screenshot and the times here.)*
- **Not done:** burn-rate alerts (optional in the brief).

## Step 6: Incident drill

*To be completed after the drill: what the instructor broke, how it was noticed (the alert), the mitigation, the root cause, and the link to `POSTMORTEM.md`.*

## Rebuilding after a teardown

To avoid charges, I destroy the cluster whenever I am not working. Everything is installed from files in these two repositories, in this order:

1. `terraform apply` in the Capstone 1 repository, then `aws eks update-kubeconfig --name capstone_eks --region us-east-1`.
2. Wait for both nodes and the EBS driver pods to be ready.
3. Create the `monitoring` namespace and the `slack-webhook` secret.
4. Install `kube-prometheus-stack`, then Loki, Fluent Bit, the blackbox exporter, and the manifests in `monitoring/`.
5. Run `scripts/install-shop.sh`.
6. Add the Loki data source in Grafana again and import the dashboard JSON.

Before a teardown: uninstall the shop and delete the `robot-shop` and `monitoring` namespaces first, so the shop's public load balancer and the disks are removed.

## Security notes

- No secrets are stored in Git. The Slack URL and the Grafana admin password live only in the cluster.
- The shop's web service is exposed through a public load balancer while it runs, with no login in front of it.