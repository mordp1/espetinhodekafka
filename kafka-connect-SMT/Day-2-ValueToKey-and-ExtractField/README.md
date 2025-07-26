<!--
# Exemplos de SMT do Kafka Connect: ValueToKey, ExtractField

Esta documentação fornece instruções e explicações passo a passo sobre o uso de Transformações de Mensagem Única (SMT) no Kafka Connect, com foco nas transformações `ValueToKey` e `ExtractField`. Ela aborda:

- Inicialização do ambiente Kafka Connect usando o Docker Compose.
- Verificação da prontidão do Kafka Connect e dos plugins de conector disponíveis.
- Configuração do `JdbcSourceConnector` com MySQL como fonte.
- Uso do `kcat` (antigo kafkacat) para inspecionar tópicos do Kafka e consumir mensagens.
- Aplicação da SMT `ValueToKey` para promover um campo do valor da mensagem para a chave.
- Encadeamento das SMTs `ValueToKey` e `ExtractField` para extrair um campo específico como chave da mensagem.
- Exemplos práticos de consumo de mensagens transformadas.

Referências à documentação oficial para leitura adicional sobre `ValueToKey` e `ExtractField` também são fornecidas.

Este guia destina-se a usuários que buscam enriquecer, transformar e adaptar dados que fluem pelo Kafka Connect sem código personalizado, aproveitando SMTs integrados para pipelines de dados flexíveis e sustentáveis.
-->

# Exemplos de uso de Single Message Transforms (SMT) - ValueToKey and ExtractField

- https://docs.confluent.io/kafka-connectors/transforms/current/valuetokey.html
- https://docs.confluent.io/kafka-connectors/transforms/current/extractfield.html
- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.ValueToKey
- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.ExtractField


O uso de ValueToKey e ExtractField garante que seus dados sejam particionados logicamente por chaves, permite compatibilidade com sistemas downstream, melhora a semântica de processamento e oferece escalabilidade e confiabilidade robustas para arquiteturas orientadas a eventos, seguindo as melhores práticas.


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

Verificar os plugins do Kafka Connect

```bash
curl -s http://localhost:8083/connector-plugins | jq 
```

Configurar o JdbcSourceConnector connector com mysql

```bash
curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/source-jdbc-mysql-00/config \
    -d '{
          "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
          "connection.url": "jdbc:mysql://mysql:3306/demo",
          "connection.user": "mysqluser",
          "connection.password": "mysqlpw",
          "topic.prefix": "mysql-00-",
          "poll.interval.ms": 1000,
          "tasks.max":1,
          "table.whitelist" : "customers",
          "mode":"incrementing",
          "incrementing.column.name": "id",
          "validate.non.null": false
          }'
```

Comando para verificar se nossos connectors estão rodando.

```bash
curl -s "http://localhost:8083/connectors?expand=info&expand=status" | \
       jq '. | to_entries[] | [ .value.info.type, .key, .value.status.connector.state,.value.status.tasks[].state,.value.info.config."connector.class"]|join(":|:")' | \
       column -s : -t| sed 's/\"//g'| sort
```

Listar Topicos kcat
```bash
docker exec kafkacat kcat -b broker:29092 -L -J | jq '.topics[].topic'|sort
```

Podemos ver as mensagens no banco
```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SELECT * FROM customers;"
```

Utilizando o kcat para consumir 1 mensagem: 
```bash
docker exec kafkacat kcat -b broker:29092 -r http://schema-registry:8081 -s key=s -s value=avro -t mysql-00-customers -C -c1 -o beginning -u -q -J | jq '.'
```

