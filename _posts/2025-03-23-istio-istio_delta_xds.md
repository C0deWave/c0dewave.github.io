---
title: "[Istio] Delta xDS 연구"
date: 2025-03-23 00:00:00 +0900
categories: [Istio, Service Mesh]
tags: [istio, xds, delta-xds, envoy, service-mesh]
description: "Istio 1.22에서 기본 설정이 된 Delta xDS에 대해 알아봅니다."
---

## [Istio] Delta xDS 연구

Istio 1.22 버전에 기본 설정으로 반영 되는 delta xDS에 대해서 알아본다.

Istio 프로젝트의 초기 단계에서는 구성이 글로벌 State of the World(SotW) 방법을 사용하여 Envoy 프록시에 푸시되었습니다. **서비스가 변경될 때마다 글로벌 구성을 모든 사이드카에 푸시해야 했기 때문에 제어 평면에서 상당한 네트워크 부하와 성능 손실이 발생**했습니다. Istio 커뮤니티는 이 문제를 해결하기 위해 몇 년 전부터 Incremental xDS를 개발하기 시작했으며 최근 Istio 버전에서 Incremental xDS를 지원했습니다. 최근 Istio 1.22 릴리스 에서 Incremental xDS(일명 "Delta xDS")가 기본이 되었습니다. 이 문서에서는 xDS, Incremental xDS 및 Istio의 구성 배포 방법을 소개합니다.


---
### xDS란 무엇인가?

xDS(Extensible Discovery Service)는 마이크로서비스 아키텍처에서 서비스 검색 및 동적 구성을 관리하는 데 사용되는 통신 프로토콜입니다. 이 메커니즘은 Envoy 프록시 및 Istio 서비스 메시에서 라우팅, 서비스 검색, 부하 분산 설정 등과 같은 다양한 유형의 리소스 구성을 관리하는 데 널리 사용됩니다.

---
### xDS에는 어떤 발견 서비스가 포함되어 있나요? 

xDS에는 다음과 같은 주요 검색 서비스가 포함되어 있으며, 각각은 다양한 유형의 네트워크 리소스 구성을 담당합니다.

 - **LDS(Listener Discovery Service)** : Envoy 리스너의 구성을 관리하며, 인바운드 연결을 수신하고 처리하는 방법을 정의합니다.
 - **RDS(Route Discovery Service)** : 라우팅 정보를 제공하고, 지정된 규칙에 따라 다양한 서비스에 대한 요청을 라우팅하는 방법을 정의합니다.
 - **CDS(Cluster Discovery Service)** : 클러스터 정보를 관리합니다. 여기서 클러스터는 논리적으로 유사한 백엔드 서비스 인스턴스의 그룹을 나타냅니다.
 - **EDS(Endpoint Discovery Service)** : CDS에 정의된 클러스터를 구성하는 특정 서비스 인스턴스의 네트워크 주소를 제공합니다.
 - **SDS(Secret Discovery Service)** : TLS 인증서, 개인 키 등의 보안 관련 구성을 관리합니다.
 - **VHDS(Virtual Host Discovery Service)** : RDS에 대한 가상 호스트 구성을 제공하여 연결을 다시 시작하지 않고도 가상 호스트를 동적으로 업데이트할 수 있도록 합니다.
 - **SRDS(Scoped Route Discovery Service)** : 라우팅 범위를 관리하고 다양한 조건(요청 헤더 등)에 따라 동적 경로 선택을 제공합니다.
 - **RTDS(런타임 검색 서비스)** : 실험적 기능이나 시스템 동작의 미세 조정에 사용할 수 있는 런타임 구성을 제공합니다.

이 서비스들은 동적인 설정(distribution and update of dynamic configurations)의 배포와 업데이트를 지원하며, Envoy 기반의 애플리케이션 아키텍처가 실시간으로 변화에 적응할 수 있도록 돕습니다. 이를 통해 확장성과 유연성이 향상됩니다. 각 서비스는 독립적으로 구현할 수도 있고, ADS(Aggregated Discovery Service)와 같은 통합 접근 방식을 통해 함께 관리할 수도 있습니다. CNCF는 또한 xDS API를 L4/L7 데이터 플레인 설정의 사실상 표준으로 발전시키기 위해 xDS API 워킹 그룹을 설립했습니다. 이는 SDN에서 OpenFlow가 L2/L3/L4 계층 설정에 있어 수행하는 역할과 유사합니다.

