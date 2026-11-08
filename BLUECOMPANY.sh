#!/bin/bash
# ==============================================================================
#               BLUE COMPANY • CLOUD NETWORK MANAGER
#           Sistema Corporativo de Gestión SSH / WS / UDP
#                        Edición: ENTERPRISE v9.1
# ==============================================================================
VERSION_SCRIPT="9.2"
EDICION_SCRIPT="ENTERPRISE v9.2"
GITHUB_REPO_URL="https://github.com/david-bluecompany/blue-company"
GITHUB_RAW_URL="https://raw.githubusercontent.com/david-bluecompany/blue-company/main/BLUECOMPANY.sh"
GITHUB_VERSION_URL="https://raw.githubusercontent.com/david-bluecompany/blue-company/main/VERSION"

BIN_TARGET="/usr/local/bin/adm-ssh"
BIN_ALIAS="/usr/local/bin/blue"
DB_LIMITS="/etc/ssh-limits.txt"
CONF_DIR="/etc/bluecompany"
LOG_DIR="/var/log/bluecompany"
VERSION_LOCAL_FILE="${CONF_DIR}/version.info"
BLOCKED_USERS_DB="${CONF_DIR}/blocked_users.db"
LOCKS_LOG="${LOG_DIR}/locks.log"
AUDIT_LOG="${LOG_DIR}/admin_audit.log"
SECURITY_LOG="${LOG_DIR}/security.log"
PANEL_LOCK="/run/bluecompany-panel.lock"
UPDATE_LOCK="/run/bluecompany-update.lock"
MONITOR_LOCK="/run/bluecompany-monitor.lock"
UPDATE_CACHE="/run/bluecompany-update.cache"

# ------------------------------------------------------------------------------
# AUTO-ELEVACIÓN Y ENTORNO SEGURO
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi
export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

inicializar_entorno_seguro() {
    mkdir -p "$CONF_DIR" "$LOG_DIR" /etc/dropbear 2>/dev/null
    chmod 700 "$CONF_DIR" "$LOG_DIR" 2>/dev/null
    
    for f in "$DB_LIMITS" "$BLOCKED_USERS_DB" "$LOCKS_LOG" "$AUDIT_LOG" "$SECURITY_LOG"; do
        [ ! -f "$f" ] && touch "$f"
        chmod 600 "$f" 2>/dev/null
    done
    
    echo "$VERSION_SCRIPT" > "$VERSION_LOCAL_FILE"
    chmod 600 "$VERSION_LOCAL_FILE" 2>/dev/null

    # Instalación transparente del binario
    local script_actual
    script_actual=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [ "$script_actual" != "$BIN_TARGET" ] && [ -f "$0" ]; then
        if grep -q "BLUE COMPANY • CLOUD NETWORK MANAGER" "$0" 2>/dev/null; then
            cp -f "$0" "$BIN_TARGET"
            chmod 755 "$BIN_TARGET"
            ln -sf "$BIN_TARGET" "$BIN_ALIAS"
        fi
    fi

    # Limpieza de Banner antiguo en OpenSSH
    if [ -f /etc/ssh/sshd_config ] && grep -q "^Banner " /etc/ssh/sshd_config 2>/dev/null; then
        sed -i '/^#*Banner /d' /etc/ssh/sshd_config
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
    fi
    rm -f /etc/dropbear/banner.dat 2>/dev/null

    # Asegurar shells válidos
    for sh_path in "/bin/false" "/usr/sbin/nologin"; do
        if [ -f "$sh_path" ] && ! grep -qxF "$sh_path" /etc/shells 2>/dev/null; then
            echo "$sh_path" >> /etc/shells
        fi
    done
    sed -i '\|/bin/expired|d' /etc/shells 2>/dev/null

    # Limpieza de cron duplicado
    if [ -f /etc/crontab ]; then
        awk '!seen[$0]++ || $0 !~ /adm-ssh|blue-limiter/' /etc/crontab > /tmp/.crontab.blue.$$ && mv -f /tmp/.crontab.blue.$$ /etc/crontab
    fi

    # INICIO AUTOMÁTICO EN SSH INTERACTIVO (Seguro, no afecta SCP/SFTP)
    local bashrc_file="$HOME/.bashrc"
    if [ -f "$bashrc_file" ]; then
        if ! grep -q "BLUECOMPANY_RUNNING" "$bashrc_file"; then
            echo "" >> "$bashrc_file"
            echo "# BLUE COMPANY: Inicio automático en sesión SSH interactiva" >> "$bashrc_file"
            echo "if [ -n \"\$SSH_CLIENT\" ] && [ -n \"\$PS1\" ] && [ -z \"\$BLUECOMPANY_RUNNING\" ]; then" >> "$bashrc_file"
            echo "    export BLUECOMPANY_RUNNING=1" >> "$bashrc_file"
            echo "    exec $BIN_TARGET" >> "$bashrc_file"
            echo "fi" >> "$bashrc_file"
        fi
    fi
}

if [ "${1:-}" = "--install-only" ]; then
    inicializar_entorno_seguro
    echo "[✓] BLUE COMPANY ${EDICION_SCRIPT} instalado en ${BIN_TARGET} (comando: blue o adm-ssh)."
    exit 0
fi

# Protección contra ejecuciones duplicadas
exec 9>"$PANEL_LOCK"
if ! flock -n 9; then
    echo -e "\033[1;33m[!] Ya existe otra instancia activa de BLUE COMPANY (PID: $(cat "$PANEL_LOCK" 2>/dev/null)).\033[0m"
    exit 1
fi
echo "$$" >&9
inicializar_entorno_seguro

