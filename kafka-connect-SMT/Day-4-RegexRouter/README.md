<!--
Este arquivo README.md fornece exemplos de uso do Single Message Transform (SMT) RegexRouter no Kafka Connect.
Inclui instruções e exemplos práticos para configurar e aplicar RegexRouter em tópicos Kafka, facilitando o roteamento dinâmico de mensagens com base em expressões regulares.
-->

# Exemplos de uso de Single Message Transforms (SMT) - RegexRouter

- https://docs.confluent.io/kafka-connectors/transforms/current/regexrouter.html
- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.RegexRouter

O RegexRouter é uma ferramenta poderosa e de uso frequente nas integrações de dados com Kafka Connect, simplificando a gestão, roteamento e padronização de nomes de tópicos em pipelines desde cenários simples até ambientes de produção robustos.

Iniciar docker
```bash
docker-compose -f docker-compose.yml up -d
```

Esperar Kafka Connect to start up
```bash
bash -c ' \
echo -e "\n\n=============\nWaiting for Kafka Connect to start listening on localhost ⏳\n=============\n"
while [ $(curl -s -o /dev/null -w %{http_code} http://localhost:8083/connectors) -ne 200 ] ; do
  echo -e "\t" $(date) " Kafka Connect listener HTTP state: " $(curl -s -o /dev/null -w %{http_code} http://localhost:8083/connectors) " (waiting for 200)"
  sleep 5
done
echo -e $(date) "\n\n--------------\n\o/ Kafka Connect is ready! Listener HTTP state: " $(curl -s -o /dev/null -w %{http_code} http://localhost:8083/connectors) "\n--------------\n"
curl -s http://localhost:8083/connector-plugins | jq
'
```

Configurar o JdbcSourceConnector connector com mysql
```bash
curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/source-jdbc-mysql-01/config \
    -d '{
          "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
          "connection.url": "jdbc:mysql://mysql:3306/demo",
          "connection.user": "mysqluser",
          "connection.password": "mysqlpw",
          "topic.prefix": "mysql-00-",
          "poll.interval.ms": 1000,
          "tasks.max":1,
          "table.whitelist": "customers",
          "mode": "incrementing",
          "incrementing.column.name": "id",
          "validate.non.null": false,
          "transforms": "dropTopicPrefix",
          "transforms.dropTopicPrefix.type": "org.apache.kafka.connect.transforms.RegexRouter",
          "transforms.dropTopicPrefix.regex": "mysql-00-(.*)",
          "transforms.dropTopicPrefix.replacement": "$1"
          }'
```

Vamos utilizar o DatagenConnector para gerar nossas mensagens
```bash
curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/source-voluble-datagen-00/config \
    -d '{
        "connector.class": "io.confluent.kafka.connect.datagen.DatagenConnector",
        "kafka.topic": "day4-transactions",
        "quickstart": "transactions",
        "value.converter.schemas.enable": "false",
        "max.interval": 1000,
        "tasks.max": "1"
    }'
```

Listar Topicos kcat
```bash
docker exec kafkacat kcat -b broker:29092 -L -J | jq '.topics[].topic'|sort
```

Utilizando o kcat para consumir as mensagens: 
```bash
docker exec kafkacat kcat -b broker:29092 -t day4-transactions -s key=s -s value=avro -r http://schema-registry:8081
```

Criar JdbcSinkConnector
```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/sink-jdbc-mysql-day4-transactions-00/config \
    -d '{
          "connector.class"               : "io.confluent.connect.jdbc.JdbcSinkConnector",
          "connection.url"                : "jdbc:mysql://mysql:3306/demo",
          "connection.user"               : "mysqluser",
          "connection.password"           : "mysqlpw",
          "topics"                        : "day4-transactions",
          "tasks.max"                     : "1",
          "auto.create"                   : "true",
          "auto.evolve"                   : "true"
        }'
```

Verificar o nome da tabela
```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SHOW TABLES"

docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "select * from \`day4-transactions\`;"
```

Atualizar o JdbcSinkConnector com RegexRouter

