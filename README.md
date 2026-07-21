# NO GUARANTEES! 

Only very minimal testing has been done.

I have verified that e.g. standalone *NeuralDSP Archtype: John Mayer X* works with Wine 11, under Ubuntu Studio 26.04, using workarounds introduced in this script. 

Also the VST plugin is tested working with **Carla** when using still unofficial build of [yabridge](https://github.com/robbert-vdh/yabridge). Currently latest yabridge *release* is 5.1.1 and it does **NOT** work, but the latest `master` **build** seems to work and newest builds can be found from [here](https://github.com/robbert-vdh/yabridge/actions?query=branch%3Amaster). I tested with [this particular build](https://github.com/robbert-vdh/yabridge/actions/runs/25067934796). **Ardour**, **REAPER** and other DAWs I haven't tested yet. 

# PACE License Support 6.0.0 on Wine 11

Unofficial installer workaround for PACE License Support / iLok License Manager 6.0.0 under Wine 11.x. PACE is required by some Windows audio software, including Neural DSP amp sims.

The unmodified installer can fail with generic MSI error `0x80070643` / `1603` because Wine is incorrectly rejected by two installer checks:

1. The PACE custom action reports OS major version `6`, so the Windows 10 launch condition fails.
2. WiX tries to configure service-recovery settings through APIs not implemented by Wine.

The scripts extract the internal MSI, patch those two checks, install the required Visual C++ runtime, install the patched MSI, and verify the PACE service.

This is intentionally done for very specific [scope](#scope), as I'm hoping for better fixes to emerge (e.g. new version of the License Manager with better working installer). And I'm also worried that even small version changes can cause unexpected issues as the script relies on specific installer component GUID.

### Suggested process with NeuralDSP plugins

1. Install the NeuralDSP plugin, but do not run it.
2. Install the PACE License Support using this guide
3. Apply `winetricks dxvk` patch. This fixes the unresponsive GUI.
4. Launch you NeuralDSP plugin. It should **not** try to install license components anymore, but it should go straight to activation.



## Scope

- PACE License Support base version: **6.0.0**
- Wine: **11.x**
- Default Wine prefix: `~/.wine`
- The exact PACE build number is detected automatically.

This is not an official PACE, iLok, Wine, or Neural DSP solution. Modifying the MSI invalidates its original digital signature.

## STEP 1 - Requirements

Required commands:

- `git`
- `wine` 11.x
- `winetricks` with the `vcrun2022` verb
- `msiinfo` and `msibuild` from `msitools`
- `unzip`

### On Ubuntu (Studio) 26.04:

```sh
sudo apt install git msitools unzip
```

Unfortunately Ubuntu 26.04 comes with Wine 10, so Wine 11 must be obtained from [WineHQ](https://gitlab.winehq.org/wine/wine/-/wikis/Debian-Ubuntu).
1. Download and add the repository key, e.g.:
   ```
   sudo mkdir -pm755 /etc/apt/keyrings
   wget -O - https://dl.winehq.org/wine-builds/winehq.key | sudo gpg --dearmor -o /etc/apt/keyrings/winehq-archive.key -
   ```

3.  Add the sources file, e.g. (Ubuntu 26.04 !!):
   ```
   sudo wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/resolute/winehq-resolute.sources
   ```
4. Update and install:
   ```
   sudo apt update
   sudo apt install wine-stable winetricks
   ```
   
Then verify Wine:

```sh
wine --version
```

The output **must** report Wine 11.x.



## STEP 2 - Download PACE License Support

Download the **Windows License Support Installer** ZIP from:

- https://www.ilok.com/
- https://help.ilok.com/ilm_setup.html

Extract it:

```sh
unzip LicenseSupportInstallerWin.zip
```

The extracted directory should contain `LicenseSupport.exe`.

## STEP 3 - Installation

### STEP 3.1 - Obtain and launch install script from this repo
**!!! NOTE !!!** Adjust the path to **LicenseSupport.exe** to match where you extracted the zip in STEP 2. 

```sh
git clone https://github.com/sirsipe/ilok-pace-license-support-wine11-scripts

cd ilok-pace-license-support-wine11-scripts

./install.sh \
~/Downloads/LicenseSupportInstallerWin/LicenseSupport.exe # ADJUST THE PATH!
```

#### Targeting specific wine prefix (FOR ADVANCED USERS ONLY)

```sh
WINEPREFIX="$HOME/.wine-ilok" ./install.sh LicenseSupport.exe
```

### STEP 3.2 - Navigate through the PACE License Support Installer

--> **!!! The first installer run IS EXPECTED TO FAIL !!!** <---

Follow it to the end and close it when prompted.

*This step captures the internal .msi installer package, which is then automatically modified to accept Wine 11, and executed again.*

### STEP 3.3 - Navigate through the PACE License Support Installer AGAIN

This time you are installing with the modified installer. Follow it to the end. This time it should succeed.

### STEP 4 - Validate

Simply look at the terminal output. You should see something like:
```text
Verification
  MSI installation:      PASS
  Service registered:    PASS
  Service running:       PASS
  Service registry keys: PASS
  LDSvc.exe process:     PASS
  MSI log:               /home/...

PACE License Support installed successfully.
```


## Manual installation for Advanced Troubleshooting

This is basically what the scripts does:

1. Installs the Visual C++ runtime:

```sh
winetricks -q --force vcrun2022
```

2. Extracts the internal MSI while user navigates the installer:

```sh
./extract-license-support-msi.sh <path-to>/LicenseSupport.exe
```

The MSI will be placed in the same `<path-to>/LicenseSupport.msi`

3. Patches the MSI. `/dev/shm` avoids needing temporary disk space for another full MSI copy:

```sh
TMPDIR=/dev/shm ./patch-license-support-msi.sh <path-to>/LicenseSupport.msi
```

4. Installs the patched MSI:

```sh
wine msiexec /i \
  <path-to>/LicenseSupport-patched.msi \
  BURNMSIINSTALL=1 \
  /L*v <path-to>/LicenseSupport-patched-install.log
```

5. Verifies the service. You can just check if LDScv.exe is running. If it is, it should be fine.

```sh
wine sc query PACELicenseDServices

wine reg query \
  'HKLM\System\CurrentControlSet\Services\PACELicenseDServices' \
  /s

wine tasklist | grep -i LDSvc || echo "LDSvc.exe is not running"
```

## Applied MSI patches

Windows compatibility condition:

```text
Installed Or (VersionNT64 >= 603 and COMPATIBLE_OS_VERSION="True")
```

becomes:

```text
Installed Or 1
```

WiX service-recovery configuration action:

```text
Wix4SchedServiceConfig_X86
```

is disabled by setting its execute-sequence condition to:

```text
0
```

## References

- iLok setup: https://help.ilok.com/ilm_setup.html
- Wine 11.0 release: https://www.winehq.org/news/2026011301
- WineHQ Debian/Ubuntu packages: https://gitlab.winehq.org/wine/wine/-/wikis/Debian-Ubuntu
- Winetricks `vcrun2022`: https://github.com/Winetricks/winetricks/blob/master/files/verbs/all.txt
