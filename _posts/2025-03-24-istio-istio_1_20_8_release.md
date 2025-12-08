---
title: "[Istio] Istio 1.20.8 발표"
date: 2025-03-24 00:00:00 +0900
categories: [Istio, Release Notes]
tags: [istio, release, service-mesh, update]
description: "Istio 1.20.8 버전의 주요 업데이트 내용을 살펴봅니다."
---

istio 에서 1.20.8 버전을 출시했다.
기존의 1.20.7 버전에 비해 어떤점이 개선/패치 되었는지를 한번 알아 보도록 하자.

## Istio 1.20.8 release

 - 원본 링크 : [Announcing Istio 1.20.8](https://istio.io/latest/news/releases/1.20.x/announcing-1.20.8/)
 - 소스코드 수정사항 : [Github](https://github.com/istio/istio/compare/1.20.7...1.20.8)

## Changes

1. ### **[Added]** : gateways.securityContext to manifests to provide an option to customize the gateway securityContext. (Issue [#49549](https://github.com/istio/istio/issues/49549))

     - **PR** : Can't deploy gateway with net.ipv4.ip_unprivileged_port_start

     - **문제상황** : Istio의 버전이 업데이트 되면서 net.ipv4.ip_unprivileged_port_start의 기본 값이 0 으로 활성화 되었고 이는 4.X 이후 커널에서만 지원하는 기능, 따라서 이전 버전 커널에서 해당 설정으로 인해 ingress gateway 컨테이너를 실행할 수 없었음.

     - **원인** : Istio의 1.20 버전이 되면서 istio helm 차트의 net.ipv4.ip_unprivileged_port_start의 기본 값이 0으로 설정 되었으나 이를 values에서 오버라이드 할 수 없었음.

     - **조치** : [#9e7872e](https://github.com/CloudGeometry/istio/commit/9e7872ec5aae7b099ca9df98994b9fbf3cd35b0c) [#512](https://github.com/defenseunicorns/uds-core/pull/512/files) helm chart values 내 .gateways.securityContext 옵션을 명시한 경우 오버라이드 할 수 있도록 조치

2. ### **[Fixed]** : an issue where JWKS fetched from URIs were not updated promptly when there are errors fetching other URIs. (Issue [#51636](https://github.com/istio/istio/issues/51636))
    - **PR** : JWKS URIs are not refreshed in some cases when other there are errors requesting other URIs

    - **문제상황** : Istio가 자주 구성을 재생성(config regeneration)할 때,
만약 하나 이상의 JWKS URI가 오류를 반환(예: 잘못된 주소)하면,
다른 정상적인 JWKS URI의 배경 갱신(refresh)이 트리거되지 않음. 즉, 하나라도 문제 있는 URI가 있으면 전체 갱신 로직이 막혀버림.

    - **JWKS URL** : JSON Web Key Set (JWT 서명을 검증할 때 쓰이는 공개키(public key) 들을 담고 있는 JSON 문서) 를 URL 형식으로 제공

    - **배경** : Istio는 JWT 검증을 위해 JWKS URI에서 공개키를 가져옴.
      이 공개키들은 캐시에 저장되고, 백그라운드에서 주기적으로 갱신(refresh)

      기본 갱신 주기: 20분
      , 실패 시에는 최대 60분까지 지연 (지수적 backoff)

    - **원인** : 
      - JWKS URI 중 하나라도 에러가 발생하면, Istio는 즉시 백그라운드 리프레시(부분 갱신) 를 수행
      - 이 경우 부분 갱신은 에러 난 URI만 다시 시도
      - 부분 갱신 실행 시 전체 갱신 타이머가 리셋 되어 정상 URL의 갱신이 발생하지 않음.

    - **조치** : [#51637](https://github.com/istio/istio/pull/51637/files) jwksUribackgroundChannel 변수를 두어 문제 상황에서 해당 변수 값을 true로 만들어 분기처리 진행

1. ### **[Fixed]** : 503 errors returned by auto-passthrough gateways created after enabling mTLS.
    - 관련 PR 이 릴리즈 노트에 링크되어 있지 않음.

2. ### **[Fixed]** : serviceRegistry ordering of the proxy labels, so we put the Kubernetes registry in front. (Issue [#50968](https://github.com/istio/istio/issues/50968))

    - **PR** : Sidecar CRD is ignored when pod rebalance from one Istiod to another and is endpoint in a ServiceEnrty

    - **문제 상황** : 
      - Sidecar CRD로 특정 egress.hosts를 설정하고, 해당하는 Pod들을 ServiceEntry에 IP로 추가함. 
      - 초기에는 잘 작동함.
      - 사이드카가 부팅된 지 약 30분 후, Istiod와의 연결이 재설정되면서 문제 발생
      - Istiod가 Sidecar 설정을 무시하고, 전체 mesh 설정을 사이드카에 다시 푸시
      - 설정이 갑자기 바뀌고, Endpoints 수도 급증 (예: 13개 → 321개)

    - **Sidecar CRD** : Sidecar CRD는 프록시(Envoy)의 설정 범위를 제어하기 위한 리소스입니다. 간단히 말하면, 사이드카 프록시가 어떤 트래픽을 보고, 어떤 설정을 따를지 세부적으로 지정, Istio는 모든 mesh-wide 설정을 모든 사이드카에 푸시합니다. 하지만 네임스페이스/워크로드에 따라 꼭 필요한 설정만 푸시하고 싶을 수도 있죠.
이때 사용하는 게 바로 Sidecar(CRD)

    - **Sidecar 리소스가 있는지 조회하는 방법** : kubectl get sidecar -n <네임스페이스>

    - **원인** : Proxy.SetWorkloadLabels에서 노드 레이블을 nil로 덮어써서 사이드카 리소스 입장에서 노드 특정 불가 => 따라서 PushContext.getSidecarScope가  sidecar와 일치할 수 없습니다.

    - **조치** : [#51003](https://github.com/istio/istio/pull/51003/files) Without this we can get proxy labels from WLE when the wle's address = pod ip (워크로드 주소와 pod id 가 같은 경우 해당 내용이 있어야만 프록시 라벨을 받을 수 있습니다.)