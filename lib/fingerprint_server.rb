require 'socket'
require_relative 'py_fingerprint'

# A TCP server that exposes fingerprint sensor operations over port 8023.
# Incoming connections can issue commands:
#   eXX - enroll fingerprint at location XX
#   dXX - delete fingerprint at location XX
# The server continually waits for fingerprints and reports status messages
# back to the connected client.

class FingerprintServer
  PORT = 8023

  def initialize(device: '/dev/ttyS2', baud: 57_600)
    @finger = PyFingerprint.new(device: device, baud: baud)
  end

  def start
    server = TCPServer.new(PORT)
    loop do
      client = server.accept
      Thread.new { handle_client(client) }
    end
  end

  private

  def handle_client(client)
    loop do
      if @finger.read_templates != PyFingerprint::OK
        client.puts 'status=Failed to read templates'
        break
      end

      client.puts 'status=Waiting for fingerprint...'
      until @finger.get_image == PyFingerprint::OK
        begin
          cmd = client.read_nonblock(3)
          case cmd[0]
          when 'e'
            enroll_finger(client, cmd[1..].to_i)
          when 'd'
            if @finger.delete_model(cmd[1..].to_i) == PyFingerprint::OK
              client.puts 'status=Deleted!'
            else
              client.puts 'status=Failed to delete'
            end
          end
        rescue IO::WaitReadable
          # no command available; continue waiting for fingerprint
        rescue EOFError
          client.close
          return
        end
        sleep 0.01
      end

      client.puts 'status=Templating...'
      next unless @finger.image_2_tz(1) == PyFingerprint::OK

      client.puts 'status=Searching...'
      next unless @finger.finger_search == PyFingerprint::OK

      client.puts "status=Match Found,#{@finger.finger_id}"
      sleep 5
    end
  ensure
    client.close unless client.closed?
  end

  def enroll_finger(client, location)
    2.times do |i|
      client.puts(i.zero? ? 'status=Place finger on sensor...' : 'status=Place same finger again...')
      loop do
        img = @finger.get_image
        break if img == PyFingerprint::OK
        if img == PyFingerprint::IMAGEFAIL
          client.puts 'status=Imaging error'
          return
        end
      end

      client.puts 'status=Templating...'
      tz = @finger.image_2_tz(i + 1)
      unless tz == PyFingerprint::OK
        client.puts 'status=Other error'
        return
      end

      if i.zero?
        client.puts 'status=Remove finger'
        sleep 1
        img = @finger.get_image
        img = @finger.get_image while img != PyFingerprint::NOFINGER
      end
    end

    client.puts 'status=Creating model...'
    unless @finger.create_model == PyFingerprint::OK
      client.puts 'status=Other error'
      return
    end

    client.puts "status=Storing model ##{location}..."
    if @finger.store_model(location) == PyFingerprint::OK
      client.puts 'status=Stored'
    else
      client.puts 'status=Other error'
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  FingerprintServer.new.start
end

