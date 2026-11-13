# Headphone compatibility and community testing

Aural does not claim that every model from a supported brand works. Headphone
firmware changes frequently, and several vendors use more than one control
protocol within the same product family.

The compatibility matrix records evidence, not marketing coverage. A model can
appear in the model catalog before it appears as verified support.

## Status levels

| Status | Meaning |
| --- | --- |
| **Verified** | The current Aural build was tested on the exact model. |
| **Upstream verified** | The protocol was tested on the exact model by the upstream project, but Aural still needs an independent check. |
| **Community tested** | A contributor tested the exact model and reported the result. |
| **Experimental** | The model or protocol family is recognized, but the exact model has not been hardware-validated. |
| **Planned** | No working control adapter is shipped yet. |

The UI only shows a control after the connected device confirms the relevant
protocol response. A model name alone never enables battery or noise controls.

## Current matrix

| Model | Control path | Battery | Noise control | Status |
| --- | --- | --- | --- | --- |
| Bowers & Wilkins Px7 S3 | BLE RPC | Yes | Off, cancellation, transparency | Upstream verified |
| Bowers & Wilkins Px8 | BLE RPC | Yes | Off, cancellation, transparency | Upstream verified |
| Bowers & Wilkins Px7 S2 | BLE RPC | Yes | Off, cancellation, transparency | Experimental |
| Bowers & Wilkins Pi5 / Pi6 / Pi7 / Pi8 | BLE RPC | Yes | Off, cancellation, transparency | Experimental |
| Sony WH-1000XM3 | Sony MDR V1 | Yes | Off, cancellation, transparency, optional wind reduction | Upstream verified |
| Sony WH-1000XM5 | Sony MDR V2 | Yes | Off, cancellation, transparency | Upstream verified |
| Sony ULT WEAR | Sony MDR V2 | Yes | Off, cancellation, transparency | Upstream verified |
| Sony WH-1000XM2 / XM4 | Sony MDR V1 or V2 | Protocol-dependent | Protocol-dependent | Experimental |
| Sony WH-1000XM6 / WH-CH720N | Sony MDR V2 | Yes | Off, cancellation, transparency | Experimental |
| Sony WF-1000XM4 / WF-1000XM5 / WF-1000XM6 / LinkBuds S | Sony MDR V2 | Yes | Off, cancellation, transparency | Experimental |
| Sony WF-1000XM3 / WF-SP800N / WI-SP600N / MDR-1000X | Sony MDR V1 | Protocol-dependent | Protocol-dependent | Experimental |
| OPPO Enco Air5s | OPPO RFCOMM | Yes | Off, cancellation, transparency | Upstream verified |
| AirPods / Beats | Apple/Beats HAL | System-reported components | Off plus HAL-supported cancellation, transparency, and adaptive modes | Model-dependent |
| Bose QC / QuietComfort family | Bose BMAP | Planned | Planned | Planned |
| Fast Pair battery extension | Google Fast Pair | Planned | Optional hearables extension | Planned |

“Protocol-dependent” means Aural waits for a real device reply before showing a
control. It is not a claim that every model in that list is compatible.

Sony V1/V2 is selected from the SDP service exposed by the connected device.
V2 battery uses `22 00 -> 23 00 <level> <charging>` only after the V2 service
and the 8-byte init reply are confirmed. Aural never sends that query to a
V1-only service, where `0x22` has a different meaning. Apple modes are read
from `lstm`/`lsms`; Off is the system's raw mode `1`, while cancellation,
transparency, and adaptive are exposed only when their capability bits are set.

## Reporting a new model

Please open a GitHub issue with the `headphone-compatibility` label and include:

1. Exact model name and firmware version.
2. macOS version and Mac model.
3. The output name shown by macOS and whether it was renamed.
4. Battery readings tested (single value, left, right, charging case).
5. Every noise mode tested and whether switching back to the original mode worked.
6. Bluetooth SDP UUIDs or GATT services if available.
7. The output of **Copy Headphone Diagnostics** from Aural's menu, with private
   addresses or names removed if necessary.

Useful reports also mention reconnect behavior after:

- putting the headphones in the charging case;
- disconnecting and reconnecting Bluetooth;
- sleeping and waking the Mac;
- changing the macOS audio output;
- switching between the vendor app and Aural.

## Maintainer checklist

When adding a model:

- Add or update its `HeadphoneModelProfile` entry.
- Record the real mode count and optional modes.
- Keep the protocol readback requirement; do not enable controls from the name alone.
- Add unit tests for name matching and mode filtering.
- Update this matrix and the README summary.
- Mark the result as experimental until a real hardware report exists.

Protocol research may use GPL-licensed projects as facts, but Aural must not copy
their source code. MIT-compatible implementations can be adapted with the
required notices in `THIRD_PARTY_NOTICES.md`.
