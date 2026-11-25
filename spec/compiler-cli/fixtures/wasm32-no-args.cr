# Run by a WASI host that passes zero program arguments (argc 0).
require "log"

Log.info { "logging works" }
puts "program name: #{PROGRAM_NAME.inspect}"
puts "arguments: #{ARGV.size}"
puts "progname: #{Log.progname.inspect}"
puts "top-level code ran"
