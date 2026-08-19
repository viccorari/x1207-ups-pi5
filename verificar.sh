#!/usr/bin/env bash
# Verificacion de la instalacion del UPS HAT X1207 en un Raspberry Pi 5.
#
#   ./verificar.sh          comprobaciones automaticas (no toca nada)
#   ./verificar.sh --test   ademas, prueba real de corte de corriente
#
# Devuelve 0 si todo esta correcto, 1 si hay algun fallo.
set -uo pipefail

OK=0; FAIL=0; WARN=0
PLD_PIN=6

c_ok()   { printf '  \033[32m[ OK ]\033[0m %s\n' "$1"; OK=$((OK+1)); }
c_bad()  { printf '  \033[31m[FALLA]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
c_warn() { printf '  \033[33m[AVISO]\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
titulo() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# sudo solo si hace falta (permite correrlo como root o como usuario normal)
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

titulo "1. Hardware y sistema"
MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo desconocido)"
if [[ "$MODEL" == *"Raspberry Pi 5"* ]]; then
    c_ok "Modelo: $MODEL"
else
    c_bad "Modelo: $MODEL (el X1207 requiere un Raspberry Pi 5)"
fi
echo "         SO: $(grep -oP '(?<=PRETTY_NAME=").*(?=")' /etc/os-release 2>/dev/null) | kernel $(uname -r)"

titulo "2. Dependencias"
for pkg in python3-smbus2 python3-libgpiod i2c-tools; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        c_ok "Paquete $pkg instalado"
    else
        c_bad "Falta el paquete $pkg  (sudo apt install $pkg)"
    fi
done
for mod in smbus2 gpiod; do
    if python3 -c "import $mod" 2>/dev/null; then
        c_ok "Modulo python '$mod' importable"
    else
        c_bad "Modulo python '$mod' NO importable"
    fi
done

titulo "3. I2C y fuel gauge de la bateria"
if grep -q '^dtparam=i2c_arm=on' /boot/firmware/config.txt 2>/dev/null; then
    c_ok "I2C habilitado en /boot/firmware/config.txt"
else
    c_bad "I2C NO habilitado en config.txt (falta dtparam=i2c_arm=on + reiniciar)"
fi
if grep -q '^i2c-dev' /etc/modules 2>/dev/null; then
    c_ok "Modulo i2c-dev en /etc/modules (persiste al reiniciar)"
else
    c_warn "i2c-dev no esta en /etc/modules: podria no cargar tras reiniciar"
fi
if [[ -e /dev/i2c-1 ]]; then
    c_ok "/dev/i2c-1 existe"
    # la salida se captura antes de filtrar: con 'pipefail', un 'grep -q' cierra
    # la tuberia al primer match y mata al productor con SIGPIPE, lo que haria
    # fallar la comprobacion aunque el dispositivo si estuviera presente
    I2C_OUT="$($SUDO i2cdetect -y 1 2>/dev/null)"
    if [[ "$I2C_OUT" == *" 36 "* ]]; then
        c_ok "Fuel gauge detectado en la direccion 0x36"
    else
        c_bad "No responde nada en 0x36 (bateria mal puesta o HAT mal asentado)"
    fi
else
    c_bad "/dev/i2c-1 no existe (I2C sin habilitar, o falta reiniciar)"
fi

titulo "4. POWER_OFF_ON_HALT (clave para el encendido automatico)"
EEPROM_OUT="$($SUDO rpi-eeprom-config 2>/dev/null)"
if [[ "$EEPROM_OUT" == *"POWER_OFF_ON_HALT=1"* ]]; then
    c_ok "POWER_OFF_ON_HALT=1 en la EEPROM"
else
    c_bad "POWER_OFF_ON_HALT NO esta en 1: la Pi quedara en espera al apagarse"
    echo "         (LED rojo encendido) y el HAT nunca la encendera sola."
fi

titulo "5. Software instalado"
if [[ -x /usr/local/bin/x1207ctl.py ]]; then
    c_ok "/usr/local/bin/x1207ctl.py instalado y ejecutable"
else
    c_bad "Falta /usr/local/bin/x1207ctl.py"
fi
if [[ -f /etc/systemd/system/x1207-guardian.service ]]; then
    c_ok "Unidad systemd instalada"
else
    c_bad "Falta /etc/systemd/system/x1207-guardian.service"
fi
if systemctl is-enabled --quiet x1207-guardian 2>/dev/null; then
    c_ok "Servicio habilitado (arranca solo al encender)"
else
    c_bad "Servicio NO habilitado (sudo systemctl enable x1207-guardian)"
fi
if systemctl is-active --quiet x1207-guardian 2>/dev/null; then
    c_ok "Servicio corriendo ahora mismo"
else
    c_bad "Servicio NO esta corriendo (sudo systemctl start x1207-guardian)"
fi
if [[ -d /var/log/journal ]]; then
    c_ok "Journal persistente (los logs sobreviven a los cortes)"
else
    c_warn "Journal no persistente: se perderan los logs del corte de corriente"
fi

titulo "6. Lecturas en vivo"
if STATUS_JSON="$(/usr/local/bin/x1207ctl.py status --json 2>/dev/null)"; then
    c_ok "x1207ctl.py status responde"
    python3 - "$STATUS_JSON" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
b = d["bateria"]
print(f"         Bateria .......... {b['porcentaje']:.1f}%  ({b['estado']}, {b['voltaje_v']:.3f} V)")
print(f"         Alimentacion ..... {'OK' if d['ac_power_ok'] else 'CORTADA (en bateria)'}")
print(f"         Carga ............ {d['carga']}")
t = d.get("cpu_temp_c");  print(f"         Temp. CPU ........ {t:.1f} C" if t else "         Temp. CPU ........ sin dato")
w = d.get("consumo_total_w"); print(f"         Consumo total .... {w:.2f} W" if w else "         Consumo total .... sin dato")
sys.exit(0 if 0 < b["voltaje_v"] < 5 else 1)
PY
    if [[ $? -eq 0 ]]; then
        c_ok "Voltaje de bateria en rango creible"
    else
        c_bad "Voltaje de bateria fuera de rango (revisar la celda 21700)"
    fi
else
    c_bad "x1207ctl.py status falla"
fi
CHIP="$(python3 -c "
import importlib.util
s = importlib.util.spec_from_file_location('x','/usr/local/bin/x1207ctl.py')
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.find_gpiochip(), 'API-2.x' if m._GPIOD_V2 else 'API-1.x')
" 2>/dev/null)"
if [[ -n "$CHIP" ]]; then
    c_ok "GPIO accesible (chip y API: $CHIP)"
