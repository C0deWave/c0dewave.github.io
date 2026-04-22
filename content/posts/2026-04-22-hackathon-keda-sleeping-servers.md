---
title: "해커톤 1위 후기 — KEDA HTTP Add-on으로 잠자는 서버 깨우기"
date: 2026-04-22T00:00:00+09:00
description: "사내 AI 해커톤에서 KEDA HTTP Add-on을 활용한 서버 비용 절감 + PR별 임시 환경 PoC로 1위를 했다. 어떤 문제를 풀었고, 어떻게 접근했는지 정리한다."
categories: ["devops"]
tags: ["KEDA", "Kubernetes", "EKS", "cost-optimization", "hackathon", "zero-scale", "ephemeral-environment"]
---

## 팀 소개

- **팀명:** 잠자는 서버들
- **인원:** 2명
- **해커톤:** 사내 AI 해커톤

팀 이름부터가 우리가 풀고 싶었던 문제의 정확한 묘사였다. 아무도 안 쓰는데 켜져 있는 서버들.

---

## 문제 인식 — 24시간 돌아가는 개발 환경, 정말 필요한가?

우리 조직의 개발 환경은 EKS 위에 올라가 있다. dev1, dev2처럼 고정된 환경이 24시간 돌아간다. 개발자가 퇴근하고, 주말이 되고, 심지어 연휴에도.

이게 왜 이렇게 됐냐면, 사실 다 이유가 있다.

- 개발자가 아침에 출근해서 환경 뜰 때까지 기다리기 싫다
- QA가 아무 때나 접속해서 테스트할 수 있어야 한다
- "혹시 모르니까" 켜놓자는 관성

합리적인 이유들이다. 하지만 숫자를 보면 이야기가 달라진다. 실제 트래픽을 찍어보면 업무 시간(9시~19시)에 집중되고, 새벽이나 주말엔 0에 가깝다. 24시간 중 실제로 쓰이는 건 절반도 안 된다.

그리고 더 근본적인 질문이 있었다. dev1, dev2라는 고정 환경 자체가 맞는 구조인가?

A 개발자가 dev1에서 피쳐 브랜치를 테스트하고 있으면, B 개발자는 기다려야 한다. 환경이 부족하면 dev3을 만들고, 그게 모자라면 dev4를 만들고. 환경은 늘어나는데 정리는 안 된다. 어느 순간 "이 환경 누가 쓰고 있어요?"라는 질문이 슬랙에 올라오기 시작한다.

---

## 접근 — 두 가지를 동시에 풀자

우리는 두 문제를 하나의 아키텍처로 풀기로 했다.

1. **안 쓰면 꺼라** — 트래픽이 없으면 Pod를 0으로 내리고, 요청이 오면 콜드스타트
2. **PR별 임시 환경** — dev1, dev2 같은 고정 환경 대신, PR이 올라오면 그 PR 전용 환경이 뜨고 머지되면 사라지는 구조

핵심 도구는 **KEDA HTTP Add-on**이다.

---

## KEDA HTTP Add-on이 뭔가

