"""Demo pipeline for the Strimzi Day 10 lab: producer -> [orders] -> processor -> [orders.processed] -> sink.

One file, four roles (env ROLE=producer|bridge-producer|processor|sink). Every role:
  * exposes Prometheus metrics on :8000/metrics  (business metrics: throughput, errors, end-to-end latency)
  * emits OpenTelemetry traces over OTLP/gRPC; the trace context travels INSIDE the Kafka record headers
    (W3C `traceparent`), so one trace follows a message across both topics and all three services.
    Producer side: the OTel instrumentation injects the header. Consumer side: we extract it BY HAND (see `process_span`),
    on purpose - the stock consumer instrumentation links to the producer span instead of continuing its trace.

Deliberately small and dependency-light so it can be read on camera. Not production code.
"""
import json
import logging
import os
import random
import signal
import time
import urllib.request
import uuid

from confluent_kafka import Consumer, KafkaError, Producer
from opentelemetry import propagate, trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.confluent_kafka import ConfluentKafkaInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import SpanKind, Status, StatusCode
from prometheus_client import Counter, Histogram, start_http_server

ROLE = os.environ["ROLE"]
BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "my-cluster-kafka-bootstrap.kafka.svc:9092")
TOPIC_IN = os.environ.get("TOPIC_IN", "orders")
TOPIC_OUT = os.environ.get("TOPIC_OUT", "orders.processed")
RATE = float(os.environ.get("RATE", "5"))                 # producer: messages per second
PROCESS_MS = float(os.environ.get("PROCESS_MS", "30"))    # processor/sink: simulated work per message
ERROR_RATE = float(os.environ.get("ERROR_RATE", "0"))     # processor: fraction of messages that fail (0..1)
GROUP = os.environ.get("GROUP_ID", f"order-{ROLE}")
BRIDGE_URL = os.environ.get("BRIDGE_URL", "http://my-bridge-bridge-service.kafka.svc:8080")   # bridge-producer only

logging.basicConfig(level=logging.INFO, format=f"%(asctime)s {ROLE} %(levelname)s %(message)s")
log = logging.getLogger(ROLE)

# ---------------------------------------------------------------- metrics (the "business" view)
PRODUCED = Counter("demo_messages_produced", "Messages delivered to Kafka by the producer", ["topic"])
PRODUCE_ERRORS = Counter("demo_produce_errors", "Messages Kafka refused (delivery report with error)", ["topic"])
CONSUMED = Counter("demo_messages_consumed", "Messages consumed", ["stage", "topic"])
PROC_ERRORS = Counter("demo_processing_errors", "Messages that failed processing", ["stage"])
STAGE_SECONDS = Histogram("demo_stage_processing_seconds", "Time spent processing one message", ["stage"],
                          buckets=(.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5))
E2E_SECONDS = Histogram("demo_end_to_end_latency_seconds",
                        "Time between the producer creating the order and the sink consuming it", [],
                        buckets=(.05, .1, .25, .5, 1, 2.5, 5, 10, 30, 60, 120))

# ---------------------------------------------------------------- tracing
resource = Resource.create({"service.name": os.environ.get("OTEL_SERVICE_NAME", f"order-{ROLE}")})
provider = TracerProvider(resource=resource)
# endpoint comes from OTEL_EXPORTER_OTLP_ENDPOINT (standard variable), e.g. http://tempo.monitoring.svc:4317
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(f"order-{ROLE}")
instrumentor = ConfluentKafkaInstrumentor()

running = True


def stop(*_):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


def make_producer() -> Producer:
    # instrument_producer() wraps produce(): it creates a "send" span AND injects `traceparent` into the headers
    return instrumentor.instrument_producer(Producer({
        "bootstrap.servers": BOOTSTRAP, "acks": "all", "enable.idempotence": True,
        "linger.ms": 20, "client.id": f"order-{ROLE}"}))


def make_consumer(topic: str) -> Consumer:
    c = Consumer({"bootstrap.servers": BOOTSTRAP, "group.id": GROUP, "client.id": f"order-{ROLE}",
                  "auto.offset.reset": "earliest", "enable.auto.commit": False,
                  "partition.assignment.strategy": "cooperative-sticky"})
    c.subscribe([topic])
    return c


def process_span(msg):
    """Continue the trace that the producer started: read `traceparent` from the record headers and make it the parent.

    The time between the end of the producer's "send" span and the start of this span is the time the record sat in the topic
    (replication + waiting for the consumer) - it shows up as a GAP in the waterfall.
    """
    headers = {k: v.decode() for k, v in (msg.headers() or []) if isinstance(v, bytes)}
    return tracer.start_as_current_span(
        f"{msg.topic()} process", context=propagate.extract(headers), kind=SpanKind.CONSUMER,
        attributes={"messaging.system": "kafka", "messaging.destination.name": msg.topic(),
                    "messaging.kafka.partition": msg.partition(), "messaging.kafka.offset": msg.offset(),
                    "messaging.kafka.consumer.group": GROUP})


def delivery_report(topic):
    def _cb(err, _msg):
        if err is not None:
            PRODUCE_ERRORS.labels(topic).inc()
            log.error("delivery failed: %s", err)
        else:
            PRODUCED.labels(topic).inc()
    return _cb


