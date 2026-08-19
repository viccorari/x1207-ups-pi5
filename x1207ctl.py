#!/usr/bin/env python3
"""Control y monitoreo completo del UPS HAT Suptronics X1207 (Raspberry Pi 5).

Hardware involucrado y cómo se lee/controla cada cosa:

  - Fuel gauge de la batería (compatible MAX17040) en I2C1, dirección 0x36.
    Registro 0x02 = voltaje de celda, registro 0x04 = % de carga (SOC).
  - GPIO6  (entrada) : detección de pérdida de AC / fallo del adaptador.
                       ACTIVO (alto) = alimentación externa OK.
  - GPIO16 (salida)  : control de carga de la batería.
                       alto = carga deshabilitada, bajo = carga habilitada.
                       Sin comando explícito el HAT la deja habilitada (pull-down).
  - vcgencmd pmic_read_adc: todos los rieles de voltaje/corriente del Pi 5
    (permite calcular consumo total real en vatios, no solo estimado).
  - vcgencmd measure_temp: temperatura del SoC.
  - /sys/devices/platform/cooling_fan/hwmon*/fan1_input: RPM del disipador
    activo del Pi 5, si está instalado (no es parte del HAT, es del propio Pi).
  - Botón de encendido y los 4 LED de batería del HAT son 100% hardware: el
    botón está cableado directo al pin PSW del Pi 5 (lo maneja el propio Pi,
    nada que leer/controlar por software) y los LED los enciende el propio
    chip de carga según el voltaje — no hay registro ni GPIO para leerlos ni
    apagarlos desde aquí.
  - Entrada PoE/USB-C: la conmutación es automática en hardware, no hay
    forma documentada de saber por I2C/GPIO cuál de las dos está activa.

Referencia oficial (de donde salen las direcciones/registros de arriba):
https://github.com/suptronics/x120x

Subcomandos:
  status              foto instantánea de todo (texto o --json)
  monitor             status en bucle cada --interval segundos
  charge on|off|auto   fuerza carga habilitada/deshabilitada, o la deja en
                       automático (vuelve al pull-down por defecto = habilitada)
  guardian            demonio de protección: apaga la carga sobre el
                       --charge-protect-pct para no tener la batería en
                       trickle-charge permanente, y apaga la Pi apenas se
                       pierde la alimentación externa (con un pequeño
                       debounce, --ac-loss-debounce).

REQUISITO CRÍTICO para que el ciclo apagado/encendido sea automático:
la EEPROM del Pi 5 debe tener POWER_OFF_ON_HALT=1. Sin eso, `shutdown -h
now` deja el PMIC del Pi vivo (LED rojo encendido), el HAT cree que la Pi
sigue trabajando, nunca corta la alimentación y por tanto NUNCA se arma el
auto power-on: al volver la corriente hay que apretar el botón a mano.
Con POWER_OFF_ON_HALT=1 el apagado por software se comporta igual que el
botón, el HAT corta todo y enciende solo al reconectar. Lo configura
install.sh; ver README.md.
"""

import argparse
import json
import os
import struct
import subprocess
import sys
import time
from pathlib import Path

import gpiod
import smbus2
from gpiod.line import Direction, Value


def _privileged(cmd: list[str]) -> list[str]:
    """Antepone sudo solo si no somos root; como servicio systemd corre
    directamente como root y ahí sudo sobra (y puede no estar instalado)."""
    return cmd if os.geteuid() == 0 else ["sudo", *cmd]

I2C_BUS = 1
FUEL_GAUGE_ADDR = 0x36
VCELL_REG = 0x02
SOC_REG = 0x04

GPIOCHIP = "/dev/gpiochip0"
PLD_PIN = 6      # AC power loss / power adapter failure (entrada)
CHARGE_PIN = 16  # control de carga (salida)


# --------------------------------------------------------------- batería

def read_battery(bus: smbus2.SMBus) -> tuple[float, float]:
    """(voltaje en V, capacidad en %) leídos del fuel gauge."""
    raw_v = bus.read_word_data(FUEL_GAUGE_ADDR, VCELL_REG)
    voltage = struct.unpack("<H", struct.pack(">H", raw_v))[0] * 1.25 / 1000 / 16
    raw_c = bus.read_word_data(FUEL_GAUGE_ADDR, SOC_REG)
    capacity = struct.unpack("<H", struct.pack(">H", raw_c))[0] / 256
    return voltage, min(max(capacity, 0.0), 100.0)


def battery_label(voltage: float) -> str:
    if 3.87 <= voltage <= 4.23:
        return "Llena"
    if 3.70 <= voltage < 3.87:
        return "Alta"
    if 3.55 <= voltage < 3.70:
        return "Media"
    if 3.40 <= voltage < 3.55:
        return "Baja"
    if voltage < 3.40:
        return "Crítica"
    return "Desconocida"


