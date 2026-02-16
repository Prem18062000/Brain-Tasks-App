# Technical Tasks: Summary + CI/CD & Infra Artifacts

## Summary
- Purpose: CI/CD pipeline that builds, tests, containerizes, and deploys an app to Kubernetes behind NGINX.
- Components: `Jenkinsfile`, `Dockerfile`, Kubernetes manifests, NGINX config, buildspec.yml (CodeBuild) — examples and key gotchas.

---

## Jenkinsfile (Declarative pipeline)
- Builds code, runs tests, builds Docker image, pushes to registry, deploys to Kubernetes (kubectl or Helm).
- Use Jenkins credentials (username/password, kubeconfig, Docker registry creds) and agents with Docker & kubectl.

```groovy
// Jenkinsfile (example)
pipeline {
  agent any
  environment {
    REGISTRY = 'myregistry.example.com'
    IMAGE = "${REGISTRY}/myapp:${env.BUILD_NUMBER}"
    KUBECONFIG_CREDENTIAL_ID = 'kubeconfig-cred'
    DOCKER_CREDENTIALS_ID = 'docker-cred'
  }
  stages {
    stage('Checkout') { steps { checkout scm } }
    stage('Test') { steps { sh 'npm ci && npm test' } }
    stage('Build Image') {
      steps {
        withCredentials([usernamePassword(credentialsId: env.DOCKER_CREDENTIALS_ID, usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
          sh 'echo $DOCKER_PASS | docker login -u $DOCKER_USER --password-stdin ${REGISTRY}'
          sh "docker build -t ${IMAGE} ."
          sh "docker push ${IMAGE}"
        }
      }
    }
    stage('Deploy') {
      steps {
        withCredentials([file(credentialsId: env.KUBECONFIG_CREDENTIAL_ID, variable: 'KUBECONF')]) {
          sh 'export KUBECONFIG=$KUBECONF'
          sh "kubectl set image deployment/myapp myapp=${IMAGE} -n my-namespace"
        }
      }
    }
  }
  post { always { archiveArtifacts artifacts: 'logs/**', allowEmptyArchive: true } }
}
```

Gotchas: pin agent images, avoid running kubectl as root, prefer immutable tags.

---

## Dockerfile (multi-stage, example Node app)
- Keep image small, use multi-stage, set non-root user, set HEALTHCHECK.

```dockerfile
# Stage 1: build
FROM node:18-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
RUN npm run build

# Stage 2: runtime
FROM node:18-alpine
WORKDIR /app
COPY --from=builder /app . 
ENV NODE_ENV=production
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "dist/index.js"]
```

Gotchas: use specific base image tags, set `.dockerignore` to reduce context.

---

## Kubernetes implementation
- Use Namespace, Deployment (readiness/liveness probes, resources), Service, and Ingress (NGINX ingress controller).
- Prefer rolling updates, set PodDisruptionBudget and resource requests/limits.

```yaml
# k8s/deployment.yaml (snippet)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: my-namespace
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
        - name: myapp
          image: myregistry.example.com/myapp:REPLACE_TAG
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 3000
          readinessProbe:
            httpGet: { path: /ready, port: 3000 }
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /health, port: 3000 }
            initialDelaySeconds: 15
            periodSeconds: 20
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "512Mi" }
---
apiVersion: v1
kind: Service
metadata:
  name: myapp-svc
  namespace: my-namespace
spec:
  selector: { app: myapp }
  ports: [{ port: 80, targetPort: 3000 }]
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-ingress
  namespace: my-namespace
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
spec:
  rules:
    - host: myapp.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp-svc
                port: { number: 80 }
```

Gotchas: always set readiness probe so Ingress doesn't route to non-ready pods. Use Secrets for envs.

---

## NGINX configuration (reverse proxy + static caching)
- For Ingress controller you usually configure via ConfigMap/Annotations; example standalone `nginx.conf`:

```nginx
user  nginx;
worker_processes  auto;
error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

events { worker_connections 1024; }

http {
  include       mime.types;
  default_type  application/octet-stream;
  sendfile        on;
  keepalive_timeout  65;
  gzip on;
  gzip_types text/plain application/json text/css application/javascript;

  upstream app {
    server 127.0.0.1:3000;
  }

  server {
    listen 80;
    server_name myapp.example.com;

    client_max_body_size 50m;

    location / {
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_pass http://app;
      proxy_read_timeout 90;
    }

    location ~* \\.(js|css|png|jpg|jpeg|gif|svg|ico)$ {
      root /usr/share/nginx/html;
      expires 30d;
      add_header Cache-Control "public";
    }
  }
}
```

Gotchas: respect X-Forwarded headers for app to detect scheme; tune `client_max_body_size` for uploads.

---

## buildspec.yml (AWS CodeBuild example)
- Steps: install deps, build, create/push Docker image to ECR, output artifact.

```yaml
version: 0.2
env:
  variables:
    IMAGE_REPO: "my-ecr-repo"
phases:
  install:
    runtime-versions: { docker: 18, nodejs: 18 }
    commands:
      - echo Installing...
  pre_build:
    commands:
      - $(aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com)
      - REPO_URI=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/$IMAGE_REPO
  build:
    commands:
      - npm ci
      - npm run build
      - docker build -t $REPO_URI:$CODEBUILD_RESOLVED_SOURCE_VERSION .
  post_build:
    commands:
      - docker push $REPO_URI:$CODEBUILD_RESOLVED_SOURCE_VERSION
artifacts:
  files:
    - '**/*'
```

Gotchas: CodeBuild needs IAM rights for ECR and KMS if encrypted.

---

## Recommendations & Gotchas (summary)
- Secrets: store in Kubernetes Secrets / Vault; do not bake into images.
- Image tags: use immutable tags (build number / SHA); avoid `latest` in prod.
- Health checks: readiness vs liveness — readiness prevents traffic to startup pods.
- Resources: set requests/limits to avoid evictions and noisy neighbors.
- Logging: stream stdout/stderr; use structured logs for aggregation.
- Rollbacks: use deployment strategies & image tag immutability to enable rollbacks.
- Security: run non-root user in container; scan images.
- CI: cache dependencies, run tests early, fail fast.

- Place this content in `README.md` at the repository root.
