# Use Capistrano for deployment
group :development do
  gem 'capistrano', '~> 3.6.1', require: false
  gem 'capistrano-rails', require: false
  gem 'capistrano-bundler', require: false
  gem 'capistrano-passenger', require: false
  gem 'capistrano-shell', require: false
  gem 'capistrano-logtail', require: false
  gem 'capistrano-upload', require: false
  gem 'cap-ec2', require: false
end
