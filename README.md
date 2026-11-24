# UGREEN US2000 on Synology DSM 7.4.1 using NUT in Docker

**Tested on real hardware on November 24, 2026.** This guide documents connecting a UGREEN US2000 DC UPS (USB VID:PID `2b89:ffff`) to the **Hardware & Power → UPS** panel in Synology DSM, despite DSM's built-in `usbhid-ups` driver not recognizing it.

The verified setup was:

| Component | Tested version / model |
|---|---|
| NAS | UGREEN NASync DXP2800, Intel N100 |
| NAS operating system | Synology DSM 7.4.1-90080 Update 2 through Arc Loader 4.2.3 |
| Container Manager / Docker Engine | 24.0.2 |
| Docker Compose | v2.20.1 |
| UPS | UGREEN US2000 DC200, USB VID `2b89`, PID `ffff` |
| NUT | `2.8.5.1-0+g88948fb` (development build) |
| NUT HID driver / USB library | Generic HID driver 0.74 / libusb 1.0 |
| Device-specific subdriver | UGREEN HID 0.05 |

> **Important limitations:** The UGREEN HID 0.05 subdriver is experimental, from [networkupstools/nut PR #3780](https://github.com/networkupstools/nut/pull/3780). In our test, DSM initiated UPS Safe Mode, but **did not resume normal operation automatically when mains power returned**. A short physical power-button press shut down the NAS, and it then had to be powered on manually. This is **not yet an unattended power-recovery solution**. Back up critical data before testing.
>
> **Reproducibility note:** The included Dockerfile was written from a successful manual build and pins the source commit, but **a complete clean build of the Dockerfile has not yet been independently tested**.

## 1. What was actually verified

| Test | Observed result |
|---|---|
| USB detection | `UGREEN US2000 DC200`, `2b89:ffff` |
| Dedicated driver | `Using subdriver: UGREEN HID 0.05` |
| Telemetry | Battery charge rose from 44% to 45%, 48%, 50%, then 52%; voltage, current, temperature and load values also changed |
| Power transition | `OL → OB → OL` when the US2000 input adapter was disconnected and reconnected |
| DSM network UPS | DSM displayed `UGREEN / US2000 / Connected` |
| Safe Mode timer | `UPS on battery` at 14:53:26; `UPS wait time up` and safe-shutdown initiation at 14:54:27, approximately 60 seconds later |
| Boot after manual shutdown | Docker/NUT started automatically; DSM `upsmon` reconnected five seconds after an initial connection failure |
| Automatic exit from Safe Mode | **Not observed** |

The logs confirm **initiation of safe shutdown**, including a message that DSM would unmount volumes. They do **not independently prove that every volume was successfully unmounted**.

## 2. Why the built-in DSM driver does not work

The stock Synology `usbhid-ups` (Generic HID 0.47, using libusb 0.1) sees `2b89:ffff` through `lsusb` but fails with:

```text
No matching HID UPS found
```

Its `explore` mode found 104 HID objects but did not properly process the US2000's unusual HID telemetry reports (including report `0x71`). The dedicated `ugreen-hid.c` subdriver addresses this protocol. See [PR #3780](https://github.com/networkupstools/nut/pull/3780) and [issue #3779](https://github.com/networkupstools/nut/issues/3779).

The reported `battery.runtime: 65535` should be considered **invalid/unknown**, not an actual runtime in seconds. Do not base shutdown policy on it. Reliable hardware generation of an NUT `LB` (low battery) event was not established in our test; DSM Safe Mode was instead triggered by its **Customize time** setting.

## 3. Requirements

- A DXP2800 running DSM with Container Manager, or another compatible x86_64 DSM device with USB passthrough.
- US2000 powering the NAS, with its USB data cable also connected.
- SSH access to DSM with administrator / `sudo` permissions.
- Internet access to download and build NUT, plus adequate disk space (our build-tools image was approximately 734 MB).
- A separate backup of important data, sufficient UPS charge, and physical access to the NAS power button for recovery tests.

## 4. Install the included Docker project

Put this repository on the NAS in `/volume1/docker/nut-us2000`. Native DSM has no `git` command, so download the repository archive on the NAS itself, or copy a clone from your workstation with File Station:

```bash
sudo mkdir -p /volume1/docker/nut-us2000
cd /volume1/docker/nut-us2000
sudo curl -fsSL https://github.com/crystalidea/ugreen-us2000-synology/archive/refs/heads/main.tar.gz | sudo tar xz --strip-components=1
```

The project contains:

```text
Dockerfile
compose.yaml
start.sh
config/ups.conf
config/upsd.conf
config/upsd.users
```

**Check networking before deployment.** Our particular NAS used Docker subnet `172.18.0.0/16` and gateway `172.18.0.1`. They are **not universal defaults**: verify that the subnet does not overlap another Docker network or the LAN. If `nut-us2000_default` already exists, inspect its settings before applying Compose. Do not run `docker compose down` on an actively used UPS-monitoring deployment without a recovery plan.

On the NAS:

```bash
cd /volume1/docker/nut-us2000
sudo chmod 600 config/upsd.users
sudo /var/packages/ContainerManager/target/usr/bin/docker compose config
sudo /var/packages/ContainerManager/target/usr/bin/docker compose up -d --build
sudo /var/packages/ContainerManager/target/usr/bin/docker compose ps
sudo /var/packages/ContainerManager/target/usr/bin/docker logs --tail 50 nut-us2000
```

Expected log entries include:

```text
Using subdriver: UGREEN HID 0.05
Listening on socket /var/state/ups/usbhid-ups-ups
Connected to UPS [ups]: usbhid-ups-ups
```

**Build caveat:** The Dockerfile pins the full source commit `88948fb8c0ab5e2cfa92e6f832b613e0a2094f56`, the revision underlying the manually verified build, and fetches that commit by SHA instead of checking out a branch. PR #3780 is still open, so its branch can be rebased or force-pushed at any time; a branch or short-ref checkout would quietly build something else. The supplied Dockerfile has **not yet completed an independent clean-build verification**. If the build reports missing dependencies, modify the isolated container build rather than replacing DSM's system NUT binaries.

## 5. Verify NUT inside Docker and from DSM

The following commands query the UPS without modifying its settings:

```bash
sudo /var/packages/ContainerManager/target/usr/bin/docker exec nut-us2000 /opt/nut-install/bin/upsc ups@127.0.0.1
/usr/bin/upsc ups@172.18.0.1 ups.status
```

With mains power connected, the expected UPS status is `OL`. A short, carefully controlled interruption to **only the US2000 input adapter** should produce `OB`, then `OL` again when restored. Do not disconnect the US2000 output feeding the NAS.

Our test confirmed both transitions. DSM also recorded `UPS on battery` and `UPS back online, not in safe mode`.

## 6. Configure the DSM UPS client

In DSM, open **Control Panel → Hardware & Power → UPS**:

1. Enable **UPS support**.
2. Choose **Synology UPS server** as the UPS type.
3. Enter the Docker bridge gateway as the **Network UPS server IP**. In the tested setup it was `172.18.0.1`.
4. Select **Customize time**. For a controlled test we used **1 minute**; select a production value based on measured runtime, service shutdown requirements, and a safety margin.
5. Click **Apply**, then confirm DSM shows **UGREEN / US2000 / Connected**.

The container's NUT configuration uses a device section called `[ups]` and the monitoring account `monuser` / `secret` with `upsmon secondary` permissions. **DSM chooses that pair itself:** with the UPS type set to *Synology UPS server* it writes its own `/etc/ups/upsmon.conf` containing `MONITOR ups@<ip> 1 monuser secret slave`, and its UPS panel offers no field for a user name or password. The container therefore has to present exactly these values, and the password cannot be strengthened. What limits the exposure instead is that the account holds only `upsmon secondary` rights, which cannot force a shutdown of NUT clients, and that reading values with `upsc` needs no account at all. Network isolation is the real control: never expose port 3493 to the internet. The tested Compose setup binds it only to the internal Docker bridge gateway, though access from other containers on that bridge should still be evaluated and restricted as appropriate.

**Why not `127.0.0.1` in DSM?** The command-line utility `/usr/bin/upsc ups@127.0.0.1` worked with a loopback-bound Docker port, but the DSM 7.4.1 web interface rejected the loopback address as invalid. Binding the port to the explicitly configured Docker gateway `172.18.0.1` solved the issue without depending on the NAS's LAN address.

To inspect the current gateway:

```bash
sudo /var/packages/ContainerManager/target/usr/bin/docker network inspect nut-us2000_default --format '{{json .IPAM.Config}}'
```

Our network returned:

```json
[{"Subnet":"172.18.0.0/16","Gateway":"172.18.0.1"}]
```

## 7. Verify UPS events and Safe Mode

Check that the DSM monitoring process is running:

```bash
ps aux | grep '[u]psmon'
sudo grep -i -E 'upsmon|ups@172.18.0.1|upsmsg|synopoweroff' /var/log/messages | tail -50
```

For a controlled Safe Mode test, first back up important data, stop active writes, ensure sufficient UPS charge and have physical access to the NAS. HDMI output was unavailable in our DXP2800 test, so we observed DSM and SSH remotely.

The following events were recorded during the one-minute test:

```text
14:53:26 UPS on battery.
14:54:27 UPS wait time up
14:54:27 [UPS] Server is going to Safe Mode. It will stop all services and umount all volumes.
14:54:27 synopoweroff: System is going to [safe shutdown]
```

Afterwards, SSH (port 22) and DSM (port 5000) became inaccessible; ping continued to work and fans kept spinning. Restoring input power **did not automatically restore DSM services**. A brief press of the NAS's physical power button resulted in shutdown after about ten seconds. We then powered the NAS on manually.

After boot, the Docker container restarted. The DSM client initially attempted to connect before the NUT server was ready, then automatically reconnected:

```text
15:02:14 UPS [ups@172.18.0.1]: connect failed: Connection failure: Connection refused
15:02:19 UPS [ups@172.18.0.1] connected
```

**Architecture limitation:** The NUT server runs in Docker **on the same NAS** that uses it as an external UPS server. Entering Safe Mode stops Docker, so DSM may no longer receive a later return-to-mains event. This recovery limitation remains unresolved. Truly unattended recovery may require an independent NUT server or a separately validated shutdown/power-restoration architecture.

## 8. Troubleshooting

| Symptom | Cause / action |
|---|---|
| `No matching HID UPS found` | Stock Synology HID driver does not support the US2000 protocol; use the dedicated `ugreen-hid` subdriver. |
| `'subdriver' is not a valid variable` | Synology's bundled driver does not accept this option. |
| `Can't open .../ups.conf` | Supply the NUT configuration in `/opt/nut-install/etc/nut/ups.conf`. |
| `Can't chdir to /var/state/ups` | Create `/var/state/ups` before starting the driver. |
| `upsd.users: No such file` | Create `config/upsd.users`, restrict permissions to `600`. |
| `nano: command not found` | Minimal Debian image; use a shell heredoc or install an editor. |
| `Connection refused` immediately after reboot | DSM `upsmon` can start before Docker NUT; ours reconnected automatically after five seconds. |
| Container exits with `UPS data unavailable` | The driver or `upsd` stopped answering. `start.sh` exits on purpose so the restart policy rebuilds both; if it repeats, check `docker logs` and USB passthrough. |
| DSM GUI rejects `127.0.0.1` | Use the explicitly configured internal Docker bridge gateway instead. |
| `battery.runtime: 65535` | Unknown/invalid runtime value; do not trust it. |
| HDMI has no signal | Our DXP2800 did not display video after DSM boot; manage the system through DSM and SSH. |

## 9. Remaining work

- Verify `docker compose up -d --build` from a clean checkout on another NAS.
- Independently verify that all storage volumes actually finish unmounting during Safe Mode.
- Resolve automatic exit from Safe Mode and unattended restoration after power returns.
- Reduce final image size using a multi-stage Docker build (exclude build tools from the runtime image).
- Review minimal USB permissions, service user privileges, network access and NUT credentials.
- When a stable NUT release incorporates US2000 support, compare it with the experimental commit `88948fb8c0ab5e2cfa92e6f832b613e0a2094f56` before upgrading.

## References

- [UGREEN US2000 subdriver, NUT PR #3780](https://github.com/networkupstools/nut/pull/3780)
- [UGREEN US2000 issue #3779](https://github.com/networkupstools/nut/issues/3779)
- [Network UPS Tools upstream](https://github.com/networkupstools/nut)

All observed results and log excerpts above come from hands-on tests on the UGREEN DXP2800 on November 24, 2026, rather than an assumption of official vendor support.
