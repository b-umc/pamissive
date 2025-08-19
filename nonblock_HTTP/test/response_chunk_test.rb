require 'minitest/autorun'
require_relative '../client/response'

class ResponseChunkTest < Minitest::Test
  def setup
    @response = NonBlockHTTP::Client::Response.new
  end

  def test_chunk_body_split_across_reads
    part1 = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel"
    part2 = "lo\r\n0\r\n\r\n"
    @response.parse(part1)
    refute @response.completed
    @response.parse(part2)
    assert @response.completed
    assert_equal 'hello', @response.body
  end

  def test_chunk_headers_split_across_reads
    pieces = [
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
      "5\r",
      "\nhel",
      "lo\r\n6",
      "\r\n wor",
      "ld\r\n0\r",
      "\n\r\n"
    ]
    pieces.each { |p| @response.parse(p) }
    assert @response.completed
    assert_equal 'hello world', @response.body
  end
end
