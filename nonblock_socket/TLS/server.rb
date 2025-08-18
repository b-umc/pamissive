# frozen_string_literal: true

require 'socket'
require 'fcntl'
require 'openssl'
require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative '../select_controller'
require_relative '../TCP/server'

module NonBlockSocket; end
module NonBlockSocket::TLS; end

class NonBlockSocket::TLS::Server < NonBlockSocket::TCP::Server
  CERT_NOT_BEFORE = Time.now
  CERT_NOT_AFTER = Time.now + 365 * 24 * 60 * 60 # one year validity
  CERT_VERSION = 2
  CERT_SERIAL = 1

  def initialize(**kwargs)
    super(**kwargs)
    @ssl_context = kwargs[:ssl_context] || create_default_ssl_context
  end

  private

  def create_default_ssl_context
    context = OpenSSL::SSL::SSLContext.new
    context.cert, context.key = create_self_signed_cert
    context.ssl_version = :TLSv1_2 # rubocop:disable Naming/VariableNumber
    context
  end

  def cert_details(cert, name, key)
    cert.version = CERT_VERSION
    cert.serial = CERT_SERIAL
    cert.not_before = CERT_NOT_BEFORE
    cert.not_after = CERT_NOT_AFTER
    cert.public_key = key.public_key
    cert.subject = name
    cert.issuer = name
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
  end

  def create_self_signed_cert
    name = OpenSSL::X509::Name.parse('CN=localhost')
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert_details(cert, name, key)

    [cert, key]
  end

  def setup_client(client)
    client.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK)
    ssl_client = OpenSSL::SSL::SSLSocket.new(client, @ssl_context)
    ssl_client.sync_close = true
    return ssl_client unless attempt_accept(ssl_client)

    ssl_client.extend(NonBlockSocket::TCP::SocketExtensions)
    @handlers.each { |k, v| ssl_client.on(k, v) }
    ssl_client.connected
  end

  def attempt_accept(ssl_client)
    ssl_client.accept_nonblock
    true
  rescue IO::WaitReadable, IO::WaitWritable
    false
  end
end
