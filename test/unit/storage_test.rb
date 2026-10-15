# frozen_string_literal: true

require_relative '../test_helper'

class RedmineAmazonS3::StorageTest < ActiveSupport::TestCase
  def setup
    @s3 = enable_fake_s3
    @storage = RedmineAmazonS3.storage
  end

  def teardown
    disable_fake_s3
  end

  def test_key_for_should_join_prefix_directory_and_filename
    assert_equal 'att/2026/10/file.txt', @storage.key_for('2026/10', 'file.txt')
  end

  def test_key_for_without_directory_should_not_have_double_slash
    assert_equal 'att/file.txt', @storage.key_for(nil, 'file.txt')
    assert_equal 'att/file.txt', @storage.key_for('', 'file.txt')
  end

  def test_head_should_return_nil_for_missing_object
    assert_nil @storage.head('att/missing')
  end

  def test_head_should_return_nil_and_log_when_forbidden
    @s3.client.stub_responses(:head_object, 'Forbidden')
    assert_nil @storage.head('att/secret')
  end

  def test_head_should_raise_on_server_errors
    @s3.client.stub_responses(:head_object, 'ServiceUnavailable')
    assert_raise(Aws::S3::Errors::ServiceUnavailable) { @storage.head('att/file') }
  end

  def test_upload_should_send_content_type
    with_upload_file('data') { |path| @storage.upload(path, 'att/key', content_type: 'text/plain') }
    request = @s3.requests(:put_object).last
    assert_equal 'test-bucket', request[:params][:bucket]
    assert_equal 'text/plain', request[:params][:content_type]
    assert_equal 'data', @s3.data('att/key')
  end

  def test_upload_should_send_sse_and_conditional_write_options
    enable_fake_s3(sse: 'AES256', conditional_writes: true)
    s3 = @fake_s3
    with_upload_file('data') { |path| RedmineAmazonS3.storage.upload(path, 'att/key') }
    params = s3.requests(:put_object).last[:params]
    assert_equal 'AES256', params[:server_side_encryption]
    assert_equal '*', params[:if_none_match]
  end

  def test_each_chunk_and_read_and_delete
    with_upload_file('streamed content') { |path| @storage.upload(path, 'att/key') }
    chunks = []
    @storage.each_chunk('att/key') { |chunk| chunks << chunk }
    assert_equal 'streamed content', chunks.join
    assert_equal 'streamed content', @storage.read('att/key')
    @storage.delete('att/key')
    assert_not @storage.exists?('att/key')
  end

  private

  def with_upload_file(content)
    Tempfile.create('upload') do |file|
      file.write(content)
      file.flush
      yield file.path
    end
  end
end
