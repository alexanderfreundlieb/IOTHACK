# Phase 3 — High-Level Design

AI-driven load forecasting with on-chain price incentives for households.

This document describes *what we are building and why*. For the implementation-level
detail — specific defects, feature encodings, scoring thresholds — see
[PHASE3_DESIGN.md](PHASE3_DESIGN.md).

---

## 1. Goal

An AI model forecasts each household's energy consumption and PV production one hour
ahead. Households whose actual behaviour matches the forecast pay a better price for
energy. Households that deviate pay a worse one. The entire incentive mechanism lives
on-chain in a smart contract.

The economic idea: a grid is cheaper to operate when demand is predictable. So we pay
households for predictability, not for consuming less.

---

## 2. System overview

Phase 3 adds one contract and one process to the existing Phase 1/2 system. Nothing else
changes.

```
                    ┌──────────────────────┐
                    │  data_simulator.py   │   (given — not modified)
                    │  synthetic households│
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │  oracle_writer.py    │   (given — not modified)
                    └─────┬──────────┬─────┘
                          │          │
              ┌───────────▼──┐    ┌──▼──────────────────┐
              │ history.db   │    │  OracleStorage      │
              │ (SQLite)     │    │  (on-chain truth)   │
              └───────┬──────┘    └──┬───────────────┬──┘
                      │              │               │
                      │  training    │  features     │  actuals
                      │              │               │
              ┌───────▼──────────────▼───┐           │
              │    ai_forecast.py        │  NEW      │
              │  train → predict → submit│           │
              └───────────┬──────────────┘           │
                          │ forecasts                │
              ┌───────────▼──────────────────────────▼──┐
              │       IncentiveController.sol       NEW │
              │  forecast vs actual → reputation score  │
              │            → price multiplier           │
              └───────────────────┬─────────────────────┘
                                  │ getPriceMultiplier(consumer)
              ┌───────────────────▼─────────────────────┐
              │        P2PEnergyMarket.settleSlot()     │
              │      applies multiplier to trade price  │
              └─────────────────────────────────────────┘
```

**Off-chain** does the work that is expensive or impossible on-chain: model training,
numerical prediction, historical data storage.

**On-chain** does the work that needs to be trustless and auditable: recording the
forecast *before* the fact, comparing it to reality *after* the fact, and deriving the
price everyone can verify.

The split matters. A forecast is only meaningful as a commitment — it must be recorded
before the outcome is known. That is exactly what a blockchain is good for, and it is the
reason this problem belongs on-chain at all rather than in a database.

---

## 3. The three flows

### 3.1 Training (once, then periodically)

`ai_forecast.py` reads accumulated history from SQLite — consumption, production, weather,
and time-of-day features — and fits one model per household. Each household has different
PV capacity and a different baseline load, so per-household models are simpler and more
accurate than one shared model with household identity as a feature.

Two separate targets per household: **consumption** and **production**. They have
fundamentally different structure (see §5.1), so they get different model types.

### 3.2 Forecasting (every slot)

For the upcoming hour, the forecaster:

1. Projects the simulated clock forward
2. Derives the expected weather for that time
3. Predicts consumption and production per household
4. Writes the prediction on-chain via `submitForecast`

The prediction is now a public, timestamped commitment.

### 3.3 Settlement (every slot, after the fact)

Once the hour has elapsed, actual meter readings are compared to the commitment. The
deviation updates a **reputation score** per household. When `P2PEnergyMarket` settles a
trade, it reads that household's score and adjusts the price it pays.

---

## 4. The incentive mechanism

### 4.1 Why reputation rather than per-slot pricing

A per-slot multiplier would be simpler: deviate this hour, pay more this hour. We prefer a
persistent reputation score for three reasons:

- **It smooths noise.** Any single hour contains substantial irreducible randomness. A
  household should not be punished for one unlucky slot.
- **It is legible.** A score trending up or down over a demo run tells a story that a
  jittery per-slot price does not.
- **It compounds correctly.** Sustained predictability earns a sustained discount, which
  is the actual economic behaviour we want to reward.

### 4.2 Shape of the mechanism

```
   forecast ─┐
             ├─→ deviation ─→ score update ─→ price multiplier ─→ trade price
   actual  ──┘   (bounded)     (asymmetric)     (800–1200‰)
```

- **Deviation** is normalized against a stable reference so it stays bounded even when a
  household's net position crosses zero.
- **Score update** is asymmetric — gains accrue slowly, losses faster. Without this,
  every household saturates at the maximum score within a few simulated hours and the
  contrast disappears.
