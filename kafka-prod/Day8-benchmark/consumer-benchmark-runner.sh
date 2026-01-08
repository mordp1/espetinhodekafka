#!/bin/bash

# Kafka Consumer Benchmark Runner - Native Performance Testing
# Runs kafka-consumer-perf-test.sh and saves results for comparison

set -e

# Configuration
BOOTSTRAP_SERVERS="${BOOTSTRAP_SERVERS:-localhost:29092,localhost:39092,localhost:49092}"
KAFKA_BIN="${KAFKA_BIN:-}"
NUM_MESSAGES="${NUM_MESSAGES:-1000000}"
CLIENT_CONFIG="${CLIENT_CONFIG:-}"  # Optional: path to consumer.properties file
RESULTS_DIR="./benchmark_results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_FILE="${RESULTS_DIR}/consumer_results_${TIMESTAMP}.csv"
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
        if [ -x "$KAFKA_BIN/kafka-consumer-perf-test.sh" ]; then
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
        if [ -x "$path/kafka-consumer-perf-test.sh" ]; then
            echo "$path"
            return 0
        fi
    done
    
    # Try to find in PATH
    if command -v kafka-consumer-perf-test.sh &> /dev/null; then
        echo "$(dirname $(which kafka-consumer-perf-test.sh))"
        return 0
    fi
    
    return 1
}

# Initialize results directory
init_results_dir() {
    mkdir -p "$RESULTS_DIR"
    mkdir -p "$RAW_DIR"
    
    # Create CSV header
    echo "timestamp,topic,partitions,replication_factor,num_messages,data_consumed_mb,throughput_mb_sec,messages_consumed,messages_per_sec,rebalance_time_ms,fetch_time_ms,fetch_mb_sec,fetch_msg_sec" > "$RESULT_FILE"
}

# Parse consumer perf test output
parse_consumer_output() {
    local output="$1"
    local topic="$2"
    
    # Consumer output is CSV format:
    # start.time, end.time, data.consumed.in.MB, MB.sec, data.consumed.in.nMsg, nMsg.sec, rebalance.time.ms, fetch.time.ms, fetch.MB.sec, fetch.nMsg.sec
    
    # Get the last line which contains the results
    local result_line=$(echo "$output" | grep -v "^start.time" | tail -1)
    
    if [ -z "$result_line" ]; then
        print_error "Could not parse consumer output for $topic"
        return 1
    fi
    
    # Parse CSV values
    local data_consumed_mb=$(echo "$result_line" | awk -F',' '{print $3}' | xargs)
    local throughput_mb_sec=$(echo "$result_line" | awk -F',' '{print $4}' | xargs)
    local messages_consumed=$(echo "$result_line" | awk -F',' '{print $5}' | xargs)
    local messages_per_sec=$(echo "$result_line" | awk -F',' '{print $6}' | xargs)
    local rebalance_time=$(echo "$result_line" | awk -F',' '{print $7}' | xargs)
    local fetch_time=$(echo "$result_line" | awk -F',' '{print $8}' | xargs)
    local fetch_mb_sec=$(echo "$result_line" | awk -F',' '{print $9}' | xargs)
    local fetch_msg_sec=$(echo "$result_line" | awk -F',' '{print $10}' | xargs)
    
    # Extract partition and replication factor from topic name
    local partitions=$(echo "$topic" | sed -n 's/.*p\([0-9]*\).*/\1/p')
    local rf=$(echo "$topic" | sed -n 's/.*rf\([0-9]*\).*/\1/p')
    
    # Save to CSV
    echo "${TIMESTAMP},${topic},${partitions},${rf},${NUM_MESSAGES},${data_consumed_mb},${throughput_mb_sec},${messages_consumed},${messages_per_sec},${rebalance_time},${fetch_time},${fetch_mb_sec},${fetch_msg_sec}" >> "$RESULT_FILE"
    
    # Return formatted output
    cat << EOF
Topic: ${topic}
Data Consumed: ${data_consumed_mb} MB
Throughput: ${throughput_mb_sec} MB/sec
Messages: ${messages_consumed}
Messages/sec: ${messages_per_sec}
Rebalance Time: ${rebalance_time} ms
Fetch Time: ${fetch_time} ms
Fetch Throughput: ${fetch_mb_sec} MB/sec
EOF
}

