# Crystal WASM Demo Server
#
# A simple static file server for the WASM browser demo.
# Serves files from the same directory as this script.
#
# Usage: crystal run samples/wasm/server.cr
#        Then open http://localhost:8080

require "http/server"

PORT = 8080
DIR  = File.dirname(__FILE__)

MIME_TYPES = {
  ".html" => "text/html",
  ".js"   => "application/javascript",
  ".css"  => "text/css",
  ".wasm" => "application/wasm",
  ".cr"   => "text/plain",
  ".json" => "application/json",
  ".png"  => "image/png",
  ".ico"  => "image/x-icon",
}

server = HTTP::Server.new do |context|
  path = context.request.path
  path = "/index.html" if path == "/"

  file_path = File.join(DIR, path.lstrip('/'))

  if File.exists?(file_path) && !File.directory?(file_path)
    ext = File.extname(file_path)
    content_type = MIME_TYPES[ext]? || "application/octet-stream"
    context.response.content_type = content_type
    context.response.print File.read(file_path)
  else
    context.response.status = HTTP::Status::NOT_FOUND
    context.response.content_type = "text/plain"
    context.response.print "404 Not Found: #{path}"
  end
end

puts "Crystal WASM Demo Server"
puts "Serving #{DIR} on http://localhost:#{PORT}"
puts "Press Ctrl+C to stop"
server.listen("0.0.0.0", PORT)
