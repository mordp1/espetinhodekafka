#!/bin/bash
#
# Disk Performance Baseline Test
# Tests raw disk read/write performance using dd
#

set -e

KAFKA_DATA_DIR="${1:-/var/lib/kafka/data}"
FILE_SIZE_MB="${2:-1024}"  # Default 1GB (1024 MB)
TEST_FILE="${KAFKA_DATA_DIR}/disk-performance-test"

echo "========================================="
echo "Disk Performance Baseline Test"
echo "========================================="
echo "Kafka Data Directory: $KAFKA_DATA_DIR"
echo "Test File Size: ${FILE_SIZE_MB}MB"
echo "Test File: $TEST_FILE"
echo ""

# Check if directory exists
if [ ! -d "$KAFKA_DATA_DIR" ]; then
    echo "ERROR: Directory $KAFKA_DATA_DIR does not exist!"
    echo "Please specify the correct Kafka data directory."
    echo "Usage: $0 [kafka-data-dir] [file-size-mb]"
    exit 1
fi

# Check if we have write permission
if [ ! -w "$KAFKA_DATA_DIR" ]; then
    echo "ERROR: No write permission to $KAFKA_DATA_DIR"
    echo "Please run with appropriate permissions (sudo if needed)"
    exit 1
fi

# Clean up any existing test file
if [ -f "$TEST_FILE" ]; then
    echo "Removing existing test file..."
    rm -f "$TEST_FILE"
fi

echo "========================================="
echo "Test 1: Write Throughput"
echo "========================================="
echo "Writing ${FILE_SIZE_MB}MB to disk..."
echo ""

WRITE_START=$(date +%s.%N)
dd if=/dev/zero of="$TEST_FILE" bs=1M count="$FILE_SIZE_MB" conv=fsync 2>&1
WRITE_END=$(date +%s.%N)

WRITE_TIME=$(echo "$WRITE_END - $WRITE_START" | bc)
WRITE_SPEED=$(echo "scale=2; $FILE_SIZE_MB / $WRITE_TIME" | bc)

echo ""
echo "Write Results:"
echo "  Time: ${WRITE_TIME} seconds"
echo "  Throughput: ${WRITE_SPEED} MB/s"
echo ""

# Verify file was created
if [ ! -f "$TEST_FILE" ]; then
    echo "ERROR: Test file was not created!"
    exit 1
fi

echo "========================================="
echo "Test 2: Read Throughput"
echo "========================================="
echo "Reading ${FILE_SIZE_MB}MB from disk..."
echo ""

READ_START=$(date +%s.%N)
dd if="$TEST_FILE" of=/dev/null bs=1M count="$FILE_SIZE_MB" 2>&1
READ_END=$(date +%s.%N)

READ_TIME=$(echo "$READ_END - $READ_START" | bc)
READ_SPEED=$(echo "scale=2; $FILE_SIZE_MB / $READ_TIME" | bc)

echo ""
echo "Read Results:"
echo "  Time: ${READ_TIME} seconds"
echo "  Throughput: ${READ_SPEED} MB/s"
echo ""

echo "========================================="
echo "Summary"
echo "========================================="
echo "Write Throughput: ${WRITE_SPEED} MB/s"
echo "Read Throughput: ${READ_SPEED} MB/s"
echo ""

# Clean up
echo "Cleaning up test file..."
rm -f "$TEST_FILE"

echo ""
echo "========================================="
echo "Test Complete!"
echo "========================================="
echo ""
echo "Interpretation:"
echo "  - SSD typically: 200-500 MB/s write, 400-600 MB/s read"
echo "  - HDD typically: 50-150 MB/s write, 100-200 MB/s read"
echo "  - If values are lower, disk may be a bottleneck for Kafka"
echo ""