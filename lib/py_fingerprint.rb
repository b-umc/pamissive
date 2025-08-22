class PyFingerprint
  attr_reader :finger_id, :templates

  OK = 0x00
  NOFINGER = 0x02
  IMAGEFAIL = 0x03

  def initialize(device: '/dev/ttyS2', baud: 57_600)
    script = File.expand_path('../util/fingerprint_bridge.py', __dir__)
    @io = IO.popen(['python3', '-u', script, device, baud.to_s], 'r+')
    @templates = []
  end

  def read_templates
    code, list = send_command_with_array('read_templates')
    @templates = list || []
    code
  end

  def get_image
    send_command('get_image')
  end

  def image_2_tz(slot)
    send_command("image_2_tz #{slot}")
  end

  def finger_search
    code, fid = send_command_with_fid('finger_search')
    @finger_id = fid
    code
  end

  def delete_model(location)
    send_command("delete_model #{location}")
  end

  def create_model
    send_command('create_model')
  end

  def store_model(location)
    send_command("store_model #{location}")
  end


  private

  def send_command(cmd)
    @io.puts(cmd)
    @io.flush
    @io.gets.to_i
  end

  def send_command_with_fid(cmd)
    @io.puts(cmd)
    @io.flush
    [@io.gets.to_i, @io.gets.to_i]
  end

  def send_command_with_array(cmd)
    @io.puts(cmd)
    @io.flush
    code = @io.gets.to_i
    data = @io.gets&.strip
    [code, data && data.split.map(&:to_i)]
  end
end
