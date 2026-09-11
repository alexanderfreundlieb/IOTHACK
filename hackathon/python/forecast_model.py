"""
forecast_model.py

Training pipeline for the Phase-3 load/PV forecast.

Design rationale (see PHASE3_DESIGN.md):
  - Consumption is a step function of the simulated hour, so a per-bin mean is
    the optimal estimator. Targets are normalised by the household's baseline
    so all households train one shared shape instead of four sparse ones.
  - Production is linear in irradiance through the origin, so it needs a single
    slope, not a regression with an intercept.
  - History is written by repeated simulator runs; the simulated clock resets on
    every restart. Rows are therefore grouped into sessions, and validation
    holds out whole sessions - a random split leaks because consecutive slots
    inside one bin are near-duplicates.

Pure standard library on purpose: no numpy/sklearn needed, so this runs against
data/history.db as-is.

Usage:
    python forecast_model.py            # train + validation report
"""

import json
import sqlite3
import time
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

CONFIG_PATH = Path(__file__).parent / "config.json"
DB_PATH = Path(__file__).parent.parent / "data" / "history.db"

# Mirrors data_simulator.SIM_MINUTES_PER_SLOT / 60
SLOT_FRACTION_OF_HOUR = 0.25

# The simulated clock advances 15 simulated minutes per real minute.
SIM_HOURS_PER_REAL_SECOND = SLOT_FRACTION_OF_HOUR / 60.0

# A gap larger than this between consecutive rows means the simulator was
# restarted, which resets both the simulated clock and the battery SoC.
SESSION_GAP_SECONDS = 300

# How far around the clock to look for a populated neighbour before giving up
# and using the global mean, in bins. Tuned on the current history: 2 and 4 are
# both measurably worse, because beyond ~3 bins the search starts reaching over
# a step boundary into a different load plateau.
MAX_NEIGHBOUR_DISTANCE = 3


@dataclass
class Sample:
    household_id: str
    session: int
    timestamp: int
    sim_hour: float
    sim_dow: int
    irradiance: float
    temperature_c_x10: float
    cloud_cover: float
    consumption_wh: float
    production_wh: float


# ─────────────────────────────────────────────────────────────────────
#  Loading
# ─────────────────────────────────────────────────────────────────────

def load_history(db_path: Path = DB_PATH,
                 gap_seconds: int = SESSION_GAP_SECONDS) -> List[Sample]:
    """Reads meter+weather history and tags each row with a session id."""
    with sqlite3.connect(db_path) as conn:
        rows = conn.execute("""
            SELECT m.household_id, m.timestamp, m.sim_hour, m.sim_dayofweek,
                   w.irradiance, w.temperature_c_x10, w.cloud_cover,
                   m.consumption_wh, m.production_wh
            FROM meter_history m
            JOIN weather_history w ON m.timestamp = w.timestamp
            ORDER BY m.timestamp
        """).fetchall()

    # Sessions are global: every household shares the same simulator process.
    distinct_ts = sorted({r[1] for r in rows})
    session_of: Dict[int, int] = {}
    session = 0
    prev: Optional[int] = None
    for ts in distinct_ts:
        if prev is not None and ts - prev > gap_seconds:
            session += 1
        session_of[ts] = session
        prev = ts

    return [
        Sample(
            household_id=r[0], session=session_of[r[1]], timestamp=r[1],
            sim_hour=r[2], sim_dow=r[3], irradiance=float(r[4]),
            temperature_c_x10=float(r[5]), cloud_cover=float(r[6]),
            consumption_wh=float(r[7]), production_wh=float(r[8]),
        )
        for r in rows
    ]


def load_household_config(config_path: Path = CONFIG_PATH) -> Dict[str, dict]:
    with open(config_path) as f:
        return {h["id"]: h for h in json.load(f)["households"]}


def current_sim_hour(db_path: Path = DB_PATH,
                     max_staleness_seconds: int = 180) -> float:
    """
    The simulator's *simulated* hour right now, extrapolated from the newest
    row in the history DB.

    The simulated clock lives in the oracle_writer process's memory and cannot
    be recomputed from wall time - it resets on every restart (to 18.0, not 0.0,
    because oracle_writer offsets start_real_time by 6 hours). Reading the last
    persisted value and extrapolating forward is the only correct source.

    Raises if the history is stale, which means oracle_writer is not running.
    Extrapolating across a restart would silently produce a wrong hour, so this
    fails loudly instead.
    """
    with sqlite3.connect(db_path) as conn:
        row = conn.execute(
            "SELECT timestamp, sim_hour FROM weather_history "
            "ORDER BY timestamp DESC LIMIT 1"
        ).fetchone()
    if row is None:
        raise RuntimeError("history.db has no weather rows yet")

    ts, sim_hour = row
    age = time.time() - ts
    if age > max_staleness_seconds:
        raise RuntimeError(
            f"history.db is {age:.0f}s stale (newest row at sim_hour "
            f"{sim_hour:.2f}) - is oracle_writer.py running?"
        )
    return (sim_hour + age * SIM_HOURS_PER_REAL_SECOND) % 24.0


