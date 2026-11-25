# Does the US2000 obey output-control commands?

`upscmd -l` lists the full HID power-device command set (`load.off`, `load.off.delay`, `shutdown.return`, `shutdown.stop`, …) and `ups.delay.shutdown` / `ups.delay.start` are writable. That listing comes from NUT's generic Power Device Class mapping, **not** from the US2000's firmware. The same device hardcodes `battery.runtime` to `0xFFFF`, pins `ups.load` and `input.voltage` to 1 and never raises `LB`, so the commands may be accepted and ignored.

This procedure answers whether the hardware obeys, without putting the NAS at risk.

## Result, measured 2026-11-25

**It does not.** With a 1.5 W load on the UPS output, every path was tried and the output never switched:

| Path | Outcome |
|---|---|
| `upsrw -s ups.delay.shutdown=60` | Accepted. `upsc` then reports 60, but after a driver restart the device reports 20 again: the write never reached the hardware. |
| `load.off.delay`, `shutdown.return` | Accepted. `ups.timer.shutdown` counts 20 → 0 at one per second, so the countdown is real. The output never drops. |
| `shutdown.stop` | Works. The timer returns to `-1` and the load does not flicker. |
| `load.off`, no delay | Accepted. Nothing happens. |
| `driver.killpower`, flag unlocked | Ends the driver, as designed. The load stays powered. |

Across 242 consecutive one-second samples spanning a full countdown, `output.current` read `0.07` and `output.voltage` read `12.36`, without a single other value.

The command set in `upscmd -l` is therefore NUT's generic Power Device Class mapping and nothing more, like `battery.runtime`, `ups.load` and the `LB` bits before it. **Unattended recovery from DSM Safe Mode cannot be built on this UPS in software.** It needs external hardware that can break the 12 V feed.

One caveat on method: `driver.killpower` ends the driver, which is the only instrument that reads the output, so that row rests on watching the load by eye rather than on telemetry.

The procedure below is kept so the same question can be settled on another US2000 or on a sibling model.

Why it matters: DSM in Safe Mode is halted, not asleep — it stops its services, unmounts the volumes and waits for the UPS to remove power, which is what the standard NUT design expects. The US2000 never does, so DSM stays parked. If the UPS can cut and restore its own output on a timer, that missing half of the design is back, and the timer runs inside the UPS, so it survives Safe Mode stopping Docker on the NAS.

## Have at hand

- The NAS's original 12 V adapter, to power the NAS directly during the test.
- Optionally a throwaway 12 V load for the UPS output, such as a fan or an LED strip, to see the output drop with your own eyes. It is not strictly needed: `output.voltage` and `output.current` come from the decoded `0x71` frame, so they are real readings rather than hardcoded ones, and a cut shows up there.
- The barrel polarity of the UPS output. Reversed polarity destroys hardware.

## Safety

The NAS must **not** be powered by the UPS during this test. Getting there needs a clean shutdown: the NAS has one DC jack, so there is no hot swap.

1. In DSM, **uncheck Enable UPS support** (Control Panel → Hardware & Power → UPS) and apply. Skipping this is the one mistake that ends the test before it starts: the moment the UPS loses its input it reports `OB`, and DSM parks itself in Safe Mode once Customize time expires.
2. Shut DSM down cleanly and wait for the fans to stop.
3. Move the 12 V adapter from the UPS input to the NAS. Leave the **USB** cable from the UPS to the NAS connected, so the driver keeps talking to it. Put the throwaway load, if any, on the UPS output.
4. Power the NAS on.

With a single adapter the UPS now runs on its battery, so `ups.status` reads `OB` for the whole test. That is expected, and it matches the real scenario, where the timer is armed while on battery. With two adapters, keep the UPS on mains and it stays `OL` instead.

`ups.load` falling from the NAS's figure to almost nothing confirms the rewiring took effect. Because the NAS is no longer on UPS power, restarting the container during the test costs nothing.

## Grant command permissions

`monuser` has `upsmon secondary` rights and cannot issue commands, so add a temporary account. Replace `CHANGEME` with a throwaway password and paste:

