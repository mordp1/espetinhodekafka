# Acesso Externo ao Kafka no Kubernetes — Listeners, Gateway API, DNS e Certificados (Strimzi)

> **Objetivo:** responder à pergunta que mais trava quem leva o Kafka para o Kubernetes: **"como
> um cliente que está *fora* do cluster consegue falar com o Kafka — com DNS, TLS e
> autenticação que eu controlo?"** O Day tem duas partes. **Parte 1:** como o acesso externo
> funciona de verdade (por que "conecta no bootstrap e depois dá timeout"), os tipos de listener do
> Strimzi, qual escolher e por que **não** recomendamos Istio. **Parte 2:** um **lab completo que
> simula produção**: PKI própria (CA raiz autoassinada com cert-manager), **DNS** da máquina local e
> do cluster, **Gateway API com TLS passthrough** (Envoy Gateway) e o listener `tlsroute` do Strimzi,
> **mTLS por time** com ACLs e **distribuição da CA e das credenciais aos times** (trust-manager).
> Todo cenário foi executado de ponta a ponta num kind (Strimzi 1.3.1, Kafka 4.3.2, Kubernetes
> 1.34, cert-manager 1.21.3, trust-manager 0.26.0, Envoy Gateway 1.10.0) — as saídas mostradas são
> reais. O que **não** foi executado está listado, sem rodeios, na seção 12.
>
> **Este README é também o roteiro de execução:** os blocos `bash` da Parte 2 rodam em ordem,
> copiando e colando, e foram validados do zero num kind limpo.

---

## Índice