# Run consumer test for a topic
run_consumer_test() {
    local topic="$1"
    local kafka_bin="$2"
    
    print_info "Testing topic: $topic"
    
    local raw_output_file="${RAW_DIR}/consumer_${topic}_${TIMESTAMP}.log"
    local group_id="benchmark-consumer-${topic}-${TIMESTAMP}"
    
    # Build command based on whether config file is provided
    if [ -n "$CLIENT_CONFIG" ] && [ -f "$CLIENT_CONFIG" ]; then
        print_info "Using consumer config: $CLIENT_CONFIG"
        # Run test with config file
        local output=$("$kafka_bin/kafka-consumer-perf-test.sh" \
            --topic "$topic" \
            --messages "$NUM_MESSAGES" \
            --group "$group_id" \
            --timeout 60000 \
            --consumer.config "$CLIENT_CONFIG" \
            --show-detailed-stats 2>&1 | tee "$raw_output_file")
    else
        # Run test with inline properties (default)
        local output=$("$kafka_bin/kafka-consumer-perf-test.sh" \
            --bootstrap-server "$BOOTSTRAP_SERVERS" \
            --topic "$topic" \
            --messages "$NUM_MESSAGES" \
            --group "$group_id" \
            --timeout 60000 \
            --show-detailed-stats 2>&1 | tee "$raw_output_file")
    fi
    
    # Parse and display results
    echo ""
    parse_consumer_output "$output" "$topic"
    echo ""
}

