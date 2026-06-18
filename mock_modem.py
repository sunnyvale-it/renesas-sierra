#!/usr/bin/env python3
# ==============================================================================
# Sierra Wireless EM7590 LTE Modem AT Command Mock Responder
# ==============================================================================
# Connects to QEMU's virtual serial backend socket and responds to guest OS 
# AT commands, simulating a physical EM7590 device.

import os
import sys
import time
import socket

# Load configuration from vm_config.env
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(SCRIPT_DIR, "vm_config.env")

# Defaults
PORT = 4444

if os.path.exists(CONFIG_FILE):
    with open(CONFIG_FILE, "r") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                if "=" in line:
                    key, val = line.split("=", 1)
                    key = key.strip()
                    val = val.strip().strip('"')
                    if key == "MOCK_SERIAL_PORT":
                        PORT = int(val)
else:
    print(f"[!] Warning: Config file not found at {CONFIG_FILE}. Using default port {PORT}.")

print(f"[+] Sierra Wireless EM7590 Mock Daemon Initialized.")
print(f"[+] Connecting to QEMU serial socket on 127.0.0.1:{PORT}...")

def handle_at_command(cmd: str) -> str:
    cmd = cmd.strip().upper()
    if not cmd:
        return ""
    
    print(f"    [Guest Command]: {cmd}")
    
    # Strip echoing/carrier return
    if cmd.startswith("AT"):
        sub_cmd = cmd[2:].strip()
    else:
        sub_cmd = cmd

    # Basic AT responder logic
    if sub_cmd == "":
        return "\r\nOK\r\n"
    
    elif sub_cmd == "I" or sub_cmd == "I0":
        return (
            "\r\nManufacturer: Sierra Wireless, Inc.\r\n"
            "Model: EM7590\r\n"
            "Revision: SWI9X50C_01.14.02.00\r\n"
            "IMEI: 359123456789012\r\n"
            "IMEI SV: 02\r\n"
            "+GCAP: +CGSM,+DS,+ES\r\n"
            "\r\nOK\r\n"
        )
    
    elif sub_cmd == "!GSTATUS?":
        return (
            "\r\n!GSTATUS: \r\n"
            "Current Time:  36250      Temperature: 36\r\n"
            "Bootup Time:   450        Mode:        ONLINE\r\n"
            "System mode:   LTE        PS state:    ATTACHED\r\n"
            "LTE band:      B3         LTE bw:      20 MHz\r\n"
            "LTE Rx chan:   1650       LTE Tx chan: 19650\r\n"
            "EMM state:     Registered Normal Service\r\n"
            "RRC state:     RRC Connected\r\n"
            "IMS reg state: No Srv\r\n"
            "\r\n"
            "PCC RxM RSSI:  -64        PCC RxD RSSI:  -65\r\n"
            "PCC LNA state: Low\r\n"
            "PCC Tx Power:  10         TAC:         BEEF (48879)\r\n"
            "Cell ID:       01234567 (19088743)\r\n"
            "\r\nOK\r\n"
        )
        
    elif sub_cmd == "+CGDCONT?":
        return (
            "\r\n+CGDCONT: 1,\"IP\",\"internet.sunnyvale.it\",\"\",0,0,0,0\r\n"
            "+CGDCONT: 2,\"IPV4V6\",\"ims\",\"\",0,0,0,0\r\n"
            "\r\nOK\r\n"
        )
        
    elif sub_cmd == "!USBCOMP?":
        return (
            "\r\nConfig Index: 1\r\n"
            "Active Layout: 9 (DIAG, NMEA, MODEM, MBIM)\r\n"
            "\r\nOK\r\n"
        )
        
    elif sub_cmd.startswith("E0") or sub_cmd.startswith("E1"):
        # Echo control commands
        return "\r\nOK\r\n"
        
    elif sub_cmd.startswith("+CGSN"):
        return "\r\n359123456789012\r\n\r\nOK\r\n"
        
    elif sub_cmd.startswith("+CGMR"):
        return "\r\nSWI9X50C_01.14.02.00\r\n\r\nOK\r\n"

    else:
        # Default fallback acknowledgment
        return "\r\nOK\r\n"

def main():
    while True:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.connect(("127.0.0.1", PORT))
            print(f"[+] Connected to QEMU guest serial interface successfully!")
            
            buffer = ""
            while True:
                data = s.recv(1024)
                if not data:
                    print("[-] Connection closed by QEMU host interface.")
                    break
                
                buffer += data.decode("utf-8", errors="ignore")
                
                # Check for line endings which complete AT commands
                while "\r" in buffer or "\n" in buffer:
                    if "\r" in buffer:
                        cmd, buffer = buffer.split("\r", 1)
                        # clean up trailing newlines
                        if buffer.startswith("\n"):
                            buffer = buffer[1:]
                    else:
                        cmd, buffer = buffer.split("\n", 1)
                    
                    cmd_clean = cmd.strip()
                    if cmd_clean:
                        response = handle_at_command(cmd_clean)
                        if response:
                            s.sendall(response.encode("utf-8"))
                            
        except ConnectionRefusedError:
            time.sleep(2)  # Wait for QEMU to start up and open port
        except socket.error as e:
            print(f"[!] Socket Error: {e}")
            time.sleep(2)
        except KeyboardInterrupt:
            print("\n[-] Exiting Sierra Wireless EM7590 mock daemon.")
            sys.exit(0)

if __name__ == "__main__":
    main()