xDS 프로토콜에 대한 자세한 소개(예: xDS RPC 서비스 및 다양한 메서드, xDS 요청 처리 과정 등)는 Envoy Proxy 공식 문서를 참고하시기 바랍니다.

---
### xDS 프로토콜의 다양한 종류
xDS 프로토콜은 주로 다음과 같은 형태가 포함되어 있습니다.

 - **State of the World (SotW)** : 별도의 gRPC 스트림은 각 리소스 유형에 대한 전체 데이터를 제공하며, 일반적으로 Envoy 프록시가 처음 시작될 때 사용됩니다. 이 방식은 Istio에서 처음으로 사용된 xDS 프로토콜 유형입니다.
 - **Incremental xDS (Delta xDS)** : 각 리소스 유형에 대해 변경된 부분만을 제공하는 방식으로, 2021년부터 개발이 시작되었으며 Istio 1.22 버전부터 기본적으로 활성화되어 있습니다.
 - **Aggregated Discovery Service (ADS)** : 단일 gRPC 스트림이 모든 종류의 리소스 데이터를 통합하여 제공합니다.
 - **Incremental ADS (Delta ADS)** : 단일 gRPC 스트림이 모든 종류의 증분(incremental) 데이터를 통합하여 제공합니다.

아래 표는 xDS 프로토콜의 네 가지 종류에 대한 설명, 사용 시나리오, 장단점 비교를 요약한 것입니다. 이러한 종류들은 다양한 네트워크 환경과 서비스 요구에 맞춰 여러 선택지를 제공하며, 가장 적합한 프로토콜 방식을 선택함으로써 서비스 성능과 자원 활용을 최적화할 수 있습니다.

| Variant Type | Explanation                                                                                                                              | Usage Scenario                                                                                                         | Advantages                                                                                                      | Disadvantages                                                                                                                                    |
|--------------|------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| SotW         | 변경 여부와 상관없이 매번 모든 구성 데이터를 전송합니다.                                                                           | 구성 변경이 거의 없는 안정적인 환경에 적합합니다.                                                     | 구현이 간단하고 이해 및 유지 관리가 용이합니다.                                                          | 데이터 전송량이 많아, 구성 변경이 빈번한 환경에는 적합하지 않습니다.                                                   |
| Delta xDS    | 전체 데이터가 아닌 변경된 구성 데이터만 전송합니다.                                                                                 | 변경이 자주 발생하고 업데이트에 빠르게 대응해야 하는 환경에 적합합니다.                                   | 불필요한 데이터 전송을 줄여 효율성을 높입니다.                                                   | 구현이 복잡하며, 클라이언트와 서버가 구성 상태를 함께 관리해야 합니다.                                                            |
| ADS          | 모든 구성 데이터를 단일 gRPC 스트림으로 관리하므로, 각 리소스 유형마다 별도의 연결을 만들 필요가 없습니다.       | 여러 유형의 리소스를 동시에 관리해야 하는 복잡한 서비스 아키텍처에 적합합니다.             | 네트워크 연결 수를 줄여 리소스 관리를 단순화합니다.                                     | 네트워크나 서비스 품질이 낮은 경우, 단일 장애 지점(SPOF)으로 인해 모든 구성 업데이트가 실패할 수 있습니다.                            |
| Delta ADS    | ADS와 Incremental xDS의 장점을 결합하여, 단일 gRPC 스트림을 통해 리소스의 변경 사항만을 통합해 전송합니다. | 다양한 유형의 리소스를 관리하면서 빈번한 업데이트가 필요한 고도로 동적인 환경에 적합합니다. | 최대의 유연성과 효율성을 제공하며, 대규모이면서 변화가 많은 서비스 아키텍처에 적합합니다. | 가장 복잡한 구현 방식으로, 구성 로직 관리와 리소스 변경 및 전송에 대한 정밀한 제어가 요구됩니다. |