Atualizando o JdbcSourceConnector para utilizar o transform ValueToKey, onde vamos adicionar uma nova key
```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/source-jdbc-mysql-01/config \
    -d '{
          "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
          "connection.url": "jdbc:mysql://mysql:3306/demo",
          "connection.user": "mysqluser",
          "connection.password": "mysqlpw",
          "topic.prefix": "mysql-01-",
          "poll.interval.ms": 1000,
          "tasks.max":1,
          "table.whitelist" : "customers",
          "mode":"incrementing",
          "incrementing.column.name": "id",
          "validate.non.null": false,
          "transforms": "copyIdToKey",
          "transforms.copyIdToKey.type": "org.apache.kafka.connect.transforms.ValueToKey",
          "transforms.copyIdToKey.fields": "id"
      }'
```
Utilizando o kcat para consumir 1 mensagem: 
```bash
docker exec kafkacat kcat -b broker:29092 -r http://schema-registry:8081 -s key=s -s value=avro -t mysql-01-customers -C -c1 -o beginning -u -q -J | jq '.'
```

Atualizando o JdbcSourceConnector para utilizar o transform ValueToKey and ExtractField
```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/source-jdbc-mysql-02/config \
    -d '{
          "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
          "connection.url": "jdbc:mysql://mysql:3306/demo",
          "connection.user": "mysqluser",
          "connection.password": "mysqlpw",
          "topic.prefix": "mysql-02-",
          "poll.interval.ms": 1000,
          "tasks.max":1,
          "table.whitelist" : "customers",
          "mode":"incrementing",
          "incrementing.column.name": "id",
          "validate.non.null": false,
          "transforms": "copyIdToKey,extractKeyFromStruct",
          "transforms.copyIdToKey.type": "org.apache.kafka.connect.transforms.ValueToKey",
          "transforms.copyIdToKey.fields": "id",
          "transforms.extractKeyFromStruct.type":"org.apache.kafka.connect.transforms.ExtractField$Key",
          "transforms.extractKeyFromStruct.field":"id"
      }'
```

Utilizando o kcat para consumir 1 mensagem: 
```bash
docker exec kafkacat kcat -b broker:29092 -r http://schema-registry:8081 -s key=s -s value=avro -t mysql-02-customers -C -c1 -o beginning -u -q -J | jq '.'
```

# Benefícios de Utilizar o ValueToKey e ExtractField no SMT do Kafka Connect

- https://docs.confluent.io/kafka-connectors/transforms/current/valuetokey.html
- https://docs.confluent.io/kafka-connectors/transforms/current/extractfield.html

- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.ValueToKey
- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.ExtractField

## O que é o ValueToKey?
O ValueToKey é um Single Message Transform (SMT) do Kafka Connect que permite definir a chave da mensagem (message key) com base em um ou mais campos do valor (value) da mensagem original.
Em muitas integrações, o conector de origem pode não definir a chave do registro, ou essa chave não é o campo mais útil para o downstream (por exemplo, para garantir particionamento, idempotência ou joins).

- Como funciona?
Ele copia um ou mais campos do value para formar a key do registro, sobrescrevendo o valor anterior.
O campo é especificado com a configuração fields.

## O que é o ExtractField?
O ExtractField é outro SMT usado para extrair e selecionar um campo específico de uma estrutura (Struct) no key ou value e substituir totalmente esse lado pelo valor extraído.
É comumente utilizado junto com o ValueToKey para simplificar a key: transformar uma estrutura completa em um valor primitivo.

- Como funciona?
Usa o tipo ExtractField$Key (para extrair do key) ou ExtractField$Value (para extrair do value), e o parâmetro field aponta para o nome do campo desejado.

**Uma combinação comum é usar primeiro o ValueToKey para definir a chave da mensagem e, em seguida, o ExtractField para garantir que a chave seja um valor primitivo (por exemplo, um inteiro ou string), especialmente útil em integrações via JDBC**

##  Casos de Uso Mais Comuns
|Cenário	| Benefício| 
|---|---|
|Particionamento Eficiente|	Garantir que mensagens com o mesmo valor para “id” ou outro campo relevante vão para a mesma partição Kafka.|
|Preparar dados para Kafka Streams/ksqlDB |	Muitos processamentos e joins exigem que o dado esteja "keyed" corretamente.|
|CDC e integrações com bancos relacionais	| Banco espera chave primária como key do tópico para upserts/idempotência. |
| Simplificação de dados para cargas em sinks |	Eliminar aninhamentos, tornando a key compatível com sistemas finais como bancos relacionais.|