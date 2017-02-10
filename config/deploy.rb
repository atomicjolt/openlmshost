# config valid only for current version of Capistrano
# lock '3.6.1'

set :application, 'openlmshost'
set :repo_url, 'git@github.com:atomicjolt/canvas-lms.git'

# Default branch is :master
# ask :branch, `git rev-parse --abbrev-ref HEAD`.chomp
set :branch, 'stable'

# Default deploy_to directory is /var/www/my_app_name
set :deploy_to, '/srv/www/openlmshost'

set :rails_env, 'production'

# Default value for :scm is :git
# set :scm, :git

# Default value for :format is :airbrussh.
# set :format, :airbrussh

# You can configure the Airbrussh format using :format_options.
# These are the defaults.
# set :format_options, command_output: true, log_file: 'log/capistrano.log', color: :auto, truncate: :auto

# Default value for :pty is false
# set :pty, true

# Default value for :linked_files is []
append :linked_files, 'config/database.yml', 'config/amazon_s3.yml', 'config/cassandra.yml', 'config/domain.yml', 'config/fontcustom.yml', 'config/security.yml', 'config/database.yml', 'config/external_migration.yml', 'config/outgoing_mail.yml', 'config/styleguide.yml', 'config/browsers.yml', 'config/delayed_jobs.yml', 'config/file_store.yml', 'config/redis.yml', 'config/testem.yml', 'Gemfile.lock', 'config/bb_importer_credentials.yml', 'config/dynamic_settings.yml', 'config/etherpad.yml'

# Default value for linked_dirs is []
append :linked_dirs, 'log', 'tmp', 'node_modules', 'public/assets', 'public/stylesheets', 'vendor/QTIMigrationTool', 'gems/plugins/analytics'

# Default value for default_env is {}
# set :default_env, { path: "/opt/ruby/bin:$PATH" }

# Default value for keep_releases is 5
set :keep_releases, 2
set :bundle_without, %w{sqlite}.join(' ')
set :bundle_flags, '--quiet'
set :user, 'canvas'

namespace :canvas do

  desc "Fix ownership on canvas install directory"
  task :setup_permissions do
    on roles(:all) do
      user = fetch :user

      execute :sudo, 'chown', '-R', "#{user}", "#{release_path}/config/environment.rb"
      execute :sudo, 'chown', '-R', "#{user}", "#{release_path}/log"
      execute :sudo, 'chown', '-R', "#{user}", "#{release_path}/tmp"
      execute :sudo, 'chown', '-R', "#{user}", "#{release_path}/public/assets"
      execute :sudo, 'chown', '-R', "#{user}", "#{release_path}/Gemfile.lock"
      execute :sudo, 'chown', '-R', "#{user}", "#{release_path}/config.ru"

      execute :sudo, 'chown', '-R', "#{user}", "#{release_path}/app/stylesheets"
      execute :sudo, 'chown', '-R', "#{user}", "#{release_path}/public/stylesheets/compiled"
      execute :sudo, 'chown', '-R', "#{user}", "#{release_path}/public/dist/brandable_css/"

      execute :sudo, 'chown', '-R', "#{user}", "#{release_path}/config/*.yml"
      execute :sudo, 'chmod', '440', "#{release_path}/config/*.yml"
    end
  end

  desc "Install node dependencies"
  task :npm_install do
    on roles(:all) do
      within release_path do
        execute :npm, 'install', '--silent'
      end
    end
  end

  desc "Compile static assets"
  task :compile_assets => :npm_install do
    on roles(:all) do
      within release_path do
        with rails_env: fetch(:rails_env) do
          execute :rake, 'canvas:compile_assets[false]'
        end
      end
    end
  end

  desc "Rebuild brand_configs"
  task :build_brand_configs do
    on primary :db do
      within release_path do
        with rails_env: fetch(:rails_env) do
          execute 'node_modules/.bin/gulp', 'rev'
          execute :rake, "brand_configs:generate_and_upload_all"
        end
      end
    end
  end

  desc "Run predeploy db migration task"
  task :migrate_predeploy do
    on primary :db do
      within release_path do
        with rails_env: fetch(:rails_env) do
          execute :rake, "db:migrate:predeploy"
        end
      end
    end
  end

  desc "Load new notification types"
  task :load_notifications do
    on primary :db do
      within release_path do
        with rails_env: fetch(:rails_env) do
          execute :rake, 'db:load_notifications'
        end
      end
    end
  end

  # TODO: create a separate job-processor role for this task
  namespace :delayed_jobs do
    %w[start stop restart].each do |command|
      desc "#{command} the delayed_jobs processor"
      task command do
        user = fetch :user
        on roles(:worker) do
          execute :sudo, "-u #{user}", "/etc/init.d/canvas_init #{command}"
        end
      end
    end
  end

  namespace :meta_tasks do

    desc "Tasks that need to run before _started_"
    task :before_started do
      invoke 'canvas:delayed_jobs:stop'
    end

    desc "Tasks that need to run before _updated_"
    task :before_updated do
      invoke 'canvas:migrate_predeploy'
    end

    desc "Tasks that run after _updated_"
    task :after_updated do
      invoke 'canvas:setup_permissions'
      invoke 'canvas:compile_assets'
      invoke 'canvas:build_brand_configs' if Rake::Task.task_defined?("canvas:build_brand_configs")

      invoke 'canvas:load_notifications'
    end

    desc "Tasks that run after _published_"
    task :after_published do
      invoke 'canvas:delayed_jobs:start'
    end
  end
end


before 'deploy:started', 'canvas:meta_tasks:before_started'
before 'deploy:updated', 'canvas:meta_tasks:before_updated'
after 'deploy:updated', 'canvas:meta_tasks:after_updated'
after 'deploy:published', 'canvas:meta_tasks:after_published'