Istio에서 DiscoveryServer는 Envoy의 xDS API 구현 역할을 하며 gRPC 인터페이스를 수신하고 Envoy의 요구 사항에 따라 구성을 동적으로 푸시하는 역할을 합니다. 다양한 리소스 유형에 대한 요청을 처리하고 서비스 변경 사항에 따라 Envoy 구성을 실시간으로 업데이트할 수 있습니다. 또한 클라이언트 인증서 확인 및 합법적인 서비스 인스턴스만 구성 데이터를 수신할 수 있도록 하는 것과 같은 보안 기능을 지원합니다.

---
### xDS 변형에 대한 구성 예

xDS 변형을 구성하려면 일반적으로 Envoy 프록시 또는 유사한 서비스 메시의 설정에서 xDS 서버 정보를 지정해야 합니다.
서비스 메시나 프록시 서버에 따라 구성 방식은 다를 수 있지만, 아래는 xDS 서버를 지정하고 각 프로토콜 변형을 사용하는 방법을 보여주는 일반적인 YAML 구성 예시들입니다.

---

### State of the World (SotW)
Envoy의 구성에서 SotW를 정적 리소스를 통해 사용하거나 API를 통해 동적으로 리소스를 얻어 사용할 수 있습니다. 다음은 클러스터와 리스너를 정적으로 정의하는 방법을 보여주는 간단한 Envoy 구성 예입니다.

```
static_resources:
  listeners:
    - address:
        socket_address: { address: 0.0.0.0, port_value: 80 }
      filter_chains:
        - filters:
            - name: envoy.http_connection_manager
              config:
                stat_prefix: ingress_http
                codec_type: auto
                route_config:
                  name: local_route
                  virtual_hosts:
                    - name: local_service
                      domains: ["*"]
                      routes:
                        - match: { prefix: "/" }
                          route: { cluster: local_service }
                    http_filters:
                      - name: envoy.router
                  clusters:
        - name: local_service
            connect_timeout: 0.25s
            type: STATIC
            lb_policy: ROUND_ROBIN
            hosts: [{ socket_address: { address: 127.0.0.1, port_value: 80 } }]
```

---
### Incremental xDS (delta xDS)

delta xDS 구성은 xDS 서버가 증분 프로토콜을 지원해야 하며, 클라이언트 구성은 delta xDS 사용을 지정해야 합니다. Envoy 시작 구성은 증분 xDS를 활성화하기 위해 API 버전을 추가해야 합니다.

```
dynamic_resources:
  cds_config:
    api_config_source:
      api_type: DELTA_GRPC
      grpc_services:
        envoy_grpc:
          cluster_name: xds_cluster
  lds_config:
    api_config_source:
      api_type: DELTA_GRPC
      grpc_services:
        envoy_grpc:
          cluster_name: xds_cluster
```

---
### Aggregated Discovery Service (ADS)
ADS를 사용할 때 모든 리소스 유형의 구성은 단일 API 엔드포인트를 통해 집계됩니다. 이는 Envoy 구성에서 지정됩니다.

```
dynamic_resources:
  cds_config:
    ads: {}
lds_config:
    ads: {}
  ads_config:
    api_type: GRPC
    grpc_services:
      envoy_grpc:
        cluster_name: xds_cluster
```

---
### Incremental ADS
delta ADS는 ADS 구성에서 증분형 API 유형을 지정하여 보다 세부적인 업데이트를 구현합니다.

```
dynamic_resources:
  cds_config:
    ads: {}
 lds_config:
    ads: {}
  ads_config:
    api_type: GRPC
    grpc_services:
      envoy_grpc:
        cluster_name: xds_cluster
```
이러한 구성 예는 귀하의 특정 환경 및 요구 사항에 맞게 조정해야 합니다. 자세한 내용과 고급 구성은 Envoy 설명서를 참조할 수 있습니다 .

---

### Istio는 Envoy Sidecar에 구성을 어떻게 전송하나요?

