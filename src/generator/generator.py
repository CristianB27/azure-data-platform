"""Generador de telemetría IoT simulada para Event Hubs.

Publica 1 lectura por segundo de un dispositivo aleatorio (5 en total).
Variables de entorno:
  EVENTHUB_CONN  cadena de conexión del namespace (obligatoria)
  EVENTHUB_NAME  nombre del hub (por defecto: telemetria)
Uso: python generator.py --seconds 300
"""
import argparse
import json
import os
import random
import time
from datetime import datetime, timezone

from azure.eventhub import EventData, EventHubProducerClient

DEVICES = [f"sensor-{i:02d}" for i in range(1, 6)]


def build_reading() -> dict:
    temperature = random.gauss(26, 2)
    if random.random() < 0.08:  # picos ocasionales para disparar alertas
        temperature += random.uniform(6, 10)
    return {
        "device_id": random.choice(DEVICES),
        "event_time": datetime.now(timezone.utc).isoformat(),
        "temperature": round(temperature, 2),
        "humidity": round(random.gauss(55, 8), 2),
        "pressure": round(random.gauss(1013, 5), 2),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=int, default=300, help="duración total")
    args = parser.parse_args()

    producer = EventHubProducerClient.from_connection_string(
        os.environ["EVENTHUB_CONN"],
        eventhub_name=os.environ.get("EVENTHUB_NAME", "telemetria"),
    )
    with producer:
        for i in range(args.seconds):
            reading = build_reading()
            batch = producer.create_batch()
            batch.add(EventData(json.dumps(reading)))
            producer.send_batch(batch)
            print(f"[{i + 1}/{args.seconds}] {reading}")
            time.sleep(1)


if __name__ == "__main__":
    main()
