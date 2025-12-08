---
title: "Argo Rollout Analysis 연구"
date: 2025-04-06 00:00:00 +0900
categories: [CI/CD, GitOps]
tags: [argo-rollout, kubernetes, progressive-delivery, canary, blue-green]
description: "Argo Rollout의 Analysis 기능을 활용한 자동화된 배포 검증"
---

## Argo Rollout Analysis
아래 문서면 사실 이해하는데 충분하다.  
[https://argoproj.github.io/argo-rollouts/features/analysis/](https://argoproj.github.io/argo-rollouts/features/analysis/)

이번에는 argo rollout의 analysis에 대해 알아본다.  
analysis는 crd로써 argo_rollout의 **배포가 잘 이루어 졌는지 분석할 수 있도록 도와주는 역할**을 하고있다.  
적용하게 되면 대시보드에서 아래와 같이 Steps에 추가되게 된다. 

analysis가 실패하게 되면 배포는 중단되고 Abort되어 이전 단계로 되돌아가게 된다.

![alt text](/assets/images/posts_img/cicd/argo_rollout_analysis/image.png)

 - 테스트 메트릭에 대한 정의를 DevOps 혼자 하기는 어렵고 개발자들과 한땀한땀 짜야할것 같아 보이는데 함부로 도입하기는 어려워 보이기도 한다.

예제 코드를 보면 아래와 같다.  
rollout.yaml 내 Step 부분에 analysis가 추가되는 것을 볼 수 있다.
```
apiVersion: argoproj.io/v1alpha1
kind: Rollout
...
  strategy:
    canary:
      steps:
      - setWeight: 50
      - pause: {duration: 15s}
      - analysis:
          templates:
          - templateName: http-response-time-check
          args:
          - name: response_time_limit
            value: "10s"
      - setWeight: 100
```

위 카나리 설정에서 말하는 templateName은 아래와 같이 정의할 수 있다.  
이는 템플릿 내 정의된 provider를 통해서 구현할 수 있다.

예제 1. prometheus provider
```
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: resource-usage-analysis
spec:
  args:
  - name: required-pod-count
    value: "3"  # default value if not overridden by Rollout
  metrics:
    - name: pod-count
      successCondition: "result[0] >= \{{args.required-pod-count\}}"
      failureCondition: "result[0] < \{{args.required-pod-count\}}"
      provider:
        prometheus:
          address: http://prometheus-operated.default.svc.cluster.local:9090
          query: |
            count(kube_pod_info{namespace="default", pod=~"example-app-.*"})
```

예제2. job provider
```
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: mock-success-rate-check
spec:
  metrics:
    - name: success-rate
      # This is a mock provider for demonstration purposes.
      # In a real scenario, you would use a real metric provider, such as Prometheus.
      provider:
        job:
          spec:
            template:
              spec:
                containers:
                - name: main
                  image: busybox
                  command: [sh, -c]
                  args: ["echo -n 99.5"]
                restartPolicy: Never
      successCondition: "result >= 99"
```

예제3. datadog
```
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: loq-error-rate
spec:
  args:
  - name: service-name
  metrics:
  - name: error-rate
    interval: 5m
    successCondition: result <= 0.01
    failureLimit: 3
    provider:
      datadog:
        apiVersion: v2
        interval: 5m
        query: |
          sum:requests.error.rate{service:\{{args.service-name\}}}
---
apiVersion: v1
kind: Secret
metadata:
  name: datadog
type: Opaque
stringData:
  address: https://api.datadoghq.com
  api-key: <datadog-api-key>
  app-key: <datadog-app-key>
```

문서를 보면 datadog 역시도 provider를 통해 쿼리를 할 수 있는 것으로 보인다.  
https://argoproj.github.io/argo-rollouts/analysis/datadog/

데이터 독에서 사용하는 경우에는 쿼리 수집이 안된 경우 nil을 반환하기에 default 함수를 통해서 nil 처리를 진행한다고 한다. 

![alt text](/assets/images/posts_img/cicd/argo_rollout_analysis/image3.png)

**트러블 슈팅: count 변수를 넣어주지 않으면 무한히 테스트를 할 수 있다고 경고가 나온다.**

![alt text](/assets/images/posts_img/cicd/argo_rollout_analysis/image2.png)