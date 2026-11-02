# Final Plan: FastAPI → Docker → Kubernetes → Helm → AWS CDK → CI/CD

*A self-guided build with pointers, not answers. Each phase has a goal, things to build, search terms and docs to lean on, a test checkpoint, a break-it exercise, and the CI you add.*

## How to use this plan

- Work top to bottom. Don't start a phase until the previous one's **test checkpoint** passes.
- Every phase has a **Break it** exercise. Do it. Most of the learning is in debugging.
- CI starts on day one and grows a little each phase. CD (deploying to real environments) comes last.
- Keep a `LEARNING.md` with one short paragraph per phase: what broke, why, how you fixed it.
- Pin versions as you go (base images, kind node image, Helm chart versions, GitHub Actions). Unpinned dependencies cause most "it worked yesterday" problems.
- Tag images with the git SHA, never `latest`.

### Decisions already made

- **kind** for local Kubernetes (no minikube).
- **Trunk-based promotion:** build one image per commit, then promote that same image through dev → test → prod. Only the values files differ.
- **ingress-nginx** locally and on AWS, for parity. The AWS Load Balancer Controller is a stretch goal.
- **One EKS cluster, three namespaces** (`dev`, `test`, `prod`). Not real isolation, but fine for learning.
- **No custom domain or TLS.** The load balancer's generated DNS name is enough.
- **CDK owns infrastructure; Helm owns the app.** Keep that boundary clean.

### Time and cost

Roughly 4 weeks at a few evenings a week. Everything through Phase 5a is essentially free. Phase 5b (EKS) costs real money (control plane about $0.10/hr, plus nodes and a NAT gateway). Timebox it and destroy the stack at the end of every session.

### Target repo layout

```
hello-platform/
├── app/                  # FastAPI code + tests
├── Dockerfile
├── Makefile
├── k8s/                  # raw manifests (phases 2-3, deleted in phase 4)
├── chart/hello-api/      # Helm chart (phase 4)
├── infra/                # CDK app (phase 5)
├── LEARNING.md
└── .github/
    ├── workflows/
    └── dependabot.yml
```

## Phase 0: Setup, repo, and guardrails (about 1–2 hours)

**Goal:** a working toolchain, a GitHub repo, and a CI skeleton that runs.

**Build:**

- [x] Install Docker Desktop, `kubectl`, `kind`, `helm`, AWS CLI v2, Node.js (for CDK), and Python 3.12+.
- [x] Create the GitHub repo and clone it. Add the layout above (empty folders need a `.gitkeep`).
- [x] Write a `Makefile` with placeholder targets: `test`, `lint`, `build`, `kind-up`, `kind-down`, `deploy-local`. You'll fill them in over the next phases, and CI will call the same targets.
- [ ] Add a trivial `.github/workflows/ci.yml` that checks out the repo and runs `echo hello`.
- [ ] Turn on **branch protection** for `main` (require PRs and passing status checks).
- [ ] Add `.github/dependabot.yml` for `github-actions` and `pip`.
- [ ] Set an **AWS Budget alert** now, while you remember. Create a non-root IAM/SSO identity for CLI use rather than using root keys.

**Pointers:**

- [ ] GitHub docs: "About protected branches" and "Dependabot version updates".
- [ ] AWS docs: "Creating a budget" and "IAM Identity Center" (SSO) for CLI auth.

**Test checkpoint:**

- [ ] `docker version`, `kubectl version --client`, `kind version`, `helm version`, `aws sts get-caller-identity` all work.
- [ ] Open a PR that changes a file. The workflow runs and shows as a required check.

**Break it:** push directly to `main` and confirm branch protection stops you.

## Phase 1: Dockerized FastAPI (1–2 evenings)

**Goal:** a tested app in a small, safe container image.

**Build:**

- [ ] `app/main.py` with `GET /` (hello world) and `GET /healthz` (returns a simple status). The health endpoint matters for Kubernetes probes later.
- [ ] `requirements.txt` (pin versions) and a `pytest` test using FastAPI's `TestClient`.
- [ ] `Dockerfile`: slim Python base image, copy requirements before the code (layer caching), run as a **non-root user**, serve with uvicorn on `0.0.0.0:8000`.
- [ ] `.dockerignore`.
- [ ] Fill in the Makefile targets `test`, `lint` (use `ruff`), and `build` (tag with the short git SHA).

**Pointers:**

- [ ] Search: "FastAPI testing TestClient", "Dockerfile best practices non-root user", "uvicorn host 0.0.0.0 in Docker".
- [ ] Why `0.0.0.0`? Binding to `127.0.0.1` inside a container makes the port unreachable from outside.
- [ ] Think about graceful shutdown: what does uvicorn do on SIGTERM, and why does Kubernetes care?

