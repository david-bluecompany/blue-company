# BLUE COMPANY Web Panel (prototipo)

Prototipo web estático en español que convierte las secciones del menú de `BLUECOMPANY.sh` en una interfaz administrativa adaptable a móviles.

## Ejecutar

Abre `index.html` en un navegador o sirve la carpeta con cualquier servidor estático, por ejemplo:

```bash
cd web-panel
python3 -m http.server 8000
```

Luego visita `http://localhost:8000`.

## Incluye

- Resumen visual de métricas, servicios, actividad y vencimientos.
- Navegación para usuarios, límites/sesiones, expiraciones, monitor, auditoría, servicios, diagnóstico y ajustes.
- Búsqueda y filtro local de usuarios usando datos de demostración.
- Diseño adaptable a escritorio y móvil.

## Limitaciones importantes

Este entregable es **solo un prototipo de interfaz**. No tiene autenticación, backend ni conexión con el VPS. Los usuarios, IPs, métricas, sesiones y registros son ficticios. Los botones de acción indican que están desactivados; no crean ni borran cuentas, no ejecutan comandos, no cambian servicios/firewall y no leen registros o procesos del host.

No lo expongas a Internet ni lo uses para administrar un servidor tal como está. Antes de producción hacen falta autenticación y autorización robustas, protección CSRF, validación en servidor, auditoría, gestión segura de secretos y un agente con permisos mínimos que solo admita operaciones explícitas. No conectar el navegador a una shell ni aceptar comandos arbitrarios.