# ------------------------------------------------------------------------------
# PALETA DE COLORES
# ------------------------------------------------------------------------------
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_BLUE='\033[1;34m'
C_CYAN='\033[1;36m'
C_NEON='\033[38;5;39m'
C_BBLUE='\033[48;5;17m\033[1;37m'
C_BHEADER='\033[48;5;24m\033[1;37m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_WHITE='\033[1;37m'
C_GRAY='\033[0;90m'

# ------------------------------------------------------------------------------
# AUDITORÍA Y VALIDACIÓN
# ------------------------------------------------------------------------------
registrar_accion_admin() {
    local accion="$1" detalle="$2" fecha ip_admin
    fecha=$(date "+%Y-%m-%d %H:%M:%S")
    ip_admin=$(echo "${SSH_CLIENT:-LOCAL}" | awk '{print $1}')
    echo "${fecha} | ADMIN_IP:${ip_admin} | ${accion} | ${detalle}" >> "$AUDIT_LOG"
    chmod 600 "$AUDIT_LOG" 2>/dev/null
}

registrar_bloqueo_usuario() {
    local u="$1" motivo="$2" fecha
    fecha=$(date "+%Y-%m-%d %H:%M:%S")
    echo "${fecha}|${u}|${motivo}" >> "$LOCKS_LOG"
    sed -i "/^${u}|/d" "$BLOCKED_USERS_DB" 2>/dev/null
    echo "${u}|${fecha}|${motivo}" >> "$BLOCKED_USERS_DB"
    chmod 600 "$LOCKS_LOG" "$BLOCKED_USERS_DB" 2>/dev/null
}

validar_nombre_usuario() { [[ "$1" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; }
validar_entero_positivo() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; }
validar_ip_v4() {
    if [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'; read -r o1 o2 o3 o4 <<< "$1"
        [ "$o1" -le 255 ] && [ "$o2" -le 255 ] && [ "$o3" -le 255 ] && [ "$o4" -le 255 ]
        return $?
    fi
    return 1
}

# ------------------------------------------------------------------------------
# UTILIDADES DE TIEMPO Y BLOQUEO
# ------------------------------------------------------------------------------
calcular_duracion() {
    local entrada=$(echo "$1" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    [ -z "$entrada" ] && entrada="30d"
    local valor segs texto
    if [[ "$entrada" =~ ^([0-9]+)m$ ]]; then
        valor="${BASH_REMATCH[1]}"; [ "$valor" -le 0 ] && valor=30
        segs=$(( valor * 60 )); texto="${valor} min"
    elif [[ "$entrada" =~ ^([0-9]+)h$ ]]; then
        valor="${BASH_REMATCH[1]}"; [ "$valor" -le 0 ] && valor=1
        segs=$(( valor * 3600 )); texto="${valor} horas"
    elif [[ "$entrada" =~ ^([0-9]+)d?$ ]]; then
        valor="${BASH_REMATCH[1]}"; [ "$valor" -le 0 ] && valor=30
        segs=$(( valor * 86400 )); texto="${valor} días"
    else
        segs=$(( 30 * 86400 )); texto="30 días"
    fi
    echo "${segs}|${texto}"
}

bloquear_cuenta_sistema() {
    local u="$1" motivo="${2:-BLOQUEO DE SISTEMA}"
    expulsar_sesiones_usuario "$u"
    usermod -L -s /bin/expired -e 1970-01-02 "$u" 2>/dev/null
    passwd -l "$u" &>/dev/null
    registrar_bloqueo_usuario "$u" "$motivo"
}

desbloquear_cuenta_sistema() {
    local u="$1" clave="$2" exp_ep="$3"
    local f_chage=$(date -d "@$(( exp_ep + 86400 ))" +%Y-%m-%d 2>/dev/null || date -d "+30 days" +%Y-%m-%d)
    usermod -U -s /bin/false -e "$f_chage" "$u" 2>/dev/null
    passwd -u "$u" &>/dev/null
    [ -n "$clave" ] && [ "$clave" != "(Sin registro)" ] && echo "${u}:${clave}" | chpasswd 2>/dev/null
    sed -i "/^${u}|/d" "$BLOCKED_USERS_DB" 2>/dev/null
}

verificar_y_bloquear_vencidos_ahora() {
    [ ! -s "$DB_LIMITS" ] && return
    local ahora=$(date +%s)
    while IFS=':' read -r u lim clave exp_ep estado_manual _ <&3; do
        [[ -z "$u" || "$u" =~ ^# ]] && continue
        id "$u" &>/dev/null || continue
        local debe_bloquear=0 razon_bloqueo=""
        if [ "$estado_manual" = "SUSPENDIDO" ]; then
            debe_bloquear=1; razon_bloqueo="SUSPENSIÓN ADMINISTRATIVA"
        elif [ "$estado_manual" = "BLOQUEADO_LIMITE" ]; then
            debe_bloquear=1; razon_bloqueo="EXCESO DE LÍMITE DE CONEXIONES"
        elif [[ "$exp_ep" =~ ^[0-9]+$ ]] && [ "$exp_ep" -gt 0 ] && [ "$ahora" -ge "$exp_ep" ]; then
            debe_bloquear=1; razon_bloqueo="FECHA DE VENCIMIENTO EXPIRADA"
        fi
        if [ "$debe_bloquear" -eq 1 ]; then
            local sh_actual=$(getent passwd "$u" | cut -d: -f7)
            [ "$sh_actual" != "/bin/expired" ] && bloquear_cuenta_sistema "$u" "$razon_bloqueo"
        fi
    done 3< "$DB_LIMITS"
}

# ------------------------------------------------------------------------------
# MÉTRICAS DEL SERVIDOR
# ------------------------------------------------------------------------------
obtener_ip() {
    local cache_file="/tmp/.vps_public_ip" ip=""
    [ -s "$cache_file" ] && ip=$(cat "$cache_file" 2>/dev/null)
    if [ -z "$ip" ]; then
        ip=$(curl -s --max-time 2 https://api.ipify.org || curl -s --max-time 2 https://icanhazip.com | tr -d '[:space:]')
        if ! validar_ip_v4 "$ip"; then
            ip=$(hostname -I 2>/dev/null | awk '{print $1}')
            [ -z "$ip" ] && ip="127.0.0.1"
        else
            echo "$ip" > "$cache_file"
        fi
    fi
    echo "$ip"
}

obtener_uso_cpu() {
    local a b c idle1 e f g idle2 total1 total2 diff_idle diff_total uso
    read -r _ a b c idle1 e f g _ < /proc/stat
    total1=$((a + b + c + idle1 + e + f + g))
    sleep 0.10
    read -r _ a b c idle2 e f g _ < /proc/stat
    total2=$((a + b + c + idle2 + e + f + g))
    diff_idle=$((idle2 - idle1)); diff_total=$((total2 - total1))
    [ "$diff_total" -gt 0 ] && uso=$(( (100 * (diff_total - diff_idle)) / diff_total )) || uso=0
    echo "${uso}%"
}

obtener_info_ram_gb() {
    awk '/^MemTotal:/ { total_kb = $2 } /^MemFree:/ { free_kb = $2 } /^Buffers:/ { buf_kb = $2 } /^Cached:/ { cache_kb = $2 } /^MemAvailable:/ { avail_kb = $2 } END { if (total_kb <= 0) total_kb = 1; if (avail_kb <= 0) avail_kb = free_kb + buf_kb + cache_kb; used_kb = total_kb - avail_kb; if (used_kb < 0) used_kb = 0; printf "%.2f GB|%.2f GB|%d%%", avail_kb / 1048576, total_kb / 1048576, int((used_kb * 100) / total_kb) }' /proc/meminfo
}

obtener_trafico_red_gb() {
    local iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    [ -z "$iface" ] && iface=$(awk -F: 'NR>2 && $1 !~ /lo/ {gsub(/ /,"",$1); print $1; exit}' /proc/net/dev)
    awk -v dev="$iface" '$1 ~ "^"dev":" { sub(/^[^:]+:/, "", $0); printf "%.2f GB|%.2f GB", $1 / 1073741824, $9 / 1073741824; found=1; exit } END { if (!found) printf "0.00 GB|0.00 GB" }' /proc/net/dev
}

# ------------------------------------------------------------------------------
# MOTOR DE DETECCIÓN EN VIVO
# ------------------------------------------------------------------------------
obtener_mapa_dropbear() {
    if command -v python3 &>/dev/null; then
        python3 - "$DB_LIMITS" 2>/dev/null << 'PYEOF'
import os, sys, re, subprocess
db_file = sys.argv[1]
cache_file = "/run/blue-dropbear.map"
users = []
if os.path.exists(db_file):
    with open(db_file, "r", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and ":" in line:
                u = line.split(":", 1)[0].strip()
                if u: users.append(u)
users.sort(key=len, reverse=True)
all_pids = [entry for entry in os.listdir("/proc") if entry.isdigit() and "dropbear" in open(f"/proc/{entry}/comm", "r").read().strip().lower() and int(open(f"/proc/{entry}/stat", "r").read().rsplit(")", 1)[-1].split()[1]) > 1]
if not all_pids: sys.exit(0)
mapped = {}
if os.path.exists(cache_file):
    try:
        with open(cache_file, "r", errors="ignore") as cf:
            for line in cf:
                if ":" in line:
                    p, usr = line.strip().split(":", 1)
                    if p in all_pids: mapped[p] = usr
    except Exception: pass
if len(mapped) < len(all_pids):
    log_text = ""
    for lf in ["/var/log/auth.log.1", "/var/log/auth.log", "/var/log/syslog", "/var/log/secure"]:
        if os.path.exists(lf):
            try:
                with open(lf, "r", errors="ignore") as f:
                    f.seek(0, os.SEEK_END); sz = f.tell(); f.seek(max(0, sz - 250000)); log_text += f.read() + "\n"
            except Exception: pass
    try: log_text += subprocess.check_output(["journalctl", "-u", "dropbear", "--no-pager", "-n", "1000"], stderr=subprocess.DEVNULL).decode(errors="ignore")
    except Exception: pass
    pat = re.compile(r"dropbear\[(\d+)\]:.*succeeded for ['\"]?([^'\"\s]+)['\"]?", re.IGNORECASE)
    for m in pat.finditer(log_text):
        if m.group(1) in all_pids: mapped[m.group(1)] = m.group(2)
    for pid in all_pids:
        if pid in mapped: continue
        try:
            with open(f"/proc/{pid}/maps", "r") as mf, open(f"/proc/{pid}/mem", "rb", 0) as mem:
                for line in mf:
                    if "rw-p" not in line: continue
                    parts = line.split()[0].split("-")
                    start, end = int(parts[0], 16), int(parts[1], 16)
                    if end - start > 8 * 1024 * 1024: continue
                    mem.seek(start); chunk = mem.read(end - start)
                    for u in users:
                        ub = re.escape(u.encode())
                        if re.search(rb"/home/" + ub + rb"\x00(?!/)", chunk) or (b"succeeded for '" + u.encode() + b"'" in chunk):
                            mapped[pid] = u; break
                if pid in mapped: break
        except Exception: pass
for pid, usr in mapped.items(): print(f"{pid}:{usr}")
PYEOF
    fi
}

obtener_pids_usuario() {
    local u="$1" mapa_db="$2"
    local pids_ssh=$(ps -u "$u" -o pid=,comm= 2>/dev/null | awk '$2 ~ /^sshd/ {print $1}')
    [ -z "$pids_ssh" ] && pids_ssh=$(ps -eo pid=,user=,args= 2>/dev/null | awk -v usr="$u" '$2=="root" && $0 ~ "sshd(-session)?: " usr "(\\[priv\\]|@notty|$)" {print $1}')
    local pids_db=""
    [ -n "$mapa_db" ] && pids_db=$(printf "%s\n" "$mapa_db" | awk -F':' -v usr="$u" '$2 == usr {print $1}')
    printf "%s\n%s\n" "$pids_ssh" "$pids_db" | awk 'NF>0 {print $1}' | sort -u
}

contar_conexiones_usuario() {
    local u="$1" mapa_db="$2"
    local n_ssh=$(ps -u "$u" -o comm= 2>/dev/null | grep -cE '^sshd')
    [ "$n_ssh" -eq 0 ] && n_ssh=$(ps -eo user=,args= 2>/dev/null | awk -v usr="$u" '$1=="root" && $0 ~ "sshd(-session)?: " usr "(\\[priv\\]|@notty|$)" {c++} END {print c+0}')
    local n_db=0
    [ -n "$mapa_db" ] && n_db=$(printf "%s\n" "$mapa_db" | awk -F':' -v usr="$u" '$2 == usr {c++} END {print c+0}')
    echo $(( n_ssh + n_db ))
}

expulsar_sesiones_usuario() {
    local u="$1"
    [ -z "$u" ] || [ "$u" = "root" ] && return
    local mapa_db=$(obtener_mapa_dropbear)
    pkill -KILL -u "$u" 2>/dev/null
    ps -eo pid=,user=,args= 2>/dev/null | awk -v usr="$u" '$2=="root" && $0 ~ "sshd(-session)?: " usr "(\\[|@|$)" {print $1}' | xargs -r kill -9 2>/dev/null
    if [ -n "$mapa_db" ]; then
        local pids_db=$(printf "%s\n" "$mapa_db" | awk -F':' -v usr="$u" '$2 == usr {print $1}')
        for p in $pids_db; do
            [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ] && kill -9 "$p" 2>/dev/null
        done
    fi
}

obtener_telemetria_usuario() {
    local u="$1" mapa_db="$2"
    local pids=$(obtener_pids_usuario "$u" "$mapa_db")
    [ -z "$pids" ] && echo "-|-|0 B" && return
    local ip_cli="-" etime_max="-" bytes_total=0
    local ss_out=$(ss -tnp 2>/dev/null)
    for p in $pids; do
        [ ! -d "/proc/$p" ] && continue
        [ "$etime_max" = "-" ] && etime_max=$(ps -p "$p" -o etime= 2>/dev/null | xargs)
        [ -z "$etime_max" ] && etime_max="00:01"
        local ip_cand=$(printf "%s\n" "$ss_out" | grep "pid=${p}," | awk '{print $5}' | sed 's/::ffff://g' | cut -d: -f1 | grep -vE '^127\.' | head -n 1)
        [ -n "$ip_cand" ] && ip_cli="$ip_cand"
        if [ -r "/proc/$p/io" ]; then
            local b_proc=$(awk '/^(rchar|wchar):/ {sum += $2} END {print sum+0}' "/proc/$p/io" 2>/dev/null)
            bytes_total=$(( bytes_total + b_proc ))
        fi
    done
    [ "$ip_cli" = "-" ] && ip_cli=$(printf "%s\n" "$ss_out" | awk '$4 ~ /:80$/ {print $5}' | sed 's/::ffff://g' | cut -d: -f1 | grep -vE '^127\.' | head -n 1)
    [ -z "$ip_cli" ] && ip_cli="WS-Tunel(P:80)"
    local consumo_txt=$(awk -v b="$bytes_total" 'BEGIN { if (b <= 0) printf "N/D"; else if (b < 1048576) printf "%.1f KB", b / 1024; else if (b < 1073741824) printf "%.2f MB", b / 1048576; else printf "%.2f GB", b / 1073741824; }')
    echo "${ip_cli}|${etime_max}|${consumo_txt}"
}

# ------------------------------------------------------------------------------
# ACTUALIZADOR DESDE GITHUB (SIN BACKUP/ROLLBACK, VALIDACIÓN ESTRICTA)
# ------------------------------------------------------------------------------
actualizar_desde_github() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌───────── ACTUALIZADOR INTEGRADO DESDE GITHUB ────────┐${C_RESET}"
    exec 7>"$UPDATE_LOCK"
    if ! flock -n 7; then
        echo -e "  ${C_RED}[!] Ya hay un proceso de actualización en curso.${C_RESET}"
        read -r -p "  Presiona Enter para volver..."
        return
    fi

    echo -e "  ${C_CYAN}[*] Consultando repositorio oficial en GitHub...${C_RESET}"
    local v_remota=$(curl -sL --max-time 5 "$GITHUB_VERSION_URL" 2>/dev/null | tr -d '[:space:]')

    if [[ ! "$v_remota" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo -e "  ${C_RED}[!] No se pudo obtener la versión remota o el formato es inválido.${C_RESET}"
        flock -u 7 2>/dev/null; read -r -p "  Presiona Enter para volver..."; return
    fi

    echo -e "  ${C_WHITE}Versión Instalada :${C_RESET} ${C_GREEN}v${VERSION_SCRIPT}${C_RESET}"
    echo -e "  ${C_WHITE}Versión en GitHub :${C_RESET} ${C_YELLOW}v${v_remota}${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"

    if [ "$v_remota" = "$VERSION_SCRIPT" ]; then
        echo -e "  ${C_GREEN}[✓] Ya cuentas con la versión más reciente (v${VERSION_SCRIPT}).${C_RESET}"
        read -r -p "  ¿Deseas reinstalar/sincronizar el script de todos modos? (s/n): " conf_up
    else
        echo -e "  ${C_YELLOW}[!] Se detectó una nueva versión disponible (v${v_remota}).${C_RESET}"
        read -r -p "  ¿Confirmas descargar e instalar la actualización ahora? (s/n): " conf_up
    fi

    if [[ ! "$conf_up" =~ ^[sS]$ ]]; then
        echo -e "\n  ${C_YELLOW}[!] Actualización cancelada por el administrador.${C_RESET}"
        flock -u 7 2>/dev/null; read -r -p "  Presiona Enter para volver..."; return
    fi

    local tmp_dl="/tmp/bluecompany_update.sh"
    echo -e "\n  ${C_CYAN}[1/3] Descargando nueva versión desde GitHub...${C_RESET}"
    if ! curl -sL --fail --max-time 15 "$GITHUB_RAW_URL" -o "$tmp_dl" || [ ! -s "$tmp_dl" ]; then
        echo -e "  ${C_RED}[✖] Error al descargar el archivo desde GitHub.${C_RESET}"
        rm -f "$tmp_dl"; flock -u 7 2>/dev/null; read -r -p "  Presiona Enter para volver..."; return
    fi

    echo -e "  ${C_CYAN}[2/3] Validando integridad y sintaxis del código...${C_RESET}"
    if ! head -n 5 "$tmp_dl" | grep -q "BLUE COMPANY"; then
        echo -e "  ${C_RED}[✖] Validación fallida: El archivo no contiene el encabezado esperado.${C_RESET}"
        rm -f "$tmp_dl"; flock -u 7 2>/dev/null; read -r -p "  Presiona Enter para volver..."; return
    fi

    if ! bash -n "$tmp_dl" 2>/dev/null; then
        echo -e "  ${C_RED}[✖] Validación fallida: El archivo descargado contiene errores de sintaxis.${C_RESET}"
        rm -f "$tmp_dl"; flock -u 7 2>/dev/null; read -r -p "  Presiona Enter para volver..."; return
    fi

    echo -e "  ${C_CYAN}[3/3] Aplicando actualización...${C_RESET}"
    if cp -f "$tmp_dl" "$BIN_TARGET" && chmod 755 "$BIN_TARGET" && ln -sf "$BIN_TARGET" "$BIN_ALIAS"; then
        rm -f "$tmp_dl"
        echo "$v_remota" > "$VERSION_LOCAL_FILE"
        registrar_accion_admin "ACTUALIZAR_GITHUB" "De=v${VERSION_SCRIPT} A=v${v_remota}"
        echo -e "\n  ${C_GREEN}[✓] ¡Actualización a v${v_remota} completada con éxito!${C_RESET}"
        flock -u 7 2>/dev/null; flock -u 9 2>/dev/null
        read -r -p "  Presiona Enter para recargar el panel con la nueva versión..."
        exec "$BIN_TARGET"
    else
        echo -e "  ${C_RED}[✖] Error al escribir en ${BIN_TARGET}.${C_RESET}"
        rm -f "$tmp_dl"; flock -u 7 2>/dev/null; read -r -p "  Presiona Enter para volver..."
    fi
}

# ------------------------------------------------------------------------------
# ENCABEZADO Y UTILIDADES DE VISUALIZACIÓN
# ------------------------------------------------------------------------------
generar_banner() {
    local ip=$(obtener_ip) cpu=$(obtener_uso_cpu)
    local ram_data=$(obtener_info_ram_gb)
    IFS='|' read -r ram_libre ram_total ram_porc <<< "$ram_data"
    local net_data=$(obtener_trafico_red_gb)
    IFS='|' read -r rx_gb tx_gb <<< "$net_data"
    local total_reg=0
    [ -s "$DB_LIMITS" ] && total_reg=$(grep -cvE '^(#|$)' "$DB_LIMITS" 2>/dev/null || echo 0)
    
    local c_ssh="$C_RED" s_ssh="OFF"; pgrep -x "sshd" &>/dev/null && c_ssh="$C_GREEN" && s_ssh="ON"
    local c_db="$C_RED" s_db="OFF"; pgrep -x "dropbear" &>/dev/null && c_db="$C_GREEN" && s_db="ON"
    local c_ws="$C_RED" s_ws="OFF"; systemctl is-active --quiet despachador 2>/dev/null || pgrep -f "despachador.py" &>/dev/null && c_ws="$C_GREEN" && s_ws="ON"
    local c_udp="$C_RED" s_udp="OFF"; pgrep -f "badvpn-udpgw" &>/dev/null && c_udp="$C_GREEN" && s_udp="ON"
    local c_lim="$C_RED" s_lim="OFF"; systemctl is-active --quiet blue-limiter 2>/dev/null || pgrep -f "blue-limiter.py" &>/dev/null && c_lim="$C_GREEN" && s_lim="ON"
    
    local cc_actual=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local c_tcp="$C_YELLOW" s_tcp="Estándar"
    [ "$cc_actual" = "bbr" ] || [ -f /etc/sysctl.d/99-bluecompany-tcp.conf ] && c_tcp="$C_GREEN" && s_tcp="BBR + LowLatency"

    echo -e "${C_BLUE}╔══════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BLUE}║${C_BBLUE}        BLUE COMPANY • CLOUD NETWORK MANAGER          ${C_RESET}${C_BLUE}║${C_RESET}"
    echo -e "${C_BLUE}║${C_BHEADER}       Sistema Corporativo SSH/WS • ENTERPRISE v9.1   ${C_RESET}${C_BLUE}║${C_RESET}"
    echo -e "${C_BLUE}╠══════════════════════════════════════════════════════╣${C_RESET}"
    printf "${C_BLUE}║${C_RESET} ${C_CYAN}IP Servidor:${C_RESET} ${C_WHITE}%-19s${C_RESET} ${C_CYAN}CPU Uso:${C_RESET} ${C_YELLOW}%-10s${C_RESET} ${C_BLUE}║${C_RESET}\n" "$ip" "$cpu"
    printf "${C_BLUE}║${C_RESET} ${C_CYAN}RAM Libre  :${C_RESET} ${C_GREEN}%-11s${C_RESET} ${C_CYAN}Total:${C_RESET} ${C_WHITE}%-10s${C_RESET} ${C_YELLOW}(%-4s)${C_RESET}   ${C_BLUE}║${C_RESET}\n" "$ram_libre" "$ram_total" "$ram_porc"
    printf "${C_BLUE}║${C_RESET} ${C_CYAN}Tráfico RX :${C_RESET} ${C_GREEN}%-19s${C_RESET} ${C_CYAN}TX Sub.:${C_RESET} ${C_YELLOW}%-10s${C_RESET} ${C_BLUE}║${C_RESET}\n" "$rx_gb" "$tx_gb"
    printf "${C_BLUE}║${C_RESET} ${C_CYAN}Motor TCP  :${C_RESET} ${c_tcp}%-19s${C_RESET} ${C_CYAN}Cuentas:${C_RESET} ${C_WHITE}%-10s${C_RESET} ${C_BLUE}║${C_RESET}\n" "$s_tcp" "$total_reg"
    echo -e "${C_BLUE}╠══════════════════════════════════════════════════════╣${C_RESET}"
    printf "${C_BLUE}║${C_RESET} ${C_WHITE}SSH:${C_RESET}${c_ssh}%-3s${C_RESET} │ ${C_WHITE}DB:${C_RESET}${c_db}%-3s${C_RESET} │ ${C_WHITE}WS80:${C_RESET}${c_ws}%-3s${C_RESET} │ ${C_WHITE}UDP:${C_RESET}${c_udp}%-3s${C_RESET} │ ${C_WHITE}AUTO-LIM:${C_RESET}${c_lim}%-3s${C_RESET} ${C_BLUE}║${C_RESET}\n" "$s_ssh" "$s_db" "$s_ws" "$s_udp" "$s_lim"
    echo -e "${C_BLUE}╚══════════════════════════════════════════════════════╝${C_RESET}"
}

mostrar_pantalla_encabezado() {
    verificar_y_bloquear_vencidos_ahora
    clear
    generar_banner
}

imprimir_ticket_cliente() {
    local u="$1" c="$2" lim="$3" f_exp="$4" ip=$(obtener_ip)
    echo -e "${C_BLUE}╔══════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BLUE}║${C_BBLUE}         CREDENCIALES DE ACCESO • BLUE COMPANY        ${C_RESET}${C_BLUE}║${C_RESET}"
    echo -e "${C_BLUE}╠══════════════════════════════════════════════════════╣${C_RESET}"
    echo -e "  ${C_CYAN}Servidor / IP :${C_RESET} ${C_WHITE}$ip${C_RESET}"
    echo -e "  ${C_CYAN}Usuario       :${C_RESET} ${C_GREEN}$u${C_RESET}"
    echo -e "  ${C_CYAN}Contraseña    :${C_RESET} ${C_GREEN}$c${C_RESET}"
    echo -e "  ${C_CYAN}Vencimiento   :${C_RESET} ${C_YELLOW}$f_exp${C_RESET}"
    echo -e "  ${C_CYAN}Dispositivos  :${C_RESET} ${C_YELLOW}Máximo $lim simultáneos${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}Puertos WS    :${C_RESET} ${C_WHITE}80, 8080, 8880 (HTTP / WebSocket)${C_RESET}"
    echo -e "  ${C_CYAN}Puerto Directo:${C_RESET} ${C_WHITE}2222 (Dropbear) │ 22 (OpenSSH)${C_RESET}"
    echo -e "  ${C_CYAN}Puerto Juegos :${C_RESET} ${C_GREEN}7300 (BadVPN UDPGW)${C_RESET}"
    echo -e "${C_BLUE}╚══════════════════════════════════════════════════════╝${C_RESET}"
}

formatear_tiempo_restante() {
    local exp_ep="$1" ahora="$2"
    [[ ! "$exp_ep" =~ ^[0-9]+$ ]] || [ "$exp_ep" -le 0 ] && echo "Ilim." && return
    local diff=$(( exp_ep - ahora ))
    if [ "$diff" -le 0 ]; then echo "0m"
    elif [ "$diff" -lt 3600 ]; then echo "$(( (diff + 59) / 60 ))m"
    elif [ "$diff" -lt 86400 ]; then echo "$(( diff / 3600 ))h $(( (diff % 3600) / 60 ))m"
    else echo "$(( diff / 86400 ))d $(( (diff % 86400) / 3600 ))h"
    fi
}

# ==============================================================================
# CATEGORÍA 1: GESTIÓN COMERCIAL
# ==============================================================================
crear_usuario() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌───────── ALTA DE CLIENTE O DEMO EN 1-CLICK ──────────┐${C_RESET}"
    read -r -p "  ► Nombre de Usuario  : " usuario
    usuario=$(echo "$usuario" | tr -d ' ')
    local clave entrada_tiempo limite
    if [ -z "$usuario" ]; then
        local rnd=$(shuf -i 1000-9999 -n 1 2>/dev/null || echo $(( RANDOM % 9000 + 1000 )))
        usuario="demo${rnd}"
        while id "$usuario" &>/dev/null; do rnd=$(( RANDOM % 9000 + 1000 )); usuario="demo${rnd}"; done
        clave="1234"; limite=1
        read -r -p "  ► Duración Demo [30m]: " entrada_tiempo
        [ -z "$entrada_tiempo" ] && entrada_tiempo="30m"
    else
        if ! validar_nombre_usuario "$usuario"; then
            echo -e "\n${C_RED}  [!] Usa solo letras, números, guiones (-) o (_) [máx 32 caract.].${C_RESET}"
            read -r -p "  Presiona Enter para continuar..."; return
        fi
        if id "$usuario" &>/dev/null; then
            echo -e "\n${C_RED}  [!] El cliente '$usuario' ya existe en el servidor.${C_RESET}"
            read -r -p "  Presiona Enter para continuar..."; return
        fi
        read -r -p "  ► Contraseña [1234]  : " clave
        [ -z "$clave" ] && clave="1234"
        clave=$(echo "$clave" | tr -d ':')
        read -r -p "  ► Tiempo de servicio : " entrada_tiempo
        [ -z "$entrada_tiempo" ] && entrada_tiempo="30d"
        read -r -p "  ► Límite dispositivos: " limite
        validar_entero_positivo "$limite" || limite=1
    fi
    
    local info_t=$(calcular_duracion "$entrada_tiempo")
    IFS='|' read -r segs txt_dur <<< "$info_t"
    local exp_epoch=$(( $(date +%s) + segs ))
    local f_chage=$(date -d "@$(( exp_epoch + 86400 ))" +%Y-%m-%d)
    local fecha_legible=$(date -d "@$exp_epoch" "+%Y-%m-%d %H:%M")
    
    if ! useradd -M -s /bin/false -e "$f_chage" "$usuario" 2>/dev/null; then
        echo -e "\n${C_RED}  [!] Error al registrar el usuario en el sistema.${C_RESET}"
        read -r -p "  Presiona Enter para continuar..."; return
    fi
    echo "${usuario}:${clave}" | chpasswd
    sed -i "/^${usuario}:/d" "$DB_LIMITS"
    echo "${usuario}:${limite}:${clave}:${exp_epoch}:ACTIVO" >> "$DB_LIMITS"
    chmod 600 "$DB_LIMITS"
    registrar_accion_admin "CREAR_USUARIO" "Usuario=${usuario} Limite=${limite} Duracion=${txt_dur}"
    
    systemctl is-active --quiet blue-limiter 2>/dev/null || instalar_limitador_auto "1" &>/dev/null
    clear
    imprimir_ticket_cliente "$usuario" "$clave" "$limite" "$fecha_legible ($txt_dur)"
    read -r -p "  Presiona Enter para volver al panel..."
}

modificar_usuario() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌─────── MODIFICAR CREDENCIALES / LÍMITE / TIEMPO ─────┐${C_RESET}"
    read -r -p "  ► Nombre del cliente: " usuario
    if [ -z "$usuario" ] || ! id "$usuario" &>/dev/null; then
        echo -e "\n${C_RED}  [!] El cliente '$usuario' no existe.${C_RESET}"
        read -r -p "  Presiona Enter para continuar..."; return
    fi
    local linea_actual=$(grep -E "^${usuario}:" "$DB_LIMITS" 2>/dev/null | tail -n 1)
    local lim_actual=$(echo "$linea_actual" | cut -d: -f2)
    local clave_actual=$(echo "$linea_actual" | cut -d: -f3)
    local exp_actual=$(echo "$linea_actual" | cut -d: -f4)
    local est_actual=$(echo "$linea_actual" | cut -d: -f5)
    [[ ! "$lim_actual" =~ ^[0-9]+$ ]] && lim_actual=1
    [[ ! "$exp_actual" =~ ^[0-9]+$ ]] && exp_actual=$(( $(date +%s) + 2592000 ))
    [ -z "$clave_actual" ] && clave_actual="(Sin registro)"
    [ -z "$est_actual" ] && est_actual="ACTIVO"
    
    echo -e "  ${C_GRAY}(Deja en blanco para conservar el valor actual)${C_RESET}"
    read -r -p "  ► Nueva contraseña [Actual conservada]: " nueva_clave
    if [ -n "$nueva_clave" ]; then
        nueva_clave=$(echo "$nueva_clave" | tr -d ':')
        echo "${usuario}:${nueva_clave}" | chpasswd
        clave_actual="$nueva_clave"
        echo -e "  ${C_GREEN}[✓] Contraseña actualizada correctamente.${C_RESET}"
    fi
    read -r -p "  ► Nuevo límite disp. [$lim_actual]: " nuevo_limite
    if validar_entero_positivo "$nuevo_limite"; then
        lim_actual="$nuevo_limite"
        echo -e "  ${C_GREEN}[✓] Límite actualizado a $lim_actual dispositivos.${C_RESET}"
    fi
    sed -i "/^${usuario}:/d" "$DB_LIMITS"
    echo "${usuario}:${lim_actual}:${clave_actual}:${exp_actual}:${est_actual}" >> "$DB_LIMITS"
    registrar_accion_admin "MODIFICAR_USUARIO" "Usuario=${usuario} NuevoLimite=${lim_actual}"
    read -r -p "  Presiona Enter para volver..."
}

eliminar_usuario() {
    mostrar_pantalla_encabezado
    echo -e "${C_RED}┌────────────── BAJA Y PURGA DE CLIENTES ──────────────┐${C_RESET}"
    echo -e "  ${C_WHITE}[1]${C_RESET} Eliminar un Cliente Específico"
    echo -e "  ${C_YELLOW}[2]${C_RESET} Purgar Automáticamente Todas las Cuentas Vencidas"
    echo -e "  ${C_GRAY}[0] Volver${C_RESET}"
    read -r -p "  ► Opción: " op_del
    if [ "$op_del" = "2" ]; then
        mostrar_pantalla_encabezado
        echo -e "${C_NEON}┌─────────── PURGA DE CUENTAS EXPIRADAS ───────────────┐${C_RESET}"
        local borrados=0 hoy_epoch=$(date +%s)
        if [ -s "$DB_LIMITS" ]; then
            local lista_borrar=()
            while IFS=':' read -r u limite clave exp_ep _ <&3; do
                [[ -z "$u" || "$u" =~ ^# ]] && continue
                if ! id "$u" &>/dev/null || { [[ "$exp_ep" =~ ^[0-9]+$ ]] && [ "$exp_ep" -gt 0 ] && [ "$hoy_epoch" -ge "$exp_ep" ]; }; then
                    lista_borrar+=("$u")
                fi
            done 3< "$DB_LIMITS"
            for u in "${lista_borrar[@]}"; do
                expulsar_sesiones_usuario "$u"
                userdel -rf "$u" 2>/dev/null
                sed -i "/^${u}:/d" "$DB_LIMITS"
                sed -i "/^${u}|/d" "$BLOCKED_USERS_DB" 2>/dev/null
                echo -e "  ${C_RED}✖ Cuenta expirada eliminada definitivamente:${C_RESET} $u"
                borrados=$(( borrados + 1 ))
            done
        fi
        [ "$borrados" -eq 0 ] && echo -e "\n${C_GREEN}[✓] No hay cuentas vencidas pendientes por eliminar.${C_RESET}" || registrar_accion_admin "PURGAR_VENCIDOS" "TotalEliminados=${borrados}"
        read -r -p "  Presiona Enter para volver..."
        return
    elif [ "$op_del" != "1" ]; then return; fi
    
    read -r -p "  ► Cliente a eliminar: " usuario
    if [ -z "$usuario" ] || ! id "$usuario" &>/dev/null || [ "$usuario" = "root" ]; then
        echo -e "\n${C_RED}  [!] El cliente '$usuario' no existe o no es válido.${C_RESET}"
        read -r -p "  Presiona Enter para continuar..."; return
    fi
    read -r -p "  ¿Confirmas dar de baja a '$usuario'? (s/n): " confirm
    if [[ "$confirm" =~ ^[sS]$ ]]; then
        expulsar_sesiones_usuario "$usuario"
        userdel -rf "$usuario" 2>/dev/null
        sed -i "/^${usuario}:/d" "$DB_LIMITS"
        sed -i "/^${usuario}|/d" "$BLOCKED_USERS_DB" 2>/dev/null
        registrar_accion_admin "ELIMINAR_USUARIO" "Usuario=${usuario}"
        echo -e "\n${C_GREEN}  [✓] Cliente '$usuario' eliminado del sistema.${C_RESET}"
    else
        echo -e "\n${C_YELLOW}  [!] Operación cancelada.${C_RESET}"
    fi
    read -r -p "  Presiona Enter para volver..."
}

controlar_acceso_usuario() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌────── BLOQUEAR, DESBLOQUEAR Y REINTEGRAR CLIENTE ────┐${C_RESET}"
    read -r -p "  ► Nombre del cliente: " usuario
    if [ -z "$usuario" ] || ! id "$usuario" &>/dev/null; then
        echo -e "\n${C_RED}  [!] El cliente '$usuario' no existe.${C_RESET}"
        read -r -p "  Presiona Enter para continuar..."; return
    fi
    local linea=$(grep -E "^${usuario}:" "$DB_LIMITS" 2>/dev/null | tail -n 1)
    local lim=$(echo "$linea" | cut -d: -f2)
    local clave=$(echo "$linea" | cut -d: -f3)
    local exp_ep=$(echo "$linea" | cut -d: -f4)
    local est_manual=$(echo "$linea" | cut -d: -f5)
    [[ ! "$lim" =~ ^[0-9]+$ ]] && lim=1
    [[ ! "$exp_ep" =~ ^[0-9]+$ ]] && exp_ep=$(( $(date +%s) + 2592000 ))
    [ -z "$est_manual" ] && est_manual="ACTIVO"
    
    echo -e "  ${C_CYAN}Estado actual de '$usuario':${C_RESET} ${C_YELLOW}${est_manual}${C_RESET}\n"
    echo -e "  ${C_WHITE}[1]${C_RESET} Solo expulsar sesiones activas individuales ahora (Kick)"
    echo -e "  ${C_YELLOW}[2]${C_RESET} Bloquear / Suspender cliente temporalmente"
    echo -e "  ${C_GREEN}[3]${C_RESET} Desbloquear y Reintegrar cliente (Reactivar acceso)"
    echo -e "  ${C_GRAY}[0] Cancelar${C_RESET}"
    read -r -p "  ► Opción: " op_k
    
    case "$op_k" in
        1)
            local mapa_db=$(obtener_mapa_dropbear)
            local activas=$(contar_conexiones_usuario "$usuario" "$mapa_db")
            expulsar_sesiones_usuario "$usuario"
            registrar_accion_admin "EXPULSAR_SESIONES" "Usuario=${usuario} SesionesCerradas=${activas}"
            echo -e "\n${C_GREEN}  [✓] Se cerraron únicamente las conexiones activas ($activas) de '$usuario'.${C_RESET}"
            ;;
        2)
            read -r -p "  ► Motivo del bloqueo [Suspensión administrativa]: " motivo_b
            [ -z "$motivo_b" ] && motivo_b="Suspensión administrativa"
            bloquear_cuenta_sistema "$usuario" "$motivo_b"
            sed -i "/^${usuario}:/d" "$DB_LIMITS"
            echo "${usuario}:${lim}:${clave}:${exp_ep}:SUSPENDIDO" >> "$DB_LIMITS"
            registrar_accion_admin "BLOQUEAR_USUARIO" "Usuario=${usuario} Motivo=${motivo_b}"
            echo -e "\n${C_YELLOW}  [⏸] Cliente '$usuario' bloqueado individualmente.${C_RESET}"
            ;;
        3)
            if [ "$(date +%s)" -ge "$exp_ep" ]; then
                echo -e "\n${C_YELLOW}  [!] La fecha del cliente había expirado. Se otorgarán +30 días al reintegrar.${C_RESET}"
                read -r -p "  ¿Deseas reintegrarlo sumando 30 días ahora? (s/n): " conf_r
                [[ "$conf_r" =~ ^[sS]$ ]] && exp_ep=$(( $(date +%s) + 2592000 )) || return
            fi
            desbloquear_cuenta_sistema "$usuario" "$clave" "$exp_ep"
            sed -i "/^${usuario}:/d" "$DB_LIMITS"
            echo "${usuario}:${lim}:${clave}:${exp_ep}:ACTIVO" >> "$DB_LIMITS"
            registrar_accion_admin "REINTEGRAR_USUARIO" "Usuario=${usuario} Estado=ACTIVO"
            echo -e "\n${C_GREEN}  [✓] Cliente '$usuario' desbloqueado y reintegrado exitosamente.${C_RESET}"
            ;;
        *) return ;;
    esac
    read -r -p "  Presiona Enter para volver..."
}

consultar_vencimientos() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌─────── AUDITORÍA DE VENCIMIENTOS Y FICHAS ───────────┐${C_RESET}"
    printf "${C_BOLD}${C_CYAN} %-14s %-18s %-11s %-12s${C_RESET}\n" "USUARIO" "FECHA VENCIMIENTO" "RESTANTE" "ESTADO"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    local ahora=$(date +%s)
    if [ ! -s "$DB_LIMITS" ]; then
        echo -e "  ${C_YELLOW}No hay clientes registrados.${C_RESET}"
    else
        while IFS=':' read -r u lim clave exp_ep est_manual _ <&3; do
            [[ -z "$u" || "$u" =~ ^# ]] && continue
            id "$u" &>/dev/null || continue
            local f_txt rest_txt est_col
            if [[ "$exp_ep" =~ ^[0-9]+$ ]] && [ "$exp_ep" -gt 0 ]; then
                f_txt=$(date -d "@$exp_ep" "+%Y-%m-%d %H:%M")
                rest_txt=$(formatear_tiempo_restante "$exp_ep" "$ahora")
            else
                f_txt="Ilimitado"; rest_txt="Ilim."
            fi
            if [ "$est_manual" = "SUSPENDIDO" ] || [ "$est_manual" = "BLOQUEADO_LIMITE" ]; then
                est_col="${C_YELLOW}${est_manual}${C_RESET}"
            elif [ "$rest_txt" = "0m" ]; then
                est_col="${C_RED}VENCIDO${C_RESET}"
            else
                est_col="${C_GREEN}ACTIVO${C_RESET}"
            fi
            printf " ${C_WHITE}%-14s${C_RESET} %-18s ${C_YELLOW}%-11s${C_RESET} %b\n" "$u" "$f_txt" "$rest_txt" "$est_col"
        done 3< "$DB_LIMITS"
    fi
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_WHITE}[F]${C_RESET} Ver Ficha / Ticket Completo de un Cliente   ${C_GRAY}[ENTER] Volver${C_RESET}"
    read -r -p "  ► Selección: " op_v
    [[ "$op_v" =~ ^[fF]$ ]] && ver_ficha_cliente
}

ver_ficha_cliente() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌─────────── CONSULTAR FICHA DE CLIENTE ───────────────┐${C_RESET}"
    read -r -p "  ► Nombre del cliente: " usuario
    if [ -z "$usuario" ] || ! id "$usuario" &>/dev/null; then
        echo -e "\n${C_RED}  [!] El cliente '$usuario' no existe.${C_RESET}"
        read -r -p "  Presiona Enter para continuar..."; return
    fi
    local linea=$(grep -E "^${usuario}:" "$DB_LIMITS" 2>/dev/null | tail -n 1)
    local lim=$(echo "$linea" | cut -d: -f2)
    local clave=$(echo "$linea" | cut -d: -f3)
    local exp_ep=$(echo "$linea" | cut -d: -f4)
    local est_manual=$(echo "$linea" | cut -d: -f5)
    local ahora=$(date +%s)
    [[ ! "$lim" =~ ^[0-9]+$ ]] && lim=1
    [ -z "$clave" ] && clave="(Asignada previamente)"
    local exp_txt=""
    if [[ "$exp_ep" =~ ^[0-9]+$ ]] && [ "$exp_ep" -gt 0 ]; then
        exp_txt=$(date -d "@$exp_ep" "+%Y-%m-%d %H:%M")
        if [ "$est_manual" = "SUSPENDIDO" ] || [ "$est_manual" = "BLOQUEADO_LIMITE" ]; then
            exp_txt="$exp_txt ($est_manual)"
        elif [ "$ahora" -ge "$exp_ep" ]; then
            exp_txt="$exp_txt (VENCIDO / BLOQUEADO)"
        else
            exp_txt="$exp_txt (Restan: $(formatear_tiempo_restante "$exp_ep" "$ahora"))"
        fi
    else
        exp_txt="Ilimitado"
    fi
    clear
    imprimir_ticket_cliente "$usuario" "$clave" "$lim" "$exp_txt"
    read -r -p "  Presiona Enter para volver..."
}

consultar_limites_clientes() {
    mostrar_pantalla_encabezado
    local mapa_db=$(obtener_mapa_dropbear)
    echo -e "${C_NEON}┌─────────── CONSULTA DE LÍMITES Y CAPACIDAD ──────────┐${C_RESET}"
    printf "${C_BOLD}${C_CYAN} %-15s %-12s %-12s %-14s${C_RESET}\n" "USUARIO" "CONECTADOS" "LÍMITE MAX" "DISPONIBILIDAD"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    if [ ! -s "$DB_LIMITS" ]; then
        echo -e "  ${C_YELLOW}No hay clientes registrados.${C_RESET}"
    else
        while IFS=':' read -r u lim _ <&3; do
            [[ -z "$u" || "$u" =~ ^# ]] && continue
            id "$u" &>/dev/null || continue
            [[ ! "$lim" =~ ^[0-9]+$ ]] && lim=1
            local act=$(contar_conexiones_usuario "$u" "$mapa_db")
            local disp_txt="${C_GREEN}$(( lim - act )) libres${C_RESET}"
            [ "$act" -gt "$lim" ] && disp_txt="${C_RED}EXCEDIDO (+$(( act - lim )))${C_RESET}"
            [ "$act" -eq "$lim" ] && disp_txt="${C_YELLOW}COMPLETO (0 libres)${C_RESET}"
            printf " ${C_WHITE}%-15s${C_RESET} ${C_YELLOW}%-12s${C_RESET} %-12s %b\n" "$u" "$act" "$lim" "$disp_txt"
        done 3< "$DB_LIMITS"
    fi
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

# ==============================================================================
# CATEGORÍA 2: MONITOREO Y SEGURIDAD
# ==============================================================================
listar_usuarios_en_vivo() {
    exec 8>"$MONITOR_LOCK"
    if ! flock -n 8; then
        echo -e "\n${C_YELLOW}[!] El monitor en tiempo real ya está abierto en otra sesión.${C_RESET}"
        read -r -p "  Presiona Enter para volver..."; return
    fi
    while true; do
        verificar_y_bloquear_vencidos_ahora
        clear
        generar_banner
        echo -e "${C_NEON}  MONITOR INTELIGENTE DE USUARIOS EN TIEMPO REAL (2s)${C_RESET}"
        echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
        printf "${C_BOLD}${C_CYAN} %-11s %-15s %-7s %-8s %-9s %-10s${C_RESET}\n" "USUARIO" "IP CLIENTE" "SES/LIM" "TIEMPO" "CONSUMO" "ESTADO"
        echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
        local total_online=0 total_conex=0 hoy_epoch=$(date +%s)
        local mapa_db=$(obtener_mapa_dropbear)
        if [ ! -s "$DB_LIMITS" ]; then
            echo -e "  ${C_YELLOW}No hay clientes registrados en la base de datos.${C_RESET}"
        else
            while IFS=':' read -r u limite clave exp_ep est_manual _ <&3; do
                [[ -z "$u" || "$u" =~ ^# ]] && continue
                id "$u" &>/dev/null || continue
                [[ ! "$limite" =~ ^[0-9]+$ ]] && limite=1
                local activas=$(contar_conexiones_usuario "$u" "$mapa_db")
                total_conex=$(( total_conex + activas ))
                [ "$activas" -gt 0 ] && total_online=$(( total_online + 1 ))
                local dias_txt=$(formatear_tiempo_restante "$exp_ep" "$hoy_epoch")
                local sh_usr=$(getent passwd "$u" | cut -d: -f7)
                local ip_u="-" t_con="-" cons_u="-"
                [ "$activas" -gt 0 ] && { local tele=$(obtener_telemetria_usuario "$u" "$mapa_db"); IFS='|' read -r ip_u t_con cons_u <<< "$tele"; }
                
                local estado="${C_GRAY}○ Inactivo${C_RESET}"
                if [ "$est_manual" = "SUSPENDIDO" ] || [ "$est_manual" = "BLOQUEADO_LIMITE" ]; then estado="${C_YELLOW}⏸ Bloq.${C_RESET}"
                elif [ "$dias_txt" = "0m" ] || [ "$sh_usr" = "/bin/expired" ]; then estado="${C_RED}✖ Vencido${C_RESET}"
                elif [ "$activas" -gt "$limite" ]; then estado="${C_RED}▲ Excedido${C_RESET}"
                elif [ "$activas" -gt 0 ]; then estado="${C_GREEN}● Online${C_RESET}"
                fi
                printf " ${C_WHITE}%-11.11s${C_RESET} %-15.15s ${C_YELLOW}%-7s${C_RESET} %-8.8s %-9.9s %b\n" "$u" "$ip_u" "${activas}/${limite}" "$t_con" "$cons_u" "$estado"
            done 3< "$DB_LIMITS"
        fi
        echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
        echo -e " ${C_CYAN}Clientes Conectados:${C_RESET} ${C_GREEN}$total_online${C_RESET}  │  ${C_CYAN}Túneles Activos:${C_RESET} ${C_YELLOW}$total_conex${C_RESET}"
        echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
        echo -e " ${C_YELLOW}[B]${C_RESET} Bloquear individualmente excedidos   ${C_RED}[Q / ENTER]${C_RESET} Salir"
        if read -r -t 2 -n 1 tecla; then
            if [[ "$tecla" =~ ^[bB]$ ]]; then
                local bloqueados_ahora=0
                while IFS=':' read -r u limite clave exp_ep est_manual _ <&3; do
                    [[ -z "$u" || "$u" =~ ^# ]] && continue
                    id "$u" &>/dev/null || continue
                    local act=$(contar_conexiones_usuario "$u" "$mapa_db")
                    if [ "$act" -gt "$limite" ]; then
                        bloquear_cuenta_sistema "$u" "EXCESO DE LÍMITE DETECTADO (${act}/${limite} sesiones)"
                        sed -i "/^${u}:/d" "$DB_LIMITS"
                        echo "${u}:${limite}:${clave}:${exp_ep}:BLOQUEADO_LIMITE" >> "$DB_LIMITS"
                        bloqueados_ahora=$(( bloqueados_ahora + 1 ))
                    fi
                done 3< "$DB_LIMITS"
                echo -e "\n${C_GREEN}[✓] Se bloquearon individualmente $bloqueados_ahora usuarios que superaban su límite.${C_RESET}"
                sleep 1.5
            else
                break
            fi
        fi
    done
    flock -u 8 2>/dev/null
}

monitor_consumo_usuarios() {
    mostrar_pantalla_encabezado
    local mapa_db=$(obtener_mapa_dropbear)
    echo -e "${C_NEON}┌───────── MONITOR DE CONSUMO DE DATOS Y SESIÓN ───────┐${C_RESET}"
    printf "${C_BOLD}${C_CYAN} %-14s %-9s %-14s %-16s${C_RESET}\n" "USUARIO" "SESIONES" "TIEMPO ACTIVO" "TRÁFICO SESIÓN"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    local hay_datos=0
    if [ -s "$DB_LIMITS" ]; then
        while IFS=':' read -r u limite _ <&3; do
            [[ -z "$u" || "$u" =~ ^# ]] && continue
            id "$u" &>/dev/null || continue
            local act=$(contar_conexiones_usuario "$u" "$mapa_db")
            local tele=$(obtener_telemetria_usuario "$u" "$mapa_db")
            IFS='|' read -r ip_u t_con cons_u <<< "$tele"
            printf " ${C_WHITE}%-14s${C_RESET} ${C_YELLOW}%-9s${C_RESET} %-14s ${C_GREEN}%-16s${C_RESET}\n" "$u" "${act}/${limite}" "$t_con" "$cons_u"
            hay_datos=1
        done 3< "$DB_LIMITS"
    fi
    [ "$hay_datos" -eq 0 ] && echo -e "  ${C_YELLOW}No hay usuarios registrados para medir consumo.${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

gestion_bloqueos_automaticos() {
    mostrar_pantalla_encabezado
    local est_lim="${C_RED}INACTIVO${C_RESET}"
    systemctl is-active --quiet blue-limiter 2>/dev/null && est_lim="${C_GREEN}ACTIVO 24/7 (Vigilancia individual cada 3s)${C_RESET}"
    echo -e "${C_NEON}┌────── CONTROL DE BLOQUEOS AUTOMÁTICOS Y LÍMITES ─────┐${C_RESET}"
    echo -e "  Demonio Auto-Limitador: $est_lim"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}Usuarios actualmente bloqueados:${C_RESET}"
    if [ ! -s "$BLOCKED_USERS_DB" ]; then
        echo -e "  ${C_GREEN}✓ Ningún usuario bloqueado en este momento.${C_RESET}"
    else
        while IFS='|' read -r bu bf bm; do
            [ -z "$bu" ] && continue
            echo -e "  ${C_RED}● $bu${C_RESET} │ ${C_GRAY}$bf${C_RESET} │ ${C_YELLOW}$bm${C_RESET}"
        done < "$BLOCKED_USERS_DB"
    fi
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_WHITE}[1]${C_RESET} Desbloquear y Reintegrar un Usuario Bloqueado"
    echo -e "  ${C_WHITE}[2]${C_RESET} Activar / Actualizar Motor Auto-Limitador 24/7"
    echo -e "  ${C_WHITE}[3]${C_RESET} Detener Motor Auto-Limitador"
    echo -e "  ${C_GRAY}[0] Volver${C_RESET}"
    read -r -p "  ► Opción: " op_ba
    case "$op_ba" in
        1) controlar_acceso_usuario ;;
        2) instalar_limitador_auto ;;
        3)
            systemctl stop blue-limiter &>/dev/null
            systemctl disable blue-limiter &>/dev/null
            registrar_accion_admin "DETENER_LIMITADOR" "Auto-Limitador desactivado manualmente"
            echo -e "\n${C_YELLOW}[!] Auto-Limitador detenido.${C_RESET}"
            read -r -p "  Presiona Enter para volver..."
            ;;
        *) return ;;
    esac
}

consultar_historial_sistema() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌────── HISTORIAL DE BLOQUEOS Y AUDITORÍA ADMIN ───────┐${C_RESET}"
    echo -e "  ${C_WHITE}[1]${C_RESET} Consultar Historial de Bloqueos de Usuarios (Fecha/Hora/Motivo)"
    echo -e "  ${C_WHITE}[2]${C_RESET} Consultar Historial de Acciones Administrativas"
    echo -e "  ${C_WHITE}[3]${C_RESET} Consultar Registro de Eventos de Seguridad (IPs)"
    echo -e "  ${C_GRAY}[0] Volver${C_RESET}"
    read -r -p "  ► Opción: " op_h
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    case "$op_h" in
        1)
            echo -e "${C_CYAN}  ÚLTIMOS BLOQUEOS DE USUARIOS REGISTRADOS:${C_RESET}"
            [ -s "$LOCKS_LOG" ] && tail -n 25 "$LOCKS_LOG" | awk -F'|' '{printf "  \033[0;90m%s\033[0m │ \033[1;37m%-12s\033[0m │ \033[1;33m%s\033[0m\n", $1, $2, $3}' || echo -e "  ${C_GREEN}Sin registros de bloqueos hasta la fecha.${C_RESET}"
            ;;
        2)
            echo -e "${C_CYAN}  HISTORIAL DE ACCIONES ADMINISTRATIVAS:${C_RESET}"
            [ -s "$AUDIT_LOG" ] && tail -n 25 "$AUDIT_LOG" | sed 's/^/  /' || echo -e "  ${C_GRAY}Sin acciones registradas.${C_RESET}"
            ;;
        3)
            echo -e "${C_CYAN}  REGISTRO DE SEGURIDAD E IPs BLOQUEADAS:${C_RESET}"
            [ -s "$SECURITY_LOG" ] && tail -n 25 "$SECURITY_LOG" | sed 's/^/  /' || echo -e "  ${C_GREEN}Sin incidentes de seguridad registrados.${C_RESET}"
            ;;
        *) return ;;
    esac
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

# NUEVO: CENTRO DE SEGURIDAD Y ESTADO DEL SERVIDOR (Solo consulta, sin bloqueos)
centro_seguridad_estado() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌────── CENTRO DE SEGURIDAD Y ESTADO DEL SERVIDOR ─────┐${C_RESET}"

    local ssh_st=$(systemctl is-active ssh 2>/dev/null || echo "inactive")
    local f2b_st=$(systemctl is-active fail2ban 2>/dev/null || echo "inactive")
    local xray_st=$(systemctl is-active xray 2>/dev/null || pgrep -x xray >/dev/null && echo "active" || echo "inactive")
    local xui_st=$(systemctl is-active x-ui 2>/dev/null || echo "inactive")
    local fw_st=$(ufw status 2>/dev/null | grep -q "active" && echo "Activo (UFW)" || (iptables -L -n >/dev/null 2>&1 && echo "Activo (iptables)" || echo "Inactivo"))

    echo -e "  ${C_CYAN}1. ESTADO DE SERVICIOS CRÍTICOS:${C_RESET}"
    printf "   %-25s %b\n" "OpenSSH:" "$([ "$ssh_st" = "active" ] && echo -e "${C_GREEN}● ACTIVO${C_RESET}" || echo -e "${C_RED}● DETENIDO${C_RESET}")"
    printf "   %-25s %b\n" "Fail2ban:" "$([ "$f2b_st" = "active" ] && echo -e "${C_GREEN}● ACTIVO${C_RESET}" || echo -e "${C_YELLOW}○ INACTIVO${C_RESET}")"
    printf "   %-25s %b\n" "Xray Core:" "$([ "$xray_st" = "active" ] && echo -e "${C_GREEN}● ACTIVO${C_RESET}" || echo -e "${C_GRAY}○ NO DETECTADO${C_RESET}")"
    printf "   %-25s %b\n" "3X-UI Panel:" "$([ "$xui_st" = "active" ] && echo -e "${C_GREEN}● ACTIVO${C_RESET}" || echo -e "${C_GRAY}○ NO DETECTADO${C_RESET}")"
    printf "   %-25s %b\n" "Firewall:" "$([ "$fw_st" != "Inactivo" ] && echo -e "${C_GREEN}● $fw_st${C_RESET}" || echo -e "${C_YELLOW}○ INACTIVO${C_RESET}")"

    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}2. RECURSOS DEL SISTEMA:${C_RESET}"
    local cpu=$(obtener_uso_cpu)
    local ram=$(obtener_info_ram_gb)
    IFS='|' read -r ram_libre ram_total ram_porc <<< "$ram"
    local disk=$(df -h / | awk 'NR==2 {print $5 " usado (" $4 " libre)"}')
    printf "   %-25s %b\n" "Uso de CPU:" "${C_YELLOW}$cpu${C_RESET}"
    printf "   %-25s %b\n" "Uso de RAM:" "${C_YELLOW}$ram_porc%${C_RESET} (Libre: $ram_libre / $ram_total)"
    printf "   %-25s %b\n" "Espacio en Disco (/):" "${C_YELLOW}$disk${C_RESET}"

    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}3. PUERTOS EN ESCUCHA (Principales):${C_RESET}"
    ss -tuln 2>/dev/null | awk 'NR>1 {print "   "$1" "$5}' | grep -E ':(22|80|443|2222|7300|8080|8880|2052|2053|2082|2083|2086|2087|2095|2096|8443|53|3306|5432) ' | sort -u | head -n 8

    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}4. PERMISOS DE ARCHIVOS CRÍTICOS:${C_RESET}"
    local perm_db=$(stat -c "%a %n" "$DB_LIMITS" 2>/dev/null || echo "No encontrado")
    local perm_conf=$(stat -c "%a %n" "$CONF_DIR" 2>/dev/null || echo "No encontrado")
    printf "   %-40s %b\n" "Base de datos:" "${C_WHITE}$perm_db${C_RESET}"
    printf "   %-40s %b\n" "Directorio de configuración:" "${C_WHITE}$perm_conf${C_RESET}"

    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}5. ÚLTIMOS EVENTOS DE SEGURIDAD (Auth Log):${C_RESET}"
    local log_file="/var/log/auth.log"
    [ ! -f "$log_file" ] && log_file="/var/log/secure"
    if [ -f "$log_file" ]; then
        tail -n 5 "$log_file" 2>/dev/null | grep -iE "failed|accepted|invalid" | sed 's/^/   /' || echo "   Sin eventos recientes relevantes."
    else
        echo "   No se pudo acceder al registro de autenticación."
    fi

    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_GRAY}[ENTER] Volver al menú principal${C_RESET}"
    read -r -p "  ► "
}

