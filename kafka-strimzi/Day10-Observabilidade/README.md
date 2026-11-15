# Observabilidade do Kafka no Kubernetes — Prometheus, Grafana, Kube State Metrics, Alertas, Tracing de Ponta a Ponta e GitOps

> **Objetivo:** responder, com um cluster Strimzi de verdade, às três perguntas que importam
> quando algo dá errado às 3 da manhã: **(1) o produto está funcionando? (2) o Kafka está
> saudável? (3) por onde esta mensagem específica passou e onde ela demorou?** Para isso o lab
> monta **Prometheus + Alertmanager + Grafana + kube-state-metrics + Tempo (traces)** em cima de
> um cluster Strimzi, com um pipeline de exemplo (`producer → orders → processor →
> orders.processed → sink`) que gera tráfego, métricas de negócio e **um trace que atravessa
> dois tópicos e três serviços**. Tudo — operators, dashboards, regras de alerta, rotas de
> notificação, datasource — é **código em Git**, aplicado pelo **ArgoCD** e validado por um **CI
> com testes unitários de alertas (`promtool`)**. Todo cenário deste Day foi executado de ponta a
> ponta num kind (Strimzi 1.1.0, Kafka 4.3.0, ArgoCD 3.4.6, kube-prometheus-stack 93.3.0 com
> Prometheus 3.16.0, Tempo 2.9.0) — as saídas mostradas são reais. O que **não** foi executado
> está listado, sem rodeios, na seção 12.
>
> **Este README é também o roteiro de execução:** os blocos `bash` das seções 7 a 9 rodam em
> ordem, copiando e colando, e foram validados do zero num kind limpo.

---

## Índice

