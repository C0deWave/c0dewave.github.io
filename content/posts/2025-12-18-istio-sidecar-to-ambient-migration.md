---
title: "Istio Sidecar에서 Ambient 모드로 전환하기 - Locality 라우팅까지"
date: 2025-12-18T00:00:00+09:00
categories: ["istio"]
tags: ["istio", "ambient", "sidecar", "ztunnel", "locality", "kubernetes", "minikube"]
---

## 개요

Istio 1.23에서 Ambient 모드가 GA(Generally Available)로 승격되면서, 사이드카 없이도 서비스 메시의 이점을 누릴 수 있게 되었습니다. 이 글에서는 Minikube 멀티 노드 환경에서 Istio 사이드카 모드로 시작하여 Ambient 모드로 전환하고, Locality 기반 라우팅까지 적용하는 전체 과정을 다룹니다.

**실습 목표:**
1. Minikube 멀티 노드 클러스터 구성
2. Istio 사이드카 모드 설치 및 Bookinfo 앱 배포
3. Locality 기반 라우팅 설정 및 테스트
4. Ambient 모드로 무중단 전환
5. Ambient 모드에서 Locality 라우팅 적용

**실습 환경:**
- Minikube v1.35.0
- Kubernetes v1.32.0
- Istio v1.26.6
- 3개 노드 (각 2 CPU, 4GB 메모리)

---

## Ambient 모드란?

### 기존 사이드카 모드의 문제점

Istio의 기존 사이드카 모드는 각 Pod에 Envoy 프록시를 주입하는 방식입니다. 이 방식은 강력하지만 몇 가지 문제가 있습니다:

**1. 리소스 오버헤드**
- 각 Pod마다 Envoy 프록시가 실행되어 CPU/메모리 소비 증가
- 수천 개의 Pod가 있는 클러스터에서는 상당한 리소스 낭비
- 일반적으로 Pod당 100-200MB 메모리, 0.1-0.5 CPU 추가 소비

**2. 운영 복잡성**
- 사이드카 주입을 위해 Pod 재시작 필요
- 사이드카 버전 업그레이드 시 모든 Pod 롤링 업데이트 필요
- 애플리케이션과 프록시의 생명주기가 결합됨

**3. 레이턴시 증가**
- 모든 트래픽이 사이드카를 거쳐야 함
- L4 수준의 단순 통신에도 L7 프록시 오버헤드 발생

### Ambient 모드의 해결책

Ambient 모드는 2022년 Istio 커뮤니티에서 제안되어 2024년 Istio 1.23에서 GA(Generally Available)가 되었습니다.

**핵심 아이디어: 프록시를 Pod에서 분리**

```
┌─────────────────────────────────────────────────────────────┐
│                        Node                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │   Pod A     │  │   Pod B     │  │   Pod C     │         │
│  │  (앱만)     │  │  (앱만)     │  │  (앱만)     │         │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘         │
│         │                │                │                 │
│         └────────────────┼────────────────┘                 │
│                          │                                  │
│                   ┌──────▼──────┐                          │
│                   │   Ztunnel   │  ← 노드당 1개 (L4 프록시) │
│                   │  (DaemonSet)│                          │
│                   └─────────────┘                          │
│                                                             │
│   ┌─────────────────────────────────────────────┐          │
│   │            Waypoint Proxy (선택적)          │          │
│   │          L7 기능 필요 시에만 배포           │          │
│   └─────────────────────────────────────────────┘          │
└─────────────────────────────────────────────────────────────┘
```

**Ambient 모드의 장점:**
- **리소스 절약**: Pod당 프록시 대신 노드당 ztunnel만 실행
- **간편한 운영**: Pod 재시작 없이 레이블만 변경하여 메시 참여/탈퇴
- **점진적 L7 도입**: 필요한 서비스에만 Waypoint Proxy 배포
- **빠른 업그레이드**: 프록시 업그레이드가 애플리케이션 Pod에 영향 없음

