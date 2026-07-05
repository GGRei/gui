# Windows Setup And Validation

Windows native support is under active validation. This page documents the
current setup path and failure triage; it is not a final README-level support
claim.

## Supported Path Under Validation

Use native Windows, not WSL, as the validation target.

- Windows 10 or 11.
- MSVC from Visual Studio Build Tools or Visual Studio with the Desktop C++
  workload and Windows SDK.
- `vcpkg` packages for `pango` and `freetype`.
- The V module dependency `vglyph`.

The current CI/smoke path uses MSVC first. Clang and MinGW/MSYS2 remain
exploratory until smoke evidence proves that normal users do not need manual
PATH edits, copied DLLs, or non-default package paths.

## Install Checklist

Run commands from a native x64 Developer PowerShell or x64 Native Tools shell so
`cl.exe`, `link.exe`, the Windows SDK and `vcpkg` are visible to the same
process that runs `v`.

```powershell
v version
vcpkg install pango freetype
v install vglyph
```

Then run the non-interactive native checks:

```powershell
v run _windows_preflight.vsh
```

This preflight is safe to run before building GUI examples. It checks that the
command is running on native Windows, that the selected compiler is visible,
that `vglyph` can be imported, and that a minimal text-stack probe can be built.
For the supported MSVC path it also checks that `vcpkg` is visible and that
`pango` and `freetype` packages are installed. It writes only temporary probe
files under the system temp directory and removes them before exit.

```powershell
v -no-parallel -cc msvc test `
  _native_dialog_test.v `
  _native_print_test.v `
  _native_notification_test.v `
  nativebridge/_bridge_ex_test.v `
  nativebridge/_readback_abi_test.v
```

Compile the focused examples before running any manual UI smoke:

```powershell
v -no-parallel -cc msvc -W -o dialogs_smoke.exe examples/dialogs.v
v -no-parallel -cc msvc -W -o printing_smoke.exe examples/printing.v
v -no-parallel -cc msvc -W -o notification_smoke.exe examples/native_notification.v
```

The manual UI matrix lives in
[`WINDOWS_MANUAL_SMOKE.md`](WINDOWS_MANUAL_SMOKE.md).

## D3D11 Opt-In

Windows still uses the upstream/default sokol OpenGL backend unless the
selected V/sokol toolchain implements and receives the explicit D3D11 flag:

```powershell
v -no-parallel -cc msvc -d sokol_d3d11 -W -o printing_d3d11_smoke.exe examples/printing.v
```

Use this only with a V build that contains the sokol D3D11 backend work. The
flag is not a v-gui public API and does not change the default Windows backend.

### Readback And Raster Export

`export_print_job` keeps the same public API on every backend. When sokol is
initialized it uses GPU raster export; in non-GPU test paths it still falls back
to the vector PDF renderer.

Backend support during Windows validation:

- Windows D3D11 with `-d sokol_d3d11`: raster export uses the D3D11 readback
  bridge.
- Windows default OpenGL: raster export does not route through D3D11. It returns
  a structured unsupported-render error until a Windows OpenGL readback path is
  implemented and validated.
- Non-Windows OpenGL and Metal keep their existing readback paths.

The D3D11 bridge is deliberately narrow: it reads single-sample BGRA8 render
targets through a staging texture and copies rows with the D3D11 `RowPitch`.
Unsupported formats, MSAA render targets, invalid dimensions or missing native
handles fail instead of returning fabricated pixels.

### Shader Boundary

v-gui runtime custom shaders are currently Metal/OpenGL source bodies only. The
`glsl` body is not a D3D11 shader source. D3D11-specific custom rendering should
use generated sokol shader descriptors with D3D11/HLSL output, and generated
shader files must be refreshed together with their source shader changes.

## Dependency Preflight

Most Windows setup failures happen before native dialog or print callbacks can
return a structured GUI result. Treat these as build/setup preflight failures:

- `module vglyph not found`: run `v install vglyph`.
- `pango/pango.h` or `ft2build.h` missing: install the C headers with
  `vcpkg install pango freetype` in the same native Windows environment used
  for `v`.
- unresolved `pango_*`, `FT_*`, HarfBuzz, FriBidi or Fontconfig symbols: keep
  one toolchain at a time. For the supported path, use MSVC plus matching
  `x64-windows` vcpkg packages.
- missing Pango/Freetype/HarfBuzz/FriBidi/Fontconfig DLL on smoke executable
  startup: record it as a Windows setup blocker. Do not treat random DLL
  copying or global PATH edits as the final user setup path.
- WSL or Wine passes while native Windows fails: validate again on native
  Windows. Prefilters are not gates.

When reporting a setup failure, include:

- `v version`
- compiler path (`where cl` or `where gcc`)
- `_windows_preflight.vsh` output
- `vcpkg list`
- the exact `v` command
- the first missing header, library, symbol or DLL

## Feature Contract During Validation

- Windows dialogs use native Win32 Common Item Dialog COM APIs for file/folder
  pickers and Win32 message boxes for message/confirm dialogs.
- Windows printing delegates PDFs through the native `ShellExecute` `print`
  verb. It is native PDF-handler delegation, not full printer-option parity.
- Windows notifications currently use `Shell_NotifyIconW` balloons. Toast or
  AppNotification parity is not claimed yet.
- D3D11 readback/export has bridge coverage, but runtime evidence must come
  from native Windows smoke/manual validation.
- Accessibility on Windows is not screen-reader parity yet. The current backend
  is a safe stub until a UI Automation provider is implemented.

## Windows Notification And Accessibility Guardrails

Windows notifications currently mean notification-area balloon delivery through
[`Shell_NotifyIconW`](https://learn.microsoft.com/windows/win32/api/shellapi/nf-shellapi-shell_notifyiconw)
and `NOTIFYICONDATAW`. This is the supported native fallback during validation;
it is not Windows App SDK Toast/AppNotification parity.

Do not treat Toast/AppNotification as implemented until a separate Windows App
SDK design exists for `AppNotificationManager`, runtime/bootstrap requirements,
AppUserModelID or COM registration, packaged/unpackaged behavior, and smoke
evidence on native Windows.

Windows accessibility is also deliberately limited. The current backend does
not implement a server-side UI Automation provider, does not handle
`WM_GETOBJECT` for `UiaReturnRawElementProvider`, and does not expose an
`IRawElementProviderSimple` tree. Do not claim Narrator, Accessibility Insights,
or screen-reader parity until that provider exists and has manual Windows
evidence.

## Prefilters That Are Not Gates

WSL and Wine can catch simple compile/startup mistakes, but they cannot prove
MSVC ABI behavior, COM dialogs, Shell notifications, D3D11 readback, native PDF
handler printing, or normal user setup. Passing a prefilter is useful; failing a
native Windows smoke remains authoritative.
