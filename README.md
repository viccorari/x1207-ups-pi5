# X1207 UPS HAT — control completo para Raspberry Pi 5

Control y monitoreo del UPS HAT **Suptronics/Geekworm X1207 V1.2** (PoE + batería 21700)
en un Raspberry Pi 5, con el ciclo de energía completamente automático:

| Evento | Resultado |
|---|---|
| Se corta la alimentación externa (USB-C o PoE) | La Pi se apaga sola en ~4 s, **por completo** |
| Vuelve la alimentación externa | El HAT enciende la Pi sola, sin tocar el botón |

Probado sobre Raspberry Pi OS / Debian 13 (trixie), kernel 6.12+, Pi 5 Model B.

---

## Instalación rápida

En el Raspberry Pi, con el HAT ya montado:

```bash
git clone https://github.com/viccorari/x1207-ups-pi5.git
cd x1207-ups-pi5
sudo ./install.sh
sudo reboot        # necesario la primera vez
```

Tras el reinicio, comprobar:

```bash
x1207ctl.py status
journalctl -u x1207-guardian -f
```

---

## El detalle que hace que todo funcione: `POWER_OFF_ON_HALT=1`

Este es el hallazgo central del proyecto, y sin él **el auto-encendido no funciona**.

El X1207 promete "auto power-on when power is restored", pero de fábrica esto sólo
ocurría al apagar la Pi con el **botón físico**, nunca al apagarla por software.
La causa:

- Por defecto, un `shutdown -h now` en un Pi 5 **no apaga el equipo del todo**:
  deja el PMIC en un estado de espera de bajo consumo — se reconoce porque
  **el LED rojo del Pi se queda encendido**.
- El HAT interpreta ese estado como "la Pi sigue trabajando", así que **nunca corta
  la alimentación** y por lo tanto **nunca se arma su mecanismo de auto power-on**.
  Al reconectar la corriente no pasa nada: hay que apretar el botón a mano.
- El botón físico, en cambio, provoca un corte **total** de energía. Por eso sólo
  funcionaba por esa vía.

La solución es un ajuste en la EEPROM del bootloader del Pi 5:

```bash
POWER_OFF_ON_HALT=1
```

Con eso, `shutdown -h now` apaga el PMIC por completo (LED rojo **apagado**),
idéntico a pulsar el botón → el HAT corta la energía → al volver la corriente
enciende la Pi sola. `install.sh` lo configura automáticamente.

> **Nota:** si apagas la Pi por software **con la corriente conectada** (mantenimiento),
> vas a necesitar el botón para encenderla. Es el comportamiento esperado: no hay
> evento de "energía restaurada" que el HAT pueda detectar.

---

## Qué se puede leer y controlar

### Se puede LEER

| Dato | Fuente |
|---|---|
| Voltaje de la batería | Fuel gauge I2C `0x36`, registro `0x02` |
| % de carga (SOC) | Fuel gauge I2C `0x36`, registro `0x04` |
| Estado de la batería (Llena/Alta/Media/Baja/Crítica) | Derivado del voltaje |
| Presencia de alimentación externa (AC/PoE) | GPIO6 (alto = OK) |
| Estado de la carga (habilitada/deshabilitada) | GPIO16 |
| Temperatura del SoC | `vcgencmd measure_temp` |
| RPM del ventilador | `/sys/devices/platform/cooling_fan/hwmon*/fan1_input` |
| Consumo total real en vatios | Suma de los 14 rieles del PMIC |
| Voltaje/corriente por riel (VDD_CORE, DDR, HDMI, WiFi…) | `vcgencmd pmic_read_adc` |

### Se puede CONTROLAR

| Acción | Cómo |
|---|---|
| Habilitar / deshabilitar la carga de la batería | GPIO16 (`x1207ctl.py charge on\|off\|auto`) |
| Apagado automático al perder la corriente | Servicio `x1207-guardian` |
| Corte de carga sobre cierto % (protege la batería) | Servicio `x1207-guardian` |

### NO se puede leer ni controlar (limitación de hardware)

- **Botón de encendido**: va cableado directo al pin PSW del Pi 5 vía pogo pin;
  lo gestiona el propio Pi, no hay nada que leer por software.
- **Los 4 LED de batería**: los enciende el chip de carga según el voltaje.
  No hay registro ni GPIO para leerlos ni apagarlos.
- **Distinguir si entra por PoE o por USB-C**: la conmutación es 100 % hardware,
  no hay registro documentado que lo indique.

---

## Uso de `x1207ctl.py`