**주요 컴포넌트:**
- **ztunnel**: 노드 레벨 L4 프록시, mTLS 및 텔레메트리 처리
- **waypoint proxy**: 서비스 레벨 L7 프록시, VirtualService/DestinationRule 처리
- **istio-cni**: 트래픽 리다이렉션을 위한 iptables 규칙 설정

### Waypoint Proxy: L7 세밀한 제어

Ambient 모드에서도 **Waypoint Proxy**를 배포하면 사이드카 모드와 동일한 L7 기능을 사용할 수 있습니다:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Ambient 모드 + Waypoint                      │
│                                                                 │
│  ┌─────────┐      ┌─────────┐      ┌─────────────┐             │
│  │ Client  │      │ztunnel  │      │  Waypoint   │             │
│  │   Pod   │─────▶│  (L4)   │─────▶│   Proxy     │             │
│  └─────────┘      └─────────┘      │   (L7)      │             │
│                                    └──────┬──────┘             │
│                                           │                     │
│                    ┌──────────────────────┼──────────────────┐ │
│                    │  L7 기능 처리        │                  │ │
│                    │  • VirtualService    │                  │ │
│                    │  • DestinationRule   │                  │ │
│                    │  • 헤더 기반 라우팅  │                  │ │
│                    │  • 재시도/타임아웃   │                  │ │
│                    │  • 트래픽 미러링     │                  │ │
│                    └──────────────────────┼──────────────────┘ │
│                                           ▼                     │
│                                    ┌─────────────┐             │
│                                    │   Server    │             │
│                                    │    Pod      │             │
│                                    └─────────────┘             │
└─────────────────────────────────────────────────────────────────┘
```

**Waypoint Proxy 배포 방법:**
```bash
# 네임스페이스에 Waypoint 배포
istioctl waypoint apply -n bookinfo --name reviews-waypoint

# 서비스에 Waypoint 연결
kubectl label service reviews -n bookinfo \
  istio.io/use-waypoint=reviews-waypoint
```

**Waypoint Proxy로 사용 가능한 L7 기능:**

| 기능 | 설명 | 예시 |
|------|------|------|
| **헤더 기반 라우팅** | HTTP 헤더 값에 따라 라우팅 | `end-user: jason` → v2로 라우팅 |
| **트래픽 분할** | 버전별 트래픽 비율 조정 | v1: 90%, v2: 10% |
| **재시도 정책** | 실패 시 자동 재시도 | 3회 재시도, 2초 타임아웃 |
| **서킷 브레이커** | 연속 에러 시 트래픽 차단 | 5xx 5회 연속 시 30초 차단 |
| **Fault Injection** | 의도적 지연/에러 주입 | 10% 요청에 5초 지연 |
| **요청 미러링** | 프로덕션 트래픽 복제 | 테스트 환경으로 미러링 |

**Waypoint vs Sidecar 선택 기준:**

```
┌─────────────────────────────────────────────────────────────┐
│                      L7 기능이 필요한가?                     │
│                             │                               │
│              ┌──────────────┼──────────────┐                │
│              ▼                             ▼                │
│           아니오                          예                │
│              │                             │                │
│              ▼                             ▼                │
│     ┌────────────────┐          ┌──────────────────┐       │
│     │ ztunnel만 사용 │          │ Waypoint 배포    │       │
│     │ (L4 mTLS만)    │          │ (L7 기능 활성화) │       │
│     └────────────────┘          └──────────────────┘       │
│                                                             │
│  ✅ 대부분의 서비스는 L4만으로 충분                         │
│  ✅ L7 필요한 서비스에만 선택적으로 Waypoint 배포           │
│  ✅ 사이드카 대비 리소스 효율적 (서비스당 1개 vs Pod당 1개) │
└─────────────────────────────────────────────────────────────┘
```

**핵심 포인트:**
- Ambient 모드는 L4만 지원하는 것이 아님
- Waypoint Proxy를 통해 사이드카와 동일한 L7 기능 제공
- **차이점**: 사이드카는 모든 Pod에 프록시, Waypoint는 필요한 서비스에만 프록시
- **장점**: L7 기능이 필요 없는 서비스는 ztunnel만으로 가볍게 운영

---

## Locality 라우팅이란?

### 배경: 멀티 AZ 환경의 비용 문제

클라우드 환경에서 고가용성을 위해 여러 가용영역(Availability Zone, AZ)에 워크로드를 분산 배포합니다:

```
┌─────────────────────────────────────────────────────────────────┐
│                        AWS ap-northeast-2                       │
│                                                                 │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │  ap-northeast-2a│  │  ap-northeast-2b│  │  ap-northeast-2c│ │
│  │                 │  │                 │  │                 │ │
│  │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │ │
│  │  │ Service A │  │  │  │ Service A │  │  │  │ Service A │  │ │
│  │  │  (Pod 1)  │  │  │  │  (Pod 2)  │  │  │  │  (Pod 3)  │  │ │
│  │  └─────┬─────┘  │  │  └───────────┘  │  │  └───────────┘  │ │
│  │        │        │  │                 │  │                 │ │
│  │        │ 호출   │  │                 │  │                 │ │
│  │        ▼        │  │                 │  │                 │ │
│  │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │ │
│  │  │ Service B │◄─┼──┼──│ Service B │◄─┼──┼──│ Service B │  │ │
│  │  │  (Pod 1)  │  │  │  │  (Pod 2)  │  │  │  │  (Pod 3)  │  │ │
│  │  └───────────┘  │  │  └───────────┘  │  │  └───────────┘  │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

