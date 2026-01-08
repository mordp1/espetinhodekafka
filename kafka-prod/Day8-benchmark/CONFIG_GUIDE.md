# Using Configuration Files with Benchmark Scripts

## Overview

Both benchmark scripts now support using configuration files instead of command-line properties. This is essential for scenarios requiring:
- TLS/SSL encryption
- SASL authentication
- Complex performance tuning
- Multiple custom properties

## Producer Benchmarks

### Method 1: Inline Properties (Default)
```bash
# Simple usage with default settings
./benchmark-runner.sh

# Custom bootstrap servers
BOOTSTRAP_SERVERS=broker1:9092,broker2:9092 ./benchmark-runner.sh
```

### Method 2: Configuration File (TLS/Complex Scenarios)
```bash
# Use producer.config file
CLIENT_CONFIG=producer.config ./benchmark-runner.sh

# With custom number of records
CLIENT_CONFIG=producer.config NUM_RECORDS=5000000 ./benchmark-runner.sh

# With custom config file path
CLIENT_CONFIG=/path/to/my-producer.properties ./benchmark-runner.sh
```

## Consumer Benchmarks

### Method 1: Inline Properties (Default)
```bash
# Simple usage
./consumer-benchmark-runner.sh

# Custom bootstrap servers
BOOTSTRAP_SERVERS=broker1:9092,broker2:9092 ./consumer-benchmark-runner.sh
```

### Method 2: Configuration File (TLS/Complex Scenarios)
```bash
# Use consumer.config file
CLIENT_CONFIG=consumer.config ./consumer-benchmark-runner.sh

# With custom number of messages
CLIENT_CONFIG=consumer.config NUM_MESSAGES=2000000 ./consumer-benchmark-runner.sh

# With custom config file path
CLIENT_CONFIG=/path/to/my-consumer.properties ./consumer-benchmark-runner.sh
```

## Configuration File Templates

### Producer Config (producer.config)
```properties
# Basic
bootstrap.servers=localhost:29092,localhost:39092,localhost:49092
acks=1

# TLS/SSL
security.protocol=SSL
ssl.truststore.location=/path/to/kafka.client.truststore.jks
ssl.truststore.password=your-password
ssl.keystore.location=/path/to/kafka.client.keystore.jks
ssl.keystore.password=your-password
ssl.key.password=your-password

# Performance
batch.size=16384
linger.ms=0
compression.type=lz4
```

### Consumer Config (consumer.config)
```properties
# Basic
bootstrap.servers=localhost:29092,localhost:39092,localhost:49092

# TLS/SSL
security.protocol=SSL
ssl.truststore.location=/path/to/kafka.client.truststore.jks
ssl.truststore.password=your-password
ssl.keystore.location=/path/to/kafka.client.keystore.jks
ssl.keystore.password=your-password
ssl.key.password=your-password

# Performance
fetch.min.bytes=1
fetch.max.wait.ms=500
max.partition.fetch.bytes=1048576
```

## Common Scenarios

### 1. TLS-Enabled Kafka Cluster

**producer.config:**
```properties
bootstrap.servers=kafka-ssl:9093
security.protocol=SSL
ssl.truststore.location=/etc/kafka/ssl/kafka.client.truststore.jks
ssl.truststore.password=changeit
ssl.keystore.location=/etc/kafka/ssl/kafka.client.keystore.jks
ssl.keystore.password=changeit
ssl.key.password=changeit
acks=all
```

**Run:**
```bash
CLIENT_CONFIG=producer.config ./benchmark-runner.sh
```

### 2. SASL/SCRAM Authentication

**producer.config:**
```properties
bootstrap.servers=kafka-sasl:9094
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-256
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="admin" password="admin-secret";
ssl.truststore.location=/etc/kafka/ssl/kafka.client.truststore.jks
ssl.truststore.password=changeit
acks=1
```

**Run:**
```bash
CLIENT_CONFIG=producer.config NUM_RECORDS=2000000 ./benchmark-runner.sh
```

### 3. AWS MSK with IAM Authentication

**producer.config:**
```properties
bootstrap.servers=b-1.msk-cluster.kafka.us-east-1.amazonaws.com:9098
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
acks=1
```

