{% if flag?(:use_libz) %}
  require "./lib_z/reader"
{% else %}
  require "./mica/reader"
{% end %}
