module AbfWorker
  class PublishWorkerDefault
    def self.perform(options)
      new.perform(options)
    end

    def perform(options)
      @options         = options
      @cmd_params      = options['cmd_params']
      @cmd_params     += " PLATFORM_PATH=" + options['platform']['platform_path']
      @platform_type   = options['platform']['type']
      @packages        = options['packages'] || {}
      @old_packages    = options['old_packages'] || {}
      @main_script     = options['main_script']
      @rollback_script = options['rollback_script']
      init_packages_lists
      system 'rm -rf ' + APP_CONFIG['output_folder'] + '/publish.log'
      run_script
      send_results
    end

    private

    def send_results
      log_path = APP_CONFIG['output_folder'] + "/publish.log"
      log_size = (File.size(log_path).to_f / 2**20).round(2)
      log_sha1 = Digest::SHA1.file(log_path).hexdigest

      `curl --user #{APP_CONFIG['file_store']['token']}: \
      -POST -F "file_store[file]=@#{log_path}" --connect-timeout 5 --retry 5 \
      #{APP_CONFIG['file_store']['create_url']}`

      results = {id:                   @options['id'],
                 status:               @status,
                 extra:                @options['extra'],
                 projects_for_cleanup: @options['projects_for_cleanup'],
                 build_list_ids: @options['build_list_ids'],
                 results: [{file_name: 'publish.log', sha1: log_sha1, size: log_size}] }
      Sidekiq::Client.push(
        'queue' => 'publish_observer',
        'class' => 'AbfWorker::PublishObserver',
        'args'  => [results]
      )
    end

    def run_script(rollback = false)
      command = base_command_for_run
      script_name = rollback ? @rollback_script : @main_script
      command << script_name
      output_folder = APP_CONFIG['output_folder']

      exit_status = nil
      @script_pid = Process.spawn(command.join(' '), [:out,:err]=>[output_folder + "/publish.log", "a"])
      Process.wait(@script_pid)
      exit_status = $?.exitstatus
      if exit_status.nil? or exit_status != 0
        @status = 1
        run_script(true)
      elsif rollback
        @status = 1
      else
        @status = 0
      end
    end

    def base_command_for_run
      [
        'cd ' + ROOT + '/scripts/' + @platform_type + ';',
        @cmd_params,
        ' /bin/bash '
      ]
    end

    def init_packages_lists
      puts 'Initialize lists of new and old packages...'

      system 'rm -rf ' + ROOT + '/container/*'
      [@packages, @old_packages].each_with_index do |packages, index|
        prefix = index == 0 ? 'new' : 'old'
        add_packages_to_list packages['sources'], "#{prefix}.SRPMS.list"
        (packages['binaries'] || {}).each do |arch, list|
          add_packages_to_list list, "#{prefix}.#{arch}.list"
        end
      end
    end

    def add_packages_to_list(packages = [], list_name)
      return if packages.nil? || packages.empty?
      file = File.open(ROOT + "/container/#{list_name}", "w")
      packages.each{ |p| file.puts p }
      file.close
    end

  end

  class PublishWorker < PublishWorkerDefault
  end
end