def sim_hour_after_slots(sim_hour: float, slots: int) -> float:
    """Simulated hour `slots` slots into the future."""
    return (sim_hour + slots * SLOT_FRACTION_OF_HOUR) % 24.0


# ─────────────────────────────────────────────────────────────────────
#  Model
# ─────────────────────────────────────────────────────────────────────

class ForecastModel:
    """
    Consumption: mean normalised load factor per hour bin, pooled over all
    households. Prediction rescales by the household's baseline.

    Production: single slope through the origin on irradiance, pooled over all
    PV households after normalising by peak_kwp.

    Irradiance: mean per hour bin, so a forecast for a future slot does not have
    to rely on the current reading. Learned from history rather than reproducing
    the simulator's sine formula, so it stays honest about being a model.
    """

    def __init__(self, n_bins: int = 24):
        self.n_bins = n_bins
        self.bin_factor: Dict[int, float] = {}
        self.bin_count: Dict[int, int] = {}
        self.global_factor: float = 1.0
        self.bin_irradiance: Dict[int, float] = {}
        self.global_irradiance: float = 0.0
        self.production_slope: float = 0.0
        self.households: Dict[str, dict] = {}
        self.is_trained = False
        self._estimate_cache: Dict[int, Tuple[float, str]] = {}

    # ── helpers ──────────────────────────────────────────────────────

    def _bin(self, sim_hour: float) -> int:
        return int(sim_hour / 24.0 * self.n_bins) % self.n_bins

    def _circular_distance(self, a: int, b: int) -> int:
        d = abs(a - b) % self.n_bins
        return min(d, self.n_bins - d)

    def _nearest_populated(self, b: int, table: Dict[int, float]) -> Optional[float]:
        """
        Mean of the closest populated bin(s) on the circular hour axis.

        Nearest-neighbour rather than the global mean because the load profile is
        piecewise constant with wide plateaus - an empty bin is far more likely to
        sit inside a plateau than on one of its edges, so its neighbour is usually
        the exact right answer.
        """
        for dist in range(1, MAX_NEIGHBOUR_DISTANCE + 1):
            hits = [
                table[c]
                for c in ((b - dist) % self.n_bins, (b + dist) % self.n_bins)
                if c in table
            ]
            if hits:
                return sum(hits) / len(hits)
        return None

    def _estimate(self, b: int) -> Tuple[float, str]:
        """Load factor for a bin, plus how it was obtained."""
        if b in self._estimate_cache:
            return self._estimate_cache[b]

        if b in self.bin_factor:
            n = self.bin_count[b]
            result = (self.bin_factor[b], "ok" if n >= 3 else "sparse")
        else:
            neighbour = self._nearest_populated(b, self.bin_factor)
            result = ((neighbour, "interpolated") if neighbour is not None
                      else (self.global_factor, "fallback"))

        self._estimate_cache[b] = result
        return result

    def estimate_irradiance(self, sim_hour: float) -> float:
        """Expected irradiance at a simulated hour, for forecasting ahead."""
        b = self._bin(sim_hour)
        if b in self.bin_irradiance:
            return self.bin_irradiance[b]
        neighbour = self._nearest_populated(b, self.bin_irradiance)
        return neighbour if neighbour is not None else self.global_irradiance

    def _consumption_scale(self, household_id: str) -> float:
        """Wh per unit load factor for this household."""
        base_kwh = self.households[household_id]["base_consumption_kwh_per_hour"]
        return base_kwh * 1000.0 * SLOT_FRACTION_OF_HOUR

    # ── training ─────────────────────────────────────────────────────

    def train(self, samples: List[Sample], households: Dict[str, dict]) -> None:
        self.households = households

        # Consumption: normalise out the per-household baseline so every
        # household contributes to the same shared time-of-day shape.
        by_bin: Dict[int, List[float]] = defaultdict(list)
        all_factors: List[float] = []
        for s in samples:
            scale = self._consumption_scale(s.household_id)
            if scale <= 0:
                continue
            factor = s.consumption_wh / scale
            by_bin[self._bin(s.sim_hour)].append(factor)
            all_factors.append(factor)

        if not all_factors:
            raise ValueError("No usable consumption samples")

        self.global_factor = sum(all_factors) / len(all_factors)
        # Keep every populated bin, however thin - shrinkage in _estimate()
        # decides how much to trust it. Discarding 1-2 sample bins outright
        # throws away real signal in favour of a much worse global mean.
        self.bin_factor = {b: sum(v) / len(v) for b, v in by_bin.items()}
        self.bin_count = {b: len(v) for b, v in by_bin.items()}
        self._estimate_cache.clear()

        # Irradiance per bin. Weather is shared across households, so deduplicate
        # by timestamp - otherwise every reading is counted four times.
        irr_by_bin: Dict[int, List[float]] = defaultdict(list)
        seen_ts = set()
        for s in samples:
            if s.timestamp in seen_ts:
                continue
            seen_ts.add(s.timestamp)
            irr_by_bin[self._bin(s.sim_hour)].append(s.irradiance)
        self.bin_irradiance = {b: sum(v) / len(v) for b, v in irr_by_bin.items()}
        all_irr = [x for v in irr_by_bin.values() for x in v]
        self.global_irradiance = sum(all_irr) / len(all_irr) if all_irr else 0.0

        # Production: least squares through the origin, y = slope * irradiance,
        # on production normalised by peak_kwp. Daylight rows only - night rows
        # are structurally zero and would just inflate the fit quality.
        sxy = sxx = 0.0
        for s in samples:
            peak = self.households[s.household_id]["pv_peak_kwp"]
            if peak <= 0 or s.irradiance <= 0:
                continue
            x = s.irradiance
            y = s.production_wh / peak
            sxy += x * y
            sxx += x * x
        self.production_slope = (sxy / sxx) if sxx > 0 else 0.0

        self.is_trained = True

    # ── prediction ───────────────────────────────────────────────────

    def predict(self, household_id: str, sim_hour: float,
                irradiance: Optional[float] = None) -> Tuple[float, float, str]:
        """
        Returns (consumption_wh, production_wh, confidence).

        Pass a measured `irradiance` to score the model against known weather.
        Omit it when forecasting a future slot, where the weather is not known
        yet and has to be projected from the simulated hour.
        """
        if not self.is_trained:
            raise RuntimeError("Model not trained")

        factor, confidence = self._estimate(self._bin(sim_hour))
        consumption = max(0.0, factor * self._consumption_scale(household_id))

        if irradiance is None:
            irradiance = self.estimate_irradiance(sim_hour)

        peak = self.households[household_id]["pv_peak_kwp"]
        production = max(0.0, self.production_slope * max(0.0, irradiance) * peak)

        return consumption, production, confidence

    def coverage(self) -> Tuple[int, int]:
        """(bins with at least one observation, total bins)."""
        return len(self.bin_factor), self.n_bins


