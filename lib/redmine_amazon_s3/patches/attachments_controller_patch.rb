# frozen_string_literal: true

module RedmineAmazonS3
  module Patches
    # Serves attachments stored in S3 through Redmine. Authorization, ETag,
    # download counters, file name and disposition are all left to core
    # AttachmentsController; only the file access is redirected to S3.
    module AttachmentsControllerPatch
      # Bytes read before sending headers. Smaller files are served from
      # memory; S3 errors on this first read return a proper error page.
      FIRST_PART_SIZE = 256 * 1024

      # Core #show reads diffs and text files with File.read(diskfile).
      def show
        return super unless RedmineAmazonS3.active? && @attachment

        @attachment.with_s3_local_copy { super }
      end

      private

      def send_file(path, options = {})
        if RedmineAmazonS3.active? && @attachment && path == @attachment.diskfile
          send_s3_object(@attachment, options)
        else
          super
        end
      end

      # Streams the object without buffering it. Same headers as core
      # #send_file, including its CSP sandbox.
      def send_s3_object(attachment, options)
        head = attachment.s3_head
        return render_404 if head.nil?

        size = head.content_length
        first_part = read_first_part(attachment, size) unless request.head?
        return if performed?

        headers['content-security-policy'] = RedmineAmazonS3::CONTENT_SECURITY_POLICY
        send_file_headers!(options)
        self.status = options[:status] || 200
        headers['Content-Length'] = size.to_s
        self.response_body = RedmineAmazonS3::ObjectBody.new(
          RedmineAmazonS3.storage, attachment.s3_key, size: size, first_part: first_part
        )
      end

      def read_first_part(attachment, size)
        return ''.b if size.zero?

        RedmineAmazonS3.storage.read_range(attachment.s3_key, 0, [size, FIRST_PART_SIZE].min - 1)
      rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
        render_404
      rescue *AttachmentPatch::S3_ERRORS => e
        logger&.error("Could not read S3 object '#{attachment.s3_key}': #{e.class}: #{e.message}")
        render_error(message: :error_redmine_amazon_s3_download_failed, status: 503)
      end
    end
  end
end
