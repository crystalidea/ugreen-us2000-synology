# UGREEN US2000 UPS on Synology DSM (NUT in Docker)

DSM's bundled `usbhid-ups` (Generic HID 0.47) does not recognise the UGREEN US2000: it reports `No matching HID UPS found` and rejects the `subdriver` option. This project builds NUT with the experimental `ugreen-hid` subdriver in a container and serves it to DSM's own **Synology UPS server** client over the Docker bridge.

Tested on real hardware on 2026-11-24:

| Component | Version |
|---|---|
| NAS | UGREEN NASync DXP2800, Intel N100 |
| OS | Synology DSM 7.4.1-90080 Update 2 via Arc Loader 4.2.3 (emulated SA6400) |
| Container Manager | Docker Engine 24.0.2, Compose v2.20.1 |
| UPS | UGREEN US2000 `DC200`, USB `2b89:ffff`, 12 V DC |
| NUT | `2.8.5.1-0+g88948fb`, Generic HID 0.74, libusb 1.0 0.55 |
| Subdriver | UGREEN HID 0.05, from [PR #3780](https://github.com/networkupstools/nut/pull/3780) (open, unmerged) |

## Limitations

- **No unattended recovery.** DSM enters Safe Mode on battery but does not leave it when mains returns: the NUT server runs in Docker on the same NAS, and Safe Mode stops it. Recovery needed a short power-button press and a manual power-on.
- The subdriver is experimental and not upstream.
- `battery.runtime: 65535` is invalid and the UPS never raises `LB`. Shutdown timing comes only from DSM's **Customize time**.
- Logs prove safe shutdown was *initiated*; a complete volume unmount was not independently audited.
- Back up your data before testing power loss.

## Requirements

x86_64 DSM with Container Manager and USB passthrough; the US2000 powering the NAS with its USB cable attached; SSH with `sudo`; internet access for the build (643 MB image, about 5 minutes on an N100).

## Install

Check first that `172.18.0.0/16` collides with no existing Docker network, as Compose pins the bridge to that subnet with gateway `172.18.0.1` and publishes port 3493 only there:

```bash
sudo /var/packages/ContainerManager/target/usr/bin/docker network ls
```

Then:

```bash
sudo mkdir -p /volume1/docker/nut-us2000
cd /volume1/docker/nut-us2000
sudo curl -fsSL https://github.com/crystalidea/ugreen-us2000-synology/archive/refs/heads/main.tar.gz | sudo tar xz --strip-components=1
sudo chmod 600 config/upsd.conf config/upsd.users
sudo /var/packages/ContainerManager/target/usr/bin/docker compose up -d --build
sudo /var/packages/ContainerManager/target/usr/bin/docker logs nut-us2000
```

Expected in the log:

```text
Using subdriver: UGREEN HID 0.05
Listening on socket /var/state/ups/usbhid-ups-ups
Connected to UPS [ups]: usbhid-ups-ups
```

`nut_libusb_get_string: Pipe error` appears once at startup and did not prevent operation.

## DSM setup

**Control Panel → Hardware & Power → UPS:**

1. Enable UPS support.
2. UPS type: **Synology UPS server**.
3. Network UPS server IP: **172.18.0.1**. DSM rejects `127.0.0.1` as invalid, which is why the port is bound to the bridge gateway instead of loopback.
4. **Customize time**: choose it from measured runtime. The test used 1 minute.

DSM then shows `UGREEN / US2000 / Connected`.

DSM picks the monitoring credentials itself — it writes `MONITOR ups@<ip> 1 monuser secret slave` into its own `/etc/ups/upsmon.conf` and offers no field for them — so `config/upsd.users` must contain exactly `monuser` / `secret` and the password cannot be strengthened. The account holds only `upsmon secondary` rights and cannot force a shutdown, and `upsc` reads need no account at all, so isolation is the real control: never expose port 3493 beyond the bridge.

## Verify

```bash
/usr/bin/upsc ups@172.18.0.1 ups.status
```

`OL` on mains, `OB` on battery. To test the transition, interrupt power to the **US2000 input adapter only** — never the output feeding the NAS.

## Evidence from the test

| Check | Result |
|---|---|
| Clean build from this repository | `exit 0`, ~5 min, 643 MB; `/opt/nut` at `88948fb8c0ab…` and the compiled binary contains `UGREEN HID 0.05` |
| Download integrity | md5 of all six files matched the repository; DSM ships GNU tar 1.34 |
| Telemetry | charge, voltage, current, temperature and load all changed live |
| Power transition | `OL → OB → OL` on unplugging and restoring the input adapter |
| Redeploy downtime | DSM logged `Poll UPS failed` at 16:07:13 and `connected` at 16:07:25 — 12 s, reconnected unaided |
| Stability | `RestartCount=0`, driver started once, the data-loss watchdog never fired |
| Safe Mode | `UPS on battery` 14:53:26 → `UPS wait time up` and `safe shutdown` 14:54:27, with Customize time = 1 minute |
| Leaving Safe Mode | **not observed** |

## Why the commit is pinned by SHA

The Dockerfile fetches `88948fb8c0ab5e2cfa92e6f832b613e0a2094f56` by full SHA rather than checking out a branch. PR #3780 is open, so its branch can be rebased or force-pushed, and a branch ref would silently build a different revision. When US2000 support reaches a stable NUT release, compare it against this commit before upgrading.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `No matching HID UPS found` | Stock DSM driver, which has no US2000 subdriver; it rejects `-x subdriver=...` as well. |
| `Can't chdir to /var/state/ups` | `start.sh` creates that directory; check it ran. |
| `Connection refused` right after a reboot | DSM `upsmon` starts before Docker. It reconnected by itself after 5 s in the test. |
| Container exits with `UPS data unavailable` | The driver or `upsd` stopped answering. `start.sh` exits deliberately so the restart policy rebuilds both: `upsd` alone would leave DSM showing a connected UPS that can never report `OB`. |
| `upsd.conf is world readable` | The `chmod 600` step was skipped. |
| DSM GUI rejects the address | Use the bridge gateway, not loopback. |
| `battery.runtime: 65535` | Invalid; ignore it. |
| HDMI shows no signal | The DXP2800 gave no video output after DSM booted; observe through DSM and SSH. |

## Remaining work

- Verify on another NAS model and DSM build.
- Confirm volumes finish unmounting during Safe Mode.
- Unattended recovery after mains returns. Not possible in software: the UPS accepts output-control commands and ignores them, so it needs external hardware that can break the 12 V feed — see [output-control-test.md](output-control-test.md).
- Use a multi-stage build to drop the build tools from the runtime image.
- Harden: the container runs `usbhid-ups` and `upsd` as root.

## References

[NUT PR #3780](https://github.com/networkupstools/nut/pull/3780) · [issue #3779](https://github.com/networkupstools/nut/issues/3779) · [Network UPS Tools](https://github.com/networkupstools/nut)
