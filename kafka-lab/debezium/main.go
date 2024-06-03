package main

import (
    "fmt"
    "github.com/confluentinc/confluent-kafka-go/kafka"
    "github.com/riferrei/srclient"
)

func main() {
    consumer, err := kafka.NewConsumer(&kafka.ConfigMap{
        "bootstrap.servers":        "kafka-staging-kafka-bootstrap.kafka.svc.cluster.local:9093",
        "security.protocol":        "ssl",
        "ssl.ca.location":          "ca.crt",
        "ssl.certificate.location": "user.crt",
        "ssl.key.location":         "user.key",
        "group.id":                 "your_group_id",
        "auto.offset.reset":        "earliest",
    })

    if err != nil {
        panic(err)
    }

    consumer.SubscribeTopics([]string{"ap-con-debezium-test.inventory.customers"}, nil)

    schemaRegistryClient := srclient.CreateSchemaRegistryClient("http://apicurioregistry-service.kafka.svc.cluster.local:8080/apis/registry/v2")

    for {
        msg, err := consumer.ReadMessage(-1)
        if err != nil {
            fmt.Printf("Consumer error: %v (%v)\n", err, msg)
            break
        }

        schema, err := schemaRegistryClient.GetSchema(int(msg.TopicPartition.Partition))
        if err != nil {
            fmt.Printf("Error getting schema: %v\n", err)
            break
        }

        value, err := schema.AvroToNative(msg.Value)
        if err != nil {
            fmt.Printf("Error deserializing Avro message: %v\n", err)
            break
        }

        fmt.Printf("Message on %s: %v\n", msg.TopicPartition, value)
    }

    consumer.Close()
}
