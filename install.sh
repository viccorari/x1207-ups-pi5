#!/usr/bin/env bash
# Instalador del control del UPS HAT Suptronics X1207 en un Raspberry Pi 5.
#
# Deja el equipo con el ciclo completo automatico:
#   se corta la corriente -> la Pi se apaga sola (del todo)
#   vuelve la corriente   -> el HAT la enciende sola
#
# Ejecutar EN el Raspberry Pi:  sudo ./install.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Este script necesita root. Usa: sudo $0" >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_TXT=/boot/firmware/config.txt
NEEDS_REBOOT=0

echo "==> 1/6 Verificando que sea un Raspberry Pi 5"
MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo desconocido)"
echo "    Modelo detectado: $MODEL"
if [[ "$MODEL" != *"Raspberry Pi 5"* ]]; then
    echo "    AVISO: el X1207 es solo para Pi 5. Continuando de todos modos." >&2
fi

echo "==> 2/6 Instalando dependencias"
apt-get update -qq
apt-get install -y -qq python3-smbus2 python3-libgpiod i2c-tools >/dev/null
echo "    OK: python3-smbus2, python3-libgpiod, i2c-tools"

echo "==> 3/6 Habilitando I2C (bus 1, donde vive el fuel gauge en 0x36)"
if grep -q '^dtparam=i2c_arm=on' "$CONFIG_TXT"; then
    echo "    Ya estaba habilitado en config.txt"
else
    if grep -q '^#dtparam=i2c_arm=on' "$CONFIG_TXT"; then
        sed -i 's/^#dtparam=i2c_arm=on/dtparam=i2c_arm=on/' "$CONFIG_TXT"
    else
        echo 'dtparam=i2c_arm=on' >> "$CONFIG_TXT"
    fi
    echo "    Habilitado en config.txt (requiere reinicio)"
    NEEDS_REBOOT=1
fi
# el modulo i2c-dev es lo que crea /dev/i2c-1; sin el, smbus2 no puede abrir el bus
if ! grep -q '^i2c-dev' /etc/modules; then
    echo 'i2c-dev' >> /etc/modules
    echo "    Modulo i2c-dev agregado a /etc/modules"
fi
modprobe i2c-dev 2>/dev/null || true

echo "==> 4/6 Configurando POWER_OFF_ON_HALT=1 en la EEPROM del bootloader"
# ESTE ES EL PASO CLAVE. Sin el, 'shutdown -h now' deja el PMIC del Pi vivo
# (LED rojo encendido), el HAT nunca corta la alimentacion y NUNCA se arma el
# auto power-on: al volver la corriente habria que apretar el boton a mano.
EEPROM_TMP="$(mktemp)"
rpi-eeprom-config > "$EEPROM_TMP"
if grep -q '^POWER_OFF_ON_HALT=1' "$EEPROM_TMP"; then
    echo "    Ya estaba configurado"
else
    sed -i '/^POWER_OFF_ON_HALT=/d' "$EEPROM_TMP"
    echo 'POWER_OFF_ON_HALT=1' >> "$EEPROM_TMP"
    rpi-eeprom-config --apply "$EEPROM_TMP" >/dev/null
    echo "    Aplicado (requiere reinicio)"
    NEEDS_REBOOT=1
fi
rm -f "$EEPROM_TMP"

echo "==> 5/6 Instalando x1207ctl.py en /usr/local/bin"
install -m 755 "$SRC_DIR/x1207ctl.py" /usr/local/bin/x1207ctl.py
echo "    OK: /usr/local/bin/x1207ctl.py"

echo "==> 6/6 Instalando y activando el servicio x1207-guardian"
install -m 644 "$SRC_DIR/x1207-guardian.service" /etc/systemd/system/x1207-guardian.service
systemctl daemon-reload
systemctl enable --now x1207-guardian.service
echo "    OK: servicio activo y habilitado en el arranque"

# journal persistente: sin esto los logs se pierden en cada apagado y no se
# puede diagnosticar que paso durante un corte de corriente
if [[ ! -d /var/log/journal ]]; then
    mkdir -p /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
    systemctl restart systemd-journald
    echo "    Journal persistente activado (para conservar logs entre reinicios)"
fi

echo
echo "================================================================"
echo "Instalacion completa."
if [[ $NEEDS_REBOOT -eq 1 ]]; then
    echo "REINICIA AHORA para aplicar los cambios:  sudo reboot"
else
    echo "No hace falta reiniciar."
fi
echo
echo "Comprobar estado:   x1207ctl.py status"
echo "Ver el guardian:    journalctl -u x1207-guardian -f"
echo "================================================================"
