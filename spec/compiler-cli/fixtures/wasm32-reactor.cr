# A WASI reactor, built with `-Dwithout_main`: the host calls `_initialize`,
# which runs this top-level code, and then `reactor_add`.
module Reactor
  class_property offset = 0
end

Reactor.offset = 100

fun reactor_add(first_number : Int32, second_number : Int32) : Int32
  Reactor.offset + first_number + second_number
end