**문제점: Cross-AZ 트래픽 비용**

기본적으로 Kubernetes Service는 라운드로빈으로 모든 엔드포인트에 트래픽을 분산합니다. 이로 인해:

- **AZ 간 데이터 전송 비용 발생**: AWS 기준 $0.01/GB (같은 리전 내 AZ 간)
- **레이턴시 증가**: 같은 AZ 내 통신보다 1-2ms 추가
- **대규모 트래픽에서 비용 폭증**: 하루 1TB 트래픽 시 월 $300 추가 비용

**실제 사례:**
> "마이크로서비스 100개, 일일 트래픽 10TB인 환경에서 Cross-AZ 비용만 월 $3,000 이상 발생"

### Locality 라우팅의 해결책

Locality 라우팅은 **같은 지역(Region)/가용영역(Zone)의 엔드포인트를 우선 선택**하는 기능입니다:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Locality 라우팅 적용 후                  │
│                                                                 │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │  ap-northeast-2a│  │  ap-northeast-2b│  │  ap-northeast-2c│ │
│  │                 │  │                 │  │                 │ │
│  │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │ │
│  │  │ Service A │  │  │  │ Service A │  │  │  │ Service A │  │ │
│  │  │  (Pod 1)  │  │  │  │  (Pod 2)  │  │  │  │  (Pod 3)  │  │ │
│  │  └─────┬─────┘  │  │  └─────┬─────┘  │  │  └─────┬─────┘  │ │
│  │        │        │  │        │        │  │        │        │ │
│  │        │ 100%   │  │        │ 100%   │  │        │ 100%   │ │
│  │        ▼        │  │        ▼        │  │        ▼        │ │
│  │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │ │
│  │  │ Service B │  │  │  │ Service B │  │  │  │ Service B │  │ │
│  │  │  (Pod 1)  │  │  │  │  (Pod 2)  │  │  │  │  (Pod 3)  │  │ │
│  │  └───────────┘  │  │  └───────────┘  │  │  └───────────┘  │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘ │
│                                                                 │
│  ✅ Cross-AZ 트래픽 최소화 → 비용 절감 + 레이턴시 감소          │
└─────────────────────────────────────────────────────────────────┘
```

**Locality의 계층 구조:**
```
Region (ap-northeast-2)
  └── Zone (ap-northeast-2a)
       └── Sub-zone (선택적)