```bash
x1207ctl.py status              # foto instantánea de todo
x1207ctl.py status --json       # lo mismo en JSON (para integrar con otros scripts)
x1207ctl.py monitor             # en vivo, refrescando
x1207ctl.py monitor --interval 1
x1207ctl.py charge off          # fuerza la carga deshabilitada
x1207ctl.py charge on           # fuerza la carga habilitada
x1207ctl.py charge auto         # vuelve al comportamiento por defecto del HAT
x1207ctl.py guardian            # demonio (normalmente lo corre systemd)
```

Ejemplo de salida de `status`:

```
========== UPS X1207 / Raspberry Pi 5 ==========
Batería:       95.8%  (Llena, 4.169 V)
Carga:         deshabilitada
AC / PoE:      OK
Temp. CPU:     43.3 °C
Ventilador:    0 RPM
Consumo total: 1.81 W
--- Rieles PMIC (V / A) ---
  0V8_AON      0.801V  0.003A
  ...
  VDD_CORE     0.863V  0.625A
=================================================
```

### Opciones del `guardian`

| Opción | Por defecto | Qué hace |
|---|---|---|
| `--interval` | `2.0` | Segundos entre lecturas |
| `--ac-loss-debounce` | `2` | Lecturas seguidas sin AC antes de apagar (evita falsos positivos) |
| `--charge-protect-pct` | `95.0` | Sobre este % corta la carga (evita trickle-charge permanente) |
| `--charge-protect-hysteresis` | `5.0` | Margen para volver a habilitar la carga |

Con los valores por defecto, el apagado ocurre ~4 s después del corte de energía.

---

## Mapa de hardware

| Recurso | Uso |
|---|---|
| I2C1 `0x36` | Fuel gauge de la batería (compatible MAX17040) |
| GPIO6 (pin 31) | Entrada: detección de pérdida de AC / fallo del adaptador |
| GPIO16 (pin 36) | Salida: control de carga (alto = deshabilitada, bajo = habilitada) |
| GPIO2/GPIO3 (pins 3/5) | I2C SDA/SCL hacia el fuel gauge |

LEDs con serigrafía en la placa, junto al conector USB-C: **CHG** (cargando),
**PLS** (power loss), **5V0** (5 V presentes).

---

## Qué hace `install.sh`

1. Verifica que sea un Raspberry Pi 5.
2. Instala dependencias: `python3-smbus2`, `python3-libgpiod`, `i2c-tools`.
3. Habilita I2C: descomenta `dtparam=i2c_arm=on` en `/boot/firmware/config.txt`
   y agrega el módulo `i2c-dev` a `/etc/modules` (sin él no existe `/dev/i2c-1`).
4. **Configura `POWER_OFF_ON_HALT=1`** en la EEPROM (el paso clave, ver arriba).
5. Instala `x1207ctl.py` en `/usr/local/bin`.
6. Instala y activa el servicio `x1207-guardian`.
7. Activa el journal persistente, para conservar los logs entre reinicios y poder
   diagnosticar qué pasó durante un corte de corriente.

---

## Verificar que el ciclo completo funciona

1. `x1207ctl.py status` → debe mostrar `AC / PoE: OK`.
2. Desconectar la alimentación externa.
3. La Pi debe apagarse sola en ~4 s, y **el LED rojo del Pi debe apagarse por
   completo**. Si el LED rojo queda encendido, `POWER_OFF_ON_HALT=1` no se aplicó
   (revisar con `sudo rpi-eeprom-config`) y el auto-encendido no va a funcionar.
4. Reconectar la alimentación externa → la Pi debe arrancar sola, sin tocar el botón.

---

## Diagnóstico

```bash
sudo rpi-eeprom-config              # confirmar POWER_OFF_ON_HALT=1
sudo i2cdetect -y 1                 # el fuel gauge debe aparecer en 0x36
pinctrl get 6                       # estado del pin de deteccion de AC
pinctrl get 16                      # estado del pin de control de carga
journalctl -u x1207-guardian -f     # log del demonio en vivo
journalctl -u x1207-guardian -b -1  # log del arranque anterior (util tras un corte)
```

| Síntoma | Causa probable |
|---|---|
| `status` falla al leer la batería | I2C no habilitado o falta `i2c-dev` → reinstalar y reiniciar |
| La Pi se apaga pero el LED rojo sigue encendido | Falta `POWER_OFF_ON_HALT=1` |
| No enciende sola al volver la corriente | Mismo caso anterior |
| `i2cdetect` no muestra `0x36` | Batería mal puesta o HAT mal asentado en el header |

---

## Referencias

- Código de referencia del fabricante: <https://github.com/suptronics/x120x>
- Documentación de software X120x: <https://suptronics.com/Raspberrypi/Power_mgmt/x120x-v1.0_software.html>
- Documentación de hardware X1207 v1.2: <https://suptronics.com/Raspberrypi/Power_mgmt/x1207-v1.2_hardware.html>
- Wiki del fabricante (marca Geekworm): <https://wiki.geekworm.com/X1207>
