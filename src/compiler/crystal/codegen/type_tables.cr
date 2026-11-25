require "./codegen"

class Crystal::CodeGenVisitor
  # The tables that describe the program's types: the global that holds each
  # type id (`Foo:type_id`), the subtype checks (`~match<Foo+>`), the map
  # from an object's type id to its class's (`~metaclass`) and the map from
  # a type id to the type's name (`__crystal_type_id_to_class_name_map`).
  #
  # With one module per type they are a module of their own, generated once
  # IR generation is done, from the entries the program asked for, in name
  # order. Every other module, the main one included, declares what it
  # uses. Adding a type anywhere in the program (one more tuple for an
  # interpolation, say) changes these tables, and with them in the main
  # module its object was compiled again: in an Amber app of 300 resources
  # that is about 80 s of a one-method edit. The type tables module is
  # small and compiles in about a second.
  #
  # In a single module build (`--single-module`, the interpreter, a
  # cross-compilation) they stay in the main module, defined on first use.
  module TypeTables
    MODULE_NAME = "~type_tables"

    # What the program asked of the type tables while its modules were
    # generated.
    class Requests
      getter type_by_type_id_name = {} of String => Type
      getter match_type_by_fun_name = {} of String => Type
      property? needs_metaclass = false
    end
  end

  @type_table_requests = TypeTables::Requests.new
  @type_tables_module_info : ModuleInfo?

  # Whether the type tables are a module of their own (see `TypeTables`).
  private def separate_type_tables? : Bool
    !@single_module
  end

  # The module that defines the type tables right now: the main module in
  # a single module build, the type tables module while it is generated,
  # and none before that (each module then only declares what it uses).
  private def type_tables_home : ModuleInfo?
    return @main_module_info unless separate_type_tables?

    @type_tables_module_info
  end

  # The function named *name* of the type tables, in the module code is
  # being generated into: defined by the block in the module that defines
  # the tables, and declared from *type* anywhere else.
  private def type_table_fun(name : String, type : LLVM::Type, & : -> LLVMTypedFunction) : LLVMTypedFunction
    if home = type_tables_home
      func = typed_fun?(home, name) || yield
      check_mod_fun home, name, func
    else
      typed_fun?(@module_info, name) || add_typed_fun(@module_info, name, type)
    end
  end

  # Generates the type tables module from what the program asked for, in
  # name order: the same requests give the same module, whichever modules
  # were generated and whichever were matched with the build before (a
  # matched module replays its requests, see `IrSkip`).
  private def generate_type_tables : Nil
    unless separate_type_tables?
      codegen_typeinfo(@main_module_info)
      return
    end

    requests = @type_table_requests
    llvm_mod, llvm_typer = new_module_and_typer(TypeTables::MODULE_NAME)
    module_info = ModuleInfo.new(TypeTables::MODULE_NAME, llvm_mod, llvm_typer)
    module_info.builder = new_builder(module_info)
    module_info.pin_count = 1
    @type_tables_module_info = module_info
    @modules[TypeTables::MODULE_NAME] = module_info

    in_module(module_info) do
      requests.type_by_type_id_name.keys.sort!.each do |type_id_name|
        type_id_global_in(module_info, requests.type_by_type_id_name[type_id_name])
      end
      requests.match_type_by_fun_name.keys.sort!.each do |fun_name|
        type = requests.match_type_by_fun_name[fun_name]
        if type.is_a?(UnionType) || type.is_a?(VirtualType) || type.is_a?(VirtualMetaclassType)
          match_fun(type)
        end
      end
      metaclass_fun if requests.needs_metaclass?
      codegen_typeinfo(module_info)
    end
  end
end
