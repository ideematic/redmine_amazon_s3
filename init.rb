Redmine::Plugin.register :amazon_s3 do
  name 'AmazonS3'
  version '0.0.1'
  description 'Use Amazon S3 as a storage engine for attachments'
  url 'https://github.com/jhovad/redmine4_amazon_s3'
  author 'Josef Hovad'
  requires_redmine version_or_higher: '5.0.0'
end


Attachment.send(:include, AmazonS3::Patchs::AttachmentPatch)
ApplicationHelper.send(:include, AmazonS3::Patchs::ApplicationHelperPatch)
AttachmentsController.send(:include, AmazonS3::Patchs::AttachmentsControllerPatch)