# Phase 3 — AI Prediction & Incentive Model: Implementation Design

Design notes for the optional Phase 3 bonus. Covers what we are actually predicting,
which starter-code defects have to be fixed first, how to shape the incentive, and how
to produce a demo that shows contrast.

---

## 1. What we are actually predicting

`data_simulator.py` is fully deterministic plus bounded noise, and we are not allowed to
modify it. That fixes the problem far more tightly than "forecast energy demand" suggests.

**Consumption** (`_calculate_consumption`, data_simulator.py:175-196):

```
consumption_wh = base_kwh × factor(sim_hour) × 0.25 × 1000 × uniform(0.85, 1.15)
```

`factor` is a step function of the simulated hour: 2.5 (07-09), 1.8 (12-14), 3.0 (18-22),
0.4 (23-06), 1.0 otherwise.

**Production** (`_calculate_production`, data_simulator.py:198-211):

```
production_wh = peak_kwp × irradiance_wm2 × 0.25 × uniform(0.9, 1.05)
```

Two consequences drive the entire design.

### 1.1 There is a hard error floor

The consumption multiplier `uniform(0.85, 1.15)` alone implies a mean absolute percentage
error of roughly **7.5%** at slot level. No model beats that — it is irreducible noise.

This matters because the starter code suggests a reward band of "deviation < 100 promille
(10%)". Any competent model lands inside that band on almost every slot, so the incentive
would appear to do nothing and every household would ratchet to a perfect score within a
few simulated hours.

**Fix: score on hourly aggregates, not per slot.** One simulated hour = 4 slots
(15 sim-minutes each). Summing 4 slots cuts the relative noise by ~2×, to about **4%**.
A 10% reward band then becomes a genuine test of model skill rather than a coin flip.

This also happens to match the challenge spec exactly — "Prognosegranularität: Stündlich
(= alle 4 Minuten in Simulation)".

### 1.2 The default model is misspecified for consumption, and perfect for production

Production is *exactly linear in irradiance through the origin*. `LinearRegression`
already nails it (expect R² ≈ 0.99). Leave it alone.

Consumption is a **step function of `sim_hour`**. Fitting a straight line through a step
function is visibly wrong precisely where it matters — the morning and evening peaks,
which are also the slots that dominate trading volume.

**Fix:** one-hot encode the hour buckets, or use
`sklearn.ensemble.GradientBoostingRegressor` for the consumption target only. This single
change is the bulk of the accuracy win. An LSTM would be strictly worse effort-for-effort
here: there is no real sequential dependence to learn, only a lookup table plus noise.

Recommended feature set (unchanged inputs, better encoding):

| Feature | Encoding | Notes |
|---|---|---|
| `sim_hour` | one-hot bucket **and** sin/cos | bucket captures the step, cyclical captures wraparound |
| `sim_dayofweek` | one-hot | present in the schema, but the simulator ignores it — expect ~zero importance |
| `irradiance` | raw | the only feature production needs |
| `temperature_c_x10` | raw | weak signal; simulator does not use it for load |
| `cloud_cover` | raw | already reflected in irradiance, mildly redundant |

Note that `sim_dayofweek` carries no signal at all in the current simulator — the load
profile has no weekday/weekend distinction. Keep it in the feature vector for schema
compatibility, but do not expect it to help, and do not spend time engineering calendar
features.

---

## 2. Architecture

No new infrastructure. Three processes on one laptop, one SQLite file, one testnet.

```
oracle_writer.py ──> OracleStorage (Sepolia)  ──┐
       │                                         │
       └──> data/history.db (SQLite) ──> ai_forecast.py ──> IncentiveController
                                                                   │
                                       P2PEnergyMarket.settleSlot() reads
                                          getPriceMultiplier(consumer)
```

Training data volume: 1 slot/minute × 4 households. `load_training_data` requires
`min_rows=50`, so roughly **50 minutes of `oracle_writer.py` uptime** before the first
model can be trained. One full simulated day = 96 real minutes ≈ 96 rows per household.
That runtime requirement — not compute — is the real prerequisite. Training itself is
milliseconds on CPU.

### 2.1 The settlement hook is not wired yet

`P2PEnergyMarket.sol:179-195` documents the integration, but `_executeTrade` currently
calls `calculateCost(flowWh)` (P2PEnergyMarket.sol:339), which ignores the multiplier
entirely. Wiring it is a small change: pass `consumer` into the cost calculation and
scale by `getPriceMultiplier(consumer) / 1000`.