**Test checkpoint:**

- [ ] `make test` passes.
- [ ] `docker run -p 8000:8000 <image>` then `curl localhost:8000/` and `/healthz` both respond.
- [ ] `docker exec <container> whoami` does not say `root`.

**Break it:**

- [ ] Bind to `127.0.0.1` and observe the failure from the host.
- [ ] Remove the layer-caching order (copy everything first) and compare rebuild times after a code change.

**CI added:** `ruff`, `pytest`, and `docker build` on every PR. Add Trivy image scanning if you want a cheap win (search "trivy-action").

**Stretch:** multi-stage build; compare image sizes with `docker images`.

## Phase 2: Local Kubernetes with kind (1–2 evenings)

**Goal:** run your container on a real (local) cluster and watch Kubernetes heal it.

**Build:**

- [ ] A kind cluster config file (you'll extend it in Phase 3). Pin the node image version.
- [ ] `k8s/deployment.yaml`: 2 replicas, resource requests and limits, readiness and liveness probes pointed at `/healthz`, and `securityContext` hardening (non-root, `readOnlyRootFilesystem` if the app tolerates it).
- [ ] `k8s/service.yaml`: type ClusterIP.
- [ ] Makefile targets: `kind-up` (create cluster), `deploy-local` (build, `kind load docker-image`, `kubectl apply`), `kind-down`.

**Pointers:**

- [ ] Search: "kind load docker-image", "kubernetes liveness vs readiness probe", "imagePullPolicy IfNotPresent kind".
- [ ] Use the SHA tag from Phase 1. You'll see quickly why `latest` plus the default pull policy misbehaves.
- [ ] Learn these commands until they're reflexive: `kubectl get`, `describe`, `logs`, `get events`, `exec`, `port-forward`.

**Test checkpoint:**

- [ ] Both pods reach `Ready`.
- [ ] `kubectl port-forward svc/hello-api 8080:80` then `curl localhost:8080/`.
- [ ] Delete a pod and watch the Deployment replace it.

**Break it (do all four, and diagnose each with only `kubectl`):**

- [ ] `ImagePullBackOff`: use a wrong image tag.
- [ ] `CrashLoopBackOff`: use a bad container command.
- [ ] Failing readiness probe: point it at a path that 404s.
- [ ] `OOMKilled`: set a tiny memory limit and generate load or allocate memory.

**CI added:** validate manifests with `kubeconform` (or `kubectl --dry-run=client`).

## Phase 3: Ingress with NGINX (1 evening)

**Goal:** route HTTP traffic into the cluster the way you will on AWS.

**Build:**

- [ ] Recreate the kind cluster with `extraPortMappings` for 80/443 and the `ingress-ready` node label.
- [ ] Install **ingress-nginx** (the project's kind-specific install docs are the right starting point; use `helm` if you prefer, since you'll use Helm later anyway).
- [ ] `k8s/ingress.yaml`: route `hello.localhost` to your Service.
- [ ] Add a ConfigMap-driven env var such as `APP_ENV` and surface it in the hello response. You'll reuse this idea for dev/test/prod.

**Pointers:**

- [ ] Search: "ingress-nginx kind deploy", "ingressClassName", "Kubernetes ConfigMap env var envFrom".
- [ ] Read the ingress controller's logs to see requests arrive.

**Test checkpoint:**

- [ ] `curl http://hello.localhost/` works through the controller.
- [ ] Add a second path (e.g. `/api`) to see path-based routing, then remove it.
- [ ] Change the ConfigMap value, restart the pods, and see the response change. Work out *why* the restart was needed.

**Break it:** misspell the `ingressClassName` or the Service name, and use the controller logs and `describe ingress` to find it.

**CI added (optional):** a kind-based smoke test job using the `helm/kind-action`. You'll make this properly valuable in Phase 4.

## Phase 4: Helm chart (2–3 evenings)

**Goal:** replace raw manifests with a parameterized chart that works across three environments.

**Build:**

- [ ] Scaffold with `helm create`, then delete the boilerplate you don't need.
- [ ] Convert your manifests into templates. Parameterize: image repository and tag, replica count, resources, ingress host, env vars.
- [ ] `values.yaml` holds the defaults. Add `values-dev.yaml`, `values-test.yaml`, and `values-prod.yaml` as thin overrides.
- [ ] Add a **fake secret** (e.g. `API_KEY`): a Kubernetes Secret rendered by the chart from a value you pass at install time, mounted as an env var. Do not commit real values.
- [ ] Add a `helm test` hook (a small pod that curls the service).
- [ ] Delete `k8s/` once the chart works. The chart is now the source of truth.
- [ ] Makefile: update `deploy-local` to use `helm upgrade --install`.

**Pointers:**

- [ ] Search: "helm template functions include nindent", "helm values files precedence", "helm test hook", "helm rollback".
- [ ] Learn `_helpers.tpl` and why labels and selectors must stay consistent.
- [ ] Read about why base64 in a Secret is encoding, not encryption, and what real secret management looks like (External Secrets, Sealed Secrets, SOPS).

**Test checkpoint:**

- [ ] `helm lint chart/hello-api` is clean.
- [ ] `helm template` with each values file; read the output and confirm each differs as expected.
- [ ] Install into `dev` and `test` namespaces on kind simultaneously with different values.
- [ ] `helm upgrade` with a changed value, then `helm rollback`, and read `helm history`.
- [ ] `helm test <release>` passes.

**Break it:**

- [ ] Introduce a template syntax error and a values typo. Compare how `lint`, `template`, and `install --dry-run` each report them.
- [ ] Mismatch a label selector and see what the API server says.

**CI added (high value):**

- [ ] `helm lint` and `helm template` for every values file.
- [ ] A job that spins up kind, builds and loads the image, installs the chart, runs `helm test`, and curls `/healthz`. This proves in CI what you did by hand in Phases 2–4.

## Phase 5a: CDK basics with ECR and GitHub OIDC (1–2 evenings)

**Goal:** learn CDK and give GitHub keyless access to AWS, at almost no cost.

**Build:**

- [ ] `cdk init` in `infra/` (TypeScript or Python; pick the one you're more comfortable reading). Run `cdk bootstrap` for your account and region.
- [ ] A stack containing:
  - [ ] An **ECR repository**, with a lifecycle policy to expire old images and `removalPolicy` set deliberately.
  - [ ] A **GitHub OIDC identity provider** and an **IAM role** that GitHub Actions can assume, with a trust policy scoped to *your repo* (and later specific branches or environments), not `repo:*`. Grant it only ECR push permissions for now.
- [ ] Tag every resource consistently (e.g. `project=hello-platform`).

**Pointers:**

- [ ] Search: "cdk bootstrap", "aws-cdk-lib aws\_ecr Repository lifecycle", "GitHub Actions OIDC AWS configure-aws-credentials", "aws\_iam OpenIdConnectProvider".
- [ ] **Chicken-and-egg:** CDK creates the role GitHub needs, but GitHub can't deploy without it. Your first `cdk deploy` must run from your laptop. After that, CI can take over.
- [ ] Check the OIDC subject claim format (`repo:OWNER/REPO:ref:refs/heads/main` and `...:environment:NAME`) in GitHub's docs when writing the condition.

**Test checkpoint:**

- [ ] `cdk synth` and `cdk diff` show what you expect; `cdk deploy` succeeds.
- [ ] A GitHub Actions run assumes the role (use `aws sts get-caller-identity` as a step) without any stored AWS keys.
- [ ] The workflow pushes your SHA-tagged image to ECR on merge to `main`.

**Break it:**

- [ ] Run the workflow from a branch or fork your trust policy shouldn't allow and confirm the assume-role fails.
- [ ] Remove a permission and read the exact IAM error.

**CI added:** `cdk synth` on PRs, and image push to ECR on merge to `main`. At this point you have a real build pipeline, all nearly free.

## Phase 5b: EKS with CDK (2–3 evenings, costs money)

**Goal:** run your Helm chart on a real cluster in AWS. Timebox this phase.

**Before you start:** confirm the budget alert works, write a `make destroy-eks` target, and plan to tear down every session.

**Build:**

- [ ] A second stack (keep it separate from ECR/OIDC so you can destroy it without losing the repo): a **VPC** (minimize NAT gateways to one), an **EKS cluster**, and a small managed node group (2 × t3.medium is plenty).
- [ ] Install **ingress-nginx** on the cluster via Helm. Decide whether CDK installs it (the `cluster.addHelmChart` construct) or you do it by hand once. Notice the trade-off between the two.
- [ ] Grant the GitHub role the access it needs to talk to the cluster (EKS access entries or the `aws-auth` ConfigMap; look up which your CDK version prefers).
- [ ] Fetch kubeconfig with `aws eks update-kubeconfig` and `helm upgrade --install` your chart with `values-dev.yaml` into the `dev` namespace.

**Pointers:**

- [ ] Search: "aws-cdk-lib aws\_eks Cluster", "EKS access entries vs aws-auth", "ingress-nginx AWS NLB annotations", "update-kubeconfig".
- [ ] Expect the cluster to take 10–15 minutes to create. Expect your first attempt to hit an IAM or kubectl-access problem; that's part of the lesson.
- [ ] Pull your image from ECR: the node role needs read access (the managed node group's default role usually covers it, but verify).

**Test checkpoint:**

- [ ] `kubectl get nodes` shows nodes Ready.
- [ ] Pods Running in `dev`.
- [ ] `curl` the load balancer's DNS name (with a Host header if your ingress uses a hostname) and get the hello response.

**Break it:**

- [ ] Push an image tag that doesn't exist in ECR; diagnose `ImagePullBackOff` against a real registry.
- [ ] Scale the node group down to 1 and watch scheduling behavior.

**Cost kill switch (do this every session):**

- [ ] `helm uninstall` anything creating load balancers *before* `cdk destroy`, otherwise orphaned load balancers can block VPC deletion and keep billing.
- [ ] After teardown, check the console for leftover load balancers, NAT gateways, elastic IPs, and volumes.

**CI added:** `cdk diff` on PRs that touch `infra/` (read-only role scope is enough).

## Phase 6: CD with dev, test, prod (2–3 evenings)

**Goal:** one image, promoted through environments automatically with a manual gate for prod.

**Build:**

- [ ] **GitHub Environments:** create `dev`, `test`, `prod`. Store environment-specific variables and secrets (including your fake `API_KEY`) per environment. Add **required reviewers** to `prod`.
- [ ] Tighten the OIDC trust policy so each environment's role can only be assumed by jobs running in that environment (or use one role per environment).
- [ ] `deploy.yml` triggered on merge to `main`:
  - [ ] Build and push the image tagged with the git SHA (reuse what you built in 5a).
  - [ ] Deploy to **dev** automatically: `helm upgrade --install` with `values-dev.yaml` into namespace `dev`, using `--atomic` or `--wait`.
  - [ ] Smoke test: curl `/healthz` through the ingress and fail the job unless it returns 200.
  - [ ] Deploy to **test** after dev passes, then smoke test again.
  - [ ] Deploy to **prod** after manual approval, then smoke test.
- [ ] Use `needs:` to chain jobs and `environment:` to bind each to its GitHub Environment.

**Pointers:**

- [ ] Search: "GitHub Actions environments required reviewers", "needs and environment keyword", "helm upgrade --atomic --wait --timeout", "reusable workflows" (to avoid copy-pasting three deploy jobs).
- [ ] Decide how the pipeline finds the ingress hostname for the smoke test. Options: read it with `kubectl`, or store it as an environment variable.
- [ ] Keep "test" thin. Its job is a gated promotion and a smoke test, not distinct infrastructure.

**Test checkpoint:**

- [ ] Open a PR: CI runs only, with no deploys.
- [ ] Merge it: dev → test run automatically, prod waits for approval, then deploys.
- [ ] Same image SHA appears in all three namespaces (`kubectl get deploy -o wide`).

**Break it:**

- [ ] Merge a deliberately broken change (bad probe path) and confirm the pipeline stops before prod, and that `--atomic` rolls back.
- [ ] Reject the prod approval and confirm nothing deploys.
- [ ] Practice `helm rollback` on prod by hand and compare with re-running an older pipeline.

## Final checklist

- [ ] All CI checks are required on `main`.
- [ ] No long-lived AWS keys exist anywhere (GitHub or laptop shell history).
- [ ] OIDC trust is scoped to repo and environment.
- [ ] EKS is destroyed and no orphaned load balancers, NAT gateways, or volumes remain.
- [ ] `LEARNING.md` has an entry for every phase.
- [ ] You can explain: why SHA tags, why probes exist, why base64 isn't encryption, and why CDK and Helm are kept separate.

## Stretch goals (pick any, in any order)

- [ ] A tiny stateful dependency (Redis or Postgres as a Helm subchart) for a hit counter: covers Helm dependencies, Service discovery, and PVCs.
- [ ] AWS Secrets Manager with External Secrets Operator, replacing the fake secret.
- [ ] AWS Load Balancer Controller instead of ingress-nginx (requires IRSA or Pod Identity).
- [ ] Horizontal Pod Autoscaler with a load test.
- [ ] Prometheus and Grafana.
- [ ] TLS with cert-manager and Route 53.
- [ ] Argo CD for GitOps instead of `helm upgrade` in CI.
- [ ] Multi-stage Docker build and image-size comparison.
