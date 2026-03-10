#!/usr/bin/env python3
"""
Gera um ficheiro JSON > 1MB para testar replicação de mensagens
grandes com o MirrorMaker 2.

Uso:
    python3 generate-large-message.py              # gera message-large.json (1.2MB)
    python3 generate-large-message.py --size 2     # gera ~2MB
    python3 generate-large-message.py --size 5     # gera ~5MB
    python3 generate-large-message.py --count 10   # gera 10 ficheiros (~1.2MB cada)

Produzir para Kafka depois de gerar:
    # Mensagem única
    kafka-console-producer.sh --bootstrap-server localhost:9092 \
      --topic large-messages \
      --property "parse.key=true" \
      --property "key.separator=|" < message-large.json

    # Múltiplas mensagens (uma por linha)
    kafka-console-producer.sh --bootstrap-server localhost:9092 \
      --topic large-messages \
      --property "parse.key=true" \
      --property "key.separator=|" < messages-batch.json
"""

import json
import random
import string
import argparse
import os
import time


def random_string(length: int) -> str:
    chars = string.ascii_letters + string.digits
    return "".join(random.choices(chars, k=length))


def generate_order_items(count: int) -> list:
    products = [
        "Laptop Pro X1", "Wireless Mouse", "USB-C Hub", "Monitor 4K",
        "Mechanical Keyboard", "Webcam HD", "SSD 1TB", "RAM 32GB",
        "Headphones BT", "Desk Lamp LED", "Notebook Stand", "Cable HDMI",
        "Mousepad XL", "Speakers 2.1", "Router WiFi 6",
    ]
    categories = ["electronics", "accessories", "storage", "peripherals"]
    items = []
    for i in range(count):
        items.append({
            "item_id": f"ITEM-{random_string(12)}",
            "product_id": f"PROD-{random.randint(10000, 99999)}",
            "product_name": random.choice(products),
            "category": random.choice(categories),
            "quantity": random.randint(1, 10),
            "unit_price": round(random.uniform(9.99, 1999.99), 2),
            "discount_pct": round(random.uniform(0, 30), 2),
            "warehouse_id": f"WH-{random.randint(1, 50):03d}",
            "sku": random_string(16).upper(),
            "weight_kg": round(random.uniform(0.1, 25.0), 3),
            "description": random_string(200),
            "tags": [random_string(8) for _ in range(random.randint(2, 6))],
            "metadata": {
                "origin_country": random.choice(["PT", "ES", "DE", "FR", "NL"]),
                "supplier_code": random_string(10).upper(),
                "batch_id": f"BATCH-{random_string(8)}",
                "notes": random_string(150),
            },
        })
    return items


def generate_tracking_events(count: int) -> list:
    statuses = [
        "CREATED", "CONFIRMED", "PROCESSING", "PACKED",
        "DISPATCHED", "IN_TRANSIT", "OUT_FOR_DELIVERY",
        "DELIVERED", "RETURNED", "CANCELLED",
    ]
    locations = [
        "Lisboa", "Porto", "Coimbra", "Braga", "Faro",
        "Aveiro", "Setubal", "Viseu", "Guarda", "Leiria",
    ]
    events = []
    ts = int(time.time()) - count * 3600
    for i in range(count):
        events.append({
            "event_id": f"EVT-{random_string(16)}",
            "status": statuses[i % len(statuses)],
            "timestamp": ts + i * 3600,
            "timestamp_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts + i * 3600)),
            "location": random.choice(locations),
            "operator_id": f"OP-{random.randint(100, 999)}",
            "notes": random_string(120),
            "coordinates": {
                "lat": round(random.uniform(37.0, 42.0), 6),
                "lon": round(random.uniform(-9.5, -6.0), 6),
            },
        })
    return events


