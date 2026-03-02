
# Brain-Tasks App — End-to-End Deployment Documentation

This document covers the entire project: source → Docker → ECR → CodeBuild → CodePipeline → EKS → LoadBalancer (NLB) and Uptime-Kuma monitoring. It includes what each component *is*, *why* it's used, *how* it's configured, code snippets, execution summary, setup instructions, and issues/bugs with fixes.

---

## Table of contents
1. Project overview & architecture
2. Prerequisites (accounts, tools, IAM roles, VPC)
3. Repository layout
4. Dockerize the React app — Dockerfile, nginx config, build notes
5. ECR — create repo, push image (buildspec snippet)
6. Kubernetes (EKS) — cluster, nodegroups, CNI, kube-proxy and manifests
7. Manifests — deployment/service for app and Uptime-Kuma (ready-to-apply YAML)
8. CI/CD — CodeBuild, CodePipeline, buildspecs, deploy step, deploy script, recommendations
9. IAM roles & permissions (policies + trust JSON snippets)
10. Common problems encountered (diagnosis + fixes)
11. Verification checklist & debug commands
12. Appendix — full files and useful reference commands

---

## 1 — Project overview & architecture

**What:** Deploy a React SPA packaged into an nginx Docker image, hosted on EKS behind a Kubernetes `Service: LoadBalancer` which creates an AWS NLB. Build & push Docker image via CodeBuild → ECR; orchestrate CI/CD via CodePipeline. Provide monitoring with Uptime-Kuma as a Kubernetes Deployment + LoadBalancer service.

**Why:** portable Docker runtime, AWS-native CI/CD & registry, managed orchestration with EKS, and simple monitoring service for uptime checks.

**Logical architecture:**

GitHub → CodePipeline (Source) → CodeBuild (Build image & push to ECR) → CodeBuild (Deploy step) → `kubectl apply` manifests → EKS cluster (Pods) → Service (LoadBalancer/NLB) → Internet

---

## 2 — Prerequisites

- AWS account with required IAM rights.
- GitHub repo connected to CodePipeline.
- Locally: `kubectl`, `aws` CLI; `eksctl` if creating cluster via CLI or use CloudShell.
- EKS cluster with nodes in subnets that allow public egress for worker nodes or appropriate NAT/IGW.
- Ensure security groups allow NodePort traffic from the NLB when using instance mode.

---

## 3 — Repository layout (recommended)
```
/
├─ Dockerfile
├─ nginx.conf
├─ dist/
├─ k8s/
│  ├─ app/
│  │  ├─ deployment.yaml
│  │  └─ service.yaml
│  └─ monitoring/
│     ├─ kuma-deployment.yaml
│     ├─ kuma-pvc.yaml
│     └─ kuma-service.yaml
├─ scripts/
│  └─ deploy.sh
├─ buildspec-build.yml
├─ buildspec-deploy.yml
└─ README.md
```

---

## 4 — Dockerize the React app

**Dockerfile:**
```dockerfile
FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY dist /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

**nginx.conf example:**
```nginx
server {
  listen       80;
  server_name  _;
  root /usr/share/nginx/html;
  index index.html;

  location / {
    try_files $uri $uri/ /index.html;
  }

  gzip on;
  gzip_types text/plain application/json text/css application/javascript;
}
```

Notes: Ensure `dist` contains the production build. If building in CI, generate `dist` in the build phase.

---

## 5 — ECR: store Docker images

Create ECR repo once:
```bash
aws ecr create-repository --repository-name brain-tasks-app --region us-east-1
```

In CI buildspec (high-level):
```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com
docker build -t brain-tasks-app .
docker tag brain-tasks-app:latest <account>.dkr.ecr.us-east-1.amazonaws.com/brain-tasks-app:latest
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/brain-tasks-app:latest
```

Note: Watch Docker Hub pull rate limits; either authenticate to Docker Hub or use cached/base images.

---

## 6 — Kubernetes (EKS) setup & tips

- Use `aws eks update-kubeconfig` to configure kubectl for the cluster.
- Ensure `aws-node` (VPC CNI) and `kube-proxy` daemonset exist. Missing `kube-proxy` causes NodePort behavior to fail.
- Check: `kubectl get daemonset -n kube-system` and `kubectl get pods -n kube-system`.

---

## 7 — Kubernetes manifests (canonical)

**App deployment (k8s/app/deployment.yaml):**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: brain-tasks-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: brain-tasks
  template:
    metadata:
      labels:
        app: brain-tasks
    spec:
      containers:
      - name: brain-tasks
        image: 175948132922.dkr.ecr.us-east-1.amazonaws.com/brain-tasks-app:latest
        ports:
        - containerPort: 80
```

