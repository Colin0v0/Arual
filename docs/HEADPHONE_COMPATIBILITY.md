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
| AirPods / Beats (including AirPods Max) | Apple/Beats HAL | System-reported components or Main | Off plus HAL-supported cancellation, transparency, and adaptive modes | Model-dependent |
| Bose QuietComfort Ultra Headphones (2nd Gen) | Bose BMAP | Single device | Quiet, Aware | Upstream verified |
| Bose QuietComfort Ultra Earbuds (2nd Gen) | Bose BMAP | Left, right, case | Quiet, Aware | Upstream verified |
| Bose QuietComfort Headphones | Bose BMAP over SPP | Single device | Quiet, Aware | Upstream verified |
| Bose QuietComfort 45 | Bose BMAP over SPP | Single device | Quiet, Aware after initialization | Experimental |
| Sennheiser ACCENTUM Wireless | Qualcomm GAIA over RFCOMM | Single device | Off, cancellation, transparency | Upstream verified |
| Fast Pair battery extension | Google Fast Pair | Planned | Optional hearables extension | Planned |

“Protocol-dependent” means Aural waits for a real device reply before showing a
control. It is not a claim that every model in that list is compatible.

Sony V1/V2 is selected from the SDP service exposed by the connected device.
V2 battery uses `22 00 -> 23 00 <level> <charging>` only after the V2 service
and the 8-byte init reply are confirmed. Aural never sends that query to a
V1-only service, where `0x22` has a different meaning. Apple modes are read
from `lstm`/`lsms`; Off is the system's raw mode `1`, while cancellation,
transparency, and adaptive are exposed only when their capability bits are set.

Bose support covers the QuietComfort Ultra Headphones (2nd Gen, `0x4082`,
wolverine), Ultra Earbuds (2nd Gen, `0x4062`, edith), QuietComfort Headphones
(`0x4075`, prince), and QuietComfort 45 (`0x4039`, duran). The Ultra products
use RFCOMM channel 2; the other two use their SPP service and discover the
channel through SDP. QC45 must complete the legacy initialization reply before
product identity is queried. Product ID confirmation selects the model and
battery layout; Bluetooth names only select the candidate driver. Quiet and
Aware are the two exposed presets; the UI does not invent an Off mode or map
Immersion to either.

The earbud battery records identify right (`1`), left (`2`), and case (`3`).
Aural does not use combined buds (`4`) to fill missing component values or infer
charging or wear state. A valid new reading replaces the previous component
snapshot, so unavailable parts do not retain stale percentages. Other Bose
models still require separate protocol work. The four listed products have
upstream hardware evidence; Aural has not completed independent Bose hardware
acceptance.

AirPods Max is treated as an over-ear Apple device, not as a pair of earbuds.
When the HAL does not expose active in-ear placement, Aural does not use
`unknown` placement to hide listening modes. If the system report provides only
`device_batteryLevelMain`, that value is shown as a single battery; left,
right, and case values are not synthesized. Earbuds with active ear detection
continue to require both ears for mode changes.

Sennheiser ACCENTUM Wireless uses the GAIA V3 RFCOMM service UUID
`a2129ff3-081b-4c45-8afe-469d9c4842ec`. Aural verifies the exact `ACAEBT`
model response and derives the visible mode from independent ANC and
transparency toggles. ACCENTUM Plus, ACCENTUM True Wireless, and MOMENTUM 4
are not mapped to these commands without separate capture evidence.

## Research backlog

These brands or models are not listed as supported until both the control
protocol and the device identity join are proven on macOS.

| Candidate | Current blocker |
| --- | --- |
| JBL Tune Flex 2 / JBL GATT family | The ANC protocol is documented by the MIT-licensed JblTray project, but macOS public CoreBluetooth does not expose the BLE MAC used to prove that a GATT peripheral is the same device as the selected Core Audio output. A name-only match is not acceptable. |
| Huawei FreeBuds / FreeBuds Studio | No verified Aural implementation yet; each family needs its control transport, product identity, battery layout, and mode readback captured independently. |
| Xiaomi / Redmi Buds | Same requirement as Huawei; model-name matching alone cannot establish a safe control channel. |
| vivo TWS | Same requirement; no verified channel or capability table is included in this build. |

Apple headphone support is capability-driven through the HAL. AirPods Max
hardware still needs independent Aural acceptance even though the no-wear-gate
and single-battery paths are now covered by simulator tests.

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