```

**Locality 라우팅의 장점:**
- **비용 절감**: Cross-AZ 트래픽 최소화로 데이터 전송 비용 절감
- **레이턴시 감소**: 같은 AZ 내 통신으로 네트워크 홉 최소화
- **장애 격리**: Zone 장애 시 해당 Zone 엔드포인트만 제외
- **자동 Failover**: 같은 Zone에 엔드포인트가 없으면 다른 Zone으로 자동 라우팅

---

## Phase 1: 환경 준비

### 1-1. Minikube 멀티 노드 클러스터 생성

로컬리티 테스트를 위해 3개 노드로 구성된 클러스터를 생성합니다.

```bash
# 기존 클러스터 삭제
minikube delete

# 3개 노드로 클러스터 생성
minikube start --nodes=3 --cpus=2 --memory=4096 --driver=podman
```

**노드 확인:**
```bash
kubectl --context minikube get nodes
```

```
NAME           STATUS   ROLES           AGE   VERSION
minikube       Ready    control-plane   41s   v1.32.0
minikube-m02   Ready    <none>          27s   v1.32.0
minikube-m03   Ready    <none>          15s   v1.32.0
```

### 1-2. Zone 레이블 추가

로컬리티 테스트를 위해 각 노드에 zone 레이블을 추가합니다.

```bash
kubectl --context minikube label node minikube topology.kubernetes.io/zone=zone-a
kubectl --context minikube label node minikube-m02 topology.kubernetes.io/zone=zone-b
kubectl --context minikube label node minikube-m03 topology.kubernetes.io/zone=zone-c
```

**확인:**
```bash
kubectl --context minikube get nodes -L topology.kubernetes.io/zone
```

```
NAME           STATUS   ROLES           AGE     VERSION   ZONE
minikube       Ready    control-plane   2m16s   v1.32.0   zone-a
minikube-m02   Ready    <none>          2m2s    v1.32.0   zone-b
minikube-m03   Ready    <none>          110s    v1.32.0   zone-c
```

---

## Phase 2: Istio 설치 (사이드카 모드)

### 2-1. Istio 1.26.6 다운로드 및 설치

```bash
# Istio 다운로드
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.26.6 sh -

# Default 프로파일로 설치 (사이드카 모드)
./istio-1.26.6/bin/istioctl install --set profile=default -y
```

**설치 결과:**
```
✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ Ingress gateways installed 🛬
✔ Installation complete
```

**설치 확인:**
```bash
kubectl --context minikube get pods -n istio-system
```

```
NAME                                    READY   STATUS    RESTARTS   AGE
istio-ingressgateway-688f6d4c8c-rxnmz   1/1     Running   0          17s
istiod-5756d45dfb-jntcs                 1/1     Running   0          29s
```

**주요 컴포넌트:**
- **istiod**: 컨트롤 플레인
- **istio-ingressgateway**: 인그레스 게이트웨이
- ztunnel 없음 (사이드카 모드)
- istio-cni-node 없음 (사이드카 모드)

---

## Phase 3: Bookinfo 애플리케이션 배포

### 3-1. Namespace 생성 및 사이드카 주입 활성화

```bash
kubectl --context minikube create namespace bookinfo
kubectl --context minikube label namespace bookinfo istio-injection=enabled
```

### 3-2. Bookinfo 앱 배포 (Zone별 분산)

로컬리티 테스트를 위해 reviews 서비스를 각 zone에 다른 버전으로 배포합니다.

**배포 전략:**
- details, ratings, productpage: 각 zone에 1개씩 (총 3개)
- reviews-v1: zone-a에만 배포
- reviews-v2: zone-b에만 배포
- reviews-v3: zone-c에만 배포

```yaml
# bookinfo-locality.yaml (reviews-v1 예시)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews-v1
  namespace: bookinfo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: reviews
      version: v1
  template:
    metadata:
      labels:
        app: reviews
        version: v1
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values:
                - zone-a
      containers:
      - name: reviews
        image: docker.io/istio/examples-bookinfo-reviews-v1:1.20.2
        ports:
        - containerPort: 9080
