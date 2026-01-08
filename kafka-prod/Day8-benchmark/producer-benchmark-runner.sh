#!/bin/bash

# Kafka Benchmark Runner - Native Performance Testing
# Runs kafka-producer-perf-test.sh and saves results for comparison

set -e

# Configuration
BOOTSTRAP_SERVERS="${BOOTSTRAP_SERVERS:-localhost:29092,localhost:39092,localhost:49092}"
KAFKA_BIN="${KAFKA_BIN:-}"
NUM_RECORDS="${NUM_RECORDS:-1000000}"
RECORD_SIZE="${RECORD_SIZE:-1024}"
CLIENT_CONFIG="${CLIENT_CONFIG:-}"  # Optional: path to producer.properties file
RESULTS_DIR="./benchmark_results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_FILE="${RESULTS_DIR}/results_${TIMESTAMP}.csv"
RAW_DIR="${RESULTS_DIR}/raw"

# Topics to test (in logical order)
TOPICS=(
    "p1-rf1"
    "p1-rf3"
    "p3-rf3"
    "p12-rf3"
    "p30-rf3"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_header() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================${NC}"
}

print_info() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Find Kafka binaries
find_kafka_bin() {
    if [ -n "$KAFKA_BIN" ]; then
        if [ -x "$KAFKA_BIN/kafka-producer-perf-test.sh" ]; then
            echo "$KAFKA_BIN"
            return 0
        fi
    fi
    
    # Common Kafka installation paths
    local paths=(
        "/opt/kafka/bin"
        "/usr/local/kafka/bin"
        "$HOME/kafka/bin"
        "./bin"
        "../bin"
    )
    
    for path in "${paths[@]}"; do
        if [ -x "$path/kafka-producer-perf-test.sh" ]; then
            echo "$path"
            return 0
        fi
    done
    
    # Try to find in PATH
    if command -v kafka-producer-perf-test.sh &> /dev/null; then
        echo "$(dirname $(which kafka-producer-perf-test.sh))"
        return 0
    fi
    
    return 1
}

# Initialize results directory
init_results_dir() {
    mkdir -p "$RESULTS_DIR"
    mkdir -p "$RAW_DIR"
    
    # Create CSV header
    echo "timestamp,topic,partitions,replication_factor,num_records,record_size,throughput_mb_sec,avg_latency_ms,max_latency_ms,p50_latency_ms,p95_latency_ms,p99_latency_ms,p999_latency_ms,records_per_sec" > "$RESULT_FILE"
}

# Parse producer perf test output
parse_producer_output() {
    local output="$1"
    local topic="$2"
    
    # Extract metrics from output
    # Example: "100000 records sent, 19960.079681 records/sec (19.49 MB/sec), 25.67 ms avg latency, 448.00 ms max latency, 11 ms 50th, 109 ms 95th, 431 ms 99th, 447 ms 99.9th."
    
    # Use sed for compatibility with macOS (BSD grep doesn't support -P)
    local records_sent=$(echo "$output" | grep -oE '[0-9]+ records sent' | grep -oE '[0-9]+' | head -1)
    local records_per_sec=$(echo "$output" | grep -oE '[0-9]+\.[0-9]+ records/sec' | grep -oE '[0-9]+\.[0-9]+' | head -1)
    local throughput_mb=$(echo "$output" | grep -oE '\([0-9]+\.[0-9]+ MB/sec\)' | grep -oE '[0-9]+\.[0-9]+' | head -1)
    local avg_latency=$(echo "$output" | grep -oE '[0-9]+\.[0-9]+ ms avg latency' | grep -oE '[0-9]+\.[0-9]+' | head -1)
    local max_latency=$(echo "$output" | grep -oE '[0-9]+\.[0-9]+ ms max latency' | grep -oE '[0-9]+\.[0-9]+' | head -1)
    local p50_latency=$(echo "$output" | grep -oE '[0-9]+ ms 50th' | grep -oE '[0-9]+' | head -1)
    local p95_latency=$(echo "$output" | grep -oE '[0-9]+ ms 95th' | grep -oE '[0-9]+' | head -1)
    local p99_latency=$(echo "$output" | grep -oE '[0-9]+ ms 99th' | grep -oE '[0-9]+' | head -1)
    local p999_latency=$(echo "$output" | grep -oE '[0-9]+ ms 99\.9th' | grep -oE '[0-9]+' | head -1)
    
    # Extract partition and replication factor from topic name
    local partitions=$(echo "$topic" | sed -n 's/.*p\([0-9]*\).*/\1/p')
    local rf=$(echo "$topic" | sed -n 's/.*rf\([0-9]*\).*/\1/p')
    
    # Save to CSV
    echo "${TIMESTAMP},${topic},${partitions},${rf},${NUM_RECORDS},${RECORD_SIZE},${throughput_mb},${avg_latency},${max_latency},${p50_latency},${p95_latency},${p99_latency},${p999_latency},${records_per_sec}" >> "$RESULT_FILE"
    
    # Return formatted output
    cat << EOF
Topic: ${topic}
Records Sent: ${records_sent}
Throughput: ${throughput_mb} MB/sec
Records/sec: ${records_per_sec}
Avg Latency: ${avg_latency} ms
Max Latency: ${max_latency} ms
P50/P95/P99/P99.9: ${p50_latency}/${p95_latency}/${p99_latency}/${p999_latency} ms
EOF
}