# ==============================================================================
# CATEGORÍA 3: INFRAESTRUCTURA Y DIAGNÓSTICO DEL VPS
# ==============================================================================
estado_servicios_diferenciado() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌───── ESTADO DE SERVICIOS (BLUE COMPANY vs EXTERNOS) ─┐${C_RESET}"
    echo -e "  ${C_CYAN}1. SERVICIOS ADMINISTRADOS POR BLUE COMPANY:${C_RESET}"
    local s_list=("ssh:OpenSSH Server (P:22)" "dropbear:Dropbear SSH (P:2222)" "despachador:Despachador Multiplexor WS (P:80/8080/8880)" "badvpn:BadVPN UDPGW (P:7300)" "blue-limiter:Auto-Limitador Inteligente 24/7")
    for item in "${s_list[@]}"; do
        local srv="${item%%:*}" desc="${item#*:}" st_txt="${C_RED}● DETENIDO${C_RESET}"
        if [ "$srv" = "ssh" ]; then pgrep -x "sshd" &>/dev/null && st_txt="${C_GREEN}● ACTIVO${C_RESET}"
        elif [ "$srv" = "dropbear" ]; then pgrep -x "dropbear" &>/dev/null && st_txt="${C_GREEN}● ACTIVO${C_RESET}"
        elif [ "$srv" = "badvpn" ]; then pgrep -f "badvpn-udpgw" &>/dev/null && st_txt="${C_GREEN}● ACTIVO${C_RESET}"
        else systemctl is-active --quiet "$srv" 2>/dev/null && st_txt="${C_GREEN}● ACTIVO${C_RESET}"
        fi
        printf "   %-44s %b\n" "$desc" "$st_txt"
    done
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}2. SERVICIOS EXTERNOS (SOLO LECTURA - NO MODIFICADOS):${C_RESET}"
    local ext_list=("xray:Xray Core (VLESS/VMess/Trojan)" "x-ui:Panel 3x-ui / x-ui" "nginx:Servidor Web Nginx" "hysteria-server:Hysteria 2 UDP" "cron:Demonio de Tareas Cron")
    for item in "${ext_list[@]}"; do
        local srv="${item%%:*}" desc="${item#*:}" st_txt="${C_GRAY}○ No instalado / Inactivo${C_RESET}"
        systemctl is-active --quiet "$srv" 2>/dev/null || pgrep -x "${srv%%-*}" &>/dev/null && st_txt="${C_GREEN}● ACTIVO (Protegido)${C_RESET}"
        printf "   %-44s %b\n" "$desc" "$st_txt"
    done
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