1. [Contexto: três perguntas e por que "de ponta a ponta" é difícil](#1-contexto-três-perguntas-e-por-que-de-ponta-a-ponta-é-difícil)
2. [Arquitetura](#2-arquitetura)
3. [De onde vêm as métricas do Strimzi](#3-de-onde-vêm-as-métricas-do-strimzi)
4. [A metodologia GitOps](#4-a-metodologia-gitops)
5. [Pré-requisitos](#5-pré-requisitos)
6. [Estrutura do Lab](#6-estrutura-do-lab)
7. [Subindo o lab](#7-subindo-o-lab)
8. [Tour: Grafana, Prometheus, Alertmanager e ArgoCD](#8-tour-grafana-prometheus-alertmanager-e-argocd)
9. [Cenários na prática](#9-cenários-na-prática)
10. [Tracing de ponta a ponta](#10-tracing-de-ponta-a-ponta)
11. [Indo para produção](#11-indo-para-produção)
12. [O que este lab NÃO cobre (honestamente)](#12-o-que-este-lab-não-cobre-honestamente)
13. [Cleanup](#13-cleanup)
14. [Roteiro sugerido para o vídeo](#14-roteiro-sugerido-para-o-vídeo)
15. [Referências](#15-referências)

---

## 1. Contexto: três perguntas e por que "de ponta a ponta" é difícil

Kafka é **assíncrono**: o produtor não sabe quem consome, o consumidor não sabe quem produziu, e
entre os dois existe um log. Isso tem uma consequência desconfortável para observabilidade:

- **Broker verde não significa produto funcionando.** Um consumidor travado, uma mensagem
  venenosa ou um serviço downstream lento deixam todos os painéis do broker verdes e o cliente
  sem a notificação.
- **Produto funcionando não significa Kafka saudável.** O pipeline pode estar ok *agora* com um
  broker caído e `min.insync.replicas` no limite — a próxima falha vira indisponibilidade.
- **Um trace normal quebra no tópico.** Cada serviço gera seus spans, mas, sem **propagar o
  contexto dentro da mensagem**, o Tempo/Jaeger mostra três traces soltos em vez de uma história.

O dashboard e os alertas deste Day são organizados exatamente pelas três perguntas:

| Pergunta | Sinal | Fonte |
|---|---|---|
| **1. O produto funciona?** | vazão por etapa, **latência de ponta a ponta (p95)**, taxa de erro, lag | métricas de negócio do app + Kafka Exporter |
| **2. O Kafka está saudável?** | partições sub-replicadas / abaixo do ISR mínimo / offline, controller ativo, pods Ready, status dos CRs | Strimzi Metrics Reporter + kube-state-metrics |
| **3. Para onde foi *esta* mensagem?** | trace único `producer → processor → sink` | OpenTelemetry → Tempo |

## 2. Arquitetura

```text
                         ┌────────────────────── namespace: demo ───────────────────────┐
                         │  order-producer ──► [orders] ──► order-processor ──► [orders.processed] ──► order-sink  │
                         │   :8000/metrics      (6 part.)     :8000/metrics        (6 part.)           :8000/metrics │
                         └──────┬────────────────────────────────────┬─────────────────────────────────────┬──────┘
                    OTLP/gRPC (traces, contexto no header do Kafka)   │ PodMonitor (métricas de negócio)    │
                                │                                     │                                     │
  ┌──────── namespace: kafka ───┴─────────┐          ┌────────────── namespace: monitoring ───────────────────────────────┐
  │ my-cluster (3 nós controller+broker)  │          │                                                                     │
  │  :9404  Strimzi Metrics Reporter ─────┼─PodMon──►│  Prometheus ──regras──► Alertmanager ──AlertmanagerConfig──► webhook │
  │ Kafka Exporter (lag, offsets) ────────┼─PodMon──►│     ▲  ▲  ▲                                                         │
  │ Entity Operator (Topic+User) ─────────┼─PodMon──►│     │  │  └─ kube-state-metrics (nativo: pods, PVCs, Deployments)    │
  └───────────────────────────────────────┘          │     │  └──── strimzi-kube-state-metrics (STATUS dos CRs do Strimzi)   │
  ┌── namespace: strimzi-operator ──┐                │     │                                                              │
  │ Cluster Operator ───────────────┼───PodMonitor──►│     │            Grafana ◄── datasources: Prometheus + Tempo       │
  └─────────────────────────────────┘                │     │              ▲         dashboards (ConfigMaps no Git)        │
                                                     │   Tempo (traces) ──┘                                                │
                                                     └─────────────────────────────────────────────────────────────────────┘
  ┌── namespace: argocd ───────────────────────────────────────────────────────────────────────────────────────────────────┐
  │  observability-root ──► 6 Applications (strimzi-operator, kube-prometheus-stack, tempo, kafka, observability, demo-apps) │
  │                                                      ▲                                                                  │
  │                                          Git (repo "observability"): é a ÚNICA fonte da verdade                        │
  └──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

| Componente | Versão | De onde vem |
|---|---|---|
| Strimzi Cluster Operator | 1.1.0 | chart oficial (`strimzi.io/charts`) |
| Kafka | 4.3.0 (KRaft, 3 nós dual-role) | CRs `Kafka` + `KafkaNodePool` |
| Kafbat UI | `ghcr.io/kafbat/kafka-ui:v1.5.0` | `Deployment` em `manifests/kafka/kafbat-ui.yaml` |
| kube-prometheus-stack | 93.3.0 (Prometheus 3.16.0, Prometheus Operator 0.95.2) | chart `prometheus-community` |
| Grafana | a do chart acima | dashboards/datasources via sidecar (label) |
| Tempo | 2.9.0 (single-binary, chart `grafana/tempo` 1.24.4) | chart `grafana` |
| kube-state-metrics dos CRs | v2.16.0 | manifestos oficiais do Strimzi (`examples/metrics/kube-state-metrics`) |
| ArgoCD | 3.4.6 | manifesto oficial |
| App de exemplo (3 papéis: producer, processor, sink) | Python 3.12, `confluent-kafka` 2.16.1, OpenTelemetry SDK 1.45.2 | `lab/app/` (imagem local no kind) |

Endereços (via `extraPortMappings` do kind — sem `port-forward`):

| Serviço | URL | Credenciais |
|---|---|---|
| Grafana | <http://localhost:3000> | `admin` / `admin` (**só lab**) |
| Prometheus | <http://localhost:9090> | — |
| Alertmanager | <http://localhost:9093> | — |
| Kafbat UI (tópicos e mensagens) | <http://localhost:8088> | sem login (**só lab**) |
| ArgoCD (opcional) | <https://localhost:8080> via `port-forward` (seção 7.3) | `admin` / `argocd-initial-admin-secret` |

## 3. De onde vêm as métricas do Strimzi

Esta é a tabela que mais vale mostrar no vídeo: "métrica do Kafka" não é uma coisa só, são **seis
fontes diferentes**, cada uma responde uma pergunta que as outras não respondem.

| Fonte | Responde | Como o Strimzi a liga | Exemplo de métrica |
|---|---|---|---|
| **Strimzi Metrics Reporter** (dentro do broker/controller) | saúde interna do Kafka | `spec.kafka.metricsConfig.type: strimziMetricsReporter` → `/metrics` na porta `9404` (`tcp-prometheus`) | `kafka_server_replicamanager_underreplicatedpartitions` |
| **Kafka Exporter** (pod à parte) | **lag de consumer group**, offsets por tópico/partição | `spec.kafkaExporter: {}` | `kafka_consumergroup_lag` |
| **Operators** (Cluster, Topic, User) | o operador está reconciliando? quantas vezes falhou? | já expõem `/metrics`; falta só o `PodMonitor` | métricas de reconciliação |
| **kube-state-metrics nativo** | estado dos objetos do Kubernetes: pod Ready? PVC? réplicas do Deployment? | vem no `kube-prometheus-stack` | `kube_pod_status_ready` |
| **kube-state-metrics dos CRs do Strimzi** | **o `status` dos CRs** (`KafkaTopic`, `KafkaUser`, `Kafka`, `KafkaNodePool`, `KafkaRebalance`, `KafkaConnect`...) como métrica | 2ª instância do KSM só com `--custom-resource-state-only` + um `ConfigMap` de configuração | `strimzi_kafka_topic_resource_info{ready="False"}` |
| **Métricas do app** | o **produto**: vazão, erro, latência de ponta a ponta | `PodMonitor` que o próprio time entrega junto do `Deployment` | `demo_end_to_end_latency_seconds` |

**Metrics Reporter vs. JMX Prometheus Exporter.** Antes do Metrics Reporter, a forma de
expor métricas era o `jmxPrometheusExporter` — um agente Java que lê MBeans por JMX e as traduz
com **regras de regex num `ConfigMap`** que você precisa manter. O `strimziMetricsReporter` roda
dentro da JVM como *metrics reporter* do próprio Kafka e dispensa o `ConfigMap`:

```yaml
# gitops/manifests/kafka/kafka-metrics.yaml
spec:
  kafka:
    metricsConfig:
      type: strimziMetricsReporter     # e só. Sem ConfigMap com regras de regex.
```

No lab, os nomes de métrica que as regras e os dashboards oficiais do Strimzi esperam
(`kafka_server_replicamanager_*`, `kafka_controller_kafkacontroller_*`, `kafka_log_log_size`...)
**existem** com o Metrics Reporter — conferido no Prometheus. Os dashboards `Strimzi Kafka` e
`Strimzi KRaft` usados aqui são as **variantes específicas do Metrics Reporter**
(`examples/metrics/strimzi-metrics-reporter/grafana-dashboards/`), não as do JMX Exporter.

> **Por que o Kafka Exporter não é opcional na prática:** o broker **não sabe** o que é "lag".
> Lag é `log-end-offset − committed-offset`, e quem calcula é o exporter, consultando o
> broker. Sem ele, "meu consumidor está atrasado" vira adivinhação.

> **Por que um KSM só para os CRs:** o status de um `KafkaTopic` (`Ready=False` porque o Topic
> Operator não conseguiu criar o tópico) **não é um erro do Kafka** — o Kafka está ótimo. É um
> erro do *seu YAML*. Só o `status` do CR sabe disso, e o ArgoCD dirá "Synced". Esta é a lacuna que
> o cenário C (seção 9) mostra.

## 4. A metodologia GitOps

### 4.0 O padrão Strimzi: o layout de `examples/metrics`

O Strimzi distribui, em cada release, uma pasta `examples/metrics/` com **arquivos prontos** para
métricas (seção *Example metrics files* da documentação: configuração do Metrics Reporter / JMX Exporter,
regras de alerta, dashboards do Grafana, kube-state-metrics). O lab **segue esse layout e esses nomes**
(arquivos, pastas, `PrometheusRule`, labels `app: strimzi` / `role: alert-rules`) — quem conhece a doc
encontra tudo no mesmo lugar. A tabela mostra o mapeamento (arquivos oficiais da **1.1.0**) e o que mudou:

| Oficial (`examples/metrics/...`) | No lab (`gitops/manifests/...`) | Diferença |
|---|---|---|
| `strimzi-metrics-reporter/kafka-metrics.yaml` | `kafka/kafka-metrics.yaml` | 3 nós dual-role em vez de pools separados; `podAntiAffinity`; `kafkaExporter` mantido |
| `prometheus-install/pod-monitors/{cluster-operator,entity-operator,kafka-resources}-metrics.yaml` | `observability/prometheus-install/pod-monitors/` (mesmos 3 nomes) | `namespaceSelector` aponta para os namespaces do lab (`myproject` → `kafka`, `strimzi-operator`) |
| `prometheus-install/prometheus-rules/prometheus-{kafka,kafka-exporter-topic-rules-group,strimzi-cluster-operator,strimzi-entity-operator,kafka-certificate}-rules.yaml` | mesma pasta, mesmos nomes de arquivo e de `PrometheusRule` | label `team: kafka-platform` (roteamento), `for` menores, e **sinais do kube-state-metrics** no lugar de `container_last_seen`/regex `.+-kafka-N` (que não casam com nomes de node pool); detalhes no cabeçalho de cada arquivo |
| `kube-state-metrics/{configmap,ksm,prometheus-rules}.yaml` | `observability/kube-state-metrics/` | só o `namespace` do `ClusterRoleBinding` (armadilha 3) e `for: 1m` |
| `strimzi-metrics-reporter/grafana-dashboards/*.json` | `observability/grafana-dashboards/` | iguais; + dashboard `e2e-pipeline.json` (do lab) |
| `prometheus-install/prometheus.yaml`, `alert-manager.yaml`, `prometheus-additional-properties/`, `grafana-install/grafana.yaml` | **substituídos pelo `kube-prometheus-stack`** (`apps/10-kube-prometheus-stack.yaml`) | decisão do lab, explicada abaixo |
| `prometheus-alertmanager-config/alert-manager-config.yaml` (um Secret com o `alertmanager.yaml`) | `observability/prometheus-alertmanager-config/alert-manager-config.yaml` (um `AlertmanagerConfig`) | CR em vez de Secret: cada time versiona suas rotas |

**Por que o `kube-prometheus-stack` no lugar do Prometheus "à mão" dos exemplos.** O fluxo da doc é
instalar o Prometheus Operator e aplicar `prometheus.yaml` + `prometheus-additional.yaml` (um Secret com
*scrape configs* extras para cAdvisor/kubelet). O chart já traz Prometheus Operator, Alertmanager, Grafana,
**kube-state-metrics nativo** (que o exemplo do Strimzi não inclui: o KSM dele é só para os CRs), cAdvisor e
os dashboards de Kubernetes — e é o que a maioria dos clusters reais já tem. Os `PodMonitor`/`PrometheusRule`/dashboards
oficiais **funcionam sem alteração de formato** em qualquer Prometheus Operator, então a escolha do "motor" não muda
o padrão dos arquivos. Se você quiser o caminho 100% da doc, aplique `prometheus-install/` e `grafana-install/` do
release no lugar do chart.

> **Fonte:** a página da documentação (`deploying`, capítulo de métricas) veio **truncada** nas ferramentas
> usadas aqui — só o índice (*25.1 Example metrics files ... 25.6 Cruise Control operations monitoring*) foi lido.
> O layout e o conteúdo dos arquivos acima vêm **diretamente dos exemplos da release 1.1.0** no GitHub.

### 4.1 App of apps com sync waves

Um único `kubectl apply` à mão (`bootstrap/root-app.yaml`). A partir daí, o cluster é o que o Git
diz que ele é. O `observability-root` olha a pasta `apps/` e cria um `Application` por arquivo:

| Wave | `Application` | O que instala | Origem |
|---|---|---|---|
| 0 | `strimzi-operator` | Cluster Operator + CRDs | chart oficial 1.1.0 |
| 0 | `kube-prometheus-stack` | Prometheus Operator, Prometheus, Alertmanager, Grafana, KSM, CRDs | chart `prometheus-community` |
| 1 | `tempo` | backend de traces | chart `grafana/tempo` |
| 1 | `kafka` | `Kafka`, `KafkaNodePool`, `KafkaTopic` | `manifests/kafka/` |
| 2 | `observability` | PodMonitors, PrometheusRules, AlertmanagerConfig, dashboards, datasource, KSM dos CRs, webhook de lab | `manifests/observability/` |
| 3 | `demo-apps` | producer, processor, sink + o `PodMonitor` deles | `manifests/demo-apps/` |

As waves resolvem o problema "o CR chegou antes do CRD". Como o ArgoCD não espera o CRD aparecer
dentro de uma mesma Application, cada filha tem `retry` com backoff e
`SkipDryRunOnMissingResource=true` — se o CRD ainda não existe, ela tenta de novo.

### 4.2 Tudo é um CR descoberto por label

Nenhum arquivo de configuração do Prometheus, do Alertmanager ou do Grafana é editado. Cada peça
é um objeto que o respectivo operador/sidecar encontra sozinho:

| Quero... | Crio... | Quem descobre |
|---|---|---|
| que o Prometheus raspe um pod | `PodMonitor` / `ServiceMonitor` | Prometheus Operator |
| um alerta | `PrometheusRule` | Prometheus Operator |
| uma rota de notificação | `AlertmanagerConfig` | Prometheus Operator |
| um dashboard | `ConfigMap` com label `grafana_dashboard: "1"` (gerado por `kustomize` a partir do `.json`) | sidecar do Grafana |
| um datasource | `ConfigMap` com label `grafana_datasource: "1"` | sidecar do Grafana |

**Observabilidade faz parte da entrega do app.** Repare que o `PodMonitor` do pipeline mora junto
dos `Deployments` (`manifests/demo-apps/apps.yaml`), não no repo da plataforma. O time que
entrega o serviço entrega também o "como me observar" — sem abrir ticket.

### 4.3 O fluxo de uma mudança

```text
PR (alerta, dashboard, threshold, app)
  └─► CI: ci/validate.sh ─ kustomize build ─ JSON dos dashboards ─ promtool check ─ promtool TEST (testes unitários)
        └─► revisão: CODEOWNERS (quem é acordado pelo alerta aprova o alerta)
              └─► merge ─► ArgoCD sincroniza ─► Prometheus Operator regenera a config ─► Prometheus recarrega
```

O `.github/CODEOWNERS` do repo expressa a regra "quem é acordado pelo alerta é dono do alerta":

```text
/manifests/observability/prometheus-install/prometheus-rules/   @acme-corp/kafka-platform @acme-corp/sre
/manifests/observability/prometheus-alertmanager-config/      @acme-corp/sre
/manifests/demo-apps/                             @acme-corp/orders-team
```

### 4.4 O CI: alertas com testes unitários

[`gitops/ci/validate.sh`](gitops/ci/validate.sh) roda local e no GitHub Actions
([`validate.yaml`](gitops/.github/workflows/validate.yaml)): (1) `kustomize` renderiza, (2) os
dashboards são JSON válido (um JSON quebrado faz o sidecar **ignorar o ConfigMap em silêncio**),
(3) `promtool check rules`, (4) **`promtool test rules`** — você *inventa* as séries e afirma o
que deve (ou não deve) disparar. Veja a seção 9, cenário E, com falhas reais.

### 4.5 Armadilhas que o lab encontrou (cada uma custou tempo)

1. **"Meu `PodMonitor` não faz nada."** Pelo padrão do chart, o `kube-prometheus-stack` só
   seleciona `PodMonitor`/`ServiceMonitor`/`PrometheusRule` com o label `release=<helm release>`.
   Para descobrir *todos* (inclusive os do Strimzi e dos times), os três
   `*SelectorNilUsesHelmValues` são `false` (`apps/10-kube-prometheus-stack.yaml`).
   *(Comportamento documentado do chart; o lab já nasce com o ajuste, então a falha não foi reproduzida.)*
2. **O alerta dispara, mas ninguém recebe.** Pelo padrão documentado do Prometheus Operator
   (`alertmanagerConfigMatcherStrategy: OnNamespace`), toda rota de um `AlertmanagerConfig` é
   **forçada** a casar `namespace=<onde o CR mora>`: alertas do namespace `kafka` não chegariam
   ao receiver do namespace `monitoring`. O lab usa `type: None` e a rota funciona (alertas
   entregues ao webhook). *(Não reproduzimos a falha com o padrão.)*
3. **O KSM do Strimzi sobe, mas não exporta nada.** O `ClusterRoleBinding` oficial vem com
   `namespace: myproject` no `subjects`, e o `kustomize` **não reescreve** subjects de
   `ClusterRoleBinding`. Sintoma: `customresourcedefinitions ... is forbidden` no log do KSM e zero
   métricas `strimzi_*`. Corrigido em `kube-state-metrics/ksm.yaml` (e documentado ali).
4. **Prometheus demora a enxergar o `PodMonitor` novo (1–3 min).** Observado: o operador gera o
   Secret de configuração na hora (a config já continha os `podMonitor/`), mas o Prometheus só
   recarregou ~3 min depois — compatível com a propagação lenta de um Secret montado como volume.
   Não é bug: confira `Targets` depois de ~2–3 min antes de concluir que algo está errado.
5. **`kubelet_volume_stats_*` não existe no kind.** Os volumes `local-path` não reportam espaço
   livre ao kubelet. O alerta `KafkaRunningOutOfDisk` e o painel de PVC valem em cluster real
   (CSI); no lab, o dashboard usa `kafka_log_log_size` (tamanho do log, vindo do próprio Kafka).
   O painel *Available Disk Space* do dashboard oficial `Strimzi Kafka` fica vazio — esperado.

## 5. Pré-requisitos

- **Docker** com **≥ 10 GB de RAM** dedicados (o lab usa ~7,5 GB: 3 brokers de 1 GiB + Prometheus +
  Grafana + Tempo + ArgoCD; medido com `docker stats` em 4 nós kind).
- `kind` 0.24+, `kubectl`, `git`, `curl`, `jq` (os charts são instalados pelo ArgoCD, não por você).
- Para o **CI local** (seção 9, cenário E): `python3` e Docker (o `promtool` roda numa imagem).
- Portas livres no host: **3000, 9090, 9093** (Grafana, Prometheus, Alertmanager) e 18080/8080 se usar
  o Git local / UI do ArgoCD. Se alguma estiver ocupada, troque o `hostPort` em `kind-config.yaml`.
- Internet: o lab baixa charts, imagens e o manifesto do ArgoCD.

## 6. Estrutura do Lab

```text
Day10-Observabilidade/
├── README.md / README-EN.md
├── kind-config.yaml            # 1 control-plane + 3 workers; portas 3000/9090/9093 mapeadas para o host
├── lab/
│   ├── app/                    # app.py (os 3 papéis), Dockerfile, requirements.txt
│   ├── git-server.yaml         # Git mínimo DENTRO do cluster (o mesmo do Day 9) - só para lab
│   └── push-repo.sh            # semeia o Git e cria o clone de trabalho em lab/work/observability
└── gitops/                     # <<< o conteúdo do repositório Git que o ArgoCD observa
    ├── bootstrap/              # appproject.yaml + root-app.yaml  (o ÚNICO kubectl apply manual)
    ├── apps/                   # 6 Applications (uma por arquivo, com sync-wave)
    ├── manifests/
    │   ├── kafka/              # kafka-metrics.yaml (Kafka+NodePool), kafbat-ui.yaml, topics.yaml
    │   ├── observability/      # <<< MESMO layout do examples/metrics oficial do Strimzi (seção 4.0)
    │   │   ├── prometheus-install/{pod-monitors,prometheus-rules}/
    │   │   ├── kube-state-metrics/        # configmap.yaml, ksm.yaml, prometheus-rules.yaml
    │   │   ├── grafana-dashboards/        # *.json (4 oficiais + o e2e do lab)
    │   │   ├── grafana-install/           # (lab) datasource do Tempo
    │   │   └── prometheus-alertmanager-config/  # (lab) AlertmanagerConfig + webhook
    │   └── demo-apps/          # producer, processor, sink + PodMonitor
    ├── ci/                     # validate.sh, extract_rules.py, tests/rules_test.yml
    └── .github/                # CODEOWNERS + workflow
```

## 7. Subindo o lab

> **Como usar daqui para frente:** cada bloco ` ```bash ` é para **copiar e colar, em ordem, no
> mesmo terminal** (zsh ou bash). Os blocos ` ```text ` são a **saída esperada** — não rodam.
> Blocos que começam com `: TERMINAL 2` precisam de **um segundo terminal** (abra-o na raiz do repo e
> cole de novo as funções `kx`).

**Segurança:** todos os comandos usam `--context kind-strimzi-day10` (função `kx`). Nada é aplicado
fora do kind, mesmo que o seu `kubeconfig` tenha clusters de trabalho.

**Reset** (se já rodou o lab). A partir da **raiz do repositório**:

```bash
kind delete cluster --name strimzi-day10 2>/dev/null
pkill -f "port-forward svc/git-server" 2>/dev/null
rm -rf kafka-strimzi/Day10-Observabilidade/lab/work
echo "limpo"
```

### 7.1 Cluster kind e a imagem do app

```bash
cd kafka-strimzi/Day10-Observabilidade
kind create cluster --config=kind-config.yaml --name strimzi-day10
kx() { kubectl --context kind-strimzi-day10 "$@"; }
kx wait --for=condition=Ready node --all --timeout=120s
```

O app de exemplo é uma imagem local (um `Dockerfile` de 7 linhas). Construímos e carregamos nos nós do kind:

```bash
docker build -q -t kafka-e2e-demo:0.1.0 lab/app
kind load docker-image kafka-e2e-demo:0.1.0 --name strimzi-day10
```

### 7.2 ArgoCD

Mesmo procedimento do Day 9 (ArgoCD 3.4.6; `--server-side` porque os CRDs são grandes demais para o
client-side apply; reconciliação a cada 30 s só para o lab — em produção use **webhook** do Git):

```bash
kx create namespace argocd
kx apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.6/manifests/install.yaml > /dev/null
kx wait -n argocd --for=condition=Available deployment --all --timeout=300s
kx -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
kx -n argocd patch cm argocd-cm --type merge -p '{"data":{"timeout.reconciliation":"30s","timeout.reconciliation.jitter":"0s"}}'
kx -n argocd rollout restart statefulset/argocd-application-controller deploy/argocd-repo-server
kx -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
kx -n argocd rollout status deploy/argocd-repo-server --timeout=300s
```

### 7.3 Git local e bootstrap

O ArgoCD precisa de um remoto Git de verdade. O mesmo servidor Git mínimo do Day 9 sobe dentro do
cluster (**sem autenticação, só lab**) e o `push-repo.sh` semeia o repo `observability` a partir de
`gitops/`, deixando um **clone de trabalho** em `lab/work/observability` (é nele que você faz
`git commit`/`git push` nos cenários):

```bash
kx apply -f lab/git-server.yaml
lab/push-repo.sh
```

```text
pushed observability -> http://git-server.git.svc/cgi-bin/git/observability.git (from inside the cluster)
```

Agora o **único** `kubectl apply` da plataforma inteira — o `AppProject` e o `root`:

```bash
kx apply -f gitops/bootstrap/appproject.yaml -f gitops/bootstrap/root-app.yaml
```

*(Opcional, ótimo para o vídeo)* UI do ArgoCD em <https://localhost:8080> (usuário `admin`). **No terminal 2**:

```bash
: TERMINAL 2 — deixe este comando rodando
kubectl --context kind-strimzi-day10 -n argocd port-forward svc/argocd-server 8080:443
```

```bash
kx -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

### 7.4 Esperando tudo ficar de pé (~3–6 min)

```bash
until kx get kafka my-cluster -n kafka >/dev/null 2>&1; do echo "aguardando o ArgoCD criar o Kafka..."; sleep 5; done
kx wait kafka/my-cluster -n kafka --for=condition=Ready --timeout=480s
kx -n argocd get applications
```

```text
NAME                    SYNC STATUS   HEALTH STATUS
demo-apps               Synced        Healthy
kafka                   Synced        Healthy
kube-prometheus-stack   Synced        Healthy
observability           Synced        Healthy
observability-root      Synced        Healthy
strimzi-operator        Synced        Healthy
tempo                   Synced        Healthy
```

*(O `kafka` pode aparecer `Progressing` enquanto o cluster sobe.)* Um broker por nó, graças ao
`podAntiAffinity` do `KafkaNodePool`:

```bash
kx -n kafka get pods -o wide | awk '{print $1, $2, $3, $7}'
```

```text
NAME                                         READY STATUS  NODE
my-cluster-dual-role-0                       1/1   Running strimzi-day10-worker3
my-cluster-dual-role-1                       1/1   Running strimzi-day10-worker2
my-cluster-dual-role-2                       1/1   Running strimzi-day10-worker
my-cluster-entity-operator-66d6858cdc-9thfn  2/2   Running strimzi-day10-worker2
my-cluster-kafka-exporter-674c8dfc8b-j8nq8   1/1   Running strimzi-day10-worker3
kafbat-ui-7d68588654-xnmmn                   1/1   Running strimzi-day10-worker
```

> O `order-producer` pode reiniciar **uma vez** nos primeiros minutos (`RESTARTS 1`): ele sobe
> antes de o Kafka estar pronto. É esperado — e é um bom momento para mostrar o `restarts` no
> dashboard do Kubernetes.

Confira que o Prometheus está raspando tudo. **Espere ~2 min** (armadilha nº 4 da seção 4.5):

```bash
sleep 120
curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job|test("kafka|strimzi|entity|order|cluster-operator|kube-state")) | "\(.health)\t\(.labels.job)"' | sort | uniq -c
```

```text
   4 up	demo/order-pipeline
   1 up	monitoring/cluster-operator-metrics
   2 up	monitoring/entity-operator-metrics
   4 up	monitoring/kafka-resources-metrics
   2 up	kube-state-metrics
```

## 8. Tour: Grafana, Prometheus, Alertmanager e ArgoCD

### 8.1 Grafana (<http://localhost:3000>, `admin` / `admin`)

Os dashboards foram provisionados por **ConfigMaps do Git**, em duas pastas:

```bash
curl -s -u admin:admin 'localhost:3000/api/search?type=dash-db' | jq -r '.[] | select(.folderTitle=="Strimzi" or .folderTitle=="Pipeline") | "\(.folderTitle)\t\(.title)"' | sort
```

```text
Pipeline	Order pipeline - end to end
Strimzi	Strimzi KRaft
Strimzi	Strimzi Kafka
Strimzi	Strimzi Kafka Exporter
Strimzi	Strimzi Operators
```

| Dashboard | Para quê | Origem |
|---|---|---|
| **Order pipeline - end to end** (`/d/e2e-pipeline`) | as 3 perguntas numa tela só: negócio → Kafka → traces | escrito para este Day (`grafana-dashboards/e2e-pipeline.json`) |
| **Strimzi Kafka** | brokers: tráfego, ISR, JVM, requisições | oficial Strimzi, variante *Metrics Reporter* |
| **Strimzi KRaft** | quorum, líder do controller, replicação de metadados | oficial Strimzi, variante *Metrics Reporter* |
| **Strimzi Kafka Exporter** | lag por consumer group, offsets por tópico | oficial Strimzi |
| **Strimzi Operators** | reconciliações do Cluster/Topic/User Operator | oficial Strimzi |

No `Order pipeline - end to end`, cada estatística diz de onde vem no *tooltip* (o ícone `ⓘ`):
as de cima são **métricas do app** + lag do Kafka Exporter; as de baixo são do **Metrics Reporter**,
do **kube-state-metrics nativo** e do **KSM dos CRs**. Na última linha, uma tabela TraceQL lista os
traces recentes (clique no *Trace ID* para abrir o waterfall).

Além dos nossos, o `kube-prometheus-stack` traz dashboards de Kubernetes
(*Compute Resources / Namespace (Pods)*, *Persistent Volumes*...) — úteis para ver CPU/memória dos
brokers e dos pods do pipeline sem escrever nada.

### 8.2 Prometheus (<http://localhost:9090>)

- **Status → Targets:** os `PodMonitor` viraram jobs (`monitoring/kafka-resources-metrics` etc.).
- **Alerts:** as 7 `PrometheusRule` (brokers, Kafka Exporter, operators, certificados, CRs do Strimzi e o pipeline), **todas inativas** num sistema saudável.
  O `Watchdog` (sempre disparando) é o alerta "o pipeline de alertas está vivo".
  *Pegadinha de laptop:* o alerta padrão `PrometheusMissingRuleEvaluations` pode aparecer como
  **Pending** no seu lab. Observado aqui: **todos** os grupos de regras o
  disparam — inclusive os embutidos do `kube-prometheus-stack` —, enquanto cada avaliação leva
  milissegundos. Isso aponta para a VM do Docker ficando sem CPU ou "dormindo" (o Mac em repouso),
  não para as regras do lab. *(Causa inferida, não isolada.)*
  Logo após o `bootstrap` também podem aparecer, *pending*, `PrometheusErrorSendingAlertsToAnyAlertmanager` (o
  Alertmanager ainda estava subindo) e `PrometheusDuplicateTimestamps` (medido: vem do `job` do próprio Prometheus, não dos
  alvos do Strimzi). Somem sozinhos; só o `Watchdog` deve ficar *firing*.
- **Graph:** consultas úteis para a conversa:

```promql
sum(kafka_server_replicamanager_underreplicatedpartitions)            # URP (Metrics Reporter)
sum by (consumergroup, topic) (kafka_consumergroup_lag)               # lag (Kafka Exporter)
strimzi_kafka_topic_resource_info                                      # status dos KafkaTopic (KSM dos CRs)
demo:end_to_end_latency_seconds:p95                                    # p95 de ponta a ponta (regra de gravação)
```

### 8.3 Alertmanager (<http://localhost:9093>) e o receiver de lab

O `AlertmanagerConfig` do repo encaminha **só** alertas com `team: kafka-platform` ao webhook de lab
(um `Deployment` de 20 linhas que imprime cada alerta). Para ver as notificações chegando:

```bash
kx -n monitoring logs deploy/alert-webhook -f
```

> Em produção a rota aponta para Slack/PagerDuty (exemplos comentados em
> `alert-manager-config.yaml`; o *secret* fica num `Secret`, nunca no Git).

### 8.4 Kafbat UI (<http://localhost:8088>): tópicos e mensagens

Dashboards mostram **números**; para **ver o conteúdo** — "o pedido `X` chegou ao tópico?", "qual o formato da
mensagem?" — o lab traz o **Kafbat UI** (o fork comunitário do antigo *UI for Apache Kafka*; é o mesmo do `kafka-ui.yaml`
do Day 7, agora **versionado e com imagem fixada** `v1.5.0`). Ele é um `Deployment` em
`gitops/manifests/kafka/kafbat-ui.yaml`, ligado ao listener `plain` do `my-cluster`, e o `kind` mapeia o NodePort 30080 para o
host. Sem login (só lab).

| Aba | O que ver no lab |
|---|---|
| **Brokers** | os 3 nós, partições líderes e réplicas |
| **Topics** | `orders` e `orders.processed` (6 partições, RF 3); abra um tópico → **Messages**: as mensagens chegando (offset, partição, chave, valor JSON), com busca e filtro |
| **Consumers** | `order-processor` e `order-sink`: membros, estado e a coluna **Consumer Lag** — compare com o painel de lag do Grafana (é a mesma informação, vista de outro ângulo) |
| botão **Produce Message** (dentro do tópico) | publica uma mensagem à mão (útil para testar um consumidor) |

Conferido no lab (API e navegador): o cluster aparece `ONLINE` com 3 brokers, os dois tópicos listam as
mensagens recentes (com chave `c1`..`c20` e o JSON do pedido), e `Consumers` lista os dois grupos com o lag.
Publicar pela API do UI (`POST /api/clusters/my-cluster/topics/orders/messages`) retornou `200`.

> **Quando usar o quê:** Grafana/Prometheus respondem *"está bom? está piorando?"*; o Kafbat UI responde *"o que
> exatamente está lá dentro?"*; o Tempo responde *"por onde passou **esta** mensagem?"*. Em produção, ponha o UI atrás de
> SSO e use um `KafkaUser` **somente-leitura** (Day 4); com SCRAM/TLS ele precisa das propriedades `SASL`/`SSL` do cluster
> (veja `Examples/kafka-ui.yaml`) — **não testado aqui**, o lab usa o listener sem autenticação.

## 9. Cenários na prática

Os cenários A, C, D e E mexem no **Git**, não no cluster: é a metodologia. **No terminal 2**, deixe
o Git local acessível (é por aqui que o seu `git push` chega ao servidor dentro do cluster):

```bash
: TERMINAL 2 — deixe este comando rodando
kubectl --context kind-strimzi-day10 -n git port-forward svc/git-server 18080:80
```

No terminal principal, entre no clone de trabalho e defina um atalho para o `git` com identidade de lab.
Os comandos abaixo **não dependem da pasta em que você está** (só de estar dentro do repositório) e, se o clone de
trabalho ainda não existe, o criam rodando o `lab/push-repo.sh` (seção 7.3). Atenção: `lab/work/` é **local de cada
cópia do repositório** (está no `.gitignore`) — se você trocou de pasta/branch/worktree, rode o `push-repo.sh` de novo:

```bash
D10="$(git rev-parse --show-toplevel)/kafka-strimzi/Day10-Observabilidade"   # raiz do Day 10, de qualquer pasta do repo
kx() { kubectl --context kind-strimzi-day10 "$@"; }                           # (necessário se este é um terminal novo)
[ -d "$D10/lab/work/observability" ] || "$D10/lab/push-repo.sh"                # o clone de trabalho nasce do push-repo.sh (seção 7.3); precisa do cluster no ar
cd "$D10/lab/work/observability"
lg() { git -c user.name=lab -c user.email=lab@example.com "$@"; }
```

> **Por que `kubectl edit` não funciona aqui:** o ArgoCD roda com `selfHeal: true` — qualquer
> mudança manual é revertida na próxima reconciliação (~30 s). Mudar o sistema = `git commit`.

### Cenário A — Um consumidor lento (via Git): lag, latência e alerta

O processor passa a gastar 400 ms por mensagem enquanto o producer manda 5/s. Ele só consegue
processar 2,5/s: o lag cresce. Só o *Git* muda:

```bash
sed -i.bak 's/name: PROCESS_MS, value: "30"/name: PROCESS_MS, value: "400"/' manifests/demo-apps/apps.yaml && rm manifests/demo-apps/apps.yaml.bak
lg diff --stat
lg commit -qam "perf: processor 400ms per message (simulating a slow downstream)"
lg push -q origin main
```

Abra o dashboard **Order pipeline - end to end**
(<http://localhost:3000/d/e2e-pipeline>). Em poucos minutos:

- *Throughput by stage*: a linha do `sink` e a do `processor` descolam da do `producer`;
- *Consumer-group lag*: sobe linearmente (`order-processor` em `orders`);
- *Time spent processing*: o p95 do `processor` salta para ~800 ms;
- *End-to-end latency*: p50/p95/p99 sobem (cada mensagem espera em fila no tópico).

Alertas (medido neste lab: o de latência após ~4 min e o de lag logo em seguida — a espera é o
`for:` + a janela de 2 min da regra):

```bash
kx -n monitoring logs deploy/alert-webhook --tail=5
```

```text
[FIRING  ] warning  OrderPipelineEndToEndLatencyHigh: p95 end-to-end latency is 105.2s (SLO: 2s)
[FIRING  ] warning  KafkaConsumerGroupLagHigh: Group order-processor is 667 messages behind on orders
```

**Reverter também é um commit** — e fecha o ciclo com `RESOLVED`:

```bash
lg revert --no-edit HEAD >/dev/null && lg push -q origin main
```

```text
[RESOLVED] warning  KafkaConsumerGroupLagHigh: Group order-processor is 886 messages behind on orders
[RESOLVED] warning  OrderPipelineEndToEndLatencyHigh: p95 end-to-end latency is 120.0s (SLO: 2s)
```

> **O que mostrar:** nenhuma métrica de *broker* se moveu. Todos os painéis da seção
> "O Kafka está saudável?" continuam verdes. Foi o **produto** que degradou — e só as métricas de
> negócio + lag viram isso.

### Cenário B — Perder um broker (um nó do Kubernetes)

Matar o pod do broker **não** serve de demo: o Strimzi o recria em segundos e a janela de
sub-replicação é curta demais para o alerta (testado: `kafka_server_replicamanager_underreplicatedpartitions`
chegou a somar 27 durante o restart, mas o alerta **não disparou** — o `for: 30s` mais o intervalo de
coleta de 30 s não o enxergam — e **é assim que deve ser**: um restart rápido não deve acordar ninguém). Para uma falha *de verdade* — como a perda de um nó —
cordone o nó do broker 1 (os volumes `local-path` ficam presos ao nó, então o pod não consegue ir
para outro lugar) e apague o pod. Graças ao `podAntiAffinity`, esse nó só tem **esse** broker:

```bash
cd "$D10"        # volta para Day10-Observabilidade
NODE=$(kx -n kafka get pod my-cluster-dual-role-1 -o jsonpath='{.spec.nodeName}'); echo "NODE=$NODE"
kx cordon $NODE
kx -n kafka delete pod my-cluster-dual-role-1 --wait=false
```

Com 2 de 3 nós vivos, o quorum KRaft e o `min.insync.replicas=2` sobrevivem — o pipeline continua
funcionando, porém **sem folga**. Em ~2 min:

```bash
kx -n kafka get pods | grep dual-role
curl -s -G localhost:9090/api/v1/query --data-urlencode 'query=ALERTS{alertstate=~"firing|pending",team="kafka-platform"}' | jq -r '.data.result[] | "\(.metric.alertstate)\t\(.metric.alertname)\t\(.metric.severity)\t\(.metric.topic // "")"' | sort | uniq -c
```

```text
my-cluster-dual-role-0   1/1   Running   0   7m27s
my-cluster-dual-role-1   0/1   Pending   0   118s
my-cluster-dual-role-2   1/1   Running   0   7m27s

   2 firing	KafkaUnderReplicatedPartitions	warning
   1 pending	KafkaNotReady	warning
   1 pending	KafkaExporterTopicUnderReplicated	warning	__consumer_offsets
   1 pending	KafkaExporterTopicUnderReplicated	warning	orders
   1 pending	KafkaExporterTopicUnderReplicated	warning	orders.processed
```

Olhe o dashboard **Strimzi Kafka** (*Brokers Online* cai para 2, *Under Replicated Partitions*
sobe) e o **Order pipeline** (a linha "Kafka pods Ready" vira 2). **Recupere:**

```bash
kx uncordon $NODE
kx -n kafka wait pod/my-cluster-dual-role-1 --for=condition=Ready --timeout=300s
```

> **Uma lição que o lab ensinou na prática:** na primeira versão, o alerta do Kafka Exporter era
> **por partição** — um broker fora gerou **60 alertas** para uma causa só. Foi corrigido para
> uma agregação por tópico (`sum by (topic) (...)`, e há um teste unitário que prova que 3 partições
> sub-replicadas dão **1** alerta). Alerta que dispara 60 vezes por uma causa treina o plantonista
> a ignorar o pager.

### Cenário C — Um `KafkaTopic` inválido: o ArgoCD diz "Synced", o Kafka diz "não"

Um PR "inocente" cria um tópico com `replicas: 5` num cluster de 3 brokers:

```bash
cd "$D10/lab/work/observability"
cat >> manifests/kafka/topics.yaml <<'EOF'
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: orders.audit
  labels:
    strimzi.io/cluster: my-cluster
spec:
  partitions: 3
  replicas: 5            # a 3-broker cluster cannot place 5 replicas
EOF
lg commit -qam "feat: add orders.audit topic" && lg push -q origin main
```

O YAML é válido, o Git aceita, o ArgoCD **sincroniza**. Mas:

```bash
kx -n kafka get kafkatopic
kx -n kafka get kafkatopic orders.audit -o jsonpath='{.status.conditions[0].type}={.status.conditions[0].status} {.status.conditions[0].reason}{"\n"}{.status.conditions[0].message}{"\n"}'
kx -n argocd get app kafka
```

```text
NAME               CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
orders             my-cluster   6            3                    True
orders.audit       my-cluster   3            5                    False
orders.processed   my-cluster   6            3                    True

Ready=False KafkaError
org.apache.kafka.common.errors.InvalidReplicationFactorException: Unable to replicate the partition 5 time(s): The target replication factor of 5 cannot be reached because only 3 broker(s) are registered or some brokers have all their log directories cordoned.

NAME    SYNC STATUS   HEALTH STATUS
kafka   Synced        Progressing
```

O ArgoCD marca `Synced` (o YAML *foi* aplicado) e `Progressing` — **e fica assim para sempre,
sem acordar ninguém.** Quem acorda é o **KSM dos CRs**:

```text
[FIRING  ] warning  KafkaTopicNotReady: Strimzi KafkaTopic orders.audit is not ready
```

(~2,5 min: sync do ArgoCD + `for: 1m`.) A métrica que gerou o alerta, para mostrar ao vivo:

```promql
strimzi_kafka_topic_resource_info{ready!="True"}
```

> **A moral:** "Git ok + ArgoCD ok" não significa "Kafka ok". O Day 8 mostrou que o Topic
> Operator **recusa** o que não consegue fazer; este Day mostra **como você fica sabendo**.
> Limpe: `lg revert --no-edit HEAD >/dev/null && lg push -q origin main`.

### Cenário D — Erros no processamento e o trace que aponta o culpado

30% dos pedidos passam a falhar na validação:

```bash
sed -i.bak 's/name: ERROR_RATE, value: "0"/name: ERROR_RATE, value: "0.3"/' manifests/demo-apps/apps.yaml && rm manifests/demo-apps/apps.yaml.bak
lg commit -qam "test: 30% of orders fail validation" && lg push -q origin main
```

Em ~4 min dispara `OrderPipelineProcessingErrors` (taxa de erro > 5%). Agora a pergunta
nº 3 — *quais* pedidos falharam? No **Grafana → Explore → Tempo** (ou pela API), o TraceQL
`status = error` encontra os traces com span de erro:

```text
{ status = error }
```

Cada span de erro traz o evento `order rejected` e o `order.id` — dá para ir do alerta (agregado) ao
pedido específico (individual). Limpe: `lg revert --no-edit HEAD >/dev/null && lg push -q origin main`.

### Cenário E — Um PR de alerta, com CI

A regra de ouro: **toda vez que criar ou mexer num alerta, escreva/atualize um teste.** Veja o
que o CI pega, localmente (a partir de `Day10-Observabilidade/gitops`):

```bash
cd "$D10/gitops" && ci/validate.sh
```

```text
== 1. kustomize build
   OK (...)
== 3. promtool check rules
Checking /w/rules.yml
  SUCCESS: 48 rules found

== 4. promtool test rules (unit tests)
Processing test file: /w/rules_test.yml
  SUCCESS

ALL GOOD
```

**Caso 1 — erro de sintaxe** (um parêntese esquecido no PR) é barrado antes de chegar ao Prometheus:

```text
== 3. promtool check rules
Checking /w/rules.yml
  FAILED:
/w/rules.yml: 122:11: group "kafka-exporter", rule 1, "KafkaConsumerGroupLagHigh": could not parse expression: 1:30: parse error: unexpected "(" in grouping opts, expected "," or ")"
```

**Caso 2 — PromQL válido, comportamento alterado.** Alguém sobe o limite de lag de `500` para
`50000` "para parar de incomodar". Sintaxe ok; **o teste unitário reprova**, porque o cenário
"lag de 1400 mensagens deve alertar" deixou de ser verdade:

```text
  FAILED:
    name: consumer lag is summed per group and topic (ONE alert, not one per partition),
    alertname: KafkaConsumerGroupLagHigh, time: 2m,
        exp:[ 0: Labels:{alertname="KafkaConsumerGroupLagHigh", consumergroup="order-processor", ...} ],
        got:[]
```

Para mudar o limite *de propósito*, o PR precisa mudar o teste junto — e o `CODEOWNERS` pede
revisão de quem é acordado pelo alerta. É o que impede o "alerta silenciado por acidente".

## 10. Tracing de ponta a ponta

### 10.1 O que o lab entrega

Cada pedido gera **um trace, em três serviços e dois tópicos**. Estrutura real de um trace (saída da
API do Tempo; tempos relativos ao primeiro span):

```text
+    0ms dur=   0ms  order-producer   create order                   INTERNAL   (raiz)
+    0ms dur=   0ms  order-producer   orders send                    PRODUCER
+   24ms dur=  41ms  order-processor  orders process                 CONSUMER
+   24ms dur=  41ms  order-processor  validate and enrich order      INTERNAL
+   65ms dur=   0ms  order-processor  orders.processed send          PRODUCER
+   88ms dur=  13ms  order-sink       orders.processed process       CONSUMER
+   88ms dur=  13ms  order-sink       send notification              INTERNAL
```

Como ler: a **lacuna** entre o fim de `orders send` (0 ms) e o início de `orders process` (24 ms) é o
**tempo que a mensagem passou no tópico** (replicação + espera pelo consumer). Um span longo é
trabalho do *app*; uma lacuna longa é *fila* (lag). No cenário A, essa lacuna vira **minutos**.

### 10.2 Como o contexto atravessa o Kafka

O padrão W3C `traceparent` viaja **nos headers do registro Kafka** (é metadado da mensagem, não
do payload):

1. **Producer:** a instrumentação OpenTelemetry cria o span `send` e **injeta** `traceparent`
   nos headers (`instrument_producer`).
2. **Consumer:** lê os headers, **extrai** o contexto e abre o span `process` **como filho** do
   `send` (a função `process_span` em `lab/app/app.py`).
3. **Hop seguinte:** o processor faz `produce()` **dentro** do span `process` — a instrumentação
   injeta o contexto *atual* e o próximo serviço continua o mesmo trace.

```python
def process_span(msg):
    headers = {k: v.decode() for k, v in (msg.headers() or []) if isinstance(v, bytes)}
    return tracer.start_as_current_span(
        f"{msg.topic()} process", context=propagate.extract(headers), kind=SpanKind.CONSUMER, ...)
```

> **Pegadinha que o lab encontrou:** a instrumentação de *consumer* pronta do OpenTelemetry para o
> `confluent-kafka` (`instrument_consumer`) **não continua o trace do producer** — ela cria um trace
> novo por mensagem e apenas **liga** os dois com um *span link* (modelo de "batch" da convenção
> semântica de mensageria). Resultado no Tempo: traces soltos, em vez de uma história. Por isso o
> consumer extrai o contexto **à mão** (a função acima), o que também é a melhor forma de explicar a
> propagação no vídeo. (Links são úteis para *batches* — um poll com 500 mensagens — mas o
> objetivo aqui é "siga *esta* mensagem".)

### 10.3 Consultando no Grafana (Explore → Tempo)

```text
{ resource.service.name = "order-producer" }                     # todos os pedidos
{ status = error }                                                # só os que falharam
{ resource.service.name = "order-sink" && duration > 2s }         # chegaram ao fim, mas devagar
```

### 10.4 O que o broker **não** mostra no trace

O Kafka em si **não emite spans**: no waterfall, o broker é a lacuna entre `send` e `process`. Isso
é inerente ao Kafka, não ao lab. O Strimzi documenta tracing com OpenTelemetry para
**Kafka Connect, MirrorMaker 2 e Kafka Bridge** (não exercitado neste lab — seção 12). Para
aplicações **Java**, o *agent* do OpenTelemetry instrumenta o `kafka-clients` sem mudar código
(também não exercitado aqui).

## 11. Indo para produção

| Lab | Produção |
|---|---|
| Prometheus único, retenção de 6 h, sem disco | HA (2 réplicas) + **armazenamento de longo prazo** (Thanos / Mimir / remote_write); dimensione retenção e cardinalidade |
| Métricas *por partição* do Kafka Exporter | cuidado com **cardinalidade**: tópicos × partições × grupos explode a série; use `topicRegex`/`groupRegex` para limitar |
| Alertmanager único + webhook de lab | HA + receivers reais (Slack/PagerDuty); *secrets* em `Secret`, **inibições** e silenciamentos como código |
| `for: 30s–1m` nos alertas (para o lab reagir rápido) | `for: 5m+` em tudo que se cura sozinho (rolling restart gera URP por ~1 min: normal); alerte em **sintoma** (lag, latência, erro), use causa (disco, ISR) como *warning* |
| Tempo single-binary, sem persistência, 100% de amostragem | `tempo-distributed` ou Grafana Cloud, **object storage**, **OpenTelemetry Collector** no meio (amostragem *tail-based* para guardar 100% dos erros e uma fração do resto) |
| Grafana `admin/admin`, listeners do Kafka em texto plano | SSO, TLS/SCRAM (Day 4) — **e o scraping** precisa conhecer isso; `NetworkPolicy` para `/metrics` |
| `kubelet_volume_stats` ausente (kind) | alerta de disco (`KafkaRunningOutOfDisk`) funciona em cluster real com CSI — **ative-o** |
| AppProject permissivo (`*`) | restrinja `sourceRepos`, `destinations` e o que o projeto pode criar (comentado em `appproject.yaml`) |

Mais três decisões que valem uma conversa:

- **SLO em vez de limite.** O `2s` do alerta de latência é um SLO de exemplo. Em produção,
  defina o SLO com o produto e alerte por *burn rate* — o que a estrutura deste Day (regra de
  gravação `demo:end_to_end_latency_seconds:p95`) já deixa pronto para evoluir.
- **Dashboards são código, mas quem edita pela UI?** O sidecar sobrescreve a cada sync; trate a
  UI como rascunho (exporte o JSON e abra um PR).
- **Observabilidade é parte do Definition of Done do serviço.** O `PodMonitor` junto do
  `Deployment` é essa ideia em forma de arquivo.

## 12. O que este lab NÃO cobre (honestamente)

- **O workflow do GitHub Actions não foi executado** (não há GitHub neste ambiente). O mesmo
  `ci/validate.sh` que ele chama **foi executado localmente** (sucesso e as duas falhas do
  cenário E). O que falta validar no seu GitHub: permissões, disparo dos checks, *branch protection*
  com Code Owners.
- **Receivers reais (Slack, PagerDuty, e-mail)** não foram testados — só o webhook de lab. A rota e
  os exemplos comentados existem, mas o envio real, não.
- **Tracing no Kafka Connect, MirrorMaker 2 e Kafka Bridge** (suportado pelo Strimzi) e o **agent
  Java** do OpenTelemetry **não foram exercitados**: o app de exemplo é Python. Os outros
  componentes do Strimzi (Connect, MM2, Bridge) também **não** têm métricas ligadas neste lab.
- **O `jmxPrometheusExporter` não foi implantado** — só descrito na seção 3 (o lab usa o Metrics
  Reporter). O *allowlist* de métricas do Metrics Reporter (`metricsConfig.values.allowList`) também
  não foi exercitado: o lab usa o conjunto padrão.
- **A regra oficial `CertificateExpiration`** está no lab mas **não foi exercitada** (os certificados são novos).
- **Os arquivos `prometheus-install/prometheus.yaml`, `alert-manager.yaml`, `prometheus-additional-properties/` e `grafana-install/grafana.yaml` do Strimzi não foram usados** — o `kube-prometheus-stack` os substitui (seção 4.0); o caminho 100% da doc não foi testado.
- **Cruise Control** (Day 6/7): suas métricas e o dashboard `strimzi-cruise-control.json` não foram
  ligados aqui.
- **`kubelet_volume_stats_*` não existe no kind** (armadilha 5): o alerta e o painel de espaço em PVC
  **não foram exercitados** — a regra existe, mas só valide num cluster real.
- **Multi-cluster/multi-região** não foi montado (um Prometheus, um Kafka). Federação ou
  `remote_write` por região fica fora deste Day.
- **Sem TLS/autenticação** no Kafka, no Tempo, no Grafana e no Git do lab. Nada daqui é
  configuração de produção.
- **Tempo e memória:** com tráfego contínuo (~5 traces/s, 100% de amostragem) o Tempo single-binary chegou ao limite de 768Mi e foi `OOMKilled` (5 restarts em 25h) — sintoma: o Grafana mostrava `connection refused` na porta 3200. O lab agora usa limite de 1536Mi e retenção de 6 h; deixe o lab ligado por dias e **acompanhe** `kube_pod_container_status_last_terminated_reason`. Em produção, dimensione o Tempo (ou use `tempo-distributed`) e reduza a amostragem.
- **Os tempos** (~4 min para um alerta, ~2 min para o Prometheus achar um `PodMonitor`) foram medidos
  num Docker Desktop (Apple Silicon); no seu ambiente variam.

## 13. Cleanup

```bash
kind delete cluster --name strimzi-day10
pkill -f "port-forward svc/git-server" 2>/dev/null
pkill -f "port-forward svc/argocd-server" 2>/dev/null
rm -rf lab/work lab/app/__pycache__
docker rmi kafka-e2e-demo:0.1.0 2>/dev/null
```

## 14. Roteiro sugerido para o vídeo

Duração-alvo: **~25 min**. O fio condutor são as três perguntas da seção 1; mostre-as cedo e volte a elas.

| Tempo | Bloco | O que mostrar |
|---|---|---|
| 0:00 | Gancho | "Todos os painéis do Kafka estão verdes e o cliente não recebeu a notificação. Como você descobre?" |
| 1:30 | As 3 perguntas | Seção 1; a arquitetura (seção 2) |
| 3:30 | De onde vêm as métricas | Tabela da seção 3: **6 fontes**, por que o Kafka Exporter e o KSM dos CRs existem |
| 6:00 | GitOps ao vivo | `kx -n argocd get applications`; abrir `apps/` e `manifests/observability/`; "nenhum arquivo do Prometheus foi editado" |
| 8:30 | Tour do Grafana + Kafbat UI | O dashboard end-to-end de cima para baixo; depois *Strimzi Kafka*; e o **Kafbat UI** para ver as mensagens e o lag dos grupos |
| 11:00 | **Cenário A** | Commit que deixa o processor lento → lag, latência, alerta no webhook → `git revert` → `RESOLVED` |
| 15:00 | **Cenário C** | PR com `replicas: 5` → ArgoCD "Synced" mas tópico `Ready=False` → alerta do KSM. "Git ok ≠ Kafka ok" |
| 18:00 | **Tracing** | Abrir o trace de um pedido: 3 serviços, 2 tópicos; a lacuna = tempo no tópico; mostrar `process_span` e o header `traceparent` |
| 21:00 | **Cenário D** | `{ status = error }` no Tempo: do alerta agregado ao pedido individual |
| 22:30 | Cenário B (rápido) | Cordon do nó → URP → "restart rápido não deve acordar ninguém" (e os 60 alertas por partição) |
| 24:00 | Cenário E + fechamento | `ci/validate.sh` reprovando um PR de alerta; checklist da seção 11; teaser do Day 11 (acesso externo) |

## 15. Referências

- Strimzi — [documentação oficial (Deploying and Managing)](https://strimzi.io/docs/operators/latest/deploying), capítulos *Introducing Metrics* e *Distributed tracing*, e os
  [exemplos oficiais](https://github.com/strimzi/strimzi-kafka-operator/tree/1.1.0/examples/metrics)
  (`strimzi-metrics-reporter/`, `kube-state-metrics/`, `prometheus-install/`) — os dashboards, o KSM e as regras deste lab partem deles
- [Prometheus Operator](https://prometheus-operator.dev/) — `PodMonitor`, `PrometheusRule`, `AlertmanagerConfig`
- [`promtool test rules`](https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/) — testes unitários de alertas
- [kube-state-metrics](https://github.com/kubernetes/kube-state-metrics) (modo *Custom Resource State*)
- [kube-prometheus-stack (chart)](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Grafana Tempo](https://grafana.com/docs/tempo/latest/) e [TraceQL](https://grafana.com/docs/tempo/latest/traceql/)
- [OpenTelemetry — convenções semânticas de mensageria](https://opentelemetry.io/docs/specs/semconv/messaging/) e [propagação de contexto (W3C Trace Context)](https://www.w3.org/TR/trace-context/)
- [Argo CD — App of Apps e Sync Waves](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [Kafbat UI](https://github.com/kafbat/kafka-ui) — a UI de tópicos e mensagens (fork do *UI for Apache Kafka*)
- [Day 8 — Topic e User Operator](../Day8-TopicUserOperators/) e [Day 9 — GitOps multi-time](../Day9-GitOps-MultiTime/) (o servidor Git de lab e o `selfHeal` vêm de lá)
