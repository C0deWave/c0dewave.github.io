---
title: "해커톤 1위 후기 — KEDA HTTP Add-on으로 잠자는 서버 깨우기"
date: 2026-04-22T00:00:00+09:00
description: "사내 AI 해커톤에서 KEDA HTTP Add-on 기반의 zero-scale 개발 환경과 PR별 임시 환경 PoC로 1위를 했다. 문제 정의부터 구현, 회고까지 정리한다."
categories: ["devops"]
tags: ["KEDA", "Kubernetes", "EKS", "cost-optimization", "hackathon", "zero-scale", "ephemeral-environment", "ExternalDNS", "ArgoCD", "ApplicationSet"]
---

## 팀 소개

- **팀명:** 잠자는 서버들
- **인원:** 2명
- **해커톤:** 사내 AI 해커톤

팀 이름이 곧 문제 정의였다. 아무도 안 쓰는데 켜져 있는 서버들.

---

## 문제 인식 — 24시간 켜둘 이유가 있는가

우리 조직의 개발 환경은 EKS 위에서 돌아간다. dev1, dev2 같은 고정 환경이 24시간 상시 가동된다. 퇴근 후에도, 주말에도, 연휴에도.

나름의 이유는 있다.

- 출근해서 환경 뜰 때까지 기다리기 싫다
- QA가 아무 때나 접속할 수 있어야 한다
- "혹시 모르니까" 켜두자는 관성

하지만 실제 트래픽을 보면 업무 시간(9~19시)에 집중되고, 나머지는 0에 가깝다. 24시간 중 절반 이상이 유휴 상태다.

더 근본적인 문제도 있다. 고정 환경 구조 자체의 한계다.

A가 dev1에서 피쳐 브랜치를 테스트하면 B는 기다려야 한다. 부족하면 dev3, dev4를 만든다. 환경은 늘어나고 정리는 안 된다. "이 환경 누가 쓰고 있어요?"가 슬랙에 올라오기 시작하면 이미 늦은 거다.

---

## 접근 — 두 문제를 하나로

두 가지를 동시에 풀기로 했다.

1. **안 쓰면 내린다** — 트래픽이 없으면 Pod를 0으로, 요청이 오면 콜드스타트
2. **PR별 임시 환경** — 고정 환경 대신 PR이 올라오면 전용 환경이 뜨고, 머지되면 사라진다

핵심은 **KEDA HTTP Add-on**이다.

---

## KEDA HTTP Add-on