puertos_en_escucha_vps() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌───────── PUERTOS EN ESCUCHA Y CLASIFICACIÓN ─────────┐${C_RESET}"
    printf "${C_BOLD}${C_CYAN} %-7s %-9s %-18s %-20s${C_RESET}\n" "PROTO" "PUERTO" "PROCESO" "ORIGEN / GESTIÓN"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    ss -tulnp 2>/dev/null | awk 'NR>1 {
        proto = $1; split($5, a, ":"); port = a[length(a)]; proc = $7
        gsub(/users:\(\("/, "", proc); gsub(/".*/, "", proc)
        if (proc == "") proc = "kernel/sistema"
        if (port ~ /^(22|80|2222|7300)$|despachador|dropbear|badvpn/) origen = "\033[1;36mBLUE COMPANY\033[0m"
        else origen = "\033[1;33mEXTERNO (Respetado)\033[0m"
        printf " %-7s %-9s %-18.18s %s\n", proto, port, proc, origen
    }' | sort -u
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "8080,8880" && echo -e "  ${C_GREEN}✓ Redirección NAT Activa:${C_RESET} Puertos 8080, 8880 -> Puerto 80 (Despachador)" || echo -e "  ${C_YELLOW}! Redirección NAT 8080/8880:${C_RESET} No detectada"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

monitor_cpu_ram_procesos() {
    mostrar_pantalla_encabezado
    local cpu_u=$(obtener_uso_cpu)
    local load_avg=$(awk '{print $1 " (1m) | " $2 " (5m) | " $3 " (15m)"}' /proc/loadavg 2>/dev/null)
    echo -e "${C_NEON}┌───────── RENDIMIENTO DE CPU, RAM Y PROCESOS ─────────┐${C_RESET}"
    echo -e "  ${C_CYAN}Uso Actual CPU :${C_RESET} ${C_YELLOW}$cpu_u${C_RESET}"
    echo -e "  ${C_CYAN}Carga Sistema  :${C_RESET} ${C_WHITE}$load_avg${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}ESTADO DETALLADO DE MEMORIA RAM Y SWAP:${C_RESET}"
    free -h | awk 'NR==1 {printf "  \033[1;36m%-10s %-10s %-10s %-10s %-10s\033[0m\n", "TIPO", "TOTAL", "USADO", "LIBRE", "DISPONIBLE"} NR==2 {printf "  %-10s %-10s %-10s %-10s %-10s\n", "RAM:", $2, $3, $4, $7} NR==3 {printf "  %-10s %-10s %-10s %-10s\n", "SWAP:", $2, $3, $4}'
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}TOP 8 PROCESOS QUE CONSUMEN MÁS RECURSOS:${C_RESET}"
    printf "${C_BOLD}${C_CYAN}  %-8s %-10s %-7s %-7s %-20s${C_RESET}\n" "PID" "USUARIO" "%CPU" "%MEM" "COMANDO"
    ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu,-%mem 2>/dev/null | awk 'NR>1 && NR<=9 {printf "  %-8s %-10.10s %-7s %-7s %-20.20s\n", $1, $2, $3, $4, $5}'
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

diagnostico_integral_vps() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌────────── DIAGNÓSTICO INTEGRAL DEL SERVIDOR ─────────┐${C_RESET}"
    echo -e "  ${C_CYAN}1. ESPACIO DISPONIBLE EN DISCO E INODOS:${C_RESET}"
    df -h / | awk 'NR==2 {printf "   Partición Raíz (/): Usado %s de %s (Disponible: \033[1;32m%s\033[0m - Uso: %s)\n", $3, $2, $4, $5}'
    df -i / | awk 'NR==2 {printf "   Uso de Inodos (/) : %s usados (%s disponible)\n", $5, $4}'
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}2. SALUD DE COMPONENTES BLUE COMPANY:${C_RESET}"
    local sh_ok="${C_GREEN}OK${C_RESET}"
    grep -qxF "/bin/expired" /etc/shells 2>/dev/null && sh_ok="${C_RED}ALERTA (/bin/expired en /etc/shells)${C_RESET}"
    echo -e "   Seguridad de Shells (/etc/shells): $sh_ok"
    echo -e "   Base de Datos ($DB_LIMITS) : $( [ -r "$DB_LIMITS" ] && echo -e "${C_GREEN}Legible ($(wc -l < "$DB_LIMITS") registros)${C_RESET}" || echo -e "${C_RED}No encontrada${C_RESET}" )"
    echo -e "   Demonio Limitador (blue-limiter) : $( systemctl is-active --quiet blue-limiter && echo -e "${C_GREEN}ACTIVO${C_RESET}" || echo -e "${C_RED}DETENIDO${C_RESET}" )"
    echo -e "   Multiplexor WS (despachador.py)  : $( systemctl is-active --quiet despachador && echo -e "${C_GREEN}ACTIVO${C_RESET}" || echo -e "${C_RED}DETENIDO${C_RESET}" )"
    echo -e "   Dropbear SSH (Puerto 2222)       : $( pgrep -x dropbear &>/dev/null && echo -e "${C_GREEN}ACTIVO${C_RESET}" || echo -e "${C_RED}DETENIDO${C_RESET}" )"
    echo -e "   Xray / 3x-ui (Externo)           : $( pgrep -x xray &>/dev/null && echo -e "${C_GREEN}ACTIVO (Intacto)${C_RESET}" || echo -e "${C_GRAY}No detectado${C_RESET}" )"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

