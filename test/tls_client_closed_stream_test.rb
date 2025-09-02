# frozen_string_literal: true

require 'minitest/autorun'
require 'openssl'
require 'socket'
require 'timeout'

require_relative '../nonblock_socket/select_controller'
require_relative '../nonblock_socket/TLS/client'
require_relative '../nonblock_socket/TCP/socket_extensions'

class TLSClientClosedStreamTest < Minitest::Test
  def setup
    SelectController.instance.reset
  end

  def create_cert
    key = OpenSSL::PKey::RSA.new(2048)
    name = OpenSSL::X509::Name.parse('/CN=localhost')
    cert = OpenSSL::X509::Certificate.new
    cert.subject = name
    cert.issuer = name
    cert.public_key = key.public_key
    cert.serial = 0
    cert.version = 2
    cert.not_before = Time.now
    cert.not_after = Time.now + 3600
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = cert
    cert.add_extension(ef.create_extension('basicConstraints', 'CA:FALSE', true))
    cert.add_extension(ef.create_extension('keyUsage', 'keyEncipherment,dataEncipherment,digitalSignature'))
    cert.add_extension(ef.create_extension('subjectKeyIdentifier', 'hash'))
    cert.add_extension(ef.create_extension('authorityKeyIdentifier', 'keyid:always,issuer:always'))
    cert.sign(key, OpenSSL::Digest::SHA256.new)
    [cert, key]
  end

  def test_processes_final_chunk_before_disconnect
    cert, key = create_cert
    server_ctx = OpenSSL::SSL::SSLContext.new
    server_ctx.cert = cert
    server_ctx.key = key

    tcp_server = TCPServer.new('127.0.0.1', 0)
    ssl_server = OpenSSL::SSL::SSLServer.new(tcp_server, server_ctx)
    port = tcp_server.addr[1]

    server_thread = Thread.new do
      ssl_client = ssl_server.accept
      ssl_client.write("hi\n")
      ssl_client.close
      tcp_server.close
    end

    events = []

    handlers = {
      message: MessagePattern.new(proc { |msg, _client| events << [:message, msg] }),
      disconnect: ->(_client) { events << [:disconnect] },
      error: ->(err, _client) { events << [:error, err] }
    }

    client_ctx = OpenSSL::SSL::SSLContext.new
    client_ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE

    NonBlockSocket::TLS::Client.new('127.0.0.1', port, context: client_ctx, handlers: handlers)

    select_thread = Thread.new { SelectController.run }

    Timeout.timeout(5) do
      sleep 0.05 until events.any? { |e| e.first == :disconnect }
    end

    select_thread.kill
    server_thread.join

    assert_equal [:message, :disconnect], events.map(&:first)
    assert_equal "hi\n", events.find { |e| e.first == :message }[1]
    refute events.any? { |e| e.first == :error }
  end
end
