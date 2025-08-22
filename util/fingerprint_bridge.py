import sys
import serial
import adafruit_fingerprint


device = sys.argv[1] if len(sys.argv) > 1 else '/dev/ttyS2'
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 57600

uart = serial.Serial(device, baudrate=baud, timeout=1)
finger = adafruit_fingerprint.Adafruit_Fingerprint(uart)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    print(f"CMD: {line}", file=sys.stderr)
    parts = line.split()
    cmd = parts[0]
    if cmd == 'read_templates':
        result = finger.read_templates()
        print(result)
    elif cmd == 'get_image':
        result = finger.get_image()
        print(result)
    elif cmd == 'image_2_tz':
        slot = int(parts[1])
        result = finger.image_2_tz(slot)
        print(result)
    elif cmd == 'finger_search':
        code = finger.finger_search()
        print(code)
        if code == adafruit_fingerprint.OK:
            print(finger.finger_id)
        else:
            print(-1)
    elif cmd == 'delete_model':
        location = int(parts[1])
        result = finger.delete_model(location)
        print(result)
    elif cmd == 'create_model':
        result = finger.create_model()
        print(result)
    elif cmd == 'store_model':
        location = int(parts[1])
        result = finger.store_model(location)
        print(result)
    else:
        result = -1
        print(result)
    sys.stdout.flush()
    print(f"RES: {result}", file=sys.stderr)
    sys.stderr.flush()