# ------------------------------------------------------------- GPIO / AC

def read_ac_power() -> bool:
    """True si hay alimentación externa (PoE o USB-C) presente y sana."""
    req = gpiod.request_lines(
        GPIOCHIP, consumer="x1207ctl-ac",
        config={PLD_PIN: gpiod.LineSettings(direction=Direction.INPUT)})
    try:
        return req.get_values()[0] == Value.ACTIVE
    finally:
        req.release()


def read_charge_state() -> str:
    """'habilitada' / 'deshabilitada' según el nivel actual de GPIO16."""
    out = subprocess.check_output(["pinctrl", "get", str(CHARGE_PIN)], text=True)
    return "deshabilitada" if "hi" in out.split("//")[0] else "habilitada"


def set_charging(mode: str) -> None:
    """mode: 'on' (fuerza habilitada), 'off' (fuerza deshabilitada),
    'auto' (suelta el pin, vuelve al pull-down = habilitada por defecto)."""
    if mode == "on":
        subprocess.run(["pinctrl", "set", str(CHARGE_PIN), "op", "dl"], check=True)
    elif mode == "off":
        subprocess.run(["pinctrl", "set", str(CHARGE_PIN), "op", "dh"], check=True)
    elif mode == "auto":
        subprocess.run(["pinctrl", "set", str(CHARGE_PIN), "no"], check=True)
    else:
        raise ValueError(f"modo de carga inválido: {mode!r}")


# --------------------------------------------------------- Pi 5 (vcgencmd)

def _vcgencmd(*args: str) -> str:
    return subprocess.check_output(["vcgencmd", *args], text=True).strip()


def read_cpu_temp() -> float | None:
    try:
        return float(_vcgencmd("measure_temp").split("=")[1].rstrip("'C"))
    except (IndexError, ValueError, subprocess.CalledProcessError):
        return None


def read_pmic_rails() -> dict[str, dict[str, float]]:
    """{'VDD_CORE': {'V': 0.84, 'A': 3.1}, ...} — un dict por riel con lo
    que haya disponible de voltaje y/o corriente."""
    rails: dict[str, dict[str, float]] = {}
    try:
        out = _vcgencmd("pmic_read_adc")
    except subprocess.CalledProcessError:
        return rails
    for line in out.splitlines():
        # formato real: " 3V3_SYS_A current(1)=0.12589500A" -> label + métrica(idx)=valor+unidad
        parts = line.split()
        if len(parts) != 2 or "=" not in parts[1]:
            continue
        label, metric = parts
        try:
            val = float(metric.split("=")[1][:-1])  # quita la unidad final (V/A)
        except (IndexError, ValueError):
            continue
        kind = "A" if label.endswith("_A") else "V" if label.endswith("_V") else None
        if not kind:
            continue
        rails.setdefault(label[:-2], {})[kind] = val
    return rails


def total_watts(rails: dict[str, dict[str, float]]) -> float | None:
    watts = [r["V"] * r["A"] for r in rails.values() if "V" in r and "A" in r]
    return sum(watts) if watts else None


def read_fan_rpm() -> int | None:
    for f in Path("/sys/devices/platform/cooling_fan").rglob("fan1_input"):
        try:
            return int(f.read_text().strip())
        except (OSError, ValueError):
            pass
    return None


# ------------------------------------------------------------------- CLI

def collect_status() -> dict:
    bus = smbus2.SMBus(I2C_BUS)
    try:
        voltage, capacity = read_battery(bus)
    finally:
        bus.close()
    rails = read_pmic_rails()
    return {
        "bateria": {"voltaje_v": round(voltage, 3), "porcentaje": round(capacity, 1),
                    "estado": battery_label(voltage)},
        "ac_power_ok": read_ac_power(),
        "carga": read_charge_state(),
        "cpu_temp_c": read_cpu_temp(),
        "fan_rpm": read_fan_rpm(),
        "consumo_total_w": (lambda w: round(w, 2) if w is not None else None)(total_watts(rails)),
        "rieles_pmic": rails,
    }


def print_status(s: dict) -> None:
    b = s["bateria"]
    print("========== UPS X1207 / Raspberry Pi 5 ==========")
    print(f"Batería:       {b['porcentaje']:.1f}%  ({b['estado']}, {b['voltaje_v']:.3f} V)")
    print(f"Carga:         {s['carga']}")
    print(f"AC / PoE:      {'OK' if s['ac_power_ok'] else 'CORTADA (con batería de respaldo)'}")
    temp = s["cpu_temp_c"]
    print(f"Temp. CPU:     {temp:.1f} °C" if temp is not None else "Temp. CPU:     sin dato")
    fan = s["fan_rpm"]
    print(f"Ventilador:    {fan} RPM" if fan is not None else "Ventilador:    no detectado")
    w = s["consumo_total_w"]
    print(f"Consumo total: {w:.2f} W" if w is not None else "Consumo total: sin dato")
    print("--- Rieles PMIC (V / A) ---")
    for name, vals in sorted(s["rieles_pmic"].items()):
        v = f"{vals['V']:.3f}V" if "V" in vals else "  --  "
        a = f"{vals['A']:.3f}A" if "A" in vals else "  --  "
        print(f"  {name:<12} {v}  {a}")
    print("=================================================")


