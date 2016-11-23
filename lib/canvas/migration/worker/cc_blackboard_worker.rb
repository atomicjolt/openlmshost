#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#
require 'pandarus'
require 'rest-client'
require 'open-uri'
require 'fileutils'

class Canvas::Migration::Worker::CCBlackboardWorker < Canvas::Migration::Worker::Base
  def perform(cm=nil)
    cm ||= ContentMigration.where(id: migration_id).first
    cm.job_progress.start unless cm.skip_job_progress
    begin
      cm.update_conversion_progress(1)
      settings = cm.migration_settings.clone
      settings[:content_migration_id] = migration_id
      settings[:user_id] = cm.user_id
      settings[:content_migration] = cm

      if cm.attachment
        settings[:attachment_id] = cm.attachment.id
      elsif settings[:file_url]
        # create attachment and download file
        att = Canvas::Migration::Worker.download_attachment(cm, settings[:file_url])
        settings[:attachment_id] = att.id
      elsif !settings[:no_archive_file]
        raise Canvas::Migration::Error, I18n.t(:no_migration_file, "File required for content migration.")
      end

      converter_class = settings[:converter_class]
      unless converter_class
        if settings[:no_archive_file]
          raise ArgumentError, "converter_class required for content migration with no file"
        end
        settings[:archive] = Canvas::Migration::Archive.new(settings)
        converter_class = settings[:archive].get_converter
      end

      import_file = get_import_file(settings)
      importer_credentials = YAML.load_file('./config/bb_importer_credentials.yml')

      canvas = Pandarus::Client.new(
        account_id: importer_credentials['account_id'],
        prefix: importer_credentials['api_endpoint'],
        token: importer_credentials['access_token']
      )

      begin
        temp_course = canvas.create_new_course (
          {
            'course__name__' => "temp_course",
            'course__course_code__' => "course_code",
            'course__public_description__' => "course_description"
          }
        )
      rescue Footrest::HttpError::Forbidden => e
        raise e
      rescue Footrest::HttpError::ErrorBase => e
        raise e
      rescue Faraday::ConnectionFailed => e
        raise e
      end

      begin
        new_migration = canvas.create_content_migration_courses(
          temp_course.id,
          'blackboard_exporter',
          {
            'pre_attachment__name__' => File.basename(import_file.path),
            'selective_import' => false
          },
        )

        pre = new_migration.pre_attachment

        upload_url = pre['upload_url']
        upload_params = pre['upload_params']
      rescue Footrest::HttpError::Forbidden => e
        raise e
      rescue Footrest::HttpError::ErrorBase => e
        raise e
      end

      upload_params['file'] = import_file

      begin
        puts "Uploaded #{RestClient.post(upload_url, upload_params)}"
      rescue RestClient::Exception => e # Failed request
        raise e
      end

      migration = canvas.get_content_migration_courses(temp_course.id, new_migration.id)

      progress_url = migration.progress_url
      progress_id = /\/([^\/]+)$/.match(progress_url)[1]

      done = false

      until done
        response = canvas.query_progress(progress_id)
        puts "progress: #{response.completion}%"
        sleep 5.0
        done = response.completion.to_i == 100 && response.workflow_state == 'completed'
      end

      begin
        export = canvas.export_content_courses(
          temp_course.id,
          'common_cartridge',
          {
            'skip_notifications' => true
          }
        )
      rescue Footrest::HttpError::Forbidden => e
        raise e
      rescue Footrest::HttpError::ErrorBase => e
        raise e
      end

      progress_url = export.progress_url
      progress_id = /\/([^\/]+)$/.match(progress_url)[1]

      done = false

      until done
        response = canvas.query_progress(progress_id)
        puts "progress: #{response.completion}%"
        sleep 5.0
        done = response.completion.to_i == 100 && response.workflow_state == 'completed'
      end

      finished_export = canvas.show_content_export_courses(temp_course.id, export.id)

      FileUtils.mv(import_file.path, "#{import_file.path}.old")

      open(import_file.path, 'wb') do |file|
        file << open(finished_export["attachment"]["url"]).read
      end

      canvas.conclude_course(temp_course.id, 'delete')

      converter = converter_class.new(settings)
      course = converter.export
      export_folder_path = course[:export_folder_path]
      overview_file_path = course[:overview_file_path]

      if overview_file_path
        file = File.new(overview_file_path)
        Canvas::Migration::Worker::upload_overview_file(file, cm)
        cm.update_conversion_progress(95)
      end

      if export_folder_path
        Canvas::Migration::Worker::upload_exported_data(export_folder_path, cm)
        Canvas::Migration::Worker::clear_exported_data(export_folder_path)
      end

      cm.migration_settings[:worker_class] = converter_class.name
      if !cm.migration_settings[:migration_ids_to_import] || !cm.migration_settings[:migration_ids_to_import][:copy]
        cm.migration_settings[:migration_ids_to_import] = {:copy=>{:everything => true}}
      end
      cm.workflow_state = :exported
      saved = cm.save
      cm.update_conversion_progress(100)

      if cm.import_immediately? && !cm.for_course_copy?
         cm.import_content
         cm.update_import_progress(100)
         saved = cm.save
         if converter.respond_to?(:post_process)
           converter.post_process
         end
       end
      saved
    rescue Canvas::Migration::Error
      cm.add_error($!.message, :exception => $!)
      cm.workflow_state = :failed
      cm.job_progress.fail unless cm.skip_job_progress
      cm.save
    rescue => e
      cm.fail_with_error!(e) if cm
    end
  end

  def get_import_file(settings)
    config = ConfigFile.load('external_migration') || {}
    if settings[:export_archive_path]
      File.open(settings[:export_archive_path], 'rb')
    elsif settings[:course_archive_download_url].present?
      _, uri = CanvasHttp.validate_url(settings[:course_archive_download_url])
      CanvasHttp.get(settings[:course_archive_download_url]) do |http_response|
        raise CanvasHttp::InvalidResponseCodeError.new(http_response.code.to_i) unless http_response.code.to_i == 200
        tmpfile = CanvasHttp.tempfile_for_uri(uri)
        http_response.read_body(tmpfile)
        tmpfile.rewind
        return tmpfile
      end
    elsif settings[:attachment_id]
      att = Attachment.find(settings[:attachment_id])
      att.open(:temp_folder => config[:data_folder], :need_local_file => true)
    end
  end

  def self.enqueue(content_migration)
    Delayed::Job.enqueue(new(content_migration.id),
                         :priority => Delayed::LOW_PRIORITY,
                         :max_attempts => 1,
                         :strand => content_migration.strand)
  end

end
