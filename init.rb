require 'redmine'
require_relative 'lib/amazon_s3'
require_relative 'lib/amazon_s3_hooks'

Redmine::Plugin.register :amazon_s3 do
  name 'AmazonS3'
  version '0.0.1'
  description 'Use Amazon S3 as a storage engine for attachments'
  url 'https://github.com/jhovad/redmine4_amazon_s3'
  author 'Josef Hovad'
end