# Generate comparison report
generate_report() {
    local report_file="${RESULTS_DIR}/consumer_report_${TIMESTAMP}.txt"
    local html_report="${RESULTS_DIR}/consumer_report_${TIMESTAMP}.html"
    
    print_header "Generating Comparison Report"
    
    # Text report
    {
        echo "KAFKA CONSUMER BENCHMARK RESULTS"
        echo "================================="
        echo "Timestamp: ${TIMESTAMP}"
        echo "Bootstrap Servers: ${BOOTSTRAP_SERVERS}"
        echo "Messages per Test: ${NUM_MESSAGES}"
        echo ""
        echo "RESULTS SUMMARY"
        echo "==============="
        echo ""
        
        # Read CSV and format output
        tail -n +2 "$RESULT_FILE" | while IFS=',' read -r ts topic part rf num_msg data_mb throughput msg_consumed msg_sec rebal fetch fetch_mb fetch_msg; do
            echo "Topic: $topic (Partitions: $part, RF: $rf)"
            echo "  Throughput: $throughput MB/sec"
            echo "  Messages/sec: $msg_sec"
            echo "  Data Consumed: $data_mb MB"
            echo "  Fetch Time: $fetch ms"
            echo ""
        done
        
        echo "PERFORMANCE RANKING (by Throughput)"
        echo "===================================="
        tail -n +2 "$RESULT_FILE" | sort -t',' -k7 -rn | head -5 | while IFS=',' read -r ts topic part rf num_msg data_mb throughput msg_consumed msg_sec rebal fetch fetch_mb fetch_msg; do
            echo "$topic: $throughput MB/sec"
        done
        
        echo ""
        echo "HIGHEST MESSAGE RATE"
        echo "===================="
        tail -n +2 "$RESULT_FILE" | sort -t',' -k9 -rn | head -5 | while IFS=',' read -r ts topic part rf num_msg data_mb throughput msg_consumed msg_sec rebal fetch fetch_mb fetch_msg; do
            echo "$topic: $msg_sec messages/sec"
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
    <title>Kafka Consumer Benchmark Results</title>
    <script src="https://cdn.plot.ly/plotly-2.27.0.min.js"></script>
    <style>
        body { 
            font-family: Arial, sans-serif; 
            margin: 20px;
            background: #f5f5f5;
        }
        .header {
            background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
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
            background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
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
            background: #f093fb; 
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
        <h1>📥 Kafka Consumer Benchmark Results</h1>
        <p>Native kafka-consumer-perf-test.sh Performance Analysis</p>
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
                    <th>Messages/sec</th>
                    <th>Data (MB)</th>
                    <th>Fetch Time (ms)</th>
                </tr>
            </thead>
            <tbody id="resultsBody"></tbody>
        </table>
        
        <div class="chart" id="throughputChart"></div>
        <div class="chart" id="messagesChart"></div>
        <div class="chart" id="fetchTimeChart"></div>
        <div class="chart" id="comparisonChart"></div>
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
                        num_messages: parseInt(values[4]),
                        data_consumed_mb: parseFloat(values[5]),
                        throughput_mb_sec: parseFloat(values[6]),
                        messages_consumed: parseFloat(values[7]),
                        messages_per_sec: parseFloat(values[8]),
                        rebalance_time_ms: parseFloat(values[9]),
                        fetch_time_ms: parseFloat(values[10]),
                        fetch_mb_sec: parseFloat(values[11]),
                        fetch_msg_sec: parseFloat(values[12])
                    };
                });
                
                renderDashboard(data);
        }
        
        // Load data on page load
        window.addEventListener('DOMContentLoaded', loadData);
        
        function renderDashboard(data) {
            // Summary cards
            const totalMessages = data.reduce((sum, d) => sum + d.messages_consumed, 0);
            const avgThroughput = data.reduce((sum, d) => sum + d.throughput_mb_sec, 0) / data.length;
            const bestThroughput = Math.max(...data.map(d => d.throughput_mb_sec));
            const bestTopic = data.find(d => d.throughput_mb_sec === bestThroughput).topic;
            
            document.getElementById('summary').innerHTML = `
                <div class="summary-card">
                    <h3>Total Messages Consumed</h3>
                    <div class="value">${Math.round(totalMessages).toLocaleString()}</div>
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
            const maxThroughput = Math.max(...data.map(d => d.throughput_mb_sec));
            const minFetchTime = Math.min(...data.map(d => d.fetch_time_ms));
            
            data.forEach(row => {
                const tr = document.createElement('tr');
                tr.innerHTML = `
                    <td>${row.topic}</td>
                    <td>${row.partitions}</td>
                    <td>${row.rf}</td>
                    <td class="${row.throughput_mb_sec === maxThroughput ? 'best' : ''}">${row.throughput_mb_sec.toFixed(2)}</td>
                    <td>${row.messages_per_sec.toFixed(2)}</td>
                    <td>${row.data_consumed_mb.toFixed(2)}</td>
                    <td class="${row.fetch_time_ms === minFetchTime ? 'best' : ''}">${row.fetch_time_ms.toFixed(2)}</td>
                `;
                tbody.appendChild(tr);
            });
            
            // Charts
            createThroughputChart(data);
            createMessagesChart(data);
            createFetchTimeChart(data);
            createComparisonChart(data);
        }
        
        function createThroughputChart(data) {
            const trace = {
                x: data.map(d => d.topic),
                y: data.map(d => d.throughput_mb_sec),
                type: 'bar',
                marker: {
                    color: data.map(d => d.throughput_mb_sec),
                    colorscale: 'Sunset'
                },
                text: data.map(d => d.throughput_mb_sec.toFixed(2) + ' MB/s'),
                textposition: 'outside'
            };
            
            const layout = {
                title: 'Consumer Throughput Comparison (MB/sec)',
                xaxis: { title: 'Topic' },
                yaxis: { title: 'Throughput (MB/sec)' },
                height: 400
            };
            
            Plotly.newPlot('throughputChart', [trace], layout);
        }
        
        function createMessagesChart(data) {
            const trace = {
                x: data.map(d => d.topic),
                y: data.map(d => d.messages_per_sec),
                type: 'bar',
                marker: { color: '#f5576c' },
                text: data.map(d => Math.round(d.messages_per_sec).toLocaleString()),
                textposition: 'outside'
            };
            
            const layout = {
                title: 'Messages per Second',
                xaxis: { title: 'Topic' },
                yaxis: { title: 'Messages/sec' },
                height: 400
            };
            
            Plotly.newPlot('messagesChart', [trace], layout);
        }
        
        function createFetchTimeChart(data) {
            const trace = {
                x: data.map(d => d.topic),
                y: data.map(d => d.fetch_time_ms),
                type: 'bar',
                marker: { color: '#f093fb' },
                text: data.map(d => d.fetch_time_ms.toFixed(2) + ' ms'),
                textposition: 'outside'
            };
            
            const layout = {
                title: 'Fetch Time Comparison (ms)',
                xaxis: { title: 'Topic' },
                yaxis: { title: 'Fetch Time (ms)' },
                height: 400
            };
            
            Plotly.newPlot('fetchTimeChart', [trace], layout);
        }
        
        function createComparisonChart(data) {
            const trace1 = {
                x: data.map(d => d.topic),
                y: data.map(d => d.throughput_mb_sec),
                name: 'Throughput (MB/s)',
                type: 'scatter',
                mode: 'lines+markers',
                marker: { size: 10, color: '#f093fb' },
                yaxis: 'y'
            };
            
            const trace2 = {
                x: data.map(d => d.topic),
                y: data.map(d => d.fetch_time_ms),
                name: 'Fetch Time (ms)',
                type: 'scatter',
                mode: 'lines+markers',
                marker: { size: 10, color: '#f5576c' },
                yaxis: 'y2'
            };
            
            const layout = {
                title: 'Throughput vs Fetch Time',
                xaxis: { title: 'Topic' },
                yaxis: { 
                    title: 'Throughput (MB/sec)',
                    side: 'left'
                },
                yaxis2: {
                    title: 'Fetch Time (ms)',
                    overlaying: 'y',
                    side: 'right'
                },
                height: 400
            };
            
            Plotly.newPlot('comparisonChart', [trace1, trace2], layout);
        }
    </script>
</body>
</html>
EOF

    # Embed CSV data directly in HTML (for file:// protocol compatibility)
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
    print_header "Kafka Consumer Native Benchmark Runner"
    
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
    print_info "Messages per test: $NUM_MESSAGES"
    echo ""
    
    print_warning "Make sure topics have data! Run producer benchmark first if needed."
    echo ""
    
    # Run tests
    print_header "Running Consumer Benchmark Tests"
    for topic in "${TOPICS[@]}"; do
        run_consumer_test "$topic" "$KAFKA_BIN"
        sleep 2  # Brief pause between tests
    done
    
    # Generate reports
    generate_report
    
    print_header "Consumer Benchmark Complete! 🎉"
    print_info "Open the HTML report to view results:"
    echo ""
    echo "  open ${RESULTS_DIR}/consumer_report_${TIMESTAMP}.html"
    echo ""
}

# Run main function
main "$@"