else
    c_bad "No se pudo acceder al GPIO"
fi

# ---------------------------------------------------------------- prueba real

if [[ "${1:-}" == "--test" ]]; then
    titulo "7. Prueba real de corte de corriente"
    echo "  Se va a comprobar que la Pi detecta de verdad el corte y el retorno"
    echo "  de la alimentacion externa."
    echo
    echo "  Durante la prueba se detiene el guardian, para que NO apague la Pi."
    echo "  La Pi seguira funcionando con la bateria del HAT."
    echo

    GUARDIAN_WAS_ACTIVE=0
    systemctl is-active --quiet x1207-guardian && GUARDIAN_WAS_ACTIVE=1
    restaurar() {
        if [[ $GUARDIAN_WAS_ACTIVE -eq 1 ]]; then
            $SUDO systemctl start x1207-guardian
            echo "  Guardian reactivado."
        fi
    }
    trap restaurar EXIT INT TERM   # se restaura aunque se corte con Ctrl+C

    [[ $GUARDIAN_WAS_ACTIVE -eq 1 ]] && { $SUDO systemctl stop x1207-guardian; echo "  Guardian detenido temporalmente."; }

    leer_ac() {
        python3 -c "
import importlib.util
s = importlib.util.spec_from_file_location('x','/usr/local/bin/x1207ctl.py')
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print('1' if m.read_ac_power() else '0')" 2>/dev/null
    }

    esperar_estado() {  # $1 = estado esperado (0/1), $2 = mensaje, $3 = timeout
        local esperado="$1" msg="$2" limite="$3" t=0
        echo
        echo "  >>> $msg"
        printf '      esperando'
        while [[ $t -lt $limite ]]; do
            [[ "$(leer_ac)" == "$esperado" ]] && { printf ' detectado en %ss\n' "$t"; return 0; }
            printf '.'; sleep 1; t=$((t+1))
        done
        printf ' TIEMPO AGOTADO (%ss)\n' "$limite"
        return 1
    }

    if [[ "$(leer_ac)" != "1" ]]; then
        c_bad "La prueba necesita empezar CON la alimentacion conectada"
    else
        c_ok "Punto de partida: alimentacion externa presente"
        if esperar_estado 0 "DESCONECTA ahora la alimentacion externa (USB-C o PoE)" 90; then
            c_ok "Corte de corriente detectado correctamente"
            if esperar_estado 1 "RECONECTA ahora la alimentacion externa" 90; then
                c_ok "Retorno de la corriente detectado correctamente"
            else
                c_bad "No se detecto el retorno de la corriente"
            fi
        else
            c_bad "No se detecto el corte de corriente (revisar GPIO$PLD_PIN)"
        fi
    fi
else
    titulo "7. Prueba real de corte de corriente"
    echo "  Omitida. Para ejecutarla:  ./verificar.sh --test"
fi

# ------------------------------------------------------------------- resumen

titulo "Resumen"
printf '  Correctas: %s   Avisos: %s   Fallas: %s\n\n' "$OK" "$WARN" "$FAIL"
if [[ $FAIL -eq 0 ]]; then
    echo "  Todo correcto. El ciclo automatico deberia funcionar:"
    echo "    se corta la corriente -> la Pi se apaga sola (LED rojo APAGADO)"
    echo "    vuelve la corriente   -> el HAT la enciende sola"
    exit 0
else
    echo "  Hay $FAIL comprobacion(es) fallida(s). Revisa los detalles de arriba."
    exit 1
fi
