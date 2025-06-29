#!/bin/bash
TOPIC=${TOPIC:-test-10}
BROKER=${BROKER:-kafka01:9092}
i=0
while true; do
  echo "message $i from producer" | kafka-console-producer.sh --broker-list $BROKER --topic $TOPIC > /dev/null
  echo "Produced: message $i"
  i=$((i+1))
  sleep 1
done