```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/sink-jdbc-mysql-day4-transactions-00/config \
    -d '{
          "connector.class"                        : "io.confluent.connect.jdbc.JdbcSinkConnector",
          "connection.url"                         : "jdbc:mysql://mysql:3306/demo",
          "connection.user"                        : "mysqluser",
          "connection.password"                    : "mysqlpw",
          "topics"                                 : "day4-transactions",
          "tasks.max"                              : "4",
          "auto.create"                            : "true",
          "auto.evolve"                            : "true",
          "transforms"                             : "dropTopicPrefix",
          "transforms.dropTopicPrefix.type"        : "org.apache.kafka.connect.transforms.RegexRouter",
          "transforms.dropTopicPrefix.regex"       : "day4-(.*)",
          "transforms.dropTopicPrefix.replacement" : "$1"
        }'
```

Verificar o nome da tabela
```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SHOW TABLES"
```

# O que é o RegexRouter?
O RegexRouter é uma Single Message Transform (SMT) do Kafka Connect que permite alterar dinamicamente o nome do tópico de uma mensagem usando uma expressão regular e uma string de substituição. Isso é útil tanto em conectores de origem (source) quanto de destino (sink), modificando o nome do tópico conforme as necessidades da integração.

## Benefícios do RegexRouter
Padronização de nomes de tópicos
Facilita a adaptação dos tópicos Kafka para convenções específicas de sistemas consumidores ou de times diferentes, evitando múltiplos tópicos redundantes.

- Roteamento flexível
Permite rotear mensagens para diferentes tópicos com base em padrões do nome original, apoiando cenários multitenant, sharding ou agrupamento por ambiente ou aplicação.

- Facilita integração com sinks
Muitas vezes, sistemas downstream (como bancos, Elasticsearch, S3) derivam o nome da tabela, índice ou diretório usando o nome do tópico. O RegexRouter permite ajustar esse nome conforme esperado pelo destino.

- Reaproveitamento de pipelines/projetos
Com RegexRouter, é possível reutilizar pipelines de integração e scripts, apenas trocando padrões de roteamento conforme cada ambiente (DEV, QA, PROD).

- Simplificação da arquitetura
Pode consolidar ou dividir tópicos de acordo com diferentes necessidades sem refatorar a fonte de dados.

# Casos de Uso Comuns em Produção
- Adição ou remoção de prefixos/sufixos: Empresas frequentemente utilizam prefixos como dev-, qa-, prod- nos tópicos; o RegexRouter remove ou adiciona esses prefixos quando necessário migrar dados entre ambientes ou integrar diferentes sistemas.

- Integração entre sistemas legados e modernos: Ao integrar dados vindos de sistemas que geram tópicos com padrões herdados, é possível atualizar os nomes dos tópicos de acordo com nomenclaturas modernas ou padrões do ecossistema de destino.

- Normalização de nomes: Aplicar lowercase, trocar caracteres inválidos, ou remover strings desnecessárias ao publicar dados, por exemplo, para garantir compatibilidade com sistemas como Elasticsearch, que têm restrições no nome de índices.

- Roteamento de eventos multiempresa/multitenant:Em ambientes SaaS, o RegexRouter pode separar ou unir eventos de diferentes clientes, criando tópicos dinâmicos baseados no identificador do cliente ou regionalidade.

- Organização para sinks como S3: Sinks como S3 ou BigQuery utilizam o nome do tópico para nomear pastas ou tabelas, e o RegexRouter é fundamental para criar hierarquias ou limpar nomes para atender a padrões do data lake.

## Exemplos de Configuração e Uso

1. Remover Prefixo
```json
"transforms": "dropPrefix",
"transforms.dropPrefix.type": "org.apache.kafka.connect.transforms.RegexRouter",
"transforms.dropPrefix.regex": "soe-(.*)",
"transforms.dropPrefix.replacement": "$1"
```
Antes: soe-Order → Depois: Order

2. Adicionar Prefixo
```json
"transforms": "AddPrefix",
"transforms.AddPrefix.type": "org.apache.kafka.connect.transforms.RegexRouter",
"transforms.AddPrefix.regex": ".*",
"transforms.AddPrefix.replacement": "acme_$0"
```
Antes: Order → Depois: acme_Order

3. Remover parte intermediária do nome
```json
"transforms": "RemoveString",
"transforms.RemoveString.type": "org.apache.kafka.connect.transforms.RegexRouter",
"transforms.RemoveString.regex": "(.*)Stream_(.*)",
"transforms.RemoveString.replacement": "$1$2"
```
Antes: Order_Stream_Data → Depois: Order_Data
