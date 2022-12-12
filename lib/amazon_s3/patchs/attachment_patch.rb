module AmazonS3
    module Patchs
        module AttachmentPatch
            def self.included(base)
                base.send(:include, InstanceMethods)
                base.class_eval do
                    attr_accessor :s3_access_key_id, :s3_secret_acces_key, :s3_bucket, :s3_bucket
                    after_validation :put_to_s3
                    after_create     :generate_thumbnail_s3
                    before_destroy   :delete_from_s3


                    def self.disk_filename(filename, directory=nil)
                        timestamp = DateTime.now.strftime("%y%m%d%H%M%S")
                        ascii = ''
                        if %r{^[a-zA-Z0-9_\.\-]*$}.match?(filename) && filename.length <= 50
                            ascii = filename
                        else
                            ascii = Digest::MD5.hexdigest(filename)
                            # keep the extension if any
                            ascii << $1 if filename =~ %r{(\.[a-zA-Z0-9]+)$}
                        end
                        while File.exist?(File.join(storage_path, directory.to_s,
                                                    "#{timestamp}_#{ascii}"))
                            timestamp.succ!
                        end
                        "#{timestamp}_#{ascii}"
                    end

                    def self.archive_attachments(attachments)
                        attachments = attachments.select(&:readable?)
                        return nil if attachments.blank?
                    
                        Zip.unicode_names = true
                        archived_file_names = []
                        buffer = Zip::OutputStream.write_buffer do |zos|
                          attachments.each do |attachment|
                            filename = attachment.filename
                            # rename the file if a file with the same name already exists
                            dup_count = 0
                            while archived_file_names.include?(filename)
                              dup_count += 1
                              extname = File.extname(attachment.filename)
                              basename = File.basename(attachment.filename, extname)
                              filename = "#{basename}(#{dup_count})#{extname}"
                            end
                            zos.put_next_entry(filename)
                            zos << AmazonS3::Connection.get(attachment.disk_filename_s3)
                            archived_file_names << filename
                          end
                        end
                        buffer.string
                    ensure
                        buffer&.close
                    end

                    def readable?
                        true
                    end    
                end
            end

            module InstanceMethods
                def put_to_s3
                    if @temp_file && (@temp_file.size > 0) && errors.blank?
                      self.disk_directory = disk_directory || target_directory
                      self.disk_filename  = Attachment.disk_filename(filename, disk_directory) if self.disk_filename.blank?
                      logger.debug("Uploading to #{disk_filename}")
                      AmazonS3::Connection.put(disk_filename_s3, filename, @temp_file, self.content_type)
                      self.digest = Time.now.to_i.to_s
                    end
                    @temp_file = nil # so that the model's original after_save block skips writing to the fs
                end
            
                def delete_from_s3
                    logger.debug("Deleting #{disk_filename_s3}")
                    AmazonS3::Connection.delete(disk_filename_s3)
                end
                
                # Prevent file uploading to the file system to avoid change file name
                def files_to_final_location; end
                
                # Returns the full path the attachment thumbnail, or nil
                # if the thumbnail cannot be generated.
                def thumbnail_s3(options = {})
                    return unless thumbnailable?
                
                    size = options[:size].to_i
                    if size > 0
                        # Limit the number of thumbnails per image
                        size = (size / 50) * 50
                        # Maximum thumbnail size
                        size = 800 if size > 800
                    else
                        size = Setting.thumbnails_size.to_i
                    end
                    size         = 100 unless size > 0
                    target       = "#{id}_#{digest}_#{size}.thumb"
                    update_thumb = options[:update_thumb] || false
                    begin
                        AmazonS3::Thumbnail.get(self.disk_filename_s3, target, size, update_thumb)
                    rescue => e
                        logger.error "An error occured while generating thumbnail for #{disk_filename_s3} to #{target}\nException was: #{e.message}" if logger
                        return
                    end
                end
                
                def disk_filename_s3
                    path = self.disk_filename
                    path = File.join(disk_directory, path) unless disk_directory.blank?
                    path
                end
                
                def generate_thumbnail_s3
                    thumbnail_s3(update_thumb: true)
                end
            end
        end
    end
end