# frozen_string_literal: true

require 'openssl'
require 'base64'

class Encryptor
  def initialize(key)
    @cipher = OpenSSL::Cipher.new('AES-128-CBC')
    @key = key
  end

  def encrypt(data)
    iv = OpenSSL::Random.random_bytes(@cipher.iv_len)
    @cipher.iv = iv
    @cipher.encrypt
    @cipher.key = @key
    encrypted = @cipher.update(data) + @cipher.final

    safe_token = Base64.encode64(encrypted)
    safe_iv = Base64.encode64(iv)
    { encrypted_data: safe_token, iv: safe_iv }
  end

  def decrypt(encrypted_data, init_vector)
    iv = Base64.decode64(init_vector)

    encrypted_data = Base64.decode64(encrypted_data)

    @cipher.decrypt
    @cipher.iv = iv
    @cipher.key = @key
    @cipher.update(encrypted_data) + @cipher.final
  end
end
