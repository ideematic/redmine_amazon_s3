# frozen_string_literal: true

require_relative '../test_helper'

# Full Rack stack: uploads through the API and streamed downloads. Uses the
# in-memory fake S3 by default; set S3_TEST_ENDPOINT (plus S3_TEST_BUCKET,
# S3_TEST_ACCESS_KEY_ID, S3_TEST_SECRET_ACCESS_KEY) to run against a real
# S3-compatible server, e.g. SeaweedFS on http://127.0.0.1:8333.
class RedmineAmazonS3::S3DownloadTest < Redmine::IntegrationTest
  def setup
    set_tmp_attachments_directory
    if live?
      RedmineAmazonS3.configuration = RedmineAmazonS3::Configuration.new(
        {
          endpoint: ENV['S3_TEST_ENDPOINT'], force_path_style: true, region: 'us-east-1',
          bucket: ENV.fetch('S3_TEST_BUCKET', 'redmine-test'), prefix: "test-#{SecureRandom.hex(4)}",
          access_key_id: ENV['S3_TEST_ACCESS_KEY_ID'], secret_access_key: ENV['S3_TEST_SECRET_ACCESS_KEY']
        }
      )
    else
      enable_fake_s3
    end
    Setting.rest_api_enabled = '1'
  end

  def teardown
    disable_fake_s3
  end

  def test_api_upload_then_streamed_download_and_delete
    content = SecureRandom.random_bytes(300_000)
    post(
      '/uploads.json?filename=random.bin', params: content,
      headers: {'CONTENT_TYPE' => 'application/octet-stream'}.merge(credentials('jsmith'))
    )
    assert_response :created
    token = response.parsed_body['upload']['token']
    attachment = Attachment.find(token.split('.').first)
    assert_equal Digest::SHA256.hexdigest(content), attachment.digest
    assert RedmineAmazonS3.storage.exists?(attachment.s3_key)

    attachment.update!(container: Issue.find(1))
    get "/attachments/download/#{attachment.id}/random.bin"
    assert_response :success
    assert_equal content.bytesize.to_s, response.headers['Content-Length']
    assert_equal content, response.body.b
    assert_equal RedmineAmazonS3::CONTENT_SECURITY_POLICY, response.headers['Content-Security-Policy']

    gets = live? ? nil : @fake_s3.requests(:get_object).size
    head "/attachments/download/#{attachment.id}/random.bin"
    assert_response :success
    assert_equal content.bytesize.to_s, response.headers['Content-Length']
    assert_equal gets, @fake_s3.requests(:get_object).size, 'HEAD should not read the object' unless live?

    key = attachment.s3_key
    delete "/attachments/#{attachment.id}.json", headers: credentials('admin')
    assert_response :no_content
    assert_not RedmineAmazonS3.storage.exists?(key)
  end

  private

  def live?
    ENV['S3_TEST_ENDPOINT'].present?
  end
end