```

**Pod 배포 확인:**
```bash
kubectl --context minikube get pods -n bookinfo -o wide
```

```
NAME                              READY   STATUS    RESTARTS   AGE   IP           NODE
details-v1-94f89d44f-4zx5j        2/2     Running   0          98s   10.244.2.3   minikube-m03
productpage-v1-6cf65f6dcc-v6dmw   2/2     Running   0          98s   10.244.0.4   minikube
reviews-v1-6f4479b77c-j9ll5       2/2     Running   0          98s   10.244.0.5   minikube
reviews-v2-7bf76c6765-lxpjj       2/2     Running   0          98s   10.244.1.3   minikube-m02
reviews-v3-5847894485-ftsrc       2/2     Running   0          98s   10.244.2.4   minikube-m03
```

**Pod 분포:**
- **zone-a (minikube)**: reviews-v1 (별점 없음)
- **zone-b (minikube-m02)**: reviews-v2 (검은 별)
- **zone-c (minikube-m03)**: reviews-v3 (빨간 별)

모든 Pod가 **2/2 Ready** 상태로 사이드카(istio-proxy)가 정상 주입되었습니다.

---

## Phase 4: Locality 기반 라우팅 설정 (사이드카 모드)

### 4-1. DestinationRule 배포

사이드카 모드에서는 DestinationRule을 사용하여 locality 라우팅을 설정합니다.

```yaml
# locality-destinationrule.yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews-locality
  namespace: bookinfo
spec:
  host: reviews.bookinfo.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      localityLbSetting:
        enabled: true
        distribute:
        - from: "*/zone-a/*"
          to:
            "*/zone-a/*": 100
        - from: "*/zone-b/*"
          to:
            "*/zone-b/*": 100
        - from: "*/zone-c/*"
          to:
            "*/zone-c/*": 100
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
```

```bash
kubectl --context minikube apply -f locality-destinationrule.yaml
```

### 4-2. Locality 테스트

각 zone에서 curl Pod를 배포하고 테스트합니다.

```bash
# 테스트 결과
=== Locality Test: Sidecar Mode ===

Testing from zone-a:
Expected: reviews-v1 (zone-a) - no stars
  Request 1-10: v1, v1, v1, v1, v1, v1, v1, v1, v1, v1 ✅

Testing from zone-b:
Expected: reviews-v2 (zone-b) - black stars
  Request 1-10: v2, v2, v2, v2, v2, v2, v2, v2, v2, v2 ✅
```

사이드카 모드에서는 DestinationRule을 통해 **100% locality 라우팅**이 정상 동작합니다.

---

## Phase 5: Ambient 모드로 전환

### 5-1. Istio 앰비언트 프로파일로 재설치

```bash
./istio-1.26.6/bin/istioctl install --set profile=ambient -y
```

**결과:**
```
✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ CNI installed 🪢
✔ Ztunnel installed 🔒
- Pruning removed resources
  Removed apps/v1, Kind=Deployment/istio-ingressgateway.istio-system.
✔ Installation complete
The ambient profile has been installed successfully, enjoy Istio without sidecars!
```

**주요 변경사항:**
- ✅ CNI 설치됨 (istio-cni-node)
- ✅ Ztunnel 설치됨 (L4 프록시)
- ❌ Ingress Gateway 제거됨

### 5-2. 앰비언트 컴포넌트 확인

```bash
kubectl --context minikube get pods -n istio-system
```

```
NAME                          READY   STATUS    RESTARTS   AGE
istio-cni-node-l8wj4          1/1     Running   0          2m
istio-cni-node-ttldq          1/1     Running   0          2m
istio-cni-node-vhl5f          1/1     Running   0          2m
istiod-5c9ccd6775-twn75       1/1     Running   0          2m
ztunnel-9tthx                 1/1     Running   0          18s
ztunnel-b9zkj                 1/1     Running   0          18s
ztunnel-g4x5z                 1/1     Running   0          18s
```

**앰비언트 모드 아키텍처:**
```
사이드카 모드:
Pod (앱 + istio-proxy)
  ↓