[KEDA(Kubernetes Event Driven Autoscaling)](https://keda.sh/)는 이벤트 기반 오토스케일러다. 큐 길이, 크론, 외부 메트릭 등을 기반으로 Pod 수를 조절한다. HPA와 다른 점은 **0까지 스케일 다운**이 가능하다는 것이다.

[KEDA HTTP Add-on](https://github.com/kedacore/http-add-on)은 HTTP 트래픽 기반 스케일링을 추가한다.

```
[클라이언트] → [Interceptor Proxy] → [워크로드 Pod]
                    ↑
              요청 수 메트릭 수집
                    ↓
              [KEDA Scaler] → Pod 0 ↔ N 조절
```

1. HTTP 요청이 Interceptor Proxy를 거친다
2. Interceptor가 요청 수를 KEDA Scaler에 전달한다
3. Pod가 0인 상태에서 요청이 오면, Interceptor가 요청을 잡아두고 Pod가 뜰 때까지 기다린다
4. Pod가 Ready 되면 요청을 포워딩한다
5. 일정 시간 요청이 없으면 다시 0으로 내린다

사용자 입장에서는 첫 요청에 약간의 대기가 있을 뿐, 이후는 일반 서비스와 동일하다.

---

## 구현 — Zero-Scale 개발 환경

### 설치

```bash
# KEDA
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda -n keda --create-namespace

# HTTP Add-on
helm install keda-http-add-on kedacore/keda-add-ons-http -n keda
```

### HTTPScaledObject

```yaml
apiVersion: http.keda.sh/v1alpha1
kind: HTTPScaledObject
metadata:
  name: my-app
  namespace: dev
spec:
  hosts:
    - "my-app.dev.example.com"
  scaleTargetRef:
    name: my-app
    kind: Deployment
    apiVersion: apps/v1
  replicas:
    min: 0
    max: 3
  scalingMetric:
    requestRate:
      targetValue: 10
  scaledownPeriod: 300  # 5분간 요청 없으면 0으로
```

매니페스트 하나로 끝난다.

- 트래픽이 없으면 Pod 0
- 요청이 들어오면 자동 기동
- RPS 10 기준 오토스케일링
- 5분간 조용하면 다시 0

24시간 떠 있던 dev1에 적용하면, 업무 시간에만 Pod가 뜨고 나머지는 리소스를 반환한다.

---

## 구현 — PR별 임시 환경

고정 환경을 없애고, PR마다 전용 환경을 만든다.

### 전체 흐름

```
[PR 생성] → [Argo ApplicationSet 감지]
              ├─ PR generator가 열린 PR 감지
              ├─ Namespace 자동 생성 (pr-<number>)
              ├─ 앱 + 의존성(DB, Redis 등) 배포
              ├─ ExternalDNS가 DNS 레코드 자동 등록
              └─ HTTPScaledObject 적용 (min: 0)
                      ↓
[PR에 접속 URL 코멘트] → 개발자/QA 접속
                      ↓
[PR 머지/닫힘] → Application 삭제
              → Namespace 정리 → DNS 레코드 자동 제거
```

### ExternalDNS — 도메인 자동화

PR이 뜰 때마다 도메인을 수동 등록하는 건 불가능하다. [ExternalDNS](https://github.com/kubernetes-sigs/external-dns)로 자동화한다.

ExternalDNS는 클러스터의 Ingress/Service를 감시하다가, 호스트 정보가 변경되면 DNS 프로바이더(Route53, CloudFlare 등)에 레코드를 자동 생성·삭제한다.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: pr-123
  annotations:
    external-dns.alpha.kubernetes.io/hostname: pr-123.dev.example.com
spec:
  rules:
    - host: pr-123.dev.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

Ingress가 생기면 DNS 레코드가 만들어지고, 삭제되면 레코드도 사라진다. PR 환경의 라이프사이클과 DNS가 완전히 연동된다.

### Argo ApplicationSet — 의존성까지 한 번에

[Argo ApplicationSet](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/)의 Pull Request Generator를 쓰면 PR이 올라올 때 ArgoCD가 전체 환경을 프로비저닝한다.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: pr-environments
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - pullRequest:
        github:
          owner: my-org
          repo: my-app
          tokenRef:
            secretName: github-token
            key: token
        requeueAfterSeconds: 30
  template:
    metadata:
      name: 'pr-{{.number}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/my-org/my-app.git
        targetRevision: '{{.head_sha}}'
        path: deploy/pr-environment
        helm:
          valuesObject:
            pr:
              number: '{{.number}}'
              branch: '{{.branch}}'
            ingress:
              host: 'pr-{{.number}}.dev.example.com'
            dependencies:
              postgres:
                enabled: true
                image: postgres:15
              redis:
                enabled: true
                image: redis:7-alpine
            keda:
              enabled: true
              minReplicas: 0
              scaledownPeriod: 300
      destination:
        server: https://kubernetes.default.svc
        namespace: 'pr-{{.number}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

ApplicationSet 하나로 다음이 동작한다.

- PR 열림 → `pr-<number>` namespace에 앱 + PostgreSQL + Redis 배포
- Helm values로 의존성 on/off 제어
- PR 닫힘 → Application 삭제, `prune: true`로 리소스 전체 정리
- ExternalDNS가 DNS 등록·해제까지 처리

CI에서 kubectl이나 helm을 직접 호출할 필요가 없다. 선언만 하면 ArgoCD가 수렴시킨다.

### PR 코멘트

환경이 뜨면 접속 URL을 알려줘야 한다.

```yaml
- name: Comment PR URL
  uses: actions/github-script@v7
  with:
    script: |
      github.rest.issues.createComment({
        owner: context.repo.owner,
        repo: context.repo.repo,
        issue_number: context.issue.number,
        body: `🚀 임시 환경이 준비됐습니다!\n\n` +
              `🔗 https://pr-${context.issue.number}.dev.example.com\n\n` +
              `> 첫 접속 시 콜드스타트로 수 초 걸릴 수 있습니다.`
      })
```

PR이 열리면 ArgoCD가 환경을 띄우고, ExternalDNS가 도메인을 잡고, KEDA가 트래픽에 따라 스케일링한다. 닫히면 전부 역순으로 정리된다. 수동 개입은 없다.

### 스코프 — PoC는 Stateless, 실제 도입은 의존성까지

해커톤 PoC에서는 **stateless 서비스만** 대상으로 했다. API 서버, BFF 같은 워크로드만 PR별로 띄웠다. DB, Redis 등 stateful 의존성은 공용 dev를 바라보게 했다. 48시간에 전부 다룰 순 없었다.

다만 위에서 본 것처럼, ApplicationSet 구조에서는 의존성도 함께 올리는 게 이미 가능하다. `dependencies.postgres.enabled: true`만 켜면 PR namespace에 DB가 같이 뜬다.

실제 도입 시 서비스 특성에 따른 전략:

- **컨테이너 DB** — PR namespace에 경량 DB를 띄우고 시드 데이터 주입. 대부분의 경우 이걸로 충분하다.
- **DB 브랜치** — PlanetScale, Neon 같은 브랜칭 지원 서비스로 프로덕션에 가까운 데이터 테스트
- **서비스 메시 라우팅** — 변경 없는 의존성은 공용 환경으로 라우팅, 변경 있는 것만 PR 환경에 포함 (Istio VirtualService 활용)
- **Mock 서비스** — 외부 의존성이 많으면 핵심만 실제로 띄우고 나머지는 mock 처리

---

## 결과

### 비용

- 기존: dev1, dev2가 24/7 상시 가동
- 변경: 트래픽이 있을 때만 Pod 기동, 없으면 0
- 업무 외 시간(약 60%)의 리소스가 회수된다
- PR 환경도 접속 중일 때만 Pod가 뜨므로, 환경이 늘어도 비용이 비례하지 않는다

### 개발 경험

| 기존 | 변경 후 |
|------|---------|
| dev1 점유 충돌 | PR마다 전용 환경 |
| 환경 충돌로 작업 깨짐 | 완전 격리 |
| "이 환경 누가 쓰나요?" | PR 닫으면 자동 정리 |
| 환경 부족 → dev3, dev4 증식 | 필요한 만큼 자동 생성·삭제 |

### 콜드스타트

Pod가 0에서 올라오려면 이미지 풀 + 컨테이너 기동 + readiness probe 통과까지 시간이 걸린다.

PoC 기준:

- 이미지 캐시 있을 때: **3~8초**
- 이미지 캐시 없을 때: **15~30초**

개발 환경에서 첫 접속에 몇 초 기다리는 건 수용 가능한 수준이다.

최적화 방향:

- 이미지 경량화 (distroless, multi-stage 빌드)
- 노드 레벨 이미지 프리 캐시
- readiness probe 초기 지연 조정

---

## 회고

기술적으로 어려운 건 아니었다. KEDA HTTP Add-on은 설치하고 HTTPScaledObject 하나 정의하면 동작한다.

잘한 건 **문제 선택**이다.

- 모든 팀이 겪지만 아무도 손 안 대던 문제를 골랐다
- "dev 환경이 24시간 켜져 있어야 하나?"에 대한 기술적 대안을 실제 동작하는 PoC로 보여줬다
- 비용 절감과 개발 경험 개선을 동시에 잡았다

2인 팀이라 스코프가 중요했다. 프로덕션 카나리까지 욕심냈다가 빠르게 접었다. "개발 환경 zero-scale + PR 환경"으로 범위를 좁히고, 실제 동작하는 데모를 보여준 게 1위의 핵심이었다.

---

## 다음 단계

해커톤은 끝났지만 PoC는 시작이다.

- **Stateful 의존성 고도화** — ApplicationSet으로 구조는 잡았지만 마이그레이션 자동화, 시드 데이터 관리, 스토리지 정리 정책이 남아 있다
- **모니터링** — zero-scale 상태의 메트릭 수집, 콜드스타트 시간 추적
- **개발자 온보딩** — "첫 접속이 느린 이유" 가이드
- **스케일다운 정책** — 5분이 적절한지, 서비스마다 다르게 가야 하는지

잠자는 서버들은 이제 진짜 잠들 수 있다. 필요할 때 깨우면 된다.
