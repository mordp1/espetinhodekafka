# espetinhodekafka
Para entender e aprender um pouco sobre o Apache Kafka.

Os vídeos foram feitos com a idéia de compartilhar o meu conhecimento adquirido, trabalhando com Kafka, para colegas de trabalho e alguns amigos.

Eu mesmo editei os vídeos, sem muito conhecimento na ferramenta.

## Canal no Youtube
https://www.youtube.com/@espetinhodekafka

## Descrição
Aqui você pode acompanhar todos os comandos utilizados em cada dia, para facilitar no aprendizado e montar seu Laboratorio.

## Configurando seu laboratorio
Estou utilizando o [minikube](https://minikube.sigs.k8s.io/docs/start/) para essa primeira prova de conceito. Você precisa instalar o [minikube](https://minikube.sigs.k8s.io/docs/start/), e pode ser configurado com VirtualBox, HyperV,Docker etc. 
Para este laboratório, você não precisa configurar 8GB com 6 cpus.
Obs. Com o Docker, você pode ter alguns desafios em relação ao ingress do Kubernetes + Dcoker.

### Ferramentas

- Instale [kubectl](https://kubernetes.io/docs/tasks/tools/)
- Instale [kubectx e kubens](https://github.com/ahmetb/kubectx)
- Instale [helm](https://helm.sh/)

### Habiltar no Windows o HyperV
Eu estou utilizando Windows 11.
Rode o PowerShell como Adminstrador e habilite o Hyper-V

```
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

### Iniciando o Minikube

```
minikube start --memory=8096 --cpus 6 --driver=hyperv
```

Você pode fazer o mesmo com VirtualBox, sem precisar habilitar o Hyper-V

```
minikube start --memory=8096 --cpus 6 --driver=virtualbox
```

### Minikube Addons

```
minikube addons enable metrics-server
minikube addons enable ingress
minikube addons enable ingress-dns
```

## Strimzi - Kafka
Criando o Namespace

```
kubectl create namespace kafka-test

kubens kafka-test
```

### Helm install
Baixando e instalando o repo do Strimzi.
```
helm repo add strimzi https://strimzi.io/charts/

helm install my-strimzi strimzi/strimzi-kafka-operator --namespace kafka-test --version 0.38.0
```

### Metrics
O configMap [kafka-metrics.yaml](kafka-metrics.yaml) será necessário para coletarmos as métricas via JMX e podermos configurar depois os Dashboards no Grafana.

```
kubectl apply -f Kafka-Metrics.yaml -n kafka-test
```

### Kafka
Aqui já tenho exemplo de um cluster Kafka com 3 Brokers e algumas configurações extras -> [kafka-server.yml](kafka-server.yml)

```
kubectl apply -f kafka-server.yaml -n kafka-test
```

### Admin user
Como estamos utlizando autenticação para acessar o Kafka, e foi definido um superUser, devemos aplicar o [kafka-admin.yaml](kafka-admin.yaml) para que seja criado as Secrets com a senha.

```
kubectl apply -f kafka-admin.yaml -n kafka-test
```

### Criar Topico de teste
[topic-test.yaml](topic-test.yaml)
```
kubectl apply -f topic-test.yaml
```

### RBAC
Aqui daremos permissões para que possamos executar alguns comandos (kubectl) de dentro no POD.

[RBAC.yaml](RBAC.yaml)

```
kubectl apply -f RBAC.yaml
```
 
### Internal Pod
Vamos iniciar um POD com  imagem da Confluent para realizar alguns testes e gerar nossa keystore.

```
kubectl run my-shell --rm -i --tty --image confluentinc/cp-kafka -- bash
```

- Instale Kubectl.

```
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && mkdir bin && mv kubectl bin && chmod +x bin/kubectl
```

- Gerando keystore

```
kubectl get secret mykafka-cluster-ca-cert -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
keytool -import -trustcacerts -alias root -file ca.crt -keystore truststore.jks -storepass password -noprompt
```

- Password user admin

Crie a variável com password do usuário admin.
```
passwd=$(kubectl get secret user-admin -o jsonpath='{.data.password}' | base64 -d)
```

Crie o properties
```
cat <<EOF> conf.properties
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="admin" password=passwd;
ssl.truststore.location=truststore.jks
ssl.truststore.password=password
EOF
```

Adicione o password do usuario admin no conf.properties
```
sed -i "s/passwd/$passwd/g" /tmp/conf.properties
```

- Listar todos os topicos
```
kafka-topics --bootstrap-server mykafka-kafka-bootstrap:9093 --list --command-config conf.properties
```

- Produzir mensagem

```
kafka-console-producer --bootstrap-server mykafka-kafka-bootstrap:9093 --producer.config conf.properties --topic topic-test
```

- Consumir mensagem

```
kafka-console-consumer --bootstrap-server mykafka-kafka-bootstrap:9093 --consumer.config conf.properties --from-beginning --topic topic-test
```

### Testando acesso via maquina local
Abra um novo terminal.

1. Precisamos realizar as configurações no minikube, para isso deve acessar o seguinte link para ajudar nesta tarefa:

Primeiro habiltar addons [ingress-dns](https://minikube.sigs.k8s.io/docs/handbook/addons/ingress-dns/)

O suporte Ingress no Strimzi foi adicionado no Strimzi 0.12.0. Ele usa TLS passthrough e foi testado com o controlador NGINX Ingress. Antes de usá-lo, certifique-se de que TLS passthrough esteja habilitada no controlador.

Para isso, basta editar e adicionar um novo argumento:
```
kubectl -n ingress-nginx edit deployment/ingress-nginx-controller
```
Segue exemplo `--enable-ssl-passthrough`:
```
    spec:
      containers:
      - args:
        - /nginx-ingress-controller
        - --election-id=ingress-nginx-leader
        - --controller-class=k8s.io/ingress-nginx
        - --watch-ingress-without-class=true
        - --configmap=$(POD_NAMESPACE)/ingress-nginx-controller
        - --tcp-services-configmap=$(POD_NAMESPACE)/tcp-services
        - --udp-services-configmap=$(POD_NAMESPACE)/udp-services
        - --validating-webhook=:8443
        - --validating-webhook-certificate=/usr/local/certificates/cert
        - --validating-webhook-key=/usr/local/certificates/key
        - --enable-ssl-passthrough
        env:
```

2. Copie os arquivos do nosso container para maquina local

```
kubectl cp my-shell:ca.crt ca.crt
kubectl cp my-shell:truststore.jks truststore.jks
kubectl cp my-shell:conf.properties conf.properties
```

3. Baixe os binarios do kafka e descompacte em sua maquina local.

[kafka Download](https://downloads.apache.org/kafka/3.6.0/kafka_2.13-3.6.0.tgz)

4. Comando de teste

```
.\kafka_2.13-3.6.0\bin\windows\kafka-topics.bat --bootstrap-server bootstrap.test:443 --list --command-config conf.properties
```

### Kafka-UI

Vamos utilizar o Kafka-ui [provectus/kafka-ui](https://github.com/provectus/kafka-ui).

Utilizaremos o [kafka-ui.yaml](kafka-ui.yaml)
```
kubectl apply -f kafka-ui.yaml
```

Configurando o [kafka-ui-ingress.yml](kafka-ui-ingress.yml) para acessar o Kafka Ui 
```
kubectl apply -f kafka-ui-ingress.yaml
```

Abra o navegador em http://kafka-ui.test


### Prometheus + Grafana


Pode pegar a referencia no link https://strimzi.io/docs/operators/latest/deploying#assembly-metrics-prometheus-str

Criando namespace
```
kubectl create namespace monitoring

kubens monitoring
```

Deploy do prometheus operator
```
kubectl apply -f monitor/prometheus-operator-deployment.yaml -n monitoring --force-conflicts=true --server-side
```

Deploy do prometheus e suas configs
```
kubectl apply -f monitor\prometheus-additional.yaml
kubectl apply -f monitor\strimzi-pod-monitor.yaml
kubectl apply -f monitor\strimzi-prometheus-rules.yaml
kubectl apply -f monitor\prometheus-alert-manager.yaml
kubectl apply -f monitor\prometheus.yaml
```

Deploy do Grafana
```
kubectl apply -f monitor\grafana.yaml
```

Vamos criar os Ingress
```
kubectl apply -f monitor\prometheus-ingress.yaml
kubectl apply -f monitor\grafana-ingress.yaml
```

Acessar Prometheus: http://prometheus.test
Acessar Grafana: http://grafana.test

No grafana, configure o Prometheus com endereço:
http://prometheus-operated.monitoring.svc.cluster.local:9090

Basta agora importar os Dashboards no Grafana que estão no diretório grafana-dashboards.