# ─────────────────────────────────────────────────────────────────────
#  Validation
# ─────────────────────────────────────────────────────────────────────

def _mae_mape(pairs: List[Tuple[float, float]]) -> Tuple[float, Optional[float]]:
    """pairs of (actual, predicted). MAPE skips zero actuals."""
    if not pairs:
        return 0.0, None
    mae = sum(abs(a - p) for a, p in pairs) / len(pairs)
    nz = [(a, p) for a, p in pairs if a > 0]
    mape = (100.0 * sum(abs(a - p) / a for a, p in nz) / len(nz)) if nz else None
    return mae, mape


def validate(samples: List[Sample], households: Dict[str, dict],
             n_bins: int = 24) -> None:
    """
    Leave-one-session-out cross-validation.

    Every session takes a turn as the test set, so all rows are scored and the
    estimate does not hinge on which single session happened to be held out.
    Splitting by session rather than at random is essential: consecutive slots
    inside one bin are near-duplicates, so a random split leaks and reports a
    fictitiously good score.
    """
    sizes: Dict[int, int] = defaultdict(int)
    for s in samples:
        sizes[s.session] += 1

    print(f"sessions detected: {len(sizes)}  "
          f"(sizes: {sorted(sizes.values(), reverse=True)})")

    if len(sizes) < 2:
        print("Only one session - cannot cross-validate. Collect more history.")
        return

    cons_model: List[Tuple[float, float]] = []
    cons_base: List[Tuple[float, float]] = []
    prod_model: List[Tuple[float, float]] = []
    prod_projected: List[Tuple[float, float]] = []
    conf_counts: Dict[str, int] = defaultdict(int)

    for holdout in sorted(sizes):
        train = [s for s in samples if s.session != holdout]
        test = [s for s in samples if s.session == holdout]
        if not train or not test:
            continue

        model = ForecastModel(n_bins=n_bins)
        model.train(train, households)

        base_sum: Dict[str, List[float]] = defaultdict(list)
        for s in train:
            base_sum[s.household_id].append(s.consumption_wh)
        baseline = {h: sum(v) / len(v) for h, v in base_sum.items()}

        for s in test:
            c, p, conf = model.predict(s.household_id, s.sim_hour, s.irradiance)
            conf_counts[conf] += 1
            cons_model.append((s.consumption_wh, c))
            cons_base.append((s.consumption_wh, baseline.get(s.household_id, 0.0)))
            if households[s.household_id]["pv_peak_kwp"] > 0:
                prod_model.append((s.production_wh, p))
                # What the live path actually does: no measured weather, so the
                # irradiance has to be projected from the simulated hour too.
                _, p_proj, _ = model.predict(s.household_id, s.sim_hour)
                prod_projected.append((s.production_wh, p_proj))

    print(f"cross-validated over {len(sizes)} folds, {len(cons_model)} scored rows\n")

    # Coverage is reported from a model fitted on everything, since that is what
    # would actually be deployed.
    full = ForecastModel(n_bins=n_bins)
    full.train(samples, households)
    filled, total = full.coverage()
    missing = sorted(set(range(total)) - set(full.bin_factor))
    print(f"bin coverage    : {filled}/{total} bins populated")
    if missing:
        print(f"unobserved hours: {missing}")
    print(f"production slope: {full.production_slope:.4f} "
          f"(theory: {SLOT_FRACTION_OF_HOUR:.4f})\n")

    cm_mae, cm_mape = _mae_mape(cons_model)
    cb_mae, cb_mape = _mae_mape(cons_base)
    pm_mae, pm_mape = _mae_mape(prod_model)

    def fmt(x: Optional[float]) -> str:
        return f"{x:6.1f}%" if x is not None else "   n/a"

    print("consumption")
    print(f"  model    MAE {cm_mae:8.1f} Wh   MAPE {fmt(cm_mape)}")
    print(f"  baseline MAE {cb_mae:8.1f} Wh   MAPE {fmt(cb_mape)}")
    if cb_mae > 0:
        print(f"  improvement over baseline: {100 * (1 - cm_mae / cb_mae):.1f}%")

    total_preds = sum(conf_counts.values()) or 1
    breakdown = "  ".join(
        f"{k}={conf_counts[k]} ({100 * conf_counts[k] / total_preds:.0f}%)"
        for k in ("ok", "sparse", "interpolated", "fallback")
        if conf_counts.get(k)
    )
    print(f"  estimate source: {breakdown}")

    pp_mae, pp_mape = _mae_mape(prod_projected)
    print("\nproduction")
    print(f"  measured weather  MAE {pm_mae:8.1f} Wh   MAPE {fmt(pm_mape)}")
    print(f"  projected weather MAE {pp_mae:8.1f} Wh   MAPE {fmt(pp_mape)}"
          f"   <- the live forecast path")

    print("\nNote: slot-level consumption MAPE below ~8% is not achievable - "
          "that is the simulator's\n      uniform(0.85, 1.15) noise. A better "
          "number means the split leaked.")


# ─────────────────────────────────────────────────────────────────────

def train_from_db(db_path: Path = DB_PATH,
                  config_path: Path = CONFIG_PATH,
                  n_bins: int = 24) -> ForecastModel:
    """Convenience entry point for ai_forecast.py."""
    samples = load_history(db_path)
    households = load_household_config(config_path)
    model = ForecastModel(n_bins=n_bins)
    model.train(samples, households)
    return model


if __name__ == "__main__":
    samples = load_history()
    households = load_household_config()

    print(f"loaded {len(samples)} joined rows "
          f"across {len({s.household_id for s in samples})} households\n")

    per_hh: Dict[str, int] = defaultdict(int)
    for s in samples:
        per_hh[s.household_id] += 1
    for h in sorted(per_hh):
        print(f"  {h}: {per_hh[h]} rows")
    print()

    validate(samples, households)
