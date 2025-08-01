<!--
Este README documenta o uso do Kafka Connect para integração de dados entre Kafka e outros sistemas, incluindo MySQL e arquivos locais. Os principais tópicos abordados são:

- Verificação dos plugins disponíveis no Kafka Connect.
- Utilização do Datagen Connector para geração de mensagens fictícias no tópico `transactions`.
- Consumo das mensagens do Kafka usando `kcat`, com opção de visualização via [VisiData](https://www.visidata.org/).
- Configuração do JdbcSinkConnector para persistir dados do tópico `transactions` em uma tabela MySQL, incluindo comandos para consulta dos dados.
- Alternativa de persistência dos dados em arquivo texto usando FileStreamSinkConnector.
- Comando para listar e verificar o status dos connectors configurados.
- Exemplos de uso de Single Message Transforms (SMT) para adicionar e formatar campos de timestamp nas mensagens antes de persistir no MySQL ou em arquivo.

Esses exemplos facilitam o entendimento e a prática de integração de dados com Kafka Connect, demonstrando desde a geração até o consumo e persistência dos dados, além de transformações intermediárias.
-->

# Exemplos de uso de Single Message Transforms (SMT) - InsertField (timestamp) 

- https://docs.confluent.io/kafka-connectors/transforms/current/insertfield.html
- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.InsertField 

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

Vamos utilizar o DatagenConnector para gerar nossas mensagens

```bash
curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/source-voluble-datagen-00/config \
    -d '{
        "connector.class": "io.confluent.kafka.connect.datagen.DatagenConnector",
        "kafka.topic": "transactions",
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
docker exec kafkacat kcat -b broker:29092 -t transactions -s key=s -s value=avro -r http://schema-registry:8081
```

Utilizando o kcat para consumir as mensagens com o [VisiData](https://www.visidata.org/)

```bash
docker exec kafkacat kcat -b broker:29092 -t transactions -s key=s -s value=avro -r http://schema-registry:8081 -C -e -o-100 | vd --filetype jsonl
```

Configurar o JdbcSinkConnector connector com mysql

```bash
curl -i -X PUT "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/sink-jdbc-mysql-00/config \
    -d '{
          "connector.class"     : "io.confluent.connect.jdbc.JdbcSinkConnector",
          "connection.url"      : "jdbc:mysql://mysql:3306/demo",
          "connection.user"     : "mysqluser",
          "connection.password" : "mysqlpw",
          "topics"              : "transactions",
          "tasks.max"           : "1",
          "auto.create"         : "true"
        }'
```

Podemos ver as mensagens no banco

```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SELECT * FROM transactions;"
```

Poderia ser em um S3, mas vamos apenas criar um arquivo txt com FileStreamSinkConnector.
```bash
curl -i -X PUT -H "Accept:application/json" \
    -H "Content-Type:application/json" http://localhost:8083/connectors/sink-filestream-00/config \
    -d '{
          "connector.class"        : "org.apache.kafka.connect.file.FileStreamSinkConnector",
          "tasks.max"              : "1",
          "topics"                 : "customers,transactions",
          "file"                   : "/tmp/kafka-output.txt"
        }'
```

Verificar nosso arquivo .txt

```bash
docker exec -it connect cat /tmp/kafka-output.txt
```

Comando para verificar se nossos connectors estão rodando.

```bash
curl -s "http://localhost:8083/connectors?expand=info&expand=status" | \
       jq '. | to_entries[] | [ .value.info.type, .key, .value.status.connector.state,.value.status.tasks[].state,.value.info.config."connector.class"]|join(":|:")' | \
       column -s : -t| sed 's/\"//g'| sort
```


Atualizando o JdbcSinkConnector para utilizar o transform, onde vamos adicionar uma nova coluna com timestamp no mysql.

```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/sink-jdbc-mysql-00/config \
    -d '{
          "connector.class"     : "io.confluent.connect.jdbc.JdbcSinkConnector",
          "connection.url"      : "jdbc:mysql://mysql:3306/demo",
          "connection.user"     : "mysqluser",
          "connection.password" : "mysqlpw",
          "topics"              : "transactions",
          "tasks.max"           : "1",
          "auto.create"         : "true",
          "auto.evolve"         : "true",
          "transforms"          : "insertTS",
          "transforms.insertTS.type": "org.apache.kafka.connect.transforms.InsertField$Value",
          "transforms.insertTS.timestamp.field": "messageTS"
        }'
```

Vamos aplicar a mesma transformação ao FileStreamSinkConnector
```bash
curl -i -X PUT -H "Accept:application/json" \
    -H "Content-Type:application/json" http://localhost:8083/connectors/sink-filestream-00/config \
    -d '{
          "connector.class"        : "org.apache.kafka.connect.file.FileStreamSinkConnector",
          "tasks.max"              : "1",
          "topics"                 : "customers,transactions",
          "file"                   : "/tmp/kafka-output2.txt",
          "transforms"                          : "insertTS,formatTS",
          "transforms.insertTS.type"            : "org.apache.kafka.connect.transforms.InsertField$Value",
          "transforms.insertTS.timestamp.field" : "messageTS",
          "transforms.formatTS.type"            : "org.apache.kafka.connect.transforms.TimestampConverter$Value",
          "transforms.formatTS.format"          : "yyyy-MM-dd HH:mm:ss:SSS",
          "transforms.formatTS.field"           : "messageTS",
          "transforms.formatTS.target.type"     : "string"
        }'
```
# Benefícios de Utilizar o InsertField no SMT do Kafka Connect

- https://docs.confluent.io/kafka-connectors/transforms/current/insertfield.html

- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.InsertField

O SMT InsertField permite adicionar campos extras a cada mensagem trafegada por um conector no Kafka Connect, seja no valor, na chave ou ambos. Ele pode inserir valores provenientes de metadados da mensagem (como tópico, partição, offset, timestamp) ou incluir um valor totalmente estático e configurável.

## Por Que Usar o InsertField
- Enriquecimento de Dados: Você pode enriquecer as mensagens, acrescentando informações contextuais importantes antes do dado ser enviado ao sistema de destino, sem alterar os conectores nem implementar lógica adicional externa.

- Padronização e Auditoria: Inserir campos como timestamp, nome do tópico, partição ou outros metadados facilita rastrear, auditar e padronizar entradas em bancos de dados, data lakes, sistemas analíticos, etc.

- Facilidade de Integração: Sistemas de destino muitas vezes precisam de campos extras (como identificadores, origens ou datas de processamento) que não estão no dado original – InsertField permite atender esse requisito sem modificar a aplicação ou fluxo de origem.

- Rapidez e Simplicidade: Tudo é feito por configuração, eliminando a necessidade de desenvolver, manter e versionar código customizado para simples transformações.

## Casos de Uso Comuns
- Adição de Campos de Timestamp: Inserir um campo com o timestamp do processamento da mensagem ao exportar dados para sistemas de armazenamento, como bancos SQL ou S3 – útil para rastrear quando aquele dado foi ingerido ou exportado.

- Inclusão de Metadados do Kafka: Adicionar informações como nome do tópico, partição e offset em cada registro, facilitando investigações, debugging e análise posterior.

- Tagueamento de Origem: Incluir um campo estático indicando a origem do dado, como "fonte": "Kafka Connect", para uso em pipelines onde múltiplas fontes coexistem.

- Configuração de Time-To-Live: Inserir um campo de TTL (Time To Live) em plataformas como Cosmos DB, permitindo controle do tempo de vida de cada registro exportado.

- Facilitar Processos de UPSERT: Adicionar um campo auxiliar como chave única artificial quando os dados de origem não ajudam na identificação unívoca do registro em processos de upsert em bancos relacionais.

- Adaptação de Schema: Quando o destino exige obrigatoriamente certos campos, InsertField pode garantir que todos os registros recebam esse campo, mesmo que não exista na origem.