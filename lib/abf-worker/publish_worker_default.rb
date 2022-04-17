require 'resque'

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
      @repository_id   = options['repository']['id']
      @packages        = options['packages'] || {}
      @old_packages    = options['old_packages'] || {}
      @main_script     = "publisher.py"
      init_packages_lists
      system "rm -rf /root/.gnupg/ && mkdir /root/.gnupg && chmod 700 /root/.gnupg && rm -rf /root/gnupg && mkdir /root/gnupg"
      get_public_key
      get_keys if !options.include?('resign_rpms') || options['resign_rpms']
      system 'rm -rf ' + APP_CONFIG['output_folder'] + '/publish.log'
      run_script
      send_results
    end

    private

    def send_results
      log_path = APP_CONFIG['output_folder'] + "/publish.log"
      log_size = (File.size(log_path).to_f / 2**20).round(2)
      log_sha1 = Digest::SHA1.file(log_path).hexdigest

      curl_cmd = "curl -fs --user #{APP_CONFIG['file_store']['token']}: -POST -F \"file_store[file]=@#{log_path}\" --connect-timeout 5 #{APP_CONFIG['file_store']['create_url']} 2> /dev/null"
      loop do
        begin
          resp = JSON.parse(popen_with_rescue(curl_cmd))
          break
        rescue => e
          puts "Failed to parse JSON: #{e.message}, retrying..."
          sleep 10
          retry
        end
      end

      results = {id:                   @options['id'],
                 status:               @status,
                 extra:                @options['extra'],
                 projects_for_cleanup: @options['projects_for_cleanup'],
                 build_list_ids: @options['build_list_ids'],
                 results: [{file_name: 'publish.log', sha1: log_sha1, size: log_size}] }
      Resque.push(
        'publish_observer',
        'class' => 'AbfWorker::PublishObserver',
        'args'  => [results]
      )
    end

    def run_script
      command = base_command_for_run
      script_name = @main_script
      command << script_name
      output_folder = APP_CONFIG['output_folder']

      exit_status = nil
      @script_pid = Process.spawn(command.join(' '), [:out,:err]=>[output_folder + "/publish.log", "a"])
      Process.wait(@script_pid)
      exit_status = $?.exitstatus
      if exit_status.nil? or exit_status != 0
        @status = 1
      else
        @status = 0
      end
    end

    def base_command_for_run
      [
        'cd ' + ROOT + '/scripts/;',
        @cmd_params,
        ' /usr/bin/python '
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

    def popen_with_rescue(cmd, sleep_for = 10)
      cmd_name = cmd.split(/\s+/).first
      res = nil
      loop do
        begin
          IO.popen(cmd) do |io|
            res = io.read
          end
        rescue => e
          puts "IO.popen error, cmd #{cmd_name}: #{e.message}, retrying in #{sleep_for}..."
          sleep sleep_for
          retry
        end
        exitstatus = $?.exitstatus
        break if exitstatus == 0
        puts "#{cmd_name} failed with exit status #{exitstatus}, retrying..."
        sleep sleep_for
      end
      res
    end

    def get_public_key
      resp = popen_with_rescue("curl -fs -u #{APP_CONFIG['file_store']['token']}: https://abf.rosalinux.ru/api/v1/repositories/#{@repository_id}/public_key 2> /dev/null")
      system 'rm -f /tmp/pubkey'
      if resp && resp.length > 0
        open('/tmp/pubkey', 'w') { |f| f.write(resp) }
      end
    end

    def get_keys
       resp = nil
       loop do
         begin
           resp = JSON.parse(popen_with_rescue("curl -fs -u #{APP_CONFIG['file_store']['token']}: https://abf.rosalinux.ru/api/v1/repositories/#{@repository_id}/key_pair 2> /dev/null"))
           break
         rescue => e
           puts "Failed to parse JSON: #{e.message}, retrying..."
           sleep 10
           retry
         end
       end
      if resp && resp['repository'] && resp['repository']['key_pair']
        key_pair = resp['repository']['key_pair']
        if key_pair['public'].length > 0 && key_pair['secret'].length > 0
          open("/root/gnupg/pubring.gpg", "w") { |f| f.write(key_pair['public']) }
          open("/root/gnupg/secring.gpg", "w") { |f| f.write(key_pair['secret']) }
        end
      end
    end
  end

  class PublishWorker < PublishWorkerDefault
  end
end
