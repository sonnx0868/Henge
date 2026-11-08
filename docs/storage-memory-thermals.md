# Storage, memory, sustained performance and Apple Account support

## Larger disks

New installations can choose 64, 96, 128 or 256 GiB of logical disk capacity.
The image remains sparse: the selected capacity is not immediately allocated,
and available physical storage still limits how much the guest can write.
The installer passes this capacity to the blank image before restore, so the
restore system can create the partition map for that disk.

This setting does not resize an existing Mac. A usual restored disk contains,
in order, an ISC container, the main APFS container and a Recovery container.
Adding bytes to the image puts space after Recovery, not after the main APFS
physical store. `diskutil apfs resizeContainer <store> limits` is a read-only
way to inspect the maximum size. `resizeContainer ... 0` does not mean move
the next partition out of the way.

For an existing disk, a supported expansion needs an offline copy, verified
partition/container handling and a tested boot/recovery path before replacing
the original. There is no automatic live-resize implementation in this branch.
Installing another Mac with a larger disk also requires a separate data-migration
step; changing this new-install setting does not migrate a current Mac's files.

## Guest memory and MeloNX 2.7

The official MeloNX 2.7 tag resolves to commit
`13700519f3abc4e6d7ed8a065b118b2cc59bcd67`:
<https://starforgejo.dev/projects/MeloNX/src/tag/2.7>.
The implementation was inspected through its public Git transport, since the
web frontend returned HTTP 403 to the research client.

Its `MeloNXRamDonor/main.m` creates memory in an extension and exports it through
`xpc_shmem_create`. `Core/Memory/MLXRamDonor.m` maps those chunks into a contiguous
region with `xpc_shmem_map` and `mach_vm_remap`. Chunks are 256 MiB, with up to four
donors and headroom deducted from each donor's reported allocation budget.
The Swift configuration defaults to terminating donors after mapping. This is
allocation/ownership machinery, not additional physical RAM or a faster CPU.
The extension startup and private endpoint-decoding hook are additional lifecycle
and compatibility concerns that a port would need to test.

Henge already first tries named Mach memory entries with
`mach_memory_entry_ownership(..., LEDGER_NO_FOOTPRINT)`, in 128 MiB chunks.
If this fails it can use an unlinked, mapped RAM file; anonymous RAM is the last
fallback. A successful ledger allocation already achieves the relevant goal of
excluding guest RAM from the app's footprint without a donor extension.

An extension allocator could be useful if ledger ownership is refused and the
file-backed fallback demonstrably bottlenecks. It is not justified solely by
a larger guest-RAM selection. The opt-in diagnostic snapshot now records the
actual successful backend, physical host RAM and the app's remaining allocation
budget. The latter is **not** a measurement of system-wide free physical RAM.
Do not introduce a donor allocator without a measured comparison of startup,
footprint, memory pressure and workload performance on the target device.

## Sustained performance

The refresh-rate selector now also offers 30 Hz, applied at the next guest boot.
It changes the refresh rate advertised to the guest; it does not merely dim the
image or skip cursor events. The default remains 60 Hz. Use it as an optional
tradeoff with visibly less fluid movement, rather than a claim of faster video.
The existing Low load screen preset reduces rendered pixels.

Neither setting bypasses iPadOS thermal protection. Lower refresh and resolution
can reduce display work, but guest CPU translation, video decoding, other apps,
charging and ambient conditions can still make the device hot. Measure the same
workload at 60 and 30 Hz with thermal-state logs before claiming a reduction in
thermal dimming. Do not raise screen brightness in a loop to counter the OS.

Apple recommends reducing CPU/GPU/I/O work and frame rate at elevated thermal
states: <https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html>.

## Apple Account and iCloud

Apple documents VM iCloud support for VMs created through macOS 15 or newer
Virtualization.framework, using an appropriate restore image/hardware model.
The framework creates a VM identity derived from the **Mac host's Secure
Enclave** and changes it when moving to another Mac host. Upgrading an older
VM alone is insufficient.

Henge emulates the VMApple platform on iOS; it does not have that macOS-host
Virtualization.framework identity path. Its existing verification failure
cannot therefore be described as a fixed serial-number field. No supported
native-iCloud login fix has been implemented here. Do not rotate ECID/seed,
erase account state or reuse another machine's identity as a speculative fix.

Primary source:
<https://developer.apple.com/documentation/virtualization/using-icloud-with-macos-virtual-machines>.
