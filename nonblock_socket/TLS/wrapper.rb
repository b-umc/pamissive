# frozen_string_literal: true
class NonBlockSocket::TLS::Wrapper < NonBlockSocket::TCP::Wrapper
  include NonBlockSocket::TCP::SocketExtensions

  def to_io
    @ssl_socket.to_io
  end

  def to_sock
    @ssl_socket
  end
end