informacion_ficha_vps() {
    mostrar_pantalla_encabezado
    local os_name=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 || uname -s)
    local kern=$(uname -r)
    local cpu_mod=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
    [ -z "$cpu_mod" ] && cpu_mod=$(lscpu 2>/dev/null | grep "Model name:" | cut -d: -f2 | xargs || uname -m)
    local cores=$(nproc 2>/dev/null || echo 1)
    local up_txt=$(uptime -p 2>/dev/null || uptime)
    local bbr_st=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
    local ip_pub=$(obtener_ip)
    echo -e "${C_NEON}┌──────────── FICHA TÉCNICA DEL SERVIDOR VPS ──────────┐${C_RESET}"
    echo -e "  ${C_CYAN}Dirección IPv4   :${C_RESET} ${C_WHITE}$ip_pub${C_RESET}"
    echo -e "  ${C_CYAN}Sistema Operativo:${C_RESET} ${C_WHITE}$os_name${C_RESET}"
    echo -e "  ${C_CYAN}Versión Kernel   :${C_RESET} ${C_WHITE}$kern ($(uname -m))${C_RESET}"
    echo -e "  ${C_CYAN}Procesador (CPU) :${C_RESET} ${C_WHITE}$cpu_mod ($cores núcleos)${C_RESET}"
    echo -e "  ${C_CYAN}Tiempo Encendido :${C_RESET} ${C_GREEN}$up_txt${C_RESET}"
    echo -e "  ${C_CYAN}Control TCP      :${C_RESET} ${C_YELLOW}$bbr_st${C_RESET}"
    echo -e "  ${C_CYAN}Versión Panel    :${C_RESET} ${C_NEON}BLUE COMPANY ${EDICION_SCRIPT}${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