# ---------------------------------------------------------------- roles
def run_producer():
    p = make_producer()
    interval = 1.0 / RATE
    log.info("producing to %s at %.1f msg/s", TOPIC_IN, RATE)
    while running:
        order = {"order_id": str(uuid.uuid4()), "customer": f"c{random.randint(1, 20)}",
                 "amount": round(random.uniform(5, 500), 2), "created_at": time.time()}
        # the span below is the ROOT of the end-to-end trace
        with tracer.start_as_current_span("create order") as span:
            span.set_attribute("order.id", order["order_id"])
            try:
                p.produce(TOPIC_IN, key=order["customer"], value=json.dumps(order).encode(),
                          on_delivery=delivery_report(TOPIC_IN))
            except BufferError:
                PRODUCE_ERRORS.labels(TOPIC_IN).inc()
                span.set_status(Status(StatusCode.ERROR, "local queue full"))
        p.poll(0)
        time.sleep(interval)
    p.flush(10)


def run_bridge_producer():
    """Same orders, but sent over HTTP to the Strimzi Kafka Bridge (a client that cannot speak the Kafka protocol).

    The W3C `traceparent` goes in the HTTP REQUEST headers; the Bridge (tracing: opentelemetry) continues that trace and
    writes it into the Kafka record headers - so the downstream processor/sink spans join the SAME trace.
    """
    interval = 1.0 / RATE
    log.info("producing to %s through the Bridge at %s (%.1f msg/s)", TOPIC_IN, BRIDGE_URL, RATE)
    while running:
        order = {"order_id": str(uuid.uuid4()), "customer": f"c{random.randint(1, 20)}",
                 "amount": round(random.uniform(5, 500), 2), "created_at": time.time()}
        with tracer.start_as_current_span("create order (HTTP)", kind=SpanKind.CLIENT) as span:
            span.set_attribute("order.id", order["order_id"])
            headers = {"Content-Type": "application/vnd.kafka.json.v2+json"}
            propagate.inject(headers)                      # adds `traceparent` to the HTTP request
            body = json.dumps({"records": [{"key": order["customer"], "value": order}]}).encode()
            req = urllib.request.Request(f"{BRIDGE_URL}/topics/{TOPIC_IN}", data=body, headers=headers, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=5) as resp:
                    span.set_attribute("http.status_code", resp.status)
                PRODUCED.labels(TOPIC_IN).inc()
            except Exception as exc:                       # HTTPError (4xx/5xx), timeouts, connection refused...
                PRODUCE_ERRORS.labels(TOPIC_IN).inc()
                span.set_status(Status(StatusCode.ERROR, str(exc)))
                log.error("bridge request failed: %s", exc)
        time.sleep(interval)


def run_processor():
    c, p = make_consumer(TOPIC_IN), make_producer()
    log.info("processing %s -> %s (PROCESS_MS=%s ERROR_RATE=%s)", TOPIC_IN, TOPIC_OUT, PROCESS_MS, ERROR_RATE)
    while running:
        msg = c.poll(1.0)
        if msg is None:
            p.poll(0)
            continue
        if msg.error():
            if msg.error().code() != KafkaError._PARTITION_EOF:
                log.error("consumer error: %s", msg.error())
            continue
        CONSUMED.labels("processor", TOPIC_IN).inc()
        order = json.loads(msg.value())
        t0 = time.time()
        with process_span(msg) as span:                # parent = the producer's span, via the Kafka headers
            span.set_attribute("order.id", order["order_id"])
            with tracer.start_as_current_span("validate and enrich order"):
                time.sleep(max(0.0, random.gauss(PROCESS_MS, PROCESS_MS / 4)) / 1000)
            if random.random() < ERROR_RATE:
                PROC_ERRORS.labels("processor").inc()
                span.set_status(Status(StatusCode.ERROR, "validation failed"))
                span.add_event("order rejected", {"reason": "simulated validation error"})
                STAGE_SECONDS.labels("processor").observe(time.time() - t0)
                c.commit(msg, asynchronous=True)     # a real app would send it to a DLQ; here we count and move on
                continue
            order["tax"] = round(order["amount"] * 0.1, 2)
            # produce() INSIDE the span: the instrumented producer injects the CURRENT context -> the next hop continues this trace
            p.produce(TOPIC_OUT, key=msg.key(), value=json.dumps(order).encode(),
                      on_delivery=delivery_report(TOPIC_OUT))
        p.poll(0)
        STAGE_SECONDS.labels("processor").observe(time.time() - t0)
        c.commit(msg, asynchronous=True)
    p.flush(10)
    c.close()


def run_sink():
    c = make_consumer(TOPIC_OUT)
    log.info("sink reading %s (PROCESS_MS=%s)", TOPIC_OUT, PROCESS_MS)
    while running:
        msg = c.poll(1.0)
        if msg is None:
            continue
        if msg.error():
            if msg.error().code() != KafkaError._PARTITION_EOF:
                log.error("consumer error: %s", msg.error())
            continue
        CONSUMED.labels("sink", TOPIC_OUT).inc()
        order = json.loads(msg.value())
        t0 = time.time()
        with process_span(msg) as span:
            span.set_attribute("order.id", order["order_id"])
            with tracer.start_as_current_span("send notification"):
                time.sleep(max(0.0, random.gauss(PROCESS_MS, PROCESS_MS / 4)) / 1000)
        STAGE_SECONDS.labels("sink").observe(time.time() - t0)
        E2E_SECONDS.observe(time.time() - order["created_at"])
        c.commit(msg, asynchronous=True)
    c.close()


if __name__ == "__main__":
    start_http_server(int(os.environ.get("METRICS_PORT", "8000")))
    {"producer": run_producer, "bridge-producer": run_bridge_producer, "processor": run_processor, "sink": run_sink}[ROLE]()
    provider.shutdown()
