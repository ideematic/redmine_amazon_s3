# frozen_string_literal: true

require 'aws-sdk-s3'
require 'tempfile'

module RedmineAmazonS3
  module Patches
    # Stores attachment files in S3 instead of the local files directory.
    #
    # Every override calls super when the plugin is inactive. Thumbnails stay
    # in Redmine's local cache (tmp/thumbnails): they are derived data, keyed
    # by digest, and regenerated from S3 when missing.
    module AttachmentPatch
      S3_ERRORS = [
        Aws::Errors::ServiceError, Seahorse::Client::NetworkingError,
        Aws::S3::MultipartUploadError, Aws::Errors::MissingCredentialsError
      ].freeze
      # Errors while buffering the upload locally (e.g. disk full)
      UPLOAD_ERRORS = (S3_ERRORS + [SystemCallError, IOError]).freeze

      module ClassMethods
        def archive_attachments(attachments)
          return super unless RedmineAmazonS3.active?

          attachments = attachments.to_a
          begin
            attachments.each(&:acquire_s3_local_copy)
            super(attachments)
          ensure
            attachments.each(&:release_s3_local_copy)
          end
        end
      end

      def s3_key
        RedmineAmazonS3.storage.key_for(disk_directory, disk_filename)
      end

      # Memoized head_object response, nil if the object does not exist.
      # The cache is tied to the key, so changing disk_filename invalidates it.
      def s3_head
        key = s3_key
        return @s3_head[1] if @s3_head && @s3_head[0] == key

        head = disk_filename.present? ? RedmineAmazonS3.storage.head(key) : nil
        @s3_head = [key, head]
        head
      end

      def reset_s3_head
        @s3_head = nil
      end

      def readable?
        return super unless RedmineAmazonS3.active?

        !s3_head.nil?
      end

      def reload(*)
        reset_s3_head
        super
      end

      # Uploads the incoming file to S3. Mirrors core: same directory layout,
      # SHA256 digest computed while reading 8 KB chunks.
      def files_to_final_location
        return super unless RedmineAmazonS3.active? && @temp_file

        self.disk_directory = target_directory
        self.disk_filename = s3_disk_filename
        key = s3_key
        Tempfile.create(['redmine_s3_upload', File.extname(disk_filename)], Rails.root.join('tmp').to_s,
                        binmode: true) do |tmp|
          self.digest = copy_temp_file_to(tmp)
          tmp.flush
          logger&.info("Saving attachment '#{key}' to S3 (#{tmp.size} bytes)")
          RedmineAmazonS3.storage.upload(tmp.path, key, content_type: s3_content_type)
        end
        delete_s3_object_on_rollback(key)
        reset_s3_head
        @temp_file = nil
        super
      rescue *UPLOAD_ERRORS => e
        logger&.error("Could not upload attachment '#{filename}' to S3: #{e.class}: #{e.message}")
        raise RedmineAmazonS3::UploadError, e.message if RedmineAmazonS3.raise_upload_errors?

        errors.add(:base, l(:error_redmine_amazon_s3_upload_failed))
        throw :abort
      end

      def update_digest_to_sha256!
        return super unless RedmineAmazonS3.active?
        return unless readable?

        sha = Digest::SHA256.new
        RedmineAmazonS3.storage.each_chunk(s3_key) { |chunk| sha.update(chunk) }
        update_column :digest, sha.hexdigest
      end

      def move_to_target_directory!
        return super unless RedmineAmazonS3.active?

        logger&.warn("Attachment ##{id}: moving files is not supported with S3 storage, skipped")
      end

      # Returns the full path of the thumbnail. A missing thumbnail is generated
      # from a temporary local copy of the S3 object.
      def thumbnail(options = {})
        return super unless RedmineAmazonS3.active?
        return nil unless thumbnailable? && readable?

        # Core would evaluate #diskfile first, which downloads the original
        # inside a local copy scope (PDF export) even though it is not needed.
        target = thumbnail_path(normalized_thumbnail_size(options))
        return target if File.exist?(target)

        with_s3_local_copy { super }
      end

      # Inside the block, #diskfile downloads the object to a temporary file on
      # first call and returns its path, so core code that reads the file from
      # disk works unchanged. Nothing is downloaded unless #diskfile is called.
      def with_s3_local_copy
        acquire_s3_local_copy
        yield
      ensure
        release_s3_local_copy
      end

      def acquire_s3_local_copy
        @s3_local_copy_depth = @s3_local_copy_depth.to_i + 1
      end

      def release_s3_local_copy
        @s3_local_copy_depth = @s3_local_copy_depth.to_i - 1
        return if @s3_local_copy_depth.positive?

        @s3_local_copy_depth = 0
        @s3_local_copy&.close!
        @s3_local_copy = nil
      end

      def diskfile
        if RedmineAmazonS3.active? && @s3_local_copy_depth.to_i.positive? && disk_filename.present?
          s3_local_copy_path
        else
          super
        end
      end

      private

      def s3_local_copy_path
        return @s3_local_copy.path if @s3_local_copy

        tmp = Tempfile.new(['redmine_s3', File.extname(disk_filename)], binmode: true)
        tmp.close
        begin
          RedmineAmazonS3.storage.download_to(s3_key, tmp.path)
        rescue StandardError
          tmp.close!
          raise
        end
        @s3_local_copy = tmp
        tmp.path
      end

      # Core's after_rollback only runs for records that were inserted. This
      # also removes the object when the INSERT itself fails or a later
      # before_create callback aborts. The key is unique to this upload.
      def delete_s3_object_on_rollback(key)
        self.class.current_transaction.after_rollback do
          RedmineAmazonS3.storage.delete(key)
        rescue *S3_ERRORS => e
          logger&.error("Could not delete S3 object '#{key}' after rollback: #{e.class}: #{e.message}")
        end
      end

      # The content type is sent as an HTTP header: skip values that could
      # break it. Downloads use the database value anyway.
      def s3_content_type
        value = content_type.presence || Redmine::MimeType.of(filename)
        value if value.present? && value.length <= 255 && !value.match?(/[[:cntrl:]]/)
      end

      def copy_temp_file_to(io)
        sha = Digest::SHA256.new
        # A failed save may be retried with the same IO
        @temp_file.rewind if @s3_temp_file_read && @temp_file.respond_to?(:rewind)
        @s3_temp_file_read = true
        if @temp_file.respond_to?(:read)
          while (buffer = @temp_file.read(8192))
            io.write(buffer)
            sha.update(buffer)
          end
        else
          io.write(@temp_file)
          sha.update(@temp_file)
        end
        sha.hexdigest
      end

      # Same naming scheme as Attachment.create_diskfile, plus a random part:
      # S3 has no exclusive create, so two uploads of the same file name in
      # the same second must never get the same key.
      def s3_disk_filename
        timestamp = DateTime.now.strftime('%y%m%d%H%M%S')
        max_filename_length = 50
        if %r{^[a-zA-Z0-9_.-]*$}.match?(filename) && filename.length <= max_filename_length
          ascii = filename.dup
        else
          ascii = ActiveSupport::Digest.hexdigest(filename)
          # keep the extension if any
          if filename =~ %r{(\.[a-zA-Z0-9]+)$} && (ascii.length + $1.length) <= max_filename_length
            ascii << $1
          end
        end
        "#{timestamp}_#{SecureRandom.hex(4)}_#{ascii}"
      end

      # Same size rules as core Attachment#thumbnail.
      def normalized_thumbnail_size(options)
        size = options[:size].to_i
        if size > 0
          size = (size / 50.0).ceil * 50
          size = 800 if size > 800
        else
          size = Setting.thumbnails_size.to_i
        end
        size > 0 ? size : 100
      end

      # Deduplication: when another attachment has the same SHA256 digest and
      # size, point this record at its object and drop ours if unreferenced.
      # Digests shorter than 64 characters (MD5, or timestamps written by the
      # legacy plugin) are never trusted.
      def reuse_existing_file_if_possible
        return super unless RedmineAmazonS3.active?
        return if disk_filename.blank? || digest.to_s.size != 64

        original_key = s3_key
        original_filename = disk_filename
        reused = with_lock do
          existing = Attachment
                       .where(digest: digest, filesize: filesize)
                       .where.not(disk_filename: original_filename)
                       .order(:id)
                       .last
          existing&.with_lock do
            existing_head = existing.s3_head
            if existing_head && existing_head.content_length == filesize
              update_columns(disk_directory: existing.disk_directory, disk_filename: existing.disk_filename)
            end
          end
        end
        reset_s3_head
        if reused && Attachment.where(disk_filename: original_filename).none?
          RedmineAmazonS3.storage.delete(original_key)
        end
      rescue ActiveRecord::StatementInvalid, ActiveRecord::RecordNotFound
        # Same as core: deduplication is optional, lock errors are ignored.
      rescue *S3_ERRORS => e
        logger&.warn("Attachment ##{id}: S3 deduplication skipped: #{e.class}: #{e.message}")
      end

      # Core keys thumbnails by digest and size. Digests written by the legacy
      # plugin are timestamps, so two images uploaded in the same second with
      # the same size would share a thumbnail: add the id for those.
      def thumbnail_path(size)
        return super unless RedmineAmazonS3.active? && digest.to_s.size < 64

        File.join(self.class.thumbnails_storage_path, "#{id}_#{digest}_#{filesize}_#{size}.thumb")
      end

      # Called by core #delete_from_disk only when no other attachment
      # references the same disk_filename.
      def delete_from_disk!
        return super unless RedmineAmazonS3.active?

        if disk_filename.present?
          begin
            RedmineAmazonS3.storage.delete(s3_key)
          rescue *S3_ERRORS => e
            logger&.error("Could not delete S3 object '#{s3_key}': #{e.class}: #{e.message}")
          end
        end
        Dir[thumbnail_path('*')].each do |thumb|
          File.delete(thumb)
        end
        reset_s3_head
      end
    end
  end
end