**Parte 1 — Como o acesso externo funciona**
1. [O problema: dois "endereços" e uma conexão que parece funcionar](#1-o-problema-dois-endereços-e-uma-conexão-que-parece-funcionar)
2. [Os tipos de listener do Strimzi 1.3.1](#2-os-tipos-de-listener-do-strimzi-131)
3. [Qual escolher (e o Istio, o Router do OpenShift...)](#3-qual-escolher-e-o-istio-o-router-do-openshift)
4. [Certificados: três cadeias de confiança](#4-certificados-três-cadeias-de-confiança)

**Parte 2 — O lab**
5. [Arquitetura e pré-requisitos](#5-arquitetura-e-pré-requisitos)
6. [Estrutura do lab](#6-estrutura-do-lab)
7. [Passo a passo](#7-passo-a-passo)
8. [Cenários de falha (todos executados)](#8-cenários-de-falha-todos-executados)
9. [Indo para produção](#9-indo-para-produção)
10. [Armadilhas que o lab encontrou](#10-armadilhas-que-o-lab-encontrou)
11. [Roteiro sugerido para o vídeo](#11-roteiro-sugerido-para-o-vídeo)
12. [O que este lab NÃO cobre (honestamente)](#12-o-que-este-lab-não-cobre-honestamente)
13. [Cleanup](#13-cleanup)
14. [Referências](#14-referências)

---

# Parte 1 — Como o acesso externo funciona

## 1. O problema: dois "endereços" e uma conexão que parece funcionar

Um cliente Kafka **não** fala com "o cluster": ele fala com **brokers específicos**. A conexão acontece
em duas etapas:

```text
   cliente                          bootstrap                         brokers
      │  1. conecta em bootstrap:9094        │
      ├─────────────────────────────────────►│
      │  2. "me dê os metadados"             │
      │◄─────────────────────────────────────┤  resposta: broker 0 = ADDR0, broker 1 = ADDR1, broker 2 = ADDR2
      │  3. conecta no LÍDER de cada partição, usando os endereços da resposta (advertised.listeners)
      ├────────────────────────────────────────────────────────────────────────►│  ADDR0 / ADDR1 / ADDR2
```

O endereço de bootstrap **só serve para a etapa 1**. A partir da etapa 3 o cliente usa o que o
**broker anunciou** (`advertised.listeners`). Por isso o erro mais clássico de acesso externo é:

> *"O bootstrap conecta, `kafka-topics --list` funciona, mas produzir/consumir dá timeout."*

Quase sempre o broker está anunciando um endereço que **só existe dentro do cluster** (ou um IP de
nó que o cliente não alcança). Acesso externo, portanto, exige **um endereço por broker + um de
bootstrap**, todos **resolvíveis (DNS)**, **alcançáveis (rede)** e — se houver TLS — **presentes no
certificado (SAN)**. São três problemas independentes; o lab trata cada um (e os faz falhar de
propósito na seção 8).

## 2. Os tipos de listener do Strimzi 1.3.1

Valores aceitos em `spec.kafka.listeners[].type` (lidos do CRD do operator desta versão):

| Tipo | O que o Strimzi cria | Endereço que o cliente usa | Observação |
|---|---|---|---|
| `internal` | só o Service headless/bootstrap | `my-cluster-kafka-bootstrap.kafka.svc:9092` | só dentro do cluster (Days 1–10) |
| `cluster-ip` | **um `ClusterIP` por broker** | o que **você** colocar na frente (Gateway/proxy) | peça de montagem: para quem expõe com solução própria |
| `nodeport` | um `NodePort` por broker + bootstrap | IP/DNS **dos nós** + porta alta | simples, mas exige nós alcançáveis e portas altas; é onde nasce o erro da seção 8 (A) |
| `loadbalancer` | **um `LoadBalancer` por broker + um de bootstrap** | IP/DNS de cada LB | o padrão em cloud; **N+1 load balancers** (custo e cota), cada um com sua porta |
| `ingress` | `Ingress` por broker (NGINX, TLS passthrough) | `bootstrap.example.com:443` | **deprecated** no 1.3.1 (o CRD diz isso); depende do NGINX Ingress |
| `tlsroute` | **um `TLSRoute` (Gateway API v1) + `ClusterIP` por broker** | `bootstrap.example.com:443` | **o caminho moderno** — usado neste lab |
| `route` | `Route` do OpenShift (passthrough) | hostname do **Router** do OpenShift, porta 443 | só em OpenShift; mesma ideia do `tlsroute` |

**O truque do `ingress`/`tlsroute`/`route`:** os três usam **uma única porta (443) e um único IP**.
O proxy lê o **SNI** (o nome do servidor, enviado em claro no início do handshake TLS) e encaminha o
fluxo *criptografado* para o broker certo. Por isso cada broker precisa de **um nome DNS próprio**
(`broker-0.…`, `broker-1.…`) e o listener **precisa ter `tls: true`**: sem TLS não existe SNI.

No Strimzi 1.3.1 o CRD descreve `ingress` como *deprecated*, e o projeto NGINX Ingress Controller foi
anunciado como aposentado — o `tlsroute` (Gateway API) é o sucessor natural. É o que o lab usa.

```text
                     laptop / time externo                          cluster
  bootstrap.kafka.lab.test ─┐
  broker-0.kafka.lab.test  ─┤  DNS → mesmo IP     ┌──────────────┐  TLS passthrough (SNI)   ┌──────────────┐
  broker-1.kafka.lab.test  ─┼─────────:443───────►│ Gateway      ├─────────────────────────►│ broker 0/1/2 │
  broker-2.kafka.lab.test  ─┘                     │ (Envoy)      │  1 TLSRoute por nome     │  (termina TLS)│
                                                  └──────────────┘                          └──────────────┘
```

## 3. Qual escolher (e o Istio, o Router do OpenShift...)

| Situação | Escolha | Por quê |
|---|---|---|
| Só apps no mesmo cluster | `internal` | nada a expor |
| Clientes externos, cluster com **Gateway API** (ou dá para instalar) | **`tlsroute`** | um IP/porta, nomes por broker, TLS de ponta a ponta, mTLS funciona |
| Cloud, sem Gateway API, poucos brokers | `loadbalancer` | simples; cuidado com o custo de N+1 LBs |
| **OpenShift** | `route` | o **Router do OpenShift** faz o papel do Gateway: o Strimzi cria os `Route`s com passthrough e o hostname vem do Router (porta 443). Mesma lógica do `tlsroute`; **não exercitado neste lab** (seção 12) |
| Ambiente de desenvolvimento / kind sem proxy | `nodeport` | funciona, mas veja a armadilha da seção 8 (A) |
| Já usa um proxy/malha própria | `cluster-ip` | o Strimzi só entrega os Services; o roteamento é seu |

### E o Istio?

**Não recomendamos colocar o Kafka (nem o acesso externo a ele) numa malha Istio.** Duas discussões do
projeto Strimzi mostram o que acontece, e vale ler as duas:

- [#11869](https://github.com/orgs/strimzi/discussions/11869): depois de atualizar o operator para a 0.47.0, o
  `CruiseControlMetricsReporter` não conectava nos brokers com os sidecars do Istio. Resposta dos
  mantenedores: **o Strimzi não suporta Istio e não há plano**; a malha também não entende o protocolo Kafka
  (então "TLS dentro de TLS" e nenhum ganho de roteamento).
- [#12200](https://github.com/orgs/strimzi/discussions/12200) (aberta por nós): com Istio + Cilium, o *metrics
  reporter* do Cruise Control usa o Service headless `<cluster>-kafka-brokers:9091`, que em KRaft inclui os
  **controllers**; o sidecar redirecionava as conexões para pods que não escutam nessa porta (e capturava o
  DNS), e a autenticação TLS/SASL falhava em loop. O mantenedor respondeu: *"o Strimzi não suporta Istio…
  o conselho geral é evitá-lo"*.

O que funcionou em quem insiste em usar a malha (relatado nas discussões; **não reproduzido neste lab**):
desligar a injeção nos pods do Kafka (`sidecar.istio.io/inject: "false"` no `template.pod.metadata.annotations`
do `KafkaNodePool`), ou excluir as portas inter-broker (`traffic.sidecar.istio.io/excludeInboundPorts` /
`excludeOutboundPorts`) e desligar a captura de DNS (`ISTIO_META_DNS_CAPTURE: "false"`). Repare que **todas**
as soluções são "tirar o Kafka da malha": o Kafka já tem TLS, autenticação e ACL no próprio protocolo.

## 4. Certificados: três cadeias de confiança

O acesso externo com TLS junta **três** coisas diferentes que as pessoas costumam misturar:

| # | O quê | Quem emite | Quem confia nela | Neste lab |
|---|---|---|---|---|
| 1 | **Cluster CA** do Strimzi | o próprio Strimzi (gerada, renovada sozinha) | os brokers entre si e listeners internos | `my-cluster-cluster-ca-cert` — **não** a entregamos a ninguém |
| 2 | **Clients CA** do Strimzi | o próprio Strimzi | os **brokers**, para validar o certificado de cada **cliente** (mTLS) | assina o certificado de cada `KafkaUser` |
| 3 | **Certificado do listener** (o que o cliente vê no handshake) | **a sua PKI** (aqui: cert-manager) | os **clientes**, para validar o broker | `kafka-external-tls`, assinado pela *Lab Root CA* |

Por que não usar a Cluster CA no listener externo? Porque você teria de distribuir **a CA interna do
Strimzi** (que é renovada periodicamente) a todos os times, e porque em empresas o time de segurança quer
certificados da **CA corporativa**. O Strimzi permite trocar só o certificado de um listener com
`brokerCertChainAndKey` (um `Secret` com `tls.crt` e `tls.key`).

Regras que o lab confirmou (cada uma tem cenário na seção 8):

- **Todo nome que o cliente usa precisa estar no SAN** do certificado (bootstrap *e* cada broker).
  O cliente Java valida o hostname (cenário B).
- A chave privada precisa ser **PKCS#8** (`BEGIN PRIVATE KEY`). O padrão do cert-manager (PKCS#1) derruba
  o broker (cenário C).
- Com **TLS passthrough** o Gateway **não** vê o certificado: quem termina o TLS é o broker. Por isso
  mTLS e o seu certificado funcionam. (Com *terminate* no Gateway, o mTLS com o broker deixa de existir.)
- O que os times precisam confiar é **só a CA raiz pública** — nunca uma chave privada.

---

# Parte 2 — O lab

## 5. Arquitetura e pré-requisitos

```text
 ┌─────────────────────────── seu laptop ───────────────────────────┐
 │  kafka-client.sh / kafka-*.sh   (nomes *.kafka.lab.test via DNS) │
 │   DNS local: dnsmasq :5354 → 127.0.0.1   (ou /etc/hosts)         │
 └───────────────────────────────┬──────────────────────────────────┘
                          :443  (kind extraPortMappings → NodePort 30443)
 ┌───────────────────────────────▼──────── kind: strimzi-day11 (1 control-plane + 3 workers) ─────────────┐
 │  Envoy Gateway ── Gateway "kafka-gateway" (TLS passthrough, *.kafka.lab.test)                          │
 │      │ TLSRoute bootstrap / broker-0 / broker-1 / broker-2   (criados e mantidos pelo Strimzi)          │
 │      ▼                                                                                                 │
 │  my-cluster (3 nós dual-role): listener internal :9093 (mTLS)  e  external :9094 (tlsroute, mTLS)      │
 │      ▲ certificado do listener                          ▲ Clients CA assina os KafkaUsers              │
 │  cert-manager: selfsigned → Lab Root CA → kafka-external (SAN: bootstrap + 3 brokers)                  │
 │  trust-manager: copia a Lab Root CA (pública) para os namespaces dos times ─► ns team-orders           │
 │  CoreDNS: *.kafka.lab.test → Service do Gateway (apps dos times resolvem os MESMOS nomes)              │
 └────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

| Componente | Versão | Papel |
|---|---|---|
| Kubernetes (kind) | 1.34.0 (`kindest/node:v1.34.0`) | o Strimzi 1.3.x exige **≥ 1.32** (o `kind` mais antigo traz 1.31 por padrão) |
| Strimzi | 1.3.1 (chart `strimzi/strimzi-kafka-operator`) | operator; listener `tlsroute` |
| Kafka | 4.3.2 (KRaft, 3 nós dual-role) | — |
| cert-manager | v1.21.3 | a PKI do lab, como código |
| trust-manager | v0.26.0 | entrega a CA pública aos namespaces dos times |
| Envoy Gateway | v1.10.0 (traz os CRDs da Gateway API, `TLSRoute` v1) | implementação do `Gateway` |

**Pré-requisitos:** `docker` (≥ 6 GB de memória para o Docker; o lab usou ~5 GB), `kind`, `kubectl`,
`helm`, `openssl`, `python3`. **Todo comando `kubectl` do lab usa `--context kind-strimzi-day11` de forma
explícita** (via o atalho `kx` abaixo): se a sua máquina tem outros contextos, nada roda no cluster errado.

```bash
cd kafka-strimzi/Day11-AcessoExterno
kx() { kubectl --context kind-strimzi-day11 "$@"; }      # use em TODO terminal novo
```

## 6. Estrutura do lab

```text
Day11-AcessoExterno/
├── README.md / README-EN.md
├── kind-config.yaml              # 443 → NodePort 30443 (o "load balancer" do lab) + NodePorts 31090-31093 (cenário A)
└── lab/
    ├── up.sh                     # kind + cert-manager + trust-manager + Envoy Gateway + Strimzi (idempotente)
    ├── manifests/
    │   ├── 00-gateway.yaml       # EnvoyProxy + GatewayClass + Gateway (TLS passthrough)
    │   ├── 10-pki.yaml           # selfsigned → Lab Root CA → ClusterIssuer lab-ca → Certificate kafka-external
    │   ├── 20-kafka.yaml         # KafkaNodePool + Kafka (listeners internal e external=tlsroute)
    │   ├── 30-topics-users.yaml  # 2 tópicos e 2 KafkaUsers (team-orders, team-payments) com ACLs
    │   ├── 40-trust-bundle.yaml  # trust-manager Bundle + namespace team-orders
    │   ├── 41-team-orders-client.yaml   # o pod que um time roda no namespace dele
    │   └── scenario-a-*.yaml     # JSON patches do cenário A (nodeport)
    └── scripts/
        ├── dns-local.sh          # dnsmasq (laptop)        dns-cluster.sh   # CoreDNS (pods)
        ├── client-bundle.sh      # o "pacote" que o time de plataforma entrega a um time
        ├── kafka-client.sh       # roda as ferramentas do Kafka em container, como um time externo
        └── wait-kafka.sh         # espera o Kafka ficar Ready E parar de reiniciar
```

## 7. Passo a passo

### 7.1 A plataforma (cluster, cert-manager, trust-manager, Envoy Gateway, Strimzi)

```bash
lab/up.sh
```

```text
platform ready on context kind-strimzi-day11
```

```bash
kx get pods -A | grep -E "cert-manager|trust-manager|envoy|strimzi"
```

Seis pods de plataforma: `cert-manager` (+ `cainjector` e `webhook`), `trust-manager`, `envoy-gateway`
e o `strimzi-cluster-operator`. O Strimzi vigia só o namespace `kafka`.

### 7.2 DNS — o nome que o cliente usa tem de resolver para o Gateway

Os nomes são `bootstrap.kafka.lab.test` e `broker-{0,1,2}.kafka.lab.test` (o TLD `.test` é reservado e
nunca existirá na internet). Há **dois** "DNS" a resolver:

**(a) O DNS do laptop.** Uma zona curinga `*.lab.test → 127.0.0.1` num dnsmasq em container:

```bash
lab/scripts/dns-local.sh up
```

```text
dnsmasq up on 127.0.0.1:5354. Now (once, sudo):
  sudo mkdir -p /etc/resolver && printf 'nameserver 127.0.0.1\nport 5354\n' | sudo tee /etc/resolver/lab.test
```

Rode o `sudo` impresso (o script **não** o executa): no macOS, o arquivo em `/etc/resolver/` manda só as
consultas `*.lab.test` para o dnsmasq. Porta **5354**: a 5353 já pertence ao mDNSResponder (Bonjour) e o
Docker recusa o bind. A alternativa de duas linhas, sem container, é o `/etc/hosts`:

```bash
echo '127.0.0.1 bootstrap.kafka.lab.test broker-0.kafka.lab.test broker-1.kafka.lab.test broker-2.kafka.lab.test' | sudo tee -a /etc/hosts
```

```bash
lab/scripts/dns-local.sh test
```

```text
dnsmasq direct:
127.0.0.1
127.0.0.1
127.0.0.1
what the OS resolver says (needs /etc/resolver/lab.test):
  (not resolving through the OS yet)       # ← é isto que você vê ANTES do sudo; depois, aparece o ip_address
```

**(b) O DNS dentro do cluster.** Apps de **outros times, em outros namespaces**, devem usar *exatamente*
os mesmos nomes (e, portanto, o mesmo certificado). Uma linha de `rewrite` no CoreDNS aponta
`*.kafka.lab.test` para o Service do Gateway:

```bash
lab/scripts/dns-cluster.sh
```

```text
CoreDNS apply: *.kafka.lab.test -> envoy-kafka-kafka-gateway-bf6d80f0.envoy-gateway-system
```

```bash
kx run dnscheck --rm -i --restart=Never --image=busybox:1.36 -- nslookup broker-1.kafka.lab.test 2>&1 | grep -E "Name|Address" | tail -2
```

```text
Name:	envoy-kafka-kafka-gateway-bf6d80f0.envoy-gateway-system.svc.cluster.local
Address: 10.96.219.170
```

> **Em produção** isto é uma zona de DNS de verdade (Route 53, Cloud DNS, ExternalDNS) com um registro
> para o bootstrap e um por broker apontando para o IP do load balancer do Gateway (seção 9).

### 7.3 A PKI — a CA raiz e o certificado do listener, como código

```bash
kx apply -f lab/manifests/10-pki.yaml
kx -n kafka get certificate
```

```text
NAME             READY   SECRET               AGE
kafka-external   True    kafka-external-tls   26s
```

A cadeia é `selfsigned → lab-root-ca (raiz, 10 anos) → lab-ca (ClusterIssuer) → kafka-external`.
Os pontos que importam em [`10-pki.yaml`](lab/manifests/10-pki.yaml): os `dnsNames` (o **SAN**: bootstrap e os 3
brokers), `privateKey.encoding: PKCS8` (cenário C) e `rotationPolicy: Always` (chave nova a cada renovação).

### 7.4 O Gateway — a "porta de entrada"

```bash
kx apply -f lab/manifests/00-gateway.yaml
kx -n kafka get gateway
```

```text
NAME            CLASS   ADDRESS      PROGRAMMED   AGE
kafka-gateway   envoy   172.18.0.6   True         26s
```

O `Gateway` tem um listener `protocol: TLS`, `mode: Passthrough`, `hostname: "*.kafka.lab.test"`: o Envoy
**não decifra nada**, só lê o SNI. O Strimzi cria os `TLSRoute`s, mas **não** cria o `Gateway` — ele é da
equipe de plataforma. Dois detalhes do manifesto são do *lab* (comentados no arquivo): o `Service` do Envoy
é `NodePort` 30443 (o kind o publica em `localhost:443`) e `externalTrafficPolicy: Cluster` (seção 10, nº 1).

### 7.5 O Kafka com o listener `tlsroute`

```bash
kx apply -f lab/manifests/20-kafka.yaml
kx -n kafka wait kafka/my-cluster --for=condition=Ready --timeout=600s
```

O trecho que importa (o resto está em [`20-kafka.yaml`](lab/manifests/20-kafka.yaml)):

```yaml
- name: external
  port: 9094
  type: tlsroute
  tls: true                      # obrigatório: o Gateway faz passthrough, quem termina o TLS é o broker
  authentication: { type: tls }  # mTLS: o cliente prova quem é com um certificado da Clients CA
  configuration:
    parentRefs:                  # a qual Gateway os TLSRoutes gerados se prendem
      - { group: gateway.networking.k8s.io, kind: Gateway, name: kafka-gateway, namespace: kafka, sectionName: kafka }
    bootstrap: { host: bootstrap.kafka.lab.test }
    hostTemplate: broker-{nodeId}.kafka.lab.test
    brokerCertChainAndKey:       # o NOSSO certificado (PKI do lab), no lugar do da Cluster CA
      secretName: kafka-external-tls
      certificate: tls.crt
      key: tls.key
```

O cluster ficou `Ready` cerca de **80 s** depois do `apply`. O que o Strimzi criou:

```bash
kx -n kafka get tlsroute -o 'custom-columns=NAME:.metadata.name,HOSTNAMES:.spec.hostnames[0],BACKEND:.spec.rules[0].backendRefs[0].name,PORT:.spec.rules[0].backendRefs[0].port'
```

```text
NAME                         HOSTNAMES                  BACKEND                               PORT
my-cluster-dual-role-0       broker-0.kafka.lab.test    my-cluster-dual-role-0                9094
my-cluster-dual-role-1       broker-1.kafka.lab.test    my-cluster-dual-role-1                9094
my-cluster-dual-role-2       broker-2.kafka.lab.test    my-cluster-dual-role-2                9094
my-cluster-kafka-bootstrap   bootstrap.kafka.lab.test   my-cluster-kafka-external-bootstrap   9094
```

```bash
kx -n kafka get kafka my-cluster -o jsonpath='{range .status.listeners[*]}{.name}{"  "}{.bootstrapServers}{"\n"}{end}'
```

```text
external  bootstrap.kafka.lab.test:443
internal  my-cluster-kafka-bootstrap.kafka.svc:9093
```

Repare: o Kafka escuta em **9094**, o cliente usa **443** — o Strimzi já anuncia a porta do Gateway.

### 7.6 Times, tópicos e identidades

```bash
kx apply -f lab/manifests/30-topics-users.yaml
kx -n kafka get kafkauser,kafkatopic
```

```text
NAME                                       CLUSTER      AUTHENTICATION   AUTHORIZATION   READY
kafkauser.kafka.strimzi.io/team-orders     my-cluster   tls              simple          True
kafkauser.kafka.strimzi.io/team-payments   my-cluster   tls              simple          True

NAME                                          CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
kafkatopic.kafka.strimzi.io/orders.events     my-cluster   3            3                    True
kafkatopic.kafka.strimzi.io/payments.events   my-cluster   3            3                    True
```

Cada time tem **uma identidade mTLS** (`CN=team-orders`) e ACLs só no seu prefixo (`orders.`/`payments.`).

### 7.7 O "pacote" que o time de plataforma entrega a um time

```bash
lab/scripts/client-bundle.sh team-orders lab/bundle-team-orders
lab/scripts/client-bundle.sh team-payments lab/bundle-team-payments
```

```text
bundle for team-orders -> lab/bundle-team-orders/  (ca.crt is public; keystore.pem is a SECRET)
```

| Arquivo | O que é | Sensível? |
|---|---|---|
| `ca.crt` | a **Lab Root CA** (pública): "confie em quem ela assinou" | **não** — igual para todos os times |
| `keystore.pem` | chave privada + certificado de cliente do time (da Clients CA) | **sim** — só daquele time |
| `client.properties` | `security.protocol=SSL`, truststore e keystore em **PEM** (sem `keytool`/PKCS12) | não |

(`lab/bundle-*` está no `.gitignore`: nunca commite um `keystore.pem`.)

Com o pacote, o time usa as ferramentas do Kafka. Num container (o `kafka-client.sh` já mapeia os 4 nomes
para o laptop, onde o kind publica a 443 — com o DNS da 7.2 você pode rodar as ferramentas nativas):

```bash
BS=(--bootstrap-server bootstrap.kafka.lab.test:443 --command-config client.properties)
lab/scripts/kafka-client.sh lab/bundle-team-orders kafka-topics.sh "${BS[@]}" --list
```

```text
orders.events
```

O time de pedidos só **enxerga** o próprio tópico (a ACL de `Describe` é por prefixo). Produzir e consumir:

```bash
printf 'order-1\norder-2\norder-3\n' | lab/scripts/kafka-client.sh lab/bundle-team-orders kafka-console-producer.sh "${BS[@]}" --topic orders.events
lab/scripts/kafka-client.sh lab/bundle-team-orders kafka-console-consumer.sh "${BS[@]}" --topic orders.events --group team-orders-app --from-beginning --max-messages 3 --timeout-ms 20000
```

```text
order-1
order-2
order-3
Processed a total of 3 messages
```

E a **fronteira entre times** — `team-orders` tentando escrever no tópico de pagamentos:

```bash
echo x | lab/scripts/kafka-client.sh lab/bundle-team-orders kafka-console-producer.sh "${BS[@]}" --topic payments.events
```

```text
ERROR [Producer clientId=console-producer] Topic authorization failed for topics [payments.events]
```

Para ver o handshake como o cliente vê (e provar que o Gateway entrega o **nosso** certificado, escolhido
pelo SNI, sem decifrar nada):

```bash
openssl s_client -connect 127.0.0.1:443 -servername broker-1.kafka.lab.test \
  -CAfile lab/bundle-team-orders/ca.crt -verify_hostname broker-1.kafka.lab.test </dev/null 2>/dev/null \
  | grep -E "^ *[0-9] s:|^ *i:|Verification|Verify return"
```

```text
 0 s:
   i:CN=Espetinho de Kafka Lab Root CA
Verification: OK
Verify return code: 0 (ok)
```

(`-connect 127.0.0.1:443` + `-servername` testa **sem** depender de DNS: bom para separar "problema de DNS"
de "problema de certificado".)

### 7.8 Distribuindo a confiança e as credenciais aos times

Duas coisas chegam a um time, com sensibilidades opostas:

1. **A CA raiz (pública)** — distribuída por **trust-manager**: um `Bundle` copia `tls.crt` da `lab-root-ca`
   para um `ConfigMap` em *todo namespace com o label `kafka.lab/trust-ca=true`* e o mantém em dia (se a CA for
   rotacionada, todos os times recebem a nova). A chave privada da CA nunca sai do namespace `cert-manager`.
2. **A identidade do time (privada)** — o `Secret` do `KafkaUser`. Para quem está **fora** do cluster, é o
   `keystore.pem` do passo anterior, entregue por um canal seguro (cofre/secret manager). Para quem está
   **dentro**, o `Secret` precisa existir no namespace do time (aqui, copiado à mão; o **KafkaAccessOperator**
   do Day 5 automatiza isso).

```bash
kx apply -f lab/manifests/40-trust-bundle.yaml
kx -n team-orders get cm kafka-lab-ca -o jsonpath='{.data.ca\.crt}' | openssl x509 -noout -subject
```

```text
subject=CN=Espetinho de Kafka Lab Root CA
```

```bash
kx -n kafka get secret team-orders -o json \
  | python3 -c 'import sys,json; s=json.load(sys.stdin); s["metadata"]={"name":"team-orders","namespace":"team-orders"}; print(json.dumps(s))' \
  | kx apply -f -
kx apply -f lab/manifests/41-team-orders-client.yaml
kx -n team-orders wait --for=condition=Ready pod/orders-app --timeout=120s
```

O pod do time monta a CA (`ConfigMap` do trust-manager) e a identidade (`Secret`) e conecta pelos **mesmos
nomes externos** — resolvidos pelo CoreDNS da 7.2:

```bash
kx -n team-orders exec orders-app -- /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server bootstrap.kafka.lab.test:443 --consumer.config /tmp/client.properties \
  --topic orders.events --group team-orders-pod --from-beginning --max-messages 3 --timeout-ms 30000
```

```text
Processed a total of 3 messages
```

E a mesma fronteira de ACL vale dentro do cluster (`Topic authorization failed for topics [payments.events]`).

## 8. Cenários de falha (todos executados)

Cada cenário reproduz um erro real do dia a dia, mostra **a mensagem exata** e **como diagnosticar**.

### Cenário A — O bootstrap conecta, os brokers não (`nodeport` sem `advertisedHost`)

Acrescente um listener `nodeport` sem dizer nada sobre hostnames (JSON patch; só para o lab, em texto plano
e com `ANONYMOUS` como super user, para que a falha seja de **rede** e não de TLS/ACL):

```bash
kx -n kafka patch kafka my-cluster --type json --patch-file lab/manifests/scenario-a-nodeport-broken.yaml
lab/scripts/wait-kafka.sh
kx -n kafka get kafka my-cluster -o jsonpath='{.status.listeners[?(@.name=="nodeport")].bootstrapServers}{"\n"}'
```

```text
172.18.0.3:31090,172.18.0.5:31090,172.18.0.6:31090        # ← IPs dos NÓS do kind (rede interna do Docker)
```

(~100 s para o `Ready`.) O bootstrap responde **do laptop**, mas olhe o que ele devolve:

```bash
lab/scripts/kafka-client.sh none kafka-broker-api-versions.sh --bootstrap-server host.docker.internal:31090
```

```text
172.18.0.3:31092 (id: 1 rack: null isFenced: false) -> ERROR: org.apache.kafka.common.errors.TimeoutException: Failed to send request after 5000 ms.
172.18.0.6:31093 (id: 2 rack: null isFenced: false) -> ERROR: org.apache.kafka.common.errors.TimeoutException: Failed to send request after 5000 ms.
172.18.0.5:31091 (id: 0 rack: null isFenced: false) -> ERROR: org.apache.kafka.common.errors.TimeoutException: Failed to send request after 5000 ms.
```

É o erro da seção 1: o **metadata** (etapa 2) funcionou e listou os brokers pelos IPs `172.18.0.x`, que o
cliente **não alcança**. Um `consumer` fica em `TimeoutException` e `Processed a total of 0 messages`.
**Diagnóstico em uma linha:** olhe o endereço que cada broker *anuncia* (`id: 0 … 172.18.0.5:31091`), não o
de bootstrap. **Correção:** diga ao broker o endereço que o *cliente* deve usar
([`scenario-a-nodeport-fixed.yaml`](lab/manifests/scenario-a-nodeport-fixed.yaml): `advertisedHost` + `advertisedPort`):

```bash
kx -n kafka patch kafka my-cluster --type json --patch-file lab/manifests/scenario-a-nodeport-fixed.yaml
lab/scripts/wait-kafka.sh
lab/scripts/kafka-client.sh none kafka-console-consumer.sh --bootstrap-server host.docker.internal:31090 \
  --topic orders.events --from-beginning --max-messages 3 --timeout-ms 20000
```

```text
order-1
order-2
order-3
Processed a total of 3 messages
```

(`host.docker.internal` é um nome que resolve para o laptop tanto de dentro de um container quanto do próprio
laptop — no Docker Desktop. Em produção seria um DNS que aponta para os nós. **Prefira `tlsroute` ou
`loadbalancer`**: `nodeport` empurra esse problema para você.) Volte ao estado base:

```bash
kx -n kafka patch kafka my-cluster --type json --patch-file lab/manifests/scenario-a-cleanup.yaml
lab/scripts/wait-kafka.sh
```

### Cenário B — O nome não está no certificado (SAN)

Simula "escalei o cluster / mudei o `hostTemplate` e esqueci de atualizar o certificado": tire o `broker-2`
do SAN.

```bash
kx -n kafka patch certificate kafka-external --type json -p '[{"op":"remove","path":"/spec/dnsNames/3"}]'
EXPECT_ROLL=1 lab/scripts/wait-kafka.sh
```

Dois fatos medidos aqui: (1) o **Strimzi só percebe o `Secret` novo na reconciliação seguinte** — cerca de
**60 s** depois do cert-manager reemitir; (2) em seguida faz um **rolling restart** dos brokers (~70 s). Mudar
o certificado de um listener **reinicia o cluster**, sempre. O cliente:

```bash
lab/scripts/kafka-client.sh lab/bundle-team-orders kafka-broker-api-versions.sh --bootstrap-server bootstrap.kafka.lab.test:443 --command-config client.properties
```

```text
ERROR [LegacyAdminClient clientId=admin-1] Connection to node 2 (broker-2.kafka.lab.test/192.168.65.254:443) failed authentication due to: SSL handshake failed
broker-0.kafka.lab.test:443 (id: 0 rack: null isFenced: false) -> (
```

A causa exata aparece na cadeia de exceções (`kafka-topics.sh --describe --topic orders.events` a imprime com
clareza):

```text
Caused by: javax.net.ssl.SSLHandshakeException: (certificate_unknown) No subject alternative DNS name matching broker-2.kafka.lab.test found.
```

Note: **o bootstrap funcionou** (o nome dele está no SAN); quem falha é o **nó 2**, que só aparece na etapa 3.
Diagnóstico sem Kafka, e **sem DNS** (`-servername` escolhe o broker pelo SNI):

```bash
openssl s_client -connect 127.0.0.1:443 -servername broker-2.kafka.lab.test \
  -verify_hostname broker-2.kafka.lab.test -CAfile lab/bundle-team-orders/ca.crt </dev/null 2>&1 | grep -E "Verif"
```

```text
verify error:num=62:hostname mismatch
Verification error: hostname mismatch
```

Correção: devolva o nome (`kx apply -f lab/manifests/10-pki.yaml`) e espere o novo rolling restart.
**Lição de produção:** o SAN é parte do *contrato* do cluster. Adicionar broker = adicionar o nome ao
certificado **antes** (ou usar um curinga `*.kafka.empresa.com` — menos restritivo, mas sem esse passo).

### Cenário C — A chave privada em PKCS#1 derruba o broker

O cert-manager gera a chave em **PKCS#1** (`BEGIN RSA PRIVATE KEY`) por padrão. O Strimzi aceita o `Secret`
sem reclamar, o rolling restart começa… e o broker não sobe. Para reproduzir, mude o encoding e **force a
reemissão** (só mudar o `encoding` não reemite; `cmctl renew` é o jeito oficial — sem ele, um truque
declarativo é encostar o `renewBefore` na `duration`):

```bash
kx -n kafka patch certificate kafka-external --type merge -p '{"spec":{"privateKey":{"encoding":"PKCS1"},"renewBefore":"2159h59m"}}'
kx -n kafka get secret kafka-external-tls -o jsonpath='{.data.tls\.key}' | base64 -d | head -1
```

```text
-----BEGIN RSA PRIVATE KEY-----
```

Cerca de 2–3 minutos depois (o tempo de o Strimzi notar e reiniciar o primeiro broker):

```bash
kx -n kafka get pods | grep dual-role
```

```text
my-cluster-dual-role-0   1/1   Running            0             22m
my-cluster-dual-role-1   0/1   CrashLoopBackOff   4 (43s ago)   2m27s
my-cluster-dual-role-2   1/1   Running            0             22m
```

```bash
kx -n kafka logs my-cluster-dual-role-1 | grep -E "Fatal error|Private key|InvalidKeySpec"
```

```text
ERROR [main] BrokerServer:86 - [BrokerServer id=1] Fatal error during broker startup. Prepare to shutdown
org.apache.kafka.common.errors.InvalidConfigurationException: Invalid PEM keystore configs
Caused by: org.apache.kafka.common.errors.InvalidConfigurationException: Private key could not be loaded
Caused by: java.security.spec.InvalidKeySpecException: java.security.InvalidKeyException: Unable to decode key
```

Observe o perigo: o **`Kafka` continua `Ready=True`** durante todo esse tempo, e os outros dois brokers (ainda
com o certificado antigo) seguem servindo. O cluster está **a um broker de perder o `min.insync.replicas`** e
nada gritou. É um alerta a escrever (pod em `CrashLoopBackOff`, Day 10). Correção — `PKCS8`, que o
[`10-pki.yaml`](lab/manifests/10-pki.yaml) já tem:

```bash
kx -n kafka patch certificate kafka-external --type merge -p '{"spec":{"privateKey":{"encoding":"PKCS8"},"renewBefore":"2159h59m"}}'
```

O broker 1 voltou a `Running` cerca de **2 minutos** depois (o `Secret` montado foi atualizado e a tentativa de
reinício seguinte já leu a chave PKCS#8). Reaplique o `10-pki.yaml` para devolver o `renewBefore` a 720 h e use `lab/scripts/wait-kafka.sh`
para esperar a estabilidade.

### Cenário D — Os três erros de cliente que você vai ver nos chamados

Cada um tem uma assinatura inconfundível. Reproduzidos com cópias do pacote do time:

```bash
cp -R lab/bundle-team-orders lab/bundle-noca;   sed -i.bak '/ssl.truststore/d' lab/bundle-noca/client.properties
cp -R lab/bundle-team-orders lab/bundle-nocert; sed -i.bak '/ssl.keystore/d'   lab/bundle-nocert/client.properties
```

**D1 — o cliente não confia na CA** (esqueceu o `ssl.truststore.*`):

```bash
lab/scripts/kafka-client.sh lab/bundle-noca kafka-topics.sh "${BS[@]}" --list
```

```text
Caused by: javax.net.ssl.SSLHandshakeException: (certificate_unknown) PKIX path building failed: ... unable to find valid certification path to requested target
```

**D2 — o cliente não apresenta certificado** (esqueceu o `ssl.keystore.*`; o listener exige mTLS):

```bash
lab/scripts/kafka-client.sh lab/bundle-nocert kafka-topics.sh "${BS[@]}" --list
```

```text
Caused by: javax.net.ssl.SSLHandshakeException: (certificate_required) Received fatal alert: certificate_required
```

**D3 — só o bootstrap resolve no DNS** (esqueceram dos registros por broker):

```bash
HOSTS=bootstrap lab/scripts/kafka-client.sh lab/bundle-team-orders kafka-broker-api-versions.sh --bootstrap-server bootstrap.kafka.lab.test:443 --command-config client.properties
```

```text
WARN [LegacyAdminClient clientId=admin-1] Error connecting to node broker-1.kafka.lab.test:443 (id: 1 rack: null isFenced: false)
java.net.UnknownHostException: broker-1.kafka.lab.test: Try again
```

(Resumo de bolso: **PKIX** = confiança · **certificate_required** = identidade · **UnknownHost** = DNS ·
**No subject alternative DNS name** = SAN · **TimeoutException depois do bootstrap** = endereço anunciado.)

### Cenário E — Renovar o certificado sem derrubar ninguém

O que mais assusta no TLS próprio: *"e quando vencer?"* O cert-manager renova sozinho (aqui, 30 dias antes de
vencer) e o Strimzi propaga. Para provar que **não há indisponibilidade**, rode um producer contínuo
(`acks=all`, 20 msg/s) e force uma renovação no meio:

```bash
lab/scripts/kafka-client.sh lab/bundle-team-orders kafka-producer-perf-test.sh --topic orders.events --num-records 5000 \
  --record-size 200 --throughput 20 --command-config client.properties \
  --producer-props bootstrap.servers=bootstrap.kafka.lab.test:443 acks=all delivery.timeout.ms=60000      # terminal 1
```

```bash
kx -n kafka patch certificate kafka-external --type merge -p '{"spec":{"renewBefore":"2159h59m"}}'         # terminal 2
kx apply -f lab/manifests/10-pki.yaml                                                                       # devolve renewBefore=720h
EXPECT_ROLL=1 lab/scripts/wait-kafka.sh
```

```text
serial antes:  65456FF50322304EEC9CE7AC4C16ABED83BBC2C1
serial depois: 7087F78A614EDE7C197E232A62A81B8545D2366C         # certificado novo, CHAVE nova (rotationPolicy: Always)
kafka ready (3/3 brokers, quiet for 47s)                         # renovação → 3 brokers reiniciados e estáveis: 155 s
```

O resultado do producer (no terminal 1):

```text
5000 records sent, 19.998800 records/sec (0.00 MB/sec), 12.04 ms avg latency, 512.00 ms max latency, 11 ms 50th, 15 ms 95th, 36 ms 99th, 242 ms 99.9th.
WARN [Producer clientId=perf-producer-client] Received invalid metadata error in produce request on partition orders.events-1 due to ...NotLeaderOrFollowerException
```

**5000 de 5000 registros entregues**, latência máxima de 512 ms, e apenas **2 avisos** de `NotLeaderOrFollower`
(o broker reiniciou e o líder mudou; o cliente reenviou sozinho). Isso vale **porque** a replicação é 3,
`min.insync.replicas=2` e o Strimzi reinicia **um broker por vez**, esperando-o ficar pronto. Os clientes
continuam funcionando porque a **CA é a mesma** — só o certificado folha mudou. (Trocar a **CA** é outra
operação: aí os times precisam receber a CA nova *antes* — é para isso que o trust-manager existe.)

## 9. Indo para produção

| Lab | Produção |
|---|---|
| `Service` do Envoy `NodePort` + `extraPortMappings` do kind | `Service` **`LoadBalancer`** (o Envoy Gateway cria sozinho se você tirar o bloco `envoyService`); o DNS aponta para o IP/hostname dele. Com `externalTrafficPolicy: Local` (o padrão do Envoy Gateway) o LB verifica quais nós têm Envoy e preserva o IP do cliente |
| `Gateway` no namespace `kafka`, `allowedRoutes: Same` | `Gateway` num namespace de **infraestrutura**, `allowedRoutes.namespaces` por *selector*, 2+ réplicas do Envoy, `PodDisruptionBudget`, limites de recurso e de conexões (`maxConnections` no listener) |
| CA raiz **autoassinada**, no cluster | **CA corporativa** (PKI interna, Vault, AWS Private CA, Venafi…) como `Issuer` do cert-manager; raiz **offline** e uma intermediária para o cluster |
| dnsmasq + CoreDNS `rewrite` | zona real (Route 53 / Cloud DNS) com registros (ou curinga) para o bootstrap e cada broker; ExternalDNS se quiser automatizar |
| SAN explícito (bootstrap + 3 brokers) | decida **curinga × explícito** com a segurança; com explícito, **escalar o cluster exige reemitir o certificado antes** (cenário B) |
| Certificado de 90 dias, renova 30 antes | idem, mas **alerte** sobre expiração (`certmanager_certificate_expiration_timestamp_seconds`) e sobre pod em `CrashLoopBackOff` (cenário C) |
| `keystore.pem` entregue "à mão" | entregue por **cofre/secret manager**; para apps no cluster, `KafkaAccess` (Day 5); defina **rotação e revogação** das identidades |
| mTLS por time com ACL por prefixo | + **quotas** (`KafkaUser`), `networkPolicyPeers` no listener, observabilidade do Gateway e dos brokers (Day 10) |

## 10. Armadilhas que o lab encontrou

1. **O handshake "conecta e trava" com o Envoy Gateway em NodePort.** O Envoy Gateway cria o `Service` com
   `externalTrafficPolicy: Local`: um nó só responde se tiver um pod do Envoy **nele**. O kind publica a 443 no
   nó *control-plane* (onde o Envoy não roda), então o TCP conecta e o TLS nunca recebe resposta (`SSL
   connection timeout`). Em cloud, o LB faz *health check* e isso não aparece; no lab, `externalTrafficPolicy:
   Cluster` no `EnvoyProxy` resolve. Sintoma de diagnóstico: `openssl s_client` funciona **de dentro do nó**
   e falha de fora.
2. **Mudar o certificado reinicia o cluster, e o Strimzi só nota depois de ~1 min.** Planeje janelas e não
   se assuste com "nada acontece" logo após a emissão.
3. **`privateKey.encoding` sozinho não reemite o certificado** no cert-manager; combine com uma renovação.
4. **O Kafka fica `Ready=True` com um broker em `CrashLoopBackOff` por chave inválida** (cenário C).
5. **A porta 5353 no macOS** é do mDNSResponder: o dnsmasq do lab usa a **5354**.
6. **O Strimzi 1.3.x exige Kubernetes ≥ 1.32**; o `kindest/node` padrão de um `kind` antigo é 1.31.
7. **Um erro de *shell* que custa caro:** `[ "$n" = 3 ]` com `n=$(… | wc -w)` falha no macOS porque o `wc`
   preenche com espaços. Use comparação numérica (`$((n))`) em scripts de espera — o `wait-kafka.sh` faz isso.

## 11. Roteiro sugerido para o vídeo

Duração-alvo: **~25 min**. O fio condutor é a frase "o bootstrap conecta, o resto dá timeout".

| Tempo | Bloco | O que mostrar |
|---|---|---|
| 0:00 | Gancho | "Conecto no bootstrap, `--list` funciona, e produzir dá timeout. Por quê?" |
| 1:30 | Como o cliente conecta | Seção 1: as 3 etapas; `advertised.listeners` |
| 4:00 | Tipos de listener | Tabela da seção 2; **`ingress` deprecated → `tlsroute`**; o truque do SNI |
| 8:00 | Qual escolher / Istio | Seção 3; as discussões #11869 e #12200; Router do OpenShift (`route`) |
| 10:30 | As 3 cadeias de confiança | Seção 4: Cluster CA × Clients CA × certificado do listener |
| 12:00 | Lab: DNS e PKI | `dns-local.sh`, `dns-cluster.sh`; `10-pki.yaml` (SAN, PKCS8) |
| 14:30 | Gateway + Kafka `tlsroute` | Os TLSRoutes que o Strimzi criou; `openssl s_client` com `-servername` |
| 16:30 | Um time conecta | `client-bundle.sh`; mTLS; ACL negando o tópico do outro time; trust-manager |
| 19:30 | **Cenário A** | `nodeport` sem `advertisedHost`: metadata com IPs `172.18.0.x` |
| 21:30 | **Cenários B e C** | SAN faltando; chave PKCS#1 → `CrashLoopBackOff` com o Kafka `Ready` |
| 23:30 | **Cenário E** | Rotação com producer rodando: 5000/5000, 155 s |
| 24:30 | Fechamento | Checklist da seção 9; teaser do próximo Day |

## 12. O que este lab NÃO cobre (honestamente)

- **`loadbalancer` de verdade:** no kind/Docker Desktop um `LoadBalancer` não tem IP alcançável pelo laptop.
  Descrito na tabela da seção 2; **não executado**.
- **`route` (OpenShift Router) e `ingress` (deprecated):** descritos pela documentação do Strimzi e pelo CRD;
  **não executados** (não há OpenShift aqui, e o `ingress` depende do NGINX Ingress, aposentado).
- **Istio:** só as duas discussões; **nada foi reproduzido neste lab**.
- **O arquivo `/etc/resolver/lab.test` e o `/etc/hosts` não foram aplicados no host** (exigem `sudo`). O
  dnsmasq foi validado com `dig` direto; a resolução pelo sistema operacional **não foi exercitada**. Todos os
  testes de cliente rodaram em **container** (o `kafka-client.sh` mapeia os nomes para o host). Um `kcat`
  nativo no macOS (librdkafka 2.15.0) **falhou** contra o listener `nodeport` em texto plano — não foi
  diagnosticado; o mesmo teste com o cliente Java e com `kcat` 1.7.1 em container funcionou.
- **SCRAM / OAuth no listener externo:** o lab usa só mTLS. A troca é `authentication: scram-sha-512` (Day 4).
- **Rotação da Clients CA/Cluster CA do Strimzi** e **revogação** de certificados de clientes: não exercitadas.
- **Vários clusters / peering de redes**, **Windows**, **IPv6**, **carga** (throughput pelo Gateway não foi medido).
- Os tempos (~60 s para o Strimzi notar o `Secret`, ~155 s de rotação) foram medidos num Docker Desktop
  (Apple Silicon) e variam no seu ambiente.

## 13. Cleanup

```bash
kind delete cluster --name strimzi-day11
lab/scripts/dns-local.sh down            # e: sudo rm -f /etc/resolver/lab.test   (ou a linha do /etc/hosts)
rm -rf lab/bundle-*                       # chaves privadas de times: não deixe por aí
```

## 14. Referências

- Strimzi — [Accessing Kafka using Gateway API `TLSRoute` resources](https://strimzi.io/docs/operators/latest/deploying.html) e os capítulos
  de *Configuring listeners* / *Installing your own listener certificates* (`brokerCertChainAndKey`) da documentação oficial.
- Discussões do Strimzi sobre Istio: [#11869](https://github.com/orgs/strimzi/discussions/11869) e [#12200](https://github.com/orgs/strimzi/discussions/12200).
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) (`Gateway`, `TLSRoute`) e [Envoy Gateway](https://gateway.envoyproxy.io/).
- [cert-manager](https://cert-manager.io/) (`Certificate`, `ClusterIssuer`, `privateKey.encoding`, `renewBefore`) e [trust-manager](https://cert-manager.io/docs/trust/trust-manager/) (`Bundle`).
- Day 4 (autenticação, mTLS e ACLs), Day 5 (KafkaAccessOperator) e Day 10 (observabilidade) deste repositório.
