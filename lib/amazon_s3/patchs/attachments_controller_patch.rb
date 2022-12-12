module AmazonS3
    module Patchs
        module AttachmentsControllerPatch
            def self.included(base)
                base.class_eval do
                    before_action :find_thumbnail_attachment, :only => [:thumbnail]
                    skip_before_action :file_readable

                    def show
                        if @attachment.container.respond_to?(:attachments)
                          @attachments = @attachment.container.attachments.to_a
                          if index = @attachments.index(@attachment)
                            @paginator = Redmine::Pagination::Paginator.new(
                              @attachments.size, 1, index+1
                            )
                          end
                        end
                        if @attachment.is_diff?
                          @diff = AmazonS3::Connection.get(@attachment.disk_filename_s3)
                          @diff_type = params[:type] || User.current.pref[:diff_type] || 'inline'
                          @diff_type = 'inline' unless %w(inline sbs).include?(@diff_type)
                          # Save diff type as user preference
                          if User.current.logged? && @diff_type != User.current.pref[:diff_type]
                            User.current.pref[:diff_type] = @diff_type
                            User.current.preference.save
                          end
                          render :action => 'diff'
                        elsif @attachment.is_text? && @attachment.filesize <= Setting.file_max_size_displayed.to_i.kilobyte
                          @content = AmazonS3::Connection.get(@attachment.disk_filename_s3)
                          render :action => 'file'
                        elsif @attachment.is_image?
                          render :action => 'image'
                        else
                          render :action => 'other'
                        end
                    end
    
                    def download
                        if @attachment.container.is_a?(Version) || @attachment.container.is_a?(Project)
                          @attachment.increment_download
                        end

                        if stale?(:etag => @attachment.digest, :template => false)
                          # images are sent inline
                          send_data AmazonS3::Connection.get(@attachment.disk_filename_s3), :filename => filename_for_content_disposition(@attachment.filename),
                                                          :type => detect_content_type(@attachment),
                                                          :disposition => disposition(@attachment)
                        end
                    end
    
                    def find_editable_attachments
                      @attachments = @container.attachments.select(&:editable?)
                      render_404 if @attachments.empty?
                    end    
    
                    def find_thumbnail_attachment
                        update_thumb = 'true' == params[:update_thumb]
                        url          = @attachment.thumbnail_s3(update_thumb: update_thumb)
                        return render json: {src: url} if update_thumb
                        return if url.nil?
                        redirect_to(url)
                    end
                end
            end
        end
    end
end