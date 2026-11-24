require "uri"
require "./http/client"
require "./http/server"
# The umbrella keeps HTTP::Server#bind_tls, which HTTP::Client no longer brings
# in now that the client speaks TLS through Beryl.
require "./http/server/tls"
require "./http/log"
require "./http/common"

# The HTTP module contains `HTTP::Client`, `HTTP::Server` and `HTTP::WebSocket` implementations.
#
# NOTE: To use `HTTP`, you must explicitly import it with `require "http"`
module HTTP
end
