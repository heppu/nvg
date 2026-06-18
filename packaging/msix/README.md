# nvg — MSIX packaging (Microsoft Store)

Packages `nvg.exe` as an MSIX for the **Microsoft Store**. The Store route is
chosen deliberately:

- **Free signing.** You submit an unsigned MSIX; Microsoft re-signs it during
  certification. No code-signing certificate, HSM, or USB token required.
- **No SmartScreen.** Store-installed apps are trusted — users never see a
  SmartScreen prompt (unlike a freshly issued OV/EV-signed `.exe`).
- **winget too.** A Store listing is installable via winget's Store backend:
  `winget install nvg -s msstore`.

`nvg` ships as a **packaged Win32 app** (`runFullTrust`) with a
**command-line execution alias**, so after install `nvg` is on `PATH` and a
tiling WM can launch it (e.g. GlazeWM `shell-exec nvg left`).

## Files

| File | Purpose |
|------|---------|
| `AppxManifest.xml` | Manifest **template** (`__TOKENS__` filled at build time) |
| `build-msix.ps1` | Stage layout + run `makeappx` → `.msix` (optional self-signed sign) |
| `generate-assets.ps1` | Regenerate placeholder logos in `Assets/` |
| `Assets/` | Store/tile logos (placeholders — replace with real artwork) |

## Build locally

```powershell
# Build the GUI-subsystem release exe first
zig build -Doptimize=ReleaseSafe

# Pack an (unsigned) MSIX — Store-style
pwsh packaging/msix/build-msix.ps1 -ExePath zig-out/bin/nvg.exe -OutFile packaging/msix/out/nvg.msix
```

## Test locally (no certificate needed)

With **Developer Mode** enabled, register the staged layout and launch by name:

```powershell
Add-AppxPackage -Register packaging/msix/layout/AppxManifest.xml
nvg left                      # resolves via the execution alias on PATH
Get-AppxPackage *nvg*         # confirm it's installed
Remove-AppxPackage (Get-AppxPackage *nvg*).PackageFullName   # clean up
```

(`build-msix.ps1 -Sign` instead produces a self-signed `.msix` you can
double-click-install, if the self-signed cert is trusted on the machine.)

## Publish to the Store (one-time setup — requires a human)

1. Create a **Partner Center** account and **reserve the app name** (e.g. `nvg`).
   <https://partner.microsoft.com/dashboard>
2. Read the reserved **Product identity** (Partner Center → your app →
   *Product management* → *Product identity*): `Package/Identity/Name`,
   `Package/Identity/Publisher`, and `Publisher display name`.
3. Set these as repo **variables** so CI stamps the package correctly:
   - `MSIX_IDENTITY_NAME`
   - `MSIX_PUBLISHER`
   - `MSIX_PUBLISHER_DISPLAY_NAME`
4. Build the `.msix` (CI artifact `nvg-msix`, or locally with the values above)
   and upload it to the app's **Packages** in a Store submission. Fill in the
   listing (description, screenshots) and submit. Microsoft signs + certifies.

## Notes

- Replace the placeholder logos in `Assets/` with real artwork before the
  public listing (keep the same filenames/sizes).
- The 4th part of the version is reserved by the Store and must stay `0`;
  `build-msix.ps1` derives `X.Y.Z.0` from `build.zig.zon`.
