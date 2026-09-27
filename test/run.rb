picoruby_root = ENV['PICORUBY_ROOT'] || File.expand_path('../../../picoruby', __dir__)
require File.join(picoruby_root, 'mrbgems/picoruby-picotest/mrblib/picotest')
require_relative '../../picoruby-telemetry/mrblib/telemetry'
require_relative '../../picoruby-telemetry-transport/mrblib/transport'
require_relative '../mrblib/zabbix'
Dir[File.join(__dir__, '*_test.rb')].each { |path| require path }
failed = false
ObjectSpace.each_object(Class).select { |klass| klass < Picotest::Test }.each do |klass|
  klass.instance_methods(false).grep(/^test_/).each do |method|
    test = klass.new
    test.send(method)
    failed ||= !test.result['failures'].empty?
  end
end
puts
exit(failed ? 1 : 0)
