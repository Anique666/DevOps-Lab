import os
import random
import time

from prometheus_client import Gauge, Summary, start_http_server

total_deliveries = Gauge("total_deliveries", "Total number of deliveries")
pending_deliveries = Gauge("pending_deliveries", "Number of pending deliveries")
on_the_way_deliveries = Gauge("on_the_way_deliveries", "Number of deliveries on the way")
average_delivery_time = Summary("average_delivery_time", "Average delivery time in seconds")


def simulate_delivery():
    # SIMULATE_ALERT=1 makes the pending count stay above the alert threshold.
    if os.environ.get("SIMULATE_ALERT") == "1":
        pending = random.randint(50, 100)
    else:
        pending = random.randint(10, 20)

    on_the_way = random.randint(5, 20)
    delivered = random.randint(30, 70)
    avg_time = random.uniform(15, 45)
    total = pending + on_the_way + delivered

    print(
        f"total={total} pending={pending} on_the_way={on_the_way} "
        f"avg_time={avg_time:.2f}s",
        flush=True,
    )

    total_deliveries.set(total)
    pending_deliveries.set(pending)
    on_the_way_deliveries.set(on_the_way)
    average_delivery_time.observe(avg_time)


if __name__ == "__main__":
    print("Starting metrics server on port 8000...", flush=True)
    start_http_server(8000, addr="0.0.0.0")
    while True:
        simulate_delivery()
        time.sleep(1)
