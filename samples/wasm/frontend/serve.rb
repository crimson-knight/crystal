#!/usr/bin/ruby
# Serve the browser type checker: this folder plus the module and bundle given.
# usage: serve.rb <port> <frontend.wasm> <bundle.json> <results.jsonl>
#   POST /report appends one JSON line to <results.jsonl>.
require "webrick"

port, wasm_path, bundle_path, results_path = ARGV
abort "usage: serve.rb <port> <frontend.wasm> <bundle.json> <results.jsonl>" unless results_path

mime = WEBrick::HTTPUtils::DefaultMimeTypes.merge("wasm" => "application/wasm", "mjs" => "text/javascript")
server = WEBrick::HTTPServer.new(Port: port.to_i, BindAddress: "127.0.0.1", MimeTypes: mime,
                                 DocumentRoot: __dir__, AccessLog: [], Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN))
server.mount("/frontend.wasm", WEBrick::HTTPServlet::FileHandler, wasm_path)
server.mount("/bundle.json", WEBrick::HTTPServlet::FileHandler, bundle_path)
server.mount_proc("/report") do |request, response|
  File.open(results_path, "a") { |file| file.puts(request.body) }
  response.status = 204
end
trap("TERM") { server.shutdown }
trap("INT") { server.shutdown }
server.start
