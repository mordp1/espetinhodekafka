# espetinhodekafka
Amazon Managed Streaming for Apache Kafka  (MSK).

Entenda de vez quem é ele, onde vive, do que se alimentam? 

Venho por meio deste vídeo, apresentar um pouco do meu conhecimento sobre esta ferramenta poderosa que a AWS disponibiliza para utilizarmos e ao mesmo tempo compartilhar algumas experiencias reais utilizando em ambiente produtivo.

## Canal no Youtube
https://www.youtube.com/@espetinhodekafka

## Commands

Create topic 

```bash
kafka-topics.sh --bootstrap-server localhost:9092   \
  --create --topic tiered \
  --partitions 6 \
  --replication-factor 3 \
  --config remote.storage.enable=true \
  --config local.retention.ms=43200000 \
  --config log.retention.ms=-1 \
  --config log.retention.bytes=-1 \
  --config segment.bytes=10485760
```

Alter topic
 
```bash
kafka-configs.sh --bootstrap-server localhost:9092   \
  --alter --entity-type topics \
  --entity-name tiered \
  --add-config remote.storage.enable=true \
  --add-config local.retention.ms=43200000 \
  --add-config log.retention.ms=-1 \
  --add-config log.retention.bytes=-1 
```

## Links

Aqui você pode acompanhar todos os linkss utilizados no cada video para facilitar no aprendizado.

[Conduktor - Kafka Topic Internals: Segments and Indexes](https://www.conduktor.io/kafka/kafka-topics-internals-segments-and-indexes/)

[Confluent - Tiered Storage Best practices and recommendations](https://docs.confluent.io/platform/current/kafka/tiered-storage.html#best-practices-and-recommendations)

[AWS - Tiered storage ](https://docs.aws.amazon.com/msk/latest/developerguide/msk-tiered-storage.html)

[AWS - Deep dive on Amazon MSK tiered storage ](https://aws.amazon.com/blogs/big-data/deep-dive-on-amazon-msk-tiered-storage/)