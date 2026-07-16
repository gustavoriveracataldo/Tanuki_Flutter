# Publicar una nueva version

Este proyecto genera releases con GitHub Actions desde `.github/workflows/release.yml`.
El workflow se ejecuta al subir un tag `v*` o manualmente desde `workflow_dispatch`.

## 1. Preparar el cambio

1. Verifica que el arbol tenga solo los cambios que quieres publicar:

   ```sh
   git status --short
   ```

2. Sube la version en `pubspec.yaml`.

   Ejemplo:

   ```yaml
   version: 1.4.0+14
   ```

   El nombre del release usa la parte antes de `+`, por ejemplo `v1.4.0`.

3. Corre las validaciones locales que apliquen:

   ```sh
   sh scripts/flutter_with_secrets.sh analyze
   sh scripts/flutter_with_secrets.sh test
   sh scripts/flutter_with_secrets.sh build apk --debug
   sh scripts/flutter_with_secrets.sh build linux --debug
   ```

   Para probar el empaquetado release local en Linux/Android:

   ```sh
   sh scripts/build_release.sh
   ```

   Esto genera:

   ```text
   dist/tanuki-android-release.apk
   dist/tanuki-linux-x64-release.tar.gz
   ```

   Windows se empaqueta en Windows con:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\build_release_windows.ps1
   ```

## 2. Commit y push

1. Crea el commit:

   ```sh
   git add .
   git commit -m "Release v1.4.0"
   git push
   ```

2. Crea y sube el tag. El tag debe coincidir con la version visible del
   `pubspec.yaml`:

   ```sh
   git tag v1.4.0
   git push origin v1.4.0
   ```

Al subir el tag, GitHub Actions ejecuta el workflow `Release`.

## 3. Revisar GitHub Actions

En GitHub, abre `Actions` y entra al workflow `Release`.

El workflow hace:

1. `validate-secrets`: valida secretos obligatorios.
2. `Analyze and test`: corre `flutter analyze` y `flutter test`.
3. `Android APK`: corre `scripts/build_android.sh` y sube el APK.
4. `Linux x64`: instala dependencias Linux, corre `scripts/build_linux.sh` y sube el `.tar.gz`.
5. `Windows x64`: corre `scripts\build_release_windows.ps1` y sube el `.zip`.
6. `GitHub Release`: descarga los artefactos y crea el release.

Los secretos requeridos son:

```text
TMDB_API_KEY o TMDB_BEARER_TOKEN
FANART_API_KEY
MYANIMELIST_CLIENT_ID
SIMKL_CLIENT_ID
```

`MYANIMELIST_CLIENT_SECRET` se pasa si existe, pero no bloquea el workflow.

## 4. Ejecutar el release manualmente

Tambien puedes correr el workflow sin tag:

1. GitHub -> `Actions`.
2. Selecciona `Release`.
3. Presiona `Run workflow`.
4. Deja `Run flutter analyze and flutter test before building` activado si no
   validaste localmente. Puedes desactivarlo para ahorrar minutos despues de
   correr `analyze` y `test` en tu maquina.
5. El workflow usara la version de `pubspec.yaml` para nombrar el release.

Si el release manual crea `v1.4.0`, evita crear despues el mismo tag apuntando a
otro commit. En ese caso sube una nueva version, por ejemplo `1.4.1+15`.

## 5. Comprobar artefactos

Al terminar, el release debe incluir:

```text
tanuki-android-vX.Y.Z.apk
tanuki-linux-x64-vX.Y.Z.tar.gz
tanuki-windows-x64-vX.Y.Z.zip
```

Descarga al menos Linux o Android y verifica que la app abre, carga metadata y
puede reproducir una serie.
