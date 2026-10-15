# frozen_string_literal: true

Redmine::Plugin.register :redmine_amazon_s3 do
  name 'Amazon S3 storage'
  author 'Ideematic'
  description 'Stores attachments in Amazon S3 or an S3-compatible object store'
  version '2.0.0'
  url 'https://github.com/ideematic/redmine_amazon_s3'
  requires_redmine version_or_higher: '6.0.0'
end

# init.rb runs in a to_prepare block, i.e. again after each code reload in
# development: the guards keep the patches from being prepended twice.
{
  Attachment => RedmineAmazonS3::Patches::AttachmentPatch,
  Attachment.singleton_class => RedmineAmazonS3::Patches::AttachmentPatch::ClassMethods,
  AttachmentsController => RedmineAmazonS3::Patches::AttachmentsControllerPatch,
  MailHandler => RedmineAmazonS3::Patches::MailHandlerPatch,
  Redmine::Export::PDF::ITCPDF => RedmineAmazonS3::Patches::ItcpdfPatch
}.each do |klass, patch|
  klass.prepend(patch) unless klass < patch
end

RedmineAmazonS3.boot!