xDS 프로토콜 덕분에 Istio 및 Envoy Gateway와 같은 도구는 API를 통해 Envoy 프록시에 구성을 동적으로 배포할 수 있습니다. 아래 다이어그램은 Istio(Sidecar 모드)의 구성 배포 프로세스를 보여줍니다.

![alt text](/assets/images/posts_img/istio/01.deltaXDS/istio_logic.png)

Istio의 구성 배포 프로세스의 주요 단계는 다음과 같습니다.

 - **선언적 구성(Declarative Configuration)** : 사용자는 YAML 파일이나 다른 구성 관리 도구를 사용하여 서비스 메시의 구성을 정의합니다. 이러한 구성에는 라우팅 규칙, 보안 정책, 원격 측정 설정 등이 포함될 수 있습니다.
 - **Kubernetes** : Istio 구성 파일은 일반적으로 kubectl apply 명령이나 다른 CI/CD 도구를 통해 Kubernetes 클러스터에 제출됩니다. Kubernetes는 구성 파일을 수신하여 etcd 데이터베이스에 저장합니다.
 - **Istiod** : Istiod는 Istio의 제어 플레인 구성 요소로, 구성을 관리하고 배포하는 역할을 합니다. Kubernetes API 서버에서 발생하는 이벤트를 수신하고, 관련 구성 변경 사항을 가져와 처리합니다. Istiod는 구성 파일을 구문 분석하고, 해당 라우팅 규칙과 정책을 생성하고, 이러한 구성을 xDS API를 통해 데이터 플레인(Envoy 프록시)에 배포합니다.
 - **xDS API** : Istiod는 xDS API를 사용하여 각 Envoy 프록시에 구성을 전송합니다.
 - **Envoy Proxy** : Envoy는 Istio의 데이터 플레인 구성 요소로, 각 서비스와 함께 사이드카 컨테이너에서 실행되어 모든 인바운드 및 아웃바운드 트래픽을 가로채고 관리합니다. Envoy 프록시는 xDS API를 통해 Istiod에서 구성을 수신하고 트래픽을 관리하고, 정책을 시행하고, 이러한 구성을 기반으로 원격 측정 데이터를 수집합니다.
 - **Pod** : 각 서비스 인스턴스는 애플리케이션 컨테이너와 Envoy 프록시 컨테이너를 포함하는 Pod에서 실행됩니다. Envoy 프록시는 애플리케이션 컨테이너와의 모든 네트워크 트래픽을 가로채서 구성에 따라 처리합니다.

이러한 구성 배포 프로세스를 통해 Istio는 서비스 메시의 모든 서비스 인스턴스를 동적으로 관리하고 구성하여 일관된 트래픽 관리 및 정책 시행을 제공할 수 있습니다.

---
### xDS의 진화와 Istio에서의 Delta xDS 구현

처음에 xDS는 "글로벌 상태"(State of the World, 약칭 SotW) 디자인을 채택했는데, 이는 모든 구성 변경이 모든 구성의 전체 상태를 Envoy로 보내야 한다는 것을 의미했습니다. 이 접근 방식은 특히 대규모 서비스 배포에서 네트워크와 제어 평면에 엄청난 부담을 주었습니다.

EnvoyCon 2021에서 Aditya Prerepa와 John Howard는 xDS의 증분 구현인 Istio가 Delta xDS를 구현하는 방법을 공유했습니다. 기존 SotW xDS와 비교했을 때 **Delta xDS는 변경된 구성만 전송하여 네트워크를 통해 전송해야 하는 구성 데이터의 양을 크게 줄여 효율성과 성능을 개선**합니다. 이 방법은 전체 구성이 아닌 변경된 부분만 업데이트하므로 구성이 자주 변경되는 환경에 특히 적합합니다.

Delta xDS를 구현하는 동안 Istio 팀은 구성 업데이트의 정확성을 보장하고 잠재적인 리소스 누출을 방지하는 것을 포함하여 여러 가지 과제에 직면했습니다. 그들은 SotW와 Delta 생성기를 병렬로 실행하고 점진적으로 구현의 결함을 식별하고 수정하기 위해 Dry-run 모드를 채택하여 이러한 과제를 해결했습니다. 또한 Virtual Host Discovery Service와 같은 새로운 Envoy 유형을 도입하여 보다 세분화된 구성 배포를 지원했습니다.