def cmd_status(args):
    s = collect_status()
    print(json.dumps(s, ensure_ascii=False, indent=2)) if args.json else print_status(s)


def cmd_monitor(args):
    try:
        while True:
            s = collect_status()
            print(json.dumps(s, ensure_ascii=False)) if args.json else print_status(s)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass


def cmd_charge(args):
    set_charging(args.mode)
    print(f"Carga -> {args.mode}. Estado del pin ahora: {read_charge_state()}")


def cmd_guardian(args):
    """Demonio de protección: pensado para correr como servicio systemd
    (ver x1207-guardian.service). Registra todo en stdout -> journalctl.

    Encender solo al volver la corriente es un comportamiento de hardware
    del propio X1207 ("auto power-on"): con la Pi apagada no hay ningún
    script corriendo que pueda encenderla, eso lo decide el HAT solo. Este
    demonio únicamente se encarga de la mitad que sí depende del software:
    apagar la Pi apenas se pierde la alimentación externa.
    """
    bus = smbus2.SMBus(I2C_BUS)
    protecting = False
    ac_loss_streak = 0
    shutting_down = False
    print(f"[guardian] iniciado — corte de carga sobre {args.charge_protect_pct}%, "
         f"apagado apenas se pierde AC (debounce {args.ac_loss_debounce} lecturas), "
         f"chequeo cada {args.interval}s")
    try:
        while True:
            voltage, capacity = read_battery(bus)
            ac_ok = read_ac_power()

            # protección de batería: no mantenerla en 100% permanente
            if capacity >= args.charge_protect_pct and not protecting:
                set_charging("off")
                protecting = True
                print(f"[guardian] batería en {capacity:.1f}% -> carga deshabilitada")
            elif capacity < args.charge_protect_pct - args.charge_protect_hysteresis and protecting:
                set_charging("auto")
                protecting = False
                print(f"[guardian] batería en {capacity:.1f}% -> carga rehabilitada")

            # apagado apenas se pierde la alimentación externa (con un
            # pequeño debounce para no dispararse por un solo blip del GPIO)
            if not ac_ok:
                ac_loss_streak += 1
            else:
                if ac_loss_streak:
                    print("[guardian] AC restaurada")
                ac_loss_streak = 0

            if ac_loss_streak >= args.ac_loss_debounce and not shutting_down:
                shutting_down = True
                print(f"[guardian] AC perdida ({ac_loss_streak} lecturas seguidas) "
                     f"-> apagando ahora")
                subprocess.run(_privileged(["shutdown", "-h", "now",
                               "Perdida de AC (x1207ctl guardian)"]), check=False)

            print(f"[guardian] {capacity:.1f}% {voltage:.3f}V "
                 f"AC={'ok' if ac_ok else 'CORTADA'} carga={read_charge_state()}", flush=True)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass
    finally:
        bus.close()


def main():
    # línea por línea, no por bloque: para monitor/guardian corriendo bajo
    # systemd o `timeout`, si no se journalctl/redirección se queda sin ver
    # nada hasta que el proceso termina.
    sys.stdout.reconfigure(line_buffering=True)

    p = argparse.ArgumentParser(description="Control/monitoreo del UPS HAT Suptronics X1207")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("status", help="foto instantánea de todo")
    sp.add_argument("--json", action="store_true")
    sp.set_defaults(func=cmd_status)

    sp = sub.add_parser("monitor", help="status en bucle")
    sp.add_argument("--interval", type=float, default=5.0)
    sp.add_argument("--json", action="store_true")
    sp.set_defaults(func=cmd_monitor)

    sp = sub.add_parser("charge", help="controla la carga de la batería")
    sp.add_argument("mode", choices=["on", "off", "auto"])
    sp.set_defaults(func=cmd_charge)

    sp = sub.add_parser("guardian", help="demonio de protección (pensado para systemd)")
    sp.add_argument("--interval", type=float, default=2.0)
    sp.add_argument("--charge-protect-pct", type=float, default=95.0)
    sp.add_argument("--charge-protect-hysteresis", type=float, default=5.0)
    sp.add_argument("--ac-loss-debounce", type=int, default=2,
                    help="lecturas seguidas sin AC antes de apagar (evita un falso positivo de una sola lectura)")
    sp.set_defaults(func=cmd_guardian)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
