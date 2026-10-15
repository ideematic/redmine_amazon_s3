# frozen_string_literal: true

require 'aws-sdk-s3'

module RedmineAmazonS3
  # Thin wrapper around Aws::S3::Client for the operations the plugin needs.
  # One client is shared by all threads (Aws::S3::Client is thread safe).
  class Storage
    attr_reader :config

    def initialize(config)
      @config = config
      @mutex = Mutex.new
    end

    def client
      @client || @mutex.synchronize { @client ||= Aws::S3::Client.new(config.client_options) }
    end

    # Injects a client, e.g. Aws::S3::Client.new(stub_responses: true) in tests.
    attr_writer :client

    def bucket
      config.bucket
    end

    def inspect
      "#<#{self.class.name} bucket=#{bucket.inspect} prefix=#{config.key_prefix.inspect}>"
    end

    # Object key of an attachment. Same layout as the legacy plugin:
    # <prefix><disk_directory>/<disk_filename>
    def key_for(disk_directory, disk_filename)
      config.key_prefix + [disk_directory, disk_filename].map(&:to_s).compact_blank.join('/')
    end

    # Returns the head_object response, or nil when the object does not exist.
    # S3 answers 403 instead of 404 for a missing key when the credentials lack
    # s3:ListBucket, so Forbidden is logged and treated as missing too.
    # Network and server errors are raised.
    def head(key)
      client.head_object(bucket: bucket, key: key)
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      nil
    rescue Aws::S3::Errors::Forbidden
      RedmineAmazonS3.logger.error(
        "[redmine_amazon_s3] Access denied on HEAD #{key}; " \
          "check that the credentials have s3:GetObject and s3:ListBucket on #{bucket}"
      )
      nil
    end

    def exists?(key)
      !head(key).nil?
    end

    # Uploads a local file, switching to multipart above multipart_threshold.
    def upload(path, key, content_type: nil)
      options = {bucket: bucket, key: key, multipart_threshold: config.multipart_threshold}
      options[:content_type] = content_type if content_type.present?
      options[:if_none_match] = '*' if config.conditional_writes
      options.merge!(config.sse_options)
      transfer_manager.upload_file(path, **options)
    end

    def delete(key)
      client.delete_object(bucket: bucket, key: key)
    end

    # Streams the object (or a byte range like "bytes=1024-"), yielding
    # chunks as they arrive.
    def each_chunk(key, range: nil, &)
      params = {bucket: bucket, key: key}
      params[:range] = range if range
      client.get_object(params, &)
    end

    # Reads bytes first..last (inclusive) into memory.
    def read_range(key, first, last)
      client.get_object(bucket: bucket, key: key, range: "bytes=#{first}-#{last}").body.read
    end

    # Downloads the object to a local path.
    def download_to(key, path)
      client.get_object(bucket: bucket, key: key, response_target: path)
      path
    end

    def read(key)
      client.get_object(bucket: bucket, key: key).body.read
    end

    private

    def transfer_manager
      Aws::S3::TransferManager.new(client: client)
    end
  end
end
