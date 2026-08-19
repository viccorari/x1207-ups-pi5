# X1207 UPS HAT — control completo para Raspberry Pi 5

Control y monitoreo del UPS HAT **Suptronics/Geekworm X1207 V1.2** (PoE + batería 21700)
en un Raspberry Pi 5, con el ciclo de energía completamente automático:

| Evento | Resultado |
|---|---|
| Se corta la alimentación externa (USB-C o PoE) | La Pi se apaga sola en ~4 s, **por completo** |
| Vuelve la alimentación externa | El HAT enciende la Pi sola, sin tocar el botón |

Probado sobre Raspberry Pi 5 Model B en **Debian 12 (bookworm, kernel 6.6)** y
**Debian 13 (trixie, kernel 6.12+)**. El script se adapta solo a las diferencias
entre ambas versiones (ver [Compatibilidad](#compatibilidad-entre-versiones-de-raspberry-pi-os)).

---

## Contenido del repositorio

| Archivo | Para qué sirve |
|---|---|
| `x1207ctl.py` | Herramienta principal: leer estado, controlar la carga, demonio `guardian` |
| `x1207-guardian.service` | Unidad systemd que mantiene el `guardian` corriendo siempre |
| `install.sh` | Instalación desatendida completa (se ejecuta en el Pi, como root) |
| `verificar.sh` | Comprueba que todo quedó bien instalado, con prueba real de corte de luz |

---

## Instalación rápida (Pi que ya está funcionando)

Con el HAT montado y la batería puesta, desde el propio Pi:

```bash
git clone https://github.com/viccorari/x1207-ups-pi5.git
cd x1207-ups-pi5
sudo ./install.sh
sudo reboot        # sólo si install.sh lo pide
```

O copiando los archivos desde otra máquina, si el Pi no tiene salida a internet:

```bash
scp x1207ctl.py x1207-guardian.service install.sh verificar.sh usuario@IP_DEL_PI:/tmp/x1207/
ssh usuario@IP_DEL_PI 'cd /tmp/x1207 && chmod +x *.sh && sudo ./install.sh'
```

Después, comprobar que quedó todo bien:

```bash
./verificar.sh
```

---

## Instalación desde cero, en un Raspberry Pi virgen

Procedimiento completo partiendo de un Pi 5 recién sacado de la caja.

### 1. Montaje físico (con todo desconectado de la corriente)

1. Insertar la celda **21700** en el portapilas del HAT, respetando la polaridad
   (el `+` está serigrafiado en la placa).
2. Encajar el X1207 sobre el header de 40 pines del Pi 5, alineando bien los pines.
3. Asegurarse de que el **pogo pin** del HAT hace contacto con el pad `PSW` del
   Pi 5. Sin ese contacto el botón del HAT no puede encender ni apagar la Pi.
4. Atornillar los separadores.

> Este HAT es **exclusivo del Raspberry Pi 5**. No es compatible con Pi 4B/3B+/3B.

### 2. Grabar el sistema operativo

Con **Raspberry Pi Imager** en cualquier PC:

1. Elegir *Raspberry Pi 5* como dispositivo y **Raspberry Pi OS (64-bit)** como
   sistema. Sirven tanto la versión basada en Debian 12 como en Debian 13.
2. Antes de grabar, entrar en **Editar ajustes** y configurar:
   - Nombre de host (por ejemplo `SCU-<algo>`)
   - Usuario y contraseña
   - Red Wi-Fi, si se va a usar (con cable ethernet no hace falta)
   - En la pestaña *Servicios*: **activar SSH** con autenticación por contraseña
3. Grabar la microSD e insertarla en el Pi.

Activar SSH en este paso evita necesitar pantalla y teclado.

### 3. Primer arranque y acceso

1. Conectar el cable de red (o dejar que levante el Wi-Fi configurado).
2. Alimentar por **USB-C** o **PoE** al HAT (no directamente al Pi).
3. Si la Pi no arranca sola, pulsar una vez el botón del HAT.
4. Localizarla en la red y entrar por SSH:

```bash
ssh usuario@raspberrypi.local     # o por IP: ssh usuario@192.168.X.Y
```

Si `.local` no resuelve, ver [Cómo localizar el Pi en la red](#cómo-localizar-el-pi-en-la-red).

### 4. Instalar

```bash
sudo apt update && sudo apt full-upgrade -y     # recomendable, no obligatorio
# copiar aquí los archivos del repositorio (scp o git clone)
cd ruta/al/repositorio
sudo ./install.sh
sudo reboot
```

El reinicio es necesario la primera vez: activa el I2C y aplica el ajuste de la
EEPROM.

### 5. Verificar

```bash
./verificar.sh            # comprobaciones automáticas
./verificar.sh --test     # además, prueba real desconectando la corriente
```

Debe terminar con **0 fallas**. A partir de ahí el ciclo ya es automático.

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

> **La EEPROM es de la placa, no de la tarjeta SD.** Una vez configurado,
> `POWER_OFF_ON_HALT=1` sobrevive a reinstalaciones del sistema operativo y a
> cambios de tarjeta. Al reinstalar sólo hay que volver a poner el software
> (script + servicio + I2C), no este ajuste.

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

## Compatibilidad entre versiones de Raspberry Pi OS

Entre Debian 12 y Debian 13 cambian dos cosas que rompen cualquier script escrito
para una sola versión (por eso el fabricante publica dos juegos de scripts,
`pld.py` y `pld-trixie.py`). `x1207ctl.py` detecta ambas en tiempo de ejecución:

| | Debian 12 (bookworm, kernel 6.6) | Debian 13 (trixie, kernel 6.12+) |
|---|---|---|
| Versión de `libgpiod` | 1.6.x — API `Chip.get_line()` / `line.request()` | 2.x — API `gpiod.request_lines()` |
| gpiochip del header de 40 pines | `/dev/gpiochip4` | `/dev/gpiochip0` |

El chip **no se busca por número** sino por su etiqueta `pinctrl-rp1`, que es
estable entre versiones. La API de `libgpiod` se detecta con
`hasattr(gpiod, "request_lines")`.

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

## Qué hace `install.sh` (y cómo revertirlo)

1. Verifica que sea un Raspberry Pi 5.
2. Instala dependencias: `python3-smbus2`, `python3-libgpiod`, `i2c-tools`.
3. Habilita I2C: descomenta `dtparam=i2c_arm=on` en `/boot/firmware/config.txt`
   y agrega el módulo `i2c-dev` a `/etc/modules` (sin él no existe `/dev/i2c-1`).
4. **Configura `POWER_OFF_ON_HALT=1`** en la EEPROM (el paso clave, ver arriba).
5. Instala `x1207ctl.py` en `/usr/local/bin`.
6. Instala y activa el servicio `x1207-guardian`.
7. Activa el journal persistente, para conservar los logs entre reinicios y poder
   diagnosticar qué pasó durante un corte de corriente.

Es idempotente: se puede volver a ejecutar sin problema, sólo aplica lo que falte.

### Desinstalar

```bash
sudo systemctl disable --now x1207-guardian
sudo rm /etc/systemd/system/x1207-guardian.service /usr/local/bin/x1207ctl.py
sudo systemctl daemon-reload
```

Esto quita el software. Para que además la Pi vuelva a quedarse en espera al
apagarse (comportamiento de fábrica), hay que revertir la EEPROM:

```bash
sudo rpi-eeprom-config > /tmp/e.conf
sed -i '/^POWER_OFF_ON_HALT=/d' /tmp/e.conf
sudo rpi-eeprom-config --apply /tmp/e.conf
sudo reboot
```

---

## Verificación

### Script automático

`verificar.sh` comprueba 19 puntos: hardware, dependencias, I2C, fuel gauge,
`POWER_OFF_ON_HALT`, software, servicio, journal persistente y lecturas en vivo.
Devuelve código de salida `0` si todo está bien y `1` si algo falla, así que
también sirve dentro de otros scripts.

```bash
./verificar.sh
```

```
1. Hardware y sistema
  [ OK ] Modelo: Raspberry Pi 5 Model B Rev 1.1
         SO: Debian GNU/Linux 12 (bookworm) | kernel 6.6.31+rpt-rpi-2712
...
Resumen
  Correctas: 19   Avisos: 0   Fallas: 0
```

### Prueba real de corte de corriente

```bash
./verificar.sh --test
```

Añade una prueba interactiva que confirma que la Pi **detecta de verdad** el corte
y el retorno de la corriente. El script:

1. **Detiene temporalmente el `guardian`**, para que no apague la Pi durante la prueba
   (la Pi sigue funcionando con la batería del HAT).
2. Pide desconectar la alimentación y espera hasta 90 s a detectar el corte.
3. Pide reconectarla y espera a detectar el retorno.
4. **Reactiva el `guardian`** al terminar — incluso si se interrumpe con `Ctrl+C`.

### Prueba del ciclo completo (fin a fin)

La prueba anterior valida la *detección*. Para validar el ciclo entero, con
apagado y encendido reales:

1. `x1207ctl.py status` → debe mostrar `AC / PoE: OK`.
2. Desconectar la alimentación externa.
3. La Pi debe apagarse sola en ~4 s, y **el LED rojo del Pi debe apagarse por
   completo**. Si el LED rojo queda encendido, `POWER_OFF_ON_HALT=1` no se aplicó
   (revisar con `sudo rpi-eeprom-config`) y el auto-encendido no va a funcionar.
4. Reconectar la alimentación externa → la Pi debe arrancar sola, sin tocar el botón.

Después de un corte, se puede revisar qué pasó exactamente (el journal persistente
conserva los logs entre arranques):

```bash
sudo journalctl -u x1207-guardian -b -1 | tail -20
```

Un ciclo correcto deja un rastro como este:

```
[guardian] AC perdida (2 lecturas seguidas) -> apagando ahora
systemd-logind[681]: System is powering down (Perdida de AC (x1207ctl guardian)).
systemd[1]: Reached target poweroff.target - System Power Off.
```

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
| El botón no enciende ni apaga la Pi | El pogo pin no hace contacto con el pad `PSW` del Pi 5 |
| `AttributeError: module 'gpiod' has no attribute ...` | Versión de `x1207ctl.py` anterior al soporte de Debian 12 → actualizar |

### Cómo localizar el Pi en la red

El Pi puede cambiar de IP cada vez que arranca, porque el router le asigna un
lease nuevo por DHCP. Para encontrarlo:

```bash
# por nombre mDNS (lo mas simple, si la red lo permite)
ping NOMBRE_DEL_HOST.local

# buscando su MAC en la tabla ARP (los Pi usan el prefijo 88:a2:9e, entre otros)
ping -b -c3 192.168.1.255 2>/dev/null; ip neigh | grep -i '88:a2:9e'

# barrido de la subred buscando SSH abierto
nmap -p22 --open 192.168.1.0/24
```

Si el equipo va a quedar fijo, conviene reservarle la IP en el router (por MAC) o
configurársela estática, y así evitar tener que buscarlo cada vez.

---

## Referencias

- Código de referencia del fabricante: <https://github.com/suptronics/x120x>
- Documentación de software X120x: <https://suptronics.com/Raspberrypi/Power_mgmt/x120x-v1.0_software.html>
- Documentación de hardware X1207 v1.2: <https://suptronics.com/Raspberrypi/Power_mgmt/x1207-v1.2_hardware.html>
- Wiki del fabricante (marca Geekworm): <https://wiki.geekworm.com/X1207>
