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

## Automated submission (after the listing is live)

The `.github/workflows/store-publish.yml` workflow uses the
[`msstore` CLI](https://learn.microsoft.com/en-us/windows/apps/publish/msstore-dev-cli/overview)
to push a new MSIX to the Store on every published GitHub release (also runs
manually via *workflow_dispatch*). Microsoft's docs require two preconditions
before automated submission works:

- the app must already be **published and live** in the Store (the first
  submission must clear certification manually), and
- the product must be **free** (paid products aren't yet supported).

### One-time setup

1. **Register a Microsoft Entra ID (Azure AD) app** —
   <https://entra.microsoft.com/> → *App registrations* → *New registration*.
2. **Associate that app with Partner Center** — Partner Center →
   *Account settings* → *User management* → *Microsoft Entra applications* →
   *Add Microsoft Entra application* → select the registered app → assign the
   **Manager** role.
3. **Create a client secret** for the app registration — Entra → *Certificates
   & secrets* → *New client secret*. Copy the **value** immediately (it's
   only shown once).
4. **Collect the four values**:
   - **Tenant ID** — Entra → *Overview* → *Tenant ID*
   - **Client ID** — Entra → *App registrations* → your app → *Application
     (client) ID*
   - **Client secret** — the value from step 3
   - **Seller ID** — Partner Center → *Account settings* → *Identifiers*
5. **Get the Store product ID** — Partner Center → your app →
   *Product identity* (a 12-character ID like `9ABCDE1FGH2I`).
6. **Add the GitHub repository secrets** (Settings → *Secrets and variables* →
   *Actions* → *Secrets*):
   - `AZURE_AD_TENANT_ID`
   - `AZURE_AD_APPLICATION_CLIENT_ID`
   - `AZURE_AD_APPLICATION_SECRET`
   - `SELLER_ID`
7. **Add the Store product ID as a repo variable** (Settings → *Secrets and
   variables* → *Actions* → *Variables*):
   - `MSSTORE_PRODUCT_ID`

(The existing `MSIX_IDENTITY_NAME` / `MSIX_PUBLISHER` /
`MSIX_PUBLISHER_DISPLAY_NAME` variables are reused — they stamp the package
identity at build time and are public values, so they stay as variables.)

### How it runs

- **Auto:** GitHub release published → workflow downloads
  `nvg-windows-amd64.exe` from that release, packs the MSIX with the Store
  identity, configures `msstore`, and runs `msstore publish <path> -id $PRODUCT_ID`.
- **Manual:** Actions → *Publish to Microsoft Store* → *Run workflow*; pass an
  explicit tag input or let it default to the latest release.

Microsoft Learn references:
[Publish app updates to Microsoft Store with GitHub Actions](https://learn.microsoft.com/en-us/windows/apps/publish/msstore-dev-cli/github-actions),
[msstore CLI commands](https://learn.microsoft.com/en-us/windows/apps/publish/msstore-dev-cli/commands).

## Notes

- Replace the placeholder logos in `Assets/` with real artwork before the
  public listing (keep the same filenames/sizes).
- The 4th part of the version is reserved by the Store and must stay `0`;
  `build-msix.ps1` derives `X.Y.Z.0` from `build.zig.zon`.
