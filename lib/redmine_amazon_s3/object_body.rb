# frozen_string_literal: true

module RedmineAmazonS3
  # Rack response body that streams an S3 object in chunks, so downloads never
  # load the whole file in memory.
  #
  # The controller reads the first part of the object before sending headers
  # (see AttachmentsControllerPatch#send_s3_object): S3 errors at that point
  # still produce a proper error response. The rest is streamed from +offset+
  # on the first #each, so HEAD and 304 responses never hit S3.
  #
  # Must not respond to #to_path, otherwise Rack::Sendfile and Puma would look
  # for a local file. The caller must set Content-Length and an ETag, otherwise
  # Rack::ContentLength or Rack::ETag would iterate the body to compute them.
  class ObjectBody
    def initialize(storage, key, size:, first_part: nil)
      @storage = storage
      @key = key
      @size = size
      @first_part = first_part
    end

    def each(&block)
      return enum_for(:each) unless block

      offset = 0
      if @first_part
        yield @first_part.b
        offset = @first_part.bytesize
      end
      return if offset >= @size

      # Chunks are raw bytes, whatever encoding the SDK tags them with
      @storage.each_chunk(@key, range: "bytes=#{offset}-") { |chunk| yield chunk.b }
    rescue *Patches::AttachmentPatch::S3_ERRORS => e
      # Headers are already sent: the client gets a truncated response.
      RedmineAmazonS3.logger&.error(
        "[redmine_amazon_s3] Download of '#{@key}' interrupted: #{e.class}: #{e.message}"
      )
      raise
    end

    def close; end
  end
end
