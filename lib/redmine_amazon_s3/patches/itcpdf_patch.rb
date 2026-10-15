# frozen_string_literal: true

module RedmineAmazonS3
  module Patches
    # PDF exports embed images by reading Attachment#diskfile. Enables local
    # copies of the attachments for the lifetime of the PDF document; files
    # are only downloaded when an image is actually embedded.
    module ItcpdfPatch
      def get_image_filename(attrname)
        return super unless RedmineAmazonS3.active?

        acquire_s3_local_copies
        super
      rescue *AttachmentPatch::S3_ERRORS => e
        # Like an unreadable file in core: the image is skipped
        RedmineAmazonS3.logger&.error(
          "[redmine_amazon_s3] Image #{attrname} skipped in PDF export: #{e.class}: #{e.message}"
        )
        nil
      end

      # rbpdf defines output as an alias of Output: both must release copies.
      def Output(...)
        releasing_s3_local_copies { super }
      end

      def output(...)
        releasing_s3_local_copies { super }
      end

      private

      def acquire_s3_local_copies
        return if @attachments.blank?

        @s3_local_copies ||= {}.compare_by_identity
        @attachments.each do |attachment|
          next if @s3_local_copies.key?(attachment)

          attachment.acquire_s3_local_copy
          @s3_local_copies[attachment] = true
        end
      end

      # Output destroys the document's instance variables, so the copies are
      # taken before writing it.
      def releasing_s3_local_copies
        copies = @s3_local_copies
        @s3_local_copies = nil
        yield
      ensure
        copies&.each_key(&:release_s3_local_copy)
      end
    end
  end
end
