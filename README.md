# shoong-gitops

Shoong 서비스의 **GitOps 레포지토리**입니다.
ArgoCD가 이 레포를 단일 소스로 바라보며, 클러스터에 무엇이 어떻게 떠 있어야 하는지를 선언적으로 관리합니다.
앱·인프라·시크릿·관측성 스택의 배포 상태가 모두 이 레포의 Git 이력으로 추적됩니다.

---

## Shoong 프로젝트

Shoong은 음식 배달 도메인을 여러 개의 마이크로서비스로 나눠 구현하고,
Kubernetes(EKS) 위에서 GitOps로 배포·운영하는 클라우드 인프라 프로젝트입니다.

주문 → 조리 → 배달 → 알림으로 이어지는 흐름을 서비스 단위로 분리하고,
그 아래 인프라(IaC) → 이미지 빌드(CI) → 배포(GitOps/CD)까지의 파이프라인을 직접 구성했습니다.

### 레포지토리 구성

전체 시스템은 역할별로 레포지토리가 나뉘어 있습니다.

**플랫폼 / 인프라**

| 레포 | 역할 |
| --- | --- |
| [shoong-terraform](https://github.com/shoong-delivery/shoong-terraform) | AWS 인프라 프로비저닝 (IaC) |
| [shoong-gitops](https://github.com/shoong-delivery/shoong-gitops) | ArgoCD 앱 정의 / Helm 차트 관리 (CD) |

**애플리케이션**

| 레포 | 역할 | 포트 |
| --- | --- | --- |
| [shoong-order-api](https://github.com/shoong-delivery/shoong-order-api) | 주문 서비스 | 3001 |
| [shoong-kitchen-api](https://github.com/shoong-delivery/shoong-kitchen-api) | 주방 서비스 | 3002 |
| [shoong-delivery-api](https://github.com/shoong-delivery/shoong-delivery-api) | 배달 서비스 | 3003 |
| [shoong-notification-api](https://github.com/shoong-delivery/shoong-notification-api) | 알림 서비스 | 3004 |
| [shoong-batch](https://github.com/shoong-delivery/shoong-batch) | 오래된 주문 정리 배치 (CronJob) | - |
| [shoong-frontend](https://github.com/shoong-delivery/shoong-frontend) | 프론트엔드 | - |

### 레포 간 관계

```
shoong-terraform ──(EKS / ECR / RDS / OIDC / SSM 생성)──┐
                                                        ▼
  앱 레포 (order·kitchen·delivery·notification·batch·frontend)
        └─ GitHub Actions(OIDC)로 이미지 빌드 → ECR push
                                                        ▼
                                                shoong-gitops
                                    (ArgoCD가 Helm 차트로 EKS에 배포)
```

- **shoong-terraform** 이 클러스터·레지스트리·DB·CI 인증 기반을 먼저 만든다.
- 각 **앱 레포**는 GitHub Actions에서 OIDC로 AWS에 인증해 이미지를 빌드하고 ECR에 푸시한다.
- **shoong-gitops** 의 ArgoCD가 변경을 감지해 EKS에 배포한다.

---

## 이 레포의 역할

ArgoCD가 바라보는 **배포의 단일 진실 공급원(Single Source of Truth)** 입니다.
앱 레포의 CI가 이미지를 빌드해 ECR에 올린 뒤 이 레포의 이미지 태그를 갱신하면, ArgoCD가 그 변경을 감지해 클러스터에 반영합니다.

```
앱 레포 CI ─▶ envs/{env}/{app}.yaml 의 image.tag 갱신 (git push)
                          │
                          ▼
                  ArgoCD (자동 감지)
                          │
                          ▼
            charts/shoong-app 렌더링 → EKS 배포
```

배포 트리거가 `kubectl apply` 가 아니라 **Git 커밋**이므로, "지금 클러스터에 뭐가 떠 있나"가 곧 "이 레포의 현재 상태"가 됩니다.

## 동작 방식

### App of Apps 패턴
[argocd/bootstrap/](argocd/bootstrap/) 에 루트 Application 두 개만 두고, 나머지는 자식 Application으로 자동 생성합니다.

| 루트 | 바라보는 경로 | 내용 |
| --- | --- | --- |
| `app-of-apps-shared` | [argocd/shared/](argocd/shared/) | 환경 공통 인프라 (Istio base/istiod/gateway, metrics-server) |
| `app-of-apps-dev` | [argocd/dev/](argocd/dev/) | dev 환경의 인프라·앱·부하테스트 Application |

루트 두 개만 `kubectl apply` 하면 그 아래 Application들이 줄줄이 생성·동기화됩니다.
이후 **새 앱 추가는 `argocd/dev/` 에 Application YAML 하나 추가하고 push** 하면 끝입니다(직접 apply 불필요).

### Multi-source Application
앱 Application은 **Helm 차트와 values 파일을 분리**해 참조합니다([argocd/dev/shoong-order.yaml](argocd/dev/shoong-order.yaml)).

- source 1: `charts/shoong-app` (공통 차트)
- source 2: 같은 레포를 `ref: values` 로 참조 → `$values/envs/dev/shoong-order.yaml`

덕분에 차트 한 벌로 모든 앱을 렌더링하고, 차이는 values 파일로만 표현합니다.

### 자동 동기화
모든 Application은 `automated: { prune: true, selfHeal: true }` 입니다.
Git과 클러스터 상태가 어긋나면(수동 변경 등) ArgoCD가 Git 기준으로 되돌립니다(self-heal).

## 디렉토리 구조

```
shoong-gitops/
├── argocd/
│   ├── bootstrap/      # App of Apps 루트 (shared / dev)
│   ├── shared/         # 환경 공통 인프라 Application
│   ├── dev/  prod/     # 환경별 Application 정의 (infra-* / shoong-* / loadtest)
├── charts/
│   └── shoong-app/     # 모든 shoong 앱이 공유하는 단일 Helm 차트
├── envs/
│   ├── dev/  prod/     # 앱별 values 오버라이드 (CI가 image.tag를 갱신)
├── eso/
│   ├── dev/  prod/     # External Secrets (SecretStore / ExternalSecret)
├── infra/              # 서드파티 Helm 차트 values + Istio 리소스
│   ├── aws-lb-controller/  istio-base/  istiod/  istio-gateway/
│   ├── monitoring/  loki/  tempo/  promtail/  otel-collector/  kiali/
│   ├── metrics-server/  storage/  argocd-notifications/
│   └── istio-resources/    # Gateway / VirtualService / TargetGroupBinding
└── loadtest/           # k6 부하 테스트 CronJob
```

## 공통 Helm 차트 (charts/shoong-app)

6개 앱이 이 차트 하나를 공유합니다. 앱별 차이는 `envs/` values로만 표현합니다.

차트가 렌더링하는 리소스:

| 템플릿 | 용도 |
| --- | --- |
| `deployment` / `service` | 앱 배포 및 ClusterIP 서비스 |
| `hpa` | CPU 기반 오토스케일 (활성화 시) |
| `configmap` | `env` 값 주입 (OTEL 설정 등) |
| `cronjob` | 다중 CronJob (batch가 단일 이미지로 3개 잡 운영) |
| `virtualservice` | Istio 경로 라우팅 (`/api/orders/` 등 prefix) |
| `destinationrule` | Istio 서킷브레이커 (connectionPool + outlierDetection) |
| `servicemonitor` | Prometheus가 `/metrics` 스크랩하도록 등록 |

### 환경별 values 예시

```yaml
# envs/dev/shoong-order.yaml
image:
  repository: <account>.dkr.ecr.us-east-1.amazonaws.com/shoong-order
  tag: "dev-<commit-sha>"      # ← 앱 레포 CI가 자동 갱신
autoscaling: { enabled: true, minReplicas: 2, maxReplicas: 5 }
service: { port: 3001 }
virtualService: { enabled: true, prefix: /api/orders/ }
```

batch는 `service.enabled: false` 에 `cronjobs:` 목록으로 3개 잡(`cleanup`, `auto-complete-cooking`, `auto-complete-delivery`)을 정의합니다.

## 인프라 스택 (infra/)

ArgoCD가 서드파티 Helm 차트도 함께 관리합니다. `sync-wave` 로 설치 순서를 제어합니다.

- **서비스 메시** — Istio (base / istiod / gateway), Gateway·VirtualService·DestinationRule, Kiali
- **트래픽 진입** — AWS Load Balancer Controller, TargetGroupBinding(ALB ↔ Istio Ingress 연결)
- **메트릭** — kube-prometheus-stack (Prometheus / Grafana / Alertmanager), metrics-server, ServiceMonitor
- **로그** — Loki + Promtail
- **트레이스** — Tempo + OpenTelemetry Collector (앱이 OTLP로 전송)
- **대시보드·알림** — Grafana 대시보드, PrometheusRule, ArgoCD Notifications(Slack)

## 시크릿 관리 (eso/)

[External Secrets Operator](https://external-secrets.io/) 로 AWS의 시크릿을 K8s Secret으로 동기화합니다.
- `secret-store.yaml` — SSM Parameter Store / Secrets Manager를 가리키는 `ClusterSecretStore`
- `external-secret-*.yaml` — DB 자격증명, 앱 공통 설정, Grafana·Alertmanager·ArgoCD 알림 토큰 등

시크릿 **값**은 레포에 없고, AWS에 저장된 값을 ESO가 런타임에 가져옵니다.

## 부하 테스트 (loadtest/)

k6 시나리오를 CronJob으로 실행합니다([loadtest/dev/](loadtest/dev/)).
- `cronjob-load.yaml` — 정상 부하
- `cronjob-spike.yaml` — 스파이크 부하
- `scenarios-configmap.yaml` — k6 시나리오 스크립트

## 부트스트랩

클러스터 최초 구성은 [shoong-terraform](https://github.com/shoong-delivery/shoong-terraform) 의 `scripts/init.sh` 가 수행합니다.
ArgoCD 설치 → 이 레포 자격증명 등록 → 루트 Application 두 개 apply까지가 init.sh의 역할이고,
그 이후의 모든 배포는 이 레포에 대한 Git push로 이루어집니다.

> ArgoCD UI는 `*.internal.dev.shoong.cloud` 로 노출됩니다 (Istio Gateway + VirtualService).