[KEDA(Kubernetes Event Driven Autoscaling)](https://keda.sh/)는 이벤트 기반 오토스케일러다. 큐 길이, 크론 스케줄, 외부 메트릭 등 다양한 이벤트 소스를 기반으로 Pod 수를 조절한다. 중요한 건 **0까지 스케일 다운**이 가능하다는 점이다. HPA는 최소 1개를 유지해야 하지만, KEDA는 진짜 0으로 내린다.

[KEDA HTTP Add-on](https://github.com/kedacore/http-add-on)은 여기에 HTTP 트래픽 기반 스케일링을 추가한다. 구조는 이렇다:

```
[클라이언트] → [Interceptor Proxy] → [워크로드 Pod]
                    ↑
              요청 수 메트릭 수집
                    ↓
              [KEDA Scaler] → Pod 0 ↔ N 조절
```

1. 클라이언트의 HTTP 요청이 Interceptor Proxy를 먼저 거친다
2. Interceptor가 요청 수를 세고, KEDA Scaler에게 메트릭을 전달한다
3. Pod가 0일 때 요청이 오면, KEDA가 Pod를 띄울 때까지 Interceptor가 요청을 잡아두고(hold) 기다린다
4. Pod가 Ready 되면 요청을 포워딩한다
5. 일정 시간 요청이 없으면 다시 0으로 내린다

사용자 입장에서는 첫 요청에 약간의 지연(콜드스타트)이 있을 뿐, 그 뒤로는 일반적인 서비스와 다르지 않다.

---

## 구현 — Zero-Scale 개발 환경

### 설치

```bash
# KEDA 설치
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda -n keda --create-namespace

# HTTP Add-on 설치
helm install keda-http-add-on kedacore/keda-add-ons-http \
  -n keda
```

### HTTPScaledObject 정의

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

이게 전부다. 이 한 장의 매니페스트로:

- 트래픽이 없으면 Pod 0
- 요청이 오면 자동으로 1개 이상 기동
- RPS 10 기준으로 오토스케일링
- 5분간 조용하면 다시 0으로

기존에 24시간 떠 있던 dev1 환경에 이걸 적용하면, 업무 시간에만 Pod가 뜨고 나머지 시간엔 리소스를 반환한다.

---

## 구현 — PR별 임시 환경

여기가 진짜 재밌었던 부분이다. 고정 환경을 없애고, PR이 올라올 때마다 전용 환경을 만든다.

### 흐름

```
[PR 생성] → [CI 파이프라인]
              ├─ 이미지 빌드 & 푸시
              ├─ Namespace 생성 (pr-<number>)
              ├─ Helm 배포 (host: pr-<number>.dev.example.com)
              └─ HTTPScaledObject 생성 (min: 0)
                      ↓
[PR에 접속 URL 코멘트] → 개발자/QA 접속
                      ↓
[PR 머지/닫힘] → Namespace 삭제 → 리소스 완전 회수
```

### CI에서 임시 환경 생성 (GitHub Actions 예시)

```yaml
- name: Deploy PR Environment
  run: |
    PR_NUM=${{ github.event.pull_request.number }}
    NAMESPACE="pr-${PR_NUM}"

    kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

    helm upgrade --install my-app ./chart \
      --namespace $NAMESPACE \
      --set image.tag=pr-${PR_NUM} \
      --set ingress.host=pr-${PR_NUM}.dev.example.com \
      --set keda.enabled=true \
      --set keda.minReplicas=0 \
      --set keda.scaledownPeriod=300

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

### PR 닫힐 때 정리

```yaml
on:
  pull_request:
    types: [closed]

jobs:
  cleanup:
    runs-on: ubuntu-latest
    steps:
      - name: Delete PR Environment
        run: |
          kubectl delete namespace pr-${{ github.event.pull_request.number }} --ignore-not-found
```

PR이 열리면 환경이 뜨고, 닫히면 사라진다. 그 사이에도 KEDA가 트래픽을 보고 있으니, QA가 테스트 안 하는 시간엔 Pod가 0이다.

### 스코프 — Stateless 서비스만 대상

이번 PoC에서 임시 환경의 대상은 **stateless 서비스에 한정**했다. API 서버, BFF 같은 요청-응답 구조의 워크로드만 PR별로 띄운 것이다.

DB, Redis, 메시지 큐 같은 stateful 의존성은 공용 dev 인스턴스를 바라보게 했다. 이유는 간단하다:

- DB를 PR마다 띄우면 스키마 마이그레이션, 시드 데이터, 스토리지 비용이 따라붙는다
- Redis나 Kafka를 격리하려면 커넥션 설정, 토픽 관리까지 자동화해야 한다
- 해커톤 48시간 안에 여기까지 욕심내면 아무것도 완성 못 한다

하지만 실제 도입 단계에서는 이 부분을 반드시 풀어야 한다. PR 환경에서 공용 DB를 바라보면 테스트 데이터가 꼬일 수 있고, 마이그레이션이 충돌할 수도 있다.

가능한 접근들:

- **DB 브랜치:** PlanetScale이나 Neon처럼 DB 브랜칭을 지원하는 서비스 활용, 또는 PR마다 스키마만 분리된 논리 DB 생성
- **컨테이너 DB:** 테스트 목적이라면 PR namespace에 경량 DB 컨테이너(PostgreSQL, MySQL)를 함께 띄우고 시드 데이터 자동 주입
- **서비스 메시 라우팅:** 의존 서비스 중 변경이 없는 건 공용 환경으로 라우팅하고, 변경이 있는 서비스만 PR 환경에 포함 (Istio VirtualService 등 활용)
- **목(mock) 서비스:** 외부 의존성이 많은 경우, 핵심 의존만 실제로 띄우고 나머지는 mock으로 대체

stateless만으로도 비용 절감 효과는 충분히 보여줄 수 있었지만, 완전한 PR 환경을 위해서는 이 의존성 문제가 다음 단계의 핵심 과제다.

---

## 결과 — 뭐가 좋아졌나

### 비용

- 기존: dev1, dev2가 24시간 × 7일 상시 가동
- 변경 후: 트래픽이 있을 때만 Pod 기동, 없으면 0
- 업무 외 시간(전체의 약 60%)에 해당하는 리소스가 회수된다
- PR 환경도 사용 중일 때만 Pod가 뜨니, 환경 수가 늘어도 비용이 비례하지 않는다

### 개발 경험

| 기존 | 변경 후 |
|------|---------|
| dev1 쓰고 싶은데 누가 점유 중 | PR 올리면 내 전용 환경 |
| 환경 충돌로 다른 사람 작업 깨짐 | 완전 격리, 간섭 없음 |
| "이 환경 누가 쓰나요?" 슬랙 질문 | PR 닫으면 자동 정리 |
| 환경 부족 → dev3, dev4 증식 | 필요한 만큼 자동 생성/삭제 |

### 콜드스타트 — 유일한 트레이드오프

솔직히 말하면 콜드스타트는 있다. Pod가 0에서 올라오려면 이미지 풀 + 컨테이너 기동 + readiness probe 통과까지 시간이 걸린다.

우리 PoC 기준:

- 이미지 캐시 있을 때: **3~8초**
- 이미지 캐시 없을 때: **15~30초** (이미지 크기에 따라)

개발/QA 환경에서 첫 접속에 몇 초 기다리는 건 충분히 수용 가능한 수준이었다. 프로덕션이 아니니까.

최적화 포인트:

- 이미지 크기를 줄이면 콜드스타트가 짧아진다 (distroless, multi-stage 빌드)
- Kubernetes node에 이미지 프리 캐시를 걸어두면 풀 시간을 없앨 수 있다
- readiness probe의 초기 지연을 적절히 설정하면 불필요한 대기를 줄인다

---

## 해커톤 회고

사실 기술적으로 엄청 어려운 건 아니었다. KEDA HTTP Add-on 자체가 잘 만들어져 있어서, 설치하고 HTTPScaledObject 하나 정의하면 zero-scale이 동작한다.

우리가 잘했다고 생각하는 건 **문제 선택**이다.

- 모든 팀이 겪고 있지만, 아무도 손 안 대고 있던 문제를 골랐다
- "dev 환경이 24시간 켜져 있어야 하나?"라는 질문에 대해 기술적 대안을 PoC로 보여줬다
- 비용 절감과 개발 경험 개선을 동시에 잡았다

2인 팀이라 스코프 관리가 중요했다. 처음에 프로덕션 카나리까지 욕심을 냈다가 빠르게 접었다. "개발 환경 zero-scale + PR 환경"이라는 명확한 범위로 좁히고, PoC가 실제로 동작하는 걸 데모할 수 있었던 게 1위의 핵심이었다고 본다.

---

## 다음 단계

해커톤은 끝났지만 PoC는 시작이다. 실제 도입을 위해 남은 과제:

- **Stateful 의존성 격리** — 위에서 언급한 DB/Redis/큐의 PR별 격리 전략 구체화 및 구현
- **모니터링** — zero-scale 상태에서의 메트릭 수집, 콜드스타트 시간 추적
- **개발자 온보딩** — "왜 첫 접속이 느려요?"에 대한 가이드
- **스케일다운 정책 튜닝** — 5분이 적절한지, 서비스마다 다르게 가야 하는지

잠자는 서버는 이제 진짜 잠들 수 있게 됐다. 필요할 때 깨우면 되니까.
