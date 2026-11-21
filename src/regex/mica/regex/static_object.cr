module Regex::Mica::Regex
  # :nodoc:
  # Declares the class variable `@@name` as one *type* object that lives in
  # the program's static data rather than in the garbage-collected heap,
  # built with *arguments* when the program starts.
  #
  # A table or lock the engine shares across the process is declared this
  # way so that a program which links Mica starts with the same collector
  # heap as one that does not: making the object asks the collector for
  # nothing. The collector scans static data as it scans every class
  # variable, so the object may hold references to collected objects (a
  # `Hash` declared this way still keeps its entries in the collector's
  # heap, from its first insertion on).
  #
  # ```
  # Mica::Regex.static_object(shared_mutex, Mutex)
  # @@shared_mutex.synchronize { }
  # ```
  macro static_object(name, type, *arguments)
    @@{{name.id}}_storage = uninitialized ReferenceStorage({{type}})
    @@{{name.id}} : {{type}} = {{type}}.unsafe_construct(pointerof(@@{{name.id}}_storage), {{arguments.splat}})
  end

  # :nodoc:
  # Builds one *type* object with *arguments* in the stack frame of the
  # method that calls it, and returns it. The object is valid until that
  # method returns, so the method keeps it to itself and to the calls it
  # makes: nothing that outlives the call may use it afterward. The
  # collector scans a fiber's stack, so the object may hold references.
  #
  # A compilation's parser, ledger and work meter are made this way: they
  # serve one call, and making them asks the collector for nothing.
  macro stack_object(type, *arguments)
    %storage = uninitialized ReferenceStorage({{type}})
    {{type}}.unsafe_construct(pointerof(%storage), {{arguments.splat}})
  end

  # :nodoc:
  # Declares the constant *name* as one *type* object in the program's
  # static data (see `static_object`), built with *arguments*.
  macro static_constant(name, type, *arguments)
    @@{{name.id.downcase}}_storage = uninitialized ReferenceStorage({{type}})
    {{name.id}} = {{type}}.unsafe_construct(pointerof(@@{{name.id.downcase}}_storage), {{arguments.splat}})
  end
end