def build_message(target_size_bytes: int, message_index: int = 1) -> dict:
    """Constrói uma mensagem JSON que atinge aproximadamente target_size_bytes."""
    order_id = f"ORDER-{random_string(16).upper()}"

    # Base do documento
    doc = {
        "schema_version": "2.1.0",
        "message_id": random_string(32),
        "order_id": order_id,
        "correlation_id": random_string(24),
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_system": "order-management-service",
        "environment": "lab",
        "customer": {
            "customer_id": f"CUST-{random.randint(100000, 999999)}",
            "name": f"Customer {message_index:04d}",
            "email": f"customer{message_index}@example.com",
            "phone": f"+351 9{random.randint(10000000, 99999999)}",
            "vat_number": f"PT{random.randint(100000000, 999999999)}",
            "address": {
                "street": f"Rua {random_string(20)} nº {random.randint(1, 999)}",
                "city": random.choice(["Lisboa", "Porto", "Coimbra", "Braga"]),
                "postal_code": f"{random.randint(1000, 9999)}-{random.randint(100, 999)}",
                "country": "PT",
            },
            "segment": random.choice(["premium", "standard", "enterprise"]),
            "notes": random_string(300),
        },
        "shipping": {
            "method": random.choice(["standard", "express", "same-day"]),
            "carrier": random.choice(["CTT", "DHL", "FedEx", "UPS", "GLS"]),
            "tracking_number": random_string(20).upper(),
            "estimated_delivery": time.strftime("%Y-%m-%d"),
            "signature_required": random.choice([True, False]),
            "insurance_value": round(random.uniform(0, 5000), 2),
        },
        "payment": {
            "method": random.choice(["credit_card", "mb_way", "bank_transfer", "paypal"]),
            "status": "COMPLETED",
            "transaction_id": random_string(24),
            "amount": 0.0,
            "currency": "EUR",
            "paid_at": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
        "items": [],
        "tracking_history": [],
        "raw_payload": "",
    }

    # Serializar parcialmente para medir tamanho actual
    current = json.dumps(doc, ensure_ascii=False)
    current_size = len(current.encode("utf-8"))
    remaining = target_size_bytes - current_size

    # Adicionar itens de ordem para engordar (~800 bytes por item)
    n_items = max(5, remaining // 850)
    doc["items"] = generate_order_items(n_items)

    # Adicionar histórico de tracking (~400 bytes por evento)
    current_size = len(json.dumps(doc, ensure_ascii=False).encode("utf-8"))
    remaining = target_size_bytes - current_size
    n_events = max(5, remaining // 420)
    doc["tracking_history"] = generate_tracking_events(n_events)

    # Preencher o restante com um campo raw_payload se ainda faltar espaço
    current_size = len(json.dumps(doc, ensure_ascii=False).encode("utf-8"))
    remaining = target_size_bytes - current_size
    if remaining > 100:
        doc["raw_payload"] = random_string(max(0, remaining - 20))

    # Calcular total
    total = sum(item["unit_price"] * item["quantity"] for item in doc["items"])
    doc["payment"]["amount"] = round(total, 2)

    return doc, order_id


def main():
    parser = argparse.ArgumentParser(
        description="Gera ficheiros JSON > 1MB para testes de grandes mensagens no Kafka"
    )
    parser.add_argument(
        "--size", type=float, default=1.2,
        help="Tamanho alvo em MB (default: 1.2)"
    )
    parser.add_argument(
        "--count", type=int, default=1,
        help="Número de mensagens a gerar (default: 1)"
    )
    parser.add_argument(
        "--output-dir", type=str, default=".",
        help="Directório de saída (default: directório actual)"
    )
    args = parser.parse_args()

    target_bytes = int(args.size * 1024 * 1024)
    os.makedirs(args.output_dir, exist_ok=True)

    if args.count == 1:
        # Ficheiro único para uso simples com kafka-console-producer
        doc, order_id = build_message(target_bytes, 1)
        # Formato: key|value (uma linha) para kafka-console-producer com parse.key
        output = {
            "key": order_id,
            "value": doc,
        }
        out_path = os.path.join(args.output_dir, "message-large.json")
        with open(out_path, "w", encoding="utf-8") as f:
            # Uma linha só: "key|{...json...}"
            line = order_id + "|" + json.dumps(doc, ensure_ascii=False)
            f.write(line + "\n")

        size_bytes = os.path.getsize(out_path)
        print(f"✓ Gerado: {out_path}")
        print(f"  Tamanho : {size_bytes:,} bytes ({size_bytes / 1024 / 1024:.2f} MB)")
        print(f"  Order ID: {order_id}")
        print(f"  Itens   : {len(doc['items'])}")
        print()
        print("Produzir para Kafka:")
        print("  kafka-console-producer.sh --bootstrap-server localhost:9092 \\")
        print("    --topic large-messages \\")
        print('    --property "parse.key=true" \\')
        print('    --property "key.separator=|" < message-large.json')
    else:
        # Batch: múltiplas mensagens, uma por linha → messages-batch.json
        out_path = os.path.join(args.output_dir, "messages-batch.json")
        total_size = 0
        with open(out_path, "w", encoding="utf-8") as f:
            for i in range(1, args.count + 1):
                doc, order_id = build_message(target_bytes, i)
                line = order_id + "|" + json.dumps(doc, ensure_ascii=False)
                f.write(line + "\n")
                total_size += len(line.encode("utf-8"))
                print(f"  [{i}/{args.count}] {order_id} — {len(line.encode('utf-8')):,} bytes")

        print()
        print(f"✓ Gerado: {out_path}")
        print(f"  Mensagens : {args.count}")
        print(f"  Total     : {total_size:,} bytes ({total_size / 1024 / 1024:.2f} MB)")
        print()
        print("Produzir para Kafka:")
        print("  kafka-console-producer.sh --bootstrap-server localhost:9092 \\")
        print("    --topic large-messages \\")
        print('    --property "parse.key=true" \\')
        print('    --property "key.separator=|" < messages-batch.json')


if __name__ == "__main__":
    main()