# Run producer test for a topic
run_producer_test() {
    local topic="$1"
    local kafka_bin="$2"
    
    print_info "Testing topic: $topic"
    
    local raw_output_file="${RAW_DIR}/${topic}_${TIMESTAMP}.log"
    
    # Build command based on whether config file is provided
    if [ -n "$CLIENT_CONFIG" ] && [ -f "$CLIENT_CONFIG" ]; then
        print_info "Using producer config: $CLIENT_CONFIG"
        # Run test with config file
        local output=$("$kafka_bin/kafka-producer-perf-test.sh" \
            --topic "$topic" \
            --num-records "$NUM_RECORDS" \
            --record-size "$RECORD_SIZE" \
            --throughput -1 \
            --producer.config "$CLIENT_CONFIG" 2>&1 | tee "$raw_output_file")
    else
        # Run test with inline properties (default)
        local output=$("$kafka_bin/kafka-producer-perf-test.sh" \
            --topic "$topic" \
            --num-records "$NUM_RECORDS" \
            --record-size "$RECORD_SIZE" \
            --throughput -1 \
            --producer-props bootstrap.servers="$BOOTSTRAP_SERVERS" acks=1 2>&1 | tee "$raw_output_file")
    fi
    
    # Parse and display results
    echo ""
    parse_producer_output "$output" "$topic"
    echo ""
}

# Generate comparison report
generate_report() {
    local report_file="${RESULTS_DIR}/report_${TIMESTAMP}.txt"
    local html_report="${RESULTS_DIR}/report_${TIMESTAMP}.html"
    
    print_header "Generating Comparison Report"
    
    # Text report
    {
        echo "KAFKA BENCHMARK RESULTS"
        echo "======================="
        echo "Timestamp: ${TIMESTAMP}"
        echo "Bootstrap Servers: ${BOOTSTRAP_SERVERS}"
        echo "Records per Test: ${NUM_RECORDS}"
        echo "Record Size: ${RECORD_SIZE} bytes"
        echo ""
        echo "RESULTS SUMMARY"
        echo "==============="
        echo ""
        
        # Read CSV and format output
        tail -n +2 "$RESULT_FILE" | while IFS=',' read -r ts topic part rf num_rec rec_size throughput avg_lat max_lat p50 p95 p99 p999 rps; do
            echo "Topic: $topic (Partitions: $part, RF: $rf)"
            echo "  Throughput: $throughput MB/sec"
            echo "  Records/sec: $rps"
            echo "  Avg Latency: $avg_lat ms"
            echo "  P50/P95/P99: $p50/$p95/$p99 ms"
            echo ""
        done
        
        echo "PERFORMANCE RANKING (by Throughput)"
        echo "===================================="
        tail -n +2 "$RESULT_FILE" | sort -t',' -k7 -rn | head -5 | while IFS=',' read -r ts topic part rf num_rec rec_size throughput avg_lat max_lat p50 p95 p99 p999 rps; do
            echo "$topic: $throughput MB/sec"
        done
        
        echo ""
        echo "LOWEST LATENCY (by Avg Latency)"
        echo "================================"
        tail -n +2 "$RESULT_FILE" | sort -t',' -k8 -n | head -5 | while IFS=',' read -r ts topic part rf num_rec rec_size throughput avg_lat max_lat p50 p95 p99 p999 rps; do
            echo "$topic: $avg_lat ms"
        done
        
    } | tee "$report_file"
    
    # Generate HTML report
    generate_html_report "$html_report"
    
    print_info "Text report saved: $report_file"
    print_info "HTML report saved: $html_report"
    print_info "CSV data saved: $RESULT_FILE"
}