---

### Delta xDS 증분 구성

아래 다이어그램은 Delta xDS 증분 구성 프로세스를 보여줍니다.

![alt text](/assets/images/posts_img/istio/01.deltaXDS/istio_deltaXDS_logic.png)

Delta xDS 구성 프로세스는 다음과 같습니다.

 - **초기 완료 구성(Initial Complete Configuration)** : 제어 평면은 이때 StoW 모드를 사용하여 초기 완료 구성을 프록시로 전송합니다.
 - **구성 변경 사항 구독(Subscribe to Configuration Changes)** : 프록시는 제어 평면의 구성 변경 사항을 구독합니다.
 - **구성 변경 확인(Check Configuration Changes)** : 제어 평면은 프록시의 알려진 상태와 관련된 구성 변경 사항을 확인합니다.
 - **차이 계산(Calculate Differences)** : 제어 평면은 현재 구성과 프록시가 보유한 이전 구성 간의 차이(증가)를 계산합니다.
 - **차이점 전송(Send Only Differences)** : 제어 평면은 변경된 구성(차이점)만 프록시로 전송하고, 프록시는 이러한 증분 업데이트를 자체 구성에 적용합니다.

이 프로세스를 통해 필요한 변경 사항만 전송되고 적용되어 효율성이 향상되고 네트워크 및 프록시 리소스의 부하가 줄어듭니다.

---
### "SotW" VS "delta xDS"

Delta xDS가 대규모 네트워크에서 구성 배포의 성능 문제를 해결하는 반면, SotW 모드는 초기 구성 전달과 같이 여전히 자리를 잡고 있습니다. 아래 표는 Istio의 두 가지 구성 배포 방법인 SotW(State of the World)와 Delta xDS를 비교합니다.

|                | SotW                                                                                                 | Delta XDS                                                                                 |
|----------------|------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------|
| Data Volume    | 변경 여부와 관계없이 매번 전체 구성 데이터를 전송합니다.            | 변경된 구성 데이터만 전송하여 데이터 전송량을 줄입니다.                      |
| Efficiency     | 작거나 변경이 적은 환경에서는 수용 가능한 수준의 효율성을 제공합니다.                                        | 대규모 또는 변경이 빈번한 환경에서는 더 높은 효율성을 제공합니다.                           |
| Complexity     | 구현이 간단하고, 이해 및 유지 관리가 용이합니다.                                              | 구현이 더 복잡하며, 변경 사항에 대한 정밀한 추적 및 관리가 필요합니다.             |
| Resource Usage | 변경되지 않은 대량의 데이터를 반복적으로 전송하게 되어, 서버 및 네트워크 부하가 증가할 수 있습니다. | 변경된 부분만 처리하므로 리소스 사용이 적습니다.                                  |
| Timeliness     | 업데이트 후 전체 구성이 즉시 전송되므로 즉시성이 높습니다.                          | 변경된 부분만 전송하여 처리 시간을 줄이고 더 빠르게 반응할 수 있습니다.                  |
| Applicability  | 구성 변경이 드문 소규모부터 중간 규모의 배포 환경에 적합합니다.                      | 구성 변경이 빈번하거나 대규모 배포 환경에 적합합니다. |

---

### 결론

이 글에서는 xDS의 구성 요소와 Istio의 구성 배포 프로세스, 그리고 xDS의 두 가지 모드인 SotW와 Delta xDS에 대해 공유했습니다. Delta xDS가 Istio 버전 1.22의 기본 구성이 되면서, 사용자는 대규모 네트워크 환경에서 Istio를 쉽게 사용할 수 있게 되었습니다.

---

**참조:**
 - [Istio Delta xDS Now on by Default: What’s New in Istio 1.22 Deep Dive](https://tetrate.io/blog/istio-service-mesh-delta-xds/)
 - [xDS REST and gRPC protocol](https://www.envoyproxy.io/docs/envoy/latest/api-docs/xds_protocol)