# ==============================================================================
# CATEGORÍA 4: HERRAMIENTAS, REPARACIÓN Y MÓDULOS BASE
# ==============================================================================
reparacion_inteligente_vps() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌───── DIAGNÓSTICO Y REPARACIÓN INTELIGENTE (SAFE) ────┐${C_RESET}"
    echo -e "  ${C_CYAN}[*] Escaneando el sistema en modo lectura (Sin tocar conexiones)...${C_RESET}\n"
    local problemas=() codigos=()
    pgrep -x "dropbear" &>/dev/null || { problemas+=("El servicio Dropbear (Puerto 2222) está detenido."); codigos+=("START_DROPBEAR"); }
    systemctl is-active --quiet despachador 2>/dev/null || pgrep -f "despachador.py" &>/dev/null || { problemas+=("El Despachador Multiplexor WS (Puerto 80) está detenido."); codigos+=("START_DESPACHADOR"); }
    pgrep -f "badvpn-udpgw" &>/dev/null || { problemas+=("El servicio BadVPN UDPGW (Puerto 7300) está detenido."); codigos+=("START_BADVPN"); }
    systemctl is-active --quiet blue-limiter 2>/dev/null || pgrep -f "blue-limiter.py" &>/dev/null || { problemas+=("El demonio Auto-Limitador 24/7 (blue-limiter) está detenido."); codigos+=("START_LIMITER"); }
    
    local proc_80=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:80$/ {print $6}')
    [ -n "$proc_80" ] && ! echo "$proc_80" | grep -q "python3" && { problemas+=("Conflicto en puerto 80 detectado (Ocupado por: $proc_80)."); codigos+=("CONFLICTO_P80"); }
    
    iptables -t nat -C PREROUTING -p tcp -m multiport --dports 8080,8880 -j REDIRECT --to-ports 80 2>/dev/null || { problemas+=("Falta regla NAT iptables para redirigir puertos 8080 y 8880 hacia el puerto 80."); codigos+=("FIX_NAT_8080"); }
    
    if ! grep -qxF "/bin/false" /etc/shells 2>/dev/null || grep -qxF "/bin/expired" /etc/shells 2>/dev/null; then
        problemas+=("Anomalía en /etc/shells (/bin/false ausente o /bin/expired presente).")
        codigos+=("FIX_SHELLS")
    fi
    
    local perm_db=$(stat -c "%a" "$DB_LIMITS" 2>/dev/null || echo "644")
    [ "$perm_db" != "600" ] && { problemas+=("Permisos inseguros ($perm_db) en base de datos $DB_LIMITS (Recomendado: 600)."); codigos+=("FIX_PERMS"); }

    if [ "${#problemas[@]}" -eq 0 ]; then
        echo -e "  ${C_GREEN}[✓] ¡Diagnóstico completado! No se detectaron fallos, conflictos ni errores de configuración.${C_RESET}"
        echo -e "  ${C_GRAY}Todos los servicios administrados y reglas de red operan correctamente.${C_RESET}"
        read -r -p "  Presiona Enter para volver..."; return
    fi
    
    echo -e "  ${C_YELLOW}Se detectaron ${#problemas[@]} anomalías en el servidor:${C_RESET}"
    local i=0
    for p in "${problemas[@]}"; do i=$(( i + 1 )); echo -e "   ${C_RED}[$i]${C_RESET} $p"; done
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}Reparación propuesta:${C_RESET} Corregir únicamente los componentes afectados sin"
    echo -e "  reiniciar servicios activos ni desconectar a los clientes conectados."
    read -r -p "  ¿Confirmas aplicar las reparaciones propuestas ahora? (s/n): " conf_fix
    if [[ ! "$conf_fix" =~ ^[sS]$ ]]; then
        echo -e "\n${C_YELLOW}[!] Reparación cancelada. No se realizaron modificaciones.${C_RESET}"
        read -r -p "  Presiona Enter para volver..."; return
    fi
    
    for cod in "${codigos[@]}"; do
        case "$cod" in
            START_DROPBEAR) [ -f /etc/systemd/system/dropbear.service ] && systemctl start dropbear 2>/dev/null || instalar_dropbear_auto "1"; echo -e "  ${C_GREEN}[✓] Servicio Dropbear (2222) iniciado.${C_RESET}" ;;
            START_DESPACHADOR) [ -f /etc/systemd/system/despachador.service ] && systemctl start despachador 2>/dev/null || instalar_despachador_auto "1"; echo -e "  ${C_GREEN}[✓] Servicio Despachador WS (80) iniciado.${C_RESET}" ;;
            START_BADVPN) [ -f /etc/systemd/system/badvpn.service ] && systemctl start badvpn 2>/dev/null || instalar_badvpn_auto "1"; echo -e "  ${C_GREEN}[✓] Servicio BadVPN (7300) iniciado.${C_RESET}" ;;
            START_LIMITER) instalar_limitador_auto "1"; echo -e "  ${C_GREEN}[✓] Demonio Auto-Limitador 24/7 iniciado.${C_RESET}" ;;
            CONFLICTO_P80) echo -e "  ${C_YELLOW}[!] Nota: El puerto 80 está en uso por un servicio externo ($proc_80).${C_RESET}\n  ${C_GRAY}Por seguridad corporativa no se mató el proceso externo automáticamente.${C_RESET}" ;;
            FIX_NAT_8080) iptables -t nat -A PREROUTING -p tcp -m multiport --dports 8080,8880 -j REDIRECT --to-ports 80 2>/dev/null; echo -e "  ${C_GREEN}[✓] Regla NAT PREROUTING (8080,8880 -> 80) restaurada.${C_RESET}" ;;
            FIX_SHELLS) for sh_path in "/bin/false" "/usr/sbin/nologin"; do [ -f "$sh_path" ] && ! grep -qxF "$sh_path" /etc/shells 2>/dev/null && echo "$sh_path" >> /etc/shells; done; sed -i '\|/bin/expired|d' /etc/shells 2>/dev/null; echo -e "  ${C_GREEN}[✓] Archivo /etc/shells corregido.${C_RESET}" ;;
            FIX_PERMS) chmod 600 "$DB_LIMITS" "$BLOCKED_USERS_DB" "$LOCKS_LOG" "$AUDIT_LOG" 2>/dev/null; echo -e "  ${C_GREEN}[✓] Permisos 600 restaurados en archivos sensibles.${C_RESET}" ;;
        esac
    done
    registrar_accion_admin "REPARACION_INTELIGENTE" "ItemsReparados=${#codigos[@]}"
    read -r -p "  Presiona Enter para volver..."
}

# INSTALADORES DE COMPONENTES (Conservados y Protegidos)
instalar_dropbear_auto() {
    local silencioso="$1"
    [ "$silencioso" != "1" ] && mostrar_pantalla_encabezado && echo -e "${C_NEON}┌────── INSTALADOR CORPORATIVO DROPBEAR (2222) ────────┐${C_RESET}"
    echo -e "  ${C_CYAN}[*] Configurando entorno Dropbear en puerto 2222...${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    command -v dropbear &>/dev/null || { dpkg --configure -a &>/dev/null; apt-get update -y &>/dev/null; apt-get install -y dropbear-bin psmisc &>/dev/null; }
    mkdir -p /etc/dropbear
    cat << 'DBCONF' > /etc/default/dropbear
NO_START=0
DROPBEAR_PORT=2222
DROPBEAR_EXTRA_ARGS="-W 65536 -K 15 -I 60"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
DBCONF
    for sh_path in "/bin/false" "/usr/sbin/nologin"; do grep -qxF "$sh_path" /etc/shells 2>/dev/null || echo "$sh_path" >> /etc/shells; done
    sed -i '\|/bin/expired|d' /etc/shells 2>/dev/null
    for k in /etc/dropbear/dropbear_*_host_key; do [ -f "$k" ] && [ ! -s "$k" ] && rm -f "$k"; done
    [ ! -s /etc/dropbear/dropbear_rsa_host_key ] && dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key &>/dev/null
    [ ! -s /etc/dropbear/dropbear_ecdsa_host_key ] && dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key &>/dev/null
    [ ! -s /etc/dropbear/dropbear_ed25519_host_key ] && dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key &>/dev/null
    [ -f /etc/init.d/dropbear ] && chmod -x /etc/init.d/dropbear 2>/dev/null
    local DROPBEAR_BIN=$(command -v dropbear || echo "/usr/sbin/dropbear")
    cat << DBSRV > /etc/systemd/system/dropbear.service
[Unit]
Description=Dropbear SSH Server (Puerto 2222 - BLUE COMPANY)
After=network.target
[Service]
Type=simple
ExecStart=${DROPBEAR_BIN} -EF -R -p 2222 -W 65536 -K 15 -I 60
KillMode=process
Restart=always
RestartSec=1
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
DBSRV
    systemctl daemon-reload; systemctl enable dropbear &>/dev/null
    pgrep -x "dropbear" &>/dev/null && systemctl restart dropbear &>/dev/null || systemctl start dropbear &>/dev/null
    sleep 0.5
    pgrep -x "dropbear" &>/dev/null && echo -e "  ${C_GREEN}[✓] Dropbear 2222 activo (Handshake ligero y KillMode=process).${C_RESET}" || echo -e "  ${C_RED}[!] Error al iniciar Dropbear en puerto 2222.${C_RESET}"
    [ "$silencioso" != "1" ] && read -r -p "  Presiona Enter para volver al panel..."
}

