require 'yaml'
require 'erb'

Thread.abort_on_exception = true

ROOT = File.dirname(__FILE__) + '/../../../'

APP_CONFIG = YAML.load(ERB.new(File.read(File.join(ROOT, "config", "application.yml"))).result)
Dir.mkdir(APP_CONFIG['output_folder']) if !Dir.exists?(APP_CONFIG['output_folder'])
Dir.mkdir(ROOT + '/container') if !Dir.exists?(ROOT + '/container')
