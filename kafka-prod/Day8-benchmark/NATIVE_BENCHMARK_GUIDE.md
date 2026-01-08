# Native Kafka Benchmark Runner 🚀

Ultra-lightweight bash script that runs native `kafka-producer-perf-test.sh` and generates comparison reports. **Zero Python dependencies** - just pure bash and native Kafka tools for maximum performance!

## Why Use This?

- ✅ **Native Performance** - Uses Kafka's own performance tools directly
- ✅ **Zero Dependencies** - No Python, no pip, just bash
- ✅ **Faster Execution** - No wrapper overhead
- ✅ **Beautiful Reports** - HTML reports with interactive Plotly charts
- ✅ **CSV Export** - Easy to analyze in Excel/Google Sheets
- ✅ **Historical Tracking** - Timestamped results for comparison over time

## Quick Start

### 1. Run Benchmark

```bash
./benchmark-runner.sh
```

That's it! The script will:
1. Auto-detect your Kafka installation
2. Run tests on all configured topics
3. Save results to CSV
4. Generate interactive HTML report
5. Open the report in your browser

### 2. Custom Configuration

```bash
# Custom Kafka installation
KAFKA_BIN=/opt/kafka/bin ./benchmark-runner.sh

# Custom bootstrap servers
BOOTSTRAP_SERVERS=localhost:9092 ./benchmark-runner.sh

# Larger test (5M records, 2KB each)
NUM_RECORDS=5000000 RECORD_SIZE=2048 ./benchmark-runner.sh

# All together
KAFKA_BIN=/opt/kafka/bin \
BOOTSTRAP_SERVERS=broker1:9092,broker2:9092 \
NUM_RECORDS=2000000 \
RECORD_SIZE=2048 \
./benchmark-runner.sh
```

## Configuration Options

Set these as environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `KAFKA_BIN` | Auto-detect | Path to Kafka bin directory |
| `BOOTSTRAP_SERVERS` | localhost:29092,... | Kafka broker addresses |
| `NUM_RECORDS` | 1000000 | Records per test |
| `RECORD_SIZE` | 1024 | Record size in bytes |

## Output Files

All results saved to `benchmark_results/` directory:

### 1. CSV Data File
```
results_20260106_120530.csv
```
Contains all raw metrics for analysis in Excel/Sheets.

### 2. HTML Report
```
report_20260106_120530.html
```
Interactive dashboard with:
- Summary statistics cards
- Throughput comparison chart
- Latency analysis (Avg, P99)
- Records/sec comparison
- Percentile latency trends (P50, P95, P99, P99.9)

### 3. Text Report
```
report_20260106_120530.txt
```
Plain text summary for quick terminal viewing.

### 4. Raw Logs
```
raw/p1-rf1_20260106_120530.log
raw/p1-rf3_20260106_120530.log
...
```
Complete output from each test run.

## Topics Tested

The script tests these topics in order:

1. **p1-rf1** - Baseline (1 partition, RF=1)
2. **p1-rf3** - Replication impact (1 partition, RF=3)
3. **p3-rf3** - 3 partitions, RF=3
4. **p12-rf3** - 12 partitions, RF=3
5. **p30-rf3** - 30 partitions, RF=3

To change topics, edit the `TOPICS` array in the script.

## Example Usage

### Quick Test (100K records)
```bash
NUM_RECORDS=100000 ./benchmark-runner.sh
```

### Production-Scale Test (10M records, 2KB)
```bash
NUM_RECORDS=10000000 RECORD_SIZE=2048 ./benchmark-runner.sh
```

### Remote Cluster
```bash
BOOTSTRAP_SERVERS=prod-kafka1:9092,prod-kafka2:9092,prod-kafka3:9092 \
./benchmark-runner.sh
```

## Viewing Results

### HTML Report (Recommended)
```bash
# macOS
open benchmark_results/report_*.html

# Linux
xdg-open benchmark_results/report_*.html
```

