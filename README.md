# BLUE COMPANY Enterprise 9.1

Panel Bash de administración SSH / WS / UDP. Esta versión actualiza el código existente de BLUE COMPANY Enterprise; no es una reconstrucción desde cero.

## Archivos del repositorio

Publicar estos tres archivos en la raíz de la rama `main`:

- `BLUECOMPANY.sh`: script completo del panel.
- `VERSION`: contiene únicamente `9.1`.
- `README.md`: documentación del proyecto.

Repositorio: https://github.com/david-bluecompany/blue-company

## Instalación / actualización manual

En Ubuntu, descarga el script y ejecútalo como administrador:

```bash
sudo install -o root -g root -m 0755 BLUECOMPANY.sh /usr/local/bin/adm-ssh
sudo ln -sfn /usr/local/bin/adm-ssh /usr/local/bin/blue
sudo bash -n /usr/local/bin/adm-ssh
```

Inicia el panel con:

```bash
sudo adm-ssh
# o
sudo blue
```

## Inicio automático por SSH

Al inicializarse por primera vez, el script instala `/etc/profile.d/bluecompany-panel.sh` para el usuario administrativo que ejecutó el instalador mediante `sudo` (o `root` si se ejecutó directamente como root).

El lanzador requiere una sesión SSH interactiva con terminal y no se activa para comandos remotos no interactivos, SCP o SFTP. Para usuarios no root utiliza el `sudo` que ya tenga configurado; no crea reglas sudoers ni concede permisos nuevos. Si sudo requiere contraseña, puede solicitarla al iniciar el panel.

Para cambiar el usuario autorizado, edita el archivo `/etc/profile.d/bluecompany-panel.sh` como root y cambia el nombre de usuario en la condición `id -un`.

## Seguridad y compatibilidad

- La opción 11 es un centro de seguridad/estado de solo consulta.
- El centro muestra estado de OpenSSH, Fail2ban, Xray, 3X-UI, firewall, puertos, recursos, permisos y registros disponibles.
- El centro no bloquea direcciones IP ni modifica reglas del firewall.
- Anti-Torrent se conserva como opción independiente.
- Fail2ban y la configuración independiente de OpenSSH no se desinstalan ni se reconfiguran por el centro informativo.
- El código del panel no incluye módulo Anti-BruteForce, listas negras/blancas de IP ni acciones de bloqueo de IP.
- No se incluyen funciones de backup, restauración ni rollback.
- El actualizador valida el archivo `VERSION`, el encabezado, la versión declarada, el contenido esperado y la sintaxis Bash antes de instalar. El reemplazo del ejecutable se realiza mediante un archivo temporal de preparación en el mismo directorio y un cambio atómico de nombre; no se genera una copia de respaldo.
- El panel conserva sus módulos existentes de gestión de usuarios, límites, monitoreo, infraestructura y diagnóstico.

## Publicar una versión

Para publicar la versión 9.1:

1. Sube `BLUECOMPANY.sh`, `VERSION` y `README.md` a la raíz de `main`.
2. Comprueba que `VERSION` contenga exactamente `9.1` (una línea).
3. Comprueba que `BLUECOMPANY.sh` declare `VERSION_SCRIPT="9.1"`.
4. En el servidor, abre el panel y selecciona la opción 17.

Para futuras versiones, cambia de forma coincidente `VERSION_SCRIPT` dentro del script y el contenido de `VERSION` (por ejemplo, `9.2`, `9.3` o `10.0`).

## Validaciones de esta entrega

Ejecutada localmente sobre el archivo generado:

- `bash -n BLUECOMPANY.sh`: correcto.
- Búsqueda de referencias a Anti-BruteForce, listas de IP, backup y rollback: sin coincidencias.
- Comprobación de referencias a las funciones de backup/restauración eliminadas: sin coincidencias.
- Comprobación de declaración de versión: `9.1`.

No se han ejecutado pruebas de integración en un VPS ni pruebas reales de inicio de sesión SSH, SCP, SFTP, OpenSSH, Fail2ban, Xray o 3X-UI. Deben validarse en un entorno de prueba antes de desplegar en producción.
