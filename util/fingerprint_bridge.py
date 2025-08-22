import sys
import serial
import adafruit_fingerprint


device = sys.argv[1] if len(sys.argv) > 1 else '/dev/ttyS2'
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 57600

uart = serial.Serial(device, baudrate=baud, timeout=1)
finger = adafruit_fingerprint.Adafruit_Fingerprint(uart)

for line in sys.stdin:
    parts = line.strip().split()
    if not parts:
        continue
    cmd = parts[0]
    if cmd == 'read_templates':
        print(finger.read_templates())
    elif cmd == 'get_image':
        print(finger.get_image())
    elif cmd == 'image_2_tz':
        slot = int(parts[1])
        print(finger.image_2_tz(slot))
    elif cmd == 'finger_search':
        code = finger.finger_search()
        print(code)
        if code == adafruit_fingerprint.OK:
            print(finger.finger_id)
        else:
            print(-1)
    elif cmd == 'delete_model':
        location = int(parts[1])
        print(finger.delete_model(location))
    elif cmd == 'create_model':
        print(finger.create_model())
    elif cmd == 'store_model':
        location = int(parts[1])
        print(finger.store_model(location))
    elif cmd == 'set_led':
        color = int(parts[1]) if len(parts) > 1 else 1
        mode = int(parts[2]) if len(parts) > 2 else 3
        speed = int(parts[3], 0) if len(parts) > 3 else 0x80
        cycles = int(parts[4]) if len(parts) > 4 else 0
        print(finger.set_led(color=color, mode=mode, speed=speed, cycles=cycles))
    else:
        print(-1)
    sys.stdout.flush()
