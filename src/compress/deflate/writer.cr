{% if flag?(:use_libz) %}
  require "./lib_z/writer"
{% else %}
  require "./mica/writer"
{% end %}