`getPriceMultiplier` is `view`, so unlike `batteryManager.decideAction()` it needs no
`try/catch` — it cannot corrupt storage. Do keep the `address(0)` guard so the market
still settles when the controller is not deployed.

---

## 3. Blocking defects in the starter code

These will silently destroy forecast quality regardless of model choice. Budget the first
working hour here, not on the model.

### 3.1 Train/serve skew on the time feature — fatal

Training rows carry `sim_hour` from the simulator's **virtual** clock, which runs 15×
real time and wraps every 96 real minutes. Inference uses `time.localtime().tm_hour` —
**real wall-clock time** (ai_forecast.py:206-207). Same mismatch for `sim_dow`
(`tm_wday`, a real weekday) versus the training column `sim_dayofweek` (which cycles
every ~11 real hours).

The model is trained on one clock and queried on another. Predictions are nonsense.

Additional trap: `oracle_writer.py:89` offsets `start_real_time` by 6 hours, so the
simulation actually begins at **sim hour 18.0** (evening peak), not 0.0. Recomputing the
clock from scratch in the forecaster will get this wrong.

**Fix:** read the most recent `sim_hour` from SQLite and extrapolate forward
(`+0.25` sim-hours per slot), rather than deriving it independently.

### 3.2 Forecasting the next slot with current weather

The script predicts `next_slot` but feeds it `getLatestWeather()`. Tolerable for a
one-slot horizon; wrong for the hourly horizon the spec asks for.

**Fix:** the irradiance curve is a deterministic sine over sim_hour
(data_simulator.py:143-147), so forecast irradiance analytically from the projected
`sim_hour` and treat only cloud cover as stochastic.

### 3.3 Actuals race condition

`getLatestMeterReading` after `time.sleep(60)` may already belong to a later slot.

**Fix:** use `getMeterAtSlot(household, slot)` — it exists at `OracleStorage.sol:176`
for exactly this purpose.

### 3.4 Slots are not contiguous

`currentSlot` tracks `block.timestamp`, not call count (`OracleStorage.sol:101`), while
`oracle_writer` sends up to 8 sequential transactions per slot. On Sepolia's ~12s blocks
a pass regularly exceeds 60s, so slots **skip**. `next_slot = current + 1` is frequently
wrong, and a skipped slot has no meter data written at all.

**Fix:** record which slot each forecast targeted and reconcile in a later iteration.
Skip slots where `getMeterAtSlot` returns zeros. The contract's existing early-return on
zero actuals (`IncentiveController.sol:171`) already fails safe here.

### 3.5 Nonce collisions between processes

`AI_PRIVATE_KEY` falls back to `DEPLOYER_PRIVATE_KEY` (ai_forecast.py:39). If that is the
same key `oracle_writer` uses, the two processes fight over nonces every slot and
transactions drop.

**Fix:** a genuinely separate funded wallet, authorized via `authorizeAI()`.

### 3.6 Fragile training-data JOIN

`load_training_data` joins on `m.timestamp = w.timestamp` (ai_forecast.py:56). But meter
and weather timestamps come from two separate `int(time.time())` calls in the same pass
(data_simulator.py:168 and :265) — they differ whenever the loop straddles a second
boundary, silently dropping training rows.

**Fix:** join on nearest timestamp, or on `sim_hour`, which both tables carry.

---

## 4. Incentive design

Recommendation: **reputation score (option B)**, not a direct per-slot multiplier. It
gives a visible time series to show judges and is smoother than per-slot scoring.

### 4.1 Scoring on net position

Score the *net* grid position rather than consumption alone — that is what the market
actually trades. But net crosses zero, so the naive
`|actual − forecast| / forecast` explodes near the crossover.

**Normalize by a stable scale** instead:

```
deviation = |net_actual − net_forecast| × 1000 / (expectedConsumption + expectedProduction)
```

The denominator never approaches zero for an active household, so the metric stays bounded.

### 4.2 Asymmetric ratchet

Slow gains, faster losses:

| Hourly deviation | Score change |
|---|---|
| < 60 promille (6%) | `+15` |
| 60 – 200 | `0` (neutral) |
| > 200 promille (20%) | `−40` |

Clamped to `[0, 1000]`.