각 Pod마다 프록시

앰비언트 모드:
Pod (앱만)
  ↓
ztunnel (노드 레벨 L4 프록시)
  ↓
waypoint (선택적 L7 프록시)
```

### 5-3. 네임스페이스 전환

```bash
# 사이드카 주입 비활성화 + 앰비언트 모드 활성화
kubectl --context minikube label namespace bookinfo \
  istio-injection- \
  istio.io/dataplane-mode=ambient
```

### 5-4. 롤링 업데이트로 무중단 전환

**롤링 업데이트 전략 설정:**
```yaml
spec:
  replicas: 4
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0  # 항상 최소 replicas 수 유지
  template:
    spec:
      containers:
      - readinessProbe:
          httpGet:
            path: /health
            port: 9080
          initialDelaySeconds: 5
          periodSeconds: 5
```

**Pod 재시작:**
```bash
kubectl --context minikube rollout restart deployment -n bookinfo
```

**전환 결과:**
- **총 요청**: 2540회
- **성공**: 2534회
- **성공률**: **99.76%**
- **다운타임**: 약 3초

```bash
kubectl --context minikube get pods -n bookinfo
```

```
NAME                              READY   STATUS    RESTARTS   AGE
details-v1-564778d977-9d4cx       1/1     Running   0          32s
productpage-v1-7859bcd777-4c2xw   1/1     Running   0          18s
reviews-v1-6dd597f4f9-cnlrt       1/1     Running   0          32s
```

모든 Pod가 **1/1 Ready** 상태로 사이드카가 제거되었습니다!

---

## Phase 6: Ambient 모드에서 Locality 라우팅

### 6-1. 문제 발견: DestinationRule이 동작하지 않음

앰비언트 모드에서 기존 DestinationRule로 테스트하면:

```bash
=== Locality Test: Ambient Mode (DestinationRule) ===

Testing from zone-a:
Expected: reviews-v1 (zone-a)
  Request 1-10: v1, v2, v1, v2, v1, v2... ❌ (랜덤 분산)

Testing from zone-b:
Expected: reviews-v2 (zone-b)
  Request 1-10: v1, v2, v1, v2, v1, v2... ❌ (랜덤 분산)
```

**원인:**
- Ztunnel은 L4 프록시로 DestinationRule(L7)을 지원하지 않음
- Locality 정보 인식 방식이 다름

### 6-2. 해결책: Kubernetes trafficDistribution 사용

**Istio 1.23의 새로운 방식:**

Istio 1.23 Release Notes:
> "Support for the new `Service` field `trafficDistribution`, allowing keeping traffic in local zones/regions."

```yaml
apiVersion: v1
kind: Service
metadata:
  name: reviews
  namespace: bookinfo
spec:
  trafficDistribution: PreferClose  # 핵심!
  ports:
  - port: 9080
    name: http
  selector:
    app: reviews
```

**적용:**
```bash
kubectl --context minikube patch service reviews -n bookinfo \
  -p '{"spec":{"trafficDistribution":"PreferClose"}}'
```

### 6-3. 성공적인 Locality 라우팅

```bash
=== Locality Test: Ambient Mode (trafficDistribution) ===

Testing from zone-a (Pod 1):
  Request 1-10: v1, v1, v1, v1, v1, v1, v1, v1, v1, v1 ✅

Testing from zone-a (Pod 2):
  Request 1-10: v1, v1, v1, v1, v1, v1, v1, v1, v1, v1 ✅

Testing from zone-b (Pod 1):
  Request 1-10: v2, v2, v2, v2, v2, v2, v2, v2, v2, v2 ✅

Testing from zone-b (Pod 2):
  Request 1-10: v2, v2, v2, v2, v2, v2, v2, v2, v2, v2 ✅

