#!/usr/bin/env python3
"""Fleet model used by the capacity-and-cost skill (examples/fleet-model.csv).

Reproduces the method of ARQUITETURA.md §18.1 and the 10k report (§1), with inputs as columns:
  L = U x d x h x s x phi'        looping sessions at peak
  phi' = b*phi / (b*phi + (1 - phi))   loop share at our request time (b = our time / Claude time, §24.2)
  S = L x f                       concurrent streams at peak
  replicas_raw = S / sessions_per_replica
  replicas = ceil(replicas_raw x (1 + 3 / sqrt(L)))      Poisson margin
  load_machines = ceil(replicas / replicas_per_machine)
  spare_machines = ceil(load_machines / 5)                one N+1 machine per 5 loaded
  monthly_cost = (load + spare) x price_per_machine_hour x 730

Every output row is Inferred. Run: python3 fleet_model.py > fleet-model.csv
Check: python3 fleet_model.py --check reproduces the old §18.1 base row (15 VMs, US$ 157.7k).
"""
from __future__ import annotations

import csv
import math
import sys
from dataclasses import dataclass

HOURS_PER_MONTH = 730


@dataclass(frozen=True)
class Price:
    name: str
    machine_hour: float      # US$ per machine-hour
    replicas_per_machine: int
    source: str              # where and when the price was read


PRICES = [
    Price("AWS g7e.24xlarge on-demand us-east-1", 16.57216, 1, "AWS public price data published 2026-11-10, read 2026-11-12"),
    Price("AWS g7e.48xlarge on-demand us-east-1", 33.14432, 2, "AWS public price data published 2026-11-10, read 2026-11-12"),
    Price("AWS g7e.24xlarge EC2 Instance SP 1yr no upfront", 10.44046, 1, "AWS Savings Plans price list 20261110215713, read 2026-11-12"),
    Price("AWS g7e.24xlarge EC2 Instance SP 3yr no upfront", 7.15917, 1, "AWS Savings Plans price list 20261110215713, read 2026-11-12"),
    Price("Nebius 8x RTX PRO 6000 list", 14.40, 2, "nebius.com/prices US$ 1.80 per GPU-hour, read 2026-11-12"),
]

CAPACITIES = [
    (24, "DCP1 24 agents, one run, host 157204"),
    (16, "DCP4 16 agents, passed run 1, failed run 2"),
    (8, "DCP4 8 agents, one run (7-minute level)"),
]

DEMAND = {  # d, h, s from the 10k report factor table (low, base, high); phi and f fixed at Weka (§24.1)
    "low_dhs": (0.25, 0.35, 1.1),
    "base": (0.40, 0.50, 1.3),
    "high_dhs": (0.60, 0.60, 1.6),
}
PHI_WEKA = 0.256
F_WEKA = 1.15


def loop_share(phi: float, b: float) -> float:
    return b * phi / (b * phi + (1 - phi))


def fleet(users: int, d: float, h: float, s: float, phi: float, b: float, f: float,
          per_replica: float, price: Price) -> dict:
    phi_b = loop_share(phi, b)
    looping = users * d * h * s * phi_b
    streams = looping * f
    raw = streams / per_replica
    margin = 1 + 3 / math.sqrt(looping)
    replicas = math.ceil(raw * margin)
    load = math.ceil(replicas / price.replicas_per_machine)
    spare = math.ceil(load / 5)
    total = load + spare
    monthly = total * price.machine_hour * HOURS_PER_MONTH
    return {
        "users": users, "d": d, "h": h, "s": s, "phi_claude": phi, "b": b, "phi_ours": round(phi_b, 4),
        "f": f, "looping_sessions_L": round(looping, 1), "streams_S": round(streams, 1),
        "sessions_per_replica": per_replica, "replicas_raw": round(raw, 2), "poisson_margin": round(margin, 4),
        "replicas": replicas, "machine": price.name, "replicas_per_machine": price.replicas_per_machine,
        "load_machines": load, "spare_machines": spare, "total_machines": total,
        "price_per_machine_hour": price.machine_hour, "monthly_cost_usd": round(monthly),
        "cost_per_user_month_usd": round(monthly / users, 2), "price_source": price.source,
    }


def check_old_base_row() -> None:
    old = Price("Nebius 8x RTX list (2026-11-05)", 14.4, 2, "§18.1")
    # §18.1 used phi = 0.25 at Claude latency (b = 1), f = 1.3 and 40 streams per replica
    r = fleet(10_000, 0.40, 0.50, 1.3, 0.25, 1.0, 1.3, 40, old)
    assert (r["streams_S"], r["replicas"], r["load_machines"], r["total_machines"]) == (845.0, 24, 12, 15), r
    assert r["monthly_cost_usd"] == 157_680, r
    print("old base row reproduced:", r["streams_S"], "streams,", r["total_machines"], "VMs, US$", r["monthly_cost_usd"])


def main(argv: list[str]) -> int:
    if argv[:1] == ["--check"]:
        check_old_base_row()
        return 0
    rows = []
    for scenario, (d, h, s) in DEMAND.items():
        for b in (1.0, 2.0, 2.5, 3.0):
            for per_replica, _ in CAPACITIES:
                for price in PRICES:
                    rows.append({"scenario": scenario, **fleet(10_000, d, h, s, PHI_WEKA, b, F_WEKA, per_replica, price)})
    w = csv.DictWriter(sys.stdout, fieldnames=list(rows[0]))
    w.writeheader()
    w.writerows(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