**Run:**
```bash
CLIENT_CONFIG=producer.config ./benchmark-runner.sh
```

### 4. Performance Tuning Test

**producer-high-throughput.config:**
```properties
bootstrap.servers=localhost:9092
acks=1
batch.size=65536
linger.ms=10
compression.type=lz4
buffer.memory=67108864
max.in.flight.requests.per.connection=5
```

**producer-low-latency.config:**
```properties
bootstrap.servers=localhost:9092
acks=1
batch.size=0
linger.ms=0
compression.type=none
max.in.flight.requests.per.connection=1
```

**Run comparison:**
```bash
# High throughput test
CLIENT_CONFIG=producer-high-throughput.config ./benchmark-runner.sh

# Low latency test
CLIENT_CONFIG=producer-low-latency.config ./benchmark-runner.sh

# Compare the HTML reports!
```

## Environment Variables

### Producer Script
- `CLIENT_CONFIG` - Path to producer properties file (optional)
- `BOOTSTRAP_SERVERS` - Broker addresses (ignored if CLIENT_CONFIG is set)
- `NUM_RECORDS` - Number of records per test (default: 1000000)
- `RECORD_SIZE` - Record size in bytes (default: 1024)
- `KAFKA_BIN` - Path to Kafka binaries (auto-detected)

### Consumer Script
- `CLIENT_CONFIG` - Path to consumer properties file (optional)
- `BOOTSTRAP_SERVERS` - Broker addresses (ignored if CLIENT_CONFIG is set)
- `NUM_MESSAGES` - Number of messages per test (default: 1000000)
- `KAFKA_BIN` - Path to Kafka binaries (auto-detected)

## Tips

1. **Always test config files first:**
   ```bash
   # Verify producer config
   kafka-console-producer.sh --bootstrap-server localhost:9092 \
     --topic test --producer.config producer.config
   
   # Verify consumer config
   kafka-console-consumer.sh --bootstrap-server localhost:9092 \
     --topic test --consumer.config consumer.config --from-beginning
   ```

2. **Use absolute paths for SSL certificates** in config files

3. **Keep sensitive credentials secure** - don't commit config files with passwords to git

4. **Test with small NUM_RECORDS first** when using new configurations:
   ```bash
   CLIENT_CONFIG=producer.config NUM_RECORDS=10000 ./benchmark-runner.sh
   ```

5. **Compare results** by running multiple tests with different configs and comparing HTML reports

## Troubleshooting

### "Could not connect to broker"
- Check bootstrap.servers in config file
- Verify network connectivity
- Check firewall rules

### "SSL handshake failed"
- Verify truststore/keystore paths are absolute
- Check passwords are correct
- Ensure certificates are valid

### "SASL authentication failed"
- Verify username/password in jaas.config
- Check SASL mechanism matches broker configuration
- Ensure proper escaping of special characters in passwords

### "Config file not found"
- Use absolute path or path relative to script location
- Check file permissions (should be readable)

## Example Workflow: TLS Cluster Benchmark

```bash
# 1. Create producer config with TLS settings
cat > producer-tls.config << EOF
bootstrap.servers=kafka-tls:9093
security.protocol=SSL
ssl.truststore.location=/etc/kafka/ssl/kafka.truststore.jks
ssl.truststore.password=changeit
acks=all
EOF

# 2. Create consumer config with TLS settings
cat > consumer-tls.config << EOF
bootstrap.servers=kafka-tls:9093
security.protocol=SSL
ssl.truststore.location=/etc/kafka/ssl/kafka.truststore.jks
ssl.truststore.password=changeit
EOF

# 3. Run producer benchmark
CLIENT_CONFIG=producer-tls.config NUM_RECORDS=1000000 ./benchmark-runner.sh

# 4. Run consumer benchmark  
CLIENT_CONFIG=consumer-tls.config NUM_MESSAGES=1000000 ./consumer-benchmark-runner.sh

# 5. Compare HTML reports
open benchmark_results/report_*.html
open benchmark_results/consumer_report_*.html
```

---

**Pro Tip:** Create different config files for different environments (dev, staging, prod) and scenarios (TLS, SASL, performance tuning) to easily compare performance across configurations.