=== Summary ===
zone-a → reviews-v1: 20/20 (100%) ✅
zone-b → reviews-v2: 20/20 (100%) ✅
```

---

## 사이드카 vs 앰비언트 모드 비교

### Locality 설정 방식

| 항목 | 사이드카 모드 | 앰비언트 모드 |
|------|--------------|--------------|
| **설정 방식** | DestinationRule | Service.trafficDistribution |
| **처리 주체** | Envoy (L7) | Ztunnel + Kubernetes (L4) |
| **세밀한 제어** | ✅ 가능 (100% 강제, 비율 조정) | ⚠️ 제한적 (PreferClose) |
| **설정 복잡도** | 복잡 | 간단 |
| **Kubernetes 버전** | 무관 | 1.30+ |

### 아키텍처 비교

| 항목 | 사이드카 모드 | 앰비언트 모드 |
|------|--------------|--------------|
| **프록시 위치** | 각 Pod 내부 | 노드 레벨 (ztunnel) |
| **컨테이너 수** | 2 (앱 + proxy) | 1 (앱만) |
| **L4 처리** | 사이드카 | ztunnel |
| **L7 처리** | 사이드카 | waypoint (선택적) |
| **리소스 사용** | Pod당 프록시 | 노드당 + waypoint |
| **배포 복잡도** | Pod 재시작 필요 | 레이블만 변경 |

### trafficDistribution 작동 원리

```
Client Pod → Ztunnel (L4) → Kubernetes Service → Ztunnel (L4) → Server Pod
                           ↑
                    trafficDistribution: PreferClose
                    (같은 zone의 endpoint 우선 선택)
```

**Kubernetes가 Zone을 인식하는 방법:**
1. Node의 `topology.kubernetes.io/zone` 레이블 읽기
2. Pod의 `nodeName`으로 zone 매핑
3. Endpoints에 zone 정보 자동 추가
4. `trafficDistribution: PreferClose` 적용

---

## 핵심 교훈

### 1. 공식 문서 확인의 중요성

Istio 버전별 Release Notes에서 새로운 기능을 확인하는 것이 중요합니다. Ambient 모드의 locality 지원은 Istio 1.23 Release Notes에 명시되어 있습니다.

### 2. Kubernetes 네이티브 기능 활용

Ambient 모드는 Kubernetes의 네이티브 기능(`trafficDistribution`)을 활용합니다. Istio 전용 기능(DestinationRule)보다 표준 기능을 사용하면 플랫폼 독립적인 설정이 가능합니다.

### 3. 롤링 업데이트 전략의 중요성

사이드카에서 앰비언트로 전환 시:
- `replicas=1`: 다운타임 불가피
- `replicas=4 + maxUnavailable=0`: 무중단 배포 가능
- `readinessProbe`: 새 Pod가 준비된 후 트래픽 전환

---

## 결론

### 성공한 것

✅ **Ambient 모드 전환**
- 무중단 전환 달성 (99.76% 가용성)
- 사이드카 제거로 리소스 절약

✅ **Locality 라우팅**
- `trafficDistribution: PreferClose`로 100% 성공
- Minikube 환경에서도 정상 동작

✅ **간단한 설정**
- Service 필드 하나만 추가
- DestinationRule 불필요

### 제약 사항

⚠️ **Kubernetes 버전 요구**: 1.30+

⚠️ **세밀한 제어 불가**: PreferClose만 지원 (비율 조정 불가)
- 해결책: Waypoint Proxy + DestinationRule 사용

---

## 참고 자료

### Istio
- [Istio 1.23 Release Notes](https://istio.io/latest/news/releases/1.23.x/announcing-1.23/)
- [Ambient Mode Documentation](https://istio.io/latest/docs/ambient/)
- [Ambient Mode GA Announcement](https://istio.io/latest/blog/2024/ambient-reaches-ga/)

### Kubernetes
- [Service trafficDistribution](https://kubernetes.io/docs/concepts/services-networking/service/#traffic-distribution)
- [Topology Aware Routing](https://kubernetes.io/docs/concepts/services-networking/topology-aware-routing/)
- [Topology Labels](https://kubernetes.io/docs/reference/labels-annotations-taints/#topologykubernetesiozone)