```bash
sudo tee -a /volume1/docker/nut-us2000/config/upsd.users >/dev/null <<'EOF'

[cmdtest]
    password = CHANGEME
    actions = SET
    instcmds = ALL
EOF
sudo chmod 600 /volume1/docker/nut-us2000/config/upsd.users
sudo /var/packages/ContainerManager/target/usr/bin/docker restart nut-us2000
```

This account can switch the UPS output off. Use a password you discard afterwards, and remove the section when the test is done.

Shorthand for the commands below:

```bash
X="sudo /var/packages/ContainerManager/target/usr/bin/docker exec nut-us2000 /opt/nut-install/bin"
```

## Step 1 — the driver still sees the UPS

```bash
/usr/bin/upsc ups@172.18.0.1 ups.status
/usr/bin/upsc ups@172.18.0.1 | grep -E 'delay|timer'
```

Expect `OL`, and `ups.timer.shutdown: -1` meaning no countdown is armed. Reading values needs no account.

## Step 2 — does the firmware accept a countdown?

```bash
$X/upsrw -s ups.delay.shutdown=60 -u cmdtest -p 'CHANGEME' ups@127.0.0.1
$X/upscmd -u cmdtest -p 'CHANGEME' ups@127.0.0.1 load.off.delay
/usr/bin/upsc ups@172.18.0.1 ups.delay.shutdown
/usr/bin/upsc ups@172.18.0.1 ups.timer.shutdown
```

The read-back of `ups.delay.shutdown` is a separate signal from the countdown: if it still reads 20, the write itself was swallowed and nothing else matters.

Read `ups.timer.shutdown` a few times, a couple of seconds apart.

**This is the decisive signal, and it arrives before any power is cut.** If the value counts down from 60, the firmware took the command. If it stays `-1`, the mapping is decorative and the rest of this procedure is pointless.

## Step 3 — does cancelling work?

Test the cancel path *before* letting any countdown reach zero.

```bash
$X/upscmd -u cmdtest -p 'CHANGEME' ups@127.0.0.1 shutdown.stop
/usr/bin/upsc ups@172.18.0.1 ups.timer.shutdown
```

Expect the timer back at `-1`. This matters more than the cut itself: in the real design the countdown must be cancellable the moment mains returns, or the UPS will cut power to a fully running NAS.

## Step 4 — does the output drop, and come back?

Re-arm and let it expire, watching the throwaway load:

```bash
$X/upsrw -s ups.delay.shutdown=30 -u cmdtest -p 'CHANGEME' ups@127.0.0.1
$X/upscmd -u cmdtest -p 'CHANGEME' ups@127.0.0.1 shutdown.return
```

`shutdown.return` means "turn off the load and return when power is back". Mains is present throughout, so the output should return on its own after `ups.delay.start`, 30 s by default.

## What the outcomes mean

| Observation | Conclusion |
|---|---|
| `ups.timer.shutdown` never moves | Firmware ignores the command. Unattended recovery needs external hardware that can break the 12 V feed. |
| Timer counts down but the output never drops | Same conclusion: the mapping is decorative. |
| Output drops **and returns by itself** | The design is viable. Next: arm the timer on `OB` from the container, cancel on `OL`, and set the BIOS to power on after power loss. |
| Output drops and stays off | Worse than the status quo — the NAS would stay dead until someone intervenes. Do not build on `shutdown.return`; check whether `load.on.delay` can be pre-armed instead. |

## Restore afterwards

```bash
sudo sed -i '/^\[cmdtest\]/,$d' /volume1/docker/nut-us2000/config/upsd.users
sudo /var/packages/ContainerManager/target/usr/bin/docker restart nut-us2000
/usr/bin/upsc ups@172.18.0.1 ups.status
```

That `sed` deletes from the `[cmdtest]` header to the end of the file, which is safe only because the section was appended last. Check the file afterwards.

Then reconnect the NAS to the UPS output, remove the throwaway load, and confirm DSM shows the UPS as connected again.