# Generate HTML report with charts
generate_html_report() {
    local html_file="$1"
    
    cat > "$html_file" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Kafka Benchmark Results</title>
    <script src="https://cdn.plot.ly/plotly-2.27.0.min.js"></script>
    <style>
        body { 
            font-family: Arial, sans-serif; 
            margin: 20px;
            background: #f5f5f5;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin-bottom: 30px;
        }
        .header h1 { margin: 0 0 10px 0; }
        .container { 
            max-width: 1400px; 
            margin: 0 auto;
            background: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .summary {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .summary-card {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .summary-card h3 { margin: 0 0 10px 0; font-size: 14px; opacity: 0.9; }
        .summary-card .value { font-size: 28px; font-weight: bold; }
        .summary-card .label { font-size: 12px; opacity: 0.8; margin-top: 5px; }
        table { 
            width: 100%; 
            border-collapse: collapse; 
            margin: 20px 0;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        th { 
            background: #667eea; 
            color: white; 
            padding: 12px;
            text-align: left;
            font-weight: bold;
        }
        td { 
            padding: 12px; 
            border-bottom: 1px solid #ddd;
        }
        tr:hover { background: #f5f5f5; }
        .chart { 
            margin: 30px 0;
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .best { color: #28a745; font-weight: bold; }
        .worst { color: #dc3545; font-weight: bold; }
    </style>
</head>
<body>
    <div class="header">
        <h1>🚀 Kafka Benchmark Results</h1>
        <p>Native kafka-producer-perf-test.sh Performance Analysis</p>
    </div>
    
    <div class="container">
        <div id="summary" class="summary"></div>
        
        <h2>📊 Detailed Results</h2>
        <table id="resultsTable">
            <thead>
                <tr>
                    <th>Topic</th>
                    <th>Partitions</th>
                    <th>RF</th>
                    <th>Throughput (MB/s)</th>
                    <th>Records/sec</th>
                    <th>Avg Latency (ms)</th>
                    <th>P99 Latency (ms)</th>
                </tr>
            </thead>
            <tbody id="resultsBody"></tbody>
        </table>
        
        <div class="chart" id="throughputChart"></div>
        <div class="chart" id="latencyChart"></div>
        <div class="chart" id="recordsChart"></div>
        <div class="chart" id="percentileChart"></div>
    </div>
    
    <script>
        // Embedded CSV data (works with file:// protocol)
        const csvData = `CSV_DATA_PLACEHOLDER`;
        
        function loadData() {
                const lines = csvData.trim().split('\n');
                const headers = lines[0].split(',');
                const data = lines.slice(1).map(line => {
                    const values = line.split(',');
                    return {
                        timestamp: values[0],
                        topic: values[1],
                        partitions: parseInt(values[2]),
                        rf: parseInt(values[3]),
                        num_records: parseInt(values[4]),
                        record_size: parseInt(values[5]),
                        throughput: parseFloat(values[6]),
                        avg_latency: parseFloat(values[7]),
                        max_latency: parseFloat(values[8]),
                        p50: parseFloat(values[9]),
                        p95: parseFloat(values[10]),
                        p99: parseFloat(values[11]),
                        p999: parseFloat(values[12]),
                        records_per_sec: parseFloat(values[13])
                    };
                });
                
                renderDashboard(data);
        }
        
        // Load data on page load
        window.addEventListener('DOMContentLoaded', loadData);
        
        function renderDashboard(data) {
            // Summary cards
            const totalRecords = data.reduce((sum, d) => sum + d.num_records, 0);
            const avgThroughput = data.reduce((sum, d) => sum + d.throughput, 0) / data.length;
            const bestThroughput = Math.max(...data.map(d => d.throughput));
            const bestTopic = data.find(d => d.throughput === bestThroughput).topic;
            
            document.getElementById('summary').innerHTML = `
                <div class="summary-card">
                    <h3>Total Records Tested</h3>
                    <div class="value">${totalRecords.toLocaleString()}</div>
                </div>
                <div class="summary-card">
                    <h3>Average Throughput</h3>
                    <div class="value">${avgThroughput.toFixed(2)}</div>
                    <div class="label">MB/sec</div>
                </div>
                <div class="summary-card">
                    <h3>Peak Throughput</h3>
                    <div class="value">${bestThroughput.toFixed(2)}</div>
                    <div class="label">MB/sec (${bestTopic})</div>
                </div>
                <div class="summary-card">
                    <h3>Topics Tested</h3>
                    <div class="value">${data.length}</div>
                </div>
            `;
            
            // Results table
            const tbody = document.getElementById('resultsBody');
            const maxThroughput = Math.max(...data.map(d => d.throughput));
            const minLatency = Math.min(...data.map(d => d.avg_latency));
            
            data.forEach(row => {
                const tr = document.createElement('tr');
                tr.innerHTML = `
                    <td>${row.topic}</td>
                    <td>${row.partitions}</td>
                    <td>${row.rf}</td>
                    <td class="${row.throughput === maxThroughput ? 'best' : ''}">${row.throughput.toFixed(2)}</td>
                    <td>${row.records_per_sec.toFixed(2)}</td>
                    <td class="${row.avg_latency === minLatency ? 'best' : ''}">${row.avg_latency.toFixed(2)}</td>
                    <td>${row.p99.toFixed(2)}</td>
                `;
                tbody.appendChild(tr);
            });
            
            // Charts
            createThroughputChart(data);
            createLatencyChart(data);
            createRecordsChart(data);
            createPercentileChart(data);
        }
        
        function createThroughputChart(data) {
            const trace = {
                x: data.map(d => d.topic),
                y: data.map(d => d.throughput),
                type: 'bar',
                marker: {
                    color: data.map(d => d.throughput),
                    colorscale: 'Viridis'
                },
                text: data.map(d => d.throughput.toFixed(2) + ' MB/s'),
                textposition: 'outside'
            };
            
            const layout = {
                title: 'Throughput Comparison (MB/sec)',
                xaxis: { title: 'Topic' },
                yaxis: { title: 'Throughput (MB/sec)' },
                height: 400
            };
            
            Plotly.newPlot('throughputChart', [trace], layout);
        }
        
        function createLatencyChart(data) {
            const trace1 = {
                x: data.map(d => d.topic),
                y: data.map(d => d.avg_latency),
                name: 'Avg Latency',
                type: 'bar',
                marker: { color: '#667eea' }
            };
            
            const trace2 = {
                x: data.map(d => d.topic),
                y: data.map(d => d.p99),
                name: 'P99 Latency',
                type: 'bar',
                marker: { color: '#764ba2' }
            };
            
            const layout = {
                title: 'Latency Comparison (ms)',
                xaxis: { title: 'Topic' },
                yaxis: { title: 'Latency (ms)' },
                barmode: 'group',
                height: 400
            };
            
            Plotly.newPlot('latencyChart', [trace1, trace2], layout);
        }
        
        function createRecordsChart(data) {
            const trace = {
                x: data.map(d => d.topic),
                y: data.map(d => d.records_per_sec),
                type: 'bar',
                marker: { color: '#28a745' },
                text: data.map(d => d.records_per_sec.toFixed(0)),
                textposition: 'outside'
            };
            
            const layout = {
                title: 'Records per Second',
                xaxis: { title: 'Topic' },
                yaxis: { title: 'Records/sec' },
                height: 400
            };
            
            Plotly.newPlot('recordsChart', [trace], layout);
        }
        
        function createPercentileChart(data) {
            const trace1 = {
                x: data.map(d => d.topic),
                y: data.map(d => d.p50),
                name: 'P50',
                type: 'scatter',
                mode: 'lines+markers',
                marker: { size: 10 }
            };
            
            const trace2 = {
                x: data.map(d => d.topic),
                y: data.map(d => d.p95),
                name: 'P95',
                type: 'scatter',
                mode: 'lines+markers',
                marker: { size: 10 }
            };
            
            const trace3 = {
                x: data.map(d => d.topic),
                y: data.map(d => d.p99),
                name: 'P99',
                type: 'scatter',
                mode: 'lines+markers',
                marker: { size: 10 }
            };
            
            const trace4 = {
                x: data.map(d => d.topic),
                y: data.map(d => d.p999),
                name: 'P99.9',
                type: 'scatter',
                mode: 'lines+markers',
                marker: { size: 10 }
            };
            
            const layout = {
                title: 'Latency Percentiles (ms)',
                xaxis: { title: 'Topic' },
                yaxis: { title: 'Latency (ms)' },
                height: 400
            };
            
            Plotly.newPlot('percentileChart', [trace1, trace2, trace3, trace4], layout);
        }
    </script>
</body>
</html>
EOF

    # Embed CSV data directly in HTML (for file:// protocol compatibility)
    # Create a temporary file with the CSV data properly escaped for JavaScript
    local temp_html="${html_file}.tmp"
    awk -v csvfile="$RESULT_FILE" '
        /CSV_DATA_PLACEHOLDER/ {
            printf "        const csvData = `"
            while ((getline line < csvfile) > 0) {
                gsub(/`/, "\\`", line)
                gsub(/\$/, "\\$", line)
                print line
            }
            close(csvfile)
            printf "`;\n"
            next
        }
        { print }
    ' "$html_file" > "$temp_html"
    mv "$temp_html" "$html_file"
}

# Main execution
main() {
    print_header "Kafka Native Benchmark Runner"
    
    # Find Kafka binaries
    print_info "Locating Kafka binaries..."
    KAFKA_BIN=$(find_kafka_bin)
    if [ $? -ne 0 ]; then
        print_error "Could not find Kafka binaries. Set KAFKA_BIN environment variable."
        exit 1
    fi
    print_info "Using Kafka binaries: $KAFKA_BIN"
    
    # Initialize
    init_results_dir
    print_info "Results directory: $RESULTS_DIR"
    if [ -n "$CLIENT_CONFIG" ] && [ -f "$CLIENT_CONFIG" ]; then
        print_info "Using config file: $CLIENT_CONFIG"
    else
        print_info "Bootstrap servers: $BOOTSTRAP_SERVERS"
    fi
    print_info "Records per test: $NUM_RECORDS"
    print_info "Record size: $RECORD_SIZE bytes"
    echo ""
    
    # Run tests
    print_header "Running Benchmark Tests"
    for topic in "${TOPICS[@]}"; do
        run_producer_test "$topic" "$KAFKA_BIN"
        sleep 2  # Brief pause between tests
    done
    
    # Generate reports
    generate_report
    
    print_header "Benchmark Complete! 🎉"
    print_info "Open the HTML report to view results:"
    echo ""
    echo "  open ${RESULTS_DIR}/report_${TIMESTAMP}.html"
    echo ""
}

# Run main function
main "$@"