instalar_despachador_auto() {
    local silencioso="$1"
    [ "$silencioso" != "1" ] && mostrar_pantalla_encabezado && echo -e "${C_NEON}┌───── INSTALADOR DESPACHADOR MULTIPLEXOR (80) ────────┐${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    for dep_bin in python3 fuser iptables; do command -v "$dep_bin" &>/dev/null || { apt-get update -y &>/dev/null; apt-get install -y python3 psmisc iptables &>/dev/null; break; }; done
    cat << 'PY_EOF' > /usr/local/bin/despachador.py
#!/usr/bin/env python3
import socket, select, threading, random
LISTEN_HOST, LISTEN_PORT, SSH_PORT = "0.0.0.0", 80, 2222
PORT_WS, PORT_UPGRADE, PORT_XHTTP, BUF_SIZE = 20001, 20002, 20003, 32768
def optimizar_socket(sock, timeout=None):
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        if timeout is not None: sock.settimeout(timeout)
    except Exception: pass
def conectar_dropbear_aislado():
    ssh = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    optimizar_socket(ssh, timeout=10)
    try: ssh.bind((f"127.{random.randint(0, 254)}.{random.randint(0, 254)}.{random.randint(2, 254)}", 0))
    except Exception: pass
    ssh.connect(("127.0.0.1", SSH_PORT)); ssh.settimeout(None); return ssh
def cerrar_par(s1, s2):
    for s in (s1, s2):
        if s is None: continue
        try: s.shutdown(socket.SHUT_RDWR)
        except Exception: pass
        try: s.close()
        except Exception: pass
def pipe_directo(src, dst):
    try:
        while True:
            data = src.recv(BUF_SIZE)
            if not data: break
            dst.sendall(data)
    except Exception: pass
    finally: cerrar_par(src, dst)
def pipe_cliente_a_ssh(client, ssh, ssh_iniciado=False):
    acumulado = b""
    try:
        if not ssh_iniciado:
            client.settimeout(12)
            while True:
                data = client.recv(BUF_SIZE)
                if not data: break
                if ssh_iniciado: ssh.sendall(data)
                else:
                    acumulado += data
                    if b"SSH-2.0-" in acumulado:
                        idx = acumulado.find(b"SSH-2.0-")
                        ssh_iniciado = True; client.settimeout(None)
                        ssh.sendall(acumulado[idx:]); acumulado = b""
                    elif len(acumulado) > 65536: acumulado = b""
    except Exception: pass
    finally: cerrar_par(client, ssh)
def extraer_ruta_http(buffer):
    try:
        primera_linea = buffer.split(b"\r\n", 1)[0].decode("latin1", errors="ignore")
        partes = primera_linea.split(" ")
        if len(partes) >= 2: return partes[1].lower()
    except Exception: pass
    return ""
def procesar_conexion(client, addr):
    ssh = None
    try:
        optimizar_socket(client, timeout=12)
        buffer = client.recv(BUF_SIZE)
        if not buffer: client.close(); return
        if buffer.startswith(b"SSH-"):
            ssh = conectar_dropbear_aislado(); client.settimeout(None); ssh.sendall(buffer)
            threading.Thread(target=pipe_cliente_a_ssh, args=(client, ssh, True), daemon=True).start()
            pipe_directo(ssh, client); return
        ruta = extraer_ruta_http(buffer); target_port = None
        if ruta.startswith("/ws"): target_port = PORT_WS
        elif ruta.startswith("/upgrade"): target_port = PORT_UPGRADE
        elif ruta.startswith("/xhttp"): target_port = PORT_XHTTP
        if target_port:
            try:
                remote = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                optimizar_socket(remote, timeout=4); remote.connect(("127.0.0.1", target_port))
                remote.settimeout(None); client.settimeout(None); remote.sendall(buffer)
                threading.Thread(target=pipe_directo, args=(client, remote), daemon=True).start()
                pipe_directo(remote, client); return
            except Exception:
                try: remote.close()
                except Exception: pass
        for _ in range(5):
            if b"SSH-2.0-" in buffer: break
            espera = 0.08 if buffer.endswith(b"\r\n\r\n") else 0.45
            rlist, _, _ = select.select([client], [], [], espera)
            if not rlist: break
            extra = client.recv(BUF_SIZE)
            if not extra: break
            buffer += extra
        client.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        ssh = conectar_dropbear_aislado(); ya_inicio_ssh = False
        if b"SSH-2.0-" in buffer:
            idx = buffer.find(b"SSH-2.0-"); ya_inicio_ssh = True; client.settimeout(None); ssh.sendall(buffer[idx:])
        threading.Thread(target=pipe_cliente_a_ssh, args=(client, ssh, ya_inicio_ssh), daemon=True).start()
        pipe_directo(ssh, client)
    except Exception: cerrar_par(client, ssh)
def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); optimizar_socket(server)
    server.bind((LISTEN_HOST, LISTEN_PORT)); server.listen(4096)
    while True:
        try:
            client, addr = server.accept()
            threading.Thread(target=procesar_conexion, args=(client, addr), daemon=True).start()
        except Exception: pass
if __name__ == "__main__": main()
PY_EOF
    chmod +x /usr/local/bin/despachador.py
    cat << 'SRV_EOF' > /etc/systemd/system/despachador.service
[Unit]
Description=Despachador Multiplexor Puerto 80/8080/8880 (BLUE COMPANY)
After=network.target
[Service]
Type=simple
User=root
Environment="PYTHONUNBUFFERED=1"
ExecStartPre=-/bin/sh -c 'iptables -t nat -C PREROUTING -p tcp -m multiport --dports 8080,8880 -j REDIRECT --to-ports 80 2>/dev/null || iptables -t nat -A PREROUTING -p tcp -m multiport --dports 8080,8880 -j REDIRECT --to-ports 80 2>/dev/null'
ExecStart=/usr/bin/python3 /usr/local/bin/despachador.py
Restart=always
RestartSec=1
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SRV_EOF
    systemctl daemon-reload; systemctl enable despachador &>/dev/null
    systemctl is-active --quiet despachador && systemctl restart despachador &>/dev/null || systemctl start despachador &>/dev/null
    sleep 0.5
    systemctl is-active --quiet despachador && echo -e "  ${C_GREEN}[✓] Despachador WS activo en puertos 80, 8080 y 8880.${C_RESET}" || echo -e "  ${C_RED}[!] Error al iniciar puerto 80. Verifica posibles conflictos en Diagnóstico.${C_RESET}"
    [ "$silencioso" != "1" ] && read -r -p "  Presiona Enter para volver al panel..."
}