Asymmetry matters: with a good model most hours land in the reward band, and a symmetric
rule would pin every household at 1000 within a few simulated hours, erasing the contrast
we need for the demo.

### 4.3 Price multiplier

Linear interpolation as sketched in the starter:

```
score 1000 → multiplier  800  (20% discount)
score  500 → multiplier 1000  (neutral)
score    0 → multiplier 1200  (20% surcharge)
```

Bounded by the existing `MAX_DISCOUNT` / `MAX_PENALTY` constants (200 promille each).

### 4.4 Two bugs to avoid in our own implementation

**The amnesty loophole.** `submitForecast` sets the score to 500 whenever it reads 0
(`IncentiveController.sol:120-122`). Since our update rule can *drive* a score down to 0,
a maximally-bad household gets silently reset to neutral on its next forecast — a free
pardon, and one a judge may well probe for.

**Fix:** add an explicit `mapping(address => bool) initialized` and stop overloading `0`
to mean both "new household" and "worst possible score". The commented
`getPriceMultiplier` sketch at `IncentiveController.sol:205` conflates the same two
states and needs the same fix.

### 4.5 Trust hardening (worth the 20 lines)

Currently the AI submits both the forecast **and** the actual, so it can trivially fake
its own accuracy. Since `IncentiveController` can import `IOracleStorage` and call
`getMeterAtSlot()` itself, we can drop `submitActual` entirely and expose a
permissionless `finalizeSlot(household, slot)` that reads the truth on-chain.

This removes the trust hole, halves our transaction count, and is the kind of thing that
scores well with judges. Recommended if time allows.

---

## 5. Producing demo contrast

The spec requires "mindestens 1 Haushalt mit Incentive-Belohnung vs. 1 ohne". This is the
genuinely hard part, and it is a *design* problem, not an engineering one.

Every household is generated by the same deterministic law, and we cannot modify the
simulator. So **no household can actually adapt its behaviour**. We need a defensible
story for where the contrast comes from.

### Preferred: battery flexibility as the adherence mechanism

Only `house_01` and `house_02` have batteries. `house_03` and `house_04` have
`battery_capacity_kwh: 0.0` in `config.json`.

Forecast each household's **net grid position**, and let `BatteryManager` be the
adherence mechanism: a household running the optimizer can steer its net position toward
the forecast, while a household with no battery structurally cannot.

Why this is the right choice:

- It is a real causal mechanism, not a staged result.
- It ties Phase 3 back into Phase 2 rather than bolting on a parallel system.
- The control group falls out of the existing config for free.

Implementation: the forecaster computes actuals the same way `settleSlot` does —
`.call()` on `decideAction` and apply the same `±amountWh` adjustment as
`P2PEnergyMarket.sol:227-231`. Note the battery effect is **not** visible in the meter
reading; the simulator's SoC is independent of `BatteryManager`. The adjustment must be
applied in our code to match what the market actually settles.

### Fallback if time runs short

Simply do not submit forecasts for two households. They sit at the neutral 1000
multiplier while the forecasted pair earn discounts. Weaker story, satisfies the
requirement, costs nothing.

---

## 6. Effort and sequencing

The ML is the small part — roughly 45 minutes once the clock bug is fixed. The real time
goes into the starter-code fixes and the settlement wiring.

Suggested order:

1. Start `oracle_writer.py` **immediately** and leave it running — everything downstream
   is gated on accumulating >50 rows per household. Do this before writing any code.
2. Fix the train/serve clock skew (§3.1). Nothing else matters until this is correct.
3. Fix the JOIN (§3.6) and re-check how many training rows actually survive.
4. Swap the consumption model to bucketed / gradient-boosted (§1.2).
5. Implement `_updateScoreForSlot` and `getPriceMultiplier` (§4).
6. Wire the multiplier into `_executeTrade` (§2.1).
7. Slot reconciliation and the actuals fix (§3.3, §3.4).
8. If time allows: on-chain actuals (§4.5) and batching (below).

### One cheap high-value addition

Add `submitForecastBatch(address[] households, uint256 slot, uint256[] cons, uint256[] prod)`
to the controller. That turns 8 transactions per slot into 2. On Sepolia with ~12s blocks
and `oracle_writer` already consuming 8 transactions per slot, this is the difference
between keeping pace with the slot cadence and falling permanently behind.

Also worth checking early: Sepolia faucet balance. Two processes at ~10 transactions per
minute will drain a thin wallet over a multi-hour run.