- **Multiplier** interpolates linearly between a 20% discount and a 20% surcharge,
  bounded by the constants already defined in the contract.

The multiplier applies to the **consumer** side of a trade, matching the starter contract's
documented intent. The consumer is the party whose predictability the grid cares about.

### 4.3 Trust boundary

The AI is a privileged actor — it writes forecasts. It must **not** also be the source of
truth for actuals, or it could fake its own accuracy.

Design decision: `IncentiveController` reads actual meter values directly from
`OracleStorage` rather than accepting them from the AI. The AI can only commit
predictions; it cannot grade its own homework. This costs about twenty lines and closes
the obvious attack on the whole mechanism.

---

## 5. Key design decisions

### 5.1 Model choice is driven by structure, not by sophistication

The two targets have genuinely different shapes:

- **Production** is linear in solar irradiance through the origin. A linear model is not
  a simplification here — it is the correct functional form.
- **Consumption** is a step function of time-of-day (morning peak, midday, evening peak,
  night). A linear model is structurally wrong for it, most visibly at the peaks, which
  are also the highest-volume trading periods.

So: linear for production, bucketed or tree-based for consumption. Deliberately **not**
an LSTM — there is no sequential dependence to learn here, only a lookup table plus noise,
and it would cost hours for no accuracy gain.

### 5.2 Forecast the net grid position

We forecast net position (production minus consumption, adjusted for battery action)
rather than raw meter values, because net position is what the market actually trades and
therefore what predictability is worth money for.

### 5.3 Score hourly, not per slot

The simulation's per-slot noise is large enough that a tight reward band would be hit
essentially at random. Aggregating to the hour cuts that noise roughly in half and makes
the reward band a real test of forecast skill. It also matches the challenge spec's
stated hourly granularity.

### 5.4 Fail open

Every Phase 3 integration point is optional and defaults to inactive. If the controller
is not deployed, `settleSlot` uses the unmodified base price and Phase 1/2 behaviour is
untouched. A failure in the incentive layer must never block energy trading — the same
principle the starter code already applies to the Phase 2 battery integration.

---

## 6. Demonstrating that it works

The requirement is at least one household visibly rewarded and one not.

This is the subtlest part of the design, because all four households are generated by the
same fixed simulator that we cannot modify — so strictly speaking **no household can
change its behaviour in response to price**. We need an honest mechanism for the
difference rather than a staged one.

**Our approach: battery flexibility is the adherence mechanism.**

`house_01` and `house_02` have batteries. `house_03` and `house_04` have none. A household
with storage can shift its *net grid position* toward the forecast by charging or
discharging; a household without storage is at the mercy of its raw load profile.

This gives us:

- A real causal story — flexibility enables adherence, adherence earns a discount
- Reuse of the Phase 2 `BatteryManager` rather than a parallel mechanism
- A control group that falls out of the existing configuration, not out of stagecraft

The expected demo result: the two battery households trend toward high reputation and a
discounted price; the two consumer-only households sit near neutral. That is a legitimate
finding about the value of flexibility, which is a better story than an engineered one.

**Fallback**, if time runs short: submit forecasts for only two households. The others
remain at the neutral multiplier. This satisfies the requirement but demonstrates
plumbing rather than an economic effect.

---

## 7. Infrastructure

None beyond a laptop.

Training data is a few hundred rows of five features per household. Models train in
milliseconds on CPU. No GPU, no cloud, no container, no external database — SQLite plus
three Python processes plus the Sepolia testnet.

The one real constraint is **wall-clock time**: `oracle_writer.py` must accumulate roughly
50 minutes of history before the first model can be trained. That is the actual gating
factor for Phase 3, and it argues for starting the data collection process before writing
any Phase 3 code at all.

Secondary practical constraints: the forecaster needs its own funded wallet to avoid
transaction-nonce contention with the oracle writer, and transaction volume per slot
should be batched to keep pace with the slot cadence on a public testnet.

---

## 8. Scope summary

| Component | Status | Work |
|---|---|---|
| `data_simulator.py` | given | none — do not modify |
| `oracle_writer.py` | given | none — do not modify |
| `OracleStorage.sol` | given | none — do not modify |
| `ai_forecast.py` | starter | fix clock skew, improve model, wire submission |
| `IncentiveController.sol` | starter | implement scoring + multiplier, read actuals on-chain |
| `P2PEnergyMarket.sol` | ours | apply multiplier in trade pricing |

The forecasting model is the smallest piece of the work. The bulk is correcting the
forecaster's data plumbing and implementing the on-chain incentive logic.
