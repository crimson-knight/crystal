require "../../spec_helper"

private ANIMALS = <<-CRYSTAL
  class Animal
    def legs
      4
    end
  end

  class Dog < Animal
  end

  class Bird < Animal
    def legs
      2
    end
  end

  class Rock
  end
  CRYSTAL

# The same program with one more class in the middle of the hierarchy.
private ANIMALS_WITH_A_NEW_CLASS = ANIMALS.sub("class Bird < Animal", "class Puppy < Dog\nend\n\nclass Bird < Animal")

private def type_ids_of(code : String, kept_type_ids : Hash(String, Int32)?) : {Crystal::Program, Crystal::LLVMId}
  program = semantic(code).program
  {program, Crystal::LLVMId.new(program, kept_type_ids)}
end

private def id_is_in_ranges?(list_of_ranges : Array({Int32, Int32}), id : Int32) : Bool
  list_of_ranges.any? { |(min, max)| min <= id <= max }
end

# The names of the functions of *mod* that start with *prefix*.
private def function_names(mod : LLVM::Module, prefix : String) : Array(String)
  list_of_names = [] of String
  mod.functions.each do |function|
    list_of_names << function.name if function.name.starts_with?(prefix)
  end
  list_of_names.sort!
end

private PROC_LITERALS = <<-CRYSTAL
  class Counter
    def steps
      first = ->(number : Int32) { number &+ 1 }
      second = ->(number : Int32) { number &+ 2 }
      label = ->{ 3 }
      first.call(1) &+ second.call(1) &+ label.call
    end
  end

  Counter.new.steps
  CRYSTAL

private STABLE_PROGRAM = <<-CRYSTAL
  require "prelude"

  abstract class Shape
    abstract def area : Int32

    def describe : String
      "\#{self.class.name} \#{area}"
    end
  end

  class Square < Shape
    def initialize(@side : Int32)
    end

    def area : Int32
      @side * @side
    end
  end

  class Strip < Shape
    def initialize(@length : Int32)
    end

    def area : Int32
      @length
    end
  end

  class Ledger
    def initialize
      @entries = [] of String
    end

    def record(shape : Shape) : Nil
      offset = @entries.size
      label = ->(text : String) { "\#{offset}:\#{text}" }
      @entries << label.call(shape.describe)
    end

    def report : String
      @entries.join(",")
    end
  end

  module Sizes
    def self.largest(list_of_shapes : Array(Shape)) : Int32
      list_of_shapes.max_of(&.area)
    end

    def self.count_of_squares(list_of_shapes : Array(Shape)) : Int32
      list_of_shapes.count(&.is_a?(Square))
    end
  end

  list_of_shapes = [Square.new(3), Strip.new(5)] of Shape
  # more shapes
  ledger = Ledger.new
  list_of_shapes.each { |shape| ledger.record(shape) }
  puts ledger.report, Sizes.largest(list_of_shapes), Sizes.count_of_squares(list_of_shapes)
  CRYSTAL

private def build_stable_program(directory : String, code : String, build_index : Int32) : {String, Crystal::Compiler}
  program = File.join(directory, "program.cr")
  File.write(program, code)
  # The cache tells an edited file by its time and size.
  File.touch(program, Time.utc + build_index.seconds)
  executable = File.join(directory, "program")

  compiler = Crystal::Compiler.new
  compiler.incremental = true
  # A resident set this small writes most modules to disk in several parts.
  compiler.resident_modules = 2
  # Line numbers in debug info move with every line added above them.
  compiler.debug = Crystal::Debug::None
  ENV["CRYSTAL_SPEC_COMPILER_FLAGS"]?.try { |flags| compiler.flags.concat(flags.split) }
  compiler.compile(Crystal::Compiler::Source.new(program, File.read(program)), executable)
  {Process.capture(executable), compiler}
end

