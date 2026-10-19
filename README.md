# PowerService

External CPU profile owner for R4OS. CPUPOWER owns the hardware backends.

POWERSVC starts automatically with the profile selected in
`C:\R4OS\CONFIG\POWER.R4S`. The installed default is `firmware`: it leaves
hardware parameters alone and creates no CPU workers. The other profiles are
`balanced`, `performance` and `saving`, expressed in the backend's abstract
performance units and optional energy/performance preference.

After both direct providers report unsupported, the service may use CPUPOWER's
separate ACPIPLAT backend. Disabled or uncertain direct control never triggers a
competing firmware fallback. ACPI CPPC uses its declared abstract units; legacy
P-states use nonzero ordering ranks, not MHz. PSS saving chooses the lowest
declared rank, while balanced/performance choose the highest nominal declared
state because PSS supplies no autonomous range/EPP controller.

A firmware domain has one actual leader worker. Summary masks expand only its
confirmed whole-domain receipt; follower rows do not invent independent tokens.
The whole group remains reserved until original words and the real lease return
are confirmed. Firmware catalogue withdrawal retains the controller's exact
token for sensor-independent return. Unsupported transports and missing domains
leave firmware parameters unchanged.

The fixed common per-CPU profile record keeps its raw HWP/CPPC word meanings.
Those words and request-valid bits remain unavailable for firmware. The
controller keeps the independent `CpuFirmwareInfo` privately for exact parameter,
firmware-generation and domain confirmation; `SYSINFO /CPUFW:<cpu>` exposes
that separate receipt. Firmware fingerprints are never reported as raw MSRs.

Use `SYSINFO /POWER` for intent and confirmed masks, `/POWER:balanced`,
`/POWER:performance`, `/POWER:saving` or `/POWER:firmware` to select a profile,
and `/POWERCPU:n` for an individual receipt. `quiesce`, `resume` and `reload`
are explicit `/POWER:` operations. Each mutation binds the exact service
generation and revision; a timeout has an unknown outcome and is never retried
automatically. Configuration uses the existing R4STD atomic document owner.

Only a non-firmware profile accepts the additional `/ENABLE` argument. This
is separate consent for reset-only interface activation, never saved as startup
consent. Returning owned parameters does not disable an already enabled
interface. Unsupported, virtual or missing hardware never reports an applied
profile; actual clock, boost, temperature and energy response remain unknown.

Workers are hard placed on their own CPU before the first provider call. They
keep exact provider/CPU/token/revision receipts and return the original baseline
before exit and real join. Foreign controls are never adopted. Failed or
uncertain returns retain their owner and block a false stop acknowledgement.
SYSINFO CPU changes quiesce the whole service before membership changes.
Normal system transitions close new requests, stop POWERSVC cooperatively and
wait for real returns and callback completion before stopping other CPUs.

Build with Build.sh (Linux) or Build.bat (Windows); both use shared PowerShell7.
The `test` target checks the actual policy, receipt, protocol and join owners
with simulated peers, without host CPU probes. `/SELFTEST` explicitly checks
the live R4STD configuration and service IPC contracts without profile writes.
Physical HWP/CPPC response needs separate qualification on supported hardware.
