# frozen_string_literal: true

# Plugin tests run from the Redmine root (rake redmine:plugins:test), and the
# plugin directory may be a symlink, so resolve Redmine's helper from there.
require File.expand_path('test/test_helper', Dir.pwd)

module RedmineAmazonS3
  module TestHelper
    # In-memory S3 built on the SDK's stubbed client, so tests exercise the
    # real request building without any network access.
    class FakeS3
      attr_reader :objects, :client

      def initialize
        @objects = {}
        @client = Aws::S3::Client.new(
          stub_responses: true, region: 'us-east-1',
          credentials: Aws::Credentials.new('test', 'test')
        )
        stub_object_operations
      end

      def requests(operation = nil)
        client.api_requests.select { |r| operation.nil? || r[:operation_name] == operation }
      end

      def data(key)
        objects.dig(key, :data)
      end

      private

      def stub_object_operations
        client.stub_responses(:put_object, lambda { |ctx|
          body = ctx.params[:body]
          data = body.respond_to?(:read) ? body.read : body.to_s
          objects[ctx.params[:key]] = {data: data.b, content_type: ctx.params[:content_type]}
          {etag: '"etag"'}
        })
        client.stub_responses(:head_object, lambda { |ctx|
          object = objects[ctx.params[:key]]
          object ? {content_length: object[:data].bytesize, content_type: object[:content_type]} : 'NotFound'
        })
        client.stub_responses(:get_object, lambda { |ctx|
          object = objects[ctx.params[:key]]
          next 'NoSuchKey' unless object

          data = object[:data]
          if (range = ctx.params[:range]) && (m = range.match(/\Abytes=(\d+)-(\d*)\z/))
            last = m[2].empty? ? data.bytesize - 1 : [m[2].to_i, data.bytesize - 1].min
            data = data.byteslice(m[1].to_i..last)
          end
          {body: data, content_length: data.bytesize}
        })
        client.stub_responses(:delete_object, lambda { |ctx|
          objects.delete(ctx.params[:key])
          {}
        })
      end
    end

    def enable_fake_s3(options = {})
      @fake_s3 = FakeS3.new
      RedmineAmazonS3.configuration = RedmineAmazonS3::Configuration.new(
        {bucket: 'test-bucket', region: 'us-east-1', prefix: 'att'}.merge(options)
      )
      RedmineAmazonS3.storage.client = @fake_s3.client
      @fake_s3
    end

    # Explicitly inactive, whatever config/amazon_s3.yml contains.
    def disable_fake_s3
      RedmineAmazonS3.configuration = RedmineAmazonS3::Configuration.new(nil, present: false)
    end

    def create_s3_attachment(content: 'Hello S3', filename: 'hello.txt', content_type: 'text/plain', **attributes)
      Attachment.create!(
        {file: content, filename: filename, content_type: content_type, author: User.find(1)}.merge(attributes)
      )
    end

    def fixture_file_content(name)
      File.binread(File.join(Rails.root, 'test', 'fixtures', 'files', name))
    end
  end
end

ActiveSupport::TestCase.include RedmineAmazonS3::TestHelper