instalar_limitador_auto() {
    local silencioso="$1"
    [ "$silencioso" != "1" ] && mostrar_pantalla_encabezado && echo -e "${C_NEON}┌─── DEMONIO AUTO-LIMITADOR INTELIGENTE 24/7 (v9.1) ───┐${C_RESET}"
    cat << 'LIM_EOF' > /usr/local/bin/blue-limiter.py
#!/usr/bin/env python3
import os, re, time, fcntl, signal, subprocess
from datetime import datetime
DB_LIMITS, CACHE_FILE, LOCK_FILE = "/etc/ssh-limits.txt", "/run/blue-dropbear.map", "/run/blue-limiter-daemon.lock"
LOCKS_LOG, BLOCKED_USERS_DB = "/var/log/bluecompany/locks.log", "/etc/bluecompany/blocked_users.db"
pid_memory = {}
def registrar_evento_bloqueo(u, motivo):
    os.makedirs("/var/log/bluecompany", exist_ok=True); os.makedirs("/etc/bluecompany", exist_ok=True)
    ahora_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        with open(LOCKS_LOG, "a") as lf: lf.write(f"{ahora_str}|{u}|{motivo}\n")
        lineas = []
        if os.path.exists(BLOCKED_USERS_DB):
            with open(BLOCKED_USERS_DB, "r", errors="ignore") as bf: lineas = [l for l in bf if not l.startswith(f"{u}|")]
        lineas.append(f"{u}|{ahora_str}|{motivo}\n")
        with open(BLOCKED_USERS_DB, "w") as bf: bf.writelines(lineas)
    except Exception: pass
def leer_base_usuarios():
    usuarios = {}
    if not os.path.exists(DB_LIMITS): return usuarios
    try:
        with open(DB_LIMITS, "r", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or ":" not in line: continue
                parts = line.split(":"); u = parts[0].strip()
                if not u: continue
                try: lim = int(parts[1]); if lim <= 0: lim = 1
                except Exception: lim = 1
                exp_epoch = 0
                if len(parts) >= 4 and parts[3].strip().isdigit(): exp_epoch = int(parts[3].strip())
                est_manual = "ACTIVO"
                if len(parts) >= 5 and parts[4].strip(): est_manual = parts[4].strip()
                usuarios[u] = (lim, exp_epoch, est_manual)
    except Exception: pass
    return usuarios
def obtener_procesos():
    dropbear_pids, sshd_por_usuario, uid_map = {}, {}, {}
    try:
        with open("/etc/passwd", "r", errors="ignore") as pf:
            for line in pf:
                p = line.strip().split(":")
                if len(p) >= 3: uid_map[p[2]] = p[0]
    except Exception: pass
    for entry in os.listdir("/proc"):
        if not entry.isdigit(): continue
        try:
            with open(f"/proc/{entry}/comm", "r") as f: comm = f.read().strip().lower()
            with open(f"/proc/{entry}/stat", "r") as f: stat_after = f.read().rsplit(")", 1)[-1].split()
            ppid, starttime = int(stat_after[1]), int(stat_after[19])
            if "dropbear" in comm and ppid > 1: dropbear_pids[entry] = starttime
            elif comm.startswith("sshd") and ppid > 1:
                usr_detectado = None
                with open(f"/proc/{entry}/status", "r") as sf:
                    for sline in sf:
                        if sline.startswith("Uid:"):
                            real_uid = sline.split()[1]
                            if real_uid != "0" and real_uid in uid_map: usr_detectado = uid_map[real_uid]; break
                if not usr_detectado:
                    with open(f"/proc/{entry}/cmdline", "rb") as cf:
                        cmd = cf.read().replace(b"\x00", b" ").decode("latin1", errors="ignore")
                        m = re.search(r"sshd(?:-session)?:\s+([a-zA-Z0-9_-]+)(?:@|\[notty\]|$)", cmd)
                        if m and m.group(1) != "root": usr_detectado = m.group(1)
                if usr_detectado: sshd_por_usuario.setdefault(usr_detectado, []).append((starttime, int(entry)))
        except Exception: continue
    return dropbear_pids, sshd_por_usuario
def actualizar_mapa_dropbear(dropbear_pids, users):
    global pid_memory
    activos = {(pid, st) for pid, st in dropbear_pids.items()}
    pid_memory = {k: v for k, v in pid_memory.items() if k in activos}
    faltantes = [pid for pid, st in dropbear_pids.items() if (pid, st) not in pid_memory]
    if faltantes:
        log_text = ""
        for lf in ["/var/log/auth.log", "/var/log/syslog", "/var/log/secure"]:
            if os.path.exists(lf):
                try:
                    with open(lf, "r", errors="ignore") as f:
                        f.seek(0, os.SEEK_END); sz = f.tell(); f.seek(max(0, sz - 200000)); log_text += f.read() + "\n"
                except Exception: pass
        try: log_text += subprocess.check_output(["journalctl", "-u", "dropbear", "--no-pager", "-n", "600"], stderr=subprocess.DEVNULL).decode(errors="ignore")
        except Exception: pass
        pat = re.compile(r"dropbear\[(\d+)\]:.*succeeded for ['\"]?([^'\"\s]+)['\"]?", re.IGNORECASE)
        for m in pat.finditer(log_text):
            if m.group(1) in dropbear_pids: pid_memory[(m.group(1), dropbear_pids[m.group(1)])] = m.group(2)
        users_sorted = sorted(users, key=len, reverse=True)
        for pid in faltantes:
            st = dropbear_pids.get(pid)
            if (pid, st) in pid_memory: continue
            try:
                with open(f"/proc/{pid}/maps", "r") as mf, open(f"/proc/{pid}/mem", "rb", 0) as mem:
                    for line in mf:
                        if "rw-p" not in line: continue
                        parts = line.split()[0].split("-"); start, end = int(parts[0], 16), int(parts[1], 16)
                        if end - start > 8 * 1024 * 1024: continue
                        mem.seek(start); chunk = mem.read(end - start)
                        for u in users_sorted:
                            ub = re.escape(u.encode())
                            if re.search(rb"/home/" + ub + rb"\x00(?!/)", chunk) or (b"succeeded for '" + u.encode() + b"'" in chunk):
                                pid_memory[(pid, st)] = u; break
                        if (pid, st) in pid_memory: break
            except Exception: pass
        try:
            with open(CACHE_FILE + ".tmp", "w") as cf:
                for (pid, _), usr in pid_memory.items(): cf.write(f"{pid}:{usr}\n")
            os.replace(CACHE_FILE + ".tmp", CACHE_FILE)
        except Exception: pass
    db_por_usuario = {}
    for (pid, st), usr in pid_memory.items(): db_por_usuario.setdefault(usr, []).append((st, int(pid)))
    return db_por_usuario
def bloquear_usuario_individual(u, sesiones, motivo):
    for _, pid in sesiones:
        try:
            if pid > 1: os.kill(pid, signal.SIGKILL)
        except Exception: pass
    subprocess.run(["pkill", "-KILL", "-u", u], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    subprocess.run(["usermod", "-L", "-s", "/bin/expired", "-e", "1970-01-02", u], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    subprocess.run(["passwd", "-l", u], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    registrar_evento_bloqueo(u, motivo)
def ciclo_control():
    usuarios = leer_base_usuarios()
    if not usuarios: return
    dropbear_pids, sshd_por_usuario = obtener_procesos()
    db_por_usuario = actualizar_mapa_dropbear(dropbear_pids, list(usuarios.keys()))
    ahora = int(time.time()); hoy_dias = ahora // 86400
    for u, (lim, exp_epoch, est_manual) in usuarios.items():
        if u == "root": continue
        sesiones = sshd_por_usuario.get(u, []) + db_por_usuario.get(u, [])
        bloqueado, motivo = False, ""
        if est_manual == "SUSPENDIDO": bloqueado, motivo = True, "SUSPENSIÓN ADMINISTRATIVA"
        elif est_manual == "BLOQUEADO_LIMITE": bloqueado, motivo = True, "BLOQUEADO POR EXCESO DE LÍMITE"
        elif exp_epoch > 0 and ahora >= exp_epoch: bloqueado, motivo = True, "CUENTA EXPIRADA POR TIEMPO"
        if bloqueado:
            # Verificar si ya está bloqueado para evitar reinicios innecesarios
            try:
                with open("/etc/passwd", "r") as pf:
                    for line in pf:
                        if line.startswith(f"{u}:"):
                            if "/bin/expired" in line: bloqueado = False # Ya está bloqueado
                            break
            except Exception: pass
            if bloqueado: bloquear_usuario_individual(u, sesiones, motivo)
            continue
        if len(sesiones) > lim:
            sesiones.sort(key=lambda x: x[0]); excedentes = sesiones[lim:]
            for _, pid in excedentes:
                try:
                    if pid > 1: os.kill(pid, signal.SIGKILL)
                except Exception: pass
            registrar_evento_bloqueo(u, f"EXCESO DE LÍMITE CORREGIDO ({len(sesiones)}/{lim} sesiones)")
def main():
    lock_fd = open(LOCK_FILE, "w")
    try: fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except IOError: return
    while True:
        try: ciclo_control()
        except Exception: pass
        time.sleep(3)
if __name__ == "__main__": main()
LIM_EOF
    chmod +x /usr/local/bin/blue-limiter.py
    cat << 'LSRV_EOF' > /etc/systemd/system/blue-limiter.service
[Unit]
Description=Demonio Auto-Limitador y Bloqueo Individual 24/7 (BLUE COMPANY v9.1)
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/blue-limiter.py
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
LSRV_EOF
    systemctl daemon-reload; systemctl reset-failed blue-limiter &>/dev/null; systemctl enable blue-limiter &>/dev/null; systemctl restart blue-limiter &>/dev/null
    sleep 0.4
    systemctl is-active --quiet blue-limiter && echo -e "  ${C_GREEN}[✓] Auto-Limitador 24/7 activo.${C_RESET}" || echo -e "  ${C_RED}[!] No se pudo iniciar blue-limiter.service.${C_RESET}"
    [ "$silencioso" != "1" ] && read -r -p "  Presiona Enter para volver al panel..."
}

instalar_badvpn_auto() {
    local silencioso="$1"
    [ "$silencioso" != "1" ] && mostrar_pantalla_encabezado && echo -e "${C_NEON}┌───── INSTALADOR BADVPN UDPGW (PUERTO 7300) ──────────┐${C_RESET}"
    if [ ! -x /usr/local/bin/badvpn-udpgw ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y &>/dev/null; apt-get install -y cmake make gcc git curl psmisc &>/dev/null
        rm -rf /tmp/badvpn-build
        if git clone --depth 1 https://github.com/ambrop72/badvpn.git /tmp/badvpn-build &>/dev/null; then
            sed -i 's/cmake_minimum_required.*/cmake_minimum_required(VERSION 3.5)/g' /tmp/badvpn-build/CMakeLists.txt 2>/dev/null
            mkdir -p /tmp/badvpn-build/build; cd /tmp/badvpn-build/build || return
            cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 &>/dev/null
            make -j"$(nproc)" &>/dev/null
            [ -f /tmp/badvpn-build/build/udpgw/badvpn-udpgw ] && cp -f /tmp/badvpn-build/build/udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw && chmod +x /usr/local/bin/badvpn-udpgw
            cd /root || cd /; rm -rf /tmp/badvpn-build
        fi
    fi
    if [ ! -x /usr/local/bin/badvpn-udpgw ] && [ "$(uname -m)" = "x86_64" ]; then
        curl -sL "https://raw.githubusercontent.com/daybreakersx/premscript/master/badvpn-udpgw64" -o /usr/local/bin/badvpn-udpgw; chmod +x /usr/local/bin/badvpn-udpgw
    fi
    cat << 'BVEOF' > /etc/systemd/system/badvpn.service
[Unit]
Description=BadVPN UDPGW Server Puerto 7300 (BLUE COMPANY)
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 100 --client-socket-sndbuf 1048576
Restart=always
RestartSec=2
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
BVEOF
    systemctl daemon-reload; systemctl enable badvpn &>/dev/null; systemctl restart badvpn &>/dev/null
    sleep 0.5
    pgrep -f "badvpn-udpgw" &>/dev/null && echo -e "  ${C_GREEN}[✓] BadVPN UDPGW activo en puerto 7300.${C_RESET}" || echo -e "  ${C_RED}[!] Error al iniciar BadVPN 7300.${C_RESET}"
    [ "$silencioso" != "1" ] && read -r -p "  Presiona Enter para volver al panel..."
}

optimizar_tcp_sin_retraso() {
    local silencioso="$1"
    [ "$silencioso" != "1" ] && mostrar_pantalla_encabezado && echo -e "${C_NEON}┌───── OPTIMIZACIÓN DE RED SIN RETRASO (BBR) ──────────┐${C_RESET}"
    modprobe tcp_bbr 2>/dev/null; modprobe sch_fq 2>/dev/null
    cat << 'SYSEOF' > /etc/sysctl.d/99-bluecompany-tcp.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 32768
SYSEOF
    sysctl --system &>/dev/null
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i '/^#*UseDNS/d' /etc/ssh/sshd_config; sed -i '/^#*TCPKeepAlive/d' /etc/ssh/sshd_config; sed -i '/^#*Banner /d' /etc/ssh/sshd_config
        echo "UseDNS no" >> /etc/ssh/sshd_config; echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
    fi
    local iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    [ -n "$iface" ] && ip link set dev "$iface" txqueuelen 5000 2>/dev/null
    echo -e "  ${C_GREEN}[✓] Optimización TCP BBR + LowLatency aplicada.${C_RESET}"
    [ "$silencioso" != "1" ] && read -r -p "  Presiona Enter para volver al panel..."
}

instalacion_completa_vps() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌───── DESPLIEGUE CORPORATIVO 1-CLICK (VPS NUEVA) ─────┐${C_RESET}"
    echo -e "  ${C_YELLOW}[!] Esta opción despliega todos los servicios base de BLUE COMPANY.${C_RESET}"
    read -r -p "  ¿Confirmas ejecutar el despliegue de componentes? (s/n): " conf_dep
    [[ ! "$conf_dep" =~ ^[sS]$ ]] && return
    optimizar_tcp_sin_retraso "1"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    instalar_dropbear_auto "1"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    instalar_despachador_auto "1"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    instalar_limitador_auto "1"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    instalar_badvpn_auto "1"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_GREEN}[✓] ¡Infraestructura BLUE COMPANY ${EDICION_SCRIPT} desplegada al 100%!${C_RESET}"
    read -r -p "  Presiona Enter para volver al panel..."
}

informacion_version_y_modulos() {
    mostrar_pantalla_encabezado
    local v_rem=$(curl -sL --max-time 3 "$GITHUB_VERSION_URL" 2>/dev/null | tr -d '[:space:]')
    echo -e "${C_NEON}┌────── INFORMACIÓN DE VERSIÓN Y MÓDULOS BASE ─────────┐${C_RESET}"
    echo -e "  ${C_CYAN}Nombre del Sistema:${C_RESET} ${C_WHITE}BLUE COMPANY • CLOUD NETWORK MANAGER${C_RESET}"
    echo -e "  ${C_CYAN}Edición Instalada :${C_RESET} ${C_GREEN}${EDICION_SCRIPT}${C_RESET}"
    echo -e "  ${C_CYAN}Versión en GitHub :${C_RESET} ${C_YELLOW}v${v_rem}${C_RESET}"
    echo -e "  ${C_CYAN}Repositorio       :${C_RESET} ${C_GRAY}${GITHUB_REPO_URL}${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}Instaladores Individuales de Infraestructura:${C_RESET}"
    echo -e "  ${C_WHITE}[1]${C_RESET} Instalar / Reconfigurar Dropbear (Puerto 2222)"
    echo -e "  ${C_WHITE}[2]${C_RESET} Instalar / Reconfigurar Despachador WS (P:80/8080/8880)"
    echo -e "  ${C_WHITE}[3]${C_RESET} Instalar / Reconfigurar BadVPN UDPGW (Puerto 7300)"
    echo -e "  ${C_WHITE}[4]${C_RESET} Aplicar Perfil Kernel TCP BBR + LowLatency"
    echo -e "  ${C_WHITE}[5]${C_RESET} Despliegue Completo 1-Click (Para VPS recién instalada)"
    echo -e "  ${C_GRAY}[0] Volver al menú principal${C_RESET}"
    read -r -p "  ► Opción: " op_iv
    case "$op_iv" in
        1) instalar_dropbear_auto ;;
        2) instalar_despachador_auto ;;
        3) instalar_badvpn_auto ;;
        4) optimizar_tcp_sin_retraso ;;
        5) instalacion_completa_vps ;;
        *) return ;;
    esac
}

# ==============================================================================
# MENÚ PRINCIPAL ORGANIZADO EN 4 CATEGORÍAS CORPORATIVAS (ENTERPRISE v9.1)
# ==============================================================================
while true; do
    mostrar_pantalla_encabezado
    echo -e "  ${C_CYAN}━━ 1. GESTIÓN COMERCIAL ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "  ${C_NEON}[01]${C_RESET} ${C_WHITE}Crear usuarios (Cliente o Demo 1-Click)${C_RESET}"
    echo -e "  ${C_NEON}[02]${C_RESET} ${C_WHITE}Modificar usuarios (Contraseña, Límite o Renovar)${C_RESET}"
    echo -e "  ${C_NEON}[03]${C_RESET} ${C_WHITE}Eliminar usuarios (Individual o Purgar vencidos)${C_RESET}"
    echo -e "  ${C_NEON}[04]${C_RESET} ${C_WHITE}Bloquear y desbloquear (Suspender / Reintegrar)${C_RESET}"
    echo -e "  ${C_NEON}[05]${C_RESET} ${C_WHITE}Consultar vencimientos y Ficha / Ticket${C_RESET}"
    echo -e "  ${C_NEON}[06]${C_RESET} ${C_WHITE}Consultar límites de conexiones${C_RESET}"
    echo -e ""
    echo -e "  ${C_CYAN}━━ 2. MONITOREO Y SEGURIDAD ━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "  ${C_NEON}[07]${C_RESET} ${C_GREEN}Usuarios conectados (Monitor en Tiempo Real)${C_RESET}"
    echo -e "  ${C_NEON}[08]${C_RESET} ${C_WHITE}Monitor de consumo por usuario${C_RESET}"
    echo -e "  ${C_NEON}[09]${C_RESET} ${C_WHITE}Bloqueos automáticos (Auto-Limitador y Reintegro)${C_RESET}"
    echo -e "  ${C_NEON}[10]${C_RESET} ${C_WHITE}Historial (Bloqueos, motivos y auditoría)${C_RESET}"
    echo -e "  ${C_NEON}[11]${C_RESET} ${C_WHITE}Centro de Seguridad y Estado del Servidor (Consulta)${C_RESET}"
    echo -e ""
    echo -e "  ${C_CYAN}━━ 3. INFRAESTRUCTURA ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "  ${C_NEON}[12]${C_RESET} ${C_WHITE}Estado de servicios (BLUE COMPANY vs Externos)${C_RESET}"
    echo -e "  ${C_NEON}[13]${C_RESET} ${C_WHITE}Puertos en escucha y redirecciones NAT${C_RESET}"
    echo -e "  ${C_NEON}[14]${C_RESET} ${C_WHITE}CPU, RAM, Carga y Procesos activos${C_RESET}"
    echo -e "  ${C_NEON}[15]${C_RESET} ${C_WHITE}Diagnóstico del VPS (Disco, Red y Salud)${C_RESET}"
    echo -e "  ${C_NEON}[16]${C_RESET} ${C_WHITE}Información técnica del VPS${C_RESET}"
    echo -e ""
    echo -e "  ${C_CYAN}━━ 4. HERRAMIENTAS Y MANTENIMIENTO ━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "  ${C_NEON}[17]${C_RESET} ${C_YELLOW}Actualización desde GitHub (Validación estricta)${C_RESET}"
    echo -e "  ${C_NEON}[18]${C_RESET} ${C_WHITE}Reparación inteligente (Sin corte de túneles)${C_RESET}"
    echo -e "  ${C_NEON}[19]${C_RESET} ${C_WHITE}Información de versión y Módulos base${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_RED}[00]${C_RESET} ${C_GRAY}Salir del Panel${C_RESET}"
    echo -e "${C_BLUE}════════════════════════════════════════════════════════${C_RESET}"
    read -r -p "  ► Selecciona una opción [0-19]: " opcion
    case "$opcion" in
        1|01) crear_usuario ;;
        2|02) modificar_usuario ;;
        3|03) eliminar_usuario ;;
        4|04) controlar_acceso_usuario ;;
        5|05) consultar_vencimientos ;;
        6|06) consultar_limites_clientes ;;
        7|07) listar_usuarios_en_vivo ;;
        8|08) monitor_consumo_usuarios ;;
        9|09) gestion_bloqueos_automaticos ;;
        10) consultar_historial_sistema ;;
        11) centro_seguridad_estado ;;
        12) estado_servicios_diferenciado ;;
        13) puertos_en_escucha_vps ;;
        14) monitor_cpu_ram_procesos ;;
        15) diagnostico_integral_vps ;;
        16) informacion_ficha_vps ;;
        17) actualizar_desde_github ;;
        18) reparacion_inteligente_vps ;;
        19) informacion_version_y_modulos ;;
        0|00) flock -u 9 2>/dev/null; clear; exit 0 ;;
        *) echo -e "\n${C_RED}[!] Opción no válida.${C_RESET}"; sleep 1 ;;
    esac
done