**App service (k8s/app/service.yaml):**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: brain-tasks-service
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  type: LoadBalancer
  selector:
    app: brain-tasks
  ports:
    - port: 80
      targetPort: 80
```

**Uptime-Kuma deployment & service (k8s/monitoring):** see files `kuma-deployment.yaml`, `kuma-pvc.yaml`, `kuma-service.yaml` in repo (use port 3001 and targetPort 3001).

---

## 8 — CI/CD: buildspecs and pipeline

**buildspec-build.yml** (build & push to ECR) — example in documentation earlier.
**buildspec-deploy.yml** (deploy to EKS) — include `aws eks update-kubeconfig` and explicit `kubectl apply -f k8s/monitoring/kuma-service.yaml` and other manifests. Make the pipeline `kubectl get svc` after apply to assert state.

**Deploy script (scripts/deploy.sh)** — optional. If used, ensure pipeline invokes it and working directory is correct.

**Pipeline flow recommended:** Source (GitHub) → Build (CodeBuild: build & push) → Deploy (CodeBuild: run kubectl applies).

---

## 9 — IAM roles & policies

- CodeBuild role trust to `codebuild.amazonaws.com` and permissions for ECR, S3 (artifact bucket), EKS (DescribeCluster), CloudWatch Logs.
- Pipeline role: s3:GetObject/List, codebuild:StartBuild, iam:PassRole as needed.
- EKS node role typically has EC2 and ELB permissions if managed nodegroup is used. Verify if you have custom node roles.

---

## 10 — Issues encountered & fixes (autopsy)

1. eksctl not installed on Windows → use CloudShell or install eksctl.
2. CodeBuild sts:AssumeRole error → fix trust policy for role.
3. S3 artifact access denied → add s3:GetObject/List to role on artifacts bucket.
4. Docker Hub pull rate limit → authenticate Docker Hub or use prebuilt base images.
5. targetPort mismatch (app service) → ensure service targetPort matches containerPort (80).
6. Missing kube-proxy → install EKS managed add-on `kube-proxy` to enable NodePort routing.
7. NLB vs ALB confusion / wrong port usage → use correct port in curl or change service to port 80 for external access.
8. Security group blocking NodePort → add inbound rules to node SG from LB.
9. Stale ELB hostname / DNS negative cache → delete and recreate service or flush DNS; ensure pipeline recreates service properly.
10. Pipeline not applying monitoring manifests → ensure `k8s/monitoring` files are present in repo and `kubectl apply -f k8s/monitoring/` is invoked explicitly.

---

## 11 — Verification checklist & commands

Key commands to validate cluster and resources (copy/paste):
```bash
aws eks update-kubeconfig --region us-east-1 --name brain-tasks-cluster
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get daemonset -n kube-system
kubectl get svc -o wide
kubectl describe svc brain-tasks-service
kubectl exec -it <pod> -- curl localhost:80
```
AWS console checks: EC2 → Load Balancers, Target Groups, Instances, Security Groups.
---

## 12 — Appendix: sample buildspec-deploy.yml (recommended)
```yaml
version: 0.2
phases:
  install:
    commands:
      - curl -o kubectl https://amazon-eks.s3.us-west-2.amazonaws.com/1.27.1/2023-04-19/bin/linux/amd64/kubectl
      - chmod +x kubectl
      - mv kubectl /usr/local/bin/
  pre_build:
    commands:
      - aws eks update-kubeconfig --region us-east-1 --name brain-tasks-cluster
  build:
    commands:
      - echo "pwd: $(pwd)"
      - ls -R
      - kubectl apply -f k8s/app/deployment.yaml
      - kubectl apply -f k8s/app/service.yaml
      - kubectl apply -f k8s/monitoring/kuma-pvc.yaml || true
      - kubectl apply -f k8s/monitoring/kuma-deployment.yaml
      - kubectl apply -f k8s/monitoring/kuma-service.yaml
      - kubectl rollout restart deployment/brain-tasks-app || true
      - kubectl get svc -o wide
```

---

### Final note
This doc is intentionally exhaustive and pragmatic. It focuses on deterministic fixes and exact commands so the pipeline correctly applies the monitoring manifests and ensures AWS provisions corresponding Load Balancers. If you want, I will now export this content as:
- `Brain-Tasks-Deployment-Documentation.docx`
- `README.md` (Markdown file)

I will create both files and provide download links.
