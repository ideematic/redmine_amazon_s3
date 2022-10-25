ApplicationHelper.class_eval do
  def thumbnail_tag(attachment)
    thumbnail_size = Setting.thumbnails_size.to_i

    link_to(
      image_tag(
        attachment.thumbnail_s3, 
        data: {thumbnail: thumbnail_path(attachment)},
        :style => "max-width: #{thumbnail_size}px; max-height: #{thumbnail_size}px;",
        :loading => "lazy"
      ),
      AmazonS3::Connection.object_url(attachment.disk_filename_s3),
      title: attachment.filename
    )
  end
  
end