describe "Code generation: stable numbering" do
  describe "type ids" do
    it "numbers a program the usual way when no ids are kept" do
      program, usual = type_ids_of(ANIMALS, nil)
      _, kept_from_nothing = type_ids_of(ANIMALS, {} of String => Int32)

      %w(Animal Dog Bird Rock).each do |name|
        kept_from_nothing.type_ids_in_use_by_stable_key[name].should eq(usual.type_id(program.types[name]))
      end
      usual.stable?.should be_false
      kept_from_nothing.stable?.should be_true
    end

    it "keeps every id when a type is added, and numbers the new type after them" do
      _, before = type_ids_of(ANIMALS, {} of String => Int32)
      kept_type_ids = before.type_ids_in_use_by_stable_key
      program, after = type_ids_of(ANIMALS_WITH_A_NEW_CLASS, kept_type_ids)

      kept_type_ids.each do |stable_key, id|
        after.type_ids_in_use_by_stable_key[stable_key].should eq(id)
      end
      after.type_id(program.types["Puppy"]).should be > kept_type_ids.each_value.max
      after.type_ids_in_use_by_stable_key.values.uniq.size.should eq(after.type_ids_in_use_by_stable_key.size)
    end

    it "gives the ranges that hold a type's subtypes and nothing else" do
      _, before = type_ids_of(ANIMALS, {} of String => Int32)
      program, after = type_ids_of(ANIMALS_WITH_A_NEW_CLASS, before.type_ids_in_use_by_stable_key)

      list_of_animal_ranges = after.id_ranges(program.types["Animal"])
      list_of_animal_ranges.size.should eq(2)
      %w(Animal Dog Puppy Bird).each do |name|
        id_is_in_ranges?(list_of_animal_ranges, after.type_id(program.types[name])).should be_true
      end
      id_is_in_ranges?(list_of_animal_ranges, after.type_id(program.types["Rock"])).should be_false
      id_is_in_ranges?(list_of_animal_ranges, after.type_id(program.string)).should be_false

      list_of_dog_ranges = after.id_ranges(program.types["Dog"])
      id_is_in_ranges?(list_of_dog_ranges, after.type_id(program.types["Puppy"])).should be_true
      id_is_in_ranges?(list_of_dog_ranges, after.type_id(program.types["Bird"])).should be_false
      id_is_in_ranges?(list_of_dog_ranges, after.type_id(program.types["Animal"])).should be_false
    end

    it "gives one range, the usual one, when no ids are kept" do
      program, usual = type_ids_of(ANIMALS_WITH_A_NEW_CLASS, nil)
      animal = program.types["Animal"]

      usual.id_ranges(animal).should eq([usual.min_max_type_id(animal).not_nil!])
    end

    it "replaces a kept id that another type of the build has" do
      program, llvm_id = type_ids_of(ANIMALS, {"Dog" => 7, "Bird" => 7, "Rock" => -3})

      list_of_ids = %w(Animal Dog Bird Rock).map { |name| llvm_id.type_id(program.types[name]) }
      list_of_ids.uniq.size.should eq(4)
      list_of_ids.all?(&.>(0)).should be_true
    end

    it "numbers every type again once most kept ids are unused" do
      program, llvm_id = type_ids_of(ANIMALS, {"Dog" => 900_000})

      llvm_id.type_id(program.types["Dog"]).should be < 1000
    end

    it "checks subtypes correctly when a new class sits between kept ids" do
      numbering = Crystal::StableNumbering.new
      before = semantic(%(#{ANIMALS}\n(Dog.new || Bird.new || Rock.new).is_a?(Animal)), inject_primitives: true)
      before.program.stable_numbering = numbering
      before.program.codegen(before.node, single_module: true)
      numbering.type_ids_by_stable_key = before.program.llvm_id.type_ids_in_use_by_stable_key

      after = semantic(<<-CRYSTAL, inject_primitives: true)
        #{ANIMALS_WITH_A_NEW_CLASS}

        def count_animals(first, second, third, fourth)
          count = 0
          count &+= 1 if first.is_a?(Animal)
          count &+= 10 if second.is_a?(Animal)
          count &+= 100 if third.is_a?(Animal)
          count &+= 1000 if fourth.is_a?(Animal)
          count &+= 10000 if second.is_a?(Dog)
          count &+= 100000 if third.is_a?(Dog)
          count
        end

        list = {Dog.new || Puppy.new || Bird.new || Rock.new, Puppy.new || Dog.new || Bird.new || Rock.new,
                Bird.new || Puppy.new || Dog.new || Rock.new, Rock.new || Puppy.new || Bird.new || Dog.new}
        count_animals(list[0], list[1], list[2], list[3]) &+ (Puppy.new || Bird.new).legs &+ (Bird.new || Puppy.new).legs
        CRYSTAL
      after.program.stable_numbering = numbering
      # Animal, Puppy and Bird are animals, the rock is not, and of the
      # second and third only the puppy is a dog; then 4 legs and 2 legs.
      after.program.evaluate(after.node, Int32).should eq(10111 + 4 + 2)
      after.program.llvm_id.id_ranges(after.program.types["Animal"]).size.should eq(2)
    end
  end

  describe "functions shared by owners of one shape" do
    it "keeps the owner that stood for a group when a new class of that shape comes first" do
      shared_advance = <<-CRYSTAL
        class Base
          def initialize(@count : Int32)
          end

          def advance
            @count = @count &+ 1
          end
        end

        class First < Base
        end

        class Second < Base
        end
        CRYSTAL
      numbering = Crystal::StableNumbering.new
      before = semantic(%(#{shared_advance}\nFirst.new(1).advance &+ Second.new(2).advance), inject_primitives: true)
      before.program.stable_numbering = numbering
      before.program.codegen(before.node, single_module: true)
      numbering.type_ids_by_stable_key = before.program.llvm_id.type_ids_in_use_by_stable_key

      with_a_new_class_first = %(#{shared_advance.sub("class First < Base", "class Earlier < Base\nend\n\nclass First < Base")}
        Earlier.new(0).advance &+ First.new(1).advance &+ Second.new(2).advance)
      owner_that_stands_for_the_group = ->(kept_numbering : Crystal::StableNumbering?) do
        result = semantic(with_a_new_class_first, inject_primitives: true)
        result.program.stable_numbering = kept_numbering
        sharing = Crystal::OwnerShapeSharing.new(result.program)
        sharing.analyze(result.node)
        shape = sharing.shapes.find! { |candidate| candidate.typed_def.name == "advance" && candidate.typed_def.owner.to_s == "Second" }
        sharing.representative?(shape.typed_def).not_nil!.owner.to_s
      end

      owner_that_stands_for_the_group.call(nil).should eq("Earlier")
      owner_that_stands_for_the_group.call(numbering).should eq("First")
    end
  end

  describe "proc literal functions" do
    it "names them after the function they are in and their turn in it" do
      mod = codegen(PROC_LITERALS)

      function_names(mod, "~proc").should eq([
        "~proc2Proc(Int32, Int32)@*Counter#steps:Int32",
        "~procProc(Int32)@*Counter#steps:Int32",
        "~procProc(Int32, Int32)@*Counter#steps:Int32",
      ])
    end

    it "keeps their names when lines are added above them" do
      names = function_names(codegen(PROC_LITERALS, debug: Crystal::Debug::Default), "~proc")
      names_after_new_lines = function_names(codegen("# one\n# two\n\n#{PROC_LITERALS}", debug: Crystal::Debug::Default), "~proc")

      names_after_new_lines.should eq(names)
      names.size.should eq(3)
    end
  end

  describe "incremental rebuilds" do
    it "reuses every object file after lines are added at the top of the file" do
      with_tempfile("stable_program_lines") do |directory|
        Dir.mkdir_p(directory)
        output, _ = build_stable_program(directory, STABLE_PROGRAM, 1)
        output.should eq("0:Square 9,1:Strip 5\n9\n1\n")

        output, rebuild = build_stable_program(directory, STABLE_PROGRAM.sub(%(require "prelude"\n), %(require "prelude"\n\n# one\n# two\n# three\n\n)), 2)
        output.should eq("0:Square 9,1:Strip 5\n9\n1\n")
        rebuild.last_list_of_rebuilt_module_names.should be_empty
        rebuild.@last_modules_total.should be > 100
      end
    end

    it "rebuilds only what uses a new class, and still tells the classes apart" do
      with_tempfile("stable_program_class") do |directory|
        Dir.mkdir_p(directory)
        build_stable_program(directory, STABLE_PROGRAM, 1)

        with_a_new_class = STABLE_PROGRAM
          .sub("class Strip < Shape", "class Tile < Square\n  def area : Int32\n    super + 1\n  end\nend\n\nclass Strip < Shape")
          .sub("# more shapes", "list_of_shapes << Tile.new(2)")
        output, rebuild = build_stable_program(directory, with_a_new_class, 2)
        output.should eq("0:Square 9,1:Strip 5,2:Tile 5\n9\n2\n")

        list_of_rebuilt_module_names = rebuild.last_list_of_rebuilt_module_names
        list_of_rebuilt_module_names.should contain("Tile")
        # Modules that have nothing to do with the new class.
        %w(Strip String Array(String) Int32 Exception).each do |name|
          list_of_rebuilt_module_names.should_not contain(name)
        end
        list_of_rebuilt_module_names.size.should be < 12

        # The numbering of the first build is still what the third one keeps.
        _, restored = build_stable_program(directory, STABLE_PROGRAM, 3)
        restored.last_list_of_rebuilt_module_names.should_not contain("Strip")
        restored.last_list_of_rebuilt_module_names.should_not contain("String")
      end
    end
  end
end