### Text Report
```bash
cat benchmark_results/report_*.txt
```

### CSV Analysis
```bash
# View in terminal
column -t -s, benchmark_results/results_*.csv | less -S

# Import to Excel/Google Sheets
# File > Import > benchmark_results/results_*.csv
```

## Sample Output

```
================================================
Running Benchmark Tests
================================================
✓ Testing topic: p1-rf1

Topic: p1-rf1
Records Sent: 1000000
Throughput: 45.23 MB/sec
Records/sec: 46345.78
Avg Latency: 12.34 ms
Max Latency: 234.56 ms
P50/P95/P99/P99.9: 8/34/67/189 ms

✓ Testing topic: p1-rf3
...

================================================
Generating Comparison Report
================================================
✓ Text report saved: benchmark_results/report_20260106_120530.txt
✓ HTML report saved: benchmark_results/report_20260106_120530.html
✓ CSV data saved: benchmark_results/results_20260106_120530.csv

================================================
Benchmark Complete! 🎉
================================================
✓ Open the HTML report to view results:

  open benchmark_results/report_20260106_120530.html
```

## Comparing Multiple Runs

The script saves timestamped results, making it easy to compare runs:

```bash
# Run 1: Current configuration
./benchmark-runner.sh

# Run 2: After tuning
# ... make configuration changes ...
./benchmark-runner.sh

# Compare both HTML reports side by side
open benchmark_results/report_*.html
```

## Tips for Accurate Benchmarks

1. **Clean Between Runs**: Delete topics or wait for retention to expire
   ```bash
   kafka-topics.sh --delete --bootstrap-server localhost:9092 --topic 'p.*-rf.*'
   ```

2. **Warm Up**: Run once to warm up the cluster, then run again for real results

3. **Consistent Load**: Don't run other heavy workloads during benchmarking

4. **Multiple Runs**: Run 3-5 times and average the results for accuracy

5. **Monitor Resources**: Use `iostat`, `iftop`, `top` to identify bottlenecks

## Troubleshooting

### "Could not find Kafka binaries"
```bash
# Specify path explicitly
KAFKA_BIN=/path/to/kafka/bin ./benchmark-runner.sh
```

### "Connection refused"
```bash
# Check if Kafka is running
kafka-topics.sh --bootstrap-server localhost:9092 --list

# Or specify correct brokers
BOOTSTRAP_SERVERS=your-broker:9092 ./benchmark-runner.sh
```

### Topics don't exist
```bash
# Create topics first (see main README.md)
kafka-topics.sh --create --bootstrap-server localhost:9092 --topic p1-rf1 --partitions 1 --replication-factor 1
```

## Advanced: Add Custom Topics

Edit the `TOPICS` array in the script:

```bash
# Add your topics
TOPICS=(
    "p1-rf1"
    "p1-rf3"
    "p6-rf3"     # Add this
    "p12-rf3"
    "my-topic"   # Add this
)
```

## Performance Comparison

**Python Version** (Day8-benchmark-v2):
- Pros: More features, consumer tests, pretty code
- Cons: Slower, needs Python/pandas/plotly

**Bash Version** (This script):
- Pros: Faster, native performance, zero dependencies
- Cons: Producer tests only, less flexible

**When to use which:**
- Use **Bash version** for: Quick producer benchmarks, maximum performance, no Python available
- Use **Python version** for: Consumer tests, complex analysis, existing Python environment

## Integration with CI/CD

```yaml
# .github/workflows/benchmark.yml
- name: Run Kafka Benchmark
  run: |
    cd Day8-benchmark
    ./benchmark-runner.sh
    
- name: Upload Results
  uses: actions/upload-artifact@v3
  with:
    name: benchmark-results
    path: benchmark_results/
```

---

**Ready to benchmark? Just run `./benchmark-runner.sh` and get native Kafka performance! ⚡**
