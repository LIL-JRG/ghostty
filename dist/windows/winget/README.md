# Publicar Ghostty (port de Windows) en winget

Los manifiestos de este directorio están listos salvo dos campos que
requieren una release pública:

1. Construye el instalador:

   ```sh
   ./dist/windows/package.sh 1.3.2
   ISCC.exe dist\windows\ghostty.iss   # produce zig-out/dist/ghostty-1.3.2-windows-x86_64-setup.exe
   ```

2. Sube `ghostty-1.3.2-windows-x86_64-setup.exe` a un lugar público y
   estable (típicamente GitHub Releases de tu fork).

3. Calcula el hash y completa `Ghostty.Ghostty.installer.yaml`:

   ```powershell
   Get-FileHash zig-out\dist\ghostty-1.3.2-windows-x86_64-setup.exe -Algorithm SHA256
   ```

   Rellena `InstallerUrl` y `InstallerSha256`.

4. Decide el `PackageIdentifier` definitivo. `Ghostty.Ghostty` puede
   estar reservado para el proyecto oficial; para un port no oficial
   usa algo como `JorgeRasgado.GhosttyWindows` (cámbialo en los TRES
   manifiestos y en los nombres de archivo).

5. Valida localmente y envía el PR a microsoft/winget-pkgs:

   ```powershell
   winget validate dist\windows\winget\
   # Estructura del PR: manifests/<letra>/<Publisher>/<Package>/<version>/*.yaml
   ```

   La herramienta `wingetcreate` (`winget install wingetcreate`) puede
   automatizar el PR: `wingetcreate submit dist\windows\winget\`.
