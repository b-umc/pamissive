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
    else:
        print(-1)
    sys.stdout.flush()
